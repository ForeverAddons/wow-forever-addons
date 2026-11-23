-- What's Training? lists the recipes you can still learn ("What can I train?"). With it installed,
-- clicking one of those recipes sets a waypoint (TomTom, or the game's map pin) to the nearest
-- place to learn it: the nearest vendor that sells it, the nearest trainer of that profession,
-- or the quest giver. Works in its floating window and in its tab of the profession book.
-- Only a plain left-click: Shift- and Ctrl-click still link the item / recipe as before.
local _, ns = ...

local W = {}
ns.WhatsTraining = W

local band = bit and bit.band
local TRAINER_FLAG = 16 -- QuestieDB's npcFlags.TRAINER, used if its enum isn't there

local function Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
end

local function Enabled() return not ns.db or ns.db.whatsTraining ~= false end

------------------------------------------------------------------------
-- Profession trainers, from QuestieDB: every NPC flagged as a trainer, with its title.
-- Read a slice per frame the first time it's needed, so it never causes a hitch.
------------------------------------------------------------------------
local trainers          -- { {npcID, lowercase title}, ... } once built
local building, onBuilt = false, {}

local function BuildTrainers(done)
    if trainers then if done then done() end return end
    if done then onBuilt[#onBuilt + 1] = done end
    if building or not (ns.QDB.Ready() and NpcDB.GetAllIds and band) then return end
    building = true
    local ids = Safe(NpcDB.GetAllIds) or {}
    local flags = LibQuestieDB.Enum and LibQuestieDB.Enum.npcFlags
    local flag = flags and flags.TRAINER or TRAINER_FLAG
    local list, i = {}, 1
    local function Step()
        local stop = math.min(#ids, i + 499)
        for k = i, stop do
            local id = ids[k]
            local f = Safe(NpcDB.npcFlags, id)
            if type(f) == "number" and band(f, flag) ~= 0 then
                local sub = Safe(NpcDB.subName, id)
                if type(sub) == "string" and sub ~= "" then list[#list + 1] = { id, sub:lower() } end
            end
        end
        i = stop + 1
        if i <= #ids then C_Timer.After(0, Step) return end
        trainers, building = list, false
        local waiting = onBuilt
        onBuilt = {}
        for _, fn in ipairs(waiting) do pcall(fn) end
    end
    C_Timer.After(0, Step)
end

-- What a trainer of each profession has in its title ("Tailoring Trainer", "Expert Tailor", ...).
local STEMS = {
    Alchemy = { "alchem" }, Blacksmithing = { "blacksmith" }, Cooking = { "cook" },
    Enchanting = { "enchant" }, Engineering = { "engineer" }, ["First Aid"] = { "first aid", "physician", "surgeon" },
    Fishing = { "fish" }, Herbalism = { "herbalis" }, Jewelcrafting = { "jewel" },
    Leatherworking = { "leatherwork" }, Mining = { "mining", "miner" }, Skinning = { "skinn" },
    Tailoring = { "tailor" },
}

-- Specialization trainers (Gnomish Engineering, Weaponsmith, Dragonscale...) teach only their own recipes.
local SPECIALIZED = { "gnom", "goblin", "armorsmith", "weaponsmith", "swordsmith", "hammersmith", "axesmith",
    "dragonscale", "elemental leather", "tribal leather" }

-- How far a trainer can teach, from its title: 3 Artisan, 2 Expert, 1 the rest (Apprentice/Journeyman).
local function Tier(title)
    if title:find("artisan", 1, true) or title:find("master", 1, true) then return 3 end
    if title:find("expert", 1, true) then return 2 end
    return 1
end

local RANK_TIER = { Expert = 2, Artisan = 3, Master = 3 }

-- The trainer tier a recipe needs: Expert from skill 125, Artisan from 200 (or the rank it is).
local function NeededTier(recipe)
    if recipe.rank and RANK_TIER[recipe.rank] then return RANK_TIER[recipe.rank] end
    local skill = recipe.skill or 0
    if skill >= 200 then return 3 elseif skill >= 125 then return 2 end
    return 1
end

-- Trainers of the profession who can teach the recipe; any trainer of it if none is known to.
local function TrainerIDs(profession, recipe)
    if not (trainers and profession) then return {} end
    local stems = STEMS[profession] or { profession:lower():sub(1, 5) }
    local need = NeededTier(recipe)
    local able, any = {}, {}
    for _, t in ipairs(trainers) do
        local title = t[2]
        local match = false
        for _, stem in ipairs(stems) do
            if title:find(stem, 1, true) then match = true; break end
        end
        if match then
            for _, s in ipairs(SPECIALIZED) do
                if title:find(s, 1, true) then match = false; break end
            end
        end
        if match then
            any[#any + 1] = t[1]
            if Tier(title) >= need then able[#able + 1] = t[1] end
        end
    end
    return #able > 0 and able or any
end

------------------------------------------------------------------------
-- Where to learn one recipe: the nearest of its vendors, trainers and quest givers
------------------------------------------------------------------------
local function ForYou(location)
    local faction = UnitFactionGroup("player")
    return not location.faction or location.faction == faction or (ns.db and ns.db.otherFaction)
end

local function HasSource(sources, name)
    for _, s in ipairs(sources or {}) do if s == name then return true end end
    return false
end

local KIND = { vendor = "vendor", trainer = "trainer", quest = "quest giver" }

-- Returns the nearest place (a Vendors candidate plus .kind), or nil and why not.
function W.Nearest(data)
    local recipe = data and data.recipe
    if not recipe then return nil end
    local sources = data.sources or recipe.source or {}
    local ids, kindOf = {}, {}
    local function Add(npcID, kind)
        if type(npcID) == "number" and not kindOf[npcID] then
            kindOf[npcID] = kind
            ids[#ids + 1] = npcID
        end
    end
    if HasSource(sources, "vendor") then
        for _, v in ipairs(recipe.vendors or {}) do if ForYou(v) then Add(v.npc, "vendor") end end
    end
    local waiting = false
    if HasSource(sources, "trainer") then
        if trainers then
            for _, id in ipairs(TrainerIDs(data.profession, recipe)) do Add(id, "trainer") end
        elseif ns.QDB.Ready() then
            waiting = true
            BuildTrainers()
        end
    end
    if HasSource(sources, "quest") and ns.QDB.Ready() and QuestDB then
        for _, q in ipairs(recipe.quests or {}) do
            if ForYou(q) then
                local starters = Safe(QuestDB.startedBy, q.id)
                for _, npcID in ipairs(type(starters) == "table" and type(starters[1]) == "table" and starters[1] or {}) do
                    Add(npcID, "quest")
                end
            end
        end
    end
    if #ids > 0 then
        local best = ns.Vendors.NpcPlaces(ids)[1]
        if best and best.map then
            best.kind = KIND[kindOf[best.npcID]] or "NPC"
            return best
        end
    end
    if waiting then return nil, "loading" end
    if #ids > 0 then
        -- e.g. a vendor without QuestieDB's data: at least say which zone
        local zones, seen = {}, {}
        for _, v in ipairs(recipe.vendors or {}) do
            local zone = ForYou(v) and v.area and C_Map.GetAreaInfo and Safe(C_Map.GetAreaInfo, v.area)
            if zone and not seen[zone] then seen[zone] = true; zones[#zones + 1] = zone end
        end
        return nil, "nopos", #zones > 0 and table.concat(zones, ", ") or nil
    end
    if not ns.QDB.Ready() and (HasSource(sources, "trainer") or HasSource(sources, "quest")) then
        return nil, "noquestie"
    end
    return nil, "none"
end

local function Describe(c)
    local where = c.zoneName or "?"
    local dist = ns.DistanceText(c)
    if dist ~= "" then where = where .. ", " .. dist end
    return ("%s |cffaaaaaa(%s)|r, %s"):format(c.name or "?", c.kind, where)
end

local WHY = {
    loading = "still loading trainer locations from QuestieDB; click again in a moment.",
    nopos = "no map position is known for where to learn it.",
    noquestie = "install QuestieDB to find its trainer or quest giver.",
    none = "it isn't sold by a vendor, taught by a trainer or given by a quest you can reach.",
}

function W.Waypoint(data)
    local name = data.name or (data.recipe and ("recipe " .. data.recipe.spell)) or "this recipe"
    local c, why, zones = W.Nearest(data)
    if not c then
        if why == "nopos" and zones then
            ns.Print(("%s: sold in %s, but the vendor's map position isn't known (QuestieDB has it, or open that vendor once)."):format(name, zones))
            return
        end
        ns.Print(name .. ": " .. (WHY[why] or WHY.none))
        if why == "loading" then BuildTrainers() end
        return
    end
    local target = {}
    for k, v in pairs(c) do target[k] = v end
    target.name = ("%s (%s): %s"):format(c.name or "?", c.kind, name)
    ns.SetWaypoint(target)
end

------------------------------------------------------------------------
-- Hooking What's Training's recipe lists
------------------------------------------------------------------------
local ourRows = setmetatable({}, { __mode = "k" }) -- the rows we watch, for the tooltip line

local function Plain() return not (IsShiftKeyDown() or IsControlKeyDown() or IsAltKeyDown()) end

local function OnRowClick(row, button)
    if button ~= "LeftButton" or not Plain() or not Enabled() then return end
    local data = row.data
    if data and data.recipe then W.Waypoint(data) end
end

-- The floating window's rows set their OnClick once, so a hook stays.
local function HookFloatingRows(list)
    for _, row in ipairs(list.rows or {}) do
        if not ourRows[row] then
            ourRows[row] = true
            row:HookScript("OnClick", OnRowClick)
        end
    end
end

-- The profession book's list reuses rows and sets their OnClick each time a row is filled, so wrap
-- that OnClick right after: the mouse and the gamepad (which calls the row's OnClick) both go through it.
local wrappers = setmetatable({}, { __mode = "k" })
local function HookBookRow(row)
    if not (row.GetScript and row.SetScript) then return end
    ourRows[row] = true
    local original = row:GetScript("OnClick")
    if not original or wrappers[original] then return end
    local function Wrapped(self, button, ...)
        original(self, button, ...)
        OnRowClick(self, button)
    end
    wrappers[Wrapped] = true
    row:SetScript("OnClick", Wrapped)
end

local hookedFloating, hookedBook = false, false

local function TryHook()
    local floating = WhatsTrainingFloatingFrame
    local list = floating and floating.professionsPage and floating.professionsPage.recipeList
    if list and list.rows and not hookedFloating then
        hookedFloating = true
        HookFloatingRows(list)
        list:HookScript("OnShow", function(self) -- rows added later; trainers looked up once you use it
            HookFloatingRows(self)
            if Enabled() then BuildTrainers() end
        end)
        if list.IsVisible and list:IsVisible() and Enabled() then BuildTrainers() end
    end
    local book = WhatsTrainingCraftingRecipeList
    local scroll = book and book.scrollBox
    if scroll and scroll.RegisterCallback and ScrollBoxListMixin and not hookedBook then
        hookedBook = true
        scroll:RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, function(_, frame, node)
            local data = node and node.GetData and node:GetData()
            if data and data.recipe then HookBookRow(frame) end
        end, W)
        scroll:ForEachFrame(function(frame)
            if frame.data and frame.data.recipe then HookBookRow(frame) end
        end)
        if book.HookScript then book:HookScript("OnShow", function() if Enabled() then BuildTrainers() end end) end
        if book.IsVisible and book:IsVisible() and Enabled() then BuildTrainers() end
    end
    return hookedFloating and hookedBook
end

-- Both lists are built only when first opened, so look for them now and then until they exist.
local ticker
local function Watch()
    if ticker or TryHook() then return end
    ticker = C_Timer.NewTicker(1, function()
        if TryHook() then ticker:Cancel() end
    end)
end

------------------------------------------------------------------------
-- The tooltip line: "Click: waypoint to ..."
------------------------------------------------------------------------
local function AddTooltipLine(tooltip, spellID)
    if tooltip ~= GameTooltip or not Enabled() then return end
    local row = tooltip:GetOwner()
    if not (row and ourRows[row]) then return end
    local data = row.data
    if not (data and data.recipe and data.recipe.spell == spellID) then return end
    local c, why = W.Nearest(data)
    if c then
        tooltip:AddLine("Click: waypoint to " .. Describe(c), 0.3, 1, 0.3, true)
    elseif why == "loading" then
        tooltip:AddLine("Reagent Scout: finding trainers...", 0.6, 0.6, 0.6)
    else
        return
    end
    tooltip:Show()
end

ns.On("PLAYER_LOGIN", function()
    if not (C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded)("WhatsTraining") then return end
    Watch()
    if TooltipDataProcessor and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, function(tooltip, data)
            if data then pcall(AddTooltipLine, tooltip, data.id) end
        end)
    end
end)
