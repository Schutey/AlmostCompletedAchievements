--------------------------------------------------------------------------------
-- AlmostCompletedAchievements
-- v1.3  –  Reward-filter edition (with Options tab + scan progress bar)
--  reward filter dropdown
--------------------------------------------------------------------------------
local ADDON_NAME, ACA = "AlmostCompletedAchievements", {}
_G[ADDON_NAME] = ACA

----------------------------------------
-- 1.  Saved-variables
----------------------------------------
ACA_ScanThreshold   = ACA_ScanThreshold or 80
ACA_Cache           = ACA_Cache or {}
ACA_IgnoreList      = ACA_IgnoreList or {}
ACA_FilterMode      = ACA_FilterMode or "All"

----------------------------------------
-- 2.  Locals & API caches
----------------------------------------
local C_Timer, CreateFrame = C_Timer, CreateFrame
local ipairs, pairs, tonumber, tostring, select = ipairs, pairs, tonumber, tostring, select
local floor, sort, format = math.floor, table.sort, string.format
local GetAchievementInfo = GetAchievementInfo
local GetAchievementNumCriteria = GetAchievementNumCriteria
local GetAchievementCriteriaInfo = GetAchievementCriteriaInfo
local GetCategoryList, GetCategoryNumAchievements = GetCategoryList, GetCategoryNumAchievements
local UIParentLoadAddOn = UIParentLoadAddOn

----------------------------------------
-- 3.  Constants
----------------------------------------
ACA.BATCH_SIZE      = 15
ACA.SCAN_DELAY      = 0.025
ACA.SLIDER_MIN      = 50
ACA.SLIDER_MAX      = 100
ACA.DEFAULT_THRESHOLD = 80
ACA.CACHE_TTL       = 60 * 5
ACA_PANEL_NAME      = "AlmostCompletedPanel"
ACA.ROW_HEIGHT      = 44

----------------------------------------
-- 4.  Reward-filter tables
----------------------------------------
local FILTERS = {
    ["All"]                 = function(r) return true end,
    ["Any reward"]          = function(r) return r ~= "" end,
    ["Mount"]               = function(r) return r:find("Mount") end,
    ["Title"]               = function(r) return r:find("Title") end,
    ["Appearance"]          = function(r) return r:find("Appearance") end,
    ["Drake Customization"] = function(r) return r:find("Drake Customization") end,
    ["Pet"]                 = function(r) return r:find("Pet") end,
    ["Warband Campsite"]    = function(r) return r:find("Campsite") end,
    ["Other"]               = function(r)
        if r == "" then return false end
        return not (r:find("Mount") or r:find("Title") or r:find("Appearance") or
                    r:find("Drake Customization") or r:find("Pet") or r:find("Campsite"))
    end,
}
local FILTER_LIST = {
    "All", "Any reward", "Mount", "Title", "Appearance",
    "Drake Customization", "Pet", "Warband Campsite", "Other"
}

----------------------------------------
-- 5.  Helpers
----------------------------------------
local function SafeGetCategoryList()
    local t = GetCategoryList() or {}
    return type(t) == "table" and t or {}
end

local function GetCompletionPercent(achID)
    local num = GetAchievementNumCriteria(achID)
    if not num or num == 0 then return 0 end
    local done = 0
    for i = 1, num do
        local _, _, completed, qty, req = GetAchievementCriteriaInfo(achID, i)
        if completed then
            done = done + 1
        elseif qty and req and req > 0 then
            done = done + (qty / req)
        end
    end
    return (done / num) * 100
end

local function GetCachedResultsForThreshold(th)
    local e = ACA_Cache[tostring(th)]
    return (e and (time() - (e.timestamp or 0)) <= ACA.CACHE_TTL) and e.results or nil
end

local function StoreCacheForThreshold(th, res)
    ACA_Cache[tostring(th)] = { results = res, timestamp = time() }
end

