-- Loot Alert: warns you when your group's loot is set to Free for All, like a boss-mod alert:
-- big text in the middle of the screen, the raid-warning sound and a chat line. Only in dungeons
-- and raids, and only while you're in a party or raid group. If you're the group leader it offers
-- to switch to Group Loot.
local ADDON = ...

local DEFAULTS = {
  enabled = true,
  sound = true,
  screen = true,        -- big text in the middle of the screen
  offer = true,         -- leader: offer to switch to Group Loot
  onPull = true,        -- warn again when a boss is pulled
  roundRobin = false,   -- also warn for Round Robin
}

-- Enum.LootMethod on this client: 0 Free for All, 1 Round Robin, 2 Master Looter, 3 Group, 4 Need before Greed, 5 Personal
local LM = Enum and Enum.LootMethod or {}
local FFA = LM.Freeforall or 0
local ROUND_ROBIN = LM.Roundrobin or 1
local GROUP = LM.Group or 3
local OLD_NAMES = { freeforall = FFA, roundrobin = ROUND_ROBIN, master = 2, group = GROUP, needbeforegreed = 4, personal = 5 }
local NAMES = { [FFA] = "Free for All", [ROUND_ROBIN] = "Round Robin" }

local DB
local lastKey          -- the situation we last warned about, so the same one isn't repeated
local RegisterSettings -- the settings page, defined at the end
local settingFor = {}

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD100Loot Alert:|r " .. msg)
end

local function SetOption(key, value)
  local setting = settingFor[key]
  if setting and setting.SetValue and pcall(setting.SetValue, setting, value) and DB[key] == value then return end
  DB[key] = value
end

----------------------------------------------------------------------
-- The loot method
----------------------------------------------------------------------
local function Method()
  if C_PartyInfo and C_PartyInfo.GetLootMethod then
    local ok, m = pcall(C_PartyInfo.GetLootMethod)
    if ok and type(m) == "number" then return m end
  end
  if GetLootMethod then
    local ok, m = pcall(GetLootMethod)
    if ok and type(m) == "string" then return OLD_NAMES[m] end
  end
end

local function IsLeader()
  return UnitIsGroupLeader and UnitIsGroupLeader("player") or false
end

local function SetGroupLoot()
  if not IsLeader() then return Print("only the group leader can change the loot method.") end
  local ok
  if C_PartyInfo and C_PartyInfo.SetLootMethod then ok = pcall(C_PartyInfo.SetLootMethod, GROUP)
  elseif SetLootMethod then ok = pcall(SetLootMethod, "group") end
  if not ok then Print("couldn't change the loot method; right-click your portrait > Loot > Group Loot.") end
end

-- The group's loot method if it's one to warn about (in a group, Loot Alert on), else nil.
local function BadMethodAnywhere()
  if not (DB.enabled and IsInGroup()) then return nil end
  local m = Method()
  if m == FFA or (m == ROUND_ROBIN and DB.roundRobin) then return m end
end

-- Only inside a dungeon or raid instance.
local function InScope()
  local inInstance, kind = IsInInstance()
  return inInstance and (kind == "party" or kind == "raid") or false
end

-- The loot method to warn about here and now, or nil.
local function BadMethod()
  local m = BadMethodAnywhere()
  if m and InScope() then return m end
end

----------------------------------------------------------------------
-- The warning
----------------------------------------------------------------------
local declined      -- the leader clicked "Keep it": no more offers or pull reminders until the loot method or group changes
local offerWaiting  -- an offer held back until combat ends

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs.LOOTALERT_CHANGE = {
  text = "Loot is set to %s.\nChange it to Group Loot?",
  button1 = "Group Loot",
  button2 = "Keep it",
  OnAccept = function() SetGroupLoot() end,
  OnCancel = function(_, _, reason) if reason == "clicked" then declined = true end end,
  timeout = 60,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
}

