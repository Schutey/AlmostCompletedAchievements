-- core.lua
local ADDON_NAME, ACA = ...
ACA = ACA or {}
_G[ADDON_NAME] = ACA


-- saved vars
ACA_ScanThreshold    = ACA_ScanThreshold or 80
ACA_Cache            = ACA_Cache or {}
ACA_IgnoreList       = ACA_IgnoreList or {}
ACA_FilterMode       = ACA_FilterMode or "All"
ACA_AnchorSide       = ACA_AnchorSide or "RIGHT"
ACA_ParseSpeed       = ACA_ParseSpeed or "Auto"
ACA_SortMode         = ACA_SortMode or "Percent Desc."  -- NEW: default sort
ACA._deferUntilReady = true

ACA_Top5DB         = ACA_Top5DB or { shown = false, locked = false, clickThrough = false, point = nil }



-- Reanchor helper: RIGHT or LEFT
function ACA.Reanchor(side)
    ACA_AnchorSide = side or "RIGHT"
    local panel = _G[ACA_PANEL_NAME]
    if panel and AchievementFrame then
        panel:ClearAllPoints()
        if ACA_AnchorSide == "LEFT" then
            panel:SetPoint("TOPRIGHT", AchievementFrame, "TOPLEFT", -10, 0)
            panel._acaBaseX = -10
        else
            panel:SetPoint("TOPLEFT", AchievementFrame, "TOPRIGHT", 10, 0)
            panel._acaBaseX = 10
        end
        if ACA.UpdateHideButtonAnchors then ACA.UpdateHideButtonAnchors() end
        if ACA._ApplyPanelStrata then ACA._ApplyPanelStrata(panel._acaHidden) end
    end
    if _G["ACAAnchorDrop"] then UIDropDownMenu_SetText(_G["ACAAnchorDrop"], ACA_AnchorSide) end
end

-- constants & cached APIs
local C_Timer, CreateFrame = C_Timer, CreateFrame
local ipairs, pairs, tonumber, tostring, select = ipairs, pairs, tonumber, tostring, select
local floor, sort, format = math.floor, table.sort, string.format
local GetAchievementInfo = GetAchievementInfo
local GetAchievementNumCriteria = GetAchievementNumCriteria
local GetAchievementCriteriaInfo = GetAchievementCriteriaInfo
local GetCategoryList, GetCategoryNumAchievements = GetCategoryList, GetCategoryNumAchievements
local UIParentLoadAddOn = UIParentLoadAddOn

ACA.BATCH_SIZE      = 20
ACA.SCAN_DELAY      = 0.025
ACA.SLIDER_MIN      = 0
ACA.SLIDER_MAX      = 99
ACA.DEFAULT_THRESHOLD = 80
ACA.CACHE_TTL       = 60 * 5
ACA_PANEL_NAME      = "AlmostCompletedPanel"
ACA.ROW_HEIGHT      = 48  -- ACA_BIGGER_TEXT_PATCH

-- speed presets

-- Remix: Legion "Timerunner" detection and mode
local function IsTimerunnerRemix()
    -- Prefer official API: seasonID 2 means Legion Remix
    local ok, seasonID = pcall(PlayerGetTimerunningSeasonID)
    if ok and type(seasonID) == "number" then
        return seasonID == 2
    end
    -- Fallback heuristics only if API is unavailable
    if UnitBuff then
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i)
            if not name then break end
            if spellId == 1213439 or name == "WoW Remix: Legion" then
                return true
            end
        end
    end
    if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
        local info = C_CurrencyInfo.GetCurrencyInfo(2778)
        if info and ((info.quantity and info.quantity > 0) or info.discovered) then
            return true
        end
    end
    return false
end

function ACA.ApplyRemixModeIfTimerunner()
    if ACA.RemixApplied then return end

    if not IsTimerunnerRemix() then return end
    -- Flip all categories off except "Legion: Remix" as a starting point,
    -- but do NOT lock them; user can re-enable others from the UI.
    _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
    if _G.ACA_CatFilterDB["Legion: Remix"] == nil then _G.ACA_CatFilterDB["Legion: Remix"] = true end
    for k, v in pairs(_G.ACA_CatFilterDB) do
        if type(v) == "boolean" then
            _G.ACA_CatFilterDB[k] = (k == "Legion: Remix")
        end
    end
    -- Ensure Professions and World Events are set to "None" while in Remix mode
    _G.ACA_CatFilterDB["ProfessionsMode"] = "None"
    _G.ACA_CatFilterDB["WorldEventsMode"] = "None"

    ACA.RemixMode = true; ACA.RemixApplied = true

    -- Fel green title if the panel exists
    local p = _G[ACA_PANEL_NAME]
    if p and p.title and p.title.SetTextColor then
        p.title:SetTextColor(0.2, 1.0, 0.2) -- fel green-ish
    end

    -- Sync options UI so the dropdowns show "None"
    if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end

    -- Rebuild visible list
    if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
end
local SPEED_PRESETS = {
    ["Fast"]   = { batch = 50, delay = 0.010 },
    ["Smooth"] = { batch = 20, delay = 0.025 },
    ["Slow"]   = { batch = 8,  delay = 0.040 },
}

-- keep a small cache utility available
local Utils = require and require("utils") or (function() return ACA.Utils end)()
ACA.Utils = Utils or ACA.Utils

-- safe category list getter (kept for compatibility)
local function SafeGetCategoryList()
    local t = GetCategoryList() or {}
    return type(t) == "table" and t or {}
end
ACA.SafeGetCategoryList = SafeGetCategoryList

-- Compute percentage complete for an achievement (per-character)
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

ACA.GetCompletionPercent = GetCompletionPercent

-- row pool + acquire/release
local rowPool = {}
local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if row and row:GetParent() ~= parent then row:SetParent(parent) end
    if row then row:Show(); return row end

    local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
    f:SetSize(360, ACA.ROW_HEIGHT)

    f._isACARow = true

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
    f.Name:SetPoint("LEFT", f.Icon, "RIGHT", 8, 8)
    f.Name:SetJustifyH("LEFT")
    f.Name:SetWidth(220)

    f.Label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.Label:SetPoint("TOPLEFT", f.Icon, "TOPRIGHT", 8, -20)
    f.Label:SetJustifyH("LEFT")
    f.Label:SetWidth(220)

    -- ACA_BIGGER_TEXT_PATCH begin
    -- Nudge the title about 10% larger for better visual balance. Percent/label unchanged.
    do
        local nfont, nsize = f.Name:GetFont()
        if nfont and nsize then
            local target = math.floor((nsize * 1.10) + 0.5)
            f.Name:SetFont(nfont, math.max(8, target))
        end
        -- Leave percent/label as-is.
    end
    -- ACA_BIGGER_TEXT_PATCH end

    f._ignoreButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f._ignoreButton:SetSize(24, 20)
    -- ACA_ROW_LAYOUT_PATCH begin
f._ignoreButton:ClearAllPoints()
f._ignoreButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
-- ACA_ROW_LAYOUT_PATCH end

    -- ACA_POINTS_ROW_PATCH begin
    -- Small points tag to the left of the ignore X
    f.Points = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.Points:ClearAllPoints()
    f.Points:SetPoint("RIGHT", f._ignoreButton, "LEFT", -6, 0)
    f.Points:SetJustifyH("RIGHT")
    f.Points:SetWidth(56)  -- ACA_POINTS_SIZE_PATCH
    f.Points:SetText("")
    -- ACA_POINTS_ROW_PATCH end

    -- ACA_POINTS_SIZE_PATCH begin
    do
        local pfont, psize = f.Points:GetFont()
        if pfont and psize then
            -- Make points a bit more prominent near the X
            f.Points:SetFont(pfont, math.min(18, psize + 4))
        end
    end
    -- ACA_POINTS_SIZE_PATCH end

    f.Reward = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- ACA_ROW_LAYOUT_PATCH begin
f.Reward:ClearAllPoints()
f.Reward:SetPoint("TOPRIGHT", f._ignoreButton, "BOTTOMRIGHT", 0, -2)
-- ACA_ROW_LAYOUT_PATCH end
    f.Reward:SetJustifyH("RIGHT")
    f.Reward:SetWidth(160)
    f.Reward:SetWordWrap(false)

    return f
end

local function ReleaseRow(row)
    if not row then return end
    row:Hide(); row:SetParent(nil)
    row:SetScript("OnEnter", nil); row:SetScript("OnLeave", nil); if row:GetObjectType()=="Button" then row:SetScript("OnClick", nil) end
    if row._ignoreButton then row._ignoreButton:SetScript("OnClick", nil) end
    table.insert(rowPool, row)
end

-- wipe helper
local function WipeChildren(frame)
    for _, child in ipairs({ frame:GetChildren() }) do
        if child and child._isACARow then
            ReleaseRow(child)
        end
    end
end

-- populate a row
function ACA:PopulateNativeRow(row, ach)
    row.Icon.SetTexture = row.Icon.SetTexture or row.Icon.SetTexture  -- guard
    row.Icon:SetTexture(ach.icon or 134400)
    row.Name:SetText(ach.name or ("[" .. tostring(ach.id) .. "]"))

    -- reward text
    local _, _, _, _, _, _, _, _, _, _, rewardText = GetAchievementInfo(ach.id)
    if not rewardText then
        local all = { GetAchievementInfo(ach.id) }
        rewardText = all[11] or all[12] or all[13] or ""
    end
    row.Reward:SetText(Utils and Utils.TruncateString and Utils.TruncateString(rewardText, 36) or (rewardText and rewardText.sub and rewardText:sub(1, 36) or ""))

    
