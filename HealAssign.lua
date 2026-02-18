-- HealAssign.lua
-- WoW 1.12.1 Addon for raid heal assignments
-- Assign healers to tanks and groups, sync with raid members

-------------------------------------------------------------------------------
-- CONSTANTS & CLASS COLORS
-------------------------------------------------------------------------------
local ADDON_NAME = "HealAssign"
local ADDON_VERSION = "1.0.0"
local COMM_PREFIX = "HealAssign"

local CLASS_COLORS = {
    ["WARRIOR"]     = {r=0.78, g=0.61, b=0.43},
    ["PALADIN"]     = {r=0.96, g=0.55, b=0.73},
    ["HUNTER"]      = {r=0.67, g=0.83, b=0.45},
    ["ROGUE"]       = {r=1.00, g=0.96, b=0.41},
    ["PRIEST"]      = {r=1.00, g=1.00, b=1.00},
    ["SHAMAN"]      = {r=0.00, g=0.44, b=0.87},
    ["MAGE"]        = {r=0.41, g=0.80, b=0.94},
    ["WARLOCK"]     = {r=0.58, g=0.51, b=0.79},
    ["DRUID"]       = {r=1.00, g=0.49, b=0.04},
}

local CLASS_NAMES = {
    "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST",
    "SHAMAN", "MAGE", "WARLOCK", "DRUID"
}

local CLASS_DISPLAY = {
    ["WARRIOR"]  = "Warrior",
    ["PALADIN"]  = "Paladin",
    ["HUNTER"]   = "Hunter",
    ["ROGUE"]    = "Rogue",
    ["PRIEST"]   = "Priest",
    ["SHAMAN"]   = "Shaman",
    ["MAGE"]     = "Mage",
    ["WARLOCK"]  = "Warlock",
    ["DRUID"]    = "Druid",
}

-------------------------------------------------------------------------------
-- SAVED VARIABLES DEFAULT
-------------------------------------------------------------------------------
-------------------------------------------------------------------------------
-- SAVED VARIABLES DEFAULT
-- NOTE: Do NOT pre-initialize HealAssignDB here.
-- In WoW 1.12, SavedVariables are nil until VARIABLES_LOADED fires.
-- InitDB() is called from the VARIABLES_LOADED event handler.
-------------------------------------------------------------------------------
local function InitDB()
    -- Ensure the global exists (in case called before VARIABLES_LOADED)
    if not HealAssignDB then HealAssignDB = {} end
    if not HealAssignDB.templates then HealAssignDB.templates = {} end
    if not HealAssignDB.activeTemplate then HealAssignDB.activeTemplate = nil end
    if not HealAssignDB.options then
        HealAssignDB.options = {
            tankClasses = {
                ["WARRIOR"] = true,
                ["DRUID"]   = true,
                ["PALADIN"] = true,
            },
            customTargets = {},
            chatChannel = 1,
            showAssignFrame = true,
        }
    end
    if not HealAssignDB.options.customTargets then
        HealAssignDB.options.customTargets = {}
    end
    if not HealAssignDB.options.chatChannel then
        HealAssignDB.options.chatChannel = 1
    end
    if HealAssignDB.options.showAssignFrame == nil then
        HealAssignDB.options.showAssignFrame = true
    end
    if not HealAssignDB.options.tankClasses then
        HealAssignDB.options.tankClasses = {
            ["WARRIOR"] = true,
            ["DRUID"]   = true,
            ["PALADIN"] = true,
        }
    end
end

-------------------------------------------------------------------------------
-- UTILITY FUNCTIONS
-------------------------------------------------------------------------------
local function GetClassColor(class)
    local c = CLASS_COLORS[class]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

-- Get all raid/party members with their class
local function GetRaidMembers()
    local members = {}
    local numRaid = GetNumRaidMembers()
    if numRaid and numRaid > 0 then
        for i = 1, numRaid do
            local name, rank, subgroup, level, class, fileName, zone, online, isDead = GetRaidRosterInfo(i)
            if name then
                -- fileName is the uppercase class name in 1.12
                table.insert(members, {name=name, class=fileName or class, subgroup=subgroup, online=online})
            end
        end
    else
        local pname = UnitName("player")
        local _, pclass = UnitClass("player")
        if pname then
            table.insert(members, {name=pname, class=pclass, subgroup=1, online=true})
        end
        local numParty = GetNumPartyMembers()
        if numParty and numParty > 0 then
            for i = 1, numParty do
                local mname = UnitName("party"..i)
                local _, mclass = UnitClass("party"..i)
                if mname then
                    table.insert(members, {name=mname, class=mclass, subgroup=1, online=true})
                end
            end
        end
    end
    table.sort(members, function(a,b) return a.name < b.name end)
    return members
end

-- Get player class by name from raid/party
local function GetPlayerClass(playerName)
    if not playerName then return nil end
    local numRaid = GetNumRaidMembers()
    if numRaid and numRaid > 0 then
        for i = 1, numRaid do
            local name, rank, subgroup, level, class, fileName = GetRaidRosterInfo(i)
            if name == playerName then
                return fileName or class
            end
        end
    end
    if UnitName("player") == playerName then
        local _, pclass = UnitClass("player")
        return pclass
    end
    local numParty = GetNumPartyMembers()
    if numParty and numParty > 0 then
        for i = 1, numParty do
            if UnitName("party"..i) == playerName then
                local _, c = UnitClass("party"..i)
                return c
            end
        end
    end
    return nil
end

