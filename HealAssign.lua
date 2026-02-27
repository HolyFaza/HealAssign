-- HealAssign.lua v2.0
-- WoW 1.12.1 Heal Assignment Addon
-- Healer-centric assignment system

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------
local ADDON_NAME    = "HealAssign"
local ADDON_VERSION = "2.0.3"
local COMM_PREFIX   = "HealAssign"

local CLASS_COLORS = {
    ["WARRIOR"] = {r=0.78,g=0.61,b=0.43},
    ["PALADIN"] = {r=0.96,g=0.55,b=0.73},
    ["HUNTER"]  = {r=0.67,g=0.83,b=0.45},
    ["ROGUE"]   = {r=1.00,g=0.96,b=0.41},
    ["PRIEST"]  = {r=1.00,g=1.00,b=1.00},
    ["SHAMAN"]  = {r=0.00,g=0.44,b=0.87},
    ["MAGE"]    = {r=0.41,g=0.80,b=0.94},
    ["WARLOCK"] = {r=0.58,g=0.51,b=0.79},
    ["DRUID"]   = {r=1.00,g=0.49,b=0.04},
}

local CLASS_NAMES = {
    "WARRIOR","PALADIN","HUNTER","ROGUE","PRIEST",
    "SHAMAN","MAGE","WARLOCK","DRUID"
}

local CLASS_DISPLAY = {
    ["WARRIOR"]="Warrior",["PALADIN"]="Paladin",["HUNTER"]="Hunter",
    ["ROGUE"]="Rogue",["PRIEST"]="Priest",["SHAMAN"]="Shaman",
    ["MAGE"]="Mage",["WARLOCK"]="Warlock",["DRUID"]="Druid",
}

local TYPE_TANK   = "tank"

-- Stack for tracking open windows (ESC closes in reverse order)
local openStack = {}
local TYPE_GROUP  = "group"
local TYPE_CUSTOM = "custom"

-------------------------------------------------------------------------------
-- DEEP COPY
-------------------------------------------------------------------------------
function DeepCopy(orig)
    local t = type(orig)
    if t ~= "table" then return orig end
    local copy = {}
    for k,v in pairs(orig) do copy[DeepCopy(k)] = DeepCopy(v) end
    return copy
end

-------------------------------------------------------------------------------
-- DATABASE INIT
-------------------------------------------------------------------------------
local function InitDB()
    if not HealAssignDB then HealAssignDB = {} end
    if not HealAssignDB.templates then HealAssignDB.templates = {} end
    if not HealAssignDB.activeTemplate then HealAssignDB.activeTemplate = nil end
    if not HealAssignDB.options then
        HealAssignDB.options = {
            fontSize        = 12,
            showAssignFrame = false,
            windowAlpha     = 0.95,
            customTargets   = {},
        }
    end
    if not HealAssignDB.options.customTargets  then HealAssignDB.options.customTargets = {} end
    if not HealAssignDB.options.fontSize       then HealAssignDB.options.fontSize = 12 end
    if HealAssignDB.options.showAssignFrame == nil then HealAssignDB.options.showAssignFrame = false end
    if HealAssignDB.options.windowAlpha == nil then HealAssignDB.options.windowAlpha = 0.95 end
    if not HealAssignDB.innCD then HealAssignDB.innCD = {} end
end

local function NewTemplate(name)
    return { name=name or "", roster={}, healers={}, innervate={} }
end

-------------------------------------------------------------------------------
-- TOOLTIP HELPER
-------------------------------------------------------------------------------
local function AddTooltip(frame, text)
    frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-------------------------------------------------------------------------------
-- DIRTY CHECK (unsaved changes)
-------------------------------------------------------------------------------
local function IsCurrentTemplateDirty()
    if not currentTemplate then return false end
    -- No healers = nothing to lose
    if table.getn(currentTemplate.healers or {}) == 0 then return false end
    local name = currentTemplate.name or ""
    -- No name = definitely unsaved
    if name == "" then return true end
    local saved = HealAssignDB.templates[name]
    if not saved then return true end
    -- Compare healer count
    if table.getn(currentTemplate.healers) ~= table.getn(saved.healers or {}) then return true end
    -- Compare targets per healer
    for i,h in ipairs(currentTemplate.healers) do
        local sh = saved.healers[i]
        if not sh then return true end
        if table.getn(h.targets or {}) ~= table.getn(sh.targets or {}) then return true end
    end
    return false
end

-------------------------------------------------------------------------------
-- STATIC POPUP DIALOGS
-------------------------------------------------------------------------------
-- nameEdit reference stored here after CreateMainFrame runs
local _nameEditRef = nil
-- Forward-declared references set after the real functions are defined
local _RebuildMainGrid       = nil
local _UpdateAssignFrame     = nil
local _SyncHealersFromRoster = nil
local _RebuildRosterRows     = nil

local function _DoNewTemplate()
    local newTmpl = NewTemplate("")
    if currentTemplate and currentTemplate.roster then
        for pname,pdata in pairs(currentTemplate.roster) do
            newTmpl.roster[pname] = {class=pdata.class, tagT=pdata.tagT, tagH=pdata.tagH, tagV=pdata.tagV}
        end
        if _SyncHealersFromRoster then _SyncHealersFromRoster(newTmpl) end
    end
    currentTemplate = newTmpl
    HealAssignDB.activeTemplate = nil
    if _nameEditRef then _nameEditRef:SetText("") end
    if _RebuildMainGrid   then _RebuildMainGrid() end
    if _UpdateAssignFrame then _UpdateAssignFrame() end
    if _UpdateDruidAssignFrame then _UpdateDruidAssignFrame() end
end

local function InitStaticPopups()
    StaticPopupDialogs["HEALASSIGN_CONFIRM_DELETE"] = {
        text = "Delete template '%s'? This cannot be undone.",
        button1 = "Delete",
        button2 = "Cancel",
        OnAccept = function()
            local name = _nameEditRef and _nameEditRef:GetText() or ""
            if name ~= "" and HealAssignDB.templates[name] then
                HealAssignDB.templates[name] = nil
                if HealAssignDB.activeTemplate == name then
                    HealAssignDB.activeTemplate = nil
                end
                currentTemplate = NewTemplate("")
                if _nameEditRef then _nameEditRef:SetText("") end
                if _RebuildMainGrid   then _RebuildMainGrid() end
                if _UpdateAssignFrame then _UpdateAssignFrame() end
                if _UpdateDruidAssignFrame then _UpdateDruidAssignFrame() end
    if _UpdateDruidAssignFrame then _UpdateDruidAssignFrame() end
                if rosterFrame and _RebuildRosterRows then _RebuildRosterRows() end
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Template '"..name.."' deleted.")
            end
        end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }

    StaticPopupDialogs["HEALASSIGN_SAVE_BEFORE_NEW"] = {
        text = "Current template has unsaved changes. Save before creating a new one?",
        button1 = "Save",
        button2 = "Cancel",
        OnAccept = function()
            -- Save current then create new
            local name = _nameEditRef and _nameEditRef:GetText() or ""
            if name == "" then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Enter a template name first.")
                return
            end
            if not currentTemplate then currentTemplate = NewTemplate(name) end
            currentTemplate.name = name
            HealAssignDB.templates[name] = DeepCopy(currentTemplate)
            HealAssignDB.activeTemplate = name
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Saved '"..name.."'.")
            _DoNewTemplate()
        end,
        timeout = 0, whileDead = true, hideOnEscape = true,
    }
end

-------------------------------------------------------------------------------
-- UTILITY
-------------------------------------------------------------------------------
local function GetClassColor(class)
    local c = CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1,1,1
end

local function GetRaidMembers()
    local members = {}
    local numRaid = GetNumRaidMembers()
    if numRaid and numRaid > 0 then
        for i=1,numRaid do
            local name,rank,subgroup,level,class,fileName,zone,online = GetRaidRosterInfo(i)
            if name then
                table.insert(members, {name=name, class=fileName or class, rank=rank, subgroup=subgroup, online=online})
            end
        end
    else
        local pname = UnitName("player")
        local _,pclass = UnitClass("player")
        if pname then table.insert(members, {name=pname, class=pclass, rank=2, subgroup=1, online=true}) end
        local numParty = GetNumPartyMembers()
        if numParty and numParty > 0 then
            for i=1,numParty do
                local mname = UnitName("party"..i)
                local _,mclass = UnitClass("party"..i)
                if mname then table.insert(members, {name=mname, class=mclass, rank=0, subgroup=1, online=true}) end
            end
        end
    end
    table.sort(members, function(a,b) return a.name < b.name end)
    return members
end

local function IsRaidLeader()
    local myName = UnitName("player")
    local numRaid = GetNumRaidMembers()
    if not numRaid or numRaid == 0 then return false end
    for i=1,numRaid do
        local name,rank = GetRaidRosterInfo(i)
        if name == myName and rank == 2 then return true end
    end
    return false
end

local function HasEditorRights()
    local numRaid = GetNumRaidMembers()
    if not numRaid or numRaid == 0 then return false end
    local myName = UnitName("player")
    for i=1,numRaid do
        local name,rank = GetRaidRosterInfo(i)
        if name == myName and rank >= 1 then return true end
    end
    return false
end

local function GetTargetDisplayText(target)
    if target.type == TYPE_GROUP  then return "Group "..target.value end
    if target.type == TYPE_TANK   then return "[Tank] "..target.value end
    if target.type == TYPE_CUSTOM then return target.value end
    return target.value or "?"
end

-------------------------------------------------------------------------------
-- TEMPLATE STATE
-------------------------------------------------------------------------------
currentTemplate = nil

local function GetActiveTemplate()
    if currentTemplate then
        if not currentTemplate.roster   then currentTemplate.roster   = {} end
        if not currentTemplate.healers  then currentTemplate.healers  = {} end
        if not currentTemplate.innervate then currentTemplate.innervate = {} end
    end
    return currentTemplate
end

local function SyncHealersFromRoster(tmpl)
    local existing = {}
    for _,h in ipairs(tmpl.healers) do existing[h.name] = h end

    local hNames = {}
    for pname,pdata in pairs(tmpl.roster) do
        if pdata.tagH then table.insert(hNames, pname) end
    end
    table.sort(hNames)

    local newHealers = {}
    for _,pname in ipairs(hNames) do
        if existing[pname] then
            table.insert(newHealers, existing[pname])
        else
            table.insert(newHealers, {name=pname, targets={}})
        end
    end
    tmpl.healers = newHealers
    if not tmpl.innervate then tmpl.innervate = {} end
end

-------------------------------------------------------------------------------
-- FRAME REFERENCES
-------------------------------------------------------------------------------
local mainFrame    = nil
local rosterFrame  = nil
local assignFrame      = nil
local druidAssignFrame = nil
local optionsFrame = nil
local rlFrame      = nil
local alertFrame   = nil
local innervateFrame = nil

-- Forward declarations for functions used before their definition
local INN_BroadcastCast  -- defined in INNERVATE ASSIGNMENT SYSTEM section

-- Innervate forward refs (functions defined later)
local innCD           = {}    -- [druidName] = GetTime() of cast
local INN_CD_FULL     = 360
local INN_ICON        = "Interface\\Icons\\Spell_Nature_Lightning"
local INN_ALERT_SHOWN = {}

local function INN_GetCDRemaining(druidName)
    local t = innCD[druidName]
    if not t then return 0 end
    local rem = INN_CD_FULL - (GetTime() - t)
    return rem > 0 and rem or 0
end

local function INN_GetHealerMana(healerName)
    for i = 1, GetNumRaidMembers() do
        if UnitName("raid"..i) == healerName then
            local cur = UnitMana("raid"..i)
            local max = UnitManaMax("raid"..i)
            if max and max > 0 then return math.floor(cur/max*100) end
        end
    end
    if UnitName("player") == healerName then
        local cur = UnitMana("player")
        local max = UnitManaMax("player")
        if max and max > 0 then return math.floor(cur/max*100) end
    end
    return nil
end

-- Record innervate cast: saves to both innCD and persistent DB
local function INN_RecordCast(druidName)
    innCD[druidName] = GetTime()
    if HealAssignDB and HealAssignDB.innCD then
        HealAssignDB.innCD[druidName] = GetTime()
    end
end

-- Restore innCD from DB on login (GetTime() just restarted, recalc from saved remaining)
local function INN_RestoreFromDB()
    if not HealAssignDB or not HealAssignDB.innCD then return end
    -- HealAssignDB.innCD stores {druid: {saved_at_uptime, remaining_at_save}}
    for druidName, data in pairs(HealAssignDB.innCD) do
        if type(data) == "table" and data.rem and data.rem > 0 then
            -- Reconstruct: castTime = GetTime() - (INN_CD_FULL - data.rem)
            innCD[druidName] = GetTime() - (INN_CD_FULL - data.rem)
        end
    end
end

-------------------------------------------------------------------------------
-- DROPDOWN
-------------------------------------------------------------------------------
local dropdownFrame        = nil
local dropdownLocker       = nil
local activeDropdownAnchor = nil

local function CloseDropdown()
    if dropdownFrame and dropdownFrame:IsShown() then
        dropdownFrame:Hide()
        if dropdownLocker then dropdownLocker:Hide() end
        activeDropdownAnchor = nil
    end
end

