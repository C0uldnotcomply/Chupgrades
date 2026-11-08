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

-- Applies Config.lua's corrections and levelling Stamina on top of StatPriority's values.
-- Works on a copy (StatPriority's own table is never changed) and reuses it while nothing
-- relevant changes, so item scores can stay cached.
local adjustedKey, adjusted
function CU.AdjustWeights(w)
  if cfg and cfg.safeMode then return w end
  local _, class = UnitClass("player")
  local spec, levelling = CU.specID, CU.IsLevelling()
  local key = tostring(w) .. ":" .. tostring(class) .. ":" .. tostring(spec) .. ":" .. tostring(levelling)
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
local function EquippedScore(def, weights)
  local scores, hits = {}, {}
  for i, slot in ipairs(def[2]) do
    local link = GetInventoryItemLink("player", slot)
    scores[i] = ScoreItem(link, weights) or 0
    hits[i] = HitRating(link)
  end
  if def[3] == "weakest" then
    local w = 1
    for i = 2, #scores do if scores[i] < scores[w] then w = i end end
    return scores[w], hits[w]
  end
  if def[3] == "sum" then
    local t, h = 0, 0
    for i = 1, #scores do t, h = t + scores[i], h + hits[i] end
    return t, h
  end
  return scores[1], hits[1]
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
    local allowed, main = ArmorFor(class, reqLevel) -- by the item's level, so look-ahead works at 39 -> 40
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
    if slot ~= 4 then t = t + (ScoreItem(GetInventoryItemLink("player", slot), weights) or 0) end -- 4 = shirt
  end
  return t
end

local function TopTwoSum(list)
  table.sort(list, function(x, y) return x > y end)
  return (list[1] or 0) + (list[2] or 0)
end

-- Turns the scan into "slot groups". Each group is a list of options, and the plan picks at most
-- ONE option per group. An option can be one item, or two (a pair of rings, main hand + off hand).
function CU:BuildPlanOptions(weights)
  local pool, hidden, groups = self.lastPool or {}, cfg.hiddenSlots, {}
  local function cands(g)
    if hidden[g] then return {} end
    local out = {}
    for _, it in ipairs(pool[g] or {}) do if it.gain > 0 then table.insert(out, it) end end
    return out
  end

  for _, g in ipairs({ "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Ranged" }) do
    local opts = {}
    for _, it in ipairs(cands(g)) do
      table.insert(opts, { cost = it.price, gain = it.gain, slot = g, items = { it } })
    end
    if #opts > 0 then table.insert(groups, opts) end
  end

  -- You wear two rings and two trinkets, so the plan may buy one or two of each.
  -- The best pair keeps whichever two of (new ones + equipped ones) score highest.
  for _, pair in ipairs({ { "Ring", 11, 12 }, { "Trinket", 13, 14 } }) do
    local g = pair[1]
    local s1 = ScoreItem(GetInventoryItemLink("player", pair[2]), weights) or 0
    local s2 = ScoreItem(GetInventoryItemLink("player", pair[3]), weights) or 0
    local list, opts = cands(g), {}
    for i, a in ipairs(list) do
      local one = TopTwoSum({ a.score, s1, s2 }) - (s1 + s2)
      if one > 0 then table.insert(opts, { cost = a.price, gain = one, slot = g, items = { a } }) end
      for j = i + 1, #list do
        local b = list[j]
        if b.link ~= a.link then
          local two = TopTwoSum({ a.score, b.score, s1, s2 }) - (s1 + s2)
          if two > one then
            table.insert(opts, { cost = a.price + b.price, gain = two, slot = g .. "s", items = { a, b } })
          end
        end
      end
    end
    if #opts > 0 then table.insert(groups, opts) end
  end

  -- Weapons are one group: a two-hander, a main hand, an off hand, or a main hand + off hand pair.
  local mh, oh, opts = cands("Main Hand"), cands("Off Hand"), {}
  for _, a in ipairs(mh) do table.insert(opts, { cost = a.price, gain = a.gain, slot = "Main Hand", items = { a } }) end
  for _, b in ipairs(oh) do table.insert(opts, { cost = b.price, gain = b.gain, slot = "Off Hand", items = { b } }) end
  for _, a in ipairs(mh) do
    if a.equipLoc ~= "INVTYPE_2HWEAPON" then
      for _, b in ipairs(oh) do
        if b.link ~= a.link then
          table.insert(opts, { cost = a.price + b.price, gain = a.gain + b.gain, slot = "Both hands", items = { a, b } })
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

function CU:StartScan()
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
  CU.scanPasses = 0
  Print("Scanning the whole Auction House. This takes up to a minute, and Blizzard only allows it about once every 15 minutes.")
  if not pcall(scanFrame.RegisterEvent, scanFrame, "REPLICATE_ITEM_LIST_UPDATE") then
    Print("This client doesn't report full-scan results, so Chupgrades can't scan here.") return
  end
  C_AuctionHouse.ReplicateItems()
end

-- Results arrive in bursts; wait until they've been quiet for 3 seconds.
scanFrame:SetScript("OnEvent", function(self)
  if quietTimer then quietTimer:Cancel() end
  quietTimer = C_Timer.NewTimer(3, function()
    self:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    CU:ProcessScan()
  end)
end)

function CU:ProcessScan()
  local cheapest, n, notReady = {}, C_AuctionHouse.GetNumReplicateItems(), 0
  for i = 0, n - 1 do
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
    if itemID and buyout and buyout > 0 then
      local _, _, _, equipLoc, _, classID, subID = GetItemInfoInstant(itemID)
      if EQUIP[equipLoc] and (classID == 2 or classID == 4) then
        local link = C_AuctionHouse.GetReplicateItemLink(i)
        if not link then notReady = notReady + 1 end
        if link then
          local price = buyout / math.max(count or 1, 1)
          if not cheapest[link] or price < cheapest[link].price then
            cheapest[link] = { price = price, equipLoc = equipLoc, classID = classID, subID = subID }
          end
        end
      end
    end
  end
  -- Some listings arrive without their full details at first. The scan data stays available,
  -- so give the game a few more seconds and read it again rather than dropping them.
  self.scanPasses = (self.scanPasses or 0) + 1
  if notReady > 0 and self.scanPasses < 6 then
    Print(("Waiting for details on %d listings..."):format(notReady))
    C_Timer.After(2, function() CU:ProcessScan() end)
    return
  end
  self.scanPasses = 0
  self.lastScan, self.lastScanTime, self.retries, self.summaryShown = cheapest, time(), 0, false
  -- Keep it between /reloads and logins: a full scan is only allowed about every 15 minutes.
  cfg.savedScan = { time = self.lastScanTime, items = cheapest }
  local found = 0
  for _ in pairs(cheapest) do found = found + 1 end
  Print(("Scan done: %d listings checked, %d different pieces of gear for sale."):format(n, found))
  if self.updateTabStatus then self.updateTabStatus() end
  self:BuildResults()
end

---------------------------------------------------------------------------
-- Build and show results
---------------------------------------------------------------------------
function CU:BuildResults()
  local weights = WeightsOrSay()
  if not weights then return end
  if not self.lastScan then Print("No scan yet: open the Auction House and click Chupgrades.") return end

  local mhID  = GetInventoryItemID("player", 16)
  local mhLoc = mhID and select(4, GetItemInfoInstant(mhID))
  local groups, loading, usable, total = {}, 0, 0, 0
  for _ in pairs(self.lastScan) do total = total + 1 end

  local ohLink = GetInventoryItemLink("player", 17)
  local ohScore, ohHit = ScoreItem(ohLink, weights) or 0, HitRating(ohLink)
  local hit = CU.HitInfo()

  for link, a in pairs(self.lastScan) do
    local def = EQUIP[a.equipLoc]
    local skip =
      (def[1] == "Off Hand" and mhLoc == "INVTYPE_2HWEAPON")            -- no off-hands with a two-hander
      or (a.equipLoc == "INVTYPE_WEAPONOFFHAND" and not cfg.dualWield)   -- off-hand weapons need dual wield
    if not skip then
      local ok, reqLevel = CanUse(link, a.equipLoc, a.classID, a.subID)
      if ok == nil then
        loading = loading + 1
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, link) end
      elseif ok then
        usable = usable + 1
        local new = ScoreItem(link, weights)
        if new == nil then loading = loading + 1 end
        if new then
          -- Which slot(s) to compare against. With dual wield on, a one-hander is checked
          -- against your main hand AND your off hand, and can show up under both.
          local oldScore, oldHit = EquippedScore(def, weights)
          local targets = { { def[1], oldScore, oldHit } }
          local newHit = HitRating(link)
          if cfg.dualWield and a.equipLoc == "INVTYPE_WEAPON" and mhLoc ~= "INVTYPE_2HWEAPON" then
            table.insert(targets, { "Off Hand", ohScore, ohHit })
          end
          for _, t in ipairs(targets) do
            local group, old = t[1], t[2]
            local empty = old <= 0
            local gain, wasted = HitAwareGain(new, newHit, old, t[3], weights, hit)
            local pct = empty and 0 or gain / old * 100
            if (empty and new > 0) or pct >= cfg.minUpgradePct then
              groups[group] = groups[group] or {}
              table.insert(groups[group], {
                link = link, price = a.price, upgradePct = pct, empty = empty, group = group, oldScore = old,
                rank = empty and (1e6 + new) or pct, reqLevel = reqLevel,
                score = new, gain = empty and new or gain, equipLoc = a.equipLoc, hitWasted = wasted,
                quality = select(3, GetItemInfo(link)), setID = select(16, GetItemInfo(link)),
              })
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
    C_Timer.After(2, function() CU:BuildResults() end)
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
  table.insert(parts, CU.IsLevelling() and "levelling mode (Stamina counts a little)" or "level-60 mode")
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
    sf:SetVerticalScroll(0)
  end
  return view
