-- Chupgrades: settings and scoring tables.
-- Everything in this file is safe to tweak.

Chupgrades = Chupgrades or {}
local CU = Chupgrades

-- Defaults. Changes made with slash commands are saved per account and override these.
CU.Defaults = {
  minUpgradePct  = 2,     -- ignore upgrades smaller than this (%)
  levelLookahead = 0,     -- also show items you can wear within this many levels
  mainArmorOnly  = true,  -- only your class's main armour type (e.g. no cloth chests for a Warrior)
  maxPerSlot     = 8,     -- max lines per slot in the best-value list
  showAll        = false, -- list view: show every upgrade instead of only the best-value ladder
  levelling      = "auto",-- "auto" (on below level 60), "on" or "off"
  trackHit       = true,  -- value hit only up to your hit cap
  safeMode       = false, -- true = plain StatPriority scoring: no corrections, levelling or hit-cap logic
  dualWield      = false, -- compare one-handers against your off hand too, and show off-hand-only weapons
  view           = "list",-- "list" (per slot) or "plan" (shopping plan for your gold)
  reserveCopper  = 0,     -- money the planner should leave untouched (repairs, training...), in copper
  -- budgetCopper (plan with a set amount instead of what you carry) is saved from the Budget boxes
  -- hiddenSlots (which slot filters are switched off) is saved automatically
}

-- Corrections to StatPriority's per-point values, by class, then by spec.
--   CLASS = { ALL = { ... applies to every spec ... }, [specID] = { ... one spec only ... } }
-- Values are per point of the stat, on StatPriority's scale: 1 = one point of Attack Power
-- (physical specs) or one point of Spell Power (casters and healers).
-- Spec IDs: Hunter 253 Beast Mastery, 254 Marksmanship, 255 Survival;
--           Priest 256 Discipline, 257 Holy, 258 Shadow;
--           Mage 62 Arcane, 63 Fire, 64 Frost;  Druid 102 Balance, 103 Feral, 104 Guardian, 105 Restoration.
-- Type /cu safe in game to switch ALL of these off and score with plain StatPriority values.
CU.WeightAdjust = {
  HUNTER = {
    -- StatPriority's own notes say its hunter numbers "look odd": it has Agility at 0.64.
    -- In Forever each point of Agility gives a hunter 2 ranged Attack Power + 1 melee Attack Power,
    -- plus crit (about 53 Agility per 1% at level 60) and armour. Plain Attack Power on gear
    -- already counts for melee and ranged, so StatPriority's 1.0 for it is right.
    ALL = { ITEM_MOD_AGILITY_SHORT = 2.1 },
  },
  MAGE = {
    -- In Forever one third of bonus healing also counts as bonus damage, so "+healing" items
    -- aren't worthless to a damage caster. StatPriority values them at 0.
    ALL = { ITEM_MOD_SPELL_HEALING_DONE_SHORT = 0.33 },
  },
  PRIEST = {
    [258] = { ITEM_MOD_SPELL_HEALING_DONE_SHORT = 0.33 },   -- Shadow: same healing-counts-as-damage rule
    -- Discipline (256) and Holy (257): StatPriority's healer values look sound, unchanged.
  },
  DRUID = {
    [102] = { ITEM_MOD_SPELL_HEALING_DONE_SHORT = 0.33 },   -- Balance: same healing-counts-as-damage rule
    -- Feral (103), Guardian (104) and Restoration (105): StatPriority's values look sound, unchanged.
  },
}

-- With "main armour type only" on, these specs may also use the armour types listed
-- (1 cloth, 2 leather, 3 mail, 4 plate). Caster and healer druids wear plenty of cloth.
CU.ExtraArmor = {
  DRUID = { [102] = { 1 }, [105] = { 1 } },   -- Balance, Restoration: cloth too
}

-- Levelling mode: on automatically below maxLevel (or force it with /cu levelling on|off|auto).
--   * Stamina counts as a tie-breaker: 0.25 = 4 Stamina worth 1 Attack Power / Spell Power.
--     Damage sims value Stamina at 0 because they never die; while levelling, deaths cost time.
--     Tanks keep StatPriority's own (much higher) Stamina value.
--   * Hit caps are the ones against same-level enemies instead of raid bosses.
CU.Levelling = { maxLevel = 60, stamina = 0.25 }

