local ADDON, ns = ...
local TR = ns.TR

-- 1. Questitems schuetzen: Tooltip Warnung, Warnung beim Loeschen und beim Verkaufen
-- 2. Ausruestung: bei mehreren Belohnungen die beste fuer deine Klasse vorschlagen

------------------------------------------------------------
-- Gebrauchte Items
------------------------------------------------------------
ns.neededItems = {} -- [itemID] = "Grund"
local neededNames = {}

local function QDB() return ns.QDBAccess and ns.QDBAccess() end
local function QQ(qdb, id, k) local ok, v = pcall(qdb.QueryQuestSingle, id, k); if ok then return v end end
local function QI(qdb, id, k) if not qdb.QueryItemSingle then return end local ok, v = pcall(qdb.QueryItemSingle, id, k); if ok then return v end end

local function Bags(fn)
  local num = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local idf = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
  if not (num and idf) then return end
  for bag = 0, 4 do
    for slot = 1, (num(bag) or 0) do
      local id = idf(bag, slot)
      if id then fn(id, bag, slot) end
    end
  end
end

local function Rebuild()
  local qdb = QDB()
  if not qdb then return end
  local need = {}
  local log = ns.logProgress or {}
  for qid, p in pairs(log) do
    local title = p.title or (TR"Quest " .. qid)
    local objs = QQ(qdb, qid, "objectives")
    for _, c in ipairs(type(objs) == "table" and objs[3] or {}) do need[c[1]] = TR"Questziel: " .. title end
    for _, id in ipairs(QQ(qdb, qid, "requiredSourceItems") or {}) do need[id] = TR"gebraucht für " .. title end
    local src = QQ(qdb, qid, "sourceItemId")
    if type(src) == "number" and src > 0 then need[src] = TR"gebraucht für " .. title end
  end
  -- Items in der Tasche, die eine Quest starten
  local complete = (Questie and Questie.db and Questie.db.char and Questie.db.char.complete) or {}
  Bags(function(id)
    if not need[id] then
      local q = QI(qdb, id, "startQuest")
      if type(q) == "number" and q > 0 and not complete[q] and not log[q] then
        need[id] = TR"startet die Quest " .. (QQ(qdb, q, "name") or q)
      end
    end
  end)
  -- Items fuer spaetere Quests aus der Route (unterwegs gesammelt oder zu kaufen)
  local later = {}
  local db = ns.db
  local opt = db and db.optMode and db.opt
  if opt and opt.steps then
    local cur = opt.idx or 1
    local accAt = {}
    for k = cur, #opt.steps do
      for _, a in ipairs(opt.steps[k].acts or {}) do
        if a.k == "A" and a.qid and not accAt[a.qid] then accAt[a.qid] = k end
      end
    end
    for k = cur, #opt.steps do
      for _, a in ipairs(opt.steps[k].acts or {}) do
        local items = {}
        if a.k == "O" and a.item and not (a.qid and log[a.qid]) then table.insert(items, a.item) end
        if a.k == "A" then for _, b in ipairs(a.buy or {}) do table.insert(items, b.item) end end
        for _, it in ipairs(items) do
          if it and not need[it] then
            local n = (a.qid and accAt[a.qid] or k) - cur
            later[it] = math.max(n, 0)
            if n > 0 then
              need[it] = (TR"für spätere Quest %s, annehmen in %d %s"):format(a.quest or "?", n, n == 1 and TR"Schritt" or TR"Schritten")
            else
              need[it] = (TR"für die Quest %s, gleich annehmen"):format(a.quest or "?")
            end
          end
        end
      end
    end
  end
  ns.laterItems = later
  ns.neededItems = need
  neededNames = {}
  for id, why in pairs(need) do
    local name = GetItemInfo and GetItemInfo(id)
    if name then neededNames[name] = why end
  end
end

local pending
local function Later()
  if pending then return end
  pending = true
  C_Timer.After(3, function() pending = false; Rebuild() end)
end
ns.RebuildNeeded = Rebuild

-- Taschen Markierung: kleines Ausrufezeichen auf gebrauchten Items,
-- bei spaeteren Quests die Zahl der Schritte bis zum Annehmen
local marks = {}
local function SlotOf(btn)
  local slot = btn.GetID and btn:GetID()
  local bag = btn.bagID or btn.BagID or btn.bag
  if bag == nil and btn.GetBagID then local ok, v = pcall(btn.GetBagID, btn); if ok then bag = v end end
  if bag == nil then local p = btn.GetParent and btn:GetParent(); bag = p and p.GetID and p:GetID() end
  return bag, slot
