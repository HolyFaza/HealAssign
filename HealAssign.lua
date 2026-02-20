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
-- UTILITY: DEEP COPY (global, no 'local', so StaticPopupDialogs can call it)
-------------------------------------------------------------------------------
function DeepCopy(orig)
    local t = type(orig)
    local copy
    if t == 'table' then
        copy = {}
        for k, v in pairs(orig) do
            copy[DeepCopy(k)] = DeepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

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
    -- Ensure the global exists
    if not HealAssignDB then HealAssignDB = {} end
    if not HealAssignDB.templates then HealAssignDB.templates = {} end
    if not HealAssignDB.activeTemplate then HealAssignDB.activeTemplate = nil end
    
    -- Default Options
    if not HealAssignDB.options then
        HealAssignDB.options = {
            tankClasses = {
                ["WARRIOR"] = true,
                ["DRUID"]   = true,
                ["SHAMAN"] = true,
            },
            customTargets = {},
            chatChannel = 1,
            showAssignFrame = true,
            fontSize = 12,
        }
    end

    -- Safety checks
    if not HealAssignDB.options.customTargets then HealAssignDB.options.customTargets = {} end
    if not HealAssignDB.options.chatChannel then HealAssignDB.options.chatChannel = 1 end
    if HealAssignDB.options.showAssignFrame == nil then HealAssignDB.options.showAssignFrame = true end
    if not HealAssignDB.options.fontSize then HealAssignDB.options.fontSize = 12 end
    if not HealAssignDB.options.tankClasses then
        HealAssignDB.options.tankClasses = {
            ["WARRIOR"] = true,
            ["DRUID"]   = true,
            ["SHAMAN"] = true,
        }
    end

    -- Dialog 1: Confirm Delete
    StaticPopupDialogs["HEALASSIGN_CONFIRM_DELETE"] = {
        text = "Are you sure you want to delete template '%s'?",
        button1 = "Yes",
        button2 = "No",
        OnAccept = function()
            local name = HealAssignNameEdit:GetText()
            if name and HealAssignDB.templates[name] then
                HealAssignDB.templates[name] = nil
                HealAssignDB.activeTemplate = nil
                currentTemplate = { name = "", targets = {} }
                HealAssignNameEdit:SetText("")
                RebuildMainRows()
                UpdateAssignFrame()
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..name.."' deleted.")
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }

    -- Dialog 2: Save before New
    StaticPopupDialogs["HEALASSIGN_SAVE_BEFORE_NEW"] = {
        text = "Current template has unsaved changes. Save before creating a new one?",
        button1 = "Save",
        button2 = "Cancel",
        OnAccept = function()
            local name = HealAssignNameEdit:GetText()
            -- If name field is empty, warn and do NOT proceed
            if not name or name == "" then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Please enter a template name before saving.")
                return
            end
            -- Save current template (same logic as the SAVE button in row 1)
            if not currentTemplate then currentTemplate = { name = name, targets = {} } end
            currentTemplate.name = name
            HealAssignDB.templates[name] = DeepCopy(currentTemplate)
            HealAssignDB.activeTemplate = name
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..name.."' saved.")
            -- Now clear everything for the new blank template
            currentTemplate = { name = "", targets = {} }
            HealAssignDB.activeTemplate = nil
            HealAssignNameEdit:SetText("")
            RebuildMainRows()
            UpdateAssignFrame()
        end,
        OnCancel = function()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
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

currentTemplate = nil       -- global: must be accessible from StaticPopupDialogs
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

-- Global variables for dropdown control
local lastDropdownCloseTime = 0
local activeDropdownAnchor = nil

local function CloseDropdown()
    if dropdownFrame and dropdownFrame:IsShown() then
        dropdownFrame:Hide()
        if dropdownLocker then dropdownLocker:Hide() end
        lastDropdownCloseTime = GetTime()
        activeDropdownAnchor = nil
    end
end