-- ACA_POINTS_ROW_PATCH begin
    -- Show percent to the left of the X button; keep original small-tag behavior (hide when zero)
    do
        local pct = (ach.percent or 0)
        if row.Points then
            if pct > 0 then
                row.Points:SetText(string.format("%.0f%%", pct))
                row.Points:Show()
            else
                row.Points:SetText("")
                row.Points:Hide()
            end
        end
    end
    -- ACA_POINTS_ROW_PATCH end


    do local _, _, pts = GetAchievementInfo(ach.id); row.Label:SetText(pts and string.format("%dpts", pts) or "") end

    -- tooltip & click handlers
    row:SetScript("OnEnter", function(self)
        UIParentLoadAddOn("Blizzard_AchievementUI")
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        local id = ach.id
        local a_id, name, points, completed, month, day, year, description, flags, icon, rewardText =
            GetAchievementInfo(id)
        local title = (name and tostring(name) ~= "") and name or ("[" .. tostring(id) .. "]")
        GameTooltip:AddLine(format("%s (%d)", title, id), 1, 0.82, 0)
        GameTooltip:AddLine(" ")
        -- ACA_POINTS_TOOLTIP_PATCH begin
        if points and points > 0 then
            GameTooltip:AddLine(string.format("%dpts", points), 1, 1, 1)
        end
        -- ACA_POINTS_TOOLTIP_PATCH end
        if completed then
            if month and day and year and month > 0 then
                GameTooltip:AddLine(format("Completed on %02d/%02d/%d", month, day or 0, year or 0), 0, 1, 0)
            else
                GameTooltip:AddLine("Completed", 0, 1, 0)
            end
        else
            GameTooltip:AddLine("Achievement in progress by " .. UnitName("player"), 0.5, 0.8, 1)
        end

        if description and description ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(description, 0.9, 0.9, 0.9, true)
        end

        local numC = GetAchievementNumCriteria(id) or 0
        if numC > 0 then
            GameTooltip:AddLine(" ")
            for i = 1, numC do
                local critName, critType, critCompleted, qty, req, charName = GetAchievementCriteriaInfo(id, i)
                local r, g, b = 0.6, 0.6, 0.6
                if critCompleted then r, g, b = 0, 1, 0 end
                local progressText = ""
                if req and req > 1 then progressText = format(" (%d/%d)", qty or 0, req) end
                GameTooltip:AddLine("• " .. (critName or ("Criteria " .. i)) .. progressText, r, g, b)
            end

            local done, total = 0, numC
            for i = 1, numC do
                local _, _, critCompleted, qty, req = GetAchievementCriteriaInfo(id, i)
                if critCompleted then
                    done = done + 1
                elseif qty and req and req > 0 then
                    done = done + (qty / req)
                end
            end
            local percent = (done / total) * 100
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Character progress:", format("%d / %d (%.0f%%)", floor(done + 0.5), total, percent), 1, 1, 1, 1, 1, 1)
        end

        if rewardText and rewardText ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Reward: " .. rewardText, 1, 1, 1)
        end

        GameTooltip:Show()
    end)

    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    row:SetScript("OnClick", function()
        local id = tonumber(ach.id)
        -- Ensure Blizzard Achievement UI is loaded
        if not AchievementFrame or not AchievementFrame_IsVisible then
            if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_AchievementUI") end
        end
        local AF = _G["AchievementFrame"]
        if AF then AF:Show() end
        local function selectAch()
            local selectFn = _G["AchievementFrame_SelectAchievement"]
            if type(selectFn) == "function" then selectFn(id) end
        end
        -- Small defer so the frame is fully visible before selection
        if C_Timer and C_Timer.After then C_Timer.After(0, selectAch) else selectAch() end
    end)

    -- ignore button
    row._ignoreButton:SetScript("OnClick", function()
    local id = tonumber(ach.id)
        ACA_IgnoreList[id] = true
        print(format("ACA: Ignored %s", ach.name or ach.id))
        for i = #ACA.scanResults, 1, -1 do
            if ACA.scanResults[i].id == id then table.remove(ACA.scanResults, i); break end
        end
        ACA.UpdatePanel(false)
    end)

    if not row._ignoreButton.icon then
        row._ignoreButton.icon = row._ignoreButton:CreateTexture(nil, "ARTWORK")
        row._ignoreButton.icon:SetSize(16, 16)
        row._ignoreButton.icon:SetPoint("CENTER", row._ignoreButton, "CENTER", 0, 0)
    end

    if ACA_IgnoreList[tonumber(ach.id)] then
        row._ignoreButton.icon:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    else
        row._ignoreButton.icon:SetTexture("Interface\\Buttons\\UI-StopButton")
    end
end

-- Scanner (batched). This is nearly the same logic as before but clearer and designed to hand off fullList.
local scanning = false
ACA.scanResults = {}
ACA.scanResultsForThr = nil

function ACA.ScanAchievements(onComplete, onProgress)
    if scanning then return end
    scanning = true
    wipe(ACA.scanResults)
    ACA.scanResultsForThr = ACA_ScanThreshold

    C_Timer.After(0, function()
        local results, categories = ACA.scanResults, SafeGetCategoryList()
        local totalCategories = #categories
        local currentCat, currentAch = 1, 1
        local scanned, totalToScan = 0, 0
        local threshold = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD
    -- auto-govern only when ParseSpeed is Auto; otherwise respect manual choice
    if (ACA_ParseSpeed == "Auto" or ACA_ParseSpeed == nil) then
        local v = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD
        local preset = (ACA.SPEED_PRESETS and (
            (v <= 50 and ACA.SPEED_PRESETS.Slow) or
            (v <= 90 and ACA.SPEED_PRESETS.Smooth) or
            ACA.SPEED_PRESETS.Fast
        )) or { batch = 20, delay = 0.025 }
        ACA.BATCH_SIZE, ACA.SCAN_DELAY = preset.batch, preset.delay
    end

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
                        local _, name, points, completed, _, _, _, _, _, icon = GetAchievementInfo(achID)
                        if not completed then
                            local percent = GetCompletionPercent(achID)
                            if percent >= threshold then
                                local _, _, _, _, _, _, _, _, _, _, rewardText = GetAchievementInfo(achID)
                                if not rewardText then
                                    local all = { GetAchievementInfo(achID) }
                                    rewardText = all[11] or all[12] or all[13] or ""
                                end
                                table.insert(results, {
                                    id = achID,
                                    name = name or ("[" .. tostring(achID) .. "]"),
                                    percent = percent,
                                    category = catID,
                                    icon = icon,
                                    reward = rewardText,
                                    points = points or 0,   -- NEW: store points for sorting
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

-- Sort logic
ACA.SORT_LIST = {
    "Percent Desc.",
    "Percent Asc.",
    "Name Asc.",
    "Name Desc.",
    "Points Desc.",
    "Points Asc.",
}

local function _getComparator(mode)
    if mode == "Percent Asc." then
        return function(a, b)
            if a.percent == b.percent then
                return (a.name or ""):lower() < (b.name or ""):lower()
            end
            return a.percent < b.percent
        end
    elseif mode == "Name Asc." then
        return function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end
    elseif mode == "Name Desc." then
        return function(a, b)
            return (a.name or ""):lower() > (b.name or ""):lower()
        end
    elseif mode == "Points Desc." then
        return function(a, b)
            if (a.points or 0) == (b.points or 0) then
                return a.percent > b.percent
            end
            return (a.points or 0) > (b.points or 0)
        end
    elseif mode == "Points Asc." then
        return function(a, b)
            if (a.points or 0) == (b.points or 0) then
                return a.percent > b.percent
            end
            return (a.points or 0) < (b.points or 0)
        end
    end
    -- default: Percent Desc
    return function(a, b)
        if a.percent == b.percent then
            return (a.name or ""):lower() < (b.name or ""):lower()
        end
        return a.percent > b.percent
    end
end

-- Panel creation. We keep the layout similar to original but shift options to modules.
local function CreateAlmostCompletedPanel()
    if _G[ACA_PANEL_NAME] then return _G[ACA_PANEL_NAME] end
    UIParentLoadAddOn("Blizzard_AchievementUI")
    local parent = _G["AchievementFrame"] or UIParent

    local panel = CreateFrame("Frame", ACA_PANEL_NAME, parent, "BackdropTemplate")
    panel:SetSize(420, 500)
    local side = (ACA_AnchorSide == "LEFT") and "TOPRIGHT" or "TOPLEFT"
    local relSide = (ACA_AnchorSide == "LEFT") and "TOPLEFT" or "TOPRIGHT"
    local xOff = (ACA_AnchorSide == "LEFT") and -10 or 10
    panel:SetPoint(side, parent, relSide, xOff, 0)
    panel._acaBaseX = xOff
    panel._acaHidden = false
    if ACA._ApplyPanelStrata then C_Timer.After(0, function() ACA._ApplyPanelStrata(false) end) end
    panel:SetBackdrop({
        bgFile = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    panel:SetBackdropBorderColor(0.2, 0.15, 0.1)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); panel.title = title; panel.title = title
    title:SetPoint("TOP", panel, "TOP", 0, -12)
    title:SetText("Almost Completed Achievements")
    if ACA and ACA.RemixMode and title.SetTextColor then title:SetTextColor(0.2, 1.0, 0.2) end
    if ACA.RemixMode then title:SetTextColor(0.2, 1.0, 0.2) end

    local tab1 = CreateFrame("Button", panel:GetName() .. "Tab1", panel, "PanelTabButtonTemplate")
    tab1:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, -30)
-- ACA_RESULTS_LABEL_PATCH -- begin
-- Results counter (only shown after a finished scan on Tab 1)
local resultsLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
resultsLabel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -14)
resultsLabel:SetText("")
resultsLabel:Hide()
resultsLabel:SetTextColor(1, 1, 1)
panel.resultsLabel = resultsLabel
-- ACA_RESULTS_LABEL_PATCH -- end
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
    contentCompleted:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -40)
    contentCompleted:SetSize(396, 395)
    local contentIgnored = CreateFrame("Frame", nil, panel)
    contentIgnored:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -40)
    contentIgnored:SetSize(396, 390)
    contentIgnored:Hide()
    local contentOptions = CreateFrame("Frame", nil, panel)
    contentOptions:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -40)
    contentOptions:SetSize(396, 390)
    contentOptions:Hide()
    panel.contentCompleted, panel.contentIgnored, panel.contentOptions = contentCompleted, contentIgnored, contentOptions

    -- Reflect current DB settings into the options UI without firing clicks
