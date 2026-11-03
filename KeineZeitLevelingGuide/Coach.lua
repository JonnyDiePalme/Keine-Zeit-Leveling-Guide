local ADDON, ns = ...
local TR = ns.TR

-- Kurze Erklaerung beim ersten Oeffnen eines Fensters: ein Rahmen um den Knopf, daneben ein kleines Fenster
-- mit Text und Weiter. Jede Erklaerung kommt nur einmal. Unter Hilfe kann man alle wieder einschalten.

local box, ring, cur

local function T() return ns.T end

local function Build()
  if box then return end
  local t = T()
  box = CreateFrame("Frame", "ForeverWegweiserCoach", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box:SetFrameStrata("FULLSCREEN_DIALOG")
  box:SetFrameLevel(200)
  box:SetSize(300, 110)
  box:SetClampedToScreen(true)
  box:EnableMouse(true)
  t.Skin(box, "tooltip")
  -- gut sichtbar in beiden Looks (17.3, Wunsch): fast deckender Hintergrund und ein roter Rahmen, der langsam pulsiert
  box.solid = box:CreateTexture(nil, "BACKGROUND", nil, 7)
  box.solid:SetPoint("TOPLEFT", 3, -3); box.solid:SetPoint("BOTTOMRIGHT", -3, 3)
  box.solid:SetColorTexture(0.06, 0.06, 0.07, 0.96)
  box.edge = CreateFrame("Frame", nil, box, BackdropTemplateMixin and "BackdropTemplate" or nil)
  box.edge:SetPoint("TOPLEFT", -3, 3); box.edge:SetPoint("BOTTOMRIGHT", 3, -3)
  box.edge:SetFrameLevel(box:GetFrameLevel() + 1)
  if box.edge.SetBackdrop then box.edge:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 3 }) end
  box.edge:EnableMouse(false)
  local eacc = 0
  box.edge:SetScript("OnUpdate", function(self, e)
    eacc = eacc + (e or 0)
    local a = 0.45 + 0.55 * math.abs(math.sin(eacc * 2.2))
    if self.SetBackdropBorderColor then self:SetBackdropBorderColor(1, 0.2, 0.12, a) end
  end)
  box.logo = t.Logo(box, 16)
  box.logo:SetPoint("TOPLEFT", 10, -9)
  box.title = box:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  box.title:SetPoint("LEFT", box.logo, "RIGHT", 6, 0)
  box.title:SetPoint("RIGHT", box, "RIGHT", -50, 0)
  box.title:SetJustifyH("LEFT")
  box.count = box:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  box.count:SetPoint("TOPRIGHT", -10, -11)
  box.text = box:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  box.text:SetPoint("TOPLEFT", 12, -32)
  box.text:SetWidth(276)
  box.text:SetJustifyH("LEFT")
  box.text:SetSpacing(3)
  box.skip = t.Button(box, TR"Überspringen", 104, 20)
  box.skip:SetPoint("BOTTOMLEFT", 10, 10)
  box.next = t.Button(box, TR"Weiter", 96, 20, true)
  box.next:SetPoint("BOTTOMRIGHT", -10, 10)
  -- X: nur beim Rundgang (beendet ihn, der Stand bleibt gemerkt)
  box.close = CreateFrame("Button", nil, box, "UIPanelCloseButton")
  box.close:SetSize(22, 22)
  box.close:SetPoint("TOPRIGHT", -2, -2)
  if t.SkinClose then t.SkinClose(box.close) end
  box.close:Hide()
  box:Hide()

  ring = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  ring:SetFrameStrata("FULLSCREEN_DIALOG")
  ring:SetFrameLevel(190)
  if ring.SetBackdrop then
    ring:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
  end
  ring:EnableMouse(false)
  ring:Hide()
  local acc = 0
  ring:SetScript("OnUpdate", function(self, e)
    acc = acc + e
    local a = 0.55 + 0.45 * math.abs(math.sin(acc * 3))
    local r, g, b = 1, 0.82, 0
    if t.IsElv() then r, g, b = t.Acc() end
    if self.SetBackdropBorderColor then self:SetBackdropBorderColor(r, g, b, a) end
    -- Fenster zu: Erklaerung weg, kommt beim naechsten Mal wieder (Rundgang: naechster sichtbarer Schritt)
    if cur and cur.target and not cur.target:IsVisible() then
      if cur.tour then if ns.TourCheck then ns.TourCheck() end else ns.CoachHide() end
    end
  end)
end

