-- ==========================================
-- Almost Completed Achievements Addon
-- Highlights achievements that are nearly complete
-- ==========================================

-- Default scan threshold (percent complete)
if not ACA_ScanThreshold then
    ACA_ScanThreshold = 80
end

-- Track whether we've scanned achievements this session
local hasScannedThisSession = false

-- Ensure Blizzard's Achievement UI is loaded
UIParentLoadAddOn("Blizzard_AchievementUI")

-- SavedVariable for blacklisted achievement IDs
if not ACA_Blacklist then
    ACA_Blacklist = {}
end

-- Helper: Calculate completion percentage for an achievement
local function GetCompletionPercent(achievementID)
    local numCriteria = GetAchievementNumCriteria(achievementID)
    if not numCriteria or numCriteria == 0 then return 0 end

    local completed = 0
    for i = 1, numCriteria do
        local _, _, done = GetAchievementCriteriaInfo(achievementID, i)
        if done then
            completed = completed + 1
        end
    end

    return (completed / numCriteria) * 100
end

-- Achievement Scanner: scans all achievements and filters by threshold
local function ScanAchievements(callback, updateProgress)
    local results = {}
    local categories = GetCategoryList()
    local currentCategory = 1
    local currentAchievement = 1
    local batchSize = 20

    local function scanStep()
        local scanned = 0

        while currentCategory <= #categories and scanned < batchSize do
            local categoryID = categories[currentCategory]
            local numAchievements = GetCategoryNumAchievements(categoryID)

            if currentAchievement <= numAchievements then
                local achievementID = select(1, GetAchievementInfo(categoryID, currentAchievement))
                if achievementID then
                    -- Skip blacklisted achievements
                    if not ACA_Blacklist[achievementID] then
                        local _, name, _, completed = GetAchievementInfo(achievementID)
                        if not completed then
                            local percent = GetCompletionPercent(achievementID)
                            if percent >= ACA_ScanThreshold then
                                table.insert(results, {
                                    id = achievementID,
                                    name = name,
                                    percent = percent
                                })
                            end
                        end
                    end
                end
                currentAchievement = currentAchievement + 1
                scanned = scanned + 1

                if updateProgress then
                    updateProgress(currentCategory, currentAchievement)
                end
            else
                currentCategory = currentCategory + 1
                currentAchievement = 1
            end
        end

        if currentCategory > #categories then
            table.sort(results, function(a, b) return a.percent > b.percent end)
            callback(results)
        else
            C_Timer.After(0.01, scanStep)
        end
    end

    scanStep()
end