function ACA.SyncOptionsUI()
    local p = _G[ACA_PANEL_NAME]
    if not p or not p.contentOptions then return end
    local box = p.contentOptions

    -- walk all checkbuttons under options box
    local function handleCB(cb)
        if not cb or not cb.Text then return end
        local label = cb.Text:GetText()
        if not label or label == "" then return end

        -- Category checkboxes: label is key except PvP
        local key = (label == "PvP") and "Player vs. Player" or label

        -- Professions radio row (exclusive)
        if label == "All" or label == "Learned" or label == "None" then
            local mode = _G.ACA_CatFilterDB and _G.ACA_CatFilterDB["ProfessionsMode"]
            cb:SetChecked(label == mode)
            return
        end

        -- World Events row (exclusive)
        if label == "All" or label == "Active" or label == "None" then
            local mode = _G.ACA_CatFilterDB and _G.ACA_CatFilterDB["WorldEventsMode"]
            cb:SetChecked(label == mode)
            return
        end

        -- Top-level categories reflect DB booleans
        if _G.ACA_CatFilterDB and type(_G.ACA_CatFilterDB[key]) ~= "nil" then
            cb:SetChecked(_G.ACA_CatFilterDB[key] ~= false)
        end
    end

    -- iterate children recursively
    local function walk(frame)
        if not frame or not frame.GetChildren then return end
        local kids = { frame:GetChildren() }
        for _, child in ipairs(kids) do
            if child:GetObjectType() == "CheckButton" then
                handleCB(child)
            end
            walk(child)
        end
    end

    walk(box)

    -- also update the Scan Speed dropdown text to reflect current setting
    if p.contentOptions.ACAParseDrop then
        UIDropDownMenu_SetText(p.contentOptions.ACAParseDrop, _G.ACA_ParseSpeed or "Auto")
    end
end


    -- NEW: Sort dropdown at top-left of Tab 1
    do
        local sortLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal"); panel.sortLabel = sortLabel
        sortLabel:SetPoint("TOPLEFT", contentCompleted, "TOPLEFT", 0, 10)
        sortLabel:SetText("Sort by:")

        
        sortLabel:SetTextColor(1, 1, 1)
local sortDropdown = CreateFrame("Frame", "ACASortDrop", panel, "UIDropDownMenuTemplate")
        sortDropdown:SetPoint("TOPLEFT", sortLabel, "BOTTOMLEFT", -10, -4)
        UIDropDownMenu_SetWidth(sortDropdown, 160)
        UIDropDownMenu_SetText(sortDropdown, ACA_SortMode or "Percent (Desc)")
        panel.sortDropdown = sortDropdown

        UIDropDownMenu_Initialize(sortDropdown, function(self, level)
            local info = UIDropDownMenu_CreateInfo()
            for _, key in ipairs(ACA.SORT_LIST) do
                info.text = key
                info.func = function()
                    ACA_SortMode = key
                    UIDropDownMenu_SetText(sortDropdown, key)
                    if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
                end
                info.checked = (ACA_SortMode == key)
                UIDropDownMenu_AddButton(info)
            end
        end)
    end

    local scrollCompleted = CreateFrame("ScrollFrame", nil, contentCompleted, "UIPanelScrollFrameTemplate")
    scrollCompleted:SetPoint("TOPLEFT", contentCompleted, "TOPLEFT", 0, -33)  -- shifted down to make room for Sort dropdown
    scrollCompleted:SetPoint("BOTTOMRIGHT", contentCompleted, "BOTTOMRIGHT", -25, -20)
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

    -- progress bar, refresh, filter dropdown, slider etc will be manipulated by options module later
    local scanBar = CreateFrame("StatusBar", nil, panel, "TextStatusBar")
    scanBar:SetSize(180, 18)
    scanBar:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 200, 14)
    scanBar:SetStatusBarTexture("Interface\\TARGETINGFRAME\\UI-StatusBar")
    scanBar:GetStatusBarTexture():SetHorizTile(false)
    scanBar:GetStatusBarTexture():SetVertexColor(0, 0.8, 0.2, 1)
    scanBar:SetMinMaxValues(0, 1)
    scanBar:SetValue(0)
    scanBar:SetMovable(false)
    scanBar.bg = scanBar:CreateTexture(nil, "BACKGROUND")
    scanBar.bg:SetAllPoints(scanBar)
    scanBar.bg:SetColorTexture(0.1, 0.1, 0.1, 0.6)
    scanBar.Text = scanBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    scanBar.Text:SetPoint("CENTER", scanBar, "CENTER", 0, 0)
    scanBar.Text:SetText("Idle")
    
    scanBar.Text:SetTextColor(1, 1, 1)