end
local function Mark(btn, idf)
  if not (btn and btn.IsVisible and btn:IsVisible()) then if btn and marks[btn] then marks[btn].tex:Hide(); marks[btn].txt:Hide() end return end
  local bag, slot = SlotOf(btn)
  local id = bag and slot and slot > 0 and idf(bag, slot)
  local on = ns.db and ns.db.markBags ~= false and ns.db.protectItems ~= false
  local why = on and id and ns.neededItems[id]
  local m = marks[btn]
  if not why then if m then m.tex:Hide(); m.txt:Hide() end return end
  if not m then
    if InCombatLockdown and InCombatLockdown() then return end
    m = {}
    m.tex = btn:CreateTexture(nil, "OVERLAY", nil, 7)
    m.tex:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    m.tex:SetSize(14, 14)
    m.tex:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
    m.txt = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    m.txt:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 2, 2)
    m.txt:SetTextColor(0.75, 0.55, 1)
    marks[btn] = m
  end
  local n = ns.laterItems and ns.laterItems[id]
  if n then m.tex:SetVertexColor(0.75, 0.55, 1) else m.tex:SetVertexColor(1, 1, 1) end
  m.tex:Show()
  if n and n > 0 then m.txt:SetText(n); m.txt:Show() else m.txt:Hide() end
end
function ns.MarkBags()
  local idf = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
  if not idf then return end
  for f = 1, 13 do
    local fr = _G["ContainerFrame" .. f]
    if fr and fr:IsShown() then
      for i = 1, 36 do local b = _G["ContainerFrame" .. f .. "Item" .. i]; if not b then break end Mark(b, idf) end
    end
  end
  local elv = _G.ElvUI_ContainerFrame
  if elv and elv:IsShown() then
    for bag = 0, 4 do
      for i = 1, 36 do local b = _G["ElvUI_ContainerFrameBag" .. bag .. "Slot" .. i]; if not b then break end Mark(b, idf) end
    end
  end
  local bb = _G.ContainerFrameCombinedBags
  if bb and bb:IsShown() and bb.EnumerateValidItems then
    for _, b in bb:EnumerateValidItems() do Mark(b, idf) end
  end
end
local function AnyBagOpen()
  if _G.ElvUI_ContainerFrame and _G.ElvUI_ContainerFrame:IsShown() then return true end
  if _G.ContainerFrameCombinedBags and _G.ContainerFrameCombinedBags:IsShown() then return true end
  for f = 1, 13 do local fr = _G["ContainerFrame" .. f]; if fr and fr:IsShown() then return true end end
end
-- leicht: nur wenn Taschen offen sind, und Route Schritt Wechsel neu einlesen
local lastIdx, lastOpt, wasOpen
if C_Timer and C_Timer.NewTicker then
  ns.Ticker(0.7, function()
    local opt = ns.db and ns.db.opt
    local idx = opt and opt.idx
    if opt ~= lastOpt or idx ~= lastIdx then lastOpt, lastIdx = opt, idx; Rebuild() end
    local open = AnyBagOpen()
    if open then ns.MarkBags() end
    wasOpen = open
  end)
end

-- Tooltip
local function OnTip(tt)
  if not (ns.db and ns.db.protectItems ~= false) then return end
  local _, link = tt:GetItem()
  local id = link and tonumber(link:match("item:(%d+)"))
  local why = id and ns.neededItems[id]
  if why then tt:AddLine(TR"|cffff5050Keine Zeit Leveling Guide: nicht verkaufen, " .. why .. "|r", 1, 0.3, 0.3, true) end
end
if GameTooltip and GameTooltip.HookScript then pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", OnTip) end

-- beim Haendler: verschwindet ein gebrauchtes Item, sofort warnen (Rueckkauf moeglich)
local atMerchant, snapshot = false, {}
local function Snap()
  snapshot = {}
  Bags(function(id) if ns.neededItems[id] then snapshot[id] = (snapshot[id] or 0) + 1 end end)
end

local function Warn(text)
  ns.Print("|cffff5050" .. text .. "|r")
  if UIErrorsFrame then UIErrorsFrame:AddMessage(text, 1, 0.2, 0.2) end
  if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

------------------------------------------------------------
-- Ausruestung: Belohnung vorschlagen
------------------------------------------------------------
local W = { -- Gewichte pro Klasse fuers Leveln
  WARRIOR = { STR = 2, AGI = 1, STA = 1.2, AP = 0.5, ARM = 0.03, DPS = 6 },
  PALADIN = { STR = 2, AGI = 0.6, STA = 1.2, INT = 0.6, SPI = 0.3, AP = 0.5, ARM = 0.02, DPS = 5 },
  HUNTER  = { AGI = 2, STA = 1, INT = 0.5, AP = 0.4, RAP = 0.6, ARM = 0.01, DPS = 3, RDPS = 6 },
  ROGUE   = { AGI = 2, STR = 1, STA = 1, AP = 0.5, ARM = 0.01, DPS = 6 },
  PRIEST  = { INT = 2, SPI = 1.5, STA = 1, SP = 1.5, ARM = 0.005, DPS = 0.5 },
  MAGE    = { INT = 2, SPI = 1, STA = 1, SP = 1.5, ARM = 0.005, DPS = 0.5 },
  WARLOCK = { INT = 1.5, SPI = 1, STA = 1.5, SP = 1.5, ARM = 0.005, DPS = 0.5 },
  DRUID   = { STR = 1, AGI = 1, INT = 1.2, SPI = 1, STA = 1, AP = 0.4, ARM = 0.01, DPS = 2 },
  SHAMAN  = { STR = 1.2, AGI = 0.8, INT = 1.2, SPI = 0.6, STA = 1, AP = 0.4, ARM = 0.015, DPS = 4 },
}
local STAT = {
  ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_STAMINA_SHORT = "STA",
  ITEM_MOD_INTELLECT_SHORT = "INT", ITEM_MOD_SPIRIT_SHORT = "SPI", ITEM_MOD_ATTACK_POWER_SHORT = "AP",
  ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RAP", RESISTANCE0_NAME = "ARM", ITEM_MOD_SPELL_POWER_SHORT = "SP",
  ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "DPS",
}
-- hoechste Ruestungsart: 1 Stoff, 2 Leder, 3 Kette, 4 Platte
local function MaxArmor(cls, L)
  if cls == "WARRIOR" or cls == "PALADIN" then return L >= 40 and 4 or 3 end
  if cls == "HUNTER" or cls == "SHAMAN" then return L >= 40 and 3 or 2 end
  if cls == "ROGUE" or cls == "DRUID" then return 2 end
  return 1
