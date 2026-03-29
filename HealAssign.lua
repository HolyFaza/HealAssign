-- HealAssign.lua v2.0
-- WoW 1.12.1 Heal Assignment Addon
-- Healer-centric assignment system

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------
local ADDON_NAME    = "HealAssign"
local ADDON_VERSION = "2.0.6"
local COMM_PREFIX   = "HealAssign"
local HA_editorOpenBy   = nil   -- name of player who has mainFrame open
local HA_editorOpenTime = nil   -- GetTime() when HA_OPEN was received

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
            hideInBG        = true,
            windowAlpha     = 0.95,
            customTargets   = {},
        }
    end
    if not HealAssignDB.options.customTargets  then HealAssignDB.options.customTargets = {} end
    if not HealAssignDB.options.fontSize       then HealAssignDB.options.fontSize = 12 end
    if HealAssignDB.options.showAssignFrame == nil then HealAssignDB.options.showAssignFrame = false end
    if HealAssignDB.options.hideInBG == nil then HealAssignDB.options.hideInBG = true end
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
local _CreateMainFrame       = nil
local _SyncHealersFromRoster = nil
local _RebuildRosterRows     = nil
local _UpdateDruidAssignFrame = nil

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
local currentTemplate  = nil
local HA_wasInRaid     = false  -- true only after first RAID_ROSTER_UPDATE(inRaid=true) this session
local HA_reloadProtect = true   -- true on fresh load, blocks roster clear until raid confirmed

-- Ensure currentTemplate is always persisted in HealAssignDB
local function PersistTemplate()
    if currentTemplate and currentTemplate.name and currentTemplate.name ~= "" then
        HealAssignDB.templates[currentTemplate.name] = DeepCopy(currentTemplate)
        HealAssignDB.activeTemplate = currentTemplate.name
    end
end

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

local INN_CD_FULL   = 360   -- 6 min innervate CD
local INN_ICON      = "Interface\\Icons\\Spell_Nature_Lightning"
local innCD           = {}    -- [druidName] = GetTime() when cast
local INN_ALERT_SHOWN = {}    -- [druidName] = true when alert shown

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
-- BATTLEGROUND DETECTION
-------------------------------------------------------------------------------
local function HA_IsInBattleground()
    local zone = GetZoneText() or ""
    -- WoW 1.12 battleground zone names
    local bgZones = {
        ["Warsong Gulch"]      = true,
        ["Arathi Basin"]       = true,
        ["Alterac Valley"]     = true,
    }
    return bgZones[zone] == true
end

-- Returns true if addon windows should be visible right now
local function HA_ShouldShow()
    if HA_IsInBattleground() then
        local hideInBG = HealAssignDB and HealAssignDB.options and HealAssignDB.options.hideInBG
        if hideInBG == nil then hideInBG = true end
        if hideInBG then return false end
    end
    return true
end

-------------------------------------------------------------------------------
-- INNERVATE RUNTIME STATE
-------------------------------------------------------------------------------
local innervateFrame = nil  -- assignment popup frame
local viewerFrame    = nil  -- viewer (V tag) overview window

-------------------------------------------------------------------------------
-- TEXT MEASUREMENT UTILITY
-- One hidden fontstring used to measure text width accurately
-------------------------------------------------------------------------------
-- Text width estimation for FRIZQT__.TTF in WoW 1.12.1
-- Coefficient calibrated for 12-char names (max WoW name length)
local _charWidthCoeff = 0.50  -- adjusted empirically
local _measureDebugDone = false
local function HA_MeasureText(text, fontSize)
    return string.len(text) * fontSize * _charWidthCoeff
end

-- Returns pixel width of the longest name in roster at given fontSize
local function HA_MaxNameWidth(tmpl, fontSize)
    local maxW = HA_MeasureText("Abcde", fontSize)  -- minimum ~5 char fallback
    if tmpl and tmpl.roster then
        for pname,_ in pairs(tmpl.roster) do
            local w = HA_MeasureText(pname, fontSize)
            if w > maxW then maxW = w end
        end
    end
    return maxW
end

-------------------------------------------------------------------------------
-- REBIRTH SYSTEM UTILITIES
-------------------------------------------------------------------------------
local BR_CD_FULL    = 1800  -- 30 min in vanilla
local BR_ICON       = "Interface\\Icons\\Spell_Nature_Reincarnation"
local brDeadList    = {}    -- [{name, time}] dead T/H players for Rebirth tracking
local brTargeted    = {}    -- [druidName] = targetName
local brCD          = {}    -- [druidName] = castTime

local function BR_IsTH(name)
    local tmpl = GetActiveTemplate()
    if not tmpl or not tmpl.roster then return false end
    local pd = tmpl.roster[name]
    return pd and (pd.tagT or pd.tagH)
end

local function BR_GetCDRemaining(druidName)
    -- Use brCD table for everyone (set via combat log on cast)
    local t = brCD[druidName]
    if t then
        local rem = BR_CD_FULL - (GetTime() - t)
        return rem > 0 and rem or 0
    end
    -- Fallback for self: read from spellbook (e.g. after /reload before any cast)
    if druidName == UnitName("player") then
        local slot
        for i = 1, 200 do
            local sName = GetSpellName(i, BOOKTYPE_SPELL)
            if not sName then break end
            if sName == "Rebirth" then slot = i end
        end
        if slot then
            local cdStart, cdDur = GetSpellCooldown(slot, BOOKTYPE_SPELL)
            if cdStart and cdStart > 0 and cdDur and cdDur > 1.5 then
                local rem = (cdStart + cdDur) - GetTime()
                return rem > 0 and rem or 0
            end
        end
    end
    return 0
end

local function BR_AddDead(name)
    for _,d in ipairs(brDeadList) do
        if d.name == name then return end  -- already in list
    end
    table.insert(brDeadList, {name=name, time=GetTime()})
end

local function BR_RemoveDead(name)
    local new = {}
    for _,d in ipairs(brDeadList) do
        if d.name ~= name then table.insert(new, d) end
    end
    brDeadList = new
    -- Clear targeting if someone was targeting this person
    for druid, target in pairs(brTargeted) do
        if target == name then brTargeted[druid] = nil end
    end
end

local function BR_BroadcastTarget(druidName, targetName)
    local chan = GetNumRaidMembers() > 0 and "RAID" or nil
    if not chan then return end
    local msg = targetName and ("BR_TARGET;"..druidName..";"..targetName) or ("BR_CLEAR;"..druidName)
    pcall(SendAddonMessage, COMM_PREFIX, msg, chan)
end

local function BR_BroadcastCast(druidName)
    local chan = GetNumRaidMembers() > 0 and "RAID" or nil
    if not chan then return end
    pcall(SendAddonMessage, COMM_PREFIX, "BR_CAST;"..druidName, chan)
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

-- Rebirth system

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
    -- Only hide the alert banner after 15s; do NOT remove from deadHealers
    -- Removal from deadHealers happens only via RemoveDeadHealer() on actual resurrection
    local now = GetTime()
    local anyRecent = false
    for _,d in ipairs(deadHealers) do
        if now - d.time < 15 then anyRecent = true break end
    end
    if not anyRecent then
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
-- VIEWER FRAME (V tag: overview of all assignments + rebirth)
-- Widget pool: frames are created once; on each update only text/color/position/
-- visibility changes. CreateFrame/CreateFontString are NOT called on every update
-- eliminating memory leaks and frame rate drops.
-------------------------------------------------------------------------------

-- Header pool: frame + fontstring
local VF_HDR_POOL = {}
local VF_HDR_MAX  = 10

-- Assignment block pool (TargetBlock): frame + fsTarget + vdiv + up to 10 healer rows
local VF_BLK_POOL = {}
local VF_BLK_MAX  = 40  -- max target->healers blocks per render

-- Healer rows inside each block (up to 10 healers per target x 40 blocks,
-- stored per-block as blk.healRows)
local VF_HEAL_PER_BLK = 10

-- Rebirth block pool
local VF_RBK_POOL = {}
local VF_RBK_MAX  = 20

-- Active element counters for current render
local vfHdrUsed = 0
local vfBlkUsed = 0
local vfRbkUsed = 0

-- Single fontstrings for "no assignments" / "no druids" messages
local vfNoAssignFS = nil
local vfNoDruidsFS = nil

local function VF_EnsurePools(fontSize)
    -- Create headers
    while table.getn(VF_HDR_POOL) < VF_HDR_MAX do
        local hdr = CreateFrame("Frame", nil, viewerFrame)
        hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
            insets={left=0,right=0,top=0,bottom=0}})
        hdr:Hide()
        local fs = hdr:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
        fs:SetPoint("LEFT",  hdr, "LEFT",  0, 0)
        fs:SetPoint("RIGHT", hdr, "RIGHT", 0, 0)
        fs:SetJustifyH("CENTER")
        hdr.fs = fs
        table.insert(VF_HDR_POOL, hdr)
    end

    -- Create assignment blocks
    while table.getn(VF_BLK_POOL) < VF_BLK_MAX do
        local blk = CreateFrame("Frame", nil, viewerFrame)
        blk:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        blk:Hide()
        local fsT = blk:CreateFontString(nil,"OVERLAY")
        fsT:SetJustifyH("LEFT")
        fsT:SetJustifyV("MIDDLE")
        blk.fsTarget = fsT
        local vdiv = blk:CreateTexture(nil,"ARTWORK")
        vdiv:SetWidth(1)
        blk.vdiv = vdiv
        blk.healRows = {}
        for i = 1, VF_HEAL_PER_BLK do
            local fh = blk:CreateFontString(nil,"OVERLAY")
            fh:SetJustifyH("LEFT")
            fh:SetJustifyV("MIDDLE")
            fh:Hide()
            local sep = blk:CreateTexture(nil,"ARTWORK")
            sep:SetHeight(1)
            sep:Hide()
            table.insert(blk.healRows, {fs=fh, sep=sep})
        end
        table.insert(VF_BLK_POOL, blk)
    end

    -- Create Rebirth blocks
    while table.getn(VF_RBK_POOL) < VF_RBK_MAX do
        local blk = CreateFrame("Frame", nil, viewerFrame)
        blk:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        blk:Hide()
        local fsD  = blk:CreateFontString(nil,"OVERLAY")
        fsD:SetJustifyH("LEFT") fsD:SetJustifyV("MIDDLE")
        local vd1  = blk:CreateTexture(nil,"ARTWORK") vd1:SetWidth(1)
        local fsCD = blk:CreateFontString(nil,"OVERLAY")
        fsCD:SetJustifyH("CENTER") fsCD:SetJustifyV("MIDDLE")
        local vd2  = blk:CreateTexture(nil,"ARTWORK") vd2:SetWidth(1)
        local fsTgt= blk:CreateFontString(nil,"OVERLAY")
        fsTgt:SetJustifyH("LEFT") fsTgt:SetJustifyV("MIDDLE")
        blk.fsD = fsD blk.vd1 = vd1 blk.fsCD = fsCD
        blk.vd2 = vd2 blk.fsTgt = fsTgt
        table.insert(VF_RBK_POOL, blk)
    end

    -- Single empty-state strings
    if not vfNoAssignFS then
        vfNoAssignFS = viewerFrame:CreateFontString(nil,"OVERLAY")
        vfNoAssignFS:Hide()
    end
    if not vfNoDruidsFS then
        vfNoDruidsFS = viewerFrame:CreateFontString(nil,"OVERLAY")
        vfNoDruidsFS:Hide()
    end
end

-- Hide all pool elements
local function VF_HideAll()
    for _,h in ipairs(VF_HDR_POOL) do h:Hide() end
    for _,b in ipairs(VF_BLK_POOL) do
        b:Hide()
        for _,r in ipairs(b.healRows) do r.fs:Hide() r.sep:Hide() end
    end
    for _,b in ipairs(VF_RBK_POOL) do b:Hide() end
    if vfNoAssignFS then vfNoAssignFS:Hide() end
    if vfNoDruidsFS then vfNoDruidsFS:Hide() end
    if viewerFrame and viewerFrame._brToggleBtn then viewerFrame._brToggleBtn:Hide() end
    vfHdrUsed = 0
    vfBlkUsed = 0
    vfRbkUsed = 0
end