-- Hit stops counting once you reach these (% hit), by attack type and target.
-- Source: method.gg's WoW Forever hit guide (caps assume maxed weapon skill).
CU.HitCaps = {
  levelling = { melee = 5, ranged = 5, spell = 4,  dualwield = 24 },  -- same-level enemies
  raid      = { melee = 8, ranged = 8, spell = 17, dualwield = 29 },  -- raid bosses
}

-- Which hit chance matters for each class / spec ("none" = healers: hit isn't capped for them).
CU.HitType = {
  HUNTER  = { ALL = "ranged", [255] = "melee" },
  MAGE    = { ALL = "spell" },
  DRUID   = { [102] = "spell", [103] = "melee", [104] = "melee", [105] = "none" },
  WARLOCK = { ALL = "spell" },
  PRIEST  = { ALL = "none", [258] = "spell" },
  SHAMAN  = { [262] = "spell", [263] = "melee", [264] = "none" },
  PALADIN = { ALL = "melee", [65] = "none" },
  WARRIOR = { ALL = "melee" },
  ROGUE   = { ALL = "melee" },
}

-- (StatLedger only: with StatPriority installed, its own weights and scoring are used and
-- these two tables are ignored.)
-- StatLedger stat key -> the stat names the game uses on item tooltips.
-- Run "/cu item <shift-click an item>" in game to see what an item reports;
-- anything listed as "not scored" can be added here.
CU.StatMap = {
  STR        = { "ITEM_MOD_STRENGTH_SHORT" },
  AGI        = { "ITEM_MOD_AGILITY_SHORT" },
  STA        = { "ITEM_MOD_STAMINA_SHORT" },
  INT        = { "ITEM_MOD_INTELLECT_SHORT" },
  SPI        = { "ITEM_MOD_SPIRIT_SHORT" },
  AP         = { "ITEM_MOD_ATTACK_POWER_SHORT" },
  RAP        = { "ITEM_MOD_RANGED_ATTACK_POWER_SHORT" },
  SP         = { "ITEM_MOD_SPELL_POWER_SHORT", "ITEM_MOD_SPELL_DAMAGE_DONE_SHORT" },
  HEAL       = { "ITEM_MOD_SPELL_HEALING_DONE_SHORT" },
  CRIT       = { "ITEM_MOD_CRIT_RATING_SHORT", "ITEM_MOD_CRIT_MELEE_RATING_SHORT" },
  SPELLCRIT  = { "ITEM_MOD_CRIT_SPELL_RATING_SHORT" },
  HIT        = { "ITEM_MOD_HIT_RATING_SHORT", "ITEM_MOD_HIT_MELEE_RATING_SHORT", "ITEM_MOD_HIT_SPELL_RATING_SHORT" },
  HASTE      = { "ITEM_MOD_HASTE_RATING_SHORT" },
  MP5        = { "ITEM_MOD_MANA_REGENERATION_SHORT", "ITEM_MOD_POWER_REGEN0_SHORT" },
  ARMOR      = { "RESISTANCE0_NAME" },
  DEF        = { "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT" },
  DODGE      = { "ITEM_MOD_DODGE_RATING_SHORT" },
  PARRY      = { "ITEM_MOD_PARRY_RATING_SHORT" },
  BLOCK      = { "ITEM_MOD_BLOCK_RATING_SHORT" },
  BLOCKVALUE = { "ITEM_MOD_BLOCK_VALUE_SHORT" },
  DPS        = { "ITEM_MOD_DAMAGE_PER_SECOND_SHORT" },
}

-- StatLedger weights rank stats (1.0 = most important) but don't say how much ONE POINT
-- of each stat is worth. 1% crit is worth far more than 1 Stamina, and armour comes in
-- hundreds. These rough "one point = this many primary-stat points" values even that out.
-- Rough vanilla-era ballpark figures: adjust to taste.
CU.StatScale = {
  STR = 1, AGI = 1, STA = 1, INT = 1, SPI = 1,
  AP = 0.5, RAP = 0.4,
  SP = 1, HEAL = 0.5,
  CRIT = 14, SPELLCRIT = 14, HIT = 14,   -- vanilla items give these as whole %
  HASTE = 10,
  MP5 = 2,
  ARMOR = 0.02,
  DEF = 1.5, DODGE = 12, PARRY = 12, BLOCK = 12, BLOCKVALUE = 0.3,
  DPS = 5,
}