local function Target(st)
  local tg = st.target
  if type(tg) == "function" then
    local ok, v = pcall(tg)
    tg = ok and v or nil
  end
  if type(tg) == "table" and tg.IsVisible and tg:IsVisible() then return tg end
end

local Show
local function Finish(markSeen)
  if cur and markSeen and ns.db and not cur.tour then
    ns.db.coachSeen = ns.db.coachSeen or {}
    ns.db.coachSeen[cur.key] = true
  end
  cur = nil
  if box then box:Hide(); box.close:Hide() end
  if ring then ring:Hide() end
end
function ns.CoachHide() Finish(false) end

Show = function()
  if not cur then return end
  local st = cur.steps[cur.i]
  local tg = st and Target(st)
  while st and not tg do
    cur.i = cur.i + 1
    st = cur.steps[cur.i]
    tg = st and Target(st)
  end
  -- kein einziger Schritt war zu sehen (Seite gewechselt): nicht als gesehen merken, kommt beim naechsten Mal
  if not st then Finish(cur.shown and true or false); return end
  cur.shown = true
  cur.target = tg
  local n = #cur.steps
  box.title:SetText(st.title or "")
  box.text:SetText(st.text or "")
  box.count:SetText((TR"%d von %d"):format(cur.i, n))
  box.next:SetText(cur.i >= n and TR"Fertig" or TR"Weiter")
  box:SetHeight(math.max(96, (box.text:GetStringHeight() or 30) + 74))
  ring:ClearAllPoints()
  ring:SetPoint("TOPLEFT", tg, "TOPLEFT", -4, 4)
  ring:SetPoint("BOTTOMRIGHT", tg, "BOTTOMRIGHT", 4, -4)
  ring:Show()
  box:ClearAllPoints()
  local side = st.side or "RIGHT"
  if side == "INSIDE" then box:SetPoint("TOPRIGHT", tg, "TOPRIGHT", -16, -16)
  elseif side == "LEFT" then box:SetPoint("RIGHT", tg, "LEFT", -14, 0)
  elseif side == "TOP" then box:SetPoint("BOTTOM", tg, "TOP", 0, 14)
  elseif side == "BOTTOM" then box:SetPoint("TOP", tg, "BOTTOM", 0, -14)
  else box:SetPoint("LEFT", tg, "RIGHT", 14, 0) end
  box:Show()
end

-- key: Name der Erklaerung, steps: { { target = Frame oder Funktion, title = "", text = "", side = "RIGHT" }, ... }
function ns.Coach(key, steps, force)
  local db = ns.db
  if not db or not ns.T or not steps or #steps == 0 then return end
  db.coachSeen = db.coachSeen or {}
  if not force and (db.coachSeen[key] or db.coachOff) then return end
  if cur and cur.key ~= key then return end
  Build()
  -- vom Rundgang zurueck auf die normale Erklaerung
  box.skip:Show(); box.skip:SetText(TR"Überspringen"); box.close:Hide()
  box.count:ClearAllPoints(); box.count:SetPoint("TOPRIGHT", -10, -11)
  cur = { key = key, steps = steps, i = 1 }
  box.skip:SetScript("OnClick", function() Finish(true) end)
  box.next:SetScript("OnClick", function()
    if not cur then return end
    cur.i = cur.i + 1
    if cur.i > #cur.steps then Finish(true) else Show() end
  end)
  Show()
end

-- erst zeigen, wenn das Fenster sicher aufgebaut ist
-- (wird oft jede Sekunde aufgerufen: nur einmal anstossen und nur wenn gerade keine andere Erklaerung laeuft)
local pending = {}
function ns.CoachBusy() return cur ~= nil end
function ns.CoachLater(key, stepsFn, delay)
  if not ns.db then return end
  ns.db.coachSeen = ns.db.coachSeen or {}
  if ns.db.coachSeen[key] or ns.db.coachOff or pending[key] or cur or (ns.TourActive and ns.TourActive()) then return end
  pending[key] = true
  C_Timer.After(delay or 0.4, function()
    pending[key] = nil
    if cur then return end
    local ok, steps = pcall(stepsFn)
    if ok and steps then ns.Coach(key, steps) end
  end)
end

-- Hilfe: alle Erklaerungen wieder einschalten
function ns.CoachReset()
  if not ns.db then return end
  ns.db.coachSeen = {}
  ns.db.coachOff = nil
  ns.Print(TR"Alle Erklärungen sind wieder an. Sie kommen, sobald du das Fenster oder die Karte das nächste Mal öffnest.")
end

