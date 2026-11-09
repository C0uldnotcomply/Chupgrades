-- Chupgrades: scans the Auction House, scores gear with your stat priority addon,
-- and lists the best-value upgrade "ladder" for each slot.
--
-- Stat weights come from, in order of preference:
--   1. StatPriority (Todd King, CurseForge): its own per-spec weights and item scoring
--      (simulated per-point values for WoW: Forever specs), the same maths as its tooltip.
--   2. StatLedger: priority weights, combined with the StatMap / StatScale tables in Config.lua.

local CU  = Chupgrades
local cfg -- filled in on ADDON_LOADED

-- Modern API names first, older globals as a fallback.
local GetItemInfo        = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetItemStats       = (C_Item and C_Item.GetItemStats) or GetItemStats

local function Print(...) print("|cff33ff99Chupgrades:|r", ...) end

local MAX_MONEY = 2147483647
local function Finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function ValidNumber(n, lo, hi, integer)
  return Finite(n) and n >= lo and n <= hi and (not integer or n == math.floor(n))
end
local function RequestItem(item)
  local id = type(item) == "number" and item or type(item) == "string" and tonumber(item:match("item:(%d+)"))
  if id and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

-- Bare numbers are gold. Unit amounts may be joined (1g33s) or separated by spaces.
function CU.ParseMoney(text)
  text = type(text) == "string" and text:lower():match("^%s*(.-)%s*$") or ""
  if text == "" then return nil, "Enter an amount, such as 5 or 1g 33s 38c." end
  local total, number = 0, tonumber(text)
  if text:match("^%d*%.?%d+$") and number then
    total = number * 10000
  else
    local pos, seen = 1, {}
    while pos <= #text do
      local first, last, amount, unit = text:find("%s*(%d*%.?%d+)%s*([gsc])%s*", pos)
      if first ~= pos or seen[unit] then return nil, "Use gold, silver and copper, for example 1g 33s 38c." end
      seen[unit] = true
      total = total + tonumber(amount) * ({g=10000,s=100,c=1})[unit]
      pos = last + 1
    end
  end
  if not ValidNumber(total, 0, MAX_MONEY) then return nil, "That money amount is out of range." end
  return math.floor(total + .5)
end

