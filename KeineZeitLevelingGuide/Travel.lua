local ADDON, ns = ...
local TR = ns.TR

-- Reisen mit Schiff und Zeppelin
-- Feste Verbindungen (Hafen und Turm Positionen), Fahrzeit und Takt.
-- Wenn NauticusClassic geladen ist und den Takt kennt, nehmen wir die echte Abfahrtszeit,
-- sonst rechnen wir mit der mittleren Wartezeit (halber Takt).

local LOAD = 15 -- Ladebildschirm, ein und aussteigen

-- id = Nauticus Nummer, pa/pb = Nauticus Plattform auf Seite a/b
-- Koordinaten nil = unbekannt, werden ueber Hafen NPCs gesucht oder beim ersten Mitfahren gelernt
local LINKS = {
  { id = 1,  kind = TR"Zeppelin", a = { 1411, 0.509, 0.139, "Orgrimmar" }, b = { 1420, 0.607, 0.588, TR"Unterstadt" }, pa = 1, pb = 2, rtt = 356.3, faction = "Horde" },
  { id = 2,  kind = TR"Zeppelin", a = { 1411, 0.506, 0.126, "Orgrimmar" }, b = { 1434, 0.316, 0.291, TR"Grom'gol" }, pa = 1, pb = 2, rtt = 303.5, faction = "Horde" },
  { id = 3,  kind = TR"Zeppelin", a = { 1420, 0.619, 0.592, TR"Unterstadt" }, b = { 1434, 0.316, 0.291, TR"Grom'gol" }, pa = 1, pb = 2, rtt = 335.3, faction = "Horde" },
  { id = 4,  kind = TR"Schiff",   a = { 1413, 0.637, 0.386, ns.EN and "Ratchet" or "Ratschet" }, b = { 1434, 0.259, 0.731, TR"Beutebucht" }, pa = 1, pb = 2, rtt = 350.8 },
  { id = 14, kind = TR"Schiff",   a = { 2548, nil, nil, TR"Powderfuse Port" }, b = { 1446, nil, nil, TR"Steamwheedle Port" }, pa = 1, pb = 2, rtt = 271.4 },
  -- Zephras Isle (Forever, Skyborne): Himmelsschiff laut Questtext der letzten Startquest. Steg Positionen unbekannt,
  -- 5. und 6. Feld = Schaetzung (Questgeber auf Zephras, Abgabe NPC am Ziel), bis der Steg gelernt ist
  { id = 12, kind = TR"Himmelsschiff", a = { 2521, nil, nil, "Zephras", 0.5915, 0.7973 }, b = { 1412, nil, nil, "Mulgore", 0.334, 0.225 }, pa = 1, pb = 2, rtt = 347, faction = "Horde" },
  { id = "zephA", kind = TR"Himmelsschiff", a = { 2521, nil, nil, "Zephras", 0.6659, 0.7991 }, b = { 1416, nil, nil, "Dalaran", 0.1224, 0.5654 }, pa = 1, pb = 2, rtt = 347, faction = "Alliance" },
  -- Allianz (Forever: das Menethil Schiff faehrt ueber Suederstade nach Auberdine)
  { id = 5,  kind = TR"Schiff", a = { 1437, 0.046, 0.571, "Menethil" }, b = { 1439, 0.324, 0.438, "Auberdine" }, pa = 1, pb = 3, rtt = 486.2, faction = "Alliance" },
  { id = 5,  kind = TR"Schiff", a = { 1437, 0.046, 0.571, "Menethil" }, b = { 1424, nil, nil, TR"Süderstade" }, pa = 1, pb = 2, rtt = 486.2, faction = "Alliance" },
  { id = 5,  kind = TR"Schiff", a = { 1424, nil, nil, TR"Süderstade" }, b = { 1439, 0.324, 0.438, "Auberdine" }, pa = 2, pb = 3, rtt = 486.2, faction = "Alliance" },
  { id = 6,  kind = TR"Schiff", a = { 1437, 0.050, 0.635, "Menethil" }, b = { 1445, 0.716, 0.564, "Theramore" }, pa = 1, pb = 2, rtt = 329.3, faction = "Alliance" },
  { id = 7,  kind = TR"Schiff", a = { 1438, 0.553, 0.930, TR"Rut'theran" }, b = { 1439, 0.332, 0.403, "Auberdine" }, pa = 1, pb = 2, rtt = 316.3, faction = "Alliance" },
  { id = 11, kind = TR"Schiff", a = { 1453, nil, nil, TR"Sturmwind Hafen" }, b = { 1439, nil, nil, "Auberdine" }, pa = 1, pb = 2, rtt = 246.5, faction = "Alliance" },
  -- 17.9: Tiefenbahn Sturmwind und Eisenschmiede (Nauticus 9 Nord und 10 Sued, Takt 143 s, Fahrt 60 s).
  -- Eingaenge wie bei Questie (Zwergenviertel und Tueftlerstadt). Gleicher Kontinent: zaehlt nur, wenn sie schneller ist als laufen
  { id = 9,  kind = TR"Tiefenbahn", a = { 1453, 0.7198, 0.2761, TR"Sturmwind" }, b = { 1455, 0.841, 0.531, TR"Eisenschmiede" }, pa = 1, pb = 2, rtt = 143.3, ride = 60, faction = "Alliance", tram = true },
  { id = 10, kind = TR"Tiefenbahn", a = { 1453, 0.7198, 0.2761, TR"Sturmwind" }, b = { 1455, 0.841, 0.531, TR"Eisenschmiede" }, pa = 1, pb = 2, rtt = 143.3, ride = 60, faction = "Alliance", tram = true },
}
ns.travelLinks = LINKS
for i, l in ipairs(LINKS) do l.idx = i end
local function MyFaction() return UnitFactionGroup and UnitFactionGroup("player") or "Horde" end
local function Usable(l) return not l.faction or l.faction == MyFaction() end