local function ShowCenter(text)
  local color = ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.3, b = 0.1 }
  if RaidWarningUtil and RaidWarningUtil.AddMessage then
    if pcall(RaidWarningUtil.AddMessage, text, color) then return end
  end
  if RaidNotice_AddMessage and RaidWarningFrame then pcall(RaidNotice_AddMessage, RaidWarningFrame, text, color) end
end

-- The leader's offer to switch to Group Loot. Never in combat: it waits until combat ends.
local function Offer(m, test)
  if not (DB.offer and StaticPopup_Show) then return end
  if not test and (declined or not IsLeader()) then return end
  if InCombatLockdown and InCombatLockdown() then offerWaiting = true; return end
  offerWaiting = false
  StaticPopup_Show("LOOTALERT_CHANGE", NAMES[m] or "Free for All")
end

local function HideOffer()
  offerWaiting = false
  if StaticPopup_Hide then pcall(StaticPopup_Hide, "LOOTALERT_CHANGE") end
end

-- pull: the boss-pull reminder, which never brings the offer
local function Warn(m, test, pull)
  local name = NAMES[m] or "Free for All"
  local text = "Loot is set to " .. name .. "!"
  if DB.screen then ShowCenter(text) end
  if DB.sound and PlaySound then pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master") end
  Print("|cFFFF5555" .. text .. "|r" .. (IsLeader() and "" or " Ask the group leader to change it."))
  if not pull then Offer(m, test) end
end

-- The situation we warn about once: this instance (or world) and this loot method.
local function Key(m)
  local _, _, _, _, _, _, _, instanceID = GetInstanceInfo()
  return tostring(instanceID or 0) .. ":" .. m
end

local function Check()
  local m = BadMethodAnywhere()
  if not m then -- the loot is fine now (or no group): start over
    lastKey, declined = nil, nil
    HideOffer()
    return
  end
  if not InScope() then return end -- e.g. outside the dungeon after a wipe: keep what we warned about
  local key = Key(m)
  if key == lastKey then return end
  lastKey = key
  Warn(m)
end

local function OnPull()
  local m = BadMethod()
  if m and not declined then Warn(m, false, true) end
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local checkSoon
local function CheckSoon() -- the loot method arrives a moment after zoning or joining
  if checkSoon then return end
  checkSoon = true
  C_Timer.After(2, function() checkSoon = false; Check() end)
end

local f = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE", "GROUP_JOINED", "GROUP_LEFT",
  "PARTY_LOOT_METHOD_CHANGED", "PARTY_LEADER_CHANGED", "ENCOUNTER_START", "ZONE_CHANGED_NEW_AREA",
  "PLAYER_REGEN_ENABLED" }) do pcall(f.RegisterEvent, f, e) end
f:SetScript("OnEvent", function(_, event, a1)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON then return end
    LootAlertDB = LootAlertDB or {}
    DB = LootAlertDB
    for k, v in pairs(DEFAULTS) do if DB[k] == nil then DB[k] = v end end
    DB.where = nil -- an old option: Loot Alert now only warns in dungeons and raids
    local ok, err = pcall(RegisterSettings)
    if not ok then Print("couldn't add the settings page: " .. tostring(err)) end
    return
  end
  if not DB then return end
  if event == "ENCOUNTER_START" then
    if DB.onPull then OnPull() end
  elseif event == "PARTY_LEADER_CHANGED" then -- you may be the leader now, and able to fix it
    local m = BadMethod()
    if m and lastKey then Offer(m) end
    CheckSoon()
  elseif event == "PLAYER_REGEN_ENABLED" then -- combat over: show an offer that was held back
    local m = offerWaiting and BadMethod()
    if m then Offer(m) end
  else
    CheckSoon()
  end
end)

