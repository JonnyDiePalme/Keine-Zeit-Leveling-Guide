local ADDON, ns = ...
-- 1.1 (P39, S 11:24): Mini Fenster zeigt ohne eigene Wahl 3 naechste Schritte. Wer schon gewaehlt hat, behaelt seine Zahl
ns.HUD_STEPS_STD = 3
function ns.HudSteps()
  local n = ns.db and tonumber(ns.db.hudSteps)
  return n or ns.HUD_STEPS_STD
end
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

local panel, statusText, toggleBtn, nameBox

local function Run(cmd)
  SlashCmdList.TAURENROUTE(cmd)
end

-- 18.0: Text auf eine Zeile im Mini Fenster kuerzen (echt gemessen mit der Schrift vom Ziel), Ergebnis gemerkt.
-- prefix: steht davor (zaehlt mit). place: Ortsangabe, dann zuerst beim letzten Komma kuerzen (nicht in Koordinaten), sonst "..".
local fitFS, fitCache, fitN = nil, {}, 0
local function FitWidth(t)
  fitFS:SetText(t)
  local w = fitFS.GetUnboundedStringWidth and fitFS:GetUnboundedStringWidth() or fitFS:GetStringWidth()
  return w or 0
end
function ns.FitLine(text, prefix, place)
  if type(text) ~= "string" or text == "" then return text end
  local hud = _G.TaurenRouteHUD
  local maxW = (hud and hud.target and hud.target.GetWidth and hud.target:GetWidth()) or 0
  if maxW < 60 then maxW = 238 end
  prefix = prefix or ""
  local key = prefix .. "\1" .. text .. "\1" .. math.floor(maxW) .. (place and "p" or "")
  local hit = fitCache[key]
  if hit then return hit end
  if not fitFS then
    local f = CreateFrame("Frame", nil, UIParent)
    f:Hide()
    fitFS = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    fitFS:SetWordWrap(false)
  end
  local out = text
  if FitWidth(prefix .. text) > maxW - 2 then
    out = nil
    if place then
      -- von hinten: "Ort, Zusatz, Zusatz" -> so viele Teile wie passen (", " vor einer Zahl ist eine Koordinate)
      local cuts, i = {}, 1
      while true do
        local a = text:find(", ", i, true)
        if not a then break end
        if not text:sub(a + 2, a + 2):match("%d") then cuts[#cuts + 1] = a end
        i = a + 2
      end
      for j = #cuts, 1, -1 do
        local t = text:sub(1, cuts[j] - 1)
        if FitWidth(prefix .. t) <= maxW - 2 then out = t; break end
      end
    end
    if not out then
      -- Zeichen genau (UTF-8 sicher), am Wortende abschneiden wenn moeglich
      local lo, hi = 1, #text
      while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local t = text:sub(1, mid):gsub("[\192-\255][\128-\191]*$", "")
        if FitWidth(prefix .. t .. "..") <= maxW - 2 then lo = mid else hi = mid - 1 end
      end
      local t = text:sub(1, lo):gsub("[\192-\255][\128-\191]*$", "")
      local w = t:match("^(.*%S)%s+%S*$")
      if w and #w >= #t * 0.6 then t = w end
      out = t:gsub("[%s:,%-]+$", "") .. ".."
    end
  end
  fitN = fitN + 1
  if fitN > 400 then fitCache, fitN = {}, 0 end
  fitCache[key] = out
  return out
end
-- 18.6: Ziel Zeile mit Herkunft ("Ziel: Item (von Kiste)") hoechstens zwei Zeilen. Zu lang: Ziel auf die erste Zeile,
-- die Herkunft grau auf die zweite, beide gekuerzt (Sim Teil A: "Halber Anhänger der Wasser-Beweglichkeit (von Merkwürdige
-- Schließkassette)" ging auf drei Zeilen)
function ns.FitTwo(text)
  if type(text) ~= "string" or text == "" or text:find("\n", 1, true) then return text end
  local hud = _G.TaurenRouteHUD
  local maxW = (hud and hud.target and hud.target.GetWidth and hud.target:GetWidth()) or 0
  if maxW < 60 then maxW = 238 end
  if not fitFS then ns.FitLine("x") end
  if FitWidth(text) <= (maxW - 2) * 1.8 then return text end
  local main, src = text:match("^(.-)%s(%b())$")
  if not main or main == "" then return ns.FitLine(text) end
  return ns.FitLine(main) .. "\n|cff9d9d9d" .. ns.FitLine(src) .. "|r"
end

function ns.RefreshUI()
  if not panel or not panel:IsShown() then return end
  statusText:SetText(ns.Status())
  toggleBtn:SetText(ns.db.show and TR"Route aus" or TR"Route an")
  local atMax = (UnitLevel("player") or 0) >= ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60)
  local txt = ns.db.planText or (atMax and TR"Level 60 erreicht, kein Plan bis 60 mehr." or TR"Plan bis Level 60 wird gerade berechnet ...")
  local qc = ns.questCheck
  if qc and qc.lines then
    txt = table.concat(qc.lines, "\n") .. "\n\n" .. txt
  end
  local w = ns.levelWarn
  if w and not w.ignored and w.lines then
    txt = table.concat(w.lines, "\n") .. "\n\n" .. txt
  end
  panel.planText:SetText(txt)
  panel.planChild:SetHeight(panel.planText:GetStringHeight() + 10)
end


local function MakeButton(parent, text, w, x, y, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 24)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function MakeHeader(parent, text, y)
  local t = parent:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
  t:SetText(text)
  return t
end

local function BuildPanel()
  panel = CreateFrame("Frame", "TaurenRoutePanel", UIParent, "BasicFrameTemplateWithInset")
  panel:SetSize(350, 680)
  panel:SetPoint("CENTER")
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", panel.StartMoving)
  panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
  panel:SetClampedToScreen(true)
  panel:Hide()
  if ns.CloseOnEscape then ns.CloseOnEscape(panel) end

  local title = panel:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  title:SetPoint("TOP", panel, "TOP", 0, -6)
  title:SetText(TR"Keine Zeit Leveling Guide")

  statusText = panel:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  statusText:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -34)
  statusText:SetWidth(238)
  statusText:SetJustifyH("LEFT")

  local L, R, W = 16, 138, 116

  MakeHeader(panel, TR"Route", -100)
  toggleBtn = MakeButton(panel, TR"Route aus", W, L, -118, function()
    Run(ns.db.show and "aus" or "an")
  end)
  MakeButton(panel, TR"Zone ID", W, R, -118, function() Run("id") end)
  MakeButton(panel, TR"Mini Fenster", 74, 260, -118, function() ns.ToggleHud() end)
  MakeButton(panel, TR"Pfeil", 74, 260, -146, function() ns.ToggleArrow() end)
  MakeButton(panel, TR"Karte Zeit", 74, 260, -174, function() SlashCmdList.TAURENROUTEMAP() end)
  MakeButton(panel, TR"Warnung weg", 74, 260, -210, function() Run("ignorieren") end)
  MakeButton(panel, TR"Level check", 74, 260, -238, function() Run("check") end)
  MakeButton(panel, TR"Auto Quest", 74, 260, -282, function() ns.ToggleAutoQuest() end)
  MakeButton(panel, TR"Quest Check", 74, 260, -310, function() ns.PrintQuestCheck(); ns.RefreshUI() end)
  MakeButton(panel, TR"Gefahr hier", 74, 260, -346, function() Run("gefahr") end)
  MakeButton(panel, TR"Gefahr weg", 74, 260, -374, function() Run("gefahrweg") end)
  MakeButton(panel, TR"< Zurück", W, L, -146, function() Run("back") end)
  MakeButton(panel, TR"Nächster >", W, R, -146, function() Run("next") end)
  MakeButton(panel, TR"Zone neu starten", W * 2 + 6, L, -174, function() Run("reset") end)

  MakeHeader(panel, TR"Eigene Route", -210)
  nameBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
  nameBox:SetSize(W * 2, 20)
  nameBox:SetPoint("TOPLEFT", panel, "TOPLEFT", L + 6, -228)
  nameBox:SetAutoFocus(false)
  nameBox:SetMaxLetters(40)
  nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local hint = nameBox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  hint:SetPoint("LEFT", nameBox, "LEFT", 2, 0)
  hint:SetText(TR"Name (leer = Gebietsname)")
  nameBox:SetScript("OnTextChanged", function(self) hint:SetShown(self:GetText() == "") end)

  MakeButton(panel, TR"Punkt hier speichern", W * 2 + 6, L, -254, function()
    local name = nameBox:GetText() or ""
    Run(TR"add " .. name)
    nameBox:SetText("")
    nameBox:ClearFocus()
  end)
  MakeButton(panel, TR"Letzten löschen", W, L, -282, function() Run("undo") end)
  MakeButton(panel, TR"Route löschen", W, R, -282, function() ns.Confirm(TR"Eigene Route in dieser Zone wirklich löschen?", TR"Ja", function() Run("clear") end, TR"Nein") end)
  MakeButton(panel, TR"In Chat exportieren", W * 2 + 6, L, -310, function() Run("export") end)

  MakeHeader(panel, TR"Radius", -346)
  MakeButton(panel, TR"Kleiner", W, L, -364, function()
    Run((TR"radius %.3f"):format(math.max(0.005, ns.db.radius - 0.005)))
  end)
  MakeButton(panel, TR"Grösser", W, R, -364, function()
    Run((TR"radius %.3f"):format(math.min(0.1, ns.db.radius + 0.005)))
  end)

  MakeHeader(panel, TR"Plan bis Level 60", -400)

  -- Plan in einem scrollbaren Bereich
  local sf = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -422)
  sf:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -32, 12)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(300, 10)
  sf:SetScrollChild(child)
  panel.planChild = child
  panel.planText = child:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  panel.planText:SetPoint("TOPLEFT", child, "TOPLEFT", 0, 0)
  panel.planText:SetWidth(300)
  panel.planText:SetJustifyH("LEFT")
  panel.planText:SetSpacing(2)

  panel:SetScript("OnShow", ns.RefreshUI)
end

local function TogglePanel()
  if panel:IsShown() then panel:Hide() else panel:Show() end
end

local function OnClick(button)
  if button == "RightButton" then
    Run(ns.db.show and "aus" or "an")
  elseif not (ns.OpenCharPage and ns.OpenCharPage()) then
    TogglePanel()
  end
end

local function FillTooltip(tt)
  tt:AddLine(TR"Keine Zeit Leveling Guide")
  tt:AddLine(TR"Linksklick: Keine Zeit Leveling Guide Seite", 1, 1, 1)
  tt:AddLine(TR"Rechtsklick: Route an/aus", 1, 1, 1)
end

-- Eigener Button, nur falls kein LibDBIcon da ist
local function BuildOwnButton()
  local db = ns.db
  db.minimapAngle = db.minimapAngle or 220

  local b = CreateFrame("Button", "TaurenRouteMinimapButton", Minimap)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")

  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)

  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Map_01")
  icon:SetPoint("TOPLEFT", 7, -6)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT")

  -- passt sich an runde und eckige Minimap (ElvUI) an
  local function UpdatePos()
    local a = math.rad(db.minimapAngle)
    local x, y = math.cos(a), math.sin(a)
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    if shape == "SQUARE" then
      local m = math.max(math.abs(x), math.abs(y))
      x, y = x / m, y / m
    end
    local w = Minimap:GetWidth() / 2 + 5
    local h = Minimap:GetHeight() / 2 + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x * w, y * h)
  end
  UpdatePos()
  ns.ResetButton = function() db.minimapAngle = 220; b:Show(); UpdatePos() end

  b:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      db.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
      UpdatePos()
    end)
  end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnClick", function(_, button) OnClick(button) end)
  b:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_LEFT")
    FillTooltip(GameTooltip)
    GameTooltip:AddLine(TR"Ziehen: Knopf verschieben", 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function BuildMinimapButton()
  local db = ns.db
  local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
  local DBI = LibStub and LibStub("LibDBIcon-1.0", true)

  if LDB then
    -- Launcher fuer ElvUI Datatexte, MinimapButtonButton, Titan usw.
    local obj = LDB:NewDataObject("ForeverWegweiser", {
      type = "launcher",
      text = TR"Keine Zeit Leveling Guide",
      icon = "Interface\\Icons\\INV_Misc_Map_01",
      OnClick = function(_, button) OnClick(button) end,
      OnTooltipShow = FillTooltip,
    })
    if DBI and obj then
      db.minimap = db.minimap or {}
      DBI:Register("ForeverWegweiser", obj, db.minimap)
      ns.ResetButton = function() db.minimap.hide = false; DBI:Show("ForeverWegweiser") end
      return
    end
  end
  BuildOwnButton()
end

-- Mini Fenster (A1): Normal mit drei Knoepfen, Klein nur Ziel und Weg, oder nur der Pfeil
local hud
local function T() return ns.T end
local function ACC() return T().AccT() end

local function HudSkin(f, kind) T().Skin(f, kind or "inset") end

local function HudBar(parent, h, col)
  local b = CreateFrame("StatusBar", nil, parent)
  b:SetHeight(h)
  b:SetStatusBarTexture(T().BarTexture())
  b:SetStatusBarColor(col[1], col[2], col[3], 0.9)
  b:SetMinMaxValues(0, 1)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.08)
  return b
end