panel.scanBar = scanBar

    local refresh = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    refresh:SetSize(100, 24)
    refresh:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 14)
    refresh:SetText("Rescan")
    refresh:GetFontString():SetTextColor(1, 1, 1)
    panel.refresh = refresh
    -- Align scan bar inline with the Rescan button
    if panel.scanBar then
        panel.scanBar:ClearAllPoints()
        panel.scanBar:SetPoint("LEFT", refresh, "RIGHT", 16, 0)
    end
    -- Stretch scan bar to the right edge of the achievements list
    if panel.scanBar and panel.contentCompleted then
        -- Match the scroll frame right offset (-25) so edges line up
        panel.scanBar:SetPoint("RIGHT", panel.contentCompleted, "RIGHT", -30, 0)
    end


    -- Ensure Clear and Reset buttons exist (same anchor as Rescan)
    if not panel.clearBtn then
        local clearBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        clearBtn:SetSize(100, 24)
        clearBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 14)
        clearBtn:SetText("Clear")
        clearBtn:GetFontString():SetTextColor(1, 1, 1)
        clearBtn:Hide()
        clearBtn:SetScript("OnClick", function()
            local n = 0
            if _G.ACA_IgnoreList then
                for k in pairs(_G.ACA_IgnoreList) do _G.ACA_IgnoreList[k] = nil; n = n + 1 end
            end
            if ACA and ACA.CategoryFilters and ACA.CategoryFilters.hiddenIDs then
                wipe(ACA.CategoryFilters.hiddenIDs)
            end
            print(("ACA: cleared %d ignored achievement%s."):format(n, n == 1 and "" or "s"))
            if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
        end)
        panel.clearBtn = clearBtn
    end

    if not panel.resetBtn then
        local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        resetBtn:SetSize(100, 24)
        resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 14)
        resetBtn:SetText("Reset")
        resetBtn:GetFontString():SetTextColor(1, 1, 1)
        resetBtn:Hide()
        resetBtn:SetScript("OnClick", function()
            ACA_ScanThreshold = ACA.DEFAULT_THRESHOLD
            ACA_ParseSpeed    = "Auto"
            ACA_AnchorSide    = "RIGHT"
            ACA_FilterMode    = "All"
            local p = (ACA.SPEED_PRESETS and ACA.SPEED_PRESETS.Smooth) or { batch = 20, delay = 0.025 }
            ACA.BATCH_SIZE, ACA.SCAN_DELAY = p.batch, p.delay
            ACA_Cache, ACA.scanResults, ACA.scanResultsForThr = {}, {}, nil
            
            -- Reset category filters DB to defaults
            _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
            for k, v in pairs(_G.ACA_CatFilterDB) do
                if type(v) == "boolean" then _G.ACA_CatFilterDB[k] = true end
            end
            _G.ACA_CatFilterDB["ProfessionsMode"] = "All"
            _G.ACA_CatFilterDB["WorldEventsMode"]  = "Active"
            if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
if ACA.CategoryFilters then
                local CF = ACA.CategoryFilters
                if CF.fullList then wipe(CF.fullList) end
                if CF.hiddenIDs then wipe(CF.hiddenIDs) end
                CF.mapsBuilt = false
            end
            if panel.optionsSlider then
                panel.optionsSlider:SetValue(ACA_ScanThreshold)
                panel.optionsSlider.Text:SetText("Threshold: " .. ACA_ScanThreshold .. "%")
            end
            print("ACA: all settings reset to default.")
            if ACA.UpdatePanel then ACA.UpdatePanel(true) end
            -- Anchor: default RIGHT
            ACA.Reanchor("RIGHT")
            -- Enforce default radio modes
            _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
            _G.ACA_CatFilterDB["ProfessionsMode"] = "Learned"
            _G.ACA_CatFilterDB["WorldEventsMode"]  = "Active"
            if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
            -- Reflect reward filter dropdown label
            if panel.filterDropdown then
                UIDropDownMenu_SetText(panel.filterDropdown, "All")
                if UIDropDownMenu_SetSelectedName then UIDropDownMenu_SetSelectedName(panel.filterDropdown, "All") end
                if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(panel.filterDropdown, true) end
            end



        end)
        panel.resetBtn = resetBtn
    end


    -- Unified per-tab button toggle + title color; hook ShowTab if available or fall back to PanelTemplates_SetTab
    local function _ACA_UpdateTabChrome(idx)
        if ACA and ACA.RemixMode and panel.title and panel.title.SetTextColor then
            panel.title:SetTextColor(0.2, 1.0, 0.2)
        end
        if panel.title and panel.title.SetTextColor then
            if ACA and ACA.RemixMode then
                panel.title:SetTextColor(0.2, 1.0, 0.2)
            else
                if NORMAL_FONT_COLOR and NORMAL_FONT_COLOR.GetRGB then
                    panel.title:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
                else
                    panel.title:SetTextColor(1, 0.82, 0) -- fallback to default UI yellow
                end
            end
        end
        if panel.refresh  then panel.refresh:SetShown(idx == 1) end
        if panel.clearBtn then panel.clearBtn:SetShown(idx == 2) end
        if panel.resetBtn then panel.resetBtn:SetShown(idx == 3) end
    end
    if hooksecurefunc then
        if type(panel.ShowTab) == "function" then
            hooksecurefunc(panel, "ShowTab", function(i) _ACA_UpdateTabChrome(i) end)
        else
            hooksecurefunc("PanelTemplates_SetTab", function(frame, idx)
                if frame == panel then _ACA_UpdateTabChrome(idx) end
            end)
        end
    end
    C_Timer.After(0, function() _ACA_UpdateTabChrome(panel.activeTab or panel.selectedTab or 1) end)


    -- reward-filter dropdown label
    local filterLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    filterLabel:SetPoint("TOPLEFT", contentCompleted, "TOPLEFT", 190, 10)
    filterLabel:SetText("Filter by:")
    filterLabel:SetTextColor(1, 1, 1)
    panel.filterLabel = filterLabel

    local filterDropdown = CreateFrame("Frame", nil, panel, "UIDropDownMenuTemplate")
    filterDropdown:SetPoint("TOPLEFT", filterLabel, "BOTTOMLEFT", -16, -4)
    UIDropDownMenu_SetWidth(filterDropdown, 140)
    UIDropDownMenu_SetText(filterDropdown, ACA_FilterMode)
    panel.filterDropdown = filterDropdown
    UIDropDownMenu_Initialize(filterDropdown, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        local list = ACA.FILTER_LIST or {}
        for _, name in ipairs(list) do
            info.text = name
            info.func = function()
                ACA_FilterMode = name
                UIDropDownMenu_SetText(filterDropdown, name)
                if ACA and ACA.UpdatePanel then ACA.UpdatePanel(false) end
            end
            info.checked = (ACA_FilterMode == name)
            UIDropDownMenu_AddButton(info)
        end
    end)


    -- create parse & anchor dropdowns later in options module (they'll parent to contentOptions)

    -- slider + help area will be created by options module

    -- tab switching handler
    local function ShowTab(idx)
        PanelTemplates_SetTab(panel, idx)
        if idx == 1 then
            contentCompleted:Show(); contentIgnored:Hide(); contentOptions:Hide()
            panel.scanBar:Show()
            panel.optionsSlider = panel.optionsSlider or panel.optionsSlider
            if panel.optionsSlider then
				panel.optionsSlider:Hide()


-- ACA_RESULTS_LABEL_PATCH -- begin
-- Hide the results label on other tabs; it only shows on Tab 1 after scanning completes
if panel and panel.resultsLabel then
    if idx ~= 1 then
        panel.resultsLabel:Hide()
    end
end
-- ACA_RESULTS_LABEL_PATCH -- end
			end
            panel.filterDropdown:Show()
            if panel.filterLabel then panel.filterLabel:Show() end
            refresh:Show()
            if panel.sortDropdown then panel.sortDropdown:Show() end
            if panel.sortLabel then panel.sortLabel:Show() end
        elseif idx == 2 then
            contentCompleted:Hide(); contentIgnored:Show(); contentOptions:Hide()
            panel.scanBar:Hide()
            if panel.optionsSlider then
				panel.optionsSlider:Hide()
			end
            panel.filterDropdown:Hide()
            if panel.filterLabel then panel.filterLabel:Hide() end
            refresh:Hide()
            if panel.sortDropdown then panel.sortDropdown:Hide() end
            if panel.sortLabel then panel.sortLabel:Hide() end
        else
            contentCompleted:Hide(); contentIgnored:Hide(); contentOptions:Show()
            panel.scanBar:Hide()
            if panel.optionsSlider then
				panel.optionsSlider:Show()
			end
            panel.filterDropdown:Hide()
            if panel.filterLabel then panel.filterLabel:Hide() end
            refresh:Hide()
            if panel.sortDropdown then panel.sortDropdown:Hide() end
            if panel.sortLabel then panel.sortLabel:Hide() end
        end
    end
    tab1:SetScript("OnClick", function() ShowTab(1); ACA.UpdatePanel(false) end)
    tab2:SetScript("OnClick", function() ShowTab(2); ACA.UpdatePanel(false) end)
    tab3:SetScript("OnClick", function() ShowTab(3); ACA.UpdatePanel(false) end)

    refresh:SetScript("OnClick", function()
        ACA.scanResults = {}
        ACA.scanResultsForThr = nil
        ACA.UpdatePanel(true)
    end)

    -- clear button (for ignored) left to options module

    
    -- ACA_HIDE_TOGGLE_UI begin
    if not panel.hideBtn then
        local btnParent = UIParent
        local btn = CreateFrame("Button", nil, btnParent, "UIPanelButtonTemplate")
        btn:SetSize(20, 64)
        btn:SetFrameStrata((AchievementFrame and AchievementFrame:GetFrameStrata()) or "HIGH")
        btn.txt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        btn.txt:SetPoint("CENTER")
        btn.txt:SetText((ACA_AnchorSide == "RIGHT") and "‹" or "›")
        btn:SetScript("OnClick", function() ACA.TogglePanelHidden() end)
        btn:SetScript("OnEnter", function(self) if ACA and ACA.UpdateHideBtnTooltip then ACA.UpdateHideBtnTooltip(self) end end)
        btn:SetScript("OnLeave", function() if GameTooltip and GameTooltip:IsOwned(btn) then GameTooltip:Hide() end end)
        panel.hideBtn = btn
        ACA.UpdateHideButtonAnchors()
        if AchievementFrame and AchievementFrame:IsShown() then
            btn:Show()
        else
            btn:Hide()
        end
    end
    -- keep the button aligned if user switches tabs or we reanchor
    if hooksecurefunc then
        hooksecurefunc(panel, "SetPoint", function() C_Timer.After(0, function() ACA.UpdateHideButtonAnchors(); if ACA.UpdateHideButtonVisibility then ACA.UpdateHideButtonVisibility() end end) end)
    end
    -- ACA_HIDE_TOGGLE_UI end
    panel.ShowTab = ShowTab
    _G[ACA_PANEL_NAME] = panel
    ShowTab(1)
    return panel
end

-- ACA_HIDE_TOGGLE_HELPERS begin
do

    function ACA.UpdateHideButtonVisibility()
        local panel = _G[ACA_PANEL_NAME]
        if not panel or not panel.hideBtn then return end
        if AchievementFrame and AchievementFrame:IsShown() then
            panel.hideBtn:Show()
        else
            panel.hideBtn:Hide()
        end
    end

    function ACA.UpdateHideBtnTooltip(btn)
        if not btn or not GameTooltip then return end
        local panel = _G[ACA_PANEL_NAME]
        local isHidden = panel and panel._acaHidden
        GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
        if isHidden then
            GameTooltip:SetText("Show Almost Completed Achievements Panel", 1, 1, 1)
        else
            GameTooltip:SetText("Hide Almost Completed Achievements Panel", 1, 1, 1)
        end
        GameTooltip:Show()
    end
    local function _AnimatePanelX(panel, fromX, toX, duration, onDone)
        if not panel or not panel:IsShown() then
            if onDone then onDone() end
            return
        end
        duration = duration or 0.20
        local elapsed, f = 0, CreateFrame("Frame")
        f:SetScript("OnUpdate", function(_, dt)
            elapsed = elapsed + dt
            local t = elapsed / duration
            if t >= 1 then t = 1 end
            local x = fromX + (toX - fromX) * t
            panel:ClearAllPoints()
            local side = _G.ACA_AnchorSide == "LEFT"
                and "TOPRIGHT" or "TOPLEFT"
            local rel  = _G.ACA_AnchorSide == "LEFT"
                and "TOPLEFT"  or "TOPRIGHT"
            local parent = AchievementFrame or UIParent
            panel:SetPoint(side, parent, rel, x, 0)
            if t >= 1 then
                f:SetScript("OnUpdate", nil)
                f:Hide()
                if onDone then onDone() end
            end
        end)
        f:Show()
    end

    function ACA.UpdateHideButtonAnchors()
        local panel = _G[ACA_PANEL_NAME]
        if not panel or not panel.hideBtn then return end
        local btn = panel.hideBtn
        btn:ClearAllPoints()
        if not panel._acaHidden then
            -- Shown: button sits off the outer edge of the ACA panel, centered vertically
            if _G.ACA_AnchorSide == "RIGHT" then
                btn:SetPoint("LEFT", panel, "RIGHT", 2, 0)
            else
                btn:SetPoint("RIGHT", panel, "LEFT", -2, 0)
            end
        else
            -- Hidden: button sits off the edge of the Blizzard AchievementFrame
            local parent = AchievementFrame or UIParent
            if _G.ACA_AnchorSide == "RIGHT" then
                btn:SetPoint("LEFT", parent, "RIGHT", 2, 0)
            else
                btn:SetPoint("RIGHT", parent, "LEFT", -2, 0)
            end
        end
    end

    function ACA.TogglePanelHidden()
        local panel = _G[ACA_PANEL_NAME]
        if not panel then return end
        local parent = AchievementFrame or UIParent

        -- ensure base offsets cached
        if panel._acaBaseX == nil then
            panel._acaBaseX = (_G.ACA_AnchorSide == "LEFT") and -10 or 10
        end

        local width = panel:GetWidth() or 420
        local tuckX = (_G.ACA_AnchorSide == "RIGHT") and (-width - 20) or (width + 20)
        local fromX, toX

        if not panel._acaHidden then
            -- slide toward Blizzard frame then hide
            fromX, toX = panel._acaBaseX, tuckX
            ACA._ApplyPanelStrata(true)
            _AnimatePanelX(panel, fromX, toX, 0.20, function()
                panel:Hide()
                panel._acaHidden = true
                -- flip arrow
                if panel.hideBtn and panel.hideBtn.txt then
                    panel.hideBtn.txt:SetText((_G.ACA_AnchorSide == "RIGHT") and "›" or "‹")
                end
                ACA.UpdateHideButtonAnchors()
                if panel.hideBtn and GameTooltip and GameTooltip:IsOwned(panel.hideBtn) and ACA and ACA.UpdateHideBtnTooltip then ACA.UpdateHideBtnTooltip(panel.hideBtn) end
                if panel.hideBtn and GameTooltip and GameTooltip:IsOwned(panel.hideBtn) and ACA and ACA.UpdateHideBtnTooltip then ACA.UpdateHideBtnTooltip(panel.hideBtn) end
            end)
        else
            -- reveal: start tucked, show, then slide out to base
            panel:Show()
            -- Keep below Blizzard during the entire slide-out, restore after
            if ACA._ApplyPanelStrata then ACA._ApplyPanelStrata(true) end
            fromX, toX = tuckX, panel._acaBaseX
            _AnimatePanelX(panel, fromX, toX, 0.20, function()
                panel._acaHidden = false
                if ACA._ApplyPanelStrata then ACA._ApplyPanelStrata(false) end
                if panel.hideBtn and panel.hideBtn.txt then
                    panel.hideBtn.txt:SetText((_G.ACA_AnchorSide == "RIGHT") and "‹" or "›")
                end
                ACA.UpdateHideButtonAnchors()
            end)
        end
    end
end
-- ACA_HIDE_TOGGLE_HELPERS end

-- ACA_STRATA_HELPERS begin
do
    local ORDER = { BACKGROUND=1, LOW=2, MEDIUM=3, HIGH=4, DIALOG=5, FULLSCREEN=6, FULLSCREEN_DIALOG=7, TOOLTIP=8 }
    local INDEX = { "BACKGROUND","LOW","MEDIUM","HIGH","DIALOG","FULLSCREEN","FULLSCREEN_DIALOG","TOOLTIP" }

    local function LowerStrata(strata)
        local i = ORDER[strata or "MEDIUM"] or 3
        i = math.max(1, i - 1)
        return INDEX[i]
    end

    local function ForEachChild(frame, fn)
        if not frame or not fn then return end
        fn(frame)
        if frame.GetChildren then
            local kids = { frame:GetChildren() }
            for i = 1, #kids do
                local child = kids[i]
                ForEachChild(child, fn)
            end
        end
        -- Regions don't have their own strata; no action needed. Still consume safely.
        if frame.GetRegions then
            local regs = { frame:GetRegions() }
            -- no-op, but avoids generic-for misuse
        end
    end

    function ACA._ApplyPanelStrata(hiddenMode)
        local panel = _G[ACA_PANEL_NAME]
        if not panel then return end
        local parent = AchievementFrame or UIParent

        panel._acaOrigStrata = panel._acaOrigStrata or panel:GetFrameStrata() or "MEDIUM"
        local parentStrata = parent and parent:GetFrameStrata() or "HIGH"

        if hiddenMode then
            local target = LowerStrata(parentStrata)
            ForEachChild(panel, function(f) if f.SetFrameStrata then f:SetFrameStrata(target) end end)
            -- ensure the toggle button stays on top of Blizzard panel edge
            if panel.hideBtn and panel.hideBtn.SetFrameStrata then
                panel.hideBtn:SetFrameStrata(parentStrata)
            end
        else
            local restore = panel._acaOrigStrata or "MEDIUM"
            ForEachChild(panel, function(f) if f.SetFrameStrata then f:SetFrameStrata(restore) end end)
            if panel.hideBtn and panel.hideBtn.SetFrameStrata and parent then
                panel.hideBtn:SetFrameStrata(parent:GetFrameStrata() or "HIGH")
            end
        end
    end
end
-- ACA_STRATA_HELPERS end

-- === Top 5 Mini Window ======================================================

-- Shared tooltip helpers so Top5 and the main list can use the same behavior.

-- Robust, shared tooltip used by both the main list and the Top 5 window.
function ACA.ShowAchievementTooltip(owner, achievementID)
    if not achievementID then return end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_AchievementUI") end

    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    local id = achievementID
    local _, name, points, completed, month, day, year, description, flags, icon, rewardText = GetAchievementInfo(id)

    GameTooltip:AddLine(name or ("[" .. tostring(id) .. "]"), 1, 0.82, 0)

    if points and points > 0 then
        GameTooltip:AddLine(string.format("%d Achievement Points", points), 1, 1, 1)
    end

    if completed then
        if month and day and year and month > 0 then
            GameTooltip:AddLine(string.format("Completed: %02d/%02d/%d", month, day or 0, year or 0), 0, 1, 0)
        else
            GameTooltip:AddLine("Completed", 0, 1, 0)
        end
    end

    if rewardText and rewardText ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Reward", 0.6, 0.8, 1)
        GameTooltip:AddLine(rewardText, 0.9, 0.9, 0.9, true)
    end

    if description and description ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(description, 0.9, 0.9, 0.9, true)
    end

    local numCriteria = GetAchievementNumCriteria(id) or 0
    if numCriteria and numCriteria > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Criteria", 0.6, 0.8, 1)
        for i = 1, numCriteria do

    function Top5.ShowRichTooltip(owner, achievementID)
        if not achievementID then return end
        if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_AchievementUI") end
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()

        local id = achievementID
        local _, name, points, completed, month, day, year, description, flags, icon, rewardText = GetAchievementInfo(id)

        GameTooltip:AddLine(name or ("[" .. tostring(id) .. "]"), 1, 0.82, 0)

        if points and points > 0 then
            GameTooltip:AddLine(string.format("%d Achievement Points", points), 1, 1, 1)
        end

        if completed then
            if month and day and year and month > 0 then
                GameTooltip:AddLine(string.format("Completed: %02d/%02d/%d", month, day or 0, year or 0), 0, 1, 0)
            else
                GameTooltip:AddLine("Completed", 0, 1, 0)
            end
        end

        if rewardText and rewardText ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Reward", 0.6, 0.8, 1)
            GameTooltip:AddLine(rewardText, 0.9, 0.9, 0.9, true)
        end

        if description and description ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(description, 0.9, 0.9, 0.9, true)
        end

        local numCriteria = GetAchievementNumCriteria(id) or 0
        if numCriteria and numCriteria > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Criteria", 0.6, 0.8, 1)
            for i = 1, numCriteria do
                local cDesc, cType, cCompleted, cQuantity, cReqQuantity, cFlags, cAssetID, cQuantityString, cCriteriaID, eligible = GetAchievementCriteriaInfo(id, i)
                local line = cDesc and cDesc ~= "" and cDesc or (cQuantityString or "Criteria")
                if cReqQuantity and cReqQuantity > 0 and cQuantity ~= nil then
                    line = string.format("%s (%d/%d)", line, cQuantity or 0, cReqQuantity or 0)
                end
                if cCompleted then
                    GameTooltip:AddLine(" • " .. line, 0, 1, 0, true)
                else
                    GameTooltip:AddLine(" • " .. line, 0.9, 0.9, 0.9, true)
                end
            end
        end

        GameTooltip:Show()
    end
            local cDesc, cType, cCompleted, cQuantity, cReqQuantity, cFlags, cAssetID, cQuantityString, cCriteriaID, eligible = GetAchievementCriteriaInfo(id, i)
            local line = cDesc and cDesc ~= "" and cDesc or (cQuantityString or "Criteria")
            if cReqQuantity and cReqQuantity > 0 and cQuantity ~= nil then
                line = string.format("%s (%d/%d)", line, cQuantity or 0, cReqQuantity or 0)
            end
            if cCompleted then
                GameTooltip:AddLine(" • " .. line, 0, 1, 0, true)
            else
                GameTooltip:AddLine(" • " .. line, 0.9, 0.9, 0.9, true)
            end
        end
    end

    GameTooltip:Show()
end

function ACA.HideAchievementTooltip(owner)
    if GameTooltip and GameTooltip:IsOwned(owner) then GameTooltip:Hide() end
end

function ACA.TryShowAchievementTooltip(owner, achievementID)
    if ACA and type(ACA.ShowAchievementTooltip) == 'function' then
        return ACA.ShowAchievementTooltip(owner, achievementID)
    end
end

function ACA.TryHideAchievementTooltip(owner)
    if ACA and type(ACA.HideAchievementTooltip) == 'function' then
        return ACA.HideAchievementTooltip(owner)
    end
end


do
    local function SafeEnableMouse(frame, enable)
        if not frame then return end
        if frame.EnableMouse then frame:EnableMouse(enable and true or false) end
        if frame.GetChildren then
            for _, child in ipairs({ frame:GetChildren() }) do
                SafeEnableMouse(child, enable)
            end
        end
    end

    local function _RestorePosition(f)
        local db = _G.ACA_Top5DB or {}
        if db.point and type(db.point) == "table" then
            f:ClearAllPoints()
            f:SetPoint(db.point[1], db.point[2] or UIParent, db.point[3], db.point[4] or 0, db.point[5] or 0)
        else
            f:ClearAllPoints()
            f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        end
    end

    local function _SavePosition(f)
        local a1, r, a2, x, y = f:GetPoint(1)
        _G.ACA_Top5DB = _G.ACA_Top5DB or {}
        _G.ACA_Top5DB.point = { a1 or "CENTER", r or UIParent, a2 or "CENTER", x or 0, y or 0 }
    end

    local function _MakeRow(parent)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(260, 22)
        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.bg:SetColorTexture(0, 0, 0, 0.25)
        btn.hl = btn:CreateTexture(nil, "HIGHLIGHT")
        btn.hl:SetAllPoints()
        btn.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        btn.hl:SetBlendMode("ADD")
        btn.hl:SetAlpha(0.25)

        btn.Title = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        btn.Title:SetPoint("LEFT", btn, "LEFT", 8, 0)
        btn.Title:SetJustifyH("LEFT")
        btn.Title:SetWidth(200)

        btn.Pct = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn.Pct:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
        btn.Pct:SetJustifyH("RIGHT")
        btn.Pct:SetWidth(40)

        return btn
    end

    local Top5 = CreateFrame("Frame", "ACA_Top5Window", UIParent, "BackdropTemplate")
    Top5:SetSize(280, 5 + (22 * 5) + 5 + 22) -- rows + paddings + header
    Top5:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    Top5:SetBackdropBorderColor(0.35, 0.35, 0.35)
    _RestorePosition(Top5)
    Top5:SetMovable(true)
    Top5:EnableMouse(true)
    Top5:RegisterForDrag("LeftButton")
    Top5:SetScript("OnDragStart", function(self)
        if not _G.ACA_Top5DB.locked then self:StartMoving() end
    end)
    Top5:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        _SavePosition(self)
    end)
    Top5:Hide()

    -- Header
    Top5.Header = Top5:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    Top5.Header:SetPoint("TOP", Top5, "TOP", 0, -6)
    Top5.Header:SetText("ACA: Top 5")

    -- Rows
    Top5.rows = {}
    for i = 1, 5 do
        local row = _MakeRow(Top5)
        row:SetPoint("TOPLEFT", Top5, "TOPLEFT", 10, - (6 + 20 + ((i - 1) * 22)))
        row:SetPoint("TOPRIGHT", Top5, "TOPRIGHT", -10, - (6 + 20 + ((i - 1) * 22)))
        Top5.rows[i] = row

        row:SetScript("OnEnter", function(self)
    local id = self._id
    if not id then return end
    if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_AchievementUI") end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    local _, name, points, completed, month, day, year, description, flags, icon, rewardText = GetAchievementInfo(id)
    GameTooltip:AddLine(name or ("[" .. tostring(id) .. "]"), 1, 0.82, 0)
    if points and points > 0 then
        GameTooltip:AddLine(string.format("%d Achievement Points", points), 1, 1, 1)
    end
    if completed then
        if month and day and year and month > 0 then
            GameTooltip:AddLine(string.format("Completed: %02d/%02d/%d", month, day or 0, year or 0), 0, 1, 0)
        else
            GameTooltip:AddLine("Completed", 0, 1, 0)
        end
    end
    if rewardText and rewardText ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Reward", 0.6, 0.8, 1)
        GameTooltip:AddLine(rewardText, 0.9, 0.9, 0.9, true)
    end
    if description and description ~= "" then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(description, 0.9, 0.9, 0.9, true)
    end
    local numCriteria = GetAchievementNumCriteria(id) or 0
    if numCriteria and numCriteria > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Criteria", 0.6, 0.8, 1)
        for i = 1, numCriteria do
            local cDesc, cType, cCompleted, cQuantity, cReqQuantity, cFlags, cAssetID, cQuantityString, cCriteriaID, eligible = GetAchievementCriteriaInfo(id, i)
            local line = (cDesc and cDesc ~= "" and cDesc) or (cQuantityString or "Criteria")
            if cReqQuantity and cReqQuantity > 0 and cQuantity ~= nil then
                line = string.format("%s (%d/%d)", line, cQuantity or 0, cReqQuantity or 0)
            end
            if cCompleted then
                GameTooltip:AddLine(" • " .. line, 0, 1, 0, true)
            else
                GameTooltip:AddLine(" • " .. line, 0.9, 0.9, 0.9, true)
            end
        end
    end
    GameTooltip:Show()
end)
        row:SetScript("OnLeave", function(self)
    if GameTooltip and GameTooltip:IsOwned(self) then GameTooltip:Hide() end
end)

        row:RegisterForClicks("AnyUp")
        row:SetScript("OnClick", function(self, button)
            local id = self._id
            if not id then return end
            if button == "LeftButton" and IsShiftKeyDown() then
    if AddTrackedAchievement and RemoveTrackedAchievement and IsTrackedAchievement then
        if IsTrackedAchievement(id) then RemoveTrackedAchievement(id) else AddTrackedAchievement(id) end
    elseif AddTrackedAchievement then
        AddTrackedAchievement(id)
    end
    return
end
                if button == "LeftButton" and not IsShiftKeyDown() then
                    if not AchievementFrame or not AchievementFrame_IsVisible then
                        if UIParentLoadAddOn then UIParentLoadAddOn("Blizzard_AchievementUI") end
                    end
                    local AF = _G["AchievementFrame"]
                    if AF then AF:Show() end
                    C_Timer.After(0, function()
                        local selectFn = _G["AchievementFrame_SelectAchievement"]
                        if type(selectFn) == "function" then selectFn(id) end
                    end)
                end
        end)
    end

    function ACA.Top5_Toggle()
        _G.ACA_Top5DB = _G.ACA_Top5DB or {}
        _G.ACA_Top5DB.shown = not not (not Top5:IsShown())
        if _G.ACA_Top5DB.shown then Top5:Show() else Top5:Hide() end
    end

    function ACA.Top5_Show(show)
        _G.ACA_Top5DB = _G.ACA_Top5DB or {}
        _G.ACA_Top5DB.shown = not not show
        if show then Top5:Show() else Top5:Hide() end
    end

    function ACA.Top5_SetLocked(locked)
        _G.ACA_Top5DB = _G.ACA_Top5DB or {}
        _G.ACA_Top5DB.locked = not not locked
    end

    function ACA.Top5_SetClickThrough(ct)
        _G.ACA_Top5DB = _G.ACA_Top5DB or {}
        _G.ACA_Top5DB.clickThrough = not not ct
        SafeEnableMouse(Top5, not ct)
    end

    function ACA.Top5_Update(list)
        if not Top5 or not Top5.rows then return end
        local Utils = ACA and ACA.Utils
        for i = 1, 5 do
            local row = Top5.rows[i]
            local data = list and list[i]
            if data then
                row._id = data.id
                local nm = data.name or ("[" .. tostring(data.id) .. "]")
                if Utils and Utils.TruncateString then
                    nm = Utils.TruncateString(nm, 32)
                end
                row.Title:SetText(nm)
                row.Pct:SetText(string.format("%.0f%%", data.percent or 0))
                row:Show()
            else
                row._id = nil
                row.Title:SetText("")
                row.Pct:SetText("")
                row:Hide()
            end
        end
    end

    -- On init, reflect saved state
    C_Timer.After(0.2, function()
        ACA.Top5_SetLocked(_G.ACA_Top5DB and _G.ACA_Top5DB.locked)
        ACA.Top5_SetClickThrough(_G.ACA_Top5DB and _G.ACA_Top5DB.clickThrough)
        if _G.ACA_Top5DB and _G.ACA_Top5DB.shown then Top5:Show() end
    end)
