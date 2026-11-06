local ADDON, ns = ...
local TR = ns.TR

local db
local overlay
local lines, pins, labels = {}, {}, {}
local nLine, nPin, nLab = 0, 0, 0
local rings, icons = {}, {}
local nRing, nIcon = 0, 0
-- OpenMap: Zonen Punkte auf die zusammengesetzte Karte umrechnen
local xform
local function Cv(x, y)
  if xform then x, y = xform(x, y) end
  -- nur mit beiden Werten zeichnen (OpenMap oder Umrechnung liefert manchmal nur einen)
  if not (x and y) then return end
  return x, y
end
-- Punkt einer beliebigen Zone auf die gerade gezeigte Karte (normal oder OpenMap)
local function ToView(zone, x, y, mapID)
  local OM = OpenMapAPI
  if OM and OM.IsStitched and OM.IsStitched() then
    local u, v = OM.WorldFromMap(zone, x, y)
    if not u then return end
    return OM.MapFromWorld(WorldMapFrame:GetMapID(), u, v)
  end
  if zone == mapID then return x, y end
  return ns.ToMap and ns.ToMap(zone, x, y, mapID)
end
local sess

------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------
-- Forever: manche Werte sind im Kampf "geheim" und duerfen nicht verglichen werden
local function Plain(v)
  if v == nil then return nil end
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end
ns.Plain = Plain

-- Questlog Groesse: auf Forever 40 statt 20, mit /klg log N anpassbar
function ns.LogMax()
  local v = ns.db and tonumber(ns.db.logMax)
  return (v and v >= 10) and v or 40
end
-- ab so vielen Quests warnen (Standard: ein Platz frei)
function ns.LogWarn()
  local w = ns.db and tonumber(ns.db.logWarn)
  local m = ns.LogMax()
  if w and w >= 1 then return math.min(w, m) end
  return m - 1
end

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage(TR"|cff7fd1b9Keine Zeit Leveling Guide|r: " .. msg)
end
ns.Print = Print

local function ZoneName(mapID)
  local info = mapID and C_Map.GetMapInfo(mapID)
  return info and info.name or tostring(mapID)
end

local function PlayerMap()
  return C_Map.GetBestMapForUnit("player")
end

local function Dist(ax, ay, bx, by)
  return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

local function FmtMin(sec)
  local m = math.floor(sec / 60 + 0.5)
  if m >= 60 then return (TR"%d Std %d Min"):format(math.floor(m / 60), m % 60) end
  return m .. TR" Min"
end

-- Karte zu Weltkoordinaten. Pro Karte einmal die vier Ecken holen, danach nur noch rechnen:
-- jeder Aufruf der Spiel Funktion baut neue Vektor Tabellen, tausende davon (Haendler suchen, Route rechnen)
-- machen Muell und damit Ruckler. Ist eine Karte kein einfaches Rechteck in der Welt, wird wie frueher gefragt.
local mwCache = {}
local function MapWorldRaw(map, x, y)
  local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if ok and c and w then local wx, wy = w:GetXY(); return c, wx, wy end
end
local function MapAffine(map)
  local m = mwCache[map]
  if m ~= nil then return m end
  m = false
  if C_Map.GetWorldPosFromMapPos and CreateVector2D then
    local c0, ox, oy = MapWorldRaw(map, 0, 0)
    local c1, ax, ay = MapWorldRaw(map, 1, 0)
    local c2, bx, by = MapWorldRaw(map, 0, 1)
    local c3, dx, dy = MapWorldRaw(map, 1, 1)
    if c0 and c0 == c1 and c0 == c2 and c0 == c3 then
      local ex, ey, fx, fy = ax - ox, ay - oy, bx - ox, by - oy
      local det = ex * fy - ey * fx
      if det ~= 0 and math.abs(ox + ex + fx - dx) < 1 and math.abs(oy + ey + fy - dy) < 1 then
        -- Stichprobe in der Mitte: muss auch passen
        local c4, mx, my = MapWorldRaw(map, 0.37, 0.61)
        if c4 == c0 and math.abs(ox + 0.37 * ex + 0.61 * fx - mx) < 1 and math.abs(oy + 0.37 * ey + 0.61 * fy - my) < 1 then
          m = { c0, ox, oy, ex, ey, fx, fy, det }
        end
      end
    end
  end
  mwCache[map] = m
  return m
end
local function MapWorld(map, x, y)
  if not (map and x and y) then return end
  local m = MapAffine(map)
  if m then return m[1], m[2] + x * m[4] + y * m[6], m[3] + x * m[5] + y * m[7] end
  if C_Map.GetWorldPosFromMapPos and CreateVector2D then return MapWorldRaw(map, x, y) end
end
ns.MapWorld = MapWorld
-- Welt Punkt auf eine Karte (nil, wenn die Karte kein Rechteck ist oder anderer Kontinent)
local function WorldToMapFast(map, c, wx, wy)
  local m = MapAffine(map)
  if not m or m[1] ~= c then return end
  local rx, ry = wx - m[2], wy - m[3]
  return (rx * m[7] - ry * m[6]) / m[8], (ry * m[4] - rx * m[5]) / m[8]
end
-- Punkt einer Karte auf eine andere (nil ausserhalb 0..1). Schnell, wenn beide Karten Rechtecke sind.
function ns.MapToMap(fromMap, x, y, toMap)
  if fromMap == toMap then return x, y end
  local mf, mt = MapAffine(fromMap), MapAffine(toMap)
  if mf and mt then
    local c, wx, wy = MapWorld(fromMap, x, y)
    local u, v = WorldToMapFast(toMap, c, wx, wy)
    if not u or u < 0 or u > 1 or v < 0 or v > 1 then return end
    return u, v
  end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
  local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, fromMap, CreateVector2D(x, y))
  if not ok or not cont or not world then return end
  local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, toMap)
  if not ok2 or not pos then return end
  local u, v = pos:GetXY()
  if not u or u < 0 or u > 1 or v < 0 or v > 1 then return end
  return u, v
end

-- Zonen Koordinate auf eine andere Karte umrechnen (z.B. Kontinent)
local function ToMap(zoneID, x, y, targetMap)
  if MapAffine(zoneID) and MapAffine(targetMap) then return ns.MapToMap(zoneID, x, y, targetMap) end
  if not (C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
  local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, zoneID, CreateVector2D(x, y))
  if not ok or not cont or not world then return end
  local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, targetMap)
  if not ok2 or not pos then return end
  local px, py = pos:GetXY()
  if px < 0 or px > 1 or py < 0 or py > 1 then return end
  return px, py
end

-- Distanz in Yards zwischen {map, x, y} Punkten, nil wenn anderer Kontinent
local function WorldDist(a, b)
  local c1, x1, y1 = MapWorld(a[1], a[2], a[3])
  if not c1 then return end
  local c2, x2, y2 = MapWorld(b[1], b[2], b[3])
  if not c2 or c1 ~= c2 then return end
  return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2)
end
ns.WorldDist = WorldDist
-- dasselbe ohne Tabellen
function ns.WorldDistXY(m1, x1, y1, m2, x2, y2)
  local c1, a1, b1 = MapWorld(m1, x1, y1)
  if not c1 then return end
  local c2, a2, b2 = MapWorld(m2, x2, y2)
  if not c2 or c1 ~= c2 then return end
  return math.sqrt((a1 - a2) ^ 2 + (b1 - b2) ^ 2)
end
ns.ToMap = ToMap
-- 17.9 wie ToMap, aber auch knapp ausserhalb 0..1 (Zonengrenzen liegen auf neu vermessenen Forever Karten wie
-- Rotkammgebirge teils neben dem Kartenrand)
function ns.ToMapLoose(fromMap, x, y, toMap)
  if fromMap == toMap then return x, y end
  if not (MapAffine(fromMap) and MapAffine(toMap)) then return ToMap(fromMap, x, y, toMap) end
  local c, wx, wy = MapWorld(fromMap, x, y)
  if not c then return end
  local u, v = WorldToMapFast(toMap, c, wx, wy)
  if not u or u < -0.25 or u > 1.25 or v < -0.25 or v > 1.25 then return end
  return u, v
end

-- 19.2 wie ToMap, aber ohne Grenze 0..1 (Navi Linien, die von ausserhalb der Karte kommen). nil bei anderem Kontinent.
function ns.ToMapFree(fromMap, x, y, toMap)
  if fromMap == toMap then return x, y end
  if MapAffine(fromMap) and MapAffine(toMap) then
    local c, wx, wy = MapWorld(fromMap, x, y)
    if not c then return end
    return WorldToMapFast(toMap, c, wx, wy)
  end
  return ToMap(fromMap, x, y, toMap)
end