-- Serialize template to string for addon comm
-- Format: v1~name~type:value,type:value,...~idx:h1;h2|idx:h1;h2
local function Serialize(t)
    local parts = {}
    table.insert(parts, "v1")
    table.insert(parts, t.name or "")

    local targetParts = {}
    for i, target in ipairs(t.targets or {}) do
        -- Escape colons/commas in values
        local safeVal = string.gsub(target.value or "", "[,~|;:]", "_")
        table.insert(targetParts, target.type..":"..safeVal)
    end
    table.insert(parts, table.concat(targetParts, ","))

    local healerParts = {}
    for i, target in ipairs(t.targets or {}) do
        local hlist = {}
        for _, h in ipairs(target.healers or {}) do
            table.insert(hlist, h)
        end
        table.insert(healerParts, i..":"..table.concat(hlist, ";"))
    end
    table.insert(parts, table.concat(healerParts, "|"))

    return table.concat(parts, "~")
end

local function Deserialize(str)
    if not str then return nil end
    local parts = {}
    -- Split by ~
    local i = 1
    local last = 1
    while i <= string.len(str) do
        if string.sub(str, i, i) == "~" then
            table.insert(parts, string.sub(str, last, i-1))
            last = i + 1
        end
        i = i + 1
    end
    table.insert(parts, string.sub(str, last))

    if parts[1] ~= "v1" then return nil end
    local t = {}
    t.name = parts[2] or ""
    t.targets = {}

    if parts[3] and parts[3] ~= "" then
        -- Split by comma
        local tstr = parts[3]
        local ti = 1
        local tlast = 1
        while ti <= string.len(tstr) do
            if string.sub(tstr, ti, ti) == "," then
                local entry = string.sub(tstr, tlast, ti-1)
                local colon = string.find(entry, ":")
                if colon then
                    local ttype = string.sub(entry, 1, colon-1)
                    local tval = string.sub(entry, colon+1)
                    table.insert(t.targets, {type=ttype, value=tval, healers={}})
                end
                tlast = ti + 1
            end
            ti = ti + 1
        end
        -- Last entry
        local entry = string.sub(tstr, tlast)
        if entry ~= "" then
            local colon = string.find(entry, ":")
            if colon then
                local ttype = string.sub(entry, 1, colon-1)
                local tval = string.sub(entry, colon+1)
                table.insert(t.targets, {type=ttype, value=tval, healers={}})
            end
        end
    end

    if parts[4] and parts[4] ~= "" then
        -- Split by |
        local hstr = parts[4]
        local hi = 1
        local hlast = 1
        while hi <= string.len(hstr) do
            if string.sub(hstr, hi, hi) == "|" then
                local entry = string.sub(hstr, hlast, hi-1)
                local colon = string.find(entry, ":")
                if colon then
                    local idx = tonumber(string.sub(entry, 1, colon-1))
                    local healers_str = string.sub(entry, colon+1)
                    if idx and t.targets[idx] then
                        t.targets[idx].healers = {}
                        if healers_str ~= "" then
                            -- Split by ;
                            local si = 1
                            local slast = 1
                            while si <= string.len(healers_str) do
                                if string.sub(healers_str, si, si) == ";" then
                                    local h = string.sub(healers_str, slast, si-1)
                                    if h ~= "" then table.insert(t.targets[idx].healers, h) end
                                    slast = si + 1
                                end
                                si = si + 1
                            end
                            local h = string.sub(healers_str, slast)
                            if h ~= "" then table.insert(t.targets[idx].healers, h) end
                        end
                    end
                end
                hlast = hi + 1
            end
            hi = hi + 1
        end
        -- Last entry
        local entry = string.sub(hstr, hlast)
        if entry ~= "" then
            local colon = string.find(entry, ":")
            if colon then
                local idx = tonumber(string.sub(entry, 1, colon-1))
                local healers_str = string.sub(entry, colon+1)
                if idx and t.targets[idx] then
                    t.targets[idx].healers = {}
                    if healers_str ~= "" then
                        local si = 1
                        local slast = 1
                        while si <= string.len(healers_str) do
                            if string.sub(healers_str, si, si) == ";" then
                                local h = string.sub(healers_str, slast, si-1)
                                if h ~= "" then table.insert(t.targets[idx].healers, h) end
                                slast = si + 1
                            end
                            si = si + 1
                        end
                        local h = string.sub(healers_str, slast)
                        if h ~= "" then table.insert(t.targets[idx].healers, h) end
                    end
                end
            end
        end
    end

    return t
end

-------------------------------------------------------------------------------
-- MAIN FRAME VARIABLES
-------------------------------------------------------------------------------
local mainFrame = nil
local optionsFrame = nil
local assignFrame = nil
local dropdownFrame = nil
local activeDropdown = nil

local currentTemplate = nil
local templateRows = {}

-------------------------------------------------------------------------------
-- DROPDOWN MENU
-------------------------------------------------------------------------------
local function CloseDropdown()
    if dropdownFrame then
        dropdownFrame:Hide()
    end
    activeDropdown = nil
end