local function CancelTimer(timer) if timer then timer:Cancel() end end
local function SameKey(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for _, k in ipairs({"itemID", "itemLevel", "itemSuffix", "battlePetSpeciesID", "battlePetBreedQuality", "battlePetLevel"}) do
    if (a[k] or 0) ~= (b[k] or 0) then return false end
  end
  return true
end

---------------------------------------------------------------------------
-- Where the weights come from
---------------------------------------------------------------------------
local backend          -- "statpriority" | "statledger" | nil
local scoreCache, lastWeights = {}, nil

local function SPAddon()
  local sp = _G.StatPriority
  if sp and type(sp.GetActiveWeights) == "function" and type(sp.ScoreItem) == "function" then return sp end
end

local function LedgerAddon()
  local l = _G.StatLedger
  if l and type(l.GetWeights) == "function" then return l end
  local sp = _G.StatPriority -- older StatLedger versions used this name
  if sp and type(sp.GetWeights) == "function" then return sp end
end

local WEIGHT_PROBLEMS = {
  nospec = "StatPriority doesn't know your spec yet. Spend a talent point, or click its bar on the Character sheet to pick one.",
  nodata = "StatPriority has no stat data for your spec.",
}

function CU.IsLevelling()
  local mode = cfg and cfg.levelling or "auto"
  if mode == "on" then return true elseif mode == "off" then return false end
  return (UnitLevel("player") or 1) < ((CU.Levelling and CU.Levelling.maxLevel) or 60)
end

-- Casters and healers: specs whose hit type in Config.lua is "spell" or "none".
function CU.IsManaCaster(class, spec)
  local ht = CU.HitType and class and CU.HitType[class]
  local kind = ht and ((spec and ht[spec]) or ht.ALL)
  return kind == "spell" or kind == "none"
end

-- Applies Config.lua's corrections and levelling Stamina on top of StatPriority's values.
-- Works on a copy (StatPriority's own table is never changed) and reuses it while nothing
-- relevant changes, so item scores can stay cached.
local adjustedKey, adjusted
function CU.AdjustWeights(w)
  if cfg and cfg.safeMode then return w end
  local _, class = UnitClass("player")
  local spec, levelling = CU.specID, CU.IsLevelling()
  local parts = {}
  for k, v in pairs(w) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
  table.sort(parts)
  local key = table.concat(parts, ";") .. ":" .. tostring(class) .. ":" .. tostring(spec) .. ":" .. tostring(levelling)
  if key == adjustedKey then return adjusted end
  local t = {}
  for k, v in pairs(w) do t[k] = v end
  local layers = { CU.WeightAdjust and CU.WeightAdjust.ALL }
  local mine = CU.WeightAdjust and class and CU.WeightAdjust[class]
  if mine then
    table.insert(layers, mine.ALL)
    if spec then table.insert(layers, mine[spec]) end
  end
  for i = 1, 3 do
    for k, v in pairs(layers[i] or {}) do
      if type(k) == "string" and k:match("^[A-Z]") and type(v) == "number" then t[k] = v end
    end
  end
  local stam = CU.Levelling and CU.Levelling.stamina
  if levelling and stam and CU.specRole ~= "tank" then
    t.ITEM_MOD_STAMINA_SHORT = math.max(t.ITEM_MOD_STAMINA_SHORT or 0, stam)
  end
  local floors = CU.Levelling and CU.Levelling.manaFloors
  if levelling and floors and CU.IsManaCaster(class, spec) then
    for k, v in pairs(floors) do t[k] = math.max(t[k] or 0, v) end
  end
  local sf = levelling and CU.Levelling and CU.Levelling.specFloors and class and CU.Levelling.specFloors[class]
  sf = sf and ((spec and sf[spec]) or sf.ALL)
  if type(sf) == "table" then
    for k, v in pairs(sf) do
      if type(v) == "number" then t[k] = math.max(t[k] or 0, v) end
    end
  end
  adjusted, adjustedKey = t, key
  return t
end

-- StatPriority's weights for ANY spec of your class (not just the one it detected), built the
-- same way it builds its own: simulated per-point values on Forever, else the priority line.
-- Cached per spec so item scores can stay cached too.
local specWeightCache = {}
function CU.WeightsForSpec(sp, class, id)
  local key = tostring(class) .. ":" .. tostring(id)
  local hit = specWeightCache[key]
  if hit then return hit.w, hit.name end
  local okF, isForever = pcall(sp.IsForever, sp)
  isForever = okF and isForever
  local w
  local ep = isForever and sp.ForeverEP and sp.ForeverEP[class] and sp.ForeverEP[class][id]
  if type(ep) == "table" and sp.BuildEPScoring then
    local ok, r = pcall(sp.BuildEPScoring, sp, ep, class, id)
    if ok then w = r end
  else
    local data = isForever and sp.ForeverSpecs or sp.Specs
    local line = data and data[class] and data[class][id]
    if line and sp.BuildPositionScoring then
      local ok, r = pcall(sp.BuildPositionScoring, sp, line, class)
      if ok then w = r end
    end
  end
  local okN, name = pcall(sp.GetSpecDisplayName, sp, id, isForever)
  name = (okN and name) or ("spec " .. tostring(id))
  if w then specWeightCache[key] = { w = w, name = name } end
  return w, name
end

-- The specs of your class, as { id, name } pairs, from StatPriority.
function CU.ClassSpecs()
  local sp = SPAddon()
  if not (sp and sp.GetSpecChoices) then return {} end
  local ok, list, isForever = pcall(sp.GetSpecChoices, sp)
  if not ok or type(list) ~= "table" then return {} end
  local out = {}
  for _, id in ipairs(list) do
    local okN, name = pcall(sp.GetSpecDisplayName, sp, id, isForever)
    table.insert(out, { id = id, name = (okN and name) or ("spec " .. tostring(id)) })
  end
  return out
end

-- Returns the weights table, or nil plus a message saying what's wrong.
local function GetWeights()
  local w
  local sp = SPAddon()
  if sp then
    local _, class = UnitClass("player")
    local ok, weights, specOrReason, isForever = pcall(sp.GetActiveWeights, sp)
    -- What StatPriority detected (shown next to "Auto" in the window).
    local okR, r = pcall(sp.Resolve, sp)
    CU.detectedSpecID = okR and type(r) == "table" and r.specID or nil
    CU.detectedSpecName = okR and type(r) == "table" and r.specName or nil
    -- A spec picked in the Chupgrades window wins over the detected one.
    local chosen = cfg and cfg.specOverride and cfg.specOverride[class]
    local chosenWeights, chosenName
    if chosen then chosenWeights, chosenName = CU.WeightsForSpec(sp, class, chosen) end
    if chosenWeights then
      backend, CU.spForever, CU.specName, CU.specID, CU.specChosen = "statpriority", select(2, pcall(sp.IsForever, sp)), chosenName, chosen, true
      weights, ok = chosenWeights, true
    elseif ok and weights then
      backend, CU.spForever, CU.specName, CU.specChosen = "statpriority", isForever, specOrReason, false
      CU.specID = CU.detectedSpecID
    end
    if ok and weights then
      -- The spec's role, for levelling Stamina (tanks keep their own value).
      local ep = CU.specID and sp.ForeverEP and sp.ForeverEP[class] and sp.ForeverEP[class][CU.specID]
      CU.specRole = type(ep) == "table" and ep.role or nil
      w = CU.AdjustWeights(weights)
    elseif not LedgerAddon() then
      return nil, (ok and WEIGHT_PROBLEMS[specOrReason]) or "StatPriority couldn't give stat weights."
    end
  end
  if not w then
    local l = LedgerAddon()
    if not l then return nil, "No stat addon found: Chupgrades needs StatPriority (or StatLedger) enabled." end
    backend, w = "statledger", l:GetWeights()
  end
  -- New spec or edited priority = a different weights table: old scores are out of date.
  if w ~= lastWeights then wipe(scoreCache); lastWeights = w end
  return w
end

local function WeightsOrSay()
  local w, problem = GetWeights()
  if not w then Print(problem) end
  return w
end

---------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------
local function ScoreItem(link, weights)
  if not link then return 0 end
  local id = type(link) == "number" and link or tonumber(link:match("item:(%d+)"))
  local cached = not (id and C_Item and C_Item.IsItemDataCachedByID) or C_Item.IsItemDataCachedByID(id)
  local stats = GetItemStats(link)
  if not cached or not stats or (not next(stats) and not GetItemInfo(link)) then
    RequestItem(link); return nil
  end
  if scoreCache[link] then return scoreCache[link] end
  local total
  if backend == "statpriority" then
    local sp = SPAddon()
    local ok, s = pcall(sp.ScoreItem, sp, link, weights, CU.spForever)
    if ok then total = s end
  else
    local stats = GetItemStats(link)
    if stats then
      total = 0
      for ledgerKey, itemKeys in pairs(CU.StatMap) do
        local w = weights[ledgerKey]
        if w then
          local scale = CU.StatScale[ledgerKey] or 1
          for _, k in ipairs(itemKeys) do
            if stats[k] then total = total + stats[k] * scale * w end
          end
        end
      end
    end
  end
  if total then scoreCache[link] = total end
  return total
end

---------------------------------------------------------------------------
-- Hit chance: tracked so hit only counts up to your cap
---------------------------------------------------------------------------
local HIT_KEYS = { "ITEM_MOD_HIT_RATING_SHORT", "ITEM_MOD_HIT_SPELL_RATING_SHORT",
                   "ITEM_MOD_HIT_MELEE_RATING_SHORT", "ITEM_MOD_HIT_RANGED_RATING_SHORT" }

local function HitRating(link)
  if not link then return 0 end
  local stats = GetItemStats(link)
  if type(stats) ~= "table" then return 0 end
  local t = 0
  for _, k in ipairs(HIT_KEYS) do if type(stats[k]) == "number" then t = t + stats[k] end end
  return t
end

local function HitWeight(weights)
  local w = 0
  for _, k in ipairs(HIT_KEYS) do if (weights[k] or 0) > w then w = weights[k] end end
  return w
end

local function Number(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, v = pcall(fn, ...)
  if not ok or type(v) ~= "number" then return nil end
  if type(issecretvalue) == "function" and issecretvalue(v) then return nil end
  return v
end

-- Returns { kind, current %, cap %, rating per 1% } or nil when hit isn't being tracked.
function CU.HitInfo()
  if not cfg or cfg.safeMode or cfg.trackHit == false then return nil end
  local _, class = UnitClass("player")
  local ht = CU.HitType and CU.HitType[class]
  local kind = ht and ((CU.specID and ht[CU.specID]) or ht.ALL)
  if not kind or kind == "none" then return nil end
  local ratingType = kind
  if kind == "melee" and cfg.dualWield then kind = "dualwield" end
  local caps = CU.IsLevelling() and CU.HitCaps.levelling or CU.HitCaps.raid
  local cr = (ratingType == "spell" and CR_HIT_SPELL) or (ratingType == "ranged" and CR_HIT_RANGED) or CR_HIT_MELEE
  -- Hit from rating on gear, plus hit from talents and other sources.
  local fromRating = cr and Number(GetCombatRatingBonus, cr) or 0
  local other = Number(ratingType == "spell" and GetSpellHitModifier or GetHitModifier) or 0
  -- Rating needed per 1%: read from your own gear if you have any, else StatPriority's level-60 value.
  local rating = cr and Number(GetCombatRating, cr)
  local sp = SPAddon()
  local rpp = (rating and rating > 0 and fromRating > 0) and (rating / fromRating)
    or (sp and sp.RatingPerPercent and sp.RatingPerPercent.hit) or 10
  return { kind = kind, current = fromRating + other, cap = caps[kind] or 8, rpp = rpp }
end

-- Score gained by swapping (oldScore, oldHit) for (newScore, newHit), counting hit only up to the cap.
local function HitAwareGain(newScore, newHit, oldScore, oldHit, weights, hit)
  local wHit = HitWeight(weights)
  if not hit or wHit == 0 or (newHit == 0 and oldHit == 0) then return newScore - oldScore, false end
  local base = (newScore - newHit * wHit) - (oldScore - oldHit * wHit)
  local before = hit.current
  local after = before + (newHit - oldHit) / hit.rpp
  local hitPart = wHit * hit.rpp * (math.min(after, hit.cap) - math.min(before, hit.cap))
  local wasted = newHit > oldHit and after > hit.cap
  return base + hitPart, wasted
end

-- equipLoc -> { group name, inventory slot(s), how to compare }
local EQUIP = {
  INVTYPE_HEAD           = { "Head",      {1} },
  INVTYPE_NECK           = { "Neck",      {2} },
  INVTYPE_SHOULDER       = { "Shoulder",  {3} },
  INVTYPE_CLOAK          = { "Back",      {15} },
  INVTYPE_CHEST          = { "Chest",     {5} },
  INVTYPE_ROBE           = { "Chest",     {5} },
  INVTYPE_WRIST          = { "Wrist",     {9} },
  INVTYPE_HAND           = { "Hands",     {10} },
  INVTYPE_WAIST          = { "Waist",     {6} },
  INVTYPE_LEGS           = { "Legs",      {7} },
  INVTYPE_FEET           = { "Feet",      {8} },
  INVTYPE_FINGER         = { "Ring",      {11, 12}, "weakest" },
  INVTYPE_TRINKET        = { "Trinket",   {13, 14}, "weakest" },
  INVTYPE_WEAPON         = { "Main Hand", {16} },
  INVTYPE_WEAPONMAINHAND = { "Main Hand", {16} },
  INVTYPE_2HWEAPON       = { "Main Hand", {16, 17}, "sum" },
  INVTYPE_WEAPONOFFHAND  = { "Off Hand",  {17} },
  INVTYPE_SHIELD         = { "Off Hand",  {17} },
  INVTYPE_HOLDABLE       = { "Off Hand",  {17} },
  INVTYPE_RANGED         = { "Ranged",    {18} },
  INVTYPE_RANGEDRIGHT    = { "Ranged",    {18} },
  INVTYPE_THROWN         = { "Ranged",    {18} },
  INVTYPE_RELIC          = { "Ranged",    {18} },
}
local GROUP_ORDER = { "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist",
                      "Legs", "Feet", "Ring", "Trinket", "Main Hand", "Off Hand", "Ranged" }

-- Returns the score and the hit rating of whatever the new item would replace.
local function EquippedScore(def, weights, newScore, newHit, hit)
  local scores, hits = {}, {}
  for i, slot in ipairs(def[2]) do
    local link = GetInventoryItemLink("player", slot)
    scores[i] = ScoreItem(link, weights)
    if scores[i] == nil then RequestItem(link); return nil end
    hits[i] = HitRating(link)
  end
  if def[3] == "weakest" then
    local w = 1
    for i = 2, #scores do
      if newScore and HitAwareGain(newScore, newHit or 0, scores[i], hits[i], weights, hit)
          > HitAwareGain(newScore, newHit or 0, scores[w], hits[w], weights, hit)
        or not newScore and scores[i] < scores[w] then w = i end
    end
    return scores[w], hits[w], { def[2][w] }
  end
  if def[3] == "sum" then
    local t, h = 0, 0
    for i = 1, #scores do t, h = t + scores[i], h + hits[i] end
    return t, h, def[2]
  end
  return scores[1], hits[1], def[2]
end

---------------------------------------------------------------------------
-- Can I use it? (level, armour type, weapon skill, class restrictions)
---------------------------------------------------------------------------
-- Armour subclass IDs: 1 cloth, 2 leather, 3 mail, 4 plate, 6 shield
local function ArmorFor(class, lvl)
  local hi = lvl >= 40
  if class == "WARRIOR" or class == "PALADIN" then
    return { [1]=true, [2]=true, [3]=true, [4]=hi, [6]=true }, hi and 4 or 3
  elseif class == "HUNTER" then
    return { [1]=true, [2]=true, [3]=hi }, hi and 3 or 2
  elseif class == "SHAMAN" then
    return { [1]=true, [2]=true, [3]=hi, [6]=true }, hi and 3 or 2
  elseif class == "ROGUE" or class == "DRUID" then
    return { [1]=true, [2]=true }, 2
  end
  return { [1]=true }, 1 -- Mage, Priest, Warlock
end

local function IsRed(c) return c and c.r and c.r > 0.9 and c.g < 0.25 and c.b < 0.25 end
local LEVEL_PATTERN = (ITEM_MIN_LEVEL or "Requires Level %d"):gsub("%%d", "%%d+")

-- The game colours anything you can't use red on the tooltip: an untrained weapon type,
-- an armour type you can't wear, "Classes: ...", profession requirements. Reading that
-- covers weapon proficiencies without hard-coding every class.
local function TooltipBlocks(link, ignoreRightText)
  if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return false end
  local data = C_TooltipInfo.GetHyperlink(link)
  if not (data and data.lines) then return false end
  for _, line in ipairs(data.lines) do
    if not ignoreRightText and line.rightText and line.rightText ~= "" and IsRed(line.rightColor) then
      return true, line.rightText
    end
    if line.leftText and IsRed(line.leftColor) and not line.leftText:find(LEVEL_PATTERN) then
      return true, line.leftText
    end
  end
  return false
end

-- Returns true/false (or nil if item info is still loading), plus required level or a reason.
function CU.SpecExtraArmor(byClass)
  return (CU.specID and byClass[CU.specID]) or byClass.ALL
end

local function CanUse(link, equipLoc, classID, subID)
  local _, _, _, _, reqLevel = GetItemInfo(link)
  if not reqLevel then return nil, "loading" end
  local level = UnitLevel("player")
  if reqLevel > level + cfg.levelLookahead then return false, "level " .. reqLevel end

  -- StatPriority's own class rules: weapon types your class can never use, mail/plate before 40.
  local sp = backend == "statpriority" and SPAddon()
  if sp and type(sp.Usability) == "function" then
    local ok, verdict, needLevel = pcall(sp.Usability, sp, classID, subID, equipLoc)
    if ok then
      if verdict == "never" then return false, "your class can't use this" end
      if verdict == "nodw" then return false, "needs dual wield" end
      if verdict == "level" and needLevel then
        if needLevel > level + cfg.levelLookahead then return false, "armour type at level " .. needLevel end
        reqLevel = math.max(reqLevel, needLevel)
      end
    end
  end

  local isArmor = classID == 4 and equipLoc ~= "INVTYPE_CLOAK" and (subID == 6 or (subID >= 1 and subID <= 4))
  if isArmor then
    local _, class = UnitClass("player")
    -- Proficiency belongs to the player, not to the item's required level.
    if (class == "WARRIOR" or class == "PALADIN") and subID == 4
      or (class == "HUNTER" or class == "SHAMAN") and subID == 3 then
      reqLevel = math.max(reqLevel, 40)
      if reqLevel > level + cfg.levelLookahead then return false, "armour type at level 40" end
    end
    local allowed, main = ArmorFor(class, math.max(level, reqLevel))
    if not allowed[subID] then return false, "can't wear this armour type" end
    if cfg.mainArmorOnly and subID ~= 6 and subID ~= main then
      local extra = CU.ExtraArmor and CU.ExtraArmor[class] and CU.SpecExtraArmor(CU.ExtraArmor[class])
      local allowed = false
      for _, t in ipairs(extra or {}) do if t == subID then allowed = true end end
      if not allowed then return false, "not your main armour type" end
    end
  end

  -- For armour you'll only be able to wear after levelling, the tooltip shows the type in red
  -- today, so skip that part of the check; the table above already covered it.
  local blocked, why = TooltipBlocks(link, isArmor and reqLevel > level)
  if blocked then return false, why end
  return true, reqLevel
end

---------------------------------------------------------------------------
-- Best-value ladder: keep only items that are a bigger upgrade than everything cheaper
---------------------------------------------------------------------------
-- `key` = what counts as "bigger": "rank" (upgrade %) for the list view, "gain" (score points) for the planner.
local function Front(items, key)
  local sorted = {}
  for i, it in ipairs(items) do sorted[i] = it end
  table.sort(sorted, function(a, b)
    if a.price == b.price then return a[key] > b[key] end
    return a.price < b.price
  end)
  local out, best = {}, -math.huge
  for _, it in ipairs(sorted) do
    if it[key] > best then
      table.insert(out, it)
      best = it[key]
    end
  end
  return out
end

-- Too long for the window? Keep the cheapest ones and always keep the biggest upgrade at the end.
local function Trim(ladder)
  if #ladder <= cfg.maxPerSlot then return ladder end
  local trimmed = {}
  for i = 1, cfg.maxPerSlot - 1 do trimmed[i] = ladder[i] end
  trimmed[cfg.maxPerSlot] = ladder[#ladder]
  return trimmed
end

---------------------------------------------------------------------------
-- Shopping planner: the set of items that gives the biggest total upgrade for your gold
---------------------------------------------------------------------------
local function GearScore(weights)
  local t = 0
  for slot = 1, 18 do
    if slot ~= 4 then
      local link = GetInventoryItemLink("player", slot)
      local score = ScoreItem(link, weights)
      if score == nil then RequestItem(link); return nil end
      t = t + score
    end -- 4 = shirt
  end
  return t
end

-- The list, planner and breakdown must all quote the same swap.  In particular an
-- equipped item can have a zero score (and an empty slot is not the same thing), so
-- never derive the displayed gain from a rank/frontier value.
local function UpgradeMetrics(it, weights)
  local old = it.oldScore or 0
  local raw = (it.score or 0) - old
  -- Recalculate from the immutable swap inputs.  `rank` is only for Front(), and
  -- must never become a displayed gain; this also makes a re-render after a hit
  -- update agree with the breakdown.
  local gain = HitAwareGain(it.score or 0, it.newHit or HitRating(it.link), old, it.oldHit or 0, weights, CU.HitInfo())
  local base = GearScore(weights)
  return gain, base and base > 0 and gain / base * 100 or 0, raw
end
CU.UpgradeMetrics = UpgradeMetrics

local function TopTwoSum(list)
  table.sort(list, function(x, y) return x > y end)
  return (list[1] or 0) + (list[2] or 0)
end

-- Turns the scan into "slot groups". Each group is a list of options, and the plan picks at most
-- ONE option per group. An option can be one item, or two (a pair of rings, main hand + off hand).
function CU:BuildPlanOptions(weights)
  local pool, hidden, groups = self.lastPool or {}, cfg.hiddenSlots, {}
  local hit = CU.HitInfo()
  local function option(items, slots, label)
    local ns, nh, os, oh, cost, seen = 0, 0, 0, 0, 0, {}
    for _, it in ipairs(items) do
      if seen[it.link] then return nil end
      seen[it.link] = true
      ns, nh, cost = ns + it.score, nh + (it.newHit or HitRating(it.link)), cost + it.price
    end
    for _, slot in ipairs(slots or {}) do
      local link = GetInventoryItemLink("player", slot)
      local score = ScoreItem(link, weights)
      if score == nil then RequestItem(link); return nil end
      os, oh = os + score, oh + HitRating(link)
    end
    local gain = HitAwareGain(ns, nh, os, oh, weights, hit)
    if gain <= 0 then return nil end
    return {cost=cost, gain=gain, slot=label, items=items, newScore=ns, newHit=nh, oldScore=os, oldHit=oh}
  end
  local function add(opts, items, slots, label)
    local o = option(items, slots, label)
    if o then table.insert(opts, o) end
  end
  local function cands(g)
    if hidden[g] then return {} end
    local out = {}
    for _, it in ipairs(pool[g] or {}) do if it.gain > 0 then table.insert(out, it) end end
    return out
  end

  for _, g in ipairs({ "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Ranged" }) do
    local opts = {}
    for _, it in ipairs(cands(g)) do
      add(opts, {it}, it.replacedSlots, g)
    end
    if #opts > 0 then table.insert(groups, opts) end
  end

  -- You wear two rings and two trinkets, so the plan may buy one or two of each.
  -- The best pair keeps whichever two of (new ones + equipped ones) score highest.
  for _, pair in ipairs({ { "Ring", 11, 12 }, { "Trinket", 13, 14 } }) do
    local g = pair[1]
    local list, opts = cands(g), {}
    for i, a in ipairs(list) do
      add(opts, {a}, {pair[2]}, g)
      add(opts, {a}, {pair[3]}, g)
      for j = i + 1, #list do
        local b = list[j]
        if b.link ~= a.link then
          add(opts, {a,b}, {pair[2],pair[3]}, g .. "s")
        end
      end
    end
    if #opts > 0 then table.insert(groups, opts) end
  end

  -- Weapons are one group: a two-hander, a main hand, an off hand, or a main hand + off hand pair.
  local mh, oh, opts = cands("Main Hand"), cands("Off Hand"), {}
  for _, a in ipairs(mh) do add(opts, {a}, a.replacedSlots, "Main Hand") end
  for _, b in ipairs(oh) do add(opts, {b}, b.replacedSlots, "Off Hand") end
  for _, a in ipairs(mh) do
    if a.equipLoc ~= "INVTYPE_2HWEAPON" then
      for _, b in ipairs(oh) do
        if b.link ~= a.link then
          add(opts, {a,b}, {16,17}, "Both hands")
        end
      end
    end
  end
  if #opts > 0 then table.insert(groups, opts) end
  return groups
end

-- Picks at most one option per group so the total gain is as high as possible without going
-- over budget. Money is counted in round steps (1c, 10c, 1s, 10s, 1g...) so there are at most
-- 5000 of them; prices round UP to the step, so it never overspends.
local function Knapsack(groups, budget)
  if budget <= 0 or #groups == 0 then return {}, 0, 0 end
  local step = 1
  while budget / step > 5000 do step = step * 10 end
  local B = math.floor(budget / step)
  local dp, picks = {}, {}
  for b = 0, B do dp[b] = 0 end
  for gi, opts in ipairs(groups) do
    local new, pick = {}, {}
    for b = 0, B do new[b] = dp[b]; pick[b] = 0 end
    for oi, o in ipairs(opts) do
      local c = math.ceil(o.cost / step)
      if c <= B then
        for b = c, B do
          local v = dp[b - c] + o.gain
          if v > new[b] then new[b] = v; pick[b] = oi end
        end
      end
    end
    dp, picks[gi] = new, pick
  end
  local b, chosen, spent = B, {}, 0
  for gi = #groups, 1, -1 do
    local oi = picks[gi][b]
    if oi > 0 then
      local o = groups[gi][oi]
      table.insert(chosen, o)
      spent = spent + o.cost
      b = b - math.ceil(o.cost / step)
    end
  end
  return chosen, dp[B], spent
end

---------------------------------------------------------------------------
-- Auction House scan
---------------------------------------------------------------------------
local scanFrame = CreateFrame("Frame")
local quietTimer
local win -- declared before the slot-search callbacks so they can update an open results window

-- One progress display for both kinds of scan: a bar with a label in the results window
-- and another on the Auction House tab. frac = 0..1, or nil to hide.
function CU.SetProgress(frac, text)
  for _, bar in pairs({ win and win.progressBar, CU.ahProgressBar }) do
    if bar then
      if frac then
        bar:SetMinMaxValues(0, 1); bar:SetValue(math.max(0.02, math.min(frac, 1)))
        if bar.label then bar.label:SetText(text or "") end
        bar:Show()
      else
        bar:Hide()
      end
    end
  end
end

local function EndFullScan(reason)
  CU.fullScanRunning = nil
  CancelTimer(quietTimer); quietTimer = nil
  CancelTimer(CU.fullScanRead); CU.fullScanRead = nil
  if CU.fullScanWatch then CU.fullScanWatch:Cancel(); CU.fullScanWatch = nil end
  pcall(scanFrame.UnregisterEvent, scanFrame, "REPLICATE_ITEM_LIST_UPDATE")
  pcall(scanFrame.UnregisterEvent, scanFrame, "AUCTION_HOUSE_CLOSED")
  CU.SetProgress(nil)
  if reason then Print(reason) end
  if CU.updateTabStatus then CU.updateTabStatus() end
end

function CU:StartScan()
  if self.slotSearch then Print("A slot search is already running.") return end
  local ah = AuctionHouseFrame
  if not (ah and ah:IsShown()) then Print("Open the Auction House first.") return end
  if not WeightsOrSay() then return end
  if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then
    Print("This client doesn't allow a full Auction House scan.") return
  end
  local left = CU.ScanCooldownLeft()
  if left > 0 then
    Print(("Blizzard probably won't allow another full scan for %d:%02d. Trying anyway..."):format(math.floor(left / 60), left % 60))
  end
  if self.fullScanRunning then Print("A full Auction House scan is already running.") return end
  if not pcall(scanFrame.RegisterEvent, scanFrame, "REPLICATE_ITEM_LIST_UPDATE") then
    Print("This client doesn't report full-scan results, so Chupgrades can't scan here.") return
  end
  local token = {}
  CU.scanPasses, CU.fullScanRunning = 0, token
  pcall(scanFrame.RegisterEvent, scanFrame, "AUCTION_HOUSE_CLOSED")
  Print("Scanning the whole Auction House. This takes up to a minute, and Blizzard only allows it about once every 15 minutes.")
  CU.SetProgress(0.05, "Full scan: waiting for the Auction House...")
  -- If Blizzard refuses the scan (the 15-minute limit) no results ever arrive: don't stay
  -- "running" forever, which would also block slot searches.
  CU.fullScanWatch = C_Timer.NewTimer(90, function()
    CU.fullScanWatch = nil
    if CU.fullScanRunning == token then
      EndFullScan("The full scan got no results back (Blizzard's 15-minute limit, most likely). Use Search slots meanwhile.")
    end
  end)
  local ok, err = pcall(C_AuctionHouse.ReplicateItems)
  if not ok then EndFullScan("Full scan stopped: " .. tostring(err)) end
end

-- Results arrive in bursts; wait until they've been quiet for 3 seconds.
scanFrame:SetScript("OnEvent", function(self, event)
  local token = CU.fullScanRunning
  if not token then return end
  if event == "AUCTION_HOUSE_CLOSED" then EndFullScan("Full scan stopped: the Auction House closed.") return end
  if quietTimer then quietTimer:Cancel() end
  quietTimer = C_Timer.NewTimer(3, function()
    if CU.fullScanRunning ~= token then return end
    self:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    local ok, err = pcall(CU.ProcessScan, CU, token)
    if not ok then EndFullScan("Full scan stopped: " .. tostring(err)) end
  end)
end)

-- Reading the scan. Blizzard's full scan often hands over listings before their item link is
-- ready. Each pass reads everything it can, asks the game to load what's missing, and tries
-- again (up to SCAN_PASSES x 2 seconds). Unresolved exact links are skipped: a plain base
-- item's stats must never be attributed to an unknown random variant's buyout.
local SCAN_PASSES = 15

function CU:ProcessScan(token)
  token = token or self.fullScanRunning
  if not token or self.fullScanRunning ~= token then return end
  local cheapest, n, notReady, fallback, bidOnly = {}, C_AuctionHouse.GetNumReplicateItems(), 0, 0, 0
  local final = (self.scanPasses or 0) >= SCAN_PASSES - 1
  local missingIDs = {}
  for i = 0, n - 1 do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
    if itemID then
      local _, _, _, equipLoc, _, classID, subID = GetItemInfoInstant(itemID)
      if not equipLoc or not classID then
        notReady = notReady + 1; missingIDs[itemID] = true
      elseif EQUIP[equipLoc] and (classID == 2 or classID == 4) then
        if not (buyout and buyout > 0) then
          bidOnly = bidOnly + 1
        else
          local link = C_AuctionHouse.GetReplicateItemLink(i)
          if not link then
            notReady = notReady + 1
            missingIDs[itemID] = true
          else
            local price = buyout / math.max(count or 1, 1)
            if not cheapest[link] or price < cheapest[link].price then
              cheapest[link] = { price = price, equipLoc = equipLoc, classID = classID, subID = subID }
            end
          end
        end
      end
    end
  end
  self.scanPasses = (self.scanPasses or 0) + 1
  CU.SetProgress(0.1 + 0.9 * self.scanPasses / SCAN_PASSES, ("Full scan: reading %d listings..."):format(n))
  if notReady > 0 and self.scanPasses < SCAN_PASSES then
    for id in pairs(missingIDs) do
      if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
    if self.scanPasses == 1 or self.scanPasses % 5 == 0 then
      Print(("Reading the scan: waiting for details on %d listings..."):format(notReady))
    end
    self.fullScanRead = C_Timer.NewTimer(2, function()
      if CU.fullScanRunning ~= token then return end
      local ok, err = pcall(CU.ProcessScan, CU, token)
      if not ok then EndFullScan("Full scan stopped: " .. tostring(err)) end
    end)
    return
  end
  self.scanPasses = 0
  EndFullScan()
  CancelTimer(self.resultsRetry); self.resultsRetry = nil
  self.partialScan = notReady > 0
  self.fullScanComplete = true
  self.lastScan, self.lastScanTime, self.retries, self.summaryShown = cheapest, time(), 0, false
  self.lastScanStats = { listings = n, unread = notReady, fallback = fallback, bidOnly = bidOnly }
  -- Keep it between /reloads and logins: a full scan is only allowed about every 15 minutes.
  cfg.savedScan = { time = self.lastScanTime, items = cheapest, full=true, partial=self.partialScan }
  local found = 0
  for _ in pairs(cheapest) do found = found + 1 end
  local extra = {}
  if fallback > 0 then table.insert(extra, fallback .. " read from the item's plain version") end
  if notReady > 0 then table.insert(extra, "|cffff8800" .. notReady .. " couldn't be read|r") end
  if bidOnly > 0 then table.insert(extra, bidOnly .. " bid-only (no buyout) skipped") end
  Print(("Scan done: %d listings, %d different pieces of gear for sale%s."):format(n, found,
    #extra > 0 and (" (" .. table.concat(extra, ", ") .. ")") or ""))
  if self.updateTabStatus then self.updateTabStatus() end
  self:BuildResults()
end

---------------------------------------------------------------------------
-- Targeted browse search.  Unlike ReplicateItems this is deliberately small:
-- browse finds the cheap item keys, then an item query supplies each exact link.
---------------------------------------------------------------------------
local slotSearchFrame = CreateFrame("Frame")

local function SlotSearchGroups(groups)
  local wanted, out = {}, {}
  for _, g in ipairs(groups or GROUP_ORDER) do
    if not wanted[g] and (groups or not cfg.hiddenSlots[g]) then
      wanted[g] = true; table.insert(out, g)
    end
  end
  return wanted, out
end

local function SlotSearchFilters(wanted)
  local filters, seen = {}, {}
  local function add(classID, subClassID)
    local k = classID .. ":" .. tostring(subClassID or "")
    if not seen[k] then seen[k] = true; table.insert(filters, { classID = classID, subClassID = subClassID }) end
  end
  local _, class = UnitClass("player")
  local armour, main = ArmorFor(class, UnitLevel("player") + cfg.levelLookahead)
  local armourSlots = { Head=true, Shoulder=true, Chest=true, Wrist=true, Hands=true, Waist=true, Legs=true, Feet=true }
  local needArmour = false
  for g in pairs(wanted) do if armourSlots[g] then needArmour = true end end
  if needArmour then
    local extra = CU.ExtraArmor and CU.ExtraArmor[class] and CU.SpecExtraArmor(CU.ExtraArmor[class]) or {}
    local extras = {}; for _, sub in ipairs(extra) do extras[sub] = true end
    for sub, allowed in pairs(armour) do
      if allowed and sub ~= 6 and (not cfg.mainArmorOnly or sub == main or extras[sub]) then add(4, sub) end
    end
  end
  if wanted.Back then add(4, 1) end
  if wanted.Neck or wanted.Ring or wanted.Trinket or wanted["Off Hand"] then add(4, 0) end
  if wanted["Off Hand"] and armour[6] then add(4, 6) end
  if wanted["Main Hand"] or wanted.Ranged or (wanted["Off Hand"] and cfg.dualWield) then add(2) end
  return filters
end

function CU:SlotSearchProgress(text)
  self.slotSearchProgress = text
  if self.slotSearchButton then self.slotSearchButton:SetText(text) end
  if self.ahSlotSearchButton then self.ahSlotSearchButton:SetText(text) end
  local done, total = text:match("Pricing (%d+)/(%d+)")
  local page = text:match("page (%d+)")
  if done then
    CU.SetProgress(0.3 + 0.7 * tonumber(done) / math.max(tonumber(total), 1), ("Looking up rolled items: %s of %s"):format(done, total))
  else
    CU.SetProgress(math.min(0.05 * tonumber(page or 1), 0.3), ("Listing gear: page %s"):format(page or 1))
  end
  if self.updateTabStatus then self.updateTabStatus() end
end

function CU:FinishSlotSearch(reason)
  local s = self.slotSearch
  if not s then return end
  self.slotSearch = nil
  if s.timer then s.timer:Cancel() end
  slotSearchFrame:UnregisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  slotSearchFrame:UnregisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
  slotSearchFrame:UnregisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
  pcall(slotSearchFrame.UnregisterEvent, slotSearchFrame, "ITEM_SEARCH_RESULTS_ADDED")
  slotSearchFrame:UnregisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  slotSearchFrame:UnregisterEvent("AUCTION_HOUSE_CLOSED")
  if self.slotSearchButton then self.slotSearchButton:Enable(); self.slotSearchButton:SetText("Search shown slots") end
  if self.ahSlotSearchButton then self.ahSlotSearchButton:Enable(); self.ahSlotSearchButton:SetText("Search slots") end
  CU.SetProgress(nil)
  self.slotSearchProgress = nil
  if reason then Print("Slot search stopped: " .. reason) else
    self.searchedGroups = self.searchedGroups or {}
    for _, g in ipairs(s.groups or {}) do self.searchedGroups[g] = true end
    local old = {}
    for link,a in pairs(self.lastScan or {}) do old[link]=a end
    for link, a in pairs(old) do
      local def = EQUIP[a.equipLoc]
      if def and s.wanted[def[1]] and not s.partial then old[link] = nil end
    end
    for link, a in pairs(s.cheapest) do old[link] = a end
    CancelTimer(self.resultsRetry); self.resultsRetry = nil
    self.partialScan = self.partialScan or s.partial or false
    self.lastScan, self.lastScanTime, self.retries, self.summaryShown = old, time(), 0, false
    cfg.savedScan = { time = self.lastScanTime, items = old, partial=self.partialScan, groups=self.searchedGroups }
    local pieces = 0; for _ in pairs(s.cheapest) do pieces = pieces + 1 end
    Print(("Slot search done: %d listings checked, %d pieces for %s."):format(s.listings, pieces, table.concat(s.groups, ", ")))
    if s.partial then Print(("Partial search: %d capped, %d timed-out and %d unread lookups. Previous listings retained; prices may be stale."):format(s.skipped or 0, s.timeouts or 0, s.unread or 0)) end
    self:BuildResults()
  end
  if self.updateTabStatus then self.updateTabStatus() end
end

local function SlotSearchLater(s, seconds, fn)
  if s.timer then s.timer:Cancel() end
  s.timer = C_Timer.NewTimer(seconds, function()
    if CU.slotSearch == s then
      local ok, err = pcall(fn)
      if not ok then CU:FinishSlotSearch(tostring(err)) end
    end
  end)
end

local function SlotSearchSend(s, fn)
  if CU.slotSearch ~= s or type(fn) ~= "function" then return end
  if type(C_AuctionHouse.IsThrottledMessageSystemReady) == "function" and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    s.throttleSince = s.throttleSince or GetTime()
    if GetTime() - s.throttleSince >= 20 then return CU:FinishSlotSearch("Auction House remained throttled; previous results kept") end
    s.waitingThrottle = fn
    SlotSearchLater(s, .5, function() local f = s.waitingThrottle; s.waitingThrottle = nil; SlotSearchSend(s, f) end)
    return
  end
  s.throttleSince, s.waitingThrottle = nil, nil
  local ok, err = pcall(fn)
  if not ok then CU:FinishSlotSearch(tostring(err)) end
end

local function SlotSearchPriceNext(s)
  if CU.slotSearch ~= s then return end
  CancelTimer(s.timer)
  s.index = s.index + 1
  if s.index > #s.needsSearch then return CU:FinishSlotSearch() end
  local row = s.needsSearch[s.index]
  s.current = row
  CU:SlotSearchProgress(("Pricing %d/%d"):format(s.index, #s.needsSearch))
  if s.index == 1 or s.index % 25 == 0 then Print(("Priced %d/%d..."):format(s.index - 1, #s.needsSearch)) end
  s.searches = s.searches + 1
  local status
  if type(C_AuctionHouse.GetItemCommodityStatus) == "function" then
    local ok, value = pcall(C_AuctionHouse.GetItemCommodityStatus, row.itemKey)
    if ok then status = value end
  end
  if status and Enum and Enum.ItemCommodityStatus and status == Enum.ItemCommodityStatus.Commodity then
    s.partial = true
    return SlotSearchPriceNext(s)
  end
  local function send()
    if C_AuctionHouse.GetItemKeyInfo and not C_AuctionHouse.GetItemKeyInfo(row.itemKey) then
      row.waitSince = row.waitSince or GetTime()
      RequestItem(row.itemKey.itemID)
      if GetTime() - row.waitSince < 8 then return SlotSearchLater(s, .5, function() SlotSearchSend(s, send) end) end
      s.partial=true; s.timeouts=(s.timeouts or 0)+1; return SlotSearchPriceNext(s)
    end
    SlotSearchLater(s, 8, function() s.partial=true; s.timeouts=(s.timeouts or 0)+1; SlotSearchPriceNext(s) end)
    C_AuctionHouse.SendSearchQuery(row.itemKey, { { sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false } }, true)
  end
  SlotSearchSend(s, send)
end

local function SlotSearchBrowseNext(s)
  s.query = s.query + 1
  if s.query > #s.queries then
    table.sort(s.candidates, function(a, b) return (a.minPrice or math.huge) < (b.minPrice or math.huge) end)
    s.needsSearch = {}
    local instant = 0
    for _, row in ipairs(s.candidates) do
      local suffix = row.itemKey.itemSuffix
      local link = select(2, GetItemInfo(row.itemKey.itemID))
      local quality = select(3, GetItemInfo(row.itemKey.itemID))
      -- White and grey items never have a random roll, so their plain link is exact too.
      local fixed = (not suffix or suffix == 0) and link and quality and quality < 2
      if fixed and row.minPrice then
        s.cheapest[link] = { price=row.minPrice, equipLoc=row.equipLoc, classID=row.classID, subID=row.subID }
        instant = instant + 1
      else
        table.insert(s.needsSearch, row)
      end
    end
    -- Look up the strongest items first: higher item level means bigger rolled stats, so real
    -- upgrades are priced before cheap low-level ones use up the lookup limit.
    table.sort(s.needsSearch, function(a, b)
      local la, lb = a.itemKey.itemLevel or 0, b.itemKey.itemLevel or 0
      if la ~= lb then return la > lb end
      return (a.minPrice or math.huge) < (b.minPrice or math.huge)
    end)
    local cap = cfg.searchCap or 200
    local skipped = math.max(0, #s.needsSearch - cap)
    if skipped > 0 then s.partial=true; s.skipped=skipped end
    while #s.needsSearch > cap do table.remove(s.needsSearch) end
    Print(("Found %d items: %d priced instantly, looking up %d rolled items%s..."):format(#s.candidates, instant, #s.needsSearch,
      skipped > 0 and ("; skipped the " .. skipped .. " lowest-level ones (/cu searchcap raises the limit)") or ""))
    s.index, s.phase = 0, "price"; return SlotSearchPriceNext(s)
  end
  s.page, s.phase = 1, "browse"; CU:SlotSearchProgress("Listing... page 1")
  SlotSearchSend(s, function()
    C_AuctionHouse.SendBrowseQuery(s.queries[s.query])
    SlotSearchLater(s, 8, function() s.partial=true; SlotSearchBrowseNext(s) end)
  end)
end

function CU:StartSlotSearch(groups)
  if self.fullScanRunning then Print("A full Auction House scan is already running.") return end
  if self.slotSearch then Print("A slot search is already running.") return end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Print("Open the Auction House first.") return end
  local weights = WeightsOrSay()
  if not weights then return end
  if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery and C_AuctionHouse.SendSearchQuery) then Print("This client doesn't allow Auction House browse searches.") return end
  local wanted, chosen = SlotSearchGroups(groups)
  if #chosen == 0 then Print("No shown slots to search.") return end
  local filters = SlotSearchFilters(wanted)
  if #filters == 0 then Print("No usable item classes for those slots.") return end
  local level = UnitLevel("player") + cfg.levelLookahead
  -- Skip gear far below your level: it fills the results with tiny upgrades. /cu floor changes it.
  local minLevel = math.max(0, UnitLevel("player") - (cfg.searchFloor or 10))
  local query = { searchString="", minLevel=minLevel, maxLevel=level, filters={}, itemClassFilters=filters,
    sorts={ { sortOrder=Enum.AuctionHouseSortOrder.Price, reverseSort=false } } }
  local s = { wanted=wanted, groups=chosen, queries={query}, query=0, page=0, candidates={}, seen={}, cheapest={}, listings=0, index=0, searches=0, weights=weights }
  self.slotSearch = s
  slotSearchFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  slotSearchFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
  slotSearchFrame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
  pcall(slotSearchFrame.RegisterEvent, slotSearchFrame, "ITEM_SEARCH_RESULTS_ADDED")
  slotSearchFrame:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  slotSearchFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
  if self.slotSearchButton then self.slotSearchButton:Disable() end
  if self.ahSlotSearchButton then self.ahSlotSearchButton:Disable() end
  Print(("Searching %s: gear for levels %d-%d..."):format(table.concat(chosen, ", "), minLevel, level))
  SlotSearchBrowseNext(s)
end

local function SlotSearchEvent(_, event, itemKey)
  local s = CU.slotSearch; if not s then return end
  if event == "AUCTION_HOUSE_CLOSED" then return CU:FinishSlotSearch("the Auction House closed") end
  if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" and s.waitingThrottle then
    local f = s.waitingThrottle; s.waitingThrottle = nil; return SlotSearchSend(s, f)
  end
  -- Only listen to the phase we're in: other addons and the AH's own browse list fire these
  -- events too, and a stray browse update while pricing used to restart the whole search.
  if (event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED") and s.phase == "browse" then
    local rows = type(C_AuctionHouse.GetBrowseResults) == "function" and C_AuctionHouse.GetBrowseResults() or {}
    s.listings = #rows -- browse results are cumulative across pages
    for _, row in ipairs(rows) do
      local key, id = row.itemKey, row.itemKey and row.itemKey.itemID
      local loc, classID, subID
      if id then _, _, _, loc, _, classID, subID = GetItemInfoInstant(id) end
      local def = loc and EQUIP[loc]
      local _, _, _, _, req = id and GetItemInfo(id)
      if not id or not loc or not classID then
        s.partial=true
        s.unreadIDs=s.unreadIDs or {}
        local unreadKey=id or tostring(row)
        if not s.unreadIDs[unreadKey] then
          s.unreadIDs[unreadKey]=true; s.unread=(s.unread or 0)+1
          RequestItem(id)
        end
      elseif key and def and s.wanted[def[1]] and (not req or req <= UnitLevel("player") + cfg.levelLookahead) then
        local k = table.concat({ tostring(id), tostring(key.itemLevel or ""), tostring(key.itemSuffix or ""),
          tostring(key.battlePetSpeciesID or ""), tostring(key.battlePetBreedQuality or ""), tostring(key.battlePetLevel or "") }, ":")
        if not s.seen[k] then s.seen[k] = true; table.insert(s.candidates, { itemKey=key, minPrice=row.minPrice, equipLoc=loc, classID=classID, subID=subID }) end
      end
    end
    if s.timer then s.timer:Cancel() end
    if type(C_AuctionHouse.HasFullBrowseResults) == "function" and not C_AuctionHouse.HasFullBrowseResults() then
      s.page = s.page + 1; CU:SlotSearchProgress("Listing... page " .. s.page)
      return SlotSearchSend(s, function()
        SlotSearchLater(s, 8, function() s.partial=true; s.timeouts=(s.timeouts or 0)+1; SlotSearchBrowseNext(s) end)
        C_AuctionHouse.RequestMoreBrowseResults()
      end)
    end
    return SlotSearchBrowseNext(s)
  end
  if (event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED") and s.phase == "price" then
    local row = s.current
    if not row or not SameKey(itemKey, row.itemKey) then return end
    if s.timer then s.timer:Cancel() end
    local n = C_AuctionHouse.GetNumItemSearchResults(row.itemKey) or 0
    for i = 1, n do
      local info = C_AuctionHouse.GetItemSearchResultInfo(row.itemKey, i)
      if info and info.itemLink and info.buyoutAmount and info.buyoutAmount > 0 then
        local old = s.cheapest[info.itemLink]
        if not old or info.buyoutAmount < old.price then s.cheapest[info.itemLink] = { price=info.buyoutAmount, equipLoc=row.equipLoc, classID=row.classID, subID=row.subID } end
      end
    end
    if C_AuctionHouse.HasFullItemSearchResults and not C_AuctionHouse.HasFullItemSearchResults(row.itemKey) then
      if not C_AuctionHouse.RequestMoreItemSearchResults then s.partial=true; return SlotSearchPriceNext(s) end
      return SlotSearchSend(s, function()
        SlotSearchLater(s, 8, function() s.partial=true; s.timeouts=(s.timeouts or 0)+1; SlotSearchPriceNext(s) end)
        C_AuctionHouse.RequestMoreItemSearchResults(row.itemKey)
      end)
    end
    return SlotSearchPriceNext(s)
  end
end
slotSearchFrame:SetScript("OnEvent", function(...)
  local ok, err = pcall(SlotSearchEvent, ...)
  if not ok then CU:FinishSlotSearch(tostring(err)) end
end)

---------------------------------------------------------------------------
-- Build and show results
---------------------------------------------------------------------------
function CU:BuildResults()
  CancelTimer(self.resultsRetry); self.resultsRetry = nil
  local weights = WeightsOrSay()
  if not weights then return end
  if not self.lastScan then Print("No scan yet: open the Auction House and click Chupgrades.") return end
  -- A replicated/full scan is a search of every equipment group.  Targeted searches
  -- mark just their requested groups in FinishSlotSearch.
  if self.fullScanComplete then
    self.searchedGroups = self.searchedGroups or {}
    for _, g in ipairs(GROUP_ORDER) do self.searchedGroups[g] = true end
  end

  local mhID  = GetInventoryItemID("player", 16)
  local mhLoc = mhID and select(4, GetItemInfoInstant(mhID))
  local groups, loading, usable, total = {}, 0, 0, 0
  for _ in pairs(self.lastScan) do total = total + 1 end

  local ohLink = GetInventoryItemLink("player", 17)
  local ohScore, ohHit = ScoreItem(ohLink, weights), HitRating(ohLink)
  local hit = CU.HitInfo()

  for link, a in pairs(self.lastScan) do
    local def = EQUIP[a.equipLoc]
    local skip = not def or
      (def[1] == "Off Hand" and mhLoc == "INVTYPE_2HWEAPON")            -- no off-hands with a two-hander
      or (a.equipLoc == "INVTYPE_WEAPONOFFHAND" and not cfg.dualWield)   -- off-hand weapons need dual wield
    if not skip then
      local ok, reqLevel = CanUse(link, a.equipLoc, a.classID, a.subID)
      if ok == nil then
        loading = loading + 1
        RequestItem(link)
      elseif ok then
        usable = usable + 1
        local new = ScoreItem(link, weights)
        if new == nil then loading = loading + 1; RequestItem(link) end
        if new then
          -- Which slot(s) to compare against. With dual wield on, a one-hander is checked
          -- against your main hand AND your off hand, and can show up under both.
          local newHit = HitRating(link)
          local oldScore, oldHit, replacedSlots = EquippedScore(def, weights, new, newHit, hit)
          local hasItem = false
          for _, slot in ipairs(def[2]) do if GetInventoryItemLink("player", slot) then hasItem = true end end
          local targets = { { def[1], oldScore, oldHit, hasItem, replacedSlots } }
          if cfg.dualWield and a.equipLoc == "INVTYPE_WEAPON" and mhLoc ~= "INVTYPE_2HWEAPON" then
            table.insert(targets, { "Off Hand", ohScore, ohHit, ohLink ~= nil, {17} })
          end
          for _, t in ipairs(targets) do
            local group, old = t[1], t[2]
            if old == nil then loading = loading + 1
            else
            local empty = old <= 0
            local gain, wasted = HitAwareGain(new, newHit, old, t[3], weights, hit)
            local pct = empty and 0 or gain / old * 100
            if gain > 0 and (empty or pct >= cfg.minUpgradePct) then
              groups[group] = groups[group] or {}
              table.insert(groups[group], {
                link = link, price = a.price, upgradePct = pct, empty = empty, group = group, oldScore = old,
                slotHasItem = t[4], oldHit = t[3], newHit = newHit, replacedSlots=t[5],
                rank = empty and (1e6 + new) or pct, reqLevel = reqLevel,
                score = new, gain = gain, equipLoc = a.equipLoc, hitWasted = wasted,
                quality = select(3, GetItemInfo(link)), setID = select(16, GetItemInfo(link)),
              })
            end
            end
          end
        end
      end
    end
  end

  -- Items the game hasn't sent details for yet: asking above starts the download, so try again shortly.
  if loading > 0 and (self.retries or 0) < 8 then
    self.retries = (self.retries or 0) + 1
    if self.retries == 1 then Print(("Waiting for details on %d items..."):format(loading)) end
    local snapshot = self.lastScan
    self.resultsRetry = C_Timer.NewTimer(2, function()
      self.resultsRetry = nil
      if self.lastScan == snapshot then self:BuildResults() end
    end)
  elseif not self.summaryShown then
    local upgrades = 0
    for _, items in pairs(groups) do upgrades = upgrades + #items end
    Print(("%d pieces of gear for sale, %d you can use, %d are upgrades for you%s."):format(
      total, usable, upgrades, loading > 0 and (" (" .. loading .. " still waiting for details: they'll be added as they arrive)") or ""))
    self.summaryShown = true
  end

  self.lastAll = groups
  -- Items still waiting for details are re-checked when the game delivers them (see the
  -- GET_ITEM_INFO_RECEIVED handler) and whenever the results are shown again.
  self.pendingLoading = loading
  self.inBuild = true
  self:Render()
  self.inBuild = false
end

-- Quality and set-piece filters. Returns the items that pass, and how many were hidden.
local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
local QUALITY_HEX   = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee" }

local function PassesFilters(it)
  if it.quality and cfg.hiddenQuality[it.quality] then return false end
  local isSet = type(it.setID) == "number" and it.setID > 0
  if cfg.setFilter == "only" and not isSet then return false end
  if cfg.setFilter == "none" and isSet then return false end
  return true
end

local function SetName(id)
  if type(id) ~= "number" or id <= 0 then return nil end
  local fn = (C_Item and C_Item.GetItemSetInfo) or GetItemSetInfo
  if not fn then return "set" end
  local ok, name = pcall(fn, id)
  return (ok and type(name) == "string" and name ~= "") and name or "set"
end
CU.SetName = SetName

-- List view: the best-value ladder per slot (look-ahead items included).
-- Planner pool: only items you can equip right now, ranked by score gained. Rings and trinkets
-- keep a second layer too, because the best PAIR can include an item the first layer drops.
function CU:BuildViews()
  local level, hiddenCount = UnitLevel("player"), 0
  local filtered, ladders, pool = {}, {}, {}
  for g, items in pairs(self.lastAll or {}) do
    local keep = {}
    for _, it in ipairs(items) do
      if PassesFilters(it) then table.insert(keep, it) else hiddenCount = hiddenCount + 1 end
    end
    filtered[g] = keep
    ladders[g] = Front(keep, "rank")
    local now = {}
    for _, it in ipairs(keep) do
      if not (it.reqLevel and it.reqLevel > level) then table.insert(now, it) end
    end
    local first = Front(now, "gain")
    pool[g] = first
    if g == "Ring" or g == "Trinket" then
      local taken, rest = {}, {}
      for _, it in ipairs(first) do taken[it] = true end
      for _, it in ipairs(now) do if not taken[it] then table.insert(rest, it) end end
      pool[g] = {}
      for _, it in ipairs(first) do table.insert(pool[g], it) end
      for _, it in ipairs(Front(rest, "gain")) do table.insert(pool[g], it) end
    end
  end
  self.lastFiltered, self.lastLadders, self.lastPool, self.hiddenByFilters = filtered, ladders, pool, hiddenCount
end

-- One line saying how items are being scored right now.
function CU.ModeLine()
  if cfg.safeMode then return "|cffff8800Safe mode: plain StatPriority scoring (type /cu safe to switch back).|r" end
  local parts = {}
  if CU.specName then table.insert(parts, CU.specName .. (CU.specChosen and " (chosen)" or " (detected)")) end
  local lvlNote = "levelling mode (Stamina counts a little)"
  if CU.IsManaCaster(select(2, UnitClass("player")), CU.specID) then
    lvlNote = "levelling mode (Stamina and mana stats count more)"
  end
  table.insert(parts, CU.IsLevelling() and lvlNote or "level-60 mode")
  local hit = CU.HitInfo()
  if hit then
    table.insert(parts, ("hit %.1f%% of %g%% cap%s"):format(hit.current, hit.cap,
      hit.current >= hit.cap and " - capped" or ""))
  end
  local age = CU.lastScanTime and math.floor((time() - CU.lastScanTime) / 60)
  if age then
    table.insert(parts, age < 1 and "prices from a scan just now"
      or age < 120 and ("prices from a scan %d min ago"):format(age)
      or ("prices from a scan %d hours ago - rescan for current prices"):format(math.floor(age / 60)))
  end
  return "|cff999999Scoring: " .. table.concat(parts, ", ") .. ".|r"
end

-- A scrolling text panel that reads top to bottom and supports clickable item links.
-- (A chat-style message frame fills from the bottom, which left short lists stuck at the
-- bottom of the window.) Use :AddMessage(line) for each line, then :Done() to show them.
local function EscapeHTML(t) return (t:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end

local function MakeTextView(parent, onClick)
  local sf = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  local html = CreateFrame("SimpleHTML", nil, sf)
  html:SetFontObject("p", GameFontHighlightSmall)
  html:SetSize(300, 10)
  sf:SetScrollChild(html)
  sf:SetScript("OnSizeChanged", function(_, width) if width and width > 50 then html:SetWidth(width - 4) end end)
  if html.SetHyperlinksEnabled then pcall(html.SetHyperlinksEnabled, html, true) end
  html:EnableMouse(true) -- needed for link clicks and hovers
  html:SetScript("OnHyperlinkEnter", function(self, link)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR"); GameTooltip:SetHyperlink(link); GameTooltip:Show()
  end)
  html:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
  if onClick then html:SetScript("OnHyperlinkClick", onClick) end
  local view = { frame = sf, html = html, lines = {} }
  function view:AddMessage(text) table.insert(self.lines, text or "") end
  function view:Clear() wipe(self.lines) end
  function view:SetPoint(...) sf:SetPoint(...) end
  function view:Show() sf:Show() end
  function view:Hide() sf:Hide() end
  function view:Done()
    local width = sf:GetWidth()
    if width and width > 50 then html:SetWidth(width - 4) end
    local parts = {}
    for _, line in ipairs(self.lines) do
      if line == "" or line == " " then
        table.insert(parts, "<br/>")
      else
        table.insert(parts, "<p>" .. EscapeHTML(line) .. "</p>")
      end
    end
    html:SetText("<html><body>" .. table.concat(parts) .. "</body></html>")
    local h = html.GetContentHeight and html:GetContentHeight()
    html:SetHeight(math.max(type(h) == "number" and h or (#self.lines * 14), 10))
    local oldScroll = sf:GetVerticalScroll() or 0
    sf:SetVerticalScroll(math.max(0, math.min(oldScroll, math.max(0, html:GetHeight() - sf:GetHeight()))))
  end
  return view
end

local function Money(copper)
  copper = math.floor(copper + 0.5)
  return GetMoneyString and GetMoneyString(copper, true) or GetCoinTextureString(copper)
end
local function MoneyInput(copper)
  return ("%dg %ds %dc"):format(math.floor(copper/10000),math.floor(copper/100)%100,copper%100)
end

-- Short "+5 AP, +3 Sta" text for the stats an item actually has, so rolled stats ("of Power",
-- "of the Monkey"...) are visible. Armour is only listed when your spec values it.
local STAT_NAMES = {
  { "ITEM_MOD_DAMAGE_PER_SECOND_SHORT", "DPS" },
  { "ITEM_MOD_STRENGTH_SHORT", "Strength" }, { "ITEM_MOD_AGILITY_SHORT", "Agility" }, { "ITEM_MOD_STAMINA_SHORT", "Stamina" },
  { "ITEM_MOD_INTELLECT_SHORT", "Intellect" }, { "ITEM_MOD_SPIRIT_SHORT", "Spirit" },
  { "ITEM_MOD_ATTACK_POWER_SHORT", "Attack Power" }, { "ITEM_MOD_RANGED_ATTACK_POWER_SHORT", "Ranged Attack Power" },
  { "ITEM_MOD_FERAL_ATTACK_POWER_SHORT", "Feral Attack Power" },
  { "ITEM_MOD_SPELL_POWER_SHORT", "Spell Power" }, { "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT", "Spell Dmg" },
  { "ITEM_MOD_SPELL_HEALING_DONE_SHORT", "Healing" },
  { "ITEM_MOD_SHADOW_DAMAGE_DONE_SHORT", "Shadow Damage" }, { "ITEM_MOD_FIRE_DAMAGE_DONE_SHORT", "Fire Damage" },
  { "ITEM_MOD_FROST_DAMAGE_DONE_SHORT", "Frost Damage" }, { "ITEM_MOD_ARCANE_DAMAGE_DONE_SHORT", "Arcane Damage" },
  { "ITEM_MOD_NATURE_DAMAGE_DONE_SHORT", "Nature Damage" }, { "ITEM_MOD_HOLY_DAMAGE_DONE_SHORT", "Holy Damage" },
  { "ITEM_MOD_HIT_RATING_SHORT", "Hit" }, { "ITEM_MOD_HIT_MELEE_RATING_SHORT", "Hit" },
  { "ITEM_MOD_HIT_RANGED_RATING_SHORT", "Hit" }, { "ITEM_MOD_HIT_SPELL_RATING_SHORT", "Hit" },
  { "ITEM_MOD_CRIT_RATING_SHORT", "Crit" }, { "ITEM_MOD_CRIT_MELEE_RATING_SHORT", "Crit" },
  { "ITEM_MOD_CRIT_RANGED_RATING_SHORT", "Crit" }, { "ITEM_MOD_CRIT_SPELL_RATING_SHORT", "Crit" },
  { "ITEM_MOD_HASTE_RATING_SHORT", "Haste" }, { "ITEM_MOD_HASTE_SPELL_RATING_SHORT", "Haste" },
  { "ITEM_MOD_POWER_REGEN0_SHORT", "MP5" }, { "ITEM_MOD_MANA_REGENERATION_SHORT", "MP5" },
  { "ITEM_MOD_EXPERTISE_RATING_SHORT", "Expertise" }, { "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT", "Defense" },
  { "ITEM_MOD_DODGE_RATING_SHORT", "Dodge" }, { "ITEM_MOD_PARRY_RATING_SHORT", "Parry" },
  { "ITEM_MOD_BLOCK_RATING_SHORT", "Block" }, { "ITEM_MOD_BLOCK_VALUE_SHORT", "Block Value" },
  { "RESISTANCE0_NAME", "Armor" },
}
local function StatSummary(link)
  local stats = link and GetItemStats(link)
  if type(stats) ~= "table" then return "" end
  local totals, order = {}, {}
  for _, pair in ipairs(STAT_NAMES) do
    local key, name = pair[1], pair[2]
    local v = stats[key]
    local armorUnwanted = key == "RESISTANCE0_NAME" and not (lastWeights and (lastWeights[key] or 0) > 0)
    if type(v) == "number" and v ~= 0 and not armorUnwanted then
      if not totals[name] then table.insert(order, name); totals[name] = 0 end
      totals[name] = totals[name] + v
    end
  end
  local parts = {}
  for _, name in ipairs(order) do
    local v = totals[name]
    table.insert(parts, name == "DPS" and ("%.1f DPS"):format(v) or ("+%d %s"):format(v, name))
  end
  return table.concat(parts, ", ")
end
CU.StatSummary = StatSummary

local GROUP_SLOTS = {
  Head = {1}, Neck = {2}, Shoulder = {3}, Back = {15}, Chest = {5}, Wrist = {9}, Hands = {10},
  Waist = {6}, Legs = {7}, Feet = {8}, Ring = {11, 12}, Trinket = {13, 14},
  ["Main Hand"] = {16}, ["Off Hand"] = {17}, Ranged = {18},
}
local function WearingText(group)
  local bits = {}
  for _, slot in ipairs(GROUP_SLOTS[group] or {}) do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local sum = StatSummary(link)
      table.insert(bits, link .. " |cff999999(" .. (sum ~= "" and sum or "no useful stats") .. ")|r")
    else
      table.insert(bits, "nothing")
    end
  end
  return table.concat(bits, "  |  ")
end

local function SearchInAuctionator(names)
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.MultiSearchExact) then Print("Auctionator isn't loaded.") return end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then Print("Open the Auction House first.") return end
  if CU.slotSearch or CU.fullScanRunning then Print("Finish or stop the current scan before searching in Auctionator.") return end
  local ok, err = pcall(api.MultiSearchExact, "Chupgrades", names)
  if not ok then Print("Auctionator search failed: " .. tostring(err)) end

end

local GetWindow -- defined further down; declared here so the breakdown code can use it

-- Choosing the spec to score for (from the results window or the Auction House tab).
-- "auto" follows StatPriority. Scans hold every piece of gear for sale whatever your spec,
-- so changing spec just re-scores the saved scan: no new scan needed.
CU.specBoxSets = {}   -- every set of spec tickboxes, so they all stay in step
function CU.RefreshSpecBoxes()
  local _, myClass = UnitClass("player")
  local chosen = cfg and cfg.specOverride and cfg.specOverride[myClass]
  for _, set in ipairs(CU.specBoxSets) do
    for id, cb in pairs(set.checks) do
      cb:SetChecked((chosen and id == chosen) or (not chosen and id == "auto"))
    end
    set.labels.auto:SetText("Auto" .. (CU.detectedSpecName and (" (" .. CU.detectedSpecName .. ")") or ""))
  end
end

function CU.ChooseSpec(id)
  local _, myClass = UnitClass("player")
  cfg.specOverride = cfg.specOverride or {}
  cfg.specOverride[myClass] = (id ~= "auto") and id or nil
  wipe(scoreCache)
  GetWeights()
  CU.RefreshSpecBoxes()
  if win and win:IsShown() and CU.lastScan then CU.retries = 0; CU:BuildResults() end
  if CU.updateTabStatus then CU.updateTabStatus() end
end

-- A row of spec tickboxes: Auto + each spec of your class. Returns the row's width.
function CU.MakeSpecRow(parent, anchorPoint, relTo, relPoint, x, y)
  local set = { checks = {}, labels = {} }
  local function Box(id, text, offset, width)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint(anchorPoint, relTo, relPoint, x + offset, y)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    label:SetText(text)
    cb:SetHitRectInsets(0, -(width - 24), 0, 0)
    cb:SetScript("OnClick", function() CU.ChooseSpec(id) end)
    set.checks[id], set.labels[id] = cb, label
  end
  Box("auto", "Auto", 0, 150)
  local offset = 150
  for _, spec in ipairs(CU.ClassSpecs()) do
    Box(spec.id, spec.name, offset, 104)
    offset = offset + 104
  end
  table.insert(CU.specBoxSets, set)
  return offset, set
end

---------------------------------------------------------------------------
-- Breakdown: how one item was scored, stat by stat
---------------------------------------------------------------------------
local RANGED_LOCS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }
local MELEE_LOCS  = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true }

-- Per stat: amount on the item and the points it scores with the weights in use.
local function Contributions(link, weights)
  local out, order = {}, {}
  local stats = link and GetItemStats(link)
  if type(stats) ~= "table" then return out, order end
  local equipLoc = select(4, GetItemInfoInstant(link))
  for _, pair in ipairs(STAT_NAMES) do
    local key, name = pair[1], pair[2]
    local v = stats[key]
    if type(v) == "number" and v ~= 0 then
      local w
      if backend == "statpriority" then
        if key == "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" then
          w = (RANGED_LOCS[equipLoc] and weights.RANGED_DPS)
            or (equipLoc == "INVTYPE_WEAPONOFFHAND" and (weights.OFFHAND_DPS or weights.MELEE_DPS))
            or (MELEE_LOCS[equipLoc] and weights.MELEE_DPS)
        else
          w = weights[key]
        end
      else
        for lk, keys in pairs(CU.StatMap) do
          for _, k in ipairs(keys) do
            if k == key and weights[lk] then w = (w or 0) + weights[lk] * (CU.StatScale[lk] or 1) end
          end
        end
      end
      if not out[name] then out[name] = { amount = 0, points = 0 }; table.insert(order, name) end
      out[name].amount = out[name].amount + v
      out[name].points = out[name].points + v * (w or 0)
    end
  end
  return out, order
end

-- The equipped item(s) a candidate would replace, matching how it was compared.
local function ReplacedLinks(it, weights)
  local def = EQUIP[it.equipLoc]
  if not def then return {} end
  local slots = it.replacedSlots or ((it.group == "Off Hand") and { 17 } or def[2])
  local links = {}
  if not it.replacedSlots and def[3] == "weakest" and it.group ~= "Off Hand" then
    local best, bestScore
    for _, slot in ipairs(slots) do
      local l = GetInventoryItemLink("player", slot)
      local sc = l and (ScoreItem(l, weights) or 0) or -1
      if not bestScore or sc < bestScore then best, bestScore = l, sc end
    end
    if best then table.insert(links, best) end
  else
    for _, slot in ipairs(slots) do
      local l = GetInventoryItemLink("player", slot)
      if l then table.insert(links, l) end
    end
  end
  return links
end

local function Signed(v, fmt) fmt = fmt or "%.0f"; return (v >= 0 and "+" or "") .. fmt:format(v) end

function CU.ShowBreakdownHelp()
  local bd = win and win.breakdown
  if not bd then return end
  bd:Clear()
  bd:AddMessage("|cffffd100Breakdown|r")
  bd:AddMessage(" ")
  bd:AddMessage("What you're wearing")
  for _, group in ipairs(GROUP_ORDER) do bd:AddMessage(("|cff999999%s:|r %s"):format(group, WearingText(group))) end
  bd:Done()
end

function CU:ShowBreakdown(it)
  self.bdLink, self.bdGroup = it.link, it.group
  local w = GetWindow()
  local bd = w.breakdown
  local weights = lastWeights
  if not weights then return end
  bd:Clear()
  local replaced = ReplacedLinks(it, weights)

  bd:AddMessage(it.link)
  bd:AddMessage(("|cff999999%s slot, %s|r"):format(it.group or "?", Money(it.price)))
  bd:AddMessage("Replaces: " .. (#replaced > 0 and table.concat(replaced, " + ") or "nothing (empty slot)"))
  bd:AddMessage(" ")

  local new, newOrder = Contributions(it.link, weights)
  local old, oldOrder = {}, {}
  for _, l in ipairs(replaced) do
    local c, o = Contributions(l, weights)
    for _, name in ipairs(o) do
      if not old[name] then old[name] = { amount = 0, points = 0 }; table.insert(oldOrder, name) end
      old[name].amount = old[name].amount + c[name].amount
      old[name].points = old[name].points + c[name].points
    end
  end
  -- Every stat on either side, in a fixed order.
  local names, seen = {}, {}
  for _, pair in ipairs(STAT_NAMES) do
    local n = pair[2]
    if not seen[n] and (new[n] or old[n]) then seen[n] = true; table.insert(names, n) end
  end

  bd:AddMessage("|cffffd100Stat: this item vs what you wear  x  worth per point  =  points|r")
  local ignored = {}
  for _, n in ipairs(names) do
    local a, b = new[n] or { amount = 0, points = 0 }, old[n] or { amount = 0, points = 0 }
    local fmt = (n == "DPS") and "%.1f" or "%.0f"
    local per = (a.amount ~= 0 and a.points / a.amount) or (b.amount ~= 0 and b.points / b.amount) or 0
    if per == 0 then
      table.insert(ignored, n)
    else
      local delta = a.points - b.points
      local colour = delta > 0.005 and "|cff00ff00" or (delta < -0.005 and "|cffff6060" or "|cffbbbbbb")
      bd:AddMessage(("%s: %s vs %s  x %.2f  =  %s%s|r"):format(n, fmt:format(a.amount), fmt:format(b.amount),
        per, colour, Signed(delta, "%.2f")))
    end
  end
  if #ignored > 0 then
    bd:AddMessage("|cff999999Not counted for your spec: " .. table.concat(ignored, ", ") .. "|r")
  end
  bd:AddMessage(" ")

  local gain, overall, raw = UpgradeMetrics(it, weights)
  local hitAdj = gain - raw
  bd:AddMessage(("This item scores |cffffffff%.2f|r, what you wear scores |cffffffff%.2f|r."):format(it.score or 0, it.oldScore or 0))
  if math.abs(hitAdj) > 0.005 then
    bd:AddMessage(("Hit cap adjustment: %s%s|r %s"):format(hitAdj < 0 and "|cffff6060" or "|cff00ff00", Signed(hitAdj, "%.2f"),
      hitAdj < 0 and "(hit past your cap, or dropping below it, isn't worth full value)" or ""))
  end
  local gearBase = GearScore(weights) or 0
  bd:AddMessage(("Gain: |cff00ff00%s points|r out of your total gear score of %.1f"):format(Signed(gain, "%.2f"), gearBase))
  bd:AddMessage(("Weighted increase: |cff00ff00%s%% overall|r  (%.2f%% per gold)"):format(Signed(overall, "%.1f"),
    overall / math.max((it.price or 0) / 10000, 1)))
  if it.reqLevel and it.reqLevel > UnitLevel("player") then
    bd:AddMessage(("|cffff8800Usable at level %d.|r"):format(it.reqLevel))
  end
  bd:AddMessage(" ")
  bd:AddMessage("|cff999999If this item \"may vary in stats\", buy the listing with exactly the stats above.|r")
  bd:AddMessage("|cff999999Alt-click the item on the left to search for it in Auctionator.|r")
  bd:Done()
end


-- Biggest upgrade first; of several items with exactly the same useful stats (e.g. five
-- "+3 Stamina" cloaks that differ only in a resistance you don't value) keep the cheapest.
local function DistinctByStats(items)
  local sorted = {}
  for i, it in ipairs(items) do sorted[i] = it end
  table.sort(sorted, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.price < b.price
  end)
  local out, seen = {}, {}
  for _, it in ipairs(sorted) do
    local key = StatSummary(it.link)
    if key == "" then key = it.link end
    if not seen[key] then seen[key] = true; table.insert(out, it) end
  end
  return out
end


function CU:Budget()
  local have = GetMoney()
  local base = cfg.budgetCopper or have
  return math.max(0, base - (cfg.reserveCopper or 0)), have
end

function CU:RenderPlan(m)
  local weights, problem = GetWeights()
  if not weights then m:AddMessage(problem) return end
  local budget, have = self:Budget()
  local base = GearScore(weights)
  if not base then m:AddMessage("Waiting for equipped item details before planning.") return end
  local groups = self:BuildPlanOptions(weights)
  m:AddMessage("|cff999999Approximate plan: hit caps are shared across slots; totals below use the combined swap. Switching a two-hander to a new main hand plus off hand is not planned.|r")

  local source = cfg.budgetCopper and ("a set budget of " .. Money(cfg.budgetCopper)) or ("your " .. Money(have))
  local keep = (cfg.reserveCopper or 0) > 0 and (", keeping " .. Money(cfg.reserveCopper) .. " back") or ""
  m:AddMessage(("|cff999999Planning with %s%s. Buy in this order: best value first, so if a listing has gone you've already got the biggest wins. Prices are from your last scan%s.|r"):format(
    source, keep, self.lastScanTime and (", " .. math.floor((time() - self.lastScanTime) / 60) .. " min ago") or ""))

  local function show(title, b, addLinks)
    m:AddMessage(" ")
    m:AddMessage(("|cffffd100%s|r  |cff999999(budget %s)|r"):format(title, Money(b)))
    local chosen, gain, spent = Knapsack(groups, b)
    local hit=CU.HitInfo()
    local function combined(options, omit)
      local ns,nh,os,oh,cost=0,0,0,0,0
      for i,o in ipairs(options) do if i~=omit then
        ns=ns+o.newScore; nh=nh+o.newHit; os=os+o.oldScore; oh=oh+o.oldHit; cost=cost+o.cost
      end end
      return HitAwareGain(ns,nh,os,oh,weights,hit),cost
    end
    -- Independent knapsack values share hit-cap room. Drop any option whose removal
    -- improves the actual combined swap, rather than recommending a net downgrade.
    while #chosen>0 do
      gain=combined(chosen)
      local remove,best=nil,gain
      for i=1,#chosen do
        local without=combined(chosen,i)
        if without>=best then remove,best=i,without end
      end
      if not remove then break end
      table.remove(chosen,remove)
    end
    -- Pick a safe purchase order using the true marginal gain at each step.
    local ordered={}
    while #chosen>0 do
      local before=combined(ordered)
      local bestIndex,bestValue,bestGain=nil,0,0
      for i,o in ipairs(chosen) do
        ordered[#ordered+1]=o
        local marginal=combined(ordered)-before
        ordered[#ordered]=nil
        local value=marginal/math.max(o.cost,1)
        if value>bestValue then bestIndex,bestValue,bestGain=i,value,marginal end
      end
      if not bestIndex then break end
      local o=table.remove(chosen,bestIndex); o.purchaseGain=bestGain; ordered[#ordered+1]=o
    end
    chosen=ordered; gain,spent=combined(chosen)
    if #chosen == 0 then
      m:AddMessage("   Nothing you can afford is an upgrade.")
      return 0
    end
    local running = 0
    for i, o in ipairs(chosen) do
      running = running + o.cost
      local links = {}
      for _, it in ipairs(o.items) do
        local sum = StatSummary(it.link)
        local setName = SetName(it.setID)
        table.insert(links, it.link .. (sum ~= "" and (" |cffbbbbbb(" .. sum .. ")|r") or "")
          .. (setName and (" |cff00ccff[Set: " .. setName .. "]|r") or ""))
        if addLinks then table.insert(self.shownLinks, it.link) end
        local data = it.link:match("|H(.-)|h")
        if data then self.lineItems[data] = it end
      end
      local pct = base > 0 and ("%+.1f%% overall"):format(o.purchaseGain / base * 100) or "upgrade"
      m:AddMessage(("   %d. |cffffffff%s|r  %s   %s   |cff00ff00%s|r   |cff999999total so far %s|r"):format(
        i, o.slot, Money(o.cost), table.concat(links, " + "), pct, Money(running)))
    end
    m:AddMessage(("   |cffffffffSpend %s for %s gear score. Left over: %s|r"):format(
      Money(spent), base > 0 and ("+%.1f%%"):format(gain / base * 100) or "a better", Money(b - spent)))
    return spent
  end

  local spent = show("Suggested plan for your budget", budget, true)
  -- A cheaper alternative, only worth showing if the full plan uses a fair chunk of the budget.
  if spent > 0 and budget >= 20000 then show("If you'd rather spend about half", math.floor(budget / 2), false) end
end



-- Compact slot-first results window.  These definitions deliberately replace the
-- original table view above; its scoring/search helpers are retained unchanged.
local function NewBackdrop(f, r, g, b, a)
  if f.SetBackdrop then pcall(f.SetBackdrop, f, { bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", edgeSize=1 }) end
  if f.SetBackdropColor then f:SetBackdropColor(r or 0, g or 0, b or 0, a or .85) end
  if f.SetBackdropBorderColor then f:SetBackdropBorderColor(.45, .38, .18, .65) end
end
local function QColour(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
  if c then return c.r, c.g, c.b, (c.hex and c.hex:gsub("^|c%x%x", "")) or QUALITY_HEX[q or 1] end
  local h = QUALITY_HEX[q or 1] or "ffffff"
  return tonumber(h:sub(1,2),16)/255, tonumber(h:sub(3,4),16)/255, tonumber(h:sub(5,6),16)/255, h
end
local function CurrentLadder(g)
  local items
  if cfg.topFive and CU.lastFiltered and CU.lastFiltered[g] then
    items = DistinctByStats(CU.lastFiltered[g]); while #items > 5 do table.remove(items) end
  elseif cfg.showAll and CU.lastFiltered and CU.lastFiltered[g] then
    items = DistinctByStats(CU.lastFiltered[g]); table.sort(items, function(a,b) return a.price < b.price end)
  else items = (CU.lastLadders or {})[g] or {} end
  return items or {}
end
local function DeltaText(it, cache)
  if it.empty then return "|cffbbbbbbnew slot|r" end
  local new = cache[it.link] or GetItemStats(it.link) or {}; cache[it.link] = new
  local old, useful = {}, false
  for _, link in ipairs(ReplacedLinks(it, lastWeights or {})) do
    local s = cache[link] or GetItemStats(link) or {}; cache[link] = s
    for k,v in pairs(s) do old[k] = (old[k] or 0) + (tonumber(v) or 0) end
  end
  local out, seen = {}, {}
  for _, pair in ipairs(STAT_NAMES) do
    local key, name = pair[1], pair[2]
    if not seen[name] and (lastWeights and (lastWeights[key] or 0) > 0) then
      seen[name], useful = true, true
      local d = (new[key] or 0) - (old[key] or 0)
      if d ~= 0 then table.insert(out, (d > 0 and "|cff00ff00+" or "|cffff6060-") .. math.abs(d) .. " " .. name .. "|r") end
    end
  end
  if #out == 0 and not useful then table.insert(out, "|cffbbbbbbnew slot|r") end
  if it.reqLevel and it.reqLevel > UnitLevel("player") then table.insert(out, "|cffff8800lvl " .. it.reqLevel .. "|r") end
  if (it.price or 0) > GetMoney() then table.insert(out, "|cffff6060can't afford|r") end
  return table.concat(out, "  ")
end

function GetWindow()
  if win and win.slotRows then return win end
  win = CreateFrame("Frame", "ChupgradesFrame", UIParent, "BasicFrameTemplateWithInset")
  CU.window = win
  win:SetSize(900, 520); win:SetPoint("CENTER")
  win:SetClampedToScreen(true)
  local function position(reset)
    local scale = math.min(1, (UIParent:GetWidth()-24)/900, (UIParent:GetHeight()-24)/520)
    win:SetScale(math.max(.25, scale)); win:ClearAllPoints()
    local p = not reset and cfg.windowPosition
    if type(p)=="table" and Finite(p.x) and Finite(p.y) and math.abs(p.x)<10000 and math.abs(p.y)<10000 then
      win:SetPoint("CENTER", UIParent, "CENTER", p.x, p.y)
    else win:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
  end
  position()
  win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton"); win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing); win:SetFrameStrata("HIGH")
  win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local x,y=self:GetCenter(); local px,py=UIParent:GetCenter(); local scale=self:GetScale()
    if x and y and px and py then cfg.windowPosition={x=x*scale-px,y=y*scale-py} end
  end)
  CU.ResetPosition = function() cfg.windowPosition=nil; position(true) end
  if win.TitleText then win.TitleText:SetText("Chupgrades") end
  tinsert(UISpecialFrames, "ChupgradesFrame")
  win.header = win:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); win.header:SetPoint("TOPLEFT",14,-30)
  win.header:SetWidth(490); win.header:SetHeight(16); win.header:SetJustifyH("LEFT")
  win.tabs = {}
  local function tab(text, n, click)
    local b=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); b:SetSize(n==1 and 108 or 82,20); b:SetPoint("TOPRIGHT", win,"TOPRIGHT", -92-(3-n)*86-(n==1 and 20 or 0), -27); b:SetText(text); b:SetScript("OnClick",click); win.tabs[n]=b
  end
  tab("Biggest upgrades",1,function() cfg.view="list"; cfg.topFive=true; cfg.showAll=false; CU:Render() end)
  tab("Best value",2,function() cfg.view="list"; cfg.topFive=false; cfg.showAll=false; CU:Render() end)
  tab("Plan",3,function() cfg.view="plan"; CU:Render() end)
  local filters=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); filters:SetSize(64,20); filters:SetPoint("TOPRIGHT",-14,-27); filters:SetText("Filters")
  local panel=CreateFrame("Frame",nil,win,"BackdropTemplate"); panel:SetSize(650,132); panel:SetPoint("TOPRIGHT",-14,-51); panel:SetFrameStrata("DIALOG"); NewBackdrop(panel,.04,.04,.04,.96); panel:Hide(); win.filterPanel=panel
  filters:SetScript("OnClick",function() panel:SetShown(not panel:IsShown()) end)
  local ql=panel:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); ql:SetPoint("TOPLEFT",10,-10); ql:SetText("Quality")
  win.qualityChecks={}; local x=10
  for q=0,4 do local cb=CreateFrame("CheckButton",nil,panel,"UICheckButtonTemplate"); cb:SetSize(20,20); cb:SetPoint("TOPLEFT",x,-28); local l=panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); l:SetPoint("LEFT",cb,"RIGHT",0,0); l:SetText(QUALITY_NAMES[q]); local r,g,b=QColour(q); l:SetTextColor(r,g,b); cb:SetScript("OnClick",function(self) cfg.hiddenQuality[q]=(not self:GetChecked()) or nil; CU:Render() end); win.qualityChecks[q]=cb; x=x+105 end
  local set=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate"); set:SetSize(122,20); set:SetPoint("TOPLEFT",10,-54); set:SetScript("OnClick",function() cfg.setFilter=({any="only",only="none",none="any"})[cfg.setFilter] or "only"; CU:Render() end); win.setButton=set
  local dw=CreateFrame("CheckButton",nil,panel,"UICheckButtonTemplate"); dw:SetSize(20,20); dw:SetPoint("TOPLEFT",142,-54); local dl=panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); dl:SetPoint("LEFT",dw,"RIGHT",0,0); dl:SetText("Dual wield"); dw:SetScript("OnClick",function(self) cfg.dualWield=self:GetChecked() and true or false; CU:BuildResults() end); win.dualWieldCheck=dw
  local every=CreateFrame("CheckButton",nil,panel,"UICheckButtonTemplate"); every:SetSize(20,20); every:SetPoint("TOPLEFT",255,-54); local el=panel:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); el:SetPoint("LEFT",every,"RIGHT",0,0); el:SetText("Show every upgrade"); every:SetScript("OnClick",function(self) cfg.showAll=self:GetChecked() and true or false; if cfg.showAll then cfg.topFive=false; cfg.view="list" end; CU:Render() end); win.showAllCheck=every
  local all=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate"); all:SetSize(38,18); all:SetPoint("TOPLEFT",440,-55); all:SetText("All"); all:SetScript("OnClick",function() wipe(cfg.hiddenSlots); CU:Render() end)
  local none=CreateFrame("Button",nil,panel,"UIPanelButtonTemplate"); none:SetSize(42,18); none:SetPoint("LEFT",all,"RIGHT",3,0); none:SetText("None"); none:SetScript("OnClick",function() for _,g in ipairs(GROUP_ORDER) do cfg.hiddenSlots[g]=true end; CU:Render() end)
  local sl=panel:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); sl:SetPoint("TOPLEFT",10,-84); sl:SetText("Spec")
  CU.MakeSpecRow(panel,"TOPLEFT",panel,"TOPLEFT",48,-80)
  local div=win:CreateTexture(nil,"ARTWORK"); div:SetColorTexture(1,1,1,.12); div:SetPoint("TOPLEFT",230,-51); div:SetPoint("BOTTOMLEFT",230,34); div:SetWidth(1)
  win.slotRows={}
  for i,g in ipairs(GROUP_ORDER) do
    local row=CreateFrame("Button",nil,win,"BackdropTemplate"); row:SetSize(210,25); row:SetPoint("TOPLEFT",12,-52-(i-1)*26); row:EnableMouse(true); NewBackdrop(row,0,0,0,0); row.cb=CreateFrame("CheckButton",nil,row,"UICheckButtonTemplate"); row.cb:SetSize(18,18); row.cb:SetPoint("LEFT",0,0); row.name=row:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); row.name:SetPoint("LEFT",row.cb,"RIGHT",0,0); row.status=row:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); row.status:SetPoint("RIGHT",-3,0); row.group=g
    row.cb:SetScript("OnClick",function(self) cfg.hiddenSlots[g]=(not self:GetChecked()) or nil; CU:Render() end)
    row:SetScript("OnClick",function(self) if self.cb:IsMouseOver() then return end; CU.selectedSlot=g; cfg.selectedSlot=g; CU:Render() end); win.slotRows[g]=row
  end
  local search=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); search:SetSize(210,22); search:SetPoint("BOTTOMLEFT",12,31); search:SetText("Search ticked slots"); search:SetScript("OnClick",function() CU:StartSlotSearch() end); win.slotSearchButton=search; CU.slotSearchButton=search
  local bar=CreateFrame("StatusBar",nil,win); bar:SetSize(210,12); bar:SetPoint("BOTTOMLEFT",12,17); bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); bar:SetStatusBarColor(.2,.8,.25); bar.label=bar:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); bar.label:SetPoint("CENTER"); bar:Hide(); win.progressBar=bar
  win.wearing=win:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); win.wearing:SetPoint("TOPLEFT",244,-57); win.wearing:SetWidth(638); win.wearing:SetJustifyH("LEFT")
  win.cards={}; for i=1,6 do
    local c=CreateFrame("Button",nil,win,"BackdropTemplate"); c:SetSize(638,46); c:SetPoint("TOPLEFT",244,-76-(i-1)*49); c:EnableMouse(true); NewBackdrop(c,.03,.03,.03,.88); c.icon=c:CreateTexture(nil,"ARTWORK"); c.icon:SetSize(32,32); c.icon:SetPoint("LEFT",6,0); c.name=c:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); c.name:SetPoint("TOPLEFT",c.icon,"TOPRIGHT",7,-4); c.name:SetWidth(400); c.delta=c:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); c.delta:SetPoint("TOPLEFT",c.name,"BOTTOMLEFT",0,-3); c.delta:SetWidth(430); c.pct=c:CreateFontString(nil,"OVERLAY","GameFontNormal"); c.pct:SetPoint("TOPRIGHT",-77,-5); c.price=c:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); c.price:SetPoint("TOPRIGHT",-77,-24); c.find=CreateFrame("Button",nil,c,"UIPanelButtonTemplate"); c.find:SetSize(42,18); c.find:SetPoint("RIGHT",-5,0); c.find:SetText("Find"); c.find:SetScript("OnClick",function(self) local n=GetItemInfo(self:GetParent().item.link); if n then SearchInAuctionator({n}) end end); c:SetScript("OnEnter",function(self) if self.item then GameTooltip:SetOwner(self,"ANCHOR_CURSOR"); GameTooltip:SetHyperlink(self.item.link); GameTooltip:AddLine("Alt-click Find • Shift-click links",.6,.6,.6); GameTooltip:Show() end end); c:SetScript("OnLeave",function() GameTooltip:Hide() end); c:SetScript("OnClick",function(self,button) if not self.item then return end; if IsAltKeyDown() then local n=GetItemInfo(self.item.link); if n then SearchInAuctionator({n}) end elseif IsShiftKeyDown() then SetItemRef(self.item.link,self.item.link,button) else CU:ShowBreakdown(self.item); win.breakdown.frame:Show(); win.breakdownClose:Show(); end end); c:Hide(); win.cards[i]=c
  end
  win.empty=win:CreateFontString(nil,"OVERLAY","GameFontDisableSmall"); win.empty:SetPoint("TOPLEFT",244,-86); win.empty:SetWidth(580); win.empty:SetJustifyH("LEFT")
  local es=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); es:SetSize(120,22); es:SetPoint("TOPLEFT",244,-114); es:SetScript("OnClick",function() if CU.selectedSlot then CU:StartSlotSearch({CU.selectedSlot}) end end); win.emptySearch=es; es:Hide()
  local bd=MakeTextView(win); bd:SetPoint("TOPLEFT",244,-372); bd:SetPoint("BOTTOMRIGHT",-16,35); win.breakdown=bd; bd:Hide()
  local close=CreateFrame("Button",nil,win,"UIPanelCloseButton"); close:SetSize(20,20); close:SetPoint("TOPRIGHT",bd.frame,"TOPRIGHT",2,2); close:SetScript("OnClick",function() bd.frame:Hide(); close:Hide() end); win.breakdownClose=close; close:Hide()
  local msg=MakeTextView(win, function(_, link, _, button)
    local it=CU.lineItems and CU.lineItems[link]
    if not it then return end
    if IsAltKeyDown() then local name=GetItemInfo(it.link); if name then SearchInAuctionator({name}) end
    elseif IsShiftKeyDown() then SetItemRef(link,it.link,button)
    elseif IsControlKeyDown and IsControlKeyDown() and DressUpItemLink then DressUpItemLink(it.link)
    else CU:ShowBreakdown(it); win.breakdown:Show(); win.breakdownClose:Show() end
  end); msg:SetPoint("TOPLEFT",244,-106); msg:SetPoint("BOTTOMRIGHT",-16,66); win.msg=msg; msg.frame:Hide()
  local breakdownLevel=(msg.frame:GetFrameLevel() or 1)+5
  bd.frame:SetFrameLevel(breakdownLevel)
  local bdBackground=CreateFrame("Frame",nil,bd.frame,"BackdropTemplate")
  bdBackground:SetAllPoints(bd.frame); bdBackground:SetFrameLevel(breakdownLevel)
  NewBackdrop(bdBackground,.03,.03,.03,1)
  close:SetFrameLevel(breakdownLevel+4)
  local allSearch=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); allSearch:SetSize(170,20); allSearch:SetPoint("BOTTOMRIGHT",-14,12); allSearch:SetText("Search all in Auctionator"); allSearch:SetScript("OnClick",function() local names,seen={},{}; for _,l in ipairs(CU.shownLinks or {}) do local n=GetItemInfo(l); if n and not seen[n] then seen[n]=true; table.insert(names,n) end end; if #names>0 then SearchInAuctionator(names) end end)
  local function moneyField(label, x, field)
    local text=win:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); text:SetPoint("TOPLEFT",x,-60); text:SetText(label)
    local box=CreateFrame("EditBox",nil,win,"InputBoxTemplate"); box:SetSize(140,20); box:SetPoint("TOPLEFT",x+68,-55); box:SetAutoFocus(false)
    local function restore() box:SetText(field=="budgetCopper" and cfg[field]==nil and "" or MoneyInput(cfg[field] or 0)) end
    box:SetScript("OnEscapePressed",function(self) restore(); self:ClearFocus() end)
    box:SetScript("OnEnterPressed",function(self)
      local input=self:GetText():match("^%s*(.-)%s*$")
      local value,err=CU.ParseMoney(input)
      if input=="" then value=field=="reserveCopper" and 0 or nil; err=nil end
      if err then Print(err); restore(); return end
      cfg[field]=value; self:ClearFocus(); CU:Render()
    end)
    return {label=text, box=box, restore=restore}
  end
  win.budgetField=moneyField("Budget",244,"budgetCopper")
  win.reserveField=moneyField("Keep",570,"reserveCopper")
  win.prevPage=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); win.prevPage:SetSize(64,20); win.prevPage:SetPoint("BOTTOMLEFT",244,39); win.prevPage:SetText("Previous")
  win.nextPage=CreateFrame("Button",nil,win,"UIPanelButtonTemplate"); win.nextPage:SetSize(64,20); win.nextPage:SetPoint("BOTTOMLEFT",470,39); win.nextPage:SetText("Next")
  win.pageLabel=win:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall"); win.pageLabel:SetPoint("BOTTOMLEFT",317,43)
  win.prevPage:SetScript("OnClick",function() CU.page=math.max(1,(CU.page or 1)-1); CU:Render() end)
  win.nextPage:SetScript("OnClick",function() CU.page=math.min(CU.pageCount or 1,(CU.page or 1)+1); CU:Render() end)
  for _,cb in pairs(win.qualityChecks) do cb:SetHitRectInsets(0,-76,0,0) end
  win.dualWieldCheck:SetHitRectInsets(0,-75,0,0); win.showAllCheck:SetHitRectInsets(0,-137,0,0)
  for _,card in ipairs(win.cards) do
    card:SetScript("OnClick",function(self,button)
      local it=self.item; if not it then return end
      if IsAltKeyDown() then local name=GetItemInfo(it.link); if name then SearchInAuctionator({name}) end
      elseif IsShiftKeyDown() then SetItemRef(it.link,it.link,button)
      elseif IsControlKeyDown and IsControlKeyDown() and DressUpItemLink then DressUpItemLink(it.link)
      else CU:ShowBreakdown(it); win.breakdown:Show(); win.breakdownClose:Show() end
    end)
  end
  return win
end

function CU:Render()
  if (self.pendingLoading or 0)>0 and not self.inBuild and self.lastScan then self.retries=99; return self:BuildResults() end
  self:BuildViews(); local w=GetWindow(); local mode=CU.ModeLine():gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r",""):gsub("Scoring: ","")
  w.header:SetText(mode .. " · level " .. (UnitLevel("player") or 0) .. " · " .. Money(GetMoney()))
  local selected=cfg.view=="plan" and 3 or (cfg.topFive and 1 or 2); for i,b in ipairs(w.tabs) do b:SetAlpha(i==selected and 1 or .55); b:SetEnabled(i~=selected) end
  for q,cb in pairs(w.qualityChecks) do cb:SetChecked(not cfg.hiddenQuality[q]) end; w.dualWieldCheck:SetChecked(cfg.dualWield); w.showAllCheck:SetChecked(cfg.showAll); w.setButton:SetText(({any="Set pieces: any",only="Set pieces: only",none="Set pieces: none"})[cfg.setFilter] or "Set pieces: any"); CU.RefreshSpecBoxes()
  local best,bestPct=nil,-math.huge; local ladders={}; for _,g in ipairs(GROUP_ORDER) do ladders[g]=CurrentLadder(g); local it=ladders[g][1]; if it then local _,p=UpgradeMetrics(it,lastWeights); if p>bestPct then best,bestPct=g,p end end end
  if not self.selectedSlot or not ladders[self.selectedSlot] then self.selectedSlot=cfg.selectedSlot or best or GROUP_ORDER[1] end
  for _,g in ipairs(GROUP_ORDER) do local r=w.slotRows[g]; r.cb:SetChecked(not cfg.hiddenSlots[g]); r.name:SetText(g); local it=CU.lastFiltered and CU.lastFiltered[g] and DistinctByStats(CU.lastFiltered[g])[1]; if it then local _,p=UpgradeMetrics(it,lastWeights); r.status:SetText("|cff00ff00+"..string.format("%.1f",p).."%|r") elseif (self.searchedGroups or {})[g] then r.status:SetText("none found") else r.status:SetText("not searched") end; if g==self.selectedSlot then NewBackdrop(r,.22,.17,.05,.8) else NewBackdrop(r,0,0,0,0) end end
  for _,c in ipairs(w.cards) do c:Hide() end; w.empty:Hide(); w.emptySearch:Hide(); w.breakdown.frame:Hide(); w.breakdownClose:Hide(); w.msg.frame:Hide(); self.shownLinks={}; self.lineItems={}
  for _,field in ipairs({w.budgetField,w.reserveField}) do
    field.label:SetShown(cfg.view=="plan"); field.box:SetShown(cfg.view=="plan")
    if not field.box:HasFocus() then field.restore() end
  end
  w.prevPage:Hide(); w.nextPage:Hide(); w.pageLabel:Hide()
  if cfg.view=="plan" then w.wearing:Hide(); w.msg:Clear(); self:RenderPlan(w.msg); w.msg:Done(); w.msg.frame:Show(); w:Show(); return end
  local g=self.selectedSlot; local items=ladders[g] or {}; w.wearing:SetText("|cffffd100Wearing|r "..WearingText(g)); local cache={}
  w.wearing:Show()
  local signature=g..":"..cfg.view..":"..tostring(cfg.topFive)..":"..tostring(cfg.showAll)..":"..cfg.setFilter
  for q=0,4 do signature=signature..tostring(cfg.hiddenQuality[q]) end
  if signature~=self.pageSignature then self.page=1; self.pageSignature=signature end
  self.pageCount=math.max(1,math.ceil(#items/6)); self.page=math.max(1,math.min(self.page or 1,self.pageCount))
  w.prevPage:SetEnabled(self.page>1); w.nextPage:SetEnabled(self.page<self.pageCount)
  w.pageLabel:SetText(("Page %d/%d · %d upgrades%s"):format(self.page,self.pageCount,#items,self.partialScan and " · partial scan" or ""))
  w.prevPage:Show(); w.nextPage:Show(); w.pageLabel:Show()
  if #items==0 then
    local hidden=#((self.lastAll or {})[g] or {})>0
    local text=hidden and ("Upgrades for "..g.." are hidden by your filters.")
      or (self.searchedGroups or {})[g] and ("No upgrades found for "..g..". Search again to check current listings.")
      or (g.." hasn't been searched yet.")
    if self.partialScan then text=text.." The last search was partial; retained prices may be stale." end
    if (self.pendingLoading or 0)>0 then text=text.." Waiting for item details." end
    w.empty:SetText(text); w.empty:Show(); w.emptySearch:SetText("Search "..g); w.emptySearch:Show()
  else
    local first=(self.page-1)*6
    for card=1,6 do
      local it=items[first+card]
      if it then
        local c=w.cards[card]; local n,_,q,_,_,_,_,_,_,icon=GetItemInfo(it.link); local _,_,_,hex=QColour(q or it.quality)
        c.item=it; c.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        c.name:SetText("|cff"..hex..(n or it.link).."|r"); c.delta:SetText(DeltaText(it,cache))
        local _,p=UpgradeMetrics(it,lastWeights); c.pct:SetText("|cff00ff00+"..string.format("%.1f",p).."%|r")
        c.price:SetText(Money(it.price or 0)); c:Show(); table.insert(self.shownLinks,it.link)
        local key=it.link:match("|H(.-)|h"); if key then self.lineItems[key]=it end
      end
    end
  end
  w:Show()
end

---------------------------------------------------------------------------
-- Button on the Auction House, events, slash commands
---------------------------------------------------------------------------
-- The Chupgrades tab along the bottom of the Auction House, next to Auctionator's tabs.
-- Uses LibAHTab (bundled with Auctionator), which adds tabs without tainting Blizzard's UI.
-- Blizzard allows one full Auction House scan about every 15 minutes (shared with Auctionator's
-- full scan). Returns seconds until the next one is allowed (0 = now), going by the last scan seen.
function CU.ScanCooldownLeft()
  local last = cfg and cfg.lastReplicateAt
  if not last then return 0 end
  local cooldown = (CU.ScanCooldown or 15 * 60)
  return math.max(0, last + cooldown - time())
end

local function CooldownText()
  local left = CU.ScanCooldownLeft()
  if left <= 0 then return "|cff00ff00A full scan is available now.|r" end
  return ("|cffff8800Next full scan available in %d:%02d|r"):format(math.floor(left / 60), left % 60)
end

local function AgoText()
  if not CU.lastScanTime then return "No scan yet." end
  local mins = math.floor((time() - CU.lastScanTime) / 60)
  return mins < 1 and "Last scan: just now." or ("Last scan: %d min ago."):format(mins)
end

local function BuildAHTab()
  if CU.ahTabMade then return "already made" end
  if not AuctionHouseFrame then return "AuctionHouseFrame doesn't exist yet" end
  local lib = LibStub and LibStub("LibAHTab-1-0", true)

  local panel = CreateFrame("Frame", nil, AuctionHouseFrame)
  panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 20, -70)
  panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -20, 40)

  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -20)
  title:SetText("Chupgrades")
  local blurb = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  blurb:SetPoint("TOP", title, "BOTTOM", 0, -16)
  blurb:SetWidth(520)
  blurb:SetText("Scans every piece of gear for sale, works out which pieces are upgrades for you, and finds the best value for your gold.")

  -- Spec to score for, chosen before (or after) scanning.
  local specTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  specTitle:SetPoint("TOP", blurb, "BOTTOM", 0, -18)
  specTitle:SetText("Score upgrades for:")
  local specs = CU.ClassSpecs()
  local rowWidth = 150 + 104 * #specs
  CU.MakeSpecRow(panel, "TOPLEFT", specTitle, "BOTTOM", -rowWidth / 2, -6)
  local specNote = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  specNote:SetPoint("TOP", specTitle, "BOTTOM", 0, -32)
  specNote:SetWidth(480)
  specNote:SetText("Scans keep every piece of gear for sale, so you can change spec any time and your last scan is re-scored instantly.")

  local scan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  scan:SetSize(220, 30)
  scan:SetPoint("TOP", specNote, "BOTTOM", 0, -16)
  scan:SetText("Scan for upgrades")
  scan:SetScript("OnClick", function() CU:StartScan() end)

  local slotSearch = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  slotSearch:SetSize(220, 26)
  slotSearch:SetPoint("TOP", scan, "BOTTOM", 0, -8)
  slotSearch:SetText("Search slots")
  slotSearch:SetScript("OnClick", function() CU:StartSlotSearch() end)
  CU.ahSlotSearchButton = slotSearch
  local ahBar = CreateFrame("StatusBar", nil, panel)
  ahBar:SetSize(300, 18)
  ahBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar"); ahBar:SetStatusBarColor(0.2, 0.8, 0.25)
  local ahBg = ahBar:CreateTexture(nil, "BACKGROUND"); ahBg:SetAllPoints(); ahBg:SetColorTexture(0, 0, 0, 0.5)
  ahBar.label = ahBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); ahBar.label:SetPoint("CENTER")
  ahBar:Hide(); CU.ahProgressBar = ahBar

  local list = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  list:SetSize(220, 26)
  list:SetPoint("TOP", slotSearch, "BOTTOM", 0, -8)
  list:SetText("Show upgrades by slot")
  list:SetScript("OnClick", function()
    if not CU.lastScan then Print("No scan yet: click Scan for upgrades first.") return end
    cfg.view = "list"; CU.retries = 0; CU:BuildResults()
  end)

  local plan = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  plan:SetSize(220, 26)
  plan:SetPoint("TOP", list, "BOTTOM", 0, -8)
  plan:SetText("Plan my purchases")
  plan:SetScript("OnClick", function()
    if not CU.lastScan then Print("No scan yet: click Scan for upgrades first.") return end
    cfg.view = "plan"; CU.retries = 0; CU:BuildResults()
  end)

  local status = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  -- The progress bar sits between the buttons and the status lines, in its own gap.
  CU.ahProgressBar:SetPoint("TOP", plan, "BOTTOM", 0, -14)
  status:SetPoint("TOP", plan, "BOTTOM", 0, -44)
  local cooldown = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  cooldown:SetPoint("TOP", status, "BOTTOM", 0, -8)
  local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOP", cooldown, "BOTTOM", 0, -6)
  note:SetWidth(460)
  note:SetText("Full scans are shared with Auctionator's full scan. /cu scan forces a try anyway.")
  CU.updateTabStatus = function()
    if not CU.detectedSpecName then GetWeights() end
    CU.RefreshSpecBoxes()
    status:SetText(CU.slotSearchProgress or AgoText())
    cooldown:SetText(CooldownText())
    local left = CU.ScanCooldownLeft()
    if left > 0 then
      scan:Disable()
      scan:SetText(("Scan in %d:%02d"):format(math.floor(left / 60), left % 60))
    else
      scan:Enable()
      scan:SetText("Scan for upgrades")
    end
    if CU.slotSearch then
      slotSearch:Disable()
    else
      slotSearch:Enable()
      slotSearch:SetText("Search slots")
    end
  end
  panel:SetScript("OnShow", CU.updateTabStatus)
  -- Tick the countdown once a second while the tab is open.
  local elapsed = 0
  panel:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + (dt or 0)
    if elapsed >= 1 then elapsed = 0; CU.updateTabStatus() end
  end)

  if lib then
    lib:CreateTab("Chupgrades", panel, "Chupgrades", "Chupgrades")
  else
    -- No LibAHTab (Auctionator missing): a plain button under the frame's bottom-right corner.
    panel:Hide()
    local b = CreateFrame("Button", nil, AuctionHouseFrame, "UIPanelButtonTemplate")
    b:SetSize(130, 22)
    b:SetPoint("TOPRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -8, -2)
    b:SetText("Chupgrades")
    b:SetScript("OnClick", function() CU:StartScan() end)
  end
  CU.ahTabMade = true
  return lib and "tab made with LibAHTab" or "LibAHTab not found, made a button under the frame instead"
end

local function MakeAHTab(verbose)
  local ok, result = pcall(BuildAHTab)
  CU.tabResult = ok and result or ("error: " .. tostring(result))
  if verbose or not ok then Print("Auction House tab: " .. CU.tabResult) end
end

local refreshTimer
local function RefreshSoon()
  if CU.slotSearch or not (CU.lastScan and win and win:IsShown()) then return end
  if refreshTimer then refreshTimer:Cancel() end
  refreshTimer = C_Timer.NewTimer(1, function() CU.retries = 0; CU:BuildResults() end)
end

local ev = CreateFrame("Frame")
-- Event names differ between game versions, and registering one the client doesn't have is an
-- error that would stop the rest of this file loading. So every registration is protected.
local function Listen(e) pcall(ev.RegisterEvent, ev, e) end
Listen("ADDON_LOADED")
Listen("PLAYER_LOGIN")
Listen("PLAYER_INTERACTION_MANAGER_FRAME_SHOW") -- modern client: the Auction House opened
Listen("AUCTION_HOUSE_SHOW")                    -- older clients
Listen("PLAYER_EQUIPMENT_CHANGED")              -- you bought and equipped something: re-rank
Listen("PLAYER_LEVEL_UP")
Listen("SKILL_LINES_CHANGED")                   -- trained a new weapon skill
Listen("PLAYER_MONEY")                          -- gold changed: the plan's budget changed
Listen("GET_ITEM_INFO_RECEIVED")                -- item details arrived: re-check items that were waiting
Listen("ITEM_DATA_LOAD_RESULT")
local function NormalizeSettings(data)
  data=type(data)=="table" and data or {}
  for k,v in pairs(CU.Defaults) do
    if type(v)=="boolean" and type(data[k])~="boolean" or data[k]==nil then data[k]=v end
  end
  local limits={minUpgradePct={0,1000000,false,2},levelLookahead={0,60,true,0},maxPerSlot={1,100,true,8},
    searchCap={1,2000,true,200},searchFloor={0,100,true,10},reserveCopper={0,MAX_MONEY,true,0}}
  for k,r in pairs(limits) do if not ValidNumber(data[k],r[1],r[2],r[3]) then data[k]=r[4] end end
  if data.budgetGold~=nil and ValidNumber(tonumber(data.budgetGold),0,MAX_MONEY/10000) then data.budgetCopper=math.floor(tonumber(data.budgetGold)*10000+.5) end
  if data.reserveGold~=nil and ValidNumber(tonumber(data.reserveGold),0,MAX_MONEY/10000) then data.reserveCopper=math.floor(tonumber(data.reserveGold)*10000+.5) end
  data.budgetGold,data.reserveGold=nil,nil
  if not ValidNumber(data.budgetCopper,0,MAX_MONEY,true) then data.budgetCopper=nil end
  if data.view~="plan" then data.view="list" end
  if data.levelling~="on" and data.levelling~="off" then data.levelling="auto" end
  if data.setFilter~="only" and data.setFilter~="none" then data.setFilter="any" end
  for _,k in ipairs({"hiddenSlots","hiddenQuality","specOverride"}) do if type(data[k])~="table" then data[k]={} end end
  local names={}; for _,g in ipairs(GROUP_ORDER) do names[g]=true end
  if not names[data.selectedSlot] then data.selectedSlot=nil end
  if not ValidNumber(data.lastReplicateAt,0,time()+60) then data.lastReplicateAt=nil end
  local saved=data.savedScan
  if type(saved)=="table" and type(saved.items)=="table" and ValidNumber(saved.time,0,time()+60) then
    local clean={}
    for link,a in pairs(saved.items) do
      if type(link)=="string" and link:match("item:%d+") and type(a)=="table" and EQUIP[a.equipLoc]
        and ValidNumber(a.price,0,MAX_MONEY) and a.price>0 and (a.classID==2 or a.classID==4)
        and ValidNumber(a.subID,0,30,true) then clean[link]=a end
    end
    saved.items=clean
  else data.savedScan=nil end
  return data
end
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == "Chupgrades" then
    ChupgradesDB = NormalizeSettings(ChupgradesDB)
    for k, v in pairs(CU.Defaults) do
      if ChupgradesDB[k] == nil then ChupgradesDB[k] = v end
    end
    if type(ChupgradesDB.hiddenSlots) ~= "table" then ChupgradesDB.hiddenSlots = {} end
    if type(ChupgradesDB.hiddenQuality) ~= "table" then ChupgradesDB.hiddenQuality = {} end
    if ChupgradesDB.setFilter ~= "only" and ChupgradesDB.setFilter ~= "none" then ChupgradesDB.setFilter = "any" end
    -- Older versions saved these in gold; they're in copper now.
    ChupgradesDB.budgetGold, ChupgradesDB.reserveGold = nil, nil
    cfg = ChupgradesDB
    -- Bring back the last scan, so results survive /reload and logging out.
    if type(cfg.savedScan) == "table" and type(cfg.savedScan.items) == "table" then
      CU.lastScan, CU.lastScanTime = cfg.savedScan.items, cfg.savedScan.time
      CU.partialScan=cfg.savedScan.partial==true
      CU.fullScanComplete=cfg.savedScan.full==true
      CU.searchedGroups=type(cfg.savedScan.groups)=="table" and cfg.savedScan.groups or {}
      CU.summaryShown = true
    end
  elseif event == "PLAYER_LOGIN" then
    Print("loaded. Open the Auction House and use the Chupgrades tab, or type /cu help.")
    local L = LedgerAddon()
    if L and L.RegisterCallback then
      -- Priority edited or spec changed: old scores are wrong now.
      L:RegisterCallback("Chupgrades", function() wipe(scoreCache); RefreshSoon() end)
    end
    -- Note the time of every full scan, whoever starts it (Auctionator's full scan counts too).
    if C_AuctionHouse and type(C_AuctionHouse.ReplicateItems) == "function" and hooksecurefunc then
      hooksecurefunc(C_AuctionHouse, "ReplicateItems", function()
        cfg.lastReplicateAt = time()
        if CU.updateTabStatus then CU.updateTabStatus() end
      end)
    end
    -- Talents changed = maybe a new spec. Not every client has every event, so ask politely.
    for _, e in ipairs({ "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED" }) do
      Listen(e)
    end
  elseif event == "AUCTION_HOUSE_SHOW" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
      and Enum and Enum.PlayerInteractionType and arg1 == Enum.PlayerInteractionType.Auctioneer) then
    CU.ahEventSeen = event
    -- Try now, then again shortly after, in case the Auction House frame is still being built.
    MakeAHTab()
    C_Timer.After(0.2, function() if not CU.ahTabMade then MakeAHTab() end end)
    C_Timer.After(1, function() if not CU.ahTabMade then MakeAHTab(true) end end)
  elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
    wipe(scoreCache)
    -- A slot search asks for thousands of items' details; it rebuilds once when it finishes.
    if not CU.slotSearch and (CU.pendingLoading or 0) > 0 and CU.lastScan and win and win:IsShown() then
      if CU.itemInfoTimer then CU.itemInfoTimer:Cancel() end
      local snapshot=CU.lastScan
      CU.itemInfoTimer = C_Timer.NewTimer(1, function()
        CU.itemInfoTimer=nil
        if CU.lastScan==snapshot then CU.retries = 99; CU:BuildResults() end
      end)
    end
  elseif event == "PLAYER_MONEY" then
    if cfg.view == "plan" and CU.lastLadders and win and win:IsShown() then CU:Render() end
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    wipe(scoreCache) -- equipped items' scores are cached by link, but cheap to recompute
    RefreshSoon()
  else
    RefreshSoon()
  end
end)

