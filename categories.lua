-- categories.lua
local ADDON, ACA = ...
local CF = {}
ACA.CategoryFilters = CF

-- persistent DB per-character
ACA_CatFilterDB = ACA_CatFilterDB or {
    ["Characters"] = true, ["Quests"] = true, ["Exploration"] = true,
    ["Delves"] = true, ["Player vs. Player"] = true, ["Dungeons & Raids"] = true,
    ["Reputation"] = true, ["Pet Battles"] = true, ["Collections"] = true,
    ["Expansion Features"] = true, ["Legion: Remix"] = true,
    ["ProfessionsMode"] = "Learned",   -- All / Learned / None
    ["WorldEventsMode"] = "Active",    -- All / Active / None
}


-- per-character expansion filter DB: keys are expansion names, values boolean (selected)
ACA_ExpFilterDB = ACA_ExpFilterDB or {
    ["Classic"] = false,
    ["The Burning Crusade"] = false,
    ["Wrath of the Lich King"] = false,
    ["Cataclysm"] = false,
    ["Mists of Pandaria"] = false,
    ["Warlords of Draenor"] = false,
    ["Legion"] = false,
    ["Battle for Azeroth"] = false,
    ["Shadowlands"] = false,
    ["Dragonflight"] = false,
    ["The War Within"] = false,
    ["Midnight"] = false,
}
CF.topParent = {}    -- categoryID -> top-level name
CF.achParent = {}    -- achievementID -> top-level name
CF.achCatName = {}  -- achievementID -> subcategory name (e.g., specific holiday)
CF.achExpansion = {} -- achievementID -> expansion name
CF.fullList  = {}    -- master scan list (unfiltered)
CF.hiddenIDs = {}    -- set of filtered out achIDs
CF.mapsBuilt = false

-- version-aware parent map builder
do
    local wowVersion = tostring((select(1, GetBuildInfo())) or "0.0.0")
    function CF.BuildParentMaps()
        if CF.mapsBuilt and ACA_CatFilterDB["LastBuild"] == wowVersion then
            return
        end
        CF.mapsBuilt = true
        ACA_CatFilterDB["LastBuild"] = wowVersion

        wipe(CF.topParent)
        wipe(CF.achParent)

        local cats = (ACA.SafeGetCategoryList and ACA.SafeGetCategoryList()) or (GetCategoryList() or {})
        for _, catID in ipairs(cats) do
            local EXP_MATCH = {
                ["Classic"] = { "Classic" },
                ["The Burning Crusade"] = { "Burning Crusade" },
                ["Wrath of the Lich King"] = { "Wrath", "Wrath of the Lich King" },
                ["Cataclysm"] = { "Cataclysm" },
                ["Mists of Pandaria"] = { "Mists", "Pandaria" },
                ["Warlords of Draenor"] = { "Warlords", "Draenor" },
                ["Legion"] = { "Legion" },
                ["Battle for Azeroth"] = { "Battle for Azeroth", "BFA", "Azeroth" },
                ["Shadowlands"] = { "Shadowlands" },
                ["Dragonflight"] = { "Dragonflight" },
                ["The War Within"] = { "The War Within", "War Within" },
                ["Midnight"] = { "Midnight" },
            }
            local name, parent = GetCategoryInfo(catID)
            local topName = name
            while parent and parent > 0 do
                local n, p = GetCategoryInfo(parent)
                if not n then break end
                topName = n
                parent = p
            end
            CF.topParent[catID] = topName
            local function detectExpansion()
                local hay = ((name or "") .. " " .. (topName or "")):lower()
                for exp, keys in pairs(EXP_MATCH) do
                    for _, k in ipairs(keys) do
                        if hay:find(k:lower(), 1, true) then return exp end
                    end
                end
                return nil
            end
            local catExpansion = detectExpansion()
            local num = GetCategoryNumAchievements(catID) or 0
            for i = 1, num do
                local achID = select(1, GetAchievementInfo(catID, i))
                if achID then CF.achParent[achID] = topName; CF.achCatName[achID] = name; if catExpansion then CF.achExpansion[achID] = catExpansion end end
            end
        end
    end