local function UpdateViewerFrame()
    -- Create viewerFrame once
    if not viewerFrame then
        viewerFrame = CreateFrame("Frame","HealAssignViewerFrame",UIParent)
        viewerFrame:SetWidth(220)
        viewerFrame:SetHeight(100)
        viewerFrame:SetPoint("CENTER",UIParent,"CENTER",400,100)
        viewerFrame:SetMovable(true)
        viewerFrame:EnableMouse(true)
        viewerFrame:RegisterForDrag("LeftButton")
        viewerFrame:SetScript("OnDragStart",function() this:StartMoving() end)
        viewerFrame:SetScript("OnDragStop",function()
            this:StopMovingOrSizing()
            local _,_,_,x,y = this:GetPoint()
            if HealAssignDB and HealAssignDB.options then
                HealAssignDB.options.viewerFrameX = x
                HealAssignDB.options.viewerFrameY = y
            end
        end)
        viewerFrame:SetFrameStrata("MEDIUM")
        viewerFrame:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile=true,tileSize=8,edgeSize=12,
            insets={left=4,right=4,top=4,bottom=4}
        })
        local _alpha = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
        viewerFrame:SetBackdropColor(0.05,0.05,0.1,_alpha)
        viewerFrame:SetBackdropBorderColor(0.3,0.6,1,0.8)
        viewerFrame:Hide()
        -- Window title (created once)
        viewerFrame.titleFS = viewerFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        viewerFrame.titleFS:SetPoint("TOP",viewerFrame,"TOP",0,-3)
        viewerFrame.titleFS:SetTextColor(1,0.82,0.0)
        viewerFrame.titleFS:SetText("Assignments")
        -- Rebirth collapsed state (persists between updates)
        viewerFrame._brCollapsed = false
        -- Rebirth toggle button (created once, repositioned each render)
        local brToggle = CreateFrame("Button",nil,viewerFrame,"UIPanelButtonTemplate")
        brToggle:SetWidth(18) brToggle:SetHeight(14)
        brToggle:SetText("+")
        brToggle:Hide()
        brToggle:SetScript("OnClick",function()
            viewerFrame._brCollapsed = not viewerFrame._brCollapsed
            UpdateViewerFrame()
        end)
        viewerFrame._brToggleBtn = brToggle
    end

    local inRaid = GetNumRaidMembers() > 0
    local showOutsideRaid = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
    if not inRaid and not showOutsideRaid then
        VF_HideAll()
        viewerFrame:Hide()
        return
    end
    if not HA_ShouldShow() then
        VF_HideAll()
        viewerFrame:Hide()
        return
    end

    local myName   = UnitName("player")
    local tmpl     = GetActiveTemplate()
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12

    local myPdata = tmpl and tmpl.roster and tmpl.roster[myName]
    if not myPdata or not myPdata.tagV then
        VF_HideAll()
        viewerFrame:Hide()
        return
    end

    -- Frame width based on actual measured text width of longest name
    local nameW   = HA_MaxNameWidth(tmpl, fontSize)
    local colMinW = math.floor(nameW) + 16   -- one name column
    local brCD_W  = math.floor(fontSize * 2.2) + 4
    local twoColW   = colMinW * 2 + 10
    local threeColW = colMinW + brCD_W + colMinW + 14
    local frameW    = math.max(160, math.max(twoColW, threeColW))
    viewerFrame:SetWidth(frameW)

    local rowH    = fontSize + 4
    local rowStep = fontSize + 5
    local titleH  = fontSize + 8
    local yOff    = -(titleH + 2)
    local PAD     = 6
    local innerW  = frameW - PAD*2
    local colL    = colMinW  -- left column = exactly one name width
    local colR    = innerW - colL - 1

    -- Initialize pools if needed (first call or viewerFrame just created)
    VF_EnsurePools(fontSize)
    -- Hide all pool elements before render
    VF_HideAll()

    -- Window title already created, just update font
    viewerFrame.titleFS:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
    viewerFrame.titleFS:SetWidth(frameW - 32)  -- leave room for Options button
    viewerFrame.titleFS:Show()

    -- Helper: get header from pool
    local function UseHeader(text, r,g,b, bgMul)
        bgMul = bgMul or 0.18
        vfHdrUsed = vfHdrUsed + 1
        local hdr = VF_HDR_POOL[vfHdrUsed]
        if not hdr then return end  -- pool exhausted
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT", viewerFrame,"TOPLEFT", PAD, yOff)
        hdr:SetWidth(innerW)
        hdr:SetHeight(rowH + 2)
        hdr:SetBackdropColor(r*bgMul, g*bgMul, b*bgMul, 0.7)
        hdr.fs:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
        hdr.fs:SetTextColor(r,g,b)
        hdr.fs:SetText(text)
        hdr:Show()
        yOff = yOff - (rowH + 4)
    end

    -- Helper: get assignment block from pool
    local function UseTargetBlock(m, heals, tcR,tcG,tcB)
        local numRows = table.getn(heals)
        if numRows == 0 then numRows = 1 end
        local blockH = rowStep * numRows + 2
        vfBlkUsed = vfBlkUsed + 1
        local blk = VF_BLK_POOL[vfBlkUsed]
        if not blk then return end  -- pool exhausted
        blk:ClearAllPoints()
        blk:SetPoint("TOPLEFT", viewerFrame,"TOPLEFT", PAD, yOff)
        blk:SetWidth(innerW)
        blk:SetHeight(blockH)
        blk:SetBackdropColor(tcR*0.05, tcG*0.05, tcB*0.05, 0.4)
        blk:SetBackdropBorderColor(tcR*0.5, tcG*0.5, tcB*0.5, 0.6)
        -- Target label
        blk.fsTarget:ClearAllPoints()
        blk.fsTarget:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
        blk.fsTarget:SetPoint("TOPLEFT",blk,"TOPLEFT",4,-2)
        blk.fsTarget:SetWidth(colL - 8)
        blk.fsTarget:SetHeight(rowStep)
        blk.fsTarget:SetTextColor(tcR,tcG,tcB)
        blk.fsTarget:SetText(m.display)
        -- Vertical divider
        blk.vdiv:ClearAllPoints()
        blk.vdiv:SetPoint("TOPLEFT",    blk,"TOPLEFT",   colL, -2)
        blk.vdiv:SetPoint("BOTTOMLEFT", blk,"BOTTOMLEFT", colL,  2)
        blk.vdiv:SetTexture(tcR*0.5, tcG*0.5, tcB*0.5, 0.5)
        blk.vdiv:Show()
        -- Healer rows
        for i = 1, VF_HEAL_PER_BLK do
            local row = blk.healRows[i]
            if i <= numRows then
                local hname = heals[i]
                local hr2,hg2,hb2 = 1,1,1
                if hname and tmpl and tmpl.roster and tmpl.roster[hname] then
                    hr2,hg2,hb2 = GetClassColor(tmpl.roster[hname].class)
                end
                local isDead = false
                if hname then
                    for _,dd in ipairs(deadHealers) do
                        if dd.name == hname then isDead=true break end
                    end
                end
                if isDead then hr2,hg2,hb2 = 1,0.15,0.15 end
                row.fs:ClearAllPoints()
                row.fs:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
                row.fs:SetPoint("TOPLEFT",blk,"TOPLEFT", colL+4, -(2 + (i-1)*rowStep))
                row.fs:SetWidth(colR - 8)
                row.fs:SetHeight(rowStep)
                row.fs:SetTextColor(hr2,hg2,hb2)
                local healText = hname or ""
                row.fs:SetText(healText)
                row.fs:Show()
                if i < numRows then
                    row.sep:ClearAllPoints()
                    row.sep:SetPoint("TOPLEFT",  blk,"TOPLEFT",  colL+2, -(2 + i*rowStep))
                    row.sep:SetPoint("TOPRIGHT", blk,"TOPRIGHT", -2,     -(2 + i*rowStep))
                    row.sep:SetTexture(0.3,0.3,0.3,0.3)
                    row.sep:Show()
                else
                    row.sep:Hide()
                end
            else
                row.fs:Hide()
                row.sep:Hide()
            end
        end
        blk:Show()
        yOff = yOff - blockH - 3
    end

    if not tmpl then
        viewerFrame:SetHeight(titleH + rowStep + 4)
        viewerFrame:Show()
        return
    end

    -- Collect targets
    local tankTargets2, groupTargets2, customTargets2 = {},{},{}
    local targetMeta2, targetHeals2, seen2 = {},{},{}
    for _,h in ipairs(tmpl.healers) do
        for _,t in ipairs(h.targets) do
            local key = (t.type or "").."~"..(t.value or "")
            if not seen2[key] then
                seen2[key] = true
                local disp = t.value or "?"
                if t.type == TYPE_GROUP  then disp = "Group "..t.value
                elseif t.type == TYPE_CUSTOM then disp = t.value end
                targetMeta2[key] = {display=disp, ttype=t.type, tvalue=t.value}
                targetHeals2[key] = {}
                if t.type == TYPE_TANK      then table.insert(tankTargets2,  key)
                elseif t.type == TYPE_GROUP then table.insert(groupTargets2, key)
                else                             table.insert(customTargets2, key) end
            end
            table.insert(targetHeals2[key], h.name)
        end
    end
    table.sort(tankTargets2,  function(a,b) return targetMeta2[a].tvalue < targetMeta2[b].tvalue end)
    table.sort(groupTargets2, function(a,b)
        local na,nb = tonumber(targetMeta2[a].tvalue), tonumber(targetMeta2[b].tvalue)
        return (na or 0) < (nb or 0)
    end)
    table.sort(customTargets2, function(a,b) return targetMeta2[a].display < targetMeta2[b].display end)

    UseHeader("Heal Assignments", 1,0.8,0.2, 0.22)

    if table.getn(tankTargets2) > 0 then
        yOff = yOff - 2
        UseHeader("Tanks", 0.78,0.61,0.43, 0.15)
        for _,key in ipairs(tankTargets2) do
            local m = targetMeta2[key]
            local tcR,tcG,tcB = 0.78,0.61,0.43
            if tmpl.roster and tmpl.roster[m.tvalue] then
                tcR,tcG,tcB = GetClassColor(tmpl.roster[m.tvalue].class)
            end
            UseTargetBlock(m, targetHeals2[key], tcR,tcG,tcB)
        end
    end
    if table.getn(groupTargets2) > 0 then
        yOff = yOff - 2
        UseHeader("Groups", 0.5,0.85,1.0, 0.12)
        for _,key in ipairs(groupTargets2) do
            UseTargetBlock(targetMeta2[key], targetHeals2[key], 0.5,0.85,1.0)
        end
    end
    if table.getn(customTargets2) > 0 then
        yOff = yOff - 2
        UseHeader("Custom", 0.9,0.6,1.0, 0.12)
        for _,key in ipairs(customTargets2) do
            UseTargetBlock(targetMeta2[key], targetHeals2[key], 0.9,0.6,1.0)
        end
    end
    if table.getn(tankTargets2)==0 and table.getn(groupTargets2)==0 and table.getn(customTargets2)==0 then
        vfNoAssignFS:ClearAllPoints()
        vfNoAssignFS:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
        vfNoAssignFS:SetPoint("TOPLEFT",viewerFrame,"TOPLEFT",PAD+4,yOff)
        vfNoAssignFS:SetTextColor(0.5,0.5,0.5)
        vfNoAssignFS:SetText("(no assignments)")
        vfNoAssignFS:Show()
        yOff = yOff - rowStep
    end

    -- Innervate section
    if tmpl.innervate and next(tmpl.innervate) then
        yOff = yOff - 2
        UseHeader("Innervate", 1,0.65,0.1, 0.15)
        local innList2 = {}
        for dn,hn in pairs(tmpl.innervate) do
            table.insert(innList2, {druid=dn, healer=hn})
        end
        table.sort(innList2, function(a,b) return a.druid < b.druid end)
        for _,pair in ipairs(innList2) do
            local vdr,vdg,vdb = GetClassColor("DRUID")
            local fakeM = {display=pair.druid, ttype="druid", tvalue=pair.druid}
            UseTargetBlock(fakeM, {pair.healer}, vdr,vdg,vdb)
        end
    end

    -- Rebirth section
    do
        yOff = yOff - 4
        local collapsed = viewerFrame._brCollapsed
        local brLabel = collapsed and "> Rebirth" or "v Rebirth"
        UseHeader(brLabel, 0.7,0.3,1, 0.15)

        -- Position toggle button on top of the Rebirth header
        local btn = viewerFrame._brToggleBtn
        local hdr = VF_HDR_POOL[vfHdrUsed]  -- the header just placed by UseHeader
        if hdr then
            btn:ClearAllPoints()
            btn:SetPoint("RIGHT", hdr, "RIGHT", -2, 0)
            btn:SetText(collapsed and "+" or "-")
            btn:Show()
        end

        local brDruids = {}
        if tmpl.roster then
            for pname,pd in pairs(tmpl.roster) do
                if pd.class == "DRUID" then table.insert(brDruids, pname) end
            end
        end
        table.sort(brDruids)

        local brCol1 = colMinW                          -- druid name
        local brCol2 = brCD_W                           -- CD: "90s"/"30m"
        local brCol3 = innerW - brCol1 - brCol2 - 2    -- target name

        if not collapsed then
            if table.getn(brDruids) == 0 then
                vfNoDruidsFS:ClearAllPoints()
                vfNoDruidsFS:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
                vfNoDruidsFS:SetPoint("TOPLEFT",viewerFrame,"TOPLEFT",PAD+4,yOff)
                vfNoDruidsFS:SetTextColor(0.5,0.5,0.5)
                vfNoDruidsFS:SetText("(no druids)")
                vfNoDruidsFS:Show()
                yOff = yOff - rowStep
            else
                local druidTargets = {}
                local claimedDead  = {}
                for _,dname in ipairs(brDruids) do
                    local tgt = brTargeted[dname]
                    if tgt then druidTargets[dname] = tgt claimedDead[tgt] = true end
                end
                local freeDruids = {}
                for _,dname in ipairs(brDruids) do
                    if not druidTargets[dname] then table.insert(freeDruids, dname) end
                end
                local fdi = 1
                for _,d in ipairs(brDeadList) do
                    if not claimedDead[d.name] and fdi <= table.getn(freeDruids) then
                        druidTargets[freeDruids[fdi]] = d.name
                        fdi = fdi + 1
                    end
                end

                -- Helper: get Rebirth block from pool
                local function UseRebirthBlock(druidName, cdRem2, targetName, isClaimed, dr2,dg2,db2)
                    local blockH = rowStep + 2
                    vfRbkUsed = vfRbkUsed + 1
                    local blk = VF_RBK_POOL[vfRbkUsed]
                    if not blk then return end
                    blk:ClearAllPoints()
                    blk:SetPoint("TOPLEFT", viewerFrame,"TOPLEFT", PAD, yOff)
                    blk:SetWidth(innerW)
                    blk:SetHeight(blockH)
                    blk:SetBackdropColor(dr2*0.05, dg2*0.05, db2*0.05, 0.4)
                    blk:SetBackdropBorderColor(dr2*0.5, dg2*0.5, db2*0.5, 0.6)
                    blk.fsD:ClearAllPoints()
                    blk.fsD:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
                    blk.fsD:SetPoint("TOPLEFT",blk,"TOPLEFT",4,-2)
                    blk.fsD:SetWidth(brCol1 - 8) blk.fsD:SetHeight(rowStep)
                    blk.fsD:SetTextColor(dr2,dg2,db2) blk.fsD:SetText(druidName)
                    blk.vd1:ClearAllPoints()
                    blk.vd1:SetPoint("TOPLEFT",    blk,"TOPLEFT",   brCol1, -2)
                    blk.vd1:SetPoint("BOTTOMLEFT", blk,"BOTTOMLEFT", brCol1,  2)
                    blk.vd1:SetTexture(dr2*0.5, dg2*0.5, db2*0.5, 0.5)
                    blk.fsCD:ClearAllPoints()
                    blk.fsCD:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
                    blk.fsCD:SetPoint("TOPLEFT",blk,"TOPLEFT", brCol1+4, -2)
                    blk.fsCD:SetWidth(brCol2 - 8) blk.fsCD:SetHeight(rowStep)
                    if cdRem2 > 0 then
                        blk.fsCD:SetTextColor(1,1,0)
                        if cdRem2 <= 90 then blk.fsCD:SetText(math.ceil(cdRem2).."s")
                        else blk.fsCD:SetText(math.ceil(cdRem2/60).."m") end
                    else blk.fsCD:SetTextColor(1,1,1) blk.fsCD:SetText("") end
                    blk.vd2:ClearAllPoints()
                    blk.vd2:SetPoint("TOPLEFT",    blk,"TOPLEFT",   brCol1+brCol2+1, -2)
                    blk.vd2:SetPoint("BOTTOMLEFT", blk,"BOTTOMLEFT", brCol1+brCol2+1,  2)
                    blk.vd2:SetTexture(dr2*0.5, dg2*0.5, db2*0.5, 0.5)
                    blk.fsTgt:ClearAllPoints()
                    blk.fsTgt:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
                    blk.fsTgt:SetPoint("TOPLEFT",blk,"TOPLEFT", brCol1+brCol2+5, -2)
                    blk.fsTgt:SetWidth(brCol3 - 8) blk.fsTgt:SetHeight(rowStep)
                    if targetName then
                        if isClaimed then
                            blk.fsTgt:SetTextColor(1,0.85,0.85)
                            blk.fsTgt:SetText(targetName)
                        else
                            blk.fsTgt:SetTextColor(1,0.3,0.3)
                            blk.fsTgt:SetText(targetName)
                        end
                    else blk.fsTgt:SetTextColor(1,1,1) blk.fsTgt:SetText("") end
                    blk:Show()
                    yOff = yOff - blockH - 3
                end

                for _,dname in ipairs(brDruids) do
                    local tgt = druidTargets[dname]
                    local cdRem = BR_GetCDRemaining(dname)
                    local dr,dg,db = GetClassColor("DRUID")
                    UseRebirthBlock(dname, cdRem, tgt, brTargeted[dname] ~= nil, dr,dg,db)
                end

                -- Orphaned dead (no free druid available)
                local orphaned = {}
                for _,d in ipairs(brDeadList) do
                    local assigned = false
                    for _,dtgt in pairs(druidTargets) do
                        if dtgt == d.name then assigned = true break end
                    end
                    if not assigned then table.insert(orphaned, d.name) end
                end
                for _,uname in ipairs(orphaned) do
                    local fakeM2 = {display=uname, ttype="dead", tvalue=uname}
                    UseTargetBlock(fakeM2, {}, 1,0.2,0.2)
                end
            end
        end
    end

    local totalH = math.abs(yOff) + rowStep + 4
    if totalH < titleH + rowStep then totalH = titleH + rowStep end
    viewerFrame:SetHeight(totalH)
    viewerFrame:Show()