end
local SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_BODY = { 4 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 }, INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 },
}

-- Waffen, die die Klasse tragen kann (Classic, Untertyp der Waffe)
local WEAPONS = {
  WARRIOR = { [0]=1, [1]=1, [2]=1, [3]=1, [4]=1, [5]=1, [6]=1, [7]=1, [8]=1, [10]=1, [13]=1, [15]=1, [16]=1, [18]=1 },
  PALADIN = { [0]=1, [1]=1, [4]=1, [5]=1, [6]=1, [7]=1, [8]=1 },
  HUNTER  = { [0]=1, [1]=1, [2]=1, [3]=1, [6]=1, [7]=1, [8]=1, [10]=1, [13]=1, [15]=1, [16]=1, [18]=1 },
  ROGUE   = { [2]=1, [3]=1, [4]=1, [7]=1, [13]=1, [15]=1, [16]=1, [18]=1 },
  PRIEST  = { [4]=1, [10]=1, [15]=1, [19]=1 },
  SHAMAN  = { [0]=1, [1]=1, [4]=1, [5]=1, [10]=1, [13]=1, [15]=1 },
  MAGE    = { [7]=1, [10]=1, [15]=1, [19]=1 },
  WARLOCK = { [7]=1, [10]=1, [15]=1, [19]=1 },
  DRUID   = { [4]=1, [5]=1, [10]=1, [13]=1, [15]=1 },
}

local function Score(link)
  if not link then return 0, nil end
  local _, cls = UnitClass("player")
  local w = W[cls] or W.WARRIOR
  local stats = GetItemStats and GetItemStats(link) or {}
  local s = 0
  local _, _, _, _, _, _, _, _, loc, _, _, classID, subID = GetItemInfo(link)
  for k, v in pairs(stats) do
    local key = STAT[k]
    if key == "DPS" and (loc == "INVTYPE_RANGED" or loc == "INVTYPE_RANGEDRIGHT" or loc == "INVTYPE_THROWN") and w.RDPS then key = "RDPS" end
    if key and w[key] then s = s + v * w[key] end
  end
  -- Ruestung, die du nicht tragen kannst oder die schwaecher ist als deine
  if classID == 4 and subID and subID >= 1 and subID <= 4 then
    local mx = MaxArmor(cls, UnitLevel("player"))
    if subID > mx then return -1, loc end
    if subID < mx and loc ~= "INVTYPE_CLOAK" then s = s * 0.85 end
  end
  if classID == 4 and subID == 6 and not (cls == "WARRIOR" or cls == "PALADIN" or cls == "SHAMAN") then return -1, loc end
  if classID == 2 and subID and WEAPONS[cls] and not WEAPONS[cls][subID] then return -1, loc end
  return s, loc
end

local function Equipped(slot)
  local l = GetInventoryItemLink and GetInventoryItemLink("player", slot)
  return (Score(l))
end

-- Zweihaender in der Haupthand? Beidhaendig kaempfen gelernt?
local function MainIs2H()
  local l = GetInventoryItemLink and GetInventoryItemLink("player", 16)
  local eq = l and select(9, GetItemInfo(l))
  return eq == "INVTYPE_2HWEAPON"
end
local function CanDW()
  if CanDualWield then local ok, v = pcall(CanDualWield); if ok and v ~= nil then return v and true or false end end
  return IsSpellKnown and IsSpellKnown(674) or false
end

