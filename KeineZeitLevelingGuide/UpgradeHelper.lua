local ADDON, ns = ...
local TR = ns.TR

-- Upgrade Helfer am Charakterfenster (ersetzt das alte Feld C):
-- Slots mit einem Upgrade aus einer Quest bekommen eine kleine gruene Ecke.
-- Maus auf einen Slot: Tooltip und die schmale Leiste zeigen die Quests mit besserem Teil, mit "einplanen".

local SLOTBTN = { [1] = "CharacterHeadSlot", [2] = "CharacterNeckSlot", [3] = "CharacterShoulderSlot", [5] = "CharacterChestSlot",
  [6] = "CharacterWaistSlot", [7] = "CharacterLegsSlot", [8] = "CharacterFeetSlot", [9] = "CharacterWristSlot", [10] = "CharacterHandsSlot",
  [11] = "CharacterFinger0Slot", [12] = "CharacterFinger1Slot", [13] = "CharacterTrinket0Slot", [14] = "CharacterTrinket1Slot",
  [15] = "CharacterBackSlot", [16] = "CharacterMainHandSlot", [17] = "CharacterSecondaryHandSlot", [18] = "CharacterRangedSlot" }

local function Active() return ns.db and ns.Unlocked and ns.Unlocked("gear") end

-- Upgrades je Slot aus der Ausruestungsseite
local function BySlot()
  local out = {}
  for _, q in ipairs(ns.gearQuests or {}) do
    -- alle Upgrades zeigen (auswaehlen ist fuer die Route, hier geht es ums Sehen)
    do
      for _, it in ipairs(q.items or {}) do
        if it.slot and (it.gain or 0) > 0 then
          out[it.slot] = out[it.slot] or {}
          table.insert(out[it.slot], { q = q, it = it })
        end
      end
    end
  end
  for _, l in pairs(out) do table.sort(l, function(a, b) return a.it.gain > b.it.gain end) end
  return out
end

-- Quest einplanen: nur diese Quest (mit Vorquests) als Ausruestungs Route
local function Plan(q)
  if not (q and ns.Optimize) then return end
  -- 20.3k (S Test 20.3g Punkt 21): eigene Zusatz Route wie Ausruestung (mit Vorquests), die Leveling Route bleibt und geht
  -- danach weiter. Vorher kam die Quest in die normale Route, auf Level 60 passierte dabei nichts
  local set = { [q.id] = true }
  for _, p in ipairs(q.pre or {}) do set[p] = true end
  local L = UnitLevel("player") or 1
  -- 20.3s (Punkt 21): Dungeon Quest geht hier nicht (Ziel im Dungeon), dann klar sagen statt still nichts zu tun
  if q.dungeon then
    ns.Print((TR"%s ist eine Dungeon Quest, die geht über die Dungeon Seite oder in der Gruppe."):format(q.name or "?"))
    if #(q.pre or {}) == 0 then return end
    ns.Print(TR"Die Vorquests werden trotzdem eingeplant.")
  end
  ns.Print(TR"Eingeplant: " .. (q.name or "?") .. TR". Eigene Route mit Vorquests wird berechnet, danach geht die Leveling Route weiter.")
  -- 20.3s (Punkt 21): kein Abbruch mehr bei laufender Rechnung, Optimize bricht eine Leveling Rechnung selbst ab (20.3o)
  ns.Optimize(math.min(60, L + 3), function(opt)
    if opt and ns.db then ns.db.optMode = true end
    if ns.RefreshBig then pcall(ns.RefreshBig) end
  end, { gearQ = set, maxTime = 7200 })
end

local marks = {}
local strip
local function Line(e)
  local q, it = e.q, e.it
  local where = (q.zone and ns.ZoneName and ns.ZoneName(q.zone)) or ""
  return (TR"%s  |cff9d9d9dQuest %s, Level %d%s|r"):format(it.link or (TR"Item " .. (it.id or "?")), q.name or "?", q.rl or q.ql or 0,
    where ~= "" and (", " .. where) or "")
end
-- kurz fuer die Leiste: nur die Quest, das Item steht im Tooltip
local function Short(e)
  local q = e.q
  local where = (q.zone and ns.ZoneName and ns.ZoneName(q.zone)) or ""
  return (TR"%s\n|cff9d9d9dLevel %d%s|r"):format(q.name or "?", q.rl or q.ql or 0, where ~= "" and (", " .. where) or "")