------------------------------------------------------------
-- Rundgang: alle Seiten im grossen Fenster nacheinander. Pro Seite zuerst der Reiter (was ist das),
-- dann die Schritte mit Rahmen um die Knoepfe. Weiter: naechster Schritt, Naechster Reiter: Rest der Seite
-- ueberspringen, X: beenden (der Stand bleibt gemerkt, der Knopf heisst dann "Rundgang fortsetzen").
-- Im Modus Gefuehrt nur Seiten, die schon frei sind. ns.TourPage(seite): nur diese Seite (Knopf ? oben rechts).
------------------------------------------------------------
local function U(k) return ns.UnlockInfo and ns.UnlockInfo(k) end
local function Nav(k) return function() return ns.BigNavButton and ns.BigNavButton(k) end end
local function Page() return function() return ns.BigBody and ns.BigBody() end end
local function JP(k, f) return function() local p = ns.BigJPage and ns.BigJPage(k); return p and p[f] end end
local function HowSteps(key, out)
  local u = U(key)
  for i, h in ipairs(u and u.how or {}) do
    out[#out + 1] = { target = Page(), side = "INSIDE", title = (TR"Schritt %d"):format(i), text = h }
  end
  return out
end
local function TourTabs()
  local db = ns.db or {}
  local farm = ns.FarmOn and ns.FarmOn() or false -- 20.4b
  local T = {
    { view = "overview", nav = "overview", name = TR"Übersicht", text = TR"Dein Stand auf einen Blick: Level, XP, die nächsten Ziele und Pause.",
      steps = function() return {
        { target = function() return ns.BigChip and ns.BigChip() end, side = "BOTTOM", title = TR"Tempo und Modus",
          text = TR"Klick: Tempo und Modus wählen. Maus auf einen Eintrag erklärt ihn." },
        { target = JP("start", "pause"), side = "LEFT", title = TR"Pause", text = TR"Hält alles an, nichts wird mehr gerechnet. Nochmal klicken macht weiter." },
        { target = JP("start", "tour"), side = "LEFT", title = TR"Rundgang", text = TR"Dieser Rundgang. Er merkt sich, wo du aufgehört hast." },
        { target = Page(), side = "INSIDE", title = TR"Ziele", text = TR"Unten deine Ziele als Karten, zum Beispiel Dungeons und Bücher. Klick öffnet die Seite dazu." },
      } end },
    { view = "weg", nav = "weg", name = TR"Mein Weg", text = TR"Welche Funktion ab welchem Level kommt. Gelb ist die nächste Stufe.",
      steps = function() return ns.PageCoachSteps and ns.PageCoachSteps("weg") or {} end },
    { view = "perf", nav = "perf", lock = "perf", name = TR"Statistik", text = U("perf") and U("perf").text or "",
      steps = function() return HowSteps("perf", {}) end },
    { view = "opt", nav = "opt", name = TR"Meine Route", text = TR"Alle Schritte der Route, der Zonenplan bis 60 und Planen: neu rechnen, Touren, Stunden Budget, Feierabend.",
      steps = function() return {
        { target = Page(), side = "INSIDE", title = TR"Schritt 1", text = TR"Oben die Reiter Schritte, Zonenplan und Planen." },
        { target = Page(), side = "INSIDE", title = TR"Schritt 2", text = TR"Neu rechnen rechnet die Route ab deinem Standort, zum Beispiel nach einem Umweg." },
      } end },
    { view = "dungeons", nav = "dungeons", lock = "dungeons", name = TR"Dungeons", text = U("dungeons") and U("dungeons").text or "",
      steps = function() return HowSteps("dungeons", {}) end },
    { view = "gear", nav = "gear", lock = "gear", name = TR"Ausrüstung", text = U("gear") and U("gear").text or "",
      steps = function() return HowSteps("gear", {}) end },
    { view = "rep", nav = "rep", lock = "rep", name = TR"Ruf", text = U("rep") and U("rep").text or "",
      steps = function() return HowSteps("rep", ns.PageCoachSteps and ns.PageCoachSteps("rep") or {}) end },
    { view = "books", nav = "books", lock = "books", name = TR"Bücher", text = U("books") and U("books").text or "",
      steps = function() return HowSteps("books", ns.PageCoachSteps and ns.PageCoachSteps("books") or {}) end },
    { view = "set", nav = "set", name = TR"Einstellungen", text = TR"Alles als Fragen mit Ja und Nein. Maus auf die Frage erklärt, was passiert.",
      steps = function() return {
        { target = JP("set", "allBtn"), side = "LEFT", title = TR"Alle Einstellungen", text = TR"Im Modus Geführt stehen zuerst die wichtigsten. Dieser Knopf zeigt alle." },
      } end },
    farm and { view = "berufe", nav = "berufe", lock = "berufe", name = TR"Berufe", text = U("berufe") and U("berufe").text or "",
      steps = function() return HowSteps("berufe", {}) end } or false,
    farm and { view = "farm", nav = "gold", lock = "farm", name = TR"Gold", text = U("farm") and U("farm").text or "",
      steps = function() return HowSteps("farm", ns.PageCoachSteps and ns.PageCoachSteps("farm") or {}) end } or false,
    { view = "help", nav = "help", name = TR"Hilfe", text = TR"Alles zum Nachlesen. Hier startest du auch die Einrichtung und die kurzen Erklärungen nochmal.",
      steps = function() return {} end },
  }
  local out, later, all = {}, {}, {}
  for _, t in ipairs(T) do
    if t then all[#all + 1] = t end
    if t then
      if t.lock and ns.Unlocked and not ns.Unlocked(t.lock) then later[#later + 1] = ("%s (%s)"):format(t.name, (TR"Level %d"):format(ns.UnlockLevel and ns.UnlockLevel(t.lock) or 0))
      else out[#out + 1] = t end
    end
  end
  return out, later, all
end

local tour
local function TourSave()
  if not (tour and ns.db and not tour.single) then return end
  ns.db.tourAt = { tab = tour.list[tour.ti] and tour.list[tour.ti].view, si = tour.si }
end
local function TourEnd(done)
  if not tour then return end
  local single, later = tour.single, tour.later
  if done and not single and ns.db then ns.db.tourAt = nil; ns.db.tourDone = true
  elseif not single then TourSave() end
  tour = nil
  Finish(false)
  if done and not single then
    Build()
    cur = { key = "tour_end", steps = { {} }, i = 1, tour = false }
    box.title:SetText(TR"Rundgang fertig")
    box.text:SetText(#later > 0 and ((TR"Mit dem Level kommen noch: %s. Jede neue Seite erklärt sich beim ersten Öffnen."):format(table.concat(later, ", ")))
      or TR"Du kennst jetzt alle Seiten. Das ? oben rechts erklärt jede Seite nochmal.")
    box.count:SetText("")
    box.next:SetText(TR"Fertig")
    box.next:SetScript("OnClick", function() Finish(false) end)
    box.skip:Hide()
    box:SetHeight(math.max(96, (box.text:GetStringHeight() or 30) + 74))
    box:ClearAllPoints()
    local big = _G.TaurenRouteBig
    if big and big:IsShown() then box:SetPoint("CENTER", big, "CENTER", 0, 0) else box:SetPoint("CENTER") end
    if ring then ring:Hide() end
    box:Show()
  end
end
local TourShow
local function TourNextTab()
  tour.ti, tour.si, tour.opened = tour.ti + 1, 1, nil
  if tour.single or not tour.list[tour.ti] then TourEnd(true) return end
  TourShow()
end
TourShow = function()
  if not tour then return end
  local tab = tour.list[tour.ti]
  if not tab then TourEnd(true) return end
  local big = _G.TaurenRouteBig
  -- Seite oeffnen (einmal pro Reiter), dann kurz warten, bis sie aufgebaut ist
  if not tour.opened then
    tour.opened = true
    if ns.ShowBig then ns.ShowBig(tab.view) end
    C_Timer.After(0.35, TourShow)
    return
  end
  if not (big and big:IsShown()) then TourEnd(false) return end
  if not tour.steps then
    local okS, list = pcall(tab.steps)
    tour.steps = { { target = tab.pageFirst and Page() or Nav(tab.nav), side = tab.pageFirst and "INSIDE" or "RIGHT", title = tab.name, text = tab.text } }
    -- nur Schritte, die es auf der Seite gerade gibt (sonst stimmt "Schritt 2 von 3" nicht)
    for _, st in ipairs(okS and list or {}) do if Target(st) then tour.steps[#tour.steps + 1] = st end end
  end
  -- naechster sichtbarer Schritt
  local st, tg
  while true do
    st = tour.steps[tour.si]
    if not st then tour.steps = nil; TourNextTab() return end
    tg = Target(st)
    if tg then break end
    tour.si = tour.si + 1
  end
  Build()
  cur = { key = "tour", steps = tour.steps, i = tour.si, tour = true, target = tg, shown = true }
  box.title:SetText(st.title or "")
  box.text:SetText(st.text or "")
  local nt = #tour.list
  box.count:SetText(tour.single and (TR"%d von %d"):format(tour.si, #tour.steps)
    or (TR"Reiter %d von %d, Schritt %d von %d"):format(tour.ti, nt, tour.si, #tour.steps))
  box.count:ClearAllPoints(); box.count:SetPoint("TOPRIGHT", -28, -11)
  box.close:Show()
  box.close:SetScript("OnClick", function() TourEnd(false) end)
  box.skip:Show()
  box.skip:SetText(tour.single and TR"Beenden" or (tour.ti >= nt and TR"Fertig" or TR"Nächster Reiter"))
  box.skip:SetScript("OnClick", function() if tour.single then TourEnd(false) else tour.steps = nil; TourNextTab() end end)
  local last = tour.si >= #tour.steps
  box.next:SetText(last and (tour.single and TR"Fertig" or (tour.ti >= nt and TR"Fertig" or TR"Nächster Reiter")) or TR"Weiter")
  box.next:SetScript("OnClick", function()
    if not tour then return end
    -- 17.9 (Chaos Test): Reiter inzwischen gewechselt, die Schritte sind weg: neu aufbauen statt Lua Fehler
    if not tour.steps then TourShow() return end
    if tour.si >= #tour.steps then tour.steps = nil; TourNextTab() return end
    tour.si = tour.si + 1
    TourSave()
    TourShow()
  end)
  box.text:SetWidth(276)
  box:SetHeight(math.max(96, (box.text:GetStringHeight() or 30) + 74))
  ring:ClearAllPoints()
  ring:SetPoint("TOPLEFT", tg, "TOPLEFT", -4, 4)
  ring:SetPoint("BOTTOMRIGHT", tg, "BOTTOMRIGHT", 4, -4)
  ring:Show()
  box:ClearAllPoints()
  local side = st.side or "RIGHT"
  if side == "INSIDE" then box:SetPoint("TOPRIGHT", tg, "TOPRIGHT", -16, -16)
  elseif side == "LEFT" then box:SetPoint("RIGHT", tg, "LEFT", -14, 0)
  elseif side == "TOP" then box:SetPoint("BOTTOM", tg, "TOP", 0, 14)
  elseif side == "BOTTOM" then box:SetPoint("TOP", tg, "BOTTOM", 0, -14)
  else box:SetPoint("LEFT", tg, "RIGHT", 14, 0) end
  box:Show()
  TourSave()
end
-- Ziel verschwunden (Seite gewechselt, Fenster zu)
function ns.TourCheck()
  if not tour then Finish(false) return end
  local big = _G.TaurenRouteBig
  if not (big and big:IsShown()) then TourEnd(false) return end
  TourShow()
end
-- Knopf auf der Uebersicht: starten oder dort weiter, wo du aufgehoert hast
function ns.TourStart()
  local list, later = TourTabs()
  if #list == 0 then return end
  Finish(false)
  tour = { list = list, later = later, ti = 1, si = 1 }
  local at = ns.db and ns.db.tourAt
  if at and at.tab then
    for i, t in ipairs(list) do if t.view == at.tab then tour.ti = i; tour.si = math.max(1, at.si or 1) end end
  end
  TourShow()
end
-- ? oben rechts: nur die aktuelle Seite
function ns.TourPage(view)
  local list, _, all = TourTabs()
  local alias = { detail = "perf", stats = "perf", statgold = "perf", raids = "dungeons", pvp = "dungeons", route = "opt", plan = "opt", gold = "farm" }
  local v = alias[view] or view
  local pick
  for _, t in ipairs(list) do if t.view == v then pick = t end end
  if not pick then
    -- Seite noch gesperrt (Gefuehrt): was sie macht und ab wann
    for _, t in ipairs(all or {}) do
      if t.view == v then
        local lv = t.lock and ns.UnlockLevel and ns.UnlockLevel(t.lock) or 0
        pick = { view = t.view, nav = t.nav, pageFirst = true, name = t.name, text = (t.text or "") .. "\n\n" .. (TR"Kommt ab Level %d. Im Modus Alles frei ist alles sofort da."):format(lv),
          steps = function() return {} end }
      end
    end
  end
  if not pick then ns.Print(TR"Für diese Seite gibt es noch keinen Rundgang.") return end
  Finish(false)
  tour = { list = { pick }, later = {}, ti = 1, si = 1, single = true, opened = true }
  TourShow()
end
function ns.TourLabel()
  local db = ns.db
  if db and db.tourAt and db.tourAt.tab then return TR"Rundgang fortsetzen" end
  return TR"Rundgang starten"
end
function ns.TourActive() return tour ~= nil end