-- Gewinn fuer ein Teil mit Wertung s und Slot Typ loc gegen das Angelegte (nil: kein Upgrade moeglich)
local function SlotGain(s, loc)
  local slots = loc and SLOTS[loc]
  if not (s and s >= 0 and slots) then return nil end
  if loc == "INVTYPE_2HWEAPON" then
    return s - (Equipped(16) + math.max(0, Equipped(17))), 16
  end
  local two = MainIs2H()
  if loc == "INVTYPE_WEAPON" then
    -- Einhand: mit Zweihaender oder ohne Beidhaendig nur gegen die Haupthand
    if two or not CanDW() then return s - Equipped(16), 16 end
  elseif loc == "INVTYPE_WEAPONMAINHAND" then
    return s - Equipped(16), 16
  elseif loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" or loc == "INVTYPE_WEAPONOFFHAND" then
    -- Nebenhand geht nicht neben einem Zweihaender, Nebenhand Waffen nur mit Beidhaendig
    if two then return nil end
    if loc == "INVTYPE_WEAPONOFFHAND" and not CanDW() then return nil end
  end
  local worst, ws
  for _, sl in ipairs(slots) do local e = Equipped(sl); if not worst or e < worst then worst, ws = e, sl end end
  return s - (worst or 0), ws
end
-- leerer Platz: ein Teil dort bringt mehr als nur die Zahl (gar nichts an ist schlecht), darum bevorzugen
local function SlotGainEmptyFirst(s, loc)
  local g, sl = SlotGain(s, loc)
  if g and sl and GetInventoryItemLink then
    local empty = not GetInventoryItemLink("player", sl)
    if loc == "INVTYPE_2HWEAPON" then empty = empty and not GetInventoryItemLink("player", 17) end
    if empty and g > 0 then return g * 1.3, sl, true end
  end
  return g, sl, false
end
ns.SlotGain = SlotGainEmptyFirst

-- Verbesserung gegenueber dem angelegten Teil: Gewinn (Wertung), Slot Typ, Nummer des schlechtesten Slots
function ns.UpgradeGain(link)
  local s, loc = Score(link)
  -- Waffenfertigkeit nicht gelernt und Aehnliches: kein Upgrade
  if s and s >= 0 and ns.LinkUsable and not ns.LinkUsable(link) then return nil, loc end
  local g, sl, empty = SlotGainEmptyFirst(s, loc)
  if not g then return nil, loc end
  return g, loc, sl, empty
end
ns.ItemScore = Score

-- kannst du das Teil wirklich tragen? Im Tooltip steht dann nichts in Rot (Waffenfertigkeit fehlt,
-- Ruestungsart, Level, Klasse). Das ist genauer als jede eigene Liste.
local scan
local minLvlPat = ITEM_MIN_LEVEL and ("^" .. ITEM_MIN_LEVEL:gsub("%%d", "%%d+") .. "$")
local function RedLine(tip, skipLevel)
  for k = 2, tip:NumLines() do
    for _, side in ipairs({ "Left", "Right" }) do
      local fs = _G["ForeverWegweiserScanTipText" .. side .. k]
      local txt = fs and fs:IsShown() and fs:GetText()
      if txt then
        local r, g, b = fs:GetTextColor()
        if r and r > 0.9 and g < 0.2 and b < 0.2 and not (skipLevel and minLvlPat and txt:find(minLvlPat)) then return true end
      end
    end
  end
  return false
end
-- fuer geplante Belohnungen (Seite Ausruestung): Level spaeter ist ok, alles andere Rote nicht
function ns.LinkUsable(link)
  if not (link and CreateFrame) then return true end
  if not scan then
    scan = CreateFrame("GameTooltip", "ForeverWegweiserScanTip", UIParent, "GameTooltipTemplate")
  end
  scan:SetOwner(UIParent, "ANCHOR_NONE")
  scan:ClearLines()
  if not pcall(scan.SetHyperlink, scan, link) then return true end
  return not RedLine(scan, true)
end
local function UsableChoice(i)
  if not CreateFrame then return true end
  if not scan then
    scan = CreateFrame("GameTooltip", "ForeverWegweiserScanTip", UIParent, "GameTooltipTemplate")
    scan:SetOwner(UIParent, "ANCHOR_NONE")
  end
  scan:ClearLines()
  scan:SetOwner(UIParent, "ANCHOR_NONE")
  local ok = pcall(scan.SetQuestItem, scan, "choice", i)
  if not ok then return true end
  return not RedLine(scan, false)
end

-- beste Belohnung: Verbesserung gegenueber dem angelegten Teil (nur was du tragen kannst), sonst die teuerste zum Verkaufen
-- 19.31 (Saschas Runde: als Jaeger Level 2 und 5 Kette vorgeschlagen, die Handschuhe waeren besser gewesen): ein Teil fuer
-- einen leeren Platz zaehlt als Verbesserung, auch mit wenig Werten (bei Level 5 haben Handschuhe oft nur Ruestung).
-- Nur was du jetzt tragen kannst (Ruestungsart: Jaeger und Schamane Kette ab 40, Krieger und Paladin Platte ab 40).
-- Zum Verkaufen zuerst ein Teil, das du tragen kannst, wenn es gleich viel bringt. Jede Wahl kommt ins Test Log
local ARMOR_NAME = { [1] = "Stoff", [2] = "Leder", [3] = "Kette", [4] = "Platte", [6] = "Schild" }
local function ArmorOf(link)
  local _, _, _, _, _, _, _, _, loc, _, _, classID, subID = GetItemInfo(link)
  if classID == 4 then return ARMOR_NAME[subID] or ("Art " .. tostring(subID)), loc end
  if classID == 2 then return "Waffe", loc end
  return "anderes", loc
