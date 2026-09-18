-- SpellCastTracker.lua

local ADDON_NAME = ...
local PREFIX = "|cff00ff00[SpellCastTracker]|r "
local TOP_ON_LOGIN = 5

-- Account-wide and per-character SavedVariables (declared in the .toc).
SpellCastTrackerDB     = SpellCastTrackerDB     or {}
SpellCastTrackerCharDB = SpellCastTrackerCharDB or {}

local currentCombatCasts = {}
local combatStartTime
local inCombat = false
local skippedCasts = 0
local currentCombatForms = {}
local currentCombatSeconds = 0

local function IsPublic(value)
    return not (issecretvalue and issecretvalue(value))
end

-- Auto-attack spells fire UNIT_SPELLCAST_SUCCEEDED on every swing without any
-- keypress, so they're pure noise for a keybind-ergonomics tracker. Filter at
-- both record time (so new sessions don't accumulate them) and on login (so
-- previously-recorded data is scrubbed).
local IGNORED_SPELL_IDS = {
    [75]   = true,  -- Auto Shot (hunter / ranged)
    [6603] = true,  -- Auto Attack (melee)
}

-- Forward-declared so functions defined above the LDB block can call it.
-- Assigned later, after the LDB data object is created (or remains a no-op
-- when LibDataBroker isn't embedded).
local UpdateLDB = function() end

local function Print(msg)
    print(PREFIX .. msg)
end

-- Resolve a spell name from its ID via the modern (11.0+) API,
-- falling back to a stable string if the spell can't be looked up.
local function GetSpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        local name = C_Spell.GetSpellName(spellID)
        if IsPublic(name) and name then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if IsPublic(info) and info and IsPublic(info.name) and info.name then return info.name end
    end
    return "Spell " .. tostring(spellID)
end

local function Bump(tbl, key)
    tbl[key] = (tbl[key] or 0) + 1
end

local function FormatCPM(count, seconds)
    if not seconds or seconds <= 0 then return "" end
    return string.format(" (%.1f/min)", count / (seconds / 60))
end

-- Map an action bar slot index to every binding name that can fire it.
--
-- A slot can be reached by more than one binding: the default UI's binding
-- names (ACTIONBUTTON*, MULTIACTIONBAR*) plus whatever a replacement bar
-- addon registers. Bartender4 binds BT4Button1..120 1:1 to slots 1..120,
-- independent of stance/form paging — so for those slots we emit BOTH the
-- default name AND the BT4 alias, and GetBindingKey on each will pick up
-- whichever the user actually has assigned.
--
-- The MULTIACTIONBAR<N> prefix on the default names does NOT line up
-- numerically with the WoW UI "Bar N" label or with slot ordering: Bottom
-- Left (Bar 2) is MULTIACTIONBAR1, Right (Bar 4) is MULTIACTIONBAR3, etc.
-- Reference: SACI's LoadActionSlotMap.
--
-- formOffset on an entry means "this binding only fires the slot when the
-- player's bonus-bar offset matches" — true for the default UI's stance/form
-- paged ACTIONBUTTON1-12, false for everything else (MULTIACTIONBAR*, BT4*).
local function GetSlotBindingNames(slot)
    local out = {}
    if     slot >= 1   and slot <= 12  then out[#out+1] = { name = "ACTIONBUTTON"          .. slot,          formOffset = 0 }
    elseif slot >= 13  and slot <= 24  then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 12),   formOffset = 0 }
    elseif slot >= 25  and slot <= 36  then out[#out+1] = { name = "MULTIACTIONBAR3BUTTON" .. (slot - 24)  }
    elseif slot >= 37  and slot <= 48  then out[#out+1] = { name = "MULTIACTIONBAR4BUTTON" .. (slot - 36)  }
    elseif slot >= 49  and slot <= 60  then out[#out+1] = { name = "MULTIACTIONBAR2BUTTON" .. (slot - 48)  }
    elseif slot >= 61  and slot <= 72  then out[#out+1] = { name = "MULTIACTIONBAR1BUTTON" .. (slot - 60)  }
    elseif slot >= 73  and slot <= 84  then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 72),   formOffset = 1 }
    elseif slot >= 85  and slot <= 96  then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 84),   formOffset = 2 }
    elseif slot >= 97  and slot <= 108 then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 96),   formOffset = 3 }
    elseif slot >= 109 and slot <= 120 then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 108),  formOffset = 4 }
    elseif slot >= 121 and slot <= 132 then out[#out+1] = { name = "ACTIONBUTTON"          .. (slot - 120) }
    elseif slot >= 145 and slot <= 156 then out[#out+1] = { name = "MULTIACTIONBAR5BUTTON" .. (slot - 144) }
    elseif slot >= 157 and slot <= 168 then out[#out+1] = { name = "MULTIACTIONBAR6BUTTON" .. (slot - 156) }
    elseif slot >= 169 and slot <= 180 then out[#out+1] = { name = "MULTIACTIONBAR7BUTTON" .. (slot - 168) }
    end
    -- Bartender4: BT4Button<slot> maps 1:1 to action slots 1-120, no form paging.
    -- The lookup is cheap (single GetBindingKey call) so we emit unconditionally;
    -- if Bartender isn't loaded, the binding just isn't set and we skip it.
    if slot >= 1 and slot <= 120 then
        out[#out+1] = { name = "BT4Button" .. slot }
    end
    return out
end

-- "CTRL-SHIFT-=" -> "CS=", "ALT-BUTTON3" -> "AM3", "CTRL-MOUSEWHEELUP" -> "CMwU".
local function CompactBinding(key)
    if not key or key == "" then return nil end
    local mods, base = "", key
    if base:find("ALT%-")   then mods = mods .. "A"; base = base:gsub("ALT%-",   "") end
    if base:find("CTRL%-")  then mods = mods .. "C"; base = base:gsub("CTRL%-",  "") end
    if base:find("SHIFT%-") then mods = mods .. "S"; base = base:gsub("SHIFT%-", "") end
    if base:find("META%-")  then mods = mods .. "M"; base = base:gsub("META%-",  "") end
    if     base == "MOUSEWHEELUP"   then base = "MwU"
    elseif base == "MOUSEWHEELDOWN" then base = "MwD"
    elseif base:match("^BUTTON")    then base = base:gsub("^BUTTON", "M")
    end
    return mods .. base
end

local function KeyEffort(key)
    local e = 0
    if key:find("CTRL%-")  then e = e + 1 end
    if key:find("SHIFT%-") then e = e + 1 end
    if key:find("ALT%-")   then e = e + 1 end
    if key:find("META%-")  then e = e + 1 end
    return e
end

-- Stance/form paging: ACTIONBUTTON1-12 maps to a different slot range
-- depending on the current bonus-bar offset (driven by shapeshift/stance).
-- 0 = no form; 1-4 = bonus bars 1-4 (slots 73-120).
-- MULTIACTIONBAR1-7 slots are always reachable, independent of form.
local function GetCurrentFormOffset()
    if GetBonusBarOffset then
        local offset = GetBonusBarOffset()
        if IsPublic(offset) and type(offset) == "number" then return offset end
    end
    return 0
end

-- Form-paging filter: only the default UI's ACTIONBUTTON1-12 binding rotates
-- through different slots based on bonus-bar offset. Bindings without a
-- formOffset (MULTIACTIONBAR*, BT4Button*, Skyriding override) are always
-- reachable regardless of stance/form.
local function BindingReachableInForm(binding, formOffset)
    if formOffset == nil then return true end
    if binding.formOffset == nil then return true end
    return binding.formOffset == formOffset
end

-- Resolve a spell name to its spell ID. Tries the modern C_Spell API first
-- and falls back to the global GetSpellInfo for older clients.
local function GetSpellIDByName(name)
    if not name or name == "" then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(name)
        if info and info.spellID then return info.spellID end
    end
    if GetSpellInfo then
        local _, _, _, _, _, _, sid = GetSpellInfo(name)
        if sid then return sid end
    end
    return nil
end

-- Strip leading [conditional] groups and a leading "!" toggle from a /cast
-- option token, leaving just the spell-name portion.
local function CleanCastOption(option)
    option = option:gsub("^%s+", ""):gsub("%s+$", "")
    while option:match("^%[") do
        local stripped = option:gsub("^%[[^%]]*%]%s*", "", 1)
        if stripped == option then break end
        option = stripped
    end
    option = option:gsub("^!+", "")
    return option:gsub("^%s+", ""):gsub("%s+$", "")
end

-- Pull every spell ID referenced anywhere in a macro body, including those
-- gated by [form:N]/[stance:N]/[mod:...] conditionals. GetMacroSpell only
-- returns whichever option is active right now, so a form-conditional
-- "/cast [form:0] Wrath; [form:5] Starsurge" would otherwise show just one.
local function ParseMacroSpellIDs(body)
    local out = {}
    if not body or body == "" then return out end
    local seen = {}
    local function add(name)
        local sid = GetSpellIDByName(name)
        if sid and not seen[sid] then
            seen[sid] = true
            out[#out + 1] = sid
        end
    end
    for line in body:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", "")
        local cmd, rest = line:match("^/(%w+)%s+(.*)$")
        if cmd == "cast" or cmd == "use" then
            for option in rest:gmatch("[^;]+") do
                local name = CleanCastOption(option)
                if name ~= "" then add(name) end
            end
        elseif cmd == "castsequence" then
            -- Optional leading conditional, then optional "reset=...".
            while rest:match("^%[") do
                local stripped = rest:gsub("^%[[^%]]*%]%s*", "", 1)
                if stripped == rest then break end
                rest = stripped
            end
            rest = rest:gsub("^%s*reset=%S+%s*,?%s*", "")
            for token in rest:gmatch("[^,]+") do
                local name = token:gsub("^%s+", ""):gsub("%s+$", "")
                if name ~= "" then add(name) end
            end
        end
    end
    return out
end

-- Return every spell ID that an action slot can fire. Direct spell placements
-- yield one ID; macros may yield multiple if they use form/stance conditionals.
local function GetSpellsAtSlot(slot)
    local t, id = GetActionInfo(slot)
    if t == "spell" and id then
        return { id }
    elseif t == "macro" and id then
        local ids, seen = {}, {}
        local function add(sid)
            if sid and not seen[sid] then
                seen[sid] = true
                ids[#ids + 1] = sid
            end
        end
        if GetMacroSpell then add(GetMacroSpell(id)) end
        if GetMacroInfo then
            local _, _, body = GetMacroInfo(id)
            for _, parsedID in ipairs(ParseMacroSpellIDs(body)) do add(parsedID) end
        end
        return ids
    end
    return {}
end

-- Scan every action slot once and collect *every* distinct keybind that fires
-- each spell. A button can have multiple bindings, the same spell can sit on
-- multiple bars, and a single macro can route to multiple spells via form
-- conditionals, so we union everything and let the display present all paths.
--
-- Dead-binding filter: a key can be assigned to several binding commands but
-- only one actually fires. GetBindingKey returns every assignment regardless,
-- so we ask GetBindingAction which command wins for the key and skip the
-- shadowed ones (e.g. CTRL-SHIFT-2 assigned to both ACTIONBUTTON2 and
-- MULTIACTIONBAR5BUTTON2 — only one of those actually presses).
local cachedBindings = {}
local function BuildSpellBindingMap()
    -- Reports can be opened in combat. Use the last public snapshot rather
    -- than inspecting action slots or macro conditionals during lockdown.
    if InCombatLockdown() then return cachedBindings end
    local map = {}
    if not GetActionInfo then return map end
    for slot = 1, 180 do
        local sids = GetSpellsAtSlot(slot)
        if #sids > 0 then
            for _, candidate in ipairs(GetSlotBindingNames(slot)) do
                local bname = candidate.name
                local keys = { GetBindingKey(bname) }
                for _, key in ipairs(keys) do
                    if key and key ~= "" then
                        -- Pass checkOverride=true so addon-managed overrides
                        -- (Bartender, Dominos, ElvUI all use SetOverrideBinding*)
                        -- are honored. If an override redirects this key to a
                        -- different button, treat this slot's binding as dead.
                        --
                        -- Exception: replacement-bar addons commonly leave the
                        -- default binding in place AND add an override that
                        -- click-targets a proxy button for the same slot
                        -- (Bartender4: "CLICK BT4Button<slot>:Keybind"). That's
                        -- routing, not shadowing — the key still fires this
                        -- slot's action, so don't treat it as dead.
                        local actual = GetBindingAction and GetBindingAction(key, true)
                        local shadowed = false
                        if actual and actual ~= "" and actual ~= bname then
                            local proxySlot = actual:match("^CLICK BT4Button(%d+):")
                            proxySlot = proxySlot and tonumber(proxySlot) or nil
                            shadowed = proxySlot ~= slot
                        end
                        if not shadowed then
                            local compact = CompactBinding(key)
                            if compact then
                                local effort = KeyEffort(key)
                                for _, sid in ipairs(sids) do
                                    local list = map[sid]
                                    if not list then list = {}; map[sid] = list end
                                    local dup = false
                                    for _, b in ipairs(list) do
                                        if b.compact == compact and b.slot == slot then dup = true; break end
                                    end
                                    if not dup then
                                        list[#list + 1] = {
                                            compact    = compact,
                                            effort     = effort,
                                            slot       = slot,
                                            formOffset = candidate.formOffset,
                                        }
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    for _, list in pairs(map) do
        table.sort(list, function(a, b)
            if a.effort == b.effort then return a.compact < b.compact end
            return a.effort < b.effort
        end)
    end
    cachedBindings = map
    return map
end

local function FormatBindings(list)
    if not list or #list == 0 then return nil end
    local parts = {}
    for i, b in ipairs(list) do parts[i] = b.compact end
    return table.concat(parts, "/")
end

-- Pick the form (bonus-bar offset) the spell was cast in most often. Lets us
-- show the binding for the form the user actually uses, even if the spell
-- is *also* bound somewhere else for an out-of-form context the user never
-- actually presses (e.g. Druid Wrath bound to "6" in caster and "2" in
-- moonkin, but only ever cast in moonkin).
local function DominantFormOffset(formCasts, spellID)
    local entries = formCasts and formCasts[spellID]
    if not entries then return nil end
    local bestForm, bestCount
    for offset, count in pairs(entries) do
        if not bestCount or count > bestCount then
            bestForm, bestCount = offset, count
        end
    end
    return bestForm
end

-- Merge every binding that fires the tracked spell. Four layers, all filtered
-- by reachability in the spell's dominant form (so out-of-form bindings the
-- user never actually presses don't pollute the display):
--  1. Direct hit on the spellID itself.
--  2. Base/override expansion: a talent or aura may store one ID on the bar
--     while UNIT_SPELLCAST_SUCCEEDED fires another.
--  3. Name-based fallback: form-specific variants and talent reskins often
--     share a name but aren't linked via base/override.
local function MergeBindingsForSpell(map, spellID, formOffset)
    local merged, seen = {}, {}
    local function consume(list)
        if not list then return end
        for _, b in ipairs(list) do
            if BindingReachableInForm(b, formOffset) and not seen[b.compact] then
                seen[b.compact] = true
                merged[#merged + 1] = b
            end
        end
    end
    consume(map[spellID])
    if not InCombatLockdown() and C_Spell and C_Spell.GetBaseSpell then
        local base = C_Spell.GetBaseSpell(spellID)
        if IsPublic(base) and base and base ~= spellID then consume(map[base]) end
    end
    if not InCombatLockdown() and C_Spell and C_Spell.GetOverrideSpell then
        local over = C_Spell.GetOverrideSpell(spellID)
        if IsPublic(over) and over and over ~= spellID then consume(map[over]) end
    end
    local targetName = GetSpellName(spellID)
    if targetName then
        for otherID, list in pairs(map) do
            if otherID ~= spellID and GetSpellName(otherID) == targetName then
                consume(list)
            end
        end
    end
    if #merged == 0 then return nil end
    table.sort(merged, function(a, b)
        if a.effort == b.effort then return a.compact < b.compact end
        return a.effort < b.effort
    end)
    return merged
end

-- Aggregate by spell name: multiple spell IDs commonly share a name (talent
-- variants, proc-modified casts, etc.) and the user thinks of them as one
-- spell. Sum the counts, merge the per-form distribution, and pick the
-- highest-count variant as the canonical lookup ID for bindings.
local function SortedByCountDesc(tbl, formCasts)
    local bindings = BuildSpellBindingMap()
    local byName = {}
    for spellID, count in pairs(tbl) do
        local name = GetSpellName(spellID) or ("Spell " .. tostring(spellID))
        local agg = byName[name]
        if not agg then
            agg = { name = name, count = 0, primaryID = spellID, primaryCount = -1, mergedForms = {} }
            byName[name] = agg
        end
        agg.count = agg.count + count
        if count > agg.primaryCount then
            agg.primaryID = spellID
            agg.primaryCount = count
        end
        local rowForms = formCasts and formCasts[spellID]
        if rowForms then
            for offset, fc in pairs(rowForms) do
                agg.mergedForms[offset] = (agg.mergedForms[offset] or 0) + fc
            end
        end
    end
    local list = {}
    for _, agg in pairs(byName) do
        local dominant, bestCount
        for offset, c in pairs(agg.mergedForms) do
            if not bestCount or c > bestCount then
                bestCount, dominant = c, offset
            end
        end
        list[#list + 1] = {
            id      = agg.primaryID,
            count   = agg.count,
            name    = agg.name,
            binding = FormatBindings(MergeBindingsForSpell(bindings, agg.primaryID, dominant)),
        }
    end
    table.sort(list, function(a, b)
        if a.count == b.count then return a.name < b.name end
        return a.count > b.count
    end)
    return list
end

local function PrintCasts(header, casts, combatSeconds, limit, formCasts)
    Print(header)
    if not next(casts) then
        print("  No spells cast.")
        return
    end
    local sorted = SortedByCountDesc(casts, formCasts)
    local n = limit and math.min(limit, #sorted) or #sorted
    for i = 1, n do
        local s = sorted[i]
        print(string.format("  #%-2d [%-8s] %s: %d%s",
            i, s.binding or "--", s.name, s.count, FormatCPM(s.count, combatSeconds)))
    end
    if limit and #sorted > limit then
        print(string.format("  ... and %d more (use /sct for full list)", #sorted - limit))
    end
end

local function IsEnabled()
    return SpellCastTrackerCharDB.enabled
end

local function OnCombatStart()
    if inCombat then return end
    wipe(currentCombatCasts)
    wipe(currentCombatForms)
    skippedCasts = 0
    currentCombatSeconds = 0
    combatStartTime = IsEnabled() and GetTime() or nil
    inCombat = true
    if IsEnabled() then
        Print("Combat started! Tracking spell casts...")
    end
end

local function SaveCombatTime()
    if not combatStartTime then return 0 end
    local duration = math.max(0, GetTime() - combatStartTime)
    combatStartTime = GetTime()
    SpellCastTrackerCharDB.combatTime = (SpellCastTrackerCharDB.combatTime or 0) + duration
    SpellCastTrackerDB.combatTime = (SpellCastTrackerDB.combatTime or 0) + duration
    currentCombatSeconds = currentCombatSeconds + duration
    return duration
end

local function OnCombatEnd()
    if not inCombat then return end
    inCombat = false
    SaveCombatTime()
    local duration = currentCombatSeconds
    combatStartTime = nil
    if IsEnabled() then
        PrintCasts("Combat ended. Keybind activity this battle:",
            currentCombatCasts, duration, nil, currentCombatForms)
        if skippedCasts > 0 then
            Print(string.format("%d restricted cast(s) omitted; totals may be incomplete.", skippedCasts))
        end
    end
    UpdateLDB()
end

local function BumpForm(formMap, spellID, offset)
    local row = formMap[spellID]
    if not row then row = {}; formMap[spellID] = row end
    row[offset] = (row[offset] or 0) + 1
end

local function OnSpellCast(spellID)
    if not inCombat or not IsEnabled() then return end
    -- Never compare, stringify, or use a secret ID as a table key.
    if not IsPublic(spellID) then
        skippedCasts = skippedCasts + 1
        return
    end
    if type(spellID) ~= "number" or spellID <= 0 then return end
    if IGNORED_SPELL_IDS[spellID] then return end
    Bump(currentCombatCasts, spellID)
    Bump(SpellCastTrackerCharDB.totalCasts, spellID)
    Bump(SpellCastTrackerDB.totalCasts, spellID)
    local offset = GetCurrentFormOffset()
    BumpForm(currentCombatForms, spellID, offset)
    BumpForm(SpellCastTrackerCharDB.formCasts, spellID, offset)
    BumpForm(SpellCastTrackerDB.formCasts,     spellID, offset)
end

local function SetEnabled(state)
    if inCombat and state ~= IsEnabled() then
        SaveCombatTime()
        combatStartTime = state and GetTime() or nil
        wipe(currentCombatCasts)
        wipe(currentCombatForms)
        skippedCasts = 0
        currentCombatSeconds = 0
    end
    SpellCastTrackerCharDB.enabled = state and true or false
    if state then
        Print("Tracking |cff00ff00ON|r")
    else
        Print("Tracking |cffff5555OFF|r")
    end
    UpdateLDB()
end

local function ToggleEnabled()
    SetEnabled(not IsEnabled())
end

local function ShowCharTotals(limit)
    PrintCasts("Top keybinds by cast count (this character):",
        SpellCastTrackerCharDB.totalCasts,
        SpellCastTrackerCharDB.combatTime,
        limit,
        SpellCastTrackerCharDB.formCasts)
end

local function ShowAccountTotals()
    PrintCasts("Top keybinds by cast count (all characters):",
        SpellCastTrackerDB.totalCasts,
        SpellCastTrackerDB.combatTime,
        nil,
        SpellCastTrackerDB.formCasts)
end

local function ResetCharTotals()
    SaveCombatTime()
    SpellCastTrackerCharDB.totalCasts = {}
    SpellCastTrackerCharDB.combatTime = 0
    SpellCastTrackerCharDB.formCasts  = {}
    wipe(currentCombatCasts)
    wipe(currentCombatForms)
    currentCombatSeconds = 0
    Print("Character spell-cast totals have been reset.")
    UpdateLDB()
end

local function ResetAccountTotals()
    SaveCombatTime()
    SpellCastTrackerDB.totalCasts = {}
    SpellCastTrackerDB.combatTime = 0
    SpellCastTrackerDB.formCasts  = {}
    Print("Account-wide spell-cast totals have been reset.")
end

local function ShowHelp()
    Print("Commands:")
    print("  /sct             - show this character's totals")
    print("  /sct all         - show account-wide totals")
    print("  /sct on|off      - turn tracking on or off (this character)")
    print("  /sct toggle      - flip tracking state")
    print("  /sct reset       - clear this character's totals")
    print("  /sct reset all   - clear account-wide totals")
    print("  /sct debug [<name>] - dump action-slot/binding state (optionally filtered)")
    print("  /sct help        - show this help")
end

local function DebugDump(filter)
    if InCombatLockdown() then
        Print("Binding diagnostics are available after combat.")
        return
    end
    filter = filter and filter ~= "" and filter:lower() or nil
    Print("=== Debug dump ===")
    print(string.format("  Current bonus-bar offset: %d", GetCurrentFormOffset()))
    if filter then
        print(string.format("  Filter: spells matching '%s'", filter))
    end
    print("  -- Populated action slots --")
    if GetActionInfo then
        for slot = 1, 180 do
            local t, id = GetActionInfo(slot)
            if t and id then
                local spellIDs = GetSpellsAtSlot(slot)
                local names = {}
                for _, sid in ipairs(spellIDs) do
                    names[#names + 1] = string.format("%s(%d)", GetSpellName(sid) or "?", sid)
                end
                local nameStr = #names > 0 and table.concat(names, " | ") or "(no spell)"
                local matches = not filter or nameStr:lower():find(filter, 1, true)
                if matches then
                    local candidates = GetSlotBindingNames(slot)
                    local nameParts = {}
                    for _, c in ipairs(candidates) do nameParts[#nameParts + 1] = c.name end
                    local bnameStr = #nameParts > 0 and table.concat(nameParts, "+") or "?"
                    -- Union the keys across every binding name that fires this slot
                    -- (default + BT4Button + any other replacement-bar alias).
                    local keys, keySeen = {}, {}
                    for _, c in ipairs(candidates) do
                        for _, k in ipairs({ GetBindingKey(c.name) }) do
                            if k and k ~= "" and not keySeen[k] then
                                keySeen[k] = true
                                keys[#keys + 1] = k
                            end
                        end
                    end
                    local keyStr = #keys > 0 and table.concat(keys, ", ") or "(unbound)"
                    print(string.format("    slot %3d  %-30s  type=%-6s  keys=[%s]  %s",
                        slot, bnameStr, tostring(t), keyStr, nameStr))
                    -- For each key, show what it ACTUALLY fires (regular vs override).
                    -- A divergence means an addon (Bartender etc.) intercepts the key.
                    if GetBindingAction then
                        for _, key in ipairs(keys) do
                            local reg = GetBindingAction(key, false)
                            local ovr = GetBindingAction(key, true)
                            if (reg and reg ~= "") or (ovr and ovr ~= "") then
                                print(string.format("        key=%s  regular=%s  override=%s",
                                    key, tostring(reg), tostring(ovr)))
                            end
                        end
                    end
                end
            end
        end
    end
    print("  -- Binding-map entries --")
    local bindings = BuildSpellBindingMap()
    for sid, list in pairs(bindings) do
        local name = GetSpellName(sid) or ("Spell " .. tostring(sid))
        if not filter or name:lower():find(filter, 1, true) then
            local parts = {}
            for _, b in ipairs(list) do
                parts[#parts + 1] = string.format("%s[slot %d]", b.compact, b.slot)
            end
            print(string.format("    %s (%d): %s", name, sid, table.concat(parts, ", ")))
        end
    end
end

local function HandleSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" or msg == "total" then
        ShowCharTotals()
    elseif msg == "all" or msg == "total all" then
        ShowAccountTotals()
    elseif msg == "on" then
        SetEnabled(true)
    elseif msg == "off" then
        SetEnabled(false)
    elseif msg == "toggle" then
        ToggleEnabled()
    elseif msg == "reset" then
        ResetCharTotals()
    elseif msg == "reset all" then
        ResetAccountTotals()
    elseif msg == "debug" or msg:match("^debug%s") then
        DebugDump(msg:match("^debug%s+(.+)$"))
    elseif msg == "help" or msg == "?" then
        ShowHelp()
    else
        Print("Unknown command. Try /sct help.")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- COMBAT_LOG_EVENT_UNFILTERED was made private to addons in 12.0 (Midnight).
-- Only public player spell IDs are recorded; restricted payloads are skipped.
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            SpellCastTrackerDB.totalCasts     = SpellCastTrackerDB.totalCasts     or {}
            SpellCastTrackerDB.combatTime     = SpellCastTrackerDB.combatTime     or 0
            SpellCastTrackerDB.formCasts      = SpellCastTrackerDB.formCasts      or {}
            SpellCastTrackerCharDB.totalCasts = SpellCastTrackerCharDB.totalCasts or {}
            SpellCastTrackerCharDB.combatTime = SpellCastTrackerCharDB.combatTime or 0
            SpellCastTrackerCharDB.formCasts  = SpellCastTrackerCharDB.formCasts  or {}
            if SpellCastTrackerCharDB.enabled == nil then
                SpellCastTrackerCharDB.enabled = true
            end
            for sid in pairs(IGNORED_SPELL_IDS) do
                SpellCastTrackerDB.totalCasts[sid]     = nil
                SpellCastTrackerDB.formCasts[sid]      = nil
                SpellCastTrackerCharDB.totalCasts[sid] = nil
                SpellCastTrackerCharDB.formCasts[sid]  = nil
            end
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        BuildSpellBindingMap()
        if InCombatLockdown() then OnCombatStart() end
        Print("Loaded. Use /sct help for commands.")
        if next(SpellCastTrackerCharDB.totalCasts) then
            PrintCasts(string.format("Top %d keybinds on this character:", TOP_ON_LOGIN),
                SpellCastTrackerCharDB.totalCasts,
                SpellCastTrackerCharDB.combatTime,
                TOP_ON_LOGIN,
                SpellCastTrackerCharDB.formCasts)
        end
        UpdateLDB()
    elseif event == "PLAYER_LOGOUT" then
        SaveCombatTime()
        combatStartTime = nil
    elseif event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnSpellCast(spellID)
    end
end)

-- LibDataBroker feed (optional). If LibStub or LDB aren't embedded, this no-ops
-- and the rest of the addon works exactly as before. Users running an LDB
-- display addon (Bazooka, Titan Panel, ElvUI databars, etc.) get a click /
-- hover surface for free; users who don't run one pay no cost.
local LDB
do
    local ok, lib = pcall(function()
        return LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
    end)
    if ok and lib then LDB = lib end
end

local ldbObject
local function GetTopSpellSummary(casts, formCasts)
    if not next(casts) then return nil end
    return SortedByCountDesc(casts, formCasts)[1]
end

UpdateLDB = function()
    if not ldbObject then return end
    local prefix = IsEnabled() and "" or "|cffff5555[OFF]|r "
    local top = GetTopSpellSummary(SpellCastTrackerCharDB.totalCasts, SpellCastTrackerCharDB.formCasts)
    if top then
        ldbObject.text = string.format("%s[%s] %s (%d)", prefix, top.binding or "--", top.name, top.count)
    else
        ldbObject.text = prefix .. "no data"
    end
end

if LDB then
    ldbObject = LDB:NewDataObject("SpellCastTracker", {
        type    = "data source",
        text    = "no data",
        icon    = "Interface\\ICONS\\Spell_Holy_MagicalSentry",
        label   = "SpellCastTracker",
        OnClick = function(_, button)
            if button == "LeftButton" then
                ToggleEnabled()
            elseif button == "RightButton" then
                if IsShiftKeyDown() then
                    ShowAccountTotals()
                else
                    ShowCharTotals()
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("|cff00ff00SpellCastTracker|r")
            if IsEnabled() then
                tooltip:AddLine("Tracking |cff00ff00ON|r", 1, 1, 1)
            else
                tooltip:AddLine("Tracking |cffff5555OFF|r", 1, 1, 1)
            end
            tooltip:AddLine(" ")
            local sorted = SortedByCountDesc(SpellCastTrackerCharDB.totalCasts, SpellCastTrackerCharDB.formCasts)
            if #sorted == 0 then
                tooltip:AddLine("No casts recorded yet.", 1, 1, 1)
            else
                tooltip:AddLine("Top keybinds (this character):", 1, 1, 1)
                local seconds = SpellCastTrackerCharDB.combatTime
                for i = 1, math.min(TOP_ON_LOGIN, #sorted) do
                    local s = sorted[i]
                    tooltip:AddDoubleLine(
                        string.format("#%d  [%s]  %s", i, s.binding or "--", s.name),
                        string.format("%d%s", s.count, FormatCPM(s.count, seconds)),
                        1, 1, 1, 1, 1, 1)
                end
            end
            tooltip:AddLine(" ")
            tooltip:AddLine("|cffaaaaaaLeft-click:|r toggle tracking", 0.7, 0.7, 1)
            tooltip:AddLine("|cffaaaaaaRight-click:|r this character's totals", 0.7, 0.7, 1)
            tooltip:AddLine("|cffaaaaaaShift+Right-click:|r account-wide totals", 0.7, 0.7, 1)
        end,
    })
end

SLASH_SPELLCASTTRACKER1 = "/sct"
SLASH_SPELLCASTTRACKER2 = "/spellcasttracker"
SlashCmdList["SPELLCASTTRACKER"] = HandleSlash

-- Legacy aliases documented in the addon description. The use case is
-- per-character keybind tuning, so they map to the per-character view.
SLASH_SCTOTAL1 = "/sctotal"
SLASH_SCTOTAL2 = "/spellcasttotal"
SlashCmdList["SCTOTAL"] = function() ShowCharTotals() end

SLASH_SCRESET1 = "/screset"
SLASH_SCRESET2 = "/spellcastreset"
SlashCmdList["SCRESET"] = ResetCharTotals