-- Create the floating panel beside the Achievement UI
local function CreateAlmostCompletedPanel()
    if AlmostCompletedPanel then return end

    -- Create main panel and assign immediately to global
    local panel = CreateFrame("Frame", "AlmostCompletedPanel", AchievementFrame, "BackdropTemplate")
    AlmostCompletedPanel = panel

    panel:SetSize(360, 500)
    panel:SetPoint("TOPLEFT", AchievementFrame, "TOPRIGHT", 10, 0)
    panel:SetBackdrop({
        bgFile = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })

    -- Title header
    local titleFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    titleFrame:SetSize(320, 24)
    titleFrame:SetPoint("TOP", panel, "TOP", 0, -10)
    titleFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    titleFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    titleFrame:SetBackdropBorderColor(0.3, 0.3, 0.3)

    local titleText = titleFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("CENTER", titleFrame, "CENTER", 0, 0)
    titleText:SetText("Almost Completed Achievements")
    titleText:SetTextColor(1.0, 0.82, 0.0)

    -- Threshold slider container
    local sliderContainer = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    sliderContainer:SetSize(220, 36)
    sliderContainer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    sliderContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    sliderContainer:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    sliderContainer:SetBackdropBorderColor(0.3, 0.3, 0.3)

    -- Threshold slider
    local slider = CreateFrame("Slider", nil, sliderContainer, "OptionsSliderTemplate")
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(200, 14)
    slider:SetPoint("TOP", sliderContainer, "TOP", 0, -4)
    slider:SetMinMaxValues(50, 100)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(ACA_ScanThreshold or 80)

    -- Slider label
    slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    slider.Text:SetPoint("BOTTOM", sliderContainer, "BOTTOM", 0, 4)
    slider.Text:SetText("Scan Threshold: " .. ACA_ScanThreshold .. "%")

    slider:SetScript("OnValueChanged", function(self, value)
        ACA_ScanThreshold = math.floor(value)
        self.Text:SetText("Scan Threshold: " .. ACA_ScanThreshold .. "%")
    end)

    panel.thresholdSlider = slider
    panel.sliderContainer = sliderContainer

    -- Scroll frame for achievement buttons
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scrollFrame:SetSize(340, 380) -- Reduced height to leave room for slider/refresh
    scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -40)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetSize(340, 420)
    scrollFrame:SetScrollChild(content)

    panel.scrollFrame = scrollFrame
    panel.content = content

    -- Progress bar container
    local progressContainer = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    progressContainer:SetSize(340, 22)
    progressContainer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
    progressContainer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    progressContainer:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    progressContainer:SetBackdropBorderColor(0.3, 0.3, 0.3)

    local progressBar = CreateFrame("StatusBar", nil, progressContainer)
    progressBar:SetSize(334, 14)
    progressBar:SetPoint("CENTER", progressContainer, "CENTER", 0, 0)
    progressBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    progressBar:SetMinMaxValues(0, 100)
    progressBar:SetValue(0)
    progressBar:SetStatusBarColor(0.22, 0.72, 0.0)

    local bg = progressBar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(true)
    bg:SetColorTexture(0.05, 0.05, 0.05, 0.6)

    local progressText = progressBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    progressText:SetPoint("CENTER", progressBar, "CENTER", 0, 0)
    progressText:SetText("Scanning...")

    panel.progressBar = progressBar
    panel.progressText = progressText
    panel.progressContainer = progressContainer

    -- Manual refresh button
    local refreshButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    refreshButton:SetSize(100, 24)
    refreshButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
    refreshButton:SetText("Refresh")
    refreshButton:SetScript("OnClick", function()
        UpdateAlmostCompletedPanel()
    end)

    panel.refreshButton = refreshButton

    -- Hide slider and refresh button initially to prevent flicker
    panel.sliderContainer:Hide()
    panel.refreshButton:Hide()
end

-- Helper to create achievement row with a button and X button
local function CreateAchievementRow(parent, ach, yOffset, blacklistCallback)
    local rowWidth = 292 -- leave room for X button
    local rowHeight = 24

    -- Achievement button
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(rowWidth, rowHeight)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yOffset)
    button:SetText(string.format("%.0f%% - %s", ach.percent, ach.name))
    button:SetScript("OnClick", function()
        AchievementFrame_SelectAchievement(ach.id)
    end)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")

    -- X button (Blacklist)
    local xButton = CreateFrame("Button", nil, parent)
    xButton:SetSize(20, 20)
    xButton:SetPoint("LEFT", button, "RIGHT", 4, 0)
    xButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    xButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    xButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
    xButton:SetScript("OnClick", function()
        blacklistCallback(ach.id)
    end)
    xButton:SetMotionScriptsWhileDisabled(true)

    -- Tooltip for X button
    xButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Blacklist this achievement from future scans.\nUse /acareset to reset the blacklist.", nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    xButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Blacklist helper