local function ShowDropdown(anchorFrame, items, onSelect, width)
    if dropdownFrame and dropdownFrame:IsShown() and activeDropdownAnchor == anchorFrame then
        CloseDropdown()
        return
    end
    CloseDropdown()

    if not dropdownLocker then
        dropdownLocker = CreateFrame("Button","HealAssignDropdownLocker",UIParent)
        dropdownLocker:SetAllPoints(UIParent)
        dropdownLocker:SetFrameStrata("DIALOG")
        dropdownLocker:SetScript("OnClick", CloseDropdown)
    end

    if not dropdownFrame then
        dropdownFrame = CreateFrame("Frame","HealAssignDropdownFrame",UIParent)
        dropdownFrame:SetFrameStrata("TOOLTIP")
        dropdownFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        dropdownFrame:SetBackdropColor(0.08,0.08,0.12,0.97)
        dropdownFrame.buttons = {}
    end

    local f   = dropdownFrame
    activeDropdownAnchor = anchorFrame
    dropdownLocker:Show()

    for _,b in ipairs(f.buttons) do b:Hide() end

    local itemH = 22
    local pad   = 4
    local w     = width or 160
    local h     = table.getn(items)*itemH + pad*2
    if h < 24 then h = 24 end

    f:SetWidth(w)
    f:SetHeight(h)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -2)

    for i,item in ipairs(items) do
        local btn = f.buttons[i]
        if not btn then
            btn = CreateFrame("Button",nil,f)
            btn:SetHeight(itemH)
            btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            btn:GetHighlightTexture():SetAlpha(0.4)

            local ic = btn:CreateTexture(nil,"OVERLAY")
            ic:SetWidth(14)
            ic:SetHeight(14)
            ic:SetPoint("LEFT",btn,"LEFT",4,0)
            btn.icon = ic

            local fs = btn:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            fs:SetPoint("LEFT",btn,"LEFT",22,0)
            fs:SetPoint("RIGHT",btn,"RIGHT",-4,0)
            fs:SetJustifyH("LEFT")
            btn.label = fs
            f.buttons[i] = btn
        end

        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT",f,"TOPLEFT",pad,-(pad+(i-1)*itemH))
        btn:SetWidth(w-pad*2)
        btn:Show()

        btn.label:ClearAllPoints()
        btn.label:SetPoint("RIGHT",btn,"RIGHT",-4,0)
        if item.icon then
            btn.icon:SetTexture(item.icon)
            btn.icon:SetWidth(16)
            btn.icon:SetHeight(16)
            btn.icon:Show()
            btn.label:SetPoint("LEFT",btn,"LEFT",24,0)
        else
            btn.icon:SetTexture(nil)
            btn.icon:Hide()
            btn.label:SetPoint("LEFT",btn,"LEFT",6,0)
        end

        if item.r then btn.label:SetTextColor(item.r,item.g,item.b)
        else btn.label:SetTextColor(1,1,1) end
        btn.label:SetText(item.text or "")

        local capturedItem = item
        btn:SetScript("OnClick",function()
            CloseDropdown()
            onSelect(capturedItem)
        end)
    end

    f:Show()
end

-------------------------------------------------------------------------------
-- SERIALIZATION
-------------------------------------------------------------------------------
local function SplitStr(str, sep)
    local result = {}
    local i = 1
    local last = 1
    local len = string.len(str)
    while i <= len do
        if string.sub(str,i,i) == sep then
            local part = string.sub(str,last,i-1)
            if part ~= "" then table.insert(result,part) end
            last = i+1
        end
        i = i+1
    end
    local part = string.sub(str,last)
    if part ~= "" then table.insert(result,part) end
    return result
end

local function Serialize(tmpl)
    local rosterParts = {}
    for pname,pdata in pairs(tmpl.roster or {}) do
        local safe = string.gsub(pname,"[|~;:,]","_")
        local tagStr = (pdata.tagT and "T" or "")..(pdata.tagH and "H" or "")..(pdata.tagV and "V" or "")
        table.insert(rosterParts, safe..":"..(pdata.class or "")..":"..tagStr)
    end

    local healerParts = {}
    for _,h in ipairs(tmpl.healers or {}) do
        local safeName = string.gsub(h.name or "","[|~;:,]","_")
        local tStrs = {}
        for _,t in ipairs(h.targets or {}) do
            local safeVal = string.gsub(t.value or "","[|~;:,]","_")
            table.insert(tStrs, t.type..":"..safeVal)
        end
        table.insert(healerParts, safeName..";"..table.concat(tStrs,","))
    end

    local innParts = {}
    for dn,hn in pairs(tmpl.innervate or {}) do
        local safeD = string.gsub(dn,"[|~;:,]","_")
        local safeH = string.gsub(hn,"[|~;:,]","_")
        table.insert(innParts, safeD.."="..safeH)
    end

    return "v2~"..string.gsub(tmpl.name or "","[|~;:,]","_").."~"
        ..table.concat(rosterParts,"|").."~"
        ..table.concat(healerParts,"|").."~"
        ..table.concat(innParts,"^")
end

local function Deserialize(str)
    if not str then return nil end
    local parts = SplitStr(str,"~")
    -- parts[1]=v2, parts[2]=name, parts[3]=roster, parts[4]=healers
    if not parts[1] or parts[1] ~= "v2" then return nil end

    local tmpl = NewTemplate(parts[2] or "")

    if parts[3] and parts[3] ~= "" then
        local entries = SplitStr(parts[3],"|")
        for _,entry in ipairs(entries) do
            local ep = SplitStr(entry,":")
            if ep[1] and ep[1] ~= "" then
                local tagStr = ep[3] or ""
                tmpl.roster[ep[1]] = {
                    class = ep[2] or "",
                    tagT  = string.find(tagStr,"T") ~= nil or nil,
                    tagH  = string.find(tagStr,"H") ~= nil or nil,
                    tagV  = string.find(tagStr,"V") ~= nil or nil,
                }
            end
        end
    end

    if parts[4] and parts[4] ~= "" then
        local hentries = SplitStr(parts[4],"|")
        for _,hentry in ipairs(hentries) do
            local semi = string.find(hentry,";")
            if semi then
                local hname = string.sub(hentry,1,semi-1)
                local tstr  = string.sub(hentry,semi+1)
                local healer = {name=hname, targets={}}
                if tstr and tstr ~= "" then
                    local tparts = SplitStr(tstr,",")
                    for _,tp in ipairs(tparts) do
                        local colon = string.find(tp,":")
                        if colon then
                            table.insert(healer.targets, {
                                type  = string.sub(tp,1,colon-1),
                                value = string.sub(tp,colon+1)
                            })
                        end
                    end
                end
                table.insert(tmpl.healers, healer)
            end
        end
    end

    -- parts[5] = innervate assignments (druid=healer pairs separated by ^)
    if parts[5] and parts[5] ~= "" then
        local ipairs2 = SplitStr(parts[5],"^")
        for _,ipair in ipairs(ipairs2) do
            local eq = string.find(ipair,"=")
            if eq then
                local dn = string.sub(ipair,1,eq-1)
                local hn = string.sub(ipair,eq+1)
                if dn ~= "" and hn ~= "" then
                    tmpl.innervate[dn] = hn
                end
            end
        end
    end

    return tmpl
end

-------------------------------------------------------------------------------
-- DEATH ALERT SYSTEM
-------------------------------------------------------------------------------
local deadHealers = {}

-- DBM-style alert: big text center screen, fades after 5 sec
local function CreateAlertFrame()
    if alertFrame then return end

    alertFrame = CreateFrame("Frame","HealAssignAlertFrame",UIParent)
    alertFrame:SetWidth(600)
    alertFrame:SetHeight(44)
    alertFrame:SetPoint("TOP",UIParent,"TOP",0,-120)
    alertFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    alertFrame:Hide()

    alertFrame:SetBackdrop({
        bgFile  = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile= "Interface\\Tooltips\\UI-Tooltip-Border",
        tile=true,tileSize=8,edgeSize=10,
        insets={left=4,right=4,top=4,bottom=4}
    })
    alertFrame:SetBackdropColor(0.3,0,0,0.92)
    alertFrame:SetBackdropBorderColor(1,0.1,0.1,1)

    local header = alertFrame:CreateFontString(nil,"OVERLAY","GameFontNormalHuge")
    header:SetFont("Fonts\\FRIZQT__.TTF", 22, "OUTLINE")
    header:SetPoint("CENTER",alertFrame,"CENTER",0,0)
    header:SetTextColor(1,0.1,0.1)
    alertFrame.header = header

    local sub = alertFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    sub:SetPoint("TOP",header,"BOTTOM",0,-4)
    sub:SetTextColor(1,0.75,0.1)
    alertFrame.sub = sub

    -- Fade out timer
    alertFrame.elapsed = 0
    alertFrame.duration = 5
    alertFrame:SetScript("OnUpdate",function()
        if not alertFrame.active then return end
        alertFrame.elapsed = alertFrame.elapsed + arg1
        local pct = alertFrame.elapsed / alertFrame.duration
        if pct >= 1 then
            alertFrame.active = false
            alertFrame:Hide()
        else
            local alpha = 1
            if pct > 0.6 then alpha = 1 - (pct - 0.6) / 0.4 end
            alertFrame:SetAlpha(alpha)
        end
    end)

    alertFrame.rows = {}
end

local function RefreshAlertFrame()
    if not alertFrame then return end
    local now = GetTime()
    local alive = {}
    for _,d in ipairs(deadHealers) do
        if now - d.time < 15 then table.insert(alive,d) end
    end
    deadHealers = alive
    if table.getn(deadHealers) == 0 then
        alertFrame:Hide()
    end
end

local function TriggerHealerDeath(healerName, targets)
    local myName = UnitName("player")
    local tmpl = GetActiveTemplate()

    -- Always track in deadHealers (needed for UNATTENDED display)
    local found = false
    for _,d in ipairs(deadHealers) do
        if d.name == healerName then
            d.time = GetTime()
            d.targets = DeepCopy(targets or {})
            found = true
            break
        end
    end
    if not found then
        table.insert(deadHealers, {name=healerName, targets=DeepCopy(targets or {}), time=GetTime()})
    end

    -- Check if local player should see visual alert (tag H or V or RL)
    local shouldShow = false
    if tmpl and tmpl.roster and tmpl.roster[myName] then
        local me = tmpl.roster[myName]
        if me.tagH or me.tagV then shouldShow = true end
    end
    if HasEditorRights and HasEditorRights() then shouldShow = true end

    if not shouldShow then return end

    -- Play sound
    PlaySoundFile("Interface\\AddOns\\HealAssign\\Sounds\\bucket.wav")

    -- Show DBM-style alert
    if not alertFrame then CreateAlertFrame() end

    local targetText = "No assigned targets"
    if table.getn(targets or {}) > 0 then
        local names = {}
        for _,t in ipairs(targets) do table.insert(names, GetTargetDisplayText(t)) end
        targetText = "Unattended:  "..table.concat(names, "   |   ")
    end

    alertFrame.header:SetText("HEALER DEAD:  "..healerName)
    alertFrame.sub:SetText("")
    alertFrame.duration = 7
    alertFrame.elapsed = 0
    alertFrame.active = true
    alertFrame:SetAlpha(1)
    alertFrame:Show()
end

