# Chupgrades

**Cheap upgrades from the Auction House, scored for your spec. For World of Warcraft: Forever.**

Chupgrades scans Auction House gear and scores each item with your spec's stat values from
**StatPriority** (or StatLedger). It filters gear by usability, then shows upgrades by slot,
along with a shopping plan for your budget.

➡️ **[Step-by-step install guide](INSTALL.md)**

---

## Features

* **Two ways to search.** Scan the full Auction House, or search just the slots you choose without waiting
  for the full-scan cooldown. Exact "of the X" versions are used when the game supplies their links.
  The last results are saved across `/reload` and logging out.
* **Scored for your spec.** Uses StatPriority's per-spec values, with Forever-specific corrections, for example
  hunter Agility = 2 ranged Attack Power plus crit. **Auto** follows your detected spec, or you can pick any spec
  of your class. You can change spec any time without rescanning.
* **Only gear you can use:** level (with optional look-ahead), armour type (mail/plate at 40), weapon skills
  and class restrictions.
* **Hit-cap aware.** Reads your current hit chance and values hit only up to the cap: same-level caps while
  levelling, raid caps at 60.
* **Levelling mode.** Under 60, Stamina counts a little as a tie-breaker, and casters and healers get
  minimum values for Intellect, MP5 and Spirit (level-60 sims barely value mana).
* **Three result views.** Biggest upgrades shows the top five per slot. Best value is cheapest first, with
  each step a bigger upgrade. Show every upgrade includes the rest; page controls let you reach all results.
* **Shopping plan.** Suggests a combination of upgrades within your budget and keep-back amount. Enter
  amounts such as `1g 33s 38c` or `5` for five gold in the plan controls or slash commands.
* **Breakdown panel.** Click any item to see each stat, what it's worth to you, the hit-cap adjustment and the
  weighted % increase to your whole gear score.
* **Filters:** slots, item quality (Poor → Epic), set pieces (any / only / none) and dual wield.
* **Auctionator integration.** A Chupgrades tab on the Auction House, a countdown to the next allowed full
  scan, and alt-click or "Search all" to send items to Auctionator to buy.
* **Window controls.** Drag to reposition; the position is remembered and the window fits smaller screens.
  `/cu reset` restores its position.

## Requirements

* World of Warcraft: Forever (Interface 16001)
* **StatPriority** (recommended) or **StatLedger** (one scoring addon is required)
* **Auctionator** (recommended)

## Slash commands

| Command | What it does |
| --- | --- |
| `/cu scan` | Scan the Auction House (same as the tab's button) |
| `/cu stop` | Cancel a running scan or slot search and keep the previous results |
| `/cu search [slots]` | Search shown slots, or named slots such as `head ring main` |
| `/cu searchcap <n>` | Limit rolled-item lookups to 1–2000 items |
| `/cu floor <n>` / `/cu floor off` | Search gear at most n levels below you (0–100), or every level |
| `/cu` | Show the last results again |
| `/cu top` | Toggle the top five biggest upgrades per slot |
| `/cu plan` / `/cu list` | Shopping plan / per-slot list |
| `/cu budget <amount>` | Plan with a set amount, e.g. `1g 33s 38c` or `5` for 5 gold. `/cu budget` on its own uses what you carry |
| `/cu keep <amount>` | Money the plan should leave untouched; no amount clears it |
| `/cu slot <name>` | Show or hide a slot (`head`, `ring`, `main`…). `all` shows every slot |
| `/cu sets any\|only\|none` | Set-piece filter |
| `/cu dw` | Toggle dual wield |
| `/cu min <n>` | Hide upgrades smaller than n% (finite, nonnegative number) |
| `/cu ahead <n>` | Include items usable within n levels (whole number, 0–60) |
| `/cu armour` | Toggle "main armour type only" |
| `/cu levelling auto\|on\|off` | Levelling mode |
| `/cu hit` | Your hit and hit cap. `/cu hit off\|on` toggles cap tracking |
| `/cu weights` | Show the stat values in use |
| `/cu why <link>` | Why an item is or isn't listed: scan, slot, usability, score, filters, budget |
| `/cu item <link>` | Debug how one item is scored |
| `/cu safe` | Safe mode: plain StatPriority scoring (rollback switch) |
| `/cu tab` | Diagnostics for the Auction House tab |
| `/cu reset` | Restore the results window's position and fit |

Invalid money or numeric input leaves the previous setting intact. Slot names accept unambiguous
prefixes; empty or ambiguous names are rejected. In the plan's Budget and Keep fields,
press **Enter** to apply an amount or **Escape** to restore the saved value.

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
* **Plans are approximate.** Budget rounding can leave some money unused. Item combinations are selected
  using per-option gains, then the displayed total is corrected for their combined hit-cap effect; this does
  not guarantee the best possible combination when several purchases share hit headroom. The planner
  does not search a switch from a currently equipped two-hander to a new main-hand/off-hand pair.
* **Results are a snapshot.** Listings may sell after a scan. Capped, timed-out or unread searches are marked
  partial; retained older listings can be stale. Unread random-stat versions are skipped rather than assigned
  a plain item's stats. Increase `/cu searchcap`, search fewer slots, or search again for better coverage.
* **"May vary in stats" items:** buy the listing whose stats match the ones Chupgrades shows.