end
-- === End Top 5 Mini Window ==================================================





-- reward filters (same list)
local function sanitizeReward(r)
    if not r then return "" end
    local s = tostring(r)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")  -- strip colors
    s = s:gsub("|T.-|t", "")                              -- strip textures
    s = s:gsub("^%s+", ""):gsub("%s+$", "")               -- trim
    return s
end

local function matchReward(r, ...)
    local s = sanitizeReward(r):lower()
    if s == "" then return false end
    for i = 1, select("#", ...) do
        local needle = tostring(select(i, ...)):lower()
        if needle ~= "" and s:find(needle, 1, true) then return true end
    end
    return false
end

local FILTERS = {
    ["All"]                 = function(r) return true end,
    ["Any reward"]          = function(r) return sanitizeReward(r) ~= "" end,
    ["Mount"]               = function(r) return matchReward(r, "Mount") end,
    ["Pet"]                 = function(r) return matchReward(r, "Pet") end,
    ["Title"]               = function(r) return matchReward(r, "Title") end,
    ["Infinite Knowledge"]  = function(r) return matchReward(r, "Infinite Knowledge", "Pouch of Infinite Knowledge") end,
    ["Bronze Cache"]        = function(r) return matchReward(r, "Bronze Cache", "Greater Bronze Cache", "Lesser Bronze Cache", "Minor Bronze Cache") end,
    ["Decor"]               = function(r) return matchReward(r, "Decor") end,
    ["Toy"]                 = function(r) return matchReward(r, "Toy", "Toy:") end,
    ["Appearance"]          = function(r) return matchReward(r, "Appearance", "Transmog") end,
    ["Tabard"]              = function(r) return matchReward(r, "Tabard") end,
    ["Illusion"]            = function(r) return matchReward(r, "Illusion", "Illusion:") end,
    ["Drake Customization"] = function(r) return matchReward(r, "Drake Customization") end,
    ["Warband Campsite"]    = function(r) return matchReward(r, "Campsite") end,
    ["Other"]               = function(r)
        local s = sanitizeReward(r)
        if s == "" then return false end
        local known = { "Mount","Title","Pet","Toy","Appearance","Transmog","Tabard","Drake Customization","Decor","Campsite","Bronze Cache","Greater Bronze Cache","Lesser Bronze Cache","Minor Bronze Cache","Infinite Knowledge","Illusion" }
        for _, k in ipairs(known) do if matchReward(s, k) then return false end end
        return true
    end,
}
local FILTER_LIST = {
    "All",
    "Any reward",
    "Mount",
    "Pet",
    "Title",
    "Infinite Knowledge",
    "Bronze Cache",
    "Decor",
    "Toy",
    "Appearance",
    "Tabard",
    "Illusion",
    "Drake Customization",
    "Warband Campsite",
    "Other"
}
ACA.FILTER_LIST = FILTER_LIST
ACA.FILTER_LIST = FILTER_LIST
ACA.FILTER_LIST = FILTER_LIST