----------------------------------------------------------------------
-- Settings page: Esc > Options > AddOns > Loot Alert
----------------------------------------------------------------------
local OPTIONS = {
  { "enabled", "boolean", "Enable Loot Alert", "Warns you in dungeons and raids, while you're in a group, when the loot is Free for All. When it's off you get no warnings and the options below are greyed out." },
  { "screen", "boolean", "Big text on screen", "Shows the warning in the middle of the screen, like a raid warning." },
  { "sound", "boolean", "Warning sound", "Plays the raid-warning sound." },
  { "offer", "boolean", "Offer to switch to Group Loot", "When you're the group leader, a window offers to change the loot to Group Loot." },
  { "onPull", "boolean", "Warn again when a boss is pulled", "If the loot is still Free for All when a boss fight starts, warn again." },
  { "roundRobin", "boolean", "Also warn for Round Robin", "Round Robin hands each corpse's loot to one player in turn, so you may want a warning for it too." },
}

local category
function RegisterSettings()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
  category = Settings.RegisterVerticalLayoutCategory("Loot Alert")
  local master
  local function IsOn() return DB.enabled end
  for _, o in ipairs(OPTIONS) do
    local key, kind, label, tip = unpack(o)
    local setting = Settings.RegisterAddOnSetting(category, "LootAlert_" .. key, key, DB, kind, label, DEFAULTS[key])
    settingFor[key] = setting
    local init = Settings.CreateCheckbox(category, setting, tip)
    if key == "enabled" then
      master = init
    elseif master and type(init) == "table" and init.SetParentInitializer then
      pcall(init.SetParentInitializer, init, master, IsOn)
    end
  end
  local layout = SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(category)
  if layout and CreateSettingsButtonInitializer then
    layout:AddInitializer(CreateSettingsButtonInitializer("Try it", "Test warning",
      function() Warn(FFA, true) end, "Shows the warning as if loot were Free for All.", true))
  end
  Settings.RegisterAddOnCategory(category)
end

local function OpenSettings()
  if category and Settings and Settings.OpenToCategory and pcall(Settings.OpenToCategory, category:GetID()) then return true end
end

----------------------------------------------------------------------
-- /lootalert
----------------------------------------------------------------------
local function OnOff(v) return v and "|cFF55FF55on|r" or "|cFFFF5555off|r" end
local function CurrentName()
  local m = Method()
  local names = { [0] = "Free for All", "Round Robin", "Master Looter", "Group Loot", "Need before Greed", "Personal" }
  return IsInGroup() and (names[m] or "unknown") or "not in a group"
end

local function Help()
  Print(string.format("%s (in dungeons and raids, while in a group). Loot right now: %s.", OnOff(DB.enabled), CurrentName()))
  print("  /lootalert                  settings window")
  print("  /lootalert on | off         turn warnings on or off")
  print("  /lootalert test             show the warning")
  print("  /lootalert check            check the loot method now")
  print("  /lootalert group            set Group Loot (group leader only)")
end

SLASH_LOOTALERT1, SLASH_LOOTALERT2 = "/lootalert", "/lalert"
SlashCmdList.LOOTALERT = function(msg)
  local cmd = (msg or ""):lower():match("^%s*(%S*)")
  if cmd == "on" or cmd == "off" then
    SetOption("enabled", cmd == "on")
    Print(DB.enabled and "warnings on." or "warnings off.")
    if DB.enabled then lastKey, declined = nil, nil; Check() end
  elseif cmd == "test" then
    Warn(FFA, true)
  elseif cmd == "check" then
    local m = BadMethod()
    if m then
      lastKey = Key(m); Warn(m)
    elseif IsInGroup() and not InScope() then
      Print("loot right now: " .. CurrentName() .. ". Loot Alert only warns inside dungeons and raids.")
    else
      Print("loot right now: " .. CurrentName() .. ". Nothing to warn about.")
    end
  elseif cmd == "group" then
    SetGroupLoot()
  elseif cmd == "" or cmd == "settings" or cmd == "options" then
    if not OpenSettings() then Help() end
  else
    Help()
  end
end
