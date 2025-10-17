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

CF.topParent = {}    -- categoryID -> top-level name
CF.achParent = {}    -- achievementID -> top-level name
CF.achCatName = {}  -- achievementID -> subcategory name (e.g., specific holiday)
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
            local name, parent = GetCategoryInfo(catID)
            local topName = name
            while parent and parent > 0 do
                local n, p = GetCategoryInfo(parent)
                if not n then break end
                topName = n
                parent = p
            end
            CF.topParent[catID] = topName
            local num = GetCategoryNumAchievements(catID) or 0
            for i = 1, num do
                local achID = select(1, GetAchievementInfo(catID, i))
                if achID then CF.achParent[achID] = topName; CF.achCatName[achID] = name end
            end
        end
    end
end

-- helpers: professions and holidays
local function PlayerKnowsProfInAchieve(achID)
    -- Build a set of known profession names
    local known = {}

    -- Prefer stable API available immediately
    if GetProfessions and GetProfessionInfo then
        local a, b, c, d, e = GetProfessions()
        for _, idx in ipairs({a, b, c, d, e}) do
            if idx then
                local name = GetProfessionInfo(idx)
                if name then known[name] = true end
            end
        end
    end

    -- Fallback: TradeSkill API (may not be ready right at login)
    if next(known) == nil and C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionInfo then
        local profs = C_TradeSkillUI.GetAllProfessionInfo()
        if profs then
            for _, p in ipairs(profs) do
                if p and p.name then known[p.name] = true
                end
            end
        end
    end

    -- If still unknown, don't pretend everything matches
    if next(known) == nil then
        return false
    end

    -- Match any known profession name against criteria text
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
        -- If the calendar doesn’t exist for some reason, don’t claim there’s a holiday.
        return false
    end

    -- Initialize calendar data if necessary (pcall to avoid taint issues)
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

    -- Today, and around reset boundaries
    return dayHasHoliday(0) or dayHasHoliday(-1) or dayHasHoliday(1)
end

-- Check whether the specific holiday for this achievement is active.
-- Uses the achievement's subcategory name under "World Events" (e.g., "Hallow's End", "Brewfest").
local function HolidayActiveForAchievement(achID)
    if not C_Calendar or not C_DateAndTime then return false end
    -- Initialize calendar data if needed
    if C_Calendar.OpenCalendar then pcall(C_Calendar.OpenCalendar) end

    local sub = CF.achCatName and CF.achCatName[achID]
    if not sub or sub == "" then
        -- Fallback: if we cannot resolve a subcategory name, fall back to "any holiday active"
        return AnyHolidayActive()
    end

    -- Normalize for simple contains matching
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

    -- Check a small window around today to cover reset boundaries
    for d = -1, 1 do
        if dayHasHolidayName(d) then return true end
    end
    return false
end


-- whether an achievement should be displayed
function CF.ShouldShow(achID)
    -- if we don't know parent, be permissive
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

    return true
end

-- build the filtered view (populates ACA.scanResults and CF.hiddenIDs)
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

-- wrap the main scan to store master copy (fullList)
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

-- UI injection functions (checkboxes)
function CF.InjectUI(parent)
    if not parent or parent.catFilterBox then return end

    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetSize(360, 200)
    box:SetPoint("TOP", parent, "TOP", 0, -150)
    box:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    box:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
    box:SetBackdropBorderColor(0.4, 0.4, 0.4)
    parent.catFilterBox = box

    local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    title:SetText("Achievement Categories")

    -- BEGIN: Toggle All button (tiny, polite, does not touch Professions/World Events)
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

        -- if any boolean is false, we turn everything on; else turn all off
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
    -- END: Toggle All button

    local function AddCheck(parent, text, key, x, y, tooltip)
        local cb = CreateFrame("CheckButton", nil, parent, "ChatConfigCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        cb.Text:SetText(text)
		
        -- Fit across UI scales: smaller font + wrapping
        if cb.Text and cb.Text.SetFontObject then cb.Text:SetFontObject(GameFontNormalSmall) end
        if cb.Text and cb.Text.SetWordWrap then cb.Text:SetWordWrap(true) end
        if cb.Text and cb.Text.SetWidth then cb.Text:SetWidth(110) end
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
        "Pet Battles", "Collections", "Expansion Features","Legion: Remix",
    }
    local perRow, colPitch, x0, y0 = 3, 350 / 3, 10, -25
    for i, cat in ipairs(cats) do
        local row = floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        local label = cat == "Player vs. Player" and "PvP" or cat
        AddCheck(box, label, cat, x0 + col * colPitch, y0 - row * 28, "Hide all achievements in this category.")
    end

    -- Professions row
    local profText = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profText:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -145)
    profText:SetText("Professions:")
    local profAll = AddCheck(box, "All", "ProfessionsModeAll", 90, -145)
    local profNone = AddCheck(box, "None", "ProfessionsModeNone", 150, -145, "Hide all profession achievements.")
    local profLearn = AddCheck(box, "Learned", "ProfessionsModeLearned", 225, -145, "Only show achievements for your learned professions.")

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
    weText:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -170)
    weText:SetText("World Events:")
    local weAll = AddCheck(box, "All", "WorldEventsModeAll", 90, -170)
    local weNone = AddCheck(box, "None", "WorldEventsModeNone", 150, -170, "Hide all world-event achievements.")
    local weActive = AddCheck(box, "Active", "WorldEventsModeActive", 225, -170, "Only show achievements for currently active holidays.")
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

-- delayed initializer to hook scanning and inject UI
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name == "AlmostCompletedAchievements" then
        C_Timer.After(0.3, function()
            CF.BuildParentMaps()
            CF.HookScan()
            local panel = _G[ACA_PANEL_NAME]
            if panel and panel.contentOptions then CF.InjectUI(panel.contentOptions) end
            -- copy first scan into master list if present
            if ACA.scanResults and #ACA.scanResults > 0 and #CF.fullList == 0 then
                for i = 1, #ACA.scanResults do CF.fullList[i] = ACA.scanResults[i] end
            end
            CF.RefreshFilteredList()
        end)
        loader:UnregisterAllEvents()
    end
end)

-- ensure UpdatePanel incremental updates respect CF.hiddenIDs (hook), wait until UpdatePanel exists
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