end

-------------------------------------------------------------------------------
-- ASSIGN FRAME (personal frame showing my targets + unattended)
-------------------------------------------------------------------------------
-- Widget pool for assignFrame (healers)
-- Headers and blocks are created once; on each update only
-- text/color/position/visibility changes.
local AF_HDR_POOL  = {}   -- section headers
local AF_BLK_POOL  = {}   -- target blocks
local AF_HDR_MAX   = 12
local AF_BLK_MAX   = 30
local afHdrUsed    = 0
local afBlkUsed    = 0

-- Dead player button pool for Rebirth section (druid-healer)
-- Up to 40 raid members can die
local AF_DEAD_POOL = {}
local AF_DEAD_MAX  = 40
local afDeadUsed   = 0

local function AF_EnsurePools(fontSize)
    while table.getn(AF_HDR_POOL) < AF_HDR_MAX do
        local hdr = CreateFrame("Frame", nil, assignFrame)
        hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
            insets={left=0,right=0,top=0,bottom=0}})
        hdr:Hide()
        local fs = hdr:CreateFontString(nil,"OVERLAY")
        fs:SetPoint("LEFT",  hdr,"LEFT",  4, 0)
        fs:SetPoint("RIGHT", hdr,"RIGHT", -4, 0)
        fs:SetJustifyH("CENTER")
        hdr.fs = fs
        table.insert(AF_HDR_POOL, hdr)
    end
    while table.getn(AF_BLK_POOL) < AF_BLK_MAX do
        local blk = CreateFrame("Frame", nil, assignFrame)
        blk:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        blk:Hide()
        local fs = blk:CreateFontString(nil,"OVERLAY")
        fs:SetJustifyH("LEFT") fs:SetJustifyV("MIDDLE")
        blk.fs = fs
        table.insert(AF_BLK_POOL, blk)
    end
    while table.getn(AF_DEAD_POOL) < AF_DEAD_MAX do
        local row = CreateFrame("Button", nil, assignFrame)
        row:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        row:Hide()
        local fs2 = row:CreateFontString(nil,"OVERLAY")
        fs2:SetJustifyH("LEFT") fs2:SetJustifyV("MIDDLE")
        row.fs2 = fs2
        local icF2 = CreateFrame("Frame",nil,row)
        local icT2 = icF2:CreateTexture(nil,"OVERLAY")
        icT2:SetAllPoints(icF2)
        icT2:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.icF2 = icF2
        row.icT2 = icT2
        table.insert(AF_DEAD_POOL, row)
    end
end

local function AF_HideAll()
    for _,h in ipairs(AF_HDR_POOL) do h:Hide() end
    for _,b in ipairs(AF_BLK_POOL) do b:Hide() end
    for _,r in ipairs(AF_DEAD_POOL) do r:Hide() r:SetScript("OnClick",nil) r:EnableMouse(false) end
    afHdrUsed = 0
    afBlkUsed = 0
    afDeadUsed = 0
end

