# Installing Chupgrades

A step-by-step guide for WoW: Forever on Windows. It takes about five minutes.

---

## What you need

| Addon | Needed? | Why |
| --- | --- | --- |
| **StatPriority** (by Todd King, on CurseForge), or **StatLedger** | **One is required** | Supplies stat values for scoring gear. StatPriority is recommended and is used when both are loaded. |
| **Auctionator** (on CurseForge) | Strongly recommended | Provides the Chupgrades tab on the Auction House and does the buying when you send items to it. |
| **Chupgrades** | Yes | This addon. |

---

## Step 1: Install StatPriority and Auctionator

1. Open the **CurseForge** app and choose **World of Warcraft**.
2. Make sure the version selector at the top says **WoW Forever**, not Retail or Classic.
3. Search for **StatPriority** and click **Install**.
4. Search for **Auctionator** and click **Install**.

> Already have both? Skip to Step 2.

---

## Step 2: Download Chupgrades

1. Open [the Chupgrades repository](https://github.com/C0uldnotcomply/Chupgrades). No GitHub account is needed.
2. Click the green **Code** button, then **Download ZIP**.
3. You'll get **`Chupgrades-main.zip`** in your Downloads folder.

---

## Step 3: Find your AddOns folder

1. **Exit WoW completely.** New addons are only picked up when the game starts, so a `/reload` won't find them.
2. The default location is:

   ```
   C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns
   ```

3. Not there? Open the **Battle.net** app, select **World of Warcraft**, choose **Forever** in the version
   drop-down, then click the cog next to **Play** and choose **Show in Explorer**. Open
   `_forever_` → `Interface` → `AddOns`.

You should see folders such as `Auctionator` and `StatPriority` in there.

---

## Step 4: Put Chupgrades in the AddOns folder

The download has one extra folder layer: `Chupgrades-main` contains the guides **and** the actual addon
folder, `Chupgrades`. Only that inner `Chupgrades` folder goes into AddOns.

1. Right-click **`Chupgrades-main.zip`** and choose **Extract All...**, then click **Extract**. Your Downloads folder is fine.
2. Open the extracted **`Chupgrades-main`** folder. Inside you'll see `Chupgrades`, `README.md` and `INSTALL.md`.
3. **Copy the `Chupgrades` folder** (right-click → Copy).
4. Open your **AddOns** folder from Step 3 and **paste** it there.
5. **Check the result.** This file must exist:

   ```
   ...\Interface\AddOns\Chupgrades\Chupgrades.toc
   ```

   | ✅ Right | ❌ Wrong |
   | --- | --- |
   | `AddOns\Chupgrades\Chupgrades.toc` | `AddOns\Chupgrades-main\Chupgrades\Chupgrades.toc` |
   | | `AddOns\Chupgrades\Chupgrades\Chupgrades.toc` |

   If you see one of the wrong layouts, move the folder that **contains** `Chupgrades.toc` straight into `AddOns`,
   and delete any leftover outer folder. WoW only finds the addon when the `.toc` file is exactly one folder deep.

> **Updating from an older version?** Delete the old `AddOns\Chupgrades` folder first, then
> extract the new one. Your settings and last scan are kept: they live in WoW's `WTF` folder,
> not in the addon folder.

---

## Step 5: Turn it on in game

1. Start WoW: Forever.
2. On the character select screen, click **AddOns** (bottom left).
3. Make sure **Chupgrades**, **StatPriority** and **Auctionator** are all ticked.
4. If any of them say **Out of date**, tick **Load out of date AddOns** at the top.
5. Click **Okay** and log in.

You should see this in chat:

```
Chupgrades: loaded. Open the Auction House and use the Chupgrades tab, or type /cu help.
```

---

## Step 6: Check your spec

StatPriority prints your spec when you log in, for example `StatPriority: Hunter - Beast Mastery (auto)`.

* **(auto)** means it was detected from your talents. 👍
* **(manual)** means a spec was picked by hand, for example by left-clicking StatPriority's bar on the
  Character sheet. If that's not the spec you want, type `/statprio spec auto` to go back to auto-detection.

You can also pick the spec inside Chupgrades itself (Step 7). That choice is independent of StatPriority.

---

## Step 7: First scan

1. Go to an **Auctioneer** and open the Auction House.
2. Click the **Chupgrades** tab along the bottom, next to Auctionator's tabs.
3. Under **Score upgrades for:**, tick your spec, or leave **Auto**.
4. Click the full-scan button, or **Search slots** for a smaller search of the selected slots.
5. Open the results and choose **Biggest upgrades**, **Best value** or the shopping plan.

> Blizzard only allows a **full scan about every 15 minutes**, and that allowance is shared with Auctionator's
> full scan. The tab shows a countdown. Your last scan is saved, so you can change spec, filters or
> budget at any time without scanning again.

Targeted slot searches use the normal Auction House search queue instead of that full-scan allowance.
They still need the Auction House open and can be throttled. `/cu search head ring`, for example, searches
only those slots. `/cu searchcap 400` raises the rolled-item lookup limit; `/cu floor off` includes lower-level
gear that the normal search floor would skip. A larger search can take longer.
Use `/cu stop` to cancel a search and keep your previous results.

---

## Using the results window

| Click | What happens |
| --- | --- |
| Click an item | Open its stat and score breakdown |
| **Alt**-click an item | Search for it in Auctionator |
| **Shift**-click an item | Link it in chat |
| **Ctrl**-click an item | Preview it on your character |

* **Slot tickboxes:** choose which slots to search and include in the plan. Click a slot's row to view it.
* **Quality / Set pieces:** filter by item quality, or show only (or no) set pieces.
* **Biggest upgrades:** the five largest upgrades for the selected slot.
* **Best value:** a cheapest-first ladder where each step is a bigger upgrade. **Show every upgrade**
  includes items outside that ladder. Use the page controls to move through more than six results.
* **Shopping plan:** suggests purchases for your budget. **Budget** and **Keep** each have separate
  gold, silver and copper boxes. **Enter** or **Tab** applies (Tab moves to the next box), and **Escape** restores the saved value.
  A blank budget uses the money you carry; a blank keep-back amount clears the reserve.
* **Move the window:** drag it to a convenient position. That position is saved. `/cu reset` restores its
  position if you want to start again.

Money and numeric commands reject invalid input without changing your existing setting. `/cu budget`
uses carried money, `/cu keep` clears the reserve, and `/cu ahead 3` includes items usable within three
levels. Look-ahead gear is shown in lists, but the shopping plan only includes items usable now.

The plan is an estimate, not a guaranteed optimum: prices round up for budgeting, and combinations are
selected before correcting their total for shared hit-cap headroom. It also does not plan a switch from
your equipped two-hander to a new main-hand/off-hand pair.

If a search reaches its lookup limit, times out or cannot read some listings, its coverage is partial.
Older results may be retained and can be stale. Unread random-stat listings are skipped rather than
given guessed stats. Search fewer slots, increase `/cu searchcap`, or retry to improve coverage.

> ⚠️ Items marked **"may vary in stats"** (names like *"...of Power"*) come in versions with different stats.
> Auctionator's search row only shows the plain version. Buy the listing whose stats match the
> ones Chupgrades shows.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| No Chupgrades tab on the Auction House | Fully exit and restart WoW (not `/reload`) after a first install. Check Step 4's folder layout and Step 5's AddOns list. |
| "No stat addon found" | Enable StatPriority or StatLedger in the AddOns list. |
| "StatPriority doesn't know your spec yet" | Spend a talent point, or tick a spec in Chupgrades. |
| Full scan is on cooldown | Wait for the countdown, or use **Search slots**. `/cu scan` can try a full scan anyway, but Blizzard may refuse it. |
| Search stopped or results are marked partial | Keep the Auction House open. Retry fewer slots or increase `/cu searchcap` if the lookup limit was reached. |
| Window is in the wrong place | Type `/cu reset` to restore its position and screen fit. |
| An item you can see on the AH isn't listed | Type `/cu why ` and shift-click the item: it checks scan, slot tickboxes, usability, score, filters and budget, and says where it drops out. |
| Results look wrong | Click the item to see its breakdown. Type `/cu safe` to compare with plain StatPriority scoring. |
| Nothing happens and no error shows | Type `/console scriptErrors 1`, then `/reload`, to show Lua errors. |

---

## Rolling back to an older version

* **Quick switch:** `/cu safe` turns off all of Chupgrades' own scoring corrections and uses plain StatPriority values.
  Type it again to switch back.
* **Older version:** on GitHub, click **commits**, open an older commit, then **Browse files** → **Code** →
  **Download ZIP**, and repeat Step 4. You'll need to delete the current folder first.

## Uninstalling

Exit WoW and delete `Interface\AddOns\Chupgrades`. Saved settings live in
`WTF\Account\<your account>\SavedVariables\Chupgrades.lua`. Delete that file too if you want a clean slate.
