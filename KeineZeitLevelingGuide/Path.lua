local ADDON, ns = ...
local TR = ns.TR

-- Laufwege um Berge herum.
-- 19.0: Gelaende und Wegnetz kommen aus der Werkzeug Karte (Daten Addon, Karte.lua). Obendrauf lernt Keine Zeit Leveling Guide:
--  1. jeder Ort, an dem du schon zu Fuss oder beritten warst (mit Richtung, Schwimmen und Spruengen): dort nie Berg
--  2. geteilte Wege anderer Spieler (Ways.lua, Sync.lua): machen Berge unsicher oder frei
--  3. wo NPCs stehen und laufen (Mob Ebene, schwach)
--  4. Uebergaenge zwischen Zonen, durch die du schon gelaufen bist
-- Mit Karte Daten geht der Weg ueber das Netz der Karte (Karte.lua). Ohne (Daten Addon fehlt) wie frueher ueber
-- bekannte Felder auf dem Raster; ist die Luftlinie frei, bleibt es die Luftlinie. Gefahrenstellen (Alt+Klick) sind gesperrt.

local CELL = 0.0125            -- 80 x 80 Felder pro Zone
local N = 80
local EMPTY = {}
-- Kosten pro Feld, von gut nach schlecht:
-- selbst gelaufen und extrem zuverlaessig geteilt, sehr zuverlaessig, wohl frei, Mob Ebene, unbekannt, unsicher, Berg
local COST_WALKED, COST_NEAR, COST_UNKNOWN, COST_BLOCK = 1, 1.3, 2.5, 60
local COST_ROAD = 0.85 -- Wege der Karte: lieber dort lang, aber kein Muss
local COST_ENEMY = 6    -- Posten der anderen Fraktion: nur wenn es nicht anders geht
-- Zonen ohne Karte Daten: unbekannt kann ein Berg sein, darum ist bekannter Boden viel billiger
local COST_X, COST_HI, COST_SH, COST_UNSURE = 1.0, 1.1, 1.3, 3.5
-- Zonen mit Karte Daten: unbekannte Felder sind meist begehbar (die Berge sind ja eingezeichnet)
local COST_UNKNOWN_P = 1.25
local COST_X_P, COST_HI_P, COST_SH_P, COST_MOB_P, COST_UNSURE_P = 1.0, 1.05, 1.12, 1.2, 2.2
local COST_CLIFF = 6   -- viele Spieler sind hier heruntergesprungen: hoch fast gesperrt
local SWIM, SWIM_MOUNT = 1.5, 2.4 -- schwimmen ist langsamer (beritten erst recht, im Wasser muss man absteigen)
local MAX_NODES = 3000 -- mehr Felder durchsuchen ruckelt (A* laeuft im Pfeil Takt)

local function Plain(v) if ns.Plain then return ns.Plain(v) end return v end
local function Key(cx, cy) return cy * 100 + cx end
local function Cell(x, y)
  local cx, cy = math.floor(x / CELL), math.floor(y / CELL)
  if cx < 0 then cx = 0 elseif cx >= N then cx = N - 1 end
  if cy < 0 then cy = 0 elseif cy >= N then cy = N - 1 end
  return cx, cy
end
local function W() return ns.Ways end
local function HasBit(v, b) return math.floor(v / 2 ^ b) % 2 == 1 end
local function SetBit(v, b) if math.floor(v / 2 ^ b) % 2 == 0 then return v + 2 ^ b end return v end
-- eigene Spur: Bits 0..7 Richtungen, 8 geschwommen, 9 trocken
local function OwnWater(m) return m and HasBit(m, 8) and not HasBit(m, 9) end

-- Felder aus den festen Daten (FesteDaten.lua): je 2 Zeichen ein Feld
local decIdx
local function Decode(str, set)
  set = set or {}
  local A = ns.PAINT_ABC
  if not (str and A) then return set end
  if not decIdx then decIdx = {}; for i = 1, #A do decIdx[A:sub(i, i)] = i - 1 end end
  for p = 1, #str - 1, 2 do
    local a, b = decIdx[str:sub(p, p)], decIdx[str:sub(p + 1, p + 1)]
    if a and b then set[a * 90 + b] = true end
  end
  return set
end
ns.PaintDecode = Decode
-- Forever: die Quest Punkte und Posten sind auf den Era Karten. Auf den neu vermessenen Karten (Mulgore,
-- Oestliche Pestlaender, Rotkammgebirge, Sturmwind) jedes Feld ueber seine Mitte auf das neue Raster legen.
-- (Die Werkzeug Karte ist schon im Raster des eigenen Clients, die wird nicht umgerechnet.)
local function ForeverCells(ui, set)
  local t = ns.FOREVER and ns.ERA2FOR and ns.ERA2FOR[ui]
  if not (t and set and ns.EraXY) then return set end
  local out = {}
  for k, v in pairs(set) do
    local cx, cy = k % 100, math.floor(k / 100)
    local x, y = ns.EraXY(ui, (cx + 0.5) * CELL, (cy + 0.5) * CELL)
    if x and y then
      local nx, ny = Cell(x, y)
      out[Key(nx, ny)] = v
    end
  end
  return out
end
ns.PaintForever = ForeverCells
local function DecodeZ(ui, str) return ForeverCells(ui, Decode(str)) end
local qpCache, postCache = {}, {}
-- Felder mit Quest Punkten (Geber, Abgabe, Ziele): dort nie ein Berg
local function QuestCells(ui)
  local c = qpCache[ui]
  if not c then c = DecodeZ(ui, ns.PAINT_QP and ns.PAINT_QP[ui]); qpCache[ui] = c end
  return c
end
-- Posten der anderen Fraktion in dieser Zone
local function EnemyPosts(ui)
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local other = (fac == "Alliance") and "H" or "A"
  local key = other .. ui
  local c = postCache[key]
  if not c then c = DecodeZ(ui, ns.PAINT_POST and ns.PAINT_POST[other] and ns.PAINT_POST[other][ui]); postCache[key] = c end
  return c
end
ns.EnemyPostCells = EnemyPosts
-- 19.11: liegt der Punkt (Zonen Koordinaten) in einem Posten der anderen Fraktion? Fuer den Navi Hinweis.
function ns.EnemyPostAt(ui, x, y)
  if not (ui and x and y) or x ~= x or y ~= y then return false end
  return EnemyPosts(ui)[Key(Cell(x, y))] and true or false
end
-- Nachbarfelder; diagonal nur, wenn nicht beide Ecken gesperrt sind (sonst rutscht man durch gemalte Linien)
local function Neighbors(k, isBlocked, fn)
  local cx, cy = k % 100, math.floor(k / 100)
  for dx = -1, 1 do
    for dy = -1, 1 do
      if dx ~= 0 or dy ~= 0 then
        local nx, ny = cx + dx, cy + dy
        if nx >= 0 and nx < N and ny >= 0 and ny < N then
          if not (dx ~= 0 and dy ~= 0 and isBlocked(Key(nx, cy)) and isBlocked(Key(cx, ny))) then
            fn(Key(nx, ny), dx, dy)
          end
        end
      end
    end
  end
end

