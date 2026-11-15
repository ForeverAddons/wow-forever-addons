-- Boss Report: after each boss kill, posts the top damage and healing to party or raid chat.
-- The numbers come from the game's built-in damage meter (C_DamageMeter), the same data the
-- Details! window shows on WoW Forever. While you're in combat the game hides those numbers
-- from addons, so the report waits until combat has ended.
local ADDON = ...

local DEFAULTS = {
  enabled = true,
  damage = true,
  heal = true,
  lines = 5,
  channel = "auto", -- auto (raid or party, else only you), party, raid, guild, say, self
  wipes = false,
  oneMessage = true, -- the whole report in one chat message, instead of a line per player
}
local CHANNELS = { auto = true, party = true, raid = true, guild = true, say = true, self = true }
local PREFIX = "BossReport"
local POLL, MAX_WAIT = 0.5, 90  -- seconds between checks for the numbers, and how long to wait at most
local LINE_GAP = 0.2            -- seconds between chat lines, so the server doesn't drop any

local DM = C_DamageMeter
local DAMAGE = Enum and Enum.DamageMeterType and Enum.DamageMeterType.DamageDone or 0
local HEALING = Enum and Enum.DamageMeterType and Enum.DamageMeterType.HealingDone or 2
local CURRENT = Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current or 1

local DB
local lastEncounter   -- { name, killed, sessionID } of the last boss fight, for /breport test and now
local pending         -- the boss report waiting to be posted
local claimed = {}    -- [encounter key] = true once someone in the group said they're posting it
local RegisterSettings -- the settings page, defined at the end
local settingFor = {}  -- [key] = the settings-page setting, so chat commands update the open page too

-- Change an option. Through the settings page when it exists, so an open page shows the change.
local function SetOption(key, value)
  local setting = settingFor[key]
  if setting and setting.SetValue and pcall(setting.SetValue, setting, value) and DB[key] == value then return end
  DB[key] = value
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFFFFD100Boss Report:|r " .. msg)
end

local function Secret(v)
  return issecretvalue and issecretvalue(v) or false
end

local function Short(n)
  n = math.floor(n + 0.5)
  if n >= 999500 then return string.format("%.2fM", n / 1e6) end
  if n >= 9950 then return string.format("%.1fk", n / 1e3) end
  return tostring(n)
end

local function Clock(sec)
  sec = math.floor(sec + 0.5)
  return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

----------------------------------------------------------------------
-- Reading the built-in damage meter
----------------------------------------------------------------------
local function Sessions()
  local ok, list = pcall(DM.GetAvailableCombatSessions)
  return ok and type(list) == "table" and list or {}
end

