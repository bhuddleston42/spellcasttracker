# SpellCastTracker

Tracks successful public player casts during combat, with per-character and account totals, casts per minute, and keybind reports.

The 1.6.0 update preserves the locally developed 1.5 keybind and macro analysis, form tracking, auto-attack filtering, and tracking toggle. It targets Retail 12.1 (interface 120100), guards secret cast IDs, uses current C_Spell lookup APIs, and accounts only for enabled tracking time. Restricted casts are skipped and reported; totals can be incomplete where Blizzard restricts cast information. Keybinds are inferred from action bars and macros, not actual keyboard input. Combat reports use the last out-of-combat binding snapshot. Account totals describe all characters, but bindings describe the current character.

Commands: `/sct`, `/sct all`, `/sct on`, `/sct off`, `/sct toggle`, `/sct reset`, `/sct reset all`, and `/sct debug`. Broker: left-click toggles tracking, right-click shows character totals, Shift-right-click shows account totals.

## Installation and releases

Download the addon ZIP from GitHub Releases and extract the SpellCastTracker folder into `World of Warcraft/_retail_/Interface/AddOns`. Fully restart the game after a first installation. Existing saved variables are retained.

GitHub Actions runs Lua 5.1 parsing, regression checks, and TOC validation on pushes and pull requests. Push a tag matching the TOC version (for example `v1.6.0`) to publish a BigWigs-packaged addon ZIP and `release.json` for addon managers such as WoWUp. Manual workflow runs build an artifact without publishing. GitHub Actions publishes the GitHub release using the automatic GITHUB_TOKEN. CurseForge packages tagged commits through its connected GitHub repository and an active push webhook. The webhook URL contains the CurseForge publishing token; no CurseForge Actions secret is required. The TOC carries the CurseForge project ID; GitHub packaging uses -p 0 to avoid duplicate CurseForge uploads.

## Validation

Run `lua tests/regression.lua` and `python tests/validate_toc.py` from the repository root. Tests mock the WoW APIs; actual protected-frame, secret-value, and Edit Mode behavior still requires an in-game check.

## Bundled libraries

LibStub, CallbackHandler-1.0, and LibDataBroker-1.1 are included for a standalone broker feed. Third-party libraries retain their upstream ownership and licenses.