-- Punkt an der Stelle einfuegen, wo er am wenigsten Umweg macht
local function InsertCheapest(list, pt)
  if #list == 0 then table.insert(list, pt); return end
  local best, bestCost = 1, Dist(list[1][1], list[1][2], pt[1], pt[2])
  for i = 1, #list - 1 do
    local a, b = list[i], list[i + 1]
    local cost = Dist(a[1], a[2], pt[1], pt[2]) + Dist(pt[1], pt[2], b[1], b[2]) - Dist(a[1], a[2], b[1], b[2])
    if cost < bestCost then best, bestCost = i + 1, cost end
  end
  local last = list[#list]
  if Dist(last[1], last[2], pt[1], pt[2]) < bestCost then best = #list + 1 end
  table.insert(list, best, pt)
end

------------------------------------------------------------
-- Gefahrenstellen (Klippen, Schluchten) und Umwege
------------------------------------------------------------
local DANGER_R = 0.025

-- alle aktiven Gefahren: Klippen, plus Gebiete mit zu starken Mobs
local function Dangers(mapID)
  local out = {}
  if not (db and mapID) then return out end
  for _, d in ipairs(db.danger[mapID] or {}) do table.insert(out, d) end
  local L = UnitLevel("player")
  -- Grind Spots aus den Daten, wenn die Mobs zu stark sind
  for _, g in ipairs((ns.GrindList and ns.GrindList(mapID)) or ns.grind[mapID] or {}) do
    if g[4] >= L + 3 then
      table.insert(out, { g[1], g[2], 0.04, (TR"Mobs Level %d bis %d"):format(g[4], g[5]), mob = true })
    end
  end
  -- Elite Gebiete aus den Questie Mob Daten
  if ns.EliteAreas then
    for _, e in ipairs(ns.EliteAreas(mapID)) do table.insert(out, e) end
  end
  -- unterwegs gesehene starke Mobs, nur solange ihr zu tief seid
  for _, m in ipairs(db.mobDanger[mapID] or {}) do
    if m[4] >= L + 3 then
      table.insert(out, { m[1], m[2], 0.03, (TR"starke Mobs Level %d"):format(m[4]), mob = true })
    end
  end
  return out
end
ns.Dangers = Dangers

-- 20.3m+ (S Punkt 27): von dir gesetzt (Alt+Klick, /klg gefahr) oder automatisch gelernt (Sturz). Auf der Karte zeigen
-- nur die selbst gesetzten, die gelernten wirken weiter fuer die Wege (Umweg), stehen aber nicht als Pin herum.
-- Alte Eintraege ohne Merker: an den Sturz Texten erkennen
local AUTO_WHY = { ["tiefer Sturz"] = true, ["viel Fallschaden"] = true, ["Tod durch Sturz"] = true }
AUTO_WHY[TR"tiefer Sturz"] = true; AUTO_WHY[TR"viel Fallschaden"] = true; AUTO_WHY[TR"Tod durch Sturz"] = true
function ns.DangerIsAuto(d)
  if not d or d.mob or d.elite then return false end
  if d.hand then return false end
  if d.auto then return true end
  return AUTO_WHY[d[4] or ""] and true or false
end
function ns.AddDanger(mapID, x, y, why, r, hand)
  if not mapID then return end
  db.danger[mapID] = db.danger[mapID] or {}
  for _, d in ipairs(db.danger[mapID]) do
    if Dist(d[1], d[2], x, y) < DANGER_R * 0.6 then return end -- schon bekannt
  end
  table.insert(db.danger[mapID], { x, y, r or DANGER_R, why, hand = hand or nil, auto = (not hand) or nil })
  Print((TR"Gefahr gespeichert (%s) bei %.1f, %.1f. Die Route macht hier jetzt einen Umweg."):format(why or "?", x * 100, y * 100))
end

function ns.RemoveDanger(mapID, x, y)
  local list = (db.danger[mapID]) or {}
  local best, bd
  for i, d in ipairs(list) do
    local dd = Dist(d[1], d[2], x, y)
    if dd < 0.06 and (not bd or dd < bd) then best, bd = i, dd end
  end
  if best then table.remove(list, best); Print(TR"Gefahrenstelle gelöscht") else Print(TR"Keine Gefahrenstelle in der Nähe") end
end

-- Wegpunkte und Punkte verschieben (Shift auf der Karte)
local function Changed()
  db.learnedRev = (db.learnedRev or 0) + 1
  if ns.Draw then ns.Draw() end
  if ns.RefreshUI then ns.RefreshUI() end
end

-- Position eines Wegpunkts in der fertigen Route
local function ViaPos(mapID, index)
  for i, p in ipairs(ns.GetRoute(mapID) or {}) do
    if p.kind == "via" and p.viaIndex == index then return i end
  end
end

function ns.AddVia(mapID, x, y, after)
  if not mapID then return end
  -- Fortschritt vor dem Neubau lesen (danach ist der neue Punkt schon eingerechnet)
  local prog = db.progress[mapID] or 1
  db.via[mapID] = db.via[mapID] or {}
  table.insert(db.via[mapID], { x, y, after = after })
  db.learnedRev = (db.learnedRev or 0) + 1
  -- liegt er im schon gelaufenen Teil, Fortschritt mitschieben
  local pos = ViaPos(mapID, #db.via[mapID])
  if pos and pos < prog and ns.DoneSet then ns.DoneSet(mapID)[TR"Wegpunkt " .. #db.via[mapID]] = true end
  Print((TR"Wegpunkt gesetzt bei %.1f, %.1f, Route neu berechnet"):format(x * 100, y * 100))
  Changed()
end

function ns.RemoveVia(mapID, index)
  local list = db.via[mapID]
  if list and list[index] then
    table.remove(list, index)
    Print(TR"Wegpunkt gelöscht")
    Changed()
  end
end

function ns.ClearVia(mapID)
  db.via[mapID] = nil
  Print(TR"Alle eigenen Wegpunkte in dieser Zone gelöscht")
  Changed()
end

-- Punkt der Route unter der Maus finden
function ns.PointAt(mapID, x, y, maxD)
  local route = ns.GetRoute(mapID)
  if not route then return end
  local best, bd
  for i, p in ipairs(route) do
    local d = Dist(p[1], p[2], x, y)
    if d < (maxD or 0.015) and (not bd or d < bd) then best, bd = p, d end
  end
  return best
end

-- Stueck der Route unter der Maus: gibt den Punkt davor zurueck
function ns.SegmentAt(mapID, x, y, maxD)
  local route = ns.GetRoute(mapID)
  if not route then return end
  local best, bd
  for i = 2, #route do
    local a, b = route[i - 1], route[i]
    local vx, vy = b[1] - a[1], b[2] - a[2]
    local l2 = vx * vx + vy * vy
    if l2 > 0 then
      local t = math.max(0, math.min(1, ((x - a[1]) * vx + (y - a[2]) * vy) / l2))
      local d = Dist(x, y, a[1] + vx * t, a[2] + vy * t)
      if d < (maxD or 0.012) and (not bd or d < bd) then best, bd = i - 1, d end
    end
  end
  if not best then return end
  -- Name des letzten echten Punkts vor diesem Stueck
  local j = best
  while j > 1 and route[j].kind == "via" do j = j - 1 end
  return route[j][3], route[best]
end

-- neuen Wegpunkt mitten in einer Linie anlegen und zurueckgeben
function ns.SplitAt(mapID, x, y)
  local after = ns.SegmentAt(mapID, x, y)
  if not after then return end
  ns.AddVia(mapID, x, y, after)
  local idx = #db.via[mapID]
  for _, p in ipairs(ns.GetRoute(mapID) or {}) do
    if p.kind == "via" and p.viaIndex == idx then return p end
  end
end

function ns.MovePoint(mapID, p, x, y, live)
  if p.kind == "via" and p.viaIndex and db.via[mapID] and db.via[mapID][p.viaIndex] then
    local v = db.via[mapID][p.viaIndex]
    v[1], v[2] = x, y
  elseif p[3] then
    db.override[mapID] = db.override[mapID] or {}
    db.override[mapID][p[3]] = { x, y }
  end
  p[1], p[2] = x, y
  if live then
    if ns.Draw then ns.Draw() end
  else
    Changed()
  end
end

-- Alt Klick auf der Karte: Gefahr setzen oder loeschen
function ns.ToggleDangerAt(mapID, x, y, big)
  if not (db and mapID) then return end
  local list = db.danger[mapID] or {}
  for i, d in ipairs(list) do
    if Dist(d[1], d[2], x, y) < math.max(d[3], 0.02) then
      table.remove(list, i)
      Print(TR"Gefahrenstelle gelöscht, Route neu berechnet")
      if ns.Draw then ns.Draw() end
      return
    end
  end
  ns.AddDanger(mapID, x, y, big and TR"gross, auf der Karte gesetzt" or TR"auf der Karte gesetzt", big and 0.05 or DANGER_R, true)
  if ns.Draw then ns.Draw() end
end

-- Umweg fuer die Strecke A nach B, falls sie durch eine Gefahrenstelle geht
local function Detour(mapID, ax, ay, bx, by)
  local best, bestT
  local vx, vy = bx - ax, by - ay
  local len2 = vx * vx + vy * vy
  if len2 == 0 then return end
  for _, d in ipairs(Dangers(mapID)) do
    local t = ((d[1] - ax) * vx + (d[2] - ay) * vy) / len2
    local atEnd = Dist(bx, by, d[1], d[2]) < d[3] or Dist(ax, ay, d[1], d[2]) < d[3]
    if t > 0 and t < 1 and not atEnd then
      local cx, cy = ax + vx * t, ay + vy * t
      local dist = Dist(cx, cy, d[1], d[2])
      if dist < d[3] and (not bestT or t < bestT) then
        -- vom Zentrum weg schieben, Richtung der Linie
        local nx, ny = cx - d[1], cy - d[2]
        local nl = math.sqrt(nx * nx + ny * ny)
        if nl < 1e-6 then
          nx, ny = -vy, vx -- genau mittendurch: quer zur Strecke
          nl = math.sqrt(nx * nx + ny * ny)
        end
        best = { d[1] + nx / nl * d[3] * 1.6, d[2] + ny / nl * d[3] * 1.6 }
        bestT = t
      end
    end
  end
  return best
end
ns.Detour = Detour

-- ganzer Weg von A nach B mit allen Umwegen (rekursiv, bis 3 Stufen)
local function DetourPath(mapID, ax, ay, bx, by, depth)
  depth = depth or 0
  local d = Detour(mapID, ax, ay, bx, by)
  if not d or depth >= 3 then return {} end
  local out = DetourPath(mapID, ax, ay, d[1], d[2], depth + 1)
  table.insert(out, d)
  for _, q in ipairs(DetourPath(mapID, d[1], d[2], bx, by, depth + 1)) do table.insert(out, q) end
  return out
end
ns.DetourPath = DetourPath

-- starke Mobs in der Naehe ueber die Namensplaketten erkennen
local function MobScan()
  if not (db and C_NamePlate and C_NamePlate.GetNamePlates) then return end
  local L = UnitLevel("player")
  local count, maxLvl = 0, 0
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
    if u and ns.Api.U(UnitCanAttack, "player", u) and not ns.Api.U(UnitIsDead, u) and not ns.Api.U(UnitIsPlayer, u) then
      local lvl = Plain(UnitLevel(u))
      if lvl == -1 then lvl = L + 10 end -- Totenkopf
      if lvl and lvl >= L + 3 then
        count = count + 1
        if lvl > maxLvl then maxLvl = lvl end
      end
    end
  end
  if count < 2 then return end
  local mapID = PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  db.mobDanger[mapID] = db.mobDanger[mapID] or {}
  for _, m in ipairs(db.mobDanger[mapID]) do
    if Dist(m[1], m[2], x, y) < 0.025 then
      if maxLvl > m[4] then m[4] = maxLvl end
      return
    end
  end
  table.insert(db.mobDanger[mapID], { x, y, 0.03, maxLvl })
  Print((TR"Starke Mobs (Level %d) hier, die Route weicht ab jetzt aus"):format(maxLvl))
  if ns.Draw then ns.Draw() end
end

-- Stuerze automatisch erkennen
local fall = {}
local function FallTick()
  if not db then return end
  local falling = IsFalling and ns.Api.U(IsFalling)
  local mapID = PlayerMap()
  if falling and not fall.active then
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local x, y = pos:GetXY()
      fall = { active = true, map = mapID, x = x, y = y, t = GetTime(), dmg = 0, hp0 = Plain(UnitHealth("player")) }
      -- 19.18 (Sascha: "viele springen vom Zeppelin"): vom Schiff oder Zeppelin gesprungen, oder am Steg / Turm:
      -- keine Gefahrenstelle (sonst macht die Route dort einen Umweg, wo nur der Zeppelin drueber flog)
      fall.boat = (ns.WalkOnBoat and ns.WalkOnBoat()) or (ns.NearDock and ns.NearDock(mapID, Plain(x), Plain(y), 70)) or false
    end
  elseif not falling and fall.active then
    fall.active = false
    fall.landed = GetTime()
    local dur = GetTime() - fall.t
    local maxHp = Plain(UnitHealthMax("player")) or 1
    -- Fallschaden ohne Kampflog: Leben vor dem Sturz minus Leben nach der Landung
    local hp1 = Plain(UnitHealth("player"))
    if fall.hp0 and hp1 and fall.hp0 > hp1 then fall.dmg = fall.hp0 - hp1 end
    -- ohne Schaden (Wasser, Langsamer Fall, Levitieren) ist es keine Gefahr
    if fall.boat then
      -- nichts merken
    elseif (dur > 2.5 and fall.dmg > 0) or fall.dmg > maxHp * 0.3 then
      ns.AddDanger(fall.map, fall.x, fall.y, dur > 2.5 and TR"tiefer Sturz" or TR"viel Fallschaden")
      if ns.Draw then ns.Draw() end
    end
  end
end

local function OnFallDamage(amount)
  if fall.active then
    fall.dmg = (fall.dmg or 0) + amount
  elseif fall.landed and GetTime() - fall.landed < 1 then
    fall.dmg = (fall.dmg or 0) + amount
    local maxHp = Plain(UnitHealthMax("player")) or 1
    if fall.dmg > maxHp * 0.3 and not fall.boat then ns.AddDanger(fall.map, fall.x, fall.y, TR"viel Fallschaden") end
  end
end

local function OnDeath()
  if fall.map and not fall.boat and (fall.active or (fall.landed and GetTime() - fall.landed < 3)) then
    ns.AddDanger(fall.map, fall.x, fall.y, TR"Tod durch Sturz")
  end
end

------------------------------------------------------------
-- Route einer Zone: Erkunden + Flugpunkte + Quest Hubs + Grind Spots
------------------------------------------------------------
local PRIO = { via = 0, explore = 1, grind = 2, obj = 2.5, quest = 3, fp = 4, turnin = 5 }
local routeCache = {}

local entryCache = {}
local function BaseRoute(mapID)
  local custom = db.custom[mapID]
  if custom and #custom > 0 then return custom end
  local r = ns.routes[mapID]
  local want = r and ns.entry and ns.entry[mapID]
  if not want or (r[1] and r[1][3] == want) then return r end
  -- Einstieg je Volk nach vorne holen, Rest ordnet Optimize. Einmal pro Zone, sonst trifft der Cache nie
  local ec = entryCache[mapID]
  if ec and ec.r == r and ec.want == want then return ec.out end
  local out, rest = {}, {}
  for _, p in ipairs(r) do
    if p[3] == want then table.insert(out, p) else table.insert(rest, p) end
  end
  for _, p in ipairs(rest) do table.insert(out, p) end
  entryCache[mapID] = { r = r, want = want, out = out }
  return out
end

local Optimize -- wird weiter unten gesetzt
local function BuildRoute(mapID)
  local res = {}
  local learned = db.learned[mapID] or {}
  local ren = db.renames[mapID] or {}
  for _, p in ipairs(BaseRoute(mapID) or {}) do
    local lp = p[3] and learned[p[3]]
    local name = (p[3] and ren[p[3]]) or p[3]
    table.insert(res, { lp and lp[1] or p[1], lp and lp[2] or p[2], name, kind = "explore", tags = { explore = true } })
  end
  local function Add(x, y, name, tag, info, mergeR)
    for _, p in ipairs(res) do
      if Dist(p[1], p[2], x, y) < (mergeR or 0.03) then
        p.tags[tag] = info or true
        if PRIO[tag] > PRIO[p.kind] then p.kind = tag; p[3] = name end
        return
      end
    end
    InsertCheapest(res, { x, y, name, kind = tag, tags = { [tag] = info or true } })
  end
  local fpAdded = {}
  for _, f in ipairs(ns.fp[mapID] or {}) do
    local x, y = f[1], f[2]
    if f.map and f.map ~= mapID then x, y = ToMap(f.map, f[1], f[2], mapID) end
    if x and not (ns.FPKnownNear and ns.FPKnownNear(mapID, x, y)) then
      Add(x, y, TR"FP " .. f[3], "fp", f)
      table.insert(fpAdded, { x, y })
    end
  end
  -- Flugmeister aus Questie, die du noch nicht hast
  for _, e in ipairs(ns.FlightMasters and ns.FlightMasters(mapID) or {}) do
    local dup = false
    for _, a in ipairs(fpAdded) do if Dist(a[1], a[2], e[1], e[2]) < 0.04 then dup = true end end
    if not dup then Add(e[1], e[2], TR"FP " .. (e[3] or "?"), "fp", { e[1], e[2], e[3], npc = e[6] }) end
  end
  if ns.qStarts then
    -- echte Questgeber aus Questie
    for _, e in ipairs(ns.qStarts[mapID] or {}) do Add(e[1], e[2], TR"Quests: " .. e[3], "quest", e, 0.006) end
    for _, e in ipairs((ns.qEnds and ns.qEnds[mapID]) or {}) do Add(e[1], e[2], TR"Abgeben: " .. e[3], "turnin", e, 0.006) end
    for _, o in ipairs((ns.qObjs and ns.qObjs[mapID]) or {}) do Add(o[1], o[2], o[3], "obj", o, 0.01) end
  else
    for _, h in ipairs(ns.hubs[mapID] or {}) do Add(h[1], h[2], TR"Quests " .. h[3], "quest", h) end
  end
  -- Grind Spots nur, wenn der Plan dort wirklich grinden will (sonst Quests, wie bei RestedXP)
  local gs = ns.planGrindSpot and ns.planGrindSpot[mapID]
  if gs and db.planGrind and db.planGrind[mapID] then
    for _, g in ipairs((ns.GrindList and ns.GrindList(mapID)) or ns.grind[mapID] or {}) do
      if g[3] == gs then Add(g[1], g[2], TR"Grind " .. g[3], "grind", g) end
    end
  end
  -- Erkunden ist optional: ohne "Alles erkunden" nur Gebiete, die sowieso auf dem Weg liegen
  -- (mit Quest, Flugpunkt usw. zusammengelegt). Der Einstieg bleibt als Startpunkt.
  if not db.exploreAll then
    local entry = res[1]
    local keep = {}
    for _, p in ipairs(res) do
      if p.kind ~= "explore" or p == entry then table.insert(keep, p) end
    end
    if #keep >= 2 then
      for i = #res, 1, -1 do res[i] = nil end
      for _, p in ipairs(keep) do table.insert(res, p) end
    end
  end
  -- von Hand verschobene Punkte
  local ov = db.override[mapID]
  if ov then
    for _, p in ipairs(res) do
      local o = p[3] and ov[p[3]]
      if o then p[1], p[2] = o[1], o[2] end
    end
  end
  if db.optimize ~= false then Optimize(res, mapID) end
  -- eigene Wegpunkte, z.B. um Berge herum
  for i, v in ipairs(db.via[mapID] or {}) do
    local pt = { v[1], v[2], TR"Wegpunkt " .. i, kind = "via", tags = { via = true }, viaIndex = i }
    local at
    if v.after then
      for j, q in ipairs(res) do
        if q.kind ~= "via" and q[3] == v.after then at = j end
      end
      if at then
        -- hinter andere Wegpunkte im selben Stueck
        while res[at + 1] and res[at + 1].kind == "via" do at = at + 1 end
      end
    end
    if at then table.insert(res, at + 1, pt) else InsertCheapest(res, pt) end
  end
  return res
end

-- erledigte Punkte pro Zone, Fortschritt = erster noch offener Punkt
local function DoneSet(mapID)
  db.done = db.done or {}
  db.done[mapID] = db.done[mapID] or {}
  return db.done[mapID]
end

local function SyncProgress(mapID, res)
  db.done = db.done or {}
  local d = db.done[mapID]
  if not d then
    -- alte Speicherstaende: bisherige Nummer uebernehmen
    d = {}
    local prog = db.progress[mapID] or 1
    for i = 1, math.min(prog - 1, #res) do if res[i][3] then d[res[i][3]] = true end end
    db.done[mapID] = d
  end
  -- zurueckgestellte Punkte (zu hoch) zaehlen, bis man das Level hat
  local df = db.defer and db.defer[mapID]
  local L = UnitLevel("player")
  local idx = #res + 1
  for i, p in ipairs(res) do
    local deferred = df and p[3] and df[p[3]] and L < df[p[3]]
    if not (p[3] and d[p[3]]) and not deferred then idx = i; break end
  end
  db.progress[mapID] = idx
end
ns.DoneSet = DoneSet

-- Ab welchem Level gehoert ein Ort dazu? Naechster Quest Hub in der Naehe, sonst Zonen Minimum
local function LocStage(mapID, x, y)
  -- naechster Quest Hub, egal wie weit (weit weg vom Start = spaeteres Gebiet)
  local best, bd
  for _, h in ipairs(ns.hubs[mapID] or {}) do
    local d = Dist(x, y, h[1], h[2])
    if not bd or d < bd then best, bd = h[4], d end
  end
  local z = ns.zones[mapID]
  local s = best or (z and z.min) or 1
  -- Mobs in der Naehe zaehlen auch: dort erst hin, wenn man sie schafft
  for _, g in ipairs((ns.GrindList and ns.GrindList(mapID)) or ns.grind[mapID] or {}) do
    if Dist(x, y, g[1], g[2]) < 0.08 then s = math.max(s, g[4] - 2) end
  end
  return s
end
ns.LocStage = LocStage

local function PointStage(mapID, p)
  local s = LocStage(mapID, p[1], p[2])
  local t = p.tags or {}
  if type(t.quest) == "table" and t.quest[4] and t.quest[4] < 99 then s = math.max(s, t.quest[4] - 1) end
  if type(t.grind) == "table" then s = math.max(s, t.grind[4] - 1) end
  return s
end

-- 2-opt auf einer Liste, der erste Punkt bleibt fest
local function TwoOpt(list)
  local n = #list
  local function D(i, j) return Dist(list[i][1], list[i][2], list[j][1], list[j][2]) end
  if n < 4 then return end
  for _ = 1, 10 do
    local improved = false
    for i = 1, n - 2 do
      for k = i + 2, n do
        local before = D(i, i + 1) + (k < n and D(k, k + 1) or 0)
        local after = D(i, k) + (k < n and D(i + 1, k + 1) or 0)
        if after + 1e-9 < before then
          local a, b = i + 1, k
          while a < b do list[a], list[b] = list[b], list[a]; a = a + 1; b = b - 1 end
          improved = true
        end
      end
    end
    if not improved then break end
  end
end

-- naechster Nachbar ab einem Startpunkt, danach 2-opt
local function Chain(start, pts)
  local list = { start }
  local left = {}
  for _, p in ipairs(pts) do table.insert(left, p) end
  while #left > 0 do
    local cur = list[#list]
    local bi, bd
    for i, p in ipairs(left) do
      local d = Dist(cur[1], cur[2], p[1], p[2])
      if not bd or d < bd then bi, bd = i, d end
    end
    table.insert(list, table.remove(left, bi))
  end
  TwoOpt(list)
  return list
end

-- Weg: erledigte Punkte nach vorne, dann was zum Level passt, hoehere Gebiete erst spaeter
Optimize = function(res, mapID)
  local d = (db.done and db.done[mapID]) or {}
  local doneList, openList = {}, {}
  for _, p in ipairs(res) do
    if p[3] and d[p[3]] then table.insert(doneList, p) else table.insert(openList, p) end
  end
  local L = UnitLevel("player")
  -- Gruppen: jetzt (bis Level +2), dann in 3er Level Stufen
  local groups, keys = {}, {}
  for _, p in ipairs(openList) do
    local s = PointStage(mapID, p)
    p.stage = s
    local k = (s <= L + 2) and 0 or math.floor((s - L - 3) / 3) + 1
    if not groups[k] then groups[k] = {}; table.insert(keys, k) end
    table.insert(groups[k], p)
  end
  table.sort(keys)
  -- Startpunkt: letzter erledigter, sonst Einstieg (erster Punkt der Basis Route)
  local entry = res[1]
  local out = {}
  local cur = doneList[#doneList]
  for _, k in ipairs(keys) do
    local pts = groups[k]
    local start, skipFirst = cur, true
    if not start then
      -- ohne erledigte Punkte: Einstieg der Route bleibt vorne
      local idx = 1
      for i, p in ipairs(pts) do if p == entry then idx = i; break end end
      start, skipFirst = table.remove(pts, idx), false
    end
    local chain = Chain(start, pts)
    for i = (skipFirst and 2 or 1), #chain do table.insert(out, chain[i]) end
    cur = chain[#chain]
  end
  for i = #res, 1, -1 do res[i] = nil end
  for _, p in ipairs(doneList) do table.insert(res, p) end
  for _, p in ipairs(out) do table.insert(res, p) end
end

local function GetRoute(mapID)
  if not mapID or not db then return nil end
  local base = BaseRoute(mapID)
  if not base and not ns.fp[mapID] and not ns.hubs[mapID] and not ns.grind[mapID] and not (db.via[mapID] and #db.via[mapID] > 0)
    and not (ns.qStarts and ns.qStarts[mapID]) then return nil end
  local key = tostring(base) .. ":" .. (base and #base or 0) .. ":" .. (db.learnedRev or 0) .. ":" .. UnitLevel("player")
  local c = routeCache[mapID]
  if c and c.key == key then return c.res end
  local res = BuildRoute(mapID)
  routeCache[mapID] = { key = key, res = res }
  SyncProgress(mapID, res)
  return res
end
ns.GetRoute = GetRoute
ns.PlayerMap = PlayerMap
ns.ZoneName = ZoneName

local function ZoneDone(zoneID)
  local r = GetRoute(zoneID)
  return r and (db.progress[zoneID] or 1) > #r
end

------------------------------------------------------------
-- XP Messung
------------------------------------------------------------
-- Grundwert Erkundungs XP pro Gebiet (aus Classic abgeleitet)
local function ExploreBase(areaLvl)
  return 7 * areaLvl + 15
end

local function ExploreRatio()
  local s = db.stats
  if s.exN and s.exN >= 3 then return s.exRatio end
  return 1
end

-- Kill XP pro Stunde fuer ein Level, gemessen oder geschaetzt
local function MobXP(L) return 5 * L + 45 end

-- Gruppen XP nach Classic Regeln: XP vom Mob mal Gruppenbonus, verteilt nach Level Anteil
local GROUP_BONUS = { 1, 1, 1.166, 1.3, 1.4 }
-- 20.3t (S 06:36, Sim Duo: echt 15.9k XP/Std beim Grinden, gerechnet 26.5k): in der Gruppe Grinden etwas langsamer
-- rechnen (Suchen, Mobs teilen, Warten auf den anderen). Solo unveraendert
local GROUP_GRIND_F = 0.8
function ns.GroupGrindF() return (ns.GroupSize and ns.GroupSize() or 1) > 1 and GROUP_GRIND_F or 1 end
local function GroupSize()
  local n = (IsInGroup and IsInGroup() and GetNumGroupMembers and GetNumGroupMembers()) or 0
  if n < 1 then n = 1 end
  if n > 5 then n = 5 end
  return n
end
-- Anteil an den Kill XP, den du in der jetzigen Gruppe bekommst (solo = 1)
-- Forever: XP Boni aus Buffs (17.5). Gut gesaettigt (Essen) +5 % auf Kill XP, haelt ca 15 Minuten.
-- Schlafsack (Well-Rested, Zauber 429959) +1 % je Stapel (hoechstens 3), auf Kill und Quest XP, haelt 1 bis 2 Stunden.
-- Die Route rechnet jeden Buff nur fuer die Zeit ein, die er noch laeuft (ns.XPBuffs), nicht fuer den ganzen Weg.
local FOOD_PCT, BAG_PCT, BAG_MAX = 0.05, 0.01, 3
local function Auras()
  local out, i = {}, 1
  while i <= 40 do
    local name, count, expires, sid, icon
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
      local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
      if not a then break end
      name, count, expires, sid, icon = a.name, a.applications, a.expirationTime, a.spellId, a.icon
    elseif UnitBuff then
      local n, ic, c, _, _, e, _, _, _, id = UnitBuff("player", i)
      if not n then break end
      name, count, expires, sid, icon = n, c, e, id, ic
    else break end
    out[#out + 1] = { name = name, count = count, expires = expires, id = sid, icon = icon }
    i = i + 1
  end
  return out
end
ns.PlayerAuras = Auras
local function IsFood(a)
  local ln = tostring(a.name or ""):lower()
  local ic = tostring(a.icon or ""):lower()
  return a.icon == 136000 or ic:find("spell_misc_food", 1, true) or ln:find("well fed", 1, true) or ln:find("gesättigt", 1, true) or ln:find("gesaettigt", 1, true)
end
local function IsBag(a)
  local ln = tostring(a.name or ""):lower()
  return a.id == 429959 or ln:find("well-rested", 1, true) or ln:find("well rested", 1, true) or ln:find("ausgeschlafen", 1, true)
end
-- aktive XP Buffs: { kind, pct, left (Sekunden), quest (gilt auch fuer Quest XP), name, stacks }
function ns.XPBuffs()
  local out = {}
  local ok, list = pcall(Auras)
  local now = GetTime()
  for _, a in ipairs(ok and list or {}) do
    local left = (a.expires and a.expires > 0) and math.max(0, a.expires - now) or nil
    if IsFood(a) then
      out[#out + 1] = { kind = "food", pct = FOOD_PCT, left = left or 900, quest = false, name = a.name }
    elseif IsBag(a) then
      local st = math.min(BAG_MAX, math.max(1, tonumber(a.count) or 1))
      out[#out + 1] = { kind = "bag", pct = BAG_PCT * st, left = left or 3600, quest = true, name = a.name, stacks = st }
    end
  end
  return out
end
-- Bonus auf Kill XP genau jetzt (fuers Messen: der Bonus gehoert nicht zum Mob, und fuers Test Log)
function ns.KillXPBonus()
  local b = 0
  for _, x in ipairs(ns.XPBuffs()) do b = b + x.pct end
  return 1 + b
end

-- Schlafsack bereit? (in der Tasche, keine Abklingzeit, Buff nicht aktiv)
function ns.SleepingBagReady()
  if not ns.HasSleepingBag() then return false end
  for _, x in ipairs(ns.XPBuffs()) do if x.kind == "bag" then return false end end
  local cd = (C_Container and C_Container.GetItemCooldown) or ns.Api.GetItemCooldown
  if cd then
    local st, dur = cd(211527)
    if st and dur and dur > 1.5 and st + dur > GetTime() then return false end
  end
  return true
end

-- Forever: Cozy Sleeping Bag in der Tasche? Zaehlt beim Ausloggen wie ein Gasthaus.
local bagCache = { t = -99 }
local HasSleepingBagRaw
-- haeufig gefragt (Hinweise, Schritt Text): Ergebnis 5 Sekunden merken
function ns.HasSleepingBag()
  local now = GetTime and GetTime() or 0
  if now - bagCache.t < 5 then return bagCache.has, bagCache.name end
  local ok, has, name = pcall(HasSleepingBagRaw)
  bagCache.t, bagCache.has, bagCache.name = now, ok and has or false, ok and name or nil
  return bagCache.has, bagCache.name
end
HasSleepingBagRaw = function()
  -- Gemuetlicher Schlafsack, Item 211527
  local cnt = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(211527)) or (ns.Api.GetItemCount and ns.Api.GetItemCount(211527)) or 0
  if cnt > 0 then return true, (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(211527)) or TR"den Schlafsack" end
  local slots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  local link = (C_Container and C_Container.GetContainerItemLink) or ns.Api.GetContainerItemLink
  if not (slots and link) then return false end
  for bag = 0, 4 do
    for slot = 1, (slots(bag) or 0) do
      local l = link(bag, slot)
      local nm = l and l:match("%[(.-)%]")
      if nm then
        local ln = nm:lower()
        if ln:find("sleeping bag", 1, true) or ln:find("schlafsack", 1, true) then return true, nm end
      end
    end
  end
  return false
end

function ns.GroupXPShare()
  local n = GroupSize()
  if n <= 1 then return 1, 1 end
  local L = UnitLevel("player") or 1
  local sum, cnt = L, 1
  for i = 1, 4 do
    local u = "party" .. i
    if UnitExists and ns.Api.U(UnitExists, u) then
      local l = UnitLevel(u)
      if type(l) == "number" and l > 0 then sum = sum + l; cnt = cnt + 1 end
    end
  end
  if cnt < n then sum = sum + L * (n - cnt) end -- unbekannte Level wie deins zaehlen
  return (GROUP_BONUS[n] or 1.4) * L / sum, n
end
ns.GroupSize = GroupSize
-- Messwerte getrennt: solo in db.stats, Gruppe je Groesse in db.stats.grp["2"] bis ["5"]
local function Bucket(n)
  n = n or GroupSize()
  local s = db.stats
  if n <= 1 then return s end
  s.grp = s.grp or {}
  local k = tostring(n)
  s.grp[k] = s.grp[k] or {}
  return s.grp[k]
end
ns.StatBucket = Bucket

local function KillRate(L)
  local s = Bucket()
  local kph = ns.KillSeconds and 3600 / ns.KillSeconds(0) or 120
  if ns.KillBreakdown and ns.KillBreakdown(0) then
    kph = 3600 / ns.KillSeconds(0)
  elseif s.killN and s.killN >= 8 and s.killGapAvg and s.killGapAvg > 0 then
    kph = 3600 / s.killGapAvg
  end
  local ratio = (s.killN and s.killN >= 3) and s.killRatio or 1
  return kph * MobXP(L) * ratio * ns.GroupXPShare() * ns.GroupGrindF(), (s.killN or 0) >= 8
end

local function QuestXP(L) return 65 * L + 2 * L * L end
ns.MobXP = MobXP
ns.KillRate = function(L) return KillRate(L) end
-- Sekunden pro Kill inkl. Suchen und Laufen zwischen den Mobs (gemessen, sonst geschaetzt)
-- Median einer Liste (robust gegen Ausreisser wie Adds oder Flucht)
local function Median(t)
  if not t or #t == 0 then return nil end
  local c = {}
  for i, v in ipairs(t) do c[i] = v end
  table.sort(c)
  local m = math.floor((#c + 1) / 2)
  if #c % 2 == 0 then return (c[m] + c[m + 1]) / 2 end
  return c[m]
end

-- Zeit pro Kill aus den letzten 20 Kills: Kampfzeit (je nach Mob Level) plus Pause dazwischen
-- (Laufen zum naechsten Mob, Essen, Reg). diff = Mob Level minus dein Level.
function ns.KillBreakdown(diff, n)
  if not db then return nil end
  n = n or GroupSize()
  if n > 1 then
    local f, d, c = ns.KillBreakdown(diff, -1)
    if f then return f, d, c end
    -- noch keine Messung in dieser Gruppengroesse: solo Werte, Mobs sterben schneller
    f, d, c = ns.KillBreakdown(diff, 1)
    if f then return f / (0.7 * n + 0.3), d, c end
    return nil
  end
  local s = (n == -1) and Bucket() or db.stats
  diff = math.max(-5, math.min(5, math.floor((diff or 0) + 0.5)))
  local all = {}
  for d, list in pairs(s.fights or {}) do
    for _, v in ipairs(list) do table.insert(all, { d = tonumber(d) or 0, v = v }) end
  end
  if #all < 5 then return nil end
  local own = s.fights[tostring(diff)]
  local fight
  if own and #own >= 3 then
    fight = Median(own)
  else
    -- zu wenig Kills auf dieser Stufe: von allen hochrechnen, pro Level ca 12 Prozent laenger
    local norm = {}
    for _, e in ipairs(all) do table.insert(norm, e.v / (1 + 0.12 * e.d)) end
    fight = Median(norm) * (1 + 0.12 * diff)
  end
  local down = Median(s.downs) or 8
  return fight, down, #all
end

function ns.KillSeconds(diff)
  local fight, down = ns.KillBreakdown(diff)
  local g
  if fight then
    g = fight + down
  else
    local s = db and Bucket() or {}
    -- noch keine eigenen Kills (neuer Charakter): unter Level 20 langsamer schaetzen. Im Log vom Troll Krieger
    -- waren es auf Level 1 bis 4 ca 40 bis 46 Sek pro Kill mit Suchen, gerechnet waren 27
    local base = 28
    local L = ns.simLevel or UnitLevel("player") or 1
    if L < 10 then
      local _, cls = UnitClass("player")
      base = ({ WARRIOR = 40, ROGUE = 38, PALADIN = 38, PRIEST = 36, SHAMAN = 36, DRUID = 36, MAGE = 34, WARLOCK = 32, HUNTER = 30 })[cls or ""] or 36
    elseif L < 20 then
      base = 32
    end
    g = (s.killN and s.killN >= 8 and s.killGapAvg) or (base / (0.7 * GroupSize() + 0.3))
  end
  if g < 8 then g = 8 elseif g > 90 then g = 90 end
  return g
end

local exploredPattern, killPattern, exploredOrder, killOrder
local S1, S2 = string.char(1), string.char(2)
local function BuildPatterns()
  -- Vorlage wie "%1$s entdeckt: %2$d Erfahrung erhalten." in ein Suchmuster umbauen
  local function Conv(str)
    if type(str) ~= "string" then return nil end
    local order = {}
    local p = str:gsub("%%(%d?)%$?([sd])", function(n, t)
      table.insert(order, tonumber(n) or (#order + 1))
      return t == "s" and S1 or S2
    end)
    p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    p = p:gsub(S1, "(.+)"):gsub(S2, "(%%d+)")
    return "^" .. p, order
  end
  exploredPattern, exploredOrder = Conv(ERR_ZONE_EXPLORED_XP)
  killPattern, killOrder = Conv(COMBATLOG_XPGAIN_FIRSTPERSON)
end

-- Treffer in der richtigen Reihenfolge zurueckgeben
local function MatchOrdered(m, pat, order)
  if not pat then return end
  local ok, a, b, c = pcall(string.match, m, pat)
  if not ok or not a then return end
  local caps, out = { a, b, c }, {}
  for i, pos in ipairs(order or {}) do out[pos] = caps[i] end
  return out[1], out[2]
end

local lastMsg, lastMsgTime = nil, 0

local function OnExplored(name, xp)
  local now = GetTime()
  if name == lastMsg and now - lastMsgTime < 2 then return end
  lastMsg, lastMsgTime = name, now
  if ns.Count then ns.Count("explore", xp) end

  local mapID = PlayerMap()
  local s = db.stats
  -- Verhaeltnis gemessen zu geschaetzt mitteln
  local z = mapID and ns.zones[mapID]
  local L = UnitLevel("player")
  local eff = math.min(z and z.area or L, L + 5)
  local ratio = xp / ExploreBase(eff)
  s.exN = (s.exN or 0) + 1
  s.exRatio = s.exRatio and (s.exRatio * 0.8 + ratio * 0.2) or ratio
  s.exSum = (s.exSum or 0) + xp

  -- echte Position lernen
  if mapID then
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local x, y = pos:GetXY()
      db.learned[mapID] = db.learned[mapID] or {}
      db.learned[mapID][name] = { x, y }
      -- Forever Namen weichen ab: naechsten noch nicht gelernten Punkt nehmen
      local base = BaseRoute(mapID)
      if base then
        local exact = false
        for _, p in ipairs(base) do if p[3] == name then exact = true end end
        -- englischer Client: Namen sind uebersetzt, Gross/Klein und Satzzeichen koennen abweichen
        if not exact and ns.EN then
          local function Norm(s) return (tostring(s or ""):lower():gsub("[%p%s]", "")) end
          local nn = Norm(name)
          for _, p in ipairs(base) do
            if p[3] and Norm(p[3]) == nn then
              exact = true
              db.learned[mapID][p[3]] = { x, y }
              db.renames[mapID] = db.renames[mapID] or {}
              db.renames[mapID][p[3]] = name
              break
            end
          end
        end
        if not exact then
          local best, bd
          for _, p in ipairs(base) do
            if not db.learned[mapID][p[3]] then
              local d = Dist(p[1], p[2], x, y)
              if d < 0.12 and (not bd or d < bd) then best, bd = p, d end
            end
          end
          if best then
            db.learned[mapID][best[3]] = { x, y }
            db.renames[mapID] = db.renames[mapID] or {}
            db.renames[mapID][best[3]] = name
          end
        end
      end
      db.learnedRev = (db.learnedRev or 0) + 1
    end
  end
  Print((TR"Entdeckt: %s, %d XP (Schnitt %.0f%% der Schätzung)"):format(name, xp, (s.exRatio or 1) * 100))

  -- wenn das der naechste Punkt war, weiter
  local route = GetRoute(mapID)
  local idx = db.progress[mapID] or 1
  if route and route[idx] and route[idx][3] == name then
    ns.Advance(mapID, 1)
  end
end

-- Kampfzeit messen: Start des Kampfs bis zum Kill, bei mehreren Mobs ab dem letzten Kill
local combatStart, combatEnd, lastKillAt
local cf = CreateFrame("Frame")
cf:RegisterEvent("PLAYER_REGEN_DISABLED")
cf:RegisterEvent("PLAYER_REGEN_ENABLED")
cf:SetScript("OnEvent", function(_, ev)
  local now = GetTime()
  if ev == "PLAYER_REGEN_DISABLED" then
    combatStart = now
    if combatEnd and db then
      local down = now - combatEnd
      if down > 0 and down < 120 then -- laengere Pausen sind Questen, Reisen oder AFK
        local b = Bucket()
        b.downs = b.downs or {}
        table.insert(b.downs, down)
        while #b.downs > 20 do table.remove(b.downs, 1) end
      end
    end
  else
    combatEnd = now
  end
end)
local function RecordFight(xp)
  if not (db and combatStart) then return end
  local now = GetTime()
  local from = combatStart
  if lastKillAt and lastKillAt > from then from = lastKillAt end
  local t = now - from
  lastKillAt = now
  if t < 2 or t > 180 then return end
  -- Mob Level: das tote Ziel, sonst aus den XP geschaetzt
  local L = UnitLevel("player")
  local diff
  if UnitExists and Plain(ns.Api.U(UnitExists, "target")) and UnitIsDead and Plain(ns.Api.U(UnitIsDead, "target")) then
    local ml = Plain(UnitLevel("target"))
    if ml and ml > 0 then diff = ml - L end
  end
  if not diff then
    local r = xp / (MobXP(L) * ns.GroupXPShare())
    local rest = GetXPExhaustion and Plain(GetXPExhaustion())
    if type(rest) == "number" and rest > 0 then r = r / 2 end -- Ruhebonus verdoppelt Kill XP
    r = r / ns.KillXPBonus() -- Essen und Schlafsack gehoeren nicht zum Mob
    diff = (r >= 1) and (r - 1) / 0.05 or -(1 - r) * 5
  end
  diff = math.max(-5, math.min(5, math.floor(diff + 0.5)))
  local s = Bucket()
  s.fights = s.fights or {}
  local key = tostring(diff)
  s.fights[key] = s.fights[key] or {}
  table.insert(s.fights[key], t)
  while #s.fights[key] > 20 do table.remove(s.fights[key], 1) end
end

local lastKill
local function OnKillXP(xp)
  RecordFight(xp)
  if ns.Count then ns.Count("kill", xp) end
  local s = Bucket()
  local L = UnitLevel("player")
  local ratio = xp / (MobXP(L) * ns.GroupXPShare())
  -- ausgeruht: die Zahl enthaelt den Bonus (doppelt), der gehoert nicht zum Mob
  local rest = GetXPExhaustion and Plain(GetXPExhaustion())
  if type(rest) == "number" and rest > 0 then ratio = ratio / 2 end
  ratio = ratio / ns.KillXPBonus() -- Essen und Schlafsack ebenso
  if ratio > 3 then ratio = 3 end -- Elites nicht zu stark werten
  s.killN = (s.killN or 0) + 1
  s.killRatio = s.killRatio and (s.killRatio * 0.9 + ratio * 0.1) or ratio
  local now = GetTime()
  if lastKill then
    local gap = now - lastKill
    if gap < 120 then -- nur echtes Grinden zaehlen
      s.killGapAvg = s.killGapAvg and (s.killGapAvg * 0.9 + gap * 0.1) or gap
    end
  end
  lastKill = now
end

------------------------------------------------------------
-- Pfeil und Ansagen
------------------------------------------------------------
-- (frueher TomTom Wegpunkt und AzerothGPS, raus: nur noch der eigene Pfeil)
local function SetArrow() end

local function GrindTarget(mapID, g)
  local spot = ns.planGrindSpot and ns.planGrindSpot[mapID]
  if g and spot and g[3] ~= spot then return nil end
  return db.planGrind and db.planGrind[mapID]
end

-- Wo sollte man laut Level Plan gerade sein, und wohin danach?
function ns.PlanNow(L)
  L = L or UnitLevel("player")
  local plan = ns.plan
  if not plan or #plan == 0 then return end
  for i, sg in ipairs(plan) do
    if sg[3] > L or (sg[2] == sg[3] and sg[3] == L) then
      local nxt
      for j = i + 1, #plan do
        if plan[j][1] ~= sg[1] then nxt = plan[j]; break end
      end
      return sg, nxt
    end
  end
  return plan[#plan]
end

local function Announce(mapID)
  -- es gibt nur noch die optimierte Route: die alte Zonenroute meldet sich nicht mehr im Chat
  if db and db.optMode then return end
  local route = GetRoute(mapID)
  if not route then return end
  local idx = db.progress[mapID] or 1
  local p = route[idx]
  if not p then
    Print(ZoneName(mapID) .. TR" ist fertig!")
    -- laut Level Plan, sonst die naechste Zone in der Reihenfolge
    local cur, nxt = ns.PlanNow()
    local nextID, upto
    if cur and cur[1] ~= mapID then nextID, upto = cur[1], cur[3]
    elseif nxt then nextID, upto = nxt[1], nxt[3] end
    if not nextID then
      for i, id in ipairs(ns.zoneOrder) do
        if id == mapID and ns.zoneOrder[i + 1] then nextID = ns.zoneOrder[i + 1] end
      end
    end
    if nextID then
      Print(TR"Weiter nach: " .. ZoneName(nextID) .. (upto and (TR" (bis ca Level " .. upto .. ")") or ""))
      local hint = ns.travelHint and ns.travelHint[mapID .. ">" .. nextID]
      if hint then Print("  " .. hint) end
    end
    SetArrow(mapID, nil)
    return
  end
  Print((TR"Nächster Punkt %d/%d: %s (%.0f, %.0f)"):format(idx, #route, p[3] or "?", p[1] * 100, p[2] * 100))
  local t = p.tags or {}
  if t.fp then Print(TR"  Flugpunkt, Flugmeister ansprechen!") end
  if type(t.quest) == "table" and ns.QuestHint then
    Print("  " .. (ns.QuestHint(p) or TR"Quests annehmen"))
  end
  if type(t.turnin) == "table" and ns.QuestHint then
    Print("  " .. (ns.QuestHint({ tags = { turnin = t.turnin } }) or TR"Quests abgeben"))
  end
  if type(t.grind) == "table" then
    local gt = GrindTarget(mapID, t.grind)
    if gt then
      Print((TR"  Grind Spot, Mobs Level %d bis %d, hier grinden bis Level %d"):format(t.grind[4], t.grind[5], gt))
    else
      Print((TR"  Grind Spot, Mobs Level %d bis %d (laut Plan nicht nötig)"):format(t.grind[4], t.grind[5]))
    end
  end
  SetArrow(mapID, p)
end

------------------------------------------------------------
-- Zeichnen
------------------------------------------------------------
local GRAY   = { 0.5, 0.5, 0.5 }
local YELLOW = { 1, 0.75, 0.1 }
local GREEN  = { 0.1, 1, 0.3 }
local PURPLE = { 0.75, 0.45, 1 }
local KINDCOL = {
  explore = YELLOW,
  fp      = { 0.2, 0.6, 1 },
  quest   = { 1, 0.5, 0 },
  grind   = { 1, 0.2, 0.2 },
  via     = { 0.9, 0.9, 0.9 },
  turnin  = { 0.3, 1, 0.6 },
  obj     = { 1, 0.4, 0.8 },
}
local KINDTXT = { explore = "", fp = TR" FP", quest = " Q", grind = " G", via = " W", turnin = " A", obj = " Z" }
local KINDNAME = { explore = TR"Entdecken", fp = TR"Flugpunkt", quest = TR"Quests annehmen", grind = TR"Grinden", via = TR"Wegpunkt", turnin = TR"Quests abgeben", obj = TR"Questziel" }
ns.KINDNAME = KINDNAME
ns.KINDCOL = KINDCOL

local function HideAll()
  for _, o in ipairs(lines) do o:Hide() end
  for _, o in ipairs(pins) do o:Hide() end
  for _, o in ipairs(labels) do o:Hide() end
  for _, o in ipairs(rings) do o:Hide() end
  for _, o in ipairs(icons) do o:Hide() end
  nLine, nPin, nLab = 0, 0, 0
  nRing, nIcon = 0, 0
end

-- Zoom: Symbole, Kreise, Linien und Zahlen werden beim Reinzoomen im Verhaeltnis zur Karte kleiner
-- (auf dem Bildschirm bleiben sie fast gleich gross, statt riesig zu werden und sich zu ueberdecken)
local ZF = 1
local zoomFont = {}
local function ZoomFactor()
  local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
  if not sc then return 1 end
  local s = sc.GetCanvasScale and sc:GetCanvasScale()
  local s0 = sc.GetScaleForMinZoom and sc:GetScaleForMinZoom()
  local f
  if type(s) == "number" and type(s0) == "number" and s > 0 and s0 > 0 then
    f = (s0 / s) ^ 0.85
  elseif sc.GetCanvasZoomPercent then
    local pc = sc:GetCanvasZoomPercent()
    f = (type(pc) == "number") and (1 - 0.6 * pc) or 1
  else
    f = 1
  end
  if f > 1 then f = 1 elseif f < 0.3 then f = 0.3 end
  return f
end
local function Z(v) return v * ZF end
-- Schrift der Zahlen und Namen auf der Karte mitskalieren
local function ZoomFont(t)
  local base = zoomFont.path and zoomFont
  if not base and GameFontNormalLarge and GameFontNormalLarge.GetFont then
    local path, size, flags = GameFontNormalLarge:GetFont()
    if path then zoomFont.path, zoomFont.size, zoomFont.flags = path, size or 16, flags; base = zoomFont end
  end
  if base and t.SetFont then pcall(t.SetFont, t, base.path, math.max(7, base.size * ZF), base.flags) end
end

local function EnsureOverlay()
  if overlay or not WorldMapFrame then return end
  local canvas = WorldMapFrame:GetCanvas()
  overlay = CreateFrame("Frame", nil, canvas)
  overlay:SetAllPoints(canvas)
  overlay:SetFrameStrata(WorldMapFrame:GetFrameStrata())
  overlay:SetFrameLevel(9000) -- ueber allen Karten Ebenen (Erkundung, Pins)
end

local function AddLine(ax, ay, bx, by, c, a, thick)
  ax, ay = Cv(ax, ay)
  bx, by = Cv(bx, by)
  if not (ax and ay and bx and by) then return end
  nLine = nLine + 1
  local l = lines[nLine]
  if not l then
    l = overlay:CreateLine(nil, "OVERLAY", nil, 5)
    lines[nLine] = l
  end
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  l:SetThickness(math.max(1.2, (thick or 4) * ZF))
  l:SetColorTexture(c[1], c[2], c[3], a)
  l:ClearAllPoints()
  l:SetStartPoint("TOPLEFT", overlay, ax * w, -ay * h)
  l:SetEndPoint("TOPLEFT", overlay, bx * w, -by * h)
  l:Show()
end

-- kind: Symbol aus dem Punkte Atlas (Figma), sonst ein farbiges Kaestchen
local function AddPin(x, y, size, c, text, kind)
  x, y = Cv(x, y)
  if not (x and y) then return end
  nPin = nPin + 1
  local p = pins[nPin]
  if not p then
    p = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    pins[nPin] = p
  end
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  if kind and ns.T and ns.T.PinTex and ns.T.PinTex(p, kind) then
    size = size + 8
  else
    p:SetTexture("Interface\\Buttons\\WHITE8X8")
    p:SetTexCoord(0, 1, 0, 1)
    p:SetVertexColor(c[1], c[2], c[3], 1)
  end
  p:SetSize(Z(size), Z(size))
  p:ClearAllPoints()
  p:SetPoint("CENTER", overlay, "TOPLEFT", x * w, -y * h)
  p:Show()
  if text then
    nLab = nLab + 1
    local t = labels[nLab]
    if not t then
      t = overlay:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
      labels[nLab] = t
    end
    ZoomFont(t)
    t:SetText(text)
    t:ClearAllPoints()
    t:SetPoint("BOTTOM", p, "TOP", 0, Z(2))
    t:Show()
  end
  return true
end

-- runder Ring (Kreis Textur, eingefaerbt)
local RING_TEX = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
local function AddRing(x, y, size, c, a, layer)
  x, y = Cv(x, y)
  if not x then return end
  nRing = nRing + 1
  local r = rings[nRing]
  if not r then
    r = overlay:CreateTexture(nil, "OVERLAY", nil, 4)
    r:SetTexture(RING_TEX)
    rings[nRing] = r
  end
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  r:SetDrawLayer("OVERLAY", layer or 4)
  r:SetSize(Z(size), Z(size))
  r:SetVertexColor(c[1], c[2], c[3], a or 1)
  r:ClearAllPoints()
  r:SetPoint("CENTER", overlay, "TOPLEFT", x * w, -y * h)
  r:Show()
end

-- Quest Symbol (! annehmen, ? abgeben) ueber dem Punkt
local ICON_AVAIL = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_ACTIVE = "Interface\\GossipFrame\\ActiveQuestIcon"
local function AddIcon(x, y, tex, dx, dy, size)
  x, y = Cv(x, y)
  if not x then return end
  nIcon = nIcon + 1
  local t = icons[nIcon]
  if not t then
    t = overlay:CreateTexture(nil, "OVERLAY", nil, 7)
    icons[nIcon] = t
  end
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  t:SetTexture(tex)
  t:SetSize(Z(size or 18), Z(size or 18))
  t:ClearAllPoints()
  t:SetPoint("CENTER", overlay, "TOPLEFT", x * w + Z(dx or 0), -y * h + Z(dy or 0))
  t:Show()
end

-- Questgeber: Ring und Symbol; beides (abgeben und annehmen) bekommt einen Doppelring
local function QuestMarker(p, isNext)
  local t = p.tags or {}
  local hasTurn = type(t.turnin) == "table"
  local hasQuest = type(t.quest) == "table"
  if not (hasTurn or hasQuest) then return false end
  local x, y = p[1], p[2]
  if ns.T and ns.T.PinTex then
    -- Symbol aus Figma: ! annehmen, ? abgeben, beides geteilt
    if isNext then AddRing(x, y, 36, { 0.1, 1, 0.3 }, 0.4, 1) end
    AddPin(x, y, 16, { 1, 1, 1 }, nil, (hasTurn and hasQuest) and "both" or (hasTurn and "turnin" or "quest"))
    return true, hasTurn and hasQuest, true
  end
  if hasTurn and hasQuest then
    AddRing(x, y, 34, { 1, 0.5, 0 }, 0.95, 2)       -- aussen orange: annehmen
    AddRing(x, y, 26, { 0, 0, 0 }, 0.85, 3)
    AddRing(x, y, 22, { 0.3, 1, 0.6 }, 0.95, 4)     -- innen gruen: abgeben
    AddRing(x, y, 14, { 0, 0, 0 }, 0.85, 5)
    AddIcon(x, y, ICON_ACTIVE, -8, 26, 18)
    AddIcon(x, y, ICON_AVAIL, 8, 26, 18)
  elseif hasTurn then
    AddRing(x, y, 24, { 0.3, 1, 0.6 }, 0.95, 3)
    AddRing(x, y, 16, { 0, 0, 0 }, 0.85, 4)
    AddIcon(x, y, ICON_ACTIVE, 0, 24, 18)
  else
    AddRing(x, y, 24, { 1, 0.5, 0 }, 0.95, 3)
    AddRing(x, y, 16, { 0, 0, 0 }, 0.85, 4)
    AddIcon(x, y, ICON_AVAIL, 0, 24, 18)
  end
  if isNext then AddRing(x, y, 42, { 0.1, 1, 0.3 }, 0.35, 1) end
  return true, hasTurn and hasQuest
end

-- genaue Route in der Zone
local function DrawZone(mapID, route)
  local nextIdx = db.progress[mapID] or 1
  for i, p in ipairs(route) do
    if i > 1 then
      local a = route[i - 1]
      local done = i <= nextIdx
      local c, al = done and GRAY or YELLOW, done and 0.6 or 0.9
      local lx, ly = a[1], a[2]
      for _, q in ipairs(DetourPath(mapID, a[1], a[2], p[1], p[2])) do
        AddLine(lx, ly, q[1], q[2], c, al)
        lx, ly = q[1], q[2]
      end
      AddLine(lx, ly, p[1], p[2], c, al)
    end
    local c
    if i < nextIdx then c = GRAY
    elseif i == nextIdx then c = GREEN
    else c = KINDCOL[p.kind] or YELLOW end
    local big = (i == nextIdx) or p.kind ~= "explore"
    local marked, both = false, false
    local badge
    if i >= nextIdx then marked, both, badge = QuestMarker(p, i == nextIdx) end
    if marked then
      -- kleiner Kern in der Mitte, Text mit Nummer und was zu tun ist
      local t = both and (i .. TR" |cff4dff99?|r|cffff8000!|r Beides") or (i .. (KINDTXT[p.kind] or ""))
      if not badge then AddPin(p[1], p[2], 8, c, nil) end
      nLab = nLab + 1
      local l = labels[nLab]
      if not l then
        l = overlay:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
        labels[nLab] = l
      end
      ZoomFont(l)
      local w, h = overlay:GetWidth(), overlay:GetHeight()
      local lx, ly = Cv(p[1], p[2])
      l:SetText(t)
      l:ClearAllPoints()
      if lx then
        l:SetPoint("TOP", overlay, "TOPLEFT", lx * w, -ly * h - Z(both and 18 or 13))
        l:Show()
      else
        l:Hide()
      end
    else
      -- erledigte Punkte bleiben kleine graue Kaestchen, offene bekommen ihr Symbol
      local pk = (i > nextIdx) and p.kind or (i == nextIdx and "next") or nil
      if pk == "explore" and not big then pk = nil end
      AddPin(p[1], p[2], big and 14 or 10, c, i .. (KINDTXT[p.kind] or ""), pk)
    end
  end
  -- Laufwege des aktuellen Ziels (herumlaufender NPC oder Mob)
  local walkers = {}
  local cur = route[nextIdx]
  local ob = cur and cur.tags and type(cur.tags.obj) == "table" and cur.tags.obj
  if ob and ob.npcs and #ob.npcs <= 2 then for _, n in ipairs(ob.npcs) do table.insert(walkers, n) end end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  local ph = pos and ns.PendingHub and ns.PendingHub(mapID, pos:GetXY())
  if ph and ph.hub and ph.hub.npc then table.insert(walkers, ph.hub.npc) end
  for _, n in ipairs(walkers) do
    for _, path in ipairs((ns.Waypoints and ns.Waypoints(n, mapID)) or {}) do
      for k = 2, #path do AddLine(path[k - 1][1], path[k - 1][2], path[k][1], path[k][2], { 1, 1, 1 }, 0.75, 2) end
      AddPin(path[1][1], path[1][2], 6, { 1, 1, 1 }, nil)
    end
  end
  -- starke Patrouillen (Elite oder weit ueber dir): Weg in Rot
  -- 1.1 (S Log L14.5 "Patrouillen Mobs sollten waehrend dem Fliegen nicht angezeigt werden"): im Flug nicht
  local flying = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  if db.patrolWarn ~= false and not flying and ns.Ways and ns.Ways.DangerPatrols and ns.Waypoints then
    for _, e in ipairs(ns.Ways.DangerPatrols(mapID, UnitLevel("player") or 1)) do
      for _, path in ipairs(ns.Waypoints(e.id, mapID) or {}) do
        for k = 2, #path do AddLine(path[k - 1][1], path[k - 1][2], path[k][1], path[k][2], { 1, 0.15, 0.1 }, 0.7, 2) end
      end
    end
  end
  -- Service Ziel (Lehrer, Haendler, ...)
  local st = ns.serviceTarget
  if st and st.map == mapID then
    AddRing(st.x, st.y, 30, { 0.3, 0.8, 1 }, 0.9, 3)
    AddRing(st.x, st.y, 20, { 0, 0, 0 }, 0.85, 4)
    AddPin(st.x, st.y, 8, { 0.3, 0.8, 1 }, "|cff4dccff" .. (st.name or "Service") .. "|r", "vendor")
  end
  -- 20.3m+ (S Punkt 27, Mulgore voller "! Gefahr" Pins bei L60): Schalter "Gefahren auf der Karte" (Standard an),
  -- gelernte Sturz Stellen nur als Weg Umweg, nicht als Pin. Mobs und Elite zeigen nur, wenn sie fuer dein Level zaehlen
  for _, d in ipairs(db.showDanger ~= false and Dangers(mapID) or {}) do
    if ns.DangerIsAuto(d) then
      -- nichts zeichnen
    elseif d.elite then
      AddRing(d[1], d[2], 26, { 1, 0.1, 0.1 }, 0.5, 1)
      AddPin(d[1], d[2], 12, { 1, 0.1, 0.1 }, TR"|cffff3030! Elite|r", "danger")
    elseif d.mob then
      AddPin(d[1], d[2], 14, { 0.8, 0, 0.6 }, TR"|cffff40c0! Mobs|r", "danger")
    else
      AddPin(d[1], d[2], 16, { 1, 0, 0 }, TR"|cffff2020! Gefahr|r", "danger")
    end
  end
end

-- kompletter Weg ueber alle Zonen im Plan
local function DrawPlan(mapID)
  local plan = db.plan
  if not plan or #plan == 0 then return end
  local lastX, lastY
  for n, zoneID in ipairs(plan) do
    local route = GetRoute(zoneID) or {}
    local start = db.progress[zoneID] or 1
    local first = true
    for i = start, #route do
      local p = route[i]
      local x, y
      x, y = ToView(zoneID, p[1], p[2], mapID)
      if x then
        if lastX then AddLine(lastX, lastY, x, y, PURPLE, 0.85, 3) end
        local c = KINDCOL[p.kind] or PURPLE
        if p.kind == "explore" then c = PURPLE end
        AddPin(x, y, first and 12 or ((p.kind ~= "explore") and 8 or 5), c, first and tostring(n) or nil)
        lastX, lastY = x, y
        first = false
      else
        lastX, lastY = nil, nil
      end
    end
  end
end

-- Gold Route in Gold zeichnen
local GOLD = { 1, 0.84, 0 }
local function DrawGold(mapID)
  local r = ns.goldRoute
  if not r then return end
  local lastX, lastY
  local start = db.goldIdx or 1
  for i = start, #r do
    local c = r[i]
    local x, y
    x, y = ToView(c.map, c.x, c.y, mapID)
    if x then
      if lastX then AddLine(lastX, lastY, x, y, GOLD, 0.95, 4) end
      AddPin(x, y, (i == start) and 14 or 10, (i == start) and GREEN or GOLD, "|cffffd100" .. i .. " $|r", (i == start) and "next" or "gold")
      lastX, lastY = x, y
    else
      lastX, lastY = nil, nil
    end
  end
end

-- Grind Spots als Info auf der Karte (Option), Farbe je nach Level
local function DrawGrindSpots(mapID)
  local L = UnitLevel("player")
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  for _, g in ipairs((ns.GrindList and ns.GrindList(mapID)) or ns.grind[mapID] or {}) do
    local c, txt
    if g[4] > L + 2 then c, txt = { 1, 0.2, 0.2 }, TR"zu stark"
    elseif g[5] < L - 3 then c, txt = { 0.6, 0.6, 0.6 }, TR"zu tief"
    elseif g[4] <= L + 1 and g[5] >= L - 1 then c, txt = { 0.2, 1, 0.3 }, TR"passt"
    else c, txt = { 1, 0.85, 0.1 }, TR"geht" end
    AddRing(g[1], g[2], 30, c, 0.35, 1)
    AddRing(g[1], g[2], 22, { 0, 0, 0 }, 0.5, 2)
    AddRing(g[1], g[2], 12, c, 0.9, 3)
    nLab = nLab + 1
    local l = labels[nLab]
    if not l then
      l = overlay:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
      labels[nLab] = l
    end
    ZoomFont(l)
    l:SetText((TR"|cff%02x%02x%02xGrind %d-%d|r |cff9d9d9d%s|r"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), g[4], g[5], txt))
    l:ClearAllPoints()
    local gx, gy = Cv(g[1], g[2])
    if gx then
      l:SetPoint("TOP", overlay, "TOPLEFT", gx * w, -gy * h - Z(16))
      l:Show()
    else
      l:Hide()
    end
  end
end

-- Welche Schritte auf die Karte kommen: die naechsten 10, in der aktuellen Zone und hoechstens einer weiteren
-- (zb nach Schiff oder Zeppelin).
-- 20.4a4 (K 20:30 z6 Punkt 1, S 20:22): auf der Kontinent oder Welt Karte (wide) zeigt auch die Leveling Route mehr
-- Schritte ueber alle Zonen (MAP_WIDE_STEPS), sonst sah man dort fast nichts
local MAP_WIDE_STEPS = 40
function ns.MapStepList(opt, start, wide)
  local out = {}
  local steps = opt and opt.steps or {}
  local first = steps[start]
  if not first then return out end
  local function ZoneOf(st) return (ns.cityParent and ns.cityParent[st.map]) or st.map end
  local zone = ZoneOf(first)
  local inZone, extra, lastTravel = 0, nil, false
  -- Farmrunde: die ganze Runde zeigen (sonst die naechsten 10 Stopps)
  local cap = (opt and opt.loop) and 40 or 10
  if wide then
    for i = start, math.min(#steps, start + MAP_WIDE_STEPS - 1) do table.insert(out, i) end
    return out
  end
  -- 20.3k (S Test 20.3g Punkt 20b): Zusatz Routen (Dungeon, Ruf, Ausruestung, Farmen) ganz zeigen, bis 300 Stopps und
  -- ueber alle Zonen. Die Leveling Route bleibt bei den naechsten 10
  local all = ns.OptSpecial and ns.OptSpecial(opt) and not (opt.mirror or opt.group or opt.split)
  if all then
    -- 20.3o (Da Pruefung Nr 10): schwacher PC nur 40 Stopps (jedes Neuzeichnen der Karte geht durch alle)
    local maxN = (db and db.slowPC) and 40 or 300
    for i = start, math.min(#steps, start + maxN - 1) do table.insert(out, i) end
    return out
  end
  for i = start, #steps do
    if #out >= cap then break end
    local st = steps[i]
    local z = ZoneOf(st)
    if z == zone then
      inZone = inZone + 1
    elseif z == extra then
      -- naechste Zone, schon freigegeben
    elseif extra == nil and (inZone < 10 or lastTravel or st.travel) then
      extra = z
    else
      break
    end
    table.insert(out, i)
    lastTravel = st.travel and true or false
  end
  return out
end

-- Optimierte Route zeichnen: die naechsten Stopps mit Nummer, Farbe je nach Aufgabe
local OPTCOL = { A = { 1, 0.5, 0 }, O = { 1, 0.4, 0.8 }, T = { 0.3, 1, 0.6 } }
local OPTPIN = { A = "quest", T = "turnin", O = "obj", G = "grind", F = "fp", E = "explore", R = "travel",
  V = "vendor", B = "hearth", H = "hearth", L = "inn", K = "book", M = "via" }
local function DrawOpt(mapID, optArg)
  local opt = optArg or db.opt
  local start = opt.idx or 1
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  local lastX, lastY
  -- Startpunkt Spieler: wie die Schritte ueber ToView (OpenMap Ansicht ist zusammengesetzt)
  local pm = PlayerMap()
  local pp = pm and C_Map.GetPlayerMapPosition(pm, "player")
  if pp then
    local px, py = pp:GetXY()
    lastX, lastY = ToView(pm, px, py, mapID)
    if type(lastX) ~= "number" or type(lastY) ~= "number" then lastX, lastY = nil, nil end
  end
  if not lastX then
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then lastX, lastY = pos:GetXY() end
  end
  local legs = 0
  local vinfo = C_Map.GetMapInfo(mapID)
  local zoneView = vinfo and vinfo.mapType == Enum.UIMapType.Zone
  -- 20.4a4 (K 20:30 z6 Punkt 1): Kontinent und Welt (Azeroth mit zwei Kontinenten) wie beim Navi umrechnen
  local wide = vinfo and vinfo.mapType and vinfo.mapType < Enum.UIMapType.Zone
  -- 1.1 (S Log 06.11., Core.lua:1753 compare nil with number, 173x): Schritte ohne Punkt (zb Reise ohne Ziel) oder eine
  -- Umrechnung mit nur einem Wert. View gibt nur noch ein ganzes Paar Zahlen zurueck oder nichts
  local function View(zone, x, y, edge)
    if not (zone and type(x) == "number" and type(y) == "number") then return nil, nil end
    local u, v = ToView(zone, x, y, mapID)
    -- 1.2i (P71, K 17:00: "Reise: Zeppelin" ohne Linie, KARTE "0 von 4 Schritten" auf Orgrimmar): Schritte knapp
    -- ausserhalb der Karte (Zeppelin Turm vor der Stadt) gab ToMap nicht her. Jetzt auch in der Zonen Ansicht ueber
    -- ToMapFree (ns.MapViewPt), und am Rand der Karte festhalten, damit die Linie dorthin zeigt
    if not (type(u) == "number" and type(v) == "number") and ns.MapViewPt and (wide or edge) then
      u, v = ns.MapViewPt(zone, x, y, mapID)
      if not wide and type(u) == "number" and type(v) == "number" then
        u, v = math.max(0, math.min(1, u)), math.max(0, math.min(1, v))
      end
    end
    if type(u) ~= "number" or type(v) ~= "number" then return nil, nil end
    return u, v
  end
  if wide and not lastX and pm and pp then lastX, lastY = View(pm, pp:GetXY()) end
  local list = ns.MapStepList(opt, start, wide)
  local drawn = 0
  -- v11f (K P37): Runde im grossen Gegner Gebiet (Arrow.lua NaviRundPts) als geschlossener Kreis
  do
    local rp = not wide and ns.NaviRundPts and ns.NaviRundPts(mapID)
    if rp and #rp >= 4 then
      for k = 2, #rp do
        local ax, ay = View(mapID, rp[k - 1][1], rp[k - 1][2])
        local bx, by = View(mapID, rp[k][1], rp[k][2])
        if ax and bx then AddLine(ax, ay, bx, by, { 0.35, 0.95, 0.5 }, 0.8, 3) end
      end
    end
  end
  -- 20.3o (S Punkt 27 eckige Route 1 bis 11, Na 23:11): Zusatz Routen liefern seit 20.3k bis 300 Stopps ueber alle Zonen.
  -- In der Zonenansicht nur die Schritte dieser Zone (Reise Schritte als Uebergang dazu), die Nummer bleibt die Stelle in
  -- der Route. Kontinent und Welt zeigen weiter alles. Vorher kamen Punkte der Nachbarzonen als Kaestchen ins Bild
  -- 20.3z3 (S Test 20.3z2 Z4: Flugpunkte und Entdecken Tour "sehe nicht wie die Route geht"): Touren zeigen alle Stopps
  local allZones = ns.OptSpecial and ns.OptSpecial(opt) and not (opt.mirror or opt.group or opt.split or opt.tour)
  local viewZone = (ns.cityParent and ns.cityParent[mapID]) or mapID
  for li, i in ipairs(list) do
    local st = opt.steps[i]
    -- 1.2i (P71): Reise Schritt und jetziger Schritt duerfen am Kartenrand stehen (Linie zeigt dorthin)
    local x, y = View(st.map, st.x, st.y, st.travel or i == start)
    if x and wide and (x < 0 or x > 1 or y < 0 or y > 1) then x, y = nil, nil end
    if x then drawn = drawn + 1 end
    if x and zoneView and allZones and not st.travel and ((ns.cityParent and ns.cityParent[st.map]) or st.map) ~= viewZone then x, y = nil, nil end
    if x then
      if lastX then
        -- Farbverlauf: Schritt 1 gruen, je weiter weg desto roter
        local f = (#list > 1) and (li - 1) / (#list - 1) or 0
        local col, wd = { 0.25 + 0.75 * f, 0.9 - 0.65 * f, 0.35 - 0.2 * f }, (i == start) and 4 or 3
        -- in der Zonenansicht: Weg um Berge herum (nur die ersten Abschnitte, spart Rechenzeit)
        local path
        -- 19.32 (Saschas Runde 1 Punkt 6): das erste Stueck ab dir genau so, wie der Pfeil fuehrt (sein Weg, nicht neu
        -- gerechnet), wenn der Pfeil gerade zu diesem Schritt geht
        if li == 1 and i == start and zoneView and st.map == mapID and pm == mapID and not optArg and ns.Karte and ns.Karte.FollowPts then
          local fp = ns.Karte.FollowPts(mapID, 60)
          local e = fp and fp[#fp]
          if e and math.abs(e[1] - x) < 0.004 and math.abs(e[2] - y) < 0.004 then path = fp end
        end
        path = path or (zoneView and st.map == mapID and legs < 10 and not st.travel and ns.WalkPath and ns.WalkPath(mapID, lastX, lastY, x, y))
        legs = legs + 1
        if path then
          local ax, ay = lastX, lastY
          for _, p in ipairs(path) do AddLine(ax, ay, p[1], p[2], col, 0.9, wd); ax, ay = p[1], p[2] end
        else
          AddLine(lastX, lastY, x, y, col, 0.9, wd)
        end
      end
      local k = st.acts[1].k
      local both = false
      for _, a in ipairs(st.acts) do if a.k ~= k then both = true end end
      local c = OPTCOL[k] or YELLOW
      if i == start then AddRing(x, y, 40, GREEN, 0.35, 1) end
      -- Symbol je Art (Figma Atlas); ohne Atlas wie frueher Ringe
      local pk = OPTPIN[k]
      if k == "V" and st.acts[1].books then pk = "book" end
      if both then
        local hasA, hasT = false, false
        for _, a in ipairs(st.acts) do if a.k == "A" then hasA = true elseif a.k == "T" then hasT = true end end
        if hasA and hasT then pk = "both" end
      end
      if not (pk and ns.T and ns.T.PinTex and AddPin(x, y, both and 16 or 14, c, nil, pk)) then
        AddRing(x, y, both and 26 or 20, c, 0.95, 3)
        AddRing(x, y, 12, { 0, 0, 0 }, 0.85, 4)
        if both then AddRing(x, y, 8, OPTCOL.T, 1, 5) end
      end
      nLab = nLab + 1
      local l = labels[nLab]
      if not l then
        l = overlay:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
        labels[nLab] = l
      end
      ZoomFont(l)
      local lx, ly = Cv(x, y)
      if lx then
        -- 19.32 (Saschas Runde 1 Punkt 6): Nummern ab dem aktuellen Schritt 1, 2, 3 (vorher die Nummer im ganzen Fahrplan, zb 23)
        l:SetText((i == start and "|cff40ff40" or "|cffffffff") .. li .. "|r")
        l:ClearAllPoints()
        l:SetPoint("BOTTOM", overlay, "TOPLEFT", lx * w, -ly * h + Z(14))
        l:Show()
      else
        l:Hide()
      end
      lastX, lastY = x, y
    else
      lastX, lastY = nil, nil
    end
  end
  -- 20.4a4: Test Log wie beim Navi, nur wenn sich Karte oder Zahl aendert (S sah auf dem Kontinent keine Route)
  if ns.TestLog then
    local key = mapID .. ":" .. drawn .. ":" .. #list .. ":" .. tostring(opt.title)
    if ns.drawOptLogKey ~= key then
      ns.drawOptLogKey = key
      ns.TestLog("KARTE", ("Route %s auf Karte %s (%s): %d von %d Schritten, ab Schritt %d"):format(tostring(opt.title or "-"),
        tostring(mapID), tostring(vinfo and vinfo.name or "?"), drawn, #list, start))
    end
  end
  -- Farmrunde im Kreis: letzte Stelle zurueck zur ersten (die Runde geht wieder von vorne)
  if opt.loop and #list > 2 and lastX then
    local s1 = opt.steps[1]
    local fx, fy
    if s1 then fx, fy = View(s1.map, s1.x, s1.y) end
    if fx then AddLine(lastX, lastY, fx, fy, { 0.4, 1, 0.6 }, 0.6, 2) end
  end
  -- 19.17: Laufweg vom aktuellen Ziel (herumlaufender Questgeber oder einzelner Mob), weiss wie im alten Modus.
  -- Der Pfeil sagt dazu "laeuft herum, Weg auf der Karte", in der Route fehlte der Weg bisher.
  local cs = (not optArg) and opt.steps and opt.steps[start]
  if cs and cs.map and type(cs.acts) == "table" and ns.Waypoints then
    local walker
    for _, a in ipairs(cs.acts) do
      if not (ns.OptActDone and ns.OptActDone(a)) then
        if (a.k == "A" or a.k == "T") and a.npc and not a.tram then walker = a.npc
        elseif a.k == "O" and type(a.npcs) == "table" and #a.npcs == 1 and (type(a.pts) ~= "table" or #a.pts <= 8) then walker = a.npcs[1] end
        break
      end
    end
    for _, path in ipairs((walker and ns.Waypoints(walker, cs.map)) or {}) do
      local ax, ay
      for k = 1, #path do
        local bx, by = ToView(cs.map, path[k][1], path[k][2], mapID)
        if ax and bx then AddLine(ax, ay, bx, by, { 1, 1, 1 }, 0.75, 2) end
        ax, ay = bx, by
      end
    end
  end
end

-- Navi (17.4, Navi.lua): Strecke ab dir, Laufen gelb, Flug hellblau, Schiff und Zeppelin blau, Nummer je Abschnitt
local NAVICOL = { walk = { 1, 0.82, 0 }, fly = { 0.45, 0.85, 1 }, ride = { 0.3, 0.5, 1 }, hearth = { 0.8, 0.5, 1 }, portal = { 0.8, 0.5, 1 } }
-- 19.2 (Era Log, Sascha: "die linie fehlte nach dem zeppelin"): Punkte ausserhalb der Karte nicht mehr wegwerfen,
-- sondern die Linie am Kartenrand abschneiden (sonst fehlt alles, was von ausserhalb hereinkommt), die Weltkarte
-- Azeroth ueber die Kontinente rechnen, und am Steg sagen, auf welcher Karte es weiter geht.
local naviCont, naviRect = {}, {}
local function ContinentOf(zone)
  local c = naviCont[zone]
  if c ~= nil then return c end
  c = false
  local id, guard = zone, 0
  while id and guard < 8 do
    local info = C_Map.GetMapInfo(id)
    if not info then break end
    if info.mapType == Enum.UIMapType.Continent then c = id; break end
    id = info.parentMapID; guard = guard + 1
  end
  naviCont[zone] = c
  return c
end
ns.ContinentOf = ContinentOf
local function RectOn(child, top)
  local k = child * 100000 + top
  local r = naviRect[k]
  if r ~= nil then return r end
  r = false
  if C_Map.GetMapRectOnMap then
    local ok, x1, x2, y1, y2 = pcall(C_Map.GetMapRectOnMap, child, top)
    if ok and type(x1) == "number" and type(x2) == "number" and type(y1) == "number" and type(y2) == "number"
      and x2 > x1 and y2 > y1 then r = { x1, x2, y1, y2 } end
  end
  naviRect[k] = r
  return r
end
local function NaviView(zone, x, y, mapID)
  if not (zone and x and y and mapID) then return end
  local OM = OpenMapAPI
  if OM and OM.IsStitched and OM.IsStitched() then return ToView(zone, x, y, mapID) end
  if zone == mapID then return x, y end
  local u, v = ns.ToMapFree(zone, x, y, mapID)
  if u and v then return u, v end
  -- Karte ohne Rechteck (Weltkarte Azeroth mit zwei Kontinenten): ueber den Kontinent der Zone
  local c = ContinentOf(zone)
  if c and c ~= mapID then
    local r = RectOn(c, mapID)
    if r then
      local cu, cv = ns.ToMapFree(zone, x, y, c)
      if cu and cv then return r[1] + cu * (r[2] - r[1]), r[3] + cv * (r[4] - r[3]) end
    end
  end
end
ns.MapViewPt = NaviView -- 20.4a4: auch fuer die Route auf Kontinent und Welt Karte (DrawOpt)
local function In01(x, y) return x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1 end
-- Strecke auf das Rechteck 0..1 kuerzen (Liang Barsky), nil wenn sie ganz draussen liegt
local function ClipT(p, q, t0, t1)
  if p == 0 then if q < 0 then return nil end return t0, t1 end
  local t = q / p
  if p < 0 then
    if t > t1 then return nil end
    if t > t0 then t0 = t end
  else
    if t < t0 then return nil end
    if t < t1 then t1 = t end
  end
  return t0, t1
end
local HUGE = math.huge
local function Clip01(ax, ay, bx, by)
  -- 19.9 (Code Pruefung): nur endliche Werte (NaN oder unendlich gaeben NaN Endpunkte statt nil)
  if not (ax == ax and ay == ay and bx == bx and by == by) then return end
  if ax == HUGE or ax == -HUGE or ay == HUGE or ay == -HUGE or bx == HUGE or bx == -HUGE or by == HUGE or by == -HUGE then return end
  local dx, dy = bx - ax, by - ay
  local t0, t1 = 0, 1
  t0, t1 = ClipT(-dx, ax, t0, t1); if not t0 then return end
  t0, t1 = ClipT(dx, 1 - ax, t0, t1); if not t0 then return end
  t0, t1 = ClipT(-dy, ay, t0, t1); if not t0 then return end
  t0, t1 = ClipT(dy, 1 - ay, t0, t1); if not t0 then return end
  return ax + t0 * dx, ay + t0 * dy, ax + t1 * dx, ay + t1 * dy
end
ns.NaviClip01 = Clip01
local function NaviLine(ax, ay, bx, by, c, a, thick)
  if not (ax and ay and bx and by) then return 0 end
  local x1, y1, x2, y2 = Clip01(ax, ay, bx, by)
  if not x1 then return 0 end
  AddLine(x1, y1, x2, y2, c, a, thick)
  return 1
end
local function NaviLabel(x, y, text, below)
  local w, h = overlay:GetWidth(), overlay:GetHeight()
  nLab = nLab + 1
  local l = labels[nLab]
  if not l then l = overlay:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge")); labels[nLab] = l end
  ZoomFont(l)
  local cx, cy = Cv(x, y)
  if cx then
    l:SetText(text)
    l:ClearAllPoints()
    if below then l:SetPoint("TOP", overlay, "TOPLEFT", cx * w, -cy * h - Z(14))
    else l:SetPoint("BOTTOM", overlay, "TOPLEFT", cx * w, -cy * h + Z(12)) end
    l:Show()
  else l:Hide() end
end
local function DrawNavi(mapID)
  local nv = ns.navi
  local lx, ly
  local pm = PlayerMap()
  local pp = pm and C_Map.GetPlayerMapPosition(pm, "player")
  local from -- Startpunkt des Abschnitts in Zonen Koordinaten (fuer die Wegsuche)
  local nSeg, nVis = 0, 0
  if pp then local px, py = pp:GetXY(); lx, ly = NaviView(pm, px, py, mapID); from = { pm, px, py } end
  -- Laufen den Wegen entlang (17.5): Linie ueber die Punkte der Wegsuche, sonst gerade
  local function Walk(i, gx, gy, col, wd)
    local pts = from and ns.NaviLegPts and ns.NaviLegPts(i, from)
    if pts and #pts > 0 then
      local ax, ay = lx, ly
      for _, q in ipairs(pts) do
        local qx, qy = NaviView(q[1], q[2], q[3], mapID)
        if qx then
          if ax then nSeg = nSeg + NaviLine(ax, ay, qx, qy, col, 0.9, wd) end
          ax, ay = qx, qy
        end
      end
      return
    end
    if lx and gx then nSeg = nSeg + NaviLine(lx, ly, gx, gy, col, 0.9, wd) end
  end
  for i = nv.cur or 1, #nv.legs do
    local lg = nv.legs[i]
    local col = NAVICOL[lg.kind] or YELLOW
    local x, y = NaviView(lg.to.map, lg.to.x, lg.to.y, mapID)
    -- Schiff und Zeppelin: erst zum Steg (Pfeil Punkt), dann hinueber
    if lg.kind == "ride" then
      local ax, ay = NaviView(lg.at.map, lg.at.x, lg.at.y, mapID)
      if ax and lx and i == nv.cur then Walk(i, ax, ay, NAVICOL.walk, 3) end
      if ax then lx, ly = ax, ay end
      -- Ankunft auf einer anderen Karte: am Steg sagen, wo es weiter geht
      if In01(ax, ay) and not x then
        local cz = ContinentOf(lg.to.map)
        local ci = cz and C_Map.GetMapInfo(cz)
        local zn = ns.ZoneName and ns.ZoneName(lg.to.map)
        local where = (ci and ci.name) or zn
        NaviLabel(ax, ay, ("|cff4d80ff%d|r |cffffffff%s|r"):format(i, lg.text or "")
          .. (where and ("\n|cffbbbbbb" .. TR"weiter auf der Karte %s" .. "|r"):format(where) or ""), true)
      end
    end
    if x and lx and lg.kind == "walk" then Walk(i, x, y, col, i == nv.cur and 4 or 3)
    elseif x and lg.kind == "walk" then Walk(i, x, y, col, i == nv.cur and 4 or 3)
    elseif x and lx and lg.kind ~= "hearth" and lg.kind ~= "portal" then nSeg = nSeg + NaviLine(lx, ly, x, y, col, 0.9, i == nv.cur and 4 or 3) end
    -- 20.3l (Log 20.3j J3 / 20.3k K2, Vorschlag Na 22:25): Ruhestein oder Teleport als aktueller Abschnitt, das Ziel liegt
    -- auf einer anderen Karte: auf der Karte, wo du stehst, sonst gar nichts. Jetzt Ring und Text an deiner Stelle
    if i == (nv.cur or 1) and (lg.kind == "hearth" or lg.kind == "portal") and lx and In01(lx, ly) then
      nVis = nVis + 1
      AddRing(lx, ly, 18, col, 0.95, 3); AddRing(lx, ly, 10, { 0, 0, 0 }, 0.85, 4)
      NaviLabel(lx, ly, "|cff40ff40" .. i .. "|r |cffffffff" .. (lg.text or "") .. "|r", true)
    end
    from = { lg.to.map, lg.to.x, lg.to.y }
    if In01(x, y) then
      nVis = nVis + 1
      if i == #nv.legs then AddRing(x, y, 30, GREEN, 0.5, 1) end
      AddRing(x, y, 18, col, 0.95, 3)
      AddRing(x, y, 10, { 0, 0, 0 }, 0.85, 4)
      -- 20.3j (Na, test_203g Punkt 9): am Flugmeister sagen, wohin der Flug geht (und auf welcher Karte es weiter geht)
      local ft = lg.kind == "walk" and lg.flyTo
      if ft and ft.map then
        local fx = NaviView(ft.map, ft.x, ft.y, mapID)
        local extra = "\n|cffbbbbbb" .. (TR"weiter: Flug nach %s"):format(ft.name or "?") .. "|r"
        if not fx then
          local zn = ns.ZoneName and ns.ZoneName(ft.map)
          if zn then extra = extra .. "\n|cffbbbbbb" .. (TR"weiter auf der Karte %s"):format(zn) .. "|r" end
        end
        NaviLabel(x, y, (i == nv.cur and "|cff40ff40" or "|cffffffff") .. i .. "|r" .. extra, true)
      else
        NaviLabel(x, y, (i == nv.cur and "|cff40ff40" or "|cffffffff") .. i .. "|r")
      end
    end
    lx, ly = x, y
  end
  -- Test Log: je Karte einmal, wie viel vom Navi zu sehen war (fuer Karten wie die Weltkarte Azeroth)
  if ns.TestLog and mapID then
    nv.mapSeen = nv.mapSeen or {}
    local key = mapID .. ":" .. (nv.cur or 1)
    if not nv.mapSeen[key] then
      nv.mapSeen[key] = true
      local ci = C_Map.GetMapInfo(mapID)
      ns.TestLog("NAVI", ("Karte %s (%s): %d von %d Punkten, %d Linien, ab Schritt %d"):format(tostring(mapID),
        tostring(ci and ci.name), nVis, #nv.legs - (nv.cur or 1) + 1, nSeg, nv.cur or 1))
    end
  end
end

local Draw
-- beim Verschieben und Zoomen feuert das oft pro Frame: zusammenfassen
local drawSoon = false
function ns.DrawSoon()
  if drawSoon then return end
  drawSoon = true
  C_Timer.After(0, function() drawSoon = false; if Draw then Draw() end end)
end
Draw = function()
  HideAll()
  if not db or db.paused or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  -- Route auf der Karte aus: das Navi (17.4) zeichnet trotzdem
  if (not db.show or db.mapShow == false) and not (ns.navi and not ns.navi.hidden and ns.navi.legs) then return end
  EnsureOverlay()
  ZF = ZoomFactor()
  local mapID = WorldMapFrame:GetMapID()
  local info = mapID and C_Map.GetMapInfo(mapID)
  -- Navi aktiv: nur die Navi Strecke
  if ns.navi and not ns.navi.hidden and ns.navi.legs then
    local OMn = OpenMapAPI
    if OMn and OMn.IsStitched and OMn.IsStitched() then
      local top = OMn.ArtTopLevel and OMn.ArtTopLevel()
      if top and overlay:GetFrameLevel() <= top then overlay:SetFrameLevel(top + 20) end
    end
    DrawNavi(mapID)
    -- 20.3y (S Test 17:04): bei einer Runde (Farm, Beruf, Gold) bleibt der Kreislauf zu sehen, das Navi zeigt den Anweg dazu
    local o = db.opt
    -- 20.3z5 (S Test 20.3z4 19:53/19:54): auch Touren (Flugpunkte, Entdecken), sonst sah man nur den Navi Weg zum naechsten Punkt
    -- 20.4a4 (Na Vorschlag 20:07): alle Zusatz Routen (ohne Gruppe/Spiegel), nicht nur Runden und Touren
    if db.optMode and o and (o.loop or o.prof or o.farm or o.tour or (ns.OptSpecial and ns.OptSpecial(o) and not (o.mirror or o.group or o.split)))
      and (o.idx or 1) <= #(o.steps or {}) then DrawOpt(mapID) end
    return
  end
  -- Vorschau einer Farmrunde (Fenster Route planen): nur die zeichnen
  if ns.profPreview then
    local OMp = OpenMapAPI
    if OMp and OMp.IsStitched and OMp.IsStitched() then
      local top = OMp.ArtTopLevel and OMp.ArtTopLevel()
      if top and overlay:GetFrameLevel() <= top then overlay:SetFrameLevel(top + 20) end
    end
    DrawOpt(mapID, ns.profPreview)
    return
  end
  -- Optimierte Route aktiv: nur die zeichnen
  if db.optMode and db.opt and not (db.goldMode and ns.goldRoute) then
    local OMa = OpenMapAPI
    if OMa and OMa.IsStitched and OMa.IsStitched() then
      local top = OMa.ArtTopLevel and OMa.ArtTopLevel()
      if top and overlay:GetFrameLevel() <= top then overlay:SetFrameLevel(top + 20) end
    end
    DrawOpt(mapID)
    if db.showGrind and info and info.mapType == Enum.UIMapType.Zone then DrawGrindSpots(mapID) end
    return
  end
  -- 20.3o (S Punkt 27b): ohne laufende Route zeichnete die Karte die alten geschaetzten Zonen Routen (Route.lua, eckig
  -- mit Nummern und Gefahr Stellen) in jeder Zone, auch auf Max Level. Das ist nur der Notbehelf ohne Questie:
  -- mit Questie (oder auf Max Level) ohne Route nichts davon zeigen
  do
    local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    local okQ, qdb = false, nil
    if ns.QDBAccess then okQ, qdb = pcall(ns.QDBAccess) end
    if not (db.goldMode and ns.goldRoute) and ((okQ and qdb) or (UnitLevel("player") or 1) >= maxL) then
      if db.showGrind and info and info.mapType == Enum.UIMapType.Zone then DrawGrindSpots(mapID) end
      return
    end
  end
  local route = GetRoute(mapID)
  -- OpenMap aktiv: Route deiner Zone auf die zusammengesetzte Karte legen
  local OM = OpenMapAPI
  if OM and OM.IsStitched and OM.IsStitched() then
    local top = OM.ArtTopLevel and OM.ArtTopLevel()
    if top and overlay:GetFrameLevel() <= top then overlay:SetFrameLevel(top + 20) end
    if db.goldMode and ns.goldRoute then
      DrawGold(mapID)
      return
    end
    local zone = PlayerMap()
    local zr = zone and GetRoute(zone)
    if db.plan and #db.plan > 0 then DrawPlan(mapID) end
    if zr then
      xform = function(x, y)
        local u, v = OM.WorldFromMap(zone, x, y)
        if not u then return end
        return OM.MapFromWorld(mapID, u, v)
      end
      DrawZone(zone, zr)
      if db.showGrind then DrawGrindSpots(zone) end
      xform = nil
    end
    return
  end
  -- Zonenkarte mit Route: genaue Route, sonst (Kontinent, Stadt) den ganzen Plan
  if db.goldMode and ns.goldRoute then
    DrawGold(mapID) -- im Gold Modus nur die Gold Route
  elseif route and info and info.mapType == Enum.UIMapType.Zone then
    DrawZone(mapID, route)
  else
    DrawPlan(mapID)
  end
  if db.showGrind and info and info.mapType == Enum.UIMapType.Zone then DrawGrindSpots(mapID) end
end
ns.Draw = Draw

------------------------------------------------------------
-- Planer
------------------------------------------------------------
ns.speed = 7
local function SampleSpeed()
  if not db then return end
  if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return end
  local cur = Plain(ns.Api.GetUnitSpeed("player"))
  if cur and cur > 0 and cur < 30 then
    ns.speed = cur
    -- Reittier Tempo merken (gemessen, wenn du draufsitzt)
    if IsMounted and ns.Api.U(IsMounted) and cur > 8 then db.mountSpeed = math.max(db.mountSpeed or 0, cur) end
    if not (IsMounted and ns.Api.U(IsMounted)) and cur >= 6 and cur <= 8 then db.runSpeed = cur end
  end
end

-- Reiten Fertigkeit aus dem Fertigkeiten Fenster (75 = langsames, 150 = schnelles Reittier)
local RIDING = { ["Reiten"] = true, ["Riding"] = true, ["Monte"] = true, ["Equitación"] = true, ["Cavalcare"] = true,
  ["Montaria"] = true, ["Верховая езда"] = true, ["탈것 타기"] = true, ["骑术"] = true, ["騎術"] = true }
local function RidingRank()
  if not (GetNumSkillLines and GetSkillLineInfo) then return 0 end
  for i = 1, GetNumSkillLines() do
    local name, header, _, rank = GetSkillLineInfo(i)
    -- Name der Fertigkeit in jeder Spielsprache (vorher nur Deutsch und Englisch: auf Franzoesisch kein Reittier Tempo)
    if not header and name and RIDING[name] then return rank or 0 end
  end
  return 0
end

-- Tempo fuer die Planung: zu Fuss, oder mit Reittier sobald du eins hast
function ns.PlanSpeed()
  local run = (db and db.runSpeed) or 7
  if db and db.noMountPlan then return run end
  local mount = db and db.mountSpeed
  if not mount then
    local r = RidingRank()
    if r >= 150 then mount = run * 2 elseif r >= 75 then mount = run * 1.6 end
  end
  -- Auf und Absteigen, Kaempfe unterwegs: nicht ganz das volle Tempo
  if mount and mount > run then return run + (mount - run) * 0.85 end
  return run
end

local function LevelOf(total)
  local L = 1
  for i = 1, 60 do
    if ns.xpTotal[i] <= total then L = i end
  end
  return L
end

-- Weg durch die restlichen Punkte einer Zone in Yards
local function ZoneDistance(zoneID, route, start)
  local path, prev = 0, nil
  for i = start, #route do
    local p = { zoneID, route[i][1], route[i][2] }
    if prev then path = path + (WorldDist(prev, p) or 0) end
    prev = p
  end
  if path > 0 then return path * 1.25 end
  local w, h
  if C_Map.GetMapWorldSize then
    local ok, a, b = pcall(C_Map.GetMapWorldSize, zoneID)
    if ok then w, h = a, b end
  end
  return (w and h and w > 0) and (w + h) * 1.2 or 4000
end

local function BuildPlan(target)
  local lvl = UnitLevel("player")
  target = math.floor(tonumber(target) or 0)
  if target > 60 then target = 60 end
  if target <= lvl then
    return nil, nil, TR"Ziel muss höher sein als dein Level (" .. lvl .. ")"
  end
  local total = (ns.xpTotal[lvl] or 0) + (UnitXP("player") or 0)
  local goal = ns.xpTotal[target]
  local speed = ns.speed or 7
  local exRatio = ExploreRatio()
  local plan, grindPlan, out = {}, {}, {}
  local time = 0
  local prevLast

  -- noch offene Zonen der Reihe nach
  local open = {}
  for _, id in ipairs(ns.zoneOrder) do
    local z = ns.zones[id]
    -- schon fertig oder Zone ist grau fuer dich: auslassen
    if not ZoneDone(id) and not (z and z.max < lvl - 2) then table.insert(open, id) end
  end

  ns.planZoneSec = {}
  ns.planGrindSpot = {}
  for zi, id in ipairs(open) do
    if total >= goal then break end
    local tStart = time
    local z = ns.zones[id] or { min = 1, max = 60, area = lvl }
    local route = GetRoute(id) or {}
    local start = db.progress[id] or 1
    local L0 = LevelOf(total)
    table.insert(plan, id)
    local rows = {}

    -- Weg hierher
    local hop = 0
    if prevLast and route[start] then
      local d = WorldDist(prevLast, { id, route[start][1], route[start][2] })
      hop = d and d / speed or 180
    end
    if route[#route] then prevLast = { id, route[#route][1], route[#route][2] } end

    -- Erkunden
    local areas = 0
    for i = start, #route do
      if route[i].tags and route[i].tags.explore then areas = areas + 1 end
    end
    local eff = math.min(z.area, LevelOf(total) + 5)
    local exXP = math.floor(areas * ExploreBase(eff) * exRatio)
    local exSec = ZoneDistance(id, route, start) / speed + hop
    total = total + exXP
    time = time + exSec
    table.insert(rows, (TR"   Erkunden %d Gebiete: ca %d XP, %s"):format(areas, exXP, FmtMin(exSec)))

    -- Quest Hubs, die zum Level passen (ohne Daten: Schaetzung fuer die ganze Zone)
    local hubs = ns.hubs[id]
    if not hubs then
      local zq = math.floor((z.q or 20) * 1.5)
      hubs = {
        { 0.5, 0.5, TR"Quests der Zone (Teil 1)", z.min, math.floor((z.min + z.max) / 2), math.floor(zq / 2) },
        { 0.5, 0.5, TR"Quests der Zone (Teil 2)", math.floor((z.min + z.max) / 2), z.max, zq - math.floor(zq / 2) },
      }
    end
    for _, h in ipairs(hubs) do
      local L = LevelOf(total)
      if total < goal and h[5] >= L - 3 and h[4] <= L + 4 then
        local ql = math.max(h[4], math.min(h[5], L))
        -- Quest XP plus die Mobs, die man beim Questen sowieso killt (ca 40 Prozent dazu)
        local qxp = math.floor(h[6] * QuestXP(ql) * 1.4)
        local qsec = h[6] * 300
        total = total + qxp
        time = time + qsec
        table.insert(rows, (TR"   Quests %s (%d): ca %d XP, %s"):format(h[3], h[6], qxp, FmtMin(qsec)))
      end
    end

    -- Grinden bis zum Mindestlevel der naechsten Zone, bzw. bis zum Ziel
    local nextZ = open[zi + 1]
    local want = target
    -- nur grinden, wenn man fuer die naechste Zone mehr als 3 Level zu tief ist
    -- (die ersten Quests der naechsten Zone holen den Rest auf)
    if nextZ and ns.zones[nextZ] then want = math.min(target, math.max(ns.zones[nextZ].min - 3, 1)) end
    local L = LevelOf(total)
    local missing = (ns.xpTotal[want] or 0) - total
    local oneLevel = (ns.xpTotal[L + 1] or total) - (ns.xpTotal[L] or 0)
    if L < want and nextZ and missing > oneLevel * 0.5 then
      local spot
      for _, g in ipairs((ns.GrindList and ns.GrindList(id)) or ns.grind[id] or {}) do
        if g[4] <= L + 1 and g[5] >= L - 2 then spot = g end
      end
      if spot then
        local need = math.min(ns.xpTotal[want], goal) - total
        local rate = KillRate(L)
        local gsec = need / rate * 3600
        total = total + need
        time = time + gsec
        grindPlan[id] = want
        ns.planGrindSpot[id] = spot[3]
        table.insert(rows, (TR"   Grind %s (Mobs %d-%d) bis Level %d: ca %d XP, %s"):format(spot[3], spot[4], spot[5], want, need, FmtMin(gsec)))
      end
    end

    ns.planZoneSec[id] = time - tStart
    table.insert(out, (TR"%d. %s  (Level %d bis %d)"):format(#plan, ZoneName(id), L0, LevelOf(total)))
    for _, r in ipairs(rows) do table.insert(out, r) end
  end

  -- falls die Zonen nicht reichen
  if total < goal then
    local L = LevelOf(total)
    local rate = KillRate(L)
    local gsec = (goal - total) / rate * 3600
    time = time + gsec
    table.insert(out, (TR"Danach noch ca %d XP grinden oder questen, ca %s"):format(goal - total, FmtMin(gsec)))
  end

  local rate, measured = KillRate(lvl)
  local head = {
    (TR"Bis Level %d, total ca %s"):format(target, FmtMin(time)),
    (TR"Speed %.1f Yards/Sek (%d%%), Update alle 15 Sek"):format(speed, math.floor(speed / 7 * 100 + 0.5)),
    (TR"Grinden ca %d XP/Std (%s)"):format(math.floor(rate), measured and (ns.EN and "measured" or "gemessen") or TR"geschätzt"),
    (TR"Erkunden %d%% der Schätzung (%s)"):format(math.floor(exRatio * 100 + 0.5), (db.stats.exN or 0) >= 3 and (ns.EN and "measured" or "gemessen") or TR"geschätzt"),
  }
  local text = table.concat(head, "\n") .. "\n\n" .. table.concat(out, "\n") ..
    TR"\n\nKarte: Lila Weg, Blau FP, Orange Quests, Rot Grinden"
  return plan, grindPlan, text, time
end

function ns.CalcPlan(target)
  local plan, grindPlan, text, ptime = BuildPlan(target)
  db.planText = text
  if plan then
    ns.planTime, ns.planTimeAt = ptime, GetTime()
    db.plan = plan
    -- Grind Plan geaendert? Dann Routen neu bauen (Grind Spot rein oder raus)
    local function Key(t)
      local k = {}
      for id, v in pairs(t or {}) do table.insert(k, id .. "=" .. v .. "=" .. tostring(ns.planGrindSpot and ns.planGrindSpot[id])) end
      table.sort(k)
      return table.concat(k, ",")
    end
    if Key(grindPlan) ~= ns.lastGrindKey then
      ns.lastGrindKey = Key(grindPlan)
      db.learnedRev = (db.learnedRev or 0) + 1
    end
    db.planGrind = grindPlan
    db.planTarget = target
  end
  Draw()
  return text
end

-- Abschnitt der Route: ein paar Level voraus, Ziel ist immer das Maximallevel
function ns.SectionTarget()
  local L = UnitLevel("player")
  local max = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  -- 10 Level voraus rechnen, damit Pakete und Questreihen ueber die Grenze nicht rausfallen.
  -- Angezeigt werden in Meine Route nur die naechsten 3 Level (ns.ShownStepMax).
  return math.min(max, L + 10)
end

-- letzter Schritt, der in Meine Route und im Mini Fenster gezeigt wird (bis 3 Level voraus)
function ns.ShownStepMax(opt)
  if not (opt and opt.steps) then return 0 end
  local L = UnitLevel("player") or 1
  local n = #opt.steps
  for i = math.max(1, opt.idx or 1), #opt.steps do
    local st = opt.steps[i]
    if st.lvl and st.lvl >= L + 3 then n = i; break end
  end
  return n
end

function ns.ClearPlan()
  db.plan = nil
  if db.planGrind and next(db.planGrind) then db.learnedRev = (db.learnedRev or 0) + 1 end
  ns.lastGrindKey = nil
  db.planGrind = nil
  db.planText = nil
  db.planTarget = nil
  Draw()
end

------------------------------------------------------------
-- Level Check: unterlevelt? Dann Questen oder Grinden empfehlen
------------------------------------------------------------
ns.levelWarn = nil
local lastWarnKey, ignoredKey

local function FmtClock(sec)
  local m = math.floor(sec / 60 + 0.5)
  if m >= 60 then return (TR"%d Std %d Min"):format(math.floor(m / 60), m % 60) end
  return m .. TR" Min"
end

-- Was braucht der Spieler hier fuer ein Level?
local function RequiredLevel(mapID, route)
  local L = UnitLevel("player")
  local z = ns.zones[mapID]
  local need, why = nil, nil
  if z and L < z.min - 2 then
    need, why = z.min, (TR"%s ist ab Level %d"):format(ZoneName(mapID), z.min)
  end
  local p = route and route[db.progress[mapID] or 1]
  if p and p.tags then
    local g = type(p.tags.grind) == "table" and p.tags.grind
    if g and g[4] > L + 2 and (not need or g[4] - 1 > need) then
      need, why = g[4] - 1, (TR"Mobs am nächsten Grind Spot sind Level %d bis %d"):format(g[4], g[5])
    end
  end
  return need, why
end

-- beste Option suchen: Questen oder Grinden, inkl. Laufweg
local function BestOption(L, needXP, from)
  local speed = ns.speed or 7
  local grindRate = KillRate(L) -- XP pro Stunde
  local qPerSec = QuestXP(L) / 300 -- eine Quest ca 5 Min
  local bestQ, bestG
  for _, id in ipairs(ns.zoneOrder) do
    for _, h in ipairs(ns.hubs[id] or {}) do
      if h[4] <= L + 1 and h[5] >= L then
        local d = WorldDist(from, { id, h[1], h[2] })
        if d then
          local cap = h[6] * QuestXP(L)
          local t = d / speed + math.min(needXP, cap) / qPerSec + math.max(0, needXP - cap) / grindRate * 3600
          if not bestQ or t < bestQ.t then bestQ = { t = t, zone = id, pt = h, d = d } end
        end
      end
    end
    for _, g in ipairs((ns.GrindList and ns.GrindList(id)) or ns.grind[id] or {}) do
      if g[4] <= L + 1 and g[5] >= L - 2 then
        local d = WorldDist(from, { id, g[1], g[2] })
        if d then
          local t = d / speed + needXP / grindRate * 3600
          if not bestG or t < bestG.t then bestG = { t = t, zone = id, pt = g, d = d } end
        end
      end
    end
  end
  return bestQ, bestG
end

function ns.CheckLevel(silent)
  if not db then return end
  -- optimierte Route: die plant Level selbst (Mindestlevel, Grind Pausen), keine Warnung mit Ton aus der alten Zonenroute
  if db.optMode then ns.levelWarn = nil; lastWarnKey = nil; return end
  local mapID = PlayerMap()
  local route = GetRoute(mapID)
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  local need, why = RequiredLevel(mapID, route)
  local L = UnitLevel("player")

  if not need or not pos or L >= need then
    if ns.levelWarn and not silent then Print(TR"Level passt jetzt, weiter mit der Route!") end
    ns.levelWarn = nil
    lastWarnKey = nil
    return
  end

  local px, py = pos:GetXY()
  local needXP = ns.xpTotal[need] - ((ns.xpTotal[L] or 0) + UnitXP("player"))
  local q, g = BestOption(L, needXP, { mapID, px, py })
  local best, kind
  -- Questen bevorzugen: Grinden nur, wenn es deutlich schneller ist
  if q and (not g or q.t <= g.t * 1.6) then best, kind = q, "quest" elseif g then best, kind = g, "grind" end

  local w = { need = need, why = why, kind = kind }
  local lines = { (TR"|cffff5050Unterlevelt:|r Level %d, %s"):format(L, why) }
  if best then
    local what = kind == "quest" and (TR"Questen in %s"):format(best.pt[3]) or (TR"Grinden bei %s"):format(best.pt[3])
    w.short = (TR"%s (%s), ca %s"):format(what, ZoneName(best.zone), FmtClock(best.t))
    w.target = { best.zone, best.pt[1], best.pt[2], best.pt[3] }
    if kind == "quest" then w.hub = best.pt end
    table.insert(lines, TR"Empfehlung: " .. w.short)
    local other = (kind == "quest") and g or q
    if other then
      local ow = (kind == "quest") and TR"Grinden bei " or TR"Questen in "
      table.insert(lines, (TR"Alternativ: %s%s, ca %s"):format(ow, other.pt[3], FmtClock(other.t)))
    end
  else
    w.short = TR"Keine passende Quest oder Mobs gefunden"
    table.insert(lines, w.short)
  end
  w.lines = lines
  w.key = mapID .. ":" .. L .. ":" .. need
  w.ignored = (ignoredKey == w.key)
  ns.levelWarn = w

  if not silent and w.key ~= lastWarnKey and not w.ignored then
    lastWarnKey = w.key
    for _, l in ipairs(lines) do Print(l) end
    if w.target then Print(TR"Der Pfeil zeigt jetzt zur Empfehlung. Ignorieren: Knopf im Fenster oder /klg ignorieren") end
    if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
  end
end

function ns.IgnoreWarn()
  if ns.levelWarn then
    ignoredKey = ns.levelWarn.key
    ns.levelWarn.ignored = true
    Print(TR"Level Warnung ignoriert, der Pfeil zeigt wieder auf die Route")
  end
end

-- alle 15 Sek: Speed messen, Plan neu rechnen
function ns.SpeedTick()
  SampleSpeed()
  ns.CheckLevel()
  -- Plan nur neu rechnen bei Levelwechsel, neuem Ziel oder alle 2 Minuten
  local lvl, now = UnitLevel("player"), GetTime()
  -- optimierte Route: der alte Zonen Plan braucht kein Neurechnen alle 2 Minuten (kostet Ruckler)
  local periodic = not db.optMode and now - (ns.planBuiltAt or -999) > 120
  if db and db.planTarget and (lvl ~= ns.planLvl or db.planTarget ~= ns.planTgt or periodic) then
    ns.planLvl, ns.planTgt, ns.planBuiltAt = lvl, db.planTarget, now
    local plan, grindPlan, text, ptime = BuildPlan(db.planTarget)
    if plan then db.plan = plan; db.planGrind = grindPlan; ns.planTime, ns.planTimeAt = ptime, GetTime() end
    db.planText = text
    if WorldMapFrame and WorldMapFrame:IsShown() then Draw() end
    if ns.RefreshUI then ns.RefreshUI() end
  end
end

------------------------------------------------------------
-- Fortschritt
------------------------------------------------------------
local function Advance(mapID, step)
  local route = GetRoute(mapID)
  if not route then return end
  local idx = db.progress[mapID] or 1
  local d = DoneSet(mapID)
  if step > 0 then
    local p = route[idx]
    if p and p[3] then d[p[3]] = true end
  else
    local p = route[idx - 1]
    if p and p[3] then d[p[3]] = nil end
  end
  SyncProgress(mapID, route)
  ns.waiting = nil
  Announce(mapID)
  Draw()
  if ns.RefreshUI then ns.RefreshUI() end
end
ns.Advance = Advance

-- Ist der naechste Punkt zu hoch? Dann zum naechsten sinnvollen Abschnitt springen
local function TooHigh(mapID, p, L)
  local st = p.stage or LocStage(mapID, p[1], p[2])
  return st > L + 2, st
end

function ns.SkipSuggestion()
  if not db then return end
  local mapID = PlayerMap()
  local route = mapID and GetRoute(mapID)
  if not route then return end
  local idx = db.progress[mapID] or 1
  local p = route[idx]
  if not p then return end
  local L = UnitLevel("player")
  local high, st = TooHigh(mapID, p, L)
  if not high then return end
  -- naechster Punkt in dieser Zone, der passt
  for j = idx + 1, #route do
    if not TooHigh(mapID, route[j], L) then
      return { map = mapID, from = idx, to = j, count = j - idx, name = route[j][3], stage = st,
        text = (TR"Punkt %d ist für Level %d. Weiter bei Punkt %d: %s"):format(idx, st, j, route[j][3] or "?") }
    end
  end
  -- nichts mehr passend hier: zuerst laut Level Plan, sonst naechste Zone in der Reihenfolge
  local nextZone
  local pc, pn = ns.PlanNow(L)
  if pc and pc[1] ~= mapID then nextZone = pc[1] elseif pn then nextZone = pn[1] end
  if nextZone then
    return { map = mapID, from = idx, to = #route + 1, count = #route - idx + 1, stage = st, zone = nextZone,
      text = (TR"Rest der Zone ist für Level %d+. Laut Plan jetzt: %s"):format(st, ZoneName(nextZone)) }
  end
  local pos = 0
  for k, id in ipairs(ns.zoneOrder) do if id == mapID then pos = k end end
  for k, id in ipairs(ns.zoneOrder) do
    local z = ns.zones[id]
    local curMin = (ns.zones[mapID] and ns.zones[mapID].min) or 0
    if k > pos and pos > 0 and z and z.min > curMin and z.min <= L + 1 and z.max >= L + 1 then
      local r = GetRoute(id)
      if not (r and (db.progress[id] or 1) > #r) then nextZone = id; break end
    end
  end
  return { map = mapID, from = idx, to = #route + 1, count = #route - idx + 1, stage = st, zone = nextZone,
    text = nextZone and (TR"Rest der Zone ist für Level %d+. Besser weiter nach %s"):format(st, ZoneName(nextZone))
      or (TR"Rest der Zone ist für Level %d+"):format(st) }
end

-- Punkte zurueckstellen, bis man das Level dafuer hat (nicht erledigt, kommen spaeter wieder)
function ns.DoSkip()
  local sg = ns.SkipSuggestion()
  if not sg then Print(TR"Nichts zu überspringen, der Punkt passt zum Level"); return end
  local route = GetRoute(sg.map)
  db.defer = db.defer or {}
  db.defer[sg.map] = db.defer[sg.map] or {}
  local L = UnitLevel("player")
  for i = sg.from, sg.to - 1 do
    local p = route[i]
    if p and p[3] then
      local _, st = TooHigh(sg.map, p, L)
      db.defer[sg.map][p[3]] = math.max(st - 2, L + 1)
    end
  end
  SyncProgress(sg.map, route)
  ns.waiting = nil
  Print((TR"%d Punkte zurückgestellt, die kommen wieder, wenn du das Level hast."):format(sg.count))
  if sg.zone then
    Print(TR"Weiter nach " .. ZoneName(sg.zone))
    local hint = ns.travelHint and ns.travelHint[sg.map .. ">" .. sg.zone]
    if hint then Print("  " .. hint) end
  elseif (db.progress[sg.map] or 1) > #route then
    local lo
    for _, lv in pairs(db.defer[sg.map]) do if not lo or lv < lo then lo = lv end end
    Print((TR"Alles Passende hier ist erledigt. Weiter questen oder grinden, ab Level %d geht es hier weiter."):format(lo or L + 1))
  else
    Announce(sg.map)
  end
  Draw()
  if ns.RefreshUI then ns.RefreshUI() end
end

-- kompakte Infos fuer das Mini HUD
-- Farbe vom Schritt (Farbstreifen links im Mini Fenster, Karte), auch fuer Tooltip und Hilfe
ns.KIND_COLORS = {
  { { 1, 0.5, 0 }, TR"Orange: Quest annehmen" },
  { { 1, 0.4, 0.8 }, TR"Rosa: Questziel" },
  { { 0.3, 1, 0.6 }, TR"Grün: Quest abgeben" },
  { { 0.4, 0.8, 1 }, TR"Blau: Reise (Schiff, Zeppelin, Flug)" },
  { { 1, 0.3, 0.3 }, TR"Rot: Grinden" },
  { { 0.4, 1, 0.4 }, TR"Hellgrün: Flugpunkt holen" },
  { { 1, 1, 0.4 }, TR"Gelb: Entdecken" },
  { { 0.4, 1, 0.6 }, TR"Mintgrün: Farmen" },
  { { 0.6, 0.6, 0.6 }, TR"Grau: Händler, Lehrer, Gasthaus, Ruhestein, Buch" },
}
-- 1.1 (P40, S 11:24): jetzige Quest heller und dezent nach Art gefaerbt (toeten, sammeln, annehmen, abgeben, reisen).
-- Zaehler gruen, sobald das Ziel fast voll ist (ab HUD_NEAR_DONE oder es fehlt nur noch eins)
ns.HUD_KIND_TINT = { kill = "ffd2c8", collect = "fff0b4", accept = "ffdcae", turnin = "c4ffd4", travel = "c8e6ff", other = "ffffff" }
ns.HUD_NEAR_DONE = 0.75
ns.HUD_NEAR_LEFT = 1
ns.HUD_NEAR_COL = "50ff50"
ns.HUD_KIND_OF_ACT = { A = "accept", T = "turnin", R = "travel", F = "travel" }
function ns.ObjKind(o)
  local t = o and o.typ
  if t == "monster" then return "kill" end
  if t == "item" or t == "object" then return "collect" end
  return "other"
end
function ns.ObjHud(o)
  local txt = tostring(o and o.text or "")
  if o and o.done then return "|cff6d6d6d" .. txt .. "|r" end
  local tint = ns.HUD_KIND_TINT[ns.ObjKind(o)] or "ffffff"
  local head, have, need = txt:match("^(.-)(%d+)%s*/%s*(%d+)%s*$")
  have, need = tonumber(have), tonumber(need)
  if have and need and need > 0 and (have / need >= ns.HUD_NEAR_DONE or need - have <= ns.HUD_NEAR_LEFT) then
    return "|cff" .. tint .. head .. "|r|cff" .. ns.HUD_NEAR_COL .. have .. "/" .. need .. "|r"
  end
  return "|cff" .. tint .. txt .. "|r"
end
function ns.HudInfo()
  local i = {}
  if not db then return i end
  -- Optimierte Route: Schritt x von y und das Ziel daraus
  if db.optMode and ns.OptTarget then
    local st, pt, name = ns.OptTarget()
    local opt = db.opt
    local mapID = PlayerMap()
    i.zone = mapID and ZoneName(mapID) or "?"
    if opt then i.idx, i.total, i.done = math.min(opt.idx or 1, #opt.steps), #opt.steps, (opt.idx or 1) - 1 end
    -- Mini Fenster: Zone der Route an dieser Stelle und der Schritt in dieser Zone ("Wald von Elwynn, Schritt 12 von 57"),
    -- dazu die naechste Zone ("danach Westfall"). Staedte zaehlen zu ihrer Zone.
    if opt and opt.steps and #opt.steps > 0 then
      local function Z(m) return m and ((ns.cityParent and ns.cityParent[m]) or m) end
      local n = #opt.steps
      local idx = math.max(1, math.min(opt.idx or 1, n))
      local z = Z(opt.steps[idx].map)
      local a, b = idx, idx
      while a > 1 and Z(opt.steps[a - 1].map) == z do a = a - 1 end
      while b < n and Z(opt.steps[b + 1].map) == z do b = b + 1 end
      i.zoneIdx, i.zoneTotal = idx - a + 1, b - a + 1
      i.zoneName = z and ZoneName(z) or i.zone
      local nz
      for k = b + 1, n do local m = Z(opt.steps[k].map); if m and m ~= z then nz = m; break end end
      local pl0 = db.plan60
      if not nz and opt.plan and pl0 and pl0.secs and pl0.secs[opt.plan + 1] then
        for _, st2 in ipairs(pl0.secs[opt.plan + 1].steps or {}) do local m = Z(st2.map); if m and m ~= z then nz = m; break end end
      end
      i.nextZone = nz and ZoneName(nz) or nil
      -- 20.3k (S Test 20.3g Punkt 3): Fenster zeigte "Schritt 2 von 51" (in dieser Zone), der Chat "Schritt 2 von 63"
      -- (ganzer Abschnitt). Im Fenster jetzt klar die Zone: "Durotar, 2 von 51 hier"
      i.zone = (TR"%s, %d von %d hier"):format(i.zoneName or "?", i.zoneIdx, i.zoneTotal)
    end
    -- Fahrplan: Schritt ueber den ganzen Plan zaehlen ("Schritt 312 von 2100")
    local pl = db.plan60
    if opt and opt.plan and pl and pl.secs then
      local before, all = 0, 0
      for k, sc in ipairs(pl.secs) do
        if k < opt.plan then before = before + #(sc.steps or {}) end
        all = all + #(sc.steps or {})
      end
      i.idx, i.total = before + (i.idx or 1), all
      i.done = before + (opt.idx or 1) - 1
    end
    if ns.planBuilding and ns.planProgress then i.planMsg = ns.planProgress end
    -- 20.1b (P9): erster Abschnitt laeuft schon, der Rest rechnet im Hintergrund
    if ns.planBuilding and st and opt and opt.early then i.planNote = TR"Weitere Level werden im Hintergrund berechnet ..." end
    if opt and opt.pin then i.back = true; i.zone = TR"|cffffd100Zurück geblättert|r, Weiter geht wieder vor" end
    if st then
      -- Art nach der Aktion, die gerade offen ist (nicht die erste im Schritt)
      local ca = ns.OptCurrentAct and ns.OptCurrentAct()
      local k = (ca and ca.k) or (st.acts and st.acts[1] and st.acts[1].k)
      i.kind = ({ A = TR"Quests annehmen", O = (ca and ca.buyAt) and TR"Kaufen" or TR"Questziel", T = TR"Quests abgeben", R = TR"Reise", G = (ca and ca.hint) and ((ca.grp and ca.dung) and TR"Dungeon" or TR"Level fehlt") or TR"Grinden", F = TR"Flugpunkt", E = TR"Entdecken", P = TR"Farmen",
        V = (ca and ca.trainer) and TR"Lehrer" or TR"Händler", K = TR"Buch holen", H = TR"Ruhestein", B = TR"Gasthaus" })[k] or TR"Schritt"
      i.col = ({ A = { 1, 0.5, 0 }, O = { 1, 0.4, 0.8 }, T = { 0.3, 1, 0.6 }, R = { 0.4, 0.8, 1 }, G = { 1, 0.3, 0.3 }, F = { 0.4, 1, 0.4 }, E = { 1, 1, 0.4 }, P = { 0.4, 1, 0.6 } })[k]
      i.qids = {}
      for _, a in ipairs(st.acts) do if a.qid and a.qid > 0 then table.insert(i.qids, a.qid) end end
      i.name = name
      local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
      if pos then
        local px, py = pos:GetXY()
        local d = WorldDist({ mapID, px, py }, { st.map, st.x, st.y })
        if d then i.dist, i.time = math.floor(d), ns.Clock(d / (ns.speed or 7)) end
        -- Ruhestein: keine Entfernung zum Gasthaus zeigen, benutzt wird er hier
        if ca and ca.k == "H" then i.dist, i.time = nil, nil end
      end
    elseif opt then
      i.finished = true
    end
    if not st and i.planMsg then i.name = i.planMsg; i.finished = nil end
    -- Questziele dieses Schritts mit Stand (z.B. Hirnloser Zombie getötet: 3/8). Nur die Ziele, die dieser
    -- Schritt macht: die anderen Ziele der Quest kommen in spaeteren Schritten (sonst stehen sie doppelt da,
    -- einmal hier und nochmal bei Danach oder Mitnehmen)
    i.objs = {}
    -- Quest annehmen, die vom Level her noch nicht geht (du bist knapp hinter der Route): sagen, ab wann
    local ca = st and ns.OptCurrentAct and ns.OptCurrentAct()
    if st and ca and ca.k == "A" and ca.qid then
      local QDB = ns.QDBAccess and select(1, ns.QDBAccess())
      local okR, rl = false, nil
      if QDB and QDB.QueryQuestSingle then okR, rl = pcall(QDB.QueryQuestSingle, ca.qid, "requiredLevel") end
      local L = UnitLevel("player") or 1
      rl = okR and tonumber(rl)
      if rl and rl > L then
        local need = math.max(0, (ns.xpTotal and ns.xpTotal[rl] or 0) - ((ns.xpTotal and ns.xpTotal[L] or 0) + (ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0)))
        table.insert(i.objs, (TR"|cffff9030Geht erst ab Level %d|r, noch %d XP. Kurz grinden oder Schritt überspringen."):format(rl, math.floor(need)))
      end
    end
    local shown = {}
    local VON = TR" (von "
    local function Base(t)
      if type(t) ~= "string" then return nil end
      local p = t:find(VON, 1, true)
      return p and t:sub(1, p - 1) or t
    end
    if st and ns.logProgress then
      local seenQ, seenL = {}, {}
      for _, a in ipairs(st.acts) do
        local lp = a.qid and ns.logProgress[a.qid]
        if a.k == "O" and lp then
          local hit = false
          local want = Base(a.obj)
          if want and want ~= "" then
            local o, oi = ns.ObjFind(lp.objs, want, nil, function(k) return seenL[a.qid .. ":" .. k] end)
            if o then
              seenL[a.qid .. ":" .. oi] = true
              hit = true
              if #i.objs < 4 then table.insert(i.objs, ns.ObjHud(o)) end
              if not o.done and not i.objKind then i.objKind = ns.ObjKind(o) end
            end
            shown[want] = true
          end
          -- Ziel nicht im Log gefunden (anderer Name): dann alle Ziele der Quest, wie frueher
          if not hit and not seenQ[a.qid] then
            seenQ[a.qid] = true
            for oi, o in ipairs(lp.objs or {}) do
              if not seenL[a.qid .. ":" .. oi] and #i.objs < 4 then
                seenL[a.qid .. ":" .. oi] = true
                table.insert(i.objs, ns.ObjHud(o))
                if not o.done and not i.objKind then i.objKind = ns.ObjKind(o) end
              end
            end
          end
        end
      end
    end
    -- 1.1 (P40): Farbe fuer den Namen oben (Art der offenen Aktion, bei Questzielen die Art vom ersten offenen Ziel)
    do
      local ca3 = st and ns.OptCurrentAct and ns.OptCurrentAct()
      local k3 = (ca3 and ca3.k) or (st and st.acts and st.acts[1] and st.acts[1].k)
      local kind3 = (k3 == "O") and (i.objKind or "other") or ns.HUD_KIND_OF_ACT[k3]
      i.tint = kind3 and ns.HUD_KIND_TINT[kind3] or nil
    end
    -- gleiches Ziel fuer mehrere Quests (zb drei Quests wollen Eberlungen): einmal zeigen, mit Anzahl Quests
    if #i.objs > 1 then
      local seenT, out = {}, {}
      for _, l in ipairs(i.objs) do
        if seenT[l] then seenT[l].n = seenT[l].n + 1 else seenT[l] = { n = 1 }; out[#out + 1] = l end
      end
      for k, l in ipairs(out) do
        if seenT[l].n > 1 then out[k] = l .. (TR" |cff9d9d9d(%d Quests)|r"):format(seenT[l].n) end
      end
      i.objs = out
    end
    -- Abgeben, aber im Questlog ist noch ein Ziel offen (Ziel ohne Ort, Item verkauft ...): sagen, was fehlt,
    -- statt still beim NPC zu warten
    if st and ns.logProgress then
      local ca2 = ns.OptCurrentAct and ns.OptCurrentAct()
      local lp = ca2 and ca2.k == "T" and ca2.qid and ns.logProgress[ca2.qid]
      if lp and not lp.complete then
        local open = {}
        for _, o in ipairs(lp.objs or {}) do if not o.done and #open < 2 then open[#open + 1] = o.text end end
        if #open > 0 then
          table.insert(i.objs, 1, TR"|cffff9030Noch offen:|r |cffffffff" .. table.concat(open, ", ") .. "|r")
        end
      end
    end
    -- wichtig: was man unterwegs gleich mitnehmen soll (naechste Questziele in der Naehe).
    -- Ab dem uebernaechsten Schritt (den naechsten zeigt schon "Danach") und nichts, was oben schon steht.
    i.along = {}
    if st and opt then
      local nx1 = opt.steps[(opt.idx or 1) + 1]
      local a0 = nx1 and nx1.acts and nx1.acts[1]
      if a0 and a0.obj then shown[Base(a0.obj)] = true end
      for k = (opt.idx or 1) + 2, math.min(#opt.steps, (opt.idx or 1) + 4) do
        local nx = opt.steps[k]
        local a1 = nx and nx.acts and nx.acts[1]
        if a1 and a1.k == "O" then
          local d = WorldDist({ st.map, st.x, st.y }, { nx.map, nx.x, nx.y })
          local lp = a1.qid and ns.logProgress and ns.logProgress[a1.qid]
          -- nur was jetzt schon geht: Quest im Log (oder Item, das man vorab sammeln darf), und noch nicht erledigt
          local can = (lp ~= nil or a1.pre) and not (ns.OptActDone and ns.OptActDone(a1))
          local key = Base(a1.obj or a1.quest)
          -- steht schon oben bei den Zielen (auch wenn der Name im Log etwas anders ist, zb "Sleepers' Key: 0/8")
          local inObjs = false
          if key and key ~= "" then
            for _, l in ipairs(i.objs) do if l:find(key, 1, true) then inObjs = true; break end end
          end
          if can and d and d < 300 and key and not shown[key] and not inObjs then
            shown[key] = true
            if a1.qid then i.alongQ = i.alongQ or {}; i.alongQ[a1.qid] = true end
            local prog = ""
            for _, o in ipairs(lp and lp.objs or {}) do if key and o.text:find(key, 1, true) then prog = "  " .. (o.text:match("(%d+/%d+)") or ""); break end end
            table.insert(i.along, (a1.obj or a1.quest or "?") .. prog)
          end
        end
      end
    end
    if ns.missed then
      i.warn = (TR"Bei %s noch nicht %s: %s"):format(ns.missed.name or "?", ns.missed.turnin and (ns.EN and "turned in" or "abgegeben") or (ns.EN and "accepted" or "angenommen"), table.concat(ns.missed.names, ", "))
    elseif ns.levelWarn and not ns.levelWarn.ignored then
      i.warn = (TR"Unterlevelt, Ziel Level %d"):format(ns.levelWarn.need)
    end
    -- kein Questziel in diesem Schritt: Stand einer Quest aus diesem Schritt (nicht irgendeine aus der Zone)
    if #i.objs == 0 and ns.ProgressText then
      -- nicht die Quest, deren Ziel gleich als Danach kommt (sonst steht es zweimal da)
      local nx = opt and opt.steps and opt.steps[(opt.idx or 1) + 1]
      local nq = nx and nx.acts and nx.acts[1] and nx.acts[1].qid
      for _, q in ipairs(i.qids or {}) do
        local lp = ns.logProgress and ns.logProgress[q]
        if lp and not lp.complete and q ~= nq and not (i.alongQ and i.alongQ[q]) then i.progress = ns.ProgressText(q); if i.progress then break end end
      end
    end
    return i
  end
  local mapID = PlayerMap()
  local route = mapID and GetRoute(mapID)
  local speed = ns.speed or 7
  i.zone = mapID and ZoneName(mapID) or "?"
  if route then
    i.idx, i.total = math.min(db.progress[mapID] or 1, #route), #route
    i.done = math.max(0, (db.progress[mapID] or 1) - 1)
    local p = route[db.progress[mapID] or 1]
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if p and pos then
      local px, py = pos:GetXY()
      local kind, name, tx, ty = p.kind, p[3], p[1], p[2]
      local ph = ns.PendingHub(mapID, px, py)
      if ph then kind, name, tx, ty = ph.turnin and "turnin" or "quest", ph[3], ph[1], ph[2] end
      -- Quests an diesem Ziel (fuer den Gruppen Sync)
      i.qids = {}
      local function AddQ(list) for _, q in ipairs(list or {}) do if q.id then table.insert(i.qids, q.id) end end end
      if ph then AddQ(ph.quests) end
      local t = p.tags or {}
      if type(t.quest) == "table" then AddQ(t.quest.quests) end
      if type(t.turnin) == "table" then AddQ(t.turnin.quests) end
      if type(t.obj) == "table" and t.obj.qid then table.insert(i.qids, t.obj.qid) end
      local c = KINDCOL[kind] or YELLOW
      i.kind = KINDNAME[kind] or TR"Punkt"
      i.col = c
      i.name = name
      local d = WorldDist({ mapID, px, py }, { mapID, tx, ty })
      if d then i.dist, i.time = math.floor(d), ns.Clock(d / speed) end
    elseif not p then
      i.finished = true
    end
  end
  if ns.missed then
    i.warn = (TR"Nicht %s: %s"):format(ns.missed.turnin and (ns.EN and "turned in" or "abgegeben") or (ns.EN and "accepted" or "angenommen"), table.concat(ns.missed.names, ", "))
  elseif ns.levelWarn and not ns.levelWarn.ignored then
    i.warn = (TR"Unterlevelt, Ziel Level %d"):format(ns.levelWarn.need)
  end
  if ns.ZoneProgressLines then
    local l = ns.ZoneProgressLines(1)
    i.progress = l and l[1]
  end
  i.skip = ns.SkipSuggestion()
  return i
end

-- Zone neu starten: pruefen, was schon erledigt ist, und bis dahin vorspringen
local function Explored(mapID, p)
  local learned = db.learned[mapID]
  if learned and p[3] and learned[p[3]] then return true end
  local api = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredAreaIDsAtPosition
  if api and CreateVector2D then
    local ok, ids = pcall(api, mapID, CreateVector2D(p[1], p[2]))
    if ok and type(ids) == "table" and #ids > 0 then return true end
  end
  return false
end

local function SmartReset(mapID)
  if not mapID then return end
  db.done = db.done or {}
  db.done[mapID] = {}
  db.learnedRev = (db.learnedRev or 0) + 1
  local route = GetRoute(mapID)
  if not route then return end
  local L = UnitLevel("player")
  local state, lastDone = {}, 0
  for i, p in ipairs(route) do
    local t = p.tags or {}
    local s
    if t.quest == true or (type(t.quest) == "table" and t.quest.quests) or t.turnin or t.obj then
      s = "open" -- kommt von Questie, ist also noch zu machen
    elseif t.explore then
      s = Explored(mapID, p) and "done" or "open"
    elseif type(t.grind) == "table" then
      local want = db.planGrind and db.planGrind[mapID]
      if (want and L >= want) or L >= t.grind[5] then s = "done" end
    end
    state[i] = s
    if s == "done" then lastDone = i end
  end
  -- Questie Punkte zaehlen nur, wenn die Quest in Questie bekannt ist; Schaetz Hubs wie Wegpunkte
  local d = db.done[mapID]
  local n = 0
  for i, p in ipairs(route) do
    local s = state[i]
    if s == "done" or (s == nil and i < lastDone) then
      if p[3] then d[p[3]] = true; n = n + 1 end
    end
  end
  SyncProgress(mapID, route)
  ns.waiting = nil
  local idx = db.progress[mapID] or 1
  Print((TR"Zone neu geprüft: %d Punkte schon erledigt, weiter bei Punkt %d von %d"):format(n, idx, #route))
  Announce(mapID)
  Draw()
  if ns.RefreshUI then ns.RefreshUI() end
end
ns.SmartReset = SmartReset

-- XP dieser Session
sess = { start = nil, xp = 0 }

-- XP pro Stunde so genau wie moeglich: nur aktive Zeit zaehlt, und nur die letzten 20 aktiven Minuten.
-- Wer 10 Minuten AFK steht, zieht den Schnitt nicht runter; danach zaehlt wieder, was jetzt passiert.
local RATE_WIN = 20 * 60
local buckets, idleFor = {}, 0
local function RateBucket()
  local k = math.floor(GetTime() / 60)
  local b = buckets[#buckets]
  if not b or b.k ~= k then
    b = { k = k, act = 0, xp = 0 }
    table.insert(buckets, b)
    while #buckets > 90 do table.remove(buckets, 1) end
  end
  return b
end
local function ActiveTick()
  local moving = ns.Api.GetUnitSpeed and (Plain(ns.Api.GetUnitSpeed("player")) or 0) > 0
  local fight = UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player")
  local afk = UnitIsAFK and ns.Api.U(UnitIsAFK, "player")
  local taxi = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  if moving or fight or taxi then idleFor = 0 else idleFor = idleFor + 1 end
  -- kurz stehen (reden, looten, essen) gehoert dazu, ab 90 Sekunden ohne alles gilt es als Pause
  if afk or idleFor > 90 then return end
  local b = RateBucket()
  b.act = b.act + 1
end
local function ActiveXP(d)
  local b = RateBucket()
  b.xp = b.xp + d
  idleFor = 0
end
function ns.XPRate()
  local act, xp = 0, 0
  for i = #buckets, 1, -1 do
    act = act + buckets[i].act
    xp = xp + buckets[i].xp
    if act >= RATE_WIN then break end
  end
  if act < 90 then return 0, act end
  return xp / act * 3600, act
end

local function Clock(sec)
  if not sec or sec ~= sec or sec == math.huge then return "?" end
  sec = math.floor(sec)
  local h = math.floor(sec / 3600)
  local m = math.floor((sec % 3600) / 60)
  if h > 0 then return (TR"%d:%02d Std"):format(h, m) end
  return (TR"%d:%02d Min"):format(m, sec % 60)
end
ns.Clock = Clock

local function Num(n)
  n = math.floor(n + 0.5)
  local s = tostring(n)
  local out = s:reverse():gsub("(%d%d%d)", "%1'"):reverse()
  return (out:gsub("^'", ""))
end

-- Zeilen fuers Mini Fenster
function ns.HudLines()
  if not db then return {} end
  local out = {}
  local mapID = PlayerMap()
  local route = GetRoute(mapID)
  local speed = ns.speed or 7

  if route then
    local idx = db.progress[mapID] or 1
    local p = route[idx]
    table.insert(out, (TR"|cffffd100%s|r  Punkt %d/%d"):format(ZoneName(mapID), math.min(idx, #route), #route))
    if p then
      local pos = C_Map.GetPlayerMapPosition(mapID, "player")
      local d
      if pos then
        local px, py = pos:GetXY()
        d = WorldDist({ mapID, px, py }, { mapID, p[1], p[2] })
      end
      -- zeigt der Pfeil gerade zuerst zu Quests, dann das als Ziel
      local ph = pos and ns.PendingHub(mapID, pos:GetXY())
      local kind, name = p.kind, p[3]
      if ph then
        kind, name = ph.turnin and "turnin" or "quest", ph[3]
        local px2, py2 = pos:GetXY()
        d = WorldDist({ mapID, px2, py2 }, { mapID, ph[1], ph[2] })
      end
      local c = KINDCOL[kind] or YELLOW
      local hex = ("%02x%02x%02x"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
      table.insert(out, (TR"Ziel: |cff%s[%s]|r %s"):format(hex, KINDNAME[kind] or TR"Punkt", name or "?"))
      if d then
        table.insert(out, (TR"   %d Yards, ca %s"):format(math.floor(d), Clock(d / speed)))
      end
      local gt = p.tags and type(p.tags.grind) == "table" and GrindTarget(mapID, p.tags.grind)
      if gt and ns.waiting == idx then
        table.insert(out, (TR"|cffff5050Grinden bis Level %d|r"):format(gt))
      end
    else
      table.insert(out, TR"Zone fertig!")
    end
  else
    table.insert(out, (TR"|cffffd100%s|r  keine Route"):format(mapID and ZoneName(mapID) or "?"))
  end

  local ms = ns.missed
  if ms then
    table.insert(out, (TR"|cffff5050Nicht %s bei %s:|r"):format(ms.turnin and "abgegeben" or "angenommen", ms.name or "?"))
    table.insert(out, "|cffff9030" .. table.concat(ms.names, ", ") .. "|r")
  end
  local w = ns.levelWarn
  if w and not w.ignored then
    table.insert(out, (TR"|cffff5050Unterlevelt, Ziel Level %d|r"):format(w.need))
    table.insert(out, "|cffff9030" .. (w.short or "") .. "|r")
  end
  if ns.ZoneProgressLines then
    for _, l in ipairs(ns.ZoneProgressLines(3)) do table.insert(out, "|cffff66cc" .. l .. "|r") end
  end
  table.insert(out, (TR"Speed %d%%"):format(math.floor(speed / 7 * 100 + 0.5)))
  if ns.QuestCounts then
    local qt, qd = ns.QuestCounts()
    local col = qd > 0 and "|cff40ff40" or ""
    table.insert(out, (TR"Quests: %d im Log, %s%d fertig zum Abgeben|r"):format(qt, col, qd))
    local qc = ns.questCheck
    if qc and qc.problems > 0 then
      table.insert(out, (TR"|cffff9030Quest Check: %d Probleme, siehe Fenster|r"):format(qc.problems))
    end
  end

  local el = sess.start and (GetTime() - sess.start) or 0
  local xph = ns.XPRate()
  if xph > 0 then
    table.insert(out, (TR"XP/Std %s  (Session %s)"):format(Num(xph), Clock(el)))
    local rest = UnitXPMax("player") - UnitXP("player")
    table.insert(out, (TR"Nächstes Level in %s"):format(Clock(rest / xph * 3600)))
  else
    table.insert(out, TR"XP/Std: wird gemessen")
  end

  if db.planTarget and ns.planTime then
    local left = ns.planTime - (GetTime() - (ns.planTimeAt or GetTime()))
    table.insert(out, (TR"Level %d in ca %s"):format(db.planTarget, Clock(math.max(0, left))))
  end
  local pc, pn = ns.PlanNow()
  if pc then
    local here = PlayerMap()
    local txt = (TR"Laut Plan: %s bis Level %d"):format(ZoneName(pc[1]), pc[3])
    if pn then txt = txt .. (TR", danach %s"):format(ZoneName(pn[1])) end
    table.insert(out, (pc[1] == here and "|cff7fd1b9" or "|cffffd100") .. txt .. "|r")
  end
  return out
end

-- Zahlen fuer die Kacheln auf der Charakterseite
ns.STAT_LOG_S = 300
function ns.Stats()
  local s = {}
  if not db then return s end
  local el = sess.start and (GetTime() - sess.start) or 0
  s.xph = ns.XPRate()
  s.session = el
  -- 20.3l (Log 20.3k K5, S: "Lauftempo 100% obwohl beritten"): das Spiel liefert neben dem aktuellen Tempo auch das
  -- moegliche Lauftempo mit allen Boni (Reittier, Buffs, Talente, Gegenstaende), auch im Stehen. Das zeigt die Zeile.
  -- Vorher nur das zuletzt gemessene Tempo beim Laufen (im Stehen auf dem Reittier blieb 100%)
  do
    local sp = ns.speed or 7
    if ns.Api.GetUnitSpeed and not (UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")) then
      local cur, run, _, swim = ns.Api.GetUnitSpeed("player")
      cur, run, swim = Plain(cur), Plain(run), Plain(swim)
      if IsSwimming and ns.Api.U(IsSwimming) and swim and swim > 0 then sp = swim
      elseif run and run > 0 and run < 40 then sp = run
      elseif cur and cur > 0 and cur < 40 then sp = cur end
    end
    s.speedPct = math.floor(sp / 7 * 100 + 0.5)
  end
  local xp, mx = Plain(UnitXP("player")), Plain(UnitXPMax("player"))
  if xp and mx and mx > 0 then
    s.xpFrac = xp / mx
    if s.xph > 0 then s.nextLevel = (mx - xp) / s.xph * 3600 end
  end
  s.level = UnitLevel("player")
  local mapID = PlayerMap()
  s.zone = mapID and ZoneName(mapID) or "?"
  local route = mapID and GetRoute(mapID)
  local o = db.optMode and db.opt
  if o and o.steps and #o.steps > 0 then
    -- optimierte Route: Schritt aus dem Plan
    s.idx = math.min(o.idx or 1, #o.steps)
    s.total = #o.steps
    s.done = math.max(0, (o.idx or 1) - 1)
  elseif route then
    s.idx = math.min(db.progress[mapID] or 1, #route)
    s.total = #route
    s.done = math.max(0, (db.progress[mapID] or 1) - 1)
  end
  if ns.QuestCounts then s.qLog, s.qDone = ns.QuestCounts() end
  if ns.PendingQuestXP and s.qDone and s.qDone > 0 then
    local ok, px, plv, pfrac = pcall(ns.PendingQuestXP)
    if ok and px and px > 0 then s.pendXP, s.pendLevel, s.pendFrac = px, plv, pfrac end
  end
  -- 1.1 (P56, K 14:24, S Bild "2:33 Std bis Lvl 16" mit 9 fertigen Quests): Zeit bis zum Level ohne die XP der fertigen,
  -- noch nicht abgegebenen Quests. Reicht die Abgabe schon, heisst es "nach Abgabe"
  if xp and mx and mx > 0 and s.xph > 0 then
    local rest = mx - xp - (s.pendXP or 0)
    if s.pendXP and rest <= 0 then
      s.nextLevel, s.levelAfterTurnIn = 0, true
    else
      s.nextLevel = math.max(0, rest) / s.xph * 3600
    end
  end
  s.nextLevelText = s.levelAfterTurnIn and TR"nach Abgabe" or (s.nextLevel and Clock(s.nextLevel)) or nil
  -- Log STAT hoechstens alle STAT_LOG_S, wenn offene Abgabe XP da sind
  if ns.TestLog and s.pendXP and GetTime() - (ns.statLogAt or -999) > ns.STAT_LOG_S then
    ns.statLogAt = GetTime()
    ns.TestLog("STAT", ("Zeit bis Level %d: %s, offene Abgabe %d XP aus %d Quests, %d XP pro Stunde"):format((s.level or 0) + 1,
      tostring(s.nextLevelText), s.pendXP, s.qDone or 0, math.floor(s.xph or 0)))
  end
  if db.planTarget and ns.planTime then
    s.planTarget = db.planTarget
    s.planLeft = math.max(0, ns.planTime - (GetTime() - (ns.planTimeAt or GetTime())))
  end
  s.fmt = Clock
  s.num = Num
  return s
end

------------------------------------------------------------
-- Performance: Zeit und XP pro Zone, pro Charakter
------------------------------------------------------------
local function CharKey()
  return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")
end

local function Perf()
  db.perf = db.perf or {}
  local k = CharKey()
  db.perf[k] = db.perf[k] or { zones = {}, order = {}, total = 0, xp = 0 }
  return db.perf[k]
end

local function ZoneStat(mapID)
  local p = Perf()
  if not p.zones[mapID] then
    p.zones[mapID] = { t = 0, xp = 0, lvlFrom = UnitLevel("player"), lvlTo = UnitLevel("player"), kills = 0, found = 0 }
    table.insert(p.order, mapID)
  end
  return p.zones[mapID]
end

local function ZoneOnly(mapID)
  local info = mapID and C_Map.GetMapInfo(mapID)
  if info and info.mapType and Enum.UIMapType and info.mapType > Enum.UIMapType.Zone and info.parentMapID then
    return info.parentMapID -- Unterzonen und Dungeons zur Zone zaehlen
  end
  return mapID
end

-- Werte pro Level (Zeit, XP, Zaehler, Geld, Zeitverteilung)
local function LvlStat(L)
  local p = Perf()
  p.lvl = p.lvl or {}
  L = L or UnitLevel("player")
  p.lvl[L] = p.lvl[L] or { t = 0, xp = 0 }
  return p.lvl[L]
end
ns.LvlStat = LvlStat
ns.ZoneStatOf = function(id) return ZoneStat(id) end
ns.PerfData = function() return Perf() end
ns.CurZone = function() return ZoneOnly(PlayerMap()) end

-- Zaehler in einen Eintrag (Level oder Zone)
local function Bump(e, field, key, v)
  e[field] = e[field] or {}
  e[field][key] = (e[field][key] or 0) + (v or 1)
end
ns.StatBump = function(field, key, v)
  if not db then return end
  Bump(LvlStat(), field, key, v)
  local z = ZoneOnly(PlayerMap())
  if z then Bump(ZoneStat(z), field, key, v) end
  Bump(Perf(), field, key, v)
end

local function PerfTick()
  if not db then return end
  if UnitIsAFK and ns.Api.U(UnitIsAFK, "player") then return end
  local mapID = ZoneOnly(PlayerMap())
  if not mapID then return end
  local z = ZoneStat(mapID)
  z.t = z.t + 1
  z.lvlTo = UnitLevel("player")
  local p = Perf()
  p.total = p.total + 1
  ns.perfZone = mapID
  -- wofuer geht die Zeit drauf (Session und gesamt)
  local kind
  if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then kind = "dead"
  elseif UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then kind = "fly"
  elseif UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player") then kind = "fight"
  elseif ns.Api.GetUnitSpeed and (Plain(ns.Api.GetUnitSpeed("player")) or 0) > 0 then kind = "walk"
  else kind = "idle" end
  sess.split = sess.split or {}
  sess.split[kind] = (sess.split[kind] or 0) + 1
  Bump(z, "split", kind)
  local ls = LvlStat(UnitLevel("player"))
  ls.t = ls.t + 1
  Bump(ls, "split", kind)
  p.split = p.split or {}
  p.split[kind] = (p.split[kind] or 0) + 1
  -- Zeit pro Level (bleibt gespeichert)
  local L = UnitLevel("player")
  p.lvlTime = p.lvlTime or {}
  p.lvlTime[L] = (p.lvlTime[L] or 0) + 1
  -- XP pro Minute fuer das Diagramm (nur diese Session)
  if sess.lastMinXP == nil then sess.lastMinXP = sess.xp end
  sess.tick = (sess.tick or 0) + 1
  if sess.tick % 60 == 0 then
    sess.minXP = sess.minXP or {}
    table.insert(sess.minXP, sess.xp - (sess.lastMinXP or 0))
    sess.lastMinXP = sess.xp
    if #sess.minXP > 120 then table.remove(sess.minXP, 1) end
  end
end

-- Daten fuer die Diagramme auf der Performance Seite
function ns.PerfGraph()
  local out = { rates = {}, levels = {} }
  if not db then return out end
  -- XP pro Stunde, gleitend ueber 5 Minuten, ein Balken pro 2 Minuten, letzte Stunde
  local m = sess.minXP or {}
  for i = 2, #m, 2 do
    local sum, n = 0, 0
    for j = math.max(1, i - 4), i do sum = sum + m[j]; n = n + 1 end
    table.insert(out.rates, sum / n * 60)
  end
  while #out.rates > 30 do table.remove(out.rates, 1) end
  -- Zeit pro Level, die letzten 15 Level
  local p = Perf()
  local L = UnitLevel("player")
  for lv = math.max(1, L - 14), L do
    table.insert(out.levels, { lv = lv, t = (p.lvlTime and p.lvlTime[lv]) or 0, cur = (lv == L) })
  end
  out.fmt = Clock
  out.num = Num
  return out
end

-- Zaehler fuer die Statistik (pro Charakter, bleibt gespeichert)
function ns.Count(kind, xp, money)
  if not db then return end
  local p = Perf()
  p.cnt = p.cnt or { kill = 0, quest = 0, death = 0, explore = 0, gold = 0 }
  p.src = p.src or { kill = 0, quest = 0, explore = 0 }
  p.cnt[kind] = (p.cnt[kind] or 0) + 1
  if xp and xp > 0 and p.src[kind] then p.src[kind] = p.src[kind] + xp end
  -- auch pro Level und Zone
  local ls = LvlStat()
  Bump(ls, "cnt", kind)
  if xp and xp > 0 then Bump(ls, "src", kind, xp) end
  local zid = ZoneOnly(PlayerMap())
  if zid then
    local z = ZoneStat(zid)
    Bump(z, "cnt", kind)
    if xp and xp > 0 then Bump(z, "src", kind, xp) end
  end
  if money and money > 0 then p.cnt.gold = (p.cnt.gold or 0) + money end
  sess.cnt = sess.cnt or {}
  sess.cnt[kind] = (sess.cnt[kind] or 0) + 1
end

-- Kennzahlen fuer die Performance Kacheln
function ns.PerfTiles()
  local out = {}
  if not db then return out end
  local el = sess.start and (GetTime() - sess.start) or 0
  local c = sess.cnt or {}
  local h = el / 3600
  out.xph = (el > 120) and sess.xp / el * 3600 or nil
  out.kph = (h > 0.03) and (c.kill or 0) / h or nil
  out.qph = (h > 0.03) and (c.quest or 0) / h or nil
  out.deaths = c.death or 0
  out.secPerKill = ns.KillSeconds and ns.KillSeconds() or nil
  out.fight, out.down = ns.KillBreakdown(0)
  local kb = ns.StatBucket()
  out.xpPerKill = MobXP(UnitLevel("player")) * ns.GroupXPShare() * ((kb.killN or 0) >= 3 and (kb.killRatio or 1) or 1)
  local r = GetXPExhaustion and Plain(GetXPExhaustion()) or nil
  out.rested = type(r) == "number" and r or 0
  local mx = Plain(UnitXPMax("player")) or 1
  out.restedPct = mx > 0 and out.rested / mx * 100 or 0
  out.split = sess.split or {}
  out.splitAll = Perf().split or {}
  -- optimierte Route: Plan gegen echte Zeit
  local opt = db.opt
  if opt and opt.created and opt.steps and opt.idx and opt.idx > 1 then
    local s = opt.steps[opt.idx - 1]
    if s and s.t and time then
      out.optPlan = s.t
      out.optReal = time() - opt.created
    end
  end
  return out
end

-- alles fuer die grosse Statistik Seite
function ns.BigStats()
  local out = {}
  if not db then return out end
  local p = Perf()
  out.cnt = p.cnt or {}
  out.src = p.src or {}
  out.totalXP = p.xp or 0
  out.totalTime = p.total or 0
  out.sessCnt = sess.cnt or {}
  -- Zonen: Zeit, XP, XP pro Stunde
  out.zones = {}
  for _, id in ipairs(p.order or {}) do
    local z = p.zones[id]
    if z and z.t > 60 then
      table.insert(out.zones, { name = ZoneName(id), t = z.t, xp = z.xp, rate = z.xp / z.t * 3600, from = z.lvlFrom, to = z.lvlTo })
    end
  end
  -- Level Verlauf: Zeit pro Level und aufsummiert
  out.levels = {}
  local L = UnitLevel("player")
  local sum = 0
  for lv = 1, L do
    local t = (p.lvlTime and p.lvlTime[lv]) or 0
    sum = sum + t
    table.insert(out.levels, { lv = lv, t = t, sum = sum })
  end
  -- Prognose bis 60 mit der aktuellen XP pro Stunde (Session, sonst gesamt)
  local el = sess.start and (GetTime() - sess.start) or 0
  local rate = (el > 300 and sess.xp > 0) and (sess.xp / el * 3600) or ((p.total or 0) > 600 and (p.xp or 0) / p.total * 3600 or 0)
  out.rate = rate
  local now = (ns.xpTotal[L] or 0) + (Plain(UnitXP("player")) or 0)
  out.xpTo60 = math.max(0, (ns.xpTotal[60] or 0) - now)
  if rate > 0 then out.eta60 = out.xpTo60 / rate * 3600 end
  out.fmt = Clock
  out.num = Num
  return out
end

local function PerfXP(d)
  if not db or d <= 0 then return end
  local ls = LvlStat()
  ls.xp = ls.xp + d
  local mapID = ZoneOnly(PlayerMap())
  if mapID then ZoneStat(mapID).xp = ZoneStat(mapID).xp + d end
  Perf().xp = Perf().xp + d
end

-- restliche Punkte einer Zone als Zeit
local function ZoneRestSec(mapID)
  local route = GetRoute(mapID)
  if not route then return nil end
  local start = db.progress[mapID] or 1
  if start > #route then return 0 end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  local path, prev = 0, nil
  if pos then local x, y = pos:GetXY(); prev = { mapID, x, y } end
  for i = start, #route do
    local p = { mapID, route[i][1], route[i][2] }
    if prev then path = path + (WorldDist(prev, p) or 0) end
    prev = p
  end
  return path * 1.25 / (ns.speed or 7)
end

function ns.PerfLines()
  if not db then return {} end
  local out = {}
  local p = Perf()
  local cur = ns.perfZone or ZoneOnly(PlayerMap())
  local function Rate(xp, t) return (t > 60) and Num(xp / t * 3600) or "?" end

  table.insert(out, TR"|cffffd100Aktuelle Zone|r")
  if cur then
    local z = ZoneStat(cur)
    table.insert(out, ("   %s"):format(ZoneName(cur)))
    table.insert(out, (TR"   Zeit hier: %s"):format(Clock(z.t)))
    table.insert(out, (TR"   XP hier: %s, also %s pro Std"):format(Num(z.xp), Rate(z.xp, z.t)))
    table.insert(out, (TR"   Level %d bis %d"):format(z.lvlFrom, z.lvlTo))
    local planned = ns.planZoneSec and ns.planZoneSec[cur]
    if planned then
      local route = GetRoute(cur)
      local finished = route and (db.progress[cur] or 1) > #route
      local diff = z.t - planned
      if finished then
        table.insert(out, (TR"   Geplant: %s, %s"):format(Clock(planned),
          diff > 0 and ("|cffff5050" .. Clock(diff) .. TR" länger gebraucht|r") or ("|cff40ff40" .. Clock(-diff) .. TR" schneller|r")))
      elseif diff > 0 then
        table.insert(out, (TR"   Geplant: %s, |cffff5050schon %s drüber|r"):format(Clock(planned), Clock(diff)))
      else
        table.insert(out, (TR"   Geplant: %s, laut Plan noch %s"):format(Clock(planned), Clock(-diff)))
      end
    end
    local rest = ZoneRestSec(cur)
    if rest then table.insert(out, (TR"   Rest der Zone: ca %s Laufzeit"):format(Clock(rest))) end
  end

  local el = sess.start and (GetTime() - sess.start) or 0
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Diese Session|r")
  table.insert(out, (TR"   Zeit: %s, XP: %s, %s pro Std"):format(Clock(el), Num(sess.xp), Rate(sess.xp, el)))

  if db.planTarget and ns.planTime then
    local left = ns.planTime - (GetTime() - (ns.planTimeAt or GetTime()))
    table.insert(out, (TR"   Bis Level %d noch ca %s"):format(db.planTarget, Clock(math.max(0, left))))
  end

  table.insert(out, "")
  table.insert(out, TR"|cffffd100Gesamt mit diesem Charakter|r")
  table.insert(out, (TR"   Zeit: %s, XP: %s, %s pro Std"):format(Clock(p.total), Num(p.xp), Rate(p.xp, p.total)))

  if #p.order > 0 then
    table.insert(out, "")
    table.insert(out, TR"|cffffd100Bisherige Zonen|r")
    for _, id in ipairs(p.order) do
      local z = p.zones[id]
      if z and z.t > 30 then
        table.insert(out, (TR"   %s: %s, %s XP, Level %d bis %d"):format(ZoneName(id), Clock(z.t), Num(z.xp), z.lvlFrom, z.lvlTo))
      end
    end
  end
  return out
end

-- was an einem Punkt zu tun ist, fuer den Tooltip auf der Karte
function ns.PointHint(mapID, p)
  local out = {}
  if not p then return out end
  local route = GetRoute(mapID) or {}
  local idx
  for i, q in ipairs(route) do if q == p then idx = i end end
  local kind = KINDNAME[p.kind] or TR"Punkt"
  local prog = db.progress[mapID] or 1
  local state = ""
  if idx then
    if idx < prog then state = TR" |cff9d9d9d(erledigt)|r" elseif idx == prog then state = TR" |cff40ff40(nächstes Ziel)|r" end
  end
  table.insert(out, ("|cffffd100%s%s|r%s"):format(idx and (idx .. ". ") or "", p[3] or "?", state))
  local t = p.tags or {}
  local L = UnitLevel("player")
  if t.explore then table.insert(out, TR"Gebiet entdecken") end
  if t.fp then table.insert(out, TR"Flugmeister ansprechen") end
  if type(t.quest) == "table" and ns.QuestHint then
    local h = ns.QuestHint(p)
    if h then table.insert(out, h) end
  end
  if type(t.grind) == "table" then
    local g = t.grind
    local gt = GrindTarget(mapID, g)
    if g[4] >= L + 3 then
      table.insert(out, (TR"|cffff5050Mobs Level %d bis %d, zu stark, auslassen|r"):format(g[4], g[5]))
    elseif gt and gt > L then
      table.insert(out, (TR"|cffff5050Hier grinden bis Level %d|r (Mobs %d bis %d)"):format(gt, g[4], g[5]))
    else
      table.insert(out, (TR"Mobs Level %d bis %d, laut Plan nicht nötig"):format(g[4], g[5]))
    end
  end
  if type(t.turnin) == "table" and ns.QuestHint then
    table.insert(out, "|cff40ff90" .. (ns.QuestHint({ tags = { turnin = t.turnin } }) or "") .. "|r")
  end
  if type(t.obj) == "table" and ns.ProgressText then
    table.insert(out, "|cffff66cc" .. (ns.ProgressText(t.obj.qid) or t.obj.quest or "") .. "|r")
  end
  if t.via then table.insert(out, TR"Shift+Linksklick löscht ihn") end
  if p.kind ~= "via" then table.insert(out, "|cff9d9d9d(" .. kind .. ")|r") end
  return out
end

-- naechste Schritte als Text
function ns.RouteSteps(n)
  if not db then return {} end
  if db.optMode and ns.OptLines then return ns.OptLines(n) end
  n = n or 12
  local out = {}
  local mapID = PlayerMap()
  local route = GetRoute(mapID)
  local speed = ns.speed or 7
  local w = ns.levelWarn
  if w and not w.ignored and w.lines then
    for _, l in ipairs(w.lines) do table.insert(out, l) end
    table.insert(out, "")
  end
  if not route then
    table.insert(out, TR"Keine Route für " .. (mapID and ZoneName(mapID) or TR"diese Zone"))
    return out
  end
  table.insert(out, (TR"|cffffd100%s|r, Punkt %d von %d"):format(ZoneName(mapID), math.min(db.progress[mapID] or 1, #route), #route))
  out.zoneHead = #out -- Kopfzeile merken (Text ist je nach Sprache anders)
  local ppos = C_Map.GetPlayerMapPosition(mapID, "player")
  local ph = ppos and ns.PendingHub(mapID, ppos:GetXY())
  if ph then
    table.insert(out, ph.turnin and (TR"|cff40ff90Zuerst: Quests abgeben bei %s|r"):format(ph[3]) or (TR"|cffff9030Zuerst: Quests holen bei %s|r"):format(ph[3]))
  end
  local start = db.progress[mapID] or 1
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  local prev = pos and { mapID, pos:GetXY() } or nil
  local acc = 0
  local L = UnitLevel("player")
  for i = start, math.min(#route, start + n - 1) do
    local p = route[i]
    local here = { mapID, p[1], p[2] }
    local d = prev and WorldDist(prev, here) or 0
    acc = acc + d / speed
    prev = here
    local t = p.tags or {}
    local kind = KINDNAME[p.kind] or TR"Punkt"
    table.insert(out, (TR"%d. |cffffffff[%s]|r %s  |cff9d9d9d%d Yards, nach ca %s|r"):format(i, kind, p[3] or "?", math.floor(d), Clock(acc)))
    if t.fp then table.insert(out, TR"     Flugmeister ansprechen") end
    if type(t.quest) == "table" and ns.QuestHint then
      local h = ns.QuestHint(p)
      if h then table.insert(out, "     " .. h) end
    end
    if type(t.turnin) == "table" and ns.QuestHint then
      table.insert(out, "     |cff40ff90" .. ns.QuestHint({ tags = { turnin = t.turnin } }) .. "|r")
    end
    if type(t.obj) == "table" and ns.ProgressText then
      table.insert(out, "     |cffff66cc" .. (ns.ProgressText(t.obj.qid) or "") .. "|r")
    end
    if type(t.grind) == "table" then
      local g = t.grind
      local gt = GrindTarget(mapID, g)
      if g[4] >= L + 3 then
        table.insert(out, (TR"     Mobs Level %d bis %d, zu stark, auslassen"):format(g[4], g[5]))
      elseif gt then
        table.insert(out, (TR"     Hier grinden bis Level %d"):format(gt))
      end
    end
  end
  if start + n - 1 < #route then
    table.insert(out, (TR"... und noch %d weitere Punkte"):format(#route - (start + n - 1)))
  end
  return out
end

function ns.Status()
  if not db then return "" end
  local mapID = PlayerMap()
  local route = GetRoute(mapID)
  local out = { TR"Zone: " .. (mapID and ZoneName(mapID) or "?") }
  if not route then
    table.insert(out, TR"Keine Route für diese Zone")
  else
    local idx = db.progress[mapID] or 1
    local p = route[idx]
    if p then
      table.insert(out, (TR"Nächster: %d/%d %s"):format(idx, #route, p[3] or ""))
    else
      table.insert(out, TR"Zone fertig!")
    end
    local c = db.custom[mapID]
    if c and #c > 0 then table.insert(out, TR"Eigene Route: " .. #c .. TR" Punkte") end
  end
  table.insert(out, (TR"Radius: %.3f   Route: %s"):format(db.radius, db.show and (ns.EN and "on" or "an") or (ns.EN and "off" or "aus")))
  return table.concat(out, "\n")
end

------------------------------------------------------------
-- Quests zuerst: offene Quest Hubs in der Zone vor allem anderen
------------------------------------------------------------
local function HubVisits()
  db.hubVisited = db.hubVisited or {}
  local k = CharKey()
  db.hubVisited[k] = db.hubVisited[k] or {}
  return db.hubVisited[k]
end

-- bringt der Hub gerade etwas und war man noch nicht (oder vor 2+ Leveln) dort?
local function HubPending(mapID, h)
  local L = UnitLevel("player")
  if h[5] < L - 4 or h[4] > L + 3 then return false end -- grau oder zu hoch
  local v = HubVisits()[mapID .. ":" .. h[3]]
  if not v then return true end
  return L >= v + 2 and h[5] >= L
end

-- naechster offener Quest Hub in der aktuellen Zone
local sticky -- aktuelles Quest Ziel, bleibt bis erledigt

local function StillPending(mapID, st)
  if not st or st.map ~= mapID then return nil end
  if st.x and LocStage(mapID, st.x, st.y) > UnitLevel("player") + 2 then return nil end
  local list = st.turnin and (ns.qEnds and ns.qEnds[mapID]) or (ns.qStarts and ns.qStarts[mapID])
  for _, e in ipairs(list or {}) do
    if e.npc == st.npc and (st.turnin or HubPending(mapID, e)) then
      return { e[1], e[2], e[3], hub = e, turnin = st.turnin }
    end
  end
end

function ns.PendingHub(mapID, px, py)
  if not (db and db.questFirst and mapID) then return end
  -- gleiches Ziel behalten, solange es offen ist
  local keep = StillPending(mapID, sticky)
  if keep then return keep end
  sticky = nil
  -- nur was in der Naehe ist und zum Level passt; weit weg oder hoeheres Gebiet macht die Route spaeter
  local L = UnitLevel("player")
  local realX, realY = px, py
  local LOCAL = 0.13
  local function Near(e)
    if Dist(realX, realY, e[1], e[2]) > LOCAL then return false end
    return LocStage(mapID, e[1], e[2]) <= L + 2
  end
  -- sonst das naechste Ziel ab dem letzten Ziel suchen, nicht ab der Spielerposition
  if ns.lastQuestPos and ns.lastQuestPos[1] == mapID then px, py = ns.lastQuestPos[2], ns.lastQuestPos[3] end
  local best, bd
  if ns.qStarts then
    for _, e in ipairs((ns.qEnds and ns.qEnds[mapID]) or {}) do
      if Near(e) then
        local d = Dist(px, py, e[1], e[2])
        if not bd or d < bd then best, bd = { e[1], e[2], e[3], hub = e, turnin = true }, d end
      end
    end
    if not best then
      for _, e in ipairs(ns.qStarts[mapID] or {}) do
        if HubPending(mapID, e) and Near(e) then
          local d = Dist(px, py, e[1], e[2])
          if not bd or d < bd then best, bd = { e[1], e[2], e[3], hub = e }, d end
        end
      end
    end
    if best then
      sticky = { map = mapID, npc = best.hub.npc, turnin = best.turnin, x = best[1], y = best[2] }
      ns.lastQuestPos = { mapID, best[1], best[2] }
    end
    return best
  end
  for _, h in ipairs(ns.hubs[mapID] or {}) do
    if HubPending(mapID, h) then
      local x, y = h[1], h[2]
      local ov = db.override[mapID] and db.override[mapID][TR"Quests " .. h[3]]
      if ov then x, y = ov[1], ov[2] end
      local d = Dist(px, py, x, y)
      if not bd or d < bd then best, bd = { x, y, h[3], hub = h }, d end
    end
  end
  return best
end

function ns.MarkHubVisited(mapID, h)
  HubVisits()[mapID .. ":" .. h[3]] = UnitLevel("player")
end

-- Checkt jede Sekunde, ob ihr beim naechsten Punkt seid
-- Ist die Aufgabe eines Questziel Punkts erledigt? nil = weiss nicht
local function ObjDone(o)
  if type(o) ~= "table" or not o.qid or not ns.logProgress then return nil end
  local q = ns.logProgress[o.qid]
  if not q then return true end -- nicht mehr im Log: abgegeben oder abgebrochen
  if q.complete then return true end
  if o.obj then
    for _, ob in ipairs(q.objs or {}) do
      if ob.text and ob.text:find((ns.OptObjKey and ns.OptObjKey(o.obj)) or (o.obj:gsub("%s*%(.*%)$", "")), 1, true) then return ob.done and true or false end
    end
  end
  return false
end
ns.ObjDone = ObjDone

-- wirklich noch offen? (Questie Liste kann alt sein: im Log nachsehen und ob die Quest schon erledigt ist)
local function DoneQuest(id)
  if not id then return false end
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return true end
  if IsQuestFlaggedCompleted and IsQuestFlaggedCompleted(id) then return true end
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  return c and c[id] and true or false
end
local function StillOpen(q, turnin)
  if not q or not q.id then return true end
  if ns.ReadLog then ns.ReadLog() end
  local lp = ns.logProgress and ns.logProgress[q.id]
  if turnin then return lp ~= nil and lp.complete and true or false end
  if lp or DoneQuest(q.id) then return false end
  if q.level and q.level > (UnitLevel("player") or 1) + 4 then return false end
  return true
end
ns.QuestStillOpen = StillOpen

local function Tick()
  if not db or not db.show then return end
  -- optimierte Route: die fuehrt (Schritte warten selbst aufs Annehmen), die alte Zonenroute bleibt still
  if db.optMode then
    if ns.missed then ns.missed = nil; if ns.serviceTarget and ns.serviceTarget.kind == "missed" then ns.serviceTarget = nil end end
    ns.atGiver = nil
    return
  end
  local mapID = PlayerMap()
  local route = GetRoute(mapID)
  if not route then return end
  local idx = db.progress[mapID] or 1
  local p = route[idx]
  if not p then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  -- reiner Grind Spot mit zu starken Mobs: auslassen
  local g = p.tags and type(p.tags.grind) == "table" and p.tags.grind
  if g and p.kind == "grind" and not p.tags.explore and not p.tags.fp and not p.tags.quest and g[4] >= UnitLevel("player") + 3 then
    Print((TR"Grind Spot %s ausgelassen, Mobs Level %d sind zu stark"):format(g[3], g[4]))
    Advance(mapID, 1)
    return
  end
  local px, py = pos:GetXY()
  local hub = ns.PendingHub(mapID, px, py)
  if hub and Dist(px, py, hub[1], hub[2]) < db.radius * 1.5 then
    if hub.hub.npc then
      -- Questie Questgeber: merken und beim Weggehen pruefen, ob alles angenommen ist
      if not ns.atGiver or ns.atGiver.npc ~= hub.hub.npc then
        ns.atGiver = { npc = hub.hub.npc, map = mapID, x = hub[1], y = hub[2], name = hub[3], turnin = hub.turnin }
        Print(hub.turnin and (TR"Bei %s Quests abgeben"):format(hub[3]) or (TR"Bei %s Quests annehmen"):format(hub[3]))
      end
    else
      ns.MarkHubVisited(mapID, hub.hub)
      Print(hub.turnin and (TR"Bei %s Quests abgeben"):format(hub[3]) or (TR"Bei %s Quests annehmen. Danach gehts mit der Route weiter."):format(hub[3]))
    end
  end
  -- vom Questgeber weggegangen: ist noch was offen?
  local ag = ns.atGiver
  if ag and ag.map == mapID and Dist(px, py, ag.x, ag.y) > 0.04 then
    ns.atGiver = nil
    local list = ag.turnin and (ns.qEnds and ns.qEnds[mapID]) or (ns.qStarts and ns.qStarts[mapID])
    for _, e in ipairs(list or {}) do
      if e.npc == ag.npc and e.quests and #e.quests > 0 then
        -- nur was wirklich noch offen ist (im Log fertig, oder noch nicht angenommen und nicht erledigt)
        local names = {}
        for _, q in ipairs(e.quests) do if StillOpen(q, ag.turnin) then table.insert(names, q.name) end end
        if #names > 0 then
          ns.missed = { npc = ag.npc, map = mapID, name = ag.name, names = names, turnin = ag.turnin, entry = e }
          Print((TR"|cffff5050Achtung:|r Bei %s noch nicht %s: %s"):format(ag.name, ag.turnin and "abgegeben" or "angenommen", table.concat(names, ", ")))
          Print(TR"Der Pfeil zeigt zurück. Auslassen mit /klg auslassen oder Quest auslassen unter Meine Route.")
          -- Pfeil gleich dorthin
          ns.serviceTarget = { map = mapID, x = ag.x, y = ag.y, name = ("%s: %s"):format(ag.name, ag.turnin and TR"noch abgeben" or TR"noch annehmen"), kind = "missed" }
          if ns.Draw then ns.Draw() end
          if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
        end
        break
      end
    end
  end
  -- alles erledigt? dann Warnung wieder weg
  local ms = ns.missed
  if ms then
    local still
    for _, q in ipairs(ms.entry and ms.entry.quests or {}) do if StillOpen(q, ms.turnin) then still = true end end
    if not still then
      ns.missed = nil
      if ns.serviceTarget and ns.serviceTarget.kind == "missed" then
        ns.serviceTarget = nil
        Print(TR"Erledigt, weiter mit der Route.")
        if ns.Draw then ns.Draw() end
      end
    end
  end
  -- Questziel: weiter, sobald die Aufgabe erfuellt ist (egal wo man gerade steht)
  local ob = p.tags and type(p.tags.obj) == "table" and p.tags.obj
  if ob and ObjDone(ob) then
    if ns.waiting == idx then ns.waiting = nil end
    Print(TR"Questziel erledigt: " .. (ob.obj or ob.quest or p[3] or "?"))
    Advance(mapID, 1)
    return
  end
  if Dist(px, py, p[1], p[2]) < db.radius then
    -- Questziel noch nicht fertig: hier bleiben, nicht ueberspringen
    if ob and ObjDone(ob) == false then
      if ns.waiting ~= idx then
        ns.waiting = idx
        local prog = ns.ProgressText and ns.ProgressText(ob.qid)
        Print((TR"Questziel erreicht: %s. Die Route wartet, bis es fertig ist."):format(prog or ob.obj or "?"))
      end
      return
    end
    -- am Grind Spot warten, bis das Level aus dem Plan erreicht ist
    local gt = p.tags and type(p.tags.grind) == "table" and GrindTarget(mapID, p.tags.grind)
    if gt and UnitLevel("player") < gt then
      if ns.waiting ~= idx then
        ns.waiting = idx
        Print((TR"Grind Spot erreicht, grinden bis Level %d. Danach gehts automatisch weiter."):format(gt))
      end
      return
    end
    Print(TR"Erreicht: " .. (p[3] or idx))
    Advance(mapID, 1)
  end
end

------------------------------------------------------------
-- Befehle
------------------------------------------------------------
-- Englische Befehle: gehen auf jedem Client, werden auf den deutschen Befehl umgestellt
local CMD_EN = {
  setup = "einrichten", on = "an", off = "aus", skip = "auslassen", gear = "ausruestung", blocked = "blockiert",
  shop = "einkaufen", beginner = "einsteiger", learn = "lernen", expert = "experte", explain = "erklaerungen",
  farm = "farmen", danger = "gefahr", nodanger = "gefahrweg", ignore = "ignorieren", loud = "laut", arrow = "pfeil",
  points = "punkte", questfirst = "questzuerst", calc = "rechnung", nowarn = "warnweg", why = "warum", wpdel = "wegweg",
  paths = "wege", ways = "wege", flights = "fluege", ["flüge"] = "fluege", guided = "gefuehrt", ["geführt"] = "gefuehrt", free = "frei", unlocked = "frei",
  testmode = "testmodus", zonepath = "karte", terrain = "karte",
}
ns.CMD_EN = CMD_EN
-- Test Befehle: gehen nur nach /klg testmodus (gilt bis zum Ausloggen) und stehen sonst nicht in der Liste.
-- /klg testlog notiz bleibt fuer alle (die Tester brauchen es).
local TEST_CMDS = { tlvl = true, diag = true, rechnung = true, laut = true, warum = true, blockiert = true, id = true,
  stats = true, pfeil = true, add = true, undo = true, clear = true, export = true, radius = true,
  reset = true, wegweg = true, plan = true }
function ns.TestMode() return ns.testMode and true or false end
local function Slash(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  cmd = CMD_EN[cmd] or cmd
  if cmd == "testmodus" then
    ns.testMode = not ns.testMode
    Print(ns.testMode and TR"Testmodus an: Test Befehle gehen jetzt (/klg help zeigt sie). Aus mit /klg testmodus oder beim Ausloggen."
      or TR"Testmodus aus.")
    if not ns.testMode and ns.testLevel and ns.SimLevel then ns.SimLevel(nil) end
    return
  end
  if TEST_CMDS[cmd] and not ns.testMode then Print(TR"Unbekannt, /klg help"); return end
  -- 20.3j (S Test 20.3g Punkt 11): /klg log start | stop fuer alle, schaltet das Test Log und zeigt den Kasten Test Notiz
  local logSub = (cmd == "log") and (((rest or ""):match("^(%S*)") or ""):lower()) or nil
  -- /klg log 40 38 (Questlog Plaetze) bleibt wie bisher, nur start/stop gehoeren zum Test Log
  if logSub and (logSub == "start" or logSub == "stop" or logSub == "an" or logSub == "aus" or logSub == "on" or logSub == "off") then
    local sub = logSub
    if sub == "start" or sub == "an" or sub == "on" then
      if ns.TestLogCmd then ns.TestLogCmd("an") end
      if ns.TestLogActive and ns.TestLogActive() then
        if ns.db then ns.db.testerBox = true end
        if ns.TesterBoxStart then pcall(ns.TesterBoxStart) end
        Print(TR"Es wird geloggt. Fehler oder Ideen im Kasten Test Notiz eintragen. Aus mit /klg log stop.")
      end
    else
      if ns.TestLogCmd then ns.TestLogCmd("aus") end
    end
    return
  end
  if cmd == "testlog" and not ns.testMode then
    local sub = (rest or ""):match("^(%S*)")
    if sub ~= "notiz" and sub ~= "note" then Print(TR"/klg testlog notiz TEXT  Notiz ins Test Log schreiben"); return end
  end
  -- "help": auf Deutsch wie bisher die kurze Liste, auf Englisch die Anleitung (wie "hilfe")
  if cmd == "help" and ns.EN and ns.ShowBig then cmd = "hilfe" end
  local mapID = PlayerMap()

  if cmd == "log" then
    local v = tonumber((rest or ""):match("^(%d+)"))
    local w = tonumber((rest or ""):match("^%d+%s+(%d+)"))
    if v and v >= 10 and v <= 50 then
      db.logMax = v; if w then db.logWarn = w end
      Print((TR"Questlog: %d Plätze, Warnung ab %d. Route wird neu berechnet."):format(v, ns.LogWarn())); if ns.AutoOptSoon then ns.AutoOptSoon() elseif ns.AutoOpt then ns.AutoOpt(true) end
    else Print((TR"Questlog: %d Plätze, Warnung ab %d. Ändern mit /klg log 40 38 oder unter Einstellungen"):format(ns.LogMax(), ns.LogWarn())) end
    return
  end
  if cmd == "blockiert" then
    if rest == "reset" then db.blockedLog = {}; db.forbidden = {}; Print(TR"Liste der blockierten Aktionen geleert."); return end
    local any = false
    for fn, n in pairs(db.blockedLog or {}) do any = true; Print((TR"blockiert: %s (%dx)"):format(fn, n)) end
    if not any then Print(TR"Bisher hat Blizzard nichts blockiert.") end
    return
  end
  if cmd == "gear" or cmd == "ausruestung" then
    if ns.ShowBig then ns.ShowBig("gear") end
    return
  end
  if cmd == "farm" or cmd == "farmen" then
    if rest == "stop" then if ns.FarmStop then ns.FarmStop() end
    elseif ns.ShowBig then ns.ShowBig("farm") end
    return
  end
  if cmd == "einkaufen" then
    if ns.ShowShopping then ns.ShowShopping() elseif ns.PrintShopping then ns.PrintShopping() end
    return
  end
  if cmd == "pfeil" then
    if ns.ArrowCheck then ns.ArrowCheck() end
    return
  end
  if cmd == "einrichten" or cmd == "setup" then
    if ns.ShowSetup then ns.ShowSetup() end
    return
  end
  if cmd == "warum" then
    if ns.OptWhyReport then ns.OptWhyReport() end
    return
  end
  -- Meldungen vom Optimierer: letzte zeigen, oder laut stellen
  if cmd == "pause" then
    if ns.SetPaused then ns.SetPaused(not db.paused) end
    return
  end
  if cmd == "punkte" then
    db.pinIcons = (db.pinIcons == false)
    ns.Print(db.pinIcons and TR"Karte: Punkte als Symbole." or TR"Karte: Punkte wie früher (Ringe und Kästchen).")
    if ns.Draw then ns.Draw() end
    return
  end
  if cmd == "testlog" then
    if ns.TestLogCmd then ns.TestLogCmd(rest) end
    return
  end
  if cmd == "rechnung" then
    for _, m in ipairs(ns.optLog or {}) do ns.Print(m) end
    if not ns.optLog or #ns.optLog == 0 then ns.Print(TR"Noch keine Meldungen.") end
    return
  end
  if cmd == "laut" then
    db.optVerbose = not db.optVerbose
    ns.Print(db.optVerbose and TR"Optimierer Meldungen im Chat an." or TR"Optimierer Meldungen im Chat aus. /klg rechnung zeigt sie.")
    return
  end
  -- Fehlersuche: warum findet er keine Quests?
  if cmd == "diag" then
    local function C(v) return v and TR"|cff40ff40ja|r" or TR"|cffff5050nein|r" end
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    local ver, build, _, iface = GetBuildInfo()
    Print((TR"Spiel: %s (%s), Interface %s, Projekt %s"):format(tostring(ver), tostring(build), tostring(iface), tostring(WOW_PROJECT_ID)))
    Print((TR"Questie geladen: %s, Version %s"):format(C(loaded and loaded("Questie")), tostring(meta and meta("Questie", "Version"))))
    Print((TR"QuestieDB geladen: %s, Version %s, LibQuestieDB: %s"):format(C(loaded and loaded("QuestieDB")), tostring(meta and meta("QuestieDB", "Version")), C(LibQuestieDB ~= nil)))
    Print((TR"QuestieLoader: %s, Questie.db.char: %s"):format(C(QuestieLoader ~= nil), C(Questie and Questie.db and Questie.db.char)))
    local nIds = 0
    local lib = LibQuestieDB
    local okA, all = pcall(function() return lib and lib.Quest and lib.Quest.GetAllIds and lib.Quest.GetAllIds() end)
    if okA and type(all) == "table" then nIds = #all end
    local QDB = ns.QDBAccess and ns.QDBAccess()
    local nPtr = 0
    if QDB and QDB.QuestPointers then for _ in pairs(QDB.QuestPointers) do nPtr = nPtr + 1 end end
    Print((TR"Questie Daten bereit: %s, Quests aus LibQuestieDB: %d, aus Questie: %d"):format(C(QDB ~= nil), nIds, nPtr))
    local mapID = PlayerMap()
    Print((TR"Karte: %s (%s), Level %d, Route hier: %d Schritte, rechnet: %s"):format(tostring(mapID), mapID and ZoneName(mapID) or "?",
      _G.UnitLevel("player") or 0, (mapID and GetRoute(mapID) and #GetRoute(mapID)) or 0, C(ns.OptBusy and ns.OptBusy())))
    Print(TR"Schick mir diese Zeilen, dann sehe ich, wo es hängt.")
    return
  end
  -- nur zum Testen, steht nicht in der Hilfe
  if cmd == "tlvl" then
    local arg = (rest or ""):match("^(%S+)")
    if ns.SimLevel then
      if not arg or arg == "aus" or arg == "off" or arg == "0" then ns.SimLevel(nil) else ns.SimLevel(tonumber(arg)) end
    end
    return
  end
  if cmd == "gefuehrt" or cmd == "frei" or cmd == "experte" or cmd == "einsteiger" or cmd == "lernen" then
    local m = (cmd == "frei" or cmd == "experte") and "free" or "guided"
    if ns.SetMode then ns.SetMode(m) end
    Print(m == "free" and TR"Modus Alles frei: alles ist sofort da." or TR"Modus Geführt: Funktionen kommen mit dem Level dazu, jede mit kurzer Erklärung.")
    return
  end
  if cmd == "erklaerungen" or cmd == "erklärungen" then
    if ns.CoachReset then ns.CoachReset() end
    return
  end
  if cmd == "look" then
    if ns.CycleLook then ns.CycleLook() end
    return
  end
  if cmd == "hilfe" then
    if ns.ShowBig then ns.ShowBig("help") end
    return
  end
  if cmd == "" or cmd == "help" then
    Print(TR"/klg  grosses Fenster,  /klg hilfe  Anleitung im grossen Fenster")
    Print(TR"/klg an | aus  Route zeigen oder verstecken,  /klg pause  alles anhalten oder weiter")
    Print(TR"/klg einrichten  Einrichtung nochmal,  /klg gefahr | gefahrweg  Gefahr hier markieren oder löschen")
    -- Test Log Notiz nur nennen, wenn das Test Log gerade schreibt
    if ns.TestLogActive and ns.TestLogActive() then Print(TR"/klg testlog notiz TEXT  Notiz ins Test Log schreiben") end
    if ns.testMode then
      Print(TR"|cffffd100Testmodus:|r /klg tlvl 30 | aus  Test Level,  /klg diag  Questie prüfen,  /klg warum  warum so wenig Quests")
      Print(TR"|cffffd100Testmodus:|r /klg rechnung  letzte Meldungen der Route,  /klg laut  Meldungen im Chat,  /klg testlog an | aus | leeren")
      Print(TR"|cffffd100Testmodus:|r /klg stats  gemessene XP Werte,  /klg id  MapID,  /klg wege  Wege teilen Stand,  /klg blockiert  blockierte Aktionen,  /klg pfeil  Pfeil prüfen")
      Print(TR"|cffffd100Testmodus:|r /klg add Name | undo | clear | export | reset | radius 0.02 | wegweg  eigene Wegpunkte der Zone")
      Print(TR"|cffffd100Testmodus:|r /klg karte  Stand der Gelände Karte und Strecke zum Ziel über das Wegnetz")
    end
  elseif cmd == "an" or cmd == "on" then
    db.show = true; Print(TR"Route an"); Announce(mapID); Draw()
  elseif cmd == "aus" or cmd == "off" then
    db.show = false; Print(TR"Route aus"); SetArrow(mapID, nil); Draw()
  elseif cmd == "next" then
    if db.optMode and ns.OptForward then ns.OptForward() else Advance(mapID, 1) end
  elseif cmd == "back" then
    if db.optMode and ns.OptBack then ns.OptBack() else Advance(mapID, -1) end
  elseif cmd == "reset" then
    SmartReset(mapID)
  elseif cmd == "add" then
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then Print(TR"Keine Position gefunden"); return end
    local x, y = pos:GetXY()
    db.custom[mapID] = db.custom[mapID] or {}
    local name = rest ~= "" and rest or (GetSubZoneText() ~= "" and GetSubZoneText() or (TR"Punkt " .. (#db.custom[mapID] + 1)))
    table.insert(db.custom[mapID], { x, y, name })
    Print((TR"Gespeichert #%d: %s (%.1f, %.1f)"):format(#db.custom[mapID], name, x * 100, y * 100))
    Draw()
  elseif cmd == "undo" then
    local c = mapID and db.custom[mapID]
    if c and #c > 0 then table.remove(c); Print(TR"Letzter Punkt gelöscht") end
    Draw()
  elseif cmd == "clear" then
    if not mapID then Print(TR"Keine Zone gefunden"); return end
    db.custom[mapID] = nil; db.done = db.done or {}; db.done[mapID] = {}; db.learnedRev = (db.learnedRev or 0) + 1; Print(TR"Eigene Route gelöscht"); Draw()
  elseif cmd == "export" then
    local c = db.custom[mapID]
    if not c or #c == 0 then Print(TR"Keine eigene Route in dieser Zone"); return end
    Print(("[%d] = { -- %s"):format(mapID, ZoneName(mapID)))
    for _, p in ipairs(c) do
      Print(("  { %.3f, %.3f, \"%s\" },"):format(p[1], p[2], p[3]))
    end
    Print("},")
  elseif cmd == "radius" then
    local r = tonumber(rest)
    -- sinnvoller Bereich: 0.005 bis 0.1 (Anteil der Karte), ohne Zahl den aktuellen Wert zeigen
    if r then
      r = math.max(0.005, math.min(0.1, r))
      db.radius = r
    end
    Print(TR"Radius: " .. tostring(db.radius or 0.02) .. (r and "" or "  (/klg radius 0.02)"))
  elseif cmd == "plan" then
    local t = tonumber(rest)
    Print(TR"Der Plan geht immer bis Level " .. ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) .. TR", die Route rechnet sich Abschnitt für Abschnitt.")
  elseif cmd == "stats" then
    local s = db.stats
    Print((TR"Erkundet: %d Gebiete, %d XP, %d%% der Schätzung"):format(s.exN or 0, s.exSum or 0, math.floor(ExploreRatio() * 100 + 0.5)))
    local rate, measured = KillRate(UnitLevel("player"))
    Print((TR"Kills: %d, ca %d XP/Std (%s)"):format(s.killN or 0, math.floor(rate), measured and (ns.EN and "measured" or "gemessen") or TR"geschätzt"))
  elseif cmd == "gefahr" then
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then local x, y = pos:GetXY(); ns.AddDanger(mapID, x, y, rest ~= "" and rest or TR"von Hand", nil, true); Draw() end
  elseif cmd == "gefahrweg" then
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then local x, y = pos:GetXY(); ns.RemoveDanger(mapID, x, y); Draw() end
  elseif cmd == "questzuerst" then
    db.questFirst = not db.questFirst
    Print(db.questFirst and TR"Quests zuerst: an" or TR"Quests zuerst: aus")
  elseif cmd == "auslassen" then
    local ms = ns.missed or (ns.atGiver and { npc = ns.atGiver.npc, map = ns.atGiver.map, name = ns.atGiver.name })
    if ms then
      for _, e in ipairs((ns.qStarts and ns.qStarts[ms.map]) or {}) do
        if e.npc == ms.npc then ns.MarkHubVisited(ms.map, e) end
      end
      Print((TR"Quests bei %s ausgelassen, weiter mit der Route"):format(ms.name or "?"))
      ns.missed = nil
      if ns.serviceTarget and ns.serviceTarget.kind == "missed" then ns.serviceTarget = nil end
      Draw()
    else
      Print(TR"Nichts zum Auslassen")
    end
  elseif cmd == "wegweg" then
    if not mapID then Print(TR"Keine Zone gefunden"); return end
    ns.ClearVia(mapID)
  elseif cmd == "karte" or cmd == "zonenweg" then
    -- 19.0: Stand der Gelaende Karte und Weg zum Ziel (Luftlinie, ueber das Netz, ueber die Zonen)
    local K = ns.Karte
    if not K then return end
    local st = K.Status()
    if st.state ~= "ok" then Print(K.Hint() or TR"Gelände Karte: keine Daten."); return end
    Print((TR"Gelände Karte: %s, Stand %s, Build %s, %d Zonen, %d geladen, %d mit Netz%s."):format(tostring(st.client or "?"), tostring(st.stand or "?"),
      tostring(st.build or "?"), st.zones, st.fields, st.nets, st.busy and TR", rechnet noch" or ""))
    if st.graphs ~= "" then Print(TR"Zonen Wege: " .. st.graphs) end
    if st.check then Print((TR"Übergänge gegen die Karten des Clients: im Mittel %d yd, höchstens %d yd daneben."):format(st.check, st.checkMax)) end
    -- 19.28: Daten Build gegen das Spiel (nach einem Patch kann die Karte an einzelnen Stellen veraltet sein)
    -- 20.3o (Da Pruefung Nr 1): "a and f()" gibt nur einen Wert weiter, dB und cB waren immer nil (Lua Fehler nach Patch)
    local okB, dB, cB
    if K.BuildCheck then okB, dB, cB = K.BuildCheck() end
    if okB == false then Print((TR"Daten Stand: Build %s, dein Spiel Build %s. Nach einem Patch kann die Karte an einzelnen Stellen veraltet sein."):format(tostring(dB or "?"), tostring(cB or "?"))) end
    local m = ns.PlayerMap and ns.PlayerMap()
    local x, y
    local pos = m and C_Map.GetPlayerMapPosition(m, "player")
    if pos then x, y = pos:GetXY() end
    local stp = ns.OptTarget and ns.OptTarget()
    if m and x and stp and stp.map and stp.x then
      local d = ns.WorldDistXY(m, x, y, stp.map, stp.x, stp.y)
      local zp = ns.cityParent and ns.cityParent[m] or m
      local zq = ns.cityParent and ns.cityParent[stp.map] or stp.map
      local nd
      if zp == zq then
        local tx, ty = stp.x, stp.y
        if stp.map ~= m then tx, ty = ns.ToMap(stp.map, stp.x, stp.y, m) end
        if tx then nd = ns.GridDist(m, x, y, tx, ty) end
      else
        nd = ns.XZoneDist(m, x, y, stp.map, stp.x, stp.y)
      end
      Print((TR"Zum Ziel: Luftlinie %s yd, über das Wegnetz %s yd."):format(d and math.floor(d) or "-", nd and math.floor(nd) or TR"(Luftlinie ist frei)"))
    end
  elseif cmd == "wege" then
    if ns.SyncStatus then ns.SyncStatus() end
    if ns.FlightsStatus then ns.FlightsStatus() end
  elseif cmd == "fluege" then
    if ns.FlightsStatus then ns.FlightsStatus() end
  elseif cmd == "quests" then
    ns.PrintQuestCheck()
  elseif cmd == "ignorieren" then
    ns.IgnoreWarn()
  elseif cmd == "warnweg" then
    ns.IgnoreWarn()
    if ns.missed then
      for _, e in ipairs((ns.qStarts and ns.qStarts[ns.missed.map]) or {}) do
        if e.npc == ns.missed.npc then ns.MarkHubVisited(ns.missed.map, e) end
      end
      ns.missed = nil
    end
    Print(TR"Warnungen ausgeblendet")
  elseif cmd == "check" then
    ns.CheckLevel()
    if not ns.levelWarn then Print(TR"Level passt, alles gut") end
  elseif cmd == "id" then
    Print(TR"Zone: " .. ZoneName(mapID) .. TR" MapID: " .. tostring(mapID))
  else
    Print(TR"Unbekannt, /klg help")
  end
  if ns.RefreshUI then ns.RefreshUI() end
end

------------------------------------------------------------
-- Start Tor: der Wegweiser rechnet erst, wenn alles andere geladen ist
-- (alle Addons, Ladebildschirm weg, ein paar Sekunden Ruhe). Questie selbst prueft danach QuestieBridge.
------------------------------------------------------------
local gate = { pew = false, pewAt = 0, lastAddon = 0, open = false, loadAt = GetTime and GetTime() or 0 }
-- wie lange noch (Sekunden), bis das Tor aufgeht (geschaetzt: 3 Sekunden Ruhe nach dem letzten Addon)
function ns.StartGateLeft()
  if gate.open or ns.startGateForce then return 0 end
  local now = GetTime()
  if not gate.pew then return 5 end
  return math.max(1, math.ceil(3 - (now - math.max(gate.pewAt, gate.lastAddon))))
end
function ns.StartReady()
  if gate.open or ns.startGateForce then return true end
  if not gate.pew then return false end
  local now = GetTime()
  if now - gate.pewAt < 3 or now - gate.lastAddon < 3 then return false end
  gate.open = true
  if ns.TestLog then
    ns.TestLog("START", ("alle Addons geladen, Rechnen frei nach %.0fs"):format(now - gate.loadAt))
  end
  return true
end
do
  local gf = CreateFrame("Frame")
  gf:RegisterEvent("ADDON_LOADED")
  gf:RegisterEvent("PLAYER_ENTERING_WORLD")
  gf:RegisterEvent("LOADING_SCREEN_DISABLED")
  gf:SetScript("OnEvent", function(_, event)
    if gate.open then gf:UnregisterAllEvents(); return end
    local now = GetTime and GetTime() or 0
    if event == "ADDON_LOADED" then gate.lastAddon = now
    else gate.pew = true; gate.pewAt = now end
  end)
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:RegisterEvent("UI_INFO_MESSAGE")
f:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("PLAYER_XP_UPDATE")
-- Kampflog (COMBAT_LOG_EVENT_UNFILTERED) ist auf Forever fuer Addons gesperrt, daher nicht mehr benutzt
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("QUEST_TURNED_IN")

-- Kaputte gespeicherte Daten (von Hand geaendert, Absturz beim Speichern, sehr alte Version): was den falschen Typ hat,
-- wird verworfen und neu angelegt, statt dass das Addon beim Einloggen mit einem Fehler abbricht (Sim 17.2)
local SV_TABLES = { "opt", "plan60", "myWay", "planHist", "planPast", "bindInn", "hudPos", "arrowPos", "stats", "chars", "profiles",
  "trail", "progress", "custom", "learned", "renames", "danger", "via", "override", "mobDanger", "done", "defer", "knownFP", "booksDone",
  "bookTierDone", "gearSkip", "gearPick", "logPick", "classSeen", "unlockSeen", "innHinted", "startAsked", "svcSnooze", "profSel", "profSess", "profLastOpt",
  "questBlocked", "forceQ", "planGrind", "mobLayer", "tourAt", "shared", "sharedD", "sharedOut", "sharedX", "syncIgnore", "blockedLog",
  "cross", "walk", "walkDir", "walkDrop", "road", "cliff", "water", "loot", "recipes", "killRep", "questMoney", "best", "block", "perf",
  "coachSeen", "migrated", "minimap", "prof", "profPlan", "qdrop", "otherSaid", "hubVisited", "forbidden", "bookItems", "bookPick",
  "startBindNames", "questTwin", "optParked", "farmSess", "repGoal", "docks", "npcName", "hubQuests", "oldCVars", "shareFail", "skipQ",
  -- 20.3l (Na J1): vermutete Flugpunkte (pro Charakter, siehe CHAR_FIELDS)
  "fpVermutet" }
local function SaneSteps(steps)
  if type(steps) ~= "table" then return nil end
  local ok = {}
  for _, st in ipairs(steps) do
    if type(st) == "table" and type(st.acts) == "table" then
      local acts = {}
      for _, a in ipairs(st.acts) do if type(a) == "table" and type(a.k) == "string" then acts[#acts + 1] = a end end
      if #acts > 0 then st.acts = acts; ok[#ok + 1] = st end
    end
  end
  return ok
end
local function SaneOpt(o)
  if type(o) ~= "table" then return nil end
  local st = SaneSteps(o.steps)
  if not st or #st == 0 then return nil end
  o.steps = st
  if type(o.idx) ~= "number" or o.idx < 1 then o.idx = 1 end
  if o.idx > #st + 1 then o.idx = #st end
  if o.title ~= nil and type(o.title) ~= "string" then o.title = nil end
  return o
end
local function SaneFields(t)
  local n = 0
  for _, k in ipairs(SV_TABLES) do
    if t[k] ~= nil and type(t[k]) ~= "table" then t[k] = nil; n = n + 1 end
  end
  if t.opt then local o = SaneOpt(t.opt); if not o then t.opt = nil; n = n + 1 end end
  local pl = t.plan60
  if pl then
    local good = type(pl.secs) == "table" and #pl.secs > 0
    if good then
      for _, sc in ipairs(pl.secs) do if type(sc) ~= "table" then good = false; break end end
    end
    if not good then t.plan60 = nil; n = n + 1
    else
      if type(pl.cur) ~= "number" or pl.cur < 1 or pl.cur > #pl.secs then pl.cur = 1 end
      for _, sc in ipairs(pl.secs) do if sc.steps ~= nil then sc.steps = SaneSteps(sc.steps) end end
    end
  end
  if t.myWay and type(t.myWay.steps) ~= "table" then t.myWay = nil; n = n + 1 end
  local bi = t.bindInn
  if bi and not (type(bi[1]) == "number" and type(bi[2]) == "number" and type(bi[3]) == "number") then t.bindInn = nil; n = n + 1 end
  for _, k in ipairs({ "hudPos", "arrowPos" }) do
    local p = t[k]
    if p and not (type(p[1]) == "string" and type(p[2]) == "string" and type(p[3]) == "number" and type(p[4]) == "number") then t[k] = nil; n = n + 1 end
  end
  -- alte Werte (Modus easy, learn, expert, Tempo 1 bis 7) stellt die Umstellung danach selber um, die bleiben
  if t.mode ~= nil and type(t.mode) ~= "string" then t.mode = nil; n = n + 1 end
  local lsOk = type(t.levelStep) == "number" and t.levelStep >= 1 and t.levelStep <= 7 and t.levelStep % 1 == 0
  if lsOk and (tonumber(t.setVer) or 0) >= (ns.SETTINGS_VER or 3) and ns.LEVEL_STEPS and not ns.LEVEL_STEPS[t.levelStep] then lsOk = false end
  if t.levelStep ~= nil and not lsOk then t.levelStep = nil; n = n + 1 end
  if t.hudSize ~= nil and type(t.hudSize) ~= "string" then t.hudSize = nil; n = n + 1 end
  if t.hudScale ~= nil and type(t.hudScale) ~= "number" then t.hudScale = nil; n = n + 1 end
  if t.chars then
    for ck, cv in pairs(t.chars) do
      if type(ck) ~= "string" or type(cv) ~= "table" then t.chars[ck] = nil; n = n + 1 else n = n + SaneFields(cv) end
    end
  end
  return n
end
ns.SanitizeDB = SaneFields

f:SetScript("OnEvent", function(_, event, ...)
  if event == "PLAYER_LOGIN" then
    -- 20.3m (AUF K 22:32, Release Ordner KeineZeitLevelingGuide): laeuft daneben noch der alte Ordner ForeverWegweiser,
    -- rechnen und zeichnen beide. Einmal pro Sitzung im Chat sagen, dass der alte aus soll
    do
      local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
      local other = ADDON ~= "ForeverWegweiser" and "ForeverWegweiser" or "KeineZeitLevelingGuide"
      local okL, isL = pcall(function() return loaded and loaded(other) end)
      if okL and isL then
        C_Timer.After(6, function()
          ns.Print((TR"Der Ordner %s ist auch noch eingeschaltet. Bitte nur einen laufen lassen: im Charakter Menü bei AddOns den alten ausschalten."):format(other))
        end)
      end
    end
    -- neuer Name: Daten vom alten TaurenRoute einmal uebernehmen
    if not KeineZeitLevelingGuideDB and type(TaurenRouteDB) == "table" then
      KeineZeitLevelingGuideDB = TaurenRouteDB
      KeineZeitLevelingGuideDB.migratedFrom = "TaurenRoute"
      C_Timer.After(8, function()
        Print(TR"Deine Daten von TaurenRoute wurden übernommen. Der alte Ordner TaurenRoute kann gelöscht werden.")
      end)
    end
    if type(KeineZeitLevelingGuideDB) ~= "table" then KeineZeitLevelingGuideDB = {} end
    db = KeineZeitLevelingGuideDB
    do
      local okS, nBad = pcall(SaneFields, db)
      if okS and nBad > 0 then
        C_Timer.After(6, function() Print((TR"%d gespeicherte Einträge waren kaputt und wurden neu angelegt."):format(nBad)) end)
      end
    end
    -- pro Charakter: Route, Fahrplan, Einrichtung, Ruhestein, Lehrer, Flugpunkte, Buecher ...
    -- (vorher fuer den ganzen Account: ein Level 60 Magier hatte die Route vom neuen Tauren)
    do
      local CHAR_FIELDS = { "opt", "plan60", "setupDone", "firstStartDone", "trainedAt", "bindInn", "bindZone", "bindStart", "hearthUsedAt", "startPlan", "startAsked", "forceQ", "innHinted", "knownFP",
        "questBlocked", "planGrind", "booksDone", "booksTurned", "bookTierDone", "gearSkip", "gearPick", "logPick", "classSeen", "unlockSeen",
        "stepChanged", "trainerSkip", "svcSnooze", "optMode", "profSel", "profSess", "profLastOpt",
        -- auch pro Charakter: Zonen Fortschritt, Tempo (ein Twink ohne Reittier ist langsamer), Gold Modus
        "progress", "done", "defer", "plan", "planText", "goldIdx", "goldMode", "goldTarget", "mountSpeed", "runSpeed",
        -- Kampf Messwerte (Zeit pro Kill, XP pro Kill, Tode pro Zone): ein 60er soll die Schaetzung fuer einen Twink nicht verfaelschen
        "stats", "optParked",
        -- Weg zu 60: was dieser Charakter gemacht hat und seine Zeiten (vorher fuer den ganzen Account)
        "myWay", "planPast", "planHist", "profiles",
        -- Umbau 17: Route und Profile pro Charakter einmal auf das Neue uebernehmen
        "charSetVer",
        -- 17.4 Mein Weg Figur: Ausruestung alle 5 Level und bis wo die Figur schon gelaufen ist
        "wegGear", "wegSeen", "naviDest",
        -- 20.3l (Na J1, Log 20.3j): vermutete Flugpunkte und ob die Flugkarte schon gesehen wurde, pro Charakter
        -- (sonst mischt sich die Vermutung vom Tauren L6 mit dem Troll L60)
        "fpVermutet", "fpKarteGesehen",
        -- 18.5: uebersprungene Quests (erst 3 Level spaeter wieder in der Route)
        "skipQ",
        -- 20.1b (P13): grosses Fenster nach der Einrichtung einmal von selbst gezeigt
        "bigShownAuto",
        -- 20.2b (P15): Groesse vom grossen Fenster
        "bigScale" }
      local k = CharKey()
      db.chars = db.chars or {}
      -- 19.33 (Pruefer 04:50 Punkt 4): kennt das Addon diesen Charakter schon (zuletzt gespielt oder gemerkt)?
      -- Fuer den ersten Start (Services.lua FirstStart): bekannte Charaktere werden nicht als neu behandelt
      ns.charSeenBefore = (db.lastChar == k) or (db.chars[k] ~= nil)
      if db.lastChar ~= k then
        if db.lastChar then
          local old = {}
          for _, f in ipairs(CHAR_FIELDS) do old[f] = db[f] end
          db.chars[db.lastChar] = old
        end
        local c = db.chars[k]
        if c or db.lastChar then
          for _, f in ipairs(CHAR_FIELDS) do db[f] = c and c[f] or nil end
        end
        db.chars[k] = nil
        db.lastChar = k
      end
    end
    -- alte Notfall Route (nur "Grinden: Mobs in deiner Naehe", oft aus einer frueheren Version): weg damit,
    -- sonst steht sie nach dem Einloggen da, bis der Plan fertig ist (Tester Log: Orc Krieger Level 2)
    do
      local o = db.opt
      if o and o.steps and #o.steps <= 1 and not (o.prof or o.tour or o.farm or o.repFarm or o.mirror) then
        local a = o.steps[1] and o.steps[1].acts and o.steps[1].acts[1]
        if a and a.k == "G" and not (a.hint or a.farm or a.repFarm) then db.opt = nil end
      end
    end
    db.progress = db.progress or {}
    db.custom = db.custom or {}
    db.learned = db.learned or {}
    db.renames = db.renames or {}
    db.danger = db.danger or {}
    db.via = db.via or {}
    if db.questFirst == nil then db.questFirst = true end
    db.override = db.override or {}
    db.mobDanger = db.mobDanger or {}
    db.stats = db.stats or {}
    db.radius = db.radius or 0.02
    if db.show == nil then db.show = true end
    -- einmalig: gespeicherte Punkt Namen von ae, oe, ue auf echte Umlaute umstellen
    if not db.umlaut1 then
      db.umlaut1 = true
      -- deutsche Wortteile, absichtlich ohne TR (schuetzt deutsche Namen beim Umstellen)
      local PROTECT = { "Quest", "quest", "Feuer", "feuer", "Neue", "neue", "auer", "uell", "Quell", "Lordaeron", "Bael", "Maestr" }
      local function Conv(n)
        if type(n) ~= "string" or not n:find("[aouAOU]e") then return n end
        local t = n
        for i, w in ipairs(PROTECT) do t = t:gsub(w, "\001" .. i .. "\002") end
        t = t:gsub("ae", "ä"):gsub("oe", "ö"):gsub("ue", "ü"):gsub("Ae", "Ä"):gsub("Oe", "Ö"):gsub("Ue", "Ü")
        t = t:gsub("\001(%d+)\002", function(i) return PROTECT[tonumber(i)] end)
        return t
      end
      for _, tbl in ipairs({ "done", "learned", "renames", "override", "defer" }) do
        for _, m in pairs(type(db[tbl]) == "table" and db[tbl] or {}) do
          if type(m) == "table" then
            local moves = {}
            for k, v in pairs(m) do local nk = Conv(k); if nk ~= k then moves[k] = nk end end
            for k, nk in pairs(moves) do if m[nk] == nil then m[nk] = m[k] end; m[k] = nil end
          end
        end
      end
    end
    if ns.SetupRace then ns.SetupRace() end
    BuildPatterns()
    sess.start = GetTime()
    sess.lastXP, sess.lastMax = UnitXP("player"), UnitXPMax("player")

    if WorldMapFrame then
      WorldMapFrame:HookScript("OnShow", Draw)
      WorldMapFrame:HookScript("OnHide", HideAll)
      if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", Draw) end
      -- OpenMap: bei Verschieben, Zoomen und Umschalten neu zeichnen
      if OpenMapAPI and OpenMapAPI.RegisterCallback then
        local owner = {}
        pcall(OpenMapAPI.RegisterCallback, owner, "OpenMap_ViewChanged", function() ns.DrawSoon() end)
        pcall(OpenMapAPI.RegisterCallback, owner, "OpenMap_StitchedChanged", function() Draw() end)
      end
      if WorldMapFrame.ScrollContainer then
        WorldMapFrame.ScrollContainer:HookScript("OnSizeChanged", function() ns.DrawSoon() end)
      end
      -- Zoom: neu zeichnen (Symbole passen ihre Groesse an), hoechstens 10 Mal pro Sekunde plus am Ende
      if WorldMapFrame.OnCanvasScaleChanged then
        local zt, zPend = 0, false
        hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", function()
          local now = GetTime()
          if now - zt >= 0.1 then zt = now; ns.DrawSoon()
          elseif not zPend then
            zPend = true
            C_Timer.After(0.12, function() zPend = false; zt = GetTime(); ns.DrawSoon() end)
          end
        end)
      end
    end

    ns.Ticker(0.5, Tick)
    ns.TickNow = Tick
    ns.Ticker(0.2, FallTick, true)
    ns.Ticker(2, MobScan)
    ns.Ticker(1, PerfTick, true)
    ns.Ticker(1, ActiveTick, true)
    ns.Ticker(15, ns.SpeedTick)
    C_Timer.After(5, ns.SpeedTick)
    SLASH_TAURENROUTE1 = "/tr"
    SLASH_TAURENROUTE2 = "/taurenroute"
    SLASH_TAURENROUTE3 = "/fw"
    SLASH_TAURENROUTE4 = "/wegweiser"
    SLASH_TAURENROUTE5 = "/klg" -- 20.3z4 (S 18:59): /klg ist der Befehl, /fw und die alten nur noch stille Aliase
    SlashCmdList.TAURENROUTE = Slash
    ns.db = db
    -- gespeicherte Einstellungen auf das Neue uebernehmen (Tempo 3 Stufen, 2 Modi, Mini Fenster klein/gross)
    if ns.MigrateSettings then pcall(ns.MigrateSettings, db) end
    db.optMode = true -- es gibt nur noch die optimierte Route
    -- Plan geht immer bis zum Maximallevel, die Route rechnet Abschnitt fuer Abschnitt
    db.planTarget = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    -- Mini HUD und erweiterte Leiste sind Standard (einmalig auch fuer alte Daten)
    if not db.hudDefault2 then db.hudDefault2 = true; db.hud = true; db.hudExt = true end
    -- neues Mini Fenster: Menue startet zu
    if not db.hudDefault3 then db.hudDefault3 = true; db.hudExt = false end
    -- 1.1 (P52, K 13:30): Pause VOR dem Aufbau der Fenster zuruecksetzen. Vorher danach, dann blieben Pfeil und
    -- Minimap Weg aus dem Aufbau mit Pause versteckt (kein Weg auf der Minimap, keine PFEIL Zeilen im Log)
    -- 1.1 (P49, K 12:55, S Log 12:45: neuer Tauren startete mit "Pause ja"): Pause gilt nur bis zum Ausloggen, beim Einloggen
    -- ist sie immer aus (vorher blieb sie aus einer alten Sitzung haengen, auch "Pfeil und Mini Fenster aus")
    if db.paused or db.quiet then
      db.paused, db.quiet = false, nil
      if ns.TestLog then C_Timer.After(5, function() ns.TestLog("PAUSE", "aus beim Einloggen (war aus alter Sitzung an)") end) end
    end
    if ns.InitUI then ns.InitUI() end
    local rp = ns.racePlan
    Print((TR"geladen, Startroute für %s ab %s"):format(rp and rp.name or "Horde", ZoneName(ns.zoneOrder[1])))
    C_Timer.After(3, function() if db.show then Announce(PlayerMap()) end end)
    return
  end
  if not db then return end

  if event == "CHAT_MSG_SYSTEM" or event == "UI_INFO_MESSAGE" then
    if not exploredPattern then return end
    for i = 1, select("#", ...) do
      local m = select(i, ...)
      if type(m) == "string" then
        local name, xp = MatchOrdered(m, exploredPattern, exploredOrder)
        if name and tonumber(xp) then OnExplored(name, tonumber(xp)); break end
      end
    end
  elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
    local m = ...
    if type(m) == "string" then
      local _, xp
      -- nur echte Kills (mit Mob Namen), XP ohne Namen kommt von Quests, Entdecken usw.
      _, xp = MatchOrdered(m, killPattern, killOrder)
      if tonumber(xp) then
        OnKillXP(tonumber(xp))
        if ns.BagKill then ns.BagKill() end
      end
    end
  elseif event == "PLAYER_DEAD" then
    OnDeath()
    if ns.Count then ns.Count("death") end
    -- Tode pro Zone merken: dort werden gefaehrliche Quests spaeter eingeplant
    local m = ns.PlayerMap and ns.PlayerMap()
    if m and db and db.stats then
      db.stats.deathZones = db.stats.deathZones or {}
      db.stats.deathZones[m] = (db.stats.deathZones[m] or 0) + 1
    end
  elseif event == "QUEST_TURNED_IN" then
    local _, qxp, money = ...
    if ns.Count then ns.Count("quest", Plain(qxp) or 0, Plain(money) or 0) end
  elseif event == "PLAYER_XP_UPDATE" then
    local xp, max = UnitXP("player"), UnitXPMax("player")
    if sess.lastXP then
      local d = xp - sess.lastXP
      if d < 0 then d = (sess.lastMax or max) - sess.lastXP + xp end -- Level Up
      if d > 0 then sess.xp = sess.xp + d; PerfXP(d); ActiveXP(d) end
    end
    sess.lastXP, sess.lastMax = xp, max
  elseif event == "PLAYER_LEVEL_UP" then
    C_Timer.After(1, ns.SpeedTick)
    -- 20.4a4 Verlauf (K 17:46): wann ein Level fertig war und wann das neue begann (fuer Meine Route, Zeitstempel je Level)
    local newL = tonumber((...))
    if newL and newL > 1 then
      local now = time and time() or 0
      LvlStat(newL - 1).upAt = now
      local ln = LvlStat(newL)
      ln.at = ln.at or now
    end
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    if db.show then Announce(PlayerMap()) end
    C_Timer.After(2, function() ns.CheckLevel() end)
  end
  if ns.RefreshUI then ns.RefreshUI() end
end)

-- Pause: alles anhalten (Menue im Mini Fenster, Reiter im Charakterfenster, /klg pause)
function ns.SetPaused(on)
  local db = ns.db
  if not db then return end
  db.paused = on and true or false
  -- 19.32 (Saschas Runde 2 Punkt 15): Weitermachen holt auch das Mini Fenster zurueck, wenn es mit "Pfeil und Mini
  -- Fenster aus" weg war
  if not db.paused and db.quiet then
    db.quiet = nil
    local h = _G.TaurenRouteHUD
    if h and db.hud ~= false then h:Show(); if ns.RefreshHud then pcall(ns.RefreshHud) end end
  end
  local arrow = _G.TaurenRouteArrow
  if arrow then arrow:SetShown(not db.paused and db.arrow ~= false) end
  if ns.Draw then ns.Draw() end
  if ns.MiniRouteRefresh then ns.MiniRouteRefresh() end
  if ns.RefreshItemBar then ns.RefreshItemBar() end
  if ns.RefreshHud then ns.RefreshHud() end
  if ns.TestLog then ns.TestLog("PAUSE", db.paused and "an" or "aus") end
  if ns.PauseLabels then ns.PauseLabels() end
  if ns.RefreshBig and _G.TaurenRouteBig and _G.TaurenRouteBig:IsShown() then ns.RefreshBig() end
  ns.Print(db.paused and TR"Pausiert: nichts wird mehr gerechnet. Weiter mit Weitermachen im Mini Fenster Menü oder /klg pause."
    or TR"Pause aus, es geht weiter.")
end
-- 19.32 (Saschas Runde 2 Punkt 15): "Pfeil und Mini Fenster aus" im Charakterfenster: wie Pause (nichts rechnet im
-- Hintergrund, gut fuer schwache PCs), dazu ist auch das Mini Fenster weg. Einstellungen bleiben. Nochmal klicken oder
-- Weitermachen irgendwo holt beides zurueck
function ns.SetQuiet(on)
  local db = ns.db
  if not db then return end
  if on then
    db.quiet = true
    if not db.paused then ns.SetPaused(true) end
    local h = _G.TaurenRouteHUD
    if h then h:Hide() end
    if ns.TestLog then ns.TestLog("PAUSE", "Pfeil und Mini Fenster aus") end
  else
    ns.SetPaused(false)
  end
  if ns.PauseLabels then ns.PauseLabels() end
end