local function UpdateAssignFrame()
    if not assignFrame then return end

    local inRaid = GetNumRaidMembers() > 0
    local showOutsideRaid = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
    if not inRaid and not showOutsideRaid then
        AF_HideAll()
        assignFrame:Hide()
        return
    end
    if not HA_ShouldShow() then
        AF_HideAll()
        assignFrame:Hide()
        return
    end

    local myName   = UnitName("player")
    local tmpl     = GetActiveTemplate()
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    local PAD_H    = 6

    local myTargets     = {}
    local myDeadTargets = {}

    local myPdata = tmpl and tmpl.roster and tmpl.roster[myName]
    local isHealer = myPdata and myPdata.tagH

    if tmpl then
        for _,h in ipairs(tmpl.healers) do
            if h.name == myName then myTargets = h.targets break end
        end
        for _,d in ipairs(deadHealers) do
            if d.name ~= myName then
                for _,t in ipairs(d.targets) do
                    table.insert(myDeadTargets,{target=t, from=d.name})
                end
            end
        end
    end

    if not isHealer then
        AF_HideAll()
        assignFrame:Hide()
        return
    end

    -- Frame width: max of (single name column) vs (innervate block: icon + name)
    local nameW_H    = HA_MaxNameWidth(tmpl, fontSize)
    local INN_ICON_W = math.max(18, math.min(44, math.floor(fontSize * 2.0)))
    local colMinW_H  = math.floor(nameW_H) + 16
    local innBlockW  = INN_ICON_W + math.floor(nameW_H) + 20  -- icon + gap + name + padding
    local frameW     = math.max(80, math.max(colMinW_H, innBlockW) + PAD_H * 2)
    assignFrame:SetWidth(frameW)

    local rowH    = fontSize + 4
    local rowStep = fontSize + 5
    local titleH  = fontSize + 8
    local yOff    = -(titleH + 2)
    local innerW_H = frameW - PAD_H*2

    -- Initialize pools if needed
    AF_EnsurePools(fontSize)
    AF_HideAll()

    -- Window title (created once in CreateAssignFrame)
    if assignFrame.titleFS then
        assignFrame.titleFS:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "")
        assignFrame.titleFS:Show()
    end

    -- Helper: section header from pool
    local function HAddHeader(text, r,g,b, bgMul)
        bgMul = bgMul or 0.18
        afHdrUsed = afHdrUsed + 1
        local hdr = AF_HDR_POOL[afHdrUsed]
        if not hdr then return end
        hdr:ClearAllPoints()
        hdr:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        hdr:SetWidth(innerW_H)
        hdr:SetHeight(rowH + 2)
        hdr:SetBackdropColor(r*bgMul, g*bgMul, b*bgMul, 0.7)
        hdr.fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
        hdr.fs:SetTextColor(r,g,b)
        hdr.fs:SetText(text)
        hdr:Show()
        yOff = yOff - (rowH + 4)
    end

    -- Helper: target block from pool
    local function HAddBlock(text, r,g,b)
        afBlkUsed = afBlkUsed + 1
        local blk = AF_BLK_POOL[afBlkUsed]
        if not blk then return end
        blk:ClearAllPoints()
        blk:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        blk:SetWidth(innerW_H)
        blk:SetHeight(rowStep + 2)
        blk:SetBackdropColor(r*0.05, g*0.05, b*0.05, 0.4)
        blk:SetBackdropBorderColor(r*0.5, g*0.5, b*0.5, 0.6)
        blk.fs:ClearAllPoints()
        blk.fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        blk.fs:SetPoint("LEFT", blk,"LEFT",   6, 0)
        blk.fs:SetPoint("RIGHT",blk,"RIGHT", -4, 0)
        blk.fs:SetHeight(rowStep + 2)
        blk.fs:SetTextColor(r,g,b)
        blk.fs:SetText(text)
        blk:Show()
        yOff = yOff - (rowStep + 2) - 3
    end

    -- Targets by type
    local myTanks, myGroups, myCustom = {},{},{}
    for _,t in ipairs(myTargets) do
        if t.type == TYPE_TANK      then table.insert(myTanks,  t)
        elseif t.type == TYPE_GROUP then table.insert(myGroups, t)
        else                             table.insert(myCustom, t) end
    end
    table.sort(myGroups, function(a,b)
        return (tonumber(a.value) or 0) < (tonumber(b.value) or 0)
    end)

    local hasTargets = table.getn(myTanks)+table.getn(myGroups)+table.getn(myCustom) > 0
    if not hasTargets then
        HAddBlock("(none assigned)", 0.5,0.5,0.5)
    else
        if table.getn(myTanks) > 0 then
            yOff = yOff - 2
            HAddHeader("Tanks", 0.78,0.61,0.43, 0.15)
            for _,t in ipairs(myTanks) do
                local dr,dg,db = 0.78,0.61,0.43
                if tmpl and tmpl.roster and tmpl.roster[t.value] then
                    dr,dg,db = GetClassColor(tmpl.roster[t.value].class)
                end
                HAddBlock(t.value, dr,dg,db)
            end
        end
        if table.getn(myGroups) > 0 then
            yOff = yOff - 2
            HAddHeader("Groups", 0.5,0.85,1.0, 0.12)
            for _,t in ipairs(myGroups) do
                HAddBlock("Group "..t.value, 0.5,0.85,1.0)
            end
        end
        if table.getn(myCustom) > 0 then
            yOff = yOff - 2
            HAddHeader("Custom", 0.9,0.6,1.0, 0.12)
            for _,t in ipairs(myCustom) do
                HAddBlock(t.value, 0.9,0.6,1.0)
            end
        end
    end

    -- Innervate (non-druid healers only)
    local _,myClass = UnitClass("player")
    local amDruidHealer = myClass == "DRUID"
    local myInnDruid = nil
    if tmpl and tmpl.innervate and not amDruidHealer then
        for dname,hname in pairs(tmpl.innervate) do
            if hname == myName then myInnDruid = dname break end
        end
    end
    if myInnDruid then
        yOff = yOff - 2
        HAddHeader("Innervate", 1,0.65,0.1, 0.15)
        local cdRem   = INN_GetCDRemaining(myInnDruid)
        local isReady = math.floor(cdRem) <= 0
        local INN_ICON_SZ = math.max(18, math.min(44, math.floor(fontSize * 2.0)))
        local dr2,dg2,db2 = GetClassColor("DRUID")
        -- Innervate block (created once)
        if not assignFrame._innBlock then
            local blk = CreateFrame("Frame",nil,assignFrame)
            blk:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile=true, tileSize=8, edgeSize=8,
                insets={left=2,right=2,top=2,bottom=2}
            })
            local iconCont = CreateFrame("Frame",nil,blk)
            local iTex = iconCont:CreateTexture(nil,"BACKGROUND")
            iTex:SetAllPoints(iconCont)
            iTex:SetTexture(INN_ICON)
            local cdFS = iconCont:CreateFontString(nil,"OVERLAY")
            cdFS:SetPoint("CENTER",iconCont,"CENTER",0,0)
            cdFS:SetTextColor(1,1,1)
            local nameFS = blk:CreateFontString(nil,"OVERLAY")
            nameFS:SetJustifyH("LEFT") nameFS:SetJustifyV("MIDDLE")
            assignFrame._innBlock    = blk
            assignFrame._innIconCont = iconCont
            assignFrame._innIconTex  = iTex
            assignFrame._innCDFS     = cdFS
            assignFrame._innNameFS   = nameFS
        end
        local blk = assignFrame._innBlock
        blk:ClearAllPoints()
        blk:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        blk:SetWidth(innerW_H)
        blk:SetHeight(INN_ICON_SZ + 4)
        blk:SetBackdropColor(dr2*0.05, dg2*0.05, db2*0.05, 0.4)
        blk:SetBackdropBorderColor(dr2*0.5, dg2*0.5, db2*0.5, 0.6)
        assignFrame._innIconCont:SetWidth(INN_ICON_SZ)
        assignFrame._innIconCont:SetHeight(INN_ICON_SZ)
        assignFrame._innIconCont:ClearAllPoints()
        assignFrame._innIconCont:SetPoint("LEFT",blk,"LEFT",4,0)
        local cdFSz = math.max(8,math.floor(fontSize*0.85))
        assignFrame._innCDFS:SetFont("Fonts\\FRIZQT__.TTF",cdFSz,"OUTLINE")
        if not isReady then
            assignFrame._innIconTex:SetVertexColor(0.35,0.35,0.35)
            local mins = math.floor(cdRem/60)
            local secs = math.floor(math.mod(cdRem,60))
            assignFrame._innCDFS:SetText(string.format("%d:%02d",mins,secs))
        else
            assignFrame._innIconTex:SetVertexColor(1,1,1)
            assignFrame._innCDFS:SetText("")
        end
        assignFrame._innNameFS:ClearAllPoints()
        assignFrame._innNameFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        assignFrame._innNameFS:SetPoint("LEFT", blk,"LEFT",  INN_ICON_SZ+8, 0)
        assignFrame._innNameFS:SetPoint("RIGHT",blk,"RIGHT", -4, 0)
        assignFrame._innNameFS:SetHeight(INN_ICON_SZ + 4)
        assignFrame._innNameFS:SetTextColor(
            isReady and dr2 or dr2*0.6,
            isReady and dg2 or dg2*0.6,
            isReady and db2 or db2*0.6)
        assignFrame._innNameFS:SetText(myInnDruid)
        blk:Show()
        yOff = yOff - INN_ICON_SZ - 4 - 3
    else
        if assignFrame._innBlock then assignFrame._innBlock:Hide() end
    end

    -- Cover Targets (dead healers)
    if table.getn(myDeadTargets) > 0 then
        yOff = yOff - 2
        HAddHeader("Cover Targets", 1,0.2,0.2, 0.25)
        local healerOrder, healerTargets = {}, {}
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
            HAddBlock(dname, dr2,dg2,db2)
            for _,t in ipairs(healerTargets[dname]) do
                local tr2,tg2,tb2 = 0.5,0.85,1.0
                if t.type == TYPE_TANK then
                    if tmpl and tmpl.roster and tmpl.roster[t.value] then
                        tr2,tg2,tb2 = GetClassColor(tmpl.roster[t.value].class)
                    end
                elseif t.type == TYPE_CUSTOM then tr2,tg2,tb2 = 0.9,0.6,1.0 end
                local disp2 = t.value or "?"
                if t.type == TYPE_GROUP then disp2 = "Group "..t.value end
                HAddBlock(disp2, tr2,tg2,tb2)
            end
        end
    end

    -- Rebirth (druid-healers only)
    if amDruidHealer and tmpl then
        yOff = yOff - 2
        HAddHeader("Rebirth", 0.7,0.3,1, 0.15)
        local brCDRem   = BR_GetCDRemaining(myName)
        local BR_ICON_SZ = math.max(18, math.min(44, math.floor(fontSize * 2.0)))
        local cdFontSz2 = math.floor(fontSize * 0.85)
        if cdFontSz2 < 8 then cdFontSz2 = 8 end
        local BTN_H2   = fontSize + 8
        local rowH2    = fontSize + 8
        local innerW2  = frameW - PAD_H*2
        local iconSzSm = math.floor(fontSize * 1.2)
        if iconSzSm < 10 then iconSzSm = 10 end
        if iconSzSm > 20 then iconSzSm = 20 end

        -- BR icon (created once)
        if not assignFrame._brIconF then
            local brIF = CreateFrame("Frame",nil,assignFrame)
            local brIT = brIF:CreateTexture(nil,"BACKGROUND")
            brIT:SetTexture(BR_ICON)
            brIT:SetAllPoints(brIF)
            local brCDT = brIF:CreateFontString(nil,"OVERLAY","GameFontNormal")
            brCDT:SetPoint("CENTER",brIF,"CENTER",0,0)
            brCDT:SetTextColor(1,1,0)
            assignFrame._brIconF   = brIF
            assignFrame._brIconTex = brIT
            assignFrame._brCDFS    = brCDT
        end
        local brIF = assignFrame._brIconF
        brIF:ClearAllPoints()
        brIF:SetPoint("TOP",assignFrame,"TOP",0,yOff)
        brIF:SetWidth(BR_ICON_SZ) brIF:SetHeight(BR_ICON_SZ)
        brIF:Show()
        assignFrame._brCDFS:SetFont("Fonts\\FRIZQT__.TTF",cdFontSz2,"OUTLINE")
        if brCDRem > 0 then
            assignFrame._brIconTex:SetVertexColor(0.3,0.3,0.3)
            local bm = math.floor(brCDRem/60)
            local bs = math.floor(math.mod(brCDRem,60))
            assignFrame._brCDFS:SetText(string.format("%d:%02d",bm,bs))
        else
            assignFrame._brIconTex:SetVertexColor(1,1,1)
            assignFrame._brCDFS:SetText("")
        end
        yOff = yOff - BR_ICON_SZ - PAD_H

        -- Dead list - use AF_DEAD_POOL
        local myNameCap = myName
        for _,d in ipairs(brDeadList) do
            local dname = d.name
            local takenBy = nil
            for druid,target in pairs(brTargeted) do
                if target == dname and druid ~= myNameCap then takenBy = druid end
            end
            local isMine = brTargeted[myNameCap] == dname
            local cr,cg,cb = 0.6,0.5,0.5
            if tmpl.roster and tmpl.roster[dname] then
                cr,cg,cb = GetClassColor(tmpl.roster[dname].class)
            end
            afDeadUsed = afDeadUsed + 1
            local row = AF_DEAD_POOL[afDeadUsed]
            if not row then break end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
            row:SetWidth(innerW2)
            row:SetHeight(rowH2)
            row:EnableMouse(not takenBy and not isMine and brCDRem <= 0)
            if isMine then
                row:SetBackdropColor(cr*0.35,cg*0.35,cb*0.35,0.9)
                row:SetBackdropBorderColor(cr,cg,cb,0.9)
            elseif takenBy then
                row:SetBackdropColor(0.1,0.1,0.1,0.6)
                row:SetBackdropBorderColor(0.3,0.3,0.3,0.4)
            else
                row:SetBackdropColor(cr*0.12,cg*0.12,cb*0.12,0.8)
                row:SetBackdropBorderColor(cr*0.4,cg*0.4,cb*0.4,0.7)
            end
            row.fs2:ClearAllPoints()
            row.fs2:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
            row.fs2:SetPoint("LEFT",row,"LEFT",6,0)
            row.fs2:SetPoint("RIGHT",row,"RIGHT",-(iconSzSm+8),0)
            row.fs2:SetHeight(rowH2)
            if isMine then
                row.fs2:SetTextColor(cr,cg,cb)
                row.fs2:SetText(dname)
            elseif takenBy then
                row.fs2:SetTextColor(0.4,0.4,0.4)
                row.fs2:SetText(dname.." |cff666666("..takenBy..")|r")
            else
                row.fs2:SetTextColor(0.9,0.85,0.75)
                row.fs2:SetText(dname)
            end
            row.icF2:SetWidth(iconSzSm) row.icF2:SetHeight(iconSzSm)
            row.icF2:ClearAllPoints()
            row.icF2:SetPoint("RIGHT",row,"RIGHT",-4,0)
            if isMine then row.icT2:SetVertexColor(1,0.85,0)
            elseif takenBy then row.icT2:SetVertexColor(1,0.2,0.2)
            else row.icT2:SetVertexColor(0.2,1,0.2) end
            if not takenBy and not isMine and brCDRem <= 0 then
                local capName = dname
                row:SetScript("OnClick",function()
                    brTargeted[myNameCap] = capName
                    TargetByName(capName)
                    BR_BroadcastTarget(myNameCap, capName)
                    UpdateAssignFrame() UpdateViewerFrame()
                end)
            else
                row:SetScript("OnClick",nil)
            end
            row:Show()
            yOff = yOff - rowH2 - 3
        end

        if table.getn(brDeadList) > 0 then yOff = yOff - 2 end

        -- Rebirth! button (created once)
        if not assignFrame._brCastBtn then
            local brBtn = CreateFrame("Button","HealAssignHealBRBtn",assignFrame,"UIPanelButtonTemplate")
            brBtn:SetText("Rebirth!")
            brBtn:SetScript("OnClick",function()
                local tgt = brTargeted[myName]
                if not tgt then return end
                if UnitName("target") ~= tgt then TargetByName(tgt)
                else CastSpellByName("Rebirth") end
            end)
            assignFrame._brCastBtn = brBtn
        end
        local brBtn = assignFrame._brCastBtn
        brBtn:ClearAllPoints()
        brBtn:SetPoint("TOP",assignFrame,"TOP",0,yOff - 2)
        local brBtnW = math.max(80, fontSize * 6)
        brBtn:SetWidth(brBtnW) brBtn:SetHeight(BTN_H2)
        local brBtnText = getglobal("HealAssignHealBRBtn" .. "Text")
        if brBtnText then brBtnText:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "") end
        brBtn:Show()
        local hasTarget = brTargeted[myName] ~= nil
        if hasTarget and brCDRem <= 0 then
            brBtn:SetTextColor(0.8,0.3,1) brBtn:EnableMouse(true) brBtn:SetAlpha(1)
        else
            brBtn:SetTextColor(0.5,0.5,0.5) brBtn:EnableMouse(false) brBtn:SetAlpha(0.5)
        end
        yOff = yOff - BTN_H2 - PAD_H
    else
        if assignFrame._brIconF   then assignFrame._brIconF:Hide() end
        if assignFrame._brCastBtn then assignFrame._brCastBtn:Hide() end
    end

    local totalH = math.abs(yOff) + rowStep + 4
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
    if viewerFrame  then viewerFrame:SetBackdropColor(0.05,0.05,0.1,alpha)  end
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
    assignFrame:Hide()

    -- Window title (created once)
    local titleFS = assignFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFS:SetPoint("TOP",assignFrame,"TOP",0,-3)
    titleFS:SetTextColor(1,0.82,0.0)
    titleFS:SetText("My Assignments")
    assignFrame.titleFS = titleFS
end