local function ShowDropdown(anchorFrame, items, onSelect, width)
    -- Toggle logic: if clicking the same button that opened it, just close and exit
    if dropdownFrame and dropdownFrame:IsShown() and activeDropdownAnchor == anchorFrame then
        CloseDropdown()
        return
    end

    -- If another dropdown is open, close it first
    CloseDropdown()

    -- Create locker to detect clicks outside
    if not dropdownLocker then
        dropdownLocker = CreateFrame("Button", "HealAssignDropdownLocker", UIParent)
        dropdownLocker:SetAllPoints(UIParent)
        dropdownLocker:SetFrameStrata("BACKGROUND")
        dropdownLocker:SetScript("OnClick", function()
            CloseDropdown()
        end)
    end

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
    activeDropdownAnchor = anchorFrame
    dropdownLocker:Show()

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
function UpdateAssignFrame()
    if not assignFrame then return end
    if not assignFrame:IsShown() then return end

    local myName = UnitName("player")
    local content = assignFrame.content

    -- Set the font size from options dynamically
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    content:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")

    local tmpl = GetActiveTemplate()
    if not tmpl then
        content:SetText("|cff888888No active template.|r")
        assignFrame:SetHeight(50)
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

    -- Calculate height based on actual font size and number of lines
    local numLines = table.getn(lines)
    local lineSpacing = fontSize + 4
    local newH = 20 + (numLines * lineSpacing) + 10
    
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
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -20) -- Slightly lower to clear title
    content:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -20)
    content:SetJustifyH("LEFT")
    content:SetJustifyV("TOP")
    
    -- Apply the font size immediately on creation
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    content:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
    content:SetText("|cff888888Waiting for sync...|r")
    
    f.content = content
    assignFrame = f

    if HealAssignDB.options and HealAssignDB.options.showAssignFrame then
        f:Show()
        UpdateAssignFrame() -- Initial update
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

function RebuildMainRows()
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
                        --SaveCurrentTemplate()
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
            --SaveCurrentTemplate()
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
                    --SaveCurrentTemplate()
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
        ReleaseEditorLock()
        f:Hide()
        CloseDropdown()
    end)
    -- Also release lock if frame is hidden by any other means
    f:SetScript("OnHide", function()
        ReleaseEditorLock()
        CloseDropdown()
    end)

-------------------------------------------------------------------------------
-- ROW 1: NEW / LOAD / SAVE / RESET / DELETE
-------------------------------------------------------------------------------

-- (DeepCopy is defined at the top of the file in global scope)

-- Helper to check if current workspace differs from the saved database entry
local function IsCurrentTemplateDirty()
    if not currentTemplate or table.getn(currentTemplate.targets) == 0 then 
        return false 
    end
    
    local name = f.nameEdit:GetText()
    local saved = HealAssignDB.templates[name]
    
    if not saved then return true end
    
    if table.getn(currentTemplate.targets) ~= table.getn(saved.targets) then
        return true
    end
    
    for i, target in ipairs(currentTemplate.targets) do
        local sTarget = saved.targets[i]
        if not sTarget or target.value ~= sTarget.value or target.type ~= sTarget.type then 
            return true 
        end
        
        if table.getn(target.healers) ~= table.getn(sTarget.healers) then 
            return true 
        end
        
        for j, healer in ipairs(target.healers) do
            if healer ~= sTarget.healers[j] then return true end
        end
    end
    
    return false
end

-- Helper for tooltips
local function AddTooltip(frame, text)
    frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
nameLabel:SetPoint("TOP", f, "TOP", -155, -42) 
nameLabel:SetText("Template:")

local nameEdit = CreateFrame("EditBox", "HealAssignNameEdit", f, "InputBoxTemplate")
nameEdit:SetWidth(80)
nameEdit:SetHeight(20)
nameEdit:SetPoint("LEFT", nameLabel, "RIGHT", 5, 0)
nameEdit:SetAutoFocus(false)
nameEdit:SetMaxLetters(64)
f.nameEdit = nameEdit

-- 1. NEW (Updated with IsCurrentTemplateDirty check)
local newBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
newBtn:SetWidth(36)
newBtn:SetHeight(20)
newBtn:SetPoint("LEFT", nameEdit, "RIGHT", 5, 0)
newBtn:SetText("New")
AddTooltip(newBtn, "Clear workspace and name to start a fresh template.")
newBtn:SetScript("OnClick", function()
    if IsCurrentTemplateDirty() then
        StaticPopup_Show("HEALASSIGN_SAVE_BEFORE_NEW")
    else
        currentTemplate = { name = "", targets = {} }
        HealAssignDB.activeTemplate = nil
        f.nameEdit:SetText("")
        if type(RebuildMainRows) == "function" then RebuildMainRows() end
        if type(UpdateAssignFrame) == "function" then UpdateAssignFrame() end
    end
end)

