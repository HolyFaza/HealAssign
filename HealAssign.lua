-- HealAssign.lua v2.0
-- WoW 1.12.1 Heal Assignment Addon
-- Healer-centric assignment system

-------------------------------------------------------------------------------
-- CONSTANTS
-------------------------------------------------------------------------------
local ADDON_NAME    = "HealAssign"
local ADDON_VERSION = "2.0.4"
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
currentTemplate  = nil
HA_wasInRaid     = false  -- true only after first RAID_ROSTER_UPDATE(inRaid=true) this session
HA_reloadProtect = true   -- true on fresh load, blocks roster clear until raid confirmed

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

-------------------------------------------------------------------------------
-- REBIRTH SYSTEM UTILITIES
-------------------------------------------------------------------------------
local BR_CD_FULL    = 1800  -- 30 min in vanilla
local BR_ICON       = "Interface\\Icons\\Spell_Nature_Reincarnation"
local brDeadList    = {}    -- [{name, time}] мёртвые T/H для BR
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
    if not HA_ShouldShow() then
        assignFrame:Hide()
        return
    end

    local myName   = UnitName("player")
    local tmpl     = GetActiveTemplate()
    local fontSize = (HealAssignDB.options and HealAssignDB.options.fontSize) or 12
    local PAD     = 6
    local ICON_SZ = math.floor(fontSize * 2.5)
    if ICON_SZ < 20 then ICON_SZ = 20 end
    if ICON_SZ > 48 then ICON_SZ = 48 end

    local myTargets     = {}
    local myDeadTargets = {}

    -- Determine player role
    local myPdata = tmpl and tmpl.roster and tmpl.roster[myName]
    local isHealer = myPdata and myPdata.tagH
    local isViewer = myPdata and myPdata.tagV

    -- assignFrame visibility rules:
    --   H only        -> healer window
    --   V (any combo) -> viewer window (overrides H)
    --   anything else -> hide
    if not isHealer and not isViewer then
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

    -- Frame width scales cleanly with font size
    local frameW
    if isViewer then
        -- Viewer: wider to fit two-column table
        frameW = math.max(200, math.min(380, fontSize * 18))
    else
        -- Healer/druid: single-column, narrower
        frameW = math.max(130, math.min(260, fontSize * 13))
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

    local titleFS = assignFrame:CreateFontString(nil,"OVERLAY","GameFontNormal")
    titleFS:SetPoint("TOP",assignFrame,"TOP",0,-3)
    titleFS:SetTextColor(1,0.82,0.0)  -- gold, same as section headers
    titleFS:SetText(isViewer and "Assignments" or "My Assignments")
    table.insert(assignFrame.content,titleFS)

    -- Viewer (V tag): table layout
    if isViewer and tmpl then
        local PAD    = 6
        local innerW = frameW - PAD*2
        local colL   = math.floor(innerW * 0.44)
        local colR   = innerW - colL - 1

        -- Centered full-width header (main or sub)
        local function AddHeader(text, r,g,b, bgMul)
            bgMul = bgMul or 0.18
            local hdr = CreateFrame("Frame",nil,assignFrame)
            hdr:SetPoint("TOPLEFT", assignFrame,"TOPLEFT", PAD, yOff)
            hdr:SetWidth(innerW)
            hdr:SetHeight(rowH + 2)
            hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
                insets={left=0,right=0,top=0,bottom=0}})
            hdr:SetBackdropColor(r*bgMul, g*bgMul, b*bgMul, 0.7)
            table.insert(assignFrame.content, hdr)
            local fs = hdr:CreateFontString(nil,"OVERLAY")
            fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
            fs:SetPoint("LEFT", hdr,"LEFT",  0, 0)
            fs:SetPoint("RIGHT",hdr,"RIGHT", 0, 0)
            fs:SetJustifyH("CENTER")
            fs:SetTextColor(r,g,b)
            fs:SetText(text)
            yOff = yOff - (rowH + 4)
        end

        -- Collect targets
        local tankTargets2, groupTargets2, customTargets2 = {},{},{}
        local targetMeta2, targetHeals2, seen2 = {},{},{}
        for _,h in ipairs(tmpl.healers) do
            for _,t in ipairs(h.targets) do
                local key = (t.type or "").."~"..(t.value or "")
                if not seen2[key] then
                    seen2[key] = true
                    -- Display: for tanks use just the name (no [Tank] prefix)
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

        -- Render one bordered block: target name row + healer rows, all inside a thin-border frame
        local function RenderTargetBlock(m, heals, tcR,tcG,tcB)
            local numRows = table.getn(heals)
            if numRows == 0 then numRows = 1 end
            local blockH = rowStep * numRows + 2  -- total pixel height of this block

            -- Outer bordered container
            local block = CreateFrame("Frame",nil,assignFrame)
            block:SetPoint("TOPLEFT", assignFrame,"TOPLEFT", PAD, yOff)
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
            table.insert(assignFrame.content, block)

            -- Target name (left cell of first row, inside block)
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
            vdiv:SetPoint("TOPLEFT",    block,"TOPLEFT",  colL, -2)
            vdiv:SetPoint("BOTTOMLEFT", block,"BOTTOMLEFT",colL,  2)
            vdiv:SetTexture(tcR*0.5, tcG*0.5, tcB*0.5, 0.5)

            -- Healer rows (right cell)
            for hi,hname in ipairs(heals) do
                local hr2,hg2,hb2 = 1,1,1
                if tmpl.roster and tmpl.roster[hname] then
                    hr2,hg2,hb2 = GetClassColor(tmpl.roster[hname].class)
                end
                local isDead = false
                for _,dd in ipairs(deadHealers) do
                    if dd.name == hname then isDead=true break end
                end
                if isDead then hr2,hg2,hb2 = 1,0.15,0.15 end

                local fsH = block:CreateFontString(nil,"OVERLAY")
                fsH:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                fsH:SetPoint("TOPLEFT",block,"TOPLEFT", colL+4, -(2 + (hi-1)*rowStep))
                fsH:SetWidth(colR - 8)
                fsH:SetHeight(rowStep)
                fsH:SetJustifyH("LEFT")
                fsH:SetJustifyV("MIDDLE")
                fsH:SetTextColor(hr2,hg2,hb2)
                local healText = isDead and (hname.." [dead]") or hname
                fsH:SetText(healText)

                -- Horizontal separator between healers (except after last)
                if hi < numRows then
                    local hsep = block:CreateTexture(nil,"ARTWORK")
                    hsep:SetHeight(1)
                    hsep:SetPoint("TOPLEFT",  block,"TOPLEFT",  colL+2,  -(2 + hi*rowStep))
                    hsep:SetPoint("TOPRIGHT", block,"TOPRIGHT", -2,      -(2 + hi*rowStep))
                    hsep:SetTexture(0.3,0.3,0.3,0.3)
                end
            end

            yOff = yOff - blockH - 3  -- 3px gap between blocks
        end

        -- ── Main header ────────────────────────────────────────────────
        AddHeader("Heal Assignments", 1,0.8,0.2, 0.22)

        -- ── Tanks sub-section ──────────────────────────────────────────
        if table.getn(tankTargets2) > 0 then
            yOff = yOff - 2
            AddHeader("Tanks", 0.78,0.61,0.43, 0.15)
            for _,key in ipairs(tankTargets2) do
                local m = targetMeta2[key]
                local tcR,tcG,tcB = 0.78,0.61,0.43
                if tmpl.roster and tmpl.roster[m.tvalue] then
                    tcR,tcG,tcB = GetClassColor(tmpl.roster[m.tvalue].class)
                end
                RenderTargetBlock(m, targetHeals2[key], tcR,tcG,tcB)
            end
        end

        -- ── Groups sub-section ─────────────────────────────────────────
        if table.getn(groupTargets2) > 0 then
            yOff = yOff - 2
            AddHeader("Groups", 0.5,0.85,1.0, 0.12)
            for _,key in ipairs(groupTargets2) do
                local m = targetMeta2[key]
                RenderTargetBlock(m, targetHeals2[key], 0.5,0.85,1.0)
            end
        end

        -- ── Custom sub-section ─────────────────────────────────────────
        if table.getn(customTargets2) > 0 then
            yOff = yOff - 2
            AddHeader("Custom", 0.9,0.6,1.0, 0.12)
            for _,key in ipairs(customTargets2) do
                local m = targetMeta2[key]
                RenderTargetBlock(m, targetHeals2[key], 0.9,0.6,1.0)
            end
        end

        if table.getn(tankTargets2)==0 and table.getn(groupTargets2)==0 and table.getn(customTargets2)==0 then
            local noFs = assignFrame:CreateFontString(nil,"OVERLAY")
            noFs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
            noFs:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD+4,yOff)
            noFs:SetTextColor(0.5,0.5,0.5)
            noFs:SetText("(no assignments)")
            table.insert(assignFrame.content,noFs)
            yOff = yOff - rowStep
        end

        -- ── Innervate sub-section ──────────────────────────────────────
        if tmpl.innervate and next(tmpl.innervate) then
            yOff = yOff - 2
            AddHeader("Innervate", 1,0.65,0.1, 0.15)
            local innList2 = {}
            for dn,hn in pairs(tmpl.innervate) do
                table.insert(innList2, {druid=dn, healer=hn})
            end
            table.sort(innList2, function(a,b) return a.druid < b.druid end)
            for _,pair in ipairs(innList2) do
                local vdr,vdg,vdb = GetClassColor("DRUID")
                local vhr,vhg,vhb = 1,1,1
                if tmpl.roster and tmpl.roster[pair.healer] then
                    vhr,vhg,vhb = GetClassColor(tmpl.roster[pair.healer].class)
                end
                local fakeM = {display=pair.druid, ttype="druid", tvalue=pair.druid}
                local fakeHeals = {pair.healer}
                RenderTargetBlock(fakeM, fakeHeals, vdr,vdg,vdb)
            end
        end

        -- ── Rebirth sub-section ───────────────────────────────────────
        -- Same layout as Innervate: druid left column, target right column
        do
            yOff = yOff - 4
            AddHeader("Rebirth", 0.7,0.3,1, 0.15)

            -- Collect all non-healer druids
            local brDruids = {}
            if tmpl.roster then
                for pname,pd in pairs(tmpl.roster) do
                    if pd.class == "DRUID" and not pd.tagH then
                        table.insert(brDruids, pname)
                    end
                end
            end
            table.sort(brDruids)

            if table.getn(brDruids) == 0 then
                local noFs = assignFrame:CreateFontString(nil,"OVERLAY")
                noFs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                noFs:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD+4,yOff)
                noFs:SetTextColor(0.5,0.5,0.5)
                noFs:SetText("(no druids)")
                table.insert(assignFrame.content,noFs)
                yOff = yOff - rowStep
            else
                -- Build druid->target mapping:
                -- 1. Druids with explicit brTargeted claim keep their target
                -- 2. Remaining dead auto-assigned to free druids for display
                local druidTargets = {}
                local claimedDead  = {}
                for _,dname in ipairs(brDruids) do
                    local tgt = brTargeted[dname]
                    if tgt then
                        druidTargets[dname] = tgt
                        claimedDead[tgt] = true
                    end
                end
                -- Auto-assign unclaimed dead to free druids
                local freeDruids = {}
                for _,dname in ipairs(brDruids) do
                    if not druidTargets[dname] then
                        table.insert(freeDruids, dname)
                    end
                end
                local fdi = 1
                for _,d in ipairs(brDeadList) do
                    if not claimedDead[d.name] and fdi <= table.getn(freeDruids) then
                        druidTargets[freeDruids[fdi]] = d.name
                        fdi = fdi + 1
                    end
                end

                -- Three-column block for Rebirth rows:
                -- col1=druid name, col2=CD timer, col3=dead target
                local brCol1 = math.floor(innerW * 0.42)
                local brCol2 = math.floor(innerW * 0.16)
                local brCol3 = innerW - brCol1 - brCol2 - 2  -- 2 for dividers

                local function RenderRebirthBlock(druidName, cdRem2, targetName, isClaimed, dr2,dg2,db2)
                    local blockH = rowStep + 2
                    local block = CreateFrame("Frame",nil,assignFrame)
                    block:SetPoint("TOPLEFT", assignFrame,"TOPLEFT", PAD, yOff)
                    block:SetWidth(innerW)
                    block:SetHeight(blockH)
                    block:SetBackdrop({
                        bgFile   = "Interface\\Buttons\\WHITE8X8",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile=true, tileSize=8, edgeSize=8,
                        insets={left=2,right=2,top=2,bottom=2}
                    })
                    block:SetBackdropColor(dr2*0.05, dg2*0.05, db2*0.05, 0.4)
                    block:SetBackdropBorderColor(dr2*0.5, dg2*0.5, db2*0.5, 0.6)
                    table.insert(assignFrame.content, block)

                    -- Col 1: druid name
                    local fsD = block:CreateFontString(nil,"OVERLAY")
                    fsD:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                    fsD:SetPoint("TOPLEFT",block,"TOPLEFT",4,-2)
                    fsD:SetWidth(brCol1 - 8)
                    fsD:SetHeight(rowStep)
                    fsD:SetJustifyH("LEFT")
                    fsD:SetJustifyV("MIDDLE")
                    fsD:SetTextColor(dr2,dg2,db2)
                    fsD:SetText(druidName)

                    -- Divider 1 (after col1)
                    local vd1 = block:CreateTexture(nil,"ARTWORK")
                    vd1:SetWidth(1)
                    vd1:SetPoint("TOPLEFT",    block,"TOPLEFT",  brCol1, -2)
                    vd1:SetPoint("BOTTOMLEFT", block,"BOTTOMLEFT",brCol1,  2)
                    vd1:SetTexture(dr2*0.5, dg2*0.5, db2*0.5, 0.5)

                    -- Col 2: CD timer
                    local fsCD = block:CreateFontString(nil,"OVERLAY")
                    fsCD:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                    fsCD:SetPoint("TOPLEFT",block,"TOPLEFT", brCol1+4, -2)
                    fsCD:SetWidth(brCol2 - 8)
                    fsCD:SetHeight(rowStep)
                    fsCD:SetJustifyH("CENTER")
                    fsCD:SetJustifyV("MIDDLE")
                    if cdRem2 > 0 then
                        local cdText
                        if cdRem2 <= 90 then
                            cdText = math.ceil(cdRem2).."s"
                        else
                            cdText = math.ceil(cdRem2/60).."m"
                        end
                        fsCD:SetTextColor(1,1,0)
                        fsCD:SetText(cdText)
                    else
                        fsCD:SetText("")
                    end

                    -- Divider 2 (after col2)
                    local vd2 = block:CreateTexture(nil,"ARTWORK")
                    vd2:SetWidth(1)
                    vd2:SetPoint("TOPLEFT",    block,"TOPLEFT",  brCol1+brCol2+1, -2)
                    vd2:SetPoint("BOTTOMLEFT", block,"BOTTOMLEFT",brCol1+brCol2+1,  2)
                    vd2:SetTexture(dr2*0.5, dg2*0.5, db2*0.5, 0.5)

                    -- Col 3: dead target name
                    local fsTgt = block:CreateFontString(nil,"OVERLAY")
                    fsTgt:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
                    fsTgt:SetPoint("TOPLEFT",block,"TOPLEFT", brCol1+brCol2+5, -2)
                    fsTgt:SetWidth(brCol3 - 8)
                    fsTgt:SetHeight(rowStep)
                    fsTgt:SetJustifyH("LEFT")
                    fsTgt:SetJustifyV("MIDDLE")
                    if targetName then
                        if isClaimed then
                            fsTgt:SetTextColor(1,0.85,0.85)
                        else
                            fsTgt:SetTextColor(1,0.3,0.3)
                            fsTgt:SetText("|cffff4444[!]|r "..targetName)
                        end
                        if isClaimed then fsTgt:SetText(targetName) end
                    else
                        fsTgt:SetText("")
                    end

                    yOff = yOff - blockH - 3
                end

                -- One row per druid
                for _,dname in ipairs(brDruids) do
                    local tgt      = druidTargets[dname]
                    local cdRem    = BR_GetCDRemaining(dname)
                    local dr,dg,db = GetClassColor("DRUID")
                    local isClaimed = brTargeted[dname] ~= nil
                    RenderRebirthBlock(dname, cdRem, tgt, isClaimed, dr,dg,db)
                end

                -- Dead with no druid available (more dead than druids)
                local orphaned = {}
                for _,d in ipairs(brDeadList) do
                    local assigned = false
                    for _,dtgt in pairs(druidTargets) do
                        if dtgt == d.name then assigned = true break end
                    end
                    if not assigned then table.insert(orphaned, d.name) end
                end
                for _,uname in ipairs(orphaned) do
                    local ur,ug,ub = 1,0.2,0.2
                    local fakeM2 = {display="|cffff4444[!] No druid:|r "..uname, ttype="dead", tvalue=uname}
                    RenderTargetBlock(fakeM2, {}, ur,ug,ub)
                end
            end
        end

        local totalH = math.abs(yOff) + rowStep + 4
        if totalH < titleH + rowStep then totalH = titleH + rowStep end
        assignFrame:SetHeight(totalH)
        assignFrame:Show()
        return
    end

    -- Healer window: same style as viewer (Tanks / Groups / Innervate sections)
    local PAD_H   = 6
    local innerW_H = frameW - PAD_H*2

    -- Centered section header (no icon)
    local function HAddHeader(text, r,g,b, bgMul)
        bgMul = bgMul or 0.18
        local hdr = CreateFrame("Frame",nil,assignFrame)
        hdr:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        hdr:SetWidth(innerW_H)
        hdr:SetHeight(rowH + 2)
        hdr:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8",
            insets={left=0,right=0,top=0,bottom=0}})
        hdr:SetBackdropColor(r*bgMul, g*bgMul, b*bgMul, 0.7)
        table.insert(assignFrame.content, hdr)
        local fs = hdr:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"OUTLINE")
        fs:SetPoint("LEFT", hdr,"LEFT",  0, 0)
        fs:SetPoint("RIGHT",hdr,"RIGHT", 0, 0)
        fs:SetJustifyH("CENTER")
        fs:SetTextColor(r,g,b)
        fs:SetText(text)
        yOff = yOff - (rowH + 4)
    end

    -- Single full-width bordered block
    local function HAddBlock(text, r,g,b)
        local block = CreateFrame("Frame",nil,assignFrame)
        block:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        block:SetWidth(innerW_H)
        block:SetHeight(rowStep + 2)
        block:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        block:SetBackdropColor(r*0.05, g*0.05, b*0.05, 0.4)
        block:SetBackdropBorderColor(r*0.5, g*0.5, b*0.5, 0.6)
        table.insert(assignFrame.content, block)
        local fs = block:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        fs:SetPoint("LEFT", block,"LEFT",   6, 0)
        fs:SetPoint("RIGHT",block,"RIGHT", -4, 0)
        fs:SetHeight(rowStep + 2)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        fs:SetTextColor(r,g,b)
        fs:SetText(text)
        yOff = yOff - (rowStep + 2) - 3
    end

    -- Collect my targets by type
    local myTanks, myGroups, myCustom = {},{},{}
    for _,t in ipairs(myTargets) do
        if t.type == TYPE_TANK        then table.insert(myTanks,  t)
        elseif t.type == TYPE_GROUP   then table.insert(myGroups, t)
        else                               table.insert(myCustom, t) end
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

    -- ── Innervate ─────────────────────────────────────────────────
    local myInnDruid = nil
    if tmpl and tmpl.innervate then
        for dname,hname in pairs(tmpl.innervate) do
            if hname == myName then myInnDruid = dname break end
        end
    end
    if myInnDruid then
        yOff = yOff - 2
        HAddHeader("Innervate", 1,0.65,0.1, 0.15)
        local cdRem   = INN_GetCDRemaining(myInnDruid)
        local isReady = cdRem <= 0
        local ICON_SZ = math.max(18, math.min(44, math.floor(fontSize * 2.0)))
        local dr2,dg2,db2 = GetClassColor("DRUID")
        local block = CreateFrame("Frame",nil,assignFrame)
        block:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
        block:SetWidth(innerW_H)
        block:SetHeight(ICON_SZ + 4)
        block:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
        block:SetBackdropColor(dr2*0.05, dg2*0.05, db2*0.05, 0.4)
        block:SetBackdropBorderColor(dr2*0.5, dg2*0.5, db2*0.5, 0.6)
        table.insert(assignFrame.content, block)
        local iconCont = CreateFrame("Frame",nil,block)
        iconCont:SetWidth(ICON_SZ) iconCont:SetHeight(ICON_SZ)
        iconCont:SetPoint("LEFT",block,"LEFT",4,0)
        local iTex = iconCont:CreateTexture(nil,"BACKGROUND")
        iTex:SetAllPoints(iconCont)
        iTex:SetTexture(INN_ICON)
        if not isReady then
            iTex:SetVertexColor(0.35,0.35,0.35)
            local mins = math.floor(cdRem/60)
            local secs = math.floor(math.mod(cdRem,60))
            local cdFS = iconCont:CreateFontString(nil,"OVERLAY")
            cdFS:SetFont("Fonts\\FRIZQT__.TTF",math.max(8,math.floor(fontSize*0.85)),"OUTLINE")
            cdFS:SetPoint("CENTER",iconCont,"CENTER",0,0)
            cdFS:SetTextColor(1,1,1)
            cdFS:SetText(string.format("%d:%02d",mins,secs))
        end
        local nameFS = block:CreateFontString(nil,"OVERLAY")
        nameFS:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        nameFS:SetPoint("LEFT", block,"LEFT",  ICON_SZ+8, 0)
        nameFS:SetPoint("RIGHT",block,"RIGHT", -4, 0)
        nameFS:SetHeight(ICON_SZ + 4)
        nameFS:SetJustifyH("LEFT")
        nameFS:SetJustifyV("MIDDLE")
        nameFS:SetTextColor(isReady and dr2 or dr2*0.6,
                            isReady and dg2 or dg2*0.6,
                            isReady and db2 or db2*0.6)
        nameFS:SetText(myInnDruid)
        yOff = yOff - ICON_SZ - 4 - 3
    end

    -- ── Cover Targets (dead healers) ──────────────────────────────
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
            HAddBlock(dname.." [dead]", dr2,dg2,db2)
            for _,t in ipairs(healerTargets[dname]) do
                local tr2,tg2,tb2 = 0.5,0.85,1.0
                if t.type == TYPE_TANK then
                    if tmpl and tmpl.roster and tmpl.roster[t.value] then
                        tr2,tg2,tb2 = GetClassColor(tmpl.roster[t.value].class)
                    end
                elseif t.type == TYPE_CUSTOM then tr2,tg2,tb2 = 0.9,0.6,1.0
                end
                local disp2 = t.value or "?"
                if t.type == TYPE_GROUP then disp2 = "Group "..t.value end
                HAddBlock(disp2, tr2,tg2,tb2)
            end
        end
    end

    -- ── BR section for healer-druids ──────────────────────────
    local myPdH = tmpl and tmpl.roster and tmpl.roster[myName]
    if myPdH and myPdH.class == "DRUID" and myPdH.tagH then
        -- Separator
        if not assignFrame._brSep then
            local sep = assignFrame:CreateTexture(nil,"ARTWORK")
            sep:SetHeight(1)
            sep:SetTexture(0.4,0.4,0.4,0.8)
            assignFrame._brSep = sep
        end
        assignFrame._brSep:ClearAllPoints()
        assignFrame._brSep:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",6,yOff)
        assignFrame._brSep:SetPoint("TOPRIGHT",assignFrame,"TOPRIGHT",-6,yOff)
        assignFrame._brSep:Show()
        yOff = yOff - 8

        -- BR icon (centered, same size as innervate icon)
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
        brIF:SetWidth(ICON_SZ) brIF:SetHeight(ICON_SZ)
        brIF:Show()
        local brCDRem = BR_GetCDRemaining(myName)
        local brCDFontSz = math.floor(fontSize * 0.85)
        if brCDFontSz < 8 then brCDFontSz = 8 end
        assignFrame._brCDFS:SetFont("Fonts\\FRIZQT__.TTF",brCDFontSz,"OUTLINE")
        if brCDRem > 0 then
            assignFrame._brIconTex:SetVertexColor(0.3,0.3,0.3)
            local bm = math.floor(brCDRem/60)
            local bs = math.floor(math.mod(brCDRem,60))
            assignFrame._brCDFS:SetText(string.format("%d:%02d",bm,bs))
        else
            assignFrame._brIconTex:SetVertexColor(1,1,1)
            assignFrame._brCDFS:SetText("")
        end
        yOff = yOff - ICON_SZ - 6

        -- Dead list
        if not assignFrame._brDeadBtns then assignFrame._brDeadBtns = {} end
        for _,b in ipairs(assignFrame._brDeadBtns) do b:Hide() end
        assignFrame._brDeadBtns = {}
        local aRowH   = fontSize + 8
        local aIconSz = math.floor(fontSize * 1.2)
        if aIconSz < 10 then aIconSz = 10 end
        if aIconSz > 20 then aIconSz = 20 end
        local aInnerW = assignFrame:GetWidth() - PAD_H*2
        for _,d in ipairs(brDeadList) do
            local dname = d.name
            local takenBy = nil
            for druid,target in pairs(brTargeted) do
                if target == dname and druid ~= myName then takenBy = druid end
            end
            local isMine = brTargeted[myName] == dname
            local cr,cg,cb = 0.6,0.5,0.5
            if tmpl and tmpl.roster and tmpl.roster[dname] then
                cr,cg,cb = GetClassColor(tmpl.roster[dname].class)
            end
            local row = CreateFrame("Button",nil,assignFrame)
            row:SetPoint("TOPLEFT",assignFrame,"TOPLEFT",PAD_H,yOff)
            row:SetWidth(aInnerW)
            row:SetHeight(aRowH)
            row:EnableMouse(not takenBy and not isMine and brCDRem <= 0)
            row:SetBackdrop({
                bgFile   = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile=true, tileSize=8, edgeSize=8,
                insets={left=2,right=2,top=2,bottom=2}
            })
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
            local fs = row:CreateFontString(nil,"OVERLAY")
            fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
            fs:SetPoint("LEFT",row,"LEFT",6,0)
            fs:SetPoint("RIGHT",row,"RIGHT",-(aIconSz+8),0)
            fs:SetHeight(aRowH)
            fs:SetJustifyH("LEFT") fs:SetJustifyV("MIDDLE")
            if isMine then fs:SetTextColor(cr,cg,cb)
            elseif takenBy then
                fs:SetTextColor(0.4,0.4,0.4)
                fs:SetText(dname.." |cff666666("..takenBy..")|r")
            else fs:SetTextColor(0.9,0.85,0.75) end
            if not takenBy then fs:SetText(dname) end
            local icF = CreateFrame("Frame",nil,row)
            icF:SetWidth(aIconSz) icF:SetHeight(aIconSz)
            icF:SetPoint("RIGHT",row,"RIGHT",-4,0)
            local icT = icF:CreateTexture(nil,"OVERLAY")
            icT:SetAllPoints(icF)
            icT:SetTexture("Interface\\Buttons\\WHITE8X8")
            if isMine then icT:SetVertexColor(1, 0.85, 0)      -- yellow: claimed by me
            elseif takenBy then icT:SetVertexColor(1, 0.2, 0.2) -- red: claimed by other
            else icT:SetVertexColor(0.2, 1, 0.2) end             -- green: free
            if not takenBy and not isMine and brCDRem <= 0 then
                local capName = dname
                row:SetScript("OnClick",function()
                    brTargeted[myName] = capName
                    TargetByName(capName)
                    BR_BroadcastTarget(myName, capName)
                    UpdateAssignFrame()
                end)
            end
            yOff = yOff - aRowH - 3
            table.insert(assignFrame._brDeadBtns, row)
        end

        -- Rebirth cast button
        if not assignFrame._brCastBtn then
            local brBtn = CreateFrame("Button",nil,assignFrame,"UIPanelButtonTemplate")
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
        brBtn:ClearAllPoints()
        brBtn:SetPoint("TOP",assignFrame,"TOP",0,yOff - 2)
        local brBtnW = math.max(80, fontSize * 6)
        brBtn:SetWidth(brBtnW)
        brBtn:SetHeight(fontSize + 8)
        brBtn:Show()
        local hasTarget = brTargeted[myName] ~= nil
        if hasTarget and brCDRem <= 0 then
            brBtn:SetTextColor(0.8,0.3,1) brBtn:EnableMouse(true) brBtn:SetAlpha(1)
        else
            brBtn:SetTextColor(0.5,0.5,0.5) brBtn:EnableMouse(false) brBtn:SetAlpha(0.5)
        end
        yOff = yOff - (fontSize + 8) - 6
    else
        -- Not a healer-druid: hide any BR widgets in assignFrame
        if assignFrame._brSep     then assignFrame._brSep:Hide()     end
        if assignFrame._brIconF   then assignFrame._brIconF:Hide()   end
        if assignFrame._brLbl     then assignFrame._brLbl:Hide()     end
        if assignFrame._brCastBtn then assignFrame._brCastBtn:Hide() end
        if assignFrame._brDeadBtns then
            for _,b in ipairs(assignFrame._brDeadBtns) do b:Hide() end
        end
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
    local myName     = UnitName("player")
    local tmpl       = GetActiveTemplate()
    local inRaid     = GetNumRaidMembers() > 0
    local showOutside= HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
    local myPdata    = tmpl and tmpl.roster and tmpl.roster[myName]

    -- Determine role
    -- Use UnitClass directly - always available regardless of roster state
    local _,playerClass = UnitClass("player")
    local isDruid       = playerClass == "DRUID"
    local isHealerDruid = isDruid and myPdata and myPdata.tagH
    -- Healer-druids get BR in assignFrame, not here
    -- Non-druids don't get this window at all
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
    local frameW    = 100 + fontSize * 8
    if frameW < 120 then frameW = 120 end
    if frameW > 260 then frameW = 260 end

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

        -- Options button
        local optBtn = CreateFrame("Button",nil,druidAssignFrame,"UIPanelButtonTemplate")
        optBtn:SetWidth(24) optBtn:SetHeight(16)
        optBtn:SetPoint("TOPRIGHT",druidAssignFrame,"TOPRIGHT",-4,-4)
        optBtn:SetText("O")
        optBtn:SetScript("OnClick",function()
            if optionsFrame and optionsFrame:IsShown() then optionsFrame:Hide()
            else HealAssign_OpenOptions() end
        end)

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

        local btn = CreateFrame("Button",nil,druidAssignFrame,"UIPanelButtonTemplate")
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

        local brBtn = CreateFrame("Button",nil,druidAssignFrame,"UIPanelButtonTemplate")
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

        local btn = druidAssignFrame._castBtn
        btn:ClearAllPoints()
        btn:SetPoint("TOP",druidAssignFrame,"TOP",0,curY)
        local btnW = math.max(80, fontSize * 6)
        btn:SetWidth(btnW) btn:SetHeight(BTN_H)
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

    -- Dead list: styled rows with name left + BR icon status right
    for _,b in ipairs(druidAssignFrame._brDeadBtns) do b:Hide() end
    druidAssignFrame._brDeadBtns = {}

    local myName2  = UnitName("player")
    local rowH2    = fontSize + 8
    local innerW   = frameW - PAD*2
    local iconSzSm = math.floor(fontSize * 1.2)  -- small icon for status
    if iconSzSm < 10 then iconSzSm = 10 end
    if iconSzSm > 20 then iconSzSm = 20 end

    for _,d in ipairs(brDeadList) do
        local dname   = d.name
        local takenBy = nil
        for druid,target in pairs(brTargeted) do
            if target == dname and druid ~= myName2 then takenBy = druid end
        end
        local isMine = brTargeted[myName2] == dname

        -- Class color
        local cr,cg,cb = 0.6,0.5,0.5
        if tmpl and tmpl.roster and tmpl.roster[dname] then
            cr,cg,cb = GetClassColor(tmpl.roster[dname].class)
        end

        -- Row frame with backdrop like HAddBlock
        local row = CreateFrame("Button",nil,druidAssignFrame)
        row:SetPoint("TOPLEFT",druidAssignFrame,"TOPLEFT",PAD,curY)
        row:SetWidth(innerW)
        row:SetHeight(rowH2)
        row:EnableMouse(not takenBy and not isMine and brCDRem <= 0)
        row:SetBackdrop({
            bgFile   = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile=true, tileSize=8, edgeSize=8,
            insets={left=2,right=2,top=2,bottom=2}
        })
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

        -- Name text (left aligned, leave room for icon on right)
        local fs = row:CreateFontString(nil,"OVERLAY")
        fs:SetFont("Fonts\\FRIZQT__.TTF",fontSize,"")
        fs:SetPoint("LEFT",  row,"LEFT",  6, 0)
        fs:SetPoint("RIGHT", row,"RIGHT", -(iconSzSm + 8), 0)
        fs:SetHeight(rowH2)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("MIDDLE")
        if isMine then
            fs:SetTextColor(cr, cg, cb)
        elseif takenBy then
            fs:SetTextColor(0.4,0.4,0.4)
            fs:SetText(dname.." |cff666666("..takenBy..")|r")
        else
            fs:SetTextColor(0.9,0.85,0.75)
        end
        if not takenBy then fs:SetText(dname) end

        -- Status indicator: colored square (right side)
        local icF = CreateFrame("Frame",nil,row)
        icF:SetWidth(iconSzSm) icF:SetHeight(iconSzSm)
        icF:SetPoint("RIGHT",row,"RIGHT",-4,0)
        local icT = icF:CreateTexture(nil,"OVERLAY")
        icT:SetAllPoints(icF)
        icT:SetTexture("Interface\\Buttons\\WHITE8X8")
        if isMine then
            icT:SetVertexColor(1, 0.85, 0)      -- yellow: claimed by me
        elseif takenBy then
            icT:SetVertexColor(1, 0.2, 0.2)     -- red: claimed by other druid
        else
            icT:SetVertexColor(0.2, 1, 0.2)     -- green: free
        end

        -- Click: claim target (no unclaim on second click - use ESC to drop target)
        if not takenBy and not isMine and brCDRem <= 0 then
            local capName = dname
            row:SetScript("OnClick",function()
                brTargeted[myName2] = capName
                TargetByName(capName)
                BR_BroadcastTarget(myName2, capName)
                UpdateDruidAssignFrame()
            end)
        end

        curY = curY - rowH2 - 3
        table.insert(druidAssignFrame._brDeadBtns, row)
    end

    -- Gap before cast button
    if table.getn(brDeadList) > 0 then curY = curY - 2 end

    -- Rebirth cast button
    local brBtn = druidAssignFrame._brCastBtn
    brBtn:ClearAllPoints()
    brBtn:SetPoint("TOP",druidAssignFrame,"TOP",0,curY - 2)
    local brBtnW = math.max(80, fontSize * 6)
    brBtn:SetWidth(brBtnW) brBtn:SetHeight(BTN_H)
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
            fsH:SetText(isDead and (hname.." [dead]") or hname)
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
    local numRaid = GetNumRaidMembers()
    -- Build lookup of current raid members
    local currentMembers = {}
    for _,m in ipairs(members) do
        currentMembers[m.name] = m
    end
    -- Remove players no longer in raid (protected against /reload race condition)
    if numRaid > 0 then
        if HA_reloadProtect then
            if table.getn(members) > 0 then
                HA_reloadProtect = false  -- raid confirmed, safe to clean
            else
                return  -- raid not loaded yet, don't touch roster
            end
        end
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
                    entry.tagT = entry.tagT and nil or true
                    if entry.tagT then entry.tagH = nil end
                    SyncHealersFromRoster(tmpl)
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame()
                end
            end)

            hBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedName]
                if entry then
                    entry.tagH = entry.tagH and nil or true
                    if entry.tagH then entry.tagT = nil end
                    SyncHealersFromRoster(tmpl)
                    RebuildRosterRows()
                    RebuildMainGrid()
                    UpdateAssignFrame()
                    UpdateDruidAssignFrame()
                end
            end)

            local capturedVName = p.name
            vBtn:SetScript("OnClick",function()
                local entry = tmpl.roster[capturedVName]
                if entry then
                    entry.tagV = entry.tagV and nil or true
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
    y = y-26

    -- Hide in Battleground checkbox
    local bgCB = CreateFrame("CheckButton",nil,optionsFrame,"UICheckButtonTemplate")
    bgCB:SetWidth(20)
    bgCB:SetHeight(20)
    bgCB:SetPoint("TOPLEFT",optionsFrame,"TOPLEFT",14,y)
    bgCB:SetChecked(HealAssignDB.options.hideInBG ~= false)
    bgCB:SetScript("OnClick",function()
        HealAssignDB.options.hideInBG = this:GetChecked()
        UpdateAssignFrame()
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
-- Фрейм создаётся через HealAssign.xml (по образцу ItemRack)
-------------------------------------------------------------------------------
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
    HealAssignMinimapBtn:SetScript("OnClick", function()
        if mainFrame and mainFrame:IsShown() then
            mainFrame:Hide()
        else
            if _CreateMainFrame then _CreateMainFrame() end
        end
    end)

    -- Tooltip
    HealAssignMinimapBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("HealAssign v"..ADDON_VERSION)
        GameTooltip:AddLine("Click to toggle main window", 1, 1, 1)
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
            HealAssignDB.templates[tmpl.name] = DeepCopy(tmpl)
            -- Only apply received template if we are NOT the raid leader
            -- (RL sends templates, non-RL receives and applies them)
            if not IsRaidLeader() then
                HealAssignDB.activeTemplate = tmpl.name
                currentTemplate = tmpl
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign:|r Received '"..tmpl.name.."' from "..sender)
                if mainFrame and mainFrame:IsShown() then RebuildMainGrid() end
                UpdateAssignFrame()
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
deathFrame:SetScript("OnEvent",function()
    -- UNIT_HEALTH: catch death when health hits 0
    if event == "UNIT_HEALTH" then
        local unit = arg1
        if not unit then return end
        if not UnitIsDeadOrGhost(unit) then return end
        local deadName = UnitName(unit)
        if not deadName then return end
        local tmpl2 = GetActiveTemplate()
        if not tmpl2 or not tmpl2.roster then return end
        local pd = tmpl2.roster[deadName]
        if not pd then return end
        if pd.tagT or pd.tagH then
            BR_AddDead(deadName)
            UpdateDruidAssignFrame()
            UpdateAssignFrame()
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
            UpdateAssignFrame()
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
            UpdateAssignFrame()
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
        BR_RemoveDead(name)
    end
    if table.getn(toRez) > 0 then
        UpdateDruidAssignFrame()
        UpdateAssignFrame()
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
    if event == "UNIT_HEALTH" then
        local unit = arg1
        if unit and not UnitIsDeadOrGhost(unit) then
            local aliveName = UnitName(unit)
            if aliveName then
                for _,d in ipairs(brDeadList) do
                    if d.name == aliveName then
                        BR_RemoveDead(aliveName)
                        RemoveDeadHealer(aliveName)
                        UpdateDruidAssignFrame()
                        UpdateAssignFrame()
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
        UpdateAssignFrame()
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
                UpdateAssignFrame()
            end
            CreateMinimapButton()
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccffHealAssign|r v"..ADDON_VERSION.." loaded. |cffffffff/ha|r to open.")
        end

    elseif event == "CHAT_MSG_ADDON" then
        HandleAddonMessage(arg1,arg2,arg3,arg4)

    elseif event == "PLAYER_ENTERING_WORLD" then
        if INN_BroadcastMyCD then INN_BroadcastMyCD() end
        UpdateAssignFrame()
        UpdateDruidAssignFrame()

    elseif event == "RAID_ROSTER_UPDATE" or event == "PARTY_MEMBERS_CHANGED" then
        local inRaid = GetNumRaidMembers() > 0
        if inRaid then
            HA_wasInRaid = true
            HA_reloadProtect = false  -- raid confirmed, protection no longer needed
            UpdateAssignFrame()
            UpdateDruidAssignFrame()
        else
            local showOutside = HealAssignDB and HealAssignDB.options and HealAssignDB.options.showAssignFrame
            if assignFrame then
                if showOutside then UpdateAssignFrame()
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
                            PersistTemplate()
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
            UpdateAssignFrame()
        end
    end

    -- Update druid assign frame every tick (mana refresh + CD timer).
    local myPdata3 = tmpl.roster and tmpl.roster[myName]
    local amDruid = myPdata3 and myPdata3.class == "DRUID" and not myPdata3.tagH
    if amDruid then
        -- Always update druid frame (covers both innervate mana display and rebirth CD)
        UpdateDruidAssignFrame()
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
    if amDruid and brTargeted[myName] then
        local realTarget = UnitName("target")
        if realTarget ~= brTargeted[myName] then
            brTargeted[myName] = nil
            BR_BroadcastTarget(myName, nil)
            UpdateDruidAssignFrame()
            if assignFrame and assignFrame:IsShown() then UpdateAssignFrame() end
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
        if needsUpdate and assignFrame and assignFrame:IsShown() then
            UpdateAssignFrame()
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