local function ShowDropdown(anchorFrame, items, onSelect, width)
    CloseDropdown()

    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame", "HealAssignDropdownFrame", UIParent)
        dropdownFrame:SetFrameStrata("TOOLTIP")
        dropdownFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        dropdownFrame:SetBackdropColor(0.08, 0.08, 0.12, 0.97)
        dropdownFrame.buttons = {}
    end

    local f = dropdownFrame
    -- Hide all existing buttons
    for _, b in ipairs(f.buttons) do
        b:Hide()
    end

    local itemH = 18
    local pad = 4
    local w = width or 160
    local h = table.getn(items) * itemH + pad * 2
    if h < 20 then h = 20 end

    f:SetWidth(w)
    f:SetHeight(h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -2)

    for i, item in ipairs(items) do
        local btn = f.buttons[i]
        if not btn then
            btn = CreateFrame("Button", nil, f)
            btn:SetHeight(itemH)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            btn:GetHighlightTexture():SetAlpha(0.4)
            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
            fs:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
            fs:SetJustifyH("LEFT")
            btn.label = fs
            f.buttons[i] = btn
        end

        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -(pad + (i-1)*itemH))
        btn:SetWidth(w - pad*2)
        btn:Show()

        if item.r then
            btn.label:SetTextColor(item.r, item.g, item.b)
        else
            btn.label:SetTextColor(1, 1, 1)
        end
        btn.label:SetText(item.text or "")

        local capturedItem = item
        btn:SetScript("OnClick", function()
            CloseDropdown()
            onSelect(capturedItem)
        end)
    end

    f:Show()
    activeDropdown = f
end

-------------------------------------------------------------------------------
-- TEMPLATE MANAGEMENT
-------------------------------------------------------------------------------
local function NewTemplate(name)
    return {
        name = name or "New Template",
        targets = {},
    }
end

local function GetActiveTemplate()
    if not HealAssignDB.activeTemplate then return nil end
    return HealAssignDB.templates[HealAssignDB.activeTemplate]
end

local function SaveCurrentTemplate()
    if not currentTemplate then return end
    if not currentTemplate.name or currentTemplate.name == "" then
        currentTemplate.name = "Template"
    end
    HealAssignDB.templates[currentTemplate.name] = currentTemplate
    HealAssignDB.activeTemplate = currentTemplate.name
end

-------------------------------------------------------------------------------
-- ASSIGNMENT DISPLAY FRAME (healer's personal view)
-------------------------------------------------------------------------------
local function UpdateAssignFrame()
    if not assignFrame then return end
    if not assignFrame:IsShown() then return end

    local myName = UnitName("player")
    local content = assignFrame.content

    local tmpl = GetActiveTemplate()
    if not tmpl then
        content:SetText("|cff888888No active template.|r")
        return
    end

    local lines = {}
    table.insert(lines, "|cff00ccff"..tmpl.name.."|r")

    local found = false
    for _, target in ipairs(tmpl.targets) do
        for _, healer in ipairs(target.healers) do
            if healer == myName then
                found = true
                local targetText = ""
                if target.type == "tank" then
                    local cls = GetPlayerClass(target.value)
                    if cls then
                        local r, g, b = GetClassColor(cls)
                        targetText = string.format("|cff%02x%02x%02x%s|r", r*255, g*255, b*255, target.value)
                    else
                        targetText = target.value
                    end
                    targetText = "Tank: "..targetText
                elseif target.type == "group" then
                    targetText = "|cff55ccff"..target.value.."|r"
                elseif target.type == "custom" then
                    targetText = "|cffcccccc"..target.value.."|r"
                end
                table.insert(lines, "  "..targetText)
                break
            end
        end
    end

    if not found then
        table.insert(lines, "|cff888888No assignments for you.|r")
    end

    content:SetText(table.concat(lines, "\n"))

    -- Resize frame to fit content
    local numLines = table.getn(lines)
    local newH = 22 + numLines * 14 + 10
    if newH < 50 then newH = 50 end
    assignFrame:SetHeight(newH)
end

local function CreateAssignFrame()
    if assignFrame then return end

    local f = CreateFrame("Frame", "HealAssignAssignFrame", UIParent)
    f:SetWidth(200)
    f:SetHeight(80)
    f:SetPoint("CENTER", UIParent, "CENTER", 300, 200)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true, tileSize=8, edgeSize=8,
        insets={left=2,right=2,top=2,bottom=2}
    })
    f:SetBackdropColor(0.05, 0.05, 0.1, 0.88)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -5)
    title:SetTextColor(0.4, 0.8, 1)
    title:SetText("My Assignments")

    local content = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -18)
    content:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -18)
    content:SetJustifyH("LEFT")
    content:SetJustifyV("TOP")
    content:SetText("|cff888888Waiting for sync...|r")
    f.content = content

    assignFrame = f

    if HealAssignDB.options and HealAssignDB.options.showAssignFrame then
        f:Show()
    else
        f:Hide()
    end
end

-------------------------------------------------------------------------------
-- MAIN FRAME UI
-------------------------------------------------------------------------------
local MAIN_W = 520
local MAIN_H = 500
local ROW_H = 22
local INDENT_HEALER = 20