end

local function Money(copper)
  copper = math.floor(copper + 0.5)
  return GetMoneyString and GetMoneyString(copper, true) or GetCoinTextureString(copper)
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
      table.insert(bits, sum ~= "" and sum or "no useful stats")
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
  api.MultiSearchExact("Chupgrades", names)

end

local win, GetWindow -- defined further down; declared here so the breakdown code can use them

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
  local slots = (it.group == "Off Hand") and { 17 } or def[2]
  local links = {}
  if def[3] == "weakest" and it.group ~= "Off Hand" then
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
  bd:AddMessage("Click an item on the left to see how it was scored: each stat, what it's worth to you, and the weighted % increase.")
  bd:AddMessage(" ")
  bd:AddMessage("|cffff8800Items that \"may vary in stats\"|r (names like \"...of Power\") come in versions with different stats."
    .. " The Auction House search row only shows the plain version. Buy the listing whose stats match the ones shown here.")
  bd:Done()
end

function CU:ShowBreakdown(it)
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

  local raw = (it.score or 0) - (it.oldScore or 0)
  local hitAdj = (it.gain or raw) - raw
  bd:AddMessage(("This item scores |cffffffff%.2f|r, what you wear scores |cffffffff%.2f|r."):format(it.score or 0, it.oldScore or 0))
  if math.abs(hitAdj) > 0.005 then
    bd:AddMessage(("Hit cap adjustment: %s%s|r %s"):format(hitAdj < 0 and "|cffff6060" or "|cff00ff00", Signed(hitAdj, "%.2f"),
      hitAdj < 0 and "(hit past your cap, or dropping below it, isn't worth full value)" or ""))
  end
  local gearBase = GearScore(weights)
  local overall = gearBase > 0 and ((it.gain or raw) / gearBase * 100) or 0
  bd:AddMessage(("Gain: |cff00ff00%s points|r out of your total gear score of %.1f"):format(Signed(it.gain or raw, "%.2f"), gearBase))
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

