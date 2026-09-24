# 1.6.1

Connect CurseForge project 1113915 to automated tagged releases. Add CurseForge project metadata for addon managers. No gameplay changes.

# 1.6.0

Tracks successful public player casts during combat, with per-character and account totals, casts per minute, and keybind reports.

The 1.6.0 update preserves the locally developed 1.5 keybind and macro analysis, form tracking, auto-attack filtering, and tracking toggle. It targets Retail 12.1 (interface 120100), guards secret cast IDs, uses current C_Spell lookup APIs, and accounts only for enabled tracking time. Restricted casts are skipped and reported; totals can be incomplete where Blizzard restricts cast information. Keybinds are inferred from action bars and macros, not actual keyboard input. Combat reports use the last out-of-combat binding snapshot. Account totals describe all characters, but bindings describe the current character.

Commands: `/sct`, `/sct all`, `/sct on`, `/sct off`, `/sct toggle`, `/sct reset`, `/sct reset all`, and `/sct debug`. Broker: left-click toggles tracking, right-click shows character totals, Shift-right-click shows account totals.