end

-- helpers: professions and holidays
local function PlayerKnowsProfInAchieve(achID)
    local known = {}

    if GetProfessions and GetProfessionInfo then
        local a, b, c, d, e = GetProfessions()
        for _, idx in ipairs({a, b, c, d, e}) do
            if idx then
                local name = GetProfessionInfo(idx)
                if name then known[name] = true end
            end
        end
    end

    if next(known) == nil and C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionInfo then
        local profs = C_TradeSkillUI.GetAllProfessionInfo()
        if profs then
            for _, p in ipairs(profs) do
                if p and p.name then known[p.name] = true end
            end
        end
    end

    if next(known) == nil then
        return false
    end

    local num = GetAchievementNumCriteria(achID) or 0
    for i = 1, num do
        local text = select(1, GetAchievementCriteriaInfo(achID, i))
        if text then
            for profName in pairs(known) do
                if text:find(profName, 1, true) then
                    return true
                end
            end
        end
    end
    return false
end

local function AnyHolidayActive()
    if not C_Calendar or not C_DateAndTime then
        return false
    end
    if C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end

    local function dayHasHoliday(offset)
        local now = C_DateAndTime.GetCurrentCalendarTime()
        if not now or not now.monthDay then return false end
        local day = now.monthDay + (offset or 0)
        local num = C_Calendar.GetNumDayEvents(0, day) or 0
        for i = 1, num do
            local info = C_Calendar.GetHolidayInfo(0, day, i)
            if info and (info.texture or info.startTime or info.endTime) then
                return true
            end
        end
        return false
    end

    return dayHasHoliday(0) or dayHasHoliday(-1) or dayHasHoliday(1)
end

local function HolidayActiveForAchievement(achID)
    if not C_Calendar or not C_DateAndTime then return false end
    if C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end

    local sub = CF.achCatName and CF.achCatName[achID]
    if not sub or sub == "" then
        return AnyHolidayActive()
    end

    local needle = tostring(sub):lower()
    local now = C_DateAndTime.GetCurrentCalendarTime()
    if not now or not now.monthDay then return false end

    local function dayHasHolidayName(offset)
        local day = now.monthDay + (offset or 0)
        local num = C_Calendar.GetNumDayEvents(0, day) or 0
        for i = 1, num do
            local info = C_Calendar.GetHolidayInfo(0, day, i)
            local title = info and (info.name or info.description)
            if title and tostring(title):lower():find(needle, 1, true) then
                return true
            end
        end
        return false
    end

    for d = -1, 1 do
        if dayHasHolidayName(d) then return true end
    end
    return false
end

function CF.ShouldShow(achID)
    local top = CF.achParent[achID]
    if top == "Feats of Strength" or top == "Legacy" then return false end
    if not top then return true end

    if ACA_CatFilterDB[top] == false then
        return false
    end

    if top == "Professions" then
        local mode = ACA_CatFilterDB["ProfessionsMode"] or "Learned"
        if mode == "None" then return false end
        if mode == "Learned" then return PlayerKnowsProfInAchieve(achID) end
    end

    if top == "World Events" then
        local mode = ACA_CatFilterDB["WorldEventsMode"] or "Active"
        if mode == "None" then return false end
        if mode == "Active" then return HolidayActiveForAchievement(achID) end
    end

    -- Expansion filter check
    do
        local db = _G.ACA_ExpFilterDB or {}
        local total, checked = 0, 0
        for _, _ in pairs({
            ["Classic"]=true, ["The Burning Crusade"]=true, ["Wrath of the Lich King"]=true, ["Cataclysm"]=true,
            ["Mists of Pandaria"]=true, ["Warlords of Draenor"]=true, ["Legion"]=true, ["Battle for Azeroth"]=true,
            ["Shadowlands"]=true, ["Dragonflight"]=true, ["The War Within"]=true, ["Midnight"]=true,
        }) do total = total + 1 end
        for k, v in pairs(db) do if v then checked = checked + 1 end end
        local active = (checked > 0) and (checked < total)
        if active then
            local exp = CF.achExpansion[achID]
            if not exp or not db[exp] then return false end
        end
    end
    return true
