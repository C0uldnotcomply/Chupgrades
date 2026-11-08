# Chupgrades

**Cheap upgrades from the Auction House, scored for your spec. For World of Warcraft: Forever.**

Chupgrades scans every piece of gear for sale and scores each item with your spec's stat values from
**StatPriority**. It drops anything your class or level can't use, then shows
the best-value upgrade for each slot, along with a shopping plan for the gold you have.

➡️ **[Step-by-step install guide](INSTALL.md)**

---

## Features

* **Full Auction House scan.** Every piece of armour and weapons for sale, including exact "of the X" stat rolls.
  The last scan is saved, so it survives `/reload` and logging out.
* **Scored for your spec.** Uses StatPriority's per-spec values, with Forever-specific corrections, for example
  hunter Agility = 2 ranged Attack Power plus crit. **Auto** follows your detected spec, or you can pick any spec
  of your class. You can change spec any time without rescanning.
* **Only gear you can use:** level (with optional look-ahead), armour type (mail/plate at 40), weapon skills
  and class restrictions.
* **Hit-cap aware.** Reads your current hit chance and values hit only up to the cap: same-level caps while
  levelling, raid caps at 60.
* **Levelling mode.** Under 60, Stamina counts a little as a tie-breaker, and casters and healers get
  minimum values for Intellect, MP5 and Spirit (level-60 sims barely value mana).
* **Best-value ladder per slot.** Cheapest first, and each line is a bigger upgrade than the one above it. You can
  also show every upgrade.
* **Shopping plan.** Picks the combination of items with the biggest total gain that fits your budget
  (gold / silver / copper, plus an amount to keep back), listed in the order to buy.
* **Breakdown panel.** Click any item to see each stat, what it's worth to you, the hit-cap adjustment and the
  weighted % increase to your whole gear score.
* **Filters:** slots, item quality (Poor → Epic), set pieces (any / only / none) and dual wield.
* **Auctionator integration.** A Chupgrades tab on the Auction House, a countdown to the next allowed full
  scan, and alt-click or "Search all" to send items to Auctionator to buy.

## Requirements

* World of Warcraft: Forever (Interface 16001)
* **StatPriority** (required)
* **Auctionator** (recommended)

## Slash commands

| Command | What it does |
| --- | --- |
| `/cu scan` | Scan the Auction House (same as the tab's button) |
| `/cu` | Show the last results again |
| `/cu plan` / `/cu list` | Shopping plan / per-slot list |
| `/cu budget <amount>` | Plan with a set amount, e.g. `1g 33s 38c` or `5` for 5 gold. `/cu budget` on its own uses what you carry |
| `/cu keep <amount>` | Money the plan should leave untouched |
| `/cu slot <name>` | Show or hide a slot (`head`, `ring`, `main`…). `all` shows every slot |
| `/cu sets any\|only\|none` | Set-piece filter |
| `/cu dw` | Toggle dual wield |
| `/cu min <n>` | Hide upgrades smaller than n% |
| `/cu ahead <n>` | Include items you can use within n levels |
| `/cu armour` | Toggle "main armour type only" |
| `/cu levelling auto\|on\|off` | Levelling mode |
| `/cu hit` | Your hit and hit cap. `/cu hit off\|on` toggles cap tracking |
| `/cu weights` | Show the stat values in use |
| `/cu why <link>` | Why an item is or isn't listed: scan, slot, usability, score, filters, budget |
| `/cu item <link>` | Debug how one item is scored |
| `/cu safe` | Safe mode: plain StatPriority scoring (rollback switch) |
| `/cu tab` | Diagnostics for the Auction House tab |

## Configuration

`Chupgrades/Config.lua` holds the tunable tables, each with comments:

* `CU.WeightAdjust`: per-class and per-spec corrections to StatPriority's values
* `CU.Levelling`: the level-60 cutoff, the Stamina tie-breaker value, the casters' mana-stat minimums and per-spec minimums (`specFloors`)
* `CU.HitCaps` / `CU.HitType`: hit caps by attack type and target, and which hit each spec uses
* `CU.ExtraArmor`: extra armour types allowed per spec (e.g. cloth for caster druids)

## Notes

* **Blizzard's rules:** Chupgrades only reads Auction House data through the game's own addon API. It never
  buys or sells automatically: every purchase is your own click in Auctionator.
* **Stat values are estimates.** They come from StatPriority's simulated values plus the corrections above, and
  no simulation fits every situation.
* **"May vary in stats" items:** buy the listing whose stats match the ones Chupgrades shows.
