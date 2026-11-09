-- Navi (17.4, Wunsch Sascha): Knopf an der Weltkarte, dann Klick auf ein Ziel. Das Addon sucht den schnellsten Weg
-- mit Laufen oder Reittier (dein Tempo), bekannten Flugpunkten (gemessene Flugzeiten, sonst geschaetzt), Schiff und
-- Zeppelin (Abfahrt von Nauticus, sonst mittlere Wartezeit) und dem Ruhestein, wenn er bereit ist.
-- Der Pfeil fuehrt Abschnitt fuer Abschnitt, die Karte zeigt die Strecke. Am Ziel oder mit Klick auf Navi (oder auf
-- die Ziel Zeile im Mini Fenster) geht es zurueck zur Route.
local ADDON, ns = ...
local TR = ns.TR

local HEARTH = 10          -- Ruhestein wirken
-- 1.3zo (P115, S Log 15:1x: Navi Orgrimmar nach Unterstadt plante zuerst "hearth 25s" zum Gasthaus in Orgrimmar): Ruhestein
-- nur, wenn der Bindeort weiter als HEARTH_MIN_YD weg ist (oder auf einem anderen Kontinent) und nicht in derselben Zone bzw
-- Stadt wie du. Sonst kostet er die Abklingzeit fuer ein paar Sekunden Laufweg
local HEARTH_MIN_YD = 1000
local PORT_EXTRA = 90      -- 19.32: Teleport (Magier) erst, wenn er mindestens so viel spart
local BOARD = 15           -- so viel vor der Abfahrt am Steg sein
local REACH = { walk = 25, fly = 120, ride = 200, hearth = 150, portal = 150, wp = 30 }

local pick = false         -- naechster Klick auf die Karte setzt das Ziel
local lastPlan = 0
-- 20.3z3 (Ad AN Na P7, Log 16:59:22 Ruckler 0.28 s "Route wird gerechnet"): Services.lua zaehlt db.knownFPRev bei JEDEM Oeffnen der
-- Flugkarte hoch, auch wenn kein Flugpunkt neu ist. Das Navi plante darum jedes Mal neu (Dijkstra). Jetzt nur noch, wenn sich die
-- Menge der bekannten Flugpunkte wirklich geaendert hat (Unterschrift aus Anzahl, Summe der Nummern, Anzahl vermutet).
local function FPSig()
  local db = ns.db
  local n, s, v = 0, 0, 0
  if db and type(db.knownFP) == "table" then
    for k, val in pairs(db.knownFP) do if val then n = n + 1; s = s + (tonumber(k) or 0) end end
  end
  if db and type(db.fpVermutet) == "table" then for _ in pairs(db.fpVermutet) do v = v + 1 end end
  return n .. ":" .. s .. ":" .. v
end

local function Node(map, x, y, name, extra)
  local c, wx, wy = ns.MapWorld(map, x, y)
  if not c then return nil end
  local n = { map = map, x = x, y = y, cont = c, wx = wx, wy = wy, name = name }
  if extra then for k, v in pairs(extra) do n[k] = v end end
  return n
end
local function D(a, b) return math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) end

local function Here()
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
  if not pos then return nil end
  local px, py = pos:GetXY()
  return Node(pm, px, py, TR"Du")
end

-- Wartezeit am Steg, wenn man t Sekunden ab jetzt dort ist (Nauticus: echte Abfahrt, sonst halber Takt)
-- 1.3za: live Abfahrt (unten bei der Abfahrt Vorschau gesetzt), hier vorne bekannt fuer LegText und Tick
local LiveDepart
local function Wait(l, side, t)
  -- 17.9: nicht "x and f()", das gibt nur den ersten Wert weiter (rtt war immer nil, Nauticus Zeiten nie benutzt)
  local w0, _, rtt
  if ns.TravelNautTimes then w0, _, rtt = ns.TravelNautTimes(l, side) end
  if w0 and rtt and rtt > 0 then
    local w = math.fmod(w0 - t, rtt)
    if w < 0 then w = w + rtt end
    if w < BOARD then w = w + rtt end
    return w, true
  end
  local r = ns.TravelRtt and ns.TravelRtt(l) or l.rtt or 300
  return r / 2, false
end

------------------------------------------------------------
-- Wege: Laufen folgt den Wegen (gleiche Wegsuche wie der Pfeil, Path.lua), 17.5
------------------------------------------------------------
local function ZoneOf(map, x, y)
  local p = ns.cityParent and ns.cityParent[map]
  if p and ns.ToMap then
    local zx, zy = ns.ToMap(map, x, y, p)
    if zx then return p, zx, zy end
  end
  return map, x, y
end