local function RebuildMainRows()
    for _, row in ipairs(templateRows) do
        row:Hide()
    end
    templateRows = {}

    if not currentTemplate then return end
    if not mainFrame then return end

    local scrollChild = mainFrame.scrollChild
    local yOffset = -5

    for ti, target in ipairs(currentTemplate.targets) do
        -- Target row background
        local targetRow = CreateFrame("Frame", nil, scrollChild)
        targetRow:SetHeight(ROW_H)
        targetRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 5, yOffset)
        targetRow:SetPoint("RIGHT", scrollChild, "RIGHT", -5, 0)
        table.insert(templateRows, targetRow)

        -- Colored background for target row
        local bg = targetRow:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if target.type == "tank" then
            bg:SetTexture(0.2, 0.1, 0.05, 0.4)
        elseif target.type == "group" then
            bg:SetTexture(0.05, 0.1, 0.2, 0.4)
        else
            bg:SetTexture(0.1, 0.1, 0.1, 0.4)
        end

        -- Target label
        local targetLabel = targetRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        targetLabel:SetPoint("LEFT", targetRow, "LEFT", 4, 0)
        targetLabel:SetWidth(220)
        targetLabel:SetJustifyH("LEFT")

        local displayText = ""
        if target.type == "tank" then
            local cls = GetPlayerClass(target.value)
            if cls then
                local r, g, b = GetClassColor(cls)
                displayText = string.format("|cff%02x%02x%02x[Tank] %s|r", r*255, g*255, b*255, target.value)
            else
                displayText = "|cffcc8844[Tank]|r "..target.value
            end
        elseif target.type == "group" then
            displayText = "|cff55ccff[Group] "..target.value.."|r"
        elseif target.type == "custom" then
            displayText = "|cffaaaaaa[Custom] "..target.value.."|r"
        end
        targetLabel:SetText(displayText)

        -- Add Healer button
        local addHealerBtn = CreateFrame("Button", nil, targetRow, "UIPanelButtonTemplate")
        addHealerBtn:SetWidth(90)
        addHealerBtn:SetHeight(18)
        addHealerBtn:SetPoint("LEFT", targetLabel, "RIGHT", 5, 0)
        addHealerBtn:SetText("Add Healer")
        --addHealerBtn:SetNormalFontObject(GameFontNormalSmall)

        local capturedTI = ti
        addHealerBtn:SetScript("OnClick", function()
            local members = GetRaidMembers()
            local items = {}
            for _, m in ipairs(members) do
                local r, g, b = GetClassColor(m.class)
                table.insert(items, {text=m.name, name=m.name, class=m.class, r=r, g=g, b=b})
            end
            if table.getn(items) == 0 then
                table.insert(items, {text="(No raid members)", name=nil, r=0.5,g=0.5,b=0.5})
            end
            ShowDropdown(addHealerBtn, items, function(item)
                if item.name then
                    local already = false
                    for _, h in ipairs(currentTemplate.targets[capturedTI].healers) do
                        if h == item.name then already = true end
                    end
                    if not already then
                        table.insert(currentTemplate.targets[capturedTI].healers, item.name)
                        SaveCurrentTemplate()
                        RebuildMainRows()
                    end
                end
            end, 180)
        end)

        -- Remove target button
        local removeTargetBtn = CreateFrame("Button", nil, targetRow, "UIPanelButtonTemplate")
        removeTargetBtn:SetWidth(22)
        removeTargetBtn:SetHeight(18)
        removeTargetBtn:SetPoint("RIGHT", targetRow, "RIGHT", -2, 0)
        removeTargetBtn:SetText("X")
        --removeTargetBtn:SetNormalFontObject(GameFontNormalSmall)
        local capturedTI2 = ti
        removeTargetBtn:SetScript("OnClick", function()
            table.remove(currentTemplate.targets, capturedTI2)
            SaveCurrentTemplate()
            RebuildMainRows()
        end)

        yOffset = yOffset - ROW_H

        -- Healer rows
        for hi, healer in ipairs(target.healers) do
            local healerRow = CreateFrame("Frame", nil, scrollChild)
            healerRow:SetHeight(ROW_H - 4)
            healerRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", INDENT_HEALER, yOffset)
            healerRow:SetPoint("RIGHT", scrollChild, "RIGHT", -5, 0)
            table.insert(templateRows, healerRow)

            local healerLabel = healerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            healerLabel:SetPoint("LEFT", healerRow, "LEFT", 4, 0)
            healerLabel:SetWidth(220)
            healerLabel:SetJustifyH("LEFT")

            local cls = GetPlayerClass(healer)
            local htext = ""
            if cls then
                local r, g, b = GetClassColor(cls)
                htext = string.format("|cff%02x%02x%02x  -> %s|r", r*255, g*255, b*255, healer)
            else
                htext = "  -> "..healer
            end
            healerLabel:SetText(htext)

            -- Remove healer button
            local removeHealerBtn = CreateFrame("Button", nil, healerRow, "UIPanelButtonTemplate")
            removeHealerBtn:SetWidth(22)
            removeHealerBtn:SetHeight(16)
            removeHealerBtn:SetPoint("RIGHT", healerRow, "RIGHT", -2, 0)
            removeHealerBtn:SetText("X")
            
            -- Fix: Use direct local variables for the closure to ensure correct indexing
            local targetIndex = ti
            local healerIndex = hi
            
            removeHealerBtn:SetScript("OnClick", function()
                if currentTemplate and currentTemplate.targets[targetIndex] then
                    table.remove(currentTemplate.targets[targetIndex].healers, healerIndex)
                    SaveCurrentTemplate()
                    RebuildMainRows()
                end
            end)

            yOffset = yOffset - (ROW_H - 4)
        end

        -- Small gap between targets
        yOffset = yOffset - 4
    end

    local totalH = math.abs(yOffset) + 20
    if totalH < 200 then totalH = 200 end
    scrollChild:SetHeight(totalH)
end

local function CreateMainFrame()
    if mainFrame then
        mainFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "HealAssignMainFrame", UIParent)
    f:SetWidth(MAIN_W)
    f:SetHeight(MAIN_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8}
    })
    f:SetBackdropColor(0.08, 0.08, 0.14, 0.96)

    -- Title
    local titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -14)
    titleText:SetText("|cff00ccffHealAssign|r v"..ADDON_VERSION)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function()
        f:Hide()
        CloseDropdown()
    end)