-------------------------------------------------------------------------------
-- ASSIGN FRAME (personal frame showing my targets + unattended)
-------------------------------------------------------------------------------
local function UpdateAssignFrame()
    if not assignFrame then return end

    for _,c in ipairs(assignFrame.content or {}) do c:Hide() end
    assignFrame.content = {}

    local inRaid = GetNumRaidMembers() > 0
    local showOutsideRaid = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
    if not inRaid and not showOutsideRaid then
        assignFrame:Hide()
        return
    end

    local myName   = UnitName("player")
    local tmpl     = GetActiveTemplate()
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12

    local myTargets     = {}
    local myDeadTargets = {}

    -- Determine player role
    local myPdata = tmpl and tmpl.roster and tmpl.roster[myName]
    local isHealer = myPdata and myPdata.tagH
    local isViewer = myPdata and myPdata.tagV
    local isDruid  = myPdata and myPdata.class == "DRUID" and not isHealer
    local isAssignedDruid = isDruid and tmpl and tmpl.innervate and tmpl.innervate[myName]

    -- Non-healer, non-viewer, non-druid: hide assignFrame
    if not isHealer and not isViewer and not isDruid then
        assignFrame:Hide()
        return
    end

    if tmpl then
        for _,h in ipairs(tmpl.healers) do
            if h.name == myName then myTargets = h.targets break end
        end
        local deadSet = {}
        for _,d in ipairs(deadHealers) do deadSet[d.name] = d end
        for _,d in ipairs(deadHealers) do
            if d.name ~= myName then
                for _,t in ipairs(d.targets) do
                    table.insert(myDeadTargets,{target=t, from=d.name})
                end
            end
        end
    end

    -- Adjust frame width based on font size
    local frameW = 130 + (fontSize - 8) * 7
    if isViewer then
        -- Viewer needs extra width for innervate section (druid -> healer)
        if frameW < 180 then frameW = 180 end
        if frameW > 320 then frameW = 320 end
    else
        if frameW < 120 then frameW = 120 end
        if frameW > 240 then frameW = 240 end
    end
    assignFrame:SetWidth(frameW)

    -- Row spacing scales with font size
    local rowH    = fontSize + 4   -- tight row height
    local rowStep = fontSize + 5   -- step between rows
    local titleH  = fontSize + 8   -- title area
    local yOff    = -(titleH + 2)

    local function AddRow(text, r,g,b, bgR,bgG,bgB)
        local row = CreateFrame("Frame",nil,assignFrame)
        row:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",6,yOff)
        row:SetWidth(assignFrame:GetWidth()-12)
        row:SetHeight(rowH)
        if bgR then
            row:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",insets={left=0,right=0,top=0,bottom=0}})
            row:SetBackdropColor(bgR,bgG,bgB,0.3)
        end
        local fs = row:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize)
        fs:SetPoint("LEFT",row,"LEFT",4,0)
        fs:SetTextColor(r or 1,g or 1,b or 1)
        fs:SetText(text)
        yOff = yOff - rowStep
        table.insert(assignFrame.content,row)
    end

    -- Get my class color from roster
    local myClass = nil
    if tmpl and tmpl.roster and tmpl.roster[myName] then
        myClass = tmpl.roster[myName].class
    end
    if not myClass then
        local _,c = UnitClass("player")
        myClass = c
    end
    local tr,tg,tb = GetClassColor(myClass)

    local titleFS = assignFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFS:SetPoint("TOP",assignFrame,"TOP",0,-3)
    titleFS:SetTextColor(tr,tg,tb)
    titleFS:SetText(isViewer and "Assignments" or myName)
    table.insert(assignFrame.content,titleFS)

    -- Viewer (V tag): two sections
    if isViewer and tmpl then
        -- Section 1: Healer Assignments (Target -> Healers)
        AddRow("Healer Assignments", 1,0.8,0.2)
        local targetOrder,targetMeta,targetHeals,seen = {},{},{},{}
        for _,h in ipairs(tmpl.healers) do
            for _,t in ipairs(h.targets) do
                local key = (t.type or "").."~"..(t.value or "")
                if not seen[key] then
                    seen[key]=true
                    table.insert(targetOrder,key)
                    targetMeta[key]={display=GetTargetDisplayText(t),ttype=t.type,tvalue=t.value}
                    targetHeals[key]={}
                end
                table.insert(targetHeals[key],h.name)
            end
        end
        if table.getn(targetOrder)==0 then
            AddRow("  (no assignments)",0.5,0.5,0.5)
        else
            for _,key in ipairs(targetOrder) do
                local m=targetMeta[key]
                local tr2,tg2,tb2=0.88,0.88,0.88
                if m.ttype==TYPE_TANK then
                    if tmpl.roster and tmpl.roster[m.tvalue] then tr2,tg2,tb2=GetClassColor(tmpl.roster[m.tvalue].class) end
                elseif m.ttype==TYPE_GROUP  then tr2,tg2,tb2=0.5,0.85,1.0
                elseif m.ttype==TYPE_CUSTOM then tr2,tg2,tb2=0.9,0.6,1.0
                end
                AddRow(m.display,tr2,tg2,tb2)
                for _,hname in ipairs(targetHeals[key]) do
                    local hr2,hg2,hb2=1,1,1
                    if tmpl.roster and tmpl.roster[hname] then hr2,hg2,hb2=GetClassColor(tmpl.roster[hname].class) end
                    local isDead = false
                    for _,dd in ipairs(deadHealers) do if dd.name==hname then isDead=true break end end
                    if isDead then hr2,hg2,hb2=1,0.1,0.1 end
                    AddRow("  "..hname,hr2,hg2,hb2)
                end
            end
        end

        -- Section 2: Innervate Assignments
        if tmpl.innervate and next(tmpl.innervate) then
            yOff = yOff - 4
            -- Header row with icon inline
            local hdrRow = CreateFrame("Frame",nil,assignFrame)
            hdrRow:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",6,yOff)
            hdrRow:SetWidth(assignFrame:GetWidth()-12)
            hdrRow:SetHeight(rowH)
            table.insert(assignFrame.content,hdrRow)
            local hdrIcon = hdrRow:CreateTexture(nil,"ARTWORK")
            hdrIcon:SetWidth(fontSize)
            hdrIcon:SetHeight(fontSize)
            hdrIcon:SetPoint("LEFT",hdrRow,"LEFT",4,0)
            hdrIcon:SetTexture(INN_ICON)
            local hdrFS = hdrRow:CreateFontString(nil,"OVERLAY")
            hdrFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
            hdrFS:SetPoint("LEFT",hdrRow,"LEFT",fontSize+8,0)
            hdrFS:SetTextColor(1,0.8,0.2)
            hdrFS:SetText("Innervate")
            yOff = yOff - rowStep
            -- Build sorted list
            local innList = {}
            for dn,hn in pairs(tmpl.innervate) do
                table.insert(innList,{druid=dn,healer=hn})
            end
            table.sort(innList,function(a,b) return a.druid<b.druid end)
            for _,pair in ipairs(innList) do
                local vdr,vdg,vdb = GetClassColor("DRUID")
                local vhr,vhg,vhb = 1,1,1
                if tmpl.roster and tmpl.roster[pair.healer] then
                    vhr,vhg,vhb = GetClassColor(tmpl.roster[pair.healer].class)
                end
                -- FIX 2: single row, druid LEFT half, healer RIGHT half, no arrow separator
                local vRow = CreateFrame("Frame",nil,assignFrame)
                vRow:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",6,yOff)
                vRow:SetWidth(assignFrame:GetWidth()-12)
                vRow:SetHeight(rowH)
                table.insert(assignFrame.content,vRow)
                local rowW = assignFrame:GetWidth()-12
                local halfW = math.floor(rowW/2) - 4
                -- Druid name occupies left half
                local vFS = vRow:CreateFontString(nil,"OVERLAY")
                vFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                vFS:SetPoint("LEFT",vRow,"LEFT",6,0)
                vFS:SetWidth(halfW)
                vFS:SetJustifyH("LEFT")
                vFS:SetTextColor(vdr,vdg,vdb)
                vFS:SetText(pair.druid)
                -- Healer name occupies right half
                local vHFS = vRow:CreateFontString(nil,"OVERLAY")
                vHFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                vHFS:SetPoint("RIGHT",vRow,"RIGHT",-4,0)
                vHFS:SetWidth(halfW)
                vHFS:SetJustifyH("RIGHT")
                vHFS:SetTextColor(vhr,vhg,vhb)
                vHFS:SetText(pair.healer)
                yOff = yOff - rowStep
            end
        end

        local totalH=math.abs(yOff)+rowStep
        if totalH<titleH+rowStep then totalH=titleH+rowStep end
        assignFrame:SetHeight(totalH)
        assignFrame:Show()
        return
    end

    if table.getn(myTargets) == 0 then
        AddRow("  (none assigned)",0.5,0.5,0.5)
    else
        for _,t in ipairs(myTargets) do
            local dr,dg,db = 1,1,1
            if t.type == TYPE_TANK then
                -- Class color for tanks
                if tmpl and tmpl.roster and tmpl.roster[t.value] then
                    dr,dg,db = GetClassColor(tmpl.roster[t.value].class)
                end
            elseif t.type == TYPE_GROUP  then dr,dg,db = 0.5, 0.85, 1.0
            elseif t.type == TYPE_CUSTOM then dr,dg,db = 0.9, 0.6,  1.0
            end
            AddRow("  "..GetTargetDisplayText(t),dr,dg,db)
        end
    end

    -- Innervate: show assigned druid + CD icon for healer
    local myInnDruid = nil
    if tmpl and tmpl.innervate then
        for dname,hname in pairs(tmpl.innervate) do
            if hname == myName then myInnDruid = dname break end
        end
    end
    if myInnDruid then
        yOff = yOff - 4
        local cdRem   = INN_GetCDRemaining(myInnDruid)
        local isReady = cdRem <= 0
        local iconSize = fontSize

        -- Icon row: 32x32 icon with cooldown sweep + druid name
        local ICON_SZ = math.floor(fontSize * 2.2)
        if ICON_SZ < 18 then ICON_SZ = 18 end
        if ICON_SZ > 44 then ICON_SZ = 44 end
        local innRowFrame = CreateFrame("Frame",nil,assignFrame)
        innRowFrame:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",6,yOff)
        innRowFrame:SetWidth(assignFrame:GetWidth()-12)
        innRowFrame:SetHeight(ICON_SZ)
        table.insert(assignFrame.content, innRowFrame)

        -- Icon container
        local iconCont = CreateFrame("Frame",nil,innRowFrame)
        iconCont:SetWidth(ICON_SZ)
        iconCont:SetHeight(ICON_SZ)
        iconCont:SetPoint("LEFT",innRowFrame,"LEFT",4,0)
        local iconTex = iconCont:CreateTexture(nil,"BACKGROUND")
        iconTex:SetAllPoints(iconCont)
        iconTex:SetTexture(INN_ICON)

        -- CD text overlay on icon
        if not isReady then
            iconTex:SetVertexColor(0.35,0.35,0.35)
            local mins = math.floor(cdRem/60)
            local secs = math.floor(math.mod(cdRem,60))
            local cdFS = iconCont:CreateFontString(nil,"OVERLAY")
            cdFS:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
            cdFS:SetPoint("CENTER",iconCont,"CENTER",0,0)
            cdFS:SetTextColor(1,1,1)
            cdFS:SetText(string.format("%d:%02d",mins,secs))
        end

        -- Druid name next to icon
        local dr2,dg2,db2 = GetClassColor("DRUID")
        local nameFS = innRowFrame:CreateFontString(nil,"OVERLAY")
        nameFS:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
        nameFS:SetPoint("LEFT",innRowFrame,"LEFT",ICON_SZ+8,0)
        nameFS:SetPoint("RIGHT",innRowFrame,"RIGHT",-4,0)
        nameFS:SetJustifyH("LEFT")
        if isReady then
            nameFS:SetTextColor(dr2,dg2,db2)
        else
            nameFS:SetTextColor(dr2*0.55, dg2*0.55, db2*0.55)
        end
        nameFS:SetText(myInnDruid)

        yOff = yOff - ICON_SZ - 2
    end

    if table.getn(myDeadTargets) > 0 then
        yOff = yOff - 4
        -- Group targets by dead healer
        local healerOrder = {}
        local healerTargets = {}
        for _,ud in ipairs(myDeadTargets) do
            if not healerTargets[ud.from] then
                table.insert(healerOrder, ud.from)
                healerTargets[ud.from] = {}
            end
            table.insert(healerTargets[ud.from], ud.target)
        end
        for _,dname in ipairs(healerOrder) do
            local dr2,dg2,db2 = 1,0.2,0.2
            if tmpl and tmpl.roster and tmpl.roster[dname] then
                dr2,dg2,db2 = GetClassColor(tmpl.roster[dname].class)
            end
            AddRow("  "..dname.." (dead):", dr2,dg2,db2, 0.35,0,0)
            for _,t in ipairs(healerTargets[dname]) do
                local tr2,tg2,tb2 = 1,0.6,0.1
                if t.type == TYPE_TANK then
                    if tmpl and tmpl.roster and tmpl.roster[t.value] then
                        tr2,tg2,tb2 = GetClassColor(tmpl.roster[t.value].class)
                    end
                elseif t.type == TYPE_GROUP  then tr2,tg2,tb2 = 0.5,0.85,1.0
                elseif t.type == TYPE_CUSTOM then tr2,tg2,tb2 = 0.9,0.6,1.0
                end
                AddRow("  "..GetTargetDisplayText(t), tr2,tg2,tb2)
            end
        end
    end

    local totalH = math.abs(yOff)+10
    if totalH < 60 then totalH = 60 end
    assignFrame:SetHeight(totalH)
    assignFrame:Show()
end

local function ApplyWindowAlpha(alpha)
    alpha = alpha or (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    if mainFrame    then mainFrame:SetBackdropColor(0.04,0.04,0.1,alpha)    end
    if rosterFrame  then rosterFrame:SetBackdropColor(0.04,0.04,0.1,alpha)  end
    if optionsFrame then optionsFrame:SetBackdropColor(0.04,0.04,0.1,alpha) end
    if assignFrame  then assignFrame:SetBackdropColor(0.05,0.05,0.1,alpha)  end
    if rlFrame      then rlFrame:SetBackdropColor(0.03,0.07,0.03,alpha)     end
end

-- ESC handling: UISpecialFrames only allows one frame at a time.
-- We swap which frame is registered based on openStack top.
local function UpdateEscFrame()
    -- Clear all HA frames from UISpecialFrames
    local toRemove = {
        ["HealAssignMainFrame"]=true,
        ["HealAssignOptionsFrame"]=true,
        ["HealAssignRosterFrame"]=true,
    }
    local i = 1
    while i <= table.getn(UISpecialFrames) do
        if toRemove[UISpecialFrames[i]] then
            table.remove(UISpecialFrames, i)
        else
            i = i + 1
        end
    end
    -- Register only the topmost visible window
    for j = table.getn(openStack), 1, -1 do
        local f = openStack[j]
        if f and f:IsShown() and f:GetName() then
            table.insert(UISpecialFrames, f:GetName())
            return
        end
        table.remove(openStack, j)
    end
end

local function PushWindow(f)
    for i = table.getn(openStack), 1, -1 do
        if openStack[i] == f then table.remove(openStack, i) end
    end
    table.insert(openStack, f)
    UpdateEscFrame()
end

-- Hook Hide on each HA frame to update ESC registration
local function HookFrameHide(f)
    local orig = f:GetScript("OnHide")
    f:SetScript("OnHide", function()
        if orig then orig() end
        UpdateEscFrame()
    end)
end

function HealAssign_OpenOptions()
    CreateOptionsFrame()
end


local function CreateAssignFrame()
    if assignFrame then return end
    assignFrame = CreateFrame("Frame","HealAssignAssignFrame",UIParent)
    assignFrame:SetWidth(220)
    assignFrame:SetHeight(100)
    assignFrame:SetPoint("CENTER",UIParent,"CENTER",400,0)
    assignFrame:SetMovable(true)
    assignFrame:EnableMouse(true)
    assignFrame:RegisterForDrag("LeftButton")
    assignFrame:SetScript("OnDragStart",function() this:StartMoving() end)
    assignFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    assignFrame:SetFrameStrata("MEDIUM")
    assignFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=8,edgeSize=12,
        insets={left=4,right=4,top=4,bottom=4}
    })
    local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    assignFrame:SetBackdropColor(0.05,0.05,0.1,_alpha)
    assignFrame:SetBackdropBorderColor(0.3,0.6,1,0.8)
    assignFrame.content = {}
    assignFrame:Hide()

    local optBtn = CreateFrame("Button",nil,assignFrame,"UIPanelButtonTemplate")
    optBtn:SetWidth(24)
    optBtn:SetHeight(16)
    optBtn:SetPoint("TOPRIGHT",assignFrame,"TOPRIGHT",-4,-4)
    optBtn:SetText("O")
    optBtn:SetScript("OnClick",function()
        if optionsFrame and optionsFrame:IsShown() then
            optionsFrame:Hide()
        else
            HealAssign_OpenOptions()
        end
    end)
end