----------------------------------------
-- 6.  Row pool
----------------------------------------
local rowPool = {}
local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if row and row:GetParent() ~= parent then row:SetParent(parent) end
    if row then row:Show(); return row end

    local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
    f:SetSize(360, ACA.ROW_HEIGHT)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()
    f.bg:SetColorTexture(0, 0, 0, 0.4)

    f.highlight = f:CreateTexture(nil, "HIGHLIGHT")
    f.highlight:SetAllPoints()
    f.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    f.highlight:SetBlendMode("ADD")
    f.highlight:SetAlpha(0.25)

    f.Icon = f:CreateTexture(nil, "ARTWORK")
    f.Icon:SetSize(36, 36)
    f.Icon:SetPoint("LEFT", f, "LEFT", 4, 0)

    f.Name = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Name:SetPoint("LEFT", f.Icon, "RIGHT", 8, 6)
    f.Name:SetJustifyH("LEFT")
    f.Name:SetWidth(220)

    -- percent label under the name
    f.Label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.Label:SetPoint("TOPLEFT", f.Icon, "TOPRIGHT", 8, -18)
    f.Label:SetJustifyH("LEFT")
    f.Label:SetWidth(220)

    f._ignoreButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f._ignoreButton:SetSize(24, 20)
    f._ignoreButton:SetPoint("RIGHT", f, "RIGHT", -6, 0)

    f.Reward = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.Reward:SetPoint("RIGHT", f._ignoreButton, "LEFT", -8, 0)
    f.Reward:SetJustifyH("RIGHT")
    f.Reward:SetWidth(160)
    f.Reward:SetWordWrap(false)

    return f
end

local function ReleaseRow(row)
    if not row then return end
    row:Hide(); row:SetParent(nil)
    row:SetScript("OnEnter", nil); row:SetScript("OnLeave", nil); row:SetScript("OnClick", nil)
    if row._ignoreButton then row._ignoreButton:SetScript("OnClick", nil) end
    table.insert(rowPool, row)
end

local function TruncateString(s, max)
    if not s or #s <= max then return s or "" end
    return s:sub(1, max - 3) .. "..."
end