-- Berge pruefen (Karte.lua beim Laden einer Zone): auf Quest Punkten nie ein Berg, und jeder Quest Punkt muss vom
-- Hauptgebiet der Zone aus erreichbar sein (sonst den kuerzesten Durchgang durch die Berge oeffnen). Gebaeude sind in
-- der Karte nur Kaesten, Quest Geber darin waeren sonst eingemauert. Gibt die Zahl entfernter Felder zurueck.
local NB8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local function CleanZone(ui, B)
  if not (B and next(B)) then return 0 end
  local qp = QuestCells(ui)
  if not next(qp) then return 0 end
  local n = 0
  for k in pairs(qp) do if B[k] then B[k] = nil; n = n + 1 end end
  -- zusammenhaengende Gebiete ohne Berge (diagonal nicht zwischen zwei Bergen durch). 19.0 schneller: Schleifen ohne
  -- Funktionsaufrufe pro Feld und eine einzige 0-1 Suche fuer alle eingeschlossenen Quest Punkte
  local comp, sizes, cid = {}, {}, 0
  local q = {}
  for cy = 0, N - 1 do
    for cx = 0, N - 1 do
      local k = cy * 100 + cx
      if not B[k] and not comp[k] then
        cid = cid + 1
        q[1] = k
        local h, t = 1, 1
        comp[k] = cid
        while h <= t do
          local c = q[h]; h = h + 1
          local x, y = c % 100, (c - c % 100) / 100
          for i = 1, 8 do
            local d = NB8[i]
            local nx, ny = x + d[1], y + d[2]
            if nx >= 0 and nx < N and ny >= 0 and ny < N then
              local nk = ny * 100 + nx
              if not B[nk] and not comp[nk] and not (i > 4 and B[y * 100 + nx] and B[ny * 100 + x]) then
                comp[nk] = cid; t = t + 1; q[t] = nk
              end
            end
          end
        end
        sizes[cid] = t
      end
    end
  end
  local qcount = {}
  for k in pairs(qp) do local c = comp[k]; if c then qcount[c] = (qcount[c] or 0) + 1 end end
  local main, bq, bs
  for c, sz in pairs(sizes) do
    local qc = qcount[c] or 0
    if not main or qc > bq or (qc == bq and sz > bs) then main, bq, bs = c, qc, sz end
  end
  local out = {}
  for k in pairs(qp) do if comp[k] ~= main then out[#out + 1] = k end end
  if #out == 0 then return n end
  -- 0-1 Suche vom Hauptgebiet aus: ein Berg Feld kostet 1, sonst 0
  local dist, prev = {}, {}
  local dq, head, tail = {}, 0, -1
  for k, c in pairs(comp) do if c == main then dist[k] = 0; tail = tail + 1; dq[tail] = k end end
  while head <= tail do
    local c = dq[head]; dq[head] = nil; head = head + 1
    local dc = dist[c]
    local x, y = c % 100, (c - c % 100) / 100
    for i = 1, 8 do
      local d = NB8[i]
      local nx, ny = x + d[1], y + d[2]
      if nx >= 0 and nx < N and ny >= 0 and ny < N then
        local nk = ny * 100 + nx
        local w = B[nk] and 1 or 0
        local nd = dc + w
        local od = dist[nk]
        if not od or nd < od then
          dist[nk], prev[nk] = nd, c
          if w == 0 then head = head - 1; dq[head] = nk else tail = tail + 1; dq[tail] = nk end
        end
      end
    end
  end
  -- naechste zuerst; schon angeschlossene Gebiete auslassen
  table.sort(out, function(a, b) return (dist[a] or 1e9) < (dist[b] or 1e9) end)
  local joined = { [main] = true }
  for _, target in ipairs(out) do
    local old = comp[target]
    if not (old and joined[old]) and dist[target] then
      local k = target
      while k do
        if B[k] then B[k] = nil; n = n + 1 end
        k = prev[k]
      end
      if old then joined[old] = true end
    end
  end
  return n
end
ns.CleanBlocks = CleanZone

-- Strecke in Yards innerhalb einer Zone um Berge und Wasser herum (fuer die Routen Berechnung), 19.0 ueber das Netz der
-- Werkzeug Karte (Tabelle t, Karte.lua). nil: keine Daten oder die gerade Linie ist frei (dann rechnet der Optimierer wie immer).
local zoneYards = {}
local function ZoneYards(ui)
  local z = zoneYards[ui]
  if z == nil then
    local w, h
    if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(ui) end
    z = (w and h and w > 0 and h > 0) and { w, h } or false
    zoneYards[ui] = z
  end
  return z or nil
end
ns.ZoneYards = ZoneYards
function ns.GridDist(ui, x1, y1, x2, y2)
  local K = ns.Karte
  if not (K and ns.db) then return nil end
  return K.ZoneDist(ui, x1, y1, x2, y2)
end

------------------------------------------------------------
-- 1. Lernen: wo bist du gelaufen (mit Richtung), wo geschwommen, wo heruntergesprungen, wo die Zone gewechselt
-- Nicht im Flug, auf Schiffen und Zeppelinen, als Geist oder in der Luft.
------------------------------------------------------------
local last
local fallT0, fallLen, fallEnd, fallJump, jumpAt = nil, 0, -10, false, -10
local fallFrom
-- 19.18 (Sascha: "viele springen vom Zeppelin, von unterschiedlichsten Stellen"): Schiff und Zeppelin merken.
-- Zweimal innerhalb von 15 s schneller als die eigenen Beine = Fahrt (ein Sturmangriff ist nur einmal). Die Fahrt endet
-- erst, wenn du wieder auf festem Boden bist: 8 Takte hintereinander passt die Bewegung zum eigenen Tempo (oder du stehst
-- still) und seit 5 s war nichts zu schnell. Wer auf einem Zeppelin auf dem Deck herum rennt, bewegt sich fast nie im
-- eigenen Tempo, die Fahrt bleibt (Sim Zeppelin Test). Waehrend der Fahrt wird nichts gelernt: kein Sprung vom Deck als
-- Klippe, kein Zonenwechsel in der Luft als Uebergang. Am Steg und am Turm (ns.NearDock) auch nicht.
local fastAt, boatT, onBoat, calm = -1e9, -1e9, false, 0
local DOCK_R = 45
ns.WalkOnBoat = function()
  local now = GetTime and GetTime() or 0
  return onBoat or now - fastAt < 3
end
do
  -- Sprung oder Sturz genau messen (der Lern Takt ist nur einmal pro Sekunde)
  local function Sample()
    local f = IsFalling and ns.Api.U(IsFalling)
    if f and not fallT0 then fallT0 = GetTime()
    elseif not f and fallT0 then
      fallLen, fallEnd = GetTime() - fallT0, GetTime()
      fallJump = (fallT0 - jumpAt) < 0.5
      fallT0 = nil
    end
  end
  ns.WalkFallSample = Sample
  ns.WalkJumped = function() jumpAt = GetTime() end
  local ff = CreateFrame("Frame")
  local acc = 0
  ff:SetScript("OnUpdate", function(_, el)
    acc = acc + (el or 0)
    if acc < 0.1 then return end
    acc = 0
    Sample()
  end)
  if hooksecurefunc and JumpOrAscendStart then pcall(hooksecurefunc, "JumpOrAscendStart", function() ns.WalkJumped() end) end
end
-- Felder von a nach b (ohne a, mit b) mit Richtung je Schritt
local function StepCells(a, b)
  local ax, ay = a % 100, math.floor(a / 100)
  local bx, by = b % 100, math.floor(b / 100)
  local n = math.max(math.abs(bx - ax), math.abs(by - ay))
  local out = {}
  local px, py = ax, ay
  for s = 1, n do
    local f = s / n
    local nx, ny = math.floor(ax + (bx - ax) * f + 0.5), math.floor(ay + (by - ay) * f + 0.5)
    if nx ~= px or ny ~= py then
      out[#out + 1] = { Key(nx, ny), W().Dir(nx - px, ny - py) }
      px, py = nx, ny
    end
  end
  return out
end
local function Break() last = nil; fallFrom = nil; if W() then W().EndSeg() end end
ns.WalkBreak = Break
-- 19.18: einmal alte Daten bereinigen: gelernte Spruenge (Klippen) und Sturz Gefahren am Steg und am Zeppelin Turm
-- stammen vom Deck oder vom Turm, nicht von einer Klippe
local function CleanDockFalls(db)
  local nd, ng = 0, 0
  for map, dr in pairs(db.walkDrop or EMPTY) do
    if type(dr) == "table" then
      for k in pairs(dr) do
        if type(k) == "number" and ns.NearDock(map, ((k % 100) + 0.5) * CELL, (math.floor(k / 100) + 0.5) * CELL, 60) then dr[k] = nil; nd = nd + 1 end
      end
    end
  end
  local FALL = { [TR"tiefer Sturz"] = true, [TR"viel Fallschaden"] = true, [TR"Tod durch Sturz"] = true }
  for map, list in pairs(db.danger or EMPTY) do
    if type(list) == "table" then
      for i = #list, 1, -1 do
        local d = list[i]
        if type(d) == "table" and FALL[d[4]] and ns.NearDock(map, d[1], d[2], 70) then table.remove(list, i); ng = ng + 1 end
      end
    end
  end
  if (nd > 0 or ng > 0) and ns.TestLog then ns.TestLog("LERNEN", ("Steg und Zeppelin Turm bereinigt: %d Sprung Felder, %d Sturz Gefahren"):format(nd, ng)) end
end
local function Tick()
  local db = ns.db
  if not db then return end
  if not db.dockFallClean and ns.NearDock then db.dockFallClean = 1918; pcall(CleanDockFalls, db) end
  if (UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")) or (IsFlying and ns.Api.U(IsFlying)) or (UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player")) then Break(); return end
  local map = ns.PlayerMap and ns.PlayerMap()
  local info = map and C_Map.GetMapInfo(map)
  if not (info and info.mapType == Enum.UIMapType.Zone) then Break(); return end
  local pos = C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  x, y = Plain(x), Plain(y)
  if not (x and y) or x <= 0 or y <= 0 then return end
  local now = GetTime()
  local sp = Plain(ns.Api.GetUnitSpeed and ns.Api.GetUnitSpeed("player")) or 7
  local k = Key(Cell(x, y))
  -- Schiff, Zeppelin, Aufzug, Teleport, Sturmangriff: schneller als die eigenen Beine, nichts lernen
  if last and last.map == map then
    local zy = ZoneYards(map)
    if zy then
      local dt = math.max(0.2, now - last.t)
      local moved = math.sqrt(((x - last.x) * zy[1]) ^ 2 + ((y - last.y) * zy[2]) ^ 2)
      local vmax = math.max(sp, last.sp or 0)
      -- 19.19: schon ab einem Viertel schneller (vorher 1.3 x + 5 yd): auf einem langsamen Zeppelin plus eigenes Rennen
      if (vmax < 0.3 and moved > 3) or moved > vmax * dt * 1.25 + 2.5 then
        if now - fastAt < 15 then onBoat = true end
        fastAt, boatT, calm = now, now, 0
        Break()
        last = { map = map, x = x, y = y, t = now, sp = sp }
        return
      end
      if onBoat then
        local own = sp * dt
        local ok = (sp >= 1 and math.abs(moved - own) <= math.max(2, own * 0.3)) or (sp < 0.3 and moved < 1)
        if ok then calm = calm + 1 else calm = 0 end
        if calm >= 8 and now - boatT >= 5 then onBoat = false end
      end
    end
  end
  -- 19.18: auf Schiff oder Zeppelin (bis du wieder ruhig auf festem Boden bist), oder am Steg / Turm: nichts lernen
  if onBoat or (ns.NearDock and ns.NearDock(map, x, y, DOCK_R)) then
    Break()
    last = { map = map, x = x, y = y, t = now, sp = sp }
    return
  end
  -- in der Luft: nichts lernen, aber merken, wo der Sprung anfing
  if IsFalling and ns.Api.U(IsFalling) then
    if last and last.map == map and last.k and not fallFrom then fallFrom = last.k end
    return
  end
  local swim = (IsSwimming and ns.Api.U(IsSwimming)) and 1 or 0
  db.walk = db.walk or {}
  db.walk[map] = db.walk[map] or {}
  local w = db.walk[map]
  if (w[k] or 0) < 250 then w[k] = (w[k] or 0) + 1 end
  db.walkDir = db.walkDir or {}
  db.walkDir[map] = db.walkDir[map] or {}
  local wd = db.walkDir[map]
  wd[k] = SetBit(wd[k] or 0, swim == 1 and 8 or 9)
  -- du bist hier gelaufen: ein Berg der Karte an dieser Stelle war falsch (gelaufene Wege gehen vor)
  local KF = ns.Karte and ns.Karte.FelderIfLoaded(map)
  local bz = KF and KF.block
  if bz and bz[k] then bz[k] = nil; ns.blockRev = (ns.blockRev or 0) + 1 end
  local from = (last and last.map == map) and (fallFrom or last.k) or nil
  -- heruntergesprungen (lange in der Luft): dort geht es zurueck nicht hoch
  local isDrop = from and from ~= k and fallEnd > (last.t or 0) and (fallLen >= 1.0 or (fallLen >= 0.6 and not fallJump))
  if isDrop then
    local d = W().DirOf((k % 100) - (from % 100), math.floor(k / 100) - math.floor(from / 100))
    if d then
      local up = (d + 4) % 8
      db.walkDrop = db.walkDrop or {}
      db.walkDrop[map] = db.walkDrop[map] or {}
      local dr = db.walkDrop[map]
      dr[from] = SetBit(dr[from] or 0, up)
      for _, sc in ipairs(StepCells(from, k)) do
        if sc[1] ~= k then dr[sc[1]] = SetBit(dr[sc[1]] or 0, up) end
      end
    end
  end
  -- Schritt in ein neues Feld: Richtung merken und fuer das Teilen aufschreiben
  if from and from ~= k then
    local cells = StepCells(from, k)
    if #cells <= 3 then
      for _, sc in ipairs(cells) do
        if sc[2] then
          wd[sc[1]] = SetBit(wd[sc[1]] or 0, sc[2])
          W().TrailStep(map, sc[1], sc[2], swim, isDrop)
        end
      end
    else
      W().TrailStart(map, k, swim)
    end
  elseif not from then
    W().TrailStart(map, k, swim)
  end
  fallFrom = nil
  -- Zonenwechsel zu Fuss: Uebergang merken
  if last and last.map ~= map and now - last.t < 3 and ns.WorldDist then
    local d = ns.WorldDist({ last.map, last.x, last.y }, { map, x, y })
    if d and d < 80 then
      db.cross = db.cross or {}
      local function Add(a, b, px, py)
        db.cross[a] = db.cross[a] or {}
        db.cross[a][b] = db.cross[a][b] or {}
        for _, c in ipairs(db.cross[a][b]) do
          if math.abs(c[1] - px) < 0.03 and math.abs(c[2] - py) < 0.03 then return end
        end
        table.insert(db.cross[a][b], { px, py })
        db.crossRev = (db.crossRev or 0) + 1
      end
      Add(last.map, map, last.x, last.y)
      Add(map, last.map, x, y)
    end
  end
  last = { map = map, x = x, y = y, t = now, k = k, sp = sp }
end
ns.WalkTick = Tick
if C_Timer and C_Timer.NewTicker then ns.Ticker(1, function() pcall(Tick) end) end

------------------------------------------------------------
-- Kosten eines Feldes (k) beim Betreten in Richtung d (0..7, nil = egal)
------------------------------------------------------------
local function CostFn(ui)
  local db = ns.db
  local walked = db and db.walk and db.walk[ui] or EMPTY
  local wdir = db and db.walkDir and db.walkDir[ui] or EMPTY
  local wdrop = db and db.walkDrop and db.walkDrop[ui] or EMPTY
  local KF = ns.Felder and ns.Felder(ui) or EMPTY
  local B = KF.block or EMPTY
  local road = KF.road or EMPTY
  local wat = KF.water or EMPTY
  local cliff = KF.cliff or EMPTY
  local dangers = ns.Dangers and ns.Dangers(ui) or {}
  local dz = {}
  for _, d in ipairs(dangers) do
    if not d.mob or (d[3] or 0) <= 0.05 then
      local r = d[3] or 0.025
      local c0x, c0y = Cell(d[1], d[2])
      local rc = math.ceil(r / CELL)
      for dx = -rc, rc do
        for dy = -rc, rc do
          local nx, ny = c0x + dx, c0y + dy
          if nx >= 0 and nx < N and ny >= 0 and ny < N then
            local px, py = (nx + 0.5) * CELL, (ny + 0.5) * CELL
            if (px - d[1]) ^ 2 + (py - d[2]) ^ 2 <= r * r then dz[Key(nx, ny)] = true end
          end
        end
      end
    end
  end
  local painted = next(B) or next(road) or next(wat) or next(cliff)
  local Wy = W()
  local L = Wy and Wy.Layer(ui)
  local Lc, Ldm, Lw = L and L.c or EMPTY, L and L.dm or EMPTY, L and L.w or EMPTY
  local Lup, Lupl = L and L.up or EMPTY, L and L.upl or EMPTY
  local mob = (painted and Wy) and Wy.MobCells(ui) or EMPTY
  local unknown = painted and COST_UNKNOWN_P or COST_UNKNOWN
  local unsure = painted and COST_UNSURE_P or COST_UNSURE
  local cX = painted and COST_X_P or COST_X
  local cHi = painted and COST_HI_P or COST_HI
  local cSh = painted and COST_SH_P or COST_SH
  local swimMul = (IsMounted and ns.Api.U(IsMounted)) and SWIM_MOUNT or SWIM
  local posts = EnemyPosts(ui)
  local MaskHas = Wy and Wy.MaskHas or function() return true end
  -- Klippe der Karte: Feld k geht in Richtung down nach unten. Hoch (Gegenrichtung, auch schraeg) ist gesperrt,
  -- beim Betreten und beim Verlassen des Feldes (sonst schluepft der Weg am Ende der Linie vorbei)
  local function Up(down, d) local x = (d - (down + 4)) % 8; return x == 0 or x == 1 or x == 7 end
  return function(k, d, from)
    if dz[k] then return COST_BLOCK end
    if d then
      local c1 = cliff[k]
      if c1 and Up(c1, d) then return COST_BLOCK end
      local c2 = from and cliff[from]
      if c2 and Up(c2, d) then return COST_BLOCK end
    end
    local w = wat[k]
    if w == 2 then return COST_BLOCK end
    local c = Lc[k]
    local base
    if B[k] then
      -- Berg: nur geteilte Wege machen ihn unsicher oder frei
      if c == 4 then base = unsure
      elseif c == 5 then base = cSh
      else return COST_BLOCK end
    elseif posts[k] then base = COST_ENEMY
    elseif road[k] then base = COST_ROAD
    else
      local drop = d and wdrop[k]
      if drop and MaskHas(drop, d) then
        -- hier bist du selbst heruntergesprungen: in diese Richtung geht es wohl nicht hoch
        base = unsure
      else
        if walked[k] then base = COST_WALKED
        elseif c == 1 then base = cX
        elseif c == 2 then base = cHi
        elseif c == 3 then base = cSh
        elseif mob[k] then base = COST_MOB_P
        else base = unknown end
        local own = wdir[k]
        local ownUp = d and own and own % 256 > 0 and MaskHas(own % 256, d)
        -- Klippe: viele sind hier nur in die Gegenrichtung gelaufen (herunter), keiner in diese
        local m = d and Ldm[k]
        if m and not MaskHas(m, d) and MaskHas(m, (d + 4) % 8) and base < unsure and not ownUp then base = unsure end
        -- geteilte Spruenge: ab 3 Spielern unsicher, ab 8 Klippe (nur dein eigenes Hochlaufen hebt das auf)
        local up = d and Lup[k]
        if up and MaskHas(up, d) and not ownUp then
          local c2 = (Lupl[k] == 2) and COST_CLIFF or unsure
          if base < c2 then base = c2 end
        end
      end
    end
    if w == 1 or Lw[k] or OwnWater(wdir[k]) then base = base * swimMul end
    return base
  end
end
ns.PathCostFn = CostFn

-- Luftlinie ueber bekannte Felder?
local function LineOk(cost, x1, y1, x2, y2, limit)
  local d = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
  local steps = math.max(1, math.ceil(d / (CELL * 0.5)))
  local dir = W() and W().DirOf(x2 - x1, y2 - y1)
  local pk
  for s = 0, steps do
    local t = s / steps
    local k = Key(Cell(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t))
    if cost(k, dir, (pk ~= k) and pk or nil) > limit then return false end
    pk = k
  end
  return true
end

------------------------------------------------------------
-- A* auf dem Raster
------------------------------------------------------------
local DIRS = {}
local function DirOf(dx, dy)
  local i = (dy + 1) * 3 + dx + 1
  local d = DIRS[i]
  if d == nil then d = W() and W().Dir(dx, dy) or false; DIRS[i] = d end
  return d or nil
end
local function AStar(cost, sx, sy, tx, ty)
  local start, goal = Key(sx, sy), Key(tx, ty)
  local g, came, open = { [start] = 0 }, {}, {}
  local heap = { { 0, start } }
  local function Push(f, k)
    heap[#heap + 1] = { f, k }
    local i = #heap
    while i > 1 do
      local p = math.floor(i / 2)
      if heap[p][1] <= heap[i][1] then break end
      heap[p], heap[i] = heap[i], heap[p]
      i = p
    end
  end
  local function Pop()
    local top = heap[1]
    local lastE = heap[#heap]
    heap[#heap] = nil
    if #heap > 0 then
      heap[1] = lastE
      local i = 1
      while true do
        local l, r, m = i * 2, i * 2 + 1, i
        if heap[l] and heap[l][1] < heap[m][1] then m = l end
        if heap[r] and heap[r][1] < heap[m][1] then m = r end
        if m == i then break end
        heap[m], heap[i] = heap[i], heap[m]
        i = m
      end
    end
    return top
  end
  local seen = 0
  while #heap > 0 do
    local cur = Pop()
    local k = cur[2]
    if k == goal then break end
    if not open[k] then
      open[k] = true
      seen = seen + 1
      if seen > MAX_NODES then return nil end
      local cx, cy = k % 100, math.floor(k / 100)
      for dx = -1, 1 do
        for dy = -1, 1 do
          if dx ~= 0 or dy ~= 0 then
            local nx, ny = cx + dx, cy + dy
            -- diagonal nicht zwischen zwei gesperrten Ecken durch
            local corner = dx ~= 0 and dy ~= 0 and nx >= 0 and nx < N and ny >= 0 and ny < N
              and cost(Key(nx, cy)) >= COST_BLOCK and cost(Key(cx, ny)) >= COST_BLOCK
            if not corner and nx >= 0 and nx < N and ny >= 0 and ny < N then
              local nk = Key(nx, ny)
              local step = ((dx ~= 0 and dy ~= 0) and 1.4142 or 1) * cost(nk, DirOf(dx, dy), k)
              local ng = g[k] + step
              if not g[nk] or ng < g[nk] then
                g[nk] = ng
                came[nk] = k
                local h = math.sqrt((nx - tx) ^ 2 + (ny - ty) ^ 2)
                Push(ng + h, nk)
              end
            end
          end
        end
      end
    end
  end
  if not came[goal] and start ~= goal then return nil end
  local path, k = {}, goal
  while k and k ~= start do table.insert(path, 1, k); k = came[k] end
  return path
end

------------------------------------------------------------
-- Weg in einer Zone: Liste von Punkten (ohne Start, mit Ziel) oder nil = Luftlinie
------------------------------------------------------------
local cache, cacheN = {}, 0
-- Kosten einer geraden Strecke (Laenge mal Feldkosten)
local function SegCost(cost, x1, y1, x2, y2)
  local d = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
  local steps = math.max(1, math.ceil(d / (CELL * 0.5)))
  local dir = W() and W().DirOf(x2 - x1, y2 - y1)
  local sum = 0
  local pk = Key(Cell(x1, y1))
  for s = 1, steps do
    local t = (s - 0.5) / steps
    local k = Key(Cell(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t))
    local c = cost(k, dir, (pk ~= k) and pk or nil)
    if c >= COST_BLOCK then return math.huge end
    sum = sum + c
    pk = k
  end
  return sum * d / steps
end

function ns.WalkPath(ui, fx, fy, tx, ty)
  local db = ns.db
  -- 20.2 (Log 13:41, 3 Fehler Path.lua:33 in Thunder Bluff): auch y pruefen, ein Ziel ohne y kam bis zum Raster durch
  if not (db and ui and fx and fy and tx and ty) or db.walkPaths == false then return nil end
  -- 19.0: mit Karte Daten ueber das Netz (Zwischenpunkte sind begehbar), sonst wie frueher auf dem Raster
  local K = ns.Karte
  if K and K.HasZone(ui) then
    local ok, p, why = pcall(K.PathPts, ui, fx, fy, tx, ty)
    if ok then
      if p and #p > 0 then return p end
      if why == "free" then return nil end
    end
  end
  local sx, sy = Cell(fx, fy)
  local gx, gy = Cell(tx, ty)
  if math.abs(sx - gx) <= 2 and math.abs(sy - gy) <= 2 then return nil end
  local dangers = ns.Dangers and ns.Dangers(ui) or {}
  local stamp = W() and W().Layer(ui)
  local ck = ui .. ":" .. Key(sx, sy) .. ":" .. Key(gx, gy) .. ":" .. #dangers .. ":" .. (stamp and stamp.t or 0) .. ":" .. (ns.blockRev or 0)
    .. ":" .. ((IsMounted and ns.Api.U(IsMounted)) and 1 or 0)
  local c = cache[ck]
  if c and GetTime() - c.t < 20 then return c.path end
  local cost = CostFn(ui)
  local result
  local direct = SegCost(cost, fx, fy, tx, ty)
  if not LineOk(cost, fx, fy, tx, ty, COST_NEAR) then
    local cells = AStar(cost, sx, sy, gx, gy)
    if cells and #cells > 1 then
      local pts = {}
      for _, k in ipairs(cells) do table.insert(pts, { ((k % 100) + 0.5) * CELL, (math.floor(k / 100) + 0.5) * CELL }) end
      pts[#pts] = { tx, ty }
      -- Kosten entlang des A* Weges, aufsummiert
      local cum, px, py = { [0] = 0 }, fx, fy
      for n, p in ipairs(pts) do
        local dd = W() and W().DirOf(p[1] - px, p[2] - py)
        cum[n] = cum[n - 1] + cost(cells[n], dd, cells[n - 1] or Key(sx, sy)) * math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2)
        px, py = p[1], p[2]
      end
      -- glaetten: so weit wie moeglich geradeaus, solange es nicht teurer ist als der Weg
      -- hoechstens 24 Punkte voraus pruefen (sonst wird es bei langen Wegen sehr teuer)
      local out, ax, ay, i, ai = {}, fx, fy, 1, 0
      while i <= #pts do
        local j = math.min(#pts, i + 24)
        while j > i and SegCost(cost, ax, ay, pts[j][1], pts[j][2]) > (cum[j] - cum[ai]) * 1.05 + 0.002 do j = j - 1 end
        table.insert(out, pts[j])
        ax, ay, ai = pts[j][1], pts[j][2], j
        i = j + 1
      end
      local len, qx, qy = 0, fx, fy
      for _, p in ipairs(out) do len = len + math.sqrt((p[1] - qx) ^ 2 + (p[2] - qy) ^ 2); qx, qy = p[1], p[2] end
      local straight = math.sqrt((tx - fx) ^ 2 + (ty - fy) ^ 2)
      -- nur nehmen, wenn er wirklich besser ist als die Luftlinie und nicht absurd lang
      -- ist die Luftlinie gesperrt (Berg, Klippe hoch, tiefes Wasser), zaehlt jeder Umweg
      if #out > 1 and cum[#pts] < direct * 0.9 and (len < straight * 2.2 or direct == math.huge) then result = out end
    end
  end
  -- alte Eintraege weg, sonst sammeln sich ueber Stunden tausende Wege an
  local now = GetTime()
  cacheN = cacheN + 1
  if cacheN > 60 then
    cacheN = 0
    for k, e in pairs(cache) do if now - e.t > 20 then cache[k] = nil else cacheN = cacheN + 1 end end
  end
  cache[ck] = { t = now, path = result }
  return result
end

-- 19.39 (Sascha 08:48, abs\stadt_pfeil): in Hauptstaedten sind die Wege verwinkelt. Findet das Netz dort keinen Weg,
-- oder kommst du mit dem Weg 20 s lang nicht 5 Yards naeher ans Ziel, zeigt der Pfeil gerade aufs Ziel (30 s lang,
-- danach wird der Weg wieder versucht). Ausserhalb der Staedte wie bisher. ns.walkCity = Grund (fuer die Anzeige).
-- Dann gibt WalkNext das Ziel selbst zurueck (Pfeil gerade drauf), damit Arrow.lua den Hinweis "Stadt: Richtung Ziel" zeigt
local CITY_STUCK_S, CITY_STUCK_YD, CITY_STRAIGHT_S = 20, 5, 30
-- 20.3u (Na 06:25, Sim haengt in Orgrimmar/Unterstadt/Donnerfels/Sturmwind/Eisenschmiede): wer in 20 s mindestens so weit
-- lief, haengt nicht, auch wenn der Weg (Rampe, Turm, Bruecke) gerade von der Luftlinie weg fuehrt. Hoechstens so lange
local CITY_MOVE_YD, CITY_MAX_S = 25, 90
-- 20.3w (Na 12:55, K 12:02 VORRANG): a) wer schon am Ziel steht (hoechstens CITY_NEAR_YD), haengt nicht (Abgeben, Kaufen,
-- Warten am NPC: die Luftlinie wird dort nie kleiner). b) Ziel in der Stadt knapp ausserhalb der Karte (y negativ) oder
-- nicht erreichbar: auf die Karte holen und per Karte.ReachPoint auf den naechsten erreichbaren Punkt ziehen (hoechstens
-- CITY_REACH_YD weit, sonst bleibt das Ziel). Arrow.lua WegFern macht das fuer Stadt Ziele nicht (InCity gibt dort nil).
local CITY_NEAR_YD, CITY_REACH_YD = 40, 150
local function CityTarget(ui, tx, ty)
  local x, y = tx, ty
  if x < 0.003 then x = 0.003 elseif x > 0.997 then x = 0.997 end
  if y < 0.003 then y = 0.003 elseif y > 0.997 then y = 0.997 end
  local K = ns.Karte
  if K and K.ReachPoint then
    local ok, rx, ry, rd = pcall(K.ReachPoint, ui, x, y)
    if ok and rx and ry and rd and rd <= CITY_REACH_YD then x, y = rx, ry end
  end
  return x, y
end
local cityS = {}
local function CityLog(why, city, fx, fy)
  if ns.walkCity == why then return end
  ns.walkCity = why
  if why and ns.TestLog then ns.TestLog("PFEIL", ("Stadt Pfeil gerade aufs Ziel (%s), Karte %s %.3f %.3f"):format(why, tostring(city), fx or 0, fy or 0)) end
end

-- 20.4 (Na, K 19:33, Ge Vorschlag Stand 161 stadt_tore_vorschlag.json): Stadt Tore. Findet der Pfeil in einer Hauptstadt keinen Weg
-- oder haengt (Ziel im Gebaeude, auf einer Rampe, knapp ausserhalb), zeigt er nicht nur gerade aufs Ziel, sondern erst auf ein Tor:
-- Aufzug (1) und schmaler Rand Durchgang (2) zuerst, Engstellen (3) nur mit Aufschlag. Danach wieder gerade aufs Ziel.
-- ACHTUNG: die Kandidaten sind von Ge aus dem Gelaende Raster geschaetzt, keine echten Tore. S entscheidet nach dem Test (Log STADTTOR),
-- ob es bleibt. Schalter ns.db.stadtTore = false: aus. Welt x = Norden, y = Westen (Ge); Reihenfolge wird je Stadt geprueft.
-- (die 228 eingebauten Kandidaten aus Stand 161 sind weg: S hat 45 mit Ja, 183 mit Nein beantwortet, Stand 164 Stadt.lua ist die Quelle)
local TOR_NEAR_YD, TOR_MAX_S, TOR_ENGE_YD, TOR_DETOUR, TOR_SICHER_YD = 15, 25, 80, 1.6, 150
-- 1.1 (P58, K 14:33: Pfeil in der Stadt Luftlinie statt Weg): nach Ende oder Zeit um nach so vielen Sekunden neu rechnen
-- (vorher dann fuer immer gerade aufs Ziel), wenn das Ziel noch weiter als GATE_FAR_YD weg ist
local GATE_RETRY_S, GATE_FAR_YD = 15, 30
-- 20.4b (Na, Ge Stand 164, S hat die Tore beantwortet): 45 Tore mit sicher = 1 (Ja), dazu je Stadt Wege Linien, die S gezeichnet hat
-- (Orgrimmar hat gar kein Tor, nur Wege). Wege Linien sind bewiesene Wege, in beide Richtungen. Daraus wird je Stadt ein Wegnetz:
-- Knoten alle WEG_STEP_YD auf den Linien, Linien die sich auf WEG_JOIN_YD beruehren sind verbunden, Tore sind Knoten (TOR_JOIN_YD zu
-- Linien). Start und Ziel haengen mit gerader Strecke (mal FREI_FAKTOR, also teurer als Netz) an Knoten bis ANBIND_YD Entfernung.
-- Der Pfeil geht die Knoten der Reihe nach ab (Log STADTTOR), danach gerade aufs Ziel. Stadt.lua Eintraege koennen Listen sein
-- ({id, x, y, art, breite_yd, sicher}, {x, y}) oder mit Namen (t.x), beides wird gelesen. Welt x = Norden, y = Westen (Ge).
local WEG_STEP_YD, WEG_JOIN_YD, TOR_JOIN_YD, FREI_FAKTOR, ANBIND_YD = 10, 8, 12, 1.5, 250
local NETZ_Z_STEP = 6   -- 1.1: Stadt Netz mit Hoehe, ab so viel Hoehen Unterschied ein eigener Wegpunkt
local torFlip = {}   -- [ui] = true, wenn der Spiel Vektor x und y vertauscht
-- Ge Stadt.lua: FWW_AUTO_STADT.forever.staedte[ui] = { tore = { {id, x, y, art, breite_yd, sicher} }, innen = { {x, y, art, grund} }, wege = { { {x, y}, ... } } }
local function StadtDaten(ui)
  local A = _G.FWW_AUTO_STADT
  local f = type(A) == "table" and A.forever
  local st = type(f) == "table" and type(f.staedte) == "table" and f.staedte[ui]
  if type(st) == "table" then return st end
end
-- Felder lesen: mit Namen oder als Liste
local function TorF(t) return t.id or t[1], t.x or t[2], t.y or t[3], t.art or t[4], t.breite_yd or t[5] or 0, (t.sicher ~= nil and t.sicher or t[6]) end
local function PxPy(p) return p.x or p[1], p.y or p[2] end
-- Welt (Ge Reihenfolge) <-> Karte: Reihenfolge je Stadt pruefen (der Spiel Vektor kann vertauscht sein), einmal je Stadt
local convC = {}
local function CityConv(ui, samples)
  local c = convC[ui]
  if c ~= nil then return c end
  c = false
  if #samples > 0 and ns.MapWorld and C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D then
    local cont = ns.MapWorld(ui, 0.5, 0.5)
    if cont then
      local function Try(a, b)
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, CreateVector2D(a, b), ui)
        if not (ok and pos) then return end
        local u, v = pos:GetXY()
        return u, v
      end
      local function In(u, v) return u and u > -0.05 and u < 1.05 and v > -0.05 and v < 1.05 end
      local inside, swap = 0, 0
      for i = 1, math.min(#samples, 12) do
        local u, v = Try(samples[i][1], samples[i][2])
        if In(u, v) then inside = inside + 1 end
        local u2, v2 = Try(samples[i][2], samples[i][1])
        if In(u2, v2) then swap = swap + 1 end
      end
      local flip = swap > inside
      torFlip[ui] = flip
      c = { flip = flip, inside = inside, swap = swap }
      -- Ge Welt (a, b) -> Karten Punkt (u, v) oder nil, wenn ausserhalb der Karte
      function c.Map(a, b)
        local u, v
        if flip then u, v = Try(b, a) else u, v = Try(a, b) end
        if not In(u, v) then return nil end
        if u < 0.003 then u = 0.003 elseif u > 0.997 then u = 0.997 end
        if v < 0.003 then v = 0.003 elseif v > 0.997 then v = 0.997 end
        return u, v
      end
    end
  end
  convC[ui] = c
  return c
end
-- Karten Punkt -> Welt in Ge Reihenfolge
local function CityWorld(ui, u, v)
  if not ns.MapWorld then return end
  local cont, wx, wy = ns.MapWorld(ui, u, v)
  if not cont or not wx then return end
  if torFlip[ui] then return wy, wx end
  return wx, wy
end
local function Samples(ui)
  local sd, s = StadtDaten(ui), {}
  if sd and type(sd.tore) == "table" then
    for _, t in ipairs(sd.tore) do local _, x, y = TorF(t); if x and y then s[#s + 1] = { x, y } end end
  end
  if #s == 0 and sd and type(sd.wege) == "table" then
    for _, l in ipairs(sd.wege) do for _, p in ipairs(l) do local x, y = PxPy(p); if x and y then s[#s + 1] = { x, y } end end end
  end
  if #s == 0 and sd and type(sd.innen) == "table" then
    for i = 1, math.min(#sd.innen, 12) do local x, y = PxPy(sd.innen[i]); if x and y then s[#s + 1] = { x, y } end end
  end
  return s
end
-- liegt das Ziel (Karten Punkt) in einem Gebaeude oder auf einer Hoehe (Ge innen Liste, nur mit Stadt.lua)? Dann erst Tor, kein Haenger
local INNEN_YD = 8
local function InnenZiel(ui, tx, ty)
  local sd = StadtDaten(ui)
  if not (sd and type(sd.innen) == "table" and #sd.innen > 0 and ns.MapWorld) then return false end
  CityConv(ui, Samples(ui))
  local a0, b0 = CityWorld(ui, tx, ty)
  if not a0 then return false end
  local lim = INNEN_YD * INNEN_YD
  for _, p in ipairs(sd.innen) do
    local a, b = PxPy(p)
    if a and b and (a0 - a) ^ 2 + (b0 - b) ^ 2 <= lim then return true end
  end
  return false
end
-- Wegnetz einer Stadt (Welt Koordinaten Ge Reihenfolge): nodes[i] = { a, b, u, v, id, art }, adj[i] = { {j, kosten}, ... }
local netzC = {}
local function Netz(ui)
  local N = netzC[ui]
  if N ~= nil then return N end
  N = false
  local sd = StadtDaten(ui)
  local cv = CityConv(ui, Samples(ui))
  -- 1.1 (Ka Stand 166, absprache wege_logik 09:20): eigenes Stadt Wegnetz netz = { knoten = { {x, y, z} }, kanten = { a, b, ... },
  -- tore = { {tor_id, knoten} } } aus NPC Laufwegen und Linien von S, bewiesen begehbar. Ist es da, ersetzt es das alte Netz
  -- aus Toren und Wege Linien. Kosten = Laenge mit Hoehe (z), Knoten ausserhalb der Karte bleiben im Netz (nur nicht als Ziel)
  local nz = sd and type(sd.netz) == "table" and type(sd.netz.knoten) == "table" and #sd.netz.knoten > 1 and sd.netz
  if nz and cv then
    local nodes, adj = {}, {}
    local artOf = {}
    for _, t in ipairs(type(sd.tore) == "table" and sd.tore or {}) do local id, _, _, art = TorF(t); if id then artOf[id] = art end end
    for k, p in ipairs(nz.knoten) do
      local a, b, z = p[1] or p.x, p[2] or p.y, p[3] or p.z
      if type(a) == "number" and type(b) == "number" then
        local u, v = cv.Map(a, b)
        nodes[k] = { a, b, u, v, nil, "netz", type(z) == "number" and z or nil }
      else
        nodes[k] = { 0, 0, nil, nil, nil, "leer" }
      end
      adj[k] = {}
    end
    local kn = nz.kanten or {}
    local ne = 0
    for e = 1, #kn - 1, 2 do
      local i, j = kn[e], kn[e + 1]
      local ni, nj = nodes[i], nodes[j]
      if ni and nj and ni[6] == "netz" and nj[6] == "netz" then
        local dz = (ni[7] and nj[7]) and (ni[7] - nj[7]) or 0
        local d = math.sqrt((ni[1] - nj[1]) ^ 2 + (ni[2] - nj[2]) ^ 2 + dz * dz)
        adj[i][#adj[i] + 1] = { j, d }
        adj[j][#adj[j] + 1] = { i, d }
        ne = ne + 1
      end
    end
    local nt = 0
    for _, t in ipairs(type(nz.tore) == "table" and nz.tore or {}) do
      local id, k = t[1], t[2]
      if id and nodes[k] then nodes[k][5] = id; nodes[k][6] = artOf[id] or "tor"; nt = nt + 1 end
    end
    N = { nodes = nodes, adj = adj, netz = true }
    if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: Stadt Netz %d Knoten, %d Kanten, %d Tore"):format(tostring(ui), #nodes, ne, nt)) end
    netzC[ui] = N
    return N
  end
  if sd and cv then
    local nodes, adj, lineOf = {}, {}, {}
    local function Add(a, b, id, art, line)
      local u, v = cv.Map(a, b)
      if not u then return nil end
      nodes[#nodes + 1] = { a, b, u, v, id, art }
      adj[#nodes] = {}
      lineOf[#nodes] = line
      return #nodes
    end
    local function Link(i, j, f)
      local d = math.sqrt((nodes[i][1] - nodes[j][1]) ^ 2 + (nodes[i][2] - nodes[j][2]) ^ 2) * (f or 1)
      adj[i][#adj[i] + 1] = { j, d }
      adj[j][#adj[j] + 1] = { i, d }
    end
    local tn = {}
    if type(sd.tore) == "table" then
      for _, t in ipairs(sd.tore) do
        local id, x, y, art, _, sicher = TorF(t)
        if x and y and sicher == 1 then
          local i = Add(x, y, id, art, nil)
          if i then tn[#tn + 1] = i end
        end
      end
    end
    local nl = 0
    if type(sd.wege) == "table" then
      for li, l in ipairs(sd.wege) do
        local prev
        for k = 1, #l do
          local ax, ay = PxPy(l[k])
          if ax and ay then
            if prev then
              local dx, dy = ax - prev[1], ay - prev[2]
              local len = math.sqrt(dx * dx + dy * dy)
              local n = math.max(1, math.ceil(len / WEG_STEP_YD))
              local last = prev[3]
              for s = 1, n do
                local i = Add(prev[1] + dx * s / n, prev[2] + dy * s / n, nil, "weg", li)
                if i then
                  if last then Link(last, i) end
                  last = i
                end
              end
              prev = { ax, ay, last }
            else
              prev = { ax, ay, Add(ax, ay, nil, "weg", li) }
            end
          end
        end
        nl = nl + 1
      end
    end
    -- Linien die sich beruehren und Tore an Linien
    local n = #nodes
    local j2, t2 = WEG_JOIN_YD * WEG_JOIN_YD, TOR_JOIN_YD * TOR_JOIN_YD
    for i = 1, n do
      for j = i + 1, n do
        local d2 = (nodes[i][1] - nodes[j][1]) ^ 2 + (nodes[i][2] - nodes[j][2]) ^ 2
        local ti, tj = lineOf[i] == nil, lineOf[j] == nil
        if (ti or tj) and d2 <= t2 or (not ti and not tj and lineOf[i] ~= lineOf[j] and d2 <= j2) then Link(i, j) end
      end
    end
    if n > 0 then N = { nodes = nodes, adj = adj } end
    if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: Wegnetz %d Knoten, %d Tore, %d Linien"):format(tostring(ui), n, #tn, nl)) end
  end
  netzC[ui] = N
  return N
end
-- kuerzester Weg von (sa, sb) nach (ga, gb): Liste von Knoten Indizes, Kosten. Start und Ziel haengen frei (mal FREI_FAKTOR) an Knoten
-- 1.1: A* mit Heap (das neue Stadt Netz hat bis 2900 Knoten, die alte Suche war n mal n und ruckelte)
local function HeapPush(h, f, i)
  local n = #h + 1
  h[n] = { f, i }
  while n > 1 do
    local p = math.floor(n / 2)
    if h[p][1] <= h[n][1] then break end
    h[p], h[n] = h[n], h[p]
    n = p
  end
end
local function HeapPop(h)
  local n = #h
  if n == 0 then return end
  local top = h[1]
  h[1] = h[n]; h[n] = nil; n = n - 1
  local i = 1
  while true do
    local l, r, m = i * 2, i * 2 + 1, i
    if l <= n and h[l][1] < h[m][1] then m = l end
    if r <= n and h[r][1] < h[m][1] then m = r end
    if m == i then break end
    h[i], h[m] = h[m], h[i]
    i = m
  end
  return top[1], top[2]
end
local function NetzWeg(N, sa, sb, ga, gb)
  local nodes, adj = N.nodes, N.adj
  local n = #nodes
  local dist, prev, done = {}, {}, {}
  local lim2 = ANBIND_YD * ANBIND_YD
  local heap = {}
  local function H(i) return math.sqrt((nodes[i][1] - ga) ^ 2 + (nodes[i][2] - gb) ^ 2) end
  for i = 1, n do
    if nodes[i][6] ~= "leer" then
      local d2 = (nodes[i][1] - sa) ^ 2 + (nodes[i][2] - sb) ^ 2
      if d2 <= lim2 then dist[i] = math.sqrt(d2) * FREI_FAKTOR; HeapPush(heap, dist[i] + H(i), i) end
    end
  end
  local best, bi = nil, nil
  while true do
    local f, u = HeapPop(heap)
    if not u then break end
    if best and f >= best then break end
    if not done[u] then
      done[u] = true
      local ud = dist[u]
      local d2 = (nodes[u][1] - ga) ^ 2 + (nodes[u][2] - gb) ^ 2
      if d2 <= lim2 then
        local tot = ud + math.sqrt(d2) * FREI_FAKTOR
        if not best or tot < best then best, bi = tot, u end
      end
      for _, e in ipairs(adj[u]) do
        local v, c = e[1], ud + e[2]
        if not done[v] and (not dist[v] or c < dist[v]) then dist[v], prev[v] = c, u; HeapPush(heap, c + H(v), v) end
      end
    end
  end
  if not bi then return nil end
  local path, k = {}, bi
  while k do table.insert(path, 1, k); k = prev[k] end
  return path, best
end
local gateS = {}   -- Zustand des aktuellen Tor Wegs: ui, tx, ty, route { {u, v, id, art}, ... }, i, t0, cap, done
-- Ziel (cx, cy) oder, wenn ein Tor bzw. Weg im Netz auf dem Weg lohnt, der naechste Knoten davon. Wird nur im Rueckfall (kein Weg, haengt) gerufen.
local function GateOr(ui, fx, fy, cx, cy, force)
  ns.walkGate = false
  if not ns.db or ns.db.stadtTore == false or not ns.WorldDist then return cx, cy end
  local now = GetTime and GetTime() or 0
  if gateS.ui ~= ui or math.abs((gateS.tx or -1) - cx) > 0.002 or math.abs((gateS.ty or -1) - cy) > 0.002 or now - (gateS.last or 0) > 120 then
    gateS = { ui = ui, tx = cx, ty = cy, done = {} }
  end
  gateS.last = now
  local r = gateS.route
  if r then
    local g = r[gateS.i]
    -- schon an einem der naechsten Knoten vorbei? dann dorthin springen
    while g do
      local d = ns.WorldDist({ ui, fx, fy }, { ui, g[1], g[2] })
      -- 1.1 (P58): auch weiter, wenn du am Punkt vorbei bist (zum naechsten Punkt naeher als der Punkt selbst davon weg ist),
      -- sonst zeigte der Pfeil zurueck auf einen knapp verpassten Punkt
      local nx = r[gateS.i + 1]
      local passed = false
      if d and nx and d > TOR_NEAR_YD then
        local dn = ns.WorldDist({ ui, fx, fy }, { ui, nx[1], nx[2] })
        local seg = ns.WorldDist({ ui, g[1], g[2] }, { ui, nx[1], nx[2] })
        passed = dn and seg and dn < seg
      end
      if d and (d <= TOR_NEAR_YD or passed) then
        if ns.TestLog and g[3] then ns.TestLog("STADTTOR", ("Tor %s erreicht (Abstand %d yd)"):format(tostring(g[3]), math.floor(d))) end
        gateS.i = gateS.i + 1
        gateS.t0 = now -- Fortschritt: Zeit fuer den Rest neu
        g = r[gateS.i]
      else break end
    end
    if g and now - gateS.t0 <= gateS.cap then ns.walkGate = true; return g[1], g[2] end
    if ns.TestLog then ns.TestLog("STADTTOR", g and "Weg Zeit um, weiter gerade aufs Ziel" or ("Weg fertig (%d Punkte), weiter gerade aufs Ziel"):format(#r)) end
    gateS.route = nil
    gateS.tried = now
    return cx, cy
  end
  -- 1.1 (P58): nicht fuer immer gerade aufs Ziel. Nach GATE_RETRY_S neu, solange das Ziel noch weiter weg ist
  if gateS.tried then
    local dz = ns.WorldDist({ ui, fx, fy }, { ui, cx, cy })
    if not (now - gateS.tried >= GATE_RETRY_S and dz and dz > GATE_FAR_YD) then return cx, cy end
  end
  gateS.tried = now
  local dDirect = ns.WorldDist({ ui, fx, fy }, { ui, cx, cy })
  if not dDirect then return cx, cy end
  local N = Netz(ui)
  if not N then
    if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: kein Wegnetz und keine Tore, gerade aufs Ziel"):format(tostring(ui))) end
    return cx, cy
  end
  local sa, sb = CityWorld(ui, fx, fy)
  local ga, gb = CityWorld(ui, cx, cy)
  if not (sa and ga) then return cx, cy end
  local path, cost = NetzWeg(N, sa, sb, ga, gb)
  if not path then
    if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: kein Wegnetz in %d yd, gerade aufs Ziel (Luftlinie %d yd)"):format(tostring(ui), ANBIND_YD, math.floor(dDirect))) end
    return cx, cy
  end
  if not force and cost > dDirect * TOR_DETOUR + 60 then
    if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: Netz Weg %d yd lohnt nicht gegen Luftlinie %d yd, gerade aufs Ziel"):format(tostring(ui), math.floor(cost), math.floor(dDirect))) end
    return cx, cy
  end
  -- nur Knoten die als Zwischenziel taugen: Tore immer, Linien Knoten etwa alle 30 yd (der Pfeil geht dann gerade dazwischen)
  local pts, lastA, lastB, lastZ = {}, nil, nil, nil
  for k, idx in ipairs(path) do
    local nd = N.nodes[idx]
    local keep = nd[5] ~= nil or k == #path or k == 1
    -- Netz mit Hoehe: auch bei grossem Hoehen Wechsel (Rampe, Aufzug, Treppe) einen Punkt setzen
    if not keep and N.netz and lastZ and nd[7] and math.abs(nd[7] - lastZ) >= NETZ_Z_STEP then keep = true end
    if not keep and lastA then keep = (nd[1] - lastA) ^ 2 + (nd[2] - lastB) ^ 2 >= 30 * 30 end
    if keep and nd[3] then pts[#pts + 1] = { nd[3], nd[4], nd[5], nd[6] }; lastA, lastB, lastZ = nd[1], nd[2], nd[7] or lastZ end
  end
  if #pts == 0 then return cx, cy end
  gateS.route, gateS.i, gateS.t0 = pts, 1, now
  gateS.cap = TOR_MAX_S + cost / 4
  if ns.TestLog then ns.TestLog("STADTTOR", ("Stadt %s: Weg ueber %d Punkte (%d Knoten), %d yd statt Luftlinie %d yd%s"):format(
    tostring(ui), #pts, #path, math.floor(cost), math.floor(dDirect), force and ", Ziel innen" or "")) end
  ns.walkGate = true
  return pts[1][1], pts[1][2]
end
-- naechster Punkt fuer den Pfeil (mit Karte: den Weg Stueck fuer Stueck abgehen)
function ns.WalkNext(ui, fx, fy, tx, ty)
  local db = ns.db
  if not db or db.walkPaths == false then return nil end
  local K = ns.Karte
  local city = K and K.InCity and K.InCity(ui, fx, fy)
  local now = GetTime and GetTime() or 0
  if not city then ns.walkCity = nil end
  -- 1.1 (Ka Befund Log 08:46 "Stadt 1411: kein Wegnetz"): du stehst auf der Zonen Karte (zb Durotar) im Bereich einer Stadt.
  -- Dann in der Stadt Karte rechnen und das Ergebnis zurueck auf die Zone umrechnen (vorher suchte es das Netz der Zone)
  if city and city ~= ui and ns.ToMap and not ns.walkInner then
    local cfx, cfy = ns.ToMap(ui, fx, fy, city)
    local ctx, cty = ns.ToMap(ui, tx, ty, city)
    if cfx and ctx then
      ns.walkInner = true
      local ok, rx, ry = pcall(ns.WalkNext, city, cfx, cfy, ctx, cty)
      ns.walkInner = nil
      if ok and rx and ry then
        local zx, zy = ns.ToMap(city, rx, ry, ui)
        if zx then return zx, zy end
      end
      if ok then return nil end
    end
  end
  local s = cityS
  local same = s.ui == ui and math.abs((s.tx or -1) - tx) < 0.002 and math.abs((s.ty or -1) - ty) < 0.002
  -- 20.3w: Ziel in der Stadt auf einen erreichbaren Punkt auf der Karte ziehen (cx, cy); same und cityS bleiben beim Original
  local cx, cy = tx, ty
  if city and city == ui then cx, cy = CityTarget(ui, tx, ty) end
  -- 20.4: Ziel in einem Gebaeude oder auf einer Hoehe (Ge Stadt.lua innen): erst Tor, dann Luftlinie, nicht als Haenger zaehlen
  if city and city == ui and InnenZiel(ui, tx, ty) then
    if ns.walkCity ~= "innen" and ns.TestLog then ns.TestLog("STADTTOR", ("Ziel innen in Stadt %s, Karte %.3f %.3f"):format(tostring(ui), cx, cy)) end
    ns.walkCity = "innen"
    return GateOr(ui, fx, fy, cx, cy, true)
  end
  -- 1.1 (Ka Stand 166): Stadt mit eigenem Netz (bewiesene Wege mit Hoehe): zuerst das Netz, die Karte nur fuer das letzte Stueck
  if city and city == ui and db.stadtNetz ~= false then
    local sd = StadtDaten(ui)
    if sd and type(sd.netz) == "table" then
      local gx, gy = GateOr(ui, fx, fy, cx, cy, true)
      if gateS.route then return gx, gy end
    end
  end
  if city and same and s.straightUntil and now < s.straightUntil then return GateOr(ui, fx, fy, cx, cy) end
  if K and K.HasZone(ui) then
    local ok, x, y = pcall(K.FollowNext, ui, fx, fy, cx, cy)
    if ok and x then
      if city then
        local d = ns.WorldDist and ns.WorldDist({ ui, fx, fy }, { ui, cx, cy })
        if not same then
          cityS = { ui = ui, tx = tx, ty = ty, best = d, t = now, tb = now, px = fx, py = fy }
        elseif d and s.best and d < s.best - CITY_STUCK_YD then
          s.best, s.t, s.tb, s.px, s.py = d, now, now, fx, fy
        elseif now - (s.t or now) > CITY_STUCK_S and d and d <= CITY_NEAR_YD then
          s.t, s.tb, s.best, s.px, s.py = now, now, d, fx, fy -- am Ziel, kein Haengen
        elseif now - (s.t or now) > CITY_STUCK_S then
          local mv = ns.WorldDist and s.px and ns.WorldDist({ ui, s.px, s.py }, { ui, fx, fy })
          if mv and mv >= CITY_MOVE_YD and now - (s.tb or now) <= CITY_MAX_S then
            s.t, s.px, s.py = now, fx, fy -- du bewegst dich, kein Haengen
          else
            s.straightUntil, s.t, s.tb, s.best, s.px, s.py = now + CITY_STRAIGHT_S, now, now, d, fx, fy
            CityLog("haengt", city, fx, fy)
            return GateOr(ui, fx, fy, cx, cy)
          end
        end
        if ns.walkCity then CityLog(nil) end
      end
      return x, y
    end
    if ok and y == "free" then if city and ns.walkCity then CityLog(nil) end return nil end
  end
  -- in der Stadt kein Weg im Netz: gerade aufs Ziel statt des alten Umwegs ueber das Raster
  if city then CityLog("kein Weg", city, fx, fy); return GateOr(ui, fx, fy, cx, cy) end
  local p = ns.WalkPath(ui, fx, fy, tx, ty)
  if p and p[1] and #p > 1 then return p[1][1], p[1][2] end
end

-- Uebergang von Zone a nach Zone b (Punkt in Zone a), der am wenigsten Umweg macht: die Uebergaenge der Karte
-- (Strecken ueber das Netz) und deine selbst gelaufenen (Luftlinie). Ohne Karte nur die selbst gelaufenen.
function ns.ZoneCrossing(a, px, py, b, tx, ty)
  local db = ns.db
  if not (db and ns.WorldDist) then return end
  local list = db.cross and db.cross[a] and db.cross[a][b]
  local best, bd
  local K = ns.Karte
  if K and K.HasZone(a) then
    local ok, x, y, d = pcall(K.Crossing, a, px, py, b, tx, ty)
    if ok and x then best, bd = { x, y }, d end
  end
  local function Try(cx, cy)
    local d1 = ns.WorldDist({ a, px, py }, { a, cx, cy })
    local d2 = ns.WorldDist({ a, cx, cy }, { b, tx, ty })
    -- Luftlinie ist zu kurz geschaetzt: gelaufene nur, wenn sie klar besser sind als die der Karte
    if d1 and d2 and (not bd or (d1 + d2) * 1.2 < bd) then best, bd = { cx, cy }, (d1 + d2) * 1.2 end
  end
  for _, c in ipairs(list or EMPTY) do Try(c[1], c[2]) end
  if best then return best[1], best[2] end
end

------------------------------------------------------------
-- Weg ueber Zonen (19.0 immer an, ohne Schalter): ueber die Uebergaenge der Werkzeug Karte, die festen Verbindungen
-- (FesteDaten.lua) und deine selbst gelaufenen Uebergaenge. Gerechnet wird in Karte.lua.
------------------------------------------------------------
-- Laufstrecke in Yards von a nach b in verschiedenen Zonen auf einem Kontinent. nil: nicht bekannt
-- (anderer Kontinent, Graph rechnet noch, keine Daten). force bleibt fuer alte Aufrufe (Sim), es gibt keinen Schalter mehr.
function ns.XZoneDist(m1, x1, y1, m2, x2, y2, force)
  local K = ns.Karte
  if not K then return nil end
  return K.CrossDist(m1, x1, y1, m2, x2, y2)
end
-- 19.24 (Sascha Teil 1 Punkt 4): Laufstrecke in Yards von a nach b, gleich gerechnet wie die Route (Optimizer DRaw):
-- Luftlinie mal 1.2, ueber das Netz der Gelaende Karte (in der Zone und ueber Zonen) mal 1.05, das Laengere zaehlt.
-- a, b: Tabellen mit { map, x, y } und / oder { cont (oder c), wx, wy }. nil: anderer Kontinent oder keine Position.
-- Zweiter Wert true: das Netz kennt die Strecke (sonst nur die Luftlinie)
local WALK_PATH, WALK_NET = 1.2, 1.05
local function WalkNet(a, b)
  local cp = ns.cityParent
  local pa, pb = (cp and cp[a.map]) or a.map, (cp and cp[b.map]) or b.map
  if a.map == b.map then return ns.GridDist(a.map, a.x, a.y, b.x, b.y) end
  if pa == pb then
    -- Stadt und ihre Zone (zb Orgrimmar und Durotar): in der Zone rechnen
    if not ns.ToMap then return nil end
    local x1, y1 = ns.ToMap(a.map, a.x, a.y, pa)
    local x2, y2 = ns.ToMap(b.map, b.x, b.y, pa)
    if x1 and x2 then return ns.GridDist(pa, x1, y1, x2, y2) end
    return nil
  end
  return ns.XZoneDist(a.map, a.x, a.y, b.map, b.x, b.y)
end
function ns.WalkYards(a, b)
  if not (a and b) then return nil end
  local ca, cb = a.cont or a.c, b.cont or b.c
  local air
  if a.wx and b.wx and ca and ca == cb then
    air = math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2)
  elseif a.map and b.map and a.x and b.x and ns.WorldDist and not (ca and cb and ca ~= cb) then
    air = ns.WorldDist({ a.map, a.x, a.y }, { b.map, b.x, b.y })
  end
  if not air then return nil end
  local d = air * WALK_PATH
  if a.map and b.map and a.x and b.x and ns.db and ns.Karte then
    local ok, g = pcall(WalkNet, a, b)
    if ok and g then
      if g * WALK_NET > d then d = g * WALK_NET end
      return d, true
    end
  end
  return d, false
end
-- Weg als Punkte { Zone, x, y } vom Start ueber die Uebergaenge zum Ziel
function ns.XZonePath(m1, x1, y1, m2, x2, y2)
  local K = ns.Karte
  if not K then return nil end
  return K.CrossPath(m1, x1, y1, m2, x2, y2)
end
-- erster Uebergang auf dem Weg (Punkt auf der Karte des Spielers) oder nil
-- 19.9 (Code Pruefung): der Pfeil fragt das 4 Mal pro Sekunde ohne eigenes pcall. Wirft die Karte, dann 30 Sekunden
-- Pause (Pfeil zeigt so lange die Luftlinie) und der Fehler einmal ins Test Log, statt einer Fehler Flut
local xnErrUntil, xnErrSeen = 0, nil
function ns.XZoneNext(m1, x1, y1, m2, x2, y2)
  local K = ns.Karte
  if not K then return nil end
  local now = GetTime and GetTime() or 0
  if now < xnErrUntil then return nil end
  local ok, a, b, c, d, e = pcall(K.NextCross, m1, x1, y1, m2, x2, y2)
  if ok then return a, b, c, d, e end
  xnErrUntil = now + 30
  if xnErrSeen ~= tostring(a) then
    xnErrSeen = tostring(a)
    if ns.TestLog then ns.TestLog("FEHLER", "Karte NextCross: " .. tostring(a)) end
  end
  return nil
end
ns.XContMap = function(ui) return ns.Karte and ns.Karte.ContMap(ui) end
ns.XZoneGraph = function(cont) return ns.Karte and ns.Karte.XGraph(cont) end

function ns.WalkStats(ui)
  local db = ns.db
  local n = 0
  for _ in pairs(db and db.walk and db.walk[ui] or {}) do n = n + 1 end
  local x = 0
  for _ in pairs(db and db.cross and db.cross[ui] or {}) do x = x + 1 end
  return n, x
end

------------------------------------------------------------
-- 19.0: die Felder kommen aus der Werkzeug Karte (Karte.lua), nicht mehr aus PaintData.lua und dem Mal Addon.
-- Einmal nach dem Update: die alten gemalten Felder und Wegpunkte aus deinen Daten loeschen (auch selbst gemalte).
-- Bleiben: deine gelaufenen Wege (walk, walkDir, walkDrop), Uebergaenge (cross) und die geteilten Wege.
------------------------------------------------------------
ns.blockRev = ns.blockRev or 0
local KARTE_MIG = 1
function ns.KarteMigrate(db)
  db = db or ns.db
  if not db or (db.karteMig or 0) >= KARTE_MIG then return end
  for _, f in ipairs({ "block", "road", "water", "cliff", "xpass", "xwp", "xlink", "xshut", "paintBase", "paintCleanVer", "xhandRev", "zoneWalk" }) do
    db[f] = nil
  end
  db.karteMig = KARTE_MIG
  ns.blockRev = (ns.blockRev or 0) + 1
end
do
  local pf = CreateFrame("Frame")
  pf:RegisterEvent("PLAYER_ENTERING_WORLD")
  pf:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    pcall(ns.KarteMigrate)
  end)
end


-- 19.32 (Saschas Entscheid 22:45): die Bruecke zu AzerothGPS ist raus. Pfeil, Minimap und Weltkarte zeigen den eigenen Weg
-- (Gelaende Karte, Karte.lua), alte Einstellungen useGPS und gpsDock werden ignoriert.

-- 1.1 (P41, S 11:24): Hoehe zum Ziel ("Ziel oben, ca 6 m hoeher"). Geht nur, wo es Hoehen Daten gibt: Stadt Netz von Ka
-- (Knoten mit z). Spieler Hoehe aus UnitPosition, wenn das Spiel sie liefert, sonst vom naechsten Netz Knoten. Liegen an einer
-- Stelle mehrere Stockwerke uebereinander (Knoten in HOEHE_NEAR_YD mit NETZ_Z_STEP Unterschied), wird nichts gesagt
local HOEHE_NEAR_YD = 8
local HOEHE_MIN_YD = 5
local YD_TO_M = 0.9144
local function NetzZ(ui, x, y)
  local N = Netz(ui)
  if not (N and N.netz and ns.WorldDist) then return nil end
  local best, bz, zmin, zmax
  for _, n in ipairs(N.nodes) do
    if n[7] and n[3] then
      local d = ns.WorldDist({ ui, x, y }, { ui, n[3], n[4] })
      if d and d <= HOEHE_NEAR_YD then
        zmin = math.min(zmin or n[7], n[7]); zmax = math.max(zmax or n[7], n[7])
        if not best or d < best then best, bz = d, n[7] end
      end
    end
  end
  if bz and zmax - zmin >= NETZ_Z_STEP then return nil end
  return bz
end
local hz = { t = -10 }
function ns.ZielHoehe()
  local now = GetTime and GetTime() or 0
  if now - hz.t < 1 then return hz.v end
  hz.t, hz.v = now, nil
  if not (ns.OptTarget and ns.PlayerMap and ns.db and ns.db.optMode) then return nil end
  local st = ns.OptTarget()
  local m = ns.PlayerMap()
  if not (st and st.map and st.x and m and st.map == m) then return nil end
  local pos = C_Map.GetPlayerMapPosition(m, "player")
  if not pos then return nil end
  local px, py = pos:GetXY()
  local tz = NetzZ(m, st.x, st.y)
  if not tz then return nil end
  local ok, _, _, z = pcall(UnitPosition, "player")
  z = ok and ns.Plain and ns.Plain(z) or nil
  local fromGame = type(z) == "number" and z ~= 0
  if not hz.logged and ns.TestLog then
    hz.logged = true
    ns.TestLog("PFEIL", ("Hoehe: Spieler Hoehe vom Spiel %s"):format(fromGame and "ja" or "nein, vom Stadt Netz"))
  end
  local pz = fromGame and z or NetzZ(m, px, py)
  if not pz then return nil end
  local dz = tz - pz
  if math.abs(dz) < HOEHE_MIN_YD then return nil end
  local mtr = math.floor(math.abs(dz) * YD_TO_M + 0.5)
  hz.v = dz > 0 and (TR"Ziel oben, ca %d m höher"):format(mtr) or (TR"Ziel unten, ca %d m tiefer"):format(mtr)
  return hz.v
end