end

function CF.RefreshFilteredList()
    if #CF.fullList == 0 then return end
    wipe(CF.hiddenIDs)
    wipe(ACA.scanResults)
    for i = 1, #CF.fullList do
        local ach = CF.fullList[i]
        if CF.ShouldShow(ach.id) then
            table.insert(ACA.scanResults, ach)
        else
            CF.hiddenIDs[ach.id] = true
        end
    end
    if CF._pendingUpdate then CF._pendingUpdate:Cancel() end
    CF._pendingUpdate = C_Timer.NewTimer(0.5, function()
        ACA.UpdatePanel(false)
    end)
end

function CF.HookScan()
    if ACA._scanWrapped then return end
    local orig = ACA.ScanAchievements
    if not orig then return end
    ACA.ScanAchievements = function(onComplete, onProgress)
        wipe(CF.fullList)
        wipe(CF.hiddenIDs)
        local wrapped = function(results)
            for i = 1, #results do CF.fullList[i] = results[i] end
            CF.RefreshFilteredList()
            if onComplete then onComplete(ACA.scanResults) end
        end
        orig(wrapped, onProgress)
    end
    ACA._scanWrapped = true
end

function CF.InjectUI(parent)
    if not parent or parent.catFilterBox then return end

    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetHeight(300)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)
    parent.catFilterBox = box

    -- Position: mirror list width, now tucked just under the top dropdowns.
    box:ClearAllPoints()
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -40)
    box:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -40)

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    title:SetText("Achievement Categories")

    local toggleAllBtn = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    toggleAllBtn:SetSize(80, 20)
    toggleAllBtn:SetPoint("LEFT", title, "RIGHT", 8, 0)
    toggleAllBtn:SetText("Toggle All")
    toggleAllBtn.tooltipText = "Toggle all achievement categories on/off.\nProfessions and World Events settings are not changed."

    toggleAllBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipText, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    toggleAllBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    toggleAllBtn:SetScript("OnClick", function()
        _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
        local db = _G.ACA_CatFilterDB

        local allOn = true
        for k, v in pairs(db) do
            if type(v) == "boolean" and v == false then
                allOn = false
                break
            end
        end
        local target = not allOn

        for k, v in pairs(db) do
            if type(v) == "boolean" then
                db[k] = target
            end
        end

        if ACA and ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
        if CF and CF.RefreshFilteredList then CF.RefreshFilteredList() end
    end)

    -- 4-column layout with cozier spacing
    local function AddCheck(parent, text, key, x, y, tooltip, textWidth)
        local cb = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        cb.Text:SetText(text)

        if cb.Text and cb.Text.SetFontObject then cb.Text:SetFontObject(GameFontNormalSmall) end
        if cb.Text and cb.Text.SetWordWrap then cb.Text:SetWordWrap(true) end
        if cb.Text and cb.Text.SetWidth then cb.Text:SetWidth(textWidth or 90) end  -- tighter label width
        if cb.SetHitRectInsets then cb:SetHitRectInsets(0, -10, 0, 0) end
        cb:SetSize(24, 24)
        cb:SetHitRectInsets(0, 0, 0, 0)
        cb:SetChecked(ACA_CatFilterDB[key] ~= false)
        cb:SetScript("OnClick", function(self)
            ACA_CatFilterDB[key] = self:GetChecked()
            CF.RefreshFilteredList()
        end)
        if tooltip then
            cb.tooltip = tooltip
            cb:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tooltip, nil, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        return cb
    end

    local cats = {
        "Characters", "Quests", "Exploration", "Delves",
        "Player vs. Player", "Dungeons & Raids", "Reputation",
        "Pet Battles", "Collections", "Expansion Features", "Legion: Remix",
    }

    -- Determine column pitch based on current width; fallback to sensible defaults.
    local perRow = 4
    local boxW = box:GetWidth() or parent:GetWidth() or 396
    local innerW = math.max(200, boxW - 20)              -- account for padding
    local colPitch = innerW / perRow
    local x0, y0 = 10, -25
    local rowPitch = 24                                  -- tighten vertical spacing a bit

    for i, cat in ipairs(cats) do
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        local label = cat == "Player vs. Player" and "PvP" or cat
        local x = x0 + col * colPitch
        local y = y0 - row * rowPitch
        AddCheck(box, label, cat, x, y, "Hide all achievements in this category.", math.floor(colPitch - 30))
    end


    -- Expansions header and toggle-all
    local expTitle = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    local catRows = math.ceil(#cats / perRow)
    expTitle:SetPoint("TOPLEFT", box, "TOPLEFT", 10, y0 - catRows * rowPitch - 4)
    expTitle:SetText("Expansions")

    local expToggleAll = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    expToggleAll:SetSize(80, 20)
    expToggleAll:SetPoint("LEFT", expTitle, "RIGHT", 8, 0)
    expToggleAll:SetText("Toggle All")
    expToggleAll.tooltipText = "Toggle all expansion filters on/off. If all are on or all are off, expansion filtering is disabled."

    expToggleAll:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.tooltipText, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    expToggleAll:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local EXPANSIONS = {
        "Classic","The Burning Crusade","Wrath of the Lich King","Cataclysm",
        "Mists of Pandaria","Warlords of Draenor","Legion","Battle for Azeroth",
        "Shadowlands","Dragonflight","The War Within","Midnight",
    }

    box.expansionCBs = box.expansionCBs or {}

    local expPerRow = 4
    local expColPitch = innerW / expPerRow
    local expX0 = 10
    local expY0 = y0 - catRows * rowPitch - 24
    local expRowPitch = 22

    local function AddExpCheck(parent, label, x, y, textWidth)
        local cb = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        cb.Text:SetText(label)
        if cb.Text and cb.Text.SetFontObject then cb.Text:SetFontObject(GameFontNormalSmall) end
        if cb.Text and cb.Text.SetWordWrap then cb.Text:SetWordWrap(true) end
        if cb.Text and cb.Text.SetWidth then cb.Text:SetWidth(textWidth or 120) end
        cb:SetSize(24, 24)
        cb:SetHitRectInsets(0, 0, 0, 0)
        cb:SetChecked(ACA_ExpFilterDB[label] or false)
        cb:SetScript("OnClick", function(self)
            ACA_ExpFilterDB[label] = self:GetChecked() and true or false
            CF.RefreshFilteredList()
        end)
        table.insert(box.expansionCBs, cb)
        return cb
    end

    for i, expName in ipairs(EXPANSIONS) do
        local row = math.floor((i - 1) / expPerRow)
        local col = (i - 1) % expPerRow
        local x = expX0 + col * expColPitch
        local y = expY0 - row * expRowPitch
        AddExpCheck(box, expName, x, y, math.floor(expColPitch - 30))
    end

    -- toggle-all behavior
    expToggleAll:SetScript("OnClick", function()
        local anyOff, anyOn = false, false
        for _, expName in ipairs(EXPANSIONS) do
            if ACA_ExpFilterDB[expName] then anyOn = true else anyOff = true end
        end
        local target = anyOff and true or false
        for _, expName in ipairs(EXPANSIONS) do
            ACA_ExpFilterDB[expName] = target
        end
        -- sync checkboxes
        if box.expansionCBs then
            for _, cb in ipairs(box.expansionCBs) do
                local label = cb.Text and cb.Text:GetText()
                if label then cb:SetChecked(ACA_ExpFilterDB[label] or false) end
            end
        end
        CF.RefreshFilteredList()
    end)

    -- Helper for external sync
    function CF.SyncExpUI()
        if not box or not box.expansionCBs then return end
        for _, cb in ipairs(box.expansionCBs) do
            local label = cb.Text and cb.Text:GetText()
            if label then cb:SetChecked(ACA_ExpFilterDB[label] or false) end
        end
    end
    -- After laying out the categories, move Professions and World Events up
    local rows = catRows
    local gap = 8                                         -- small spacer below categories grid
    local expRows = math.ceil(#EXPANSIONS / expPerRow)
    local profBaselineY = expY0 - expRows * expRowPitch - gap
    local weBaselineY   = profBaselineY - rowPitch        -- keep same vertical rhythm

    -- Professions row
    local profText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profText:SetPoint("TOPLEFT", box, "TOPLEFT", 10, profBaselineY)
    profText:SetText("Professions:")
    local profAll = AddCheck(box, "All", "ProfessionsModeAll", 90, profBaselineY, nil, 40)
    local profNone = AddCheck(box, "None", "ProfessionsModeNone", 150, profBaselineY, "Hide all profession achievements.", 50)
    local profLearn = AddCheck(box, "Learned", "ProfessionsModeLearned", 225, profBaselineY, "Only show achievements for your learned professions.", 70)

    local function SyncProf()
        local mode = ACA_CatFilterDB["ProfessionsMode"]
        profAll:SetChecked(mode == "All")
        profNone:SetChecked(mode == "None")
        profLearn:SetChecked(mode == "Learned")
    end
    profAll:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["ProfessionsMode"] = "All"; SyncProf(); CF.RefreshFilteredList() end
    end)
    profNone:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["ProfessionsMode"] = "None"; SyncProf(); CF.RefreshFilteredList() end
    end)
    profLearn:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["ProfessionsMode"] = "Learned"; SyncProf(); CF.RefreshFilteredList() end
    end)
    SyncProf()

    -- World-Events row
    local weText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    weText:SetPoint("TOPLEFT", box, "TOPLEFT", 10, weBaselineY)
    weText:SetText("World Events:")
    local weAll = AddCheck(box, "All", "WorldEventsModeAll", 90, weBaselineY, nil, 40)
    local weNone = AddCheck(box, "None", "WorldEventsModeNone", 150, weBaselineY, "Hide all world-event achievements.", 50)
    local weActive = AddCheck(box, "Active", "WorldEventsModeActive", 225, weBaselineY, "Only show achievements for currently active holidays.", 60)
    local function SyncWE()
        local mode = ACA_CatFilterDB["WorldEventsMode"]
        weAll:SetChecked(mode == "All")
        weNone:SetChecked(mode == "None")
        weActive:SetChecked(mode == "Active")
    end
    weAll:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["WorldEventsMode"] = "All"; SyncWE(); CF.RefreshFilteredList() end
    end)
    weNone:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["WorldEventsMode"] = "None"; SyncWE(); CF.RefreshFilteredList() end
    end)
    weActive:SetScript("OnClick", function(self)
        if self:GetChecked() then ACA_CatFilterDB["WorldEventsMode"] = "Active"; SyncWE(); CF.RefreshFilteredList() end
    end)
    SyncWE()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name == "AlmostCompletedAchievements" then
        C_Timer.After(0.3, function()
            CF.BuildParentMaps()
            CF.HookScan()
            local panel = _G[ACA_PANEL_NAME]
            if panel and panel.contentOptions then CF.InjectUI(panel.contentOptions) end
            if ACA.scanResults and #ACA.scanResults > 0 and #CF.fullList == 0 then
                for i = 1, #ACA.scanResults do CF.fullList[i] = ACA.scanResults[i] end
            end
            CF.RefreshFilteredList()
        end)
        loader:UnregisterAllEvents()
    end
end)

local refreshPending
local function CF_TryHookUpdatePanel()
    if CF._hookedUpdatePanel then return end
    if type(ACA) == "table" and type(ACA.UpdatePanel) == "function" then
        CF._hookedUpdatePanel = true
        hooksecurefunc(ACA, "UpdatePanel", function(_, forceRescan)
            if forceRescan then return end
            if refreshPending then return end
            refreshPending = true
            C_Timer.After(0.5, function()
                refreshPending = false
                CF.RefreshFilteredList()
            end)
        end)
    else
        C_Timer.After(0.2, CF_TryHookUpdatePanel)
    end
end
CF_TryHookUpdatePanel()

return CF