-------------------------------------------------------------------------------
-- DRUID INNERVATE FRAME
-------------------------------------------------------------------------------
local function UpdateDruidAssignFrame()
    local myName = UnitName("player")
    local tmpl   = GetActiveTemplate()
    local inRaid = GetNumRaidMembers() > 0
    local showOutside = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame

    local myPdata = tmpl and tmpl.roster and tmpl.roster[myName]
    local isDruid = myPdata and myPdata.class == "DRUID" and not (myPdata.tagH)
    local assignedHealer = isDruid and tmpl and tmpl.innervate and tmpl.innervate[myName]

    if not assignedHealer or (not inRaid and not showOutside) then
        if druidAssignFrame then druidAssignFrame:Hide() end
        return
    end

    -- Layout constants (all scale with fontSize)
    local fontSize = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    local PAD     = 8
    local titleH  = fontSize + 10    -- title row height
    local rowStep = fontSize + 8     -- mana row height
    local ICON_SZ = math.floor(fontSize * 2.5)
    if ICON_SZ < 20 then ICON_SZ = 20 end
    if ICON_SZ > 48 then ICON_SZ = 48 end
    local BTN_H   = fontSize + 10
    local cdFontSz = math.floor(fontSize * 0.85)
    if cdFontSz < 8 then cdFontSz = 8 end

    -- Frame width scales with fontSize
    local frameW = 100 + fontSize * 8
    if frameW < 120 then frameW = 120 end
    if frameW > 260 then frameW = 260 end

    -- Total height: PAD + title + PAD/2 + mana + PAD + icon + PAD + button + PAD
    local totalH = PAD + titleH + 4 + rowStep + PAD + ICON_SZ + PAD + BTN_H + PAD

    -- Create frame once
    if not druidAssignFrame then
        druidAssignFrame = CreateFrame("Frame","HealAssignDruidAssignFrame",UIParent)
        druidAssignFrame:SetMovable(true)
        druidAssignFrame:EnableMouse(true)
        druidAssignFrame:RegisterForDrag("LeftButton")
        druidAssignFrame:SetScript("OnDragStart",function() this:StartMoving() end)
        druidAssignFrame:SetScript("OnDragStop",function()
            this:StopMovingOrSizing()
            -- FIX 2: save position so it restores on next show
            local _,_,_,x,y = this:GetPoint()
            if HealAssignDB and HealAssignDB.options then
                HealAssignDB.options.druidFrameX = x
                HealAssignDB.options.druidFrameY = y
            end
        end)
        druidAssignFrame:SetFrameStrata("MEDIUM")
        druidAssignFrame:SetBackdrop({
            bgFile="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=8,edgeSize=12,
            insets={left=4,right=4,top=4,bottom=4}
        })
        -- FIX 2: restore saved position or use default
        local _dx = HealAssignDB and HealAssignDB.options and HealAssignDB.options.druidFrameX or 20
        local _dy = HealAssignDB and HealAssignDB.options and HealAssignDB.options.druidFrameY or -200
        druidAssignFrame:SetPoint("TOPLEFT",UIParent,"TOPLEFT",_dx,_dy)

        -- Options button (top-right corner, fixed size)
        local optBtn = CreateFrame("Button",nil,druidAssignFrame,"UIPanelButtonTemplate")
        optBtn:SetWidth(24) optBtn:SetHeight(16)
        optBtn:SetPoint("TOPRIGHT",druidAssignFrame,"TOPRIGHT",-4,-4)
        optBtn:SetText("O")
        optBtn:SetScript("OnClick",function()
            if optionsFrame and optionsFrame:IsShown() then optionsFrame:Hide()
            else HealAssign_OpenOptions() end
        end)

        -- Title fontstring (healer name)
        local tFS = druidAssignFrame:CreateFontString(nil,"OVERLAY")
        tFS:SetJustifyH("CENTER")
        druidAssignFrame._titleFS = tFS

        -- Mana fontstring
        local mFS = druidAssignFrame:CreateFontString(nil,"OVERLAY")
        mFS:SetJustifyH("CENTER")
        druidAssignFrame._manaFS = mFS

        -- Icon frame + texture + CD label
        local iFrame = CreateFrame("Frame",nil,druidAssignFrame)
        local iTex = iFrame:CreateTexture(nil,"BACKGROUND")
        iTex:SetTexture(INN_ICON)
        iTex:SetAllPoints(iFrame)          -- FIX: texture fills iFrame
        local iCDFS = iFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        iCDFS:SetPoint("CENTER",iFrame,"CENTER",0,0)
        iCDFS:SetTextColor(1,1,0)
        druidAssignFrame._iconFrame = iFrame
        druidAssignFrame._iconTex   = iTex
        druidAssignFrame._iconCDFS  = iCDFS

        -- Cast button
        local btn = CreateFrame("Button",nil,druidAssignFrame,"UIPanelButtonTemplate")
        btn:SetText("Innervate!")
        btn:SetScript("OnClick",function()
            local t2 = GetActiveTemplate()
            local n = UnitName("player")
            if not t2 then return end
            local h = t2.innervate and t2.innervate[n]
            if not h then return end
            if UnitName("target") ~= h then TargetByName(h)
            else CastSpellByName("Innervate") end
        end)
        druidAssignFrame._castBtn = btn
    end

    -- Update backdrop alpha
    local _a = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    druidAssignFrame:SetBackdropColor(0.05,0.05,0.1,_a)
    druidAssignFrame:SetBackdropBorderColor(0.3,0.6,1,0.8)

    -- Resize frame
    druidAssignFrame:SetWidth(frameW)
    druidAssignFrame:SetHeight(totalH)

    -- Running Y cursor from top
    local curY = -PAD

    -- Title: healer name
    local hr,hg,hb = 1,1,1
    if tmpl.roster and tmpl.roster[assignedHealer] then
        hr,hg,hb = GetClassColor(tmpl.roster[assignedHealer].class)
    end
    local tFS = druidAssignFrame._titleFS
    tFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
    tFS:SetTextColor(hr,hg,hb)
    tFS:SetText(assignedHealer)
    tFS:ClearAllPoints()
    tFS:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    tFS:SetWidth(frameW - 32)   -- leave room for O button
    curY = curY - titleH - 4

    -- Mana
    local mFS = druidAssignFrame._manaFS
    mFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
    mFS:ClearAllPoints()
    mFS:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    mFS:SetWidth(frameW - 12)
    local manaPct = INN_GetHealerMana(assignedHealer)
    if manaPct then
        local mr = manaPct < 50 and 1 or 0.3
        local mg = manaPct >= 50 and 0.9 or 0.3
        mFS:SetTextColor(mr,mg,0.3)
        mFS:SetText("Mana: "..manaPct.."%")
    else
        mFS:SetTextColor(0.5,0.5,0.5)
        mFS:SetText("Mana: ?")
    end
    curY = curY - rowStep - PAD

    -- Icon (centered horizontally)
    local iFrame = druidAssignFrame._iconFrame
    iFrame:ClearAllPoints()
    iFrame:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    iFrame:SetWidth(ICON_SZ)
    iFrame:SetHeight(ICON_SZ)

    -- CD via GetSpellCooldown (own spell - no combat log needed)
    local cdStart,cdDur = GetSpellCooldown("Innervate")
    local cdRem = 0
    if cdStart and cdStart > 0 and cdDur and cdDur > 1.5 then
        cdRem = (cdStart + cdDur) - GetTime()
        if cdRem < 0 then cdRem = 0 end
    end
    local iTex  = druidAssignFrame._iconTex
    local iCDFS = druidAssignFrame._iconCDFS
    iCDFS:SetFont("Fonts\\FRIZQT__.TTF",cdFontSz,"OUTLINE")
    if cdRem > 0 then
        iTex:SetVertexColor(0.3,0.3,0.3)
        local mins = math.floor(cdRem/60)
        local secs = math.floor(math.mod(cdRem,60))
        iCDFS:SetText(string.format("%d:%02d",mins,secs))
    else
        iTex:SetVertexColor(1,1,1)
        iCDFS:SetText("")
    end
    curY = curY - ICON_SZ - PAD

    -- Cast button (full width minus padding)
    local btn = druidAssignFrame._castBtn
    btn:ClearAllPoints()
    btn:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    btn:SetWidth(frameW - PAD*2)
    btn:SetHeight(BTN_H)
    if cdRem > 0 then
        btn:SetTextColor(0.5,0.5,0.5)
        btn:EnableMouse(false)
        btn:SetAlpha(0.5)
    else
        btn:SetTextColor(0.1,1,0.1)
        btn:EnableMouse(true)
        btn:SetAlpha(1)
    end

    druidAssignFrame:Show()
end


-------------------------------------------------------------------------------
-- RAID LEADER READ-ONLY FRAME
-------------------------------------------------------------------------------
local function UpdateRLFrame()
    if not rlFrame then return end
    for _,c in ipairs(rlFrame.content or {}) do c:Hide() end
    rlFrame.content = {}

    local tmpl = GetActiveTemplate()
    if not tmpl then rlFrame:Hide() return end

    local deadSet = {}
    for _,d in ipairs(deadHealers) do deadSet[d.name] = true end

    -- FIX 6: reorganize display - group by target (tanks first, then groups)
    -- Build ordered list of unique targets: tanks sorted by name, then groups sorted by number
    local tankTargets  = {}   -- {key, display, ttype, tvalue}
    local groupTargets = {}
    local targetSeen   = {}
    for _,h in ipairs(tmpl.healers) do
        for _,t in ipairs(h.targets or {}) do
            local key = (t.type or "").."~"..(t.value or "")
            if not targetSeen[key] then
                targetSeen[key] = true
                local entry = {key=key, display=GetTargetDisplayText(t), ttype=t.type, tvalue=t.value}
                if t.type == TYPE_TANK then
                    table.insert(tankTargets, entry)
                elseif t.type == TYPE_GROUP then
                    table.insert(groupTargets, entry)
                end
            end
        end
    end
    table.sort(tankTargets,  function(a,b) return a.tvalue < b.tvalue end)
    table.sort(groupTargets, function(a,b) return tonumber(a.tvalue) < tonumber(b.tvalue) end)

    local yOff = -30
    local function AddRLRow(text,indent,r,g,b)
        local fs = rlFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        fs:SetPoint("TOPLEFT",rlFrame,"TOPLEFT",10 + (indent or 0)*14,yOff)
        fs:SetTextColor(r or 1,g or 1,b or 1)
        fs:SetText(text)
        yOff = yOff - 16
        table.insert(rlFrame.content, fs)
    end

    -- Helper: find all healers assigned to a given target key
    local function HealersForTarget(targetKey)
        local out = {}
        for _,h in ipairs(tmpl.healers) do
            for _,t in ipairs(h.targets or {}) do
                local k = (t.type or "").."~"..(t.value or "")
                if k == targetKey then
                    table.insert(out, h.name)
                    break
                end
            end
        end
        table.sort(out)
        return out
    end

    -- Render tanks section
    if table.getn(tankTargets) > 0 then
        for _,tgt in ipairs(tankTargets) do
            -- Tank header row: class color from roster if available
            local tr,tg,tb = 0.78,0.61,0.43   -- warrior gold as default tank color
            if tmpl.roster and tmpl.roster[tgt.tvalue] then
                tr,tg,tb = GetClassColor(tmpl.roster[tgt.tvalue].class)
            end
            AddRLRow(tgt.display, 0, tr,tg,tb)
            for _,hname in ipairs(HealersForTarget(tgt.key)) do
                local hr2,hg2,hb2 = 1,1,1
                if tmpl.roster and tmpl.roster[hname] then
                    hr2,hg2,hb2 = GetClassColor(tmpl.roster[hname].class)
                end
                local suffix = deadSet[hname] and "  [DEAD]" or ""
                local dr2,dg2,db2 = deadSet[hname] and 1 or hr2, deadSet[hname] and 0.2 or hg2, deadSet[hname] and 0.2 or hb2
                AddRLRow(hname..suffix, 1, dr2,dg2,db2)
            end
        end
    end

    -- Render groups section
    if table.getn(groupTargets) > 0 then
        for _,tgt in ipairs(groupTargets) do
            AddRLRow(tgt.display, 0, 0.5,0.85,1.0)
            for _,hname in ipairs(HealersForTarget(tgt.key)) do
                local hr2,hg2,hb2 = 1,1,1
                if tmpl.roster and tmpl.roster[hname] then
                    hr2,hg2,hb2 = GetClassColor(tmpl.roster[hname].class)
                end
                local suffix = deadSet[hname] and "  [DEAD]" or ""
                local dr2,dg2,db2 = deadSet[hname] and 1 or hr2, deadSet[hname] and 0.2 or hg2, deadSet[hname] and 0.2 or hb2
                AddRLRow(hname..suffix, 1, dr2,dg2,db2)
            end
        end
    end

    -- Fallback: if no tank/group targets, show plain healer list
    if table.getn(tankTargets) == 0 and table.getn(groupTargets) == 0 then
        for _,h in ipairs(tmpl.healers) do
            local hr2,hg2,hb2 = 1,1,1
            if tmpl.roster and tmpl.roster[h.name] then
                hr2,hg2,hb2 = GetClassColor(tmpl.roster[h.name].class)
            end
            local suffix = deadSet[h.name] and "  [DEAD]" or ""
            AddRLRow(h.name..suffix, 0, hr2,hg2,hb2)
        end
    end

    -- Resize frame to content
    local totalH = math.abs(yOff) + 20
    if totalH < 80 then totalH = 80 end
    rlFrame:SetWidth(220)
    rlFrame:SetHeight(totalH)
    rlFrame:Show()
end

local function CreateRLFrame()
    if not rlFrame then
        rlFrame = CreateFrame("Frame","HealAssignRLFrame",UIParent)
        rlFrame:SetWidth(240)
        rlFrame:SetHeight(200)
        rlFrame:SetPoint("TOPRIGHT",UIParent,"TOPRIGHT",-220,-200)
        rlFrame:SetMovable(true)
        rlFrame:EnableMouse(true)
        rlFrame:RegisterForDrag("LeftButton")
        rlFrame:SetScript("OnDragStart",function() this:StartMoving() end)
        rlFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
        rlFrame:SetFrameStrata("MEDIUM")
        rlFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=8,edgeSize=12,
            insets={left=4,right=4,top=4,bottom=4}
        })
        rlFrame:SetBackdropColor(0.03,0.07,0.03,0.93)
        rlFrame:SetBackdropBorderColor(0.2,0.8,0.2,0.8)
        rlFrame.content = {}

        local title = rlFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        title:SetPoint("TOP",rlFrame,"TOP",0,-10)
        title:SetTextColor(0.2,1,0.2)
        title:SetText("Heal Assignments")

        local closeBtn = CreateFrame("Button",nil,rlFrame,"UIPanelCloseButton")
        closeBtn:SetPoint("TOPRIGHT",rlFrame,"TOPRIGHT",-2,-2)
        closeBtn:SetScript("OnClick",function() rlFrame:Hide() end)
    end
    UpdateRLFrame()
end

-------------------------------------------------------------------------------
-- MAIN FRAME: HEALER GRID
-------------------------------------------------------------------------------
local mainCells = {}

local function GetGridCols(count)
    if count <= 2 then return 2
    elseif count <= 6 then return 3
    else return 4 end
end