-- 19.5: wie oft beim Planen kein Landweg ueber die Gelaende Karte bekannt war (Linie dann nur die Richtung)
local noLand = 0
-- 19.9 (Code Pruefung): der Zonen Graph rechnete beim Planen noch (CrossLegs nil), das ist kein "kein Landweg"
local planBusy = false
-- Punkte { map, x, y } von a nach b (ohne a), in der Zone um Berge herum, ueber eine Zonengrenze am bekannten Uebergang
local function WalkPts(a, b)
  local za, ax, ay = ZoneOf(a.map, a.x, a.y)
  local zb, bx, by = ZoneOf(b.map, b.x, b.y)
  local out = {}
  local function Seg(z, fx, fy, tx, ty)
    local ok, p = pcall(ns.WalkPath or function() end, z, fx, fy, tx, ty)
    if ok and type(p) == "table" then
      for _, q in ipairs(p) do out[#out + 1] = { z, q[1], q[2] } end
    end
    local l = out[#out]
    if not (l and l[1] == z and math.abs(l[2] - tx) < 1e-4 and math.abs(l[3] - ty) < 1e-4) then out[#out + 1] = { z, tx, ty } end
  end
  if za == zb then
    Seg(za, ax, ay, bx, by)
    return out
  end
  -- 19.2: ueber die Uebergaenge der Gelaende Karte, pro Zone den Wegen entlang (Sascha 29.10.: von Tirisfal ging die
  -- Linie quer ueber die Berge in die Pestlaender, weil die Zonengrenzen auf der Luftlinie gesucht wurden)
  local K = ns.Karte
  if K and K.CrossLegs then
    local okL, legs = pcall(K.CrossLegs, za, ax, ay, zb, bx, by)
    if okL and type(legs) == "table" and #legs > 0 then
      for i, l in ipairs(legs) do
        if l.jump then
          out[#out + 1] = { l[1], l[4], l[5] }
        else
          Seg(l[1], l[2], l[3], l[4], l[5])
        end
        -- Uebergang: Wegpunkt behalten und sagen, wohin es weiter geht
        local nxt = legs[i + 1]
        if nxt and out[#out] and nxt[1] ~= l[1] then out[#out].cross = nxt[1] end
      end
      return out
    end
    -- beide Zonen haben Daten, aber das Netz kennt keinen Weg dazwischen (oder rechnet noch)
    if K.HasZone and K.HasZone(za) and K.HasZone(zb) then
      if K.Busy and K.Busy() then planBusy = true else noLand = noLand + 1 end
    end
  end
  -- bekannter Uebergang (selbst gelaufen) zwischen den zwei Zonen
  local cx, cy
  if ns.ZoneCrossing then cx, cy = ns.ZoneCrossing(za, ax, ay, zb, bx, by) end
  local qx, qy
  if cx and ns.ToMap then qx, qy = ns.ToMap(za, cx, cy, zb) end
  if cx and qx then
    Seg(za, ax, ay, cx, cy)
    Seg(zb, qx, qy, bx, by)
    return out
  end
  -- sonst: Zonengrenzen auf der Luftlinie suchen (Kontinent Karte), in jeder Zone den Wegen entlang
  local ok, parts = pcall(function()
    local info = C_Map.GetMapInfo and C_Map.GetMapInfo(za)
    local cont = info and info.parentMapID
    if not (cont and C_Map.GetMapInfoAtPosition and ns.ToMap) then return nil end
    local sx, sy = ns.ToMap(za, ax, ay, cont)
    local ex, ey = ns.ToMap(zb, bx, by, cont)
    if not (sx and ex) then return nil end
    local function ZoneAt(x, y)
      local zi = C_Map.GetMapInfoAtPosition(cont, x, y)
      local z = zi and zi.mapID
      if z and ns.cityParent and ns.cityParent[z] then z = ns.cityParent[z] end
      return z
    end
    local list, curZ, lastIn = {}, za, { sx, sy }
    local N = 48
    for k = 1, N do
      local t = k / N
      local x, y = sx + (ex - sx) * t, sy + (ey - sy) * t
      local z = ZoneAt(x, y)
      if z and z ~= curZ then
        list[#list + 1] = { from = curZ, to = z, a = lastIn, b = { x, y } }
        curZ = z
        if #list > 4 then return nil end
      end
      lastIn = { x, y }
    end
    return list
  end)
  if not ok or not parts or #parts == 0 then out[#out + 1] = { zb, bx, by }; return out end
  local fz, fx, fy = za, ax, ay
  for _, c in ipairs(parts) do
    local x1, y1 = ns.ToMap((C_Map.GetMapInfo(za) or {}).parentMapID, c.a[1], c.a[2], c.from)
    local x2, y2 = ns.ToMap((C_Map.GetMapInfo(za) or {}).parentMapID, c.b[1], c.b[2], c.to)
    if not (x1 and x2) or c.from ~= fz then out[#out + 1] = { zb, bx, by }; return out end
    Seg(fz, fx, fy, x1, y1)
    fz, fx, fy = c.to, x2, y2
  end
  if fz == zb then Seg(zb, fx, fy, bx, by) else out[#out + 1] = { zb, bx, by } end
  return out
end

-- Laufen in Wegpunkte teilen (17.5, Wunsch Sascha: "gehe zu Wegpunkt 1, dann Wegpunkt 2, dann Zeppelin ...").
-- Nur Ecken, die mindestens WP_MIN Yards auseinander liegen, hoechstens WP_MAX pro Abschnitt.
local WP_MIN, WP_MAX = 45, 8
local function Waypoints(a, b)
  local pts = WalkPts(a, b)
  local out, last = {}, a
  for k = 1, #pts - 1 do
    local q = pts[k]
    local n = Node(q[1], q[2], q[3])
    if n and n.cont == a.cont then
      n.cross = q.cross
      n.k = k -- 19.32 (Navi Chat): Stelle in pts, fuer die Linien Stuecke pro Wegpunkt
      if D(last, n) >= WP_MIN and D(n, b) >= WP_MIN then out[#out + 1] = n; last = n
      -- Uebergang knapp nach dem letzten Wegpunkt: den Uebergang nehmen statt dem Wegpunkt davor
      elseif n.cross and #out > 0 and not out[#out].cross and D(n, b) >= WP_MIN then out[#out] = n; last = n end
    end
  end
  -- zu viele: gleichmaessig ausduennen, Uebergaenge zwischen Zonen bleiben immer (19.2)
  local nc = 0
  for _, n in ipairs(out) do if n.cross then nc = nc + 1 end end
  if #out > WP_MAX + nc then
    local others = {}
    for i, n in ipairs(out) do if not n.cross then others[#others + 1] = i end end
    local pick = {}
    for k = 1, WP_MAX do local i = others[math.floor(k * #others / WP_MAX + 0.5)]; if i then pick[i] = true end end
    local keep = {}
    for i, n in ipairs(out) do if n.cross or pick[i] then keep[#keep + 1] = n end end
    out = keep
  end
  return out, pts
end

-- 19.11 (Teil Y: Horde 133 von 300 Navi Plaenen gingen ohne Hinweis durch einen Posten der Allianz): fuehrt der Weg
-- durch einen Posten der anderen Fraktion? 300 yd um Start und Ziel zaehlen nicht, dort will man ja hin.
-- Ergebnis: Zone und Weltpunkt der ersten Stelle, sonst nil.
local POST_FREE = 300
local function PostOnWay(a, pts, s, z)
  if not (ns.EnemyPostAt and pts) then return nil end
  local pz, px, py = ZoneOf(a.map, a.x, a.y)
  for _, q in ipairs(pts) do
    local qz, x, y = q[1], q[2], q[3]
    if qz == pz and px then
      local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
      local n = math.min(400, math.max(1, math.ceil(d / 0.006)))
      for k = 1, n do
        local t = k / n
        local sx, sy = px + (x - px) * t, py + (y - py) * t
        if ns.EnemyPostAt(qz, sx, sy) then
          local w = Node(qz, sx, sy)
          if w and (not s or w.cont ~= s.cont or D(w, s) > POST_FREE) and (not z or w.cont ~= z.cont or D(w, z) > POST_FREE) then
            return qz, w
          end
        end
      end
    end
    pz, px, py = qz, x, y
  end
end
-- 19.32 (Navi Chat, Pruefer 05:08): liegt im Rechteck eines Wegstuecks (Punkte { zone, x, y }, plus Rand) eine Posten
-- Zelle der anderen Fraktion? Felder wie Path.lua: 80 x 80 pro Zone, Schluessel cy * 100 + cx
local POST_CELL, POST_MARGIN = 0.0125, 0.03
local function PostNear(pts)
  if not (pts and ns.EnemyPostCells) then return false end
  local box = {}
  for _, q in ipairs(pts) do
    local z, x, y = q[1], q[2], q[3]
    if z and x and y then
      local b = box[z]
      if not b then b = { x, x, y, y }; box[z] = b end
      if x < b[1] then b[1] = x end
      if x > b[2] then b[2] = x end
      if y < b[3] then b[3] = y end
      if y > b[4] then b[4] = y end
    end
  end
  for z, b in pairs(box) do
    local ok, cells = pcall(ns.EnemyPostCells, z)
    if ok and type(cells) == "table" and next(cells) then
      -- Pruefer 05:14: beide Enden auf 0 bis 79 kappen (Punkte knapp ausserhalb der Zone)
      local x0 = math.min(79, math.max(0, math.floor((b[1] - POST_MARGIN) / POST_CELL)))
      local x1 = math.max(0, math.min(79, math.floor((b[2] + POST_MARGIN) / POST_CELL)))
      local y0 = math.min(79, math.max(0, math.floor((b[3] - POST_MARGIN) / POST_CELL)))
      local y1 = math.max(0, math.min(79, math.floor((b[4] + POST_MARGIN) / POST_CELL)))
      for cy = y0, y1 do
        for cx = x0, x1 do
          if cells[cy * 100 + cx] then return true end
        end
      end
    end
  end
  return false
end
-- Abstand Punkt p zur Strecke a b (Welt Yards)
local function SegD(p, a, b)
  if not (p and a and b) or a.cont ~= p.cont or b.cont ~= p.cont then return math.huge end
  local vx, vy = b.wx - a.wx, b.wy - a.wy
  local l2 = vx * vx + vy * vy
  local t = l2 > 0 and ((p.wx - a.wx) * vx + (p.wy - a.wy) * vy) / l2 or 0
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return math.sqrt((a.wx + vx * t - p.wx) ^ 2 + (a.wy + vy * t - p.wy) ^ 2)
end
local function EnemyName()
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  return (fac == "Alliance") and "H" or "A"
end

------------------------------------------------------------
-- Planen: kuerzeste Zeit ueber Laufen, Fluege, Schiffe, Zeppeline und Ruhestein
------------------------------------------------------------
-- 19.5: kennt die Gelaende Karte keinen Landweg zwischen den Zonen zweier Punkte, zaehlt Laufen dreifach. Dann nimmt
-- das Navi lieber Flug, Schiff oder Zeppelin, und nur wenn es gar nicht anders geht die Richtung (mit Hinweis).
local NOLAND_F = 3
local function LandF(a, b)
  local K = ns.Karte
  if not (K and K.Reachable) then return 1 end
  local za = ZoneOf(a.map, a.x, a.y)
  local zb = ZoneOf(b.map, b.x, b.y)
  if za == zb then return 1 end
  return (K.Reachable(za, zb) == false) and NOLAND_F or 1
end

-- 19.24 (Sascha Teil 1 Punkt 4): Laufzeit ueber das Wegnetz der Gelaende Karte, gleich wie die Route (ns.WalkYards),
-- vorher Luftlinie mal 1.2. Fuer alle Laufwege (19.21 nur ab dir und zum Ziel). Kennt das Netz keinen Landweg, zaehlt
-- Laufen dreifach (LandF). Strecken zwischen festen Punkten (Flugmeister, Stege) gemerkt, bis sich der Zonen Graph aendert
local walkMemo, walkMemoGen, walkMemoN = {}, -1, 0
local function WalkD(a, b, TV)
  local fixed = (a.fp or a.dock) and (b.fp or b.dock)
  local K = ns.Karte
  local gen = K and K.XGenNow and K.XGenNow() or 0
  if walkMemoGen ~= gen or walkMemoN > 5000 then walkMemo, walkMemoGen, walkMemoN = {}, gen, 0 end
  local key = fixed and ("%d:%.4f:%.4f:%d:%.4f:%.4f"):format(a.map or 0, a.x or 0, a.y or 0, b.map or 0, b.x or 0, b.y or 0)
  local m = key and walkMemo[key]
  if m then return m end
  local d, net
  if ns.WalkYards then d, net = ns.WalkYards(a, b) end -- nicht "x and f()", das gibt nur den ersten Wert
  if not net then d = D(a, b) * TV.PATH * LandF(a, b) end
  if key then walkMemo[key] = d; walkMemoN = walkMemoN + 1 end
  return d
end

-- 19.39: Ruhestein Stand der letzten Planung (Hinweis und Log)
local naviBind = nil
function ns.NaviPlan(dmap, dx, dy, dname)
  local S = Here()
  -- 17.9: im Dungeon gibt es keine Position, das Navi geht erst draussen
  if not S and ns.InInstance and ns.InInstance() then return nil, TR"Im Dungeon kennt das Spiel deine Position nicht. Draussen nochmal das Ziel wählen." end
  if not S then return nil, TR"Deine Position ist gerade nicht bekannt." end
  local Z = Node(dmap, dx, dy, dname or (ns.ZoneName and ns.ZoneName(dmap)) or "?")
  if not Z then return nil, TR"Für diese Stelle kennt das Addon keine Weltposition." end
  noLand = 0
  planBusy = false
  local TV = ns.TRAVEL or { LOAD = 15, FLY_SPEED = 32, FLY_OVER = 25, PATH = 1.2 }
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  -- 19.12 (Sascha): Ziel zu Fuss nicht erreichbar (im Berg, im tiefen Wasser, ringsum abgeschlossen): der Pin bleibt
  -- am geklickten Punkt, das Navi fuehrt zur naechsten erreichbaren Stelle und sagt, wie weit das Ziel noch weg ist
  local G, reach = Z, nil
  do
    local K = ns.Karte
    local zu, zx, zy = ZoneOf(dmap, dx, dy)
    -- 19.13: nicht in Staedten. Donnerfels liegt auf einem Tafelberg, im Raster der Zone ist das Berg, oben ist aber
    -- alles begehbar (Aufzuege). Sim Teil N 19.12: Ziel in Donnerfels, das Navi fuehrte an den Fuss vom Berg
    local inCity = ns.cityParent and ns.cityParent[dmap] and true or false
    if not inCity and ns.cityParent and ns.ToMap then
      for c, p in pairs(ns.cityParent) do
        if p == zu then
          local cx, cy = ns.ToMap(zu, zx, zy, c)
          if cx and cx >= 0 and cx <= 1 and cy >= 0 and cy <= 1 then inCity = true; break end
        end
      end
    end
    -- 1.3zd (K 07:16): Ufer Punkt von Ka geht vor (Ziel im tiefen Wasser)
    local ux, uy, ud = nil, nil, nil
    if K and K.Ufer then ux, uy, ud = K.Ufer(zu, zx, zy) end
    if ux and uy then
      local R = Node(zu, ux, uy, Z.name)
      local du = ns.WorldDist and ns.WorldDist({ zu, zx, zy }, { zu, ux, uy })
      if R then G = R; reach = { d = math.floor(du or ud or 0), why = "wasser" } end
    elseif not inCity and K and K.ReachPoint and K.HasZone and K.HasZone(zu) then
      local ok, rx, ry, rd, why = pcall(K.ReachPoint, zu, zx, zy)
      if ok and rx and rd and rd > 25 then
        local R = Node(zu, rx, ry, Z.name)
        if R then G = R; reach = { d = math.floor(rd), why = why } end
      end
    end
  end
  local nodes = { S, G }
  local useFly = not (ns.db and ns.db.useFlights == false)
  if useFly then
    for _, f in ipairs(ns.TravelFlightPoints and ns.TravelFlightPoints() or {}) do
      nodes[#nodes + 1] = { map = f.map, x = f.x, y = f.y, cont = f.cont, wx = f.wx, wy = f.wy, name = f.name, id = f.id, fp = true }
    end
  end
  local rides = {}
  for _, l in ipairs(ns.travelLinks or {}) do
    if not ns.TravelUsable or ns.TravelUsable(l) then
      local ea, eb = ns.TravelEndpoint(l.a), ns.TravelEndpoint(l.b)
      if ea and eb then
        local na = { map = ea.map, x = ea.x, y = ea.y, cont = ea.cont, wx = ea.wx, wy = ea.wy, name = ea.name, dock = true }
        local nb = { map = eb.map, x = eb.x, y = eb.y, cont = eb.cont, wx = eb.wx, wy = eb.wy, name = eb.name, dock = true }
        nodes[#nodes + 1] = na; local ia = #nodes
        nodes[#nodes + 1] = nb; local ib = #nodes
        rides[ia] = rides[ia] or {}; table.insert(rides[ia], { to = ib, l = l, side = "a" })
        rides[ib] = rides[ib] or {}; table.insert(rides[ib], { to = ia, l = l, side = "b" })
      end
    end
  end
  local H, recall
  local bi = ns.db and ns.db.bindInn
  local hasStone = not ns.Api.GetItemCount or ns.Api.GetItemCount(6948) > 0
  -- 19.39 (Navi Chat, Saschas Log 31.10. 13:20, K AUF 13:56): Ruhestein Ort noch unbekannt, dann einmal nachfragen
  -- (Bindeort Name, Gastwirt Orte), sonst fuer Hinweis und Log merken, warum der Ruhestein nicht dabei ist
  if not bi and ns.NaviBindGuess then pcall(ns.NaviBindGuess); bi = ns.db and ns.db.bindInn end
  do
    local left = (hasStone and ns.HearthLeft) and ns.HearthLeft() or nil
    naviBind = { known = bi and true or false, stone = hasStone and true or false, left = left,
      home = GetBindLocation and GetBindLocation() or nil }
  end
  -- 19.32 (Navi Chat): Schamane mit Astralem Rueckruf, wenn der Ruhestein gerade abklingt
  if bi and not (hasStone and ns.HearthLeft and ns.HearthLeft() <= 0) and ns.NaviRecallReady and ns.NaviRecallReady() then recall = true end
  if bi and ((hasStone and ns.HearthLeft and ns.HearthLeft() <= 0) or recall) then
    local h = Node(bi[1], bi[2], bi[3], (ns.ZoneName and ns.ZoneName(bi[1])) or "?", { inn = true })
    local cp = ns.cityParent or {}
    local function Zone(m) return m and (cp[m] or m) end
    local far = h and S and (h.cont ~= S.cont or D(S, h) > HEARTH_MIN_YD) and Zone(h.map) ~= Zone(S.map)
    if h and far then nodes[#nodes + 1] = h; H = #nodes
    elseif h and ns.TestLog and ns.naviHearthSkipLog ~= h.map then
      ns.naviHearthSkipLog = h.map
      ns.TestLog("NAVI", ("Ruhestein nicht eingeplant: Bindeort %s zu nah oder gleiche Zone"):format(tostring(h.name)))
    end
  end
  -- 19.32 (Navi Chat, Saschas Log 30.10.): Magier Teleport in die Hauptstaedte (Rune im Gepaeck), ab deinem Standort
  local jumps = {}
  for _, j in ipairs(ns.NaviJumps and ns.NaviJumps() or {}) do
    nodes[#nodes + 1] = j.node
    jumps[#jumps + 1] = { i = #nodes, j = j }
  end
  -- Dijkstra (Zeit ab jetzt), Kanten haengen an der Ankunftszeit (Abfahrten)
  local dist, prev, done = { [1] = 0 }, {}, {}
  -- Pruefer A6: Zuschlag fuer die Wahl (Teleport) bis hierher, gilt nicht fuer echte Uhrzeiten (Abfahrt Schiff, Zeppelin)
  local exv = { [1] = 0 }
  local function Relax(v, t, e)
    if not dist[v] or t < dist[v] - 0.01 then dist[v] = t; prev[v] = e; exv[v] = (exv[e.from] or 0) + (e.extra or 0) end
  end
  while true do
    local u, bu
    for i in pairs(dist) do if not done[i] and (not bu or dist[i] < bu) then u, bu = i, dist[i] end end
    if not u or u == 2 then break end
    done[u] = true
    local a = nodes[u]
    for v, b in ipairs(nodes) do
      if not done[v] and v ~= u and b.cont == a.cont then
        -- Laufen ist nie kuerzer als die Luftlinie mal 1.2: geht es so schon nicht besser, gar nicht erst rechnen
        if not dist[v] or bu + D(a, b) * TV.PATH / speed < dist[v] - 0.01 then
          Relax(v, bu + WalkD(a, b, TV) / speed, { kind = "walk", from = u, t0 = bu })
        end
        if a.fp and b.fp then
          local air = ns.FlightTime and ns.FlightTime(a.id, b.id)
          -- 19.21: ohne Messung die Zeit aus den Spieldaten (Strecke ueber deine Flugpunkte); false = keine Strecke
          local tx = (not air) and ns.TaxiTime and ns.TaxiTime(a.id, b.id)
          if air or tx ~= false then
            Relax(v, bu + (air or tx or D(a, b) * 1.15 / TV.FLY_SPEED) + TV.FLY_OVER, { kind = "fly", from = u, t0 = bu, measured = air ~= nil, game = tx and true or nil })
          end
        end
      end
    end
    for _, r in ipairs(rides[u] or {}) do
      if not done[r.to] then
        local w, exact = Wait(r.l, r.side, bu - (exv[u] or 0))
        local ride = ns.TravelRide and ns.TravelRide(r.l, r.side) or 120
        Relax(r.to, bu + w + ride + TV.LOAD, { kind = "ride", from = u, t0 = bu, l = r.l, side = r.side, wait = w, exact = exact })
      end
    end
    if u == 1 and H and not done[H] then Relax(H, HEARTH + TV.LOAD, { kind = "hearth", from = 1, t0 = 0, recall = recall }) end
    if u == 1 then
      for _, jj in ipairs(jumps) do
        -- Spielfluss: eine Rune und 10 s Zaubern nur, wenn es wirklich etwas bringt (PORT_EXTRA nur fuer die Wahl,
        -- die angezeigte Zeit bleibt echt)
        if not done[jj.i] then Relax(jj.i, jj.j.sec + TV.LOAD + PORT_EXTRA, { kind = "portal", from = 1, t0 = 0, text = jj.j.text, extra = PORT_EXTRA, spell = jj.j.node and jj.j.node.port }) end
      end
    end
  end
  if not dist[2] then return nil, TR"Dorthin findet das Navi keinen Weg (anderer Kontinent ohne bekannte Verbindung)." end
  -- 20.3k (S Flug Regel 21:28, K Log Z.7283: Orgrimmar nach Kreuzweg wurde zu Fuss geplant): Pruefzeile, warum kein Flug
  -- gewaehlt wurde. Naechster Flugpunkt am Start und am Ziel, Zeit nach Messung, Spieldaten oder Schaetzung, gegen den Fussweg
  if ns.TestLog and useFly then
    pcall(function()
      local f1, d1, f2, d2, nfp = nil, nil, nil, nil, 0
      for _, f in ipairs(nodes) do
        if f.fp then
          nfp = nfp + 1
          if f.cont == S.cont then local d = D(S, f); if not d1 or d < d1 then f1, d1 = f, d end end
          if f.cont == G.cont then local d = D(G, f); if not d2 or d < d2 then f2, d2 = f, d end end
        end
      end
      local flew = false
      local fl = {}
      local v2 = 2
      while v2 and v2 ~= 1 do
        local e = prev[v2]
        if not e then break end
        if e.kind == "fly" then
          flew = true
          table.insert(fl, 1, ("%s nach %s"):format(tostring(nodes[e.from] and nodes[e.from].name), tostring(nodes[v2] and nodes[v2].name)))
        end
        v2 = e.from
      end
      local walkT = WalkD(S, G, TV) / speed
      local txt
      if not (f1 and f2) then
        txt = ("kein Flugpunkt am Start (%s) oder Ziel (%s) bekannt"):format(f1 and f1.name or "-", f2 and f2.name or "-")
      elseif f1.cont ~= f2.cont then
        -- 20.3z3 (K 18:08 N1): Start und Ziel auf verschiedenen Kontinenten: ein Flug zwischen den beiden naechsten Flugmeistern
        -- gibt es nicht (Schiff, Zeppelin, Portal). Das war keine fehlende Strecke, nur eine irrefuehrende Pruefzeile
        txt = ("Start (%s) und Ziel (%s) auf verschiedenen Kontinenten, kein direkter Flug"):format(tostring(f1.name), tostring(f2.name))
      elseif f1 == f2 then
        txt = ("Start und Ziel am gleichen Flugpunkt %s"):format(tostring(f1.name))
      else
        local air = ns.FlightTime and ns.FlightTime(f1.id, f2.id)
        local tx = (not air) and ns.TaxiTime and ns.TaxiTime(f1.id, f2.id)
        local src = air and "gemessen" or (tx == false and "KEINE Strecke ueber deine Flugpunkte (Daten)" or (tx and "Spieldaten" or "Schaetzung"))
        local fly = air or (tx ~= false and (tx or D(f1, f2) * 1.15 / TV.FLY_SPEED)) or nil
        local tot = fly and (d1 * TV.PATH / speed + fly + TV.FLY_OVER + d2 * TV.PATH / speed) or nil
        txt = ("%s (%d yd) nach %s (%d yd): Flug %s s (%s), Fussweg %d s"):format(tostring(f1.name), math.floor(d1), tostring(f2.name), math.floor(d2),
          tot and tostring(math.floor(tot)) or "-", src, math.floor(walkT))
      end
      -- 1.3f (K 02:30 Nebenbei: 01:49 bis 01:54 alle 5 bis 60 s dieselbe Zeile): nur loggen, wenn sich der Plan aendert
      -- (Flugpunkte, Wahl, Flug ja nein); Zeiten und yd zaehlen nicht, die aendern sich beim Laufen dauernd
      local fpKey = tostring(nfp) .. "|" .. (txt:gsub("%d+", "")) .. "|" .. (flew and table.concat(fl, ",") or "-")
      if fpKey ~= ns.lastFlugPlanKey then
        ns.lastFlugPlanKey = fpKey
        ns.TestLog("FLUG_PLAN", ("%d Flugpunkte im Plan, %s, Plan nimmt %s"):format(nfp, txt, flew and ("FLUG: " .. table.concat(fl, ", ")) or "keinen Flug"))
      end
    end)
  end
  -- Weg zurueck verfolgen
  local edges, v = {}, 2
  while v ~= 1 do
    local e = prev[v]
    if not e then break end
    e.to = v
    table.insert(edges, 1, e)
    v = e.from
  end
  local legs = {}
  local portExtra = 0
  for i, e in ipairs(edges) do
    local a, b, nx = nodes[e.from], nodes[e.to], edges[i + 1]
    local sec = dist[e.to] - e.t0
    local leg = { kind = e.kind, at = b, to = b, sec = sec }
    if e.kind == "walk" then
      if nx and nx.kind == "fly" then
        local place = ns.ZoneName and ns.ZoneName(b.map)
        leg.text = (TR"Zum Flugmeister %s"):format((place and place ~= b.name) and (b.name .. ", " .. place) or (b.name or "?"))
        -- 20.3h (Na, test_203g Punkt 9): Ziel des Flugs gleich im Text (bei mehreren Fluegen hintereinander das letzte)
        local k, last = i + 1, nil
        while edges[k] and edges[k].kind == "fly" do last = edges[k]; k = k + 1 end
        local dn = last and nodes[last.to]
        if dn then
          local dp = ns.ZoneName and ns.ZoneName(dn.map)
          leg.flyTo = dn
          leg.text = (TR"%s, dann Flug nach %s"):format(leg.text, (dp and dp ~= dn.name) and (dp .. " (" .. (dn.name or "?") .. ")") or (dn.name or "?"))
        end
      elseif nx and nx.kind == "ride" then
        local tn = nodes[nx.to]
        leg.text = (nx.l.tram and TR"Zur %s nach %s" or TR"Zum %s nach %s"):format(nx.l.kind or TR"Schiff", tn and tn.name or "?")
      elseif e.to == 2 then
        leg.text = TR"Zum Ziel"
        if reach then leg.text = TR"Zur nächsten erreichbaren Stelle"; leg.reach = reach end
      else leg.text = TR"Laufen" end
      -- winzige Wege (Flugmeister gleich neben dem Steg) weglassen
      if D(a, b) < 15 and e.to ~= 2 then leg = nil end
    elseif e.kind == "fly" then
      local place = ns.ZoneName and ns.ZoneName(b.map)
      leg.text = (TR"Flug nach %s"):format((place and place ~= b.name) and (place .. " (" .. (b.name or "?") .. ")") or (b.name or "?"))
      leg.measured = e.measured
      leg.game = e.game
      leg.from = a -- 20.3p (Da Nr 7): von diesem Flugmeister geht der Flug los (Auto Flug prueft das)
    elseif e.kind == "ride" then
      -- Pfeil bleibt am Steg (das Ziel liegt meist auf einem anderen Kontinent)
      leg.at = a
      leg.wait, leg.exact = e.wait, e.exact
      -- 1.3za (P110 Punkt 6, S Log 05:29: "faehrt in 7:13", Nauticus "warten 193.8 s"): die Verbindung am Abschnitt merken,
      -- damit Anzeige, Vorschau und "verpasst" die Abfahrt live aus Nauticus nehmen. Vorher fehlten l und side am
      -- Abschnitt, darum galt immer die beim Planen geschaetzte Zeit (depart), und die lag um einen Teil Umlauf daneben
      leg.l, leg.side = e.l, e.side
      leg.tram = e.l and e.l.tram or nil
      leg.depart = GetTime() + e.t0 - (exv[e.from] or 0) + e.wait
      leg.text = (TR"%s nach %s"):format(e.l.kind or TR"Schiff", b.name or "?")
    elseif e.kind == "hearth" then
      leg.at = nodes[1]
      leg.text = (e.recall and TR"Astralen Rückruf wirken (%s)" or TR"Ruhestein benutzen (%s)"):format(b.name or "?")
      leg.recall = e.recall or nil
    elseif e.kind == "portal" then
      leg.at = nodes[1]
      leg.text = e.text or "?"
      leg.spell = e.spell
      leg.sec = math.max(1, leg.sec - (e.extra or 0))
      portExtra = e.extra or 0
    end
    if leg then legs[#legs + 1] = leg end
  end
  if #legs == 0 then legs[1] = { kind = "walk", at = G, to = G, sec = 0, text = reach and TR"Zur nächsten erreichbaren Stelle" or TR"Zum Ziel", reach = reach } end
  -- 1.3g (P87, S 02:20: Steinkrallengebirge bis Orgrimmar als zwei Fluege, zweimal Auto Flug): Fluege direkt hintereinander
  -- (ohne Fussweg dazwischen) werden ein Schritt "Flug nach X (ueber Y)", Zeit als Summe. Die einzelnen Strecken bleiben in
  -- lg.hops: am Flugmeister nimmt der Auto Flug direkt das Endziel, wenn es auf der Flugkarte erreichbar ist, sonst die
  -- naechste Strecke (und am Zwischenpunkt wieder)
  do
    local merged = {}
    for _, lg in ipairs(legs) do
      local prev = merged[#merged]
      if lg.kind == "fly" and prev and prev.kind == "fly" then
        prev.hops = prev.hops or { { from = prev.from, to = prev.to, sec = prev.sec } }
        prev.hops[#prev.hops + 1] = { from = lg.from, to = lg.to, sec = lg.sec }
        prev.to = lg.to
        prev.sec = (prev.sec or 0) + (lg.sec or 0)
        prev.measured = prev.measured and lg.measured
        prev.game = prev.game and lg.game
        local via = {}
        for k = 1, #prev.hops - 1 do via[#via + 1] = tostring(prev.hops[k].to and prev.hops[k].to.name or "?") end
        local b = lg.to
        local place = ns.ZoneName and b and ns.ZoneName(b.map)
        local dest = (place and place ~= b.name) and (place .. " (" .. (b.name or "?") .. ")") or (b and b.name or "?")
        prev.text = (TR"Flug nach %s (über %s)"):format(dest, table.concat(via, ", "))
      else
        merged[#merged + 1] = lg
      end
    end
    legs = merged
  end
  -- Laufen als Schritte: Wegpunkte den Wegen entlang, dann das eigentliche Ziel des Abschnitts
  local steps, wpn, from = {}, 0, S
  local postZ
  -- 19.32 (Navi Chat, Ruckler 0.3 bis 0.55 s beim Zeichnen): die Linie eines Abschnitts kommt aus einer einzigen
  -- Wegsuche. Jeder Wegpunkt bekommt sein Stueck davon (lg.pc), die Karte muss dafuer nichts neu suchen. Vorher suchte
  -- die Karte jedes Stueck einzeln (bis 23 Wegsuchen in einem Bild) und die Posten Pruefung jedes Stueck noch einmal.
  local xgNow = (ns.Karte and ns.Karte.XGenNow and ns.Karte.XGenNow()) or 0
  local tNow = GetTime()
  local function Slice(pts, k0, k1)
    local s = {}
    for k = k0, k1 do if pts[k] then s[#s + 1] = pts[k] end end
    return s
  end
  for _, lg in ipairs(legs) do
    local i0, hz, hw = #steps + 1, nil, nil
    if lg.kind == "walk" and from then
      local wps, pts = Waypoints(from, lg.to)
      hz, hw = PostOnWay(from, pts, S, Z)
      local used = 0
      local pv, k0 = from, 1
      for _, n in ipairs(wps) do
        wpn = wpn + 1
        local prevN = steps[#steps] and steps[#steps].wp and steps[#steps].to or from
        local sec = D(prevN, n) * 1.05 / speed
        used = used + sec
        local txt = (TR"Wegpunkt %d"):format(wpn)
        local zn = n.cross and ns.ZoneName and ns.ZoneName(n.cross)
        if zn then txt = (TR"Wegpunkt %d, weiter nach %s"):format(wpn, zn) end
        local st = { kind = "walk", wp = true, at = n, to = n, sec = sec, text = txt }
        if n.k and pts then
          local sl = Slice(pts, k0, n.k)
          st.pc = { goal = n, fm = pv.map, fx = pv.x, fy = pv.y, pts = sl, t = tNow, xg = xgNow }
          -- Posten Pruefung pro Stueck: unten nach der Schleife (nur mit Posten Zelle im Rechteck des Stuecks)
          k0 = n.k + 1
        end
        steps[#steps + 1] = st
        pv = n
      end
      if pts and #wps > 0 and wps[#wps].k then
        local sl = Slice(pts, k0, #pts)
        lg.pc = { goal = lg.to, fm = pv.map, fx = pv.x, fy = pv.y, pts = sl, t = tNow, xg = xgNow }
      elseif pts and #wps == 0 then
        lg.pc = { goal = lg.to, fm = from.map, fx = from.x, fy = from.y, pts = pts, t = tNow, xg = xgNow }
      end
      -- 19.31 (Teil Y: Allianz Level 10 nach Brill ohne Hinweis), wieder da (Pruefer 04:50): der Pfeil sucht seinen Weg
      -- von Wegpunkt zu Wegpunkt selbst (WalkNext) und kann vom Stueck der Planung abweichen. Darum ein Stueck mit
      -- eigener Wegsuche pruefen, aber nur, wenn im Rechteck dieses Stuecks (plus Rand) wirklich eine Posten Zelle liegt
      -- (Pruefer 05:08: fast jede Zone hat irgendwo Posten, die Wegsuche pro Stueck kostet sonst wieder Ruckler)
      if not hz and #wps > 0 and pts and ns.EnemyPostCells then
        local noLand0, busy0 = noLand, planBusy
        local pv, k0 = from, 1
        for k = 1, #wps + 1 do
          local nx = wps[k] or lg.to
          local k1 = wps[k] and wps[k].k or #pts
          -- Pruefer 05:14: das Stueck beginnt beim vorigen Wegpunkt, der Startpunkt gehoert ins Rechteck
          local sl
          if k0 > 1 then sl = Slice(pts, k0 - 1, k1)
          else
            local fz, fx, fy = ZoneOf(from.map, from.x, from.y)
            sl = Slice(pts, 1, k1)
            table.insert(sl, 1, { fz, fx, fy })
          end
          if PostNear(sl) then
            hz, hw = PostOnWay(pv, WalkPts(pv, nx), S, Z)
            if hz then break end
          end
          pv, k0 = nx, k1 + 1
        end
        -- Pruefer 05:08: ein Stueck ohne Landweg soll nicht den ganzen Plan als "kein Landweg bekannt" markieren
        noLand, planBusy = noLand0, busy0
      end
      lg.sec = math.max(5, lg.sec - used)
    end
    steps[#steps + 1] = lg
    -- 19.11: den Schritt mit dem Posten markieren (Mini Fenster sagt es dann genau dort)
    if hz then
      postZ = postZ or hz
      local best, bd, pv = nil, nil, from
      for j = i0, #steps do
        local d = SegD(hw, pv, steps[j].to)
        if not bd or d < bd then best, bd = j, d end
        pv = steps[j].to
      end
      if best then steps[best].post = hz end
    end
    from = lg.to
  end
  -- 19.32 (Navi Chat): waere es mit Flugpunkten, die das Addon noch nicht als bekannt hat, viel schneller? Dann ein Tipp
  local tip
  if ns.NaviFlugTipp then
    local okT, r = pcall(ns.NaviFlugTipp, S, G, speed, dist[2] - portExtra)
    if okT then tip = r end
  end
  return { dest = Z, reach = reach, legs = steps, total = dist[2] - portExtra, cur = 1, made = GetTime(), noLand = noLand > 0 or nil, busy = planBusy or nil,
    post = postZ, postFac = postZ and EnemyName() or nil, fpTip = tip, fpRev = (ns.db and ns.db.knownFPRev) or 0, fpSig = FPSig() }
end

------------------------------------------------------------
-- Pfeil und Fortschritt
------------------------------------------------------------
local function LegText(nv, i)
  local lg = nv.legs[i]
  local t = lg.text
  if lg.kind == "ride" and lg.exact and lg.depart then
    local left = (LiveDepart and LiveDepart(lg.l, lg.side, lg.depart)) or (lg.depart - GetTime())
    if left > 0 then t = t .. (TR", fährt in %s"):format(ns.Clock and ns.Clock(left) or math.floor(left) .. "s") end
  end
  return ("Weg %d/%d: %s"):format(i, #nv.legs, t)   -- 20.4b (Ad ANT z6): war "Navi 1/20", die Zahl sind Wegpunkte, nicht Schritte
end

local function SetTarget()
  local nv = ns.navi
  if not nv then return end
  local lg = nv.legs[nv.cur]
  -- 20.3y (K 17:20 / 17:22 Punkt P1, S 16:56: "Pfeil zeigt auch den Weg zu Fuss"): bei einem Flug Abschnitt war das Pfeil Ziel der
  -- Landeort (weit weg, in anderer Zone). Solange du nicht fliegst, zeigt der Pfeil zum Flugmeister, von dem der Flug startet
  -- (lg.from), waehrend des Flugs auf den Landeort. nv.st.fm = true: Arrow rechnet den Weg dorthin wie bei Laufen.
  local at, fm = lg.at, nil
  if lg.kind == "fly" and lg.from and lg.from.map and lg.from.x and lg.from.y and not (UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")) then
    at, fm = lg.from, true
  end
  nv.st = { map = at.map, x = at.x, y = at.y, name = LegText(nv, nv.cur), kind = "navi", fm = fm }
  ns.serviceTarget = nv.st
  nv.legT = GetTime()
  nv.flyT0, nv.castT0 = nil, nil -- 20.3z3 (P9): Restzeit von Flug/Teleport/Ruhestein zaehlt erst ab Abflug bzw. Zauber
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then pcall(ns.RefreshHud) end
end

-- 1.3a (P84, K 00:05, Log 23:36:01 bis 23:36:09: Pfeil wechselt alle 1 bis 2 s zwischen "Service Ziel, Weg 1/1: Zum Ziel"
-- und der Route, jedes Mal ein neues Navi mit anderem Ziel im Brachland, ohne Zeile wer es startet oder beendet): wer
-- startet und beendet, steht jetzt im Log (NAVI "Start von" / "Ende von", je Sitzung hoechstens FLAP_LOG_N mal). Kommt ein
-- neues Navi, das nicht vom Spieler gewaehlt ist, kurz nachdem eins beendet wurde (FLAP_GAP_S), zaehlt das als hin und
-- her. Ab FLAP_MAX Mal in FLAP_WIN_S sind solche Navis FLAP_BLOCK_S gesperrt: der Pfeil bleibt auf der Route
local FLAP_GAP_S, FLAP_WIN_S, FLAP_MAX, FLAP_BLOCK_S, FLAP_LOG_N = 8, 30, 2, 30, 20
local flap = { n = 0, t0 = 0, stopT = 0, blockT = 0, logN = 0 }
local function Caller()
  if not debugstack then return "?" end
  local ok, st = pcall(debugstack, 3, 3, 0)
  if not ok or type(st) ~= "string" then return "?" end
  st = st:gsub("Interface[/\\]AddOns[/\\]", ""):gsub("\n", " < ")
  return st:sub(1, 200)
end
local function FlapLog(what)
  if not ns.TestLog or flap.logN >= FLAP_LOG_N then return end
  flap.logN = flap.logN + 1
  ns.TestLog("NAVI", what .. " von: " .. Caller())
end

local function Stop(msg)
  local nv = ns.navi
  if nv then flap.stopT = GetTime(); FlapLog("Ende") end
  ns.navi = nil
  if ns.db then ns.db.naviDest = nil end
  if nv and ns.serviceTarget == nv.st then ns.serviceTarget = nil end
  if msg then ns.Print(msg) end
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then pcall(ns.RefreshHud) end
  if ns.MapButtonText then ns.MapButtonText() end
end
ns.NaviStop = Stop

local function Start(nv, quiet, hidden, user)
  -- 1.3a (P84): Sperre gegen hin und her (siehe oben), vom Spieler gewaehlte Ziele (Karte, Seiten) gehen immer
  local now = GetTime()
  if not user and not ns.navi then
    if now < flap.blockT then return false end
    if now - flap.stopT < FLAP_GAP_S then
      if now - flap.t0 > FLAP_WIN_S then flap.n, flap.t0 = 0, now end
      flap.n = flap.n + 1
      if flap.n >= FLAP_MAX then
        flap.blockT = now + FLAP_BLOCK_S
        flap.n = 0
        if ns.TestLog then ns.TestLog("NAVI", ("Hin und her: neues Navi %d s gesperrt, Pfeil bleibt auf der Route (Ziel %s)"):format(FLAP_BLOCK_S, tostring(nv.dest and nv.dest.name))) end
        FlapLog("Gesperrt")
        return false
      end
    end
  end
  FlapLog("Start")
  -- 20.3z3 (K 18:08 N2, Ad Z5): ein Navi von einer Seite (Berufe, Farm, Gold, Tour Anweg) bleibt auch nach einem Neuplanen
  -- (Flugpunkte, neuer Weg ab hier, Einblenden) eines: der neue Plan erbt das Zeichen vom alten mit gleichem Ziel
  local old = ns.navi
  if old and old.zielSeite and not nv.zielSeite and old.dest and nv.dest and old.dest.map == nv.dest.map
    and math.abs((old.dest.x or 0) - (nv.dest.x or 0)) < 0.0005 and math.abs((old.dest.y or 0) - (nv.dest.y or 0)) < 0.0005 then
    nv.zielSeite = true
  end
  ns.navi = nv
  nv.hidden = hidden or nil
  -- Ziel merken (pro Charakter): nach Neuladen oder Einloggen ist das Navi wieder da (17.5)
  if ns.db then ns.db.naviDest = { map = nv.dest.map, x = nv.dest.x, y = nv.dest.y, name = nv.dest.name, hidden = hidden or nil, seite = nv.zielSeite or nil } end
  if not quiet then
    ns.Print((TR"Navi nach %s: ca %s"):format(nv.dest.name or "?", ns.Clock and ns.Clock(nv.total) or math.floor(nv.total) .. "s"))
    for i, lg in ipairs(nv.legs) do
      local extra = ""
      -- 19.21: Zeit aus den Spieldaten ist nicht geschaetzt
      if lg.kind == "fly" and not lg.measured and not lg.game then extra = TR" (Flugzeit geschätzt)" end
      if lg.kind == "ride" and not lg.exact then extra = TR" (Abfahrt unbekannt, mittlere Wartezeit)" end
      ns.Print(("  %d. %s, %s%s"):format(i, lg.text, ns.Clock and ns.Clock(lg.sec) or math.floor(lg.sec) .. "s", extra))
    end
  end
  if nv.noLand and not quiet then
    ns.Print(TR"Navi: Für ein Stück kennt die Gelände Karte keinen Landweg. Dort zeigt die Linie nur die Richtung.")
  end
  if nv.reach and not quiet then
    ns.Print((TR"Navi: Das Ziel ist zu Fuss nicht erreichbar (%s). Der Pfeil führt so nah wie möglich hin, dann fehlen noch ca %d yd.")
      :format(nv.reach.why == "berg" and TR"liegt im Berg" or nv.reach.why == "wasser" and TR"liegt im tiefen Wasser" or TR"ringsum kein Weg", nv.reach.d))
  end
  -- 19.39: Ruhestein bereit, aber sein Ort unbekannt: einmal sagen, wie man es aendert
  local nb = naviBind
  if not quiet and nb and nb.stone and not nb.known and (nb.left or 0) <= 0 and ns.NaviBindTippNeu and ns.NaviBindTippNeu() then
    ns.Print((TR"Navi: Wo dein Ruhestein gebunden ist (%s), weiss das Addon noch nicht, darum plant das Navi ihn nicht ein. Einmal benutzen oder beim Gastwirt dort vorbeigehen, dann ist er bekannt."):format(nb.home or "?"))
  end
  if nv.fpTip and not quiet and ns.NaviFlugTippText and (not ns.NaviFlugTippNeu or ns.NaviFlugTippNeu(nv.dest)) then
    ns.Print(ns.NaviFlugTippText(nv.fpTip))
  end
  if nv.post and not quiet then
    local zn = (ns.ZoneName and ns.ZoneName(nv.post)) or "?"
    if nv.postFac == "H" then ns.Print((TR"Navi: Vorsicht, der Weg führt durch einen Posten der Horde (%s)."):format(zn))
    else ns.Print((TR"Navi: Vorsicht, der Weg führt durch einen Posten der Allianz (%s)."):format(zn)) end
  end
  if ns.TestLog then
    local parts = {}
    for _, lg in ipairs(nv.legs) do parts[#parts + 1] = lg.kind .. " " .. math.floor(lg.sec) .. "s" end
    if nv.noLand then parts[#parts + 1] = "kein Landweg bekannt" end
    if nv.post then parts[#parts + 1] = "Posten " .. tostring(nv.postFac) .. " in " .. tostring(nv.post) end
    if nv.reach then parts[#parts + 1] = ("Ziel nicht erreichbar (%s), Rest %d yd"):format(tostring(nv.reach.why), nv.reach.d) end
    -- 19.32 (Navi Chat): wie viele Flugpunkte kennt das Addon, und haette ein unbekannter Flug viel gebracht
    local nfp = 0
    for _ in pairs((ns.db and ns.db.knownFP) or {}) do nfp = nfp + 1 end
    parts[#parts + 1] = ("Flugpunkte bekannt %d"):format(nfp)
    if nv.fpTip then parts[#parts + 1] = ("Flug Tipp %d s schneller ueber %s nach %s"):format(math.floor(nv.fpTip.save), tostring(nv.fpTip.at and nv.fpTip.at.name), tostring(nv.fpTip.to and nv.fpTip.to.name)) end
    -- 19.39: Ruhestein Stand (warum er dabei ist oder nicht)
    local nb2 = naviBind
    if nb2 then
      parts[#parts + 1] = ("Ruhestein %s, Ort %s (%s)%s"):format(not nb2.stone and "nicht im Gepaeck" or ((nb2.left or 0) > 0 and ("Abklingzeit " .. math.floor(nb2.left) .. " s") or "bereit"),
        nb2.known and "bekannt" or "unbekannt", tostring(nb2.home), (ns.db and ns.db.bindInn) and (" Karte " .. tostring(ns.db.bindInn[1])) or "")
    end
    ns.TestLog("NAVI", ("Ziel %s (Karte %s %.3f,%.3f), ca %d s: %s"):format(tostring(nv.dest.name), tostring(nv.dest.map), nv.dest.x, nv.dest.y, math.floor(nv.total), table.concat(parts, ", ")))
    -- 20.3n (Na, Punkt 26 / Ge): Karte und Koordinaten jedes Abschnitts, damit man den Weg ueber das Netz nachrechnen kann
    local wl = {}
    for wi, lg in ipairs(nv.legs) do
      if wi > 14 then wl[#wl + 1] = "..."; break end
      local a = lg.at
      wl[#wl + 1] = (a and a.x and a.y) and ("%d %s %s %.3f,%.3f"):format(wi, tostring(lg.kind), tostring(a.map), a.x, a.y) or (wi .. " " .. tostring(lg.kind))
    end
    ns.TestLog("NAVI_WEG", table.concat(wl, " | "))
  end
  if hidden then
    if ns.Draw then ns.Draw() end
    if ns.RefreshHud then pcall(ns.RefreshHud) end
  else
    SetTarget()
  end
  if ns.MapButtonText then ns.MapButtonText() end
end

-- Navi wie ein Profil (17.5, Wunsch Sascha): ausblenden, die Route laeuft weiter, das Navi bleibt im Menue
function ns.NaviHide(quiet)
  local nv = ns.navi
  if not nv or nv.hidden then return end
  nv.hidden = true
  if ns.db and ns.db.naviDest then ns.db.naviDest.hidden = true end
  if ns.serviceTarget == nv.st then ns.serviceTarget = nil end
  if not quiet then ns.Print(TR"Navi ausgeblendet, Pfeil auf der Route. Im Menü unter Route kommt es wieder.") end
  if ns.TestLog then ns.TestLog("NAVI", "ausgeblendet") end
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then pcall(ns.RefreshHud) end
  if ns.MapButtonText then ns.MapButtonText() end
end
function ns.NaviShow()
  local nv = ns.navi
  if not nv then return end
  nv.hidden = nil
  if ns.db and ns.db.naviDest then ns.db.naviDest.hidden = nil end
  if ns.TestLog then ns.TestLog("NAVI", "wieder eingeblendet") end
  -- weit weg vom Abschnitt (in der Zwischenzeit woanders hin gelaufen): neu rechnen
  local P = Here()
  local lg = nv.legs[nv.cur]
  if P and lg and lg.at and (P.cont ~= lg.at.cont and P.cont ~= lg.to.cont) then
    local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
    if nn then Start(nn, true); return end
  end
  -- 20.3k (K Log Z.7010, Ad FRA 21:40): ein ausgeblendetes Navi plant nicht neu (Tick bricht ab). Haben sich die Flugpunkte
  -- seitdem geaendert (Login, Flugkarte), jetzt einmal neu planen, sonst fehlt der Flug im alten Plan
  if ns.db and (ns.db.knownFPRev or 0) ~= (nv.fpRev or 0) and FPSig() ~= nv.fpSig then
    local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
    if nn then
      if ns.TestLog then ns.TestLog("NAVI", "neu geplant beim Einblenden (Flugpunkte geaendert)") end
      Start(nn, true); return
    end
  end
  SetTarget()
  if ns.MapButtonText then ns.MapButtonText() end
end
function ns.NaviLabel()
  local nv = ns.navi
  return nv and ((TR"Navi: %s"):format(nv.dest.name or "?")) or nil
end

function ns.NaviTo(map, x, y, name)
  local nv, err = ns.NaviPlan(map, x, y, name)
  if not nv then ns.Print(TR"Navi: " .. (err or "?")); return end
  Start(nv, nil, nil, true)
end

-- 20.3h (Na, test_203g Punkt 6/8/13): Pfeil zu einem Ziel von einer Seite (Questgeber, Dungeon Eingang, Farmgebiet, Buch).
-- Mit dem Navi: Weg mit Linie auf Karte und Minimap, Fluege, Schiff und Zeppelin, und die Leveling Route bleibt unberuehrt
-- (Navi ausblenden = Pfeil wieder auf der Route). Geht das Navi nicht (kein Weg, Daten fehlen): wie vorher nur der Pfeil.
-- Rueckgabe true = Navi fuehrt, false = nur Pfeil
function ns.ZielNavi(map, x, y, name, kind)
  if map and x and y and ns.db and ns.db.zielNavi ~= false then
    local ok, nv = pcall(ns.NaviPlan, map, x, y, name)
    if ok and nv then
      nv.zielSeite = true -- 20.3y (K 17:22 P6): Karten Knopf blendet es nur aus (kommt per Klick wieder), beendet es nicht
      Start(nv, nil, nil, true)
      if ns.TestLog then ns.TestLog("NAVI", ("Ziel von Seite (%s): %s"):format(tostring(kind), tostring(name))) end
      return true
    end
    if ns.TestLog then ns.TestLog("NAVI", ("Ziel von Seite (%s) ohne Navi: %s"):format(tostring(kind), tostring(ok and "kein Weg" or nv))) end
  end
  ns.serviceTarget = { map = map, x = x, y = y, name = name, kind = kind }
  if ns.Draw then ns.Draw() end
  return false
end

-- 20.3h (Na, test_203g Punkt 13): Reisezeit zu einem Ziel in Sekunden (Laufen, Flug, Schiff, Zeppelin, wie das Navi), ohne
-- das Navi zu starten. Ein Aufruf ist ein ganzer Navi Plan, darum nur fuer wenige Kandidaten. nil, wenn kein Weg.
function ns.NaviEta(map, x, y, name)
  local ok, nv = pcall(ns.NaviPlan, map, x, y, name)
  if ok and nv then return nv.total, nv end
  return nil
end

-- 20.4 (Na, K 19:33 / 19:02): Schnittstelle fuer Zusatz Addons (Farm Addon) und Ad: eine kleine, stabile Tabelle statt vieler ns Namen.
-- Zugriff von aussen: KeineZeitLevelingGuide_API.Navi (Global, wird hier angelegt, falls Core es nicht schon tat), im Hauptaddon ns.API.Navi.
-- Alles ruft erst beim Aufruf nach (spaetere Neudefinition von ns.X bleibt wirksam). Fehlt das Navi, geben die Funktionen nil/false.
--   version                         1
--   GoTo(map, x, y, name, kind)  -> true = Navi fuehrt (Linie, Flug, Schiff), false = nur Pfeil          (= ns.ZielNavi)
--   Eta(map, x, y, name)         -> Sekunden, Plan | nil (kein Weg)                                         (= ns.NaviEta)
--   Stop()                          Navi beenden, Pfeil wieder auf der Route
--   Hide() / Show()                 Navi ausblenden / einblenden (Route laeuft weiter)
--   Active() -> true, wenn ein Navi sichtbar fuehrt;  Dest() -> { map, x, y, name } | nil
--   Walk(a, b) -> Yards zu Fuss (Wegnetz) zwischen {map,x,y} und {map,x,y} (Listen oder map/x/y Felder) | nil   (ns.WalkYards)
ns.API = ns.API or {}
ns.API.Navi = {
  version = 1,
  GoTo = function(...) if ns.ZielNavi then return ns.ZielNavi(...) end return false end,
  Eta = function(...) if ns.NaviEta then return ns.NaviEta(...) end end,
  Stop = function(...) if ns.NaviStop then return ns.NaviStop(...) end end,
  Hide = function(...) if ns.NaviHide then return ns.NaviHide(...) end end,
  Show = function(...) if ns.NaviShow then return ns.NaviShow(...) end end,
  Active = function() local nv = ns.navi; return nv ~= nil and not nv.hidden end,
  Dest = function() local nv = ns.navi; return nv and nv.dest or nil end,
  Walk = function(a, b)
    if not (ns.WalkYards and ns.MapWorld and a and b) then return nil end
    local ca, ax, ay = ns.MapWorld(a[1] or a.map, a[2] or a.x, a[3] or a.y)
    local cb, bx, by = ns.MapWorld(b[1] or b.map, b[2] or b.x, b[3] or b.y)
    if not (ca and cb) then return nil end
    return ns.WalkYards({ cont = ca, wx = ax, wy = ay, map = a[1] or a.map, x = a[2] or a.x, y = a[3] or a.y },
      { cont = cb, wx = bx, wy = by, map = b[1] or b.map, x = b[2] or b.x, y = b[3] or b.y })
  end,
}
if _G.KeineZeitLevelingGuide_API == nil then _G.KeineZeitLevelingGuide_API = ns.API end

-- 1.3p (P98, S 15:44 "Navi soll den Weg nachfuehren"): Grenzen fuer das Nachfuehren, keine Orte fest
-- 1.3v (P105 Punkt 4): verpasst = Abfahrt war hoechstens WIN_S weg und springt um mehr als JUMP_S nach oben
-- 1.3zh (Pr 08:30 schiff_lang: 6 von 14 verpasst nicht erkannt): nicht mehr nur Sprung zwischen zwei nahen Proben, sondern
-- ueber die Uhr: die letzte Probe (hoechstens WIN_S vor der Abfahrt) sagte eine Abfahrt voraus, die jetzt (LATE_S Toleranz)
-- vorbei ist, und jetzt wartet man wieder mehr als JUMP_S. So zaehlt es auch, wenn Proben fehlen (zb am Steg kurz als an
-- Bord erkannt)
local MISS = { WIN_S = 120, JUMP_S = 60, LATE_S = 2, BOARD_WAIT_S = 60, AWAY_YD = 700, BOAT_MOVE_YD = 150,
  -- 1.3zt (Pr 21:48 verpasst_zeilen, 7 Faelle "doch an Bord" ohne einzusteigen): Weg und Schiff Erkennung zaehlen nur, wenn du bei
  -- der Abfahrt am Steg oder Turm warst (DOCK_YD), und die Schiff Erkennung muss BOAT_HOLD_S am Stueck gelten (ein Positions
  -- Sprung oder kurzes schnelles Reiten reicht nicht). Ladebildschirm und Flug zaehlen immer
  DOCK_YD = 80, BOAT_HOLD_S = 10 }
-- 1.3zo (P117, S 15:24: Zeppelin "verpasst", obwohl S drauf war): "verpasst" erst nach MISS.BOARD_WAIT_S melden. Kommt in
-- der Zeit ein Ladebildschirm, steht das Spiel auf Schiff/Zeppelin (WalkOnBoat) oder auf einem Flug, warst du drauf: dann
-- nichts melden. Gilt fuer alle Zeppeline, Schiffe und die Tiefenbahn
local missPend
local missLoads = 0
do
  local lf = CreateFrame("Frame")
  ns.RegEv(lf, "PLAYER_ENTERING_WORLD")
  ns.RegEv(lf, "LOADING_SCREEN_ENABLED")
  lf:SetScript("OnEvent", function() missLoads = missLoads + 1 end)
end
local function MissDefer(what, report)
  if missPend then return end
  -- 1.3zp (Pr 17:27 schiff_lang2: 2 verpasst nicht erkannt): an Bord heisst jetzt Ladebildschirm, Flug, weit weg von hier
  -- (MISS.AWAY_YD in der Wartezeit, das schafft man zu Fuss oder beritten nicht) oder anderer Kontinent. "Auf dem Schiff"
  -- (WalkOnBoat) zaehlt nur, wenn du dich dabei auch bewegt hast (MISS.BOAT_MOVE_YD), sonst stimmte es am Steg falsch
  local p0 = Here()
  local near = true
  if p0 and ns.NearDock then near = ns.NearDock(p0.map, p0.x, p0.y, MISS.DOCK_YD) and true or false end
  missPend = { t = GetTime(), loads = missLoads, what = what, report = report, p0 = p0, near = near }
  if ns.TestLog then ns.TestLog("NAVI", ("Abfahrt vorbei: %s, warte %d s, ob du an Bord bist"):format(tostring(what), MISS.BOARD_WAIT_S)) end
end
local function MissPendTick()
  local m = missPend
  if not m then return end
  local P1 = Here()
  -- erst spaet am Steg angekommen (zb gleich nach der Abfahrt): ab dann zaehlt auch Weg und Schiff
  if not m.near and P1 and ns.NearDock and ns.NearDock(P1.map, P1.x, P1.y, MISS.DOCK_YD) then m.near = true; m.p0 = P1 end
  local moved = (m.p0 and P1) and ((P1.cont ~= m.p0.cont) and math.huge or D(P1, m.p0)) or 0
  local now = GetTime()
  local wob = ns.WalkOnBoat and ns.WalkOnBoat()
  if wob then m.boatT = m.boatT or now else m.boatT = nil end
  local loads = missLoads ~= m.loads
  local taxi = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  local away = m.near and moved > MISS.AWAY_YD
  local boat = m.near and m.boatT and now - m.boatT >= MISS.BOAT_HOLD_S and moved > MISS.BOAT_MOVE_YD
  if loads or taxi or away or boat then
    missPend = nil
    if ns.TestLog then ns.TestLog("NAVI", ("doch an Bord, nicht verpasst: %s (%s)"):format(tostring(m.what),
      loads and "Ladebildschirm" or taxi and "Flug" or away and ("%d yd weg"):format(math.floor(moved)) or "auf dem Schiff")) end
    return
  end
  if GetTime() - m.t < MISS.BOARD_WAIT_S then return end
  missPend = nil
  pcall(m.report)
end
local function MissHit(st, w, key)
  local now = GetTime()
  local hit = false
  -- andere Fahrt (anderer Abschnitt oder Schritt): neu anfangen, sonst zaehlt die alte Probe
  if st.key ~= key then st.key, st.w0, st.at = key, nil, nil end
  if w and st.w0 and st.at and st.w0 <= MISS.WIN_S and now - st.at >= st.w0 - MISS.LATE_S and w > MISS.JUMP_S and w > st.w0 then hit = true end
  st.w0, st.at = w, now
  return hit
end
local NV = {
  OFF_YD = 150,        -- so weit neben der Strecke zum naechsten Wegpunkt gilt als vom Weg abgekommen
  OFF_S = 10,          -- so lange muss man daneben sein
  CHECK_S = 120,       -- so oft leise pruefen, ob es einen klar besseren Weg gibt
  CHECK_CITY_S = 8,    -- 1.3zo (P118, S 15:32): in Hauptstaedten so oft (verwinkelt, ein Ausgang aendert viel)
  CHECK_SLOW_MS = 40,  -- dauert die Pruefung laenger (Rechner langsam), naechste Pruefung erst nach doppelter Zeit
  BETTER_S = 60,       -- neuer Weg muss mindestens so viel schneller sein
  BETTER_PCT = 0.15,   -- und mindestens so viel Anteil der Restzeit
  REPLAN_GAP_S = 30,   -- hoechstens so oft neu rechnen
}
ns.NAVI_NV = NV
local function InFight() return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) end
-- Restzeit vom jetzigen Navi: laufender Abschnitt grob (Luftlinie mal Umweg), dann die geplanten Zeiten der naechsten
local function RestSec(nv, P)
  local lg = nv.legs[nv.cur]
  if not lg then return 0 end
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local TV = ns.TRAVEL or { PATH = 1.2 }
  local left = lg.sec or 0
  if (lg.kind == "walk") and P and lg.to and P.cont == lg.to.cont then left = D(P, lg.to) * (TV.PATH or 1.2) / math.max(1, speed) end
  for k = nv.cur + 1, #nv.legs do left = left + (nv.legs[k].sec or 0) end
  return left
end
-- neu rechnen mit Grund im Log (NAVI), nur wenn wirklich anders oder besser
local function ReplanWhy(nv, why, onlyBetter, rest)
  if GetTime() - lastPlan < NV.REPLAN_GAP_S then return false end
  if not onlyBetter then lastPlan = GetTime() end
  local t0 = debugprofilestop and debugprofilestop() or 0
  local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
  local ms = debugprofilestop and (debugprofilestop() - t0) or 0
  if ms > NV.CHECK_SLOW_MS then nv.checkGap = NV.CHECK_S * 2 else nv.checkGap = nil end
  if not nn then
    if ns.TestLog then ns.TestLog("NAVI", ("neu rechnen (%s): kein Weg gefunden, alter Weg bleibt"):format(why)) end
    return false
  end
  if onlyBetter then
    local gain = (rest or 0) - (nn.total or 0)
    if gain < math.max(NV.BETTER_S, (rest or 0) * NV.BETTER_PCT) then return false end
    lastPlan = GetTime()
    why = ("%s, %d s schneller (%d statt %d s)"):format(why, math.floor(gain), math.floor(nn.total or 0), math.floor(rest or 0))
    ns.Print((TR"Navi: schnellerer Weg gefunden, ca %s"):format(ns.Clock and ns.Clock(nn.total) or math.floor(nn.total) .. "s"))
  else
    ns.Print(TR"Navi: neuer Weg ab hier")
  end
  if ns.TestLog then ns.TestLog("NAVI", ("neu berechnet ab hier, Grund: %s (%d ms)"):format(why, math.floor(ms))) end
  Start(nn, true)
  return true
end

local function Replan()
  local nv = ns.navi
  if not nv or GetTime() - lastPlan < 30 then return end
  lastPlan = GetTime()
  local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
  if nn then
    ns.Print(TR"Navi: neuer Weg ab hier")
    if ns.TestLog then ns.TestLog("NAVI", "neu berechnet ab hier") end
    Start(nn, true)
  end
end

local function Tick()
  local nv = ns.navi
  if not nv then return end
  -- 1.2n (P76): Navi fuer einen weiten Route Schritt endet, sobald die Route einen anderen Schritt hat
  if nv.routeIdx then
    local o = ns.db and ns.db.optMode and ns.db.opt
    if not (o and (o.idx or 1) == nv.routeIdx) then
      if ns.TestLog then ns.TestLog("NAVI", "Route Schritt gewechselt, Navi fuer den Schritt beendet") end
      Stop()
      return
    end
  end
  if nv.hidden then return end
  -- Pfeil Ziel wurde ersetzt oder weggeklickt (Mini Fenster, Feierabend, Haendler ...): Navi ausblenden, nicht wegwerfen
  if ns.serviceTarget ~= nv.st then
    -- 20.3n (Code Pruefung Da Nr 3, K 23:15): ein automatischer Hinweis (Core "missed": noch nicht abgegeben/angenommen) setzt
    -- ein eigenes Pfeil Ziel. Das beendet das Navi nicht: Navi wartet, danach kommt sein Ziel wieder
    local o = ns.serviceTarget
    if o and o.kind == "missed" then
      if not nv.wartet then
        nv.wartet = true
        if ns.TestLog then ns.TestLog("NAVI", "wartet (Hinweis noch offen)") end
      end
      return
    end
    if nv.wartet and not o then
      nv.wartet = nil
      ns.serviceTarget = nv.st
      if ns.TestLog then ns.TestLog("NAVI", "weiter nach Hinweis") end
      if ns.Draw then ns.Draw() end
      if ns.RefreshHud then pcall(ns.RefreshHud) end
      return
    end
    ns.NaviHide(true)
    if ns.TestLog then ns.TestLog("NAVI", "ausgeblendet (Pfeil Ziel geaendert)") end
    return
  end
  nv.wartet = nil
  local P = Here()
  local onTaxi = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  -- 1.2j (P66, Ka 17:06): auf Schiff oder Zeppelin nicht neu planen (die Position auf dem Transport ist kein Startort)
  local onBoat = not onTaxi and ns.WalkOnBoat and ns.WalkOnBoat()
  if not P then return end
  -- 19.9 (Code Pruefung): beim Planen rechnete der Zonen Graph noch (zb gemerktes Navi nach dem Einloggen), der Plan
  -- ist nur vorlaeufig. Sobald der Graph fertig ist, einmal still neu planen
  if nv.busy and not onTaxi and not onBoat then
    local K = ns.Karte
    if not (K and K.Busy and K.Busy()) then
      nv.busy = nil
      local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
      if nn then
        if ns.TestLog then ns.TestLog("NAVI", "neu geplant (Zonen Wege jetzt fertig)") end
        Start(nn, true)
        return
      end
    end
  end
  -- 19.32 (Navi Chat): neue Flugpunkte gelernt (Flugkarte offen, gelandet): einmal still neu planen, nicht in der Luft
  if not onTaxi and not onBoat and ns.db and (ns.db.knownFPRev or 0) ~= (nv.fpRev or 0) then
    nv.fpRev = ns.db.knownFPRev or 0
    local sig = FPSig()
    -- Flugkarte nur geoeffnet, nichts Neues: nicht neu planen (20.3z3, P7)
    if sig ~= nv.fpSig then
      nv.fpSig = sig
      local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
      if nn then
        if ns.TestLog then ns.TestLog("NAVI", "neu geplant (Flugpunkte gelernt)") end
        local better = nn.total < nv.total - 30
        Start(nn, true)
        if better then ns.Print((TR"Navi: neuer Weg mit deinen Flugpunkten, ca %s"):format(ns.Clock and ns.Clock(nn.total) or math.floor(nn.total) .. "s")) end
        return
      end
    end
  end
  -- schon bei einem spaeteren Abschnitt angekommen? (auch wenn einer uebersprungen wurde)
  for k = #nv.legs, nv.cur, -1 do
    local lg = nv.legs[k]
    local e = lg.to
    if not onTaxi and P.cont == e.cont and D(P, e) < (REACH[lg.wp and "wp" or lg.kind] or 25) then
      if k == #nv.legs then
        if ns.TestLog then ns.TestLog("NAVI", ("Ziel erreicht nach %d s (geplant %d s)"):format(math.floor(GetTime() - nv.made), math.floor(nv.total))) end
        Stop(TR"Navi: Ziel erreicht, weiter mit der Route.")
        return
      end
      nv.cur = k + 1
      if ns.TestLog then ns.TestLog("NAVI", ("Schritt %d/%d: %s"):format(nv.cur, #nv.legs, nv.legs[nv.cur].text)) end
      SetTarget()
      return
    end
  end
  local lg = nv.legs[nv.cur]
  -- 19.32 (Navi Chat): Teleport oder Ruhestein benutzt, aber nicht genau am geplanten Ort angekommen (Ankunft nur
  -- geschaetzt): nicht zurueck zum Startort zeigen, sondern ab hier neu planen
  -- 1.2i (P68, K 17:00, S "Ruhestein wird dauernd eingeblendet"): beim Ruhestein nur, wenn er seit dem Plan wirklich benutzt
  -- wurde (Zauber 8690 oder 556, ns.portUsedAt aus Travel.lua). Vorher reichte es, 300 yd vom Startort weg zu laufen, dann
  -- plante das Navi alle 45 s neu, wieder mit Ruhestein als Schritt 1
  local jumped = lg.kind == "portal" or (ns.portUsedAt and ns.portUsedAt >= (nv.made or 0))
  if (lg.kind == "portal" or lg.kind == "hearth") and jumped and not onTaxi and lg.at and (P.cont ~= lg.at.cont or D(P, lg.at) > 300) then
    -- Pruefer A3: findet die Planung von hier keinen Weg, nicht jede Sekunde neu probieren
    if nv.jumpTry and GetTime() - nv.jumpTry < 20 then return end
    nv.jumpTry = GetTime()
    local nn = ns.NaviPlan(nv.dest.map, nv.dest.x, nv.dest.y, nv.dest.name)
    if nn then
      if ns.TestLog then ns.TestLog("NAVI", ("neu geplant nach %s (Ankunft %d yd neben dem geplanten Ort)"):format(lg.kind,
        (lg.to and P.cont == lg.to.cont) and math.floor(D(P, lg.to)) or -1)) end
      Start(nn, true)
    end
    return
  end
  -- Wegpunkt: schon daran vorbei (naeher am naechsten Schritt als der Wegpunkt selbst), dann weiter
  local nx = nv.legs[nv.cur + 1]
  if lg.wp and nx and not onTaxi and P.cont == lg.at.cont and nx.at.cont == P.cont and D(P, lg.at) < 90
    and D(P, nx.at) < D(lg.at, nx.at) - 5 then
    nv.cur = nv.cur + 1
    if ns.TestLog then ns.TestLog("NAVI", ("Schritt %d/%d: %s (Wegpunkt passiert)"):format(nv.cur, #nv.legs, nv.legs[nv.cur].text)) end
    SetTarget()
    return
  end
  -- direkt beim Flugmeister abgeflogen: Laufen ist fertig
  if onTaxi and lg.kind == "walk" and nv.legs[nv.cur + 1] and nv.legs[nv.cur + 1].kind == "fly" then
    nv.cur = nv.cur + 1
    SetTarget()
    return
  end
  -- 20.3y: Flug laeuft (Pfeil zeigte noch zum Flugmeister): Pfeil Ziel auf den Landeort umstellen
  if onTaxi and lg.kind == "fly" and nv.st and nv.st.fm then
    SetTarget()
    return
  end
  -- ganz woanders gelandet (anderer Kontinent als dieser Abschnitt): neu rechnen
  if not onTaxi and not onBoat and P.cont ~= lg.at.cont and P.cont ~= lg.to.cont then Replan(); return end
  -- 1.3v (P105 Punkt 4, S 03:05): Schiff oder Zeppelin verpasst (Abfahrt springt von fast 0 auf fast einen ganzen Umlauf,
  -- du bist nicht drauf): sofort melden und neu rechnen, dann nimmt das Navi die naechste Abfahrt oder einen anderen Weg
  -- (Flug, Ruhestein, anderer Hafen), was schneller ist. Fuer alle Verbindungen aus Travel.lua
  MissPendTick()
  if lg.kind == "ride" and lg.exact and not onBoat and not onTaxi then
    local w = LiveDepart(lg.l, lg.side, lg.depart)
    nv.rideMiss = nv.rideMiss or {}
    if MissHit(nv.rideMiss, w, lg) then
      local nv0, text0 = nv, lg.text
      MissDefer(text0, function()
        local w2 = LiveDepart(lg.l, lg.side, lg.depart) or w
        local C = ns.Clock or function(x) return tostring(math.floor(x)) .. "s" end
        ns.Print((TR"Verpasst, nächste Abfahrt in %s. Prüfe andere Wege ..."):format(C(w2)))
        if ns.TestLog then ns.TestLog("NAVI", ("verpasst: %s, nächste Abfahrt in %d s"):format(tostring(text0), math.floor(w2))) end
        lastPlan = 0
        if ns.navi == nv0 then ReplanWhy(nv0, "Schiff oder Zeppelin verpasst") end
      end)
    end
  end
  -- 1.3p (P98): Weg nachfuehren. Nicht im Kampf, nicht im Flug, nicht auf Schiff oder Zeppelin
  if not onTaxi and not onBoat and not InFight() and not (ns.UwHold and ns.UwHold("navi_weg")) then
    local now = GetTime()
    nv.p0 = nv.p0 or P
    -- 1. deutlich vom Weg abgekommen (Abstand zur Strecke vom letzten zum naechsten Wegpunkt, ein paar Sekunden lang)
    if lg.kind == "walk" and lg.to and P.cont == lg.to.cont then
      local a = (nv.cur > 1 and nv.legs[nv.cur - 1].to) or nv.p0
      local off = SegD(P, a, lg.to)
      if off ~= math.huge and off > NV.OFF_YD then
        nv.offSince = nv.offSince or now
        if now - nv.offSince >= NV.OFF_S then
          nv.offSince = nil
          if ReplanWhy(nv, ("vom Weg abgekommen, %d yd neben der Strecke"):format(math.floor(off))) then return end
        end
      else
        nv.offSince = nil
      end
    end
    -- 2. ab und zu leise pruefen, ob es jetzt einen klar besseren Weg gibt (neuer Flugpunkt, Schiff faehrt bald, Ruhestein bereit)
    nv.checkAt = nv.checkAt or now
    local KC = ns.Karte
    local inCity = KC and KC.InCity and P and P.map and P.x and KC.InCity(P.map, P.x, P.y)
    if now - nv.checkAt >= (nv.checkGap or (inCity and NV.CHECK_CITY_S) or NV.CHECK_S) then
      nv.checkAt = now
      local K = ns.Karte
      if not (K and K.Busy and K.Busy()) then
        if ReplanWhy(nv, "Pruefung besserer Weg", true, RestSec(nv, P)) then return end
      end
    end
  end
  -- Abfahrt im Text mitzaehlen
  if lg.kind == "ride" and lg.exact then
    nv.st.name = LegText(nv, nv.cur)
  end
end

------------------------------------------------------------
-- Strecke fuer die Karte: Laufen folgt den Wegen (gleiche Wegsuche wie der Pfeil, Path.lua), 17.5
------------------------------------------------------------
-- fuer Core.lua DrawNavi: Linie fuer Abschnitt i, Startpunkt { map, x, y } (beim jetzigen Abschnitt: du)
-- Ergebnis wird gemerkt (Wegsuche ist teuer, die Karte zeichnet beim Ziehen oft neu)
function ns.NaviLegPts(i, from)
  local nv = ns.navi
  local lg = nv and nv.legs[i]
  if not (lg and from) then return nil end
  if lg.kind ~= "walk" and lg.kind ~= "ride" then return nil end
  local goal = (lg.kind == "ride") and lg.at or lg.to
  local c = lg.pc
  local now = GetTime()
  -- 19.9: neue Zonen Wege (Graph fertig gerechnet) machen die gemerkte Linie ungueltig
  local K = ns.Karte
  local xg = K and K.XGenNow and K.XGenNow() or 0
  if c and c.xg ~= xg then c = nil end
  if c and c.goal == goal and math.abs(c.fx - from[2]) < 0.004 and math.abs(c.fy - from[3]) < 0.004 and c.fm == from[1] then return c.pts end
  if c and i == nv.cur and now - c.t < 2 then return c.pts end
  -- 19.32 (Navi Chat): nicht mehr sofort suchen, sondern in die Warteschlange (verteilt auf mehrere Bilder). Bis dahin
  -- die alte Linie (wenn es eine gibt), sonst zeichnet die Karte gerade bis zum Punkt
  ns.NaviQueue(nv, i, lg, goal, from, xg)
  return c and c.pts or nil
end

-- Warteschlange fuer Linien: pro Bild so viele Wegsuchen, wie in BUDGET ms passen (mindestens eine), danach die Karte
-- einmal neu zeichnen. Eine einzelne Wegsuche bleibt am Stueck (Path.lua), darum hoechstens eine, wenn sie lang war.
local queue, qset, qFrame = {}, {}, nil
local function Budget() return (ns.db and ns.db.slowPC) and 4 or 8 end
local function QStep()
  local nv = ns.navi
  if not nv or #queue == 0 then queue, qset = {}, {}; if qFrame then qFrame:Hide() end; return end
  local t0 = debugprofilestop and debugprofilestop() or 0
  local did = 0
  while #queue > 0 do
    local q = table.remove(queue, 1)
    qset[q.key] = nil
    -- Navi inzwischen neu geplant oder beendet: weglassen
    if q.nv == nv and nv.legs[q.i] == q.lg then
      local pts = WalkPts({ map = q.from[1], x = q.from[2], y = q.from[3] }, q.goal)
      q.lg.pc = { goal = q.goal, fm = q.from[1], fx = q.from[2], fy = q.from[3], pts = pts, t = GetTime(), xg = q.xg }
      did = did + 1
    end
    if not debugprofilestop or debugprofilestop() - t0 > Budget() then break end
  end
  if did > 0 and ns.DrawSoon then ns.DrawSoon() end
  if #queue == 0 and qFrame then qFrame:Hide() end
end
function ns.NaviQueue(nv, i, lg, goal, from, xg)
  local key = tostring(i) .. ":" .. tostring(lg)
  if qset[key] then
    -- schon in der Schlange: Startpunkt nachfuehren (du laeufst weiter)
    for _, q in ipairs(queue) do if q.key == key then q.from, q.goal, q.xg = from, goal, xg end end
    return
  end
  qset[key] = true
  local q = { key = key, nv = nv, i = i, lg = lg, goal = goal, from = from, xg = xg }
  -- der jetzige Abschnitt zuerst (dort schaut man hin)
  if i == nv.cur then table.insert(queue, 1, q) else queue[#queue + 1] = q end
  if not qFrame then
    qFrame = CreateFrame("Frame")
    qFrame:SetScript("OnUpdate", function() pcall(QStep) end)
  end
  qFrame:Show()
end
function ns.NaviQueueLen() return #queue end

-- Mini Fenster: statt dem Routen Schritt der Navi Abschnitt (17.5, Wunsch Sascha)
local NCOL = { walk = { 1, 0.82, 0 }, fly = { 0.45, 0.85, 1 }, ride = { 0.3, 0.5, 1 }, hearth = { 0.8, 0.5, 1 }, portal = { 0.8, 0.5, 1 } }
local KIND = { walk = TR"Navi: laufen", fly = TR"Navi: fliegen", ride = TR"Navi: Schiff / Zeppelin", hearth = TR"Navi: Ruhestein", portal = TR"Navi: Teleport" }
-- 19.32 (Navi Chat, Sascha: "minimap und map wege sollen gleich sein"): Punkte fuer die Minimap Linie, solange das
-- Navi fuehrt. Das erste Stueck bis zum Pfeil Ziel zeichnet MiniRoute selbst (Pfeil Weg), danach die naechsten Navi
-- Abschnitte mit den gleichen Linien wie auf der Weltkarte (lg.pc, nichts neu gerechnet). Bei Flug, Schiff, Teleport und
-- Ruhestein endet die Linie dort. Ergebnis: Liste { x, y, col, target, path } auf der Karte mapID, oder nil ohne Navi
function ns.NaviMiniPts(mapID, maxLegs)
  local nv = ns.navi
  if not (nv and not nv.hidden and nv.legs and nv.legs[nv.cur] and mapID) then return nil end
  local out = {}
  local function Add(z, x, y, kind, target, path)
    if not (z and x and y) then return false end
    if z ~= mapID then
      if not ns.ToMap then return false end
      x, y = ns.ToMap(z, x, y, mapID)
      if not x then return false end
    end
    out[#out + 1] = { x, y, kind = "navi", col = NCOL[kind] or NCOL.walk, target = target, path = path }
    return true
  end
  for i = nv.cur, math.min(#nv.legs, nv.cur + (maxLegs or 4)) do
    local lg = nv.legs[i]
    if i > nv.cur and lg.kind == "walk" and lg.pc and lg.pc.pts then
      for _, q in ipairs(lg.pc.pts) do if not Add(q[1], q[2], q[3], "walk", false, true) then return out end end
    end
    local tg = (lg.kind == "walk" or lg.kind == "fly") and lg.to or lg.at
    if not (tg and Add(tg.map, tg.x, tg.y, lg.kind, i == nv.cur, false)) then return out end
    if lg.kind ~= "walk" then return out end
  end
  return out
end

-- 19.33 (Saschas Antwort f20, Koordination 08:47): "Klickbutton um den Ruhestein zu benutzen". Den Knopf unter dem
-- Pfeil gibt es seit 19.31 in QuestItems.lua (sicherer Knopf, im Kampf wird nichts umgebaut), aber nur, wenn die Route
-- den Ruhestein will. Hier das Gleiche fuer den aktuellen Navi Abschnitt, gleiche Rueckgabe wie HearthWanted dort:
-- Ruhestein (Gegenstand 6948), Astraler Rueckruf (Zauber 556) oder Magier Teleport (Zauber des Abschnitts).
-- nil, wenn das Navi aus, ausgeblendet oder der Pfeil gerade nicht beim Navi ist.
function ns.NaviHearthWanted()
  local nv = ns.navi
  if not (nv and nv.legs) or nv.hidden or ns.serviceTarget ~= nv.st then return nil end
  local lg = nv.legs[nv.cur]
  if not lg then return nil end
  local known = IsSpellKnown or IsPlayerSpell
  -- Pruefer 09:08 LEICHT 2: zuerst C_Item.GetItemCount, dann das globale (wie QuestItems.lua)
  local gic = (C_Item and C_Item.GetItemCount) or ns.Api.GetItemCount
  local function Has(id)
    if not gic then return false end
    local ok, n = pcall(gic, id)
    return ok and (n or 0) > 0
  end
  if lg.kind == "hearth" then
    if lg.recall and known and known(556) then
      return { spell = 556, icon = "Interface\\Icons\\Spell_Nature_AstralRecall", quest = lg.text, hearth = true, key = "NR" }
    end
    if Has(6948) then
      local icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(6948)) or "Interface\\Icons\\INV_Misc_Rune_01"
      return { id = 6948, link = "item:6948", icon = icon, quest = lg.text, hearth = true, key = "NH" }
    end
  -- Pruefer 09:08 LEICHT 1: Teleport nur mit Rune der Teleportation (17031, wie RUNE in NaviFlug.lua), sonst Fehler beim Klick
  elseif lg.kind == "portal" and lg.spell and known and known(lg.spell) and Has(17031) then
    local icon = (ns.Api.GetSpellTexture and ns.Api.GetSpellTexture(lg.spell)) or "Interface\\Icons\\Spell_Arcane_TeleportOrgrimmar"
    return { spell = lg.spell, icon = icon, quest = lg.text, hearth = true, key = "NP" .. lg.spell }
  end
  return nil
end

------------------------------------------------------------
-- 1.3s (P100, S 18:22 und 18:25): Abfahrt von Zeppelin oder Schiff vorausschauend zeigen. Nur wenn hoechstens
-- DP.MAX_QUEST Quest Schritte davor liegen (S will sehen, ob er vorher noch zur Bank oder zum Haendler kann).
-- Zeile "danach Zeppelin nach X, fährt in m:ss, du brauchst ca m:ss, Puffer m:ss". Alle Verbindungen aus den Daten
-- (Travel.lua LINKS). Ergebnis kurz gemerkt (DP.CACHE_S), damit das Mini Fenster nicht jede Sekunde sucht
------------------------------------------------------------
local DP = { MAX_QUEST = 1, LOOK_STEPS = 8, CACHE_S = 2, RAW_LOG_S = 30 }
local dpCache = { at = -99, txt = nil }
local dpLogKey
function LiveDepart(l, side, fallbackAt)
  local w = ns.TravelDeparts and l and ns.TravelDeparts(l.id, side, l.idx)
  if w then return w end
  if fallbackAt then return fallbackAt - GetTime() end
end
local function DpText(name, leave, need)
  local C = ns.Clock or function(s) return tostring(math.floor(s)) .. "s" end
  local buf = leave - need
  if buf >= 0 then
    return (TR"danach %s, fährt in %s, du brauchst ca %s, Puffer %s"):format(name, C(leave), C(need), C(buf))
  end
  return (TR"danach %s, fährt in %s, du brauchst ca %s, reicht knapp nicht (nächster nehmen)"):format(name, C(leave), C(need))
end
local function DpNavi(nv, P)
  local lg = nv.legs[nv.cur]
  if not lg or lg.kind == "ride" then return nil end
  local need = RestSec(nv, P)
  -- RestSec zaehlt alle Abschnitte bis zum Ziel, hier nur bis zum Steg
  for k = #nv.legs, nv.cur + 1, -1 do
    local l2 = nv.legs[k]
    need = need - (l2.sec or 0)
    if l2.kind == "ride" then
      -- erster Steg nach dem jetzigen Abschnitt? sonst weiter zurueck
      local first = true
      for j = nv.cur + 1, k - 1 do if nv.legs[j].kind == "ride" then first = false end end
      if first then
        local leave = l2.exact and LiveDepart(l2.l, l2.side, l2.depart)
        if not leave or leave <= 0 then return nil end
        local name = (l2.text or ""):gsub("^%s+", "")
        return DpText(name, leave, math.max(0, need)), "navi " .. tostring(k)
      end
    end
  end
  return nil
end
local function DpRoute(P)
  local db = ns.db
  local o = db and db.optMode and db.opt
  local idx = o and (o.idx or 1)
  local cur = o and o.steps and o.steps[idx]
  if not cur then return nil end
  local function IsQuest(s) for _, a in ipairs(s.acts or {}) do if a.k == "A" or a.k == "O" or a.k == "T" then return true end end return false end
  local function Ride(s) for _, a in ipairs(s.acts or {}) do if a.k == "R" then return a end end end
  if cur.travel or Ride(cur) then return nil end -- der Reise Schritt zeigt seine Abfahrt selbst
  local nq = IsQuest(cur) and 1 or 0
  for k = idx + 1, math.min(#o.steps, idx + DP.LOOK_STEPS) do
    local s = o.steps[k]
    local a = Ride(s)
    if a and not a.link then return nil end
    if a then
      if nq > DP.MAX_QUEST then return nil end
      local leave = ns.TravelDeparts and ns.TravelDeparts(a.link, a.side, a.li)
      if not leave or leave <= 0 then return nil end
      local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
      local TV = ns.TRAVEL or { PATH = 1.2 }
      local toCur = 0
      if P and cur.map and ns.MapWorld then
        local c, wx, wy = ns.MapWorld(cur.map, cur.x, cur.y)
        if c and c == P.cont then toCur = math.sqrt((wx - P.wx) ^ 2 + (wy - P.wy) ^ 2) * (TV.PATH or 1.2) / math.max(1, speed) end
      end
      local need = math.max(0, (s.t or 0) - (cur.t or 0)) + toCur
      local name = ("%s %s"):format(tostring(a.kind or TR"Reise"), (TR"nach %s"):format(tostring(a.dest or a.quest or "?")))
      return DpText(name, leave, need), "route " .. tostring(k)
    end
    if IsQuest(s) then nq = nq + 1; if nq > DP.MAX_QUEST then return nil end end
  end
  return nil
end
function ns.DepartPreview()
  local now = GetTime()
  MissPendTick() -- 1.3zo (P117)
  if now - dpCache.at < DP.CACHE_S then return dpCache.txt end
  dpCache.at = now
  local P = Here()
  local nv = ns.navi
  local ok, txt, key
  -- 1.3v (P102 Punkt 2, S Log 01:56: Vorschau "Zeppelin nach Unterstadt" waehrend der Schritt selbst "Zeppelin nach
  -- Orgrimmar" war): ist der jetzige Route Schritt schon die Reise, keine Vorschau, auch nicht aus dem Navi dahin
  local db = ns.db
  local o = db and db.optMode and db.opt
  local cur = o and o.steps and o.steps[o.idx or 1]
  local curRide = cur and cur.travel
  if not curRide and cur then for _, a in ipairs(cur.acts or {}) do if a.k == "R" then curRide = true end end end
  if curRide then
    dpCache.txt = nil; dpLogKey = nil
    -- 1.3v (P105 Punkt 4): Route Reise Schritt ohne Navi und verpasst: melden, dann Navi ans Ziel der Fahrt, das den
    -- schnellsten Weg ab jetzt nimmt (naechste Abfahrt, Flug, Ruhestein, anderer Hafen)
    -- 1.3zg (Pr 08:15: Zeppelin Grom'gol verpasst, nicht erkannt): auch wenn ein Navi laeuft (zb nach einem frueheren
    -- verpasst), nur nicht, wenn dessen jetziger Abschnitt selbst die Fahrt ist (dann meldet das Navi)
    local navRide = nv and nv.legs and nv.legs[nv.cur or 1] and nv.legs[nv.cur or 1].kind == "ride"
    if not navRide and not (ns.WalkOnBoat and ns.WalkOnBoat()) then
      for _, a in ipairs(cur.acts or {}) do
        if a.k == "R" and a.link and a.link ~= "fly" and ns.TravelDeparts then
          local w = ns.TravelDeparts(a.link, a.side, a.li)
          dpCache.rideMiss = dpCache.rideMiss or {}
          if MissHit(dpCache.rideMiss, w, tostring(a.link) .. ":" .. tostring(a.side) .. ":" .. tostring(o.idx or 1) .. ":" .. tostring(o.created or 0)) then
            local o0, idx0 = o, o.idx
            MissDefer(tostring(a.kind) .. " nach " .. tostring(a.dest), function()
              -- inzwischen weiter (Schritt fertig, Route neu): nichts mehr melden
              if not (ns.db and ns.db.opt == o0 and o0.idx == idx0) then return end
              local w2 = ns.TravelDeparts(a.link, a.side, a.li) or w
              local C = ns.Clock or function(x) return tostring(math.floor(x)) .. "s" end
              ns.Print((TR"Verpasst, nächste Abfahrt in %s. Prüfe andere Wege ..."):format(C(w2)))
              if ns.TestLog then ns.TestLog("NAVI", ("verpasst (Route Schritt): %s nach %s, nächste Abfahrt in %d s"):format(tostring(a.kind), tostring(a.dest), math.floor(w2))) end
              if a.toMap and a.toX and ns.ZielNavi then pcall(ns.ZielNavi, a.toMap, a.toX, a.toY, tostring(a.dest or "?"), "route") end
            end)
          end
          break
        end
      end
    end
    -- 1.3v (P105 Punkt 3): auch beim Reise Schritt selbst alle DP.RAW_LOG_S die rohen Nauticus Werte ins Log
    if ns.TestLog and now - (dpCache.rawAt or -999) >= DP.RAW_LOG_S then
      for _, a in ipairs(cur.acts or {}) do
        if a.k == "R" and a.link and a.link ~= "fly" and ns.TravelDeparts then
          dpCache.rawAt = now
          local w = ns.TravelDeparts(a.link, a.side, a.li)
          local r = ns.lastNautRaw
          ns.TestLog("NAVI", ("Abfahrt Schritt: %s nach %s, faehrt in %s | Nauticus roh: since %.1f, off %.1f, Umlauf %.1f, Alter %.1f s | Uhr %s"):format(
            tostring(a.kind), tostring(a.dest), w and (ns.Clock and ns.Clock(w) or tostring(math.floor(w))) or "unbekannt",
            r and r.since or -1, r and r.off or -1, r and r.rtt or -1, r and (now - (r.at or now)) or -1, date and date("%H:%M:%S") or "?"))
          break
        end
      end
    end
    -- 1.3zo (P114, S 15:19 "zeigt mir den Zeppelinstep nicht an, da es auf Navi geschaltet hat"): laeuft ein Navi (das Mini
    -- Fenster zeigt dann das Navi statt des Route Schritts), steht die Abfahrt trotzdem unter dem Ziel: zuerst die Vorschau
    -- des Navi, sonst die Fahrt des Route Schritts
    if nv and not nv.hidden and nv.legs and nv.legs[nv.cur] then
      local ok2, t2 = pcall(DpNavi, nv, P)
      if not (ok2 and t2) then
        t2 = nil
        for _, a in ipairs(cur.acts or {}) do
          if a.k == "R" and a.link and a.link ~= "fly" and ns.TravelDeparts then
            local w = ns.TravelDeparts(a.link, a.side, a.li)
            if w then
              t2 = (TR"%s nach %s fährt in %s"):format(tostring(a.kind or TR"Fahrt"), tostring(a.dest or "?"), ns.Clock and ns.Clock(w) or tostring(math.floor(w)))
            end
            break
          end
        end
      end
      dpCache.txt = t2
      return t2
    end
    return nil
  end
  if nv and not nv.hidden and nv.legs and nv.legs[nv.cur] then ok, txt, key = pcall(DpNavi, nv, P)
  else ok, txt, key = pcall(DpRoute, P) end
  if not ok then txt, key = nil, nil end
  dpCache.txt = txt
  -- 1.3v (P105 Punkt 3): bei neuer Vorschau und dann alle DP.RAW_LOG_S die rohen Nauticus Werte mitschreiben
  if key and ns.TestLog and (key ~= dpLogKey or now - (dpCache.rawAt or -999) >= DP.RAW_LOG_S) then
    dpCache.rawAt = now
    local r = ns.lastNautRaw
    local raw = r and (" | Nauticus roh: Linie %s Seite %s Platz %s, since %.1f, off %.1f, Umlauf %.1f, warten %.1f s, andere Seite Platz %s off %s, Alter %.1f s%s"):format(
      tostring(r.id), tostring(r.side), tostring(r.idx), r.since or -1, r.off or -1, r.rtt or -1, r.wait or -1, tostring(r.idxQ), r.offQ and ("%.1f"):format(r.offQ) or "?", now - (r.at or now),
      r.sync and (", Sync vor %.0f s"):format(now - r.sync) or "") or " | Nauticus roh: keine"
    ns.TestLog("NAVI", "Abfahrt Vorschau: " .. tostring(txt) .. raw .. (" | Uhr %s, Server %s"):format(date and date("%H:%M:%S") or "?", (GetServerTime and date and date("%H:%M:%S", GetServerTime())) or "?"))
  end
  dpLogKey = key
  return txt
end

function ns.NaviHudInfo()
  local nv = ns.navi
  if not (nv and not nv.hidden and nv.legs and nv.legs[nv.cur]) then return nil end
  local lg = nv.legs[nv.cur]
  local P = Here()
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local TV = ns.TRAVEL or { PATH = 1.2 }
  local i = { navi = true }
  -- 20.3l (K6): lange Zielnamen ("Gold farmen: ...") schneiden das Mini Fenster ab, darum hoechstens 24 Zeichen (UTF 8 sicher)
  -- 20.3n (K6/M6): Text kuerzen, UTF 8 sicher, mit ...
  local function Kurz(t, n)
    local c, out = 0, {}
    for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      c = c + 1
      if c > n then return table.concat(out) .. "..." end
      out[#out + 1] = ch
    end
    return t
  end
  local dn = Kurz(nv.dest.name or "?", 24)
  i.zoneName = (TR"Navi nach %s"):format(dn)
  i.zoneIdx, i.zoneTotal = nv.cur, #nv.legs
  i.zone = (TR"%s, Schritt %d von %d"):format(i.zoneName, nv.cur, #nv.legs)
  local nx = nv.legs[nv.cur + 1]
  -- 20.3n (M6 S 22:57): "danach"-Text im Mini Fenster war abgeschnitten ("Zum Flugmeister Doras, Orgrimmar, dann Flug nach Das ..."):
  -- bei langem Text nur bis zum ersten Komma, dann hoechstens 30 Zeichen
  do
    local t = nx and nx.text or nil
    if t and #t > 30 then
      local cut = t:match("^(.-),")
      if cut and #cut >= 8 then t = cut end
      t = Kurz(t, 30)
    end
    i.nextZone = t
  end
  i.kind = (lg.kind == "ride" and lg.tram) and TR"Navi: Tiefenbahn" or KIND[lg.kind] or TR"Navi"
  i.col = NCOL[lg.kind] or NCOL.walk
  i.name = lg.text
  -- noch bis zum Ende dieses Abschnitts
  local left = lg.sec or 0
  if P and lg.at and P.cont == lg.at.cont then
    local d = D(P, lg.at)
    i.dist = math.floor(d)
    -- 19.24 (Sascha Teil 1 Punkt 4): Weg bis zum Ende des Abschnitts ueber das Netz wie in der Planung, alle 2 Sekunden
    local now = GetTime()
    if not (nv.walkAt and now - nv.walkAt < 2 and nv.walkLeg == nv.cur) then
      nv.walkAt, nv.walkLeg = now, nv.cur
      nv.walkD = (ns.WalkYards and ns.WalkYards(P, lg.at)) or d * TV.PATH
    end
    local wd = nv.walkD or d * TV.PATH
    if lg.kind == "walk" then left = wd / speed
    elseif lg.kind == "ride" then
      left = wd / speed
      if lg.exact and lg.depart then
        local left = (LiveDepart and LiveDepart(lg.l, lg.side, lg.depart)) or (lg.depart - GetTime())
        i.objs = { (TR"Abfahrt in %s"):format(ns.Clock(math.max(0, left))) }
      end
    end
  end
  if lg.kind == "fly" or lg.kind == "hearth" or lg.kind == "portal" then
    -- 20.3z3 (K 17:22 P9, Ad AN Na: "Zeit laeuft nicht im Stehen"): die Restzeit lief ab dem Abschnittsbeginn, auch beim Warten am
    -- Flugmeister. Flug: erst ab dem Abflug (auf dem Taxi). Teleport/Ruhestein: erst ab dem Zaubern.
    local nowT, t0 = GetTime(), nil
    if lg.kind == "fly" then
      if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then
        if not nv.flyT0 then nv.flyT0 = nowT end
        t0 = nv.flyT0
      end
    else
      if UnitCastingInfo and UnitCastingInfo("player") then
        if not nv.castT0 then nv.castT0 = nowT end
      end
      t0 = nv.castT0
    end
    left = math.max(0, (lg.sec or 0) - (t0 and (nowT - t0) or 0))
    if lg.kind == "fly" and UnitOnTaxi and not ns.Api.U(UnitOnTaxi, "player") then i.objs = { TR"Beim Flugmeister den Flug nehmen" } end
  end
  i.time = ns.Clock and ns.Clock(left) or tostring(math.floor(left))
  local rest = left
  for k = nv.cur + 1, #nv.legs do rest = rest + (nv.legs[k].sec or 0) end
  i.progress = (TR"Ankunft in ca %s"):format(ns.Clock and ns.Clock(rest) or math.floor(rest) .. "s")
  i.objs = i.objs or {}
  -- 19.12: letzter Schritt endet vor dem Ziel (zu Fuss nicht erreichbar)
  if lg.reach then
    table.insert(i.objs, 1, "|cffffd100" .. (TR"Näher geht zu Fuss nicht, Ziel noch ca %d yd entfernt"):format(lg.reach.d) .. "|r")
  end
  -- 19.32 (Navi Chat): Flug waere viel schneller, das Addon kennt die Flugpunkte aber nicht
  if nv.fpTip and ns.NaviFlugTippText then
    table.insert(i.objs, 1, "|cff73d9ff" .. ns.NaviFlugTippText(nv.fpTip, true) .. "|r")
  end
  -- 19.11: dieses Stueck geht durch einen Posten der anderen Fraktion
  if lg.post then
    table.insert(i.objs, 1, "|cffff8020" .. ((nv.postFac == "H") and TR"Vorsicht: Posten der Horde auf diesem Stück" or TR"Vorsicht: Posten der Allianz auf diesem Stück") .. "|r")
  end
  for k = nv.cur + 1, math.min(#nv.legs, nv.cur + 3) do
    local l2 = nv.legs[k]
    i.objs[#i.objs + 1] = ("|cff9d9d9d%d. %s, %s|r"):format(k, l2.text, ns.Clock and ns.Clock(l2.sec or 0) or "")
  end
  return i
end

------------------------------------------------------------
-- Karte: Knopf und Klick aufs Ziel
------------------------------------------------------------
local function CursorZonePos(sc)
  local OM = OpenMapAPI
  if OM and OM.IsStitched and OM.IsStitched() and OM.CursorPosition then
    local u, v = OM.CursorPosition()
    if not u then return end
    local zone = OM.MapAt(u, v)
    local nm = zone and ns.ZoneName and ns.ZoneName(zone)
    if ns.cityParent and zone and ns.cityParent[zone] then zone = ns.cityParent[zone] end
    if zone then local zx, zy = OM.MapFromWorld(zone, u, v); if zx then return zone, zx, zy, nm end end
    return
  end
  if not sc.GetNormalizedCursorPosition then return end
  local cx, cy = sc:GetNormalizedCursorPosition()
  local mapID = WorldMapFrame:GetMapID()
  if not (cx and cy and mapID) or cx < 0 or cx > 1 or cy < 0 or cy > 1 then return end
  local info = C_Map.GetMapInfo(mapID)
  if info and info.mapType and info.mapType < Enum.UIMapType.Zone and C_Map.GetMapInfoAtPosition then
    local zi = C_Map.GetMapInfoAtPosition(mapID, cx, cy)
    if zi and zi.mapID then
      local zx, zy = ns.ToMap(mapID, cx, cy, zi.mapID)
      if zx then return zi.mapID, zx, zy, zi.name end
    end
    return
  end
  -- Stadt in der Zone angeklickt: Name der Stadt fuer die Anzeige
  local nm = ns.ZoneName and ns.ZoneName(mapID)
  if C_Map.GetMapInfoAtPosition then
    local ci = C_Map.GetMapInfoAtPosition(mapID, cx, cy)
    if ci and ci.mapID ~= mapID and ci.name and ns.cityParent and ns.cityParent[ci.mapID] then nm = ci.name end
  end
  return mapID, cx, cy, nm
end

local function Click()
  -- 20.3z3 (K 18:08 N2, S 18:01 "ganz schlecht"): der Navi Knopf auf der Karte ist NUR ein eigener Navi Punkt (Weg von hier
  -- dahin). Er blendet nie ein Navi aus, das zu einer anderen Funktion gehoert (Berufe, Farm, Gold, Zusatz Route, Tour:
  -- Anweg einmal, danach Kreislauf im selben Menue Punkt). Mit so einem Anweg Navi startet der Klick die Zielwahl; das
  -- neue Ziel ist dann ein eigener Navi Schritt, danach geht die Route wie vorher weiter.
  local nv = ns.navi
  if nv and not nv.zielSeite then
    if nv.hidden then ns.NaviShow(); pick = false; return end
    Stop(TR"Navi beendet, Pfeil wieder auf der Route."); pick = false; return
  end
  pick = not pick
  if pick then ns.Print(TR"Navi: jetzt auf der Karte auf dein Ziel klicken.") end
  if ns.MapButtonText then ns.MapButtonText() end
end

if ns.AddMapButton then
  ns.AddMapButton({ key = "navi", icon = "Interface\\Icons\\INV_Misc_Spyglass_03", name = TR"Navi",
    tip = TR"Klick hier, dann auf der Karte dein Ziel. Der Pfeil nimmt den schnellsten Weg, auch mit Flug, Schiff, Ruhestein und Teleport. Nochmal klicken beendet es.",
    on = function() return pick or (ns.navi ~= nil and not ns.navi.hidden and not ns.navi.zielSeite) end, click = Click })
end

-- 1.2n (P76, K 18:45, S 18:38 "hier haette er den Weg ueber den Flugmeister suchen sollen"): der Route Schritt liegt weit weg
-- (Annehmen bei Theodore Griffs in Unterstadt, du am Grabmal im Silberwald, 1500 yd zu Fuss ueber den Zonen Uebergang). Die
-- Route plant Fluege nur beim Rechnen, danach ging der Pfeil nur zu Fuss. Jetzt: ist der jetzige Schritt mehr als
-- AUTO_MIN_YD weg (oder auf einem anderen Kontinent), plant das Navi still einen Weg. Spart er mit Flug, Schiff, Zeppelin
-- oder Portal mindestens AUTO_GAIN_S gegen Laufen, fuehrt das Navi bis zum Schritt (Linie, Flugmeister), danach wieder die
-- Route. Ruhestein nicht (der hat seinen eigenen Hinweis). Je Schritt hoechstens alle AUTO_RETRY_S neu und nur, wenn du
-- seitdem AUTO_MOVE_YD weiter bist. Schalter db.naviAuto=false: aus
local AUTO_EVERY_S, AUTO_MIN_YD, AUTO_GAIN_S, AUTO_RETRY_S, AUTO_MOVE_YD = 5, 600, 60, 60, 200
local autoTry = {}
local function AutoRoute()
  local db = ns.db
  if not (db and db.optMode and db.naviAuto ~= false and db.zielNavi ~= false) then return end
  if ns.navi or ns.serviceTarget then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if ns.OnRide and ns.OnRide() then return end
  if ns.InInstance and ns.InInstance() then return end
  if ns.OptBusy and ns.OptBusy() then return end
  local o = db.opt
  local idx = o and (o.idx or 1)
  local st = o and o.steps and o.steps[idx]
  if not (st and st.map and st.x and st.y) or st.travel then return end
  local P = Here()
  local G = P and Node(st.map, st.x, st.y)
  if not (P and G) then return end
  local far = P.cont ~= G.cont or D(P, G) > AUTO_MIN_YD
  if not far then return end
  local now = GetTime()
  local tr = autoTry
  if tr.idx == idx and tr.started then return end -- je Schritt nur einmal von selbst (weggeklickt bleibt weg)
  if tr.idx == idx and tr.t and (now - tr.t < AUTO_RETRY_S or (tr.P and tr.P.cont == P.cont and D(tr.P, P) < AUTO_MOVE_YD)) then return end
  autoTry = { idx = idx, t = now, P = P }
  local name = st.who or st.npc or st.quest or st.name or TR"Route Schritt"
  if type(name) ~= "string" then name = TR"Route Schritt" end
  local ok, nv = pcall(ns.NaviPlan, st.map, st.x, st.y, name)
  if not (ok and nv and nv.legs) then return end
  local ride, hearth = false, false
  for _, lg in ipairs(nv.legs) do
    if lg.kind == "fly" or lg.kind == "ride" or lg.kind == "portal" then ride = true end
    if lg.kind == "hearth" then hearth = true end
  end
  if not ride or hearth then return end
  local TV = ns.TRAVEL or { PATH = 1.2 }
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local walk = (P.cont == G.cont) and (D(P, G) * (TV.PATH or 1.2) / speed) or math.huge
  if not (nv.total + AUTO_GAIN_S < walk) then
    if ns.TestLog then ns.TestLog("NAVI", ("Route Schritt weit weg (%s): mit Reise %d s, zu Fuss %d s, bleibt zu Fuss"):format(name, math.floor(nv.total), math.floor(math.min(walk, 99999)))) end
    return
  end
  nv.zielSeite = true -- nicht als eigenes Ziel merken (kommt nach dem Einloggen nicht zurueck), Karten Knopf blendet nur aus
  nv.routeIdx = idx
  autoTry.started = true
  Start(nv, false)
  if ns.TestLog then ns.TestLog("NAVI", ("Route Schritt weit weg (%s): Navi mit Reise %d s statt %s zu Fuss"):format(name, math.floor(nv.total),
    walk == math.huge and "anderer Kontinent" or (math.floor(walk) .. " s"))) end
end

local hf = CreateFrame("Frame")
ns.RegEv(hf, "PLAYER_LOGIN")
hf:SetScript("OnEvent", function()
  ns.Ticker(1, function() pcall(Tick) end, true)
  ns.Ticker(AUTO_EVERY_S, function() local ok, err = pcall(AutoRoute); if not ok and ns.TestLog then ns.TestLog("NAVI", "Route Navi Fehler: " .. tostring(err)) end end)
  -- gemerktes Navi nach dem Einloggen wieder aufbauen (Position und Flugpunkte brauchen ein paar Sekunden)
  if C_Timer then
    C_Timer.After(8, function()
      local d = ns.db and ns.db.naviDest
      if ns.navi or type(d) ~= "table" or not (d.map and d.x and d.y) then return end
      -- 20.3z3 (Ad Z5, S Log 17:51 "Gold farmen: Firesworn" kam als gespeichertes Ziel): ein Navi von einer Seite gehoert zu
      -- seiner Route (die setzt den Anweg beim Laden selbst neu, mit dem aktuellen Filter). Nicht als eigenes Ziel zurueckholen
      -- alte Staende ohne Zeichen: an den Namen der Seiten Ziele erkennen
      if d.seite or (type(d.name) == "string" and (d.name:find("^Gold farmen") or d.name:find("^Farmen:") or d.name:find("^Ruhestein benutzen"))) then
        ns.db.naviDest = nil
        if ns.TestLog then ns.TestLog("NAVI", ("gemerktes Ziel von einer Seite nicht wiederhergestellt: %s"):format(tostring(d.name))) end
        return
      end
      local nv = ns.NaviPlan(d.map, d.x, d.y, d.name)
      if nv then
        Start(nv, true, d.hidden)
        if not d.hidden then ns.Print((TR"Navi nach %s läuft weiter."):format(d.name or "?")) end
      end
    end)
  end
  local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
  if sc and sc.HookScript then
    sc:HookScript("OnMouseUp", function(self, button)
      if not pick or button ~= "LeftButton" or IsModifierKeyDown() then return end
      local m, x, y, nm = CursorZonePos(self)
      if not m then ns.Print(TR"Navi: hier ist keine Zone, bitte auf eine Zone klicken."); return end
      pick = false
      ns.NaviTo(m, x, y, nm)
    end)
  end
  if WorldMapFrame then WorldMapFrame:HookScript("OnHide", function() if pick then pick = false; if ns.MapButtonText then ns.MapButtonText() end end end) end
end)
