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
        if name then return name end
    end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellID)
        if info and info.name then return info.name end
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

local function SortedByCountDesc(tbl)
    local list = {}
    for spellID, count in pairs(tbl) do
        list[#list + 1] = { id = spellID, count = count, name = GetSpellName(spellID) }
    end
    table.sort(list, function(a, b)
        if a.count == b.count then return a.name < b.name end
        return a.count > b.count
    end)
    return list
end

local function PrintCasts(header, casts, combatSeconds, limit)
    Print(header)
    if not next(casts) then
        print("  No spells cast.")
        return
    end
    local sorted = SortedByCountDesc(casts)
    local n = limit and math.min(limit, #sorted) or #sorted
    for i = 1, n do
        local s = sorted[i]
        print(string.format("  %s: %d%s", s.name, s.count, FormatCPM(s.count, combatSeconds)))
    end
    if limit and #sorted > limit then
        print(string.format("  ... and %d more (use /sct for full list)", #sorted - limit))
    end
end

local function OnCombatStart()
    wipe(currentCombatCasts)
    combatStartTime = GetTime()
    inCombat = true
    Print("Combat started! Tracking spell casts...")
end

local function OnCombatEnd()
    inCombat = false
    local duration = combatStartTime and (GetTime() - combatStartTime) or 0
    SpellCastTrackerCharDB.combatTime = (SpellCastTrackerCharDB.combatTime or 0) + duration
    SpellCastTrackerDB.combatTime     = (SpellCastTrackerDB.combatTime     or 0) + duration
    PrintCasts("Combat ended. Spells cast this battle:", currentCombatCasts, duration)
    combatStartTime = nil
    UpdateLDB()
end

local function OnSpellCast(spellID)
    if not inCombat then return end
    Bump(currentCombatCasts, spellID)
    Bump(SpellCastTrackerCharDB.totalCasts, spellID)
    Bump(SpellCastTrackerDB.totalCasts, spellID)
end

local function ShowCharTotals(limit)
    PrintCasts("Total spell casts (this character):",
        SpellCastTrackerCharDB.totalCasts,
        SpellCastTrackerCharDB.combatTime,
        limit)
end

local function ShowAccountTotals()
    PrintCasts("Total spell casts (all characters):",
        SpellCastTrackerDB.totalCasts,
        SpellCastTrackerDB.combatTime)
end

local function ResetCharTotals()
    SpellCastTrackerCharDB.totalCasts = {}
    SpellCastTrackerCharDB.combatTime = 0
    Print("Character spell-cast totals have been reset.")
    UpdateLDB()
end

local function ResetAccountTotals()
    SpellCastTrackerDB.totalCasts = {}
    SpellCastTrackerDB.combatTime = 0
    Print("Account-wide spell-cast totals have been reset.")
end

local function ShowHelp()
    Print("Commands:")
    print("  /sct             - show this character's totals")
    print("  /sct all         - show account-wide totals")
    print("  /sct reset       - clear this character's totals")
    print("  /sct reset all   - clear account-wide totals")
    print("  /sct help        - show this help")
end

local function HandleSlash(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" or msg == "total" then
        ShowCharTotals()
    elseif msg == "all" or msg == "total all" then
        ShowAccountTotals()
    elseif msg == "reset" then
        ResetCharTotals()
    elseif msg == "reset all" then
        ResetAccountTotals()
    elseif msg == "help" or msg == "?" then
        ShowHelp()
    else
        Print("Unknown command. Try /sct help.")
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- COMBAT_LOG_EVENT_UNFILTERED was made private to addons in 12.0 (Midnight).
-- UNIT_SPELLCAST_SUCCEEDED on the "player" unit gives us the same data we need
-- (spellID for our own successful casts) without touching the restricted log.
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            SpellCastTrackerDB.totalCasts     = SpellCastTrackerDB.totalCasts     or {}
            SpellCastTrackerDB.combatTime     = SpellCastTrackerDB.combatTime     or 0
            SpellCastTrackerCharDB.totalCasts = SpellCastTrackerCharDB.totalCasts or {}
            SpellCastTrackerCharDB.combatTime = SpellCastTrackerCharDB.combatTime or 0
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        Print("Loaded. Use /sct help for commands.")
        if next(SpellCastTrackerCharDB.totalCasts) then
            PrintCasts(string.format("Top %d casts on this character:", TOP_ON_LOGIN),
                SpellCastTrackerCharDB.totalCasts,
                SpellCastTrackerCharDB.combatTime,
                TOP_ON_LOGIN)
        end
        UpdateLDB()
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
local function GetTopSpellSummary(casts)
    if not next(casts) then return nil end
    local top = SortedByCountDesc(casts)[1]
    return top.name, top.count
end

UpdateLDB = function()
    if not ldbObject then return end
    local topName, topCount = GetTopSpellSummary(SpellCastTrackerCharDB.totalCasts)
    if topName then
        ldbObject.text = string.format("%s (%d)", topName, topCount)
    else
        ldbObject.text = "no data"
    end
end

if LDB then
    ldbObject = LDB:NewDataObject("SpellCastTracker", {
        type    = "data source",
        text    = "no data",
        icon    = "Interface\\ICONS\\Spell_Holy_MagicalSentry",
        label   = "SpellCastTracker",
        OnClick = function(_, button)
            if button == "RightButton" then
                ShowAccountTotals()
            else
                ShowCharTotals()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("|cff00ff00SpellCastTracker|r")
            tooltip:AddLine(" ")
            local sorted = SortedByCountDesc(SpellCastTrackerCharDB.totalCasts)
            if #sorted == 0 then
                tooltip:AddLine("No casts recorded yet.", 1, 1, 1)
            else
                tooltip:AddLine("Top casts (this character):", 1, 1, 1)
                local seconds = SpellCastTrackerCharDB.combatTime
                for i = 1, math.min(TOP_ON_LOGIN, #sorted) do
                    local s = sorted[i]
                    tooltip:AddDoubleLine(
                        s.name,
                        string.format("%d%s", s.count, FormatCPM(s.count, seconds)),
                        1, 1, 1, 1, 1, 1)
                end
            end
            tooltip:AddLine(" ")
            tooltip:AddLine("|cffaaaaaaLeft-click:|r this character's totals", 0.7, 0.7, 1)
            tooltip:AddLine("|cffaaaaaaRight-click:|r account-wide totals", 0.7, 0.7, 1)
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
