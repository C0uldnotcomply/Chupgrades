# Local regression checks

Run from the repository root with LuaJIT (Lua 5.1 semantics):

```powershell
luajit tests/regression.lua
```

The harness loads the real `Config.lua` and `Core.lua` in fresh environments and
dispatches normal addon events against mocked frames, item data, Auction House
responses, and a deterministic timer queue. Failed assertions exit with status 1.

Coverage includes initial results-window construction, money parsing and invalid
commands, persisted-setting repair, pagination, equipped-item loading, armour
proficiency, hit-aware swaps and shopping totals, exact rolled-item request
matching, paginated prices, scan cancellation, stale callbacks, API exceptions,
bounded timeouts, and retained prior listings after incomplete browse results.
Private usability is reached through a named Lua upvalue;
the calculations under test remain production code.

The frame double verifies construction and interaction state, not pixel layout.
Actual server throttling, tooltip contents, live Auctionator integration, and
visual placement still need an in-game check.