local function RebuildMainGrid()
    if not mainFrame then return end

    for _,c in ipairs(mainCells) do c:Hide() end
    mainCells = {}

    local tmpl    = GetActiveTemplate()
    local healers = (tmpl and tmpl.healers) or {}
    local count   = table.getn(healers)

    if mainFrame.noHealerText then mainFrame.noHealerText:Hide() end

    if count == 0 then
        if not mainFrame.noHealerText then
            local fs = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
            fs:SetPoint("CENTER",mainFrame,"CENTER",0,-10)
            fs:SetTextColor(0.5,0.5,0.5)
            fs:SetText("No healers tagged.\nClick 'Raid Roster' and tag healers with [H].")
            mainFrame.noHealerText = fs
        end
        mainFrame.noHealerText:Show()
        mainFrame:SetHeight(160)
        return
    end

    local cols  = GetGridCols(count)
    local rows  = math.ceil(count/cols)
    local cellW = 200
    local padX  = 6
    mainFrame:SetWidth(cols * (cellW + padX) + 20)
    local padY  = 6
    local topY  = -76
    local targetRowH = 18  -- height per target row
    local cellBaseH  = 58  -- name + divider + buttons + padding

    -- Calculate height for each cell based on target count
    local cellHeights = {}
    for i,healer in ipairs(healers) do
        local targetCount = table.getn(healer.targets or {})
        local h = cellBaseH + targetCount * targetRowH
        if h < 90 then h = 90 end
        cellHeights[i] = h
    end

    -- Each row uses the max height of cells in that row
    local rowHeights = {}
    for r=0,rows-1 do
        local maxH = 90
        for c=0,cols-1 do
            local idx = r*cols + c + 1
            if cellHeights[idx] and cellHeights[idx] > maxH then
                maxH = cellHeights[idx]
            end
        end
        rowHeights[r] = maxH
    end

    -- Calculate Y offsets per row
    local rowYOffsets = {}
    local curY = topY
    for r=0,rows-1 do
        rowYOffsets[r] = curY
        curY = curY - rowHeights[r] - padY
    end

    for i,healer in ipairs(healers) do
        local col = math.mod(i-1, cols)
        local row = math.floor((i-1) / cols)
        local cellH = rowHeights[row]

        local cell = CreateFrame("Frame",nil,mainFrame)
        cell:SetWidth(cellW)
        cell:SetHeight(cellH)
        cell:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",
            10 + col*(cellW+padX),
            rowYOffsets[row])
        cell:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=8,edgeSize=8,
            insets={left=3,right=3,top=3,bottom=3}
        })
        cell:SetBackdropColor(0.07,0.07,0.14,0.97)
        cell:SetBackdropBorderColor(0.25,0.35,0.6,0.8)
        table.insert(mainCells,cell)

        -- Healer name
        local hclass = (tmpl.roster[healer.name] and tmpl.roster[healer.name].class) or nil
        local hr,hg,hb = GetClassColor(hclass)
        local nameLabel = cell:CreateFontString(nil,"OVERLAY","GameFontNormal")
        nameLabel:SetPoint("TOP",cell,"TOP",0,-7)
        nameLabel:SetTextColor(hr,hg,hb)
        nameLabel:SetText(healer.name)

        local div = cell:CreateTexture(nil,"ARTWORK")
        div:SetHeight(1)
        div:SetPoint("TOPLEFT",cell,"TOPLEFT",5,-22)
        div:SetPoint("TOPRIGHT",cell,"TOPRIGHT",-5,-22)
        div:SetTexture(hr,hg,hb,0.35)

        -- Target rows area
        local targetArea = CreateFrame("Frame",nil,cell)
        targetArea:SetPoint("TOPLEFT",cell,"TOPLEFT",4,-26)
        targetArea:SetPoint("TOPRIGHT",cell,"TOPRIGHT",-4,-26)
        targetArea:SetHeight(cellH - 60)
        cell.targetArea  = targetArea
        cell.targetRows  = {}

        local capturedIdx = i

        local function RebuildTargetRows()
            for _,r in ipairs(cell.targetRows) do r:Hide() end
            cell.targetRows = {}

            local h = tmpl.healers[capturedIdx]
            if not h then return end

            local ty = 0
            for tidx,target in ipairs(h.targets) do
                local tcR,tcG,tcB = 0.88,0.88,0.88
                if target.type == TYPE_TANK then
                    if tmpl.roster and tmpl.roster[target.value] then
                        tcR,tcG,tcB = GetClassColor(tmpl.roster[target.value].class)
                    end
                elseif target.type == TYPE_GROUP  then tcR,tcG,tcB = 0.5,0.85,1.0
                elseif target.type == TYPE_CUSTOM then tcR,tcG,tcB = 0.9,0.6,1.0
                end

                -- Row frame: full width minus room for delete button
                local trow = CreateFrame("Frame",nil,targetArea)
                trow:SetHeight(17)
                trow:SetPoint("TOPLEFT",targetArea,"TOPLEFT",0,ty)
                trow:SetPoint("TOPRIGHT",targetArea,"TOPRIGHT",-20,ty)
                table.insert(cell.targetRows,trow)

                local tLabel = trow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                tLabel:SetPoint("LEFT",trow,"LEFT",4,0)
                tLabel:SetPoint("RIGHT",trow,"RIGHT",0,0)
                tLabel:SetJustifyH("LEFT")
                tLabel:SetTextColor(tcR,tcG,tcB)
                tLabel:SetText(GetTargetDisplayText(target))

                -- Delete button anchored to RIGHT of targetArea, same y as trow
                local capturedTidx = tidx
                local xBtn = CreateFrame("Button",nil,cell,"UIPanelButtonTemplate")
                xBtn:SetWidth(16)
                xBtn:SetHeight(16)
                xBtn:SetPoint("TOPRIGHT",cell,"TOPRIGHT",-3,-25-(tidx-1)*18)
                xBtn:SetText("x")
                xBtn:SetScript("OnClick",function()
                    table.remove(tmpl.healers[capturedIdx].targets, capturedTidx)
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end)
                table.insert(cell.targetRows,xBtn)

                ty = ty - 18
            end
        end

        cell.RebuildTargetRows = RebuildTargetRows
        RebuildTargetRows()

        -- 4 add-target buttons at bottom
        local btnH   = 18
        local btnY   = 6   -- from bottom
        local bW     = math.floor((cellW - 12) / 3)

        local capturedCell = cell

        local function MakeAddBtn(label, xOffset, onClick)
            local btn = CreateFrame("Button",nil,cell,"UIPanelButtonTemplate")
            btn:SetWidth(bW)
            btn:SetHeight(btnH)
            btn:SetPoint("BOTTOMLEFT",cell,"BOTTOMLEFT",6+xOffset,btnY)
            btn:SetText(label)
            btn:SetScript("OnClick",onClick)
            return btn
        end

        -- Tank
        MakeAddBtn("Tank", 0, function()
            local items = {}
            if tmpl and tmpl.roster then
                local tNames = {}
                for pname,pdata in pairs(tmpl.roster) do
                    if pdata.tagT then table.insert(tNames,pname) end
                end
                table.sort(tNames)
                for _,pname in ipairs(tNames) do
                    local pdata = tmpl.roster[pname]
                    local r2,g2,b2 = GetClassColor(pdata.class)
                    table.insert(items,{text=pname,r=r2,g=g2,b=b2,targetType=TYPE_TANK,targetValue=pname})
                end
            end
            if table.getn(items)==0 then
                table.insert(items,{text="(No tanks tagged)",r=0.5,g=0.5,b=0.5})
            end
            local anchor = this
            ShowDropdown(anchor, items, function(item)
                if item.targetType then
                    table.insert(tmpl.healers[capturedIdx].targets,{type=item.targetType,value=item.targetValue})
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end, 160)
        end)

        -- Group
        MakeAddBtn("Group", bW+2, function()
            local items = {}
            for g=1,8 do table.insert(items,{text="Group "..g,targetType=TYPE_GROUP,targetValue=tostring(g)}) end
            local anchor = this
            ShowDropdown(anchor, items, function(item)
                if item.targetType then
                    table.insert(tmpl.healers[capturedIdx].targets,{type=item.targetType,value=item.targetValue})
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end, 100)
        end)

        -- Custom
        MakeAddBtn("Custom", (bW+2)*2, function()
            local items = {}
            if HealAssignDB and HealAssignDB.options and HealAssignDB.options.customTargets then
                for _,ct in ipairs(HealAssignDB.options.customTargets) do
                    table.insert(items,{text=ct,targetType=TYPE_CUSTOM,targetValue=ct})
                end
            end
            if table.getn(items)==0 then
                table.insert(items,{text="(No custom targets)",r=0.5,g=0.5,b=0.5})
            end
            local anchor = this
            ShowDropdown(anchor, items, function(item)
                if item.targetType then
                    table.insert(tmpl.healers[capturedIdx].targets,{type=item.targetType,value=item.targetValue})
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end, 160)
        end)
    end

    -- Resize main frame height to fit grid
    -- Total height = sum of all row heights + padding
    local neededH = math.abs(topY) + 20
    for r=0,rows-1 do neededH = neededH + rowHeights[r] + padY end
    if neededH < 200 then neededH = 200 end
    mainFrame:SetHeight(neededH)
end

-------------------------------------------------------------------------------
-- RAID ROSTER FRAME
-------------------------------------------------------------------------------
local rosterRowWidgets = {}

local function RebuildRosterRows()
    if not rosterFrame then return end

    for _,r in ipairs(rosterRowWidgets) do r:Hide() end
    rosterRowWidgets = {}

    local tmpl = GetActiveTemplate()
    if not tmpl then return end

    local members = GetRaidMembers()
    -- Build lookup of current raid members
    local currentMembers = {}
    for _,m in ipairs(members) do
        currentMembers[m.name] = m
    end
    -- Remove players no longer in raid (keeps roster clean between raids)
    local toRemove = {}
    for pname,_ in pairs(tmpl.roster) do
        if not currentMembers[pname] then
            table.insert(toRemove, pname)
        end
    end
    for _,pname in ipairs(toRemove) do
        tmpl.roster[pname] = nil
    end
    -- Add new members, update existing
    for _,m in ipairs(members) do
        if not tmpl.roster[m.name] then
            tmpl.roster[m.name] = {class=m.class, subgroup=m.subgroup or 1}
        else
            tmpl.roster[m.name].class    = m.class
            tmpl.roster[m.name].subgroup = m.subgroup or tmpl.roster[m.name].subgroup or 1
        end
    end
    -- Also sync healers list - remove healers no longer in raid
    if tmpl.healers then
        local newHealers = {}
        for _,h in ipairs(tmpl.healers) do
            if currentMembers[h.name] then
                table.insert(newHealers, h)
            end
        end
        tmpl.healers = newHealers
    end

    -- Build groups 1-8
    local groups = {}
    for g=1,8 do groups[g] = {} end
    for pname,pdata in pairs(tmpl.roster) do
        local sg = pdata.subgroup or 1
        if sg < 1 then sg = 1 end
        if sg > 8 then sg = 8 end
        table.insert(groups[sg], {name=pname, class=pdata.class, tagT=pdata.tagT, tagH=pdata.tagH, tagV=pdata.tagV, subgroup=sg})
    end
    for g=1,8 do
        table.sort(groups[g], function(a,b) return a.name < b.name end)
    end

    local sc      = rosterFrame.scrollChild
    -- Grid: 2 groups per row, 4 rows = 8 groups
    local cols      = 2
    local groupW    = 170  -- 70px name + 3x22px buttons + padding
    local groupPadX = 10
    local rowH      = 0    -- calculated per group
    local playerH   = 16   -- height per player row
    local headerH   = 18   -- group header height
    local groupPadY = 12

    -- Calculate max players per group for layout
    local maxPerGroup = 0
    for g=1,8 do
        if table.getn(groups[g]) > maxPerGroup then
            maxPerGroup = table.getn(groups[g])
        end
    end
    local groupH = headerH + maxPerGroup * playerH + 8

    local totalH = 0
    local rows = math.ceil(8 / cols)

    for gIdx=1,8 do
        local col  = math.mod(gIdx-1, cols)
        local grow = math.floor((gIdx-1) / cols)
        local gx   = 6 + col * (groupW + groupPadX)
        local gy   = -(6 + grow * (groupH + groupPadY))

        -- Group container
        local gFrame = CreateFrame("Frame",nil,sc)
        gFrame:SetWidth(groupW)
        gFrame:SetHeight(groupH)
        gFrame:SetPoint("TOPLEFT",sc,"TOPLEFT",gx,gy)
        gFrame:SetBackdrop({
            bgFile   = "Interface\DialogFrame\UI-DialogBox-Background",
            edgeFile = "Interface\Tooltips\UI-Tooltip-Border",
            tile=true,tileSize=8,edgeSize=8,
            insets={left=3,right=3,top=3,bottom=3}
        })
        gFrame:SetBackdropColor(0.07,0.07,0.14,0.95)
        gFrame:SetBackdropBorderColor(0.25,0.35,0.6,0.7)
        table.insert(rosterRowWidgets,gFrame)

        -- Group header
        local gLabel = gFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        gLabel:SetPoint("TOPLEFT",gFrame,"TOPLEFT",5,-4)
        gLabel:SetTextColor(0.7,0.7,0.7)
        gLabel:SetText("Group "..gIdx)

        -- Players
        local py = -headerH
        for _,p in ipairs(groups[gIdx]) do
            local pRow = CreateFrame("Frame",nil,gFrame)
            pRow:SetHeight(playerH)
            pRow:SetPoint("TOPLEFT",gFrame,"TOPLEFT",4,py)
            pRow:SetPoint("TOPRIGHT",gFrame,"TOPRIGHT",-4,py)
            table.insert(rosterRowWidgets,pRow)

            local r,g2,b = GetClassColor(p.class)

            local capturedName = p.name

            -- T button first (right-anchored)
            local tBtn = CreateFrame("Button",nil,pRow,"UIPanelButtonTemplate")
            tBtn:SetWidth(22)
            tBtn:SetHeight(14)
            tBtn:SetText("T")
            if p.tagT then tBtn:SetTextColor(1,0.85,0)
            else tBtn:SetTextColor(0.35,0.35,0.35) end

            local hBtn = CreateFrame("Button",nil,pRow,"UIPanelButtonTemplate")
            hBtn:SetWidth(22)
            hBtn:SetHeight(14)
            hBtn:SetText("H")
            if p.tagH then hBtn:SetTextColor(0.3,1,0.3)
            else hBtn:SetTextColor(0.35,0.35,0.35) end

            local vBtn = CreateFrame("Button",nil,pRow,"UIPanelButtonTemplate")
            vBtn:SetWidth(22)
            vBtn:SetHeight(14)
            vBtn:SetText("V")
            if p.tagV then vBtn:SetTextColor(0.4,0.9,1)
            else vBtn:SetTextColor(0.35,0.35,0.35) end

            local nameLabel = pRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            nameLabel:SetPoint("LEFT",pRow,"LEFT",4,0)
            nameLabel:SetWidth(72)
            nameLabel:SetJustifyH("LEFT")
            nameLabel:SetTextColor(r,g2,b)
            nameLabel:SetText(p.name)

            tBtn:SetPoint("LEFT",pRow,"LEFT",78,0)
            hBtn:SetPoint("LEFT",tBtn,"RIGHT",2,0)
            vBtn:SetPoint("LEFT",hBtn,"RIGHT",2,0)

            tBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedName]
                if entry then
                    entry.tagT = not entry.tagT
                    if entry.tagT then entry.tagH = false end  -- T excludes H
                    SyncHealersFromRoster(tmpl)
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end)

            hBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedName]
                if entry then
                    entry.tagH = not entry.tagH
                    if entry.tagH then entry.tagT = false end  -- H excludes T
                    SyncHealersFromRoster(tmpl)
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end)

            local capturedVName = p.name
            vBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedVName]
                if entry then
                    entry.tagV = not entry.tagV
                    RebuildRosterRows()
                    UpdateAssignFrame()
                end
            end)

            py = py - playerH
        end

        -- Track total height
        local thisRowBottom = 6 + grow*(groupH+groupPadY) + groupH
        if thisRowBottom > totalH then totalH = thisRowBottom end
    end

    sc:SetHeight(totalH + 20)
end