end
function ns.BestReward()
  local n = GetNumQuestChoices and GetNumQuestChoices() or 0
  if n <= 1 then return end
  local best, bestGain, bestSell, sellIdx
  local info = {}
  for i = 1, n do
    local link = GetQuestItemLink and GetQuestItemLink("choice", i)
    if link then
      local s, loc = Score(link)
      local gain, _, empty = SlotGainEmptyFirst(s, loc)
      local use = s and s >= 0 and UsableChoice(i)
      local ok = gain and use and (gain > 0.5 or (empty and gain > 0))
      if ok and (not bestGain or gain > bestGain) then best, bestGain = i, gain end
      local price = select(11, GetItemInfo(link)) or 0
      if not bestSell or price > bestSell or (price == bestSell and use) then bestSell, sellIdx = price, i end
      local art = ArmorOf(link)
      info[#info + 1] = ("%d %s (%s, Wertung %.1f, Gewinn %s%s%s)"):format(i, (GetItemInfo(link)) or "?", art, s or 0,
        gain and ("%.1f"):format(gain) or "-", empty and ", Platz leer" or "", use and "" or ", kann nicht tragen")
    end
  end
  if ns.TestLog then
    local qid = GetQuestID and GetQuestID() or 0
    ns.TestLog("BELOHNUNG", ("Quest %d: %s, vorgeschlagen %s | %s"):format(qid or 0, best and "Verbesserung" or "zum Verkaufen",
      tostring(best or sellIdx), table.concat(info, "; ")))
  end
  if best then return best, "upgrade", bestGain end
  return sellIdx, "sell", bestSell
end

local glow
-- Rahmen um die beste Belohnung: gruen mit kleinem Pfeil = Verbesserung, gold mit Muenze = teuerste zum Verkaufen
local ARROW_ELV = { "Interface\\AddOns\\ElvUI\\Core\\Media\\Textures\\ArrowUp", "Interface\\AddOns\\ElvUI\\Media\\Textures\\ArrowUp" }
local function SetArrow(tex)
  tex:SetTexCoord(0, 1, 0, 1)
  tex:SetDesaturated(false)
  if ns.T and ns.T.IsElv and ns.T.IsElv() then
    for _, f in ipairs(ARROW_ELV) do
      if tex:SetTexture(f) ~= false then tex:SetVertexColor(0.25, 1, 0.3, 1); return end
    end
  end
  -- Classic: der kleine Pfeil aus dem Spiel, gruen eingefaerbt
  tex:SetTexture("Interface\\Buttons\\Arrow-Up-Up")
  tex:SetTexCoord(0, 1, 0, 1)
  tex:SetDesaturated(true)
  tex:SetVertexColor(0.3, 1, 0.3, 1)