-- /cu why <item link>: walks through every check for one item and says where it drops out.
function CU.Why(text)
  local link = text and text:match("|H.-|h.-|h")
  if not link then Print("Usage: type /cu why and shift-click an item into the chat line.") return end
  local weights = WeightsOrSay()
  if not weights then return end
  local id = tonumber(link:match("item:(%d+)"))
  local name = GetItemInfo(link) or link
  local function Say(ok, msg) print("   " .. (ok and "|cff00ff00OK|r  " or "|cffff4444NO|r  ") .. msg) end
  Print("Why is " .. link .. " (not) listed?")

  -- 1. In the scan? (any version of it: "of the X" rolls are different listings)
  local versions = {}
  for l, a in pairs(CU.lastScan or {}) do
    if tonumber(l:match("item:(%d+)")) == id then table.insert(versions, { link = l, a = a }) end
  end
  if not CU.lastScan then Say(false, "No scan yet.") return end
  local age = math.floor((time() - (CU.lastScanTime or time())) / 60)
  if #versions == 0 then
    -- Is it in Blizzard's raw scan data (still in memory until /reload)?
    local raw, rawBuyout, rawLink
    local n = (C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems and C_AuctionHouse.GetNumReplicateItems()) or 0
    for i = 0, n - 1 do
      local info = { C_AuctionHouse.GetReplicateItemInfo(i) }
      if info[17] == id then raw, rawBuyout, rawLink = i, info[10], C_AuctionHouse.GetReplicateItemLink(i) break end
    end
    if raw then
      if not (rawBuyout and rawBuyout > 0) then
        Say(false, "It's in Blizzard's scan data but has no buyout price (bid only). Chupgrades only counts buyouts.")
      else
        Say(false, ("It's in Blizzard's scan data (buyout %s) but Chupgrades couldn't read it%s. This is a scan-reading bug: please report it."):format(
          Money(rawBuyout), rawLink and "" or " (no item link yet)"))
      end
    elseif n > 0 then
      Say(false, ("Not in your last scan (%d min ago), and not in Blizzard's scan data either: it was listed after the scan. Rescan when the countdown allows."):format(age))
    else
      Say(false, ("Not in your last scan (%d min ago). It may have been listed since: rescan when the countdown allows."):format(age))
    end
    local st = CU.lastScanStats
    if st and (st.unread > 0 or st.fallback > 0) then
      print(("   |cff999999That scan: %d listings, %d couldn't be read, %d read from plain versions.|r"):format(st.listings, st.unread, st.fallback))
    end
    return
  end
  table.sort(versions, function(x, y) return x.a.price < y.a.price end)
  Say(true, ("In your last scan (%d min ago): %d version%s, cheapest %s."):format(age, #versions,
    #versions == 1 and "" or "s", Money(versions[1].a.price)))

  local level = UnitLevel("player")
  for i, v in ipairs(versions) do
    if i > 3 then print("   ...and " .. (#versions - 3) .. " more versions.") break end
    local l, a = v.link, v.a
    local sum = StatSummary(l)
    print(("  |cffffd100Version %d:|r %s %s, %s"):format(i, l, sum ~= "" and ("(" .. sum .. ")") or "", Money(a.price)))
    local def = EQUIP[a.equipLoc]
    local group = def and def[1] or "?"
    -- 2. Slot shown?
    Say(not cfg.hiddenSlots[group], ("Slot: %s%s"):format(group, cfg.hiddenSlots[group] and " is unticked in the slot tickboxes" or " is ticked"))
    -- 3. Usable?
    local ok, why = CanUse(l, a.equipLoc, a.classID, a.subID)
    if ok == nil then Say(false, "The game hasn't sent this item's details yet. Try again in a moment.")
    elseif not ok then Say(false, "Can't use it: " .. tostring(why))
    else
      Say(true, "You can use it" .. ((type(why) == "number" and why > level) and (" from level " .. why) or ""))
      -- 4. Score vs what you wear
      local new = ScoreItem(l, weights) or 0
      local old, oldHit = EquippedScore(def, weights, new, HitRating(l), CU.HitInfo())
      if old==nil then Say(false,"Waiting for equipped item details; this comparison is deferred.") return end
      local gain = HitAwareGain(new, HitRating(l), old, oldHit, weights, CU.HitInfo())
      local pct = old > 0 and gain / old * 100 or (new > 0 and math.huge or 0)
      local gearBase = GearScore(weights)
      local capNote = math.abs(gain - (new - old)) > 0.005 and " after the hit-cap adjustment (hit past your cap doesn't count)" or ""
      Say(gain > 0, ("Scores %.2f vs %.2f for what you wear: %s points%s (%+.1f%% overall)."):format(new, old,
        (gain >= 0 and "+" or "") .. ("%.2f"):format(gain), capNote, gearBase and gearBase > 0 and gain / gearBase * 100 or 0))
      if gain > 0 and old > 0 then
        Say(pct >= cfg.minUpgradePct, ("Slot upgrade %.1f%%, minimum is %g%% (/cu min to change)."):format(pct, cfg.minUpgradePct))
      end
      -- 5. Filters
      local probe = { quality = select(3, GetItemInfo(l)), setID = select(16, GetItemInfo(l)) }
      local passes = PassesFilters(probe)
      Say(passes, passes and "Passes the quality / set-piece filters."
        or ("Hidden by the quality / set-piece filters (quality: %s)."):format(QUALITY_NAMES[probe.quality or -1] or "?"))
      -- 6. Plan: affordable, usable now?
      local budget = CU.Budget()
      Say(a.price <= budget, ("Price %s vs plan budget %s."):format(Money(a.price), Money(budget)))
      if type(why) == "number" and why > level then Say(false, "The Plan only buys gear you can wear right now.") end
    end
  end
  print("   |cff999999If everything says OK but it's missing from the best-value list, a cheaper item that's a bigger"
    .. " upgrade beats it: tick \"Show every upgrade\" to see all of them.|r")
end

SLASH_CHUPGRADES1 = "/cu"
SLASH_CHUPGRADES2 = "/chupgrades"
local function SlotName(want)
  want = (want or ""):lower():match("^%s*(.-)%s*$")
  if want=="" then return nil end
  local match
  for _, g in ipairs(GROUP_ORDER) do
    if g:lower()==want then return g end
    if g:lower():sub(1,#want)==want then
      if match then return nil end
      match=g
    end
  end
  return match
end
SlashCmdList.CHUPGRADES = function(msg)
  local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
  cmd = cmd:lower()
  if cmd == "why" then
    CU.Why(rest)
  elseif cmd == "tab" then
    Print("Diagnostics:")
    print("   AuctionHouseFrame exists: " .. tostring(AuctionHouseFrame ~= nil) .. ", shown: " .. tostring(AuctionHouseFrame and AuctionHouseFrame:IsShown() or false))
    print("   LibStub: " .. tostring(LibStub ~= nil) .. ", LibAHTab: " .. tostring(LibStub and LibStub("LibAHTab-1-0", true) ~= nil))
    print("   AH-open event seen: " .. tostring(CU.ahEventSeen or "no"))
    print("   last tab attempt: " .. tostring(CU.tabResult or "none"))
    MakeAHTab(true)
  elseif cmd == "scan" then
    CU:StartScan()
  elseif cmd == "stop" then
    if CU.slotSearch then CU:FinishSlotSearch("cancelled; previous results kept") end
    if CU.fullScanRunning then EndFullScan("Full scan cancelled; previous results kept.") end
  elseif cmd == "reset" then
    GetWindow(); CU.ResetPosition(); Print("Window position reset.")
  elseif cmd == "top" then
    cfg.topFive = not cfg.topFive
    if cfg.topFive then cfg.showAll = false end
    Print("Top 5 biggest upgrades per slot: " .. (cfg.topFive and "on" or "off")); CU:Render()
  elseif cmd == "searchcap" then
    local n = tonumber(rest)
    if not ValidNumber(n,1,2000,true) then Print("Usage: /cu searchcap <whole number 1-2000>") return end
    cfg.searchCap = math.floor(n); Print("Slot search looks up at most " .. cfg.searchCap .. " rolled items.")
  elseif cmd == "floor" then
    local n = tonumber(rest)
    if rest:lower() == "off" then cfg.searchFloor = 100
    elseif ValidNumber(n,0,100,true) then cfg.searchFloor = n
    else Print("Usage: /cu floor <levels below you> or /cu floor off") return end
    Print(cfg.searchFloor >= 100 and "Slot search: every level." or ("Slot search: skips gear more than %d levels below you."):format(cfg.searchFloor))
  elseif cmd == "search" then
    if rest == "" then
      CU:StartSlotSearch()
    else
      local groups, seen = {}, {}
      for word in rest:gmatch("%S+") do
        local g = SlotName(word)
        if not g then Print("Unknown slot: " .. word .. ". Slots: " .. table.concat(GROUP_ORDER, ", ")) return end
        if not seen[g] then seen[g] = true; table.insert(groups, g) end
      end
      CU:StartSlotSearch(groups)
    end
  elseif cmd == "" or cmd == "show" then
    CU.retries = 0
    CU:BuildResults()
  elseif cmd == "min" then
    local n=tonumber(rest)
    if not ValidNumber(n,0,1000000) then Print("Usage: /cu min <nonnegative percentage>") return end
    cfg.minUpgradePct = n
    Print("Minimum upgrade: " .. cfg.minUpgradePct .. "%"); RefreshSoon()
  elseif cmd == "ahead" then
    local n=tonumber(rest)
    if not ValidNumber(n,0,60,true) then Print("Usage: /cu ahead <whole number 0-60>") return end
    cfg.levelLookahead = n
    Print("Showing items usable within " .. cfg.levelLookahead .. " levels."); RefreshSoon()
  elseif cmd == "armour" or cmd == "armor" then
    cfg.mainArmorOnly = not cfg.mainArmorOnly
    Print("Main armour type only: " .. (cfg.mainArmorOnly and "on" or "off")); RefreshSoon()
  elseif cmd == "dw" or cmd == "dualwield" then
    cfg.dualWield = not cfg.dualWield
    Print("Dual wield: " .. (cfg.dualWield and "on" or "off")); RefreshSoon()
  elseif cmd == "slot" then
    local want = rest:lower()
    if want == "all" then
      wipe(cfg.hiddenSlots); Print("Showing all slots.")
    else
      local found = SlotName(want)
      if not found then Print("Unknown slot. Slots: " .. table.concat(GROUP_ORDER, ", ")) return end
      cfg.hiddenSlots[found] = not cfg.hiddenSlots[found] or nil
      Print(found .. ": " .. (cfg.hiddenSlots[found] and "hidden" or "shown"))
    end
    if CU.lastLadders and win and win:IsShown() then CU:Render() end
  elseif cmd == "sets" then
    local want = rest:lower()
    if want == "any" or want == "only" or want == "none" then cfg.setFilter = want end
    Print("Set pieces: " .. cfg.setFilter .. " (any / only / none).")
    if CU.lastAll and win and win:IsShown() then CU:Render() end
  elseif cmd == "safe" then
    cfg.safeMode = not cfg.safeMode
    wipe(scoreCache)
    Print(cfg.safeMode and "Safe mode ON: plain StatPriority scoring, no corrections, levelling or hit-cap logic."
      or "Safe mode OFF: corrections, levelling mode and hit-cap tracking are back on.")
    if CU.lastScan then CU.retries = 0; CU:BuildResults() end
  elseif cmd == "levelling" or cmd == "leveling" then
    local want = rest:lower()
    if want == "on" or want == "off" or want == "auto" then cfg.levelling = want end
    wipe(scoreCache)
    Print(("Levelling mode: %s (%s right now)."):format(cfg.levelling, CU.IsLevelling() and "on" or "off"))
    if CU.lastScan then CU.retries = 0; CU:BuildResults() end
  elseif cmd == "hit" then
    if rest:lower() == "off" or rest:lower() == "on" then
      cfg.trackHit = rest:lower() == "on"
      if CU.lastScan then CU.retries = 0; CU:BuildResults() end
    end
    WeightsOrSay()
    local h = CU.HitInfo()
    if not h then
      Print(cfg.trackHit == false and "Hit tracking is off (/cu hit on)." or "Hit isn't tracked for your spec, or safe mode is on.")
    else
      Print(("Hit (%s): %.2f%% now, cap %g%% (%s). %.1f hit rating = 1%%."):format(
        h.kind, h.current, h.cap, CU.IsLevelling() and "same-level enemies" or "raid bosses", h.rpp))
    end
  elseif cmd == "plan" or cmd == "list" then
    cfg.view = cmd
    if CU.lastScan then CU.retries = 0; CU:BuildResults() else Print("No scan yet: open the Auction House and use the Chupgrades tab.") end
  elseif cmd == "keep" then
    local value,err=CU.ParseMoney(rest)
    if rest=="" then value=0; err=nil end
    if err then Print(err) return end
    cfg.reserveCopper = value
    Print("Keeping " .. Money(cfg.reserveCopper) .. " back when planning."); if CU.lastLadders and win and win:IsShown() then CU:Render() end
  elseif cmd == "budget" then
    local value,err=CU.ParseMoney(rest)
    if rest=="" then value=nil; err=nil end
    if err then Print(err) return end
    cfg.budgetCopper = value
    Print(cfg.budgetCopper and ("Planning with a budget of " .. Money(cfg.budgetCopper) .. ".") or "Planning with the money you're carrying.")
    if CU.lastLadders and win and win:IsShown() then CU:Render() end
  elseif cmd == "weights" then
    local w = WeightsOrSay()
    if not w then return end
    Print(backend == "statpriority"
      and ("StatPriority weights for " .. tostring(CU.specName or "your spec") .. " (value of one point of each stat):")
      or "Your current StatLedger weights:")
    for k, v in pairs(w) do
      if type(v) == "number" and v ~= 0 then print(("   %s = %.2f"):format(k, v)) end
    end
  elseif cmd == "item" then
    local link = rest:match("|H.-|h.-|h")
    local w = WeightsOrSay()
    if not w then return end
    if not link then Print("Usage: /cu item <shift-click an item>") return end
    local mapped = {}
    if backend == "statpriority" then
      for k, v in pairs(w) do if v ~= 0 then mapped[k] = true end end
      if w.MELEE_DPS or w.RANGED_DPS or w.OFFHAND_DPS then mapped.ITEM_MOD_DAMAGE_PER_SECOND_SHORT = true end
    else
      for _, keys in pairs(CU.StatMap) do for _, k in ipairs(keys) do mapped[k] = true end end
    end
    Print("Stats the game reports for " .. link .. ":")
    for k, v in pairs(GetItemStats(link) or {}) do
      print(("   %s = %s%s"):format(k, tostring(v), mapped[k] and "" or "  |cffff4444(not scored)|r"))
    end
    local _, _, _, equipLoc, _, classID, subID = GetItemInfoInstant(link)
    local ok, why = CanUse(link, equipLoc, classID, subID)
    local def = EQUIP[equipLoc]
    print(("   Score: %.1f   Equipped: %s   Usable: %s (%s)"):format(
      ScoreItem(link, w) or 0, def and ((EquippedScore(def, w) and ("%.1f"):format(EquippedScore(def, w))) or "loading") or "n/a",
      tostring(ok), tostring(why)))
  else
    Print("Commands:")
    print("   /cu scan  - scan the Auction House (or click the button on the AH)")
    print("   /cu search [slot ...]  - price shown slots, or named slots such as off / head chest")
    print("   /cu top  - toggle the top 5 biggest upgrades per slot, whatever the price")
    print("   /cu searchcap <n>  - most rolled items a slot search looks up (now " .. (cfg.searchCap or 200) .. ")")
    print("   /cu floor <n|off>  - slot search skips gear more than n levels below you (now " .. ((cfg.searchFloor or 10) >= 100 and "off" or (cfg.searchFloor or 10)) .. ")")
    print("   /cu  - show the last results again")
    print("   /cu min <n>  - hide upgrades smaller than n% (now " .. cfg.minUpgradePct .. ")")
    print("   /cu ahead <n>  - include items you can use within n levels (now " .. cfg.levelLookahead .. ")")
    print("   /cu armour  - toggle main armour type only (now " .. (cfg.mainArmorOnly and "on" or "off") .. ")")
    print("   /cu dw  - toggle dual wield (now " .. (cfg.dualWield and "on" or "off") .. ")")
    print("   /cu slot <name>  - show/hide a slot, e.g. /cu slot head, /cu slot ring, /cu slot all")
    print("   /cu plan  - shopping plan for your gold;  /cu list  - back to the per-slot list")
    print("   /cu keep <amount>  - money to keep back when planning, e.g. 2g 50s (now " .. Money(cfg.reserveCopper or 0) .. ")")
    print("   /cu budget <amount>  - plan with this much, e.g. 1g 33s 38c or just 5 for 5g;  /cu budget  - back to what you carry")
    print("   /cu sets any|only|none  - set-piece filter (also a button in the window)")
    print("   /cu weights  - show the stat weights being used")
    print("   /cu hit  - your hit and cap;  /cu hit off|on  - stop/start valuing hit only up to the cap")
    print("   /cu levelling auto|on|off  - levelling mode (now " .. tostring(cfg.levelling) .. ")")
    print("   /cu safe  - toggle safe mode: plain StatPriority scoring (rollback switch)")
    print("   /cu why <link>  - why an item is or isn't listed (shift-click the item into the command)")
    print("   /cu item <link>  - debug how one item is scored")
  end
end