local function CreateRosterFrame()
    if rosterFrame then
        RebuildRosterRows()
        rosterFrame:Raise()
        rosterFrame:Show()
        PushWindow(rosterFrame)
        return
    end

    rosterFrame = CreateFrame("Frame","HealAssignRosterFrame",UIParent)
    rosterFrame:SetWidth(360)
    rosterFrame:SetHeight(520)
    rosterFrame:SetPoint("TOPLEFT",mainFrame,"TOPRIGHT",10,0)
    rosterFrame:SetMovable(true)
    rosterFrame:EnableMouse(true)
    rosterFrame:RegisterForDrag("LeftButton")
    rosterFrame:SetScript("OnDragStart",function() this:StartMoving() end)
    rosterFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    rosterFrame:SetFrameStrata("DIALOG")
    rosterFrame:SetFrameLevel(10)
    rosterFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=8,edgeSize=16,
        insets={left=4,right=4,top=4,bottom=4}
    })
    local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    rosterFrame:SetBackdropColor(0.04,0.04,0.1,_alpha)

    local title = rosterFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",rosterFrame,"TOP",0,-12)
    title:SetTextColor(0.4,0.8,1)
    title:SetText("Raid Roster")

    -- Headers
    -- No column headers needed - groups have their own labels

    local closeBtn = CreateFrame("Button",nil,rosterFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",rosterFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function() rosterFrame:Hide() end)
    HookFrameHide(rosterFrame)

    local resetRosterBtn = CreateFrame("Button",nil,rosterFrame,"UIPanelButtonTemplate")
    resetRosterBtn:SetWidth(70)
    resetRosterBtn:SetHeight(20)
    resetRosterBtn:SetPoint("BOTTOMLEFT",rosterFrame,"BOTTOMLEFT",10,10)
    resetRosterBtn:SetText("Reset Tags")
    resetRosterBtn:SetScript("OnClick",function()
        local tmpl = GetActiveTemplate()
        if tmpl and tmpl.roster then
            for _,pdata in pairs(tmpl.roster) do
                pdata.tagT = nil
                pdata.tagH = nil
                pdata.tagV = nil
            end
            SyncHealersFromRoster(tmpl)
            RebuildRosterRows()
            RebuildMainGrid()
            UpdateAssignFrame()
        end
    end)

    local sf = CreateFrame("ScrollFrame","HealAssignRosterScroll",rosterFrame)
    sf:SetPoint("TOPLEFT",    rosterFrame,"TOPLEFT",   8,-42)
    sf:SetPoint("BOTTOMRIGHT",rosterFrame,"BOTTOMRIGHT",-14,36)
    rosterFrame.scrollFrame = sf

    local sc = CreateFrame("Frame","HealAssignRosterScrollChild",sf)
    sc:SetWidth(336)
    sc:SetHeight(800)
    sf:SetScrollChild(sc)
    rosterFrame.scrollChild = sc

    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel",function()
        local cur = sf:GetVerticalScroll()
        local max = sf:GetVerticalScrollRange()
        local delta = arg1 * -20
        local new = cur + delta
        if new < 0 then new = 0 end
        if new > max then new = max end
        sf:SetVerticalScroll(new)
    end)

    RebuildRosterRows()
    rosterFrame:Raise()
    rosterFrame:Show()
    PushWindow(rosterFrame)
end

-------------------------------------------------------------------------------
-- OPTIONS FRAME
-------------------------------------------------------------------------------
function CreateOptionsFrame()
    if optionsFrame then optionsFrame:Raise() optionsFrame:Show() PushWindow(optionsFrame) return end

    optionsFrame = CreateFrame("Frame","HealAssignOptionsFrame",UIParent)
    optionsFrame:SetWidth(360)
    optionsFrame:SetHeight(480)
    optionsFrame:SetPoint("CENTER",UIParent,"CENTER")
    optionsFrame:SetMovable(true)
    optionsFrame:EnableMouse(true)
    optionsFrame:RegisterForDrag("LeftButton")
    optionsFrame:SetScript("OnDragStart",function() this:StartMoving() end)
    optionsFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    optionsFrame:SetFrameStrata("DIALOG")
    optionsFrame:SetFrameLevel(20)
    optionsFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=8,edgeSize=16,
        insets={left=4,right=4,top=4,bottom=4}
    })
    local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    optionsFrame:SetBackdropColor(0.04,0.04,0.1,_alpha)

    local title = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",optionsFrame,"TOP",0,-12)
    title:SetTextColor(0.4,0.8,1)
    title:SetText("HealAssign Options")

    local closeBtn = CreateFrame("Button",nil,optionsFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",optionsFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function() optionsFrame:Hide() end)
    HookFrameHide(optionsFrame)

    local y = -44

    -- Font size
    local secFont = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    secFont:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    secFont:SetTextColor(1,0.8,0.2)
    secFont:SetText("Assignments Font Size:")
    y = y-30

    local fontSlider = CreateFrame("Slider","HealAssignFontSlider",optionsFrame,"OptionsSliderTemplate")
    fontSlider:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",16,y)
    fontSlider:SetWidth(200)
    fontSlider:SetMinMaxValues(8,24)
    fontSlider:SetValueStep(1)
    fontSlider:SetValue(HealAssignDB.options.fontSize or 12)
    getglobal(fontSlider:GetName().."Text"):SetText("Size: "..(HealAssignDB.options.fontSize or 12))
    getglobal(fontSlider:GetName().."Low"):SetText("8")
    getglobal(fontSlider:GetName().."High"):SetText("24")
    fontSlider:SetScript("OnValueChanged",function()
        local val = math.floor(this:GetValue())
        HealAssignDB.options.fontSize = val
        getglobal(this:GetName().."Text"):SetText("Size: "..val)
        UpdateAssignFrame()
        UpdateDruidAssignFrame()
    end)
    y = y-44

    -- Window opacity
    local secAlpha = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    secAlpha:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    secAlpha:SetTextColor(1,0.8,0.2)
    secAlpha:SetText("Window Opacity:")
    y = y-30

    local alphaSlider = CreateFrame("Slider","HealAssignAlphaSlider",optionsFrame,"OptionsSliderTemplate")
    alphaSlider:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",16,y)
    alphaSlider:SetWidth(200)
    alphaSlider:SetMinMaxValues(0.3,1.0)
    alphaSlider:SetValueStep(0.05)
    local curAlpha = (HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    alphaSlider:SetValue(curAlpha)
    getglobal(alphaSlider:GetName().."Text"):SetText(math.floor(curAlpha*100).."%")
    getglobal(alphaSlider:GetName().."Low"):SetText("30%")
    getglobal(alphaSlider:GetName().."High"):SetText("100%")
    alphaSlider:SetScript("OnValueChanged",function()
        local val = this:GetValue()
        -- round to 0.05
        val = math.floor(val * 20 + 0.5) / 20
        HealAssignDB.options.windowAlpha = val
        getglobal(this:GetName().."Text"):SetText(math.floor(val*100).."%")
        ApplyWindowAlpha(val)
    end)
    y = y-44

    -- Show assign frame
    local showCB = CreateFrame("CheckButton","HealAssignShowCB",optionsFrame,"UICheckButtonTemplate")
    showCB:SetWidth(20)
    showCB:SetHeight(20)
    showCB:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    showCB:SetChecked(HealAssignDB.options.showAssignFrame)
    showCB:SetScript("OnClick",function()
        HealAssignDB.options.showAssignFrame = this:GetChecked()
        if assignFrame then
            local inRaid = GetNumRaidMembers() > 0
            if inRaid or HealAssignDB.options.showAssignFrame then
                UpdateAssignFrame()
                UpdateDruidAssignFrame()
            else
                assignFrame:Hide()
            end
        end
    end)
    local showLbl = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    showLbl:SetPoint("LEFT",showCB,"RIGHT",4,0)
    showLbl:SetText("Show Assignments outside raid")
    y = y-36

    -- Custom targets
    local sec3 = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    sec3:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    sec3:SetTextColor(1,0.8,0.2)
    sec3:SetText("Custom Assignment Targets:")
    y = y-18

    local customNote = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    customNote:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    customNote:SetTextColor(0.55,0.55,0.55)
    customNote:SetText("e.g. 'Main Tank', 'OT', 'Skull Target'")
    y = y-22

    local customEdit = CreateFrame("EditBox","HealAssignCustomEdit",optionsFrame,"InputBoxTemplate")
    customEdit:SetWidth(210)
    customEdit:SetHeight(20)
    customEdit:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    customEdit:SetAutoFocus(false)
    customEdit:SetMaxLetters(64)
    customEdit:SetText("")

    local addBtn = CreateFrame("Button",nil,optionsFrame,"UIPanelButtonTemplate")
    addBtn:SetWidth(60)
    addBtn:SetHeight(20)
    addBtn:SetPoint("LEFT",customEdit,"RIGHT",5,0)
    addBtn:SetText("Add")
    y = y-28

    local clf = CreateFrame("Frame",nil,optionsFrame)
    clf:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    clf:SetWidth(330)
    clf:SetHeight(120)
    clf.rows = {}
    optionsFrame.clf = clf

    local function RefreshCustomList()
        for _,r in ipairs(clf.rows) do r:Hide() end
        clf.rows = {}
        for i,ct in ipairs(HealAssignDB.options.customTargets) do
            local row = CreateFrame("Frame",nil,clf)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT",clf,"TOPLEFT",0,-(i-1)*18)
            row:SetWidth(330)
            table.insert(clf.rows,row)

            local lbl = row:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
            lbl:SetPoint("LEFT",row,"LEFT",2,0)
            lbl:SetTextColor(0.85,0.85,0.85)
            lbl:SetText(ct)

            local delBtn = CreateFrame("Button",nil,row,"UIPanelButtonTemplate")
            delBtn:SetWidth(22)
            delBtn:SetHeight(16)
            delBtn:SetPoint("RIGHT",row,"RIGHT",-2,0)
            delBtn:SetText("X")
            local idx = i
            delBtn:SetScript("OnClick",function()
                table.remove(HealAssignDB.options.customTargets,idx)
                RefreshCustomList()
            end)
        end
    end

    addBtn:SetScript("OnClick",function()
        local txt = customEdit:GetText()
        if txt and txt ~= "" then
            table.insert(HealAssignDB.options.customTargets,txt)
            customEdit:SetText("")
            RefreshCustomList()
        end
    end)

    RefreshCustomList()
    optionsFrame:Raise()
    optionsFrame:Show()
    PushWindow(optionsFrame)
end

-------------------------------------------------------------------------------
-- MAIN FRAME
-------------------------------------------------------------------------------
local function CreateMainFrame()
    if mainFrame then
        mainFrame:Show()
        RebuildMainGrid()
        return
    end

    mainFrame = CreateFrame("Frame","HealAssignMainFrame",UIParent)
    mainFrame:SetWidth(560)
    mainFrame:SetHeight(300)
    mainFrame:SetPoint("CENTER",UIParent,"CENTER")
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart",function() this:StartMoving() end)
    mainFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    mainFrame:SetFrameStrata("HIGH")
    mainFrame:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=8,edgeSize=16,
        insets={left=4,right=4,top=4,bottom=4}
    })
    local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    mainFrame:SetBackdropColor(0.04,0.04,0.1,_alpha)
    mainFrame:SetBackdropBorderColor(0.3,0.5,0.8,0.9)

    local title = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",mainFrame,"TOP",0,-10)
    title:SetTextColor(0.4,0.8,1)
    title:SetText("HealAssign  v"..ADDON_VERSION)

    local closeBtn = CreateFrame("Button",nil,mainFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",mainFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function()
        mainFrame:Hide()
        CloseDropdown()
        if rosterFrame then rosterFrame:Hide() end
    end)
    HookFrameHide(mainFrame)

    -- Template controls row
    local nameLabel = mainFrame:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
    nameLabel:SetPoint("TOPLEFT",mainFrame,"TOPLEFT",10,-34)
    nameLabel:SetTextColor(0.6,0.6,0.6)
    nameLabel:SetText("Template:")

    local nameEdit = CreateFrame("EditBox","HealAssignNameEdit",mainFrame,"InputBoxTemplate")
    nameEdit:SetWidth(100)
    nameEdit:SetHeight(20)
    nameEdit:SetPoint("LEFT",nameLabel,"RIGHT",4,0)
    nameEdit:SetAutoFocus(false)
    nameEdit:SetMaxLetters(48)
    if currentTemplate then nameEdit:SetText(currentTemplate.name or "") end
    mainFrame.nameEdit = nameEdit

    local function MakeTopBtn(label, parent, onClick)
        local btn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
        btn:SetWidth(46)
        btn:SetHeight(20)
        btn:SetPoint("LEFT",parent,"RIGHT",2,0)
        btn:SetText(label)
        btn:SetScript("OnClick",onClick)
        return btn
    end

    local newBtn = MakeTopBtn("New", nameEdit, function()
        if IsCurrentTemplateDirty() then
            StaticPopup_Show("HEALASSIGN_SAVE_BEFORE_NEW")
        else
            _DoNewTemplate()
        end
    end)

    local saveBtn = MakeTopBtn("Save", newBtn, function()
        local name = nameEdit:GetText()
        if not name or name == "" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Enter a template name first.")
            return
        end
        if not currentTemplate then currentTemplate = NewTemplate(name) end
        currentTemplate.name = name
        HealAssignDB.templates[name] = DeepCopy(currentTemplate)
        HealAssignDB.activeTemplate  = name
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Saved '"..name.."'.")
    end)

    local loadBtn = MakeTopBtn("Load", saveBtn, function()
        local items = {}
        for tname,_ in pairs(HealAssignDB.templates) do
            table.insert(items,{text=tname,tname=tname})
        end
        table.sort(items,function(a,b) return a.text < b.text end)
        if table.getn(items)==0 then table.insert(items,{text="(No saved templates)",r=0.5,g=0.5,b=0.5}) end
        ShowDropdown(this, items, function(item)
            if item.tname then
                currentTemplate = DeepCopy(HealAssignDB.templates[item.tname])
                HealAssignDB.activeTemplate = item.tname
                nameEdit:SetText(currentTemplate.name)
                RebuildMainGrid()
                UpdateAssignFrame()
            end
        end, 180)
    end)



    local delBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    delBtn:SetWidth(46)
    delBtn:SetHeight(20)
    delBtn:SetPoint("LEFT",loadBtn,"RIGHT",3,0)
    delBtn:SetText("Delete")
    delBtn:SetScript("OnClick",function()
        local name = nameEdit:GetText()
        if name and name ~= "" and HealAssignDB.templates[name] then
            StaticPopup_Show("HEALASSIGN_CONFIRM_DELETE", name)
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r No saved template with that name.")
        end
    end)

    local resetBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    resetBtn:SetWidth(46)
    resetBtn:SetHeight(20)
    resetBtn:SetPoint("LEFT",delBtn,"RIGHT",3,0)
    resetBtn:SetText("Reset")
    resetBtn:SetScript("OnClick",function()
        local tmpl = GetActiveTemplate()
        if tmpl then
            for _,h in ipairs(tmpl.healers) do h.targets = {} end
            RebuildMainGrid()
            UpdateAssignFrame()
        end
    end)

    -- Store nameEdit ref for StaticPopup callbacks
    _nameEditRef = nameEdit
    InitStaticPopups()

    -- Tooltips row 1
    AddTooltip(newBtn,    "Create a new empty template. Prompts to save if unsaved changes exist.")
    AddTooltip(saveBtn,   "Save current template to database.")
    AddTooltip(loadBtn,   "Load a saved template. Click again to close.")
    AddTooltip(delBtn,    "Permanently delete the current saved template.")
    AddTooltip(resetBtn,  "Clear all healer assignments but keep the template.")

    -- Row 2
    local rosterBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    rosterBtn:SetWidth(76)
    rosterBtn:SetHeight(20)
    rosterBtn:SetPoint("TOPLEFT",newBtn,"BOTTOMLEFT",0,-4)
    rosterBtn:SetText("Raid Roster")
    rosterBtn:SetScript("OnClick",function()
        if rosterFrame and rosterFrame:IsShown() then rosterFrame:Hide()
        else CreateRosterFrame() end
    end)

    -- FIX 4: button order: Roster -> Innervate -> Sync -> Options
    local innBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    innBtn:SetWidth(64)
    innBtn:SetHeight(20)
    innBtn:SetPoint("LEFT",rosterBtn,"RIGHT",2,0)
    innBtn:SetText("Innervate")
    innBtn:SetScript("OnClick",function()
        if innervateFrame and innervateFrame:IsShown() then innervateFrame:Hide()
        else CreateInnervateFrame() end
    end)

    local syncBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    syncBtn:SetWidth(46)
    syncBtn:SetHeight(20)
    syncBtn:SetPoint("LEFT",innBtn,"RIGHT",2,0)
    syncBtn:SetText("Sync")
    syncBtn:SetScript("OnClick",function() HealAssign_SyncTemplate() end)

    local optBtn = CreateFrame("Button",nil,mainFrame,"UIPanelButtonTemplate")
    optBtn:SetWidth(54)
    optBtn:SetHeight(20)
    optBtn:SetPoint("LEFT",syncBtn,"RIGHT",2,0)
    optBtn:SetText("Options")
    optBtn:SetScript("OnClick",function()
        if optionsFrame and optionsFrame:IsShown() then optionsFrame:Hide()
        else CreateOptionsFrame() end
    end)

    AddTooltip(rosterBtn, "Open Raid Roster to tag tanks, healers and viewers.")
    AddTooltip(innBtn,    "Manage Innervate assignments for druids.")
    AddTooltip(syncBtn,   "Broadcast current template to all raid members with the addon.")
    AddTooltip(optBtn,    "Open addon options: font size, opacity, assign frame settings.")

    RebuildMainGrid()
    PushWindow(mainFrame)