function GetWindow()
  if win then return win end
  win = CreateFrame("Frame", "ChupgradesFrame", UIParent, "BasicFrameTemplateWithInset")
  win:SetSize(990, 440)
  win:SetPoint("CENTER")
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", win.StopMovingOrSizing)
  win:SetFrameStrata("HIGH")
  if win.TitleText then win.TitleText:SetText("Chupgrades") end
  tinsert(UISpecialFrames, "ChupgradesFrame") -- Escape closes it

  -- Slot filter: a tickbox per slot. Ticked = shown. Shift-click a slot to show ONLY that slot.
  win.filterButtons, win.filterLabels = {}, {}
  local colW, rowH, x0, y0 = 76, 22, 14, -30
  for i, g in ipairs(GROUP_ORDER) do
    local row, col = math.floor((i - 1) / 8), (i - 1) % 8
    local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", x0 + col * colW, y0 - row * rowH)
    local label = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    label:SetText(g)
    cb:SetHitRectInsets(0, -(colW - 24), 0, 0) -- clicking the name toggles it too
    cb:SetScript("OnClick", function(self)
      if IsShiftKeyDown() then
        for _, other in ipairs(GROUP_ORDER) do cfg.hiddenSlots[other] = true end
        cfg.hiddenSlots[g] = nil
      else
        cfg.hiddenSlots[g] = (not self:GetChecked()) or nil
      end
      CU:Render()
    end)
    win.filterButtons[g], win.filterLabels[g] = cb, label
  end
  -- Third row: item quality tickboxes and the set-piece filter.
  local qLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  qLabel:SetPoint("TOPLEFT", x0 + 2, y0 - 2 * rowH - 6)
  qLabel:SetText("Quality:")
  win.qualityChecks = {}
  local qx = x0 + 52
  for q = 0, 4 do
    local cb = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("TOPLEFT", qx, y0 - 2 * rowH - 2)
    local label = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 1, 0)
    label:SetText("|cff" .. QUALITY_HEX[q] .. QUALITY_NAMES[q] .. "|r")
    cb:SetHitRectInsets(0, -62, 0, 0)
    cb:SetScript("OnClick", function(self)
      cfg.hiddenQuality[q] = (not self:GetChecked()) or nil
      CU:Render()
    end)
    win.qualityChecks[q] = cb
    qx = qx + 86 -- wide enough for "Uncommon"
  end
  local setBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  setBtn:SetSize(120, 20)
  setBtn:SetPoint("TOPLEFT", qx + 4, y0 - 2 * rowH - 2)
  setBtn:SetNormalFontObject(GameFontHighlightSmall)
  setBtn:SetHighlightFontObject(GameFontHighlightSmall)
  setBtn:SetScript("OnClick", function()
    cfg.setFilter = ({ any = "only", only = "none", none = "any" })[cfg.setFilter] or "only"
    CU:Render()
  end)
  win.setButton = setBtn

  -- Fourth row: which spec to score for. "Auto" follows StatPriority's detected spec.
  local sLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sLabel:SetPoint("TOPLEFT", x0 + 2, y0 - 3 * rowH - 6)
  sLabel:SetText("Spec:")
  CU.MakeSpecRow(win, "TOPLEFT", win, "TOPLEFT", x0 + 52, y0 - 3 * rowH - 2)

  -- Last spot on the second row: All / None.
  local function SmallButton(text, x, onClick)
    local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    b:SetSize(36, 18)
    b:SetPoint("TOPLEFT", x, y0 - rowH - 1)
    b:SetText(text)
    b:SetNormalFontObject(GameFontHighlightSmall)
    b:SetHighlightFontObject(GameFontHighlightSmall)
    b:SetScript("OnClick", onClick)
    return b
  end
  SmallButton("All", x0 + 7 * colW, function() wipe(cfg.hiddenSlots); CU:Render() end)
  SmallButton("None", x0 + 7 * colW + 38, function()
    for _, g in ipairs(GROUP_ORDER) do cfg.hiddenSlots[g] = true end
    CU:Render()
  end)

  -- Dual wield toggle.
  local dw = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
  dw:SetSize(24, 24)
  dw:SetPoint("BOTTOMLEFT", 10, 8)
  local dwLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  dwLabel:SetPoint("LEFT", dw, "RIGHT", 2, 0)
  dwLabel:SetText("Dual wield")
  dw:SetScript("OnClick", function(self)
    cfg.dualWield = self:GetChecked() and true or false
    CU.retries = 0
    CU:BuildResults()
  end)
  win.dualWieldCheck = dw

  local all = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
  all:SetSize(24, 24)
  all:SetPoint("BOTTOMLEFT", 10, 40)
  local allLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  allLabel:SetPoint("LEFT", all, "RIGHT", 2, 0)
  allLabel:SetText("Show every upgrade, not just the best value")
  all:SetScript("OnClick", function(self)
    cfg.showAll = self:GetChecked() and true or false
    CU:Render()
  end)
  win.showAllParts = { all, allLabel }
  win.showAllCheck = all

  -- Switch between the per-slot list and the shopping plan.
  local view = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  view:SetSize(150, 22)
  view:SetPoint("BOTTOMLEFT", 130, 10)
  view:SetScript("OnClick", function()
    cfg.view = (cfg.view == "plan") and "list" or "plan"
    CU:Render()
  end)
  win.viewButton = view

  -- Plan view: gold / silver / copper boxes for the budget and for money to keep back.
  -- Type the amounts, press Enter or Tab (or click away). Escape puts back what was there.
  local COIN = {
    "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
    "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
    "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
  }
  local function MoneyBoxes(labelText, x, get, set)
    local parts, boxes = {}, {}
    local label = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", x, 48)
    label:SetText(labelText)
    table.insert(parts, label)
    local anchor, gap = label, 10
    local function read()
      local any, total = false, 0
      for i, b in ipairs(boxes) do
        local n = tonumber((b:GetText() or ""):match("%d+"))
        if n then any = true; total = total + n * ({ 10000, 100, 1 })[i] end
      end
      return any and total or nil
    end
    local function refresh()
      for _, b in ipairs(boxes) do if b:HasFocus() then return end end
      local v = get()
      local values = v and { math.floor(v / 10000), math.floor(v / 100) % 100, v % 100 } or { "", "", "" }
      for i, b in ipairs(boxes) do b:SetText(tostring(values[i])) end
    end
    for i = 1, 3 do
      local box = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
      box:SetSize(i == 1 and 40 or 26, 20)
      box:SetPoint("LEFT", anchor, "RIGHT", gap, 0)
      box:SetAutoFocus(false)
      box:SetNumeric(true)
      box:SetMaxLetters(i == 1 and 6 or 2)
      local coin = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      coin:SetPoint("LEFT", box, "RIGHT", 1, 0)
      coin:SetText(COIN[i])
      box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
      box:SetScript("OnTabPressed", function(self)
        local nextBox = boxes[i % 3 + 1]
        self:ClearFocus(); nextBox:SetFocus(); nextBox:HighlightText()
      end)
      box:SetScript("OnEditFocusLost", function()
        C_Timer.After(0, function() -- after focus has moved, in case it moved to a sibling box
          for _, b in ipairs(boxes) do if b:HasFocus() then return end end
          set(read()); CU:Render()
        end)
      end)
      box:SetScript("OnEscapePressed", function(self)
        for _, b in ipairs(boxes) do b:ClearFocus() end
        refresh()
      end)
      table.insert(boxes, box); table.insert(parts, box); table.insert(parts, coin)
      anchor, gap = coin, 6
    end
    return { parts = parts, refresh = refresh, read = read, boxes = boxes }
  end
  win.budgetBox = MoneyBoxes("Budget:", 16,
    function() return cfg.budgetCopper end,
    function(v) cfg.budgetCopper = (v and v > 0) and v or nil end)
  win.keepBox = MoneyBoxes("Keep back:", 372,
    function() return (cfg.reserveCopper or 0) > 0 and cfg.reserveCopper or nil end,
    function(v) cfg.reserveCopper = v or 0 end)
  local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 238, 52)
  hint:SetText("empty = all you carry")
  table.insert(win.budgetBox.parts, hint)

  local msg = MakeTextView(win, function(_, link, text, button)
    if IsAltKeyDown() then
      local name = GetItemInfo(link)
      if name then SearchInAuctionator({ name }) end
    elseif IsShiftKeyDown() or IsControlKeyDown() then
      SetItemRef(link, text, button) -- shift-click to link it in chat, ctrl-click to preview
    else
      local it = CU.lineItems and CU.lineItems[link]
      if it then CU:ShowBreakdown(it) end
    end
  end)
  msg:SetPoint("TOPLEFT", 14, -124)
  msg:SetPoint("BOTTOMRIGHT", win, "BOTTOMLEFT", 600, 40)
  win.msg = msg

  -- Breakdown column: how the clicked item was scored.
  local divider = win:CreateTexture(nil, "ARTWORK")
  divider:SetColorTexture(1, 1, 1, 0.12)
  divider:SetPoint("TOPLEFT", win, "TOPLEFT", 636, -32)
  divider:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 636, 40)
  divider:SetWidth(1)
  local bd = MakeTextView(win)
  bd:SetPoint("TOPLEFT", win, "TOPLEFT", 648, -34)
  bd:SetPoint("BOTTOMRIGHT", -38, 40)
  win.breakdown = bd
  CU.ShowBreakdownHelp()

  local all = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  all:SetSize(220, 22)
  all:SetPoint("BOTTOMRIGHT", -14, 10)
  all:SetText("Search all in Auctionator")
  all:SetScript("OnClick", function()
    local names, seen = {}, {}
    for _, link in ipairs(CU.shownLinks or {}) do
      local name = GetItemInfo(link)
      if name and not seen[name] then seen[name] = true; table.insert(names, name) end
    end
    if #names > 0 then SearchInAuctionator(names) end
  end)
  return win
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
  local groups = self:BuildPlanOptions(weights)

  local source = cfg.budgetCopper and ("a set budget of " .. Money(cfg.budgetCopper)) or ("your " .. Money(have))
  local keep = (cfg.reserveCopper or 0) > 0 and (", keeping " .. Money(cfg.reserveCopper) .. " back") or ""
  m:AddMessage(("|cff999999Planning with %s%s. Buy in this order: best value first, so if a listing has gone you've already got the biggest wins. Prices are from your last scan%s.|r"):format(
    source, keep, self.lastScanTime and (", " .. math.floor((time() - self.lastScanTime) / 60) .. " min ago") or ""))

  local function show(title, b, addLinks)
    m:AddMessage(" ")
    m:AddMessage(("|cffffd100%s|r  |cff999999(budget %s)|r"):format(title, Money(b)))
    local chosen, gain, spent = Knapsack(groups, b)
    if #chosen == 0 then
      m:AddMessage("   Nothing you can afford is an upgrade.")
      return 0
    end
    table.sort(chosen, function(x, y) return x.gain / math.max(x.cost, 1) > y.gain / math.max(y.cost, 1) end)
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
      local pct = base > 0 and ("+%.1f%% overall"):format(o.gain / base * 100) or "upgrade"
      m:AddMessage(("   %d. |cffffffff%s|r  %s   %s   |cff00ff00%s|r   |cff999999total so far %s|r"):format(
        i, o.slot, Money(o.cost), table.concat(links, " + "), pct, Money(running)))
    end
    m:AddMessage(("   |cffffffffSpend %s for %s gear score. Left over: %s|r"):format(
      Money(spent), base > 0 and ("+%.1f%%"):format(gain / base * 100) or "a better", Money(b - spent)))
    return spent
  end

  local spent = show("Best plan for your budget", budget, true)
  -- A cheaper alternative, only worth showing if the full plan uses a fair chunk of the budget.
  if spent > 0 and budget >= 20000 then show("If you'd rather spend about half", math.floor(budget / 2), false) end