-------------------------------------------------------------------------------
    -- Row 1: Template name + Save/Load/Delete (Perfect Centering)
    -------------------------------------------------------------------------------
    local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    -- Centering based on the whole row width (~336px). 
    -- We anchor to TOP and move left by 168px to start the row.
    nameLabel:SetPoint("TOP", f, "TOP", -145, -42) 
    nameLabel:SetText("Template:")

    local nameEdit = CreateFrame("EditBox", "HealAssignNameEdit", f, "InputBoxTemplate")
    nameEdit:SetWidth(100) -- Reduced width as requested
    nameEdit:SetHeight(20)
    nameEdit:SetPoint("LEFT", nameLabel, "RIGHT", 5, 0)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(64)
    nameEdit:SetText("") 
    f.nameEdit = nameEdit

    -- Save button
    local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    saveBtn:SetWidth(50)
    saveBtn:SetHeight(20)
    saveBtn:SetPoint("LEFT", nameEdit, "RIGHT", 8, 0)
    saveBtn:SetText("Save")
    saveBtn:SetScript("OnClick", function()
        local name = f.nameEdit:GetText()
        if not name or name == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Enter a template name first.")
            return
        end
        
        if not currentTemplate then
            currentTemplate = NewTemplate(name)
        else
            if currentTemplate.name ~= name then
                HealAssignDB.templates[currentTemplate.name] = nil
                currentTemplate.name = name
            end
        end
        SaveCurrentTemplate()
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..name.."' saved.")
        RebuildMainRows()
    end)

    -- Load button
    local loadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    loadBtn:SetWidth(50)
    loadBtn:SetHeight(20)
    loadBtn:SetPoint("LEFT", saveBtn, "RIGHT", 4, 0)
    loadBtn:SetText("Load")
    loadBtn:SetScript("OnClick", function()
        local items = {}
        for tname, _ in pairs(HealAssignDB.templates) do
            table.insert(items, {text=tname, name=tname, r=1,g=0.9,b=0.5})
        end
        table.sort(items, function(a,b) return a.text < b.text end)
        if table.getn(items) == 0 then
            table.insert(items, {text="(No saved templates)", name=nil, r=0.5,g=0.5,b=0.5})
        end
        ShowDropdown(loadBtn, items, function(item)
            if item.name then
                currentTemplate = HealAssignDB.templates[item.name]
                HealAssignDB.activeTemplate = item.name
                f.nameEdit:SetText(currentTemplate.name)
                RebuildMainRows()
            end
        end, 180)
    end)

    -- Delete button
    local delTmplBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    delTmplBtn:SetWidth(55)
    delTmplBtn:SetHeight(20)
    delTmplBtn:SetPoint("LEFT", loadBtn, "RIGHT", 4, 0)
    delTmplBtn:SetText("Delete")
    delTmplBtn:SetScript("OnClick", function()
        if currentTemplate then
            HealAssignDB.templates[currentTemplate.name] = nil
            HealAssignDB.activeTemplate = nil
            currentTemplate = nil
            f.nameEdit:SetText("")
            RebuildMainRows()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template deleted.")
        end
    end)