end
local function Highlight(i, kind)
  local btn = _G["QuestInfoRewardsFrameQuestInfoItem" .. i] or _G["QuestInfoItem" .. i]
  if not btn then return end
  if not glow then
    glow = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if glow.SetBackdrop then
      glow:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 2 })
    end
    glow.badge = glow:CreateTexture(nil, "OVERLAY", nil, 7)
    glow.badgeBg = glow:CreateTexture(nil, "OVERLAY", nil, 6)
    glow.badgeBg:SetColorTexture(0, 0, 0, 0.75)
  end
  local up = kind == "upgrade"
  if glow.SetBackdropBorderColor then
    if up then glow:SetBackdropBorderColor(0.25, 1, 0.25, 1) else glow:SetBackdropBorderColor(1, 0.8, 0.15, 1) end
  end
  glow:SetParent(btn)
  glow:ClearAllPoints()
  glow:SetPoint("TOPLEFT", btn, "TOPLEFT", -2, 2)
  glow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 2, -2)
  glow:SetFrameLevel(btn:GetFrameLevel() + 5)
  -- Abzeichen oben rechts am Symbol der Belohnung
  local icon = btn.Icon or _G[(btn:GetName() or "") .. "IconTexture"] or btn
  local b, bg = glow.badge, glow.badgeBg
  b:ClearAllPoints()
  b:SetSize(14, 14)
  b:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 3, 3)
  if up then
    SetArrow(b)
  elseif not (ns.T and ns.T.PinTex and ns.T.PinTex(b, "gold")) then
    b:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    b:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  end
  bg:ClearAllPoints()
  bg:SetPoint("TOPLEFT", b, "TOPLEFT", -1, 1); bg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 1, -1)
  b:Show(); bg:Show()
  glow:Show()
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("BAG_UPDATE_DELAYED")
f:RegisterEvent("MERCHANT_SHOW")
f:RegisterEvent("MERCHANT_CLOSED")
f:RegisterEvent("DELETE_ITEM_CONFIRM")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_FINISHED")
f:SetScript("OnEvent", function(_, event, a1)
  if not ns.db then return end
  if event == "PLAYER_LOGIN" then
    C_Timer.After(12, Rebuild)
  elseif event == "QUEST_LOG_UPDATE" then
    Later()
  elseif event == "MERCHANT_SHOW" then
    atMerchant = true
    ns.lastMerchantAt = time()
    Snap()
  elseif event == "MERCHANT_CLOSED" then
    atMerchant = false
  elseif event == "BAG_UPDATE_DELAYED" then
    if atMerchant and ns.db.protectItems ~= false then
      local now = {}
      Bags(function(id) if ns.neededItems[id] then now[id] = (now[id] or 0) + 1 end end)
      for id, n in pairs(snapshot) do
        if (now[id] or 0) < n then
          local name = GetItemInfo(id) or (TR"Item " .. id)
          Warn((TR"Achtung: %s verkauft, %s. Beim Händler unter Rückkauf zurückholen!"):format(name, ns.neededItems[id]))
        end
      end
      snapshot = now
    else
      Later()
    end
  elseif event == "DELETE_ITEM_CONFIRM" then
    local why = a1 and neededNames[a1]
    if why and ns.db.protectItems ~= false then Warn((TR"Achtung: %s wird gebraucht, %s. Wirklich löschen?"):format(a1, why)) end
  elseif event == "QUEST_FINISHED" then
    if glow then glow:Hide() end
  elseif event == "QUEST_COMPLETE" then
    if ns.db.gearHints == false then return end
    C_Timer.After(0.3, function()
      local i, kind, v = ns.BestReward()
      if not i then return end
      local link = GetQuestItemLink("choice", i)
      if kind == "upgrade" then
        ns.Print((TR"Belohnung: nimm %s, besser für dich (+%d Punkte)"):format(link or (TR"Nummer " .. i), math.floor(v + 0.5)))
      else
        ns.Print((TR"Belohnung: keine Verbesserung dabei, %s bringt beim Händler am meisten (%s)"):format(link or (TR"Nummer " .. i), ns.Money and ns.Money(v) or v))
      end
      Highlight(i, kind)
    end)
  end
end)

-- freie Taschenplaetze (nur normale Taschen)
function ns.FreeSlots()
  local fn = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  if not fn then return 99 end
  local free = 0
  for bag = 0, 4 do
    local n, typ = fn(bag)
    if n and (typ == nil or typ == 0) then free = free + n end
  end
  return free
end

-- alle Taschenplaetze (nur normale Taschen)
-- Wie schnell fuellen sich die Taschen? Belegte Plaetze pro Kill, aus deinen eigenen Kills gelernt
-- (Plaetze, die nach einem Kill neu belegt sind, solange kein Haendler offen ist). Ohne Messung: auf
-- tiefen Level fast jeder zweite Kill ein neuer Platz (Troll Krieger: Taschen schon auf Level 3 voll)
local bagFree, bagVendor
function ns.BagKill()
  local db = ns.db
  if not db then return end
  local b = db.bagLearn or { k = 0, u = 0 }
  db.bagLearn = b
  b.k = b.k + 1
  -- belegt seit dem letzten Kill (kurz danach gemessen, nach dem Pluendern)
  local before = bagFree or ns.FreeSlots()
  C_Timer.After(4, function()
    if bagVendor then bagFree = ns.FreeSlots(); return end
    local now = ns.FreeSlots()
    if now < before then b.u = b.u + (before - now) end
    bagFree = now
    -- nur die letzten ca 200 Kills zaehlen
    if b.k > 200 then b.k, b.u = b.k / 2, b.u / 2 end
  end)
end
do
  local vf = CreateFrame("Frame")
  vf:RegisterEvent("MERCHANT_SHOW"); vf:RegisterEvent("MERCHANT_CLOSED"); vf:RegisterEvent("BAG_UPDATE")
  vf:SetScript("OnEvent", function(_, e)
    if e == "MERCHANT_SHOW" then bagVendor = true
    elseif e == "MERCHANT_CLOSED" then bagVendor = false; bagFree = ns.FreeSlots and ns.FreeSlots() or nil
    elseif bagVendor then bagFree = nil end
  end)
end
function ns.BagRate(L)
  local b = ns.db and ns.db.bagLearn
  if b and b.k >= 20 then return math.max(0.15, math.min(1.2, b.u / b.k)) end
  L = L or UnitLevel("player") or 1
  if L < 10 then return 0.5 elseif L < 30 then return 0.42 end
  return 0.36
end

function ns.TotalSlots()
  local fn = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local ff = (C_Container and C_Container.GetContainerNumFreeSlots) or GetContainerNumFreeSlots
  if not fn then return nil end
  local n = 0
  for bag = 0, 4 do
    local _, typ
    if ff then _, typ = ff(bag) end
    if typ == nil or typ == 0 then n = n + (fn(bag) or 0) end
  end
  return n