------------------------------------------------------------
-- Positionen
------------------------------------------------------------
local function World(map, x, y)
  if ns.MapWorld then return ns.MapWorld(map, x, y) end
  if not (map and x and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if not ok or not w then return end
  local wx, wy = w:GetXY()
  return cont, wx, wy
end

-- Hafen NPCs (aus dem Questie Index in Services.lua)
ns.dockNpcs = ns.dockNpcs or {}

-- Zonen, fuer die wir noch keine Hafen Position haben
function ns.TravelNeedDocks()
  local need
  for _, l in ipairs(LINKS) do
    for _, e in ipairs(Usable(l) and { l.a, l.b } or {}) do
      if not e[2] then need = need or {}; need[e[1]] = true end
    end
  end
  return need
end

local epCache = {}
local cacheRev = 0
local function Endpoint(e)
  local c = epCache[e]
  if c and c.rev == cacheRev then return c.ok and c or nil end
  local map, x, y = e[1], e[2], e[3]
  if not x then
    local learned = ns.db and ns.db.docks and ns.db.docks[map]
    if learned then x, y = learned[1], learned[2]
    else
      local d = ns.dockNpcs[map] and ns.dockNpcs[map][1]
      if d then x, y = d[1], d[2]
      elseif e[5] then x, y = e[5], e[6] end -- Schaetzung
    end
  end
  local cont, wx, wy = World(map, x, y)
  c = { rev = cacheRev, ok = cont ~= nil, map = map, x = x, y = y, cont = cont, wx = wx, wy = wy, name = e[4] }
  epCache[e] = c
  return c.ok and c or nil
end
function ns.TravelResetCache() cacheRev = cacheRev + 1 end
ns.TravelEndpoint = Endpoint

-- 19.18 (Sascha: "viele springen vom Zeppelin, von unterschiedlichsten Stellen"): liegt eine Stelle beim Steg oder beim
-- Zeppelin Turm (r Yards, ohne Tiefenbahn)? Wer dort vom Deck oder vom Turm springt, faellt nicht von einer Klippe.
function ns.NearDock(map, x, y, r)
  if not (map and x and y and ns.WorldDist) then return false end
  r = r or 60
  for _, l in ipairs(LINKS) do
    if not l.tram then
      for _, e in ipairs({ l.a, l.b }) do
        local ep = Endpoint(e)
        if ep and ep.x then
          local d = ns.WorldDist({ map, x, y }, { ep.map, ep.x, ep.y })
          if d and d < r then return true end
        end
      end
    end
  end
  return false
end

local CONT = { [0] = TR"Östliche Königreiche", [1] = "Kalimdor" }
function ns.ContName(c) return CONT[c] or TR"Insel" end

------------------------------------------------------------
-- Nauticus: echte Abfahrtszeiten
------------------------------------------------------------
local function Naut()
  local n = rawget(_G, "NauticusClassic")
  if type(n) == "table" and type(n.platforms) == "table" and type(n.rtts) == "table" and n.GetKnownCycle then return n end
end

-- Sekunden bis zur naechsten Abfahrt auf Seite side ("a"/"b"), Fahrzeit bis zur anderen Seite
local function NautTimes(l, side)
  local N = Naut()
  if not N then return end
  local id = l.id
  local okH, has = pcall(N.HasKnownCycle, N, id)
  if not (okH and has) then return end
  local plats = N.platforms[id]
  local p = plats and plats[side == "a" and l.pa or l.pb]
  local q = plats and plats[side == "a" and l.pb or l.pa]
  local rtt = N.rtts[id]
  if not (p and p.index and rtt and rtt > 0) then return end
  local okC, since = pcall(N.GetKnownCycle, N, id)
  local okD, off = pcall(N.GetCycleByIndex, N, id, p.index)
  if not (okC and okD and type(since) == "number" and type(off) == "number") then return end
  local cycle = math.fmod(since, rtt)
  local wait = math.fmod(off - cycle, rtt)
  if wait < 0 then wait = wait + rtt end
  -- 1.3v (P105 Punkt 3, S 03:04 "Timer der Schiff Abfahrt stimmt nicht"): rohe Nauticus Werte merken, das Navi schreibt
  -- sie mit der Vorschau ins Log (since = Nauticus GetKnownCycle, off = Zeit der Plattform im Umlauf, rtt = Umlauf)
  -- 1.3za: dazu die Zeit der anderen Plattform (q), um zu sehen, ob Seite a und b vertauscht sind
  local okQ, offQ = false, nil
  if q and q.index then okQ, offQ = pcall(N.GetCycleByIndex, N, id, q.index) end
  ns.lastNautRaw = { id = id, side = side, idx = p.index, since = since, off = off, rtt = rtt, wait = wait, at = GetTime(),
    idxQ = q and q.index, offQ = okQ and type(offQ) == "number" and offQ or nil,
    sync = (type(N.lastSync) == "number" and N.lastSync) or (type(N.syncTime) == "number" and N.syncTime) or nil }
  local ride
  if q and q.index then
    local okA, arr = pcall(N.GetCycleByIndex, N, id, q.index - 1)
    if okA and type(arr) == "number" then
      ride = math.fmod(arr - off, rtt)
      if ride < 0 then ride = ride + rtt end
    end
  end
  return wait, ride, rtt
end

local function Rtt(l)
  local N = Naut()
  local r = N and N.rtts[l.id]
  return (type(r) == "number" and r > 0) and r or l.rtt
end

-- Fahrzeit ohne Warten (Nauticus wenn bekannt, sonst Schaetzung)
local rideCache = {}
local function Ride(l, side)
  local key = (l.idx or l.id) .. side -- die Menethil Verbindungen teilen sich eine id
  local r = rideCache[key]
  if r and GetTime() - r[2] < 60 then return r[1] end
  local _, ride = NautTimes(l, side)
  ride = ride or l.ride or Rtt(l) * 0.42
  rideCache[key] = { ride, GetTime() }
  return ride
end

-- live: wann faehrt das naechste ab (nil wenn Nauticus den Takt nicht kennt)
function ns.TravelDeparts(linkId, side, li)
  -- 1.3zu (P123): dazu Fahrzeit und Umlauf (fuer die Abfahrt bei spaeterer Ankunft)
  if li and LINKS[li] then return NautTimes(LINKS[li], side) end
  -- 1.3zz (Pr 02:33, Block Abfahrten leer am Steg): Navi Abschnitte geben die Verbindung selbst mit
  if type(linkId) == "table" then return NautTimes(linkId, side) end
  for _, l in ipairs(LINKS) do
    if l.id == linkId then
      return NautTimes(l, side)
    end
  end
end

------------------------------------------------------------
-- Kosten fuer die Planung
------------------------------------------------------------
-- Alle Wege von a nach b ueber eine Verbindung: liefert die beste
-- Rueckgabe: Zeit in Sekunden, Abfahrt Endpunkt, Ankunft Endpunkt, Verbindung, Seite
local PATH = 1.2
local function Air(a, e)
  return math.sqrt((a.wx - e.wx) ^ 2 + (a.wy - e.wy) ^ 2) * PATH
end
-- 19.24 (Sascha Teil 1 Punkt 4): Weg zum Flugmeister und zum Steg ueber das Netz wie in der Route (ns.WalkYards)
local function Dist(a, e)
  return (ns.WalkYards and ns.WalkYards(a, e)) or Air(a, e)
end

------------------------------------------------------------
-- Fluege: bekannte Flugpunkte auf dem gleichen Kontinent
------------------------------------------------------------
local FLY_SPEED, FLY_OVER = 32, 25 -- Yards pro Sekunde, Sekunden fuer Reden, Starten, Landen
local FLY = { id = "fly", kind = TR"Flug" }
local fpList, fpRev, fpAt = nil, -1, 0
local function FlightPoints()
  local rev = ns.db and ns.db.knownFPRev or 0
  if fpList and fpRev == rev and GetTime() - fpAt < 60 then return fpList end
  fpList, fpRev, fpAt = {}, rev, GetTime()
  for _, f in ipairs(ns.KnownFlightMasters and ns.KnownFlightMasters() or {}) do
    local c, wx, wy = World(f.map, f.x, f.y)
    if c then table.insert(fpList, { map = f.map, x = f.x, y = f.y, cont = c, wx = wx, wy = wy, name = f.name, id = f.id }) end
  end
  return fpList
end

-- schnellster Flug von a nach b (gleicher Kontinent), nil wenn keiner hilft
local function FlyBest(a, b, speed)
  if ns.db and ns.db.useFlights == false then return end
  if a.cont ~= b.cont then return end
  -- 19.21: die 3 naechsten Flugmeister bei a und bei b probieren (mit den Flugdaten gibt es nicht jede Strecke)
  local ca, cb = {}, {}
  local function Keep(t, f, d)
    t[#t + 1] = { f = f, d = d }
    table.sort(t, function(x, y) return x.d < y.d end)
    if #t > 3 then t[4] = nil end
  end
  for _, f in ipairs(FlightPoints()) do
    if f.cont == a.cont then
      Keep(ca, f, Air(a, f))
      Keep(cb, f, Air(b, f))
    end
  end
  -- die 3 naechsten nach Luftlinie, fuer die dann der echte Weg
  for _, x in ipairs(ca) do x.d = Dist(a, x.f) end
  for _, y in ipairs(cb) do y.d = Dist(b, y.f) end
  local best, bfa, bfb
  for _, x in ipairs(ca) do
    for _, y in ipairs(cb) do
      local fa, fb = x.f, y.f
      if fa ~= fb then
        -- 17.4: gemessene Flugzeit (eigene oder geteilte) zuerst, 19.21: dann die Zeit aus den Spieldaten (Strecke ueber
        -- deine Flugpunkte, mehrere hintereinander), ohne Daten die Schaetzung ueber die Luftlinie
        local air = ns.FlightTime and ns.FlightTime(fa.id, fb.id)
        local tx = (not air) and ns.TaxiTime and ns.TaxiTime(fa.id, fb.id)
        if air or tx ~= false then
          local fly = air or tx or (math.sqrt((fa.wx - fb.wx) ^ 2 + (fa.wy - fb.wy) ^ 2) * 1.15 / FLY_SPEED)
          local t = x.d / speed + fly + FLY_OVER + y.d / speed
          if not best or t < best then best, bfa, bfb = t, fa, fb end
        end
      end
    end
  end
  if not best then return end
  return best, bfa, bfb
end

-- 20.3k (S Test 20.3g Punkt 19b): eigene Teleports (Magier) wie Flug in der Route: nehmen, wenn schneller. Ziel wie im
-- Navi (NaviFlug PORTS, gemessene Ankunft db.naviPortal). Nur mit gelerntem Zauber und Rune der Teleportation
local TELE = { id = "tele", kind = TR"Teleport" }
local TELE_CAST = 10
local TELES = {
  { spell = 3567, fac = "Horde", cont = 1, wx = 1469.85, wy = -4221.52, map = 1454 },
  { spell = 3563, fac = "Horde", cont = 0, wx = 1773.47, wy = 61.12, map = 1458 },
  { spell = 3566, fac = "Horde", cont = 1, wx = -964.98, wy = 283.43, map = 1456 },
  { spell = 3561, fac = "Alliance", cont = 0, wx = -9003.46, wy = 870.03, map = 1453 },
  { spell = 3562, fac = "Alliance", cont = 0, wx = -4613.62, wy = -915.38, map = 1455 },
  { spell = 3565, fac = "Alliance", cont = 1, wx = 9660.81, wy = 2513.64, map = 1457 },
}
local teleCache, teleAt = nil, -99
local function OwnTeles()
  if teleCache and GetTime() - teleAt < 30 then return teleCache end
  teleCache, teleAt = {}, GetTime()
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local runes = ns.Api.GetItemCount and ns.Api.GetItemCount(17031) or 0
  if runes <= 0 then return teleCache end
  for _, p in ipairs(TELES) do
    local known = p.fac == fac and ((IsPlayerSpell and IsPlayerSpell(p.spell)) or (IsSpellKnown and IsSpellKnown(p.spell)))
    if known then
      local m = ns.db and type(ns.db.naviPortal) == "table" and ns.db.naviPortal[p.spell]
      local node
      if type(m) == "table" and m[1] and m[2] and m[3] then
        local c, wx, wy = World(m[1], m[2], m[3])
        if c then node = { map = m[1], x = m[2], y = m[3], cont = c, wx = wx, wy = wy } end
      end
      if not node and C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D then
        local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, p.cont, CreateVector2D(p.wx, p.wy), p.map)
        if ok and pos then
          local x, y = pos:GetXY()
          local c, wx, wy = World(p.map, x, y)
          if c then node = { map = p.map, x = x, y = y, cont = c, wx = wx, wy = wy } end
        end
      end
      if node then
        node.name = (ns.ZoneName and ns.ZoneName(p.map)) or "?"
        node.spell = p.spell -- 20.3o (Log 20.3m M4): Zauber fuer den Klick Knopf unter dem Pfeil
        teleCache[#teleCache + 1] = node
      end
    end
  end
  return teleCache
end

function ns.TravelBest(a, b, speed)
  speed = speed or (ns.PlanSpeed and ns.PlanSpeed()) or ns.speed or 7
  local best, bf, bt, bl, bs
  local ft, ffa, ffb = FlyBest(a, b, speed)
  if ft then best, bf, bt, bl, bs = ft, ffa, ffb, FLY, "a" end
  -- Teleport: am Ort zaubern (Abflug = a), dann vom Ziel der Stadt weiter
  for _, tn in ipairs(OwnTeles()) do
    if tn.cont == b.cont then
      local t = TELE_CAST + LOAD + Dist(b, tn) / speed
      if not best or t < best then
        local from = { map = a.map, x = a.x, y = a.y, cont = a.cont, wx = a.wx, wy = a.wy, name = TR"hier" }
        best, bf, bt, bl, bs = t, from, tn, TELE, "a"
      end
    end
  end
  for _, l in ipairs(LINKS) do
    local ea, eb
    if Usable(l) then ea, eb = Endpoint(l.a), Endpoint(l.b) end
    if ea and eb then
      for s = 1, 2 do
        local from, to, side = ea, eb, "a"
        if s == 2 then from, to, side = eb, ea, "b" end
        if from.cont == a.cont and to.cont == b.cont then
          local t = Dist(a, from) / speed + Rtt(l) / 2 + Ride(l, side) + LOAD + Dist(b, to) / speed
          if not best or t < best then best, bf, bt, bl, bs = t, from, to, l, side end
        end
      end
    end
  end
  return best, bf, bt, bl, bs
end

-- als Laufstrecke in Yards (fuer Rechnungen, die Strecke durch Tempo teilen)
function ns.TravelYards(a, b, speed)
  speed = speed or ns.speed or 7
  local t = ns.TravelBest(a, b, speed)
  return t and t * speed or nil
end

-- von welchen Kontinenten kommt man wohin
function ns.TravelReach(fromCont)
  local out = { [fromCont] = true }
  local changed = true
  while changed do
    changed = false
    for _, l in ipairs(LINKS) do
      local ea, eb
      if Usable(l) then ea, eb = Endpoint(l.a), Endpoint(l.b) end
      if ea and eb then
        if out[ea.cont] and not out[eb.cont] then out[eb.cont] = true; changed = true end
        if out[eb.cont] and not out[ea.cont] then out[ea.cont] = true; changed = true end
      end
    end
  end
  return out
end

-- 17.9 Tiefenbahn Rattenjagd (Monty, Wunsch Sascha): nur mitnehmen, wenn die Route sowieso mit der Bahn faehrt und
-- das Level passt. Monty steht am Bahnsteig Eisenschmiede (Nipsy laut Questtext am Depot Sturmwind). Questie kennt in
-- der Bahn keine Koordinaten, darum gibt es dort keinen Pfeil: die Schritte sagen genau, wo es ist.
local TRAM_Q = 6661
local function QDone(q)
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  if c and c[q] then return true end
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompleted, q)
    if ok and v then return true end
  end
  return false
end
local function QInLog(q)
  if C_QuestLog and C_QuestLog.GetLogIndexForQuestID then
    local ok, i = pcall(C_QuestLog.GetLogIndexForQuestID, q)
    if ok and i and i > 0 then return true end
  end
  if GetQuestLogIndexByID then
    local ok, i = pcall(GetQuestLogIndexByID, q)
    if ok and i and i > 0 then return true end
  end
  return false
end
-- Aktionen fuer den Bahn Schritt (vor der Fahrt selbst), dazu Quest Nummer und Quest Level. nil: passt nicht
function ns.TramQuestActs(L, used)
  if used and used[TRAM_Q] then return nil end
  if MyFaction() ~= "Alliance" then return nil end
  local qdb = ns.QDBAccess and ns.QDBAccess()
  if not (qdb and qdb.QueryQuestSingle) then return nil end
  local function Q(k) local ok, v = pcall(qdb.QueryQuestSingle, TRAM_Q, k); if ok then return v end end
  local name = Q("name")
  if not name then return nil end
  local rl, ql = tonumber(Q("requiredLevel")) or 10, tonumber(Q("questLevel")) or 12
  L = math.floor(L or 1)
  if L < rl or L > ql + 3 then return nil end
  if QDone(TRAM_Q) then return nil end
  local acts = {}
  if not QInLog(TRAM_Q) then acts[#acts + 1] = { k = "A", qid = TRAM_Q, quest = name, who = "Monty", tram = true } end
  acts[#acts + 1] = { k = "O", qid = TRAM_Q, quest = name, tram = true }
  acts[#acts + 1] = { k = "T", qid = TRAM_Q, quest = name, who = "Monty", tram = true }
  return acts, TRAM_Q, ql
end
-- in der Tiefenbahn (eigene Karte ohne Position, Instanz 369)
function ns.InTram()
  if not GetInstanceInfo then return false end
  local _, _, _, _, _, _, _, id = GetInstanceInfo()
  return id == 369
end

-- Beschreibung einer Reise: Art, von, nach
function ns.TravelDesc(l, side, from, to)
  if l and l.id == "fly" then return TR"Flug", from and from.name or "?", to and to.name or "?" end
  if l and l.id == "tele" then return TR"Teleport", from and from.name or "?", to and to.name or "?" end
  if l and l.a then
    local f, t = l.a, l.b
    if side == "b" then f, t = l.b, l.a end
    return l.kind, f[4], t[4]
  end
  return ns.TravelText(l.id, side)
end

function ns.TravelText(linkId, side)
  for _, l in ipairs(LINKS) do
    if l.id == linkId then
      local from, to = l.a, l.b
      if side == "b" then from, to = l.b, l.a end
      return l.kind, from[4], to[4], to[1]
    end
  end
end

function ns.HasNauticus() return Naut() ~= nil end

------------------------------------------------------------
-- Haefen lernen: beim Mitfahren merken, wo man eingestiegen und ausgestiegen ist
------------------------------------------------------------
local lastInst, lastTyp, idle, idleSince, lastPos = nil, nil, {}, 0, nil
local arriveMap, arriveUntil -- nach der Ankunft: erster kurzer Halt in der Zone ist der Steg
local function Inst()
  local _, typ, _, _, _, _, _, id = GetInstanceInfo()
  return id, typ
end
-- Ruhestein, Rueckruf oder Portal: dann war der Wechsel keine Fahrt mit Schiff oder Zeppelin
local portedAt = -999
do
  local pf = CreateFrame("Frame")
  ns.RegEv(pf, "UNIT_SPELLCAST_SUCCEEDED")
  pf:SetScript("OnEvent", function(_, _, unit, _, spellID)
    if unit == "player" and (spellID == 8690 or spellID == 556 or spellID == 3567 or spellID == 3566 or spellID == 3563
      or spellID == 3565 or spellID == 3562 or spellID == 3561 or spellID == 18960) then portedAt = GetTime() end
  end)
end

local function Learn(map, x, y)
  if not (ns.db and map and x) then return end
  local need = ns.TravelNeedDocks()
  if not (need and need[map]) then return end
  ns.db.docks = ns.db.docks or {}
  if ns.db.docks[map] then return end
  ns.db.docks[map] = { x, y }
  ns.TravelResetCache()
  ns.Print((TR"Hafen gelernt: %s"):format(ns.ZoneName and ns.ZoneName(map) or tostring(map)))
end

ns.Ticker(1, function()
  if not ns.db then return end
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  if lastPos and lastPos[1] == map and math.abs(lastPos[2] - x) < 0.001 and math.abs(lastPos[3] - y) < 0.001 then
    idleSince = idleSince + 1
    if idleSince >= 5 then idle[map] = { x, y } end -- steht still, z.B. am Steg
    if arriveMap == map and idleSince >= 3 and GetTime() < arriveUntil then
      Learn(map, x, y)
      arriveMap = nil
    end
  else
    idleSince = 0
  end
  lastPos = { map, x, y }
end)

local f = CreateFrame("Frame")
ns.RegEv(f, "PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function()
  local inst, typ = Inst()
  local fromMap = lastPos and lastPos[1]
  -- nur zwischen Kontinenten in der offenen Welt (kein Dungeon, keine Tiefenbahn, kein Ruhestein oder Portal)
  local world = (typ == nil or typ == "none") and (lastTyp == nil or lastTyp == "none")
  local ported = GetTime() - portedAt < 60
  -- offene Welt: Kalimdor, Oestliche Koenigreiche und die neuen Forever Inseln (eigene Karten), nur die Tiefenbahn nicht
  local tram = { [369] = true }
  if world and not ported and lastInst and inst and inst ~= lastInst and fromMap and not tram[inst] and not tram[lastInst] then
    -- Kontinent gewechselt: wo wir zuletzt gewartet haben, war der Hafen
    local w = idle[fromMap]
    if w then Learn(fromMap, w[1], w[2]) end
    C_Timer.After(2, function()
      arriveMap = ns.PlayerMap and ns.PlayerMap()
      arriveUntil = GetTime() + 180
    end)
  end
  lastInst, lastTyp = inst, typ
end)

-- Abklingzeit vom Ruhestein messen (Forever kann sie anders haben als Classic)
local hf = CreateFrame("Frame")
ns.RegEv(hf, "UNIT_SPELLCAST_SUCCEEDED")
hf:SetScript("OnEvent", function(_, _, unit, _, spellID)
  if unit ~= "player" then return end
  spellID = ns.Api.Num(spellID)
  -- 1.2i (P68): Ruhestein oder Rueckruf benutzt (fuer das Navi: erst dann ist der Ruhestein Schritt erledigt)
  if spellID == 556 or spellID == 8690 then ns.portUsedAt = GetTime() end
  if spellID == 556 then
    -- Astraler Rueckruf (Schamane): eigene Abklingzeit messen
    C_Timer.After(1, function()
      if not (ns.db and ns.Api.GetSpellCooldown) then return end
      local _, dur = ns.Api.GetSpellCooldown(556)
      if dur and dur > 60 then ns.db.recallCD = dur end
    end)
    return
  end
  if spellID ~= 8690 then return end
  -- selbst merken, wann er benutzt wurde: manche Clients melden die Abklingzeit nicht (Tester: Route wollte den Ruhestein auf Abklingzeit)
  if ns.db then ns.db.hearthUsedAt = time and time() or nil end
  C_Timer.After(1, function()
    if not (ns.db and ns.Api.GetItemCooldown) then return end
    local _, dur = ns.Api.GetItemCooldown(6948)
    if dur and dur > 60 then ns.db.hearthCD = dur end
  end)
end)

-- Ruhestein: wie lange noch Abklingzeit (Sekunden). Vom Spiel und selbst gemerkt, der laengere Wert zaehlt
function ns.HearthLeft()
  local left = 0
  -- 1.2i (P68): Abklingzeit nur ueber ns.Api (geheime Werte werden 0, dann zaehlt die eigene Messung unten)
  if ns.Api.GetItemCooldown then
    local st, dur = ns.Api.GetItemCooldown(6948)
    if st and st > 0 and dur and dur > 1.5 then left = math.max(0, st + dur - GetTime()) end
  end
  local db = ns.db
  local used = db and db.hearthUsedAt
  if used and time then
    local own = used + (db.hearthCD or 3600) - time()
    if own > left then left = own end
  end
  return math.max(0, left)
end

-- 17.4 fuer das Navi (Navi.lua): dieselben Bausteine wie die Planung
ns.TravelNautTimes, ns.TravelRide, ns.TravelRtt, ns.TravelUsable, ns.TravelFlightPoints = NautTimes, Ride, Rtt, Usable, FlightPoints
ns.TRAVEL = { LOAD = LOAD, FLY_SPEED = FLY_SPEED, FLY_OVER = FLY_OVER, PATH = PATH }