end

function CU:Render()
  -- Some items had no details last time: score everything again (cheap; scores are cached).
  if (self.pendingLoading or 0) > 0 and not self.inBuild and self.lastScan then
    self.retries = 99 -- no extra retry loop, just one fresh pass
    return self:BuildResults()
  end
  self:BuildViews()
  local groups = self.lastLadders or {}
  local w = GetWindow()
  local m = w.msg
  m:Clear()
  self.shownLinks, self.lineItems = {}, {}
  local money, level, any = GetMoney(), UnitLevel("player"), false

  -- Keep the controls in step with the settings.
  local shownSlots = 0
  for g, cb in pairs(w.filterButtons) do
    local on = not cfg.hiddenSlots[g]
    cb:SetChecked(on)
    w.filterLabels[g]:SetTextColor(on and 1 or 0.5, on and 0.82 or 0.5, on and 0 or 0.5) -- gold when on, grey when off
    if on then shownSlots = shownSlots + 1 end
  end
  w.dualWieldCheck:SetChecked(cfg.dualWield)
  w.viewButton:SetText(cfg.view == "plan" and "Show list by slot" or "Plan my purchases")

  -- Budget boxes only belong to the plan view; the list gets their row back otherwise.
  local planning = cfg.view == "plan"
  for _, mb in ipairs({ w.budgetBox, w.keepBox }) do
    for _, part in ipairs(mb.parts) do part:SetShown(planning) end
    if planning then mb.refresh() end
  end
  for _, part in ipairs(w.showAllParts) do part:SetShown(not planning) end
  w.showAllCheck:SetChecked(cfg.showAll)
  m:SetPoint("BOTTOMRIGHT", w, "BOTTOMLEFT", 600, 72)

  m:AddMessage(CU.ModeLine())
  if shownSlots < #GROUP_ORDER then
    m:AddMessage(("|cffff8800Showing %d of %d slots - tick more slots above, or click All.|r"):format(shownSlots, #GROUP_ORDER))
  end
  if (self.hiddenByFilters or 0) > 0 then
    m:AddMessage(("|cffff8800Quality / set filters are hiding %d upgrade%s.|r"):format(self.hiddenByFilters,
      self.hiddenByFilters == 1 and "" or "s"))
  end
  for q, cb in pairs(w.qualityChecks) do cb:SetChecked(not cfg.hiddenQuality[q]) end
  CU.RefreshSpecBoxes()
  w.setButton:SetText(({ any = "Set pieces: any", only = "Only set pieces", none = "No set pieces" })[cfg.setFilter] or "Set pieces: any")
  if planning then
    self:RenderPlan(m)
    m:Done()
    w:Show()
    return
  end

  local gearBase = lastWeights and GearScore(lastWeights) or 0
  m:AddMessage(cfg.showAll
    and "|cff999999Every upgrade, cheapest first (up to 30 per slot). Alt-click an item to search it in Auctionator. Shift-click a slot to show only that slot.|r"
    or "|cff999999Best value only: cheapest first, each line a bigger upgrade than the one above it. Tick \"Show every upgrade\" to see them all. Alt-click an item to search it in Auctionator.|r")
  for _, g in ipairs(GROUP_ORDER) do
    local ladder
    if not cfg.hiddenSlots[g] then
      if cfg.showAll and self.lastFiltered and self.lastFiltered[g] then
        ladder = {}
        for i, it in ipairs(self.lastFiltered[g]) do ladder[i] = it end
        table.sort(ladder, function(a, b) return a.price < b.price end)
        while #ladder > 30 do table.remove(ladder) end
      elseif groups[g] then
        ladder = Trim(groups[g])
      end
    end
    if ladder and #ladder > 0 then
      any = true
      m:AddMessage(" ")
      m:AddMessage("|cffffd100" .. g .. "|r  |cff999999wearing: " .. WearingText(g) .. "|r")
      for _, it in ipairs(ladder) do
        local sum = StatSummary(it.link)
        -- Shown as a share of your whole gear score, so slots can be compared with each other.
        -- (A percentage of the slot alone balloons when your current item there is weak.)
        local overall = gearBase > 0 and (it.gain / gearBase * 100) or 0
        local gain = ("|cff00ff00+%.1f%% overall|r  |cff999999(%.2f%% per gold)%s|r"):format(
          overall, overall / math.max(it.price / 10000, 1), it.empty and ", empty slot" or "")
        local lvl    = (it.reqLevel and it.reqLevel > level) and ("  |cffff8800usable at %d|r"):format(it.reqLevel) or ""
        local afford = (it.price > money) and "  |cffff4444can't afford|r" or ""
        local hitNote = it.hitWasted and "  |cff999999(hit past your cap not counted)|r" or ""
        local setName = SetName(it.setID)
        if setName then hitNote = hitNote .. "  |cff00ccff[Set: " .. setName .. "]|r" end
        m:AddMessage(("   %s   %s %s  %s%s%s%s"):format(Money(it.price), it.link,
          sum ~= "" and ("|cffbbbbbb(" .. sum .. ")|r") or "", gain, lvl, afford, hitNote))
        table.insert(self.shownLinks, it.link)
        local data = it.link:match("|H(.-)|h")
        if data then self.lineItems[data] = it end
      end
    end
  end
  if not any then
    m:AddMessage(" ")
    m:AddMessage("No upgrades found in the slots you've selected. Try more slots, |cffffffff/cu min 0|r or |cffffffff/cu ahead 2|r.")
  end
  m:Done()
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

  local list = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  list:SetSize(220, 26)
  list:SetPoint("TOP", scan, "BOTTOM", 0, -12)
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
  status:SetPoint("TOP", plan, "BOTTOM", 0, -20)
  local cooldown = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  cooldown:SetPoint("TOP", status, "BOTTOM", 0, -8)
  local note = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOP", cooldown, "BOTTOM", 0, -6)
  note:SetWidth(460)
  note:SetText("Full scans are shared with Auctionator's full scan. /cu scan forces a try anyway.")
  CU.updateTabStatus = function()
    if not CU.detectedSpecName then GetWeights() end
    CU.RefreshSpecBoxes()
    status:SetText(AgoText())
    cooldown:SetText(CooldownText())
    local left = CU.ScanCooldownLeft()
    if left > 0 then
      scan:Disable()
      scan:SetText(("Scan in %d:%02d"):format(math.floor(left / 60), left % 60))
    else
      scan:Enable()
      scan:SetText("Scan for upgrades")
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
  if not (CU.lastScan and win and win:IsShown()) then return end
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
ev:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == "Chupgrades" then
    ChupgradesDB = ChupgradesDB or {}
    for k, v in pairs(CU.Defaults) do
      if ChupgradesDB[k] == nil then ChupgradesDB[k] = v end
    end
    if type(ChupgradesDB.hiddenSlots) ~= "table" then ChupgradesDB.hiddenSlots = {} end
    if type(ChupgradesDB.hiddenQuality) ~= "table" then ChupgradesDB.hiddenQuality = {} end
    if ChupgradesDB.setFilter ~= "only" and ChupgradesDB.setFilter ~= "none" then ChupgradesDB.setFilter = "any" end
    -- Older versions saved these in gold; they're in copper now.
    if ChupgradesDB.budgetGold then ChupgradesDB.budgetCopper = math.floor(ChupgradesDB.budgetGold * 10000 + 0.5) end
    if ChupgradesDB.reserveGold and ChupgradesDB.reserveGold > 0 then
      ChupgradesDB.reserveCopper = math.floor(ChupgradesDB.reserveGold * 10000 + 0.5)
    end
    ChupgradesDB.budgetGold, ChupgradesDB.reserveGold = nil, nil
    cfg = ChupgradesDB
    -- Bring back the last scan, so results survive /reload and logging out.
    if type(cfg.savedScan) == "table" and type(cfg.savedScan.items) == "table" then
      CU.lastScan, CU.lastScanTime = cfg.savedScan.items, cfg.savedScan.time
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
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    if (CU.pendingLoading or 0) > 0 and CU.lastScan and win and win:IsShown() then
      if CU.itemInfoTimer then CU.itemInfoTimer:Cancel() end
      CU.itemInfoTimer = C_Timer.NewTimer(1, function() CU.retries = 99; CU:BuildResults() end)
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
    Say(false, ("Not in your last scan (%d min ago). It may have been listed since: rescan when the countdown allows."):format(age))
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
      local old, oldHit = EquippedScore(def, weights)
      local gain = HitAwareGain(new, HitRating(l), old, oldHit, weights, CU.HitInfo())
      local pct = old > 0 and gain / old * 100 or (new > 0 and math.huge or 0)
      local gearBase = GearScore(weights)
      local capNote = math.abs(gain - (new - old)) > 0.005 and " after the hit-cap adjustment (hit past your cap doesn't count)" or ""
      Say(gain > 0, ("Scores %.2f vs %.2f for what you wear: %s points%s (%+.1f%% overall)."):format(new, old,
        (gain >= 0 and "+" or "") .. ("%.2f"):format(gain), capNote, gearBase > 0 and gain / gearBase * 100 or 0))
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
  elseif cmd == "" or cmd == "show" then
    CU.retries = 0
    CU:BuildResults()
  elseif cmd == "min" then
    cfg.minUpgradePct = tonumber(rest) or cfg.minUpgradePct
    Print("Minimum upgrade: " .. cfg.minUpgradePct .. "%"); RefreshSoon()
  elseif cmd == "ahead" then
    cfg.levelLookahead = tonumber(rest) or 0
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
      local found
      for _, g in ipairs(GROUP_ORDER) do
        if g:lower() == want or g:lower():find("^" .. want) then found = g break end
      end
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
    cfg.reserveCopper = CU.ParseMoney(rest) or 0
    Print("Keeping " .. Money(cfg.reserveCopper) .. " back when planning."); if CU.lastLadders and win and win:IsShown() then CU:Render() end
  elseif cmd == "budget" then
    cfg.budgetCopper = CU.ParseMoney(rest)
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
      ScoreItem(link, w) or 0, def and ("%.1f"):format(EquippedScore(def, w)) or "n/a",
      tostring(ok), tostring(why)))
  else
    Print("Commands:")
    print("   /cu scan  - scan the Auction House (or click the button on the AH)")
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