-- 2. LOAD
local loadBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
loadBtn:SetWidth(40)
loadBtn:SetHeight(20)
loadBtn:SetPoint("LEFT", newBtn, "RIGHT", 3, 0)
loadBtn:SetText("Load")
AddTooltip(loadBtn, "Load an existing template. Click again to close menu.")
loadBtn:SetScript("OnClick", function()
    local items = {}
    for tname, _ in pairs(HealAssignDB.templates) do
        table.insert(items, {text=tname, name=tname, r=1,g=0.9,b=0.5})
    end
    table.sort(items, function(a,b) return a.text < b.text end)
    
    if table.getn(items) == 0 then
        table.insert(items, {text="(No templates)", name=nil, r=0.5,g=0.5,b=0.5})
    end
    
    ShowDropdown(loadBtn, items, function(item)
        if item.name then
            currentTemplate = DeepCopy(HealAssignDB.templates[item.name])
            HealAssignDB.activeTemplate = item.name
            f.nameEdit:SetText(currentTemplate.name)
            if type(RebuildMainRows) == "function" then RebuildMainRows() end
            if type(UpdateAssignFrame) == "function" then UpdateAssignFrame() end
        end
    end, 180)
end)

-- 3. SAVE
local saveBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
saveBtn:SetWidth(40)
saveBtn:SetHeight(20)
saveBtn:SetPoint("LEFT", loadBtn, "RIGHT", 3, 0)
saveBtn:SetText("Save")
AddTooltip(saveBtn, "Save current assignments to the database.")
saveBtn:SetScript("OnClick", function()
    local name = f.nameEdit:GetText()
    if not name or name == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Enter a name first.")
        return
    end
    if not currentTemplate then currentTemplate = { name = name, targets = {} } end
    currentTemplate.name = name
    HealAssignDB.templates[name] = DeepCopy(currentTemplate)
    HealAssignDB.activeTemplate = name
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r '"..name.."' saved.")
    if type(RebuildMainRows) == "function" then RebuildMainRows() end
end)

-- 4. RESET
local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
resetBtn:SetWidth(42)
resetBtn:SetHeight(20)
resetBtn:SetPoint("LEFT", saveBtn, "RIGHT", 3, 0)
resetBtn:SetText("Reset")
AddTooltip(resetBtn, "Clear all assignments but keep the template name.")
resetBtn:SetScript("OnClick", function()
    if currentTemplate then
        currentTemplate.targets = {}
        if type(RebuildMainRows) == "function" then RebuildMainRows() end
        if type(UpdateAssignFrame) == "function" then UpdateAssignFrame() end
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Assignments reset.")
    end
end)