-------------------------------------------------------------------------------
    -- Row 2: Toolbar buttons (Centered via TOP anchor)
    -------------------------------------------------------------------------------
    local toolY = -68
    local btnH = 22
    local btnSpacing = 4
    
    -- The total width of all buttons + spacing is 428px.
    -- To center it, the first button must start at -(428/2) + (first_button_width/2)
    -- Calculation: -214 + 44 = -170
    local startOffset = -170

    -- Add Tank
    local addTankBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addTankBtn:SetWidth(88)
    addTankBtn:SetHeight(btnH)
    -- We anchor to "TOP" (center) instead of "TOPLEFT"
    addTankBtn:SetPoint("TOP", f, "TOP", startOffset, toolY)
    addTankBtn:SetText("Add Tank")
    addTankBtn:SetScript("OnClick", function()
        if not currentTemplate then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Create or load a template first.")
            return
        end
        local members = GetRaidMembers()
        local items = {}
        for _, m in ipairs(members) do
            if HealAssignDB.options.tankClasses[m.class] then
                local r, g, b = GetClassColor(m.class)
                table.insert(items, {text=m.name, name=m.name, class=m.class, r=r, g=g, b=b})
            end
        end
        if table.getn(items) == 0 then
            for _, m in ipairs(members) do
                local r, g, b = GetClassColor(m.class)
                table.insert(items, {text=m.name, name=m.name, class=m.class, r=r, g=g, b=b})
            end
        end
        if table.getn(items) == 0 then
            table.insert(items, {text="(No raid members)", name=nil, r=0.5,g=0.5,b=0.5})
        end
        ShowDropdown(addTankBtn, items, function(item)
            if item.name then
                table.insert(currentTemplate.targets, {type="tank", value=item.name, healers={}})
                SaveCurrentTemplate()
                RebuildMainRows()
            end
        end, 180)
    end)

    -- Add Group
    local addGroupBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addGroupBtn:SetWidth(88)
    addGroupBtn:SetHeight(btnH)
    -- Anchor to the right of the previous button
    addGroupBtn:SetPoint("LEFT", addTankBtn, "RIGHT", btnSpacing, 0)
    addGroupBtn:SetText("Add Group")
    addGroupBtn:SetScript("OnClick", function()
        if not currentTemplate then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Create or load a template first.")
            return
        end
        local items = {}
        for i = 1, 8 do
            table.insert(items, {text="Group "..i, value="Group "..i, r=0.4, g=0.8, b=1.0})
        end
        ShowDropdown(addGroupBtn, items, function(item)
            table.insert(currentTemplate.targets, {type="group", value=item.value, healers={}})
            SaveCurrentTemplate()
            RebuildMainRows()
        end, 120)
    end)

    -- Add Custom
    local addCustomBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addCustomBtn:SetWidth(92)
    addCustomBtn:SetHeight(btnH)
    addCustomBtn:SetPoint("LEFT", addGroupBtn, "RIGHT", btnSpacing, 0)
    addCustomBtn:SetText("Add Custom")
    addCustomBtn:SetScript("OnClick", function()
        if not currentTemplate then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Create or load a template first.")
            return
        end
        local items = {}
        for _, ct in ipairs(HealAssignDB.options.customTargets) do
            table.insert(items, {text=ct, value=ct, r=0.8, g=0.8, b=0.8})
        end
        if table.getn(items) == 0 then
            table.insert(items, {text="(Add custom targets in Options)", value=nil, r=0.5,g=0.5,b=0.5})
        end
        ShowDropdown(addCustomBtn, items, function(item)
            if item.value then
                table.insert(currentTemplate.targets, {type="custom", value=item.value, healers={}})
                SaveCurrentTemplate()
                RebuildMainRows()
            end
        end, 210)
    end)

    -- Options button
    local optionsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    optionsBtn:SetWidth(72)
    optionsBtn:SetHeight(btnH)
    optionsBtn:SetPoint("LEFT", addCustomBtn, "RIGHT", btnSpacing, 0)
    optionsBtn:SetText("Options")
    optionsBtn:SetScript("OnClick", function()
        CloseDropdown()
        if optionsFrame then
            if optionsFrame:IsShown() then
                optionsFrame:Hide()
            else
                optionsFrame:Show()
            end
        end
    end)

    -- Sync button
    local syncBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    syncBtn:SetWidth(72)
    syncBtn:SetHeight(btnH)
    syncBtn:SetPoint("LEFT", optionsBtn, "RIGHT", btnSpacing, 0)
    syncBtn:SetText("Sync Raid")
    syncBtn:SetScript("OnClick", function()
        HealAssign_SyncTemplate()
    end)

    -- Separator line
    local sep = f:CreateTexture(nil, "ARTWORK")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", f, "TOPLEFT", 12, toolY - btnH - 4)
    sep:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, toolY - btnH - 4)
    sep:SetTexture(0.3, 0.3, 0.4, 0.8)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "HealAssignScrollFrame", f, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 12, toolY - btnH - 10)
    scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -28, 36)

    local scrollChild = CreateFrame("Frame", "HealAssignScrollChild", scrollFrame)
    scrollChild:SetWidth(MAIN_W - 55)
    scrollChild:SetHeight(300)
    scrollFrame:SetScrollChild(scrollChild)

    f.scrollFrame = scrollFrame
    f.scrollChild = scrollChild

    -- Status bar
    local statusBar = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusBar:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    statusBar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)
    statusBar:SetJustifyH("LEFT")
    statusBar:SetTextColor(0.6, 0.6, 0.6)
    statusBar:SetText("/ha sync  |  /ha options  |  /ha assign  |  /ha help")
    f.statusBar = statusBar

    mainFrame = f
    f:Show()
end

-------------------------------------------------------------------------------
-- OPTIONS FRAME
-------------------------------------------------------------------------------
local function CreateOptionsFrame()
    if optionsFrame then
        optionsFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "HealAssignOptionsFrame", UIParent)
    f:SetWidth(370)
    f:SetHeight(440)
    f:SetPoint("TOPLEFT", UIParent, "CENTER", 20, 100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true, tileSize=32, edgeSize=32,
        insets={left=8,right=8,top=8,bottom=8}
    })
    f:SetBackdropColor(0.08, 0.08, 0.14, 0.96)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", f, "TOP", 0, -14)
    title:SetText("|cff00ccffHealAssign|r - Options")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    -- Section: Tank Classes
    local sec1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sec1:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -42)
    sec1:SetTextColor(1, 0.8, 0.2)
    sec1:SetText("Tank Classes (shown in Add Tank dropdown):")

    local cbX = 14
    local cbY = -60
    local cbPerRow = 3
    local cbW = 110
    local cbH = 20

    for i, cls in ipairs(CLASS_NAMES) do
        local cb = CreateFrame("CheckButton", "HealAssignCB_"..cls, f, "UICheckButtonTemplate")
        cb:SetWidth(cbH)
        cb:SetHeight(cbH)
        local col = math.mod(i-1, cbPerRow)
        local row = math.floor((i-1) / cbPerRow)
        cb:SetPoint("TOPLEFT", f, "TOPLEFT", cbX + col * cbW, cbY - row * (cbH + 2))

        local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        lbl:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        local r, g, b = GetClassColor(cls)
        lbl:SetTextColor(r, g, b)
        lbl:SetText(CLASS_DISPLAY[cls])

        cb:SetChecked(HealAssignDB.options.tankClasses[cls] or false)
        local capturedCls = cls
        cb:SetScript("OnClick", function()
            HealAssignDB.options.tankClasses[capturedCls] = this:GetChecked()
        end)
    end

    -- Section: Death Notification Channel
    local sec2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sec2:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -182)
    sec2:SetTextColor(1, 0.8, 0.2)
    sec2:SetText("Death Notification Channel:")

    local chanEdit = CreateFrame("EditBox", "HealAssignChanEdit", f, "InputBoxTemplate")
    chanEdit:SetWidth(50)
    chanEdit:SetHeight(20)
    chanEdit:SetPoint("LEFT", sec2, "RIGHT", 8, 0)
    chanEdit:SetAutoFocus(false)
    chanEdit:SetMaxLetters(3)
    chanEdit:SetNumeric(true)
    chanEdit:SetText(tostring(HealAssignDB.options.chatChannel or 1))
    chanEdit:SetScript("OnEnterPressed", function()
        this:ClearFocus()
        local val = tonumber(this:GetText())
        if val then HealAssignDB.options.chatChannel = val end
    end)
    chanEdit:SetScript("OnEditFocusLost", function()
        local val = tonumber(this:GetText())
        if val then HealAssignDB.options.chatChannel = val end
    end)
    f.chanEdit = chanEdit

    local chanNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanNote:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -205)
    chanNote:SetTextColor(0.55, 0.55, 0.55)
    chanNote:SetText("Set to 0 to disable. Posts: 'PlayerName (tank/healer) dead - assigned: ...'")

    -- Section: Custom Targets
    local sec3 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sec3:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -222)
    sec3:SetTextColor(1, 0.8, 0.2)
    sec3:SetText("Custom Assignment Targets:")

    local customNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customNote:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -238)
    customNote:SetTextColor(0.55, 0.55, 0.55)
    customNote:SetText("e.g. 'Main Tank', 'OT Mark', 'Skull Target'")

    local customEdit = CreateFrame("EditBox", "HealAssignCustomEdit", f, "InputBoxTemplate")
    customEdit:SetWidth(210)
    customEdit:SetHeight(20)
    customEdit:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -255)
    customEdit:SetAutoFocus(false)
    customEdit:SetMaxLetters(64)
    customEdit:SetText("")

    local addCustomBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    addCustomBtn:SetWidth(60)
    addCustomBtn:SetHeight(20)
    addCustomBtn:SetPoint("LEFT", customEdit, "RIGHT", 5, 0)
    addCustomBtn:SetText("Add")