end

-- Wire up forward references now that all functions are defined
_RebuildMainGrid       = RebuildMainGrid
_UpdateAssignFrame      = UpdateAssignFrame
_UpdateDruidAssignFrame = UpdateDruidAssignFrame
_SyncHealersFromRoster = SyncHealersFromRoster
_RebuildRosterRows     = RebuildRosterRows

-------------------------------------------------------------------------------
-- SYNC / COMMUNICATION
-------------------------------------------------------------------------------
local incomingChunks = {}
local CHUNK_SIZE = 200

function HealAssign_SyncTemplate()
    local tmpl = GetActiveTemplate()
    if not tmpl then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r No active template to sync.")
        return
    end

    local numRaid  = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()
    local channel
    if numRaid and numRaid > 0 then channel = "RAID"
    elseif numParty and numParty > 0 then channel = "PARTY"
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Not in a group.")
        return
    end

    local data = Serialize(tmpl)
    data = string.gsub(data,"%%","{perc}")
    data = string.gsub(data,"\\","{bs}")
    data = string.gsub(data,"|","{pipe}")

    local chunks = {}
    local len = string.len(data)
    local i = 1
    while i <= len do
        table.insert(chunks, string.sub(data,i,i+CHUNK_SIZE-1))
        i = i+CHUNK_SIZE
    end
    if table.getn(chunks)==0 then table.insert(chunks,"") end

    local total = table.getn(chunks)
    for ci,chunk in ipairs(chunks) do
        if channel then pcall(SendAddonMessage, COMM_PREFIX,"S;"..ci..";"..total..";"..chunk, channel) end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Synced '"..tmpl.name.."' ("..total.." chunk(s)).")
end

local function HandleAddonMessage(prefix,msg,channel,sender)
    if prefix ~= COMM_PREFIX then return end
    local myName = UnitName("player")
    if sender == myName then return end

    -- Innervate cast broadcast: INN_CAST;druidName
    local _,_,innCaster = string.find(msg,"^INN_CAST;(.+)$")
    if innCaster then
        innCD[innCaster] = GetTime()
        UpdateAssignFrame()
            return
    end

    -- Innervate assignments: INN_ASSIGN;druid1=healer1|druid2=healer2
    local _,_,innData = string.find(msg,"^INN_ASSIGN;(.*)$")
    if innData then
        local tmpl2 = GetActiveTemplate()
        if tmpl2 then
            tmpl2.innervate = {}
            for pair in string.gfind(innData,"([^|]+)") do
                local _,_,d,h = string.find(pair,"^([^=]+)=(.+)$")
                if d and h then tmpl2.innervate[d] = h end
            end
            UpdateAssignFrame()
        end
        return
    end

    -- Death signal
    local _,_,deadName = string.find(msg,"^DEAD;(.+)$")
    if deadName then
        local tmpl = GetActiveTemplate()
        if tmpl then
            for _,h in ipairs(tmpl.healers) do
                if h.name == deadName then
                    TriggerHealerDeath(deadName, h.targets)
                    UpdateAssignFrame()
                    if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
                    break
                end
            end
        end
        return
    end

    -- Chunk
    local _,_,cIdx,tChunks,d = string.find(msg,"^S;(%d+);(%d+);(.*)$")
    if not cIdx then return end

    local chunkIdx    = tonumber(cIdx)
    local totalChunks = tonumber(tChunks)

    if not incomingChunks[sender] or incomingChunks[sender].total ~= totalChunks then
        incomingChunks[sender] = {total=totalChunks, chunks={}}
    end
    incomingChunks[sender].chunks[chunkIdx] = d or ""

    local allReceived = true
    for i=1,totalChunks do
        if not incomingChunks[sender].chunks[i] then allReceived=false break end
    end

    if allReceived then
        local fullData = ""
        for i=1,totalChunks do fullData = fullData..incomingChunks[sender].chunks[i] end
        incomingChunks[sender] = nil

        fullData = string.gsub(fullData,"{perc}","%%")
        fullData = string.gsub(fullData,"{bs}","\\")
        fullData = string.gsub(fullData,"{pipe}","|")

        local tmpl = Deserialize(fullData)
        if tmpl then
            HealAssignDB.templates[tmpl.name] = tmpl
            HealAssignDB.activeTemplate = tmpl.name
            currentTemplate = tmpl
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Received '"..tmpl.name.."' from "..sender)

            if mainFrame and mainFrame:IsShown() then RebuildMainGrid() end
            UpdateAssignFrame()

            if IsRaidLeader() then CreateRLFrame() end
        end
    end
end

-------------------------------------------------------------------------------
-- DEATH DETECTION
-------------------------------------------------------------------------------
local deathFrame = CreateFrame("Frame","HealAssignDeathFrame")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
deathFrame:SetScript("OnEvent",function()
    local msg = arg1
    if not msg then return end

    local deadName = nil
    if msg == "You die." then
        deadName = UnitName("player")
    else
        local _,_,cap = string.find(msg,"^(.+) dies%.$")
        if cap then deadName = cap end
    end
    if not deadName then return end

    local tmpl = GetActiveTemplate()
    if not tmpl then return end

    local numRaid  = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()
    if (not numRaid or numRaid == 0) and (not numParty or numParty == 0) then return end

    for _,h in ipairs(tmpl.healers) do
        if h.name == deadName then
            local chan
            if numRaid and numRaid > 0 then chan = "RAID"
            elseif numParty and numParty > 0 then chan = "PARTY" end
            if chan then pcall(SendAddonMessage, COMM_PREFIX,"DEAD;"..deadName, chan) end

            TriggerHealerDeath(deadName, h.targets)
            UpdateAssignFrame()
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
            return
        end
    end
end)

-- Ticker: only expire death alerts by time (15 sec)
local alertTicker = CreateFrame("Frame","HealAssignTicker")
local alertTickerElapsed = 0
alertTicker:SetScript("OnUpdate",function()
    alertTickerElapsed = alertTickerElapsed + arg1
    if alertTickerElapsed >= 2 then
        alertTickerElapsed = 0
        if table.getn(deadHealers) > 0 then
            RefreshAlertFrame()
            UpdateAssignFrame()
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
        end
    end
end)

-- Resurrection detection via combat log
local rezFrame = CreateFrame("Frame","HealAssignRezFrame")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_RESURRECT")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_CASTOTHER")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_OTHER_CASTOTHER")

-- Innervate detection via combat log messages
-- "X gains Innervate." -> CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS
-- "You gain Innervate." -> CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS
local function INN_ProcessInnervate(msg2)
    local tmpl = GetActiveTemplate()
    if not tmpl or not tmpl.innervate then return end
    local receiverName = nil
    local _,_,r1 = string.find(msg2, "^(.+) gains Innervate")
    if r1 then receiverName = r1 end
    if string.find(msg2, "^You gain Innervate") then
        receiverName = UnitName("player")
    end
    if not receiverName then return end
    local casterDruid = nil
    for dname,hname in pairs(tmpl.innervate) do
        if hname == receiverName then casterDruid = dname break end
    end
    if not casterDruid then return end
    innCD[casterDruid] = GetTime()
    if HealAssignDB and HealAssignDB.innCD then
        HealAssignDB.innCD[casterDruid] = {t = GetTime(), rem = INN_CD_FULL}
    end
    INN_ALERT_SHOWN[casterDruid] = nil
    UpdateAssignFrame()
    INN_BroadcastCast(casterDruid)
end
local innSpellFrame = CreateFrame("Frame","HealAssignInnSpellFrame")
innSpellFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
innSpellFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")
innSpellFrame:SetScript("OnEvent",function()
    INN_ProcessInnervate(arg1 or "")
end)
rezFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
rezFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Restore druid frame and innCD on login/reload
-- druidRestoreFrame removed: druid frame handled by RAID_ROSTER_UPDATE via UpdateAssignFrame

local function RemoveDeadHealer(name)
    local newDead = {}
    local changed = false
    for _,d in ipairs(deadHealers) do
        if d.name == name then changed = true
        else table.insert(newDead, d) end
    end
    if changed then
        deadHealers = newDead
        RefreshAlertFrame()
        UpdateAssignFrame()
        if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
    end
end

local function CheckAllRezd()
    -- Called on zone change or entering world - check all dead healers
    -- If healer has full health in raid, they're alive
    if table.getn(deadHealers) == 0 then return end
    local toRez = {}
    for _,d in ipairs(deadHealers) do
        -- Search in raid
        for ri = 1, GetNumRaidMembers() do
            local rname = UnitName("raid"..ri)
            if rname == d.name then
                local hp = UnitHealth("raid"..ri)
                if hp and hp > 0 then
                    table.insert(toRez, d.name)
                end
                break
            end
        end
        -- Check self
        if UnitName("player") == d.name then
            if UnitHealth("player") > 0 then
                table.insert(toRez, d.name)
            end
        end
    end
    for _,name in ipairs(toRez) do
        RemoveDeadHealer(name)
    end
end

rezFrame:SetScript("OnEvent",function()
    -- Zone change or entering world = mass rez (instance entry)
    if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        -- Small delay to let unit data load
        local rezCheck = CreateFrame("Frame")
        local rezElapsed = 0
        rezCheck:SetScript("OnUpdate",function()
            rezElapsed = rezElapsed + arg1
            if rezElapsed >= 1.5 then
                rezCheck:SetScript("OnUpdate",nil)
                rezCheck:Hide()
                CheckAllRezd()
            end
        end)
        return
    end

    -- Combat log resurrection messages
    local msg = arg1
    if not msg then return end
    local rezzed = nil
    if string.find(msg, "^You have been resurrected") or string.find(msg, "^You are resurrected") then
        rezzed = UnitName("player")
    else
        local _,_,cap = string.find(msg, "^(.+) is resurrected")
        if not cap then _,_,cap = string.find(msg, "^(.+) comes back to life") end
        if cap then rezzed = cap end
    end
    if rezzed then RemoveDeadHealer(rezzed) end
end)

-------------------------------------------------------------------------------
-- MAIN EVENT HANDLER
-------------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame","HealAssignEventFrame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")


eventFrame:SetScript("OnEvent",function()
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()
            if HealAssignDB.activeTemplate and HealAssignDB.templates[HealAssignDB.activeTemplate] then
                currentTemplate = HealAssignDB.templates[HealAssignDB.activeTemplate]
                if not currentTemplate.roster  then currentTemplate.roster  = {} end
                if not currentTemplate.healers then currentTemplate.healers = {} end
            end
            if not currentTemplate then currentTemplate = NewTemplate("") end
            if not currentTemplate.innervate then currentTemplate.innervate = {} end
            CreateAssignFrame()
            CreateAlertFrame()
            -- Show assign frame only if already in raid (e.g. reloadui)
            if GetNumRaidMembers() > 0 then
                UpdateAssignFrame()
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.." loaded. |cffffffff/ha|r to open.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(arg1,arg2,arg3,arg4)

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Broadcast my CD state so healer frames sync after reload
        if INN_BroadcastMyCD then INN_BroadcastMyCD() end
        UpdateAssignFrame()
        UpdateDruidAssignFrame()

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        local inRaid = GetNumRaidMembers() > 0
        -- Only update assign frame based on raid status (not party)
        if assignFrame then
            if inRaid then
                UpdateAssignFrame()
                UpdateDruidAssignFrame()
            else
                local showOutside = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
                if showOutside then
                    UpdateAssignFrame()
                else
                    assignFrame:Hide()
                end
                -- FIX 4: always hide druid frame when leaving raid
                if druidAssignFrame then druidAssignFrame:Hide() end
            end
        end
        if inRaid then
            if mainFrame and mainFrame:IsShown() then RebuildMainGrid() end
            if rosterFrame and rosterFrame:IsShown() then RebuildRosterRows() end
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
        else
            -- Left raid: close roster (stale data), keep main frame open
            if rosterFrame and rosterFrame:IsShown() then rosterFrame:Hide() end
            if rlFrame and rlFrame:IsShown() then rlFrame:Hide() end
            -- FIX 5: clear runtime roster so stale members don't appear in new raid
            if currentTemplate then
                currentTemplate.roster    = {}
                currentTemplate.healers   = {}
                currentTemplate.innervate = {}
            end
        end
    end
end)