-------------------------------------------------------------------------------
-- DRUID INNERVATE FRAME
-------------------------------------------------------------------------------
local function UpdateDruidAssignFrame()
    local myName     = UnitName("player")
    local tmpl       = GetActiveTemplate()
    local inRaid     = GetNumRaidMembers() > 0
    local showOutside= HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
    local myPdata    = tmpl and tmpl.roster and tmpl.roster[myName]

    -- Determine role
    -- Use UnitClass directly - always available regardless of roster state
    local _,playerClass = UnitClass("player")
    local isDruid       = playerClass == "DRUID"
    -- All druids get druidAssignFrame EXCEPT druid-healers (tagH)
    -- Druid-healers see Rebirth in their assignFrame instead
    local isHealerDruid = isDruid and myPdata and myPdata.tagH
    if not isDruid or isHealerDruid then
        if druidAssignFrame then druidAssignFrame:Hide() end
        return
    end
    if (not inRaid and not showOutside) or not HA_ShouldShow() then
        if druidAssignFrame then druidAssignFrame:Hide() end
        return
    end

    local assignedHealer = tmpl and tmpl.innervate and tmpl.innervate[myName]

    -- Layout constants
    local fontSize  = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    local PAD       = 5
    local titleH    = fontSize + 6
    local rowStep   = fontSize + 4
    local ICON_SZ   = math.floor(fontSize * 2.5)
    if ICON_SZ < 20 then ICON_SZ = 20 end
    if ICON_SZ > 48 then ICON_SZ = 48 end
    local BTN_H     = fontSize + 8
    local cdFontSz  = math.floor(fontSize * 0.85)
    if cdFontSz < 8 then cdFontSz = 8 end
    -- Frame width based on actual measured text width of longest name
    local tmplD     = GetActiveTemplate()
    local nameW_D   = HA_MaxNameWidth(tmplD, fontSize)
    local colMinW_D = math.floor(nameW_D) + 16
    local btnW_D    = math.max(80, fontSize * 6)
    local frameW    = math.max(120, math.max(ICON_SZ + colMinW_D + PAD * 2, btnW_D + PAD * 2))

    -- Create frame once (always, regardless of assignment)
    if not druidAssignFrame then
        druidAssignFrame = CreateFrame("Frame","HealAssignDruidAssignFrame",UIParent)
        druidAssignFrame:SetMovable(true)
        druidAssignFrame:EnableMouse(true)
        druidAssignFrame:RegisterForDrag("LeftButton")
        druidAssignFrame:SetScript("OnDragStart",function() this:StartMoving() end)
        druidAssignFrame:SetScript("OnDragStop",function()
            this:StopMovingOrSizing()
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
        local _dx = HealAssignDB and HealAssignDB.options and HealAssignDB.options.druidFrameX or 20
        local _dy = HealAssignDB and HealAssignDB.options and HealAssignDB.options.druidFrameY or -200
        druidAssignFrame:SetPoint("TOPLEFT",UIParent,"TOPLEFT",_dx,_dy)

        -- Innervate widgets (shown only when assigned)
        local tFS = druidAssignFrame:CreateFontString(nil,"OVERLAY")
        tFS:SetJustifyH("CENTER")
        druidAssignFrame._titleFS = tFS

        local mFS = druidAssignFrame:CreateFontString(nil,"OVERLAY")
        mFS:SetJustifyH("CENTER")
        druidAssignFrame._manaFS = mFS

        local iFrame = CreateFrame("Frame",nil,druidAssignFrame)
        local iTex = iFrame:CreateTexture(nil,"BACKGROUND")
        iTex:SetTexture(INN_ICON)
        iTex:SetAllPoints(iFrame)
        local iCDFS = iFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
        iCDFS:SetPoint("CENTER",iFrame,"CENTER",0,0)
        iCDFS:SetTextColor(1,1,0)
        druidAssignFrame._iconFrame = iFrame
        druidAssignFrame._iconTex   = iTex
        druidAssignFrame._iconCDFS  = iCDFS

        local btn = CreateFrame("Button","HealAssignDruidInnBtn",druidAssignFrame,"UIPanelButtonTemplate")
        btn:SetText("Innervate!")
        btn:SetScript("OnClick",function()
            local t2 = GetActiveTemplate()
            local n  = UnitName("player")
            if not t2 then return end
            local h = t2.innervate and t2.innervate[n]
            if not h then return end
            if UnitName("target") ~= h then TargetByName(h)
            else CastSpellByName("Innervate") end
        end)
        druidAssignFrame._castBtn = btn

        -- BR widgets (always present)
        local brSep = druidAssignFrame:CreateTexture(nil,"ARTWORK")
        brSep:SetHeight(1)
        brSep:SetTexture(0.4,0.4,0.4,0.8)
        druidAssignFrame._brSep = brSep

        local brIF = CreateFrame("Frame",nil,druidAssignFrame)
        local brIT = brIF:CreateTexture(nil,"BACKGROUND")
        brIT:SetTexture(BR_ICON)
        brIT:SetAllPoints(brIF)
        local brCDT = brIF:CreateFontString(nil,"OVERLAY","GameFontNormal")
        brCDT:SetPoint("CENTER",brIF,"CENTER",0,0)
        brCDT:SetTextColor(1,1,0)
        druidAssignFrame._brIconF   = brIF
        druidAssignFrame._brIconTex = brIT
        druidAssignFrame._brCDFS    = brCDT

        local brBtn = CreateFrame("Button","HealAssignDruidBRBtn",druidAssignFrame,"UIPanelButtonTemplate")
        brBtn:SetText("Rebirth!")
        brBtn:SetScript("OnClick",function()
            local n   = UnitName("player")
            local tgt = brTargeted[n]
            if not tgt then return end
            if UnitName("target") ~= tgt then TargetByName(tgt)
            else CastSpellByName("Rebirth") end
        end)
        druidAssignFrame._brCastBtn = brBtn

        druidAssignFrame._brDeadBtns = {}
    end

    -- Update backdrop
    local _a = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.windowAlpha) or 0.95
    druidAssignFrame:SetBackdropColor(0.05,0.05,0.1,_a)
    druidAssignFrame:SetBackdropBorderColor(0.3,0.6,1,0.8)
    druidAssignFrame:SetWidth(frameW)

    local curY = -PAD
    local cdRem = 0

    -- ── INNERVATE section (only if assigned) ─────────────────────
    if assignedHealer then
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
        tFS:SetWidth(frameW - 32)
        tFS:Show()
        curY = curY - titleH - 4

        local mFS = druidAssignFrame._manaFS
        mFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        mFS:ClearAllPoints()
        mFS:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
        mFS:SetWidth(frameW - 12)
        mFS:SetHeight(rowStep)
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
        mFS:Show()
        curY = curY - rowStep - PAD

        local iFrame = druidAssignFrame._iconFrame
        iFrame:ClearAllPoints()
        iFrame:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
        iFrame:SetWidth(ICON_SZ) iFrame:SetHeight(ICON_SZ)
        iFrame:Show()

        cdRem = INN_GetCDRemaining(myName)
        local iTex  = druidAssignFrame._iconTex
        local iCDFS = druidAssignFrame._iconCDFS
        iCDFS:SetFont("Fonts\\FRIZQT__.TTF",cdFontSz,"OUTLINE")
        if math.floor(cdRem) > 0 then
            iTex:SetVertexColor(0.3,0.3,0.3)
            local mins = math.floor(cdRem/60)
            local secs = math.floor(math.mod(cdRem,60))
            iCDFS:SetText(string.format("%d:%02d",mins,secs))
        else
            iTex:SetVertexColor(1,1,1)
            iCDFS:SetText("")
        end
        curY = curY - ICON_SZ - PAD

        local btn = druidAssignFrame._castBtn
        btn:ClearAllPoints()
        btn:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
        local btnW = math.max(80, fontSize * 6)
        btn:SetWidth(btnW) btn:SetHeight(BTN_H)
        local innBtnText = getglobal("HealAssignDruidInnBtnText")
        if innBtnText then innBtnText:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "") end
        btn:Show()
        if cdRem > 0 then
            btn:SetTextColor(0.5,0.5,0.5) btn:EnableMouse(false) btn:SetAlpha(0.5)
        else
            btn:SetTextColor(0.1,1,0.1) btn:EnableMouse(true) btn:SetAlpha(1)
        end
        curY = curY - BTN_H - PAD
    else
        -- Hide innervate widgets
        druidAssignFrame._titleFS:Hide()
        druidAssignFrame._manaFS:Hide()
        druidAssignFrame._iconFrame:Hide()
        druidAssignFrame._castBtn:Hide()
    end

    -- ── REBIRTH section (always shown) ───────────────────────────
    -- Separator (only when innervate section shown above)
    if assignedHealer then
        local sep = druidAssignFrame._brSep
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT",druidAssignFrame,"TOPLEFT",PAD,curY)
        sep:SetPoint("TOPRIGHT",druidAssignFrame,"TOPRIGHT",-PAD,curY)
        sep:Show()
        curY = curY - 8
    else
        druidAssignFrame._brSep:Hide()
    end

    -- Title "Rebirth" (gold, like section headers)
    if not druidAssignFrame._brTitleFS then
        local tfs = druidAssignFrame:CreateFontString(nil,"OVERLAY")
        tfs:SetJustifyH("CENTER")
        druidAssignFrame._brTitleFS = tfs
    end
    druidAssignFrame._brTitleFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
    druidAssignFrame._brTitleFS:SetTextColor(1,0.82,0)
    druidAssignFrame._brTitleFS:SetText("Rebirth")
    druidAssignFrame._brTitleFS:ClearAllPoints()
    druidAssignFrame._brTitleFS:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    druidAssignFrame._brTitleFS:SetWidth(frameW - 32)
    druidAssignFrame._brTitleFS:Show()
    curY = curY - titleH - 2

    -- BR Icon centered
    local brIF = druidAssignFrame._brIconF
    brIF:ClearAllPoints()
    brIF:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
    brIF:SetWidth(ICON_SZ) brIF:SetHeight(ICON_SZ)
    brIF:Show()

    local brCDRem = BR_GetCDRemaining(UnitName("player"))
    local brIT  = druidAssignFrame._brIconTex
    local brCDT = druidAssignFrame._brCDFS
    brCDT:SetFont("Fonts\\FRIZQT__.TTF",cdFontSz,"OUTLINE")
    if brCDRem > 0 then
        brIT:SetVertexColor(0.3,0.3,0.3)
        local bm = math.floor(brCDRem/60)
        local bs = math.floor(math.mod(brCDRem,60))
        brCDT:SetText(string.format("%d:%02d",bm,bs))
    else
        brIT:SetVertexColor(1,1,1)
        brCDT:SetText("")
    end
    curY = curY - ICON_SZ - PAD

    -- Dead list: use per-frame pool (druidAssignFrame._deadPool)
    -- AF_DEAD_POOL belongs to assignFrame which has a different parent,
    -- so druids use their own pool stored on druidAssignFrame.
    if not druidAssignFrame._deadPool then
        druidAssignFrame._deadPool = {}
    end
    for _,r in ipairs(druidAssignFrame._deadPool) do
        r:Hide() r:SetScript("OnClick",nil) r:EnableMouse(false)
    end

    local myName2  = UnitName("player")
    local rowH2    = fontSize + 8
    local innerW   = frameW - PAD*2
    local iconSzSm = math.floor(fontSize * 1.2)
    if iconSzSm < 10 then iconSzSm = 10 end
    if iconSzSm > 20 then iconSzSm = 20 end

    local deadPool = druidAssignFrame._deadPool
    local deadIdx  = 0

    for _,d in ipairs(brDeadList) do
        local dname   = d.name
        local takenBy = nil
        for druid,target in pairs(brTargeted) do
            if target == dname and druid ~= myName2 then takenBy = druid end
        end
        local isMine = brTargeted[myName2] == dname
        local cr,cg,cb = 0.6,0.5,0.5
        if tmpl and tmpl.roster and tmpl.roster[dname] then
            cr,cg,cb = GetClassColor(tmpl.roster[dname].class)
        end

        deadIdx = deadIdx + 1
        local row = deadPool[deadIdx]
        if not row then
            row = CreateFrame("Button",nil,druidAssignFrame)
            row:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile=true, tileSize=8, edgeSize=8,
                insets={left=2,right=2,top=2,bottom=2}
            })
            local fs = row:CreateFontString(nil,"OVERLAY")
            fs:SetJustifyH("LEFT") fs:SetJustifyV("MIDDLE")
            row.fs = fs
            local icF = CreateFrame("Frame",nil,row)
            local icT = icF:CreateTexture(nil,"OVERLAY")
            icT:SetAllPoints(icF)
            icT:SetTexture("Interface\\Buttons\\WHITE8X8")
            row.icF = icF
            row.icT = icT
            table.insert(deadPool, row)
        end

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT",druidAssignFrame,"TOPLEFT",PAD,curY)
        row:SetWidth(innerW)
        row:SetHeight(rowH2)
        row:EnableMouse(not takenBy and not isMine and brCDRem <= 0)
        if isMine then
            row:SetBackdropColor(cr*0.35, cg*0.35, cb*0.35, 0.9)
            row:SetBackdropBorderColor(cr, cg, cb, 0.9)
        elseif takenBy then
            row:SetBackdropColor(0.1,0.1,0.1,0.6)
            row:SetBackdropBorderColor(0.3,0.3,0.3,0.4)
        else
            row:SetBackdropColor(cr*0.12, cg*0.12, cb*0.12, 0.8)
            row:SetBackdropBorderColor(cr*0.4, cg*0.4, cb*0.4, 0.7)
        end
        row.fs:ClearAllPoints()
        row.fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        row.fs:SetPoint("LEFT",  row,"LEFT",  6, 0)
        row.fs:SetPoint("RIGHT", row,"RIGHT", -(iconSzSm + 8), 0)
        row.fs:SetHeight(rowH2)
        if isMine then
            row.fs:SetTextColor(cr, cg, cb)
            row.fs:SetText(dname)
        elseif takenBy then
            row.fs:SetTextColor(0.4,0.4,0.4)
            row.fs:SetText(dname.." |cff666666("..takenBy..")|r")
        else
            row.fs:SetTextColor(0.9,0.85,0.75)
            row.fs:SetText(dname)
        end
        row.icF:SetWidth(iconSzSm) row.icF:SetHeight(iconSzSm)
        row.icF:ClearAllPoints()
        row.icF:SetPoint("RIGHT",row,"RIGHT",-4,0)
        if isMine then row.icT:SetVertexColor(1, 0.85, 0)
        elseif takenBy then row.icT:SetVertexColor(1, 0.2, 0.2)
        else row.icT:SetVertexColor(0.2, 1, 0.2) end
        if not takenBy and not isMine and brCDRem <= 0 then
            local capName = dname
            row:SetScript("OnClick",function()
                brTargeted[myName2] = capName
                TargetByName(capName)
                BR_BroadcastTarget(myName2, capName)
                UpdateDruidAssignFrame()
            end)
        else
            row:SetScript("OnClick",nil)
        end
        row:Show()
        curY = curY - rowH2 - 3
    end

    -- Gap before cast button
    if table.getn(brDeadList) > 0 then curY = curY - 2 end

    -- Rebirth cast button
    local brBtn = druidAssignFrame._brCastBtn
    brBtn:ClearAllPoints()
    brBtn:SetPoint("TOP",druidAssignFrame,"TOP",0,curY - 2)
    local brBtnW = math.max(80, fontSize * 6)
    brBtn:SetWidth(brBtnW) brBtn:SetHeight(BTN_H)
    local brBtnText2 = getglobal("HealAssignDruidBRBtnText")
    if brBtnText2 then brBtnText2:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "") end
    brBtn:Show()
    local hasTarget = brTargeted[myName2] ~= nil
    if hasTarget and brCDRem <= 0 then
        brBtn:SetTextColor(0.8,0.3,1) brBtn:EnableMouse(true) brBtn:SetAlpha(1)
    else
        brBtn:SetTextColor(0.5,0.5,0.5) brBtn:EnableMouse(false) brBtn:SetAlpha(0.5)
    end
    curY = curY - BTN_H - PAD
    -- Resize and show
    local fullH = math.abs(curY) + PAD
    druidAssignFrame:SetHeight(fullH)
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

    local fontSize = (HealAssignDB and HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    local frameW   = math.max(200, math.min(380, fontSize * 18))
    local PAD      = 6
    local rowH     = fontSize + 4
    local rowStep  = fontSize + 5
    local innerW   = frameW - PAD*2
    local colL     = math.floor(innerW * 0.44)
    local colR     = innerW - colL - 1
    local yOff     = -(fontSize + 14)

    rlFrame:SetWidth(frameW)

    -- Centered header (main or sub-section)
    local function RLHeader(text, r,g,b, bgMul)
        bgMul = bgMul or 0.18
        local hdr = CreateFrame("Frame",nil,rlFrame)
        hdr:SetPoint("TOPLEFT", rlFrame,"TOPLEFT", PAD, yOff)
        hdr:SetWidth(innerW)
        hdr:SetHeight(rowH + 2)
        hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
            insets={left=0,right=0,top=0,bottom=0}})
        hdr:SetBackdropColor(r*bgMul, g*bgMul, b*bgMul, 0.7)
        table.insert(rlFrame.content, hdr)
        local fs = hdr:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
        fs:SetPoint("LEFT", hdr,"LEFT",  0, 0)
        fs:SetPoint("RIGHT",hdr,"RIGHT", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetTextColor(r,g,b)
        fs:SetText(text)
        yOff = yOff - (rowH + 4)
    end

    -- Bordered block: target name + healer rows inside a thin border frame
    local function RLTargetBlock(m, heals, tcR,tcG,tcB)
        local numRows = table.getn(heals)
        if numRows == 0 then numRows = 1 end
        local blockH = rowStep * numRows + 2

        local block = CreateFrame("Frame",nil,rlFrame)
        block:SetPoint("TOPLEFT", rlFrame,"TOPLEFT", PAD, yOff)
        block:SetWidth(innerW)
        block:SetHeight(blockH)
        block:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        block:SetBackdropColor(tcR*0.05, tcG*0.05, tcB*0.05, 0.4)
        block:SetBackdropBorderColor(tcR*0.5, tcG*0.5, tcB*0.5, 0.6)
        table.insert(rlFrame.content, block)

        -- Target name (left cell)
        local fsTarget = block:CreateFontString(nil,"OVERLAY")
        fsTarget:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        fsTarget:SetPoint("TOPLEFT",block,"TOPLEFT",4,-2)
        fsTarget:SetWidth(colL - 8)
        fsTarget:SetHeight(rowStep)
        fsTarget:SetJustifyH("LEFT")
        fsTarget:SetJustifyV("MIDDLE")
        fsTarget:SetTextColor(tcR,tcG,tcB)
        fsTarget:SetText(m.display)

        -- Vertical divider
        local vdiv = block:CreateTexture(nil,"ARTWORK")
        vdiv:SetWidth(1)
        vdiv:SetPoint("TOPLEFT",    block,"TOPLEFT",   colL, -2)
        vdiv:SetPoint("BOTTOMLEFT", block,"BOTTOMLEFT",colL,  2)
        vdiv:SetTexture(tcR*0.5, tcG*0.5, tcB*0.5, 0.5)

        -- Healer rows (right cell)
        for hi,hname in ipairs(heals) do
            local hr2,hg2,hb2 = 1,1,1
            if tmpl.roster and tmpl.roster[hname] then
                hr2,hg2,hb2 = GetClassColor(tmpl.roster[hname].class)
            end
            local isDead = deadSet[hname]
            if isDead then hr2,hg2,hb2 = 1,0.15,0.15 end
            local fsH = block:CreateFontString(nil,"OVERLAY")
            fsH:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
            fsH:SetPoint("TOPLEFT",block,"TOPLEFT", colL+4, -(2 + (hi-1)*rowStep))
            fsH:SetWidth(colR - 8)
            fsH:SetHeight(rowStep)
            fsH:SetJustifyH("LEFT")
            fsH:SetJustifyV("MIDDLE")
            fsH:SetTextColor(hr2,hg2,hb2)
            fsH:SetText(hname)
            if hi < numRows then
                local hsep = block:CreateTexture(nil,"ARTWORK")
                hsep:SetHeight(1)
                hsep:SetPoint("TOPLEFT",  block,"TOPLEFT",  colL+2, -(2 + hi*rowStep))
                hsep:SetPoint("TOPRIGHT", block,"TOPRIGHT", -2,     -(2 + hi*rowStep))
                hsep:SetTexture(0.3,0.3,0.3,0.3)
            end
        end

        yOff = yOff - blockH - 3
    end

    -- Collect targets
    local tankT,groupT,customT = {},{},{}
    local tMeta,tHeals,tSeen = {},{},{}
    for _,h in ipairs(tmpl.healers) do
        for _,t in ipairs(h.targets or {}) do
            local key = (t.type or "").."~"..(t.value or "")
            if not tSeen[key] then
                tSeen[key] = true
                local disp = t.value or "?"
                if t.type == TYPE_GROUP  then disp = "Group "..t.value
                elseif t.type == TYPE_CUSTOM then disp = t.value end
                tMeta[key] = {display=disp, ttype=t.type, tvalue=t.value}
                tHeals[key] = {}
                if t.type==TYPE_TANK      then table.insert(tankT,  key)
                elseif t.type==TYPE_GROUP then table.insert(groupT, key)
                else                           table.insert(customT,key) end
            end
            table.insert(tHeals[key], h.name)
        end
    end
    table.sort(tankT,  function(a,b) return tMeta[a].tvalue < tMeta[b].tvalue end)
    table.sort(groupT, function(a,b)
        local na,nb = tonumber(tMeta[a].tvalue), tonumber(tMeta[b].tvalue)
        return (na or 0) < (nb or 0)
    end)
    table.sort(customT, function(a,b) return tMeta[a].display < tMeta[b].display end)

    -- ── Main header ────────────────────────────────────────────────
    RLHeader("Heal Assignments", 1,0.8,0.2, 0.22)

    -- ── Tanks ──────────────────────────────────────────────────────
    if table.getn(tankT) > 0 then
        yOff = yOff - 2
        RLHeader("Tanks", 0.78,0.61,0.43, 0.15)
        for _,key in ipairs(tankT) do
            local m = tMeta[key]
            local tcR,tcG,tcB = 0.78,0.61,0.43
            if tmpl.roster and tmpl.roster[m.tvalue] then
                tcR,tcG,tcB = GetClassColor(tmpl.roster[m.tvalue].class)
            end
            RLTargetBlock(m, tHeals[key], tcR,tcG,tcB)
        end
    end

    -- ── Groups ─────────────────────────────────────────────────────
    if table.getn(groupT) > 0 then
        yOff = yOff - 2
        RLHeader("Groups", 0.5,0.85,1.0, 0.12)
        for _,key in ipairs(groupT) do
            RLTargetBlock(tMeta[key], tHeals[key], 0.5,0.85,1.0)
        end
    end

    -- ── Custom ─────────────────────────────────────────────────────
    if table.getn(customT) > 0 then
        yOff = yOff - 2
        RLHeader("Custom", 0.9,0.6,1.0, 0.12)
        for _,key in ipairs(customT) do
            RLTargetBlock(tMeta[key], tHeals[key], 0.9,0.6,1.0)
        end
    end

    if table.getn(tankT)==0 and table.getn(groupT)==0 and table.getn(customT)==0 then
        local noFs = rlFrame:CreateFontString(nil,"OVERLAY")
        noFs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        noFs:SetPoint("TOPLEFT",rlFrame,"TOPLEFT",PAD+4,yOff)
        noFs:SetTextColor(0.5,0.5,0.5)
        noFs:SetText("(no assignments)")
        table.insert(rlFrame.content,noFs)
        yOff = yOff - rowStep
    end

    -- ── Innervate ──────────────────────────────────────────────────
    if tmpl.innervate and next(tmpl.innervate) then
        yOff = yOff - 2
        RLHeader("Innervate", 1,0.65,0.1, 0.15)
        local innList = {}
        for dn,hn in pairs(tmpl.innervate) do
            table.insert(innList, {druid=dn, healer=hn})
        end
        table.sort(innList, function(a,b) return a.druid < b.druid end)
        for _,pair in ipairs(innList) do
            local vdr,vdg,vdb = GetClassColor("DRUID")
            local vhr,vhg,vhb = 1,1,1
            if tmpl.roster and tmpl.roster[pair.healer] then
                vhr,vhg,vhb = GetClassColor(tmpl.roster[pair.healer].class)
            end
            local fakeM = {display=pair.druid, ttype="druid", tvalue=pair.druid}
            RLTargetBlock(fakeM, {pair.healer}, vdr,vdg,vdb)
        end
    end

    -- Resize to content
    local totalH = math.abs(yOff) + rowStep + 4
    if totalH < 80 then totalH = 80 end
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
                    UpdateAssignFrame() UpdateViewerFrame()
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
                    UpdateAssignFrame() UpdateViewerFrame()
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
                    UpdateAssignFrame() UpdateViewerFrame()
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
                    UpdateAssignFrame() UpdateViewerFrame()
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

-- Removes players no longer in the current raid from roster and healers list.
-- Called on every RAID_ROSTER_UPDATE so the viewer never shows stale players.
local function CleanRosterFromCurrentRaid()
    local tmpl = GetActiveTemplate()
    if not tmpl then return end
    local numRaid = GetNumRaidMembers()
    if numRaid == 0 then return end
    local members = GetRaidMembers()
    if HA_reloadProtect then
        if table.getn(members) > 0 then
            HA_reloadProtect = false
        else
            return
        end
    end
    local currentMembers = {}
    for _,m in ipairs(members) do currentMembers[m.name] = m end
    local toRemove = {}
    for pname,_ in pairs(tmpl.roster) do
        if not currentMembers[pname] then
            table.insert(toRemove, pname)
        end
    end
    for _,pname in ipairs(toRemove) do
        tmpl.roster[pname] = nil
    end
    if tmpl.healers then
        local newHealers = {}
        for _,h in ipairs(tmpl.healers) do
            if currentMembers[h.name] then
                table.insert(newHealers, h)
            end
        end
        tmpl.healers = newHealers
    end
    -- Remove innervate assignments if the druid or healer has left the raid
    if tmpl.innervate then
        for dname,hname in pairs(tmpl.innervate) do
            if not currentMembers[dname] or not currentMembers[hname] then
                tmpl.innervate[dname] = nil
            end
        end
    end
end

local function RebuildRosterRows()
    if not rosterFrame then return end

    for _,r in ipairs(rosterRowWidgets) do r:Hide() end
    rosterRowWidgets = {}

    local tmpl = GetActiveTemplate()
    if not tmpl then return end

    CleanRosterFromCurrentRaid()

    local members = GetRaidMembers()
    local numRaid = GetNumRaidMembers()
    -- Build lookup of current raid members
    local currentMembers = {}
    for _,m in ipairs(members) do
        currentMembers[m.name] = m
    end
    -- Add new members, update existing (always safe)
    for _,m in ipairs(members) do
        if not tmpl.roster[m.name] then
            tmpl.roster[m.name] = {class=m.class, subgroup=m.subgroup or 1}
        else
            tmpl.roster[m.name].class    = m.class
            tmpl.roster[m.name].subgroup = m.subgroup or tmpl.roster[m.name].subgroup or 1
        end
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
                    if entry.tagT then entry.tagT = nil else entry.tagT = true end
                    if entry.tagT then entry.tagH = nil end
                    -- If T tag removed: clean this player from all healer targets
                    if not entry.tagT then
                        for _,h in ipairs(tmpl.healers) do
                            local newTargets = {}
                            for _,t in ipairs(h.targets) do
                                if not (t.type == TYPE_TANK and t.value == capturedName) then
                                    table.insert(newTargets, t)
                                end
                            end
                            h.targets = newTargets
                        end
                    end
                    SyncHealersFromRoster(tmpl)
                    PersistTemplate()
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame() UpdateViewerFrame()
                    UpdateDruidAssignFrame()
                end
            end)

            hBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedName]
                if entry then
                    if entry.tagH then entry.tagH = nil else entry.tagH = true end
                    if entry.tagH then entry.tagT = nil end
                    -- If H tag removed: clear innervate assignment for this healer
                    if not entry.tagH and tmpl.innervate then
                        for dname,hname in pairs(tmpl.innervate) do
                            if hname == capturedName then
                                tmpl.innervate[dname] = nil
                            end
                        end
                    end
                    SyncHealersFromRoster(tmpl)
                    PersistTemplate()
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame() UpdateViewerFrame()
                    UpdateDruidAssignFrame()
                end
            end)

            local capturedVName = p.name
            vBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedVName]
                if entry then
                    if entry.tagV then entry.tagV = nil else entry.tagV = true end
                    PersistTemplate()
                    RebuildRosterRows()
                    UpdateAssignFrame() UpdateViewerFrame()
                    UpdateDruidAssignFrame()
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
            UpdateAssignFrame() UpdateViewerFrame()
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
        UpdateAssignFrame() UpdateViewerFrame()
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
                UpdateAssignFrame() UpdateViewerFrame()
                UpdateDruidAssignFrame()
            else
                assignFrame:Hide()
            end
        end
    end)
    local showLbl = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    showLbl:SetPoint("LEFT",showCB,"RIGHT",4,0)
    showLbl:SetText("Show Assignments outside raid")
    y = y-26

    -- Hide in Battleground checkbox
    local bgCB = CreateFrame("CheckButton",nil,optionsFrame,"UICheckButtonTemplate")
    bgCB:SetWidth(20)
    bgCB:SetHeight(20)
    bgCB:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    bgCB:SetChecked(HealAssignDB.options.hideInBG ~= false)
    bgCB:SetScript("OnClick",function()
        HealAssignDB.options.hideInBG = this:GetChecked()
        UpdateAssignFrame() UpdateViewerFrame()
        UpdateDruidAssignFrame()
    end)
    local bgLbl = optionsFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    bgLbl:SetPoint("LEFT",bgCB,"RIGHT",4,0)
    bgLbl:SetText("Hide in Battlegrounds")
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
-- MINIMAP BUTTON
-- Frame is created via HealAssign.xml (following ItemRack pattern)
-------------------------------------------------------------------------------
-- Open mainFrame with rights check and HA_OPEN broadcast
local function HA_OpenMainFrame()
    if not HasEditorRights() then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Only Raid Leader or Assistant can open the editor.")
        return
    end
    -- Warn if someone else has it open (auto-expire after 5 min)
    if HA_editorOpenBy and HA_editorOpenTime and (GetTime() - HA_editorOpenTime) < 300 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Editor is open at |cffffd700"..HA_editorOpenBy.."|r!")
    end
    -- Broadcast that we opened it
    local chan = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
    if chan then
        pcall(SendAddonMessage, COMM_PREFIX, "HA_OPEN;"..UnitName("player"), chan)
    end
    if _CreateMainFrame then _CreateMainFrame() end
