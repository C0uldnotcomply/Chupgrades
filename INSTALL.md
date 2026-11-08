# Installing Chupgrades

A step-by-step guide for WoW: Forever on Windows. It takes about five minutes.

---

## What you need

| Addon | Needed? | Why |
| --- | --- | --- |
| **StatPriority** (by Todd King, on CurseForge) | **Yes** | Supplies your spec and its stat values. Chupgrades can't score gear without it. |
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

1. Open **https://github.com/C0uldnotcomply/Chupgrades**. You need to be signed in, because the repository is private.
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
4. Click **Scan for upgrades**. It takes up to a minute.
5. Click **Show upgrades by slot** or **Plan my purchases**.

> Blizzard only allows a **full scan about every 15 minutes**, and that allowance is shared with Auctionator's
> full scan. The tab shows a countdown. Your last scan is saved, so you can change spec, filters or
> budget at any time without scanning again.

---

## Using the results window

| Click | What happens |
| --- | --- |
| Click an item | Breakdown on the right: each stat, what it's worth to you, and the weighted % increase |
| **Alt**-click an item | Search for it in Auctionator |
| **Shift**-click an item | Link it in chat |
| **Ctrl**-click an item | Preview it on your character |

* **Slot tickboxes:** choose which slots to include. Shift-click a slot to show only that slot.
* **Quality / Set pieces:** filter by item quality, or show only (or no) set pieces.
* **Plan my purchases:** the best combination of upgrades for your budget. Enter gold, silver and copper
  in the **Budget** boxes, or leave them empty to use what you carry.

> ⚠️ Items marked **"may vary in stats"** (names like *"...of Power"*) come in versions with different stats.
> Auctionator's search row only shows the plain version. Buy the listing whose stats match the
> ones Chupgrades shows.

---

## Troubleshooting

| Problem | Fix |
| --- | --- |
| No Chupgrades tab on the Auction House | Fully exit and restart WoW (not `/reload`) after a first install. Check Step 4's folder layout and Step 5's AddOns list. |
| "No stat addon found" | StatPriority isn't installed or isn't ticked in the AddOns list. |
| "StatPriority doesn't know your spec yet" | Spend a talent point, or tick a spec in Chupgrades. |
| Scan button greyed out | Blizzard's 15-minute full-scan limit. Wait for the countdown, or type `/cu scan` to try anyway. |
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