-------------------------------------------------------------------------------
-- INNERVATE ASSIGNMENT SYSTEM
-------------------------------------------------------------------------------
-- innervate = {} in template: [druidName] = healerName
-- innCD = {} global: [druidName] = castTime (GetTime() when cast)
-- (innervateFrame, innCD, INN_CD_FULL, INN_ICON declared in FRAME REFERENCES)


local function INN_GetChannel()
    if GetNumRaidMembers() > 0 then return "RAID"
    elseif GetNumPartyMembers() > 0 then return "PARTY" end
    return nil
end

local function INN_GetDruids()
    local tmpl = GetActiveTemplate()
    if not tmpl then return {} end
    local out = {}
    for pname,pd in pairs(tmpl.roster) do
        if pd.class == "DRUID" and not pd.tagH then
            table.insert(out, pname)
        end
    end
    table.sort(out)
    return out
end

local function INN_GetHealers()
    local tmpl = GetActiveTemplate()
    if not tmpl then return {} end
    local out = {}
    for pname,pd in pairs(tmpl.roster) do
        if pd.tagH then table.insert(out, pname) end
    end
    table.sort(out)
    return out
end


-- Broadcast assignments to raid (RL after any change)
local function INN_BroadcastAssignments()
    local tmpl = GetActiveTemplate()
    if not tmpl or not tmpl.innervate then return end
    local chan = INN_GetChannel()
    if not chan then return end   -- FIX 1b: not in group, skip (prevents "Unknown addon chat type")
    local parts = {}
    for d,h in pairs(tmpl.innervate) do
        table.insert(parts, d.."="..h)
    end
    pcall(SendAddonMessage, COMM_PREFIX, "INN_ASSIGN;"..table.concat(parts,"|"), chan)
end

-- Called after druid casts - broadcast cast time
INN_BroadcastCast = function(druidName)
    local chan = INN_GetChannel()
    if chan then
        pcall(SendAddonMessage, COMM_PREFIX, "INN_CAST;"..druidName, chan)
    end
end

-- After reload: broadcast my current CD so healer's frame syncs
local function INN_BroadcastMyCD()
    local myN = UnitName("player")
    if not myN then return end
    local rem = INN_GetCDRemaining(myN)
    if rem > 0 then
        INN_BroadcastCast(myN)
    end
end

-------------------------------------------------------------------------------
-- INNERVATE ALERT FRAME (for druids: green, no sound)
-------------------------------------------------------------------------------
local innAlertFrame = nil
local function INN_ShowAlert(healerName, manaPct)
    if not innAlertFrame then
        innAlertFrame = CreateFrame("Frame","HealAssignInnAlert",UIParent)
        innAlertFrame:SetWidth(560)
        innAlertFrame:SetHeight(44)
        innAlertFrame:SetPoint("TOP",UIParent,"TOP",0,-170)
        innAlertFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        innAlertFrame:SetBackdrop({
            bgFile  ="Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile="Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=8,edgeSize=10,
            insets={left=4,right=4,top=4,bottom=4}
        })
        innAlertFrame:SetBackdropColor(0,0.25,0,0.92)
        innAlertFrame:SetBackdropBorderColor(0.1,1,0.1,1)
        local txt = innAlertFrame:CreateFontString(nil,"OVERLAY")
        txt:SetFont("Fonts\\FRIZQT__.TTF",22,"OUTLINE")
        txt:SetPoint("CENTER",innAlertFrame,"CENTER",0,0)
        txt:SetTextColor(0.1,1,0.1)
        innAlertFrame.txt = txt
        innAlertFrame.elapsed = 0
        innAlertFrame:SetScript("OnUpdate",function()
            innAlertFrame.elapsed = innAlertFrame.elapsed + arg1
            local pct = innAlertFrame.elapsed / 7
            if pct >= 1 then
                innAlertFrame:Hide()
                innAlertFrame.elapsed = 0
            elseif pct > 0.6 then
                innAlertFrame:SetAlpha(1-(pct-0.6)/0.4)
            else
                innAlertFrame:SetAlpha(1)
            end
        end)
    end
    innAlertFrame.txt:SetText("INNERVATE  "..healerName.."  ("..manaPct.."%)")
    innAlertFrame.elapsed = 0
    innAlertFrame:SetAlpha(1)
    innAlertFrame:Show()
end

-------------------------------------------------------------------------------
-- DRUID PERSONAL FRAME
-------------------------------------------------------------------------------


-------------------------------------------------------------------------------
-- INNERVATE ASSIGNMENT WINDOW (RL only: assign druids to healers)
-------------------------------------------------------------------------------
local innRows = {}

local function INN_RebuildAssignRows()
    if not innervateFrame then return end
    for _,r in ipairs(innRows) do r:Hide() end
    innRows = {}

    local tmpl = GetActiveTemplate()
    if not tmpl then return end
    local druids  = INN_GetDruids()
    local healers = INN_GetHealers()

    local y    = -44
    local rowH = 26
    local cellW2 = 270

    for _,dname in ipairs(druids) do
        local assigned = tmpl.innervate and tmpl.innervate[dname]

        -- Cell frame - same style as healer cell in main grid
        local cell2 = CreateFrame("Frame",nil,innervateFrame)
        cell2:SetWidth(cellW2)
        cell2:SetHeight(rowH)
        cell2:SetPoint("TOPLEFT",innervateFrame,"TOPLEFT",10,y)
        cell2:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=8,edgeSize=8,
            insets={left=3,right=3,top=3,bottom=3}
        })
        cell2:SetBackdropColor(0.07,0.07,0.14,0.97)
        cell2:SetBackdropBorderColor(0.25,0.35,0.6,0.8)
        table.insert(innRows, cell2)

        -- Druid name
        local dr,dg,db = GetClassColor("DRUID")
        local dLabel = cell2:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        dLabel:SetPoint("LEFT",cell2,"LEFT",6,0)
        dLabel:SetWidth(100)
        dLabel:SetJustifyH("LEFT")
        dLabel:SetTextColor(dr,dg,db)
        dLabel:SetText(dname)

        -- Healer name label (appears after selection)
        local hLabel = cell2:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        hLabel:SetPoint("LEFT",cell2,"LEFT",112,0)
        hLabel:SetWidth(90)
        hLabel:SetJustifyH("LEFT")
        if assigned then
            local hr,hg,hb = 1,1,1
            if tmpl.roster and tmpl.roster[assigned] then
                hr,hg,hb = GetClassColor(tmpl.roster[assigned].class)
            end
            hLabel:SetTextColor(hr,hg,hb)
            hLabel:SetText(assigned)
        else
            hLabel:SetTextColor(0.4,0.4,0.4)
            hLabel:SetText("---")
        end

        -- FIX 3: standard addon button style (UIPanelButtonTemplate like all other buttons)
        local ddBtn = CreateFrame("Button",nil,cell2,"UIPanelButtonTemplate")
        ddBtn:SetWidth(50)
        ddBtn:SetHeight(16)
        ddBtn:SetPoint("RIGHT",cell2,"RIGHT",-4,0)
        ddBtn:SetText("Assign")
        local capturedDruid = dname
        ddBtn:SetScript("OnClick",function()
            local items = {}
            table.insert(items,{text="(clear)",r=0.5,g=0.5,b=0.5,clear=true})
            for _,hname in ipairs(healers) do
                local pr,pg,pb = 1,1,1
                if tmpl.roster and tmpl.roster[hname] then
                    pr,pg,pb = GetClassColor(tmpl.roster[hname].class)
                end
                table.insert(items,{text=hname,r=pr,g=pg,b=pb,hname=hname})
            end
            if table.getn(items)==1 then
                table.insert(items,{text="(no healers tagged H)",r=0.5,g=0.5,b=0.5})
            end
            ShowDropdown(this, items, function(item)
                if not tmpl.innervate then tmpl.innervate = {} end
                if item.clear then
                    tmpl.innervate[capturedDruid] = nil
                elseif item.hname then
                    tmpl.innervate[capturedDruid] = item.hname
                end
                INN_BroadcastAssignments()
                INN_RebuildAssignRows()
                UpdateAssignFrame()
                UpdateDruidAssignFrame()
            end, 140)
        end)
        table.insert(innRows, ddBtn)

        y = y - rowH - 4
    end

    if table.getn(druids) == 0 then
        local noRow = CreateFrame("Frame",nil,innervateFrame)
        noRow:SetPoint("TOPLEFT",innervateFrame,"TOPLEFT",10,-44)
        noRow:SetWidth(270)
        noRow:SetHeight(20)
        local noLabel = noRow:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        noLabel:SetAllPoints(noRow)
        noLabel:SetJustifyH("LEFT")
        noLabel:SetTextColor(0.5,0.5,0.5)
        noLabel:SetText("  No non-healer druids in roster.")
        table.insert(innRows, noRow)
        y = y - rowH
    end

    local totalH = math.abs(y) + 20
    if totalH < 80 then totalH = 80 end
    innervateFrame:SetHeight(totalH)
    innervateFrame:SetWidth(290)
end

function CreateInnervateFrame()
    if innervateFrame then
        INN_RebuildAssignRows()
        innervateFrame:Raise()
        innervateFrame:Show()
        PushWindow(innervateFrame)
        return
    end

    innervateFrame = CreateFrame("Frame","HealAssignInnervateFrame",UIParent)
    innervateFrame:SetWidth(310)
    innervateFrame:SetHeight(200)
    innervateFrame:SetPoint("CENTER",UIParent,"CENTER",0,60)
    innervateFrame:SetMovable(true)
    innervateFrame:EnableMouse(true)
    innervateFrame:RegisterForDrag("LeftButton")
    innervateFrame:SetScript("OnDragStart",function() this:StartMoving() end)
    innervateFrame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    innervateFrame:SetFrameStrata("DIALOG")
    innervateFrame:SetFrameLevel(10)
    innervateFrame:SetBackdrop({
        bgFile  ="Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile="Interface\\DialogFrame\\UI-DialogBox-Border",
        tile=true,tileSize=8,edgeSize=16,
        insets={left=4,right=4,top=4,bottom=4}
    })
    local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    innervateFrame:SetBackdropColor(0.04,0.04,0.1,_alpha)

    local title = innervateFrame:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
    title:SetPoint("TOP",innervateFrame,"TOP",0,-12)
    title:SetTextColor(0.4,1,0.4)
    title:SetText("Innervate Assignments")

    local closeBtn = CreateFrame("Button",nil,innervateFrame,"UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT",innervateFrame,"TOPRIGHT",-4,-4)
    closeBtn:SetScript("OnClick",function() innervateFrame:Hide() end)
    HookFrameHide(innervateFrame)

    INN_RebuildAssignRows()
    PushWindow(innervateFrame)
end

-------------------------------------------------------------------------------
-- INNERVATE TICKER (mana check + druid frame update)
-------------------------------------------------------------------------------
local innTicker = CreateFrame("Frame","HealAssignInnTicker")
local innTickerElapsed = 0
innTicker:SetScript("OnUpdate",function()
    innTickerElapsed = innTickerElapsed + arg1
    if innTickerElapsed < 1 then return end
    innTickerElapsed = 0

    local tmpl = GetActiveTemplate()
    if not tmpl or not tmpl.innervate then return end
    local myName = UnitName("player")


    -- Update healer assign frame if a druid assigned to me has active CD
    local myPdata2 = tmpl.roster and tmpl.roster[myName]
    if myPdata2 and myPdata2.tagH then
        -- Check if any druid is assigned to me with active CD
        local hasDruidCD = false
        for dname,hname in pairs(tmpl.innervate) do
            if hname == myName then
                local cdRem = INN_GetCDRemaining(dname)
                if cdRem > 0 then hasDruidCD = true end
                break
            end
        end
        if hasDruidCD and assignFrame and assignFrame:IsShown() then
            UpdateAssignFrame()
        end
    end

    -- Update druid assign frame every tick (mana refresh + CD timer).
    local myPdata3 = tmpl.roster and tmpl.roster[myName]
    local amDruid = myPdata3 and myPdata3.class == "DRUID" and not myPdata3.tagH
    if amDruid and tmpl.innervate and tmpl.innervate[myName] then
        UpdateDruidAssignFrame()
        -- FIX 3: BigWigs-style green alert when assigned healer drops below 50% mana
        local assignedH = tmpl.innervate[myName]
        local mPct = INN_GetHealerMana(assignedH)
        if mPct and mPct < 50 then
            -- Only fire once per low-mana event; reset when mana recovers above 60%
            if not INN_ALERT_SHOWN[myName] then
                INN_ALERT_SHOWN[myName] = true
                INN_ShowAlert(assignedH, mPct)
            end
        elseif mPct and mPct >= 60 then
            -- Reset so alert can fire again next time mana drops
            INN_ALERT_SHOWN[myName] = nil
        end
    end
    -- Update innervate assignment window if open
    if innervateFrame and innervateFrame:IsShown() then
        INN_RebuildAssignRows()
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
        if optionsFrame and optionsFrame:IsShown() then optionsFrame:Hide()
        else CreateOptionsFrame() end

    elseif msg == "assign" then
        if assignFrame then
            if assignFrame:IsShown() then assignFrame:Hide()
            else assignFrame:Show() UpdateAssignFrame() end
        end

    elseif msg == "rl" then
        if rlFrame and rlFrame:IsShown() then rlFrame:Hide()
        else CreateRLFrame() end

    elseif msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.."  commands:")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha|r            - Toggle main window")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha sync|r       - Sync template to group")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha options|r    - Options")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha assign|r     - Toggle my assignments frame")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha rl|r         - Toggle raid leader view")
        DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/ha help|r       - This help")

    else
        if not HasEditorRights() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Only Raid Leader or Assistant can open the editor.")
            return
        end
        if mainFrame then
            if mainFrame:IsShown() then
                mainFrame:Hide()
                CloseDropdown()
                if rosterFrame then rosterFrame:Hide() end
            else
                mainFrame:Show()
                mainFrame:Raise()
                if mainFrame.nameEdit and currentTemplate then
                    mainFrame.nameEdit:SetText(currentTemplate.name or "")
                end
                RebuildMainGrid()
                PushWindow(mainFrame)
            end
        else
            CreateMainFrame()
        end
    end
end