-- NEW: wipe all rows from a scroll child
local function WipeChildren(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
        ReleaseRow(child)
    end
end

----------------------------------------
-- 7.  Populate row
----------------------------------------
function ACA:PopulateNativeRow(row, ach)
    row.Icon:SetTexture(ach.icon or 134400)
    row.Name:SetText(ach.name or ("[" .. tostring(ach.id) .. "]"))

    -- reward text
    local _, _, _, _, _, _, _, _, _, _, rewardText = GetAchievementInfo(ach.id)
    if not rewardText then
        local all = { GetAchievementInfo(ach.id) }
        rewardText = all[11] or all[12] or all[13] or ""
    end
    row.Reward:SetText(TruncateString(rewardText, 36))

    -- percent under the name
    row.Label:SetText(format("%.0f%%", ach.percent))

    -- scripts
    row:SetScript("OnEnter", function(self)
        UIParentLoadAddOn("Blizzard_AchievementUI")
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetAchievementByID then
            GameTooltip:SetAchievementByID(ach.id)
        else
            GameTooltip:ClearLines()
            GameTooltip:AddLine(ach.name or "[" .. tostring(ach.id) .. "]")
        end
        local numC = GetAchievementNumCriteria(ach.id) or 0
        if numC > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Your progress:", format("%d / %d (%.0f%%)", floor((ach.percent / 100) * numC + 0.5), numC, ach.percent), 1, 1, 1, 1, 1, 1)
        end
        if rewardText and rewardText ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Reward: " .. rewardText, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function()
        UIParentLoadAddOn("Blizzard_AchievementUI")
        local AF = _G["AchievementFrame"]
        if AF then AF:Show() end
        local selectFn = _G["AchievementFrame_SelectAchievement"]
        if type(selectFn) == "function" then
            selectFn(ach.id)
        else
            print("ACA: Could not select achievement, open and search manually.")
        end
    end)

    row._ignoreButton:SetScript("OnClick", function()
        ACA_IgnoreList[tonumber(ach.id)] = (not ACA_IgnoreList[tonumber(ach.id)]) or nil
        print(format("ACA: %s %s", ACA_IgnoreList[tonumber(ach.id)] and "Ignored" or "Unignored", ach.name or ach.id))
        ACA.scanResults = {}               -- invalidate cache
        ACA.scanResultsForThr = nil
        ACA.UpdatePanel(true)
    end)
    row._ignoreButton:SetText(ACA_IgnoreList[tonumber(ach.id)] and "✓" or "X")
end

----------------------------------------
-- 8.  Scanner (batched)  – SINGLE-SCAN GUARD
----------------------------------------
local scanning        = false          -- true while a scan coroutine is active
ACA.scanResults       = {}             -- the *one* master list we keep
ACA.scanResultsForThr = nil            -- threshold that produced the list

local function ScanAchievements(onComplete, onProgress)
    if scanning then return end          -- ignore re-entry
    scanning = true
    wipe(ACA.scanResults)
    ACA.scanResultsForThr = ACA_ScanThreshold

    C_Timer.After(0, function()
        local results, categories = ACA.scanResults, SafeGetCategoryList()
        local totalCategories = #categories
        local currentCat, currentAch = 1, 1
        local scanned, totalToScan = 0, 0
        local threshold = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD

        for ci = 1, totalCategories do
            totalToScan = totalToScan + (GetCategoryNumAchievements(categories[ci]) or 0)
        end

        local function step()
            local processed = 0
            while currentCat <= totalCategories and processed < ACA.BATCH_SIZE do
                local catID = categories[currentCat]
                local numAch = GetCategoryNumAchievements(catID) or 0
                if currentAch <= numAch then
                    local achID = select(1, GetAchievementInfo(catID, currentAch))
                    if achID and not ACA_IgnoreList[tonumber(achID)] then
                        local _, name, _, completed, _, _, _, _, _, icon = GetAchievementInfo(achID)
                        if not completed then
                            local percent = GetCompletionPercent(achID)
                            if percent >= threshold then
                                local _, _, _, _, _, _, _, _, _, _, rewardText = GetAchievementInfo(achID)
                                if not rewardText then
                                    local all = { GetAchievementInfo(achID) }
                                    rewardText = all[11] or all[12] or all[13] or ""
                                end
                                table.insert(results, {
                                    id = achID, name = name or "[" .. tostring(achID) .. "]",
                                    percent = percent, category = catID, icon = icon, reward = rewardText
                                })
                            end
                        end
                    end
                    currentAch = currentAch + 1
                    scanned, processed = scanned + 1, processed + 1
                    if onProgress then onProgress(scanned, totalToScan) end
                else
                    currentCat, currentAch = currentCat + 1, 1
                end
            end

            if currentCat > totalCategories then
                scanning = false
                if onComplete then onComplete(results) end
            else
                C_Timer.After(ACA.SCAN_DELAY, step)
            end
        end
        step()
    end)
end

----------------------------------------
-- 9.  Panel creation
----------------------------------------
local function CreateAlmostCompletedPanel()
    if _G[ACA_PANEL_NAME] then return _G[ACA_PANEL_NAME] end
    UIParentLoadAddOn("Blizzard_AchievementUI")
    local parent = _G["AchievementFrame"] or UIParent

    local panel = CreateFrame("Frame", ACA_PANEL_NAME, parent, "BackdropTemplate")
    panel:SetSize(420, 500)
    panel:SetPoint("TOPLEFT", parent, "TOPRIGHT", 10, 0)
    panel:SetBackdrop({
        bgFile = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropBorderColor(0.2, 0.15, 0.1)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetText("Almost Completed Achievements")

    -- tabs: Almost Completed, Ignored, Options
    local tab1 = CreateFrame("Button", panel:GetName() .. "Tab1", panel, "PanelTabButtonTemplate")
    tab1:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, -30)
    tab1:SetText("Almost Completed")

    local tab2 = CreateFrame("Button", panel:GetName() .. "Tab2", panel, "PanelTabButtonTemplate")
    tab2:SetPoint("LEFT", tab1, "RIGHT", -15, 0)
    tab2:SetText("Ignored")

    local tab3 = CreateFrame("Button", panel:GetName() .. "Tab3", panel, "PanelTabButtonTemplate")
    tab3:SetPoint("LEFT", tab2, "RIGHT", -15, 0)
    tab3:SetText("Options")

    PanelTemplates_SetNumTabs(panel, 3)
    PanelTemplates_SetTab(panel, 1)
    panel.tab1, panel.tab2, panel.tab3 = tab1, tab2, tab3

    local contentCompleted = CreateFrame("Frame", nil, panel)
    contentCompleted:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -50)
    contentCompleted:SetSize(396, 390)
    local contentIgnored = CreateFrame("Frame", nil, panel)
    contentIgnored:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -50)
    contentIgnored:SetSize(396, 390)
    contentIgnored:Hide()
    local contentOptions = CreateFrame("Frame", nil, panel)
    contentOptions:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -50)
    contentOptions:SetSize(396, 390)
    contentOptions:Hide()
    panel.contentCompleted, panel.contentIgnored, panel.contentOptions = contentCompleted, contentIgnored, contentOptions

    local scrollCompleted = CreateFrame("ScrollFrame", nil, contentCompleted, "UIPanelScrollFrameTemplate")
    scrollCompleted:SetPoint("TOPLEFT", contentCompleted, "TOPLEFT", 0, 0)
    scrollCompleted:SetPoint("BOTTOMRIGHT", contentCompleted, "BOTTOMRIGHT", -25, 0)
    local childCompleted = CreateFrame("Frame", nil, scrollCompleted)
    childCompleted:SetSize(396, 600)
    scrollCompleted:SetScrollChild(childCompleted)
    panel.scrollCompleted, panel.childCompleted = scrollCompleted, childCompleted

    local scrollIgnored = CreateFrame("ScrollFrame", nil, contentIgnored, "UIPanelScrollFrameTemplate")
    scrollIgnored:SetPoint("TOPLEFT", contentIgnored, "TOPLEFT", 0, 0)
    scrollIgnored:SetPoint("BOTTOMRIGHT", contentIgnored, "BOTTOMRIGHT", -25, 0)
    local childIgnored = CreateFrame("Frame", nil, scrollIgnored)
    childIgnored:SetSize(396, 600)
    scrollIgnored:SetScrollChild(childIgnored)
    panel.scrollIgnored, panel.childIgnored = scrollIgnored, childIgnored

    -- === Progress bar (forest-green fill) ===
    local scanBar = CreateFrame("StatusBar", nil, panel, "TextStatusBar")
    scanBar:SetSize(180, 18)
    scanBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 20, 18)
    scanBar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
    scanBar:GetStatusBarTexture():SetHorizTile(false)
    scanBar:GetStatusBarTexture():SetVertexColor(0, 0.8, 0.2, 1)   -- emerald green
    scanBar:SetMinMaxValues(0, 1)
    scanBar:SetValue(0)
    scanBar:SetMovable(false)
    scanBar.bg = scanBar:CreateTexture(nil, "BACKGROUND")
    scanBar.bg:SetAllPoints(scanBar)
    scanBar.bg:SetColorTexture(0.1, 0.1, 0.1, 0.6)
    scanBar.Text = scanBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanBar.Text:SetPoint("CENTER", scanBar, "CENTER", 0, 0)
    scanBar.Text:SetText("Idle")
    panel.scanBar = scanBar

    -- reward-filter dropdown
    local filterDropdown = CreateFrame("Frame", nil, panel, "UIDropDownMenuTemplate")
    filterDropdown:SetPoint("BOTTOMLEFT", scanBar, "BOTTOMRIGHT", 16, -6)
    UIDropDownMenu_SetWidth(filterDropdown, 140)
    UIDropDownMenu_SetText(filterDropdown, ACA_FilterMode)
    panel.filterDropdown = filterDropdown

    local function FilterDropdown_Initialize(self, level)
        local info = UIDropDownMenu_CreateInfo()
        for _, option in ipairs(FILTER_LIST) do
            info.text = option
            info.func = function()
                ACA_FilterMode = option
                UIDropDownMenu_SetText(filterDropdown, option)
                ACA.UpdatePanel(false)
            end
            info.checked = (ACA_FilterMode == option)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(filterDropdown, FilterDropdown_Initialize)

    -- refresh / clear buttons
    local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    refresh:SetSize(80, 22)
    refresh:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -10)
    refresh:SetText("Rescan")
    refresh:GetFontString():SetTextColor(1, 1, 1)
    panel.refresh = refresh

    local clearAllBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearAllBtn:SetSize(100, 24)
    clearAllBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 14)
    clearAllBtn:SetText("Clear All")
    clearAllBtn:Hide()
    panel.clearAllBtn = clearAllBtn

    -- === Options tab contents ===
    local slider = CreateFrame("Slider", nil, contentOptions, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 12, -12)
    slider:SetWidth(220)
    slider:SetMinMaxValues(ACA.SLIDER_MIN, ACA.SLIDER_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(ACA_ScanThreshold)
    slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    slider.Text:SetPoint("TOP", slider, "TOP", 0, -18)
    slider.Text:SetText("Scan Threshold: " .. tostring(ACA_ScanThreshold) .. "%")
    panel.optionsSlider = slider

    local optText = contentOptions:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    optText:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -12)
    optText:SetText("Set the completion % threshold used when scanning.\nChanges are debounced to avoid excessive rescans.")
    optText:SetJustifyH("LEFT")

    local function ShowTab(idx)
        PanelTemplates_SetTab(panel, idx)
        if idx == 1 then
            contentCompleted:Show(); contentIgnored:Hide(); contentOptions:Hide()
            panel.scanBar:Show()
            panel.optionsSlider:Hide()
            refresh:Show(); clearAllBtn:Hide()
        elseif idx == 2 then
            contentCompleted:Hide(); contentIgnored:Show(); contentOptions:Hide()
            panel.scanBar:Hide()
            panel.optionsSlider:Hide()
            refresh:Hide(); clearAllBtn:Show()
        else -- idx == 3 (Options)
            contentCompleted:Hide(); contentIgnored:Hide(); contentOptions:Show()
            panel.scanBar:Hide()
            panel.optionsSlider:Show()
            refresh:Hide(); clearAllBtn:Hide()
        end
    end
    tab1:SetScript("OnClick", function() ShowTab(1); ACA.UpdatePanel(false) end)
    tab2:SetScript("OnClick", function() ShowTab(2); ACA.UpdatePanel(false) end)
    tab3:SetScript("OnClick", function() ShowTab(3); ACA.UpdatePanel(false) end)

    slider:SetScript("OnValueChanged", function(self, value)
        local v = floor(value)
        ACA_ScanThreshold = v
        self.Text:SetText("Scan Threshold: " .. v .. "%")
        if pendingSliderRescanCancel then pendingSliderRescanCancel() end
        local cancelled = false
        pendingSliderRescanCancel = function() cancelled = true end
        C_Timer.After(0.5, function()
            if cancelled then return end
            ACA.scanResults = {}
            ACA.scanResultsForThr = nil
            ACA.UpdatePanel(true)
            pendingSliderRescanCancel = nil
        end)
    end)

    refresh:SetScript("OnClick", function()
        ACA.scanResults = {}
        ACA.scanResultsForThr = nil
        ACA.UpdatePanel(true)
    end)
    clearAllBtn:SetScript("OnClick", function()
        ACA_IgnoreList = {}
        ACA.scanResults = {}
        ACA.scanResultsForThr = nil
        print("ACA: Cleared ignore list.")
        ACA.UpdatePanel(true)
    end)

    _G[ACA_PANEL_NAME] = panel
    ShowTab(1)
    return panel