end

local function BuildStrip()
  if strip or not CharacterFrame then return end
  local T = ns.T
  strip = CreateFrame("Frame", "ForeverWegweiserUpgrades", CharacterFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  strip:SetWidth(240)
  strip:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", 46, -10)
  strip:SetPoint("BOTTOMLEFT", CharacterFrame, "BOTTOMRIGHT", 46, 10)
  if T then T.Skin(strip, "window") end
  -- Classic: dunkler Grund wie die Blizzard Fenster, nichts scheint durch
  if T and not T.IsElv() then
    strip.bg = strip:CreateTexture(nil, "BACKGROUND", nil, -7)
    strip.bg:SetPoint("TOPLEFT", 4, -4); strip.bg:SetPoint("BOTTOMRIGHT", -4, 4)
    strip.bg:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock")
    strip.bg:SetHorizTile(true); strip.bg:SetVertTile(true)
    strip.bg:SetVertexColor(0.45, 0.45, 0.45, 1)
  end
  strip.title = strip:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  strip.title:SetPoint("TOPLEFT", 12, -12)
  strip.title:SetText(TR"Upgrades aus Quests")
  strip.sub = strip:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  strip.sub:SetPoint("TOPLEFT", strip.title, "BOTTOMLEFT", 0, -4); strip.sub:SetPoint("RIGHT", -10, 0)
  strip.sub:SetJustifyH("LEFT")
  strip.rows = {}
  -- unten: ganzen Wegweiser anhalten oder weitermachen, darueber das grosse Fenster (immer da, auch vor Level 10)
  local pause = T and T.Button(strip, TR"Pfeil und Mini Fenster aus", 216, 24) or CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  pause:SetSize(216, 24); pause:SetPoint("BOTTOM", 0, 12)
  local full = T and T.Button(strip, TR"Vollbild", 216, 24) or CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
  full:SetSize(216, 24); full:SetPoint("BOTTOM", pause, "TOP", 0, 6)
  local fic = T and T.HudIcon and T.HudIcon(TR"Grosses Fenster", 16)
  full:SetText(fic and (fic .. TR"  Vollbild öffnen") or TR"Vollbild öffnen")
  -- frei: gleich die Seite Ausruestung, sonst die Startseite
  full:SetScript("OnClick", function() if ns.ShowBig then ns.ShowBig(Active() and "gear" or nil) end end)
  strip.full = full
  -- 19.32 (Saschas Runde 2 Punkt 15): Pfeil und Mini Fenster aus, ohne Rechnen im Hintergrund (wie Pause)
  pause:SetScript("OnClick", function()
    if ns.SetQuiet then ns.SetQuiet(not ns.db.paused) elseif ns.SetPaused then ns.SetPaused(not ns.db.paused) end
  end)
  pause:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self:GetText() or "")
    GameTooltip:AddLine(TR"Pfeil und Mini Fenster weg, nichts rechnet mehr. Nochmal klicken holt beides zurück.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  pause:SetScript("OnLeave", function() GameTooltip:Hide() end)
  strip.pause = pause
  -- beim Zeigen immer neu pruefen: Modus oder Level koennen sich geaendert haben
  strip:SetScript("OnShow", function()
    if ns.PauseLabels then ns.PauseLabels() end
    if ns.UpgradeStripRefresh then ns.UpgradeStripRefresh() end
  end)
  strip:Hide()
end

-- noch nicht frei: Hinweis wie bei den gesperrten Seiten im grossen Fenster
local lockFrame
local function ShowLocked()
  local lk = lockFrame
  if not lk then
    lk = CreateFrame("Frame", nil, strip)
    lk:SetPoint("TOPLEFT", 12, -40); lk:SetPoint("BOTTOMRIGHT", -10, 10)
    lk.icon = lk:CreateTexture(nil, "ARTWORK")
    lk.icon:SetSize(56, 56); lk.icon:SetPoint("TOP", 0, -10)
    lk.icon:SetTexture(ns.APATH .. "Media\\" .. ((ns.T and ns.T.IsElv()) and "fw_weg_icons_elv" or "fw_weg_icons"))
    lk.icon:SetTexCoord(4 / 8, 5 / 8, 0, 1 / 4) -- Symbol Ausruestung
    lk.icon:SetDesaturated(true)
    lk.head = lk:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    lk.head:SetPoint("TOP", lk.icon, "BOTTOM", 0, -10); lk.head:SetPoint("LEFT", 0, 0); lk.head:SetPoint("RIGHT", 0, 0)
    lk.text = lk:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    lk.text:SetPoint("TOP", lk.head, "BOTTOM", 0, -10); lk.text:SetPoint("LEFT", 4, 0); lk.text:SetPoint("RIGHT", -4, 0)
    lk.text:SetText(TR"Hier siehst du dann Quests, deren Belohnung besser ist als das, was du anhast. Mit einem Klick plant die Route die Quest ein.")
    lk.left = lk:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisable"))
    lk.left:SetPoint("TOP", lk.text, "BOTTOM", 0, -14); lk.left:SetPoint("LEFT", 0, 0); lk.left:SetPoint("RIGHT", 0, 0)
    lockFrame = lk
  end
  local lv = ns.UnlockLevel and ns.UnlockLevel("gear") or 10
  local L = (ns.UnitLevel and ns.UnitLevel("player")) or UnitLevel("player") or 1
  local txt = ns.LockText and ns.LockText("gear") or (TR"Kommt ab Level " .. lv)
  lk.head:SetText(txt)
  lk.left:SetText(lv > L and not txt:find("Modus") and (lv - L == 1 and TR"Noch 1 Level" or (TR"Noch %d Level"):format(lv - L)) or "")
  strip.sub:SetText("")
  for _, r in ipairs(strip.rows) do r:Hide() end
  lk:Show()
end

local function ShowSlot(slot)
  if not strip then return end
  if not Active() then ShowLocked(); return end
  if lockFrame then lockFrame:Hide() end
  local list = slot and BySlot()[slot]
  local all = BySlot()
  local n = 0
  for _ in pairs(all) do n = n + 1 end
  local rowsData = {}
  if list then
    strip.sub:SetText(TR"Für diesen Slot, beste zuerst:")
    for i = 1, math.min(6, #list) do rowsData[i] = list[i] end
  else
    strip.sub:SetText(n > 0 and (TR"%d Slots mit Upgrade in Reichweite."):format(n)
      or (ns.gearQuests and TR"Gerade keine Quest mit besserem Teil." or TR"Ausrüstung wird gesucht ..."))
    for s, l in pairs(all) do if #rowsData < 6 then table.insert(rowsData, l[1]) end end
  end
  for i, e in ipairs(rowsData) do
    local r = strip.rows[i]
    if not r then
      r = CreateFrame("Frame", nil, strip)
      r:SetHeight(52)
      r:EnableMouse(true)
      -- Maus drauf: nur der Item Tooltip
      r:SetScript("OnEnter", function(self)
        if not self.link then return end
        ns.TipOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
      end)
      r:SetScript("OnLeave", function() GameTooltip:Hide() end)
      r.icon = r:CreateTexture(nil, "ARTWORK")
      r.icon:SetSize(30, 30); r.icon:SetPoint("TOPLEFT", 0, -2)
      r.text = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.text:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 0); r.text:SetPoint("RIGHT", 0, 0); r.text:SetJustifyH("LEFT")
      r.btn = ns.T and ns.T.Button(r, "einplanen", 80, 18) or CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
      r.btn:SetSize(80, 18); r.btn:SetPoint("BOTTOMLEFT", 36, 2)
      strip.rows[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", strip, "TOPLEFT", 12, -60 - (i - 1) * 58); r:SetPoint("RIGHT", strip, "RIGHT", -10, 0)
    r.text:SetText(Short(e))
    r.link = e.it.link or (e.it.id and ("item:" .. e.it.id))
    r.icon:SetTexture(e.it.id and GetItemIcon and GetItemIcon(e.it.id) or "Interface\\Icons\\INV_Misc_QuestionMark")
    r.btn:SetScript("OnClick", function() Plan(e.q) end)
    r:Show()
  end
  for i = #rowsData + 1, #strip.rows do strip.rows[i]:Hide() end
end

local function Mark(slot, on)
  local name = SLOTBTN[slot]
  local b = name and _G[name]
  if not b then return end
  local m = marks[slot]
  if not m and on then
    m = {}
    m.h = b:CreateTexture(nil, "OVERLAY", nil, 7); m.h:SetColorTexture(0.25, 1, 0.3, 1)
    m.h:SetSize(10, 2); m.h:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -1)
    m.v = b:CreateTexture(nil, "OVERLAY", nil, 7); m.v:SetColorTexture(0.25, 1, 0.3, 1)
    m.v:SetSize(2, 10); m.v:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -1)
    marks[slot] = m
    -- Maus drauf: Leiste und Tooltip
    b:HookScript("OnEnter", function()
      if not Active() then return end
      local l = BySlot()[slot]
      if l and l[1] then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(TR"Keine Zeit Leveling Guide: besser aus einer Quest", 0.25, 1, 0.3)
        for i = 1, math.min(3, #l) do GameTooltip:AddLine(Line(l[i]), 1, 1, 1, true) end
        GameTooltip:Show()
      end
      if strip and strip:IsShown() then ShowSlot(slot) end
    end)
    b:HookScript("OnLeave", function() if strip and strip:IsShown() then ShowSlot(nil) end end)
  end
  if m then m.h:SetShown(on); m.v:SetShown(on) end
end

-- Keine gruenen Ecken und keine Hooks an den Slots mehr: die Ecken haben gestoert, und der Tooltip am Slot
-- hat beim Drueberfahren gewackelt und ist verschwunden (Blizzard baut ihn laufend neu, ohne unsere Zeilen),
-- die Leiste daneben ist dabei hin und her gesprungen. Die Leiste zeigt jetzt fest alle Upgrades.
function ns.UpgradeMarks()
  for s in pairs(marks) do Mark(s, false) end
end

-- Knopf am Charakterfenster: Leiste auf und zu
-- Knopf Text je nach Pause
function ns.PauseLabels()
  if strip and strip.pause then
    local on = ns.db and ns.db.paused
    local ic = ns.T and ns.T.HudIcon and ns.T.HudIcon(on and TR"Weitermachen" or TR"Pause", 16)
    local lbl = on and TR"Pfeil und Mini Fenster an" or TR"Pfeil und Mini Fenster aus"
    strip.pause:SetText(ic and (ic .. "  " .. lbl) or lbl)
  end
end

-- Feld neu aufbauen (nach Moduswechsel, Level Up, Charakterfenster auf)
function ns.UpgradeStripRefresh()
  if not (strip and strip:IsShown()) then return end
  ShowSlot(nil)
  if ns.UpgradeMarks then ns.UpgradeMarks() end
end

-- Upgrade Liste alt? (noch keine, anderes Level, oder Ausruestung seit dem Scan gewechselt)
local equipAt = 0
local function Stale()
  return not ns.gearQuests or ns.gearLvl ~= UnitLevel("player") or equipAt > (ns.gearScanAt or 0)
end
do
  local ef = CreateFrame("Frame")
  ef:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
  ef:SetScript("OnEvent", function() equipAt = GetTime() end)
end

function ns.ToggleUpgradeStrip()
  BuildStrip()
  if not strip then return end
  if strip:IsShown() then strip:Hide() return end
  if Active() and Stale() and ns.GearScan and not (ns.GearBusy and ns.GearBusy()) then
    ns.GearScan(function() ns.UpgradeMarks(); if strip:IsShown() then ShowSlot(nil) end end)
  end
  ShowSlot(nil)
  strip:Show()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:SetScript("OnEvent", function(_, e)
  if e == "PLAYER_LEVEL_UP" then
    C_Timer.After(1, function() if ns.UpgradeStripRefresh then ns.UpgradeStripRefresh() end end)
    return
  end
  if not CharacterFrame then return end
  CharacterFrame:HookScript("OnShow", function()
    if ns.UpgradeStripRefresh then ns.UpgradeStripRefresh() end
    if not Active() then return end
    if Stale() and ns.GearScan and not (ns.GearBusy and ns.GearBusy()) then
      ns.GearScan(function() ns.UpgradeMarks() end)
    else
      ns.UpgradeMarks()
    end
  end)
end)