local function BlacklistAchievement(achievementID)
    ACA_Blacklist[achievementID] = true
    -- Remove the achievement from the current visible list without triggering a new scan
    if AlmostCompletedPanel and AlmostCompletedPanel._currentAchievements then
        for i, ach in ipairs(AlmostCompletedPanel._currentAchievements) do
            if ach.id == achievementID then
                table.remove(AlmostCompletedPanel._currentAchievements, i)
                break
            end
        end
        -- Refresh the visible list only
        local panel = AlmostCompletedPanel
        local content = panel.content
        -- Clear previous rows
        for _, child in ipairs({ content:GetChildren() }) do
            child:Hide()
            child:SetParent(nil)
        end
        -- Recreate achievement rows
        local yOffset = -10
        for _, ach in ipairs(panel._currentAchievements) do
            CreateAchievementRow(content, ach, yOffset, BlacklistAchievement)
            yOffset = yOffset - 28
        end
        content:SetHeight(#panel._currentAchievements * 28 + 50)
    end
end

-- Update the panel with scanned achievements
function UpdateAlmostCompletedPanel()
    if not AlmostCompletedPanel then return end

    local panel = AlmostCompletedPanel
    local content = panel.content
    local scrollFrame = panel.scrollFrame
    local scrollBar = panel.scrollBar
    local progressBar = panel.progressBar
    local progressText = panel.progressText
    local progressContainer = panel.progressContainer
    local refreshButton = panel.refreshButton
    local sliderContainer = panel.sliderContainer

    -- Safety check to prevent nil access
    if not refreshButton or not sliderContainer then
        print("Warning: UI elements not initialized yet.")
        return
    end

    -- Clear previous rows
    for _, child in ipairs({ content:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end

    -- Reset progress visuals
    progressBar:SetValue(0)
    progressText:SetText("Scanning...")
    progressBar:Show()
    progressText:Show()
    progressContainer:Show()

    -- Hide refresh button and slider during scan
    refreshButton:Hide()
    sliderContainer:Hide()

    -- Begin scanning
    ScanAchievements(function(nudges)
        -- Hide progress visuals after scan
        progressBar:Hide()
        progressText:Hide()
        progressContainer:Hide()

        -- Show refresh button and slider after scan
        refreshButton:Show()
        sliderContainer:Show()

        -- Save current achievements for blacklist removal
        panel._currentAchievements = nudges

        -- Create achievement rows
        local yOffset = -10
        for _, ach in ipairs(nudges) do
            CreateAchievementRow(content, ach, yOffset, BlacklistAchievement)
            yOffset = yOffset - 28
        end

        content:SetHeight(#nudges * 28 + 50)
    end,
    function(categoryIndex, achievementIndex)
        local totalCategories = #GetCategoryList()
        local progress = ((categoryIndex - 1) / totalCategories) * 100
        progressBar:SetValue(progress)
        progressText:SetText(string.format("Scanning... %.0f%%", progress))
    end)
end

-- Initialization and hook setup
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event, addonName)
    if event == "ADDON_LOADED" and (addonName == "Blizzard_AchievementUI" or addonName == "AlmostCompletedAchievements") then
        CreateAlmostCompletedPanel()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if AchievementFrame and not AchievementFrame._nudgesHooked then
            AchievementFrame._nudgesHooked = true
            AchievementFrame:HookScript("OnShow", function()
                -- Delay to ensure panel is fully initialized
                C_Timer.After(0.1, function()
                    AlmostCompletedPanel:Show()
                    if not hasScannedThisSession then
                        hasScannedThisSession = true
                        C_Timer.After(0.4, UpdateAlmostCompletedPanel)
                    end
                end)
            end)
        end
    end
end)

-- Slash command to manually show ACA panel
SLASH_ALMOSTCOMPLETED1 = "/aca"
SlashCmdList["ALMOSTCOMPLETED"] = function()
    if not AlmostCompletedPanel then
        CreateAlmostCompletedPanel()
    end
    UpdateAlmostCompletedPanel()
    AlmostCompletedPanel:Show()
end

-- Slash command to reset blacklist
SLASH_ACARESET1 = "/acareset"
SlashCmdList["ACARESET"] = function()
    ACA_Blacklist = {}
    print("Almost Completed Achievements: Blacklist cleared.")
    if AlmostCompletedPanel then
        UpdateAlmostCompletedPanel()
    end
end