-- 5. DELETE
local delBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
delBtn:SetWidth(32)
delBtn:SetHeight(20)
delBtn:SetPoint("LEFT", resetBtn, "RIGHT", 3, 0)
delBtn:SetText("Del")
AddTooltip(delBtn, "Permanently delete this template.")
delBtn:SetScript("OnClick", function()
    local name = f.nameEdit:GetText()
    if name and name ~= "" and HealAssignDB.templates[name] then
        StaticPopup_Show("HEALASSIGN_CONFIRM_DELETE", name)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Invalid template.")
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
                -- SaveCurrentTemplate() removed to prevent silent auto-save
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
            -- SaveCurrentTemplate() removed to prevent silent auto-save
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
                -- SaveCurrentTemplate() removed to prevent silent auto-save
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
-- OPTIONS FRAME (Updated with fixed font slider and spacing)
-------------------------------------------------------------------------------
local function CreateOptionsFrame()
    if optionsFrame then
        optionsFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "HealAssignOptionsFrame", UIParent)
    f:SetWidth(370)
    f:SetHeight(560) 
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

    local chanNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chanNote:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -205)
    chanNote:SetTextColor(0.55, 0.55, 0.55)
    chanNote:SetText("Set to 0 to disable. Posts: 'PlayerName (tank/healer) dead'")

    -- Section: Font Size
    local secFont = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    secFont:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -230) -- Adjusted position
    secFont:SetTextColor(1, 0.8, 0.2)
    secFont:SetText("Assignments Font Size:")

    local fontSlider = CreateFrame("Slider", "HealAssignFontSlider", f, "OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -260) -- Added more space below title
    fontSlider:SetWidth(200)
    fontSlider:SetHeight(16)
    fontSlider:SetMinMaxValues(8, 24)
    fontSlider:SetValueStep(1)
    fontSlider:SetValue(HealAssignDB.options.fontSize or 12)

    getglobal(fontSlider:GetName().."Text"):SetText("Size: " .. (HealAssignDB.options.fontSize or 12))
    getglobal(fontSlider:GetName().."Low"):SetText("8")
    getglobal(fontSlider:GetName().."High"):SetText("24")

    fontSlider:SetScript("OnValueChanged", function()
        local val = math.floor(this:GetValue())
        HealAssignDB.options.fontSize = val
        getglobal(this:GetName().."Text"):SetText("Size: " .. val)
        -- Trigger immediate update of the assignments display
        if UpdateAssignFrame then UpdateAssignFrame() end
    end)

    -- Section: Custom Targets
    local sec3 = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sec3:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -300) -- Shifted down
    sec3:SetTextColor(1, 0.8, 0.2)
    sec3:SetText("Custom Assignment Targets:")

    local customNote = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    customNote:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -317)
    customNote:SetTextColor(0.55, 0.55, 0.55)
    customNote:SetText("e.g. 'Main Tank', 'OT Mark', 'Skull Target'")

    local customEdit = CreateFrame("EditBox", "HealAssignCustomEdit", f, "InputBoxTemplate")
    customEdit:SetWidth(210)
    customEdit:SetHeight(20)
    customEdit:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -335)
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
    customListFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -360)
    customListFrame:SetWidth(330)
    customListFrame:SetHeight(120)
    customListFrame.rows = {}
    f.customListFrame = customListFrame

    local function RefreshCustomList()
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
            
            local idx = i
            delBtn:SetScript("OnClick", function()
                table.remove(HealAssignDB.options.customTargets, idx)
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
    showAssignCB:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -520)
    showAssignCB:SetChecked(HealAssignDB.options.showAssignFrame)
    showAssignCB:SetScript("OnClick", function()
        HealAssignDB.options.showAssignFrame = this:GetChecked()
        if HealAssignDB.options.showAssignFrame then
            if assignFrame then assignFrame:Show(); UpdateAssignFrame() end
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
local incomingChunks = {}

-------------------------------------------------------------------------------
-- EDITOR LOCK SYSTEM
-- Only one raid leader/officer may have the main frame open at a time.
-- Protocol (addon messages):
--   "LOCK;name"    -- "name" has taken the editor lock (broadcast on open)
--   "UNLOCK;name"  -- "name" released the lock (broadcast on close)
--   "LOCKQUERY"    -- someone is asking who holds the lock
--   "LOCKACK;name" -- reply: "name" currently holds the lock
-------------------------------------------------------------------------------
local editorLockHolder = nil   -- name of player who currently holds the lock (nil = free)

-- Returns true only if the local player is Raid Leader or Raid Assistant.
-- No raid = no rights. Party leader alone is not sufficient.
function HasEditorRights()
    local numRaid = GetNumRaidMembers()
    if not numRaid or numRaid == 0 then
        return false  -- must be in a raid
    end
    local myName = UnitName("player")
    for i = 1, numRaid do
        local name, rank = GetRaidRosterInfo(i)
        -- rank: 0 = member, 1 = assistant, 2 = leader
        if name == myName and rank >= 1 then
            return true
        end
    end
    return false
end

-- Send a lock message to the group
function SendLockMessage(msgType, playerName)
    local numRaid = GetNumRaidMembers()
    local channel
    if numRaid and numRaid > 0 then
        channel = "RAID"
    elseif GetNumPartyMembers() and GetNumPartyMembers() > 0 then
        channel = "PARTY"
    else
        return  -- solo, no need to broadcast
    end
    local payload = playerName and (msgType..";"..playerName) or msgType
    SendAddonMessage(COMM_PREFIX, payload, channel)
end

-- Try to acquire the editor lock. Returns true on success, false if blocked.
function AcquireEditorLock()
    local myName = UnitName("player")
    if not HasEditorRights() then
        local numRaid = GetNumRaidMembers()
        if not numRaid or numRaid == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r You must be in a raid to edit assignments.")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Only Raid Leader or Assistant can edit assignments.")
        end
        return false
    end
    if editorLockHolder and editorLockHolder ~= myName then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Editor is currently open by |cffffd700"..editorLockHolder.."|r.")
        return false
    end
    editorLockHolder = myName
    SendLockMessage("LOCK", myName)
    return true
end

-- Release the editor lock (call on close)
function ReleaseEditorLock()
    local myName = UnitName("player")
    if editorLockHolder == myName then
        editorLockHolder = nil
        SendLockMessage("UNLOCK", myName)
    end
