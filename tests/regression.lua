local output, frames = {}, {}
local realPrint = print
print = function(message) output[#output + 1] = tostring(message) end
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
SlashCmdList = {}
local now, combat, scans = 0, false, 0
GetTime = function() return now end
InCombatLockdown = function() return combat end
GetBonusBarOffset = function() return 0 end
local secret = setmetatable({}, { __tostring = function() error("secret stringified") end })
issecretvalue = function(v) return rawequal(v, secret) end
C_Spell = {
    GetSpellName = function(id) return id == 101 and "Test spell" or "Spell " .. id end,
    GetBaseSpell = function(id) return id end,
    GetOverrideSpell = function(id) return id end,
}
GetActionInfo = function(slot)
    assert(not combat, "action scan during combat")
    scans = scans + 1
    if slot == 1 then return "spell", 101 end
end
GetBindingKey = function(binding) if binding == "ACTIONBUTTON1" then return "CTRL-1" end end
GetBindingAction = function() return "ACTIONBUTTON1" end
CreateFrame = function()
    local f = {}
    function f:RegisterEvent() end
    function f:RegisterUnitEvent(event, unit) assert(unit == "player") end
    function f:UnregisterEvent() end
    function f:SetScript(_, fn) self.onEvent = fn end
    frames[#frames + 1] = f
    return f
end
-- Load the actual bundled dependency chain, as WoW does from the TOC.
dofile("Libs/LibStub/LibStub.lua")
dofile("Libs/CallbackHandler-1.0/CallbackHandler-1.0.lua")
dofile("Libs/LibDataBroker-1.1/LibDataBroker-1.1.lua")
assert(loadfile("SpellCastTracker.lua"))("SpellCastTracker")
local function event(name, ...) frames[1].onEvent(frames[1], name, ...) end
local function cast(id) event("UNIT_SPELLCAST_SUCCEEDED", "player", "unused", id) end
local slash = SlashCmdList.SPELLCASTTRACKER
event("ADDON_LOADED", "SpellCastTracker")
event("PLAYER_LOGIN")
cast(101)
assert(not SpellCastTrackerCharDB.totalCasts[101], "out of combat cast recorded")
combat = true
event("PLAYER_REGEN_DISABLED")
cast(101); cast(75); cast(6603); cast(nil); cast(secret)
assert(SpellCastTrackerCharDB.totalCasts[101] == 1)
assert(not SpellCastTrackerCharDB.totalCasts[75])
assert(not SpellCastTrackerCharDB.totalCasts[secret])
local previousScans = scans
slash(""); slash("debug")
assert(scans == previousScans, "report scanned protected state")
now = 10
slash("off")
assert(SpellCastTrackerCharDB.combatTime == 10)
now = 20
cast(101)
slash("on")
now = 25
cast(101)
cast(secret)
combat = false
event("PLAYER_REGEN_ENABLED")
assert(SpellCastTrackerCharDB.totalCasts[101] == 2)
assert(SpellCastTrackerCharDB.combatTime == 15, "disabled time included")
event("PLAYER_REGEN_ENABLED")
assert(SpellCastTrackerCharDB.combatTime == 15, "duplicate end double counted")
local log = table.concat(output, "\n")
assert(log:find("restricted cast(s) omitted", 1, true))
assert(log:find("C1", 1, true), "keybind feature lost")
now = 30; combat = true; event("PLAYER_REGEN_DISABLED")
now = 35; cast(101); slash("reset")
assert(SpellCastTrackerCharDB.combatTime == 0)
now = 40; cast(101); event("PLAYER_LOGOUT")
assert(SpellCastTrackerCharDB.totalCasts[101] == 1)
assert(SpellCastTrackerCharDB.combatTime == 5)
assert(SpellCastTrackerDB.combatTime == 25)
-- Reloading while fighting must resume tracking and preserve saved totals.
assert(loadfile("SpellCastTracker.lua"))("SpellCastTracker")
frames[2].onEvent(frames[2], "ADDON_LOADED", "SpellCastTracker")
frames[2].onEvent(frames[2], "PLAYER_LOGIN")
now = 45; combat = false
frames[2].onEvent(frames[2], "PLAYER_REGEN_ENABLED")
assert(SpellCastTrackerCharDB.combatTime == 10)
realPrint("SpellCastTracker regression checks passed")
