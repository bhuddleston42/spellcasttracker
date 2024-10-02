-- SpellCastTracker.lua

-- Initialize the saved variables table
SpellCastTrackerDB = SpellCastTrackerDB or {}
SpellCastTrackerDB.totalCasts = SpellCastTrackerDB.totalCasts or {}

-- Initialize current combat casts
local currentCombatCasts = {}

-- Create the main frame
local frame = CreateFrame("Frame")

-- Function to reset current combat casts
local function ResetCurrentCombatCasts()
    currentCombatCasts = {}
end

-- Function to handle combat start
local function OnCombatStart()
    ResetCurrentCombatCasts()
    print("|cff00ff00[SpellCastTracker]|r Combat started! Tracking spell casts...")
end

-- Helper function to sort spells by count in descending order
local function SortSpellsByCount(spellTable)
    local sortedSpells = {}
    for spellName, count in pairs(spellTable) do
        table.insert(sortedSpells, {name = spellName, count = count})
    end
    table.sort(sortedSpells, function(a, b) return a.count > b.count end)
    return sortedSpells
end

-- Function to handle combat end
local function OnCombatEnd()
    print("|cff00ff00[SpellCastTracker]|r Combat ended. Spells cast this battle:")
    if next(currentCombatCasts) == nil then
        print("  No spells cast during this combat.")
    else
        -- Sort the spells by count
        local sortedSpells = SortSpellsByCount(currentCombatCasts)
        for _, spell in ipairs(sortedSpells) do
            print(string.format("  %s: %d", spell.name, spell.count))
        end
    end
end

-- Function to handle combat log events
local function OnCombatLogEvent()
    local timestamp, subEvent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags, spellId, spellName = CombatLogGetCurrentEventInfo()

    -- We're interested in successful spell casts by the player
    if subEvent == "SPELL_CAST_SUCCESS" and sourceGUID == UnitGUID("player") then
        -- Increment current combat cast count
        if currentCombatCasts[spellName] then
            currentCombatCasts[spellName] = currentCombatCasts[spellName] + 1
        else
            currentCombatCasts[spellName] = 1
        end

        -- Increment total cast count
        if SpellCastTrackerDB.totalCasts[spellName] then
            SpellCastTrackerDB.totalCasts[spellName] = SpellCastTrackerDB.totalCasts[spellName] + 1
        else
            SpellCastTrackerDB.totalCasts[spellName] = 1
        end

        -- Optional: Debug print to verify tracking
        -- print(string.format("[Debug] Cast detected: %s", spellName))
    end
end

-- Function to display total spell casts
local function ShowTotalCasts()
    print("|cff00ff00[SpellCastTracker]|r Total spell casts:")
    if next(SpellCastTrackerDB.totalCasts) == nil then
        print("  No spells cast yet.")
    else
        -- Sort the spells by count
        local sortedSpells = SortSpellsByCount(SpellCastTrackerDB.totalCasts)
        for _, spell in ipairs(sortedSpells) do
            print(string.format("  %s: %d", spell.name, spell.count))
        end
    end
end

-- Function to reset total spell casts
local function ResetTotalCasts()
    SpellCastTrackerDB.totalCasts = {}
    print("|cff00ff00[SpellCastTracker]|r Total spell casts have been reset.")
end

-- Register events
frame:RegisterEvent("PLAYER_REGEN_DISABLED") -- Combat starts
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- Combat ends
frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED") -- Combat log updates

-- Set the script for handling events
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_REGEN_DISABLED" then
        OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        OnCombatEnd()
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
    end
end)

-- Define slash commands
SLASH_SPELLCASTTRACKER1 = "/sctotal"
SLASH_SPELLCASTTRACKER2 = "/spellcasttotal"
SlashCmdList["SPELLCASTTRACKER"] = ShowTotalCasts

SLASH_SPELLCASTTRACKERRESET1 = "/screset"
SLASH_SPELLCASTTRACKERRESET2 = "/spellcastreset"
SlashCmdList["SPELLCASTTRACKERRESET"] = ResetTotalCasts

-- Optional: Notify addon loaded
print("|cff00ff00[SpellCastTracker]|r Loaded successfully! Use /sctotal to view total casts.")