end

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

    -- Escape characters that cause "Invalid escape code" in WoW 1.12.1
    data = string.gsub(data, "%%", "{perc}")
    data = string.gsub(data, "\\", "{bs}")
    data = string.gsub(data, "|", "{pipe}")

    local channel = "RAID"
    if GetNumRaidMembers() == 0 then
        channel = "PARTY"
        if GetNumPartyMembers() == 0 then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Not in a group.")
            return
        end
    end

    local CHUNK_SIZE = 150 
    local totalLen = string.len(data)
    local numChunks = math.ceil(totalLen / CHUNK_SIZE)
    if numChunks < 1 then numChunks = 1 end

    for i = 1, numChunks do
        local startPos = (i-1) * CHUNK_SIZE + 1
        local endPos = i * CHUNK_SIZE
        local chunk = string.sub(data, startPos, endPos)
        
        -- Using semicolon separator to avoid chat parser confusion
        local msg = "S;"..i..";"..numChunks..";"..chunk
        SendAddonMessage(COMM_PREFIX, msg, channel)
    end

    -- Update own frame immediately after syncing
    UpdateAssignFrame()
    
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..tmpl.name.."' synced.")
end

local function HandleAddonMessage(prefix, msg, channel, sender)
    if prefix ~= COMM_PREFIX then return end
    if sender == UnitName("player") then return end

    -- Handle editor lock protocol messages first
    -- Note: string.match does not exist in Lua 5.0 (WoW 1.12), use string.find instead
    local _, _, lockName = string.find(msg, "^LOCK;(.+)$")
    if lockName then
        editorLockHolder = lockName
        -- If we have the main frame open and someone else grabbed the lock, force-close it
        if mainFrame and mainFrame:IsShown() and lockName ~= UnitName("player") then
            mainFrame:Hide()
            CloseDropdown()
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Editor taken by |cffffd700"..lockName.."|r. Your window was closed.")
        end
        return
    end

    local _, _, unlockName = string.find(msg, "^UNLOCK;(.+)$")
    if unlockName then
        if editorLockHolder == unlockName then
            editorLockHolder = nil
            -- Only notify players who actually have rights to open the editor
            if HasEditorRights() then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r |cffffd700"..unlockName.."|r closed the editor. You may now open it.")
            end
        end
        return
    end

    if msg == "LOCKQUERY" then
        -- Someone is asking who holds the lock; if we hold it, reply
        local myName = UnitName("player")
        if editorLockHolder == myName then
            SendLockMessage("LOCKACK", myName)
        end
        return
    end

    local _, _, ackName = string.find(msg, "^LOCKACK;(.+)$")
    if ackName then
        editorLockHolder = ackName
        return
    end

    -- Parse S;index;total;data format
    local _, _, cIdx, tChunks, d = string.find(msg, "^S;(%d+);(%d+);(.+)$")
    if not cIdx then return end
    
    local chunkIdx = tonumber(cIdx)
    local totalChunks = tonumber(tChunks)
    local data = d

    if not incomingChunks[sender] or incomingChunks[sender].total ~= totalChunks then
        incomingChunks[sender] = {total = totalChunks, chunks = {}}
    end
    
    incomingChunks[sender].chunks[chunkIdx] = data

    -- Check if all chunks received
    local allReceived = true
    for i = 1, totalChunks do
        if not incomingChunks[sender].chunks[i] then
            allReceived = false
            break
        end
    end

    if allReceived then
        local fullData = ""
        for i = 1, totalChunks do
            fullData = fullData .. incomingChunks[sender].chunks[i]
        end
        incomingChunks[sender] = nil

        -- Restore escaped characters
        fullData = string.gsub(fullData, "{perc}", "%%")
        fullData = string.gsub(fullData, "{bs}", "\\")
        fullData = string.gsub(fullData, "{pipe}", "|")

        local tmpl = Deserialize(fullData)
        if tmpl then
            HealAssignDB.templates[tmpl.name] = tmpl
            HealAssignDB.activeTemplate = tmpl.name
            currentTemplate = tmpl
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Received '"..tmpl.name.."' from "..sender)
            if mainFrame and mainFrame:IsShown() then RebuildMainRows() end
            UpdateAssignFrame()
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

    -- Extract dead player name (WoW 1.12.1 pattern)
    local deadName = nil
    if msg == "You die." then
        deadName = UnitName("player")
    else
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
                ReleaseEditorLock()
                mainFrame:Hide()
                CloseDropdown()
            else
                if not AcquireEditorLock() then return end
                -- Query in case another client holds a stale lock we don't know about yet
                SendLockMessage("LOCKQUERY", nil)
                mainFrame:Show()
                if currentTemplate then
                    mainFrame.nameEdit:SetText(currentTemplate.name)
                    RebuildMainRows()
                end
            end
        else
            if not AcquireEditorLock() then return end
            SendLockMessage("LOCKQUERY", nil)
            CreateMainFrame()
            if currentTemplate then
                mainFrame.nameEdit:SetText(currentTemplate.name)
                RebuildMainRows()
            end
        end
    end
end