end

----------------------------------------
-- 10.  Update panel  –  CACHE-FIRST + WIPE ROWS
----------------------------------------
function ACA.UpdatePanel(forceRescan)
    local panel = CreateAlmostCompletedPanel()
    if not panel then return end
    local completedChild, ignoredChild = panel.childCompleted, panel.childIgnored

    local threshold = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD

    --------------------------------------------------
    -- Ignored tab – WIPE then rebuild
    --------------------------------------------------
    if PanelTemplates_GetSelectedTab(panel) == 2 then
        WipeChildren(ignoredChild)   -- CLEAR OLD ROWS
        local ignored = {}
        for id in pairs(ACA_IgnoreList) do
            local aid = tonumber(id)
            if aid then
                local _, name, _, _, _, _, _, _, _, icon = GetAchievementInfo(aid)
                table.insert(ignored, {
                    id = aid, name = name or "[" .. tostring(aid) .. "]",
                    percent = GetCompletionPercent(aid), icon = icon
                })
            end
        end
        sort(ignored, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
        for i, ach in ipairs(ignored) do
            local row = AcquireRow(ignoredChild)
            row:SetPoint("TOPLEFT", ignoredChild, "TOPLEFT", 6, -((i - 1) * (ACA.ROW_HEIGHT + 4) + 6))
            ACA:PopulateNativeRow(row, ach)
            row._ignoreButton:SetText("✓")
            row._ignoreButton:SetScript("OnClick", function()
                ACA_IgnoreList[tonumber(ach.id)] = nil
                print("ACA: Unignored " .. (ach.name or ach.id))
                ACA.scanResults = {}
                ACA.scanResultsForThr = nil
                ACA.UpdatePanel(true)
            end)
        end
        ignoredChild:SetHeight(math.max(200, (#ignored * (ACA.ROW_HEIGHT + 4)) + 20))
        return
    end

    --------------------------------------------------
    -- Completed tab – CACHE FIRST + WIPE ROWS
    --------------------------------------------------
    local needFreshScan = forceRescan
                     or not ACA.scanResultsForThr
                     or ACA.scanResultsForThr ~= threshold
                     or #ACA.scanResults == 0

    local function display(results)
        WipeChildren(completedChild)   -- CLEAR OLD ROWS
        -- apply reward filter
        local filtered = {}
        local filtFn = FILTERS[ACA_FilterMode] or FILTERS["All"]
        for _, v in ipairs(results) do
            if filtFn(v.reward or "") then table.insert(filtered, v) end
        end
        sort(filtered, function(a, b) return a.percent > b.percent end)

        for i, ach in ipairs(filtered) do
            local row = AcquireRow(completedChild)
            row:SetPoint("TOPLEFT", completedChild, "TOPLEFT", 6, -((i - 1) * (ACA.ROW_HEIGHT + 4) + 6))
            ACA:PopulateNativeRow(row, ach)
        end
        completedChild:SetHeight(math.max(200, (#filtered * (ACA.ROW_HEIGHT + 4)) + 20))

        -- reset progress bar
        local p = _G[ACA_PANEL_NAME]
        if p and p.scanBar then
            p.scanBar:SetMinMaxValues(0, 1)
            p.scanBar:SetValue(0)
            p.scanBar.Text:SetText("Idle")
        end
    end

    if needFreshScan then
        ScanAchievements(display, function(scanned, total)
            local p = _G[ACA_PANEL_NAME]
            if p and p.scanBar and p.scanBar.Text then
                if total and total > 0 then
                    p.scanBar:SetMinMaxValues(0, total)
                    p.scanBar:SetValue(scanned)
                    local pct = (scanned / total) * 100
                    p.scanBar.Text:SetText(format("Scanning... %d/%d (%.0f%%)", scanned, total, pct))
                else
                    p.scanBar:SetMinMaxValues(0, 1)
                    p.scanBar:SetValue(0)
                    p.scanBar.Text:SetText("Scanning... 0/0")
                end
            end
        end)
    else
        display(ACA.scanResults)   -- instant re-filter
    end
end

----------------------------------------
-- 11.  Loader & slash
----------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ACA_ScanThreshold   = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD
        ACA_Cache           = ACA_Cache or {}
        ACA_IgnoreList      = ACA_IgnoreList or {}
        ACA_FilterMode      = ACA_FilterMode or "All"
        if ACA_Blacklist and type(ACA_Blacklist)=="table" then
            for id in pairs(ACA_Blacklist) do
                ACA_IgnoreList[tonumber(id)] = true
            end
            print("ACA: imported "..#(ACA_Blacklist).." entries from old blacklist.")
            ACA_Blacklist = nil
        end
        CreateAlmostCompletedPanel()      -- create our frame (starts hidden)

    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_AchievementUI" then
        -- Blizzard achievement window now exists; hook its OnShow
        AchievementFrame:HookScript("OnShow", function()
            local p = _G[ACA_PANEL_NAME]
            if p then
                p:Show()
                PanelTemplates_SetTab(p, 1)
                ACA.UpdatePanel(false)
            end
        end)
    end
end)

--------------------------------------------------
-- auto-show once after login if user wants it
--------------------------------------------------
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_ENTERING_WORLD")
login:SetScript("OnEvent", function(_, _)
    login:UnregisterEvent("PLAYER_ENTERING_WORLD")   -- only once
    C_Timer.After(3, function()                      -- give every UI piece time
        if not AchievementFrame or not AchievementFrame:IsShown() then
            SlashCmdList["ALMOSTCOMPLETED"]()        -- same as typing /aca
        end
    end)
end)

SLASH_ALMOSTCOMPLETED1 = "/aca"
SlashCmdList["ALMOSTCOMPLETED"] = function()
    local p = CreateAlmostCompletedPanel()
    if p then p:Show(); ACA.UpdatePanel(false) end
end

-- expose
ACA.UpdatePanel = ACA.UpdatePanel
ACA.GetCompletionPercent = GetCompletionPercent