end

-- Close mainFrame and broadcast HA_CLOSE
local function HA_CloseMainFrame()
    if mainFrame then mainFrame:Hide() end
    local chan = GetNumRaidMembers() > 0 and "RAID" or (GetNumPartyMembers() > 0 and "PARTY" or nil)
    if chan then
        pcall(SendAddonMessage, COMM_PREFIX, "HA_CLOSE", chan)
    end
end

local function CreateMinimapButton()
    if not HealAssignMinimapBtn then return end

    -- Position on minimap edge
    local angle = HealAssignDB.minimapAngle or 220
    local function UpdateMinimapPos(a)
        local x = math.cos(math.rad(a)) * 80
        local y = math.sin(math.rad(a)) * 80
        HealAssignMinimapBtn:ClearAllPoints()
        HealAssignMinimapBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - x, y - 52)
    end
    UpdateMinimapPos(angle)
    HealAssignMinimapBtn:Show()

    -- Click: toggle main window
    HealAssignMinimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    HealAssignMinimapBtn:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            if optionsFrame and optionsFrame:IsShown() then
                optionsFrame:Hide()
            else
                HealAssign_OpenOptions()
            end
        else
            if mainFrame and mainFrame:IsShown() then
                HA_CloseMainFrame()
            else
                HA_OpenMainFrame()
            end
        end
    end)

    -- Tooltip
    HealAssignMinimapBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("HealAssign v"..ADDON_VERSION)
        GameTooltip:AddLine("Left click: toggle main window", 1, 1, 1)
        GameTooltip:AddLine("Right click: options", 1, 1, 1)
        GameTooltip:Show()
    end)
    HealAssignMinimapBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Drag to reposition around minimap
    HealAssignMinimapBtn:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            cx, cy = cx/s, cy/s
            local a = math.deg(math.atan2(cy - my, cx - mx))
            HealAssignDB.minimapAngle = a
            UpdateMinimapPos(a)
        end)
    end)
    HealAssignMinimapBtn:SetScript("OnDragStop", function()
        this:UnlockHighlight()
        this:SetScript("OnUpdate", nil)
    end)
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
                UpdateAssignFrame() UpdateViewerFrame()
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
            UpdateAssignFrame() UpdateViewerFrame()
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
_UpdateAssignFrame      = function()
    UpdateAssignFrame() UpdateViewerFrame()
    UpdateViewerFrame()