-- kleiner Knopf im Mini Fenster
local function HudButton(parent, text, tip, fn)
  local b = T().Button(parent, text, 60, 20)
  local ic = T().HudIcon and T().HudIcon(text, 14)
  if ic then b:SetText(ic .. " " .. text) end
  b:SetScript("OnClick", fn)
  b:SetScript("OnEnter", function(self)
    if self.lockText then return end
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(text)
    if tip then GameTooltip:AddLine(tip, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

-- Menue: kurz, zu zweit nebeneinander. Oben der Wechsel zwischen Leveling Route und Tour (Routen Profile),
-- "Farmen stoppen" (oder "Tour beenden") nur, solange eine laeuft.
local function Big(v) return function() if ns.ShowBig then ns.ShowBig(v) end end end
-- 20.3l / 20.3z (P13): Nach 60 alle offenen Quests (Menue, Planen Kachel, Hinweis im Mini Fenster)
function ns.RestQuestsRoute()
  if not ns.db then return end
  if ns.ProfileOf and ns.ProfileOf(ns.db.opt) ~= "level" and ns.ProfileSave then ns.ProfileSave() end
  ns.db.profileCur = "level"
  if ns.AutoOpt then ns.AutoOpt("hand") end
end
-- laeuft gerade eine Farm Route (Berufe, Gold Mobs, Ruf Mobs, Gold oder Ruf Quests)?
function ns.FarmRunning()
  local o = ns.db and ns.db.opt
  if ns.farmSess or ns.repFarm then return true end
  return o and (o.prof or o.farm or o.repFarm or (o.opts and (o.opts.gold or o.opts.rep))) and (o.idx or 1) <= #(o.steps or {}) and true or false
end
-- Farm Route oder Tour beenden: Profil weg, zurueck zur Leveling Route
function ns.ExtraStop()
  local db = ns.db
  local o = db and db.opt
  if ns.farmSess and ns.FarmStop then ns.FarmStop(); return end
  if ns.repFarm and ns.RepMobStop then ns.RepMobStop(); return end
  if o and ns.ProfileOf and ns.ProfileOf(o) == "extra" then
    if o.prof and ns.ProfFinish then ns.ProfFinish() end
    o.idx = #(o.steps or {}) + 1
    if ns.ProfileBackToLevel then ns.ProfileBackToLevel() end
    return
  end
  -- laeuft gerade die Leveling Route: die gemerkte Tour wegwerfen
  if db and db.profiles and db.profiles.extra then
    db.profiles.extra = nil
    if ns.TestLog then ns.TestLog("PROFIL", "beendet (gemerkt)") end
    ns.Print(TR"Tour beendet, es geht mit der Leveling Route weiter.")
  end
end
-- Ziel waehlen: kleines Menue mit allem, was es gerade gibt
function ns.GoalMenu(owner)
  local T0 = ns.T
  if not (T0 and T0.ShowMenu) then return end
  local L = {}
  local function Add(text, key, fn, tip) if not key or ns.Unlocked(key) then L[#L + 1] = { text = text, fn = fn, tip = tip } end end
  local farm = ns.FarmOn and ns.FarmOn() -- 20.4b: braucht das Farming Zusatz Addon
  L[#L + 1] = { head = true, text = TR"Ziel wählen" }
  Add(TR"Leveling Route", nil, function() if ns.ProfileSwitch then ns.ProfileSwitch("level") end end, TR"Zurück zur Leveling Route, beim Schritt, wo du warst.")
  Add(TR"Ausrüstung", "gear", Big("gear"), TR"Quests, deren Belohnung besser ist als das, was du anhast.")
  Add(TR"Bücher", "books", Big("books"), TR"Bibliotheksbücher, die du noch nicht hast, mit Route dorthin.")
  Add(TR"Dungeons", "dungeons", Big("dungeons"), TR"Quests für passende Dungeons holen und zum Eingang.")
  Add(TR"Ruf", "rep", Big("rep"), TR"Quests und Mobs für eine Fraktion.")
  if farm then
    Add(TR"Berufe", "berufe", Big("berufe"), TR"Kräuter, Erz, Leder, Stoff, Fleisch und Fische farmen.")
    Add(TR"Gold", "farm", Big("farm"), TR"Die besten Spots und Quests für Gold.")
  end
  Add(TR"Questlog Route", "questlog", function() if ns.TourQuestLog then ns.TourQuestLog() end end, TR"Route nur mit den Quests, die schon in deinem Log sind.")
  Add(TR"Flugpunkte Tour", "flights", function() if ns.TourFlights then ns.TourFlights() end end, TR"Eine Runde zu allen Flugpunkten, die dir fehlen.")
  Add(TR"Entdecken Tour", "explore", function() if ns.TourExplore then ns.TourExplore() end end, TR"Eine Runde zu allen Gebieten, die du noch nicht aufgedeckt hast.")
  Add(TR"Stunden Budget", "budget", function() if ns.ShowBudget then ns.ShowBudget() end end, TR"Wie lange willst du spielen? Die Route endet im Gasthaus.")
  Add(TR"Lehrer als Schritt", nil, function() if ns.OptInsertService then ns.OptInsertService("trainer") end end, TR"Nächster Lehrer deiner Klasse kommt als Schritt in deine Route.")
  Add(ns.db and ns.db.paused and TR"Weitermachen" or TR"Pause", nil, function() if ns.SetPaused then ns.SetPaused(not ns.db.paused) end end, TR"Hält alles an, nichts wird mehr gerechnet. Nochmal klicken macht weiter.")
  T0.ShowMenu(owner, L)
end
-- Menue vom Mini Fenster, in drei Bereichen (17.3, Wunsch: aufgeraeumt). Schritt ueberspringen ist raus, das macht Weiter.
local MENU = {
  { head = TR"Route", profRow = true },
  { TR"Leveling Route", nil, function()
      if ns.NaviHide then ns.NaviHide() end
      if ns.ProfileSwitch and ns.ProfileOf and ns.ProfileOf(ns.db.opt) ~= "level" then ns.ProfileSwitch("level") end
    end, half = true, prof = "level",
    tip = TR"Zurück zur Leveling Route, beim Schritt, wo du warst. Was du dazwischen gemacht hast, zählt mit.",
    rel = function() return (ns.ProfileExtraName and ns.ProfileExtraName() ~= nil) or ns.navi ~= nil end },
  { TR"Tour", nil, function() if ns.NaviHide then ns.NaviHide(true) end; if ns.ProfileSwitch then ns.ProfileSwitch("extra") end end, half = true, prof = "extra",
    tip = TR"Zurück zu deiner Tour oder Farm Route. Die Leveling Route bleibt gemerkt.", rel = function() return ns.ProfileExtraName and ns.ProfileExtraName() ~= nil end },
  -- 17.5 (Wunsch Sascha): das Navi ist ein eigenes Profil wie die Tour, ausblenden laesst es gemerkt
  { TR"Navi", nil, function() if ns.NaviShow then ns.NaviShow() end end, half = true, prof = "navi",
    tip = TR"Zurück zu deinem Navi Ziel. Ausblenden: Leveling Route. Ganz beenden: Navi beenden.", rel = function() return ns.navi ~= nil end },
  { TR"Neu rechnen", nil, function() if ns.AutoOpt then ns.AutoOpt("hand") end end, half = true,
    tip = TR"Rechnet ab hier neu, zum Beispiel nach einem Umweg. Der Plan bis 60 bleibt." },
  -- 20.3l (S Wunsch, Log 20.3k K3): auf Max Level ein eigener Knopf fuer alle restlichen Quests (Leveling Route neu)
  { TR"Alle übrigen Quests", nil, function() if ns.RestQuestsRoute then ns.RestQuestsRoute() end end,
    tip = TR"Du bist auf Max Level: rechnet eine Route mit allen Quests, die du noch machen kannst.",
    rel = function()
      local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
      return (UnitLevel("player") or 0) >= maxL and not (ns.ProfileOf and ns.db and ns.ProfileOf(ns.db.opt) == "extra")
    end },
  { TR"Farmen stoppen", nil, function() if ns.ExtraStop then ns.ExtraStop() end end, half = true, stop = true,
    tip = TR"Beendet die Farm Route oder Tour. Danach geht die Leveling Route weiter.",
    rel = function() return ns.ProfileExtraName and ns.ProfileExtraName() ~= nil end },
  { TR"Navi beenden", nil, function() if ns.NaviStop then ns.NaviStop(TR"Navi beendet, Pfeil wieder auf der Route.") end end, half = true,
    tip = TR"Das Navi ganz beenden. Es geht mit der Route weiter.", rel = function() return ns.navi ~= nil end },
  { head = TR"Unterwegs" },
  { TR"Händler", "vendor", function() if ns.OptInsertService then ns.OptInsertService("vendor") end end, half = true,
    tip = TR"Der nächste Händler zum Verkaufen und Reparieren kommt als Schritt dazu. Nochmal klicken nimmt ihn raus." },
  { TR"Feierabend", "sleep", function() if ns.EndSession then ns.EndSession() end end, half = true,
    tip = TR"Route zum nächsten Gasthaus, mit Quests am Weg. Dort ausloggen gibt Ruhe XP." },
  { TR"Einkaufsliste", "shop", function() if ns.ShowShopping then ns.ShowShopping() end end, half = true,
    tip = TR"Was du für die nächsten Quests kaufen musst und wo." },
  { TR"Ziel wählen", nil, function(row) if ns.GoalMenu then ns.GoalMenu(row) end end, half = true, keepOpen = true,
    tip = TR"Ausrüstung, Bücher, Dungeons, Ruf, Berufe, Gold, Touren, Stunden Budget, Lehrer und Pause." },
  { head = TR"Fenster" },
  { TR"Grosses Fenster", nil, function() if ns.ToggleBig then ns.ToggleBig() end end, half = true },
  -- 19.32 (Saschas Runde 1 Punkt 5): mehr nächste Schritte im Mini Fenster (5), nochmal klicken wieder 1. Genauer (1, 3, 5,
  -- 8) unter Einstellungen
  -- 20.1 (P1, Wunsch Sascha): sind schon mehrere Schritte zu sehen, heisst der Knopf Weniger Schritte (zurueck auf 2:
  -- der jetzige und der naechste), beide mit eigenem Symbol
  -- 20.3j (S Test 20.3g Punkt 1 und 1b): durchklicken 1, 3, 5, 8 naechste Schritte (dann wieder 1), gleich wie unter
  -- Einstellungen. Das Menue bleibt offen, damit man die Zahl sieht
  { TR"Mehr Schritte", nil, function()
      local db = ns.db
      local NEXT = { [1] = 3, [3] = 5, [5] = 8, [8] = 1 }
      -- 1.1 (P39): eigene Wahl wird fest gespeichert (auch 1), ohne Wahl gilt der Standard ns.HUD_STEPS_STD
      db.hudSteps = NEXT[ns.HudSteps()] or ns.HUD_STEPS_STD
      if db.hudSteps > 1 and db.hudSize == "small" then db.hudSize = "normal"; if ns.ApplyHudSize then ns.ApplyHudSize() end end
      if ns.RefreshHud then pcall(ns.RefreshHud) end
    end, half = true, steps = true, keepOpen = true,
    tip = TR"Wie viele nächste Schritte das Mini Fenster zeigt: 1, 3, 5, 8, dann wieder 1. Gleich wie unter Einstellungen." },
  { TR"Gruppen Ansicht", nil, function()
      ns.db.hudGroup = not (ns.db.hudGroup ~= false)
      if ns.HudGroupUpdate then ns.HudGroupUpdate() end
    end, half = true, rel = function() return IsInGroup and IsInGroup() end,
    tip = TR"Pro Mitspieler eine Zeile mit seinem Schritt. Klick auf einen Namen: hinlaufen und helfen." },
}

-- Mini Fenster groesser oder kleiner: die Mitte bleibt, wo sie ist
ns.HUD_MIN, ns.HUD_MAX = 0.7, 2
function ns.SetHudScale(v)
  local db = ns.db
  if not db then return end
  v = math.floor(math.max(ns.HUD_MIN, math.min(ns.HUD_MAX, v or 1)) * 10 + 0.5) / 10
  if db.hudScale == v then return end
  db.hudScale = v
  if not hud then return end
  local cx, cy = hud:GetCenter()
  local s0 = hud:GetEffectiveScale()
  hud:SetScale(v * ((ns.FontScale and ns.FontScale()) or 1))
  if cx and cy then
    local s1 = hud:GetEffectiveScale()
    hud:ClearAllPoints()
    hud:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx * s0 / s1, cy * s0 / s1)
    db.hudPos = { "CENTER", "BOTTOMLEFT", cx * s0 / s1, cy * s0 / s1 }
  end
  if hud.PlaceExt then hud.PlaceExt() end
  if ns.NoticeUpdate then ns.NoticeUpdate() end
end

local function BuildHud0()
  local db = ns.db
  local W = 256
  hud = CreateFrame("Frame", "TaurenRouteHUD", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud:SetSize(W, 80)
  hud:SetFrameStrata("MEDIUM")
  hud:SetClampedToScreen(true)
  hud:SetMovable(true)
  hud:EnableMouse(true)
  hud:RegisterForDrag("LeftButton")
  HudSkin(hud, T().IsElv() and "window" or "tooltip")
  local A = ACC()

  -- farbiger Strich links (Farbe vom Ziel), Maus drauf erklaert die Farben
  hud.stripe = hud:CreateTexture(nil, "ARTWORK")
  hud.stripe:SetPoint("TOPLEFT", 3, -4)
  hud.stripe:SetPoint("BOTTOMLEFT", 3, 4)
  hud.stripe:SetWidth(2)
  hud.stripeTip = CreateFrame("Frame", nil, hud)
  hud.stripeTip:SetPoint("TOPLEFT", 0, -4); hud.stripeTip:SetPoint("BOTTOMLEFT", 0, 4); hud.stripeTip:SetWidth(8)
  hud.stripeTip:EnableMouse(true)
  hud.stripeTip:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(TR"Farbe vom Schritt")
    for _, c in ipairs(ns.KIND_COLORS or {}) do GameTooltip:AddLine(c[2], c[1][1], c[1][2], c[1][3]) end
    GameTooltip:Show()
  end)
  hud.stripeTip:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Zeile 1: Logo, Zone der Route und Schritt in dieser Zone. Zeile 2 klein: danach die naechste Zone
  hud.logo = T().Logo(hud, 14)
  hud.logo:SetPoint("TOPLEFT", 10, -7)
  hud.zone = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  hud.zone:SetPoint("LEFT", hud.logo, "RIGHT", 5, 0)
  hud.zone:SetPoint("RIGHT", hud, "RIGHT", -8, 0)
  hud.zone:SetJustifyH("LEFT"); hud.zone:SetWordWrap(false)
  hud.step = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  hud.step:SetPoint("TOPLEFT", 29, -20)
  hud.step:SetPoint("RIGHT", hud, "RIGHT", -8, 0)
  hud.step:SetJustifyH("LEFT"); hud.step:SetWordWrap(false)
  hud.zbar = HudBar(hud, 2, A)
  hud.zbar:SetPoint("TOPLEFT", 10, -24)
  hud.zbar:SetPoint("TOPRIGHT", -8, -24)
  -- Maus auf die Kopfzeile: was die Zahlen heissen
  hud.headTip = CreateFrame("Frame", nil, hud)
  hud.headTip:SetPoint("TOPLEFT", 8, -2); hud.headTip:SetPoint("TOPRIGHT", -8, -2); hud.headTip:SetHeight(26)
  hud.headTip:EnableMouse(true)
  hud.headTip:SetScript("OnEnter", function(self)
    local i = ns.HudInfo and ns.HudInfo() or {}
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(i.zoneName or TR"Route")
    if i.zoneTotal then GameTooltip:AddLine((TR"Schritt %d von %d in dieser Zone. Der Balken zeigt, wie weit du hier bist."):format(i.zoneIdx or 1, i.zoneTotal), 1, 1, 1, true) end
    if i.nextZone then GameTooltip:AddLine((TR"Danach geht es nach %s."):format(i.nextZone), 0.8, 0.8, 0.8, true) end
    if i.total then GameTooltip:AddLine((TR"Ganze Route bis 60: Schritt %d von %d"):format(i.idx or 1, i.total), 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
  end)
  hud.headTip:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Ziel
  hud.kind = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.kind:SetPoint("TOPLEFT", 10, -31)
  hud.target = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  hud.target:SetPoint("TOPLEFT", 10, -44)
  hud.target:SetWidth(W - 18)
  hud.target:SetJustifyH("LEFT")
  -- lange Ziele (Lehrer mit langem Namen, Item von Mob) duerfen zwei Zeilen haben, das HUD waechst mit
  hud.target:SetWordWrap(true)
  if hud.target.SetMaxLines then hud.target:SetMaxLines(4) end
  hud.dist = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  hud.dist:SetPoint("TOPRIGHT", -8, -31)

  -- Zusatzzeilen (Questfortschritt, Warnung), nur wenn noetig
  hud.extra = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.extra:SetPoint("TOPLEFT", hud.target, "BOTTOMLEFT", 0, -3)
  hud.extra:SetWidth(W - 18)
  hud.extra:SetJustifyH("LEFT")
  hud.extra:SetSpacing(2)

  -- Ueberspringen Empfehlung mit Knopf
  hud.skip = CreateFrame("Button", nil, hud, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud.skip:SetHeight(20)
  HudSkin(hud.skip)
  if hud.skip.SetBackdropBorderColor then hud.skip:SetBackdropBorderColor(1, 0.5, 0.1, 0.9) end
  hud.skip.text = hud.skip:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.skip.text:SetPoint("CENTER")
  local shl = hud.skip:CreateTexture(nil, "HIGHLIGHT")
  shl:SetAllPoints()
  shl:SetColorTexture(1, 0.5, 0.1, 0.2)
  hud.skip:SetScript("OnClick", function() ns.DoSkip(); hud.Update() end)
  hud.skip:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TR"Punkte zurückstellen")
    GameTooltip:AddLine(self.tip or "", 1, 1, 1, true)
    GameTooltip:AddLine(TR"Die Punkte kommen wieder, sobald du das Level hast.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  hud.skip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  hud.skip:Hide()

  -- Service Hinweis (Lehrer, Haendler, Reparatur, Flugpunkt, Ruhestein) mit Knopf
  hud.svc = CreateFrame("Button", nil, hud, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud.svc:SetHeight(20)
  HudSkin(hud.svc)
  if hud.svc.SetBackdropBorderColor then hud.svc:SetBackdropBorderColor(0.3, 0.8, 1, 0.9) end
  -- Hinweis Texte duerfen zwei Zeilen haben, die Box waechst mit
  local function TwoLines(fs, w)
    fs:SetWidth(w)
    fs:SetJustifyH("LEFT"); fs:SetJustifyV("MIDDLE")
    fs:SetWordWrap(true)
    if fs.SetMaxLines then fs:SetMaxLines(4) end
    fs:SetSpacing(1)
  end
  hud.svc.text = hud.svc:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.svc.text:SetPoint("LEFT", 6, 0)
  TwoLines(hud.svc.text, W - 18 - 30)
  local vhl = hud.svc:CreateTexture(nil, "HIGHLIGHT")
  vhl:SetAllPoints()
  vhl:SetColorTexture(0.3, 0.8, 1, 0.2)
  hud.svc:SetScript("OnClick", function()
    if ns.serviceTarget and ns.serviceTarget.kind == "navi" and ns.NaviHide then ns.NaviHide()
    elseif ns.serviceTarget then ns.serviceTarget = nil; if ns.Draw then ns.Draw() end
    elseif ns.HintClick then ns.HintClick(hud.curHint) end
    hud.Update()
  end)
  hud.svc:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_TOP")
    local h = hud.curHint
    if h and h.text and not ns.serviceTarget then GameTooltip:AddLine(h.text, 1, 1, 1, true) end
    if h and h.tip and not ns.serviceTarget then GameTooltip:AddLine(h.tip, 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine(ns.serviceTarget and TR"Klick: Pfeil wieder auf die Route" or ((h and h.onClick) and TR"Klick: öffnen" or ((h and (h.target or ns.svcHint == h)) and TR"Klick: Pfeil dorthin" or "")), 0.5, 0.8, 1)
    GameTooltip:Show()
  end)
  hud.svc:SetScript("OnLeave", function() GameTooltip:Hide() end)
  hud.svc:Hide()
  hud.svcX = CreateFrame("Button", nil, hud.svc, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud.svcX:SetSize(18, 16)
  hud.svcX:SetPoint("RIGHT", hud.svc, "RIGHT", -2, 0)
  HudSkin(hud.svcX)
  local xt = hud.svcX:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  xt:SetPoint("CENTER", 0, 0)
  xt:SetText("x")
  local xhl = hud.svcX:CreateTexture(nil, "HIGHLIGHT")
  xhl:SetAllPoints()
  xhl:SetColorTexture(1, 0.3, 0.3, 0.3)
  hud.svcX:SetScript("OnClick", function() if ns.HintDismiss then ns.HintDismiss(hud.curHint) end; hud.Update() end)
  hud.svcX:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TR"Auslassen")
    GameTooltip:AddLine(TR"Lehrer: bis zum nächsten Level. Bücher: bis zur nächsten Stufe. Sonst: eine Weile Ruhe.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  hud.svcX:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- neue Funktion: kleiner Hinweis, Klick zeigt die Erklaerung
  hud.hint = CreateFrame("Button", nil, hud, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud.hint:SetHeight(20)
  HudSkin(hud.hint, "sel")
  hud.hint.text = hud.hint:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.hint.text:SetPoint("LEFT", 6, 0)
  TwoLines(hud.hint.text, W - 18 - 12)
  hud.hint:SetScript("OnClick", function() if ns.TakePendingUnlock then ns.TakePendingUnlock() end; hud.Update() end)
  hud.hint:Hide()

  -- Gruppe: Fortschritt der anderen bei gemeinsamen Quests
  hud.group = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.group:SetJustifyH("LEFT")
  hud.group:SetSpacing(2)

  -- XP Balken und Tempo
  hud.xbar = HudBar(hud, 12, { 0.58, 0.0, 0.55 })
  -- heller Bereich: XP der fertigen Quests, die noch abgegeben werden muessen
  hud.xpend = hud.xbar:CreateTexture(nil, "BORDER")
  hud.xpend:SetColorTexture(0.86, 0.5, 0.86, 0.45)
  hud.xpend:SetPoint("TOPLEFT", hud.xbar, "TOPLEFT", 0, 0)
  hud.xpend:SetPoint("BOTTOMLEFT", hud.xbar, "BOTTOMLEFT", 0, 0)
  hud.xpend:Hide()
  hud.xbar:EnableMouse(true)
  hud.xbar:SetScript("OnEnter", function(self)
    local p = self.pend
    if not p then return end
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TR"Fertige Quests abgeben")
    GameTooltip:AddLine((TR"%d XP aus %d Quests"):format(p.xp, p.n), 1, 1, 1)
    GameTooltip:AddLine((TR"Danach: Level %d  %d%%"):format(p.lv, p.pct), 1, 1, 1)
    GameTooltip:AddLine(TR"Der helle Teil im Balken zeigt, wie weit du nach dem Abgeben bist.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  hud.xbar:SetScript("OnLeave", function() GameTooltip:Hide() end)
  hud.xtext = hud.xbar:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.xtext:SetPoint("LEFT", 4, 0)
  hud.xright = hud.xbar:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  hud.xright:SetPoint("RIGHT", -4, 0)
  hud.foot = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  hud.foot2 = hud:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  -- Tooltips fuer die Fusszeile: XP pro Stunde links, fertige Quests oder Lauftempo rechts
  local function FootTip(fs, fn)
    local tf = CreateFrame("Frame", nil, hud)
    tf:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 2); tf:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -2)
    tf:EnableMouse(true)
    tf:SetScript("OnEnter", function(self) ns.TipOwner(self, "ANCHOR_TOP"); fn(); GameTooltip:Show() end)
    tf:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return tf
  end
  hud.footTip = FootTip(hud.foot, function()
    GameTooltip:AddLine(TR"XP pro Stunde")
    GameTooltip:AddLine(TR"Dein Tempo in den letzten Minuten. Daraus kommt die Zeit bis zum nächsten Level.", 1, 1, 1, true)
  end)
  hud.foot2Tip = FootTip(hud.foot2, function()
    local s = ns.Stats and ns.Stats() or {}
    if s.qDone and s.qDone > 0 then
      GameTooltip:AddLine(TR"Fertig zum Abgeben")
      GameTooltip:AddLine((TR"%d Quests im Log sind fertig. Abgeben bringt die XP, der helle Teil im Balken zeigt, wo du danach bist."):format(s.qDone), 1, 1, 1, true)
    else
      GameTooltip:AddLine(TR"Lauftempo")
      GameTooltip:AddLine(TR"100% ist zu Fuss, mit Reittier mehr. Die Route rechnet die Wege damit.", 1, 1, 1, true)
    end
  end)

  -- drei Knoepfe unten: Zurueck, Weiter, Menue
  hud.btns = CreateFrame("Frame", nil, hud)
  hud.btns:SetHeight(20)
  hud.btns:SetPoint("BOTTOMLEFT", 8, 8)
  hud.btns:SetPoint("BOTTOMRIGHT", -8, 8)
  local bBack = HudButton(hud.btns, TR"Zurück", TR"Zeigt den Schritt davor nochmal. Solange du zurück bist, geht die Route nicht von selbst weiter.", function()
    if SlashCmdList.TAURENROUTE then SlashCmdList.TAURENROUTE("back") end
    hud.Update()
  end)
  local bNext = HudButton(hud.btns, TR"Weiter", TR"Einen Schritt vor. Beim aktuellen Schritt: gilt als erledigt.", function()
    if SlashCmdList.TAURENROUTE then SlashCmdList.TAURENROUTE("next") end
    hud.Update()
  end)
  local bMenu = HudButton(hud.btns, TR"Menü", TR"Ziel wechseln, Händler, Feierabend und mehr.", function()
    ns.db.hudExt = not ns.db.hudExt
    hud.ShowMenu()
  end)
  -- 20.3z (S Wunsch 16:58, P12): Pause direkt im Mini Fenster (Pfeil aus, nichts wird gerechnet, nochmal klicken macht weiter)
  local bPause = HudButton(hud.btns, TR"Pause", TR"Hält alles an, nichts wird mehr gerechnet. Nochmal klicken macht weiter.", function()
    if ns.SetPaused and ns.db then ns.SetPaused(not ns.db.paused) end
    hud.Update()
  end)
  hud.bPause = bPause
  -- 1.2a (P44): Hinweis Schritt (zb Haendler bei vollen Taschen) mit eigenem Knopf Ueberspringen, nur solange er dran ist
  hud.bHint = HudButton(hud, TR"Überspringen", TR"Nur ein Hinweis: Schritt raus, weiter mit der Route.", function()
    if ns.OptHintSkip then ns.OptHintSkip() end
    hud.Update()
  end)
  hud.bHint:SetSize(96, 18)
  hud.bHint:Hide()
  hud.btnList = { bBack, bNext, bPause, bMenu }
  hud.bMenu = bMenu
  hud.btns:SetScript("OnSizeChanged", function(self, w)
    local gap = 4
    local bw = ((w or 220) - gap * (#hud.btnList - 1)) / #hud.btnList
    for i, b in ipairs(hud.btnList) do
      b:ClearAllPoints(); b:SetWidth(bw)
      b:SetPoint("LEFT", self, "LEFT", (i - 1) * (bw + gap), 0)
    end
  end)

  -- Menue: Liste unter dem Mini Fenster
  hud.ext = CreateFrame("Frame", nil, hud, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hud.ext:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -2)
  hud.ext:SetPoint("TOPRIGHT", hud, "BOTTOMRIGHT", 0, -2)
  hud.extUp = false
  -- 19.8: steht das Mini Fenster so weit unten, dass das Menue nicht mehr darunter passt: Menue darueber
  -- (sonst liegt es unter dem Bildschirmrand, Sim Teil U: neu17 hud.menu.navi)
  function hud.PlaceExt()
    if not hud.ext:IsShown() then return end
    local h = hud.ext:GetHeight() or 0
    local b, t = hud:GetBottom(), hud:GetTop()
    if not (b and t) then return end
    local sTop = (UIParent:GetTop() or 0) * (UIParent:GetEffectiveScale() or 1) / (hud:GetEffectiveScale() or 1)
    local up = (b < h + 4) and (sTop - t > b)
    if up == hud.extUp then return end
    hud.extUp = up
    hud.ext:ClearAllPoints()
    if up then
      hud.ext:SetPoint("BOTTOMLEFT", hud, "TOPLEFT", 0, 2); hud.ext:SetPoint("BOTTOMRIGHT", hud, "TOPRIGHT", 0, 2)
    else
      hud.ext:SetPoint("TOPLEFT", hud, "BOTTOMLEFT", 0, -2); hud.ext:SetPoint("TOPRIGHT", hud, "BOTTOMRIGHT", 0, -2)
    end
    if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end
  end
  hud:HookScript("OnSizeChanged", function() hud.PlaceExt() end)
  HudSkin(hud.ext, T().IsElv() and "window" or "tooltip")
  hud.ext.rows = {}
  for i, m in ipairs(MENU) do
    if m.head then
      local h = hud.ext:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
      h:SetText(T().Section(m.head))
      hud.ext.rows[i] = { head = true, fs = h, def = m }
    else
      local r = T().Row(hud.ext, m.half and (W - 16) / 2 or (W - 12), 19)
      -- kleines Symbol vor dem Text, damit man schneller findet
      local ic = T().HudIcon and T().HudIcon(m[1], 15)
      r:SetText(ic and (ic .. "  " .. m[1]) or m[1])
      r:SetScript("OnClick", function(self)
        -- 20.3l (Log 20.3j J4): welcher Menue Knopf geklickt wurde, steht im Test Log (Zusatz Route "beendet" kam von hier)
        if ns.TestLog then
          local t = self.GetText and self:GetText() or m[1]
          t = tostring(t or m[1]):gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("^%s+", "")
          ns.TestLog("KNOPF", "Mini Menue: " .. t)
        end
        m[3](self)
        if not m.keepOpen then ns.db.hudExt = false end
        hud.ShowMenu()
        hud.Update()
      end)
      r.def = m
      if m.tip then
        r:SetScript("OnEnter", function(self)
          ns.TipOwner(self, "ANCHOR_RIGHT")
          GameTooltip:AddLine(m[1], 1, 0.82, 0)
          GameTooltip:AddLine(m.tip, 1, 1, 1, true)
          GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
      end
      hud.ext.rows[i] = r
    end
  end
  function hud.ShowMenu()
    -- auch im kleinen Mini Fenster (dort ist der Menue Knopf jetzt auch), nur nicht bei "Nur Pfeil"
    local on = ns.db.hudExt and true or false
    hud.ext:SetShown(on)
    if hud.bMenu.LockHighlight then if on then hud.bMenu:LockHighlight() else hud.bMenu:UnlockHighlight() end end
    if not on then if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end return end
    local function Ok(m) return (not m[2] or ns.Unlocked(m[2])) and (not m.rel or m.rel()) end
    -- Ueberschrift nur, wenn darunter etwas kommt
    local y, col, pendingHead = 6, 0, nil
    local half = (W - 16) / 2
    for i, r in ipairs(hud.ext.rows) do
      local m = r.def
      if r.head then
        r.fs:Hide()
        pendingHead = r
      else
        -- Routen Profil: das laufende gruen, die Tour mit ihrem Namen
        if m.prof then
          local naviOn = ns.navi ~= nil and not ns.navi.hidden
          local act
          if m.prof == "navi" then act = naviOn else act = (not naviOn) and ns.ProfileOf and ns.ProfileOf(ns.db.opt) == m.prof end
          local name = m.prof == "extra" and (ns.ProfileExtraName and ns.ProfileExtraName() or m[1])
            or (m.prof == "navi" and (ns.NaviLabel and ns.NaviLabel() or m[1])) or m[1]
          name = tostring(name):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
          if #name > 18 then name = name:sub(1, 17):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") .. "." end
          local lbl = act and ("|cff40ff40" .. name .. "|r") or name
          local ic = T().HudIcon and T().HudIcon(m[1], 15)
          r:SetText(ic and (ic .. "  " .. lbl) or lbl)
        end
        -- 20.1 (P1): Mehr oder Weniger Schritte, je nachdem was gerade zu sehen ist
        if m.steps then
          local nS = ns.HudSteps()
          local key = (nS >= 8) and TR"Weniger Schritte" or TR"Mehr Schritte"
          local lbl = (TR"Schritte: %d"):format(nS)
          local ic = T().HudIcon and T().HudIcon(key, 15)
          r:SetText(ic and (ic .. "  " .. lbl) or lbl)
        end
        -- Farm Route oder Tour beenden
        if m.stop then
          local lbl = (ns.FarmRunning and ns.FarmRunning()) and TR"Farmen stoppen" or TR"Tour beenden"
          local ic = T().HudIcon and T().HudIcon(lbl, 15)
          r:SetText(ic and (ic .. "  " .. lbl) or lbl)
        end
        local show = Ok(m)
        r:SetShown(show)
        if show then
          if pendingHead then
            if col == 1 then col = 0; y = y + 21 end
            pendingHead.fs:ClearAllPoints(); pendingHead.fs:SetPoint("TOPLEFT", hud.ext, "TOPLEFT", 10, -y - 2)
            pendingHead.fs:Show()
            y = y + 16
            pendingHead = nil
          end
          r:ClearAllPoints()
          if m.half then
            r:SetPoint("TOPLEFT", hud.ext, "TOPLEFT", 6 + col * (half + 4), -y)
            col = col + 1
            if col > 1 then col = 0; y = y + 21 end
          else
            if col == 1 then col = 0; y = y + 21 end
            r:SetPoint("TOPLEFT", hud.ext, "TOPLEFT", 6, -y)
            y = y + 21
          end
        end
      end
    end
    if col == 1 then y = y + 21 end
    hud.ext:SetHeight(y + 6)
    hud.PlaceExt()
    -- 20.3z3 (S Test 20.3z2, Z3: "Leveling Route", "Navi: Gold farmen.", "Grosses Fenster" abgeschnitten): ist ein Knopf Text
    -- zu lang, die Schrift dieses Knopfs etwas kleiner (bis 2 Punkte), sonst ohne Symbol
    for _, r in ipairs(hud.ext.rows) do
      local fs = r.GetFontString and r:GetFontString()
      if fs and r:IsShown() then
        if not r.fz0 then local f, s, fl = fs:GetFont(); r.fz0 = { f, s, fl } end
        if r.fz0[1] and r.fz0[2] then pcall(fs.SetFont, fs, r.fz0[1], r.fz0[2], r.fz0[3]) end
        local k = 0
        while k < 2 and fs.IsTruncated and fs:IsTruncated() and r.fz0[1] and r.fz0[2] do
          k = k + 1
          pcall(fs.SetFont, fs, r.fz0[1], r.fz0[2] - k, r.fz0[3])
        end
        if fs.IsTruncated and fs:IsTruncated() then
          local t = fs:GetText() or ""
          local noIc = t:gsub("^|T.-|t%s*", "")
          if noIc ~= t then fs:SetText(noIc) end
        end
      end
    end
    if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end
  end

  -- Groesse aus den Einstellungen (Schrift, Knoepfe, Menue und Hinweise wachsen mit)
  hud:SetScale(math.max(ns.HUD_MIN, math.min(ns.HUD_MAX, db.hudScale or 1)) * ((ns.FontScale and ns.FontScale()) or 1))
  local p = db.hudPos
  if p then
    hud:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    hud:SetPoint("RIGHT", UIParent, "RIGHT", -250, 0)
  end

  local function DragStart() if not db.hudLocked then hud:StartMoving() end end
  local function DragStop()
    hud:StopMovingOrSizing()
    local a, _, b, x, y = hud:GetPoint()
    db.hudPos = { a, b, x, y }
    if hud.PlaceExt then hud.PlaceExt() end
  end
  -- Rechtsklick sperrt oder entsperrt das Verschieben
  local function MouseUp(_, button)
    if button == "RightButton" then
      db.hudLocked = not db.hudLocked
      ns.Print(db.hudLocked and TR"Mini Fenster gesperrt" or TR"Mini Fenster verschiebbar")
    end
  end
  hud:SetScript("OnDragStart", DragStart)
  hud:SetScript("OnDragStop", DragStop)
  hud:SetScript("OnMouseUp", MouseUp)
  -- die Tooltip Flaechen (Kopf, Farbstreifen, Fusszeile) lassen das Verschieben und Sperren durch
  for _, tf in ipairs({ hud.headTip, hud.stripeTip, hud.footTip, hud.foot2Tip }) do
    tf:RegisterForDrag("LeftButton")
    tf:SetScript("OnDragStart", DragStart)
    tf:SetScript("OnDragStop", DragStop)
    tf:SetScript("OnMouseUp", MouseUp)
  end
  hud:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TR"Keine Zeit Leveling Guide")
    -- alles auf einen Blick: naechste Schritte, Mitnehmen, Gruppe, wartende Hinweise
    local opt = ns.db.optMode and ns.db.opt
    if opt and opt.steps and ns.OptStepText then
      local i0 = opt.idx or 1
      for k = i0 + 1, math.min(#opt.steps, i0 + 3) do
        local t = ns.OptStepText(opt.steps[k]):gsub("\n.*", "")
        GameTooltip:AddLine((TR"Danach %d: %s"):format(k - i0, t), 0.8, 0.8, 0.8, true)
      end
    end
    local inf = ns.HudInfo and ns.HudInfo() or {}
    if inf.along and #inf.along > 0 then GameTooltip:AddLine(TR"Mitnehmen: " .. table.concat(inf.along, ", "), 1, 0.6, 0.2, true) end
    local gl = ns.GroupLines and ns.GroupLines(inf.qids, 8) or {}
    for _, l in ipairs(gl) do GameTooltip:AddLine(l, 1, 1, 1) end
    if ns.svcHint and ns.svcHint ~= hud.curHint then GameTooltip:AddLine(TR"Wartet: " .. ns.svcHint.text, 0.3, 0.8, 1, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(TR"Ziehen: verschieben, Rechtsklick: sperren", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  hud:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local function Update()
    if not hud:IsShown() then return end
    if hud.ext and hud.ext:IsShown() and hud.ShowMenu then
      local sig = tostring(ns.ProfileOf and ns.ProfileOf(ns.db.opt)) .. "|" .. tostring(ns.ProfileExtraName and ns.ProfileExtraName()) .. "|" .. tostring(IsInGroup and IsInGroup())
        .. "|" .. tostring(ns.navi and (ns.navi.hidden and "aus" or "an") or "-")
      if sig ~= hud.menuSig then hud.menuSig = sig; hud.ShowMenu() end
    end
    local small = (ns.db.hudSize == "small")
    -- Navi aktiv (17.5): das Mini Fenster zeigt den Navi Abschnitt statt dem Routen Schritt
    local i = (not ns.db.paused) and ((ns.navi and ns.NaviHudInfo and ns.NaviHudInfo()) or (ns.HudInfo and ns.HudInfo())) or {}
    -- 1.3.1a (P119): im Flug "Flug nach X, noch m:ss" und der Schritt danach
    if not ns.db.paused and ns.UwHud then local okU, iu = pcall(ns.UwHud, i); if okU and iu then i = iu end end
    if ns.db.paused then
      i = { zone = i.zone, name = TR"Keine Zeit Leveling Guide pausiert", kind = TR"Pause", col = { 0.6, 0.6, 0.6 },
        progress = TR"Nichts wird gerechnet. Weiter: Menü, Weitermachen" }
    end
    local s = ns.Stats and ns.Stats() or {}
    hud.zone:SetText(i.zone or s.zone or "?")
    -- langer Zonen Name: kurz "Zone, 12/57", damit nichts abgeschnitten wird
    if i.zoneIdx and i.zoneTotal and not i.back then
      local fw, sw = hud.zone:GetWidth() or 0, hud.zone:GetStringWidth() or 0
      if fw > 20 and sw > fw then hud.zone:SetText(("%s, %d/%d"):format(i.zoneName or "?", i.zoneIdx, i.zoneTotal)) end
    end
    -- zweite Zeile: danach die naechste Zone (sonst nichts, dann ruecken die Zeilen hoch)
    local nxt = (not ns.db.paused and not i.back and i.nextZone) and ((TR"danach %s"):format(i.nextZone)) or nil
    hud.step:SetText(nxt or "")
    hud.step:SetShown(nxt ~= nil)
    local hd = nxt and 11 or 0
    hud.zbar:ClearAllPoints(); hud.zbar:SetPoint("TOPLEFT", 10, -24 - hd); hud.zbar:SetPoint("TOPRIGHT", -8, -24 - hd)
    hud.kind:ClearAllPoints(); hud.kind:SetPoint("TOPLEFT", 10, -31 - hd)
    hud.target:ClearAllPoints(); hud.target:SetPoint("TOPLEFT", 10, -44 - hd)
    hud.dist:ClearAllPoints(); hud.dist:SetPoint("TOPRIGHT", -8, -31 - hd)
    hud.headTip:SetHeight(26 + hd)
    if i.zoneTotal and i.zoneTotal > 0 then hud.zbar:SetValue((i.zoneIdx - 1) / i.zoneTotal)
    else hud.zbar:SetValue(i.total and i.total > 0 and (i.done / i.total) or 0) end
    local c = i.col or { 0.6, 0.6, 0.6 }
    hud.stripe:SetColorTexture(c[1], c[2], c[3], 1)
    if i.finished then
      hud.kind:SetText(TR"|cff40ff40Zone fertig|r")
      hud.target:SetText("")
      hud.dist:SetText("")
    elseif i.name then
      hud.kind:SetText((TR"|cff%02x%02x%02x%s|r"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), (i.kind or ""):upper()))
      -- 1.1 (P40): jetzige Quest heller und dezent nach Art gefaerbt
      hud.target:SetText(i.tint and ("|cff" .. i.tint .. tostring(i.name) .. "|r") or i.name)
      hud.dist:SetText(i.dist and (TR"%d yd  %s"):format(i.dist, i.time) or "")
    else
      hud.kind:SetText("")
      hud.target:SetText(TR"Keine Route hier")
      hud.dist:SetText("")
    end
    local extra = {}
    -- 1.2a (P44): Hinweis Schritt oben mit Knopf Ueberspringen
    local hintTxt = (not ns.db.paused) and ns.OptHintStep and ns.OptHintStep()
    if hud.bHint then
      if hintTxt then
        hud.bHint:ClearAllPoints(); hud.bHint:SetPoint("TOPRIGHT", hud, "TOPRIGHT", -8, -44 - hd); hud.bHint:Show()
      else hud.bHint:Hide() end
    end
    if hintTxt then table.insert(extra, "|cffffd100" .. hintTxt .. "|r") end
    -- 1.3s (P100): Abfahrt von Zeppelin oder Schiff schon vorher zeigen (hoechstens 1 Quest Schritt davor)
    local dpTxt = (not ns.db.paused) and ns.DepartPreview and ns.DepartPreview()
    if dpTxt then table.insert(extra, "|cff66ccff" .. dpTxt .. "|r") end
    -- wichtige Hinweise zuerst und gut sichtbar
    -- Hinweis Fenster an: Warnungen, Hinweise, Neu und Ueberspringen stehen dort als eigene Karten
    local nw = ns.NoticeOn and ns.NoticeOn()
    if i.warn and not nw then table.insert(extra, "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14:14|t |cffff5050" .. i.warn .. "|r") end
    for _, l in ipairs(i.objs or {}) do table.insert(extra, "   " .. l) end
    -- 1.1 (P41): Hoehe zum Ziel, nur wo es Hoehen Daten gibt
    local hh = (not i.navi) and ns.ZielHoehe and ns.ZielHoehe()
    if hh and not small then table.insert(extra, "|cffc8e6ff" .. hh .. "|r") end
    if i.progress then table.insert(extra, "|cffff66cc" .. i.progress .. "|r") end
    if i.along and #i.along > 0 and not small then
      local a2 = {}
      for k = 1, math.min(2, #i.along) do a2[k] = i.along[k] end
      local more = #i.along > 2 and ("  |cff9d9d9d+%d|r"):format(#i.along - 2) or ""
      table.insert(extra, "|TInterface\\Icons\\Ability_DualWield:14:14|t |cffff9030Mitnehmen:|r |cffffffff" .. table.concat(a2, ", ") .. "|r" .. more)
    end
    -- 20.1b: Route rechnet noch weiter (erster Abschnitt laeuft schon), kleiner Hinweis
    if i.planNote and not small then table.insert(extra, "|cff9d9d9d" .. i.planNote .. "|r") end
    -- 20.1b (P10, Sascha 13:18): Danach kommt NACH dem Fortschritt vom jetzigen Ziel (vorher stand Danach ganz oben
    -- und die Zaehler wie 1/7 rutschten unter die naechsten Schritte)
    local base = #extra + 1
    -- Danach: der naechste Schritt, grau
    if not small and not i.navi and ns.db.optMode and ns.db.opt and ns.db.opt.steps and ns.OptStepText then
      local o = ns.db.opt
      local nx = o.steps[(o.idx or 1) + 1]
      if nx then
        -- Quests vom jetzigen Schritt stehen oben schon: beim Abgeben nur der NPC, gleiche Ziele gar nicht nochmal
        local cur = o.steps[o.idx or 1]
        local here = {}
        for _, a in ipairs(cur and cur.acts or {}) do if a.qid then here[a.qid] = true end end
        local parts = {}
        for _, a in ipairs(nx.acts or {}) do
          local t
          if a.qid and here[a.qid] and a.k == "T" then
            t = (TR"Abgeben bei %s"):format(ns.NpcName and ns.NpcName(a.npc, a.who) or a.who or "?")
          elseif a.qid and here[a.qid] and a.k == "O" then
            t = nil
          else
            t = ns.OptStepText({ acts = { a }, t = nx.t })   -- 1.3zu (P123): Abfahrt bei Ankunft
          end
          if t then
            t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n.*", "")
            local dup = false
            for _, p2 in ipairs(parts) do if p2 == t then dup = true end end
            if not dup then parts[#parts + 1] = t end
          end
        end
        if #parts > 0 then
          -- ganz zeigen (die Zeile bricht um), bei vielen Teilen nur die ersten zwei und die Anzahl
          local t = parts[1] .. (parts[2] and (", " .. parts[2]) or "") .. (#parts > 2 and ("  +" .. (#parts - 2)) or "")
          table.insert(extra, base, TR"|cff9d9d9dDanach: " .. t .. "|r")
          -- 19.32 (Saschas Runde 1 Punkt 5): mehr Schritte zeigen (Einstellung 1, 3, 5 oder 8), je eine kurze Zeile
          local nShow = ns.HudSteps()
          local pos = base + 1
          for k = 2, math.min(nShow, 8) do
            local st2 = o.steps[(o.idx or 1) + k]
            if not st2 then break end
            local t2 = ns.OptStepText(st2):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n.*", "")
            if #t2 > 70 then t2 = t2:sub(1, 68):gsub("[\192-\255][\128-\191]*$", "") .. ".." end
            table.insert(extra, pos, ("|cff7f7f7f%d. %s|r"):format(k, t2))
            pos = pos + 1
          end
        end
      end
    end
    -- 1.3zw (P123 Zusatz, S 23:41): eigener Block "Abfahrten" unten
    if not small and not ns.db.paused and ns.AbfahrtLines then
      local okA, al = pcall(ns.AbfahrtLines)
      if okA and al and #al > 0 then
        table.insert(extra, "|cff66ccff" .. TR"Abfahrten" .. "|r")
        for _, l in ipairs(al) do table.insert(extra, "   |cffbbbbbb" .. l .. "|r") end
      end
    end
    -- 20.3z (S Wunsch 16:52, P11): beim Rechnen oben im Mini Fenster eine Sanduhr mit Stand, damit man sieht, dass etwas laeuft
    if (ns.OptBusy and ns.OptBusy()) or ns.planBuilding then
      local pt = ns.planBuilding and ns.planProgress or nil
      -- 1.1 (P38): Stand in Prozent dazu (Rechnung laeuft in Stuecken ueber viele Bilder)
      local pc = (ns.OptBusy and ns.OptBusy() and ns.optPct) and ("  " .. ns.optPct .. " %") or ""
      table.insert(extra, 1, "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12:12|t |cffffd100" .. (pt or TR"Route wird gerechnet ...") .. pc .. "|r")
    end
    -- 20.4a: kurzer Hinweis, wenn die Nach 60 Route im Hintergrund fertig gerechnet ist
    if ns.restDoneMsg and (GetTime() < ns.restDoneMsg.t) and not ((ns.OptBusy and ns.OptBusy()) or ns.planBuilding) then
      table.insert(extra, 1, "|cff40ff40" .. ns.restDoneMsg.text .. "|r")
    end
    local fl = ns.FarmHudLine and ns.FarmHudLine()
    if fl then table.insert(extra, "|cffffd100" .. fl .. "|r") end
    local pl = ns.ProfHudLine and ns.ProfHudLine()
    if pl then table.insert(extra, "|cff66ff99" .. pl .. "|r") end
    local gt = ns.GoldTargetLine and ns.GoldTargetLine()
    if gt then table.insert(extra, "|cffffd100" .. gt .. "|r") end
    if small then while #extra > 3 do table.remove(extra) end end
    hud.extra:SetText(table.concat(extra, "\n"))
    if hud.bPause then
      local tx = (ns.db and ns.db.paused) and TR"Weitermachen" or TR"Pause"
      if hud.bPause.lbl ~= tx then hud.bPause.lbl = tx; hud.bPause:SetText(tx) end
    end
    local extraH = (#extra > 0) and (hud.extra:GetStringHeight() + 3) or 0
    local function Place(f, y)
      f:ClearAllPoints()
      f:SetPoint("TOPLEFT", hud.target, "BOTTOMLEFT", 0, -6 - y)
      f:SetPoint("RIGHT", hud, "RIGHT", -8, 0)
    end
    -- Box so hoch wie ihr Text (eine oder zwei Zeilen)
    local function Fit(f)
      local h = f.text and f.text:GetStringHeight() or 0
      local bh = math.max(20, math.floor(h + 9))
      f:SetHeight(bh)
      return bh + 6
    end
    -- zweite Zeile beim Ziel: alles darunter rutscht mit (Place haengt am Ziel), das HUD wird hoeher
    local th = hud.target:GetStringHeight() or 0
    local tExtra = (th > 18 and th < 90) and math.floor(th - 13) or 0
    local used = extraH
    -- neue Funktion
    local pend = ns.unlockPending and ns.unlockPending[1]
    if pend and not small and not nw then
      Place(hud.hint, used)
      hud.hint.text:SetText((TR"Neu: %s, Klick für die Erklärung"):format(ns.UnlockName(pend)))
      hud.hint:Show()
      used = used + Fit(hud.hint)
    else
      hud.hint:Hide()
    end
    -- Ueberspringen nur, wenn der naechste Punkt zu hoch ist
    if i.skip and not small and not nw then
      hud.skip.tip = i.skip.text
      Place(hud.skip, used)
      hud.skip.text:SetText(i.skip.zone and TR"|cffff9030Zu hoch:|r weiter nach " .. ns.ZoneName(i.skip.zone)
        or (TR"|cffff9030Zu hoch:|r %d Punkte überspringen"):format(i.skip.count))
      hud.skip:Show()
      used = used + 26
    else
      hud.skip:Hide()
    end
    -- ein Hinweis, der wichtigste (Gruppe, Ruhestein, Taschen, Lehrer, Questlog, Buecher ...)
    local sh = not nw and (ns.TopHint and ns.TopHint() or ns.svcHint) or nil
    hud.curHint = sh
    if not nw and (ns.serviceTarget or sh) then
      Place(hud.svc, used)
      if ns.serviceTarget and ns.serviceTarget.kind == "navi" then
        hud.svc.text:SetText(TR"|cff4dccffNavi aktiv|r  |cff9d9d9d(Klick: ausblenden, zurück zur Route)|r")
      elseif ns.serviceTarget then
        hud.svc.text:SetText(TR"|cff4dccffZiel:|r " .. (ns.serviceTarget.name or "?") .. TR"  |cff9d9d9d(Klick: zurück)|r")
      else
        hud.svc.text:SetText("|cff4dccff>|r " .. sh.text)
      end
      hud.svcX:SetShown(not ns.serviceTarget and not small)
      hud.svc:Show()
      used = used + Fit(hud.svc)
    else
      hud.svc:Hide()
    end
    -- Gruppe
    local gl = (not small) and ns.GroupLines and ns.GroupLines(i.qids, 4) or {}
    if #gl > 0 or (not small and ns.groupWait and #ns.groupWait > 0) then
      if ns.groupWait and #ns.groupWait > 0 then
        table.insert(gl, 1, TR"|cffff9030Warte auf:|r " .. table.concat(ns.groupWait, ", ") .. TR" |cff9d9d9d(Gruppe bleibt zusammen)|r")
      elseif i.kind == TR"Quests abgeben" and ns.GroupNotDone then
        local wait = {}
        for _, qid in ipairs(i.qids or {}) do
          for _, who in ipairs(ns.GroupNotDone(qid)) do wait[who] = true end
        end
        local names = {}
        for who in pairs(wait) do table.insert(names, who) end
        if #names > 0 then table.insert(gl, 1, TR"|cffff9030Warte auf:|r " .. table.concat(names, ", ")) end
      end
      Place(hud.group, used)
      hud.group:SetText(table.concat(gl, "\n"))
      hud.group:Show()
      used = used + hud.group:GetStringHeight() + 6
    else
      hud.group:SetText("")
      hud.group:Hide()
    end
    -- unten: Knoepfe Zurueck, Weiter, Menue immer; XP und Tempo nur im normalen Mini Fenster
    hud.xbar:SetShown(not small); hud.foot:SetShown(not small); hud.foot2:SetShown(not small); hud.btns:Show()
    if small then
      hud:SetHeight(58 + hd + tExtra + used + 30)
      return
    end
    hud.xbar:ClearAllPoints()
    hud.xbar:SetPoint("BOTTOMLEFT", 10, 44); hud.xbar:SetPoint("BOTTOMRIGHT", -8, 44)
    hud.foot:ClearAllPoints(); hud.foot:SetPoint("BOTTOMLEFT", 10, 31)
    hud.foot2:ClearAllPoints(); hud.foot2:SetPoint("BOTTOMRIGHT", -9, 31)
    hud.xpend:Hide(); hud.xbar.pend = nil
    if s.xpFrac then
      hud.xbar:SetValue(s.xpFrac)
      hud.xtext:SetText((TR"Level %d  %d%%"):format(s.level, math.floor(s.xpFrac * 100)))
      if s.pendXP and s.pendLevel then
        local to = (s.pendLevel > s.level) and 1 or math.min(1, s.pendFrac or 0)
        local w = hud.xbar:GetWidth() or 0
        if w > 0 and to > s.xpFrac then
          hud.xpend:SetWidth(math.max(1, w * to))
          hud.xpend:Show()
        end
        local pct = math.floor((s.pendFrac or 0) * 100)
        hud.xbar.pend = { xp = s.pendXP, n = s.qDone or 0, lv = s.pendLevel, pct = pct }
        -- 1.3x (P108): wie frueher "Level 29  55 % + 40 % Abgabe", reicht es fuer ein Level: "+ Abgabe > Level 30 12 %"
        if s.pendLevel > s.level then
          hud.xtext:SetText((TR"Level %d  %d%%  |cffe0a0e0+ Abgabe > %d  %d%%|r"):format(s.level, math.floor(s.xpFrac * 100), s.pendLevel, pct))
        else
          local add = math.max(0, pct - math.floor(s.xpFrac * 100))
          hud.xtext:SetText((TR"Level %d  %d%%  |cffe0a0e0+ %d%% Abgabe|r"):format(s.level, math.floor(s.xpFrac * 100), add))
        end
      end
      -- 1.1 (P56): mit offenen Abgaben gerechnet, reicht die Abgabe schon: "Lvl 16 nach Abgabe"
      if s.levelAfterTurnIn then hud.xright:SetText((TR"Lvl %d nach Abgabe"):format(s.level + 1))
      else hud.xright:SetText(s.nextLevel and (TR"%s bis Lvl %d"):format(s.nextLevelText or s.fmt(s.nextLevel), s.level + 1) or "") end
    else
      hud.xbar:SetValue(0)
      hud.xtext:SetText((TR"Level %d"):format(s.level or 0))
      hud.xright:SetText("")
    end
    hud.foot:SetText(s.xph and s.xph > 0 and (s.num(s.xph) .. TR" XP pro Stunde") or TR"XP pro Stunde wird gemessen")
    -- klarer als "1 fertig": so viele Quests im Log sind fertig zum Abgeben; dahinter dein Lauftempo
    -- (beides zusammen war zu breit fuer die Zeile: dann nur "zum Abgeben", das Tempo ist dann weniger wichtig)
    if s.qDone and s.qDone > 0 then
      hud.foot2:SetText(s.qDone == 1 and TR"|cff40ff401 Quest fertig zum Abgeben|r" or (TR"|cff40ff40%d Quests fertig zum Abgeben|r"):format(s.qDone))
    else
      hud.foot2:SetText((TR"Lauftempo %d%%"):format(s.speedPct or 100))
    end
    -- beide Texte zu breit fuer die Zeile (zb Deutsch mit "wird gemessen"): links kurz
    do
      local W = hud:GetWidth() or 0
      local fw, f2 = hud.foot:GetStringWidth() or 0, hud.foot2:GetStringWidth() or 0
      if W > 0 and 10 + fw > (W - 9) - f2 - 4 then
        hud.foot:SetText(s.xph and s.xph > 0 and (s.num(s.xph) .. TR" XP/Std") or TR"XP/Std: misst")
      end
    end
    hud:SetHeight(58 + hd + tExtra + used + 66)
  end
  hud.Update = Update
  -- erste Erklaerung, sobald die Einrichtung fertig ist und das Mini Fenster da ist
  function hud.Coach()
    if not ns.CoachLater or not ns.db or not ns.db.setupDone then return end
    if ForeverWegweiserSetup and ForeverWegweiserSetup:IsShown() then return end
    ns.CoachLater("hud", function()
      return {
        { target = hud, title = TR"Mini Fenster", text = TR"Sagt dir, was jetzt zu tun ist und wie weit es ist. Ziehen verschiebt es, Rechtsklick sperrt es." },
        { target = hud.btnList[1], side = "BOTTOM", title = TR"Zurück", text = TR"Zeigt den Schritt davor nochmal. Mit Weiter kommst du zurück zum aktuellen Schritt." },
        { target = hud.btnList[2], side = "BOTTOM", title = TR"Weiter", text = TR"Hakt den Schritt ab, der Pfeil zeigt zum nächsten. Meist merkt das Addon das von selbst." },
        { target = hud.bMenu, side = "BOTTOM", title = TR"Menü", text = TR"Ziel wechseln, Händler, Feierabend, Meine Route planen und das grosse Fenster." },
        { target = hud.xbar, side = "BOTTOM", title = TR"XP Balken", text = TR"Der helle Teil zeigt, wo du nach dem Abgeben bist. Maus drauf zeigt die Zahlen." },
        { target = _G.TaurenRouteArrow, side = "BOTTOM", title = TR"Pfeil", text = TR"Zeigt zum nächsten Ziel, grün geradeaus, rot dahinter. Kreuz: gerade kein Weg. Sanduhr: wird gerechnet." },
      }
    end, 2)
  end
  hud:HookScript("OnShow", function() hud.Coach() end)
  ns.HudCoach = function() if hud:IsShown() then hud.Coach() end end
  C_Timer.After(6, function() if hud:IsShown() then hud.Coach() end end)
  ns.RefreshHud = function() Update(); if hud.ShowMenu then hud.ShowMenu() end; if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end end
  -- 1.3x (P108, S 03:41): auch in der Pause, damit XP Balken, Level Prozent, XP pro Stunde, Zeit bis Level und Lauftempo
  -- aktuell bleiben. In der Pause liest Update keine Route (siehe unten), nur die Werte vom Charakter
  ns.Ticker(1, function() Update(); if not ns.db.paused and ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end end, false, true)
  hud.ShowMenu()

  if db.hudSize == "arrow" then db.hudSize = "small" end
  if db.hud ~= false and not db.quiet then hud:Show(); Update() else hud:Hide() end
  C_Timer.After(0, function() if ns.BuildTargetButton then ns.BuildTargetButton() end end)
end
-- 20.3k: Mini Fenster mit ungeskalierten Schriften bauen, das ganze Fenster folgt dem Schrift Faktor (SetScale)
local function BuildHud() return ns.WithPlainFont(BuildHud0) end
local function HudScaleV() return math.max(ns.HUD_MIN, math.min(ns.HUD_MAX, (ns.db and ns.db.hudScale) or 1)) * ((ns.FontScale and ns.FontScale()) or 1) end
function ns.HudRescale()
  if not hud then return end
  hud:SetScale(HudScaleV())
  if hud.PlaceExt then pcall(hud.PlaceExt) end
  if ns.NoticeUpdate then pcall(ns.NoticeUpdate) end
  if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end
end

------------------------------------------------------------
-- Ziel anvisieren: Klick auf das Symbol links vom Pfeil visiert den Mob oder NPC an, den die Route gerade sucht.
-- Anvisieren geht nur ueber einen geschuetzten Knopf, darum ein eigener Knopf an UIParent,
-- der nur ausserhalb vom Kampf verschoben und umgestellt wird. Taste belegbar unter Tastaturbelegung.
------------------------------------------------------------
local function ValidName(n) return type(n) == "string" and n ~= "" and n ~= "?" and n end

-- Namen so, wie das Spiel sie zeigt: Questie hat manche Namen nur auf Englisch oder halb uebersetzt.
-- Gelernt wird ueber die NPC Nummer, sobald du den NPC anschaust, anvisierst oder mit ihm sprichst.
local function NpcFromGUID(g)
  if type(g) ~= "string" then return end
  local t, _, _, _, _, id = strsplit("-", g)
  if t == "Creature" then return tonumber(id) end
end
local function LearnName(unit)
  if not (UnitExists and ns.Api.U(UnitExists, unit)) or (UnitIsPlayer and ns.Api.U(UnitIsPlayer, unit)) then return end
  local g = UnitGUID(unit)
  if ns.Plain then g = ns.Plain(g) end
  local id = NpcFromGUID(g)
  local n = UnitName(unit)
  if ns.Plain then n = ns.Plain(n) end
  if id and type(n) == "string" and n ~= "" and ns.db then
    local t = ns.db.npcName or {}
    ns.db.npcName = t
    if t[id] == n then return end
    -- nur merken, was Questie anders nennt (sonst wachsen die gespeicherten Daten mit jedem NPC)
    local QDB = ns.QDBAccess and ns.QDBAccess()
    if QDB and QDB.QueryNPCSingle then
      local ok, qn = pcall(QDB.QueryNPCSingle, id, "name")
      if ok and qn == n then t[id] = nil; return end
    end
    if not ns.npcNameN then ns.npcNameN = 0; for _ in pairs(t) do ns.npcNameN = ns.npcNameN + 1 end end
    if not t[id] then
      if ns.npcNameN >= 4000 then return end
      ns.npcNameN = ns.npcNameN + 1
    end
    t[id] = n
  end
end
local nf = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "GOSSIP_SHOW", "QUEST_DETAIL",
  "QUEST_GREETING", "QUEST_PROGRESS", "QUEST_COMPLETE", "MERCHANT_SHOW", "TRAINER_SHOW", "TAXIMAP_OPENED" }) do ns.RegEv(nf, e) end
nf:SetScript("OnEvent", function(_, e, arg)
  local unit = (e == "PLAYER_TARGET_CHANGED" and "target") or (e == "UPDATE_MOUSEOVER_UNIT" and "mouseover") or (e == "NAME_PLATE_UNIT_ADDED" and arg) or "npc"
  if unit then pcall(LearnName, unit) end
end)
ns.LearnNpcName = function(unit) pcall(LearnName, unit) end
function ns.NpcName(id, fallback)
  local l = id and ns.db and ns.db.npcName and ns.db.npcName[id]
  return l or fallback
end

local function TargetInfo()
  local db = ns.db
  -- zeigt der Pfeil auf ein Service Ziel (Haendler, Lehrer, Gasthaus): diesen NPC
  local src = ns.ArrowSource and ns.ArrowSource()
  if src == "svc" then
    local st = ns.serviceTarget
    if st and (st.kind == "vendor" or st.kind == "quest" or st.kind == "repair") then
      local n = ValidName(st.name); if n then return n, "npc" end
    elseif st and (st.kind == "inn" or st.kind == "trainer") then
      local n = ValidName((st.name or ""):match(": (.+)$")); if n then return n, "npc" end
    end
    return nil
  elseif src ~= "opt" then
    return nil -- Leiche, Gold Stopp, Empfehlung: da gibt es nichts anzuvisieren
  end
  local a = db and db.optMode and ns.OptCurrentAct and ns.OptCurrentAct()
  if a then
    if a.k == "A" or a.k == "T" or a.k == "F" then
      local n = ValidName(ns.NpcName(a.npc, a.who)); if n then return n, "npc" end
    elseif a.k == "R" and a.link == "fly" then
      -- 20.3z3 (S Test 20.3z2 Z4, Flugpunkte Tour "Flug nach ...": Ziel Knopf fehlte): der Flugmeister am Start des Flugs
      if ValidName(a.who) then return a.who, "npc" end
      local opt = db.opt
      local st = opt and opt.steps and opt.steps[opt.idx or 1]
      if st and st.map and ns.KnownFlightMasters then
        local best, bd
        for _, e in ipairs(ns.KnownFlightMasters() or {}) do
          if e.map == st.map and e.x and e.y then
            local d = (e.x - st.x) ^ 2 + (e.y - st.y) ^ 2
            if not bd or d < bd then best, bd = e, d end
          end
        end
        if best and bd < 0.0004 then local n = ValidName(ns.NpcName(best.id, best.name)); if n then return n, "npc" end end
      end
    elseif a.k == "V" or a.k == "B" or a.k == "L" then
      local n = ValidName(ns.NpcName(a.npc, a.quest)); if n then return n, "npc" end
    elseif a.k == "O" then
      -- alle Mobs der offenen Ziele in diesem Schritt (zb Schnauze und Flanke von verschiedenen Ebern)
      local names, seen = {}, {}
      local QDB = ns.QDBAccess and ns.QDBAccess()
      local opt = db.opt
      local st = opt and opt.steps and opt.steps[opt.idx or 1]
      for _, b in ipairs(st and st.acts or { a }) do
        local done = ns.OptActDone and ns.OptActDone(b)
        if b.k == "O" and not done and type(b.npcs) == "table" and QDB and QDB.QueryNPCSingle then
          for _, id in ipairs(b.npcs) do
            local ok, n = pcall(QDB.QueryNPCSingle, id, "name")
            n = ns.NpcName(id, ok and n or nil)
            if ValidName(n) and not seen[n] and #names < 4 then seen[n] = true; names[#names + 1] = n end
          end
        end
      end
      if #names > 0 then return names[1], "mob", names end
      -- "Item (von Mob)": das Wort kommt uebersetzt (TR" (von "), Muster daraus bauen
      local vw = (TR" (von "):gsub("^%s*%(", ""):gsub("%p", "%%%0")
      local von = type(a.obj) == "string" and (a.obj:match("%(" .. vw .. "(.-)%)") or a.obj:match("%(von (.-)%)"))
      if ValidName(von) and a.npcs then return von, "mob" end
    elseif a.k == "G" and (a.mob or (ValidName(a.obj) and a.obj ~= TR"Mobs")) then
      local n = ValidName(ns.NpcName(a.mob, a.obj and (a.obj:match("^([^,]+)"))))
      if n and n ~= TR"Mobs" then return n, "mob" end
    -- 20.4a4 (Na Vorschlag 20:07, Log z4 ZIELKNOPF): Buch Schritt. Ein Objekt laesst sich nicht anvisieren, der Knopf
    -- bleibt sichtbar und erklaert das im Tooltip (statt zu fehlen)
    elseif a.k == "K" then
      local n = ValidName(a.quest or a.name); if n then return n, "obj" end
    end
  end
  if ns.CurrentGiver and not (db and db.optMode) then
    local ok, n = pcall(ns.CurrentGiver)
    if ok and ValidName(n) then return n, "npc" end
  end
end
ns.TargetInfo = TargetInfo

BINDING_HEADER_FOREVERWEGWEISER = TR"Keine Zeit Leveling Guide"
_G["BINDING_NAME_CLICK ForeverWegweiserTarget:LeftButton"] = TR"Ziel der Route anvisieren"

local tb
-- Der Knopf liegt unsichtbar ueber dem kleinen Symbol links vom Pfeil (zeigt die Art vom Ziel):
-- Klick auf das Symbol visiert den Mob oder NPC an.
local BuildTargetButton
local tbWait
BuildTargetButton = function()
  if tb then return end
  -- sicherer Knopf: im Kampf (zb /reload im Kampf) erst danach bauen, sonst bleibt er tot
  if InCombatLockdown and InCombatLockdown() then
    if not tbWait then
      tbWait = CreateFrame("Frame")
      ns.RegEv(tbWait, "PLAYER_REGEN_ENABLED")
      tbWait:SetScript("OnEvent", function(self) self:UnregisterAllEvents(); BuildTargetButton() end)
    end
    return
  end
  tb = CreateFrame("Button", "ForeverWegweiserTarget", UIParent, "SecureActionButtonTemplate")
  tb:SetSize(28, 28)
  -- ueber dem Pfeil (der faengt sonst zum Verschieben die Maus ab und der Klick kommt nicht an)
  tb:SetFrameStrata("HIGH")
  tb:SetFrameLevel(50)
  tb:RegisterForClicks("AnyUp", "AnyDown")
  tb:SetAttribute("type", "macro")
  local hl = tb:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3)
  hl:SetColorTexture(1, 1, 1, 0.25)
  tb:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(TR"Ziel anvisieren")
    if self.name then
      GameTooltip:AddLine(self.name, 1, 1, 1)
      GameTooltip:AddLine(self.kind == "obj" and TR"Objekt (Buch), nicht anvisierbar: in der Welt mit Rechtsklick benutzen"
        or (self.kind == "mob" and TR"Mob für das Questziel" or TR"NPC, zu dem die Route gerade will"), 0.7, 0.7, 0.7, true)
    end
    GameTooltip:AddLine(TR"Klick visiert ihn an. Eine Taste gibt es unter Tastaturbelegung, Keine Zeit Leveling Guide.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  tb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  tb:Hide()
  local acc = 0
  local f = CreateFrame("Frame")
  f:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 0.25 then return end
    acc = 0
    if InCombatLockdown and InCombatLockdown() then return end
    if tb:GetAttribute("type") ~= "macro" then ns.Api.Mark("Zielknopf"); tb:SetAttribute("type", "macro") end
    local arrow = _G.TaurenRouteArrow
    local icon = arrow and arrow.kind
    -- erst pruefen, ob der Knopf ueberhaupt sichtbar sein kann (TargetInfo fragt Questie ab)
    local can = icon and icon:IsVisible() and ns.db and ns.db.targetBtn ~= false and not ns.db.paused
    local name, kind, list
    if can then name, kind, list = TargetInfo() end
    local show = can and name
    if not show then if tb:IsShown() then ns.Api.Mark("Zielknopf"); tb:Hide() end return end
    local key = list and table.concat(list, "|") or name
    if key ~= tb.key then
      tb.key, tb.name, tb.kind = key, list and table.concat(list, ", ") or name, kind
      -- nur der genaue Name (sonst nimmt das Spiel irgendeinen Mob, der aehnlich heisst)
      -- mehrere Mobs: jeder versucht es, der letzte gefundene bleibt (der erste der Liste zuletzt)
      local lines = { "/cleartarget" }
      local l = list or { name }
      for i = #l, 1, -1 do lines[#lines + 1] = "/targetexact " .. l[i] end
      if kind == "obj" then lines = { "" } end
      ns.Api.Mark("Zielknopf")
      tb:SetAttribute("macrotext", table.concat(lines, "\n"))
    end
    -- ueber das Symbol legen (ohne Anker, damit der Pfeil frei verschiebbar bleibt)
    local cx, cy = icon:GetCenter()
    if cx and cy then
      local k = icon:GetEffectiveScale() / tb:GetEffectiveScale()
      local x, y = cx * k, cy * k
      if tb.px ~= x or tb.py ~= y then
        tb.px, tb.py = x, y
        ns.Api.Mark("Zielknopf")
        tb:ClearAllPoints()
        tb:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
      end
    end
    if not tb:IsShown() then ns.Api.Mark("Zielknopf"); tb:Show() end
  end)
end
ns.BuildTargetButton = BuildTargetButton

------------------------------------------------------------
-- Mini Fenster Groesse "Gruppe": unter dem Mini Fenster eine kurze Zeile pro Mitglied (Name 7/15).
-- Klick auf eine Zeile: der Pfeil zeigt zu ihm (hinlaufen und helfen), nochmal Klick im Mini Fenster: zurueck.
------------------------------------------------------------
local gp
local function GroupPanel0()
  if gp or not hud then return gp end
  -- eigenes Fenster an UIParent (haengt am Mini Fenster, geht mit ihm zu)
  gp = CreateFrame("Frame", "TaurenRouteHUDGroup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  gp:SetFrameStrata(hud:GetFrameStrata() or "MEDIUM")
  gp:SetClampedToScreen(true)
  hud:HookScript("OnHide", function() gp:Hide() end)
  HudSkin(gp, T().IsElv() and "window" or "tooltip")
  gp:SetWidth(hud:GetWidth() or 256)
  gp.head = gp:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  gp.head:SetPoint("TOPLEFT", 10, -7); gp.head:SetPoint("RIGHT", gp, "RIGHT", -8, 0)
  gp.head:SetJustifyH("LEFT"); gp.head:SetWordWrap(false)
  gp.hint = gp:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  gp.hint:SetPoint("TOPLEFT", gp.head, "BOTTOMLEFT", 0, -2); gp.hint:SetPoint("RIGHT", gp, "RIGHT", -8, 0)
  gp.hint:SetJustifyH("LEFT"); gp.hint:SetWordWrap(false)
  gp.rows = {}
  for i = 1, 5 do
    local r = CreateFrame("Button", nil, gp)
    r:SetHeight(16)
    r:SetPoint("TOPLEFT", gp.hint, "BOTTOMLEFT", 0, -3 - (i - 1) * 17)
    r:SetPoint("RIGHT", gp, "RIGHT", -8, 0)
    r.hl = r:CreateTexture(nil, "HIGHLIGHT"); r.hl:SetAllPoints(); r.hl:SetColorTexture(1, 1, 1, 0.08)
    r.name = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    r.name:SetPoint("LEFT", 2, 0); r.name:SetPoint("RIGHT", r, "RIGHT", -96, 0)
    r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
    r.step = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    r.step:SetPoint("RIGHT", r, "RIGHT", -2, 0); r.step:SetJustifyH("RIGHT")
    r.act = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    r.act:SetPoint("RIGHT", r.step, "LEFT", -8, 0); r.act:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function(self)
      local e = self.e
      if not e or e.me then return end
      if e.pos and e.pos[1] then
        ns.serviceTarget = { map = e.pos[1], x = e.pos[2], y = e.pos[3], name = (TR"%s helfen"):format(e.name), kind = "help", who = e.name }
        ns.Print((TR"Pfeil zeigt zu %s. Klick im Mini Fenster auf das Ziel bringt dich zurück auf die Route."):format(e.name))
        if ns.Draw then ns.Draw() end
        if ns.RefreshHud then ns.RefreshHud() end
      else
        ns.Print((TR"Wo %s ist, ist noch nicht bekannt. Das kommt alle 10 Sekunden."):format(e.name))
      end
    end)
    r:SetScript("OnEnter", function(self)
      local e = self.e
      if not e then return end
      ns.TipOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(e.name .. (e.leader and TR" (Leiter)" or ""))
      GameTooltip:AddLine((TR"Schritt %d von %d der Gruppen Route"):format(e.idx or 0, e.total or 0), 1, 1, 1)
      if not e.me then GameTooltip:AddLine(TR"Klick: der Pfeil zeigt zu ihm, damit du hinlaufen und helfen kannst.", 0.5, 0.8, 1, true) end
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    gp.rows[i] = r
  end
  gp:Hide()
  return gp
end
local function GroupPanel() return ns.WithPlainFont(GroupPanel0) end
function ns.HudGroupUpdate()
  local db = ns.db
  if not (hud and db) then return end
  -- Ziel "helfen": der Pfeil geht mit, wenn er weiter laeuft (Ort kommt alle 10 Sekunden)
  local st = ns.serviceTarget
  if st and st.kind == "help" and st.who and ns.group then
    local g = ns.group[st.who]
    if g and g.pos and g.pos[1] then st.map, st.x, st.y = g.pos[1], g.pos[2], g.pos[3] end
  end
  -- Gruppen Ansicht: Standard an (17.3), in beiden Grössen vom Mini Fenster
  if db.hudSize == "group" then db.hudSize = "normal"; db.hudGroup = true end
  local want = db.hudGroup ~= false and hud:IsShown() and IsInGroup and IsInGroup()
  if not want then if gp then gp:Hide() end return end
  GroupPanel()
  local list = ns.GroupProgress and ns.GroupProgress() or {}
  gp:SetScale(hud:GetScale() or 1)
  gp:SetWidth(hud:GetWidth() or 256)
  gp.head:SetText(TR"Gruppe")
  local n = 0
  if #list < 2 then
    gp.hint:SetText(TR"Wartet auf die Gruppen Route vom Leiter")
  else
    gp.hint:SetText(TR"Klick auf einen Namen: hinlaufen und helfen")
    for i, e in ipairs(list) do
      local r = gp.rows[i]
      if not r then break end
      n = i
      r.e = e
      r.name:SetText(e.me and (TR"Du") or e.name)
      if e.me then local a = ACC(); r.name:SetTextColor(a[1], a[2], a[3]) else r.name:SetTextColor(1, 1, 1) end
      r.step:SetText(("%d/%d"):format(e.idx or 0, e.total or 0))
      local mine = list[1] and list[1].idx or 0
      local d = (e.idx or 0) - mine
      -- ein Schritt Unterschied ist normal (die Nachricht kommt kurz spaeter), erst ab 2 Schritten melden
      r.act:SetText(e.me and "" or (d <= -2 and ("|cffff9030" .. TR"hinten" .. "|r") or (d >= 2 and TR"vorne" or "")))
      r:Show()
    end
  end
  for i = n + 1, #gp.rows do gp.rows[i]:Hide(); gp.rows[i].e = nil end
  gp:SetHeight(34 + n * 17 + 6)
  -- unter dem Mini Fenster, steht es ganz unten: darueber
  gp:ClearAllPoints()
  -- unter dem Menue, wenn es offen ist (das haengt auch unter dem Mini Fenster)
  -- 19.8: geht das Menue nach oben auf (Mini Fenster ganz unten), dann ueber das Menue
  local extOn = hud.ext and hud.ext:IsShown()
  local below = (extOn and not hud.extUp) and hud.ext or hud
  local above = (extOn and hud.extUp) and hud.ext or hud
  local b = below:GetBottom() or 200
  if b * (hud:GetScale() or 1) < (gp:GetHeight() + 10) * (gp:GetScale() or 1) then
    gp:SetPoint("BOTTOMLEFT", above, "TOPLEFT", 0, 2)
  else
    gp:SetPoint("TOPLEFT", below, "BOTTOMLEFT", 0, -2)
  end
  gp:Show()
end

-- Groesse aus den Einstellungen anwenden
function ns.ApplyHudSize()
  if not hud then return end
  local db = ns.db
  -- klein, gross und Gruppe (gross mit Zeilen pro Mitglied). "Nur Pfeil" gibt es nicht mehr, alte Daten sind klein
  if db.hudSize == "arrow" then db.hudSize = "small" end
  -- 19.32: mit "Pfeil und Mini Fenster aus" (db.quiet) bleibt es weg, auch nach dem Einloggen
  if db.hud ~= false and not db.quiet then hud:Show(); hud.Update() end
  if hud.ShowMenu then hud.ShowMenu() end
  if ns.HudGroupUpdate then pcall(ns.HudGroupUpdate) end
end

function ns.ToggleHud()
  if not hud then return end
  ns.db.hud = not hud:IsShown()
  if ns.db.hud then ns.db.quiet = nil; hud:Show(); hud.Update() else hud:Hide() end
  if ns.AutoPauseCheck then ns.AutoPauseCheck() end   -- 1.3k (P93)
end

function ns.InitUI()
  BuildHud()
  if ns.InitArrow then ns.InitArrow() end
  if ns.InitQuest then ns.InitQuest() end
  if ns.InitGold then ns.InitGold() end
  if ns.InitMiniRoute then ns.InitMiniRoute() end
  if ns.InitHighlight then ns.InitHighlight() end
  if ns.InitQuestItems then ns.InitQuestItems() end
  if ns.InitCharTab then ns.InitCharTab() end
  BuildPanel()
  -- 1.3k (P94): Reiter im Charakterfenster gibt es nicht mehr, Minimap Knopf mit Menue und /klg
  local _ = BuildMinimapButton
  SLASH_TAURENROUTEUI1 = "/trui"
  SlashCmdList.TAURENROUTEUI = TogglePanel
  SLASH_TAURENROUTEHUD1 = "/trhud"
  SlashCmdList.TAURENROUTEHUD = function() ns.ToggleHud() end
end

------------------------------------------------------------
-- 1.1 (S Log L10.0 "Map Icon oder Reiter fehlt"): Knopf an der Minimap. 1.3k: Klick oeffnet ein Menue (siehe unten),
-- Ziehen: um die Minimap verschieben (Winkel in db.minimapAngle). db.minimapBtn = false: aus
------------------------------------------------------------
do
  local MM_RADIUS_ADD = 10   -- Abstand vom Minimap Rand
  local btn
  local function Place()
    if not (btn and Minimap) then return end
    local a = math.rad((ns.db and ns.db.minimapAngle) or 200)
    local r = (Minimap:GetWidth() or 140) / 2 + MM_RADIUS_ADD
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
  end
  local function Build()
    if btn or not Minimap or (ns.db and ns.db.minimapBtn == false) then return end
    btn = CreateFrame("Button", "KeineZeitLevelingGuideMinimapButton", Minimap)
    btn:SetSize(31, 31)
    btn:SetFrameStrata("MEDIUM")
    btn:SetFrameLevel(8)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture((ns.APATH or "Interface\\AddOns\\KeineZeitLevelingGuide\\") .. "Media\\fw_logo_classic")
    local ring = btn:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53)
    ring:SetPoint("TOPLEFT")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    -- 1.3k (P93, K 13:14): Links und Rechtsklick oeffnen ein kleines eigenes Menue (kein Blizzard Dropdown, kein Taint)
    btn:SetScript("OnClick", function(self) if ns.MinimapMenuToggle then ns.MinimapMenuToggle(self) end end)
    btn:SetScript("OnDragStart", function(self)
      self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        if not (mx and cx) then return end
        local ang = math.deg((math.atan2 or math.atan)(cy / s - my, cx / s - mx))
        if ns.db then ns.db.minimapAngle = ang end
        Place()
      end)
    end)
    btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    btn:SetScript("OnEnter", function(self)
      if ns.TipOwner then ns.TipOwner(self, "ANCHOR_LEFT") else GameTooltip:SetOwner(self, "ANCHOR_LEFT") end
      GameTooltip:AddLine("Keine Zeit Leveling Guide")
      GameTooltip:AddLine(TR"Klick: Menü (grosses Fenster, Pfeil, Mini Fenster, Pause)", 1, 1, 1)
      GameTooltip:AddLine(TR"Ziehen: verschieben", 0.7, 0.7, 0.7)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    Place()
  end
  ns.MinimapButtonBuild = Build

  ----------------------------------------------------------
  -- 1.3k (P93): Menue am Minimap Knopf. Pfeil UND Mini Fenster aus = automatisch Pause (nichts rechnet, kein Navi),
  -- eins davon wieder an = automatisch weiter. Merker db.autoPaused, damit eine Pause von Hand nicht aufgehoben wird
  ----------------------------------------------------------
  local MENU_W, MENU_ROW_H, MENU_PAD = 190, 22, 6
  local MENU_IDLE_S = 8            -- Menue geht von selbst zu, wenn die Maus so lange weg ist
  local menu, rows = nil, {}
  local function ArrowOn() return ns.db and ns.db.arrow ~= false end
  local function HudOn() return ns.db and ns.db.hud ~= false and not ns.db.quiet end
  function ns.AutoPauseCheck()
    local db = ns.db
    if not db or not ns.SetPaused then return end
    local both = not ArrowOn() and not HudOn()
    if both and not db.paused then
      ns.SetPaused(true)
      db.autoPaused = true
    elseif not both and db.paused and db.autoPaused then
      ns.SetPaused(false)
    end
  end
  function ns.MenuSetArrow(on)
    local db = ns.db
    if not db then return end
    db.arrow = on and true or false
    local a = _G.TaurenRouteArrow
    if a then a:SetShown(db.arrow and not db.paused) end
    if ns.RefreshItemBar then ns.RefreshItemBar() end
    ns.AutoPauseCheck()
    if a then a:SetShown(db.arrow and not db.paused) end
  end
  function ns.MenuSetHud(on)
    local db = ns.db
    if not db then return end
    db.hud = on and true or false
    local h = _G.TaurenRouteHUD
    if on then
      db.quiet = nil
      if h then h:Show() end
      if ns.RefreshHud then pcall(ns.RefreshHud) end
    elseif h then h:Hide() end
    ns.AutoPauseCheck()
  end
  local function MenuPause()
    local db = ns.db
    if not db or not ns.SetPaused then return end
    if db.paused then
      ns.SetPaused(false)
      -- Weiter, obwohl Pfeil und Mini Fenster beide aus sind: Mini Fenster kommt zurueck, sonst waere gleich wieder Pause
      if not ArrowOn() and not HudOn() then ns.MenuSetHud(true) end
    else
      ns.SetPaused(true)
    end
  end
  local ITEMS = {
    { label = function() return TR"Grosses Fenster" end, run = function() if ns.ToggleBig then ns.ToggleBig() end end },
    { label = function() return ArrowOn() and TR"Pfeil ausblenden" or TR"Pfeil einblenden" end,
      run = function() ns.MenuSetArrow(not ArrowOn()) end },
    { label = function() return HudOn() and TR"Mini Fenster ausblenden" or TR"Mini Fenster einblenden" end,
      run = function() ns.MenuSetHud(not HudOn()) end },
    { label = function() return (ns.db and ns.db.paused) and TR"Weiter" or TR"Pause" end, run = MenuPause },
  }
  -- 1.3v (P103, S 02:16): ganz unten "Log starten" bzw "Log stoppen", abgesetzt und in eigener Farbe (rot = Log laeuft,
  -- gruen = aus). Gleicher Schalter wie in den Einstellungen (ns.TestLogCmd), nur wenn das Log Addon da ist
  local LOG_ON_COL, LOG_OFF_COL = "|cffff5050", "|cff50ff70"
  local LOG_ITEM = { sep = true,
    label = function()
      local on = ns.TestLogActive and ns.TestLogActive()
      return on and (LOG_ON_COL .. TR"Log stoppen" .. "|r") or (LOG_OFF_COL .. TR"Log starten" .. "|r")
    end,
    run = function()
      local on = ns.TestLogActive and ns.TestLogActive()
      if on and ns.TestLog then ns.TestLog("EINSTELLUNG", "Test Log aus (Minimap Menue)") end
      ns.TestLogCmd(on and "aus" or "an")
      if not on and ns.TestLog then ns.TestLog("EINSTELLUNG", "Test Log an (Minimap Menue)") end
      if ns.RefreshBig then pcall(ns.RefreshBig) end
    end }
  local MENU_SEP_H = 8
  local function MenuLabels()
    for i, r in ipairs(rows) do r.fs:SetText(ITEMS[i].label()) end
  end
  local function BuildMenu()
    if menu then return end
    if ns.TestLogAvailable and ns.TestLogAvailable() and ns.TestLogCmd then ITEMS[#ITEMS + 1] = LOG_ITEM end
    local sepN = 0
    for _, it in ipairs(ITEMS) do if it.sep then sepN = sepN + 1 end end
    menu = CreateFrame("Frame", "KeineZeitLevelingGuideMinimapMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    menu:SetSize(MENU_W, #ITEMS * MENU_ROW_H + 2 * MENU_PAD + sepN * MENU_SEP_H)
    menu:SetFrameStrata("DIALOG")
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    if ns.T and ns.T.Skin then pcall(ns.T.Skin, menu, "inset")
    elseif menu.SetBackdrop then
      menu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
      menu:SetBackdropColor(0, 0, 0, 0.9); menu:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    end
    local yOff = 0
    for i, it in ipairs(ITEMS) do
      if it.sep then
        local line = menu:CreateTexture(nil, "ARTWORK")
        line:SetColorTexture(1, 1, 1, 0.25)
        line:SetSize(MENU_W - 2 * MENU_PAD - 8, 1)
        line:SetPoint("TOPLEFT", MENU_PAD + 4, -MENU_PAD - (i - 1) * MENU_ROW_H - yOff - MENU_SEP_H / 2)
        yOff = yOff + MENU_SEP_H
      end
      local r = CreateFrame("Button", nil, menu)
      r:SetSize(MENU_W - 2 * MENU_PAD, MENU_ROW_H)
      r:SetPoint("TOPLEFT", MENU_PAD, -MENU_PAD - (i - 1) * MENU_ROW_H - yOff)
      local hl = r:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.15)
      r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      r.fs:SetPoint("LEFT", 6, 0)
      r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      r:SetScript("OnClick", function()
        menu:Hide()
        local ok, err = pcall(it.run)
        if not ok and ns.TestLog then ns.TestLog("FEHLER", "Minimap Menue: " .. tostring(err)) end
      end)
      rows[i] = r
    end
    menu.idle = 0
    menu:SetScript("OnUpdate", function(self, el)
      if self:IsMouseOver() or (btn and btn:IsMouseOver()) then self.idle = 0 return end
      self.idle = self.idle + el
      if self.idle > MENU_IDLE_S then self:Hide() end
    end)
    if ns.CloseOnEscape then ns.CloseOnEscape(menu) end
    menu:Hide()
  end
  function ns.MinimapMenuToggle(anchor)
    BuildMenu()
    if menu:IsShown() then menu:Hide() return end
    GameTooltip:Hide()
    MenuLabels()
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor or Minimap, "BOTTOMLEFT", 0, 0)
    menu.idle = 0
    menu:Show()
  end
  -- nach /reload: Pause wie vorher (Core setzt sie beim Laden zurueck und merkt sie in ns.pauseWas), danach Auto Pause
  -- pruefen (Pfeil und Mini Fenster beide aus = Pause, auch nach dem Einloggen)
  local AUTO_PAUSE_DELAY_S = 3
  local pf = CreateFrame("Frame")
  ns.RegEv(pf, "PLAYER_ENTERING_WORLD")
  pf:SetScript("OnEvent", function(self, _, isLogin, isReload)
    self:UnregisterAllEvents()
    C_Timer.After(AUTO_PAUSE_DELAY_S, function()
      local db, was = ns.db, ns.pauseWas
      if not db then return end
      ns.pauseWas = nil
      if isReload and was and was.paused and not db.paused and ns.SetPaused then
        ns.SetPaused(true)
        if was.quiet then db.quiet = true; local h = _G.TaurenRouteHUD; if h then h:Hide() end end
        db.autoPaused = was.auto
      end
      pcall(ns.AutoPauseCheck)
    end)
  end)
  function ns.MinimapButtonShow(on)
    if ns.db then ns.db.minimapBtn = on and true or false end
    if on then Build(); if btn then btn:Show() end elseif btn then btn:Hide() end
  end
  local ef = CreateFrame("Frame")
  ns.RegEv(ef, "PLAYER_LOGIN")
  ef:SetScript("OnEvent", function() C_Timer.After(2, function() pcall(Build) end) end)
end
