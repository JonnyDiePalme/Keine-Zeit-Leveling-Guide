local ADDON, ns = ...
local TR = ns.TR

-- Touren: alle fehlenden Flugpunkte, alles entdecken
-- Kuerzeste Reihenfolge ueber alle Punkte (naechster Nachbar, dann 2-opt),
-- ueber Kontinente mit Schiff und Zeppelin. Laeuft in Haeppchen, damit nichts ruckelt.

local PATH, LONG = 1.2, 2500

local function World(map, x, y)
  if ns.MapWorld then return ns.MapWorld(map, x, y) end
  if not (map and x and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if not ok or not w then return end
  local wx, wy = w:GetXY()
  return cont, wx, wy
end

local busy
local SPEED = 7

-- Reisezeit in Sekunden zwischen zwei Punkten
local function T(a, b)
  if a.cont ~= b.cont then
    local t = ns.TravelBest and ns.TravelBest(a, b, SPEED)
    return t or 1e6
  end
  -- 19.24 (Sascha Teil 1 Punkt 4): Laufweg ueber das Netz wie in der Route
  local d = (ns.WalkYards and ns.WalkYards(a, b)) or math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * PATH
  if d > LONG and ns.TravelBest then
    local t = ns.TravelBest(a, b, SPEED)
    if t and t < d / SPEED then return t end
  end
  return d / SPEED
end

-- Zeitbudget pro Frame (ms), damit nichts ruckelt
local function Budget()
  local t0 = debugprofilestop and debugprofilestop()
  local ms = (InCombatLockdown and InCombatLockdown()) and 3 or 8
  return function(n) if not t0 then return n < 10 end return n < 1 or debugprofilestop() - t0 < ms end
end

-- Zeiten zwischen allen Punkten einmal rechnen (Kontinentwechsel sind teuer zu rechnen)
local function Matrix(pts, done)
  local m, i = {}, 0
  local function Step()
    local n = 0
    local more = Budget()
    while i < #pts and more(n) do
      i = i + 1
      n = n + 1
      m[i] = {}
      for j = 1, #pts do
        if j < i then m[i][j] = m[j][i] elseif j == i then m[i][j] = 0 else m[i][j] = T(pts[i], pts[j]) end
      end
    end
    if i < #pts then C_Timer.After(0, Step); return end
    done(m)
  end
  Step()
end

-- Tour: Punkt 1 ist der Start (Spieler), Ende offen
local function Solve(pts, done)
  Matrix(pts, function(m)
    -- naechster Nachbar, auch in Haeppchen
    local order, used = { 1 }, { [1] = true }
    local TwoOpt
    local function NN()
      local more, k = Budget(), 0
      while #order < #pts and more(k) do
        k = k + 1
        local last, best, bd = order[#order], nil, nil
        for j = 2, #pts do
          if not used[j] and (not bd or m[last][j] < bd) then best, bd = j, m[last][j] end
        end
        used[best] = true
        table.insert(order, best)
      end
      if #order < #pts then C_Timer.After(0, NN); return end
      TwoOpt()
    end
    TwoOpt = function()
    -- 2-opt (offenes Ende), in Haeppchen
    local n = #order
    local improved, rounds, a = true, 0, 1
    local function Cost(i, j) return (order[i] and order[j]) and m[order[i]][order[j]] or 0 end
    local function Step()
      local work = 0
      while a < n - 1 and work < 4000 do
        a = a + 1
        for b = a + 1, n do
          work = work + 1
          -- Kante (a-1,a) und (b,b+1) tauschen gegen (a-1,b) und (a,b+1)
          local before = Cost(a - 1, a) + (b < n and Cost(b, b + 1) or 0)
          local after = Cost(a - 1, b) + (b < n and Cost(a, b + 1) or 0)
          if after + 0.5 < before then
            local i, j = a, b
            while i < j do order[i], order[j] = order[j], order[i]; i = i + 1; j = j - 1 end
            improved = true
          end
        end
      end
      if a < n - 1 then C_Timer.After(0, Step); return end
      rounds = rounds + 1
      if improved and rounds < 8 then improved = false; a = 1; C_Timer.After(0, Step); return end
      local total = 0
      for k = 2, n do total = total + m[order[k - 1]][order[k]] + (pts[order[k]].dur or 0) end
      done(order, total)
    end
    Step()
    end
    NN()
  end)
end

-- Viele Punkte (zb Alles entdecken): erst die Zonen in eine Reihenfolge bringen, dann jede Zone fuer sich.
-- Spart die riesige Tabelle mit allen Zeiten und rechnet in kleinen Stuecken.
local function SolveGrouped(pts, done)
  local groups, byKey = {}, {}
  for i = 2, #pts do
    local p = pts[i]
    local k = (ns.cityParent and ns.cityParent[p.map]) or p.map or 0
    local g = byKey[k]
    if not g then g = { idx = {}, sx = 0, sy = 0, cont = p.cont }; byKey[k] = g; groups[#groups + 1] = g end
    g.idx[#g.idx + 1] = i
    g.sx, g.sy = g.sx + p.wx, g.sy + p.wy
  end
  for _, g in ipairs(groups) do g.c = { wx = g.sx / #g.idx, wy = g.sy / #g.idx, cont = g.cont } end
  local order, cur, left = { 1 }, pts[1], {}
  for k = 1, #groups do left[k] = true end
  local function NextGroup()
    local best, bd
    for k in pairs(left) do
      local d = T(cur, groups[k].c)
      if not bd or d < bd then best, bd = k, d end
    end
    if not best then
      local total = 0
      for k = 2, #order do total = total + T(pts[order[k - 1]], pts[order[k]]) + (pts[order[k]].dur or 0) end
      done(order, total)
      return
    end
    left[best] = nil
    local g = groups[best]
    local sub = { cur }
    for _, i in ipairs(g.idx) do sub[#sub + 1] = pts[i] end
    Solve(sub, function(o)
      for k = 2, #o do order[#order + 1] = g.idx[o[k] - 1] end
      cur = pts[order[#order]]
      C_Timer.After(0, NextGroup)
    end)
  end
  NextGroup()
end

-- Schritte bauen, mit Reise Schritten am Hafen
local function Steps(pts, order)
  local steps, t = {}, 0
  local prev = pts[order[1]]
  for k = 2, #order do
    local p = pts[order[k]]
    local direct = (prev.cont == p.cont) and ((ns.WalkYards and ns.WalkYards(prev, p)) or math.sqrt((prev.wx - p.wx) ^ 2 + (prev.wy - p.wy) ^ 2) * PATH) or math.huge
    local tt, from, to, l, side
    if ns.TravelBest and (prev.cont ~= p.cont or direct > LONG) then tt, from, to, l, side = ns.TravelBest(prev, p, SPEED) end
    if tt and (prev.cont ~= p.cont or tt < direct / SPEED) then
      local kind, _, toName = ns.TravelDesc(l, side, from, to)
      local fromName = select(2, ns.TravelDesc(l, side, from, to))
      table.insert(steps, { map = from.map, x = from.x, y = from.y, t = t, travel = true, lvl = UnitLevel("player"),
        acts = { { k = "R", link = l.id, li = l.idx, side = side, kind = kind, quest = toName, dest = toName, toMap = to.map, toX = to.x, toY = to.y, toCont = to.cont, cross = prev.cont ~= p.cont,
          who = (l.id == "fly") and fromName or nil } } })
      t = t + tt
    else
      t = t + direct / SPEED
    end
    t = t + (p.dur or 0)
    table.insert(steps, { map = p.map, x = p.x, y = p.y, t = t, lvl = UnitLevel("player"), acts = { p.act } })
    prev = p
  end
  return steps, t
end

local function Start()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  local c, wx, wy = World(map, x, y)
  if not c then return end
  return { map = map, x = x, y = y, cont = c, wx = wx, wy = wy, dur = 0 }
end

local busyAt = 0
local function Run(title, pts, extra, tour)
  -- haengt eine Rechnung (Fehler im Hintergrund), nach einer Minute nicht mehr blockieren
  if busy and GetTime() - busyAt < 60 then ns.Print(TR"Tour wird schon berechnet ..."); return end
  local s = Start()
  if not s then ns.Print(TR"Keine Position gefunden"); return end
  if #pts == 0 then ns.Print(title .. TR": nichts mehr offen " .. (extra or "")); return end
  SPEED = ns.PlanSpeed and ns.PlanSpeed() or ns.speed or 7
  table.insert(pts, 1, s)
  busy, busyAt = true, GetTime()
  ns.Print((TR"%s: rechne die kürzeste Reihenfolge für %d Punkte ..."):format(title, #pts - 1))
  local solver = (#pts > 150) and SolveGrouped or Solve
  -- 20.4b (K 19:06 a, S "Neu rechnen hat die Tour nicht neu gerechnet"): sie wird neu gerechnet, ab deinem Standort.
  -- Kommt dieselbe Reihenfolge heraus, sagt der Chat das jetzt, statt dass es aussieht, als waere nichts passiert
  local function Sig(list, from)
    local t = {}
    for i = from or 1, #list do local st = list[i]; t[#t + 1] = ("%s:%.3f:%.3f"):format(tostring(st.map), st.x or 0, st.y or 0) end
    return table.concat(t, "|")
  end
  local old = ns.db and ns.db.opt
  local oldSig = (old and old.tour == tour and old.steps) and Sig(old.steps, old.idx or 1) or nil
  solver(pts, function(order)
    local steps, total = Steps(pts, order)
    busy = false
    ns.OptLoad(steps, { title = title, sec = total, quests = 0, tour = tour })
    if oldSig and oldSig == Sig(steps) then
      ns.Print((TR"%s neu gerechnet: die Reihenfolge ab hier ist schon die kürzeste, nichts geändert."):format(title))
    end
    ns.Print((TR"%s: %d Punkte, ca %s %s"):format(title, #pts - 1, ns.Clock(total), extra or ""))
    if ns.RefreshBig then ns.RefreshBig() end
  end)
end

-- Tour zu beliebigen Punkten (z.B. Buecher): Punkte auf erreichbaren Kontinenten
function ns.TourPoints(title, list, tour)
  local s = Start()
  if not s then ns.Print(TR"Keine Position gefunden"); return end
  local reach = ns.TravelReach and ns.TravelReach(s.cont) or { [s.cont] = true }
  local pts = {}
  for _, p in ipairs(list) do
    local c, wx, wy = World(p.map, p.x, p.y)
    if c and reach[c] then
      p.cont, p.wx, p.wy = c, wx, wy
      table.insert(pts, p)
    end
  end
  Run(title, pts, "", tour)
end

------------------------------------------------------------
-- Flugpunkte
------------------------------------------------------------
function ns.TourFlights()
  if not ns.svcReady then ns.Print(TR"Flugmeister werden noch eingelesen, gleich nochmal versuchen."); return end
  local s = Start()
  local reach = s and ns.TravelReach and ns.TravelReach(s.cont) or {}
  local pts, seen = {}, {}
  local L = UnitLevel("player")
  local danger = 0
  for ui in pairs(ns.svc or {}) do
    for _, e in ipairs(ns.FlightMasters(ui)) do
      if not seen[e[6]] then
        seen[e[6]] = true
        local c, wx, wy = World(ui, e[1], e[2])
        if c and reach[c] then
          local z = ns.zones and ns.zones[ui]
          if z and z.min and z.min > L + 10 then danger = danger + 1 end
          table.insert(pts, { map = ui, x = e[1], y = e[2], cont = c, wx = wx, wy = wy, dur = 10,
            act = { k = "F", npc = e[6], who = e[3], quest = TR"Flugpunkt " .. (e[3] or "?"), lvl = z and z.min } })
        end
      end
    end
  end
  Run(TR"Alle Flugpunkte", pts, danger > 0 and ("(" .. danger .. TR" davon in Zonen deutlich über deinem Level, vorsichtig)") or "", "TourFlights")
end

------------------------------------------------------------
-- Entdecken
------------------------------------------------------------
local function Explored(map, x, y, name)
  local db = ns.db
  if db and db.learned and db.learned[map] and name and db.learned[map][name] then return true end
  if C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition and CreateVector2D then
    local ok, ids = pcall(C_MapExplorationInfo.GetExploredAreaIDsAtPosition, map, CreateVector2D(x, y))
    if ok and type(ids) == "table" and #ids > 0 then return true end
  end
  return false
end
ns.TourExplored = Explored

function ns.TourExplore()
  local s = Start()
  if not s then ns.Print(TR"Keine Position gefunden"); return end
  local reach = ns.TravelReach and ns.TravelReach(s.cont) or { [s.cont] = true }
  local L = UnitLevel("player")
  local pts, skipped = {}, 0
  local learned = (ns.db and ns.db.learned) or {}
  for map, list in pairs(ns.routes or {}) do
    local z = ns.zones and ns.zones[map]
    local tooHigh = z and z.min and z.min > L + 8
    -- Zonen der anderen Fraktion (Startgebiete, Hauptstaedte) nicht zum Entdecken schicken
    local enemy = ns.EnemyZone and ns.EnemyZone((ns.cityParent and ns.cityParent[map]) or map)
    for _, p in ipairs(enemy and {} or list) do
      local lp = learned[map] and learned[map][p[3]]
      local x, y = lp and lp[1] or p[1], lp and lp[2] or p[2]
      if not Explored(map, x, y, p[3]) then
        if tooHigh then
          skipped = skipped + 1
        else
          local c, wx, wy = World(map, x, y)
          if c and reach[c] then
            table.insert(pts, { map = map, x = x, y = y, cont = c, wx = wx, wy = wy, dur = 3,
              act = { k = "E", name = p[3], quest = p[3], x = x, y = y, map = map } })
          end
        end
      end
    end
  end
  Run(TR"Alles entdecken", pts, skipped > 0 and ("(" .. skipped .. TR" Gebiete in zu hohen Zonen ausgelassen)") or "", "TourExplore")
end

------------------------------------------------------------
-- Alle Quests und Speed Leveling gibt es nicht mehr als Tour: das macht jetzt der Tempo Regler.
-- Alte Aufrufe (Makros, /klg Befehle) stellen den Regler um.
------------------------------------------------------------
function ns.TourAllQuests() if ns.SetLevelStep then ns.SetLevelStep(1) end end
function ns.TourSpeed() if ns.SetLevelStep then ns.SetLevelStep(3) end end

------------------------------------------------------------
-- Questlog Route: fragt, ob eine Zone oder alle Quests im Log
------------------------------------------------------------
local pick
function ns.TourQuestLogRun(zone, qids, n)
  local L = UnitLevel("player")
  ns.Optimize(L + 3, function(opt)
    if opt and ns.db then
      ns.db.optMode = true
      if n then opt.title = (TR"Questlog: %d Quests"):format(n) end
    end
    if ns.RefreshBig then ns.RefreshBig() end
  end, { logOnly = true, zone = zone, qids = qids })
end

-- Fenster: Quests aus dem Log anhaken, dann Route berechnen
local ROW = 18
function ns.TourQuestLog()
  local log = (ns.ReadLog and ns.ReadLog()) or {}
  local byZone, zones = {}, {}
  for qid, p in pairs(log) do
    local z = p.zone or TR"Sonstige"
    if not byZone[z] then byZone[z] = {}; table.insert(zones, z) end
    table.insert(byZone[z], { id = qid, title = p.title or (TR"Quest " .. qid), level = p.level, done = p.complete })
  end
  if #zones == 0 then ns.Print(TR"Dein Questlog ist leer."); return end
  table.sort(zones)
  for _, z in ipairs(zones) do table.sort(byZone[z], function(a, b) return (a.level or 0) < (b.level or 0) end) end
  local db = ns.db
  db.logPick = db.logPick or {}
  local sel = db.logPick
  -- neue Quests sind angehakt, abgegebene fallen raus
  for qid in pairs(sel) do if not log[qid] then sel[qid] = nil end end
  for qid in pairs(log) do if sel[qid] == nil then sel[qid] = true end end

  if not pick then
    local f = CreateFrame("Frame", "TaurenRouteLogPick", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(380, 460)
    f:SetClampedToScreen(true) -- 1.3zk (Pr 13:00 Layout WIN_NOCLAMP)
    f:SetPoint("CENTER", 0, 40)
    f:SetFrameStrata("FULLSCREEN")
    if ns.Skin then ns.Skin(f, "window") end
    local stripe = f:CreateTexture(nil, "ARTWORK")
    stripe:SetPoint("TOPLEFT", 1, -1); stripe:SetPoint("TOPRIGHT", -1, -1); stripe:SetHeight(2)
    stripe:SetColorTexture(0.5, 0.82, 0.73, 1)
    f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetText(TR"Questlog Route: Quests anhaken")
    f.count = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    f.count:SetPoint("TOPRIGHT", -12, -12)
    local sf = CreateFrame("ScrollFrame", "TaurenRouteLogPickScroll", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 10, -32); sf:SetPoint("BOTTOMRIGHT", -30, 74)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(330, 10)
    sf:SetScrollChild(child)
    f.child, f.rows = child, {}
    local function Btn(text, w, x, y, fn)
      local b = (ns.T and ns.T.Button(f) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate"))
      b:SetSize(w, 22); b:SetPoint("BOTTOMLEFT", x, y); b:SetText(text); b:SetScript("OnClick", fn)
      return b
    end
    Btn(TR"Alle", 80, 12, 42, function() for qid in pairs(f.log) do sel[qid] = true end; f.Fill() end)
    Btn(TR"Keine", 80, 96, 42, function() for qid in pairs(f.log) do sel[qid] = false end; f.Fill() end)
    Btn(TR"Nur fertige", 100, 180, 42, function() for qid, p in pairs(f.log) do sel[qid] = p.complete and true or false end; f.Fill() end)
    Btn(TR"Route berechnen", 170, 12, 12, function()
      local set, n = {}, 0
      for qid in pairs(f.log) do if sel[qid] then set[qid] = true; n = n + 1 end end
      if n == 0 then ns.Print(TR"Keine Quest angehakt."); return end
      f:Hide()
      ns.TourQuestLogRun(nil, set, n)
    end)
    Btn(TR"Schliessen", 70, 190, 12, function() f:Hide() end)
    Btn(TR"Aufräumen", 90, 264, 12, function() ns.ShowLogCleanup() end)
    pick = f
  end
  local f = pick
  f.log = log
  function f.Fill()
    local y, i = 0, 0
    local nSel = 0
    for qid in pairs(log) do if sel[qid] then nSel = nSel + 1 end end
    f.count:SetText((TR"%d von %d angehakt"):format(nSel, (function() local c = 0 for _ in pairs(log) do c = c + 1 end return c end)()))
    local function Row()
      i = i + 1
      local r = f.rows[i]
      if not r then
        r = CreateFrame("CheckButton", nil, f.child, "UICheckButtonTemplate")
        r:SetSize(20, 20)
        r.text = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
        r.text:SetPoint("LEFT", r, "RIGHT", 2, 0)
        r.text:SetWidth(300); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
        f.rows[i] = r
      end
      r:ClearAllPoints()
      r:SetPoint("TOPLEFT", 0, -y)
      r:Show()
      y = y + ROW
      return r
    end
    for _, z in ipairs(zones) do
      -- Zone: Haken setzt oder loescht alle Quests der Zone
      local all = true
      for _, q in ipairs(byZone[z]) do if not sel[q.id] then all = false end end
      local r = Row()
      r:SetChecked(all)
      r.text:SetText(("|cffffd100%s|r |cff9d9d9d(%d)|r"):format(z, #byZone[z]))
      r:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        for _, q in ipairs(byZone[z]) do sel[q.id] = on end
        f.Fill()
      end)
      for _, q in ipairs(byZone[z]) do
        local rq = Row()
        rq:SetPoint("TOPLEFT", 18, -(y - ROW))
        rq:SetChecked(sel[q.id] and true or false)
        rq.text:SetText(("%s|cff9d9d9d[%d]|r %s%s"):format("", q.level or 0, q.title, q.done and TR" |cff40ff40(fertig)|r" or ""))
        rq:SetScript("OnClick", function(self) sel[q.id] = self:GetChecked() and true or false; f.Fill() end)
      end
      y = y + 4
    end
    for k = i + 1, #f.rows do f.rows[k]:Hide() end
    f.child:SetHeight(y + 10)
  end
  f.Fill()
  f:Show()
end

------------------------------------------------------------
-- Zeit Budget: Route fuer x Stunden, am Ende ins Gasthaus
------------------------------------------------------------
function ns.TourBudget(hours)
  local L = UnitLevel("player")
  local sec = hours * 3600
  -- 17.4: im Test Log als Anlass sichtbar (stand vorher als "ohne bekannten Anlass")
  if ns.TestLogWhy then ns.TestLogWhy("Stunden Budget") end
  ns.Optimize(math.min(60, L + 5), function(opt)
    if opt and ns.db then ns.db.optMode = true end
    if ns.RefreshBig then ns.RefreshBig() end
  end, { endInn = true, maxTime = sec - 300, budget = sec })
end

------------------------------------------------------------
-- Questlog aufraeumen: welche Quests lohnen sich am wenigsten
------------------------------------------------------------
local function GrayLevel(L)
  if L <= 5 then return 0 end
  if L <= 39 then return L - 5 - math.floor(L / 10) end
  return L - 1 - math.floor(L / 5)
end

function ns.LogCleanup()
  local log = (ns.ReadLog and ns.ReadLog()) or {}
  local L = UnitLevel("player")
  local gray = GrayLevel(L)
  local inRoute = {}
  local opt = ns.db and ns.db.opt
  if opt and opt.steps and not (opt.opts and opt.opts.logOnly) then
    for k = opt.idx or 1, #opt.steps do
      for _, a in ipairs(opt.steps[k].acts) do if a.qid then inRoute[a.qid] = true end end
    end
    -- Fahrplan: auch Quests, die erst ein spaeterer Abschnitt abgibt, sind "in der Route"
    local pl = ns.db.plan60
    if pl and pl.secs then
      for k = math.max(1, pl.cur or 1), #pl.secs do
        for _, st in ipairs(pl.secs[k].steps or {}) do
          for _, a in ipairs(st.acts or {}) do if a.qid then inRoute[a.qid] = true end end
        end
      end
    end
  end
  local out = {}
  for qid, p in pairs(log) do
    if not p.complete then
      local why
      if p.level and p.level <= gray then why = TR"grau, gibt kaum noch XP"
      elseif ns.skippedFar and ns.skippedFar[qid] then why = TR"Abgabe sehr weit weg"
      elseif ns.IsEliteQuest and ns.IsEliteQuest(qid) and not (IsInGroup and IsInGroup()) then why = TR"Gruppenquest, du bist solo"
      -- 19.11: Gegner noch 3 oder mehr Level ueber dir (die Route macht sie erst spaeter, im vollen Log blockieren sie)
      elseif ns.optLogMob and ns.optLogMob[qid] then
        local fl = ns.optLogMob[qid]
        why = (fl and fl > 0) and (TR"Gegner noch zu hoch (Level %d), später wieder annehmen"):format(fl) or TR"Gegner noch zu hoch, später wieder annehmen"
      elseif next(inRoute) and not inRoute[qid] then why = TR"lohnt sich laut Route nicht" end
      if why then table.insert(out, { id = qid, title = p.title or (TR"Quest " .. qid), level = p.level, why = why }) end
    end
  end
  table.sort(out, function(a, b) return (a.level or 0) < (b.level or 0) end)
  return out
end

local function Abandon(qid)
  local n = (GetNumQuestLogEntries and GetNumQuestLogEntries()) or 0
  for i = 1, n do
    local _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
    if not isHeader and id == qid then
      SelectQuestLogEntry(i)
      if SetAbandonQuest then ns.Api.Prot("SetAbandonQuest", SetAbandonQuest) end
      if AbandonQuest then ns.Api.Prot("AbandonQuest", AbandonQuest) end
      return true
    end
  end
end

local clean
-- 19.11: "Questlog aufräumen" (Hinweis, Warnung, Meine Route) oeffnet das Fenster mit Haken (ns.AutoLogCleanup)
function ns.ShowLogCleanup()
  if ns.AutoLogCleanup then return ns.AutoLogCleanup(true) end
  return ns.ShowLogCleanupOld()
end
function ns.ShowLogCleanupOld()
  local list = ns.LogCleanup()
  if #list == 0 then ns.Print(TR"Nichts zum Aufräumen, alle Quests im Log lohnen sich."); return end
  if not clean then
    local f = CreateFrame("Frame", "TaurenRouteCleanup", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetFrameStrata("FULLSCREEN")
    f:SetPoint("CENTER", 0, 40)
    if ns.Skin then ns.Skin(f, "window") end
    f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    f.title:SetPoint("TOPLEFT", 12, -10)
    f.title:SetText(TR"Questlog aufräumen")
    f.rows = {}
    f.close = (ns.T and ns.T.Button(f) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate"))
    f.close:SetSize(100, 22); f.close:SetPoint("BOTTOM", 0, 10); f.close:SetText(TR"Fertig")
    f.close:SetScript("OnClick", function() f:Hide() end)
    f.all = (ns.T and ns.T.Button(f, "", 140, 22, true) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate"))
    f.all:SetSize(160, 22); f.all:SetPoint("BOTTOMLEFT", 12, 10); f.all:SetText(TR"Alle unnötigen abbrechen")
    f.close:ClearAllPoints(); f.close:SetPoint("BOTTOMRIGHT", -12, 10)
    clean = f
  end
  local f = clean
  for i, q in ipairs(list) do
    local r = f.rows[i]
    if not r then
      r = CreateFrame("Frame", nil, f)
      r:SetSize(420, 22)
      r.text = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.text:SetPoint("LEFT", 0, 0); r.text:SetWidth(320); r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
      r.btn = (ns.T and ns.T.Button(r) or CreateFrame("Button", nil, r, "UIPanelButtonTemplate"))
      r.btn:SetSize(90, 20); r.btn:SetPoint("RIGHT", 0, 0); r.btn:SetText(TR"Abbrechen")
      f.rows[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 12, -34 - (i - 1) * 24)
    r.text:SetText(("|cff9d9d9d[%d]|r %s  |cffff9030%s|r"):format(q.level or 0, q.title, q.why))
    r.btn:Enable()
    r.btn:SetScript("OnClick", function(self)
      if Abandon(q.id) then
        ns.Print(TR"Abgebrochen: " .. q.title)
        self:Disable()
        r.text:SetText("|cff6d6d6d" .. q.title .. TR" (abgebrochen)|r")
      end
    end)
    r:Show()
  end
  for k = #list + 1, #f.rows do f.rows[k]:Hide() end
  f.all:SetScript("OnClick", function()
    -- abbrechen laesst sich nicht rueckgaengig machen: erst fragen
    ns.Confirm((TR"Alle %d Quests in der Liste abbrechen?\n\nDas lässt sich nicht rückgängig machen."):format(#list), TR"Abbrechen", function()
      local n = 0
      for i, q in ipairs(list) do
        if Abandon(q.id) then
          n = n + 1
          local r = f.rows[i]
          if r then r.btn:Disable(); r.text:SetText("|cff6d6d6d" .. q.title .. TR" (abgebrochen)|r") end
        end
      end
      ns.Print((TR"%d Quests abgebrochen."):format(n))
      if ns.db then ns.db.stepChanged = nil end
    end, TR"Behalten")
  end)
  f:SetSize(444, 76 + #list * 24)
  f:Show()
end

-- 19.11 (Sascha): Log voll: nach Bestaetigung aufraeumen. Fenster mit Warnung und allen Quests, die die Route nicht
-- braucht (Gegner noch zu hoch, grau, Abgabe weit weg, Gruppenquest solo, lohnt sich nicht). Vor jeder Quest ein Haken
-- (am Anfang alle an): nur Quests mit Haken werden abgebrochen. Fragt hoechstens alle 30 Minuten von selbst
local autoAskAt, autoF = -1e9, nil
function ns.AutoLogCleanup(byHand)
  local T = ns.T
  if not (T and T.Popup and ns.LogCleanup) then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if not byHand and GetTime() - autoAskAt < 1800 then return end
  local list = ns.LogCleanup()
  if #list == 0 then if byHand then ns.Print(TR"Nichts zum Aufräumen, alle Quests im Log lohnen sich.") end return end
  autoAskAt = GetTime()
  if not autoF then
    local f = T.Popup("ForeverWegweiserAutoClean", 440, TR"Questlog voll")
    f.rows = {}
    f.yes = T.Button(f, TR"Ausgewählte abbrechen", 170, 24, true)
    f.yes:SetPoint("BOTTOMRIGHT", -14, 12)
    f.no = T.Button(f, TR"Behalten", 120, 24)
    f.no:SetPoint("BOTTOMLEFT", 14, 12)
    f.no:SetScript("OnClick", function() f:Hide() end)
    autoF = f
  end
  local f = autoF
  f.body:SetText(TR"Diese Quests braucht die Route nicht oder noch nicht. Quests mit Haken werden abgebrochen, das geht nicht rückgängig. Ohne Haken bleibt die Quest.")
  local top = (f.body:GetStringHeight() or 30) + 50
  local pick = {}
  for k, q in ipairs(list) do
    local r = f.rows[k]
    if not r then
      r = CreateFrame("Frame", nil, f)
      r:SetSize(412, 22)
      r.cb = T.CheckButton(r)
      r.cb:SetSize(22, 22); r.cb:SetPoint("LEFT", 0, 0)
      r.text = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.text:SetPoint("LEFT", r.cb, "RIGHT", 4, 0); r.text:SetPoint("RIGHT", r, "RIGHT", 0, 0)
      r.text:SetJustifyH("LEFT"); r.text:SetWordWrap(false)
      f.rows[k] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 14, -top - (k - 1) * 24)
    r.text:SetText(("|cff9d9d9d[%d]|r %s  |cffff9030%s|r"):format(q.level or 0, q.title, q.why))
    pick[k] = true
    r.cb:SetChecked(true)
    r.cb:SetScript("OnClick", function(self) pick[k] = self:GetChecked() and true or false end)
    r:Show()
  end
  for k = #list + 1, #f.rows do f.rows[k]:Hide() end
  f.yes:SetScript("OnClick", function()
    f:Hide()
    local n = 0
    for k, q in ipairs(list) do if pick[k] and Abandon(q.id) then n = n + 1 end end
    ns.Print((TR"%d Quests abgebrochen."):format(n))
    if ns.TestLog then ns.TestLog("QUEST", ("Questlog aufgeraeumt: %d von %d Quests abgebrochen"):format(n, #list)) end
    if n > 0 and ns.AutoOpt and C_Timer then C_Timer.After(2, function() ns.AutoOpt("auto") end) end
  end)
  if ns.TestLog then ns.TestLog("QUEST", ("Questlog voll: Aufraeumen vorgeschlagen, %d Quests"):format(#list)) end
  f:SetHeight(top + #list * 24 + 50)
  f:Show()
end

-- Log fast voll? einmal Bescheid sagen
-- 17.9: einmal, wenn das Log voll wird, danach erst wieder nach 30 Min (vorher alle 5 Min, Dungeon Test: 3x im Chat)
local lastWarn, fullNow = -9999, false
local lf = CreateFrame("Frame")
ns.RegEv(lf, "QUEST_LOG_UPDATE")
lf:SetScript("OnEvent", function()
  if not GetNumQuestLogEntries then return end
  local _, n = GetNumQuestLogEntries()
  n = ns.Plain and ns.Plain(n) or n
  if type(n) ~= "number" then return end
  local max = ns.LogMax()
  if n < ns.LogWarn() - 1 then fullNow = false; return end
  if n >= ns.LogWarn() and (not fullNow or GetTime() - lastWarn > 1800) then
    fullNow = true
    lastWarn = GetTime()
    ns.Print((TR"|cffffd100Questlog fast voll (%d von %d).|r Unter Meine Route, Planen: Questlog aufräumen."):format(n, max))
  end
end)

function ns.TourBusy() return busy end

-- Ganze Route bis zum Maximallevel (dauert laenger, nur auf Wunsch)
function ns.TourTo60()
  local max = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  local L = UnitLevel("player")
  if L >= max then ns.Print(TR"Du bist schon auf dem Maximallevel."); return end
  ns.Print((TR"Rechne die ganze Route bis Level %d. Das dauert etwas, das Spiel läuft dabei normal weiter."):format(max))
  ns.Optimize(max, function(opt)
    if opt and ns.db then ns.db.optMode = true; opt.full = true end
    ns.Print(opt and (TR"Route bis Level %d fertig: %d Schritte."):format(max, #opt.steps) or TR"Route bis 60 ging nicht.")
    if ns.RefreshBig then ns.RefreshBig() end
  end, { full = true })
end