-- Custom targets list
    local customListFrame = CreateFrame("Frame", nil, f)
    -- Back to original -280 vertical offset
    customListFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -280)
    customListFrame:SetWidth(330)
    customListFrame:SetHeight(110)
    customListFrame.rows = {}
    f.customListFrame = customListFrame

    local function RefreshCustomList()
        -- Safely hide old rows
        for _, r in ipairs(customListFrame.rows) do r:Hide() end
        customListFrame.rows = {}

        local targets = HealAssignDB.options.customTargets
        for i = 1, table.getn(targets) do
            local ct = targets[i]
            local row = CreateFrame("Frame", nil, customListFrame)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT", customListFrame, "TOPLEFT", 0, -(i-1)*18)
            row:SetWidth(330)
            table.insert(customListFrame.rows, row)

            local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            lbl:SetPoint("LEFT", row, "LEFT", 2, 0)
            lbl:SetTextColor(0.85, 0.85, 0.85)
            lbl:SetText(ct)

            local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            delBtn:SetWidth(22)
            delBtn:SetHeight(16)
            delBtn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
            delBtn:SetText("X")
            
            -- Keep the working deletion fix with local index
            local indexToRemove = i
            delBtn:SetScript("OnClick", function()
                table.remove(HealAssignDB.options.customTargets, indexToRemove)
                RefreshCustomList()
            end)
        end
    end
    f.RefreshCustomList = RefreshCustomList

    addCustomBtn:SetScript("OnClick", function()
        local txt = customEdit:GetText()
        if txt and txt ~= "" then
            table.insert(HealAssignDB.options.customTargets, txt)
            customEdit:SetText("")
            RefreshCustomList()
        end
    end)

    -- Show Assign Frame toggle
    local showAssignCB = CreateFrame("CheckButton", "HealAssignShowAssignCB", f, "UICheckButtonTemplate")
    showAssignCB:SetWidth(20)
    showAssignCB:SetHeight(20)
    showAssignCB:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -398)
    showAssignCB:SetChecked(HealAssignDB.options.showAssignFrame)
    showAssignCB:SetScript("OnClick", function()
        HealAssignDB.options.showAssignFrame = this:GetChecked()
        if HealAssignDB.options.showAssignFrame then
            if assignFrame then
                assignFrame:Show()
                UpdateAssignFrame()
            end
        else
            if assignFrame then assignFrame:Hide() end
        end
    end)
    local showAssignLbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    showAssignLbl:SetPoint("LEFT", showAssignCB, "RIGHT", 2, 0)
    showAssignLbl:SetText("Show My Assignments Frame")

    optionsFrame = f
    RefreshCustomList()
    f:Show()
end

-------------------------------------------------------------------------------
-- SYNC / COMMUNICATION
-------------------------------------------------------------------------------
-- Incoming message buffer for chunked messages
local incomingChunks = {}

function HealAssign_SyncTemplate()
    local tmpl = GetActiveTemplate()
    if not tmpl then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r No active template to sync.")
        return
    end
    local data = Serialize(tmpl)
    if not data then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Failed to serialize template.")
        return
    end

    local channel = "RAID"
    if GetNumRaidMembers() == 0 then
        channel = "PARTY"
        if GetNumPartyMembers() == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Not in a group. Sync only works in party/raid.")
            return
        end
    end

    -- WoW 1.12 SendAddonMessage limit is 255 chars
    local CHUNK_SIZE = 200
    local totalLen = string.len(data)
    local numChunks = math.floor((totalLen + CHUNK_SIZE - 1) / CHUNK_SIZE)
    if numChunks < 1 then numChunks = 1 end

    for i = 1, numChunks do
        local chunk = string.sub(data, (i-1)*CHUNK_SIZE + 1, i*CHUNK_SIZE)
        local msg = "SYNC:"..i..":"..numChunks..":"..chunk
        SendAddonMessage(COMM_PREFIX, msg, channel)
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..tmpl.name.."' synced to "..channel.." ("..numChunks.." packet(s)).")
    UpdateAssignFrame()
end