-- The session of a fight: the newest one with this name (the meter names sessions after the
-- boss or enemy), else the newest one.
local function FindSession(name)
  local list = Sessions()
  if name then
    for i = #list, 1, -1 do
      local s = list[i]
      if not Secret(s.name) and s.name == name then return s.sessionID end
    end
  end
  return list[#list] and list[#list].sessionID
end

local function GetSession(sessionID, kind)
  local ok, s
  if sessionID then ok, s = pcall(DM.GetCombatSessionFromID, sessionID, kind)
  else ok, s = pcall(DM.GetCombatSessionFromType, CURRENT, kind) end
  return ok and type(s) == "table" and s or nil
end

-- true while the game still hides the session's numbers (you or the group are in combat)
local function Hidden(session)
  local first = session and session.combatSources and session.combatSources[1]
  return first ~= nil and (Secret(first.name) or Secret(first.totalAmount))
end

local function ShortName(name)
  return name:match("^[^%-]+") or name
end

-- Group members with an amount, highest first, from one meter session.
local function Top(session)
  local list = {}
  for _, src in ipairs(session and session.combatSources or {}) do
    local name, total = src.name, src.totalAmount
    if not Secret(name) and not Secret(total) and type(total) == "number" and total > 0
      and src.sourceDisplayType ~= 2 then -- 2 = Enemy
      list[#list + 1] = { name = ShortName(name), total = total }
    end
  end
  table.sort(list, function(a, b) return a.total > b.total end)
  return list
end

local function Section(lines, session, label, rate, seconds)
  local list = Top(session)
  if #list == 0 then return end
  local sum = 0
  for _, e in ipairs(list) do sum = sum + e.total end
  lines[#lines + 1] = string.format("%s (%s total):", label, Short(sum))
  for i = 1, math.min(DB.lines, #list) do
    local e = list[i]
    lines[#lines + 1] = string.format("%d. %s %s (%s %s, %d%%)", i, e.name, Short(e.total), Short(e.total / seconds), rate,
      math.floor(e.total / sum * 100 + 0.5))
  end
end

local function Duration(sessionID, damage, heal)
  local d = (damage and damage.durationSeconds) or (heal and heal.durationSeconds)
  if (not d or Secret(d)) and sessionID then
    for _, s in ipairs(Sessions()) do if s.sessionID == sessionID then d = s.durationSeconds end end
  end
  if not d or Secret(d) then
    local ok, v = pcall(DM.GetSessionDurationSeconds, CURRENT)
    d = ok and v or nil
  end
  if type(d) ~= "number" or Secret(d) then return 1 end
  return math.max(d, 1)
end

-- The report lines for a fight, or nil (nothing to report) and true when the numbers are still hidden.
-- One chat message (the game allows 255 characters):
--   Hogger down in 2:05 - Damage (dps): 1. Mage 90.0k (720) 2. Rogue 75.0k (600) - Healing (hps): 1. Priest 40.0k (320)
-- If it's too long, the lowest players are left out, then the per-second numbers, until it fits.
local MAX_MSG = 255

local function CutBytes(s, n) -- shorten to n bytes without splitting a UTF-8 character
  if #s <= n then return s end
  local cut = n
  while cut > 0 and s:byte(cut + 1) and s:byte(cut + 1) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
  return s:sub(1, cut)
end

local function OneMessage(header, sections, seconds)
  local function Build(withRate)
    local parts = { header }
    for _, sec in ipairs(sections) do
      local items = {}
      for i = 1, sec.count do
        local e = sec.list[i]
        items[i] = withRate and string.format("%d. %s %s (%s)", i, e.name, Short(e.total), Short(e.total / seconds))
          or string.format("%d. %s %s", i, e.name, Short(e.total))
      end
      parts[#parts + 1] = (withRate and sec.label .. " (" .. sec.rate .. "): " or sec.label .. ": ") .. table.concat(items, " ")
    end
    return table.concat(parts, " - ")
  end
  local msg = Build(true)
  while #msg > MAX_MSG do -- leave out the lowest player of the longest list, keeping at least one each
    local longest
    for _, sec in ipairs(sections) do
      if sec.count > 1 and (not longest or sec.count >= longest.count) then longest = sec end
    end
    if not longest then break end
    longest.count = longest.count - 1
    msg = Build(true)
  end
  if #msg > MAX_MSG then msg = Build(false) end
  return CutBytes(msg, MAX_MSG)
end

local function BuildLines(fight)
  local damage = GetSession(fight.sessionID, DAMAGE)
  local heal = GetSession(fight.sessionID, HEALING)
  if Hidden(damage) or Hidden(heal) then return nil, true end
  local seconds = Duration(fight.sessionID, damage, heal)
  local outcome = fight.killed == true and " down" or fight.killed == false and " wipe" or ""
  local header = string.format("%s%s in %s", fight.name or "Fight", outcome, Clock(seconds))
  if DB.oneMessage then
    local sections = {}
    for _, s in ipairs({ { DB.damage, damage, "Damage", "dps" }, { DB.heal, heal, "Healing", "hps" } }) do
      local list = s[1] and Top(s[2]) or {}
      if #list > 0 then
        sections[#sections + 1] = { list = list, count = math.min(DB.lines, #list), label = s[3], rate = s[4] }
      end
    end
    if #sections == 0 then return nil end
    return { OneMessage(header, sections, seconds) }
  end
  local lines = { header }
  if DB.damage then Section(lines, damage, "Damage", "dps", seconds) end
  if DB.heal then Section(lines, heal, "Healing", "hps", seconds) end
  if #lines == 1 then return nil end
  return lines
end

----------------------------------------------------------------------
-- Sending
----------------------------------------------------------------------
local function Destination()
  local c = DB.channel
  if c == "auto" then
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
    return nil
  end
  if c == "raid" then return IsInRaid() and "RAID" or nil end
  if c == "party" then return IsInGroup() and "PARTY" or nil end
  if c == "guild" then return IsInGuild() and "GUILD" or nil end
  if c == "say" then return "SAY" end
  return nil
end

local function GroupChannel()
  if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
end

local function Send(lines, toSelf)
  local channel = not toSelf and Destination()
  for i, line in ipairs(lines) do
    if channel then
      C_Timer.After((i - 1) * LINE_GAP, function() SendChatMessage(line, channel) end)
    else
      Print(line)
    end
  end
  return channel
end

-- Tell other Boss Report users in the group that this fight is being posted, so only one does.
local function Claim(key)
  local ch = GroupChannel()
  if ch and C_ChatInfo and C_ChatInfo.SendAddonMessage then
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, "post:" .. key, ch)
  end
end

-- Leader posts first, then assistants, then everyone else, so a group with several copies
-- agrees on one poster. Returns the wait in seconds before this player posts.
local function MyTurnDelay()
  if not GroupChannel() then return 0 end
  if UnitIsGroupLeader and UnitIsGroupLeader("player") then return 0 end
  if UnitIsGroupAssistant and UnitIsGroupAssistant("player") then return 0.8 end
  local name = UnitName("player") or ""
  local spread = 0
  for i = 1, #name do spread = (spread * 31 + name:byte(i)) % 1000 end
  return 1.6 + spread / 1000 -- 1.6 to 2.6 s, different for each player
end

----------------------------------------------------------------------
-- After a boss: wait for the numbers, then post
----------------------------------------------------------------------
local function Poll()
  local p = pending
  if not p then return end
  if claimed[p.key] or not DB.enabled then pending = nil; return end -- someone else posted it, or turned off
  local lines, hidden = BuildLines(p.fight)
  if hidden or (not lines and GetTime() - p.started < 3) then -- still in combat, or the session isn't there yet
    if GetTime() - p.started < MAX_WAIT then C_Timer.After(POLL, Poll) else pending = nil end
    return
  end
  if not lines then pending = nil; return end
  if not p.waited then -- numbers are readable: now wait for our turn
    p.waited = true
    local delay = Destination() and MyTurnDelay() or 0
    if delay > 0 then C_Timer.After(delay, Poll); return end
  end
  pending = nil
  if Destination() then Claim(p.key) end
  Send(lines)
end

-- Like Details: a second into the boss fight, the newest meter session is that fight's session.
local startSession -- { id = encounterID, sessionID = that fight's meter session }
local function OnEncounterStart(encounterID)
  startSession = nil
  C_Timer.After(1, function()
    local list = Sessions()
    if list[#list] then startSession = { id = encounterID, sessionID = list[#list].sessionID } end
  end)
end

local function OnEncounterEnd(encounterID, name, killed)
  local sessionID = startSession and startSession.id == encounterID and startSession.sessionID or FindSession(name)
  startSession = nil
  local fight = { name = name, killed = killed, sessionID = sessionID }
  lastEncounter = fight
  if not DB.enabled or (not killed and not DB.wipes) then return end
  local key = tostring(encounterID) .. ":" .. tostring(fight.sessionID or 0)
  if claimed[key] then return end
  pending = { fight = fight, key = key, started = GetTime() }
  C_Timer.After(1, Poll) -- give the meter a moment to close the fight
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("CHAT_MSG_ADDON")
f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
  if event == "ADDON_LOADED" and a1 == ADDON then
    BossReportDB = BossReportDB or {}
    DB = BossReportDB
    for k, v in pairs(DEFAULTS) do if DB[k] == nil then DB[k] = v end end
    if not CHANNELS[DB.channel] then DB.channel = "auto" end
    local ok, err = pcall(RegisterSettings)
    if not ok then Print("couldn't add the settings page: " .. tostring(err)) end
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    if not DM then Print("this client has no built-in damage meter, so there's nothing to report.") end
  elseif event == "ENCOUNTER_START" and DM then
    OnEncounterStart(a1)
  elseif event == "ENCOUNTER_END" and DB and DM then
    OnEncounterEnd(a1, a2, a5 == 1) -- encounterID, encounterName, difficultyID, groupSize, success
  elseif event == "CHAT_MSG_ADDON" and a1 == PREFIX then
    local key = type(a2) == "string" and a2:match("^post:(.+)$")
    local me = UnitName("player")
    if key and ShortName(a4 or "") ~= me then claimed[key] = true end
  end
end)

----------------------------------------------------------------------
-- /breport
----------------------------------------------------------------------
local ReportLast, OpenSettings

local function OnOff(v) return v and "|cFF55FF55on|r" or "|cFFFF5555off|r" end

local function Status()
  Print(string.format("%s. Damage %s, healing %s, top %d, to %s, wipes %s, one message %s.", OnOff(DB.enabled),
    OnOff(DB.damage), OnOff(DB.heal), DB.lines, DB.channel, OnOff(DB.wipes), OnOff(DB.oneMessage)))
end

local function Help()
  Print("commands:")
  print("  /breport                       settings window")
  print("  /breport on | off              report after each boss kill")
  print("  /breport damage [on | off]     include damage")
  print("  /breport heal [on | off]       include healing")
  print("  /breport lines 1-10            how many players per list")
  print("  /breport channel auto | party | raid | guild | say | self")
  print("      auto = raid or party chat, or only you when you're alone")
  print("  /breport wipes [on | off]      also report wipes")
  print("  /breport one [on | off]        all in one chat message")
  print("  /breport test                  show the last fight's report to you only")
  print("  /breport now                   post the last fight's report to the channel")
end

-- The last fight's report: to you only (test) or to the channel (now).
function ReportLast(toSelf)
  if not DM then return Print("this client has no built-in damage meter.") end
  local fight = lastEncounter
  if not fight then -- no boss since login: the meter's newest fight
    local list = Sessions()
    local s = list[#list]
    fight = { name = s and not Secret(s.name) and s.name or nil, sessionID = s and s.sessionID }
  end
  local lines, hidden = BuildLines(fight)
  if hidden then return Print("the numbers are hidden until combat ends; try again then.") end
  if not lines then return Print("the damage meter has no fight with damage or healing to report yet.") end
  Send(lines, toSelf)
end

local function Toggle(key, arg)
  if arg == "on" then SetOption(key, true) elseif arg == "off" then SetOption(key, false)
  elseif arg == "" then SetOption(key, not DB[key])
  else Print("use on or off."); return false end
  return true
end

----------------------------------------------------------------------
-- Settings page: Esc > Options > AddOns > Boss Report
----------------------------------------------------------------------
local OPTIONS = {
  { "enabled", "boolean", "Enable Boss Report", "Turns Boss Report on or off. When it's off, nothing is posted after boss fights and the options below are greyed out." },
  { "damage", "boolean", "Damage", "Include the damage list." },
  { "heal", "boolean", "Healing", "Include the healing list." },
  { "wipes", "boolean", "Report wipes too", "Also post a report when the group wipes on a boss." },
  { "oneMessage", "boolean", "All in one message",
    "Posts the whole report as a single chat message. Chat messages hold 255 characters, so the lowest players are left out if it doesn't fit. Off: one line per player." },
  { "lines", "number", "Players per list", "How many players each list shows.", 1, 10, 1 },
  { "channel", "string", "Post to", "Where the report goes. If that chat isn't available (for example party chat while you're alone), only you see it." },
}
local CHANNEL_NAMES = {
  { "auto", "Party or raid (automatic)" },
  { "party", "Party" },
  { "raid", "Raid" },
  { "guild", "Guild" },
  { "say", "Say" },
  { "self", "Only me" },
}

local category
function RegisterSettings()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
  category = Settings.RegisterVerticalLayoutCategory("Boss Report")
  local master -- the "Enable Boss Report" checkbox; every other option greys out while it's off
  local function IsOn() return DB.enabled end
  for _, o in ipairs(OPTIONS) do
    local key, kind, label, tip, min, max, step = unpack(o)
    local setting = Settings.RegisterAddOnSetting(category, "BossReport_" .. key, key, DB, kind, label, DEFAULTS[key])
    settingFor[key] = setting
    local init
    if kind == "boolean" then
      init = Settings.CreateCheckbox(category, setting, tip)
    elseif kind == "number" then
      local options = Settings.CreateSliderOptions(min, max, step)
      if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
      end
      init = Settings.CreateSlider(category, setting, options, tip)
    else
      local function Choices()
        local c = Settings.CreateControlTextContainer()
        for _, ch in ipairs(CHANNEL_NAMES) do c:Add(ch[1], ch[2]) end
        return c:GetData()
      end
      local create = Settings.CreateDropdown or Settings.CreateDropDown
      if create then init = create(category, setting, Choices, tip) end
    end
    if key == "enabled" then
      master = init
    elseif master and type(init) == "table" and init.SetParentInitializer then
      pcall(init.SetParentInitializer, init, master, IsOn)
    end
  end
  -- buttons to try it out
  local layout = SettingsPanel and SettingsPanel.GetLayout and SettingsPanel:GetLayout(category)
  if layout and CreateSettingsButtonInitializer then
    layout:AddInitializer(CreateSettingsButtonInitializer("Last fight", "Show to me",
      function() ReportLast(true) end, "Shows the last fight's report in your chat only.", true))
    layout:AddInitializer(CreateSettingsButtonInitializer("", "Post it now",
      function() ReportLast(false) end, "Posts the last fight's report to the chosen chat.", true))
  end
  Settings.RegisterAddOnCategory(category)
end

function OpenSettings()
  if category and Settings and Settings.OpenToCategory and pcall(Settings.OpenToCategory, category:GetID()) then return end
  Status(); Help()
end

SLASH_BOSSREPORT1, SLASH_BOSSREPORT2 = "/breport", "/bossreport"
SlashCmdList.BOSSREPORT = function(msg)
  local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "on" or cmd == "off" then
    SetOption("enabled", cmd == "on")
  elseif cmd == "damage" then
    if not Toggle("damage", arg) then return end
  elseif cmd == "heal" or cmd == "healing" then
    if not Toggle("heal", arg) then return end
  elseif cmd == "wipes" then
    if not Toggle("wipes", arg) then return end
  elseif cmd == "onemessage" or cmd == "one" or cmd == "compact" then
    if not Toggle("oneMessage", arg) then return end
  elseif cmd == "lines" then
    local n = tonumber(arg)
    if not n or n < 1 or n > 10 then return Print("lines must be a number from 1 to 10.") end
    SetOption("lines", math.floor(n))
  elseif cmd == "channel" then
    if not CHANNELS[arg] then return Print("channel must be auto, party, raid, guild, say or self.") end
    SetOption("channel", arg)
  elseif cmd == "test" or cmd == "now" then
    return ReportLast(cmd == "test")
  elseif cmd == "" or cmd == "settings" or cmd == "options" then
    return OpenSettings()
  elseif cmd == "help" then
    Status(); return Help()
  else
    return Help()
  end
  Status()
end