end
_CreateMainFrame        = CreateMainFrame
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

    -- Editor open/close broadcast
    local _,_,openName = string.find(msg,"^HA_OPEN;(.+)$")
    if openName then
        HA_editorOpenBy   = openName
        HA_editorOpenTime = GetTime()
        -- Warn if we also have mainFrame open
        if mainFrame and mainFrame:IsShown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444HealAssign:|r Editor also opened by |cffffd700"..openName.."|r - avoid simultaneous editing!")
        end
        return
    end

    if msg == "HA_CLOSE" then
        if HA_editorOpenBy == sender then
            HA_editorOpenBy   = nil
            HA_editorOpenTime = nil
        end
        return
    end

    -- Innervate cast broadcast: INN_CAST;druidName
    local _,_,innCaster = string.find(msg,"^INN_CAST;(.+)$")
    if innCaster then
        innCD[innCaster] = GetTime()
        UpdateAssignFrame() UpdateViewerFrame()
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
            UpdateAssignFrame() UpdateViewerFrame()
        end
        return
    end

    -- BR: dead T/H notification
    local _,_,brDeadName = string.find(msg,"^BR_DEAD;(.+)$")
    if brDeadName then
        BR_AddDead(brDeadName)
        UpdateDruidAssignFrame()
        return
    end

    -- BR: druid targeting
    local _,_,brDruid,brTarget = string.find(msg,"^BR_TARGET;([^;]+);(.+)$")
    if brDruid then
        brTargeted[brDruid] = brTarget
        UpdateDruidAssignFrame()
        return
    end

    -- BR: druid cleared target
    local _,_,brClearDruid = string.find(msg,"^BR_CLEAR;(.+)$")
    if brClearDruid then
        brTargeted[brClearDruid] = nil
        UpdateDruidAssignFrame()
        return
    end

    -- BR: cast broadcast (to track CD for others)
    local _,_,brCastDruid = string.find(msg,"^BR_CAST;(.+)$")
    if brCastDruid then
        brCD[brCastDruid] = GetTime()
        UpdateDruidAssignFrame()
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
                    UpdateAssignFrame() UpdateViewerFrame()
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
            HealAssignDB.templates[tmpl.name] = DeepCopy(tmpl)
            -- Only apply received template if we are NOT the raid leader
            -- (RL sends templates, non-RL receives and applies them)
            if not IsRaidLeader() then
                HealAssignDB.activeTemplate = tmpl.name
                currentTemplate = tmpl
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Received '"..tmpl.name.."' from "..sender)
                if mainFrame and mainFrame:IsShown() then RebuildMainGrid() end
                UpdateAssignFrame() UpdateViewerFrame()
                if IsRaidLeader() then CreateRLFrame() end
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Stored template '"..tmpl.name.."' from "..sender)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- DEATH DETECTION
-------------------------------------------------------------------------------
local deathFrame = CreateFrame("Frame","HealAssignDeathFrame")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_HOSTILE_DEATH")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_KILLS")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLYPLAYER_DEATH")
deathFrame:RegisterEvent("CHAT_MSG_COMBAT_FRIENDLY_DEATH")
deathFrame:RegisterEvent("CHAT_MSG_SYSTEM")
deathFrame:RegisterEvent("UNIT_HEALTH")
-- Debounce for UNIT_HEALTH: do not update frames more than once per 2 seconds
-- for the same dead player (event fires repeatedly)
local unitHealthLastProcessed = {}
deathFrame:SetScript("OnEvent",function()
    -- UNIT_HEALTH: catch death when health hits 0
    if event == "UNIT_HEALTH" then
        local unit = arg1
        if not unit then return end
        if not UnitIsDeadOrGhost(unit) then
            -- Player is alive again - reset cache so next death triggers correctly
            local aliveName = UnitName(unit)
            if aliveName then unitHealthLastProcessed[aliveName] = nil end
            return
        end
        local deadName = UnitName(unit)
        if not deadName then return end
        -- Debounce: skip repeated triggers within 2 seconds
        local now = GetTime()
        if unitHealthLastProcessed[deadName] and
           now - unitHealthLastProcessed[deadName] < 2 then return end
        unitHealthLastProcessed[deadName] = now
        local tmpl2 = GetActiveTemplate()
        if not tmpl2 or not tmpl2.roster then return end
        local pd = tmpl2.roster[deadName]
        if not pd then return end
        if pd.tagT or pd.tagH then
            BR_AddDead(deadName)
            UpdateDruidAssignFrame()
            UpdateAssignFrame() UpdateViewerFrame()
        end
        return
    end

    local msg = arg1
    if not msg then return end


    local deadName = nil
    if msg == "You die." then
        deadName = UnitName("player")
    else
        -- "X dies." pattern
        local _,_,cap = string.find(msg,"^(.+) dies%.$")
        if cap then deadName = cap end
        -- "X has died." pattern (also used in 1.12)
        if not deadName then
            local _,_,cap2 = string.find(msg,"^(.+) has died%.$")
            if cap2 then deadName = cap2 end
        end
    end
    if not deadName then return end

    local tmpl = GetActiveTemplate()
    if not tmpl then return end

    local numRaid  = GetNumRaidMembers()
    local numParty = GetNumPartyMembers()
    if (not numRaid or numRaid == 0) and (not numParty or numParty == 0) then return end

    local chan
    if numRaid and numRaid > 0 then chan = "RAID"
    elseif numParty and numParty > 0 then chan = "PARTY" end

    -- Healer death
    for _,h in ipairs(tmpl.healers) do
        if h.name == deadName then
            if chan then pcall(SendAddonMessage, COMM_PREFIX,"DEAD;"..deadName, chan) end
            TriggerHealerDeath(deadName, h.targets)
            UpdateAssignFrame() UpdateViewerFrame()
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
            -- Also add to BR dead list
            BR_AddDead(deadName)
            if chan then pcall(SendAddonMessage, COMM_PREFIX,"BR_DEAD;"..deadName, chan) end
            UpdateDruidAssignFrame()
            return
        end
    end

    -- Tank death (tagT) or healer not in tmpl.healers but has tagH
    if tmpl.roster and tmpl.roster[deadName] then
        local pd = tmpl.roster[deadName]
        if pd.tagT or pd.tagH then
            BR_AddDead(deadName)
            if chan then pcall(SendAddonMessage, COMM_PREFIX,"BR_DEAD;"..deadName, chan) end
            UpdateDruidAssignFrame()
            UpdateAssignFrame() UpdateViewerFrame()
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
            UpdateAssignFrame() UpdateViewerFrame()
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
        end
    end
end)