-- UpdatePanel: uses cached ACA.scanResults and respects category module's hiddenIDs
function ACA.UpdatePanel(forceRescan)
	 -- new: skip the first eager render until Remix/category maps are settled
    if ACA._deferUntilReady then return end

    local panel = CreateAlmostCompletedPanel()
    -- Ensure Remix auto-apply runs once before the first real scan/render
    if not ACA._remixInitRan then
        ACA._remixInitRan = true
        if ACA.MaybeApplyRemixAfterInit then ACA.MaybeApplyRemixAfterInit() end
    end
    local panel = CreateAlmostCompletedPanel()
    if not panel then return end

local completedChild, ignoredChild = panel.childCompleted, panel.childIgnored
    local threshold = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD

    -- Ignored tab
    if PanelTemplates_GetSelectedTab(panel) == 2 then
        WipeChildren(ignoredChild)
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
            row._ignoreButton:SetText("")
            row._ignoreButton:SetScript("OnClick", function()
                local id = tonumber(ach.id)
                ACA_IgnoreList[id] = nil
                print("ACA: Unignored " .. (ach.name or ach.id))
                local percent = GetCompletionPercent(id)
                if percent >= ACA_ScanThreshold then
                    local _, name, _, _, _, _, _, _, _, icon, rewardText = GetAchievementInfo(id)
                    if not rewardText then local all = { GetAchievementInfo(id) }; rewardText = all[11] or all[12] or all[13] or "" end
                    table.insert(ACA.scanResults, {
                        id = id, name = name or ("[" .. tostring(id) .. "]"),
                        percent = percent, category = ach.category or 0,
                        icon = icon, reward = rewardText
                    })
                end
                ACA.UpdatePanel(false)
            end)
        end
        ignoredChild:SetHeight(math.max(200, (#ignored * (ACA.ROW_HEIGHT + 4)) + 20))
        return
    end

    -- Completed tab
    local needFreshScan = forceRescan
                     or not ACA.scanResultsForThr
                     or (ACA.scanResultsForThr ~= (ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD))

    local function display(results)
        WipeChildren(completedChild)
        local filtered = {}
        local filtFn = FILTERS[ACA_FilterMode] or FILTERS["All"]
        for _, v in ipairs(results) do
            if not (ACA_IgnoreList and ACA_IgnoreList[v.id]) and filtFn(v.reward or "") then -- check category hide map follows
                local hidden = ACA.CategoryFilters and ACA.CategoryFilters.hiddenIDs and ACA.CategoryFilters.hiddenIDs[v.id]
                if not hidden then table.insert(filtered, v) end
            end
        end
        -- NEW: apply sort mode


        sort(filtered, _getComparator(ACA_SortMode or "Percent Desc."))

        

        -- Update the Top 5 pop-out window to mirror current filters/sort (after sort)
        if ACA and ACA.Top5_Update then
            local preview = {}
            for i = 1, math.min(5, #filtered) do preview[i] = filtered[i] end
            ACA.Top5_Update(preview)
        end
local parentFrame = ACA.UI and (ACA.UI.ResultsFrame or ACA.UI.ScrollChild or ACA.UI.ScrollFrame) or completedChild
        if #filtered == 0 then
            if parentFrame and ACA.ShowEmptyResultsMessage then ACA.ShowEmptyResultsMessage(parentFrame) end
            completedChild:SetHeight(200)
-- Finished with 0 results; update counter if on Tab 1
do
    local p = _G[ACA_PANEL_NAME]
    if p and p.resultsLabel and PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(p) == 1 then
        p.resultsLabel:SetText("Results: 0")
        p.resultsLabel:Show()
    end
end

            return
        else
            if parentFrame and ACA.HideEmptyResultsMessage then ACA.HideEmptyResultsMessage(parentFrame) end
        end


        for i, ach in ipairs(filtered) do
            local row = AcquireRow(completedChild)
            row:SetPoint("TOPLEFT", completedChild, "TOPLEFT", 6, -((i - 1) * (ACA.ROW_HEIGHT + 4) + 6))
            ACA:PopulateNativeRow(row, ach)
        end
        completedChild:SetHeight(math.max(200, (#filtered * (ACA.ROW_HEIGHT + 4)) + 20))

        local p = _G[ACA_PANEL_NAME]
        if p and p.scanBar and PanelTemplates_GetSelectedTab(p) == 1 then
            p.scanBar:SetMinMaxValues(0, 1)
            p.scanBar:SetValue(0)
            p.scanBar.Text:SetText("Idle")

-- ACA_RESULTS_LABEL_PATCH -- begin
-- Scan finished; reflect final count on Tab 1
if p and p.resultsLabel and PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(p) == 1 then
    p.resultsLabel:SetText(("Results: %d"):format(#filtered))
    p.resultsLabel:Show()
end
-- ACA_RESULTS_LABEL_PATCH -- end
        end
    end

    if needFreshScan then
        ACA.ScanAchievements(display, function(scanned, total)
            local p = _G[ACA_PANEL_NAME]
            if p and p.scanBar and p.scanBar.Text then
                if total and total > 0 then
                    p.scanBar:SetMinMaxValues(0, total)
                    p.scanBar:SetValue(scanned)
                    local pct = (scanned / total) * 100
                    p.scanBar.Text:SetText(format("Scanning... %d/%d (%.0f%%)", scanned, total, pct))
                
            -- ACA_RESULTS_LABEL_PATCH -- begin
            if p and p.resultsLabel then p.resultsLabel:Hide() end
            -- ACA_RESULTS_LABEL_PATCH -- end
            else
                    p.scanBar:SetMinMaxValues(0, 1)
                    p.scanBar:SetValue(0)
                    p.scanBar.Text:SetText("Scanning... 0/0")
                end
            end
        end)
    else
        if #ACA.scanResults == 0 then
    local pf = ACA.UI and (ACA.UI.ResultsFrame or ACA.UI.ScrollChild or ACA.UI.ScrollFrame) or completedChild
    if pf and ACA.ShowEmptyResultsMessage then ACA.ShowEmptyResultsMessage(pf) end
    completedChild:SetHeight(200)
-- No rescan needed and still 0; show counter if on Tab 1
do
    local p = _G[ACA_PANEL_NAME]
    if p and p.resultsLabel and PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(p) == 1 then
        p.resultsLabel:SetText("Results: 0")
        p.resultsLabel:Show()
    end
end

    return
end
display(ACA.scanResults)
    end
end

-- loader events + slash
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        ACA_ScanThreshold   = ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD
        ACA_Cache           = ACA_Cache or {}
        ACA_IgnoreList      = ACA_IgnoreList or {}
        ACA_FilterMode      = ACA_FilterMode or "All"
        ACA_AnchorSide      = ACA_AnchorSide or "RIGHT"
        ACA_ParseSpeed      = ACA_ParseSpeed or "Auto"
        ACA_SortMode        = ACA_SortMode or "Percent Desc."
        CreateAlmostCompletedPanel()
        C_Timer.After(0, function() if ACA.MaybeApplyRemixAfterInit then ACA.MaybeApplyRemixAfterInit() end end)
    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_AchievementUI" then
        AchievementFrame:HookScript("OnShow", function()
            local p = _G[ACA_PANEL_NAME]
            if p then
                p:Show()
                if p.ShowTab then p.ShowTab(1) else PanelTemplates_SetTab(p, 1) end
                ACA.UpdatePanel(false)
            end
        
            if ACA.UpdateHideButtonVisibility then ACA.UpdateHideButtonVisibility() end
        AchievementFrame:HookScript("OnHide", function()
            local p = _G[ACA_PANEL_NAME]
            if p and p.hideBtn then p.hideBtn:Hide() end
        end)
        end)

    end
end)

-- basic login auto-show
local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_ENTERING_WORLD")
login:SetScript("OnEvent", function(_, _)
    login:UnregisterEvent("PLAYER_ENTERING_WORLD")
    -- Auto-enable Remix toggle on login when API reports Legion Remix (seasonID == 2)
    local ok2, seasonID2 = pcall(PlayerGetTimerunningSeasonID)
    if ok2 and seasonID2 == 2 then
        if not ACA.RemixMode and ACA.ApplyRemixModeIfTimerunner then
            ACA.ApplyRemixModeIfTimerunner()
        end
    end
    if ACA.MaybeApplyRemixAfterInit then ACA.MaybeApplyRemixAfterInit() end

    C_Timer.After(3, function()
        if not AchievementFrame or not AchievementFrame:IsShown() then
            SlashCmdList["ALMOSTCOMPLETED"]()
        end
    end)
end)

-- Slash handling simplified (options in separate module)
local function SlashCmd(msg)
    local cmd, arg1 = strsplit(" ", strtrim(msg or ""), 2)
    cmd = strlower(cmd or "")

    if cmd == "" or cmd == "show" then
        local p = CreateAlmostCompletedPanel()
        if ACA.MaybeApplyRemixAfterInit then ACA.MaybeApplyRemixAfterInit() end
        if p then p:Show(); ACA.UpdatePanel(false) end
        if ACA.UpdateHideButtonVisibility then ACA.UpdateHideButtonVisibility() end
                if ACA.UpdateHideButtonAnchors then ACA.UpdateHideButtonAnchors() end
                if ACA._ApplyPanelStrata then ACA._ApplyPanelStrata(_G[ACA_PANEL_NAME] and _G[ACA_PANEL_NAME]._acaHidden) end
        return
    end

    if cmd == "default" then
        ACA_ScanThreshold = ACA.DEFAULT_THRESHOLD
        ACA_ParseSpeed    = "Auto"
        ACA_AnchorSide    = "RIGHT"
        ACA_FilterMode    = "All"
        local p = SPEED_PRESETS.Smooth
        ACA.BATCH_SIZE, ACA.SCAN_DELAY = p.batch, p.delay
        local panel = _G[ACA_PANEL_NAME]
        if panel and panel.optionsSlider then
            panel.optionsSlider:SetValue(ACA_ScanThreshold)
            panel.optionsSlider.Text:SetText("Threshold: " .. ACA_ScanThreshold .. "%")
        end
        print("ACA: all settings reset to default (ignore list preserved).")
        -- Anchor: default RIGHT
        ACA.Reanchor("RIGHT")
        -- Enforce default radio modes
        _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
        _G.ACA_CatFilterDB["ProfessionsMode"] = "Learned"
        _G.ACA_CatFilterDB["WorldEventsMode"]  = "Active"
        if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
        -- Reflect reward filter dropdown label
        do
            local pnl = _G[ACA_PANEL_NAME]
            if pnl and pnl.filterDropdown then
                UIDropDownMenu_SetText(pnl.filterDropdown, "All")
                if UIDropDownMenu_SetSelectedName then UIDropDownMenu_SetSelectedName(pnl.filterDropdown, "All") end
                if UIDropDownMenu_Refresh then UIDropDownMenu_Refresh(pnl.filterDropdown, true) end
            end
        end
        -- Categories: restore defaults so /aca default matches Reset
        _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}
        for k, v in pairs(_G.ACA_CatFilterDB) do
            if type(v) == "boolean" then _G.ACA_CatFilterDB[k] = true end
        end



        return
    end

    if cmd == "anchorreset" then
        ACA_AnchorSide = "RIGHT"
        local panel = _G[ACA_PANEL_NAME]
        if panel and AchievementFrame then
            panel:ClearAllPoints()
            panel:SetPoint("TOPLEFT", AchievementFrame, "TOPRIGHT", 10, 0)
        end
        print("ACA: anchor reset to RIGHT.")
        return
    end

    if cmd == "ignore" then
        local id = tonumber(arg1)
        if not id then print("ACA: usage /aca ignore <achievementID>"); return end
        ACA_IgnoreList[id] = true
        print(format("ACA: ignored achievement %d.", id))
        for i = #ACA.scanResults, 1, -1 do if ACA.scanResults[i].id == id then table.remove(ACA.scanResults, i) end end
        local panel = _G[ACA_PANEL_NAME]; if panel and panel:IsShown() then ACA.UpdatePanel(false) end
        return
    end

    if cmd == "restore" then
        local id = tonumber(arg1)
        if not id then print("ACA: usage /aca restore <achievementID>"); return end
        if not ACA_IgnoreList[id] then print(format("ACA: achievement %d was not ignored.", id)); return end
        ACA_IgnoreList[id] = nil
        local pct = GetCompletionPercent(id)
        if pct >= (ACA_ScanThreshold or ACA.DEFAULT_THRESHOLD) then
            local _, name, _, _, _, _, _, _, _, icon, rewardText = GetAchievementInfo(id)
            if not rewardText then local all = { GetAchievementInfo(id) }; rewardText = all[11] or all[12] or all[13] or "" end
            table.insert(ACA.scanResults, {
                id = id, name = name or ("["..id.."]"), percent = pct,
                category = 0, icon = icon, reward = rewardText
            })
        end
        print(format("ACA: restored achievement %d.", id))
        local panel = _G[ACA_PANEL_NAME]; if panel and panel:IsShown() then ACA.UpdatePanel(false) end
        return
    end

    if cmd == "scanspeed" then
        local key = strtrim(strlower(arg1 or ""))
        local realKey = ({ fast = "Fast", smooth = "Smooth", slow = "Slow" })[key]
        if not realKey then print("ACA: usage /aca scanspeed <Fast | Smooth | Slow>"); return end
        ACA_ParseSpeed = realKey
        local p = SPEED_PRESETS[realKey]
        ACA.BATCH_SIZE, ACA.SCAN_DELAY = p.batch, p.delay
        print(format("ACA: scan speed set to %s.", realKey))
        return
    end

    
    if cmd == "remix" then
    _G.ACA_CatFilterDB = _G.ACA_CatFilterDB or {}

    if ACA.RemixMode then
        -- Disable Remix: restore snapshot if present
        if ACA._remixBackup and type(ACA._remixBackup) == "table" then
            -- shallow-restore of boolean keys
            for k, v in pairs(ACA._remixBackup.db or {}) do
                _G.ACA_CatFilterDB[k] = v
            end
            if ACA._remixBackup.modes then
                _G.ACA_CatFilterDB["ProfessionsMode"] = ACA._remixBackup.modes.prof  or _G.ACA_CatFilterDB["ProfessionsMode"]
                _G.ACA_CatFilterDB["WorldEventsMode"]  = ACA._remixBackup.modes.world or _G.ACA_CatFilterDB["WorldEventsMode"]
            end
        else
            -- no snapshot? be generous: turn all categories back on
            for k, v in pairs(_G.ACA_CatFilterDB) do
                if type(v) == "boolean" then _G.ACA_CatFilterDB[k] = true end
            end
            _G.ACA_CatFilterDB["ProfessionsMode"] = _G.ACA_CatFilterDB["ProfessionsMode"] or "All"
            _G.ACA_CatFilterDB["WorldEventsMode"]  = _G.ACA_CatFilterDB["WorldEventsMode"]  or "Active"
        end

        ACA.RemixMode = false
        if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
        print("ACA: Remix disabled.")
        ACA.UpdatePanel(false)
        return
    end

    -- Enable Remix: snapshot then apply Remix settings
    ACA._remixBackup = { db = {}, modes = {} }
    for k, v in pairs(_G.ACA_CatFilterDB) do
        if type(v) == "boolean" then ACA._remixBackup.db[k] = v end
    end
    ACA._remixBackup.modes.prof  = _G.ACA_CatFilterDB["ProfessionsMode"]
    ACA._remixBackup.modes.world = _G.ACA_CatFilterDB["WorldEventsMode"]

    -- baseline: only Legion: Remix checked
    if _G.ACA_CatFilterDB["Legion: Remix"] == nil then _G.ACA_CatFilterDB["Legion: Remix"] = true end
    for k, v in pairs(_G.ACA_CatFilterDB) do
        if type(v) == "boolean" then _G.ACA_CatFilterDB[k] = (k == "Legion: Remix") end
    end
    -- force modes off in Remix
    _G.ACA_CatFilterDB["ProfessionsMode"] = "None"
    _G.ACA_CatFilterDB["WorldEventsMode"]  = "None"

    ACA.RemixMode = true
    if ACA.SyncOptionsUI then ACA.SyncOptionsUI() end
    print("ACA: Remix enabled. Legion: Remix only; Professions/World Events set to None. Use /aca remix again to disable.")
    ACA.UpdatePanel(false)
    return
end




    print("ACA: unknown command.")
end

SLASH_ALMOSTCOMPLETED1 = "/aca"
SlashCmdList["ALMOSTCOMPLETED"] = SlashCmd

-- expose
ACA.UpdatePanel = ACA.UpdatePanel
ACA.GetCompletionPercent = GetCompletionPercent

-- Attempt to apply Remix after initialization is complete.
function ACA.MaybeApplyRemixAfterInit()
    -- already applied once? skip
    if not _G.ACA_CatFilterDB then return end
    if ACA.CategoryFilters and ACA.CategoryFilters.mapsBuilt == false then return end
    if ACA._deferUntilReady then
        -- if this is a Remix character, apply Remix defaults now
        if IsTimerunnerRemix() then
            ACA.ApplyRemixModeIfTimerunner()
        end
        ACA._deferUntilReady = false
        if ACA.UpdatePanel then ACA.UpdatePanel(true) end
        return
    end

    -- if we get here later and Remix hasn’t been applied yet, apply it
    if not ACA.RemixApplied and IsTimerunnerRemix() then
        ACA.ApplyRemixModeIfTimerunner()
        -- after applying Remix late, do a rescan to reflect new filters
        if ACA.UpdatePanel then ACA.UpdatePanel(true) end
    end
end


-- Run the Remix auto-apply check exactly once after the first panel update
do
    local _aca_remix_once_tried = false
    hooksecurefunc(ACA, "UpdatePanel", function()
        if _aca_remix_once_tried then return end
        _aca_remix_once_tried = true
        C_Timer.After(0, function()
            if ACA.MaybeApplyRemixAfterInit then
                ACA.MaybeApplyRemixAfterInit()
            end
        end)
    end)
end

-- BEGIN PATCH (core.lua)
-- reason: Empty-state overlay helpers to avoid rescan loops when zero results
do
    local EMPTY_MSG = "Your current ACA settings returned 0 results.|nLoosen your filters or lower the threshold, then click Rescan."
    function ACA.ShowEmptyResultsMessage(parent)
        if not parent or (parent.IsForbidden and parent:IsForbidden()) then return end
        if not parent.ACAEmptyState then
            local f = CreateFrame("Frame", nil, parent)
            f:SetAllPoints(parent)
            f:Hide()
            -- no background; just text in the results area
            local t = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            t:SetPoint("TOP", 0, -40)
            t:SetJustifyH("CENTER")
            t:SetJustifyV("TOP")
            t:SetWordWrap(true)
            t:SetText(EMPTY_MSG)
            f.Text = t
            parent.ACAEmptyState = f
        end
        parent.ACAEmptyState.Text:SetText(EMPTY_MSG)
        parent.ACAEmptyState:Show()
    end
    function ACA.HideEmptyResultsMessage(parent)
        if parent and parent.ACAEmptyState then parent.ACAEmptyState:Hide() end
    end
end
-- END PATCH