end

-- Taschen fast voll: nie neu rechnen. Liegt ein Haendler direkt am Weg zum naechsten Ziel (kaum Umweg), kommt er
-- als Schritt dazu. Sonst nur ein Hinweis: jeder entscheidet selbst (Menue Haendler fuegt ihn ein).
do
  local last = -1000
  local bf = CreateFrame("Frame")
  bf:RegisterEvent("BAG_UPDATE_DELAYED")
  bf:SetScript("OnEvent", function()
    local db = ns.db
    if not (db and db.bagPlan ~= false and db.optMode and db.opt and db.opt.steps) then return end
    if InCombatLockdown and InCombatLockdown() then return end
    if GetTime() - last < 300 then return end
    local free = ns.FreeSlots()
    if free > 3 then return end
    -- kommt in den naechsten 3 Schritten schon ein Haendler?
    local opt = db.opt
    for i = opt.idx or 1, math.min(#opt.steps, (opt.idx or 1) + 3) do
      for _, a in ipairs(opt.steps[i].acts or {}) do if a.k == "V" then return end end
    end
    last = GetTime()
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    local v, dv
    if pos and ns.NearestSvc then
      local px, py = pos:GetXY()
      v, dv = ns.NearestSvc("vendor", map, px, py, true)
      -- Umweg: zum Haendler und von dort zum naechsten Ziel, gegen direkt zum Ziel
      local st = opt.steps[opt.idx or 1]
      if v and st and st.map and ns.WorldDist and not (ns.OptSpecial and ns.OptSpecial(opt)) then
        local direct = ns.WorldDist({ map, px, py }, { st.map, st.x, st.y })
        local via = ns.WorldDist({ v.map, v.x, v.y }, { st.map, st.x, st.y })
        if direct and via and dv and (dv + via - direct) <= 80 then
          if ns.OptInsertService then ns.OptInsertService("vendor") end
          return
        end
      end
    end
    if v then
      ns.Print((TR"Taschen fast voll. Nächster Händler: %s, ca %d Yards. Im Menü auf Händler klicken, dann kommt er als Schritt dazu."):format(v.name or "?", math.floor(dv or 0)))
    else
      ns.Print(TR"Taschen fast voll. Beim nächsten Händler verkaufen.")
    end
  end)
end

------------------------------------------------------------
-- Vorraete: Essen, Wasser, Munition
------------------------------------------------------------
local MANA = { PRIEST = true, MAGE = true, WARLOCK = true, DRUID = true, SHAMAN = true, PALADIN = true, HUNTER = true }
function ns.SupplyNeeds()
  local db = ns.db
  if not db or db.supplyPlan == false then return nil end
  local food, water = 0, 0
  local info = (C_Container and C_Container.GetContainerItemInfo) or nil
  Bags(function(id, bag, slot)
    local _, _, _, _, _, _, _, _, _, _, _, classID, subID = GetItemInfo(id)
    if classID == 0 and subID == 5 then
      local count = 1
      if info then
        local t = info(bag, slot)
        count = (type(t) == "table" and t.stackCount) or 1
      elseif GetContainerItemInfo then
        local _, c = GetContainerItemInfo(bag, slot)
        count = c or 1
      end
      local spell = GetItemSpell and GetItemSpell(id) or ""
      if spell:find("Trinken") or spell:find("Drink") then water = water + count else food = food + count end
    end
  end)
  local _, cls = UnitClass("player")
  local L = UnitLevel("player")
  local need, parts = {}, {}
  if L >= 5 and food < 5 then need.food = true; table.insert(parts, TR"Essen") end
  if L >= 5 and MANA[cls] and water < 5 then need.water = true; table.insert(parts, TR"Wasser") end
  if cls == "HUNTER" and GetInventoryItemCount then
    local ammo = GetInventoryItemCount("player", 0) or 0
    if ammo < 200 then need.ammo = true; table.insert(parts, TR"Munition") end
  end
  if #parts == 0 then return nil end
  need.text = table.concat(parts, ", ")
  return need
end

------------------------------------------------------------
-- Waffenfertigkeit: neue Waffe noch schwach geskillt?
------------------------------------------------------------
local warned = {}
local function CheckWeapon()
  if not (ns.db and ns.db.weaponHint ~= false and GetSkillLineInfo and GetNumSkillLines) then return end
  local link = GetInventoryItemLink and GetInventoryItemLink("player", 16)
  if not link then return end
  local _, _, _, _, _, _, sub = GetItemInfo(link)
  if type(sub) ~= "string" then return end
  local want = sub:lower()
  -- erst genau gleich ("Zweihandschwerter" nicht als "Schwerter" erkennen), dann Teilstring
  local exact = false
  for i = 1, GetNumSkillLines() do
    local name, header = GetSkillLineInfo(i)
    if not header and name and name:lower() == want then exact = true; break end
  end
  for i = 1, GetNumSkillLines() do
    local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
    if not header and name and rank and max and max > 1 then
      local n = name:lower()
      if n == want or (not exact and (want:find(n, 1, true) or n:find(want, 1, true))) then
        if rank < max - 25 then
          local key = link .. rank
          if not warned[link] or warned[link] < rank - 20 then
            warned[link] = rank
            ns.Print((TR"|cffffd100Waffenfertigkeit:|r %s erst %d von %d. An leichten Mobs (grau oder grün) hochziehen, bevor es schwer wird."):format(name, rank, max))
          end
        end
        return
      end
    end
  end
end
local wf = CreateFrame("Frame")
wf:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
wf:RegisterEvent("PLAYER_LEVEL_UP")
wf:RegisterEvent("PLAYER_LOGIN")
wf:SetScript("OnEvent", function() C_Timer.After(3, CheckWeapon) end)

------------------------------------------------------------
-- Einkaufsliste: Quest Items, die nirgends droppen (Handwerk, Haendler, Auktionshaus)
-- Kommt im Chat, sobald du in einer Hauptstadt bist, und mit /klg einkaufen
------------------------------------------------------------
local CITIES = { [1454] = true, [1456] = true, [1458] = true, [1453] = true, [1455] = true, [1457] = true }

function ns.ShoppingList()
  local qdb = QDB()
  if not qdb then return {} end
  local out, seen = {}, {}
  local function NI(id, k) if not qdb.QueryNPCSingle then return end local ok, v = pcall(qdb.QueryNPCSingle, id, k); if ok then return v end end
  local function Add(item, name, need, quest)
    if not item or seen[item .. quest] then return end
    seen[item .. quest] = true
    local drops = QI(qdb, item, "npcDrops")
    local odrops = QI(qdb, item, "objectDrops")
    if (type(drops) == "table" and #drops > 0) or (type(odrops) == "table" and #odrops > 0) then return end
    local have = (GetItemCount and GetItemCount(item)) or 0
    if need and have >= need then return end
    local vend = QI(qdb, item, "vendors")
    local where = TR"im Auktionshaus oder herstellen"
    if type(vend) == "table" and vend[1] then
      where = TR"beim Händler " .. (NI(vend[1], "name") or "?")
    end
    table.insert(out, { item = item, name = name or GetItemInfo(item) or (TR"Item " .. item), need = need, have = have, quest = quest, where = where })
  end
  -- Quests im Log
  for qid, p in pairs(ns.logProgress or {}) do
    local objs = QQ(qdb, qid, "objectives")
    for _, c in ipairs(type(objs) == "table" and objs[3] or {}) do
      local nm = QI(qdb, c[1], "name")
      local need
      for _, o in ipairs(p.objs or {}) do
        if nm and o.text and o.text:find(nm, 1, true) then
          local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
          if b then need = tonumber(b) end
        end
      end
      Add(c[1], nm, need, p.title or (TR"Quest " .. qid))
    end
  end
  -- Quests, die die Route noch annehmen will
  local opt = ns.db and ns.db.opt
  if opt and opt.steps then
    for k = opt.idx or 1, #opt.steps do
      for _, a in ipairs(opt.steps[k].acts) do
        -- buy ist bei Quests eine Liste, beim Haendler Halt nur ein Text ("Essen, Wasser")
        if type(a.buy) == "table" then
          for _, b in ipairs(a.buy) do if type(b) == "table" then Add(b.item, b.name, nil, a.quest or "?") end end
        end
      end
    end
  end
  return out
end

function ns.PrintShopping(quiet)
  local list = ns.ShoppingList()
  if #list == 0 then
    if not quiet then ns.Print(TR"Einkaufsliste: nichts nötig, alle Quest Items kommen von Mobs oder Objekten.") end
    return
  end
  ns.Print(TR"|cffffd100Einkaufsliste für deine Quests:|r")
  for _, e in ipairs(list) do
    local cnt = e.need and (" " .. math.max(0, e.need - e.have) .. "x") or ""
    ns.Print((TR"  %s%s für %s: %s"):format(e.name, cnt, e.quest, e.where))
  end
end

-- 17.9: pro Stadt hoechstens alle 30 Min, und rein und raus aus einem Dungeon zaehlt nicht als neue Stadt
-- (Dungeon Test: Ragefire, Verlies, Ruinen von Lordaeron haben den Eingang in der Stadt, nach jedem Wipe kam die Liste)
local lastCity
local cityAt = {}
local cf = CreateFrame("Frame")
cf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
cf:RegisterEvent("ZONE_CHANGED")
cf:SetScript("OnEvent", function()
  if not ns.db or ns.db.shopHint == false then return end
  C_Timer.After(2, function()
    if ns.InInstance and ns.InInstance() then return end
    local map = ns.PlayerMap and ns.PlayerMap()
    if map and CITIES[map] then
      local now = GetTime and GetTime() or 0
      if lastCity ~= map and now - (cityAt[map] or -9999) > 1800 then cityAt[map] = now; ns.PrintShopping(true) end
      lastCity = map
    else
      lastCity = nil
    end
  end)
end)