-- Resurrection detection via combat log
local rezFrame = CreateFrame("Frame","HealAssignRezFrame")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_RESURRECT")
rezFrame:RegisterEvent("UNIT_HEALTH")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_CASTOTHER")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_OTHER_CASTOTHER")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_BUFFS")
rezFrame:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_SELF_BUFFS")

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
    -- Ignore periodic buff ticks: only record cast if CD is not already running
    if INN_GetCDRemaining(casterDruid) > 0 then return end
    innCD[casterDruid] = GetTime()
    if HealAssignDB and HealAssignDB.innCD then
        HealAssignDB.innCD[casterDruid] = {t = GetTime(), rem = INN_CD_FULL}
    end
    INN_ALERT_SHOWN[casterDruid] = nil
    UpdateAssignFrame() UpdateViewerFrame()
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
        UpdateAssignFrame() UpdateViewerFrame()
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
        BR_RemoveDead(name)
    end
    if table.getn(toRez) > 0 then
        UpdateDruidAssignFrame()
        UpdateAssignFrame() UpdateViewerFrame()
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

    -- UNIT_HEALTH: if someone in brDeadList is now alive - remove them
    -- Debounce: do not process the same player more than once per 2 seconds
    if event == "UNIT_HEALTH" then
        local unit = arg1
        if unit and not UnitIsDeadOrGhost(unit) then
            local aliveName = UnitName(unit)
            if aliveName then
                -- Debounce
                local now2 = GetTime()
                if unitHealthLastProcessed[aliveName] and
                   now2 - unitHealthLastProcessed[aliveName] < 2 then return end
                for _,d in ipairs(brDeadList) do
                    if d.name == aliveName then
                        unitHealthLastProcessed[aliveName] = now2
                        BR_RemoveDead(aliveName)
                        RemoveDeadHealer(aliveName)
                        UpdateDruidAssignFrame()
                        UpdateAssignFrame() UpdateViewerFrame()
                        break
                    end
                end
            end
        end
        return
    end

    -- BR cast detection via combat log
    -- "X casts Rebirth on Y" / "You cast Rebirth on Y"
    if event == "CHAT_MSG_SPELL_SELF_CASTOTHER" or event == "CHAT_MSG_SPELL_OTHER_CASTOTHER" then
        local msg2 = arg1
        if msg2 then
            local _,_,caster,target = string.find(msg2,"^(.+) casts Rebirth on (.+)%.$")
            if not caster then
                local _,_,t2 = string.find(msg2,"^You cast Rebirth on (.+)%.$")
                if t2 then caster = UnitName("player") target = t2 end
            end
            if caster then
                brCD[caster] = GetTime()
                brTargeted[caster] = nil  -- released target after cast
                BR_BroadcastCast(caster)
                UpdateDruidAssignFrame()
            end
        end
        -- fall through to resurrection check below
    end

    -- Combat log resurrection messages
    local msg = arg1
    if not msg then return end
    local rezzed = nil
    -- WoW 1.12 resurrection messages
    if string.find(msg, "^You have been resurrected") or
       string.find(msg, "^You are resurrected") or
       string.find(msg, "^You have been restored to life") then
        rezzed = UnitName("player")
    else
        local _,_,cap = string.find(msg, "^(.+) is resurrected")
        if not cap then _,_,cap = string.find(msg, "^(.+) comes back to life") end
        if not cap then _,_,cap = string.find(msg, "^(.+) has been resurrected") end
        if cap then rezzed = cap end
    end
    if rezzed then
        RemoveDeadHealer(rezzed)
        BR_RemoveDead(rezzed)
        UpdateDruidAssignFrame()
        UpdateAssignFrame() UpdateViewerFrame()
    end
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
                if not currentTemplate.roster   then currentTemplate.roster   = {} end
                if not currentTemplate.healers  then currentTemplate.healers  = {} end
                -- Fix: convert false tags to nil (false is falsy in Lua tag checks)
                for _,pdata in pairs(currentTemplate.roster) do
                    if pdata.tagT == false then pdata.tagT = nil end
                    if pdata.tagH == false then pdata.tagH = nil end
                    if pdata.tagV == false then pdata.tagV = nil end
                end
            end
            if not currentTemplate then currentTemplate = NewTemplate("") end
            if not currentTemplate.innervate then currentTemplate.innervate = {} end
            CreateAssignFrame()
            CreateAlertFrame()
            -- Show assign frame only if already in raid (e.g. reloadui)
            if GetNumRaidMembers() > 0 then
                UpdateAssignFrame() UpdateViewerFrame()
            end
            CreateMinimapButton()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.." loaded. |cffffffff/ha|r to open.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(arg1,arg2,arg3,arg4)

    elseif event == "PLAYER_ENTERING_WORLD" then
        if INN_BroadcastMyCD then INN_BroadcastMyCD() end
        UpdateAssignFrame() UpdateViewerFrame()
        UpdateDruidAssignFrame()

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        local inRaid = GetNumRaidMembers() > 0
        if inRaid then
            HA_wasInRaid = true
            HA_reloadProtect = false  -- raid confirmed, protection no longer needed
            CleanRosterFromCurrentRaid()
            UpdateAssignFrame() UpdateViewerFrame()
            UpdateDruidAssignFrame()
        else
            local showOutside = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
            if assignFrame then
                if showOutside then UpdateAssignFrame() UpdateViewerFrame()
                else assignFrame:Hide() end
            end
            if druidAssignFrame then druidAssignFrame:Hide() end
        end
        if inRaid then
            if mainFrame and mainFrame:IsShown() then RebuildMainGrid() end
            if rosterFrame and rosterFrame:IsShown() then RebuildRosterRows() end
            if rlFrame and rlFrame:IsShown() then UpdateRLFrame() end
        else
            if rosterFrame and rosterFrame:IsShown() then rosterFrame:Hide() end
            if rlFrame and rlFrame:IsShown() then rlFrame:Hide() end
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
local innRows = {}  -- row pool: {cell, dLabel, hLabel, ddBtn}

local function INN_RebuildAssignRows()
    if not innervateFrame then return end

    local tmpl = GetActiveTemplate()
    local druids  = INN_GetDruids()
    local healers = tmpl and INN_GetHealers() or {}

    local rowH    = 26
    local cellW2  = 270

    -- Expand pool if needed
    while table.getn(innRows) < table.getn(druids) + 1 do
        local cell2 = CreateFrame("Frame",nil,innervateFrame)
        cell2:SetWidth(cellW2)
        cell2:SetHeight(rowH)
        cell2:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true,tileSize=8,edgeSize=8,
            insets={left=3,right=3,top=3,bottom=3}
        })
        cell2:SetBackdropColor(0.07,0.07,0.14,0.97)
        cell2:SetBackdropBorderColor(0.25,0.35,0.6,0.8)
        cell2:Hide()
        local dr,dg,db = GetClassColor("DRUID")
        local dLabel = cell2:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        dLabel:SetPoint("LEFT",cell2,"LEFT",6,0)
        dLabel:SetWidth(100)
        dLabel:SetJustifyH("LEFT")
        dLabel:SetTextColor(dr,dg,db)
        local hLabel = cell2:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
        hLabel:SetPoint("LEFT",cell2,"LEFT",112,0)
        hLabel:SetWidth(90)
        hLabel:SetJustifyH("LEFT")
        local ddBtn = CreateFrame("Button",nil,cell2,"UIPanelButtonTemplate")
        ddBtn:SetWidth(50)
        ddBtn:SetHeight(16)
        ddBtn:SetPoint("RIGHT",cell2,"RIGHT",-4,0)
        ddBtn:SetText("Assign")
        cell2.dLabel = dLabel
        cell2.hLabel = hLabel
        cell2.ddBtn  = ddBtn
        -- "no druids" row (reuse first pool slot)
        table.insert(innRows, cell2)
    end

    -- Hide all pool rows
    for _,r in ipairs(innRows) do r:Hide() end

    local y = -44

    if table.getn(druids) == 0 then
        local noRow = innRows[1]
        noRow:ClearAllPoints()
        noRow:SetPoint("TOPLEFT",innervateFrame,"TOPLEFT",10,-44)
        noRow:SetWidth(270) noRow:SetHeight(20)
        -- "no druids" text stored in dLabel
        noRow.dLabel:SetTextColor(0.5,0.5,0.5)
        noRow.dLabel:SetText("  No non-healer druids in roster.")
        noRow.dLabel:SetWidth(260)
        noRow.hLabel:SetText("")
        noRow.ddBtn:Hide()
        noRow:Show()
        y = y - rowH
    else
        for i,dname in ipairs(druids) do
            local cell2 = innRows[i]
            local assigned = tmpl and tmpl.innervate and tmpl.innervate[dname]
            cell2:ClearAllPoints()
            cell2:SetPoint("TOPLEFT",innervateFrame,"TOPLEFT",10,y)
            -- Druid name
            local dr,dg,db = GetClassColor("DRUID")
            cell2.dLabel:SetTextColor(dr,dg,db)
            cell2.dLabel:SetText(dname)
            cell2.dLabel:SetWidth(100)
            -- Healer name
            if assigned then
                local hr,hg,hb = 1,1,1
                if tmpl and tmpl.roster and tmpl.roster[assigned] then
                    hr,hg,hb = GetClassColor(tmpl.roster[assigned].class)
                end
                cell2.hLabel:SetTextColor(hr,hg,hb)
                cell2.hLabel:SetText(assigned)
            else
                cell2.hLabel:SetTextColor(0.4,0.4,0.4)
                cell2.hLabel:SetText("---")
            end
            -- Assign button - reassign OnClick with current closure
            cell2.ddBtn:Show()
            local capturedDruid = dname
            cell2.ddBtn:SetScript("OnClick",function()
                local t2 = GetActiveTemplate()
                if not t2 then return end
                local items = {}
                table.insert(items,{text="(clear)",r=0.5,g=0.5,b=0.5,clear=true})
                for _,hname in ipairs(INN_GetHealers()) do
                    local pr,pg,pb = 1,1,1
                    if t2.roster and t2.roster[hname] then
                        pr,pg,pb = GetClassColor(t2.roster[hname].class)
                    end
                    table.insert(items,{text=hname,r=pr,g=pg,b=pb,hname=hname})
                end
                if table.getn(items)==1 then
                    table.insert(items,{text="(no healers tagged H)",r=0.5,g=0.5,b=0.5})
                end
                ShowDropdown(this, items, function(item)
                    if not t2.innervate then t2.innervate = {} end
                    if item.clear then
                        t2.innervate[capturedDruid] = nil
                    elseif item.hname then
                        t2.innervate[capturedDruid] = item.hname
                    end
                    PersistTemplate()
                    INN_BroadcastAssignments()
                    INN_RebuildAssignRows()
                    UpdateAssignFrame() UpdateViewerFrame()
                    UpdateDruidAssignFrame()
                end, 140)
            end)
            cell2:Show()
            y = y - rowH - 4
        end
    end

    local totalH = math.abs(y) + 20
    if totalH < 80 then totalH = 80 end
    innervateFrame:SetHeight(totalH)
    innervateFrame:SetWidth(290)
end

function CreateInnervateFrame()
    if innervateFrame then
        innervateFrame:SetFrameStrata("HIGH")
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
    innervateFrame:SetFrameLevel(50)
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
            UpdateAssignFrame() UpdateViewerFrame()
        end
    end

    -- Update druid assign frame every tick (mana refresh + CD timer).
    local myPdata3 = tmpl.roster and tmpl.roster[myName]
    local _,playerClass3 = UnitClass("player")
    local amDruid = playerClass3 == "DRUID" and not (myPdata3 and myPdata3.tagH)
    local amDruidHealer = playerClass3 == "DRUID" and (myPdata3 and myPdata3.tagH)
    if amDruid then
        -- Always update druid frame (covers both innervate mana display and rebirth CD)
        UpdateDruidAssignFrame()
    end
    -- For druid-healers: update assignFrame every tick to refresh BR CD countdown
    if amDruidHealer and assignFrame and assignFrame:IsShown() then
        if BR_GetCDRemaining(myName) > 0 or next(brTargeted) then
            UpdateAssignFrame() UpdateViewerFrame()
        end
    end
    if amDruid and tmpl.innervate and tmpl.innervate[myName] then
        -- BigWigs-style green alert when assigned healer drops below 50% mana.
        -- Alert fires only once per CD cycle: after casting Innervate the alert is
        -- suppressed for the entire cooldown duration, then resets when CD expires.
        local assignedH = tmpl.innervate[myName]
        local mPct      = INN_GetHealerMana(assignedH)
        local cdRem     = INN_GetCDRemaining(myName)
        if cdRem > 0 then
            -- Innervate on cooldown: suppress all alerts until CD expires
            INN_ALERT_SHOWN[myName] = true
        else
            -- CD is ready: allow alert to fire when healer falls below 50%
            -- but only if the healer is alive
            local healerDead = false
            for _,dd in ipairs(deadHealers) do
                if dd.name == assignedH then healerDead = true break end
            end
            if healerDead then
                INN_ALERT_SHOWN[myName] = true  -- suppress until healer is alive again
            elseif mPct and mPct < 50 then
                if not INN_ALERT_SHOWN[myName] then
                    INN_ALERT_SHOWN[myName] = true
                    INN_ShowAlert(assignedH, mPct)
                end
            elseif mPct and mPct >= 60 then
                -- Healer recovered above 60%: reset flag so next drop triggers again
                INN_ALERT_SHOWN[myName] = nil
            end
        end
    end

    -- Auto-sync brTargeted with real in-game target for self.
    -- If the druid manually changed/dropped target outside the frame - reset claim.
    -- Applies to ALL druids (including druid-healers with tagH)
    if playerClass3 == "DRUID" and brTargeted[myName] then
        local realTarget = UnitName("target")
        if realTarget ~= brTargeted[myName] then
            brTargeted[myName] = nil
            BR_BroadcastTarget(myName, nil)
            UpdateDruidAssignFrame()
            UpdateAssignFrame() UpdateViewerFrame()
        end
    end

    -- Update viewer assignFrame if open: always refresh when brTargeted has entries
    -- or there are active rebirth CDs (covers target claim/unclaim and CD countdown)
    local myPdata4 = tmpl.roster and tmpl.roster[myName]
    if myPdata4 and myPdata4.tagV then
        local needsUpdate = false
        if next(brTargeted) then needsUpdate = true end
        if not needsUpdate then
            for dname,_ in pairs(tmpl.roster) do
                if BR_GetCDRemaining(dname) > 0 then needsUpdate = true break end
            end
        end
        if needsUpdate then
            UpdateViewerFrame()
        end
    end
    -- innervateFrame is updated only on data change (via INN_RebuildAssignRows),
    -- not every second - removed to eliminate memory leak
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
            else assignFrame:Show() UpdateAssignFrame() UpdateViewerFrame() end
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
        if mainFrame and mainFrame:IsShown() then
            HA_CloseMainFrame()
            CloseDropdown()
            if rosterFrame then rosterFrame:Hide() end
        else
            HA_OpenMainFrame()
        end
    end


end
