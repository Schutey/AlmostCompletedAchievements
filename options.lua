-- options.lua
local ADDON, ACA = ...
local panelName = ACA_PANEL_NAME

local function InjectOptionsUI()
    local panel = _G[panelName]
    if not panel or not panel.contentOptions then return end
    local contentOptions = panel.contentOptions
    -- attempt to discover a reset button by scanning children if not explicitly known
    local function _FindResetButton(container)
        if not container or not container.GetChildren then return nil end
        local __kids = { container:GetChildren() }
        for _, child in ipairs(__kids) do
            if child and child.IsObjectType and child:IsObjectType("Button") then
                local fs = child.GetText and child:GetText()
                if fs and fs:lower():find("reset") then
                    return child
                end
                -- some buttons use nested FontStrings
                if child.GetFontString and child:GetFontString() then
                    local t = child:GetFontString():GetText()
                    if t and t:lower():find("reset") then
                        return child
                    end
                end
            end
        end
        return nil
    end


    --------------------------------------------------------------------
    -- Threshold slider: move to the bottom next to the Reset button.
    -- It will stretch horizontally and sit in the footer similar to
    -- Tab 1's scan progress bar, but sized for a slider.
    --------------------------------------------------------------------

    -- Try to find a Reset button to sit beside. Fall back gracefully.
    local resetBtn =
          (contentOptions.ResetButton and contentOptions.ResetButton:IsObjectType("Button") and contentOptions.ResetButton)
       or (contentOptions.resetButton and contentOptions.resetButton:IsObjectType("Button") and contentOptions.resetButton)
       or (contentOptions.btnReset and contentOptions.btnReset:IsObjectType("Button") and contentOptions.btnReset)
       or (contentOptions.ResetBtn and contentOptions.ResetBtn:IsObjectType("Button") and contentOptions.ResetBtn)
       or (panel.ResetButton and panel.ResetButton:IsObjectType("Button") and panel.ResetButton)
       or (panel.resetButton and panel.resetButton:IsObjectType("Button") and panel.resetButton)
       or (_G.ACAOptionsResetButton and _G.ACAOptionsResetButton:IsObjectType("Button") and _G.ACAOptionsResetButton)
       or _FindResetButton(contentOptions) or _FindResetButton(panel) or nil

    -- container that provides a subtle background and lets us stretch by anchoring L/R
    local sliderBox = CreateFrame("Frame", nil, contentOptions, "BackdropTemplate")
    sliderBox:SetHeight(26)
    sliderBox:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    sliderBox:SetBackdropColor(0.08, 0.08, 0.08, 0.35)
    sliderBox:SetBackdropBorderColor(0.35, 0.35, 0.35)

        -- Anchor in the footer: align vertically with Reset and match scan bar width if present
    sliderBox:ClearAllPoints()

    -- Try to locate a scan progress bar from Tab 1 to mirror its width.
    local scanBar =
          (panel.scanBar and panel.scanBar.GetObjectType and panel.scanBar)
       or (panel.ScanBar and panel.ScanBar.GetObjectType and panel.ScanBar)
       or (panel.scanStatusBar and panel.scanStatusBar.GetObjectType and panel.scanStatusBar)
       or (_G.ACAScanBar and _G.ACAScanBar.GetObjectType and _G.ACAScanBar)
       or nil

    if scanBar and resetBtn then
        -- Match left/right to the scan bar and align bottoms with Reset
        sliderBox:SetPoint("LEFT",  scanBar,   "LEFT",  0, 0)
        sliderBox:SetPoint("RIGHT", scanBar,   "RIGHT", 0, 0)
        sliderBox:SetPoint("BOTTOM", resetBtn, "BOTTOM", 0, 0)
    elseif scanBar then
        -- No Reset found; still mirror scan bar width and sit above bottom padding
        sliderBox:SetPoint("LEFT",  scanBar, "LEFT",  0, 0)
        sliderBox:SetPoint("RIGHT", scanBar, "RIGHT", 0, 0)
        sliderBox:SetPoint("BOTTOM", contentOptions, "BOTTOM", 0, 16)
    elseif resetBtn then
        -- No scan bar handle; align bottom with Reset and stretch to its left
        sliderBox:SetPoint("BOTTOMLEFT", contentOptions, "BOTTOMLEFT", 12, 0)
        sliderBox:SetPoint("RIGHT", resetBtn, "LEFT", -12, 0)
        sliderBox:SetPoint("BOTTOM", resetBtn, "BOTTOM", 0, 0)
    else
        -- Last resort: stretch neatly across the footer
        sliderBox:SetPoint("BOTTOMLEFT", contentOptions, "BOTTOMLEFT", 12, 16)
        sliderBox:SetPoint("BOTTOMRIGHT", contentOptions, "BOTTOMRIGHT", -12, 16)
    end

    -- slider inside the box

    local slider = CreateFrame("Slider", nil, sliderBox, "OptionsSliderTemplate")
    slider:SetObeyStepOnDrag(true)
    slider:SetMinMaxValues(ACA.SLIDER_MIN, ACA.SLIDER_MAX)
    slider:SetValueStep(1)
    slider:SetValue(ACA_ScanThreshold or 75)  -- preserve existing saved value if present

    -- Label sits inline at the left of the bar, so the whole control fits the footer height
    if slider.Text then slider.Text:Hide() end  -- the template may auto-create one; we'll manage placement
    slider.Text = sliderBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    slider.Text:SetPoint("LEFT", sliderBox, "LEFT", 8, 0)
    slider.Text:SetJustifyH("LEFT")
    slider.Text:SetText("Threshold: " .. tostring(ACA_ScanThreshold or 75) .. "%")

    -- Lay out the slider track from the end of the label to the right padding
    slider:ClearAllPoints()
    slider:SetPoint("LEFT", slider.Text, "RIGHT", 8, 0)
    slider:SetPoint("RIGHT", sliderBox, "RIGHT", -8, 0)
    slider:SetHeight(14)

    panel.optionsSlider = slider

    -- small performance hint above the bar to avoid crowding the footer line
    local perfNote = sliderBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    perfNote:SetPoint("BOTTOMLEFT", sliderBox, "TOPLEFT", 2, 2)
    perfNote:SetJustifyH("LEFT")
    perfNote:SetText("Lower threshold shows more results but can be slower.")
    slider.perfNote = perfNote

    local function UpdatePerfNote(v)
        local r, g, b = 1, 0.75, 0.3 -- default warm
        if v >= 90 then r, g, b = 0.6, 1.0, 0.6
        elseif v <= 50 then r, g, b = 1.0, 0.45, 0.45 end
        perfNote:SetTextColor(r, g, b)
    end
    UpdatePerfNote(ACA_ScanThreshold or 75)

    -- Debounce rescans while dragging
    local _ACA_sliderPending
    slider:SetScript("OnValueChanged", function(self, value)
        local v = math.floor(value)
        ACA_ScanThreshold = v
        self.Text:SetText("Threshold: " .. v .. "%")
        UpdatePerfNote(v)
        if _ACA_sliderPending then _ACA_sliderPending:Cancel(); _ACA_sliderPending = nil end
        _ACA_sliderPending = C_Timer.NewTimer(0.35, function()
            _ACA_sliderPending = nil
            if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
        end)
    end)

    --------------------------------------------------------------------
    -- Dropdowns: mirror Tab 1 anchors (from previous step), untouched.
    --------------------------------------------------------------------

    -- parse speed dropdown
    local parseLabel = contentOptions:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    parseLabel:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 0, 10)
    parseLabel:SetText("Scan Speed:")

    local parseDropdown = CreateFrame("Frame", "ACAParseDrop", contentOptions, "UIDropDownMenuTemplate"); panel.contentOptions.ACAParseDrop = parseDropdown
    parseDropdown:SetPoint("TOPLEFT", parseLabel, "BOTTOMLEFT", -10, -4)
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
    anchorLabel:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 190, 10)
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

    --------------------------------------------------------------------
    -- Top 5 mini window controls: Toggle button + inline checkboxes
    -- Placed under the category/expansion filter area in Tab 3.
    --------------------------------------------------------------------
    local controlsBox = CreateFrame("Frame", nil, contentOptions)
    controlsBox:SetSize(360, 28)
    controlsBox:SetPoint("TOPLEFT", contentOptions, "TOPLEFT", 0, -210) 

    local toggleBtn = CreateFrame("Button", nil, controlsBox, "UIPanelButtonTemplate")
    toggleBtn:SetSize(120, 22)
    toggleBtn:SetPoint("LEFT", controlsBox, "LEFT", 0, -85)
    toggleBtn:SetText("Top 5 Window")
    toggleBtn:SetScript("OnClick", function()
        if ACA and ACA.Top5_Toggle then ACA.Top5_Toggle() end
    end)

    local lockCB = CreateFrame("CheckButton", nil, controlsBox, "UICheckButtonTemplate")
    lockCB:SetPoint("LEFT", toggleBtn, "RIGHT", 12, 0)
    lockCB.Text:SetText("Lock")
    lockCB:SetChecked(_G.ACA_Top5DB and _G.ACA_Top5DB.locked)
    lockCB:SetScript("OnClick", function(self)
        if ACA and ACA.Top5_SetLocked then ACA.Top5_SetLocked(self:GetChecked()) end
    end)

    local passthroughCB = CreateFrame("CheckButton", nil, controlsBox, "UICheckButtonTemplate")
    passthroughCB:SetPoint("LEFT", lockCB, "RIGHT", 20, 0)
    passthroughCB.Text:SetText("Click-Through")
    passthroughCB:SetChecked(_G.ACA_Top5DB and _G.ACA_Top5DB.clickThrough)
    passthroughCB:SetScript("OnClick", function(self)
        if ACA and ACA.Top5_SetClickThrough then ACA.Top5_SetClickThrough(self:GetChecked()) end
    end)


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
