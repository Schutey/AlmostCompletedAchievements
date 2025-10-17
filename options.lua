-- options.lua
local ADDON, ACA = ...
local panelName = ACA_PANEL_NAME

local function InjectOptionsUI()
    local panel = _G[panelName]
    if not panel or not panel.contentOptions then return end
    local contentOptions = panel.contentOptions

    -- slider box (backdrop)
    local sliderBox = CreateFrame("Frame", nil, contentOptions, "BackdropTemplate")
    sliderBox:SetSize(360, 64)
    sliderBox:SetPoint("TOP", contentOptions, "TOP", 0, -70)
    sliderBox:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    sliderBox:SetBackdropColor(0.1, 0.1, 0.1, 0.4)
    sliderBox:SetBackdropBorderColor(0.4, 0.4, 0.4)

    local slider = CreateFrame("Slider", nil, sliderBox, "OptionsSliderTemplate")
    slider:SetPoint("CENTER", sliderBox, "CENTER", 0, 0)
    slider:SetWidth(320)
    slider:SetMinMaxValues(ACA.SLIDER_MIN, ACA.SLIDER_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(ACA_ScanThreshold)

    slider.Text = slider:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    slider.Text:SetPoint("BOTTOM", slider, "TOP", 0, 5)
    slider.Text:SetText("Scan Threshold: " .. tostring(ACA_ScanThreshold) .. "%")
    panel.optionsSlider = slider

    
    -- helper note under the slider
    local perfNote = slider:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    perfNote:SetPoint("TOP", slider, "BOTTOM", 0, -6)
    perfNote:SetText("Lower threshold = more results = slower.")
    slider.perfNote = perfNote

    local function UpdatePerfNote(v)
        local r, g, b = 1, 0.6, 0.2 -- orange default
        if v >= 90 then r, g, b = 0.6, 1.0, 0.6 elseif v <= 50 then r, g, b = 1.0, 0.4, 0.4 end
        perfNote:SetTextColor(r, g, b)
    end
    UpdatePerfNote(ACA_ScanThreshold)
-- debounce rescans while dragging the slider
    local _ACA_sliderPending
    -- debounce rescans while dragging the slider
    slider:SetScript("OnValueChanged", function(self, value)
        local v = math.floor(value)
        ACA_ScanThreshold = v
        self.Text:SetText("Scan Threshold: " .. v .. "%")
        if UpdatePerfNote then UpdatePerfNote(v) end
        if _ACA_sliderPending then _ACA_sliderPending:Cancel(); _ACA_sliderPending = nil end
        _ACA_sliderPending = C_Timer.NewTimer(0.35, function()
            _ACA_sliderPending = nil
            if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
        end)
    end)

    -- parse speed dropdown
    local parseLabel = contentOptions:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    parseLabel:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 12, -12)
    parseLabel:SetText("Scan Speed:")

    local parseDropdown = CreateFrame("Frame", "ACAParseDrop", contentOptions, "UIDropDownMenuTemplate"); panel.contentOptions.ACAParseDrop = parseDropdown
    parseDropdown:SetPoint("TOPLEFT", parseLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(parseDropdown, 110)
    UIDropDownMenu_SetText(parseDropdown, ACA_ParseSpeed or "Auto")

    local function ParseDropdown_Initialize(self)
        local info = UIDropDownMenu_CreateInfo()
        for _, key in ipairs({ "Auto", "Fast", "Smooth", "Slow" }) do
            info.text = key
            info.func = function()
                ACA_ParseSpeed = key
                UIDropDownMenu_SetText(parseDropdown, key)
                if key ~= "Auto" then
                    local preset = ACA.SPEED_PRESETS and ACA.SPEED_PRESETS[key]
                    if preset then
                        ACA.BATCH_SIZE = preset.batch
                        ACA.SCAN_DELAY = preset.delay
                    end
                end
            end
            info.checked = (ACA_ParseSpeed == key)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(parseDropdown, ParseDropdown_Initialize)

    -- anchor dropdown
    local anchorLabel = contentOptions:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    anchorLabel:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 240, -12)
    anchorLabel:SetText("Anchor:")

    local anchorDropdown = CreateFrame("Frame", "ACAAnchorDrop", contentOptions, "UIDropDownMenuTemplate"); panel.contentOptions.ACAAnchorDrop = anchorDropdown
    anchorDropdown:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(anchorDropdown, 90)
    UIDropDownMenu_SetText(anchorDropdown, ACA_AnchorSide)

    local function AnchorDropdown_Initialize(self)
        local info = UIDropDownMenu_CreateInfo()
        for _, side in ipairs({ "LEFT", "RIGHT" }) do
            info.text = side
            info.func = function()
                ACA_AnchorSide = side
                UIDropDownMenu_SetText(anchorDropdown, side)
                local p = _G[panelName]
                if p and AchievementFrame then
                    p:ClearAllPoints()
                    p:SetPoint(side == "RIGHT" and "TOPLEFT" or "TOPRIGHT",
                               AchievementFrame,
                               side == "RIGHT" and "TOPRIGHT" or "TOPLEFT",
                               side == "RIGHT" and 10 or -10, 0)
                end
            end
            info.checked = (ACA_AnchorSide == side)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(anchorDropdown, AnchorDropdown_Initialize)
end

-- run once when addon loads (ADDON_LOADED handler elsewhere)
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(_, _, name)
    if name == "AlmostCompletedAchievements" then
        C_Timer.After(0.3, function()
            InjectOptionsUI()
        end)
        loader:UnregisterAllEvents()
    end
end)