local function HandleAddonMessage(prefix, msg, channel, sender)
    if prefix ~= COMM_PREFIX then return end
    local myName = UnitName("player")
    if sender == myName then return end

    -- SYNC:chunkIdx:totalChunks:data
    -- In Lua 5.0 (WoW 1.12), string.find returns: startPos, endPos, cap1, cap2, ...
    local s, e, ci, tc, d = string.find(msg, "^SYNC:(%d+):(%d+):(.+)$")
    if not s then return end
    local chunkIdx = tonumber(ci)
    local totalChunks = tonumber(tc)
    local data = d

    if not incomingChunks[sender] then
        incomingChunks[sender] = {total=totalChunks, chunks={}}
    end
    -- Reset if new sync started
    if incomingChunks[sender].total ~= totalChunks then
        incomingChunks[sender] = {total=totalChunks, chunks={}}
    end
    incomingChunks[sender].chunks[chunkIdx] = data

    -- Check if all chunks received
    local allReceived = true
    for i = 1, incomingChunks[sender].total do
        if not incomingChunks[sender].chunks[i] then
            allReceived = false
            break
        end
    end

    if allReceived then
        local fullData = ""
        for i = 1, incomingChunks[sender].total do
            fullData = fullData .. incomingChunks[sender].chunks[i]
        end
        incomingChunks[sender] = nil

        local tmpl = Deserialize(fullData)
        if tmpl then
            HealAssignDB.templates[tmpl.name] = tmpl
            HealAssignDB.activeTemplate = tmpl.name
            currentTemplate = tmpl
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Received template '"..tmpl.name.."' from "..sender..".")
            if mainFrame and mainFrame:IsShown() then
                mainFrame.nameEdit:SetText(tmpl.name)
                RebuildMainRows()
            end
            UpdateAssignFrame()
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Failed to parse template from "..sender..".")
        end
    end
end

-------------------------------------------------------------------------------
-- DEATH NOTIFICATIONS
-------------------------------------------------------------------------------
local deathFrame = CreateFrame("Frame", "HealAssignDeathFrame")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")

deathFrame:SetScript("OnEvent", function()
    local msg = arg1
    if not msg then return end

    local channel = HealAssignDB and HealAssignDB.options and HealAssignDB.options.chatChannel
    if not channel or channel == 0 then return end

    local tmpl = GetActiveTemplate()
    if not tmpl then return end

    -- Extract dead player name
    -- WoW 1.12 messages: "PlayerName dies." or "You die."
    local deadName = nil
    if msg == "You die." then
        deadName = UnitName("player")
    else
        -- Lua 5.0: string.find returns startPos, endPos, cap1, ...
        local s, e, cap = string.find(msg, "^(.+) dies%.$")
        if s then deadName = cap end
    end

    if not deadName then return end

    -- Check if it's a tank in our template
    for _, target in ipairs(tmpl.targets) do
        if target.type == "tank" and target.value == deadName then
            local healerList = ""
            if table.getn(target.healers) > 0 then
                healerList = table.concat(target.healers, ", ")
            else
                healerList = "none"
            end
            local notification = deadName.." (tank) dead - assigned healer(s): "..healerList
            SendChatMessage(notification, "CHANNEL", nil, channel)
            return
        end
    end

    -- Check if it's an assigned healer
    for _, target in ipairs(tmpl.targets) do
        for _, healer in ipairs(target.healers) do
            if healer == deadName then
                local notification = deadName.." (healer) dead - was assigned to: "..target.value
                SendChatMessage(notification, "CHANNEL", nil, channel)
                return
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- MAIN EVENT HANDLER
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "HealAssignEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")

eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()
            if HealAssignDB.activeTemplate and HealAssignDB.templates[HealAssignDB.activeTemplate] then
                currentTemplate = HealAssignDB.templates[HealAssignDB.activeTemplate]
            end
            CreateAssignFrame()
            CreateOptionsFrame()
            optionsFrame:Hide()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.." loaded. Type |cffffffff/ha|r or |cffffffff/healassign|r to open.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(arg1, arg2, arg3, arg4)

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        if mainFrame and mainFrame:IsShown() then
            RebuildMainRows()
        end
        UpdateAssignFrame()
    end
end)

-------------------------------------------------------------------------------
-- SLASH COMMANDS
-------------------------------------------------------------------------------
SLASH_HEALASSIGN1 = "/healassign"
SLASH_HEALASSIGN2 = "/ha"

SlashCmdList["HEALASSIGN"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "sync" then
        HealAssign_SyncTemplate()

    elseif msg == "options" or msg == "opt" then
        if optionsFrame then
            if optionsFrame:IsShown() then
                optionsFrame:Hide()
            else
                optionsFrame:Show()
            end
        end

    elseif msg == "assign" then
        if assignFrame then
            if assignFrame:IsShown() then
                assignFrame:Hide()
            else
                assignFrame:Show()
                UpdateAssignFrame()
            end
        end

    elseif msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.." commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha|r - Toggle main window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha sync|r - Sync active template to raid/party")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha options|r - Open options")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha assign|r - Toggle my assignments display")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha help|r - Show this help")

    else
        -- Toggle main frame
        if mainFrame then
            if mainFrame:IsShown() then
                mainFrame:Hide()
                CloseDropdown()
            else
                mainFrame:Show()
                if currentTemplate then
                    mainFrame.nameEdit:SetText(currentTemplate.name)
                    RebuildMainRows()
                end
            end
        else
            CreateMainFrame()
            if currentTemplate then
                mainFrame.nameEdit:SetText(currentTemplate.name)
                RebuildMainRows()
            end
        end
    end
end
