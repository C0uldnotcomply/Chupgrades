# Changelog

## 0.9.9

* Budget and Keep are back to separate gold, silver and copper boxes. Tab moves between them; empty Budget
  plans with the money you carry, empty Keep keeps nothing back. `/cu budget` and `/cu keep` still accept `1g 33s 38c`.

## 0.9.8

* Fixed results-window creation and added page controls so every matching upgrade is reachable.
* Restored editable budget and keep-back controls, fixed money commands, and made invalid input preserve existing settings.
* Improved window placement, small-screen fit, filter feedback and shopping-plan links.
* Corrected targeted-search response matching and incomplete-result handling; bounded waits and scan cleanup prevent stuck searches.
* Kept exact random-stat listings separate and reported unread or partial scan coverage instead of guessing item stats.
* Deferred scoring while item data loads, corrected armour proficiency checks, and made ring/trinket replacements hit-cap aware.
* Corrected combined purchase gains for shared hit-cap headroom and clarified the shopping planner's approximation and weapon-transition limit.
