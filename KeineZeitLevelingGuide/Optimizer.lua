local ADDON, ns = ...
local TR = ns.TR
-- Level: das echte (oder das Test Level). Beim Vorausrechnen des Fahrplans nimmt die Planung ns.simLevel.
local function UnitLevel(u)
  if ns.UnitLevel then return ns.UnitLevel(u) end
  return _G.UnitLevel(u)
end

-- Optimierte Route: rechnet Quest fuer Quest mit den echten Questie Daten
-- (Quest XP, Mindestlevel, Vorquests, Questgeber, Abgabe, wo Mobs/Objekte/Drops sind)
-- eine moeglichst schnelle Reihenfolge aus: Annehmen, Ziele, Abgeben.
--
-- Ablauf (alles in Haeppchen ueber mehrere Frames, damit es nicht ruckelt):
--   1. Kandidaten sammeln: Quests in den Zonen, die laut Plan fuer die naechsten Level dran sind
--   2. Pro Quest die Schritte bauen: Annehmen, Ziele (dichteste Stelle), Abgeben, mit Zeit
--   3. Quests nach Nutzen einfuegen, wo sie am wenigsten Umweg kosten (Reihenfolge und Level beachten)
--   4. Reihenfolge verbessern (Or-opt), bis nichts mehr Zeit spart
--   5. Level und XP Schritt fuer Schritt simulieren, gleiche Orte zu einem Stopp zusammenfassen

local QDB, ZDB, QLib, QPlayer, XPDB

-- Lange Schleifen in den Rechen Phasen: nach ca 12 ms das Bild freigeben und im naechsten Bild weiter
-- (die Phasen laufen als Coroutine, siehe Later). Ausserhalb davon macht Tick nichts.
local coActive, coFrame = false, 0
-- Rechen Zeit pro Bild: normal 12 ms, "schwacher PC" 5 ms. Ruckelt es trotzdem (Bild dauert lange), wird
-- es von selbst weniger (bis 3 ms) und bleibt fuer das naechste Mal gemerkt.
local coBudget = 12
function ns.CalcMs()
  local db = ns.db
  local base = (db and db.slowPC) and 5 or 12
  local m = math.min(base, coBudget, (db and db.calcMs) or 99)
  return math.max(3, m)
end
local function Tick()
  if coActive and debugprofilestop and debugprofilestop() - coFrame > ns.CalcMs() and not ns.coNoYield then
    coActive = false
    coroutine.yield()
  end
end
local areaUi = {}
local busy, busyAt
-- Grind Pausen erst ab diesem Level (vorher nur, wenn gar keine Quest geht)
local GRIND_MIN_L = 10

------------------------------------------------------------
-- Datenzugriff
------------------------------------------------------------
-- Questie noch nicht geholt (zB Abschnitt laden direkt nach dem Einloggen, bevor einmal gerechnet wurde): jetzt holen,
-- ohne Questie nil statt Fehler (vorher: "attempt to index upvalue QDB")
local function DBX()
  if not QDB and ns.QDBAccess then QDB = (ns.QDBAccess()) end
  return QDB
end
local function Q(id, k)
  local d = DBX(); if not d then return end
  local ok, v = pcall(d.QueryQuestSingle, id, k)
  if not ok then return end
  -- 19.33 (Daten Korrektur vorquest_fehlt): zusaetzliche Vorquests, ODER mit denen von Questie
  if k == "preQuestSingle" and ns.DKPreSingle then return ns.DKPreSingle(id, v) end
  if k == "preQuestGroup" and ns.DKPreGroup then return ns.DKPreGroup(id, v) end -- 19.34 (vorquest_1934): negative Id
  return v
end
-- 19.33b (Pruefer 09:42 MITTEL 2): Questie Wert ohne die Daten Korrektur (fuer die Pruefung "Questie: nicht machbar")
local function QRaw(id, k) local d = DBX(); if not d then return end local ok, v = pcall(d.QueryQuestSingle, id, k); if ok then return v end end
local function N(id, k) local d = DBX(); if not d then return end local ok, v = pcall(d.QueryNPCSingle, id, k); if ok then return v end end
-- 18.1: Ziele einer Quest als kurzer Text (Mobs, Gegenstaende in der Welt, Items). Zwei Quests mit gleichem Namen beim
-- gleichen NPC sind nur dann dieselbe Quest (Zwilling), wenn auch die Ziele gleich sind. Sonst zb "Arugal's Folly":
-- vier Teile einer Kette und eine eigene Forever Quest, alle bei Dalar Dawnweaver, jede mit anderen Zielen
local function ObjSig(id)
  local ob = Q(id, "objectives")
  if type(ob) ~= "table" then return nil end
  local parts, any = {}, false
  for k = 1, 3 do
    local ids = {}
    local l = ob[k]
    if type(l) == "table" then
      for _, c in ipairs(l) do if type(c) == "table" and c[1] then ids[#ids + 1] = tostring(c[1]); any = true end end
    end
    table.sort(ids)
    parts[k] = table.concat(ids, ",")
  end
  return any and table.concat(parts, "|") or nil
end
-- false nur, wenn beide Ziele kennen und sie verschieden sind (ohne Daten lieber wie bisher)
local function SameObjs(a, b)
  local s1, s2 = ObjSig(a), ObjSig(b)
  return not (s1 and s2 and s1 ~= s2)
end
ns.OptSameObjs = SameObjs
local function O(id, k)
  local d = DBX()
  if not (d and d.QueryObjectSingle) then return end
  local ok, v = pcall(d.QueryObjectSingle, id, k); if ok then return v end
end
local function I(id, k)
  local d = DBX()
  if not (d and d.QueryItemSingle) then return end
  local ok, v = pcall(d.QueryItemSingle, id, k); if ok then return v end
end

local function Ui(area)
  local u = areaUi[area]
  if u == nil then
    local ok, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
    u = (ok and ui) or false
    areaUi[area] = u
  end
  return u or nil
end

-- Weltposition (Yards) eines Kartenpunkts; nil wenn unbekannt
-- Elite Quests allein: so viele Level ueber dem Quest Level
local ELITE_SOLO = 6
-- 19.31 (Sascha 23:35): Elite Gegner allein erst, wenn sie mindestens so viele Level unter dir sind (lernt ab 19.32 mit)
local ELITE_MOB_GAP = 2

local function World(map, x, y)
  if ns.MapWorld then return ns.MapWorld(map, x, y) end
  if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok, cont, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if not ok or not w then return end
  local wx, wy = w:GetXY()
  return cont, wx, wy
end

-- Spawn Liste {[area] = {{x,y},..}} auf erlaubte Karten (Staedte in die Zone umgerechnet)
-- 19.11 (Sascha): welche Gegner stehen am Zielort? Fuer Quests ohne Kills (Kisten, Pflanzen, Orte) zaehlen die Mobs dort
-- auch. Pro Zone einmal ein Raster aus den feindlichen Mobs (ns.hostileIds, nur normale): pro Feld Summe der Level
-- (Mitte von min und max) und Anzahl. Nur im Speicher, nicht in den gespeicherten Daten.
local AREA_CELL = 0.025
local areaGrid = {}
local function AreaGrid(ui)
  local g = areaGrid[ui]
  if g ~= nil then return g or nil end
  -- 19.29 (Sascha Teil 1 Punkt 3): Zonen mit Gelaende Karte: feindliche Mobs pro Feld aus der Karte (Werkzeug gH / gA),
  -- statt bei jedem Einloggen aus Questie. Normale Mobs (ohne Elite), Level wie in der Karte (Mittel pro Feld)
  local KA = ns.Karte
  local fac = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
  local mg = KA and KA.MobGrid and KA.MobGrid(ui, fac)
  if mg then
    g = { s = {}, n = {} }
    for k, n in pairs(mg.n) do
      local nn, lv = n - (mg.e[k] or 0), mg.lv[k] or 0
      if nn > 0 and lv > 1 then
        local key = math.floor((k % 100) / 2) * 1000 + math.floor(math.floor(k / 100) / 2)
        g.s[key] = (g.s[key] or 0) + lv * nn
        g.n[key] = (g.n[key] or 0) + nn
      end
    end
    areaGrid[ui] = g
    return g
  end
  local list = ns.hostileIds and ns.hostileIds[ui]
  if not list then return nil end -- Dienste noch nicht fertig: spaeter nochmal
  g = { s = {}, n = {} }
  for i, id in ipairs(list) do
    if i % 20 == 0 then Tick() end
    local mx = tonumber(N(id, "maxLevel")) or 0
    if mx > 1 and (tonumber(N(id, "rank")) or 0) == 0 then
      local mn = tonumber(N(id, "minLevel")) or mx
      local lv = (math.min(mn, mx) + mx) / 2
      local sp = N(id, "spawns")
      for area, coords in pairs(type(sp) == "table" and sp or {}) do
        if Ui(area) == ui and type(coords) == "table" then
          for k, c in ipairs(coords) do
            if k > 80 then break end
            if type(c) == "table" and c[1] and c[1] > 0 and c[2] then
              local key = math.floor(c[1] / 100 / AREA_CELL) * 1000 + math.floor(c[2] / 100 / AREA_CELL)
              g.s[key] = (g.s[key] or 0) + lv
              g.n[key] = (g.n[key] or 0) + 1
            end
          end
        end
      end
    end
  end
  areaGrid[ui] = g
  return g
end
-- typisches Level der Mobs im Umkreis von ca 150 Yards, nil wenn dort (fast) keine stehen
local function AreaMobLevel(ui, x, y)
  local g = ui and x and y and AreaGrid(ui)
  if not g then return nil end
  local cx, cy = math.floor(x / AREA_CELL), math.floor(y / AREA_CELL)
  local s, n = 0, 0
  for dx = -1, 1 do
    for dy = -1, 1 do
      local k = (cx + dx) * 1000 + cy + dy
      if g.n[k] then s, n = s + g.s[k], n + g.n[k] end
    end
  end
  if n < 3 then return nil end
  return s / n, n
end
ns.OptAreaMobLevel = AreaMobLevel

-- 20.3v (Punkt 26 Tausend Nadeln, K 09:56): Fundorte, die zu Fuss nicht erreichbar sind (unter der Klippe, im Berg,
-- abseits vom Netz), fallen raus, wie beim Angeln (Karte ReachPoint). Wasser bleibt (Mobs und Objekte unter Wasser).
-- Bleibt fuer ein Ziel kein Fundort uebrig, gelten alle wie bisher (nie schlechter als ohne Filter)
local REACH_DROP_YD = 40
local function Reachable(m, x, y)
  local KA = ns.Karte
  if not (KA and KA.HasZone and KA.HasZone(m)) then return true end
  -- 20.3x (K 14:13 Ruckler): schnelle Fassung, je Zone einmal geflutet, danach nur nachschauen
  if KA.ReachOK then local ok, r = pcall(KA.ReachOK, m, x, y); if ok then return r and true or false end end
  if not KA.ReachPoint then return true end
  local ok, rx, _, rd, why = pcall(KA.ReachPoint, m, x, y)
  if not ok or not rx then return true end
  if why == "wasser" then return true end
  return not (rd and rd > REACH_DROP_YD)
end
ns.OptReachable = Reachable

local function Spawns(sp, allowed, out, maxPer)
  out = out or {}
  local n0 = #out
  for area, coords in pairs(type(sp) == "table" and sp or {}) do
    local ui = Ui(area)
    if ui and type(coords) == "table" then
      local target = ui
      if not allowed[ui] then
        local parent = ns.cityParent and ns.cityParent[ui]
        target = (parent and allowed[parent]) and parent or nil
      end
      if target then
        for k, c in ipairs(coords) do
          if maxPer and k > maxPer then break end
          if type(c) == "table" and c[1] and c[1] > 0 then
            local x, y = c[1] / 100, c[2] / 100
            if target ~= ui and ns.ToMap then x, y = ns.ToMap(ui, x, y, target) end
            if x then table.insert(out, { target, x, y }) end
          end
        end
      end
    end
  end
  -- 20.3v: unerreichbare Fundorte raus, nur wenn welche uebrig bleiben
  if #out > n0 then
    local keep = {}
    for i = n0 + 1, #out do
      local p = out[i]
      if Reachable(p[1], p[2], p[3]) then keep[#keep + 1] = p end
    end
    if #keep > 0 and #keep < #out - n0 then
      for i = #out, n0 + 1, -1 do out[i] = nil end
      for _, p in ipairs(keep) do out[#out + 1] = p end
    end
  end
  return out
end

-- beste Stelle fuer ein Ziel: dicht beieinander und gross genug fuer die noetige Zahl, auf einer Karte.
-- Das Gebiet passt sich an: ein dichtes Lager bleibt klein, verstreute Mobs ergeben ein groesseres Gebiet.
-- Bei gleich vielen Fundorten die Karte der Quest bevorzugen (ein Boss mit Spawn in zwei Zonen
-- landete sonst zufaellig in der falschen, zb Mulgore Quest im Brachland)
-- Allein (keine Gruppe, keine Elite Quest): Stellen nahe bei Elite Mobs meiden, nie in Elite Gruppen schicken.
local densePrefer
-- Fahrplan Simulation: spaetere Abschnitte kennen die Taschen, Abklingzeiten und den Ort von jetzt nicht
local SIMLATE, SIMMAP = false, nil
local DENSE = { solo = false, L = 1 }
local function SetDense(L)
  DENSE.solo = not (IsInGroup and IsInGroup()) and not (ns.db and ns.db.eliteSolo)
  DENSE.L = L or ns.simLevel or (UnitLevel and UnitLevel("player")) or 1
end
ns.OptSetDense = SetDense
-- Elite Lager in der Naehe: mindestens 3 Elite Mobs im Umkreis von etwa 90 Yards, nicht weit unter dir
-- (einzelne seltene Elite laufen herum, davor warnt der Pfeil, sie sind kein Grund fuer ein anderes Gebiet)
local function EliteCamp(map, x, y, L)
  if not (ns.Ways and ns.Ways.EliteNear) then return nil end
  local lv, n = ns.Ways.EliteNear(map, x, y, 2)
  if lv and n >= 3 and lv >= (L or DENSE.L) - 2 then return lv end
end
ns.OptEliteCamp = EliteCamp
local function EliteNearPt(map, x, y)
  if not DENSE.solo then return nil end
  return EliteCamp(map, x, y)
end
local function Densest(list, need)
  need = need or 6
  local byMap = {}
  for _, p in ipairs(list) do
    byMap[p[1]] = byMap[p[1]] or {}
    table.insert(byMap[p[1]], p)
  end
  local best, bs, bc
  local raw, rs
  local cap = need + 2
  for _, l in pairs(byMap) do
    local n = math.min(#l, 60)
    for i = 1, n do
      Tick()
      local a = l[i]
      local c3, c5, c8 = 0, 0, 0
      for j = 1, n do
        local b = l[j]
        local d2 = (a[2] - b[2]) ^ 2 + (a[3] - b[3]) ^ 2
        if d2 < 0.0064 then
          local w = b.w or 1
          c8 = c8 + w
          if d2 < 0.0025 then c5 = c5 + w; if d2 < 0.0009 then c3 = c3 + w end end
        end
      end
      -- genug Mobs pro Weg: klein und dicht schlaegt gross und verstreut
      local sc, r, cn = math.min(c5, cap) / 0.07, 0.05, c5
      local s3, s8 = math.min(c3, cap) / 0.05, math.min(c8, cap) / 0.10
      if s3 > sc then sc, r, cn = s3, 0.03, c3 end
      if s8 > sc * 1.1 then sc, r, cn = s8, 0.08, c8 end
      sc = sc + c5 * 0.01
      if a[1] == densePrefer then sc = sc * 1.05 + 0.5 end
      if ns.dbgElite and (not rs or sc > rs) then raw, rs = a, sc end
      if EliteNearPt(a[1], a[2], a[3]) then sc = sc * 0.2 end
      if not bs or sc > bs then best, bs, bc = a, sc, { c3, c5, c8 } end
    end
  end
  if ns.dbgElite and raw and raw ~= best then
    local e = ns.dbgElite
    e.n = (e.n or 0) + 1
    e[#e + 1] = { raw[1], raw[2], raw[3], best[1], best[2], best[3], (ns.Ways.EliteNear(raw[1], raw[2], raw[3], 2)) }
  end
  -- Jagdgebiet: das kleinste, in dem genug Mobs fuer die Zahl stehen
  local br, bcnt = 0.08, bc and bc[3] or 1
  if bc then
    if bc[1] >= need then br, bcnt = 0.03, bc[1] elseif bc[2] >= need then br, bcnt = 0.05, bc[2] end
  end
  -- alle Fundorte im Gebiet: der Pfeil geht spaeter von einem zum naechsten
  local mem = {}
  if best then
    local r2 = (br * 1.2) ^ 2
    for _, b in ipairs(byMap[best[1]]) do
      if #mem >= 40 then break end
      if (best[2] - b[2]) ^ 2 + (best[3] - b[3]) ^ 2 < r2 then table.insert(mem, { b[2], b[3] }) end
    end
  end
  return best, mem, br, bcnt
end
ns.OptDensest = Densest

-- Zeit pro Kill nach Dichte: weit verstreut dauert laenger (laufen), sehr dicht etwas kuerzer.
-- Bei 55 Yards Abstand bleibt es wie gemessen (so dicht stehen Quest Mobs im Schnitt). Viel zu wenige Fundorte: warten auf Respawn.
local function DensityFactor(best, r, cnt, need, unit)
  if not best or (ns.FLOW and ns.FLOW.dens == false) then return 1 end
  local zy = ns.ZoneYards and ns.ZoneYards(best[1])
  local yd = zy and (zy[1] + zy[2]) / 2 or 3500
  local spacing = 0.5 * r * yd * math.sqrt(math.pi / math.max(1, cnt))
  local f = (unit + 2 * spacing / 7) / (unit + 2 * 55 / 7)
  -- weniger Mobs dort als gebraucht: auf Respawns warten (Tester Log: 12 Familiare, oft 1 bis 2 Min Warten pro Kill)
  if cnt < need then f = f * (1 + 0.5 * math.min(1, (need - cnt) / need)) end
  if f < 0.85 then f = 0.85 elseif f > 1.6 then f = 1.6 end
  return f
end
ns.OptDensityFactor = DensityFactor

------------------------------------------------------------
-- Quest XP wie im Spiel (Questie Daten, Abzug bei hoeherem Spielerlevel)
------------------------------------------------------------
local function QuestXPAt(qid, ql, L)
  if L >= 60 then return 0 end
  local d = XPDB and XPDB[qid]
  local qLevel, xp
  local sv = not (type(d) == "table" and d[2] and d[2] > 0) and ns.ServerQuest and ns.ServerQuest(qid)
  if type(d) == "table" and d[1] and d[1] > 0 and d[2] and d[2] > 0 then
    qLevel, xp = d[1], d[2]
  elseif sv and tonumber(sv[3]) and sv[3] > 0 then
    -- 19.31: Questie kennt die Quest nicht, die Server Daten 1.12 schon
    qLevel, xp = tonumber(sv[1]) or ql or L, sv[3]
  else
    qLevel = ql or L
    xp = 65 * qLevel + 2 * qLevel * qLevel -- Schaetzung, falls keine Daten
  end
  local m = 2 * (qLevel - L) + 20
  if m < 1 then m = 1 elseif m > 10 then m = 10 end
  xp = xp * m / 10
  if xp <= 100 then xp = 5 * math.floor((xp + 2) / 5)
  elseif xp <= 500 then xp = 10 * math.floor((xp + 5) / 10)
  elseif xp <= 1000 then xp = 25 * math.floor((xp + 12) / 25)
  else xp = 50 * math.floor((xp + 25) / 50) end
  return xp
end
ns.QuestXPAt = QuestXPAt

-- Grund XP einer Quest (fuer die Gold Schaetzung auf Maximallevel)
function ns.QuestBaseXP(qid, ql)
  local d = XPDB and XPDB[qid]
  if not (type(d) == "table" and d[2] and d[2] > 0) then
    -- 19.31: sonst aus den Server Daten 1.12
    local sv = ns.ServerQuest and ns.ServerQuest(qid)
    d = sv and tonumber(sv[3]) and sv[3] > 0 and { tonumber(sv[1]), sv[3] } or nil
  end
  if type(d) == "table" and d[2] and d[2] > 0 then
    local qLevel, xp = d[1] or ql or 60, d[2]
    local m = 2 * (qLevel - 60) + 20
    if m < 1 then m = 1 elseif m > 10 then m = 10 end
    return xp * m / 10, true
  end
  return nil
end

local function LevelAt(total)
  local L = 1
  for lv = 1, 60 do if (ns.xpTotal[lv] or 0) <= total then L = lv end end
  local cur, nxt = ns.xpTotal[L] or 0, ns.xpTotal[L + 1]
  if nxt and nxt > cur then return L + (total - cur) / (nxt - cur) end
  return L
end

------------------------------------------------------------
-- Schritte einer Quest bauen
------------------------------------------------------------
local ACC_SEC, TURN_SEC = 8, 8
-- 1.1: alle neuen Konstanten und Hilfen in einer Tabelle (Optimizer.lua ist nahe an 200 lokalen Namen)
local V11 = {}
-- 1.1 (P38, S 11:24): Rechnen sichtbar in Schritten. Stand in Prozent fuers Mini Fenster (nur steigend je Rechnung),
-- Mini Fenster hoechstens alle STAGE_HUD_S neu. Ein Rechen Stueck ueber LONG_STEP_MS kommt mit Phase ins Test Log
V11.STAGE_HUD_S = 0.5
V11.LONG_STEP_MS = 60
V11.LONG_STEP_LOG_MAX = 20
V11.stage = { gen = nil, pct = 0, at = 0 }
V11.longSteps = 0
function V11.Stage(gen, p0, p1, k, n)
  local st = V11.stage
  if st.gen ~= gen then st.gen = gen; st.pct = 0 end
  local p = p0 + (p1 - p0) * math.min(1, (k or 0) / math.max(1, n or 1))
  if p > st.pct then st.pct = p end
  ns.optPct = math.floor(st.pct)
  local now = GetTime and GetTime() or 0
  if ns.RefreshHud and now - st.at >= V11.STAGE_HUD_S then st.at = now; pcall(ns.RefreshHud) end
end
-- Gebiete fuer Grind Stellen einzeln analysieren (vorher alle auf einmal vor dem ersten Bild)
function V11.GrindTodo(list)
  while list and #list > 0 do
    Tick()
    ns.GrindList(table.remove(list))
  end
end
-- 1.1 (S Log: Annehmen/Abgeben im Dorf 35 s geschaetzt, echt bis 3 Min; 24 Schritte ueber 2x, fast alle A/T in Doerfern
-- und Staedten): Zuschlag fuer Questgeber in einer Stadt oder in einem Quest Hub (Daten ns.cityParent, ns.hubs), dort
-- kosten Suchen, Gebaeude und Treppen Zeit. Allgemein aus den Daten, keine Orts Liste
-- v11d (K 10:05, S 09:55): S Log Zeiten sind langsamer als normal (Berufe, Chat, volle Gebiete beim Start). Zuschlaege
-- darum klein, aus bereinigtem Median (Median Zusatz pro A/T lag bei 17 s, Schaetzung bei 18 s), Ausreisser zaehlen nicht
V11.HUB_EXTRA_SEC = 8        -- Questgeber in einem Quest Hub (Dorf)
V11.CITY_EXTRA_SEC = 15      -- Questgeber in einer Stadt
V11.HUB_RADIUS = 0.05        -- Kartenanteil, wie Quest.lua NearHub
V11.INDOOR_EXTRA_SEC = 12     -- Questgeber in einem Gebaeude oder auf anderer Hoehe (Stadt.lua innen, grund g/h)
V11.INDOOR_YD = 15            -- so nah an einem innen Punkt
-- 1.1 (K Stufe B 11): Zeitlimit. Schaetzung am Stueck: Annehmen, dann die Ziele (je der erste Ort), dann Abgeben,
-- Luftlinie mal Umweg Faktor plus die Zeiten der Knoten. Passt das nicht mit Reserve in das Limit, wird die Quest
-- nicht vorgeschlagen (Grund "Zeitlimit nicht schaffbar")
V11.REST_RETRY_MAX = 30         -- v11e: Nach 60 so oft ein leeres Stueck ueberspringen
V11.AREA_MIN_PTS = 4           -- v11d: ab so vielen Spawn Punkten zeigt der Pfeil auf Gebiete (vorher ueber 6)
V11.RUND_MIN_N = 8             -- 1.1: Gebiet mit so vielen Spawns ...
V11.RUND_MIN_R = 60            -- ... und so weit verteilt (yd) wird eine Runde
V11.RUND_MAX = 8               -- Punkte der Runde hoechstens
V11.RUND_CELL_YD = 35          -- v11f (P37): Spawns so nah zusammen sind ein Haufen (ein Punkt der Runde)
V11.AREA_STALE_S = 120         -- im Gebiet so lange kein Fortschritt: naechstes Gebiet
V11.ARROW_HOLD_S = 6           -- 1.1: Pfeil Ziel bei Questzielen hoechstens so oft wechseln (ausser erreicht)
-- 1.1 (P43, Pr Schluss 1.1f: Pfeil hin und her +25 %): Gebiet wechseln nur, wenn du gut drin bist (Anteil vom Radius) und
-- das letzte Wechseln ARROW_HOLD_S her ist. Live "andere Stelle" (Spot) hoechstens alle SPOT_HOLD_S und nicht gleich zurueck
V11.AREA_ENTER_F = 0.7
V11.SPOT_HOLD_S = 90
-- 1.1 (P42, Pr Schluss 1.1f: Nach 60 Neu rechnen 4771 und 3031 mal): auf Max Level ein neues Stueck nur, wenn die Route
-- abgearbeitet ist, hoechstens alle REST_MIN_GAP_S. Ist nichts mehr da, erst wieder nach einer angenommenen oder
-- abgegebenen Quest. Quests mit zu hohen Gegnern (gleiche Regel wie beim Ankommen) gar nicht ins Stueck
V11.REST_MIN_GAP_S = 60
V11.REST_FOE_UP = 3
V11.REST_QL_UP = 4
function V11.RestFoeHigh(q, L)
  if q.mobMax and q.mobMax - L >= V11.REST_FOE_UP then return true end
  if q.ql and q.ql - L >= V11.REST_QL_UP then return true end
  if q.eliteMob and not (IsInGroup and IsInGroup()) and q.eliteMob + ((ns.EliteGap and ns.EliteGap()) or 2) > L then return true end
  return false
end
V11.TIMER_SAFE = 0.75          -- hoechstens so viel vom Limit verplanen
V11.TIMER_DETOUR = 1.3         -- Umweg Faktor auf die Luftlinie
function V11.TimedTooLong(q)
  local lim = ns.QuestTimer and ns.QuestTimer(q.id)
  if not lim then return false end
  local sp = (ns.PlanSpeed and ns.PlanSpeed()) or ns.speed or 7
  local t, prev = 0, nil
  local order = {}
  if q.A then order[#order + 1] = q.A end
  for _, n in ipairs(q.nodes or {}) do if n ~= q.A and n ~= q.T then order[#order + 1] = n end end
  if q.T then order[#order + 1] = q.T end
  local seen = {}
  for _, n in ipairs(order) do
    local key = n.kind == "O" and (n.obj or n.idx or n) or n
    if not seen[key] then
      seen[key] = true
      if prev and prev.wx and n.wx and prev.cont == n.cont then
        t = t + math.sqrt((prev.wx - n.wx) ^ 2 + (prev.wy - n.wy) ^ 2) * V11.TIMER_DETOUR / sp
      end
      t = t + (n.dur or 0)
      prev = n
    end
  end
  return t > lim * V11.TIMER_SAFE
end
-- v11f (K P37): Runde aus den Spawn Haufen: Spawns nach Naehe buendeln (V11.RUND_CELL_YD), die dichtesten V11.RUND_MAX Haufen,
-- Reihenfolge als geschlossener Kreis (naechster Nachbar, dann 2 opt). Start beim Spieler macht Arrow.lua (RundNext)
function V11.RundLoop(list, Dist)
  local cl = {}
  for _, p in ipairs(list or {}) do
    local hit
    for _, c in ipairs(cl) do
      local d = Dist(c.x, c.y, p[1], p[2])
      if d and d <= V11.RUND_CELL_YD then hit = c; break end
    end
    if not hit then hit = { x = p[1], y = p[2], sx = 0, sy = 0, n = 0 }; cl[#cl + 1] = hit end
    hit.sx, hit.sy, hit.n = hit.sx + p[1], hit.sy + p[2], hit.n + 1
    hit.x, hit.y = hit.sx / hit.n, hit.sy / hit.n
  end
  table.sort(cl, function(a, b) return a.n > b.n end)
  local pts = {}
  for i = 1, math.min(#cl, V11.RUND_MAX) do pts[i] = { cl[i].x, cl[i].y } end
  local n = #pts
  if n < 3 then return nil end
  local D = {}
  for i = 1, n do D[i] = {}; for j = 1, n do D[i][j] = (i == j) and 0 or (Dist(pts[i][1], pts[i][2], pts[j][1], pts[j][2]) or 1e6) end end
  -- naechster Nachbar ab dem dichtesten Haufen
  local order, used = { 1 }, { [1] = true }
  for _ = 2, n do
    local last, bj, bd = order[#order], nil, nil
    for j = 1, n do if not used[j] and (not bd or D[last][j] < bd) then bj, bd = j, D[last][j] end end
    order[#order + 1] = bj; used[bj] = true
  end
  -- 2 opt auf dem geschlossenen Kreis
  local improved, guard = true, 0
  while improved and guard < 50 do
    improved, guard = false, guard + 1
    for i = 1, n - 1 do
      for k = i + 1, n do
        local a, b = order[i], order[i % n + 1]
        local c, d = order[k], order[k % n + 1]
        if b ~= c and a ~= d and D[a][c] + D[b][d] < D[a][b] + D[c][d] - 0.01 then
          local lo, hi = i + 1, k
          while lo < hi do order[lo], order[hi] = order[hi], order[lo]; lo, hi = lo + 1, hi - 1 end
          improved = true
        end
      end
    end
  end
  local loop = {}
  for _, i in ipairs(order) do loop[#loop + 1] = pts[i] end
  return loop
end
-- Staedte aus Stadt.lua (Ka): Rechteck in Welt Koordinaten und innen Punkte, einmal gesammelt
function V11.Cities()
  if V11.cityList then return V11.cityList end
  local cityList = {}
  V11.cityList = cityList
  local A = _G.FWW_AUTO_STADT
  local st = A and A.forever and A.forever.staedte
  for _, c in pairs(type(st) == "table" and st or {}) do
    if type(c) == "table" and type(c.rect) == "table" and #c.rect == 4 then cityList[#cityList + 1] = c end
  end
  return cityList
end
-- n: Knoten mit map, x, y, wx, wy
function V11.PlaceExtra(n)
  if not n then return 0 end
  if n.wx and n.wy then
    for _, c in ipairs(V11.Cities()) do
      local r = c.rect
      -- Stadt.lua hat Welt X Norden, Y Westen; je nach Karte sind die Achsen gegenueber MapWorld getauscht (wie Path torFlip)
      local wx, wy = n.wx, n.wy
      local inR = wx >= r[1] and wx <= r[3] and wy >= r[2] and wy <= r[4]
      if not inR and n.wy >= r[1] and n.wy <= r[3] and n.wx >= r[2] and n.wx <= r[4] then inR, wx, wy = true, n.wy, n.wx end
      if inR then
        for _, p in ipairs(c.innen or {}) do
          local dx, dy = wx - (p[1] or 1e9), wy - (p[2] or 1e9)
          if dx * dx + dy * dy <= V11.INDOOR_YD * V11.INDOOR_YD then return V11.CITY_EXTRA_SEC + V11.INDOOR_EXTRA_SEC end
        end
        return V11.CITY_EXTRA_SEC
      end
    end
  end
  local map, x, y = n.map, n.x, n.y
  if not (map and x and y) then return 0 end
  if ns.cityParent and ns.cityParent[map] then return V11.CITY_EXTRA_SEC end
  for _, h in ipairs(ns.hubs and ns.hubs[map] or {}) do
    local dx, dy = x - (h[1] or -9), y - (h[2] or -9)
    if dx * dx + dy * dy < V11.HUB_RADIUS * V11.HUB_RADIUS then return V11.HUB_EXTRA_SEC end
  end
  return 0
end

local function CountFromLog(prog, name)
  if not (prog and name) then return nil end
  for _, o in ipairs(prog.objs or {}) do
    if o.text and o.text:find(name, 1, true) then
      if o.done then return 0 end
      local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
      if a and b then return math.max(0, tonumber(b) - tonumber(a)) end
      return 1
    end
  end
end

-- Stueckzahl aus dem Aufgabentext von Questie ("Bringt 10 Bergpumapelze ..."), wenn die Quest noch nicht im Log ist
local function TextCount(qid, nm, single)
  local t = Q(qid, "objectivesText")
  if type(t) == "table" then t = table.concat(t, " ") end
  if type(t) ~= "string" or t == "" then return nil end
  if nm and nm ~= "" then
    local low = t:lower()
    local key = nm:lower():gsub("%s*%(.*%)$", "")
    local s = low:find(key:sub(1, math.min(#key, 12)), 1, true)
    if s then
      local num
      for n in low:sub(math.max(1, s - 40), s - 1):gmatch("(%d+)") do num = tonumber(n) end
      if num and num >= 1 and num <= 50 then return num end
    end
  end
  if single then
    local n = tonumber(t:match("(%d+)") or "")
    if n and n >= 1 and n <= 50 then return n end
  end
end

-- alle Zonen erlaubt (Haendler fuer Quest Items duerfen auch in einer anderen Zone stehen)
local ANY_ZONE = setmetatable({}, { __index = function() return true end })
-- 19.32: Sammel Ziel Ort bei den tiefsten passenden Droppern (siehe unten bei den Items)
local ITEM_LOW_GAP, ITEM_LOW_MIN = 3, 5
-- 20.3 (Log 01.11. 14:36, Spitzhauer echt 3.8x Plan): Gegner mit nur 1 bis 2 Fundorten (benannte Einzelne) sind oft
-- gerade tot oder muessen gesucht werden. Pro Kill so viele Sekunden Warten/Suchen dazu. Allgemein, ohne Mob Liste
local RARE_WAIT = 90
-- 19.32 (418 Thelsamar Blutwurst): welche 6 Dropper zaehlen? Bisher die ersten 6 aus Questie, deren Reihenfolge nur nach
-- Nummer geht (die Lauerer im Loch Modan standen auf Platz 15 und 16). Bei mehr als 6: nur Dropper mit einem Fundort in
-- den erlaubten Zonen, zuerst die bis zum Questlevel, dann bis Questlevel plus 2 (je mit den meisten Fundorten zuerst),
-- dann die uebrigen vom tiefsten Level aufwaerts. Bis 6 Dropper bleibt alles wie bisher
local function PickDroppers(list, allowed, ql, max)
  if type(list) ~= "table" or #list <= max or ns.dbgItemLowOff then return list end
  local c = {}
  for i, npc in ipairs(list) do
    local sp, n = N(npc, "spawns"), 0
    if type(sp) == "table" then
      for area, co in pairs(sp) do
        local ui = Ui(area)
        local par = ui and ns.cityParent and ns.cityParent[ui]
        if ui and (allowed[ui] or (par and allowed[par])) and type(co) == "table" then n = n + #co end
      end
    end
    if n > 0 then
      local lv = N(npc, "maxLevel") or N(npc, "minLevel")
      lv = type(lv) == "number" and lv or 0
      -- Stufe 1: hoechstens Questlevel, Stufe 2: bis Questlevel plus 2, Stufe 3: der Rest
      local qq = ql or 60
      c[#c + 1] = { npc = npc, n = n, lv = lv, i = i, t = lv <= qq and 1 or (lv <= qq + 2 and 2 or 3) }
    end
  end
  table.sort(c, function(a, b)
    if a.t ~= b.t then return a.t < b.t end
    if a.t < 3 then if a.n ~= b.n then return a.n > b.n end
    elseif a.lv ~= b.lv then return a.lv < b.lv end
    return a.i < b.i
  end)
  local out = {}
  for k = 1, math.min(max, #c) do out[k] = c[k].npc end
  return out
end
-- 19.33 (Pruefer 04:50 Punkt 4, Fall 418): dieselbe Wahl auch fuer die Kartenpunkte (QuestieBridge.lua ObjectivePoints)
ns.PickDroppers = PickDroppers
-- 20.3r: ab so vielen verschiedenen Droppern gilt ein Sammel Item als Zufall Drop (Alles: erst auf Max Level)
local RANDOM_DROP_N = 12
local function BuildQuest(qid, allowed, cont, inLog, prog)
  local name = Q(qid, "name") or (TR"Quest " .. qid)
  local okL, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
  if not okL then ql, rl = nil, nil end
  local q = { id = qid, name = name, ql = ql or 1, rl = rl or 1, inLog = inLog, nodes = {} }
  -- 19.32 (Daten 1 vom Daten Chat): Korrekturen zu dieser Quest (Dropper Ausreisser, Gegner die keine sind)
  local dq = ns.DKQuest and ns.DKQuest(qid)
  -- ueberspringen: allein nicht planen (zb Chasing A-Me 01, Item nur hergestellt oder von Elite in anderen Zonen)
  if dq and dq.skip and not inLog and not (IsInGroup and IsInGroup()) then
    if ns.DKLog then ns.DKLog("Quest", qid, "ueberspringen") end
    return nil
  end
  densePrefer = SIMMAP or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")) or nil
  SetDense()
  local killSec = ns.KillSeconds and ns.KillSeconds() or 28
  local any = setmetatable({}, { __index = function() return true end })
  -- 19.31 (Sim Rauchtest 19.30: Quellstein und Elite Funde): wer ist ein Gegner? Questie markiert auch neutrale Tiere
  -- (Ebenenschreiter, Rehe) als "freundlich zu beiden", die kann man aber angreifen. Kein Gegner ist nur, wer zu deiner
  -- Fraktion freundlich ist und kein neutrales Tier ist (nur eine Fraktion, oder ein NPC mit Diensten wie Lehrer)
  local myF = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
  local function IsFoe(npc)
    -- 19.32: kein_gegner_npc aus der Daten Korrektur (Sprech oder Benutz Ziel, das Questie als Gegner fuehrt)
    -- 19.33: auch NPCs, die nie ein Gegner sind (npc kein_gegner, zb 1140 Turm von Althalaxx)
    if ns.DKNoFoe and ns.DKNoFoe(qid, npc) then
      if ns.DKLog then ns.DKLog("Quest", qid, "kein_gegner_npc") end
      return false
    end
    local fr = N(npc, "friendlyToFaction")
    if type(fr) == "string" and fr:find(myF, 1, true) then
      local fl = N(npc, "npcFlags")
      if fr ~= "AH" or (type(fl) == "number" and fl ~= 0) then return false end
    end
    return true
  end
  local function IsElite(npc) local r = N(npc, "rank"); return r == 1 or r == 2 or r == 3 end
  local function EliteMob(lv) if lv and lv > (q.eliteMob or 0) then q.eliteMob = lv end end

  local function Node(kind, map, x, y, dur, extra)
    local c, wx, wy = World(map, x, y)
    if not c then return nil end
    -- cont: Zahl = nur dieser Kontinent, Tabelle = alle erreichbaren Kontinente
    if type(cont) == "number" and c ~= cont then return nil end
    if type(cont) == "table" and not cont[c] then return nil end
    local n = { q = q, kind = kind, map = map, x = x, y = y, wx = wx, wy = wy, dur = dur, cont = c }
    for k, v in pairs(extra or {}) do n[k] = v end
    return n
  end

  -- Laufweg eines herumlaufenden Mobs: ein paar Punkte davon zaehlen wie Fundorte (zusammen etwa zwei)
  local function AddPatrol(npc, out)
    local wp = N(npc, "waypoints")
    if type(wp) ~= "table" then return end
    local flat = {}
    for area, paths in pairs(wp) do
      if type(paths) == "table" then
        local pts = {}
        for _, path in ipairs(paths) do
          if type(path) == "table" and #path > 0 then
            local step = math.max(1, math.floor(#path / 6))
            for i = 1, #path, step do pts[#pts + 1] = path[i] end
          end
        end
        if #pts > 0 then flat[area] = pts end
      end
    end
    local n0 = #out
    Spawns(flat, allowed, out, 30)
    for j = n0 + 1, #out do out[j].w = 0.35; out[j].patrol = true end
  end

  -- Annehmen
  if not inLog then
    local sb = Q(qid, "startedBy")
    local npc = sb and sb[1] and sb[1][1]
    local obj = sb and sb[2] and sb[2][1]
    local pts, who = {}, nil
    if npc then Spawns(N(npc, "spawns"), allowed, pts, 3); who = N(npc, "name") end
    if #pts == 0 and obj then Spawns(O(obj, "spawns"), allowed, pts, 3); who = O(obj, "name") end
    local p = pts[1]
    if not p then return nil end
    local n = Node("A", p[1], p[2], p[3], ACC_SEC, { who = who or "?", npc = npc })
    if not n then return nil end
    n.dur = n.dur + V11.PlaceExtra(n)
    q.A = n
    densePrefer = n.map
    table.insert(q.nodes, n)
  end

  -- Ziele
  local objs = Q(qid, "objectives")
  local killXP = 0
  local function Obj(nm, list, count, unit, isKill, npcs, wait)
    if count <= 0 then return true end
    -- Elite geben doppelte XP, in der Gruppe wird geteilt
    local xpMul = (ns.GroupXPShare and ns.GroupXPShare() or 1)
    if isKill and npcs and npcs[1] then
      local r = N(npcs[1], "rank")
      if r == 1 or r == 2 then xpMul = xpMul * 2 end
    end
    local c, mem, r, cn = Densest(list, count)
    if not c then return false end
    q.lastBest = c
    local f = DensityFactor(c, r, cn, count, unit)
    if ns.dbgDens then ns.dbgDens[#ns.dbgDens + 1] = { f, r, cn, count, isKill } end
    local n = Node("O", c[1], c[2], c[3], count * unit * f + (wait or 0), { obj = nm, count = count, npcs = npcs, pts = mem, dens = f, wait = wait })
    if not n then return false end
    table.insert(q.nodes, n)
    if isKill then
      -- XP der Kills zaehlt beim Ziel (dort steigst du auf), nicht erst beim Abgeben
      local kx = math.floor(count * (unit / killSec) * (ns.MobXP and ns.MobXP(q.ql) or 50) * xpMul)
      killXP = killXP + kx
      n.kxp = (n.kxp or 0) + kx
    end
    return true
  end
  local nObjs = 0
  if type(objs) == "table" then for k = 1, 3 do nObjs = nObjs + #(objs[k] or {}) end end
  -- Zahl: Questlog (echt), sonst Aufgabentext von Questie, sonst geschaetzt (dann ohne Zahl anzeigen)
  local guess = {}
  local function Cnt(nm, def)
    local c = CountFromLog(prog, nm) or TextCount(qid, nm, nObjs == 1)
    if c then return c end
    guess[nm or "?"] = true
    return def
  end
  if type(objs) == "table" then
    for _, c in ipairs(objs[1] or {}) do -- Mobs
      Tick()
      local nm = N(c[1], "name")
      local cnt = Cnt(nm, 8)
      -- Kampfzeit nach Mob Level (gemessen an deinen letzten Kills)
      local ml = N(c[1], "minLevel")
      local mx = N(c[1], "maxLevel") or ml
      -- 19.28 (Realitaets Regel): ein freundlicher NPC als Ziel (ansprechen, gruessen, etwas benutzen, zb Klassenlehrer)
      -- ist kein Gegner, sein Level zaehlt nicht fuer die Grenze plus 2. Vorher wartete so eine Quest bis fast auf sein Level
      -- 19.31: neutrale Tiere (zu beiden freundlich, ohne Dienste) sind doch Gegner, siehe IsFoe
      if not IsFoe(c[1]) then mx = nil end
      if mx and mx > (q.mobMax or 0) then q.mobMax = mx end
      if mx and IsElite(c[1]) then EliteMob(mx) end
      local ks = (ml and ml > 0 and ns.KillSeconds) and ns.KillSeconds(ml - (ns.simLevel or UnitLevel("player"))) or killSec
      local list = Spawns(N(c[1], "spawns"), allowed, nil, 60)
      local nSpawn = #list
      AddPatrol(c[1], list)
      -- 19.31 (Saschas Runde: Spitzhauer geschaetzt 1222 s, echt 205 s): ohne Zahl im Text galten 8 Stueck. Ein Mob mit
      -- nur 1 bis 2 Fundorten ist ein benannter Einzelner, dann ist es 1
      if guess[nm or "?"] and nSpawn > 0 and nSpawn <= 2 then cnt = 1 end
      local wait = (mx and nSpawn > 0 and nSpawn <= 2) and RARE_WAIT * cnt or nil
      if not Obj(nm, list, cnt, ks, true, { c[1] }, wait) then return nil end
      -- 19.13: Gegner Level am Ziel merken (Pruefung beim Ankommen, falls du hinter dem Plan bist)
      do local last = q.nodes[#q.nodes]; if last and last.kind == "O" and last.obj == nm then last.mobL = mx end end
    end
    for _, c in ipairs(objs[2] or {}) do -- Objekte
      Tick()
      local nm = O(c[1], "name")
      local cnt = Cnt(nm, 5)
      if not Obj(nm, Spawns(O(c[1], "spawns"), allowed, nil, 60), cnt, 14, false) then return nil end
    end
    for _, c in ipairs(objs[3] or {}) do -- Items: wo sie droppen
      Tick()
      local nm = I(c[1], "name")
      local cnt = Cnt(nm, 8)
      local pts, npcs = {}, {}
      local nSpawn = 0
      -- 19.32 (Daten 1): gestrichene Dropper raus, BEVOR die ersten 6 genommen werden (sonst rueckt der passende Mob
      -- nicht nach). kein_kampf: Item von freundlichem NPC, Ort ja, aber kein Gegner und kein Level
      local drops, dWhy = I(c[1], "npcDrops") or {}, nil
      if ns.DKDroppers then drops, dWhy = ns.DKDroppers(qid, c[1], drops) end
      if dWhy and ns.DKLog then ns.DKLog("Quest", qid, ("Item %d: %s"):format(c[1], dWhy)) end
      local noFight = ns.DKNoFight and ns.DKNoFight(c[1]) or false
      if noFight and ns.DKLog then ns.DKLog("Item", c[1], "kein_kampf") end
      drops = PickDroppers(drops, allowed, q.ql, 6)
      local function Collect(list)
        for k, npc in ipairs(list or {}) do
          if k > 6 then break end
          local n0 = #pts
          Spawns(N(npc, "spawns"), allowed, pts, 40)
          nSpawn = nSpawn + (#pts - n0)
          AddPatrol(npc, pts)
          -- Level des Mobs an jedem Fundort merken (fuer die Sicherheit unten), nur bei Gegnern (19.31)
          local ml = N(npc, "maxLevel") or N(npc, "minLevel")
          local foe = not noFight and IsFoe(npc)
          if foe and type(ml) == "number" and ml > 0 then for j = n0 + 1, #pts do pts[j][4] = ml end end
          if not noFight then for j = n0 + 1, #pts do pts[j][5] = npc end end
          -- 19.31: nur Mobs mit einem Fundort hier (der Quellstein hing an einem Elite Mob in Kraul, Level 48)
          if #pts > n0 and not noFight then table.insert(npcs, npc) end
        end
      end
      Collect(drops)
      -- 20.3r (Top 20 Haenger, K 00:55): Item nur von Elite (auch Rar Elite, Boss) Gegnern: bei Alles raus (allein nicht
      -- planbar, wie Dungeon/Raid). Item von sehr vielen verschiedenen Gegnern (Zufall Drop, zb Verderbte Windbluete):
      -- bei Alles erst im letzten Abschnitt auf Max Level (Nachquesten)
      if not noFight and #npcs > 0 then
        local allE = true
        for _, id in ipairs(npcs) do if not (IsFoe(id) and IsElite(id)) then allE = false; break end end
        if allE then q.itemEliteOnly = true end
      end
      if not noFight and #(I(c[1], "npcDrops") or {}) >= RANDOM_DROP_N then q.itemRandom = true end
      -- 19.32: bleibt nach dropper_nicht_fuers_level hier kein Fundort (zb Tyranis' Anhaenger: nur Tyranis selbst steht
      -- in den Zonen), gilt die Liste ohne diese Regel. Nie schlechter als ohne Korrektur
      if #pts == 0 and dWhy and dWhy ~= "nur_objekt" and ns.DKDroppers then
        Collect(PickDroppers((ns.DKDroppers(nil, c[1], I(c[1], "npcDrops") or {})), allowed, q.ql, 6))
        if #pts > 0 and ns.DKLog then ns.DKLog("Quest", qid, ("Item %d: ohne Fundort, Liste ohne Korrektur"):format(c[1])) end
      end
      local fromObj = false
      if #pts == 0 then
        for k, ob in ipairs(I(c[1], "objectDrops") or {}) do
          if k > 6 then break end
          Spawns(O(ob, "spawns"), allowed, pts, 40)
          fromObj = true
        end
      end
      -- 19.31: Item von einem Mob mit nur 1 bis 2 Fundorten (Kopf eines Anfuehrers) und keine Zahl im Text: 1 Stueck
      if guess[nm or "?"] and not fromObj and nSpawn > 0 and nSpawn <= 2 then cnt = 1 end
      -- schon in der Tasche? dann weniger sammeln
      local have = (not SIMLATE and ns.Api.GetItemCount and ns.Api.GetItemCount(c[1])) or 0
      if not prog and have > 0 then cnt = math.max(0, cnt - have) end
      if #pts > 0 then
        -- 19.32 (418 Thelsamar Blutwurst: Spinnensekret bei Level 20 Taranteln im Rotkamm statt bei den Lauerern im Loch
        -- Modan): Ort fuers Sammel Ziel nur bei Droppern hoechstens 3 Level ueber dem tiefsten Dropper, wenn es dort genug
        -- Fundorte gibt (mindestens 5). Sonst wie bisher der dichteste Ort
        local use = pts
        if not fromObj and not noFight and not ns.dbgItemLowOff then
          local lo
          for _, p in ipairs(pts) do if p[4] and (not lo or p[4] < lo) then lo = p[4] end end
          if lo then
            local sub = {}
            for _, p in ipairs(pts) do if not p[4] or p[4] <= lo + ITEM_LOW_GAP then sub[#sub + 1] = p end end
            if #sub >= ITEM_LOW_MIN and #sub < #pts then use = sub end
          end
        end
        -- Drops: im Schnitt ca 1.6 Kills pro Item
        local wait = (not (fromObj or noFight) and nSpawn > 0 and nSpawn <= 2) and RARE_WAIT * cnt or nil
        if not Obj(nm, use, cnt, (fromObj or noFight) and 16 or killSec * 1.6, not (fromObj or noFight), npcs, wait) then return nil end
        -- Item von Mobs: Level der Mobs am gewaehlten Ort zaehlt wie bei Toete X Quests (nicht zu weit ueber dir)
        local b = q.lastBest
        if b and not fromObj and not noFight then
          local mx
          local near, seenN, lv = {}, {}, {}
          for _, p in ipairs(pts) do
            if p[1] == b[1] and (b[2] - p[2]) ^ 2 + (b[3] - p[3]) ^ 2 < 0.0036 then
              if p[4] then lv[#lv + 1] = p[4] end
              if p[5] and not seenN[p[5]] then seenN[p[5]] = true; near[#near + 1] = p[5] end
            end
          end
          -- 19.11 (Sascha): einzelne Ausreisser zaehlen nicht (100 Mobs dort, einer davon 4 Level hoeher). Massgebend
          -- ist das Level, unter dem 9 von 10 Fundorten liegen
          if #lv > 0 then
            table.sort(lv)
            mx = lv[math.max(1, math.ceil(#lv * 0.9))]
          end
          if mx and mx > (q.mobMax or 0) then q.mobMax = mx end
          -- 19.31: sind alle Gegner dort Elite, gilt die Elite Grenze (allein nur, wenn sie deutlich unter dir sind)
          local allE, anyF = true, false
          for _, id in ipairs(near) do if IsFoe(id) then anyF = true; if not IsElite(id) then allE = false end end end
          if anyF and allE and mx then EliteMob(mx) end
          local lastN = q.nodes[#q.nodes]
          if lastN and lastN.kind == "O" and lastN.obj == nm then
            local nf = {}
            for _, id in ipairs(near) do if IsFoe(id) then nf[#nf + 1] = id end end
            lastN.npcs = #nf > 0 and nf or nil
          end
          -- Kills pro Stueck: Dropchance der Mobs genau dort (cMaNGOS, auf Forever gelernt), statt pauschal 1.6
          local kpi = ns.QuestDropKills and ns.QuestDropKills(c[1], near, true)
          local last = q.nodes[#q.nodes]
          if mx and last and last.kind == "O" and last.obj == nm then last.mobL = mx end -- 19.13
          if kpi and last and last.kind == "O" and last.obj == nm then
            last.dur = last.dur * kpi / 1.6
            local xpMul = (ns.GroupXPShare and ns.GroupXPShare() or 1)
            local kx = math.floor(cnt * (kpi - 1.6) * (ns.MobXP and ns.MobXP(q.ql) or 50) * xpMul)
            killXP = killXP + kx
            last.kxp = math.max(0, (last.kxp or 0) + kx)
          end
        end
        -- kein reines Quest Item (z.B. Wolfsfleisch): darf schon vor dem Annehmen unterwegs gesammelt werden
        local last = q.nodes[#q.nodes]
        if last and last.kind == "O" and last.obj == nm then
          last.item = c[1]
          -- 19.31: aus einem Objekt (Quellstein am Brunnen): dort stehen keine Gegner der Quest
          if fromObj or noFight then last.npcs = nil end
          local cls = I(c[1], "class")
          -- Schluessel (Klasse 13) droppen meist nur mit der Quest im Log (zb Ignition Key), wie Quest Items behandeln
          if not inLog and cls and cls ~= 12 and cls ~= 13 then last.pre = true end
        end
      else
        -- droppt nirgends: kaufen beim Haendler. Gibt es auch keinen Haendler (hergestellt, von einem NPC im
        -- Gespraech, nur im Auktionshaus), weiss die Route nicht, wo das Ziel ist: Quest nicht einplanen
        -- (sonst steht da nur Annehmen und Abgeben, und dazwischen fehlt das Ziel). Im Log bleibt sie drin.
        local vend = I(c[1], "vendors")
        if not (type(vend) == "table" and #vend > 0) then q.noWhere = (q.noWhere or 0) + 1 end
        q.buy = q.buy or {}
        table.insert(q.buy, { item = c[1], name = nm, count = cnt, vendors = vend })
        -- Haendler mit Ort: ein eigener Halt "kaufen", sonst wird abgegeben, bevor du das Item hast.
        -- Der naechste Haendler zum Questgeber (oder zum ersten Ziel), nicht irgendeiner.
        local have = (not SIMLATE and ns.Api.GetItemCount and ns.Api.GetItemCount(c[1])) or 0
        if type(vend) == "table" and #vend > 0 and (prog == nil or not prog.complete) and have < cnt then
          local ref = q.A or q.nodes[1]
          local bestP, bestD, bestV
          for k, v in ipairs(vend) do
            if k > 8 then break end
            -- Haendler auch ausserhalb der Zonen des Abschnitts (zb Gewuerze in Sturmwind): einkaufen ist ein kurzer Abstecher
            for _, p2 in ipairs(Spawns(N(v, "spawns"), ANY_ZONE, nil, 3)) do
              local c2, wx2, wy2 = World(p2[1], p2[2], p2[3])
              if c2 then
                local d2 = ref and ref.cont == c2 and ((wx2 - ref.wx) ^ 2 + (wy2 - ref.wy) ^ 2) or (ref and 1e12 or 0)
                if not bestD or d2 < bestD then bestP, bestD, bestV = p2, d2, v end
              end
            end
          end
          local made = false
          if bestP then
            local n = Node("O", bestP[1], bestP[2], bestP[3], 20, { obj = nm, count = cnt, item = c[1], buyAt = N(bestV, "name") or TR"Händler", npc = bestV })
            if n then
              -- kaufen geht auch schon vor dem Annehmen (normales Item)
              if not inLog then n.pre = true end
              table.insert(q.nodes, n)
              made = true
            end
          end
          -- Haendler gibt es, aber keiner ist erreichbar: wie ohne Fundort (sonst Abgeben ohne das Item)
          if not made then q.noWhere = (q.noWhere or 0) + 1 end
        end
      end
    end
    local kc = objs[5]
    if type(kc) == "table" and type(kc[1]) == "table" then -- Kill Credit
      local pts = {}
      for _, npc in ipairs(kc[1]) do Spawns(N(npc, "spawns"), allowed, pts, 40) end
      local nm = kc[3] or (kc[2] and N(kc[2], "name"))
      local cnt = Cnt(nm, 6)
      if #pts > 0 and not Obj(nm, pts, cnt, killSec, true, kc[1]) then return nil end
    end
  end

  for _, n in ipairs(q.nodes) do if n.kind == "O" and n.obj and guess[n.obj] then n.guess = true end end
  -- kein einziges Ziel auffindbar (Items nur hergestellt, im Gespraech oder im Auktionshaus): dann stuende
  -- nur Annehmen und Abgeben da, ohne Ziel dazwischen. Nicht einplanen (im Log bleibt sie drin).
  if (q.noWhere or 0) > 0 and not inLog then
    local hasO = false
    for _, n in ipairs(q.nodes) do if n.kind == "O" then hasO = true; break end end
    -- auch wenn andere Ziele einen Ort haben: ein Item ohne Fundort (und ohne Quell Item, aus dem es entsteht)
    -- heisst Abgeben mit offenem Ziel. Nicht einplanen.
    local src0 = Q(qid, "requiredSourceItems")
    if hasO and not (type(src0) == "table" and #src0 > 0) then hasO = false end
    if not hasO then
      if ns.dbgNoWhere then ns.dbgNoWhere[qid] = name end
      return nil
    end
  end

  -- Quellen Items: erst holen, dann damit das Ziel machen
  -- (z.B. Marlas letzter Wunsch: Samuel Fipps toeten fuer die Ueberreste, dann am Grab begraben)
  local src = Q(qid, "requiredSourceItems")
  if type(src) == "table" and not (prog and prog.complete) then
    local isObj = {}
    for _, c in ipairs((type(objs) == "table" and objs[3]) or {}) do isObj[c[1]] = true end
    local firstO
    for k, n in ipairs(q.nodes) do if n.kind == "O" then firstO = k; break end end
    local targets = {}
    for _, n in ipairs(q.nodes) do if n.kind == "O" then table.insert(targets, n) end end
    -- Ziele, die aus dem Quell Item entstehen (Item ohne eigenen Fundort, zb Tallonkais Juwel aus der Kette)
    -- oder mit ihm gemacht werden (Objekt, zb Samuels Ueberreste am Grab): ist so ein Ziel im Log weiter,
    -- ist das Quell Item erledigt, auch wenn es verbraucht ist (vorher hing der Schritt nach dem Oeffnen)
    local srcFor = {}
    for _, c in ipairs((type(objs) == "table" and objs[3]) or {}) do
      local nd, od = I(c[1], "npcDrops"), I(c[1], "objectDrops")
      if not (type(nd) == "table" and #nd > 0) and not (type(od) == "table" and #od > 0) then
        local nm2 = I(c[1], "name"); if nm2 then srcFor[#srcFor + 1] = nm2 end
      end
    end
    for _, c in ipairs((type(objs) == "table" and objs[2]) or {}) do
      local nm2 = c[2] or O(c[1], "name"); if nm2 then srcFor[#srcFor + 1] = nm2 end
    end
    for _, id in ipairs(src) do
      local have = (not SIMLATE and ns.Api.GetItemCount and ns.Api.GetItemCount(id)) or 0
      if id and not isObj[id] and have == 0 then
        local nm = I(id, "name") or (TR"Item " .. id)
        local pts, npcs, fromObj, who = {}, {}, false, nil
        -- 19.32 (Daten 1): gestrichene Dropper vor der Grenze 6 raus, wie bei den Item Zielen
        local drops, dWhy = I(id, "npcDrops") or {}, nil
        if ns.DKDroppers then drops, dWhy = ns.DKDroppers(qid, id, drops) end
        if dWhy and ns.DKLog then ns.DKLog("Quest", qid, ("Quell Item %d: %s"):format(id, dWhy)) end
        local noFightS = ns.DKNoFight and ns.DKNoFight(id) or false
        drops = PickDroppers(drops, allowed, q.ql, 6)
        for k, npc in ipairs(drops or {}) do
          if k > 6 then break end
          Spawns(N(npc, "spawns"), allowed, pts, 40)
          table.insert(npcs, npc)
          who = who or N(npc, "name")
        end
        -- 19.32: ohne Fundort nach dropper_nicht_fuers_level die Liste ohne diese Regel (wie bei den Item Zielen)
        if #pts == 0 and dWhy and dWhy ~= "nur_objekt" and ns.DKDroppers then
          npcs, who = {}, nil
          for k, npc in ipairs(PickDroppers((ns.DKDroppers(nil, id, I(id, "npcDrops") or {})), allowed, q.ql, 6)) do
            if k > 6 then break end
            Spawns(N(npc, "spawns"), allowed, pts, 40)
            table.insert(npcs, npc)
            who = who or N(npc, "name")
          end
        end
        if #pts == 0 then
          for k, ob in ipairs(I(id, "objectDrops") or {}) do
            if k > 6 then break end
            Spawns(O(ob, "spawns"), allowed, pts, 40)
            fromObj = true
            who = who or O(ob, "name")
          end
        end
        local c, mem
        if #pts > 0 then c, mem = Densest(pts, 1) end
        -- 19.31 (Sim: Die Rettung 498, Schluessel vom Kerkermeister Level 24 bei Level 21): auch die Mobs, die ein
        -- Quell Item droppen, sind Gegner der Quest. Level und Elite der Mobs am gewaehlten Ort zaehlen
        local srcNpcs, srcL
        if c and not fromObj and not noFightS then
          local allE, anyF = true, false
          srcNpcs = {}
          for _, npc in ipairs(npcs) do
            local near = false
            for _, p in ipairs(Spawns(N(npc, "spawns"), allowed, nil, 40)) do
              if p[1] == c[1] and (p[2] - c[2]) ^ 2 + (p[3] - c[3]) ^ 2 < 0.0036 then near = true; break end
            end
            if near and IsFoe(npc) then
              srcNpcs[#srcNpcs + 1] = npc
              anyF = true
              if not IsElite(npc) then allE = false end
              local ml = N(npc, "maxLevel") or N(npc, "minLevel")
              if type(ml) == "number" and ml > 0 and ml < 100 and ml > (srcL or 0) then srcL = ml end
            end
          end
          if srcL and srcL > (q.mobMax or 0) then q.mobMax = srcL end
          if anyF and allE then EliteMob(srcL) end
          if #srcNpcs == 0 then srcNpcs = nil end
        end
        local n = c and Node("O", c[1], c[2], c[3], (fromObj or noFightS) and 16 or killSec * 1.6,
          { obj = who and (nm .. TR" (von " .. who .. ")") or nm, count = 1, item = id, npcs = srcNpcs, srcItem = true, pts = mem,
            srcFor = #srcFor > 0 and srcFor or nil, mobL = srcL })
        if n then
          n.feeds = targets
          for _, t in ipairs(targets) do t.needs = t.needs or {}; table.insert(t.needs, n) end
          -- vor die Ziele, die das Item brauchen
          table.insert(q.nodes, firstO or (#q.nodes + 1), n)
          if firstO then firstO = firstO + 1 end
        end
      end
    end
  end

  -- Abgeben
  local fb = Q(qid, "finishedBy")
  local npc = fb and fb[1] and fb[1][1]
  local obj = fb and fb[2] and fb[2][1]
  local pts, who = {}, nil
  if npc then Spawns(N(npc, "spawns"), allowed, pts, 3); who = N(npc, "name") end
  if #pts == 0 and obj then Spawns(O(obj, "spawns"), allowed, pts, 3); who = O(obj, "name") end
  local p = pts[1]
  if not p then return nil end
  local t = Node("T", p[1], p[2], p[3], TURN_SEC, { who = who or "?", npc = npc })
  if t then t.dur = t.dur + V11.PlaceExtra(t) end
  if not t then return nil end
  q.T = t
  table.insert(q.nodes, t)
  q.killXP = killXP
  local ks = 0
  for _, n in ipairs(q.nodes) do if n.kind == "O" and n.kxp then ks = ks + n.kxp end end
  q.kxpSum = math.min(ks, killXP)
  q.objNodes = {}
  for _, n in ipairs(q.nodes) do if n.kind == "O" then table.insert(q.objNodes, n) end end
  local pre1, preG = Q(qid, "preQuestSingle"), Q(qid, "preQuestGroup")
  q.preSingle = type(pre1) == "table" and pre1 or nil
  q.preGroup = type(preG) == "table" and preG or nil
  local ex = Q(qid, "exclusiveTo")
  q.excl = type(ex) == "table" and ex or nil
  return q
end

------------------------------------------------------------
-- Route Werkzeuge
------------------------------------------------------------
local PATH = 1.2 -- Umweg Faktor gegenueber Luftlinie
local GRID = true -- Laufwege um gemalte Berge (pro Rechnung aus den Einstellungen gesetzt)
local SPEED = 7   -- Lauftempo der aktuellen Rechnung
local LONG = 2500 -- ab dieser Strecke pruefen, ob Zeppelin oder Schiff schneller ist
-- 20.3j (S Test 20.3g Punkt 3, K Code Blick C1): Flug schon ab ca 1000 Yards pruefen (Orgrimmar ins Brachland, Brachland
-- Nord nach Sued lagen unter 2500 und wurden nie geflogen). Nur beim Bau der Schritte (wenige Aufrufe), genommen wird der
-- Flug nur, wenn er schneller ist als Laufen. Die Planung (DRaw) bleibt bei LONG, sonst rechnet sie viel laenger
local FLY_MIN = 400 -- 20.3k (FLUG REGEL S 21:28: keine Mindest Strecke): 400 yd nur als Rechen Sparer, darunter ist Flug nie schneller

-- Zonenwechsel kosten extra (in Yards, pro Rechnung gesetzt): so macht die Route erst alles in der
-- aktuellen Zone fertig und wechselt dann einmal, statt hin und her. Das Startgebiet zaehlt bis Level 6
-- als eigene Zone (aus den Questie Daten bestimmt, siehe FindStartArea).
local ZPEN, CPEN = 0, 0
-- Version der Fahrplan Rechnung: alte Fahrplaene werden nach einem Update einmal neu gerechnet
-- 3: alte Fahrplaene konnten ohne Startquests sein (Questie zu frueh gefragt), einmal neu rechnen
-- 8: beim Einloggen sprang der Abschnitt jedes Mal einen weiter, kaputte Plaene einmal neu
-- 9: Tempo mit 3 Stufen (Alles, Normal, Schnell), Grinden nur noch im Notfall oder bei Schnell
-- 10: Tempo mit 2 Stufen (Alles, Normal) und Schalter Grinden fuer beide (17.2)
-- 11: 19.31 Realitaets Regel beim Ankommen (act.ql, act.foeQ, act.eliteM), alte Plaene aus 19.30 haben die Felder nicht
-- 12: 19.32 Daten Korrektur, Dropper Wahl und Elite Grenze, die lernt (andere Orte und Grenzen als in 19.31 Plaenen)
ns.PLAN_VER = 12
local SAREA
-- Fluss der Route: zpen und cpen verstaerken die Strafe fuer Zonen und Kontinent Wechsel, contF: so viel besser
-- muss ein Block auf einem anderen Kontinent sein, minBlock: so lange (Sekunden) muss er mindestens dauern
-- gmax: eine Grind Pause hoechstens so lange (Sekunden, 0 = egal), gsep: so viele Schritte Abstand zwischen zwei Pausen,
-- gmin: kuerzeste Pause (Sekunden)
-- contLock: Abschnitt erst auf dem aktuellen Kontinent versuchen, contKeep: so viel besser muss es mit Reise sein,
-- lockGrind: ab diesem Anteil Grinden gilt der Abschnitt auf dem Kontinent als zu schwach
-- Laengster Grind Block am Stueck in Minuten (Normal im Notfall und Schnell mit Grinden). Hier leicht zu aendern.
-- 15 Minuten: etwa so lang wie eine Runde in einem Quest Lager, auf Level 20 bis 50 ein Fuenftel Level. Kurz genug,
-- dass es eine Pause bleibt, lang genug, dass sich der Weg zum Spot lohnt (Laufen 1 bis 3 Minuten).
ns.GRIND_BLOCK_MIN = ns.GRIND_BLOCK_MIN or 15
-- 19.35 (absprache zeitmodell_1934 B2): Rest Hinweis "Level fehlt" in Stuecke zu hoechstens maxSec teilen. Gibt eine Liste
-- { dur, gain }, Summe gleich wie vorher (Zeit und XP). Hoechstens 6 Stuecke, das letzte nimmt dann den Rest (im Spiel
-- rechnet die Route nach dem ersten Stueck ohnehin neu)
function ns.HintChunks(dur, gain, maxSec)
  dur, gain = dur or 0, gain or 0
  if not (maxSec and maxSec > 0) or dur <= maxSec then return { { dur = dur, gain = gain } } end
  -- 19.41 (AUF K 12:46, teilP skyborne 07: letztes von 6 Stuecken 122 Min, am Routen Ende rechnet nichts neu): bis 40 Stuecke
  -- 20.3d (Si rauch203cn: Duo Route endet L54 bis 57, Hinweis 1077 Min, ein Block 523 Min): 40 Stuecke reichten nicht,
  -- das letzte nahm den ganzen Rest. Jetzt bis 240 Stuecke (60 Std bei 15 Min), jedes hoechstens maxSec
  local n = math.min(240, math.ceil(dur / maxSec - 1e-6))
  -- kein Mini Stueck am Ende (unter 1 Min kommt zum letzten dazu)
  if n > 1 and dur - maxSec * (n - 1) < 60 then n = n - 1 end
  local out, xpLeft = {}, gain
  for c = 1, n do
    local d = (c < n) and maxSec or (dur - maxSec * (n - 1))
    local g = (c < n) and math.floor(gain * maxSec / dur) or xpLeft
    xpLeft = xpLeft - g
    out[c] = { dur = d, gain = g, more = (c < n) or nil }
  end
  return out
end
-- Dungeon Quests annehmen: hoechstens so weit (Yards) vom Weg der Route weg ("kleiner Umweg")
local DUNG_DETOUR = 250
-- 20.3w: ab diesem Level plant die Gruppe Quests und Elite Quests 1 Level frueher (Endspiel, sonst fehlen Quests)
local GRP_END_L = 55
-- 20.3x: Grind Spot erst, wenn du so viel ueber (hoechstes Mob Level minus 2) bist (Spieler oft etwas hinter dem Plan)
local GRIND_UP_SAFE = 0.5
-- 20.3z4: Nach 60 Route in Stuecken von so vielen Quests (die naechsten ab dir), sonst rechnet sie mit allen Quests der Welt ewig
local REST_CHUNK = 40
-- 1.1 (S Log 06.11., Rechnen bis 120 s, CPU 92 s): Nachrechnen Stufe 2 und 3 im Fahrplan nahm bis 594 Quests (auch alle
-- tieferen) in einen Abschnitt, daraus 905 Schritte. Jetzt hoechstens so viele Quests, die naechsten ab dem Abschnitts Start
-- (angenommene und Vorquests immer dazu), wie bei "Nach 60 in Stuecken". Pr misst 120 gegen 160 gegen 200.
V11.STUFE_MAX_CANDS = 160
V11.STUFE_CAP_FROM = 2        -- ab dieser Nachrechnen Stufe gilt die Grenze
-- 19.28 (Sascha: Quests und Gegner nur eigenes Level bis plus 2, in der Gruppe bis plus 2 ueber dem Gruppen Schnitt):
-- wie viele Level du ueber dem Schnitt deiner Gruppe bist (0 allein oder wenn du nicht drueber bist). Die Grenzen rechnen
-- dann ab deinem Level minus diesem Abstand, also nie ueber deinem eigenen plus 2 und nie ueber dem Gruppen Schnitt plus 2
local function GroupGap()
  if not (IsInGroup and IsInGroup()) then return 0 end
  local own = ns.simLevel or (UnitLevel and UnitLevel("player")) or 1
  local sum, n = own, 1
  local num = GetNumGroupMembers and GetNumGroupMembers() or 1
  for k = 1, math.min(4, math.max(0, num - 1)) do
    local lv = UnitLevel and UnitLevel("party" .. k)
    if type(lv) == "number" and lv > 0 then sum, n = sum + lv, n + 1 end
  end
  return math.max(0, math.floor(own - sum / n))
end
ns.OptGroupGap = GroupGap
ns.FLOW = ns.FLOW or { zpen = 2, cpen = 12, contF = 2.0, minBlock = 0, gmax = 1200, gsep = 6, gmin = 300, contLock = false, contKeep = 1.15, lockGrind = 0.25, maxSwitch = 99, qlUp = 2, ports = 2 }
local function Region(n)
  if SAREA and n.cont == SAREA.cont and n.wx and ((n.wx - SAREA.wx) ^ 2 + (n.wy - SAREA.wy) ^ 2) <= SAREA.r2 then return "S" end
  local m = n.map
  if m and ns.cityParent and ns.cityParent[m] then m = ns.cityParent[m] end
  return m
end
local function Pen(a, b)
  if ZPEN <= 0 or not (a.map and b.map) then return 0 end
  if a.cont and b.cont and a.cont ~= b.cont then return CPEN end
  local ra, rb = Region(a), Region(b)
  if ra == rb then return 0 end
  if SAREA and (ra == "S" or rb == "S") then return SAREA.pen end
  return ZPEN
end

-- Strecke in Yards; anderer Kontinent: Weg zum Hafen, Warten, Fahrt, Weg vom Hafen (als Yards gerechnet)
-- DRaw ist die echte Strecke (fuer angezeigte Zeiten), D rechnet die Zonenstrafe dazu (fuer Entscheidungen)
local function DRaw(a, b)
  if b.hearth then return 0 end -- Ruhestein: Zeit steckt in der Dauer
  if a.cont and b.cont and a.cont ~= b.cont then
    local y = ns.TravelYards and ns.TravelYards(a, b, SPEED)
    return y or 1e7
  end
  local d = math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * PATH
  -- gleiche Zone: echter Laufweg ueber das Netz der Gelaende Karte (nur wenn die Linie durch einen Berg geht)
  if a.map and a.map == b.map and a.x and b.x and ns.GridDist and GRID then
    local g = ns.GridDist(a.map, a.x, a.y, b.x, b.y)
    if g and g * 1.05 > d then d = g * 1.05 end
  elseif a.map and b.map and a.x and b.x and ns.XZoneDist and GRID then
    -- 19.0 immer (frueher Schalter): ueber Zonen ueber die Uebergaenge der Karte, nie kuerzer als die Luftlinie
    local xd = ns.XZoneDist(a.map, a.x, a.y, b.map, b.x, b.y)
    if xd and xd * 1.05 > d then d = xd * 1.05 end
  end
  if d > LONG and a.cont and ns.TravelYards then
    local y = ns.TravelYards(a, b, SPEED)
    if y and y < d then d = y end
  end
  return d
end
local function D(a, b)
  if b.hearth then return 0 end
  return DRaw(a, b) + Pen(a, b)
end

-- Zeit der ganzen Route (Laufen plus Arbeit), raw: ohne Zonenstrafe
local function TotalTime(route, start, speed, raw)
  local t, prev = 0, start
  local dist = raw and DRaw or D
  for _, n in ipairs(route) do
    t = t + dist(prev, n) / speed + n.dur
    prev = n
  end
  return t
end

-- Position eines Knotens in der Route
local function IndexMap(route)
  local idx = {}
  for i, n in ipairs(route) do idx[n] = i end
  return idx
end

------------------------------------------------------------
-- Hauptrechnung
------------------------------------------------------------
-- Meldungen vom Optimierer: nur gesammelt (/klg route zeigt sie), im Chat nur mit /klg laut
ns.optLog = {}
-- Rechnen mit Zeitbudget pro Bild: so viel wie in ca 15 ms geht, dann kurz dem Spiel Luft lassen.
-- Im Kampf weniger, damit nichts ruckelt.
local function Budget(minN)
  local t0 = debugprofilestop and debugprofilestop()
  local ms = (InCombatLockdown and InCombatLockdown()) and 4 or math.max(4, ns.CalcMs() + 3)
  return function(n)
    -- mit Zeitmessung reicht ein Stueck pro Bild (einzelne Stuecke koennen teuer sein)
    if n < (t0 and 1 or (minN or 1)) then return true end
    if not t0 then return n < (minN or 1) * 3 end
    return debugprofilestop() - t0 < ms
  end
end

local lastStepAt, slowSteps, fastSteps, throttleSaid = nil, 0, 0, false
-- 18.2: Rechenzeit pro Rechnung fuers Test Log (Sascha: echte Daten vom eigenen PC, normal und schwacher PC)
local calc = { t0 = 0, cpu = 0, frames = 0, max = 0 }
-- 19.31 (Hardcore Hänger, Prüfer V1 b): Wachhund. Zeit und Phase des letzten Rechen Stücks
local coLastT, coPhase = 0, nil
local function CoRun(fn, onErr)
  local co = coroutine.create(fn)
  coLastT = GetTime and GetTime() or 0
  do local inf = debug and debug.getinfo and debug.getinfo(fn, "S"); coPhase = inf and inf.linedefined or coPhase end
  -- Messung nur im Test (ns.coPerf gesetzt): welche Phase braucht wie lange pro Bild
  local site = ns.coPerf and debug and debug.getinfo and debug.getinfo(fn, "S")
  site = site and site.linedefined
  local function Step()
    coFrame = debugprofilestop and debugprofilestop() or 0
    coLastT = GetTime and GetTime() or 0
    -- wie lange dauert ein Bild, waehrend gerechnet wird? (Abstand zum letzten Rechen Stueck)
    if lastStepAt then
      local gap = coFrame - lastStepAt
      if gap < 1000 then
        if gap > 70 then slowSteps = slowSteps + 1; fastSteps = 0 elseif slowSteps > 0 then slowSteps = slowSteps - 1 end
        -- lange fluessig: wieder etwas mehr pro Bild
        if gap < 30 then
          fastSteps = fastSteps + 1
          if fastSteps >= 200 and ns.db and ns.db.calcMs then
            fastSteps = 0
            ns.db.calcMs = ns.db.calcMs + 1
            coBudget = ns.db.calcMs
            if ns.db.calcMs >= 12 then ns.db.calcMs = nil; coBudget = 12 end
          end
        end
        if slowSteps >= 6 and ns.CalcMs() > 3 then
          slowSteps = 0
          coBudget = math.max(3, math.floor(ns.CalcMs() * 0.6))
          if ns.db then ns.db.calcMs = coBudget end
          if not throttleSaid then
            throttleSaid = true
            ns.Print(TR"Das Spiel ruckelt beim Rechnen: die Route rechnet jetzt langsamer, dafür flüssiger.")
          end
        end
      end
    end
    lastStepAt = coFrame
    coActive = true
    local ok, err = coroutine.resume(co)
    coActive = false
    if debugprofilestop then
      local d = debugprofilestop() - coFrame
      calc.cpu = calc.cpu + d
      calc.frames = calc.frames + 1
      if d > calc.max then calc.max = d end
    end
    if site and ns.coPerf then
      local d = debugprofilestop() - coFrame
      local e = ns.coPerf[site]
      if not e then e = { n = 0, max = 0, sum = 0 }; ns.coPerf[site] = e end
      e.n, e.sum = e.n + 1, e.sum + d
      if d > e.max then e.max = d end
    end
    if debugprofilestop and ns.TestLog and V11.longSteps < V11.LONG_STEP_LOG_MAX then
      local d = debugprofilestop() - coFrame
      if d > V11.LONG_STEP_MS then
        V11.longSteps = V11.longSteps + 1
        ns.TestLog("RECHNEN", ("Langes Rechen Stueck %d ms, Phase Zeile %s"):format(math.floor(d + 0.5), tostring(coPhase)))
      end
    end
    if not ok then onErr(err); return end
    if coroutine.status(co) ~= "dead" then C_Timer.After(0, Step) end
  end
  C_Timer.After(0, Step)
end

local function Report(msg)
  table.insert(ns.optLog, msg)
  while #ns.optLog > 30 do table.remove(ns.optLog, 1) end
  if ns.db and ns.db.optVerbose then ns.Print(TR"|cff7fd1b9Optimierer:|r " .. msg) end
end

------------------------------------------------------------
-- 20.3f (REGEL K 16:42, S 16:36): Vorquest Ketten STRIKT nacheinander. Harte Endpruefung NACH allen Optimierungs
-- Schritten, danach sortiert nichts mehr um. Fuer jedes Annehmen einer Quest mit Vorquest (Feld 13 "eine davon" und
-- preQuestGroup "alle") muss die Abgabe der Vorquest vorher stehen. Sonst:
--  a) Abgabe der Vorquest steht spaeter in der Route: Annehmen (und was von dieser Quest davor steht) hinter die Abgabe
--  b) Vorquest fehlt ganz: ihre Kette (bis zum Anfang) vor dem Annehmen einfuegen, wenn machbar (Chain)
--  c) geht beides nicht (Fraktion, Klasse, Level, keine Daten): Quest aus der Route
-- Log PLAN_VORQUEST je Korrektur. Allgemein, keine Quest Liste.
------------------------------------------------------------
local function PreMissing(qid, Has)
  local miss = {}
  local ps, pg = Q(qid, "preQuestSingle"), Q(qid, "preQuestGroup")
  if type(ps) == "table" and #ps > 0 then
    local any = false
    for _, id in ipairs(ps) do if Has(id) then any = true; break end end
    if not any then miss[#miss + 1] = ps end
  end
  if type(pg) == "table" then
    for _, id in ipairs(pg) do if type(id) == "number" and id > 0 and not Has(id) then miss[#miss + 1] = { id } end end
  end
  return miss
end
ns.OptPreMissing = PreMissing

-- steps: Liste der Schritte, from: ab welchem Schritt, Has(id): Quest schon erledigt (vor dieser Route),
-- skipQ(id): diese Quest nicht pruefen (im Questlog), Chain(ids, Has, lvl): Schritte fuer eine Vorquest Kette oder nil
-- 20.3o (Da Pruefung Nr 4): upto = nur bis zu diesem Schritt pruefen (beim Spielen die naechsten 60, sonst Ruckler bei
-- langen Alles Routen), logOnly = Quests mit fehlender Vorquest nicht loeschen, nur melden (beim Spielen: die Vorquest
-- kann vor dem Addon erledigt sein und Completed1 kennt sie nicht). Die Planung (mit Chain) bleibt streng
local function VorquestOrder(steps, from, Has0, skipQ, Chain, upto, logOnly)
  local turned, warned = {}, {}
  local function Has(id) return Has0(id) or turned[id] end
  local stat = { move = 0, add = 0, gone = 0 }
  local function Log(txt) if ns.TestLog then ns.TestLog("PLAN_VORQUEST", txt) end end
  -- erste Abgabe von id ab (si, ai), auch spaeter im selben Schritt
  local function TPos(id, si, ai)
    for j = si, #steps do
      for k, b in ipairs(steps[j].acts or {}) do
        if (j > si or k > ai) and b.k == "T" and b.qid == id then return j, k end
      end
    end
  end
  local function Copy(s, acts, at)
    return { map = s.map, x = s.x, y = s.y, t = at.t, lvl = at.lvl, travel = nil, acts = acts }
  end
  -- a) alle Aufgaben der Quest qid von (si, ai) bis (sj, aj) hinter (sj, aj) schieben, jede an ihrem Ort
  local function Relocate(qid, si, ai, sj, aj)
    local moved = {}
    for j = si, sj do
      local acts = steps[j].acts or {}
      local k = (j == si) and ai or 1
      while k <= #acts do
        local b = acts[k]
        local before = (j < sj) or (k < aj)
        if before and b.qid == qid and (b.k == "A" or b.k == "O" or b.k == "T") then
          table.remove(acts, k)
          if j == sj then aj = aj - 1 end
          moved[#moved + 1] = { a = b, s = steps[j] }
        else
          k = k + 1
        end
      end
    end
    local at = steps[sj]
    -- Annehmen beim selben Ort wie die Abgabe der Vorquest (oft der gleiche NPC): direkt dahinter im gleichen Schritt
    local pos, ins = aj, {}
    for _, m in ipairs(moved) do
      if m.s == at then
        pos = pos + 1; table.insert(at.acts, pos, m.a)
      elseif ins[#ins] and ins[#ins].src == m.s then
        table.insert(ins[#ins].acts, m.a)
      else
        local ns2 = Copy(m.s, { m.a }, at); ns2.src = m.s
        ins[#ins + 1] = ns2
      end
    end
    for k = #ins, 1, -1 do ins[k].src = nil; table.insert(steps, sj + 1, ins[k]) end
    for j = sj, si, -1 do if #(steps[j].acts or {}) == 0 then table.remove(steps, j) end end
  end
  local function Remove(qid, si)
    for j = #steps, si, -1 do
      local acts = steps[j].acts or {}
      for k = #acts, 1, -1 do
        local b = acts[k]
        if b.qid == qid and (b.k == "A" or b.k == "O" or b.k == "T") then table.remove(acts, k) end
      end
      if #acts == 0 then table.remove(steps, j) end
    end
  end
  local tries, si = 0, math.max(1, from or 1)
  while si <= #steps and (not upto or si <= upto) and tries < 4000 do
    tries = tries + 1
    local s, again = steps[si], false
    for ai, a in ipairs(s.acts or {}) do
      if a.qid and a.qid > 0 and not a.cls then
        if a.k == "A" and not (skipQ and skipQ(a.qid)) and not warned[a.qid] then
          local miss = PreMissing(a.qid, Has)
          if #miss > 0 then
            local sj, aj, ok = si, ai, true
            for _, alts in ipairs(miss) do
              local bj, bk
              for _, id in ipairs(alts) do
                local j, k = TPos(id, si, ai)
                if j and (not bj or j < bj or (j == bj and k < bk)) then bj, bk = j, k end
              end
              if not bj then ok = false; break end
              if bj > sj or (bj == sj and bk > aj) then sj, aj = bj, bk end
            end
            if ok then
              Relocate(a.qid, si, ai, sj, aj)
              stat.move = stat.move + 1
              Log(("Quest %d %s: Annehmen hinter die Abgabe der Vorquest geschoben (Schritt %d nach %d)"):format(a.qid, tostring(a.quest), si, sj))
            else
              local add = Chain and Chain(miss, Has, s.lvl or 0, s)
              if add and #add > 0 then
                for k = #add, 1, -1 do table.insert(steps, si, add[k]) end
                stat.add = stat.add + 1
                Log(("Quest %d %s: Vorquest fehlte, Kette eingefuegt (%d Schritte) vor Schritt %d"):format(a.qid, tostring(a.quest), #add, si))
              elseif logOnly then
                warned[a.qid] = true
                Log(("Quest %d %s: Vorquest %s nicht als erledigt bekannt, nur gemeldet (bleibt drin)"):format(a.qid, tostring(a.quest), tostring(miss[1][1])))
              else
                Remove(a.qid, si)
                stat.gone = stat.gone + 1
                Log(("Quest %d %s: Vorquest %s fehlt und geht nicht, Quest raus"):format(a.qid, tostring(a.quest), tostring(miss[1][1])))
              end
            end
            again = true
            break
          end
        end
        if a.k == "T" then turned[a.qid] = true end
      end
    end
    if not again then si = si + 1 end
  end
  return stat
end
ns.OptVorquestOrder = VorquestOrder

function ns.Optimize(targetLevel, done, opts)
  opts = opts or {}
  -- Sicherheit: haengt eine Rechnung laenger als 5 Minuten, gilt sie als tot
  if busy and GetTime and (GetTime() - (busyAt or 0)) > 300 then busy = false end
  -- 20.3o (Log 20.3m 22:58:19, Ausruestung "rechnet schon"): eine Zusatz Route vom Knopf (Ausruestung, Ruf, Gold,
  -- Questlog) bricht eine laufende Leveling Rechnung ab, statt zu warten. Die alte Rechnung endet beim naechsten
  -- Stueck (busyAt ist dann neu, Later laeuft nicht weiter). Die Leveling Route rechnet danach von selbst wieder
  local special = opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn
  if busy and special and not ns.calcSpecial and not opts.sim then
    if ns.TestLog then ns.TestLog("RECHNEN", "Leveling Rechnung abgebrochen fuer Zusatz Route vom Knopf") end
    busy = false
  end
  if busy then Report(TR"rechnet schon ..."); return end
  if not ns.QDBAccess then return end
  QDB, ZDB, QLib, QPlayer = ns.QDBAccess()
  if not QDB then Report(TR"Questie Daten sind noch nicht geladen, bitte kurz warten."); return end
  local okX, XPmod = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestXP")
  XPDB = okX and XPmod and XPmod.db or nil

  local sim = opts.sim
  SIMLATE = sim and (sim.sec or 1) > 1 or false
  SIMMAP = sim and sim.map or nil
  local mapID, px, py
  if sim then
    mapID, px, py = sim.map, sim.x, sim.y
  else
    -- 17.9: im Dungeon gibt es keine Position: nicht jedes Mal neu versuchen, draussen rechnet es von selbst
    if ns.InInstance and ns.InInstance() then ns.instPending = true; return end
    mapID = ns.PlayerMap()
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then Report(TR"keine Position gefunden"); return end
    px, py = pos:GetXY()
  end
  local cont, swx, swy = World(mapID, px, py)
  if not cont then Report(TR"keine Position gefunden"); return end
  local start = { wx = swx, wy = swy, map = mapID, x = px, y = py, cont = cont }
  -- erreichbare Kontinente (Schiff und Zeppelin)
  local reach = ns.TravelReach and ns.TravelReach(cont) or { [cont] = true }
  -- Feinjustierung: Kontinent nicht wechseln
  if ns.db and ns.db.contSwitch == false and not opts.gold then reach = { [cont] = true } end
  -- Fahrplan: erst versuchen, den Abschnitt auf dem aktuellen Kontinent zu machen (siehe PlanBuild)
  if opts.contLock then reach = { [cont] = true } end

  local L0 = sim and sim.L or UnitLevel("player")
  local xp0 = sim and sim.xp or ((ns.xpTotal[L0] or 0) + (ns.Plain and ns.Plain(UnitXP("player")) or 0))
  -- Ruhebonus (17.5): Kill XP zaehlen doppelt, bis der Vorrat leer ist. Quest Kills und Grinden verbrauchen ihn
  -- der Reihe nach, so wie im Spiel. Abgaben bekommen keinen Bonus.
  local rested0 = (not SIMLATE and GetXPExhaustion and ns.Plain and ns.Plain(GetXPExhaustion())) or 0
  if type(rested0) ~= "number" then rested0 = 0 end
  -- Forever Buffs (Essen, Schlafsack): nur fuer die Zeit, die sie noch laufen (beim Durchrechnen der Schritte)
  local buffs0 = (not sim and ns.XPBuffs) and ns.XPBuffs() or {}
  local special0 = opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn
  -- Startgebiet: wird nach dem Lesen der Quests aus Questie bestimmt (FindStartArea)
  local startLock
  SAREA = nil
  -- Strafe fuer Zonenwechsel: am Anfang hoch, spaeter klein (in Sekunden, als Yards gerechnet).
  -- Ein anderer Kontinent zaehlt zusaetzlich zur echten Reisezeit (Schiff, Zeppelin) doppelt, unter Level 12 dreifach.
  do
    local sec = (L0 < 6 and 240) or (L0 < 10 and 180) or (L0 < 20 and 120) or (L0 < 40 and 90) or 60
    local sp = (ns.PlanSpeed and ns.PlanSpeed() or ns.speed or 7)
    local F = ns.FLOW or {}
    ZPEN = sec * sp * (F.zpen or 1)
    CPEN = ZPEN * (L0 < 12 and 3 or 2) * (F.cpen or 1)
  end
  targetLevel = math.min(60, math.max(L0 + 1, math.floor(targetLevel or (L0 + 3))))
  if targetLevel > L0 + 10 and not (opts and opts.full) then targetLevel = L0 + 10 end
  local xpNeed = (ns.xpTotal[targetLevel] or xp0) - xp0
  -- Modus "alle Quests": jede machbare Quest mitnehmen, keine XP Grenze
  local CAP = (opts.all or opts.gold or opts.logOnly or opts.endInn or opts.rep or opts.gearQ) and math.huge or xpNeed * (opts.capF or 1.15)
  local speed = (ns.PlanSpeed and ns.PlanSpeed() or ns.speed or 7)
  SPEED = speed
  GRID = not (ns.db and ns.db.gridDist == false)
  local grind = ns.KillRate and ns.KillRate(L0) or 6000

  -- erlaubte Zonen: laut Plan zwischen jetzt und Ziel, plus aktuelle Zone und Staedte darin
  local allowed = {}
  -- anderes Startgebiet gewaehlt: die Zone, in der du stehst, zaehlt nur, wenn sie im Plan ist
  -- (sonst macht die Route die Startquests von hier statt dort)
  local inPlanZ = {}
  for _, sg in ipairs(ns.plan or {}) do inPlanZ[sg[1]] = true end
  local pmap0 = (ns.cityParent and ns.cityParent[mapID]) or mapID
  local awayStart = ns.db and ns.db.startPlan and L0 < 10 and not inPlanZ[pmap0]
  if not awayStart then allowed[mapID] = true end
  -- ab welchem Level eine Zone im Plan dran ist: vorher bleibt man in den Zonen davor
  -- (Tester: Orc auf Level 5 mit dem Zeppelin nach Tirisfal, mitten im eigenen Startgebiet)
  local zoneFrom = {}
  for _, sg in ipairs(ns.plan or {}) do
    if zoneFrom[sg[1]] == nil or sg[2] < zoneFrom[sg[1]] then zoneFrom[sg[1]] = sg[2] end
  end
  for _, sg in ipairs(ns.plan or {}) do
    if sg[2] < targetLevel and sg[3] > L0 - 1 then allowed[sg[1]] = true end
  end
  -- Alles: jede Zone deiner Fraktion bis zum Ziel Level, auch alte Zonen und die Startgebiete der anderen Voelker
  -- wide: alle Zonen deiner Fraktion bis zum Ziel Level, aber ohne die Startgebiete der anderen Voelker
  -- Startgebiete der anderen Voelker (bei Alles) erst ab Level 10, vorher bleibt man im eigenen
  if opts.scope == "all" or opts.scope == "wide" then
    local inPlan = {}
    for _, sg in ipairs(ns.plan or {}) do inPlan[sg[1]] = true end
    for ui, z in pairs(ns.zones or {}) do
      local foreignStart = (z.min or 0) <= 1 and not inPlan[ui]
      local ok = not foreignStart or (opts.scope == "all" and L0 >= 10)
      if ok and (z.min or 0) < targetLevel and not (ns.EnemyZone and ns.EnemyZone(ui)) then allowed[ui] = true end
    end
  end
  -- Gold: alle Zonen fuer Maximallevel
  if opts.gold then
    -- auf 60 alle Zonen fuer Maximallevel, vorher die Zonen fuer dein Level
    if L0 >= 58 then
      for ui, z in pairs(ns.zones or {}) do if (z.max or 0) >= 54 then allowed[ui] = true end end
    else
      for ui, z in pairs(ns.zones or {}) do if (z.min or 0) <= L0 and (z.max or 0) >= L0 - 4 then allowed[ui] = true end end
    end
  end
  for city, parent in pairs(ns.cityParent or {}) do if allowed[parent] then allowed[city] = true end end
  if ns.cityParent and ns.cityParent[mapID] and not awayStart then allowed[ns.cityParent[mapID]] = true end

  -- Grinden erlaubt? (Einstellung "Grinden, wenn es schneller geht")
  -- Grinden: Schalter an (Option) oder aus (noGrind, keine Grind Schritte), steckt in den opts
  local grindOK = not opts.noGrind
  -- Luecke fuellen: reichen die Quests nicht bis zum Ziel Level, Grind Pausen (oder ohne Grinden ein Hinweis)
  local fillGap = opts.fillGap and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn)
  -- Grinden ist nur der Notfall (auf Forever gibt es mehr Quests): reichen die Quests nicht, kommen erst tiefere
  -- gruene Quests dazu (bis 7 unter dir), dann hoechstens 30 Min am Stueck grinden, der Rest wird ein Dungeon Hinweis
  local qlDown0 = opts.gold and 6 or opts.qlDown or 5
  local emDown = (not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.all) and qlDown0 < 7) and 2 or 0
  local emergency = false
  -- Gold und Ruf: der Wert einer Quest ist kein XP, die Kill XP bleiben dort beim Abgeben
  local xpNoKill = (opts.gold or opts.rep) and true or false
  -- Gruppe ab 3 (du leitest): reichen die Quests nicht, ist ein Dungeon besser als tiefe Quests oder Grinden
  -- (XP wird geteilt, Dungeon Quests kommen dazu). Statt Grind Pausen kommt ein Dungeon Vorschlag.
  local grpDung = false
  if not sim and ns.GroupPlanInfo and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn) then
    local g0 = ns.GroupPlanInfo()
    grpDung = (g0 and #g0.members >= 2) and true or false
  end
  if grpDung then emDown = 0 end
  -- Dungeon in der Gruppe: XP pro Stunde etwas besser als allein grinden
  local DUNG_F = 1.3
  -- Speed Leveling: Grind Spots der Zonen schon mal analysieren lassen
  -- 1.1 (P38): nicht mehr alle Gebiete im ersten Bild, sondern in Phase1 je Gebiet mit Tick
  local grindTodo = {}
  if (opts.speed or (fillGap and grindOK)) and ns.GrindList then for ui in pairs(allowed) do grindTodo[#grindTodo + 1] = ui end end
  busy = true
  -- eigene Generation auch im selben Bild (Abbruch und Neustart gleichzeitig): kleiner Zaehler dazu
  ns.calcGen = (ns.calcGen or 0) + 1
  busyAt = (GetTime and GetTime() or 0) + (ns.calcGen % 1000) * 1e-6
  ns.calcSpecial = special and true or nil
  V11.stage.gen, V11.stage.pct, ns.optPct = busyAt, 0, 0
  -- 20.3z (P11): Mini Fenster zeigt die Sanduhr gleich beim Start
  if not opts.sim and ns.RefreshHud and C_Timer then C_Timer.After(0, function() pcall(ns.RefreshHud) end) end
  calc.t0, calc.cpu, calc.frames, calc.max = busyAt, 0, 0, 0
  -- 19.31 (Hardcore Hänger, Prüfer V1 b): Wachhund. Kommt 60 s lang kein Rechen Stück mehr und die Rechnung ist nicht
  -- fertig, hängt sie: Zeile FEHLER mit Phase ins Test Log und "rechnet schon" lösen, damit neu gerechnet werden kann.
  -- Wartet die Rechnung nur (jedes Bild ein Stück), zählt das als Fortschritt
  local myBusy = busyAt
  coLastT = busyAt
  local function Wachhund()
    if not busy or busyAt ~= myBusy then return end
    local now = GetTime and GetTime() or 0
    if now - coLastT > 60 then
      busy = false
      local KA = ns.Karte
      local info = ("Wachhund: Rechnung %d s ohne Fortschritt, Phase Zeile %s, Bilder %d, Karte %s, wartet auf %s, Level %d bis %d"):format(
        math.floor(now - myBusy), tostring(coPhase or "?"), calc.frames, (KA and KA.Preparing and KA.Preparing()) and "bereitet vor" or "fertig",
        tostring(ns.planPending or "-"), L0 or 0, targetLevel or 0)
      Report(info)
      if ns.TestLog then ns.TestLog("FEHLER", info) end
      return
    end
    C_Timer.After(15, Wachhund)
  end
  C_Timer.After(15, Wachhund)
  -- 18.2: wenn die Rechnung fertig ist, einmal ins Test Log: echte Sekunden, reine Rechenzeit, Bilder, Budget, Level
  local done0, logged = done, false
  done = function(...)
    if not logged and ns.TestLog then
      logged = true
      local kind = sim and "Plan" or ((opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn) and "Extra" or "Route")
      ns.TestLog("RECHNEN", ("Rechenzeit %s: %.1f s, CPU %d ms in %d Bildern (max %d ms), Budget %d ms, Level %d bis %d, %s"):format(
        kind, (GetTime and GetTime() or 0) - calc.t0, math.floor(calc.cpu + 0.5), calc.frames, math.floor(calc.max + 0.5), ns.CalcMs(),
        L0, targetLevel, (ns.db and ns.db.slowPC) and "schwacher PC" or "normal"))
    end
    if done0 then return done0(...) end
  end
  -- Fehler in einer Phase: nicht fuer immer "rechnet schon" bleiben
  local function Fail(err)
    busy = false
    Report(TR"Fehler beim Rechnen: " .. tostring(err))
    if ns.TestLog then ns.TestLog("FEHLER", "Optimierer: " .. tostring(err)) end
    if sim and done then pcall(done, nil) end
  end
  -- 19.32 (Pruefer 02:45 Hinweis 2): jede Rechnung hat ihre Generation (busyAt beim Start). Ein spaeter Rueckruf einer
  -- alten Rechnung (zb nach dem Wachhund) laeuft nicht neben einer neuen weiter
  local myGen = busyAt
  local function Later(fn)
    if busyAt ~= myGen then return end
    CoRun(fn, Fail)
  end
  if opts.logOnly then
    Report((TR"rechnet die Route für deine Quests im Log%s ..."):format(opts.zone and (" (" .. opts.zone .. ")") or ""))
  else
    Report(opts.all and (TR"rechnet alle Quests bis Level %d ..."):format(targetLevel) or (TR"rechnet die Route bis Level %d ..."):format(targetLevel))
  end

  local complete = (Questie and Questie.db and Questie.db.char and Questie.db.char.complete) or {}
  -- Zwilling schon abgegeben (dieselbe Quest unter anderer ID): die geplante nicht nochmal einplanen
  local twins = ns.db and ns.db.questTwin
  if twins and next(twins) then
    local c2 = {}
    for k, v in pairs(complete) do c2[k] = v end
    for y, x in pairs(twins) do if complete[x] and SameObjs(y, x) and not (ns.OptChainLinked and ns.OptChainLinked(y, x)) then c2[y] = true end end
    complete = c2
  end
  local realDone = complete
  local inLog = (QPlayer and QPlayer.currentQuestlog) or {}
  if not sim and ns.ReadLog then ns.ReadLog() end
  local logProg = ns.logProgress or {}
  -- Gruppe (du leitest, andere laufen mit): ihr Stand zaehlt mit
  local giQ = not sim and ns.GroupPlanInfo and ns.GroupPlanInfo() or nil
  if giQ and ns.ObjFind and ns.ObjName then
    -- ein Ziel ist erst erledigt, wenn alle, die die Quest haben, es erledigt haben (sonst fehlt den anderen der Halt)
    local merged = {}
    for qid, lp in pairs(logProg) do
      local out = lp
      for _, m in ipairs(giQ.members) do
        local mq = m.log and m.log[qid]
        if mq and not mq.done then
          if out == lp then
            out = { title = lp.title, zone = lp.zone, complete = false, objs = {} }
            for k, o in ipairs(lp.objs or {}) do out.objs[k] = { text = o.text, done = o.done } end
          end
          out.complete = false
          for _, o in ipairs(out.objs) do
            local ms = ns.ObjFind(mq.objs, ns.ObjName(o.text), function(t) return t end)
            local a1, b1
            if type(ms) == "string" then a1, b1 = ms:match("(%d+)%s*/%s*(%d+)") end
            local a0 = type(o.text) == "string" and o.text:match("(%d+)%s*/%s*%d+")
            if a1 and (not a0 or tonumber(a1) < tonumber(a0)) then
              o.text = o.text:gsub("%d+%s*/%s*(%d+)", a1 .. "/%1", 1)
              o.done = tonumber(a1) >= tonumber(b1)
            end
          end
        end
      end
      merged[qid] = out
    end
    logProg = merged
  end
  if sim then
    -- Fahrplan: was in frueheren Abschnitten geplant ist, gilt als erledigt; angenommen und noch offen = im Log
    local real = complete
    complete = setmetatable({}, { __index = function(_, k) return sim.done[k] or real[k] end, __pairs = function() return next, sim.done, nil end })
    inLog = sim.log or {}
    logProg = {}
  end
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local customRace = raceID ~= nil and raceID > 8
  local blocked = (ns.db and ns.db.questBlocked) or {}
  -- von dir eingeplante Quests (zb Upgrade aus der Ausruestung): kommen in die normale Route, ersetzen sie nicht
  local forced = {}
  if not (opts.gold or opts.rep or opts.logOnly or opts.gearQ) and ns.db and ns.db.forceQ then
    for qid in pairs(ns.db.forceQ) do
      -- nur wirklich erledigte Quests austragen, nicht die in einem frueheren Fahrplan Abschnitt geplanten
      if realDone[qid] then ns.db.forceQ[qid] = nil elseif not complete[qid] then forced[qid] = true end
    end
  end
  local anyAllowed = setmetatable({}, { __index = function() return true end })

  -- 1. Kandidaten
  local ids = {}
  local lib = LibQuestieDB
  local all = lib and lib.Quest and lib.Quest.GetAllIds and lib.Quest.GetAllIds()
  if type(all) == "table" then ids = all else for id in pairs(QDB.QuestPointers or {}) do ids[#ids + 1] = id end end
  -- Ruf farmen: nur Quests mit Ruf fuer diese Fraktion, in allen Zonen
  local repOf = {}
  if opts.rep then
    allowed = setmetatable({}, { __index = function() return true end })
  end
  -- Questlog Route: nur die Quests aus dem Log (wahlweise nur eine Zone)
  if opts.logOnly then
    ids = {}
    for qid in pairs(inLog) do
      local p = logProg[qid]
      local want = (not opts.zone or (p and p.zone == opts.zone)) and (not opts.qids or opts.qids[qid])
      if want then table.insert(ids, qid) end
    end
    allowed = setmetatable({}, { __index = function() return true end })
  end
  -- Ausruestung: nur die ausgewaehlten Quests mit Belohnung (plus ihre Vorquests)
  if opts.gearQ then
    ids = {}
    for qid in pairs(opts.gearQ) do table.insert(ids, qid) end
    allowed = setmetatable({}, { __index = function() return true end })
  end
  local cands = {}
  local i = 0
  -- Dungeon Quests zum Annehmen mit kleinem Umweg (Schalter Dungeon Quests an), siehe Finish
  local dungPick = {}
  local pickOn = ns.DungeonQOn and ns.DungeonQOn() and not (opts.logOnly or opts.gold or opts.rep or opts.gearQ or opts.endInn or sim and sim.noDung)

  local Phase2 -- forward
  local IsHiddenQuest
  local SeedQuest
  -- von Questie ausgeblendet oder sonst nicht annehmbar, unabhaengig von Vorquests
  local QC = (function() local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieCorrections"); return ok and m end)()
  local hiddenAuto = QC and QC.hiddenQuests or {}
  local hiddenMan = (Questie and Questie.db and Questie.db.char and Questie.db.char.hidden) or {}
  local QProf = (function() local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieProfessions"); return ok and m end)()
  local HIDE_ON_MAP = (function() local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieQuestBlacklist"); return ok and m and m.HIDE_ON_MAP end)()
  -- warum Quests rausfallen (fuer /klg warum und wenn gar nichts rauskommt)
  local why = {}
  local whyQ, curQ = {}, nil
  local function Why(r)
    why[r] = (why[r] or 0) + 1
    if curQ and r ~= TR"passt vom Level" then whyQ[curQ] = r end
  end
  ns.optWhy = why; ns.optWhySel = nil; ns.optWhyDet = nil
  IsHiddenQuest = function(qid)
    -- HIDE_ON_MAP heisst bei Questie nur "nicht auf der Karte zeigen", die Quest gibt es trotzdem
    local h = hiddenAuto[qid]
    if h and h ~= HIDE_ON_MAP then return TR"versteckt" end
    if hiddenMan[qid] then return TR"von dir versteckt" end
    if ns.IsEventQuestSkipped and ns.IsEventQuestSkipped(qid) then return TR"Feiertag" end
    local nx = Q(qid, "nextQuestInChain")
    if nx and nx ~= 0 and (complete[nx] or inLog[nx]) then return TR"Folgequest schon gemacht" end
    local parent = Q(qid, "parentQuest")
    if parent and parent ~= 0 and not inLog[parent] then return TR"Hauptquest fehlt" end
    local excl = Q(qid, "exclusiveTo")
    if type(excl) == "table" then for _, v in pairs(excl) do if complete[v] or inLog[v] then return TR"andere Variante gemacht" end end end
    local skill = Q(qid, "requiredSkill")
    if type(skill) == "table" and skill[1] and QProf and QProf.HasProfessionAndSkillLevel then
      local ok, hasP, hasL = pcall(QProf.HasProfessionAndSkillLevel, QProf, skill)
      if ok and not (hasP and hasL) then return TR"Beruf fehlt" end
    end
    return false
  end

  -- Startgebiet aus Questie: wo die Quests mit Level 1 bis 2 fuer dein Volk und deine Klasse anfangen,
  -- in der Zone, in der du stehst. Erledigte zaehlen mit, damit es gleich bleibt, waehrend du questest.
  local seedOn = not special0 and L0 < 6 and not awayStart
  local seeds = {}
  SeedQuest = function(qid)
    local okS, qlS = pcall(QLib.GetEffectiveQuestLevel, qid)
    if not okS or not qlS or qlS > 2 then return end
    local rc, rr = Q(qid, "requiredClasses"), Q(qid, "requiredRaces")
    if rc and rc > 0 and classID and not ns.HasBit(rc, classID - 1) then return end
    if rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then return end
    local sb = Q(qid, "startedBy")
    local npc = sb and sb[1] and sb[1][1]
    if not npc then return end
    local pts = {}
    Spawns(N(npc, "spawns"), { [mapID] = true }, pts, 1)
    local pt = pts[1]
    if not pt then return end
    local c, wx, wy = World(pt[1], pt[2], pt[3])
    if c == start.cont then seeds[#seeds + 1] = { wx = wx, wy = wy } end
  end
  local function FindStartArea()
    if not seedOn or #seeds < 3 then return end
    -- Mitte: Median der Questgeber (ein einzelner Ausreisser verschiebt sie nicht)
    local xs, ys = {}, {}
    for k, p in ipairs(seeds) do xs[k] = p.wx; ys[k] = p.wy end
    table.sort(xs); table.sort(ys)
    local cx, cy = xs[math.ceil(#xs / 2)], ys[math.ceil(#ys / 2)]
    -- Ausreisser weg: Startquests weit weg von den anderen (zb eine Level 2 Quest im naechsten Dorf)
    local sd = {}
    for k, p in ipairs(seeds) do sd[k] = math.sqrt((p.wx - cx) ^ 2 + (p.wy - cy) ^ 2) end
    local sorted = {}
    for k, v in ipairs(sd) do sorted[k] = v end
    table.sort(sorted)
    local keep = math.max(300, sorted[math.ceil(#sorted / 2)] * 3)
    -- Radius: so weit, dass die meisten Startquests drin liegen (Geber, Ziele, Abgabe)
    local ds = {}
    for k in ipairs(seeds) do if sd[k] <= keep then ds[#ds + 1] = sd[k] end end
    -- Ziele der Startquests liegen weiter draussen als die Questgeber: dafuer eine groessere Grenze
    local keepN = math.max(keep * 2.5, 750)
    for _, q in ipairs(cands) do
      if (q.ql or 99) <= 2 then
        for _, nd in ipairs(q.nodes or {}) do
          local d = nd.cont == start.cont and nd.wx and math.sqrt((nd.wx - cx) ^ 2 + (nd.wy - cy) ^ 2)
          if d and d <= keepN then ds[#ds + 1] = d end
        end
      end
    end
    table.sort(ds)
    local r = ds[math.max(1, math.ceil(#ds * 0.85))] or 0
    r = math.min(900, math.max(250, r * 1.3))
    -- schon draussen? dann gilt es nicht mehr
    if (start.wx - cx) ^ 2 + (start.wy - cy) ^ 2 > (r * 1.2) ^ 2 then return end
    SAREA = { cont = start.cont, wx = cx, wy = cy, r2 = r * r, pen = 600 * speed }
    startLock = SAREA
    ns.optStartArea = { r = math.floor(r), n = #seeds }
    -- Quests ganz im Startgebiet immer mitnehmen
    local nIn = 0
    for _, q in ipairs(cands) do
      local inside = true
      for _, nd in ipairs(q.nodes or {}) do if Region(nd) ~= "S" then inside = false break end end
      if inside then q.startQ = true; nIn = nIn + 1 end
    end
    Report((TR"Startgebiet aus Questie: %d Startquests, %d Yards, %d Quests dort"):format(#seeds, math.floor(r), nIn))
  end

  local preExtra, preRound = {}, false
  local function Phase1()
    if #grindTodo > 0 then V11.GrindTodo(grindTodo) end
    local n = 0
    local more = Budget(20)
    while i < #ids and more(n) do
      Tick()
      i = i + 1
      n = n + 1
      local qid = ids[i]
      curQ = qid
      if seedOn then SeedQuest(qid) end
      if not complete[qid] and not blocked[qid] then
        local ok, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
        local repAmt
        if opts.rep then
          local rr = Q(qid, "reputationReward")
          for _, pr in ipairs(type(rr) == "table" and rr or {}) do
            if pr[1] == opts.rep and (pr[2] or 0) > 0 then repAmt = pr[2] end
          end
        end
        if opts.rep and not repAmt then
          -- keine Ruf Quest fuer diese Fraktion: ueberspringen
        elseif opts.rep and ok and rl and rl <= L0 and ql and ql <= L0 + 2 then
          repOf[qid] = repAmt
        end
        local fits
        if opts.gearQ then
          fits = opts.gearQ[qid] and (inLog[qid] or (ok and rl and rl <= L0)) and true or false
        elseif forced[qid] and (inLog[qid] or (ok and rl and rl <= L0)) then
          fits = true
        else
          fits = (opts.rep and repOf[qid]) or (not opts.rep and ((opts.logOnly and inLog[qid]) or inLog[qid] or (ok and ql and rl and rl <= (opts.gold and L0 or targetLevel - 1)
          and ql >= L0 - qlDown0 - emDown and ql <= targetLevel + 2)))
          -- tiefere Vorquest einer Questreihe, die hier weitergeht: mitnehmen, sonst faellt die ganze Reihe weg
          if not fits and preExtra[qid] and ok and rl and rl <= targetLevel - 1 then fits = true end
        end
        if fits then
          Why(TR"passt vom Level")
          local skip = (not opts.rep and QDB.IsRepeatable and QDB.IsRepeatable(qid)) or (QDB.IsDungeonQuest and QDB.IsDungeonQuest(qid))
            or (QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or (QDB.IsPvPQuest and QDB.IsPvPQuest(qid))
          -- Dungeon Quests (17.2): im Log und fertig: abgeben. Nicht im Log und Schalter an: gezielt annehmen (kleiner
          -- Umweg, die Ziele macht man im Dungeon). Schalter aus: nicht annehmen, die Vorquests zaehlen nur fuer sich selbst.
          local isDung = (QDB.IsDungeonQuest and QDB.IsDungeonQuest(qid)) or (ns.IsDungeonQuest and ns.IsDungeonQuest(qid))
          local dungCand = false
          if isDung and inLog[qid] and logProg[qid] and logProg[qid].complete then
            skip = (QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or false
          elseif isDung and not inLog[qid] and pickOn then
            dungCand = true
            skip = (not opts.rep and QDB.IsRepeatable and QDB.IsRepeatable(qid)) or (QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or (QDB.IsPvPQuest and QDB.IsPvPQuest(qid)) or false
          end
          local rc, rr = Q(qid, "requiredClasses"), Q(qid, "requiredRaces")
          local clsSkip = (rc and rc > 0 and classID and not ns.HasBit(rc, classID - 1)) or (rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID))
          -- Klassenquest eines Mitlaeufers (Gruppe, du leitest): als Halt fuer alle einplanen, wie ein Lehrer.
          -- Nur wenn sein Stand bekannt ist (erledigte Quests) und er sie noch nicht gemacht hat
          local forM
          if clsSkip and not skip and giQ and rc and rc > 0 and not (opts.logOnly or opts.gold or opts.rep or opts.gearQ) then
            for _, m in ipairs(giQ.members) do
              local okM = m.cid and m.done and ns.HasBit(rc, m.cid - 1) and not m.done[qid]
              if okM and rr and rr > 0 and not (m.rid and ns.RaceOK(rr, m.rid)) then okM = false end
              if okM and (m.lvl or 0) < (rl or 1) then okM = false end
              if okM then
                forM = forM or { names = {}, cls = m.cls, done = m.done }
                table.insert(forM.names, m.name)
                if m.log and m.log[qid] then forM.log = true end
              end
            end
          end
          if clsSkip and not forM then skip = true end
          if skip then Why(TR"anderes Volk, andere Klasse, Dungeon oder wiederholbar") end
          if QDB.IsDoable and not inLog[qid] then
            -- Questie prueft Ruf, Berufe usw.; Vorquests prueft der Optimierer selbst (Ketten zaehlen mit)
            -- (bei der Klassenquest eines Mitlaeufers prueft Questie deine Klasse, das gilt hier nicht)
            -- Questie noch nicht fertig gestartet: nicht fragen (es merkt sich sonst "nein" fuer die ganze Sitzung)
            local okD, doable = true, true
            if not ns.questieEarly then okD, doable = pcall(QDB.IsDoable, qid) end
            -- eigenes Volk von Forever: Questie kennt es nicht und sagt bei Volk Quests "nicht machbar". Volk und Klasse
            -- prueft der Wegweiser oben selbst (mit der Fraktion), Ruf, Beruf und versteckt unten auch.
            if okD and doable == false and not forM and not customRace and not (QRaw(qid, "preQuestSingle") or QRaw(qid, "preQuestGroup")) then skip = true; Why(TR"Questie: nicht machbar") end
            if not skip and ns.IsEventQuestSkipped and ns.IsEventQuestSkipped(qid) then skip = true; Why(TR"Feiertag") end
            -- auch bei Quests mit Vorquest: was Questie ausblendet, gibt es auf dem Server nicht (Event vorbei,
            -- entfernt, falsche Phase), und erledigte Folgequests heissen, dass diese Quest weg ist
            if not skip then local r = IsHiddenQuest(qid); if r then skip = true; Why(r) end end
          end
          -- Questlog Route: fertige Dungeon Quests trotzdem abgeben
          if opts.logOnly and logProg[qid] and logProg[qid].complete then skip = false end
          -- Ruf bei einer Fraktion noch zu niedrig? (angenommene Quests bleiben)
          if not skip and not inLog[qid] and not forM and ns.RepCheck and not ns.RepCheck(qid) then skip = true; Why(TR"Ruf zu niedrig") end
          -- 18.5: von dir uebersprungen (Annehmen ging nicht): erst 3 Level spaeter wieder (Zurueck auf den Schritt hebt das auf)
          if not skip and not inLog[qid] and not forM and not forced[qid] and ns.OptSkipped and ns.OptSkipped(qid, L0) then skip = true; Why(TR"von dir übersprungen") end
          if dungCand then
            if not skip then dungPick[#dungPick + 1] = qid; Why(TR"Dungeon Quest, nur annehmen") end
            skip = true
          end
          -- Elite und Gruppenquests nur in der Gruppe (oder wenn solo eingeschaltet), angenommene immer
          local elite = not skip and ns.IsEliteQuest and ns.IsEliteQuest(qid)
          if elite and not inLog[qid] and not ns.EliteAllowed() then
            -- Alles: Elite Quests kommen, sobald du sie allein schaffst (deutlich ueber dem Quest Level)
            if opts.eliteLater and ok and ql and L0 >= ql + ELITE_SOLO then elite = "solo"
            else skip = true; Why(opts.eliteLater and TR"Elite, später allein machbar" or TR"Elite, nur in Gruppe") end
          end
          -- Feinjustierung: Dungeon Quests und Eskorten nur, wenn eingeschaltet (angenommene bleiben)
          if not skip and not inLog[qid] and not opts.logOnly then
            local dqOff = not (ns.DungeonQOn and ns.DungeonQOn())
            if dqOff and ns.IsDungeonQuest and ns.IsDungeonQuest(qid) then skip = true; Why(TR"Dungeon Quest, ausgeschaltet") end
            if not skip and ns.db.escorts == false and Q(qid, "triggerEnd") then skip = true; Why(TR"Eskorte oder Ereignis, ausgeschaltet") end
          end
          if not skip then
            local q = BuildQuest(qid, forced[qid] and anyAllowed or allowed, reach, (inLog[qid] or (forM and forM.log)) and true or false, (not forM) and logProg[qid] or nil)
            if not q then Why(TR"nicht erreichbar oder keine Daten") end
            -- 20.3r (Top 20 Haenger, K 00:55): nur bei Alles und nicht angenommen
            -- 20.3s (rauchrc_r Duo Grind Block 485 Min): nicht beim Nachrechnen einer Luecke (Stufe 1 setzt auch all),
            -- dort fehlten die Quests und es wurde gegrindet
            if q and opts.all and not opts.gapFill and not inLog[qid] and not forced[qid] and not forM then
              if q.itemEliteOnly and not ns.EliteAllowed() then
                q = nil; Why(TR"Item nur von Elite, Dungeon oder Raid")
              elseif q.itemRandom and not opts.rest then
                q = nil; Why(TR"Zufall Drop, kommt auf Max Level")
              end
            end
            if q and forced[qid] then q.forced = true; q.upgrade = true end
            if q and elite == "solo" then q.name = q.name .. TR" |cffff9030(Elite)|r"; q.elite = true; q.eliteSolo = true
            elseif q and elite then q.name = q.name .. TR" |cffff5050(Gruppe)|r"; q.elite = true end
            -- Klassenquests (Formen, Totems, Begleiter, Waffen ...) immer fest einplanen
            if q and forM then
              -- du bekommst dafuer keine XP, darum zaehlt sie nicht zum Abschnitt; sie kommt trotzdem fest rein
              q.otherCls, q.forName, q.preDone = forM.cls, table.concat(forM.names, ", "), forM.done
              q.value, q.killXP, q.classQ = 0, 0, true
              q.name = q.name .. (TR" |cffff80ff(Klasse %s)|r"):format(q.forName)
            elseif q and rc and rc > 0 then q.classQ = true; q.name = q.name .. TR" |cffff80ff(Klasse)|r" end
            -- neuer Charakter: die ersten Quests im Startgebiet immer mitnehmen, egal welches Profil
            -- (nur Quests, die in der Zone anfangen, in der du gerade bist: keine weit entfernten Quests mit niedrigem Level)
            if q and not seedOn and (q.ql or 99) <= 5 and (sim and sim.L or UnitLevel("player") or 1) <= 10 then
              local here = sim and sim.map or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
              local n1 = q.nodes and q.nodes[1]
              if n1 and here and n1.map == here then q.startQ = true end
            end
            -- Zone kommt laut Plan erst spaeter dran: Quest erst ab dann (Startgebiet und eigene Zone fertig machen)
            if q and not q.inLog and not q.classQ and not q.forced and not (opts.all or opts.gold or opts.rep or opts.logOnly or opts.gearQ) then
              local n1 = q.nodes and q.nodes[1]
              local zm = n1 and n1.map
              local zf = zm and (zoneFrom[zm] or (ns.cityParent and ns.cityParent[zm] and zoneFrom[ns.cityParent[zm]]))
              if zf and zf - 1 > L0 + 0.5 then q.zoneL = math.floor(zf) - 1 end
            end
            -- 1.1 (K Stufe B 11): Quest mit Zeitlimit nur, wenn Annehmen, Ziele und Abgeben am Stueck in der Zeit gehen
            if q and not q.inLog and V11.TimedTooLong(q) then Why(TR"Zeitlimit nicht schaffbar"); q = nil end
            if q then table.insert(cands, q) end
          end
        end
      end
    end
    V11.Stage(myGen, 0, 30, i, #ids)
    if i < #ids then Later(Phase1); return end
    -- Vorquests von Questreihen, die unter dem Level Fenster liegen und noch fehlen: nochmal pruefen
    if not preRound and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ) then
      preRound = true
      local have, add = {}, {}
      for _, q in ipairs(cands) do have[q.id] = true end
      local function Want(id, depth)
        if type(id) ~= "number" or have[id] or preExtra[id] or complete[id] or blocked[id] or depth > 3 then return end
        preExtra[id] = true; add[#add + 1] = id
        for _, key in ipairs({ "preQuestSingle", "preQuestGroup" }) do
          local pre = Q(id, key)
          if type(pre) == "table" then for _, p2 in ipairs(pre) do Want(p2, depth + 1) end end
        end
      end
      for _, q in ipairs(cands) do
        for _, id in ipairs(q.preSingle or {}) do Want(id, 1) end
        for _, id in ipairs(q.preGroup or {}) do Want(id, 1) end
      end
      if #add > 0 then
        -- ids kann die Liste von Questie sein: nicht veraendern, eigene Liste weiter abarbeiten
        local nids = {}
        for k = 1, #add do nids[k] = add[k] end
        ids, i = nids, 0
        Later(Phase1); return
      end
    end
    ns.optStartArea = nil
    pcall(FindStartArea)
    -- kein Startgebiet gefunden (oder schon draussen): wie bisher die tiefen Quests der Zone fest mitnehmen
    if seedOn and not SAREA then
      local here = sim and sim.map or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
      for _, q in ipairs(cands) do
        local n1 = q.nodes and q.nodes[1]
        if (q.ql or 99) <= 5 and n1 and here and n1.map == here then q.startQ = true end
      end
    end
    -- 19.10 Tempo Alles, Variante "möglichst viel mitnehmen, Rest auf 60" (Wunsch Sascha): graue Quests nur, wenn alle
    -- ihre Punkte (Annehmen, Ziele, Abgeben) bei Punkten von Quests liegen, die du sowieso machst (nicht grau, im Log,
    -- Klasse). Graue Quests abseits davon kommen im letzten Abschnitt auf Max Level (Nachquesten).
    if opts.allCluster and not opts.rest then
      local gq = ns.OptGrayQL(L0)
      if gq then
        local R = ns.ALL_CLUSTER_YD or 300
        local CS = R
        local live = {}
        local function IsGray(q) return (q.ql or 99) <= gq and not (q.inLog or q.classQ or q.forced or q.startQ or q.upgrade) end
        for _, q in ipairs(cands) do
          if not IsGray(q) then
            for _, n in ipairs(q.nodes or {}) do
              if n.wx and n.cont then
                local k = n.cont * 1e8 + math.floor(n.wx / CS) * 1e4 + math.floor(n.wy / CS)
                local l = live[k]
                if not l then l = {}; live[k] = l end
                l[#l + 1] = n
              end
            end
          end
        end
        local function Near(n)
          if not (n.wx and n.cont) then return false end
          local cx, cy = math.floor(n.wx / CS), math.floor(n.wy / CS)
          for dx = -1, 1 do
            for dy = -1, 1 do
              for _, m in ipairs(live[n.cont * 1e8 + (cx + dx) * 1e4 + (cy + dy)] or {}) do
                if m.q ~= n.q and (m.wx - n.wx) ^ 2 + (m.wy - n.wy) ^ 2 <= R * R then return true end
              end
            end
          end
          return false
        end
        local okQ, byId = {}, {}
        for _, q in ipairs(cands) do
          byId[q.id] = q
          local ok = true
          if IsGray(q) then
            for _, n in ipairs(q.nodes or {}) do if not Near(n) then ok = false; break end end
          end
          okQ[q.id] = ok
        end
        -- Vorquests von Quests, die bleiben, bleiben auch (sonst faellt die ganze Reihe weg)
        local function Need(id, d)
          local q = byId[id]
          if not q or d > 8 then return end
          if not okQ[id] then okQ[id] = true end
          for _, p in ipairs(q.preSingle or {}) do if byId[p] and not okQ[p] then Need(p, d + 1) end end
          for _, p in ipairs(q.preGroup or {}) do if byId[p] and not okQ[p] then Need(p, d + 1) end end
        end
        for _, q in ipairs(cands) do if okQ[q.id] then Need(q.id, 0) end end
        local keep, nOut = {}, 0
        for _, q in ipairs(cands) do
          if okQ[q.id] then keep[#keep + 1] = q
          else nOut = nOut + 1; curQ = q.id; Why(TR"grau und abseits, kommt auf Max Level") end
        end
        curQ = nil
        -- in derselben Tabelle (andere Stellen halten sie schon)
        local n0 = #cands
        for k = 1, #keep do cands[k] = keep[k] end
        for k = #keep + 1, n0 do cands[k] = nil end
        ns.optAllOut = nOut
      end
    end
    -- 20.3z4 (S Test 20.3z3, K 19:06/19:09: Nach 60 Route wurde nie fertig, "rechnet alle Quests bis Level 60" mit allen
    -- Quests der Welt): auf Max Level in Stuecken. Nur die naechsten REST_CHUNK Quests ab dir (angenommene immer, Vorquests
    -- dazu), der Rest kommt mit dem naechsten Stueck, wenn dieses fertig ist
    local chunkMax = (opts.rest and not (ns.db and ns.db.allesBisFertig) and REST_CHUNK)
      or (opts.sim and (opts.stufe or 0) >= V11.STUFE_CAP_FROM and V11.STUFE_MAX_CANDS) or nil
    if chunkMax and #cands > chunkMax then
      local function D(q)
        local n = q.nodes and q.nodes[1]
        if not (n and n.wx and n.cont and start.wx) then return math.huge end
        local d = math.sqrt((n.wx - start.wx) ^ 2 + (n.wy - start.wy) ^ 2)
        if n.cont ~= start.cont then d = d + 100000 end
        return d
      end
      local byId2, keepSet = {}, {}
      for _, q in ipairs(cands) do byId2[q.id] = q end
      -- v11e (Pr P26, Nach 60 leer in Durotar und Dun Morogh): ein Stueck aus lauter Folgequests, deren Vorquest weder
      -- erledigt noch unter den Kandidaten ist, gibt 0 Schritte und die Route war fertig. Solche Quests jetzt nicht ins
      -- Stueck (sie kommen, wenn die Vorquest erledigt ist), und schon versuchte Quests eines leeren Stuecks auch nicht
      local function Have(id) return complete[id] or byId2[id] ~= nil end
      local function Blocked(q)
        if q.inLog or q.forced or q.classQ then return false end
        if opts.rest and ns.restTried and ns.restTried[q.id] then return true end
        if opts.rest and V11.RestFoeHigh(q, L0) then return true end
        if q.preSingle and #q.preSingle > 0 then
          local any = false
          for _, id in ipairs(q.preSingle) do if Have(id) then any = true; break end end
          if not any then return true end
        end
        for _, id in ipairs(q.preGroup or {}) do if not Have(id) then return true end end
        return false
      end
      local list = {}
      for _, q in ipairs(cands) do
        if not Blocked(q) then list[#list + 1] = { q = q, d = (q.inLog or q.forced or q.classQ) and -1 or D(q) } end
      end
      table.sort(list, function(a, b) return a.d < b.d end)
      local function Keep(q, depth)
        if not q or keepSet[q.id] or depth > 8 then return end
        keepSet[q.id] = true
        for _, p in ipairs(q.preSingle or {}) do Keep(byId2[p], depth + 1) end
        for _, p in ipairs(q.preGroup or {}) do Keep(byId2[p], depth + 1) end
      end
      local n = 0
      for _, e in ipairs(list) do
        if e.d < 0 or n < chunkMax then Keep(e.q, 0); if e.d >= 0 then n = n + 1 end end
      end
      local keep = {}
      for _, q in ipairs(cands) do if keepSet[q.id] then keep[#keep + 1] = q end end
      local n0 = #cands
      for k = 1, #keep do cands[k] = keep[k] end
      for k = #keep + 1, n0 do cands[k] = nil end
      if opts.rest then
        ns.optRestMore = n0 - #keep
        ns.optRestChunk = {}
        for _, q in ipairs(keep) do ns.optRestChunk[q.id] = true end
        if ns.TestLog then ns.TestLog("RECHNEN", ("Nach 60 in Stuecken: %d von %d Quests in diesem Stueck (die naechsten ab dir), %d spaeter"):format(#keep, n0, n0 - #keep)) end
      else
        ns.optRestMore = nil
        if ns.TestLog then ns.TestLog("RECHNEN", ("Stufe %d begrenzt: %d von %d Quests (die naechsten ab Abschnitts Start)"):format(opts.stufe or 0, #keep, n0)) end
      end
    else
      ns.optRestMore = nil
    end
    ns.optCands = #cands
    Phase2()
  end

  -- 2. Auswahl und Einfuegen
  local route = {}
  local chosen = {}   -- qid -> q
  local byId = {}
  local totalXP = 0

  -- erledigt im Sinne der Planung: abgeschlossen oder (Abgabe) schon in der Route
  local function PreOK(q)
    local function Have(id) return complete[id] or chosen[id] or (q.preDone and q.preDone[id]) end
    if q.preSingle and #q.preSingle > 0 then
      local any = false
      for _, id in ipairs(q.preSingle) do if Have(id) then any = true; break end end
      if not any then return false end
    end
    for _, id in ipairs(q.preGroup or {}) do if not Have(id) then return false end end
    if q.excl then for _, id in ipairs(q.excl) do if chosen[id] or complete[id] then return false end end end
    return true
  end

  -- 19.12: haengt die Grenze an den Gegnern, ein Viertel Level Luft (der Spieler liegt oft etwas hinter dem Plan,
  -- Sim: Gegner 3 ueber dir meist bei Level x.9, geplant war das naechste Level)
  -- Sim Durotar: mit einem Viertel Level Luft 110.2 statt 105.1 Std bis 60 (Gegner 3+ nur 3 statt 7 Mal, alle wegen
  -- Spieler kurz vor dem naechsten Level). Zu teuer, darum aus (0)
  local SAFE_MARGIN = 0
  local function SafeMargin(q, rl)
    if SAFE_MARGIN <= 0 or not (q.mobCap and q.safeL and rl == q.safeL and q.safeL >= q.mobCap and rl < 60) then return 0 end
    return math.floor(((ns.xpTotal[rl + 1] or 0) - (ns.xpTotal[rl] or 0)) * SAFE_MARGIN)
  end
  -- frueheste Position fuer das Annehmen: nach den Abgaben der Vorquests und wenn das Level reicht
  local xpBase = 0 -- XP, die vor dem gerade gebauten Block schon gesammelt ist
  local function EarliestA(q, idx, cumXP)
    local lo = 1
    local function After(id)
      local pq = chosen[id]
      if pq and pq.T and idx[pq.T] then lo = math.max(lo, idx[pq.T] + 1) end
    end
    for _, id in ipairs(q.preSingle or {}) do After(id) end
    for _, id in ipairs(q.preGroup or {}) do After(id) end
    -- Mindestlevel: erst wenn genug XP gesammelt ist (gefaehrliche Quests etwas spaeter)
    local rl = q.rl
    if q.safeL and q.safeL > rl then rl = math.min(60, q.safeL) end
    if q.zoneL and q.zoneL > rl then rl = q.zoneL end
    local need = (ns.xpTotal[rl] or 0) - xp0 + SafeMargin(q, rl)
    if need > 0 then
      local ok = false
      for p = lo, #route + 1 do
        if (cumXP[p] or 0) + xpBase >= need then lo = p; ok = true; break end
      end
      if not ok then return nil end
    end
    return lo
  end

  -- XP vor Position p (Abgaben davor)
  -- zweiter Wert: Ruhebonus, der an Position p noch uebrig ist
  local function CumXP()
    local c, rla, sum, rl = {}, {}, 0, rested0
    for p = 1, #route + 1 do
      c[p], rla[p] = sum, rl
      local n = route[p]
      if n and n.kind == "O" and n.kxp and not xpNoKill then
        local b = math.min(rl, n.kxp); rl = rl - b
        sum = sum + n.kxp + b
      end
      if n and n.kind == "T" then
        sum = sum + (n.q.value or 0) - (xpNoKill and 0 or (n.q.kxpSum or 0))
        if not xpNoKill and rl > 0 then
          local b = math.min(rl, math.max(0, (n.q.killXP or 0) - (n.q.kxpSum or 0))); rl = rl - b
          sum = sum + b
        end
      end
      if n and n.kind == "G" then sum = sum + (n.gain or 0); rl = math.max(0, rl - (n.bonus or 0)) end
    end
    return c, rla
  end

  -- guenstigste Einfuegestelle fuer einen Knoten zwischen lo und hi (Positionen 1..#route+1)
  local function BestSpot(n, lo, hi)
    local best, bc
    for p = lo, hi do
      Tick()
      local prev = route[p - 1] or start
      local nxt = route[p]
      local c = D(prev, n) + (nxt and (D(n, nxt) - D(prev, nxt)) or 0)
      if not bc or c < bc then best, bc = p, c end
    end
    -- Abgeben: geht es gleich (hoechstens ca 10 Sek mehr Weg), dann gleich und nicht erst spaeter
    -- (Log Troll Krieger: "wieso gibt er die Quest nebenan nicht gleich ab?")
    if best and n.kind == "T" and best > lo and not opts.gold then
      local tol = speed * 10
      for p = lo, best - 1 do
        local prev = route[p - 1] or start
        local nxt = route[p]
        local c = D(prev, n) + (nxt and (D(n, nxt) - D(prev, nxt)) or 0)
        if c <= bc + tol then return p, c end
      end
    end
    return best, bc
  end

  -- Questlog: auf Forever hoechstens 40 Quests gleichzeitig
  local LOGMAX = ns.LogMax()
  local logStart = 0
  for _ in pairs(inLog) do logStart = logStart + 1 end
  local function LogOK()
    local n = logStart
    for _, nd in ipairs(route) do
      if nd.kind == "A" then n = n + 1; if n > LOGMAX then return false end
      elseif nd.kind == "T" then n = n - 1 end
    end
    return true
  end

  -- 19.11: Quest schon im Log, Gegner noch 3 oder mehr Level ueber dir: Ziele erst, wenn das Level reicht.
  -- Ist das Log dann voll, kommt der Hinweis zum Aufraeumen (logSaid, ns.optLogMob fuer ns.LogCleanup)
  local logSaid = false
  local function LogMobLo(q, cum)
    -- 19.28: eigene Klassenquests im Log auch (fremde fuer einen Mitspieler nicht)
    if q.A or not (q.inLog and (q.mobCap or q.eliteL) and not q.otherCls) then return 1 end
    -- 19.31: Elite Gegner allein mindestens 2 Level unter dir (q.eliteL), auch fuer Quests im Log
    -- 19.32 (Sim rauch1931dev: Under the Shadow, Elite 60 allein mit Level 58 bis 60): die Grenze 60 gilt nur fuer die
    -- normalen Gegner. Elite ueber 58 gibt es allein nie, nur in der Gruppe
    local cl = math.min(60, q.mobCap or 0)
    if q.eliteL and q.eliteL > cl then
      if q.eliteL > 60 then q.logMob = true; return nil end
      cl = q.eliteL
    end
    local need = (ns.xpTotal[cl] or 0) - xp0
    if need <= 0 then return 1 end
    for p = 1, #route + 1 do if (cum[p] or 0) >= need then return p end end
    q.logMob = true
    return nil
  end

  local function InsertQuest(q)
    local idx = IndexMap(route)
    local cum = CumXP()
    local before = TotalTime(route, start, speed)
    local inserted = {}
    local lo = 1
    if not q.A then
      lo = LogMobLo(q, cum)
      if not lo then q.why = TR"Level noch zu tief"; return nil end
    end
    if q.A then
      local e = EarliestA(q, idx, cum)
      if not e then q.why = TR"Level noch zu tief"; return nil end
      local p = BestSpot(q.A, e, #route + 1)
      table.insert(route, p, q.A)
      table.insert(inserted, q.A)
      lo = p + 1
    end
    -- Stelle eines schon eingefuegten Knotens (verschiebt sich, wenn etwas davor eingefuegt wird)
    local function PosOf(nd) for k = 1, #route do if route[k] == nd then return k end end end
    for _, o in ipairs(q.objNodes) do
      -- vorab sammelbar: auch schon vor dem Annehmen, wenn es auf dem Weg liegt
      local lo2 = 1
      if not o.pre then
        local pa = q.A and PosOf(q.A)
        lo2 = math.max(pa and pa + 1 or 1, lo)
      end
      local p = BestSpot(o, lo2, #route + 1)
      table.insert(route, p, o)
      table.insert(inserted, o)
      -- ein vorab gesammeltes Ziel vor dem Annehmen schiebt alles dahinter eins weiter
      if p < lo then lo = lo + 1 else lo = p + 1 end
    end
    -- Abgeben: nach dem Annehmen und nach allen Zielen (Stellen neu suchen: vorab gesammelte Ziele vor dem
    -- Annehmen haben es nach hinten geschoben, vorher stand die Abgabe dann vor dem Annehmen)
    for _, nd in ipairs(inserted) do local pp = PosOf(nd); if pp and pp + 1 > lo then lo = pp + 1 end end
    local p = BestSpot(q.T, lo, #route + 1)
    table.insert(route, p, q.T)
    table.insert(inserted, q.T)
    if q.A and not LogOK() then
      -- Log waere voll: Abgabe direkt nach dem letzten Ziel versuchen
      for k = #route, 1, -1 do if route[k] == q.T then table.remove(route, k) end end
      table.insert(route, math.min(lo, #route + 1), q.T)
    end
    if q.A and not LogOK() then
      -- geht trotzdem nicht: Quest weglassen
      local set = {}
      for _, n in ipairs(inserted) do set[n] = true end
      for k = #route, 1, -1 do if set[route[k]] then table.remove(route, k) end end
      q.why = TR"Questlog voll"
      return nil
    end
    if ns.dbgOrder3 then ns.dbgOrder3(route, q) end
    return TotalTime(route, start, speed) - before, inserted
  end

  local function Remove(nodes)
    local set = {}
    for _, n in ipairs(nodes) do set[n] = true end
    for k = #route, 1, -1 do if set[route[k]] then table.remove(route, k) end end
  end

  -- Quest einbauen, wenn sie sich lohnt. Allein zu teuer: zusammen mit den Quests in der gleichen
  -- Gegend (Paket) nochmal pruefen. Gibt die aufgenommenen Quests zurueck (oder nil).
  local thr -- wird weiter unten gesetzt
  local function Need(q)
    local f = (q.unlocks > 0 or q.inLog) and 0.4 or 1
    if q.upgrade then f = math.min(f, 0.3) end
    return (q.classQ or q.startQ or q.forced) and 0 or thr * f
  end
  local function TryAdd(q)
    if q.lowEm and not emergency then q.why = TR"tiefe Quest, nur wenn Quests fehlen"; return nil end
    local dt, ins = InsertQuest(q)
    if not dt then return nil end
    -- Klassenquest eines Mitlaeufers: alle warten auf ihn. Dauert sie lange, macht er sie lieber als Abstecher
    if q.otherCls and dt > 900 then Remove(ins); q.why = TR"Klassenquest eines Mitspielers, zu lang (Abstecher)"; return nil end
    local need = Need(q)
    local rate = (q.value * (q.gw or 1) + (q.chain or 0) * 0.5 * (q.gs or 1)) / math.max(1, dt) * 3600
    local over = opts.maxTime and TotalTime(route, start, speed, true) > opts.maxTime
    if rate >= need and not over then q.why = nil; return { q } end
    Remove(ins)
    if not over and q.pkg and #q.pkg > 0 then
      local before = TotalTime(route, start, speed)
      local group, insList, val, ok = { q }, {}, 0, true
      for _, p in ipairs(q.pkg) do
        if not chosen[p.id] and PreOK(p) and not (p.lowEm and not emergency) then table.insert(group, p) end
      end
      if #group > 1 then
        local got = {}
        for _, p in ipairs(group) do
          local d2, i2 = InsertQuest(p)
          if d2 then table.insert(insList, i2); table.insert(got, p); val = val + p.value * (p.gw or 1) + (p.chain or 0) * 0.5 * (p.gs or 1)
          elseif p == q then ok = false; break end
        end
        local after = TotalTime(route, start, speed)
        local over2 = opts.maxTime and TotalTime(route, start, speed, true) > opts.maxTime
        if ok and #got > 1 and not over2 and val / math.max(1, after - before) * 3600 >= need then
          for _, p in ipairs(got) do p.why = nil end
          return got
        end
        for k = #insList, 1, -1 do Remove(insList[k]) end
      end
    end
    q.why = over and TR"Zeit Budget voll" or TR"lohnt sich nicht (zu weit für zu wenig XP)"
    return nil
  end

  local pass, qi = 0, 0
  local order
  local function Phase3() end -- forward
  local Blocks
  local WarmUp       -- Grinden am Anfang, wenn noch keine Quest vom Level her geht
  local fallback = 0
  local relax = 0 -- Quests bis zu 2 Level frueher (orange), bevor gegrindet wird
  local warm = 0 -- kurze Grind Pausen am Anfang, damit die naechsten Quests vom Level her gehen
  local Improve
  local EffGrind     -- echte Grind XP pro Std an den Spots (fuer die Quest Schwelle)

  Phase2 = function()
    for _, q in ipairs(cands) do byId[q.id] = q end
    -- Nutzen schaetzen: XP bei Startlevel pro Zeit (allein gemacht)
    for _, q in ipairs(cands) do
      -- tiefe Quest (bis 2 Level unter der normalen Grenze): nur im Notfall, wenn die Quests nicht reichen
      q.lowEm = (emDown > 0 and not q.inLog and not q.forced and not q.classQ and not preExtra[q.id]
        and (q.ql or 0) < L0 - qlDown0) or nil
      if opts.rep then
        q.value = repOf[q.id] or 0
      elseif opts.gold then
        -- Gold: Questbelohnung (gelernt oder geschaetzt) plus Beute der Mobs fuer die Ziele
        local m = ns.QuestMoney and ns.QuestMoney({ id = q.id, level = q.ql }) or 0
        local kills = 0
        for _, n in ipairs(q.objNodes or {}) do if n.npcs then kills = kills + (n.count or 0) end end
        q.loot = math.floor(kills * q.ql * q.ql * 0.15)
        q.value = m + q.loot
      else
        q.value = QuestXPAt(q.id, q.ql, math.floor(L0 + 1)) + (q.killXP or 0)
      end
      local t, prev = 0, start
      Tick()
      for _, n in ipairs(q.nodes) do t = t + D(prev, n) / speed + n.dur; prev = n end
      q.solo = q.value / math.max(30, t)
      -- schaltet die Quest Folgequests frei, die auch Kandidaten sind?
      q.unlocks = 0
    end
    for _, q in ipairs(cands) do
      for _, id in ipairs(q.preSingle or {}) do if byId[id] then byId[id].unlocks = byId[id].unlocks + 1 end end
      for _, id in ipairs(q.preGroup or {}) do if byId[id] then byId[id].unlocks = byId[id].unlocks + 1 end end
    end
    -- Upgrades aus der Ausruestungsseite zaehlen wie eine gute Belohnung
    local upg = {}
    for _, g in ipairs(ns.gearQuests or {}) do if g.id and (g.gain or 0) > 0 then upg[g.id] = true end end
    for _, q in ipairs(cands) do q.upgrade = upg[q.id] or nil end
    -- Gefahr: Mobs weit ueber dir, Elite allein. Starke Solo Klassen duerfen etwas frueher.
    local _, cls = UnitClass("player")
    -- Mobs hoechstens 2 Level ueber dir (Questlevel auch hoechstens 2).
    -- 19.11 (Sascha): fest fuer alle Klassen, vorher durften Jaeger, Hexer und Paladin 3 und beim Auffuellen (zu wenig
    -- Quests) alle 3, Jaeger 4. Jetzt: allein nie eine Quest, deren Gegner 3 oder mehr Level ueber dir sind
    local tol = 0
    local inGrp = IsInGroup and IsInGroup()
    local gd = GroupGap()
    -- 20.3w (S 12:01, K 12:02, Sim Duo Endspiel ab 55 ohne Quests): in der Gruppe ab GRP_END_L Quests und Elite/Gruppen
    -- Quests 1 Level frueher einplanen. Solo unveraendert
    local grpEnd = inGrp and L0 >= GRP_END_L
    for _, q in ipairs(cands) do
      -- 19.11: Ziele ohne Kills (Gegenstaende, Orte): die Mobs, die dort stehen, zaehlen wie Gegner
      local area
      for _, n in ipairs(q.nodes or {}) do
        if n.kind == "O" and not n.npcs and n.map then
          local lv = AreaMobLevel(n.map, n.x, n.y)
          n.areaL = lv and math.floor(lv + 0.5) or nil -- 19.13: fuer die Pruefung beim Ankommen
          if lv and (not area or lv > area) then area = lv end
        end
      end
      q.areaL = area and math.floor(area + 0.5) or nil
      -- Sascha 08:35: Gegner, die man toeten muss, hoechstens 2 ueber dir; Gegner, die am Zielort nur herumstehen,
      -- hoechstens 4 ueber dir; in der Gruppe je 1 Level mehr
      local foeCap
      if q.mobMax then foeCap = q.mobMax - 2 end
      if q.areaL and (not foeCap or q.areaL - 4 > foeCap) then foeCap = q.areaL - 4 end
      q.foeL = math.max(q.mobMax or 0, q.areaL or 0)
      -- feste Grenze, auch fuer Quests im Log (LogMobLo). Ist das Log voll und sonst nichts machbar, fragt das Addon
      -- nach dem Aufraeumen (die Route nimmt diese Quests trotzdem nicht)
      -- 19.28: in der Gruppe nicht mehr 1 Level mehr, sondern ab dem Gruppen Schnitt (gd, siehe GroupGap)
      q.mobCap = foeCap and (foeCap + gd) or nil
      -- 19.32: die Grenze lernt pro Charakter mit (EliteLernen.lua, Start 2)
      q.eliteL = (q.eliteMob and not inGrp) and (q.eliteMob + (ns.EliteGap and ns.EliteGap() or ELITE_MOB_GAP)) or nil
      if not q.inLog and not q.classQ then
        local safe = foeCap and (foeCap - tol) or nil
        q.mobSafe = safe
        -- auch ohne bekannte Mobs: keine Quest weit ueber deinem Level (rot), sie kommt etwas spaeter dran
        local qup = (ns.FLOW and ns.FLOW.qlUp) or 2
        -- 20.3t (S 06:36, Option B): in der Gruppe beim Nachrechnen einer Luecke Quests bis 3 statt 2 ueber dir
        if inGrp and opts.gapUp and qup > 0 then qup = qup + opts.gapUp end
        if grpEnd and qup > 0 and not opts.gapUp then qup = qup + 1 end
        if q.ql and qup > 0 then safe = math.max(safe or 0, q.ql - qup) end
        -- 19.11 (Sascha): in der Gruppe 1 Level mehr (vorher 2). 19.28: nicht mehr, Grenze ab dem Gruppen Schnitt
        if inGrp and safe then safe = safe + gd end
        if q.elite then
          -- Elite in der Gruppe: Questlevel hoechstens 2 ueber dem Gruppen Schnitt (vorher 1 ueber dir)
          local e = inGrp and (q.ql - 2 + gd - (grpEnd and 1 or 0)) or (q.ql + (q.eliteSolo and ELITE_SOLO or 2))
          safe = math.max(safe or 0, e)
        end
        -- 19.31 (Realitaets Regel, Sascha 23:35): sind die Gegner eines Ziels alle Elite, allein erst, wenn sie mindestens
        -- 2 Level unter dir sind (q.eliteL, gilt auch in der zweiten Runde und in der Schluss Pruefung). In der Gruppe wie bisher
        if q.eliteL then safe = math.max(safe or 0, q.eliteL) end
        local dz = ns.db and ns.db.stats and ns.db.stats.deathZones
        local m = q.nodes[1] and q.nodes[1].map
        if safe and m and dz and (dz[m] or 0) >= 2 then safe = safe + 1 end
        q.safeL = safe
        q.safe0 = safe
      elseif q.classQ and not q.inLog and not q.otherCls then
        -- 19.28 (Realitaets Regel, Sascha: Quests und Gegner hoechstens 2 ueber dir): auch eigene Klassenquests warten, bis
        -- Questlevel und Gegner passen (vorher kamen sie immer ab dem Mindestlevel, zb Gegner 40 mit Level 36)
        local s2 = q.mobCap
        if q.ql then s2 = math.max(s2 or 0, q.ql - 2 + gd) end
        if q.eliteL then s2 = math.max(s2 or 0, q.eliteL) end
        if s2 then q.safeL = s2; q.safe0 = s2 end
      end
    end
    -- Questreihen: was die Folgequests zusammen bringen (nur Kandidaten, Tiefe begrenzt)
    local follow = {}
    for _, q in ipairs(cands) do
      for _, id in ipairs(q.preSingle or {}) do if byId[id] then follow[id] = follow[id] or {}; table.insert(follow[id], q) end end
      for _, id in ipairs(q.preGroup or {}) do if byId[id] then follow[id] = follow[id] or {}; table.insert(follow[id], q) end end
    end
    local function ChainValue(q, depth, seen)
      if depth > 6 then return 0 end
      local v = 0
      for _, f in ipairs(follow[q.id] or {}) do
        if not seen[f.id] then
          seen[f.id] = true
          v = v + f.value * ((f.classQ or f.upgrade) and 2 or 1) + ChainValue(f, depth + 1, seen)
        end
      end
      return v
    end
    for _, q in ipairs(cands) do q.chain = ChainValue(q, 1, { [q.id] = true }) end
    -- Pakete: Quests, deren Punkte alle hoechstens ca 1 Min Laufweg von den Punkten der anderen weg sind
    local R = speed * 60
    -- Luftlinie (billig) vor der echten Strecke: weit weg ist nie ein Paket, auch nicht per Flug
    local function SD(a, b)
      if not (a.wx and b.wx) then return math.huge end
      return math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * PATH
    end
    local function Near(q, p)
      if not (q.nodes[1] and p.nodes[1]) or q.nodes[1].cont ~= p.nodes[1].cont then return false end
      if SD(q.nodes[1], p.nodes[1]) > R * 4 then return false end
      if D(q.nodes[1], p.nodes[1]) > R * 4 then return false end
      local function Cover(a, b)
        for _, n in ipairs(a.nodes) do
          local best
          for _, m in ipairs(b.nodes) do
            if SD(n, m) <= R then local d = D(n, m); if not best or d < best then best = d end end
          end
          if not best or best > R then return false end
        end
        return true
      end
      return Cover(q, p) and Cover(p, q)
    end
    for i, q in ipairs(cands) do q.pkg = q.pkg or {} end
    for i = 1, #cands do
      Tick()
      for j = i + 1, #cands do
        local q, p = cands[i], cands[j]
        if Near(q, p) then table.insert(q.pkg, p); table.insert(p.pkg, q) end
      end
    end
    for _, q in ipairs(cands) do
      local v, dur = q.value, 0
      for _, n in ipairs(q.nodes) do dur = dur + n.dur end
      for _, p in ipairs(q.pkg) do
        v = v + p.value
        for _, n in ipairs(p.nodes) do dur = dur + n.dur + R / speed * 0.5 end
      end
      local walk = q.nodes[1] and D(start, q.nodes[1]) / speed or 0
      q.pkgRate = #q.pkg > 0 and v / math.max(30, walk + dur) or q.solo
      q.rank = math.max(q.solo, q.pkgRate) + (q.chain > 0 and q.chain * 0.5 / math.max(60, walk + dur) or 0)
      if q.upgrade then q.rank = q.rank * 1.5 end
    end
    -- Gruppe (du leitest, andere laufen mit): Quests, die mehr Mitspieler mitmachen koennen, zaehlen mehr.
    -- Wer schon erledigt hat, wem Volk, Klasse, Level oder Vorquest fehlt, kann nicht mit. Die XP Rechnung bleibt.
    local gi = not sim and ns.GroupPlanInfo and ns.GroupPlanInfo()
    if gi then
      local known, N = 0, #gi.members + 1
      for _, m in ipairs(gi.members) do
        if m.done then
          known = known + 1
          local behind = math.max(0, math.floor(L0) - (m.lvl or math.floor(L0)))
          local memo = {}
          local Can
          Can = function(q, depth)
            local id = q.id
            if memo[id] ~= nil then return memo[id] end
            memo[id] = false
            local ok
            if m.log and m.log[id] then ok = true
            elseif m.done[id] then ok = false
            -- Level: ihr steigt zusammen auf, nur wer deutlich hinter dir ist, kommt an hohe Quests noch nicht
            elseif behind >= 3 and (q.rl or 1) > L0 - behind + 2 then ok = false
            else
              ok = true
              local rc, rr = Q(id, "requiredClasses"), Q(id, "requiredRaces")
              if rc and rc > 0 and (m.cid or 0) > 0 and not ns.HasBit(rc, m.cid - 1) then ok = false end
              if ok and rr and rr > 0 and (m.rid or 0) > 0 and not ns.RaceOK(rr, m.rid) then ok = false end
              local function PreOK(pid)
                if m.done[pid] or (m.log and m.log[pid]) then return true end
                return depth < 4 and byId[pid] ~= nil and Can(byId[pid], depth + 1)
              end
              if ok and q.preSingle and #q.preSingle > 0 then
                local any = false
                for _, pid in ipairs(q.preSingle) do if PreOK(pid) then any = true; break end end
                ok = any
              end
              if ok then for _, pid in ipairs(q.preGroup or {}) do if not PreOK(pid) then ok = false; break end end end
            end
            memo[id] = ok
            return ok
          end
          for _, q in ipairs(cands) do
            Tick()
            if Can(q, 0) then q.gwN = (q.gwN or 0) + 1 end
          end
        end
      end
      if known > 0 then
        local all = 0
        for _, q in ipairs(cands) do
          -- ohne Liste (noch nicht angekommen) zaehlt der Mitspieler als dabei
          local share = (1 + (q.gwN or 0) + (#gi.members - known)) / N
          if share >= 0.999 then all = all + 1 end
          -- Quest XP bekommt nur, wer mitmachen kann; XP der Mobs fuer die Ziele bekommen alle
          if q.classQ or q.forced then
            q.gw, q.gs = 1, 1
          else
            local kill = math.min(q.value or 0, q.killXP or 0)
            local v = math.max(1, q.value or 1)
            q.gw = math.max(0.2, ((v - kill) * share + kill) / v)
            q.gs = share
          end
          q.rank = q.rank * q.gw
          q.gwN = nil
        end
        Report((TR"Gruppe: %d von %d Quests können alle mitmachen, die kommen bevorzugt"):format(all, #cands))
      end
    end
    order = {}
    for _, q in ipairs(cands) do table.insert(order, q) end
    table.sort(order, function(a, b)
      if (a.classQ and 1 or 0) ~= (b.classQ and 1 or 0) then return a.classQ and true or false end
      return a.rank > b.rank
    end)
    -- Schwelle an der echten Grind Rate hier messen (Spots, Mob Level, Weg), nicht an der reinen Kill Rate,
    -- und Grinden zaehlt nur halb (Quests gehen vor, Grinden ist der Notfall): eine Quest faellt nur raus,
    -- wenn sie wirklich viel Weg fuer wenig XP ist
    if thr > 0 and EffGrind and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.goldAll) then
      local okE, e = pcall(EffGrind)
      -- nur ab Zügig (bei Viele und Einfach ist die Schwelle schon tief, tiefer gaebe nur weite Wege und Kontinent Hopping)
      -- Schnell mit Grinden: Massstab ist das echte Grinden hier (mit Weg zum Spot). Eine Quest bleibt nur, wenn sie
      -- fast so schnell ist wie Grinden, sonst kommt eine kurze Grind Pause an ihre Stelle.
      local f = (okE and e and e > 0 and e < grind and opts.grindProf) and (e / grind) or 1
      local gw = (ns.FLOW and ns.FLOW.grindW) or 1
      if ns.dbgHook then ns.dbgHook("effg", grind, okE and e or 0, thr) end
      thr = thr * f * gw
    end
    pass, qi = 1, 0
    Later(Blocks)
  end

  -- Grenzwert: mindestens 60 Prozent vom Grinden (sonst lieber grinden oder naechste Zone)
  -- Speed Leveling: nur Quests, die schneller als Grinden sind; den Rest fuellen Grind Pausen
  -- Normal: Quests gehen vor, auch wenn Grinden etwas schneller waere. Nur was wirklich nichts bringt
  -- (weiter Weg fuer ein paar XP) faellt raus. Speed Leveling bleibt streng.
  thr = (opts.all or opts.logOnly or opts.gearQ or opts.goldAll) and 0 or grind * (opts.thrF or (opts.speed and 0.9 or 0.2))


  ------------------------------------------------------------
  -- 2b. Bloecke pro Kontinent: lohnt sich die Reise fuer einen ganzen Questblock?
  -- Fuer jeden Kontinent (und jeden Ankunftshafen) wird ein eigener Block gebaut.
  -- Genommen wird der Block mit der besten XP pro Stunde inklusive Reisezeit.
  -- Danach wieder von vorne ab dem Ende des Blocks: so entsteht hin, Block, zurueck, Block ...
  -- aber nur wenn es sich wirklich lohnt.
  ------------------------------------------------------------
  local function QuestCont(q)
    local c
    for _, n in ipairs(q.nodes) do
      if c == nil then c = n.cont elseif n.cont ~= c then return false end
    end
    return c
  end

  Blocks = function()
    V11.Stage(myGen, 30, 30, 1, 1)
    if (opts.gold and not opts.goldAll) or opts.rep then
      -- Grenzwert fuer Gold und Ruf: halb so gut wie die mittlere Quest
      local r = {}
      for _, q in ipairs(cands) do table.insert(r, q.solo * 3600) end
      table.sort(r)
      thr = (r[math.max(1, math.floor(#r / 2))] or 0) * 0.5
    end
    local conts, nc = {}, 0
    for _, q in ipairs(cands) do
      q.cont = QuestCont(q)
      if q.cont and not conts[q.cont] then conts[q.cont] = true; nc = nc + 1 end
    end
    if nc < 2 or not ns.TravelBest then Later(Phase3); return end

    local mainStart = start
    local seq, base, rounds = {}, 0, 0
    local switches = 0
    local pos = start
    local trials, ti, results
    local NextRound, RunTrial

    local function Done()
      route, start, xpBase = seq, mainStart, 0
      Later(Phase3)
    end

    -- einen Block auf Kontinent c ab Startpunkt bs bauen (asynchron)
    local function BuildBlock(c, bs, cross, travel, onDone)
      route, start, xpBase = {}, bs, base
      local pool = {}
      for _, q in ipairs(cands) do
        if q.cont == c and not chosen[q.id] then
          local t, prev = 0, bs
          for _, n in ipairs(q.nodes) do t = t + D(prev, n) / speed + n.dur; prev = n end
          q.key = math.max((q.value or 0) / math.max(30, t), (q.pkgRate or 0) * 0.9)
          if q.upgrade then q.key = q.key * 1.5 end
          table.insert(pool, q)
        end
      end
      table.sort(pool, function(a, b)
        if (a.classQ and 1 or 0) ~= (b.classQ and 1 or 0) then return a.classQ and true or false end
        return a.key > b.key
      end)
      local cap = CAP - base
      local got, added, k, passes = 0, {}, 0, 1
      local function Step()
        local n = 0
        local more = Budget(4)
        while k < #pool and more(n) do
          k = k + 1
          n = n + 1
          local q = pool[k]
          if not chosen[q.id] and got < cap and PreOK(q) then
            local acc = TryAdd(q)
            for _, p in ipairs(acc or {}) do
              chosen[p.id] = p
              got = got + p.value
              table.insert(added, p)
            end
          end
        end
        if k < #pool then Later(Step); return end
        if passes < 3 and got < cap then
          passes = passes + 1
          local more = false
          for _, q in ipairs(pool) do if not chosen[q.id] and PreOK(q) then more = true; break end end
          if more then k = 0; Later(Step); return end
        end
        local time = TotalTime(route, start, speed)
        local res = { c = c, route = route, start = bs, added = added, xp = got, time = time, cross = cross,
          travel = travel, eff = got > 0 and got / math.max(60, time + cross) * 3600 or 0 }
        -- zuruecknehmen, entschieden wird erst wenn alle Bloecke gerechnet sind
        for _, q in ipairs(added) do chosen[q.id] = nil end
        onDone(res)
      end
      Step()
    end

    RunTrial = function()
      ti = ti + 1
      local tr = trials[ti]
      if not tr then
        -- besten Block waehlen; fuer einen Wechsel muss der andere Kontinent klar besser sein
        local same, best = nil, nil
        for _, r in ipairs(results) do
          if r.c == pos.cont and (not same or r.eff > same.eff) then same = r end
        end
        local F = ns.FLOW or {}
        for _, r in ipairs(results) do
          local eff = r.eff
          local other = r.c ~= pos.cont and same and same.xp > 0
          if other then eff = eff / (F.contF or 1.15) end
          -- fuer einen kurzen Abstecher lohnt keine Schiffsreise: der Block muss eine Weile dauern
          if other and (F.minBlock or 0) > 0 and (r.time or 0) < F.minBlock then eff = 0 end
          if r.xp > 0 and eff > 0 and (not best or eff > best.score) then best = r; r.score = eff end
        end
        -- alle Quests: erst den eigenen Kontinent fertig machen, dann reisen
        if (opts.all or opts.gearQ) and same and same.xp > 0 then best = same end
        if not best or best.eff < thr * 0.7 then Done(); return end
        -- Fluss: pro Abschnitt hoechstens maxSwitch Mal den Kontinent wechseln (sonst hin, zurueck, hin ...)
        if best.c ~= pos.cont and #seq > 0 then
          switches = switches + 1
          if switches > (F.maxSwitch or 99) then Done(); return end
        end
        -- Wechsel auf einen anderen Kontinent nur, wenn der Block die bisherige Route nicht verschlechtert
        if best.c ~= pos.cont and #seq > 0 then
          local soFar = TotalTime(seq, mainStart, speed)
          local avg = soFar > 0 and base / soFar * 3600 or 0
          -- erst vergleichen, wenn schon genug Route da ist (ein kurzer Block verzerrt den Schnitt)
          if not opts.gearQ and soFar > 1200 and best.eff < avg * 0.8 then Done(); return end
        end
        for _, q in ipairs(best.added) do chosen[q.id] = q; totalXP = totalXP + q.value end
        for _, n in ipairs(best.route) do table.insert(seq, n) end
        base = base + best.xp
        pos = seq[#seq] or pos
        if best.c ~= mainStart.cont or best.travel then
          Report((TR"Block auf %s: %d Quests, ca %s inkl. Reise"):format(ns.ContName and ns.ContName(best.c) or (TR"Kontinent " .. best.c),
            #best.added, ns.Clock(best.time + best.cross)))
        end
        Later(NextRound)
        return
      end
      BuildBlock(tr.c, tr.bs, tr.cross, tr.travel, function(res)
        table.insert(results, res)
        Later(RunTrial)
      end)
    end

    NextRound = function()
      rounds = rounds + 1
      if rounds > 5 or base >= CAP then Done(); return end
      trials, results, ti = {}, {}, 0
      for c in pairs(conts) do
        if c == pos.cont then
          table.insert(trials, { c = c, bs = pos, cross = 0 })
        else
          -- jeder Ankunftshafen auf c ist ein eigener Versuch
          for _, l in ipairs(ns.travelLinks or {}) do
            for s = 1, 2 do
              local e = (s == 1) and l.b or l.a
              -- Ankunft ueber diese Verbindung
              local ep = ns.TravelEndpoint and ns.TravelEndpoint(e)
              if ep and ep.cont == c then
                local t2 = ns.TravelBest(pos, ep, speed)
                if t2 then table.insert(trials, { c = c, bs = { wx = ep.wx, wy = ep.wy, cont = ep.cont, map = ep.map, x = ep.x, y = ep.y }, cross = t2, travel = true }) end
              end
            end
          end
        end
      end
      -- doppelte Haefen entfernen
      local seen, uniq = {}, {}
      for _, t in ipairs(trials) do
        local key = t.c .. ":" .. math.floor(t.bs.wx or 0) .. ":" .. math.floor(t.bs.wy or 0)
        if not seen[key] then seen[key] = true; table.insert(uniq, t) end
      end
      trials = uniq
      -- 19.2 (Sim Teil W, CPU): pro anderem Kontinent nur die ports schnellsten Haefen bauen (ns.FLOW.ports, Standard 2).
      -- Jeder Hafen ist ein ganzer Block (3 Durchgaenge TryAdd), weiter weg liegende Haefen gewinnen fast nie.
      local keep = (ns.FLOW and ns.FLOW.ports) or 2
      if keep > 0 then
        local per, out = {}, {}
        for _, t in ipairs(trials) do
          if t.travel then per[t.c] = per[t.c] or {}; table.insert(per[t.c], t) else table.insert(out, t) end
        end
        for _, l in pairs(per) do
          table.sort(l, function(x, y) return x.cross < y.cross end)
          for i = 1, math.min(keep, #l) do table.insert(out, l[i]) end
        end
        trials = out
      end
      RunTrial()
    end

    NextRound()
  end

  Phase3 = function()
    local n = 0
    local added = false
    local more = Budget(3)
    while qi < #order and more(n) do
      qi = qi + 1
      n = n + 1
      local q = order[qi]
      if not chosen[q.id] and PreOK(q) and totalXP < CAP then
        local acc = TryAdd(q)
        if acc then
          for _, p in ipairs(acc) do chosen[p.id] = p; totalXP = totalXP + p.value end
          added = true
        end
      elseif not chosen[q.id] and not PreOK(q) then
        q.why = q.why or TR"Vorquest fehlt noch"
      end
    end
    V11.Stage(myGen, 30, 75, qi, #order)
    if qi < #order then Later(Phase3); return end
    -- weitere Durchgaenge: freigeschaltete Folgequests
    pass = pass + 1
    if pass <= 4 and totalXP < CAP then
      local more = false
      for _, q in ipairs(order) do if not chosen[q.id] and PreOK(q) then more = true; break end end
      if more then qi = 0; Later(Phase3); return end
    end
    -- Quests reichen nicht bis zum Ziel, weil die naechsten noch etwas zu hoch sind? Grinden mag keiner:
    -- erst die etwas hoeheren Quests (orange, hoechstens 3 ueber dem Questlevel) zulassen, dann erst grinden
    if relax < 2 and totalXP < xpNeed * 0.85 and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.speed) then
      local low = 0
      for _, q in ipairs(order) do if not chosen[q.id] and q.why == TR"Level noch zu tief" then low = low + 1 end end
      if low > 0 then
        relax = relax + 1
        local gg, changed = GroupGap(), 0
        for _, q in ipairs(cands) do
          if q.safe0 and not q.elite then
            -- zweite Runde: Quests bis 4 ueber dir, wenn die Mobs dort hoechstens 3 ueber dir sind
            -- (viele Level 60 Quests haben Mobs um 56, die gehen ab 56)
            -- 19.11 (Sascha): Questlevel hoechstens 3 ueber dir (vorher in der zweiten Runde 4), die Gegner hoechstens 2.
            -- 19.28 (Sascha 20:50: Quests UND Gegner nur bis plus 2): auch in der zweiten Runde Questlevel hoechstens 2 ueber dir.
            -- 19.31 (Sascha 21:44): zurueck wie seit 19.11, Questlevel bis 3 ueber dir, wenn alle Gegner hoechstens 2 ueber dir
            -- sind (mobCap). In der Gruppe ab dem Gruppen Schnitt (gg) wie seit 19.28
            local floor = (q.ql or 0) - 3 + gg
            local nl = math.max(q.safe0 - relax, floor, q.mobCap or 0, q.eliteL or 0)
            if q.safeL and nl < q.safeL then changed = changed + 1 end
            q.safeL = nl
          end
        end
        -- 19.28: geht keine Quest frueher, dann kein zweiter Durchgang (spart Rechenzeit)
        if changed > 0 then
          Report((TR"Quests reichen noch nicht bis zum Ziel: %d etwas höhere Quests werden früher eingeplant"):format(low))
          qi = 0; pass = 1
          Later(Phase3); return
        end
      end
    end
    -- Notfall vor dem Grinden: tiefere gruene Quests (bis 7 unter dir) dazu nehmen
    if not emergency and emDown > 0 and totalXP < xpNeed * 0.95 then
      local nLow = 0
      for _, q in ipairs(order) do if q.lowEm and not chosen[q.id] then nLow = nLow + 1 end end
      if nLow > 0 then
        emergency = true
        Report((TR"Quests reichen nicht: %d tiefere Quests kommen dazu, bevor gegrindet wird"):format(nLow))
        qi = 0; pass = 1
        Later(Phase3); return
      end
    end
    -- immer noch viel zu wenig: nur so lange grinden, bis die naechsten Quests gehen (nicht bis zum Ziel Level),
    -- dann wieder Quests. Das ersetzt stundenlange Grind Pausen am Ende des Abschnitts.
    if warm < 4 and next(chosen) and totalXP < xpNeed * 0.6 and grindOK and fillGap and L0 >= GRIND_MIN_L
      and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.all) and WarmUp and WarmUp(true) then
      warm = warm + 1; qi = 0; pass = 1
      Later(Phase3); return
    end
    -- gar nichts genommen, obwohl es Quests gibt? Nie mit leerer Route enden:
    -- 1. alle Quests nehmen, auch wenn Grinden rechnerisch schneller waere
    -- 2. erst bis zum Level der naechsten Quests grinden, dann die Quests
    if not next(chosen) and not opts.gold and not opts.rep and not opts.logOnly and not opts.gearQ then
      -- 19.11 (Sascha): Log voll mit Quests, deren Gegner noch zu hoch sind: nicht trotzdem machen, sondern aufraeumen
      -- lassen (Hinweis "Questlog aufräumen" nennt sie), bis dahin grinden bis das Level reicht
      if logStart >= LOGMAX - 2 and not logSaid then
        for _, q in ipairs(order) do
          if q.logMob and not chosen[q.id] then
            logSaid = true
            Report(TR"Questlog voll mit Quests, deren Gegner noch zu hoch sind. Brich ein paar davon ab (Questlog aufräumen), dann gehen wieder neue Quests.")
            -- 19.11 (Sascha): gleich fragen (Liste, "Ja, abbrechen" oder "Behalten"), nur fuer den echten Stand
            if not SIMLATE and ns.AutoLogCleanup and C_Timer then C_Timer.After(1, function() pcall(ns.AutoLogCleanup) end) end
            break
          end
        end
      end
      if fallback == 0 and thr > 0 then
        fallback = 1; thr = 0; qi = 0; pass = 1
        Later(Phase3); return
      elseif fallback <= 1 and WarmUp and WarmUp() then
        fallback = 2; thr = 0; qi = 0; pass = 1
        Later(Phase3); return
      end
    end
    local wsel = {}
    for _, q in ipairs(order) do if not chosen[q.id] then local r = q.why or TR"nicht eingeplant"; wsel[r] = (wsel[r] or 0) + 1 end end
    -- 19.11: Quests im Log, deren Gegner noch zu hoch sind (fuer "Questlog aufräumen"), mit dem Level der Gegner
    local lm = {}
    for _, q in ipairs(order) do if q.logMob and not chosen[q.id] then lm[q.id] = q.foeL or 0 end end
    if not SIMLATE then ns.optLogMob = lm end
    ns.optWhySel = wsel
    if ns.dbgHook then ns.dbgHook("why", wsel, L0, xpNeed, totalXP, thr, grind, order, chosen, complete) end
    -- Details zu fehlenden Vorquests (fuer /klg warum)
    local det = {}
    for _, q in ipairs(order) do
      if not chosen[q.id] and q.why == TR"Vorquest fehlt noch" and #det < 6 then
        local miss = {}
        local function St(id)
          local nm = Q(id, "name") or (TR"Quest " .. id)
          local st
          if complete[id] then st = TR"erledigt"
          elseif byId[id] then st = byId[id].why or TR"in Auswahl"
          elseif whyQ[id] then
            st = whyQ[id]
            if st == TR"Questie: nicht machbar" and QDB.IsDoableVerbose then
              local okV, txt = pcall(QDB.IsDoableVerbose, id, false, true, true)
              if okV and type(txt) == "string" then st = TR"Questie: " .. txt end
            end
          else
            local okL, ql2, rl2 = pcall(QLib.GetEffectiveQuestLevel, id)
            st = okL and rl2 and (TR"nicht im Level Fenster, ab " .. rl2) or TR"unbekannt"
          end
          return nm .. " (" .. st .. ")"
        end
        if q.preSingle and #q.preSingle > 0 then
          local any = false
          for _, id in ipairs(q.preSingle) do if complete[id] or chosen[id] then any = true end end
          if not any then
            local l = {}
            for k, id in ipairs(q.preSingle) do if k <= 3 then table.insert(l, St(id)) end end
            table.insert(miss, TR"eine von: " .. table.concat(l, " / "))
          end
        end
        for _, id in ipairs(q.preGroup or {}) do if not (complete[id] or chosen[id]) then table.insert(miss, St(id)) end end
        table.insert(det, (q.name or (TR"Quest " .. q.id)) .. TR" braucht " .. table.concat(miss, ", "))
      end
    end
    ns.optWhyDet = det
    if ns.dbgOrder then ns.dbgOrder("insert", route) end
    Later(Improve)
  end

  -- 4. Or-opt: einzelne Knoten an die beste erlaubte Stelle verschieben
  local improveRound, ni = 0, 0
  -- XP, die vor dem Annehmen da sein muss (Mindestlevel, gefaehrliche Quests etwas spaeter)
  local function NeedXP(q)
    local rl = q.rl or 1
    if q.safeL and q.safeL > rl then rl = math.min(60, q.safeL) end
    if q.zoneL and q.zoneL > rl then rl = q.zoneL end
    return (ns.xpTotal[rl] or 0) - xp0 + SafeMargin(q, rl)
  end
  local function Bounds(n, idx, cum)
    -- Grind Pause am Anfang bleibt, wo sie ist (die Quests danach brauchen das Level)
    if n.kind == "G" then local p = idx[n] or 1; return p, p end
    local q = n.q
    local lo, hi = 1, #route
    local function After(m) if m and idx[m] then lo = math.max(lo, idx[m] + 1) end end
    local function Before(m) if m and idx[m] then hi = math.min(hi, idx[m] - 1) end end
    if n.kind == "A" then
      for _, o in ipairs(q.objNodes) do Before(o) end
      Before(q.T)
      for _, id in ipairs(q.preSingle or {}) do local pq = chosen[id]; if pq then After(pq.T) end end
      for _, id in ipairs(q.preGroup or {}) do local pq = chosen[id]; if pq then After(pq.T) end end
      -- nicht vor die Stelle, an der das Level reicht
      local need = NeedXP(q)
      if need > 0 and cum then
        for p = 1, #route + 1 do
          if (cum[p] or 0) >= need then lo = math.max(lo, p); break end
          if p == #route + 1 then lo = math.max(lo, idx[n] or lo) end
        end
      end
    elseif n.kind == "O" then
      if not n.pre then After(q.A) end
      Before(q.T)
      if not q.A and cum then
        local ml = LogMobLo(q, cum)
        if ml then lo = math.max(lo, ml) else lo = math.max(lo, idx[n] or lo) end
      end
      -- Reihenfolge innerhalb der Quest: Item holen vor dem Ziel, das es braucht
      for _, m in ipairs(n.needs or {}) do After(m) end
      for _, m in ipairs(n.feeds or {}) do Before(m) end
    else
      After(q.A)
      for _, o in ipairs(q.objNodes) do After(o) end
      -- Folgequests muessen danach angenommen werden
      for _, oq in pairs(chosen) do
        local dep = false
        for _, id in ipairs(oq.preSingle or {}) do if id == q.id then dep = true end end
        for _, id in ipairs(oq.preGroup or {}) do if id == q.id then dep = true end end
        if dep and oq.A then Before(oq.A) end
      end
      -- die XP dieser Abgabe braucht ein spaeteres Annehmen fuers Level: nicht dahinter schieben
      local v = n.kind == "T" and q.value or 0
      local me = idx[n]
      if cum and v > 0 and me then
        for p = me + 1, #route do
          local m = route[p]
          if m.kind == "A" and m.q then
            local need = NeedXP(m.q)
            if need > 0 and (cum[p] or 0) - v < need then hi = math.min(hi, p - 1); break end
          end
        end
      end
    end
    return lo, hi
  end

  local Finish, GrindFill, HearthPlan, VendorPlan, EndPlan, BookPlan, TrainerPlan, GapHint
  -- Neuer Charakter im Startgebiet: erst alle Quests dort fertig machen, dann weiter in den naechsten Ort.
  -- Quests, die ganz im Startgebiet liegen, kommen nach vorne (Reihenfolge bleibt sonst gleich).
  local function StartFirst()
    if L0 >= 10 or not SAREA then return end
    local function In(n) return Region(n) == "S" end
    if not In(start) then return end
    local function Key(n) return (n.q and n.q.id and n.q.id > 0) and n.q or n end
    local allIn = {}
    for _, n in ipairs(route) do
      local k = Key(n)
      if allIn[k] == nil then allIn[k] = true end
      if not In(n) then allIn[k] = false end
    end
    -- Quests vorne brauchen ihre Vorquests und ihr Level auch vorne, sonst bleiben sie hinten
    local function PreIn(q)
      if q.preSingle and #q.preSingle > 0 then
        local any = false
        for _, id in ipairs(q.preSingle) do
          local pq = chosen[id]
          if (pq and allIn[pq]) or (not pq and complete[id]) then any = true; break end
        end
        if not any then return false end
      end
      for _, id in ipairs(q.preGroup or {}) do
        local pq = chosen[id]
        if pq and not allIn[pq] then return false end
      end
      return true
    end
    local again = true
    while again do
      again = false
      local sum = 0
      for _, n in ipairs(route) do
        local k = Key(n)
        if allIn[k] then
          if n.kind == "A" and n.q and (not PreIn(n.q) or NeedXP(n.q) > sum) then allIn[k] = false; again = true
          elseif n.kind == "T" and n.q then sum = sum + (n.q.value or 0)
          elseif n.kind == "G" then sum = sum + (n.gain or 0) end
        end
      end
    end
    local a, b = {}, {}
    for _, n in ipairs(route) do
      if allIn[Key(n)] then a[#a + 1] = n else b[#b + 1] = n end
    end
    if #a == 0 or #b == 0 then return end
    -- schon richtig sortiert?
    local sorted = true
    for i = 1, #a do if route[i] ~= a[i] then sorted = false break end end
    if sorted then return end
    for i = #route, 1, -1 do route[i] = nil end
    for _, n in ipairs(a) do route[#route + 1] = n end
    for _, n in ipairs(b) do route[#route + 1] = n end
    Report((TR"Startgebiet zuerst: %d Stopps dort, dann geht es weiter"):format(#a))
  end

  -- Von selbst neu gerechnet, waehrend du an einem Questziel bist: dieses Ziel bleibt der erste Schritt.
  -- Nur Quests aus dem Log (kein Annehmen davor in der Route), der Rest der Reihenfolge bleibt wie gerechnet.
  local function KeepFirst()
    local kq, ko = opts.keepQ, opts.keepObj
    if not kq then return end
    local pos
    for p, n in ipairs(route) do
      if n.kind == "O" and n.q and n.q.id == kq and (not ko or n.obj == ko) then pos = p; break end
    end
    if not pos or pos == 1 then return end
    local q = route[pos].q
    for p = 1, pos - 1 do if route[p].q == q and route[p].kind == "A" then return end end
    local nd = table.remove(route, pos)
    table.insert(route, 1, nd)
    if ns.TestLog then ns.TestLog("RECHNER", (TR"Aktives Questziel bleibt vorne: %s"):format(tostring(ko or q.name or kq))) end
  end

  -- 4a2. Zonen zusammenlegen: kommt eine Zone (oder ein Kontinent) mehrmals vor, ganze Besuche verschieben,
  -- damit man einmal hingeht und alles dort macht. Nur wenn alle Bedingungen halten und es insgesamt schneller ist.
  -- Verstoesse einer Reihenfolge zaehlen (Vorquest, Annehmen vor Ziel und Abgabe, Level, Questlog voll)
  local function Viol(r)
    local idx = IndexMap(r)
    local bad = 0
    local sum, cum, rl = 0, {}, rested0
    for p = 1, #r + 1 do
      cum[p] = sum
      local nd = r[p]
      if nd and nd.kind == "O" and nd.kxp and not xpNoKill then
        local b = math.min(rl, nd.kxp); rl = rl - b
        sum = sum + nd.kxp + b
      end
      if nd and nd.kind == "T" then
        sum = sum + (nd.q.value or 0) - (xpNoKill and 0 or (nd.q.kxpSum or 0))
        if not xpNoKill and rl > 0 then
          local b = math.min(rl, math.max(0, (nd.q.killXP or 0) - (nd.q.kxpSum or 0))); rl = rl - b
          sum = sum + b
        end
      end
      if nd and nd.kind == "G" then sum = sum + (nd.gain or 0); rl = math.max(0, rl - (nd.bonus or 0)) end
    end
    for p, nd in ipairs(r) do
      local q = nd.q
      -- Reihenfolge (Annehmen, Ziel, Abgeben, Vorquest) wiegt viel mehr als Level oder Questlog:
      -- eine Verschiebung darf nie eine Level Verletzung gegen eine falsche Reihenfolge tauschen
      local W = 100
      if nd.kind == "A" then
        for _, o in ipairs(q.objNodes or {}) do if idx[o] and idx[o] < p and not o.pre then bad = bad + W end end
        if q.T and idx[q.T] and idx[q.T] < p then bad = bad + W end
        for _, id in ipairs(q.preSingle or {}) do local pq = chosen[id]; if pq and pq.T and idx[pq.T] and idx[pq.T] > p then bad = bad + W end end
        for _, id in ipairs(q.preGroup or {}) do local pq = chosen[id]; if pq and pq.T and idx[pq.T] and idx[pq.T] > p then bad = bad + W end end
        local need = NeedXP(q)
        if need > 0 and cum[p] < need then bad = bad + 1 end
      elseif nd.kind == "O" then
        if not nd.pre and q.A and idx[q.A] and idx[q.A] > p then bad = bad + W end
        if q.T and idx[q.T] and idx[q.T] < p then bad = bad + W end
        for _, m in ipairs(nd.needs or {}) do if idx[m] and idx[m] > p then bad = bad + W end end
      elseif nd.kind == "T" then
        if q.A and idx[q.A] and idx[q.A] > p then bad = bad + W end
      end
    end
    local n = logStart
    for _, nd in ipairs(r) do
      if nd.kind == "A" then n = n + 1; if n > LOGMAX then bad = bad + 1 end
      elseif nd.kind == "T" then n = n - 1 end
    end
    return bad
  end
  local function Visits(r, keyOf)
    local out = {}
    for p, nd in ipairs(r) do
      local k = keyOf(nd)
      local v = out[#out]
      if v and v.k == k then v.j = p else out[#out + 1] = { k = k, i = p, j = p } end
    end
    return out
  end
  local function Moved(r, i, j, at)
    -- Block i..j vor die Stelle at (Index in r) setzen
    local block = {}
    for p = i, j do block[#block + 1] = r[p] end
    local out = {}
    for p = 1, #r + 1 do
      if p == at then for _, nd in ipairs(block) do out[#out + 1] = nd end end
      if p <= #r and (p < i or p > j) then out[#out + 1] = r[p] end
    end
    return out
  end
  -- einen Besuch verschieben (der beste, der Zeit spart und nichts verletzt); true wenn etwas verschoben wurde
  local function MergeOnce(keyOf)
    local vs = Visits(route, keyOf)
    if #vs < 3 then return false end
    local base = TotalTime(route, start, speed)
    local baseBad = Viol(route)
    local best, bestT
    for a = 1, #vs do
      for b = a + 1, #vs do
        Tick()
        if vs[a].k ~= nil and vs[a].k == vs[b].k then
          -- Besuch a nach hinten (direkt vor b) oder Besuch b nach vorne (direkt hinter a)
          local r1 = Moved(route, vs[a].i, vs[a].j, vs[b].i)
          local r2 = Moved(route, vs[b].i, vs[b].j, vs[a].j + 1)
          for _, r in ipairs({ r1, r2 }) do
            local t = TotalTime(r, start, speed)
            if t + 1 < (bestT or base) and Viol(r) <= baseBad then best, bestT = r, t end
          end
        end
      end
    end
    if not best then return false end
    for p = #route, 1, -1 do route[p] = nil end
    for p, nd in ipairs(best) do route[p] = nd end
    return true
  end
  -- 20.3i (S 18:43, AUF K 18:52): Quest Hubs, erst sammeln, dann abarbeiten. Kommt die Route an einem Questgeber
  -- vorbei (bis ca 70 Yards), dessen Quest sie erst spaeter annimmt, wird das Annehmen nach vorne an diese Stelle
  -- geholt, wenn es nichts verletzt (Vorquest, Level, Questlog, Annehmen vor Ziel und Abgabe) und der Umweg klein
  -- bleibt (je Quest hoechstens ca 140 Yards mehr, alles zusammen hoechstens 3 % der Zeit). So holt man im Ort alle
  -- Quests auf einmal statt spaeter extra zurueck. Allgemein, keine Quest Liste.
  local HUB_YD, HUB_EXTRA_YD, HUB_PCT = 70, 140, 0.03
  local function HubFirst()
    if opts.logOnly or opts.gold or opts.rep or opts.gearQ or opts.farm or #route < 4 then return end
    local base = TotalTime(route, start, speed)
    local budget, spent, moves = base * HUB_PCT, 0, 0
    -- 20.3o (Da Pruefung Nr 5): jeder Versuch kopiert die Route und prueft sie ganz (O(n) je Versuch). Hoechstens 150
    -- Versuche pro Rechnung, sonst haengt das Bild bei langen Alles Routen (laeuft in pcall, kann nicht pausieren)
    local copies = 0
    local baseBad = Viol(route)
    local function Near(a, b)
      if not (a and b and a.wx and b.wx) or a.map ~= b.map then return false end
      local dx, dy = a.wx - b.wx, a.wy - b.wy
      return dx * dx + dy * dy <= HUB_YD * HUB_YD
    end
    local j = 2
    while j <= #route do
      local n = route[j]
      local done = false
      if n.kind == "A" and n.q and n.wx then
        local prev, nxt = route[j - 1], route[j + 1]
        local gain = D(prev, n) + (nxt and (D(n, nxt) - D(prev, nxt)) or 0)
        local tried = 0
        for k = 1, j - 2 do
          local h = route[k]
          if tried < 6 and copies < 150 and Near(h, n) then
            tried = tried + 1
            local after = route[k + 1]
            local add = D(h, n) + (after and (D(n, after) - D(h, after)) or 0)
            local extra = add - gain
            if extra <= HUB_EXTRA_YD and spent + math.max(0, extra) / speed <= budget then
              copies = copies + 1
              local r = {}
              for p = 1, #route do if p ~= j then r[#r + 1] = route[p] end; if p == k then r[#r + 1] = n end end
              if Viol(r) <= baseBad then
                for p = #route, 1, -1 do route[p] = nil end
                for p, nd in ipairs(r) do route[p] = nd end
                spent = spent + math.max(0, extra) / speed
                moves = moves + 1
                done = true
                if ns.TestLog and moves <= 5 then ns.TestLog("RECHNEN", ("Quest Hub: %s gleich mitnehmen (Stopp %d statt %d, Umweg %d yd)"):format(tostring(n.q.name), k + 1, j, math.floor(math.max(0, extra)))) end
                break
              end
            end
          end
        end
      end
      j = j + 1
    end
    if moves > 0 then Report((TR"Quest Hubs: %d Quests gleich beim ersten Besuch angenommen"):format(moves)) end
  end

  local zmPass, zmIter, zmMoves = 1, 0, 0
  local ZoneMergeStep
  ZoneMergeStep = function()
    V11.Stage(myGen, 90, 90, 1, 1)
    -- erst Kontinente, dann Zonen (Staedte zaehlen zu ihrer Zone); ein Versuch pro Frame
    local keyOf = (zmPass == 1) and function(nd) return nd.cont end or function(nd) return Region(nd) end
    local maxI = (zmPass == 1) and (ns.FLOW.contMergeN or 6) or 25
    local moved = false
    if #route >= 6 and zmIter < maxI then
      -- direkt (nicht in pcall): MergeOnce gibt zwischendurch das Bild frei, Fehler faengt Later ab
      moved = MergeOnce(keyOf) and true or false
    end
    if moved then zmIter = zmIter + 1; zmMoves = zmMoves + 1; Later(ZoneMergeStep); return end
    if zmPass == 1 then zmPass, zmIter = 2, 0; Later(ZoneMergeStep); return end
    if zmMoves > 0 then Report((TR"Zonen zusammengelegt: %d Besuche verschoben"):format(zmMoves)) end
    if ns.dbgOrder then ns.dbgOrder("zonemerge", route) end
    pcall(StartFirst)
    pcall(HubFirst)
    if ns.dbgOrder then ns.dbgOrder("startfirst", route) end
    pcall(KeepFirst)
    if ns.dbgOrder then ns.dbgOrder("keepfirst", route) end
    if (opts.speed or (fillGap and grindOK)) and not startLock then Later(GrindFill)
    elseif fillGap and not startLock then Later(GapHint)
    else Later(HearthPlan) end
  end

  Improve = function()
    local n = 0
    local changed = false
    local more = Budget(15)
    while ni < #route and more(n) do
      ni = ni + 1
      n = n + 1
      local node = route[ni]
      local idx = IndexMap(route)
      local lo, hi = Bounds(node, idx, (node.kind == "A" or node.kind == "T") and CumXP() or nil)
      -- Gewinn durchs Herausnehmen
      local prev = route[ni - 1] or start
      local nxt = route[ni + 1]
      local gain = D(prev, node) + (nxt and (D(node, nxt) - D(prev, nxt)) or 0)
      table.remove(route, ni)
      -- Grenzen nach dem Herausnehmen (Positionen hinter ni ruecken eins vor)
      local lo2 = (lo > ni) and lo - 1 or lo
      local hi2 = (hi >= ni) and hi or hi + 1
      hi2 = math.min(hi2, #route + 1)
      if hi2 >= #route + 1 then hi2 = #route + 1 end
      if lo2 < 1 then lo2 = 1 end
      -- Grenzen widersprechen sich (Level reicht erst nach den eigenen Zielen): nicht verschieben. Vorher wurde
      -- das Annehmen hinter die Ziele gelegt (Zwerg: Felix' Kiste sammeln vor "A Refugee's Quandary" annehmen)
      local p, cost
      if hi2 >= lo2 then p, cost = BestSpot(node, lo2, hi2) end
      if p and cost + 0.5 < gain then
        table.insert(route, p, node)
        if p ~= ni then
          if (node.kind == "A" or node.kind == "T") and not LogOK() then
            table.remove(route, p)
            table.insert(route, ni, node)
          else
            changed = true
          end
        end
      else
        table.insert(route, ni, node)
      end
    end
    V11.Stage(myGen, 75, 90, ni, #route)
    if ni < #route then Later(Improve); return end
    improveRound = improveRound + 1
    if changed and improveRound < 12 then ni = 0; Later(Improve); return end
    if ns.dbgOrder then ns.dbgOrder("improve", route) end
    Later(ZoneMergeStep)
  end


  ------------------------------------------------------------
  -- 4b. Speed Leveling: Grind Pausen an Spots nahe der Route einbauen
  -- Fuer jede Pause: Spot mit passendem Mob Level, wenig Umweg, beste XP pro Zeit.
  -- Ausgeruht (Rested XP) zaehlt doppelt, solange der Vorrat reicht.
  ------------------------------------------------------------
  local spots = {}
  local function BuildSpots(force)
  if (opts.speed or force) and ns.GrindList then
    for ui in pairs(allowed) do
      if not (ns.cityParent and ns.cityParent[ui]) then
        for _, g in ipairs(ns.GrindList(ui)) do
          local c, wx, wy = World(ui, g[1], g[2])
          if c and reach[c] and g[4] and g[5] then
            table.insert(spots, { map = ui, x = g[1], y = g[2], wx = wx, wy = wy, cont = c, name = g[3] or TR"Mobs", lo = g[4], hi = g[5], n = g.n or 20, mob = g.mob,
              elite = EliteCamp(ui, g[1], g[2], 0) })
          end
        end
      end
    end
  end
  end
  local GQ = { id = 0, name = TR"Grinden", rl = 1 }

  -- XP pro Stunde an einem Spot fuer Level L
  local function SpotRate(sp, L)
    local m = (sp.lo + sp.hi) / 2
    -- 19.11 (Sascha): Grind Spots hoechstens 2 Level ueber dir (vorher 3)
    -- 20.3x (K 14:13 Realitaet: Spot plus 3, Spieler hinter dem Plan): halbes Level Sicherheit zur plus 2 Grenze
    if sp.hi > L + 2 - GRIND_UP_SAFE or sp.hi < L - 6 then return 0 end
    -- allein nie neben Elite Mobs grinden
    if DENSE.solo and sp.elite and sp.elite >= L - 2 then return 0 end
    local f = 1 + 0.05 * (m - L)
    if f < 0.4 then f = 0.4 elseif f > 1.2 then f = 1.2 end
    local dens = math.min(1, 0.7 + (sp.n or 8) / 100)
    -- Zeit pro Kill fuer genau dieses Mob Level, aus deinen letzten Kills
    if ns.KillSeconds and ns.MobXP then
      return 3600 / ns.KillSeconds(m - L) * ns.MobXP(math.floor(L)) * (ns.GroupXPShare and ns.GroupXPShare() or 1) * (ns.GroupGrindF and ns.GroupGrindF() or 1) * f * dens
    end
    return (ns.KillRate and ns.KillRate(math.floor(L)) or grind) * f * dens
  end
  EffGrind = function()
    if #spots == 0 then BuildSpots(true) end
    local rates = {}
    for _, sp in ipairs(spots) do
      if sp.cont == start.cont then
        local r = SpotRate(sp, L0 + 0.5)
        if r > 0 then rates[#rates + 1] = r end
      end
    end
    if #rates == 0 then return grind * 0.75 end
    table.sort(rates, function(a, b) return a > b end)
    -- drittbester Spot, etwas Weg und Pausen abgezogen
    return rates[math.min(#rates, 3)] * 0.9
  end

  WarmUp = function(starve)
    -- unter Level 10 mit kaum Kandidaten: die Quest Daten sind noch nicht da, nicht grinden
    if L0 < GRIND_MIN_L and #cands < 6 then return false end
    local minRl, need, toLvl
    local noQ = false
    if starve then
      -- ein paar Quests sind drin, aber die naechsten sind noch zu hoch: das kleinste Level suchen,
      -- ab dem wieder Quests gehen (zusammen ein spuerbarer Teil vom Abschnitt), nur bis dahin grinden
      local lv = {}
      for _, q in ipairs(order) do
        if not chosen[q.id] and q.why == TR"Level noch zu tief" and not q.inLog then
          local nl = math.max(q.rl or 1, q.safeL or 0, q.zoneL or 0)
          if nl > L0 then lv[#lv + 1] = { l = math.ceil(nl), v = (q.value or 0) + (q.chain or 0) * 0.5 } end
        end
      end
      table.sort(lv, function(a, b) return a.l < b.l end)
      local sum = 0
      for _, e in ipairs(lv) do
        sum = sum + e.v
        if sum >= xpNeed * 0.05 then minRl = e.l; break end
      end
      if not minRl then return false end
      local full = (ns.xpTotal[minRl] or 0) - xp0
      -- was die schon eingeplanten Quests bringen, zaehlt mit (sie kommen vor den neuen dran)
      need = math.floor(math.max(full * 0.3, full - totalXP))
      if full <= 0 or minRl > L0 + 2 then return false end
    else
      -- niedrigstes Level, ab dem eine Quest geht (Vorquests erfuellt)
      -- 19.11: auch Quests, die nur wegen der Gegner (safeL) oder der Zone noch warten
      for _, q in ipairs(order) do
        local nl = q.rl and math.ceil(math.max(q.rl, q.safeL or 0, q.zoneL or 0))
        if not chosen[q.id] and PreOK(q) and not q.inLog and nl and nl > L0 and (not minRl or nl < minRl) then minRl = nl end
      end
      -- gar keine Quest moeglich (alles wartet auf Vorquests): bis zum naechsten Level grinden,
      -- danach rechnet die Route neu
      toLvl = minRl or (math.floor(L0) + 1) -- im Fahrplan ist L0 ein Bruch (zB 6.7)
      -- 19.11 (Sim B_typ_sammler_4: auf Level 58 alle 15 Min ein neuer Fahrplan mit einem Grind Schritt, 617 Mal neu
      -- gerechnet): gar keine Quest mehr in Sicht, auch nicht auf hoeherem Level. Dann ein Schritt bis zum Ziel des
      -- Abschnitts, ohne 15 Min Grenze, dazu der passende Dungeon als Vorschlag
      if not minRl and not next(chosen) then
        local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
        toLvl = math.max(toLvl, math.min(maxL, math.floor(targetLevel or toLvl)))
        noQ = true
      end
      need = (ns.xpTotal[toLvl] or 0) - xp0
    end
    if need <= 0 then return false end
    if #spots == 0 then BuildSpots(true) end
    local best, bestScore
    for _, sp in ipairs(spots) do
      local rate = SpotRate(sp, L0)
      if rate > 0 then
        local walk = D(start, sp) / speed
        local dur = need / rate * 3600
        local score = need / (dur + walk)
        if not bestScore or score > bestScore then best, bestScore = { sp = sp, dur = dur }, score end
      end
    end
    local node
    if best then
      local sp = best.sp
      node = { q = GQ, kind = "G", map = sp.map, x = sp.x, y = sp.y, wx = sp.wx, wy = sp.wy, cont = sp.cont,
        dur = best.dur, gain = need, bonus = 0, obj = sp.name, lo = sp.lo, hi = sp.hi, mob = sp.mob }
    else
      -- kein bekannter Spot: Mobs in deiner Naehe
      local rate = grind > 0 and grind or 6000
      node = { q = GQ, kind = "G", map = start.map, x = start.x, y = start.y, wx = start.wx, wy = start.wy, cont = start.cont,
        dur = need / rate * 3600, gain = need, bonus = 0, obj = TR"Mobs in deiner Nähe", lo = math.max(1, L0 - 1), hi = L0 + 1 }
    end
    -- hoechstens ein Grind Block am Stueck (ns.GRIND_BLOCK_MIN), der Rest wird ein Hinweis (Dungeon oder grinden)
    local restXP, restDur = 0, nil
    local blockMax = (ns.GRIND_BLOCK_MIN or 15) * 60
    if grpDung then
      -- Gruppe: kein Grinden, gleich der Dungeon Vorschlag
      local dn = ns.DungeonSuggest and ns.DungeonSuggest(L0, true)
      node.hint, node.grp, node.dung = true, true, dn
      node.obj = dn and TR"Dungeon" or TR"Grinden oder Dungeons"
      node.dur = need / math.max(1000, grind * DUNG_F) * 3600
    elseif noQ then
      node.noQ = true
      node.dung = ns.DungeonSuggest and ns.DungeonSuggest(L0) or nil
      -- 19.41 (AUF K 12:46): auch ohne Quests in Sicht in Stuecken zu hoechstens GRIND_BLOCK_MIN am selben Ort. Alle Stuecke
      -- stehen im selben Fahrplan, also kein Neu rechnen pro Stueck (Schutz aus 19.11 bleibt). Nur das letzte Stueck hat noQ
      if node.dur > blockMax then
        local parts = ns.HintChunks(node.dur, need, blockMax)
        node.dur, node.gain, node.more, node.noQ = parts[1].dur, parts[1].gain, parts[1].more, (not parts[1].more) or nil
        for c = 2, #parts do
          local pc = parts[c]
          table.insert(route, c - 1, { q = GQ, kind = "G", chunk = c, more = pc.more, noQ = (not pc.more) or nil, map = node.map, x = node.x, y = node.y,
            wx = node.wx, wy = node.wy, cont = node.cont, dur = pc.dur, gain = pc.gain, bonus = 0, obj = node.obj, lo = node.lo, hi = node.hi,
            mob = node.mob, dung = node.dung })
        end
      end
    elseif node.dur > blockMax then
      restXP = math.floor(need * (1 - blockMax / node.dur))
      node.gain = need - restXP
      -- 19.34 (absprache zeitmodell_1934): der Rest mit derselben Spot Rate wie der Block
      restDur = node.dur - blockMax
      node.dur = blockMax
      node.more = true -- 19.41: danach kommen die Rest Stuecke
    end
    table.insert(route, 1, node)
    if restXP > 0 then
      local lvH = math.floor(LevelAt(xp0 + need))
      -- 19.35 (absprache zeitmodell_1934 B2, ABGESEGNET 20:41): der Rest in Stuecken zu hoechstens GRIND_BLOCK_MIN am selben
      -- Ort, wie es im Spiel laeuft (der Hinweis endet nach 15 Min, siehe ActDone). Gleiche XP und Gesamtzeit
      local dn = ns.DungeonSuggest and ns.DungeonSuggest(L0) or nil
      local parts = ns.HintChunks(restDur or (restXP / math.max(1000, grind) * 3600), restXP, blockMax)
      for c, pc in ipairs(parts) do
        table.insert(route, 1 + c, { q = GQ, kind = "G", hint = true, chunk = c, more = pc.more, map = node.map, x = node.x, y = node.y, wx = node.wx, wy = node.wy, cont = node.cont,
          dur = pc.dur, gain = pc.gain, bonus = 0, obj = TR"Grinden oder Dungeons",
          lo = math.max(1, lvH - 2), hi = lvH + 1, dung = dn })
      end
    end
    -- fuers Protokoll: warum keine Quest ging (die haeufigsten Gruende)
    if ns.TestLog then
      local list = {}
      for r, n in pairs(ns.optWhy or {}) do list[#list + 1] = { r, n } end
      table.sort(list, function(a, b) return a[2] > b[2] end)
      local t = {}
      for i2 = 1, math.min(4, #list) do t[#t + 1] = list[i2][1] .. " " .. list[i2][2] end
      local rn, _, rid = UnitRace("player")
      ns.TestLog("RECHNER", "Grinden statt Quests, Gruende: " .. table.concat(t, ", ") .. ((Questie and Questie.started == nil) and " (Questie ohne Startmeldung)" or "") .. (ns.questieEarly and " (Questie noch nicht gestartet)" or "")
        .. (" | Volk %s (ID %s), Level %.1f, Kandidaten %d"):format(tostring(rn), tostring(rid), L0, #cands))
    end
    -- unter Level 10 ohne Quests: das ist fast immer ein Daten Problem (Volk, Questie noch nicht fertig). Einmal sagen.
    if not starve and L0 < GRIND_MIN_L and not sim and not ns.lowGrindWarned then
      ns.lowGrindWarned = true
      local rn, _, rid = UnitRace("player")
      ns.Print((TR"|cffff9030Achtung:|r Für Level %d findet Keine Zeit Leveling Guide keine Quests (Volk %s, ID %s). Bitte über \"Fehler melden\" kurz Bescheid geben, die Gründe stehen im Log."):format(math.floor(L0), tostring(rn), tostring(rid)))
    end
    if starve then
      node.warm = true
      Report((TR"Die nächsten Quests sind noch zu hoch: kurz grinden bis Level %d, dann geht es mit Quests weiter."):format(minRl))
    elseif minRl then
      Report((TR"Noch keine Quest für Level %d da: erst grinden bis Level %d, dann geht es mit Quests weiter."):format(L0, minRl))
    else
      Report((TR"Gerade keine Quest machbar: grinden bis Level %d, dann rechnet die Route neu."):format(toLvl))
    end
    return true
  end

  local fills = 0
  local hintGap = 0
  GrindFill = function()
    V11.Stage(myGen, 92, 92, 1, 1)
    -- Gruppe: keine Grind Pausen (XP geteilt), der Rest wird ein Dungeon Vorschlag
    if grpDung then Later(fillGap and GapHint or HearthPlan); return end
    if fills == 0 and #spots == 0 then BuildSpots(fillGap) end
    local cum, rla = CumXP()
    local have = cum[#route + 1] or 0
    local gap = xpNeed - have
    -- ohne Speed nur echte Luecken fuellen (ab ca einem Drittel Level), kleine Reste holt der naechste Abschnitt.
    -- Notfall (Alles, Normal, Schnell ohne Grinden): erst ab einem halben Level, dann gibt es im Level wirklich keine Quests
    if not opts.speed and fills == 0 then
      local lv0 = math.floor(LevelAt(xp0 + have))
      local span0 = (ns.xpTotal[lv0 + 1] or 0) - (ns.xpTotal[lv0] or 0)
      if gap < span0 * (opts.emergency and 0.5 or 0.3) then Later(HearthPlan); return end
    end
    local F = ns.FLOW or {}
    -- laengster Grind Block am Stueck: ns.GRIND_BLOCK_MIN (Minuten), der Rest kommt an einer anderen Stelle
    local gmax, sepN = (ns.GRIND_BLOCK_MIN or 15) * 60, F.gsep or 0
    -- Grinden ist der Notfall: pro Abschnitt hoechstens 30 Min Grind Pausen (Sehr zügig und Schnell 60 Min),
    -- was dann noch fehlt, wird ein Hinweis (Dungeon oder grinden)
    local gsum = 0
    for _, n in ipairs(route) do if n.kind == "G" and not n.hint and not n.warm then gsum = gsum + (n.dur or 0) end end
    local gcap = (F.gcap or (opts.grindProf and 3600 or 1800))
    if gap <= 0 or #spots == 0 or fills >= (gmax > 0 and 60 or 10) or gsum >= gcap then Later(fillGap and GapHint or HearthPlan); return end
    -- Rested Vorrat, der an der Stelle noch uebrig ist (Quest Kills und Grind Pausen davor verbrauchen ihn)
    -- Fluss: Grind Pausen nicht direkt hintereinander, sondern mit Quests dazwischen verteilt
    local function NearG(p, sep)
      if sep <= 0 then return false end
      for j = math.max(1, p - sep), math.min(#route, p + sep - 1) do
        if route[j].kind == "G" then return true end
      end
      return false
    end
    local function InsCost(sp, q)
      local prev, nxt = route[q - 1] or start, route[q]
      return D(prev, sp) + (nxt and (D(sp, nxt) - D(prev, nxt)) or 0)
    end
    local best
    -- Grind Pausen erst ab Level 10 (vorher ist Questen der fluessige Weg)
    local pMin = 1
    while pMin <= #route + 1 and LevelAt(xp0 + (cum[pMin] or 0)) < GRIND_MIN_L do pMin = pMin + 1 end
    if pMin > #route + 1 then Later(fillGap and GapHint or HearthPlan); return end
    local function Search(sep)
      for _, sp in ipairs(spots) do
        Tick()
        -- moeglichst spaet grinden (Quests bringen bei niedrigerem Level mehr XP),
        -- aber nur wenn der Umweg kaum groesser ist als an der besten Stelle
        local p, cost
        if sep > 0 then
          for q = pMin, #route + 1 do
            Tick()
            if not NearG(q, sep) then
              local c = InsCost(sp, q)
              if not cost or c < cost then p, cost = q, c end
            end
          end
        else
          -- direkt neben einer anderen Pause, aber hoechstens zwei hintereinander (keine Grind Bloecke von Stunden)
          for q = pMin, #route + 1 do
            Tick()
            local run = 0
            local j = q - 1
            while route[j] and route[j].kind == "G" do run = run + 1; j = j - 1 end
            j = q
            while route[j] and route[j].kind == "G" do run = run + 1; j = j + 1 end
            if run < 2 then
              local c = InsCost(sp, q)
              if not cost or c < cost then p, cost = q, c end
            end
          end
        end
        if p then
          for q = #route + 1, p + 1, -1 do
            if not NearG(q, sep) then
              local c = InsCost(sp, q)
              if c <= cost + 150 then p, cost = q, c; break end
            end
          end
        end
        if p then
          local L = LevelAt(xp0 + (cum[p] or 0))
          local restLeft = rla[p] or 0
          local rate = SpotRate(sp, L)
          if rate > 0 then
            -- Pause bis zum naechsten Level, hoechstens so viel wie fehlt
            local lv = math.floor(L)
            local toNext = (ns.xpTotal[lv + 1] or (xp0 + have + gap)) - (xp0 + (cum[p] or 0))
            local chunk = math.max(1000, math.min(gap, toNext))
            local bonus = math.min(math.max(0, restLeft), chunk / 2)
            local dur = (chunk - bonus) / rate * 3600
            -- Fluss: eine Pause hoechstens gmax lang, der Rest kommt an einer anderen Stelle
            if gmax > 0 and dur > gmax then
              chunk = math.max(1000, chunk * gmax / dur)
              bonus = math.min(math.max(0, restLeft), chunk / 2)
              dur = (chunk - bonus) / rate * 3600
            end
            local score = chunk / (dur + cost / speed)
            if dur >= (F.gmin or 180) and (not best or score > best.score) then
              best = { sp = sp, p = p, dur = dur, chunk = chunk, bonus = bonus, score = score, L = L }
            end
          end
        end
      end
    end
    Search(sepN)
    -- kein Platz mit Abstand: erst mit halbem Abstand, dann direkt neben einer anderen Pause (hoechstens zwei)
    if not best and sepN > 2 then Search(math.floor(sepN / 2)) end
    -- direkt nebeneinander gibt es nicht mehr (Grinden ist der Notfall): hoechstens eine Pause am Stueck
    if not best then
      if ns.dbgHook then ns.dbgHook("gfill", fills, gap, #spots, #route) end
      Later(fillGap and GapHint or HearthPlan); return
    end
    local sp = best.sp
    local node = { q = GQ, kind = "G", map = sp.map, x = sp.x, y = sp.y, wx = sp.wx, wy = sp.wy, cont = sp.cont,
      dur = best.dur, gain = best.chunk, bonus = best.bonus, obj = sp.name, lo = sp.lo, hi = sp.hi, mob = sp.mob }
    table.insert(route, best.p, node)
    fills = fills + 1
    Later(GrindFill)
  end

  -- Quests (und Grind Pausen) reichen nicht bis zum Ziel: am Ende ein Schritt "dir fehlen noch X Level,
  -- grinden oder Dungeons". Er ist erledigt, sobald du die XP hast (bist du schon voraus, faellt er weg).
  GapHint = function()
    V11.Stage(myGen, 94, 94, 1, 1)
    local cum = CumXP()
    local have = cum[#route + 1] or 0
    local gap = xpNeed - have
    local lv = math.floor(LevelAt(xp0 + have))
    local span = (ns.xpTotal[lv + 1] or 0) - (ns.xpTotal[lv] or 0)
    if gap > math.max(500, span * 0.3) then
      local last = route[#route] or start
      local rate = (grind > 0 and grind or 6000) * (grpDung and DUNG_F or 1)
      local dn = ns.DungeonSuggest and ns.DungeonSuggest(lv, grpDung) or nil
      -- 19.35 (B2): in Stuecken zu hoechstens GRIND_BLOCK_MIN. 20.3d (Si rauch203cn, 5 von 5 Duo Laeufen mit Block bis
      -- 523 Min): auch Dungeon in der Gruppe in Stuecken, ein Stueck = ein Dungeon Lauf (DUNG_RUN_MIN), danach rechnet die
      -- Route neu und nimmt neue Quests mit, falls es welche gibt
      local isGrp = (grpDung and dn) and true or nil
      local parts = ns.HintChunks(gap / rate * 3600, gap, (isGrp and (ns.DUNG_RUN_MIN or 60) or (ns.GRIND_BLOCK_MIN or 15)) * 60)
      for c, pc in ipairs(parts) do
        table.insert(route, { q = GQ, kind = "G", hint = true, chunk = c, more = pc.more, map = last.map, x = last.x, y = last.y, wx = last.wx, wy = last.wy, cont = last.cont,
          dur = pc.dur, gain = pc.gain, bonus = 0, obj = isGrp and TR"Dungeon" or TR"Grinden oder Dungeons", lo = math.max(1, lv - 2), hi = lv + 1,
          dung = dn, grp = isGrp })
      end
      hintGap = gap
      Report((TR"Quests reichen nicht: ca %d XP fehlen bis Level %d (Hinweis eingeplant)"):format(gap, targetLevel))
    end
    Later(HearthPlan)
  end


  ------------------------------------------------------------
  -- 4c. Ruhestein: wo binden und wann porten
  -- Fuer jeden Gastwirt nahe der Route wird durchgespielt, wie viel Zeit Porten spart
  -- (Abklingzeit beachtet). Ein neuer Wirt muss den Umweg zum Binden wieder reinholen.
  ------------------------------------------------------------
  HearthPlan = function()
    V11.Stage(myGen, 96, 96, 1, 1)
    local HS = 6948
    if not ns.Inns or #route < 3
      or (ns.Api.GetItemCount and ns.Api.GetItemCount(HS) == 0 and not (IsSpellKnown and IsSpellKnown(556))) then Later(VendorPlan); return end
    local cdLeft = (ns.Api.GetItemCount and ns.Api.GetItemCount(HS) == 0) and math.huge or 0
    if cdLeft == 0 and ns.HearthLeft then cdLeft = ns.HearthLeft() end
    -- spaetere Abschnitte vom Fahrplan: Rest vom Abschnitt davor (dort zuletzt benutzt)
    if SIMLATE and cdLeft ~= math.huge then cdLeft = (sim and sim.hcd) or 0 end
    local CD = (ns.db and ns.db.hearthCD) or 3600
    local CAST = 25 -- 10 s wirken plus Ladebildschirm
    -- Schamane: Astraler Rueckruf bringt auch zum Bindepunkt, mit eigener Abklingzeit
    local RECALL = 556
    local hasRecall = IsSpellKnown and IsSpellKnown(RECALL)
    local rcLeft = 0
    if hasRecall and ns.Api.GetSpellCooldown then
      local st, dur = ns.Api.GetSpellCooldown(RECALL)
      if st and st > 0 and dur and dur > 1.5 then rcLeft = math.max(0, st + dur - GetTime()) end
    end
    if SIMLATE then rcLeft = 0 end
    local RCD = (ns.db and ns.db.recallCD) or 900
    -- Gruppe: alle nehmen den Ruhestein zusammen. Der laengste Rest Cooldown zaehlt, kein Rueckruf (hat nur einer)
    local gi = not sim and ns.GroupPlanInfo and ns.GroupPlanInfo()
    if gi then
      hasRecall = false
      for _, m in ipairs(gi.members) do if (m.hcd or 0) > cdLeft then cdLeft = m.hcd end end
    end
    -- inn0, last0: bis Position last0 bringt der Ruhestein noch zum alten Bindepunkt inn0 (vor dem neuen Binden).
    -- So wird auch der erste Ruhestein genutzt: neue Charaktere sind am Startpunkt gebunden
    local function Sim(inn, first, inn0, last0)
      local uses, save, ready, ready2, tt, prev = {}, 0, cdLeft, hasRecall and rcLeft or math.huge, 0, start
      for k, n in ipairs(route) do
        Tick()
        local walk = DRaw(prev, n) / speed
        local canH, canR = tt >= ready, tt >= ready2
        local to = (inn0 and last0 and k <= last0) and inn0 or ((k >= first) and inn) or nil
        -- 20.3 (Log 13:29, Sascha: "Ruhestein im Startgebiet ist nie schneller"): nicht zu Zielen im Startgebiet (Start
        -- Quests), und nur mit klarer Ersparnis (mind. 2 Min und ein Drittel vom Fussweg): die Luftlinie unterschaetzt
        -- Wege, knappe Faelle waren in echt langsamer. Allgemein, ohne Orte
        local inStart = n.q and n.q.startQ
        if to and (canH or canR) and not n.hearth and n.kind ~= "B" and not inStart then
          local alt = CAST + DRaw(to, n) / speed
          if walk - alt > math.max(120, walk / 3) then
            -- Rueckruf zuerst (kuerzere Abklingzeit), der Ruhestein bleibt fuer spaeter
            local useR = canR
            table.insert(uses, { k = k, recall = useR, inn = to })
            save = save + walk - alt
            walk = alt
            if useR then ready2 = tt + alt + RCD else ready = tt + alt + CD end
          end
        end
        tt = tt + walk + n.dur
        prev = n
      end
      return save, uses
    end
    -- Kandidaten: aktueller Bindepunkt und Wirte in den Zonen der Route
    local cands2 = {}
    local bi = (sim and sim.bind) or (ns.db and ns.db.bindInn)
    -- Gruppe: dein Bindepunkt zaehlt nur, wenn alle dort gebunden sind, sonst binden alle am selben Gasthaus
    if bi and gi then
      for _, m in ipairs(gi.members) do
        if not (m.bind and ns.WorldDist and (ns.WorldDist(bi, m.bind) or 999) < 60) then bi = nil; break end
      end
    end
    if bi then
      local c, wx, wy = World(bi[1], bi[2], bi[3])
      if c then table.insert(cands2, { map = bi[1], x = bi[2], y = bi[3], cont = c, wx = wx, wy = wy, name = (ns.db and ns.db.bindStart) and TR"Startpunkt" or TR"dein Bindepunkt", current = true }) end
    end
    local zones = {}
    for _, n in ipairs(route) do zones[n.map] = true end
    for _, inn in ipairs(ns.Inns()) do
      local parent = ns.cityParent and ns.cityParent[inn.map]
      if zones[inn.map] or (parent and zones[parent]) then
        local c, wx, wy = World(inn.map, inn.x, inn.y)
        if c then table.insert(cands2, { map = inn.map, x = inn.x, y = inn.y, cont = c, wx = wx, wy = wy, name = inn.name }) end
      end
    end
    -- Startgebiet: dort nicht binden, erst nach der letzten Startquest (im naechsten Ort)
    local minP = 1
    for k, n in ipairs(route) do
      if n.q and n.q.startQ then minP = k + 1 end
    end
    local best
    local curInn
    for _, inn in ipairs(cands2) do if inn.current then curInn = inn end end
    for _, inn in ipairs(cands2) do
      local score, p
      if inn.current then
        score = Sim(inn, 1)
      elseif minP > #route then
        score = -1
      else
        local cost
        p, cost = BestSpot(inn, minP, #route + 1)
        local detour = cost / speed
        score = Sim(inn, p, curInn, p - 1) - (detour + 15)
        -- binden normal nur bei ca 15 s Umweg; mehr nur, wenn der Ruhestein danach deutlich mehr spart
        if detour > 15 and score < (detour - 15) * 3 + 120 then score = -1 end
      end
      if not best or score > best.score then best = { inn = inn, score = score, p = p } end
    end
    if not best or best.score < 120 then
      -- Lohnt sich nicht fuer diese Route, aber du bleibst laut Plan noch laenger in dieser Zone und das
      -- Gasthaus liegt direkt am Weg (hoechstens ca 15 s Umweg): trotzdem binden, wie der Hinweis sagt
      local cur = ns.PlanNow and ns.PlanNow(L0)
      if L0 >= 6 and minP <= #route and cur and cur[1] == start.map and cur[3] - L0 >= 2 and (ns.db and ns.db.bindZone) ~= start.map then
        local pick
        for _, inn in ipairs(cands2) do
          if not inn.current and inn.map == start.map then
            local p, cost = BestSpot(inn, minP, #route + 1)
            local detour = cost / speed
            if detour <= 15 and (not pick or detour < pick.d) then pick = { inn = inn, p = p, d = detour } end
          end
        end
        if pick then
          local inn = pick.inn
          table.insert(route, pick.p, { q = GQ, kind = "B", map = inn.map, x = inn.x, y = inn.y, wx = inn.wx, wy = inn.wy, cont = inn.cont,
            dur = 15, who = inn.name })
          Report((TR"Ruhestein: binden bei %s, liegt direkt am Weg"):format(inn.name or TR"Gastwirt"))
        end
      end
      Later(VendorPlan); return
    end
    local inn = best.inn
    local first, last0 = 1, nil
    if not inn.current then
      table.insert(route, best.p, { q = GQ, kind = "B", map = inn.map, x = inn.x, y = inn.y, wx = inn.wx, wy = inn.wy, cont = inn.cont,
        dur = 15, who = inn.name })
      first = best.p + 1
      last0 = best.p - 1
    end
    local _, uses = Sim(inn, first, (not inn.current) and curInn or nil, last0)
    local early = 0
    for k = #uses, 1, -1 do
      local to = uses[k].inn or inn
      if to ~= inn then early = early + 1 end
      table.insert(route, uses[k].k, { q = GQ, kind = "H", map = to.map, x = to.x, y = to.y, wx = to.wx, wy = to.wy, cont = to.cont,
        dur = CAST, hearth = true, who = to.name, recall = uses[k].recall or nil })
    end
    Report((TR"Ruhestein: %s, spart ca %s"):format(inn.current and TR"dein Bindepunkt passt" or (TR"binden bei " .. (inn.name or "?")), ns.Clock(best.score)))
    if early > 0 then Report(TR"Ruhestein: vorher einmal zum alten Bindepunkt (Startgebiet), das spart den Rückweg") end
    Later(VendorPlan)
  end

  ------------------------------------------------------------
  -- 4d. Taschen: werden sie unterwegs voll, vorher einen Haendler einplanen
  -- Schaetzung: etwa ein neuer Platz pro 3 Kills (Beute), Questitems stapeln sich
  ------------------------------------------------------------
  VendorPlan = function()
    if sim or (ns.db and ns.db.bagPlan == false) or not (ns.Vendors and ns.FreeSlots) then Later(BookPlan); return end
    local free = ns.FreeSlots()
    -- Essen, Wasser und Munition kaufen plant die Route nicht mehr ein, Haendler nur noch zum Verkaufen
    local supply = nil
    local used, full = 0, nil
    local usedAt = {}
    -- belegte Plaetze pro Kill: aus deinen Kills gelernt, sonst nach Level geschaetzt
    local bagRate = ns.BagRate and ns.BagRate(L0) or 0.34
    for k, n in ipairs(route) do
      usedAt[k] = used
      local kills = 0
      if n.kind == "O" and n.npcs then kills = n.count or 0 end
      if n.kind == "G" and ns.MobXP then kills = (n.gain or 0) / ns.MobXP(L0) end
      used = used + kills * bagRate
      if used >= free - 2 then full = k; break end
    end
    if supply then full = full or 1 end -- Vorraete fehlen: so frueh wie es passt einkaufen
    local zones = {}
    for _, n in ipairs(route) do zones[n.map] = true end
    -- nur dort einplanen, wo gerade keine Quest mitten drin ist: direkt nach einer Abgabe
    -- (und keine Quest hat schon Ziele erledigt, deren Abgabe erst spaeter kommt)
    local pos = {}
    for k, n in ipairs(route) do pos[n] = k end
    -- Stellen mitten in einer Quest (Ziel schon erledigt, Abgabe kommt erst noch): einmal fuer alle markieren,
    -- statt fuer jede Stelle alle Quests durchzugehen (das gab ein Ruckeln von ueber 100 ms)
    local midQ
    local function Mark()
      midQ = {}
      for q in pairs(chosen) do
        local qq = byId[q]
        local tp = qq and qq.T and pos[qq.T]
        if tp then
          local mo
          for _, o in ipairs(qq.objNodes or {}) do local op = pos[o]; if op and (not mo or op < mo) then mo = op end end
          if mo then for p = mo + 1, tp do midQ[p] = true end end
        end
        Tick()
      end
    end
    Mark()
    local function Clean(p)
      local prev = route[p - 1]
      if p > 1 and not (prev and (prev.kind == "T" or prev.kind == "H" or prev.kind == "B")) then return false end
      return not midQ[p]
    end
    local cleanList = {}
    for p = 1, #route + 1 do if Clean(p) then table.insert(cleanList, p) end end
    local best
    local vendors = ns.Vendors()
    if not full then vendors = {} end
    -- Essen und Trinken gibt es auch beim Wirt
    if supply and supply.food and ns.Inns then for _, inn in ipairs(ns.Inns()) do table.insert(vendors, inn) end end
    for _, v in ipairs(vendors) do
      Tick()
      local parent = ns.cityParent and ns.cityParent[v.map]
      if zones[v.map] or (parent and zones[parent]) then
        local c, wx, wy = World(v.map, v.x, v.y)
        if c then
          local node = { map = v.map, x = v.x, y = v.y, wx = wx, wy = wy, cont = c, name = v.name, id = v.id }
          for _, p in ipairs(cleanList) do
            Tick()
            local prev, nxt = route[p - 1] or start, route[p]
            local cost = D(prev, node) + (nxt and (D(node, nxt) - D(prev, nxt)) or 0)
            -- lieber vor dem Vollwerden, sonst die erste passende Stelle danach. Aber nicht mit fast leeren
            -- Taschen (sonst kommt der Haendler gleich am Anfang, nur weil er nah ist)
            local early = (usedAt[p] or used) < (free - 2) * 0.5
            local score = cost + (p > full and (200 + (p - full) * 50) or 0) + (early and 400 or 0)
            if not best or score < best.cost then best = { node = node, p = p, cost = score } end
          end
        end
      end
    end
    if best then
      local v = best.node
      table.insert(route, best.p, { q = GQ, kind = "V", map = v.map, x = v.x, y = v.y, wx = v.wx, wy = v.wy, cont = v.cont, dur = 40, who = v.name,
        buy = supply and supply.text, npc = v.id })
      Report(supply and (TR"Einkaufen eingeplant bei %s: %s"):format(v.name or "?", supply.text)
        or (TR"Taschen: werden unterwegs voll, Händler %s ist eingeplant"):format(v.name or "?"))
    end
    -- Haendler, an denen man sowieso vorbeilaeuft (hoechstens ca 10 s Umweg), wenn die Taschen dann ueber halb voll sind
    for k, n in ipairs(route) do pos[n] = k end
    Mark()
    -- Weltpositionen der Haendler einmal rechnen, nicht an jeder Stelle der Route neu
    local all = {}
    for _, v in ipairs(ns.Vendors()) do
      local c, wx, wy = World(v.map, v.x, v.y)
      if c and reach[c] then all[#all + 1] = { c = c, wx = wx, wy = wy, map = v.map, x = v.x, y = v.y, name = v.name, id = v.id } end
    end
    local slots = (ns.TotalSlots and ns.TotalSlots()) or (free + 16)
    local fill = math.max(0, slots - free)
    local MAXC = speed * 10
    local p = 1
    local extra = 0
    while p <= #route and extra < 4 do
      Tick()
      local n = route[p]
      if n.kind == "V" then fill = 0
      else
        if n.kind == "O" and n.npcs then fill = fill + (n.count or 0) * bagRate end
        if n.kind == "G" and ns.MobXP then fill = fill + (n.gain or 0) / ns.MobXP(L0) * bagRate end
      end
      if fill > slots * 0.5 and Clean(p + 1) then
        local prev, nxt = route[p], route[p + 1]
        local bestV, bc
        -- billig vorab: ausserhalb vom Rechteck um die Strecke plus Umweg kann nie passen
        local x0, x1, y0, y1 = prev.wx or 0, prev.wx or 0, prev.wy or 0, prev.wy or 0
        if nxt and nxt.wx and nxt.cont == prev.cont then
          x0, x1 = math.min(x0, nxt.wx), math.max(x1, nxt.wx)
          y0, y1 = math.min(y0, nxt.wy), math.max(y1, nxt.wy)
        end
        x0, x1, y0, y1 = x0 - MAXC, x1 + MAXC, y0 - MAXC, y1 + MAXC
        for _, v in ipairs(all) do
          if v.c == prev.cont and prev.wx and v.wx >= x0 and v.wx <= x1 and v.wy >= y0 and v.wy <= y1 then
            local node = { map = v.map, x = v.x, y = v.y, wx = v.wx, wy = v.wy, cont = v.c }
            local cost = D(prev, node) + (nxt and (D(node, nxt) - D(prev, nxt)) or 0)
            if cost <= MAXC and (not bc or cost < bc) then bestV, bc = { node = node, name = v.name, id = v.id }, cost end
          end
        end
        if bestV then
          local v = bestV.node
          table.insert(route, p + 1, { q = GQ, kind = "V", map = v.map, x = v.x, y = v.y, wx = v.wx, wy = v.wy, cont = v.cont, dur = 40, who = bestV.name, npc = bestV.id })
          fill = 0; extra = extra + 1
          for k, nn in ipairs(route) do pos[nn] = k end
          Mark()
          p = p + 1
        end
      end
      p = p + 1
    end
    if extra > 0 then Report((TR"Händler am Weg: %d mal kurz verkaufen, kaum Umweg"):format(extra)) end
    Later(BookPlan)
  end

  ------------------------------------------------------------
  -- 4d2. Bibliotheksbuecher: liegen sie nah an der Route, kurz mitnehmen
  ------------------------------------------------------------
  BookPlan = function()
    if not (ns.db and ns.db.books ~= false and ns.OpenBooks) or opts.gearQ then Later(TrainerPlan); return end
    local MAXD0 = (ns.BookPrio and ns.BookPrio().yd) or ns.db.bookDetour or 600 -- Yards Umweg, die ein Buch mindestens wert ist
    -- Ein Buch ist etwas wert wie eine kleine Quest: XP und Gold bei der Abgabe (gemessen, sonst geschaetzt),
    -- das Buch, das eine Belohnungs Stufe (10, 20, 25) voll macht, viel mehr. Magier: neuer Beruf am Ende.
    local have = ns.BookCount and ns.BookCount() or 0
    -- Fahrplan: Buecher aus frueheren Abschnitten zaehlen als gesammelt und werden nicht nochmal geplant
    local simBooks = sim and (sim.books or {})
    if simBooks then for _ in pairs(simBooks) do have = have + 1 end end
    local _, cls = UnitClass("player")
    local mage = cls == "MAGE"
    local bookXP = ns.db.bookXP or math.floor((ns.MobXP and ns.MobXP(L0) or 100) * 4)
    local function BookYards(nth)
      local v = bookXP
      local cnt = have + nth
      if cnt == 10 or cnt == 20 or cnt == 25 then v = v + bookXP * 6 end
      if mage then v = v * 2 end
      local sec = v / math.max(1, grind) * 3600 -- so viel Zeit ist das Buch wert
      return math.max(MAXD0, sec * speed)
    end
    local placed, n = {}, 0
    for _, b in ipairs(ns.OpenBooks(false)) do
      local MAXD = BookYards(n + 1)
      if not placed[b.id] and not (simBooks and simBooks[b.id]) then
        local c, wx, wy = World(b.map, b.x, b.y)
        if c and reach[c] then
          local node = { map = b.map, x = b.x, y = b.y, wx = wx, wy = wy, cont = c }
          local best
          for p = 1, #route + 1 do
            if p % 16 == 0 then Tick() end
            local prev, nxt = route[p - 1] or start, route[p]
            if prev.cont == c then
              local cost = D(prev, node) + (nxt and (D(node, nxt) - D(prev, nxt)) or 0)
              if not best or cost < best.cost then best = { p = p, cost = cost } end
            end
          end
          if best and best.cost <= MAXD then
            table.insert(route, best.p, { q = GQ, kind = "K", map = b.map, x = b.x, y = b.y, wx = wx, wy = wy, cont = c, dur = 20,
              who = b.name, book = b.id, note = b.note })
            placed[b.id] = true
            if simBooks then simBooks[b.id] = true; sim.books = simBooks end
            n = n + 1
          end
        end
      end
    end
    if n > 0 then Report((TR"%d Bibliotheksbuch%s liegt auf dem Weg und ist eingeplant"):format(n, n > 1 and (ns.EN and "s" or "er") or "")) end
    -- Abgeben: gesammelte Buecher beim Bibliothekar, wenn die Route sowieso durch die Stadt geht (hoechstens ca 1 Min Umweg)
    local ti = ns.BOOK_TURNIN and UnitFactionGroup and ns.BOOK_TURNIN[UnitFactionGroup("player")]
    local pending = (have + n) - (ns.db.booksTurned or 0) - (sim and sim.bookTurned or 0)
    if ti and pending > 0 then
      local c, wx, wy = World(ti.map, ti.x, ti.y)
      if c and reach[c] then
        local node = { map = ti.map, x = ti.x, y = ti.y, wx = wx, wy = wy, cont = c }
        local best
        for p = 1, #route + 1 do
          if p % 16 == 0 then Tick() end
          local prev, nxt = route[p - 1] or start, route[p]
          if prev.cont == c then
            local cost = D(prev, node) + (nxt and (D(node, nxt) - D(prev, nxt)) or 0)
            if not best or cost < best.cost then best = { p = p, cost = cost } end
          end
        end
        if best and best.cost <= speed * 60 then
          table.insert(route, best.p, { q = GQ, kind = "V", map = ti.map, x = ti.x, y = ti.y, wx = wx, wy = wy, cont = c, dur = 30,
            who = ti.name, buy = (TR"%d Bücher abgeben"):format(pending), books = true })
          if sim then sim.bookTurned = (sim.bookTurned or 0) + pending end
          Report((TR"Bücher abgeben bei %s ist eingeplant"):format(ti.name))
        end
      end
    end
    Later(TrainerPlan)
  end

  ------------------------------------------------------------
  -- 4d2. Lehrer: bis Level 10 nach jedem Level mit neuen Zaubern zum Lehrer (danach nur bei kleinem Umweg).
  -- Fehlen kurz vor dem Lehrer nur noch wenige XP zum naechsten Level, erst noch kurz Mobs hauen,
  -- damit du beim Lehrer schon aufgestiegen bist.
  ------------------------------------------------------------
  -- bis zu diesem Level: Lehrer gleich nach dem Aufstieg, wenn er so nah ist (Yards)
  local EARLY_TRAINER_LVL, EARLY_TRAINER_YD = 8, 220
  -- vor dem Lehrer noch 1 bis 3 Mobs hauen: aus. Bis Level 10 will niemand grinden, der Lehrer kommt nach dem Aufstieg
  local PRE_KILL = false
  TrainerPlan = function()
    local _, myCls = UnitClass("player")
    if opts.gold or opts.rep or opts.gearQ or opts.logOnly or not (ns.TRAINER_SPELLS and ns.Trainers) then Later(EndPlan); return end
    -- Gruppe (du leitest, andere laufen mit): Lehrer aller Klassen als Halt fuer alle
    local runs = { { cls = myCls, main = true, trained = math.max(sim and sim.trained or (ns.db and ns.db.trainedAt) or 0, 1) } }
    local gi = not sim and ns.GroupPlanInfo and ns.GroupPlanInfo()
    if gi then
      local byCls = {}
      for _, m in ipairs(gi.members) do
        if m.cls and m.cls ~= myCls then
          local r = byCls[m.cls]
          if not r then r = { cls = m.cls, trained = 99, names = {} }; byCls[m.cls] = r; runs[#runs + 1] = r end
          r.trained = math.max(1, math.min(r.trained, m.trained or m.lvl or 1))
          r.names[#r.names + 1] = m.name
        end
      end
      for _, r in ipairs(runs) do if r.names then r.forName = table.concat(r.names, ", ") end end
    end
    local trainedOut
    for _, run in ipairs(runs) do
    local cls = run.cls
    local spells = cls and ns.TRAINER_SPELLS[cls]
    local trainers = {}
    for _, t in ipairs(spells and ns.Trainers(cls) or {}) do
      local c, wx, wy = World(t.map, t.x, t.y)
      if c and reach[c] then table.insert(trainers, { map = t.map, x = t.x, y = t.y, wx = wx, wy = wy, cont = c, name = t.name, id = t.id }) end
    end
    if #trainers > 0 then
    local trained = run.trained
    local total, rlT = xp0, rested0
    local k, added = 1, 0
    -- Lehrer Knoten an Stelle p. Abgaben beim selben NPC (Klassen Brief), die schon gehen, kommen gleich mit.
    local function AddTrainer(p, t, lv)
      table.insert(route, p, { q = GQ, kind = "V", map = t.map, x = t.x, y = t.y, wx = t.wx, wy = t.wy, cont = t.cont, dur = 25,
        who = t.name, trainer = true, tlvl = lv, buy = TR"Neue Zauber lernen", npc = t.id, cls = gi and cls or nil, forName = run.forName })
      -- Klassen Briefe holt nur, wer selbst beim Lehrer ist
      if not run.main then return 0 end
      added = added + 1
      local pulled = 0
      local j = p + 1
      while j <= #route and pulled < 3 do
        local m = route[j]
        local moved = false
        if m.kind == "T" and m.q and m.q ~= GQ and m.cont == t.cont and DRaw(m, t) < 30 then
          -- angenommen vor dem Lehrer, und keine offenen Ziele dazwischen
          local acc, open = false, false
          for i2 = 1, j - 1 do
            local o = route[i2]
            if o.q == m.q then
              if o.kind == "A" and i2 < p then acc = true end
              if o.kind == "O" and i2 > p then open = true end
            end
          end
          if acc and not open then
            table.remove(route, j)
            pulled = pulled + 1
            table.insert(route, p + pulled, m)
            moved = true
          end
        end
        j = j + 1
        if moved then j = j end
      end
      return pulled
    end
    while k <= #route and added < 6 do
      Tick()
      local n = route[k]
      if n.kind == "T" and n.q and n.q.id then
        local kr = math.max(0, (n.q.killXP or 0) - (n.q.kxpSum or 0))
        local b = math.min(rlT, kr); rlT = rlT - b
        total = total + QuestXPAt(n.q.id, n.q.ql, math.floor(LevelAt(total))) + kr + b
      elseif n.kind == "O" and n.kxp then
        local b = math.min(rlT, n.kxp); rlT = rlT - b
        total = total + n.kxp + b
      elseif n.kind == "G" then total = total + (n.gain or 0); rlT = math.max(0, rlT - (n.bonus or 0)) end
      local lv = math.floor(LevelAt(total))
      -- neue Zauber seit dem letzten Lehrer?
      local want
      for l = trained + 1, lv do if spells[l] then want = l end end
      -- ab Level 20 nur alle 2 Level zum Lehrer (und nur wenn einer nah an der Route steht),
      -- nach 4 Level ohne Lehrer darf der Umweg etwas groesser sein
      if want and lv >= 20 and lv - trained < 2 then want = nil end
      if want then
        local maxDetour = (lv <= 10) and 180 or (lv < 20 and 60) or (lv - trained >= 4 and 150) or 90
        local look = lv >= 20 and 12 or 6
        local best
        -- erste Level (bis 8): neue Zauber sind viel wert. Steht ein Lehrer nah, gleich nach dem Aufstieg hin,
        -- nicht erst wenn die Route spaeter mal vorbeikommt
        if lv <= EARLY_TRAINER_LVL then
          for _, t in ipairs(trainers) do
            if n.cont == t.cont then
              local dd = DRaw(n, t)
              if dd <= EARLY_TRAINER_YD and (not best or dd < best.d) then
                local nxt = route[k + 1]
                best = { p = k + 1, d = dd, t = t, cost = (dd + (nxt and (DRaw(t, nxt) - DRaw(n, nxt)) or 0)) / speed }
              end
            end
          end
        end
        if not best then
        for p = k + 1, math.min(#route + 1, k + look) do
          Tick()
          local prev, nxt = route[p - 1], route[p]
          for _, t in ipairs(trainers) do
            if prev.cont == t.cont then
              -- echte Laufzeit: neue Zauber sind wichtig, die Zonenstrafe gilt hier nicht
              local cost = (DRaw(prev, t) + (nxt and (DRaw(t, nxt) - DRaw(prev, nxt)) or 0)) / speed
              if not best or cost < best.cost then best = { p = p, cost = cost, t = t } end
            end
          end
        end
        end
        if best and best.cost <= maxDetour then
          AddTrainer(best.p, best.t, lv)
          -- nicht springen: die Knoten bis zum Lehrer bringen noch XP (der Lehrer selbst keine)
          trained = lv
        elseif lv < 20 then
          trained = lv
        end
      elseif PRE_KILL and run.main and L0 < 10 and lv < 10 then
        -- kurz vor einem Lehrer Level, und der naechste Schritt ist bei einem Lehrer: erst noch Mobs hauen.
        -- Bis Level 8 auch, wenn du gerade beim Lehrer bist und die Route jetzt wegfuehrt: 1 bis 3 Mobs hauen,
        -- dann gleich den Lehrer mitnehmen (statt spaeter extra zurueck)
        local nl = lv + 1
        local nxt = route[k + 1]
        -- erst am letzten Halt an dieser Stelle (alles beim selben NPC zuerst erledigen)
        local sameSpot = nxt and nxt.cont == n.cont and nxt.kind ~= "O" and DRaw(n, nxt) < 25
        if spells[nl] and (nxt == nil or nxt.kind ~= "G") and n.kind ~= "G" and not sameSpot then
          local nearT
          if nxt then for _, t in ipairs(trainers) do if t.cont == nxt.cont and D(nxt, t) < 60 then nearT = t end end end
          local need = (ns.xpTotal[nl] or 0) - total
          local span = (ns.xpTotal[nl] or 0) - (ns.xpTotal[lv] or 0)
          local mobXP = lv * 5 + 45
          if not nearT and nl <= EARLY_TRAINER_LVL and need > 0 and need <= mobXP * 3 then
            for _, t in ipairs(trainers) do
              if t.cont == n.cont and DRaw(n, t) <= EARLY_TRAINER_YD then
                nearT = t
              end
            end
          end
          -- nur ein paar Mobs (hoechstens 3), kein richtiges Grinden im Startgebiet, und nur wenn Grinden an ist
          if grindOK and nearT and need > 0 and span > 0 and need <= mobXP * 3 then
            local rate = grind > 0 and grind or 6000
            table.insert(route, k + 1, { q = GQ, kind = "G", map = n.map, x = n.x, y = n.y, wx = n.wx, wy = n.wy, cont = n.cont,
              dur = math.max(30, need / rate * 3600), gain = need, bonus = 0, obj = TR"Mobs in deiner Nähe", lo = math.max(1, lv - 2), hi = lv + 1,
              kills = math.max(1, math.ceil(need / (lv * 5 + 45))) })
            total = total + need
            -- gleich danach der Lehrer (dafuer haust du ja die Mobs)
            AddTrainer(k + 2, nearT, nl)
            trained = nl
            k = k + 2
          end
        end
      end
      k = k + 1
    end
    if added > 0 then Report(run.forName and (TR"Lehrer für %s eingeplant: %d Mal"):format(run.forName, added) or (TR"Lehrer eingeplant: %d Mal"):format(added)) end
    if run.main then trainedOut = trained end
    end
    end
    if sim then sim.trainedOut = trainedOut or (sim.trained or 1) end
    Later(EndPlan)
  end

  ------------------------------------------------------------
  -- 4e. Zeit Budget: am Ende ins naechste Gasthaus zum Ausloggen (Ruhebonus)
  ------------------------------------------------------------
  EndPlan = function()
    -- Zeit Budget (Feierabend, Gold, Ruf): die Bloecke, Haendler und Lehrer kommen erst nach der Quest Auswahl dazu.
    -- Ist die Route jetzt laenger als erlaubt, von hinten ganze Quests wegnehmen (letzte Abgabe zuerst).
    if opts.maxTime then
      local guard = 0
      while guard < 300 and TotalTime(route, start, speed, true) > opts.maxTime * 1.05 do
        guard = guard + 1
        local lastQ
        for k = #route, 1, -1 do
          local n = route[k]
          if n.kind == "T" and n.q and n.q ~= GQ then lastQ = n.q; break end
        end
        if not lastQ then break end
        for k = #route, 1, -1 do if route[k].q == lastQ then table.remove(route, k) end end
        chosen[lastQ.id] = nil
        lastQ.why = TR"Zeit Budget voll"
      end
    end
    if not (opts.endInn and ns.Inns) then Later(Finish); return end
    local last = route[#route] or start
    local best, bd
    for _, inn in ipairs(ns.Inns()) do
      local c, wx, wy = World(inn.map, inn.x, inn.y)
      if c and reach[c] then
        local node = { map = inn.map, x = inn.x, y = inn.y, wx = wx, wy = wy, cont = c }
        local d = D(last, node)
        if not bd or d < bd then best, bd = { node = node, name = inn.name }, d end
      end
    end
    if best then
      local n = best.node
      table.insert(route, { q = GQ, kind = "L", map = n.map, x = n.x, y = n.y, wx = n.wx, wy = n.wy, cont = n.cont, dur = 5, who = best.name })
    end
    Later(Finish)
  end
  -- 5. Simulieren und Stopps bauen
  Finish = function()
    -- letzte Phase: ab hier kein Freigeben mehr (der Rueckruf am Ende startet zb den naechsten Abschnitt,
    -- Fenster werden neu gezeichnet, dort darf nichts mitten drin anhalten)
    coActive = false
    if ns.dbgOrder then ns.dbgOrder("finish", route) end
    -- Sicherung: Abgabe nie vor einem Ziel (oder dem Annehmen) der gleichen Quest. Hat eine Verschiebung
    -- das doch so gelegt, kommt die Abgabe direkt hinter das letzte Ziel.
    do
      local fixed = 0
      for _ = 1, 50 do
        local lastOf, posT = {}, {}
        for p, n in ipairs(route) do
          if n.q and n.q ~= GQ then
            if n.kind == "T" then posT[n.q] = p
            elseif n.kind == "O" or n.kind == "A" then lastOf[n.q] = p end
          end
        end
        local moved = false
        for q, pt in pairs(posT) do
          local lo = lastOf[q]
          if lo and lo > pt then
            if ns.dbgHook then ns.dbgHook("tfix", q.name, q.id, pt, lo, route[lo].kind, route[lo].obj, route[lo].pre, q.inLog) end
            local n = table.remove(route, pt)
            table.insert(route, lo, n) -- nach dem Entfernen steht das letzte Ziel bei lo - 1
            fixed = fixed + 1
            moved = true
            break
          end
        end
        if not moved then break end
      end
      if fixed > 0 and ns.TestLog then ns.TestLog("RECHNER", ("Abgabe vor Ziel korrigiert: %d"):format(fixed)) end
    end
    local steps = {}
    local t, total, prev = 0, xp0, start
    local cur
    local quests = 0
    local dropped = {}
    local acceptedQ = {}
    local tramUsed = {}
    local gold = 0
    local kxpDone = {}
    local rlF, buffXP = rested0, 0
    -- 19.1: faellt eine Vorquest hier weg, fallen ihre Folgequests mit weg. Sonst steht "annehmen" ohne die Vorquest
    -- in der Route und der Schritt geht nie (Teil W: Bring Back the Mug ohne Scalding Mornbrew Delivery)
    -- 20.3d (Si 08:55, 5 Haenger 577/794/957/1428/92462): Annehmen der Folgequest stand in der Route VOR dem Abgeben der
    -- Vorquest (die Sicherung "Abgabe nie vor einem Ziel" schiebt Abgaben nach hinten, die Folgequest blieb stehen). Hier
    -- zaehlt die echte Reihenfolge: Annehmen nur, wenn die Vorquest erledigt ist oder ihre Abgabe weiter vorne steht.
    -- Sonst faellt die Folgequest in diesem Abschnitt weg und kommt im naechsten (allgemein, keine Quest Liste)
    local tEmitted, preLate = {}, 0
    local function PreNotYet(q)
      local function Ok(id) return complete[id] or (q.preDone and q.preDone[id]) or tEmitted[id] end
      if q.preSingle and #q.preSingle > 0 then
        local any = false
        for _, id in ipairs(q.preSingle) do if Ok(id) then any = true; break end end
        if not any then return true end
      end
      for _, id in ipairs(q.preGroup or {}) do if not Ok(id) then return true end end
      return false
    end
    local function PreDropped(q)
      local function Gone(id) local p = chosen[id]; return p ~= nil and dropped[p] and not complete[id] end
      local function Have(id) return complete[id] or (q.preDone and q.preDone[id]) or (chosen[id] ~= nil and not dropped[chosen[id]]) end
      if q.preSingle and #q.preSingle > 0 then
        local any, gone = false, false
        for _, id in ipairs(q.preSingle) do
          if Have(id) then any = true; break end
          if Gone(id) then gone = true end
        end
        if not any and gone then return true end
      end
      for _, id in ipairs(q.preGroup or {}) do if Gone(id) then return true end end
      return false
    end
    -- 19.31 (Realitaets Regel, Questlevel 4 und mehr ueber dir ist ein Fehler): die Schaetzung beim Einplanen rechnet die
    -- XP der Abgaben mit dem Level vom Anfang. Ueber viele Level (zb 40 bis 48) ist das zu viel, eine Quest kam so bei
    -- Level 41 mit Questlevel 45 dran. Hier mit dem Level, das an dieser Stelle wirklich erreicht ist
    local gdF, highQL = GroupGap(), 0
    for _, n in ipairs(route) do
      local L = LevelAt(total)
      -- Mindestlevel nicht erreicht? (sollte selten sein) dann Quest weglassen
      if n.kind == "A" and n.q.rl > math.floor(L) then dropped[n.q] = true end
      if n.kind == "A" and n.q.ql and not dropped[n.q] and n.q.ql - 3 + gdF > math.floor(L) then
        dropped[n.q] = true; highQL = highQL + 1
        if ns.TestLog and highQL <= 3 then ns.TestLog("PLAN", ("Quest %s ausgelassen: Questlevel %d, an dieser Stelle erst Level %d"):format(tostring(n.q.name), n.q.ql, math.floor(L))) end
      end
      -- 19.31 (Realitaets Regel): Questlevel plus 3 nur, wenn alle Gegner hoechstens plus 2 sind, mit dem Level hier
      if n.kind == "A" and n.q.ql and n.q.mobMax and not dropped[n.q] and not n.q.inLog and n.q.ql - 2 + gdF > math.floor(L) and n.q.mobMax - 2 + gdF > math.floor(L) then
        dropped[n.q] = true; highQL = highQL + 1
        if ns.TestLog and highQL <= 3 then ns.TestLog("PLAN", ("Quest %s ausgelassen: Questlevel %d und Gegner %d, an dieser Stelle erst Level %d"):format(tostring(n.q.name), n.q.ql, n.q.mobMax, math.floor(L))) end
      end
      -- 19.31: Elite Gegner allein mindestens 2 Level unter dir, auch mit dem Level, das hier wirklich erreicht ist
      if n.kind == "A" and n.q.eliteL and not dropped[n.q] and not n.q.inLog and n.q.eliteL > math.floor(L) then
        dropped[n.q] = true; highQL = highQL + 1
        if ns.TestLog and highQL <= 3 then ns.TestLog("PLAN", ("Quest %s ausgelassen: Elite Gegner Level %d, an dieser Stelle erst Level %d"):format(tostring(n.q.name), n.q.eliteMob or 0, math.floor(L))) end
      end
      -- 19.33c (Absprache elite_8917): "Unterwegs sammeln" vor dem Annehmen (n.pre) steht in der Reihenfolge VOR dem
      -- Annehmen, die Pruefung oben greift erst beim Annehmen. Darum die Elite Grenze hier auch, sonst laeuft man allein
      -- zu Elite Droppern einer Quest, die beim Annehmen dann wegfaellt (Sim: Elite allein, Gegner 59, du 59)
      -- Pruefer 11:58 (MITTEL): nur Knoten mit Kampf (npcs da, nicht Kaufen beim Haendler, nicht aus einem Objekt)
      if n.kind == "O" and n.pre and n.npcs and not n.buyAt and n.q.eliteL and not dropped[n.q] and not n.q.inLog and n.q.eliteL > math.floor(L) then
        dropped[n.q] = true; highQL = highQL + 1
        if ns.TestLog and highQL <= 3 then ns.TestLog("PLAN", ("Unterwegs sammeln für %s ausgelassen: Elite Gegner Level %d, an dieser Stelle erst Level %d"):format(tostring(n.q.name), n.q.eliteMob or 0, math.floor(L))) end
      end
      if n.kind == "A" and n.q and not dropped[n.q] and PreDropped(n.q) then dropped[n.q] = true end
      if n.kind == "A" and n.q and n.q ~= GQ and not dropped[n.q] and PreNotYet(n.q) then
        dropped[n.q] = true; preLate = preLate + 1
        if ns.TestLog and preLate <= 3 then ns.TestLog("PLAN", ("Quest %s erst im naechsten Abschnitt: Abgabe der Vorquest steht nicht davor"):format(tostring(n.q.name))) end
      end
      if not dropped[n.q] then
        local walk = DRaw(prev, n) / speed
        -- Reise mit Schiff oder Zeppelin? Dann eigenen Schritt am Abfahrtshafen
        if prev.cont and n.cont and ns.TravelBest and not n.hearth then
          local direct = math.sqrt((prev.wx - n.wx) ^ 2 + (prev.wy - n.wy) ^ 2) * PATH
          if prev.cont ~= n.cont or direct > FLY_MIN then
            local tt, from, to, l, side = ns.TravelBest(prev, n, speed)
            if tt and (prev.cont ~= n.cont or tt * speed < direct) then
              walk = tt
              local kind, fromName, toName = ns.TravelDesc(l, side, from, to)
              local tw = t + math.sqrt((prev.wx - from.wx) ^ 2 + (prev.wy - from.wy) ^ 2) * PATH / speed
              local rs = { map = from.map, x = from.x, y = from.y, t = tw, lvl = LevelAt(total), travel = true,
                acts = { { k = "R", link = l.id, li = l.idx, side = side, kind = kind, quest = toName, dest = toName, from = fromName,
                  toMap = to.map, toX = to.x, toY = to.y, toCont = to.cont, cross = prev.cont ~= n.cont, spell = to.spell } } }
              table.insert(steps, rs)
              -- 17.9 Tiefenbahn (Wunsch Sascha): Montys Rattenjagd im gleichen Schritt vor der Fahrt, wenn das Level passt.
              -- Monty steht am Bahnsteig Eisenschmiede, ca 6 Min fuer die Ratten
              if l.tram and ns.TramQuestActs then
                local qa, tq, tql = ns.TramQuestActs(LevelAt(total), tramUsed)
                if qa then
                  tramUsed[tq] = true
                  for k2 = #qa, 1, -1 do table.insert(rs.acts, 1, qa[k2]) end
                  walk = walk + 360
                  local xqt = QuestXPAt(tq, tql, math.floor(LevelAt(total))) or 0
                  if xqt > 0 then total = total + xqt; rs.xq = xqt end
                end
              end
              -- 19.34 (absprache zeitmodell_1934): der Reise Schritt endet bei der Ankunft, nicht schon am Hafen. Sonst
              -- stand die ganze Fahrt (Warten, Fahrt, Laden) als Weg im Schritt danach
              rs.t = math.max(tw, t + walk - DRaw(to, n) / speed)
              cur = nil
            end
          end
        end
        local tA = t + walk
        t = t + walk + n.dur
        -- XP dieses Schritts: Quest Belohnung, Mobs (beim Ziel, wo du sie haust), Grinden
        local xq, xk, xg = 0, 0, 0
        if n.kind == "G" then
          total = total + (n.gain or 0)
          xg = n.gain or 0
        end
        if n.kind == "O" and n.kxp and n.kxp > 0 then
          total = total + n.kxp
          kxpDone[n.q] = (kxpDone[n.q] or 0) + n.kxp
          xk = n.kxp
        end
        if n.kind == "T" then
          if n.q and n.q.id then tEmitted[n.q.id] = true end
          xq = QuestXPAt(n.q.id, n.q.ql, math.floor(L))
          -- Kill XP, die nicht schon bei einem Ziel gezaehlt wurden
          xk = math.max(0, (n.q.killXP or 0) - (kxpDone[n.q] or 0))
          total = total + xq + xk
          quests = quests + 1
          if opts.gold or opts.rep then gold = gold + (n.q.value or 0) end
        end
        -- 17.5: Ruhebonus auf Kill XP der Reihe nach (Grind Pausen haben ihn schon drin),
        -- Forever Buffs nur fuer die Zeit, die sie noch laufen (Schritt am Ende anteilig)
        do
          local kb = xk + math.max(0, xg - (n.bonus or 0))
          if xk > 0 and rlF > 0 then local b = math.min(rlF, xk); rlF = rlF - b; xk = xk + b; total = total + b end
          if n.kind == "G" then rlF = math.max(0, rlF - (n.bonus or 0)) end
          if buffs0[1] and (kb > 0 or xq > 0) then
            local add = 0
            for _, bf in ipairs(buffs0) do
              if (bf.left or 0) > tA then
                local fr = (t > tA) and math.min(1, (bf.left - tA) / (t - tA)) or 1
                add = add + (kb + (bf.quest and xq or 0)) * bf.pct * fr
              end
            end
            if add > 0 then add = math.floor(add); total = total + add; buffXP = buffXP + add; xk = xk + add end
          end
        end
        local act = { k = n.kind, qid = n.q.id, quest = n.q.name, who = n.who, obj = n.obj, count = n.count, npcs = n.npcs, pts = n.pts,
          item = n.item, pre = n.pre and not acceptedQ[n.q] or nil, guess = n.guess, npc = n.npc, buyAt = n.buyAt,
          srcItem = n.srcItem, srcFor = n.srcFor, mob = n.mob }
        if n.kind == "O" then act.foe, act.foeA = n.mobL, n.areaL end -- 19.13: Gegner Level am Ziel
        -- 19.31: Questlevel und hoechster Gegner der Quest fuer die Pruefung beim Annehmen (Realitaets Regel)
        if n.kind == "A" and n.q then act.ql, act.foeQ = n.q.ql, n.q.mobMax end
        -- 19.32 (Sim rauch1931dev, Elite allein mit Gegnern auf deinem Level): Elite Level der Quest fuer die Pruefung beim
        -- Ankommen (allein erst ab N Level unter dir, mit deinem echten Level)
        -- 19.32 (Pruefer 02:45 Hinweis 1): auch wenn der Plan in der Gruppe gerechnet wurde (dann ohne eliteL), damit die
        -- Pruefung beim Ankommen greift, wenn du danach allein weiter spielst. In der Gruppe prueft sie nicht
        if (n.kind == "A" or n.kind == "O") and n.q and (n.q.eliteL or n.q.eliteMob) then act.eliteM = n.q.eliteMob end
        if n.kind == "A" then acceptedQ[n.q] = true end
        if n.q and n.q.otherCls and (n.kind == "A" or n.kind == "O" or n.kind == "T") then act.cls, act.forName = n.q.otherCls, n.q.forName end
        if n.kind == "A" and n.q.buy then act.buy = n.q.buy end
        -- 19.17: eigene Stelle vom Questgeber (ein Schritt fasst bis 25 Yards zusammen, der Pfeil soll zum richtigen NPC)
        if n.kind == "A" or n.kind == "T" then act.imap, act.ix, act.iy = n.map, n.x, n.y end
        if n.kind == "K" then act.book, act.quest, act.note = n.book, n.who, n.note end
        if n.kind == "B" or n.kind == "H" or n.kind == "V" or n.kind == "L" then
          act.quest, act.imap, act.ix, act.iy, act.buy = n.who, n.map, n.x, n.y, n.buy
          act.trainer, act.tlvl = n.trainer, n.tlvl
          act.cls, act.forName = n.cls, n.forName
          act.recall = n.recall
          act.books = n.books
        end
        if n.kind == "G" then
          act.hint = n.hint -- kein Grind Spot: "dir fehlen noch X Level, grinden oder Dungeons"
          act.dung = n.dung -- passender Dungeon fuer den Hinweis
          act.grp = n.grp -- Gruppe: Dungeon Vorschlag statt grinden
          act.warm = n.warm -- kurz grinden, bis die naechsten Quests vom Level her gehen
          act.noQ = n.noQ -- 19.11: keine Quests mehr in Sicht, der Schritt geht bis zum Level (ohne 15 Min Grenze)
          act.more = n.more -- 19.41: danach kommt im selben Fahrplan noch ein Grind Stueck
          act.untilXP = total -- Pause fertig, wenn diese Gesamt XP erreicht sind
          act.lo, act.hi, act.min = n.lo, n.hi, math.floor(n.dur / 60 + 0.5)
          act.toLvl = LevelAt(total)
          act.kills = n.kills
        end
        -- gleicher Haendler zweimal am selben Ort (Taschen und Vorraete): nur einmal zeigen
        local dup
        if cur and act.k == "V" then
          for _, o in ipairs(cur.acts) do
            if o.k == "V" and o.quest == act.quest then
              dup = o
              if act.buy and not o.buy then o.buy = act.buy
              elseif act.buy and o.buy and o.buy ~= act.buy then o.buy = tostring(o.buy) .. ", " .. tostring(act.buy) end
            end
          end
        end
        if dup then
          -- nichts, schon drin
        -- 19.35 (B2): ein Hinweis Stueck ist ein eigener Schritt, so dauert jeder Schritt hoechstens GRIND_BLOCK_MIN wie im Spiel
        elseif cur and cur.map == n.map and math.sqrt((cur.wx - n.wx) ^ 2 + (cur.wy - n.wy) ^ 2) < 25 and not (n.kind == "G" and n.chunk) then
          table.insert(cur.acts, act)
          cur.t, cur.lvl = t, LevelAt(total)
          cur.xq, cur.xk, cur.xg = (cur.xq or 0) + xq, (cur.xk or 0) + xk, (cur.xg or 0) + xg
        else
          cur = { map = n.map, x = n.x, y = n.y, wx = n.wx, wy = n.wy, acts = { act }, t = t, lvl = LevelAt(total) }
          if xq > 0 then cur.xq = xq end
          if xk > 0 then cur.xk = xk end
          if xg > 0 then cur.xg = xg end
          table.insert(steps, cur)
        end
        prev = n
      end
    end
    -- Dungeon Quests (Schalter an): gezielt annehmen, wenn es nur ein kleiner Umweg ist, damit du sie dabei hast,
    -- wenn du in den Dungeon gehst. Die Ziele macht man im Dungeon, danach gibt die Route sie ab.
    if #dungPick > 0 and #steps > 0 then
      local function TurnSteps()
        local ts = {}
        for si, st in ipairs(steps) do for _, a in ipairs(st.acts or {}) do if a.k == "T" and a.qid then ts[a.qid] = si end end end
        return ts
      end
      local turnStep = TurnSteps()
      local added = 0
      for _, qid in ipairs(dungPick) do
        if added >= 6 then break end
        local okB, q = pcall(BuildQuest, qid, allowed, reach, false, nil)
        local A = okB and q and q.A
        if A then
          -- Vorquests: erledigt oder in diesem Abschnitt abgegeben (dann erst danach annehmen)
          local after, okP = 1, true
          local p1, pg = Q(qid, "preQuestSingle"), Q(qid, "preQuestGroup")
          if type(p1) == "table" and #p1 > 0 then
            local any = false
            for _, id in ipairs(p1) do
              if complete[id] then any = true; break end
              if turnStep[id] then any = true; after = math.max(after, turnStep[id]); break end
            end
            okP = any
          end
          if okP and type(pg) == "table" then
            for _, id in ipairs(pg) do
              if not complete[id] then if turnStep[id] then after = math.max(after, turnStep[id]) else okP = false end end
            end
          end
          local rl = q.rl or 1
          if okP then
            local best, bd
            for si = after, #steps do
              local st = steps[si]
              if (st.lvl or 0) >= rl and not st.travel and st.map then
                local c, wx, wy = World(st.map, st.x or 0.5, st.y or 0.5)
                if wx and c == A.cont then
                  local d = math.sqrt((wx - A.wx) ^ 2 + (wy - A.wy) ^ 2)
                  if not bd or d < bd then best, bd = si, d end
                end
              end
            end
            if best and bd <= DUNG_DETOUR then
              local st = steps[best]
              local act = { k = "A", qid = qid, quest = q.name .. TR" |cff7fd1b9(Dungeon)|r", who = A.who, npc = A.npc, dungQ = true }
              if bd < 25 then table.insert(st.acts, act)
              else
                table.insert(steps, best + 1, { map = A.map, x = A.x, y = A.y, wx = A.wx, wy = A.wy, t = st.t, lvl = st.lvl, acts = { act } })
                turnStep = TurnSteps()
              end
              added = added + 1
            end
          end
        end
      end
      if added > 0 and ns.TestLog and not sim then ns.TestLog("RECHNEN", ("Dungeon Quests zum Annehmen eingeplant: %d"):format(added)) end
    end
    -- Vorquests je Quest (fuer die Reihenfolge am gleichen NPC)
    local preOf = {}
    for _, n in ipairs(route) do
      if n.q and n.q.id and not preOf[n.q.id] then
        local set = {}
        for _, id in ipairs(n.q.preSingle or {}) do set[id] = true end
        for _, id in ipairs(n.q.preGroup or {}) do set[id] = true end
        preOf[n.q.id] = set
      end
    end
    for _, s in ipairs(steps) do
      s.wx, s.wy = nil, nil
      -- gleicher NPC: Annehmen vor Abgeben derselben Quest (vorab gesammelt, sonst stuende "Abgeben" vor "Annehmen"),
      -- und eine Vorquest abgeben, bevor die Folgequest angenommen wird (vorher stand zb "Samophlange annehmen" vor
      -- der Abgabe vom ersten Teil, im Spiel gibt es die Folgequest dann noch gar nicht)
      local acts = s.acts
      if #acts > 1 then
        for _ = 1, 3 * #acts do
          local moved = false
          for i = 2, #acts do
            local a = acts[i]
            for j = 1, i - 1 do
              local b = acts[j]
              local need = (a.k == "A" and a.qid and b.qid == a.qid and b.k ~= "A")
                or (a.k == "T" and a.qid and b.k == "A" and b.qid and b.qid ~= a.qid and preOf[b.qid] and preOf[b.qid][a.qid])
              if need then
                table.remove(acts, i)
                table.insert(acts, j, a)
                moved = true
                break
              end
            end
            if moved then break end
          end
          if not moved then break end
        end
      end
    end
    -- 19.15 / 20.3f (REGEL K 16:42): harte Endpruefung Vorquests, nach allen Optimierungs Schritten (VorquestOrder oben).
    -- Folgequest erst, wenn die Vorquest erledigt oder vorher in dieser Route abgegeben ist. Sonst hinter die Abgabe
    -- schieben, fehlende Kette einfuegen oder (geht nicht) Quest raus. Vorher kam die Folgequest hier nur raus.
    do
      local chained = {}
      local function Chain(miss, HasF, lvl, atStep)
        local out, plan = {}, {}
        local function HasP(id) return HasF(id) or plan[id] end
        local function Build(id, depth)
          if HasP(id) then return true end
          if depth > 8 or chained[id] then return false end
          chained[id] = true
          local rc, rr = Q(id, "requiredClasses"), Q(id, "requiredRaces")
          if rc and rc > 0 and classID and not ns.HasBit(rc, classID - 1) then return false end
          if rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then return false end
          local okL, _, rl = pcall(QLib.GetEffectiveQuestLevel, id)
          if okL and rl and rl > math.floor((lvl or 0) + 0.001) then return false end
          if IsHiddenQuest and IsHiddenQuest(id) then return false end
          if ns.IsEventQuestSkipped and ns.IsEventQuestSkipped(id) then return false end
          for _, alts in ipairs(PreMissing(id, HasP)) do
            local got = false
            for _, pid in ipairs(alts) do if Build(pid, depth + 1) then got = true; break end end
            if not got then return false end
          end
          local okB, q = pcall(BuildQuest, id, anyAllowed, reach, (inLog and inLog[id]) and true or false)
          if not (okB and q and q.T and (q.A or (inLog and inLog[id]))) then return false end
          for _, n in ipairs(q.nodes) do
            local act = { k = n.kind, qid = id, quest = q.name, who = n.who, obj = n.obj, count = n.count, npcs = n.npcs, pts = n.pts,
              item = n.item, pre = n.pre, guess = n.guess, npc = n.npc, buyAt = n.buyAt, srcItem = n.srcItem, srcFor = n.srcFor, mob = n.mob, preChain = true }
            if n.kind == "A" or n.kind == "T" then act.imap, act.ix, act.iy = n.map, n.x, n.y end
            if n.kind == "A" then act.ql, act.foeQ = q.ql, q.mobMax end
            out[#out + 1] = { map = n.map, x = n.x, y = n.y, t = atStep and atStep.t, lvl = lvl, acts = { act } }
          end
          plan[id] = true
          return true
        end
        for _, alts in ipairs(miss) do
          local got = false
          for _, pid in ipairs(alts) do if Build(pid, 1) then got = true; break end end
          if not got then return nil end
        end
        return out
      end
      local st = VorquestOrder(steps, 1, function(id) return complete[id] end, function(id) return inLog and inLog[id] end, Chain)
      if ns.TestLog and (st.move + st.add + st.gone) > 0 then
        ns.TestLog("RECHNEN", ("Vorquest Pruefung %s: %d geschoben, %d Ketten eingefuegt, %d Quests raus"):format(sim and "Fahrplan" or "Route", st.move, st.add, st.gone))
      end
    end
    local gained = total - xp0
    if not sim and ns.TestLog and (buffXP > 0 or rested0 > 0) then
      local bl = {}
      for _, bf in ipairs(buffs0) do bl[#bl + 1] = ("%s %.0f %% noch %d Min"):format(bf.kind, bf.pct * 100, math.floor((bf.left or 0) / 60)) end
      ns.TestLog("RECHNEN", ("Ruhebonus eingerechnet %d von %d XP, Buffs %d XP (%s)"):format(math.floor(rested0 - rlF), math.floor(rested0), buffXP, #bl > 0 and table.concat(bl, ", ") or "keine"))
    end
    local opt = {
      steps = steps, idx = 1, created = time and time() or 0,
      from = L0, to = LevelAt(total), target = targetLevel, quests = quests, sec = t,
      xp = gained, rate = (t > 0) and (gained / t * 3600) or 0, hintGap = hintGap > 0 and hintGap or nil,
    }
    -- Anfang (bis Level 10) und kaum Quests gefunden: Questie ist noch nicht fertig. Keine Grind Route bauen
    -- (das gab "4 Std Grinden" auf Level 1), sondern kurz warten und nochmal rechnen.
    local special = opts.gold or opts.rep or opts.logOnly or opts.gearQ or opts.endInn
    local nDone = 0
    for _ in pairs(complete) do nDone = nDone + 1; if nDone > 3 then break end end
    if not sim and not special and L0 <= 3 and nDone <= 3 and quests < 3 and #cands < 6 and (ns.waitQuestie or 0) < 12 then
      busy = false
      ns.waitQuestie = (ns.waitQuestie or 0) + 1
      Report(TR"Questie ist noch nicht bereit, die Route wartet kurz und rechnet dann.")
      if ns.TestLog then ns.TestLog("RECHNEN", (TR"Warte auf Questie (%d Quests, %d Kandidaten), Versuch %d"):format(quests, #cands, ns.waitQuestie)) end
      if ns.waitQuestie <= 12 then C_Timer.After(8, function() if ns.AutoOpt then ns.AutoOpt("auto") end end) end
      if ns.db and not (ns.db.opt and ns.db.opt.steps and #ns.db.opt.steps > 0) then
        ns.db.opt = { steps = {}, idx = 1, created = time and time() or 0, from = L0, to = L0, target = targetLevel, quests = 0, sec = 0, xp = 0, rate = 0, title = TR"Warte auf Questie" }
      end
      if ns.Draw then ns.Draw() end
      return
    end
    if sim then
      busy = false
      opt.end_ = { map = (steps[#steps] or {}).map or mapID, x = (steps[#steps] or {}).x or px, y = (steps[#steps] or {}).y or py, xp = total }
      opt.opts = { all = opts.all, speed = opts.speed, step = opts.step, thrF = opts.thrF, capF = opts.capF, fillGap = opts.fillGap, allCluster = opts.allCluster, rest = opts.rest }
      if done then done(opt) end
      return
    end
    ns.waitQuestie = 0
    -- Gold Route, die waehrend dem Rechnen wieder abgeschaltet wurde: verwerfen und normal weiter
    if opts.gold and ns.db and not ns.db.goldMode then
      busy = false
      Report(TR"Gold Route verworfen, Gold Quests sind aus.")
      if done then done(nil) end
      C_Timer.After(0.5, function() if ns.AutoOpt then ns.AutoOpt(true) end end)
      return
    end
    -- 18.6: Zeit Budget ohne eine einzige Quest (Quest und Weg zum Gasthaus passen nicht in die Zeit): die Route bleibt.
    -- Vorher hiess das nur "Ausloggen im Gasthaus" (oft per Ruhestein weit weg), nach dem Einloggen wieder, ohne XP
    -- (Sim Teil R 18.5: zwei Laeufe ab Level 40 in einer Schleife aus Einloggen und Ausloggen, je 400 Mal)
    if opts.endInn and quests == 0 and ns.db and ns.db.opt and #(ns.db.opt.steps or {}) > 0 and (ns.db.opt.idx or 1) <= #ns.db.opt.steps then
      busy = false
      ns.Print(TR"Zeit Budget: für eine Quest und den Weg zum Gasthaus reicht die Zeit nicht. Die Route bleibt, ausloggen kannst du im nächsten Gasthaus.")
      if ns.TestLog then ns.TestLog("ROUTE", "Zeit Budget ohne Quest: Route bleibt") end
      if done then done(nil) end
      return
    end
    -- Spezialroute (Ruf, Questlog, Ausruestung, Gold) ohne eine einzige Quest: die bisherige Route bleibt
    -- 20.3s (Punkt 21): Ausruestung/Upgrade ohne Quest nie als leere Route laden, auch wenn die alte Route schon fertig ist
    if (opts.rep or opts.logOnly or opts.gearQ or opts.gold) and quests == 0 and ns.db and ns.db.opt
      and (opts.gearQ or (#(ns.db.opt.steps or {}) > 0 and (ns.db.opt.idx or 1) <= #ns.db.opt.steps)) then
      busy = false
      ns.Print(opts.gearQ and TR"Keine machbare Quest dabei (Dungeon, Level zu tief oder Vorquest fehlt), die bisherige Route bleibt."
        or TR"Keine passenden Quests gefunden, die bisherige Route bleibt.")
      if done then done(nil) end
      return
    end
    -- 20.1 (P7, Log 12:08 "PROFIL Start: ?"): Titel schon vor dem Profil Wechsel, sonst steht im Profil kein Name
    opt.title = (opts.gearQ and TR"Ausrüstung Quests") or (opts.rep and (TR"Ruf: " .. (opts.repName or TR"Fraktion"))) or (opts.endInn and (TR"Zeit Budget " .. ns.Clock(opts.budget or t))) or (opts.logOnly and (TR"Questlog" .. (opts.zone and (": " .. opts.zone) or ""))) or (opts.gold and TR"Gold Quests") or nil
    -- Tour oder Farm Route (Questlog, Ausruestung, Ruf, Gold, Stunden Budget): Leveling Route im Profil merken
    local parked = false
    if ns.db and ns.ProfileOf and ns.ProfileOf({ opts = opts }) == "extra" and ns.ProfileBeforeExtra then
      ns.ProfileBeforeExtra(opt.title)
      ns.db.profileCur = "extra"
      -- 20.2 (P4/P5, Log 12:08: Ruf Route nach Gold farmen ohne Linie): ein alter Gold Modus blendete Karte und Pfeil
      -- auf die Gold Route um. Jede andere Zusatz Route schaltet ihn ab
      if not opts.gold then ns.db.goldMode = false end
      -- 20.3j (S Test 20.3g): altes Navi beenden, sonst bleiben Pfeil und Karte auf dessen Ziel (wie in ns.OptLoad)
      if ns.navi and ns.NaviStop then
        if ns.TestLog then ns.TestLog("PFEIL", ("altes Navi beendet bei neuer Route: %s"):format(tostring(ns.navi.dest and ns.navi.dest.name))) end
        pcall(ns.NaviStop, nil)
      end
    elseif ns.db and ns.ProfileParkLevel and not (opts.group or opts.split or opts.mirror) then
      -- 20.1 (P7): eine Leveling Rechnung wird fertig, waehrend eine Zusatz Route laeuft (Abschnitt live neu beim
      -- Level up, Rechnung von vorher): sie kommt ins Level Profil, die Zusatz Route bleibt
      parked = ns.ProfileParkLevel(opt)
    end
    if ns.db and not parked then ns.db.opt = opt end
    if ns.db and not parked and ns.db.profileCur == "extra" and ns.OptFarStart then pcall(ns.OptFarStart, opt) end
    -- frueher: XP pro Stunde je Stufe gemerkt (gab falsche Werte am Regler), jetzt feste Werte aus der Simulation
    if ns.db and ns.db.stepRate then ns.db.stepRate = nil end
    busy = false
    if opts.gold or opts.rep then
      Report((TR"fertig: %d Quests, %d Stopps, ca %s"):format(quests, #steps, ns.Clock(t)))
    else
      Report((TR"fertig: %d Quests, %d Stopps, ca %s, Level %d bis %.1f, ca %s XP pro Stunde"):format(
        quests, #steps, ns.Clock(t), L0, opt.to, tostring(math.floor(opt.rate))))
    end
    if quests == 0 and not opts.gold and ns.db and ns.db.optVerbose then ns.OptWhyReport(#cands) end
    -- gar keine Quest gefunden, oft weil Questie nach dem Einloggen noch nicht fertig ist (neuer Charakter:
    -- nur "Mobs in deiner Naehe"). Dann von selbst nochmal rechnen, ein paar Mal.
    if quests == 0 and not (opts.gold or opts.rep or opts.logOnly or opts.gearQ) and L0 < ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) then
      ns.noQuestRetry = (ns.noQuestRetry or 0) + 1
      if ns.noQuestRetry <= 4 then
        C_Timer.After(10, function()
          if ns.db and ns.db.opt == opt and (opt.idx or 1) <= 1 then
            Report(TR"Keine Quests gefunden, Questie war vielleicht noch nicht fertig: rechne nochmal.")
            ns.AutoOpt(true)
          end
        end)
      end
    else
      ns.noQuestRetry = 0
    end
    opt.title = (opts.gearQ and TR"Ausrüstung Quests") or (opts.rep and (TR"Ruf: " .. (opts.repName or TR"Fraktion"))) or (opts.endInn and (TR"Zeit Budget " .. ns.Clock(opts.budget or t))) or (opts.logOnly and (TR"Questlog" .. (opts.zone and (": " .. opts.zone) or ""))) or (opts.gold and TR"Gold Quests") or (opts.step and ns.LEVEL_STEPS and ns.LEVEL_STEPS[opts.step] and (TR"Tempo " .. ns.LEVEL_STEPS[opts.step].name)) or (opts.all and TR"Tempo Alles") or (opts.speed and TR"Tempo Schnell") or nil
    if opts.gold then opt.gold = gold; opt.goldRate = t > 0 and gold / t * 3600 or 0 end
    if opts.rep then opt.rep = gold; opt.repRate = t > 0 and gold / t * 3600 or 0; opt.repName = opts.repName end
    opt.speed = opts.speed and true or nil
    opt.opts = { all = opts.all, speed = opts.speed, gold = opts.gold, maxTime = opts.maxTime, logOnly = opts.logOnly, zone = opts.zone, qids = opts.qids, endInn = opts.endInn, budget = opts.budget, rep = opts.rep, repName = opts.repName, gearQ = opts.gearQ,
      step = opts.step, thrF = opts.thrF, capF = opts.capF, fillGap = opts.fillGap, allCluster = opts.allCluster, rest = opts.rest }
    if opts.gold then
      Report((TR"Gold: ca %s in %s, also ca %s pro Stunde"):format(ns.Money(gold), ns.Clock(t), ns.Money(opt.goldRate)))
    end
    if opts.rep then
      Report((TR"Ruf bei %s: ca %d in %s, also ca %d pro Stunde"):format(opts.repName or "?", gold, ns.Clock(t), math.floor(opt.repRate)))
    end
    if gained < xpNeed and not opts.all and not opts.speed and not opts.gold and not opts.logOnly and not opts.endInn and not opts.rep and not opts.gearQ then
      Report((TR"Mit Quests allein fehlen noch ca %d XP bis Level %d. Danach rechnet die Route den nächsten Abschnitt."):format(xpNeed - gained, targetLevel))
    end
    -- 1.1 (P38): Karte und Fenster erst im naechsten Bild zeichnen, nicht im selben Bild wie das letzte Rechen Stueck
    if sim or not C_Timer then
      if ns.Draw then ns.Draw() end
      if ns.RefreshUI then ns.RefreshUI() end
    else
      C_Timer.After(0, function()
        if ns.Draw then ns.Draw() end
        C_Timer.After(0, function() if ns.RefreshUI then ns.RefreshUI() end end)
      end)
    end
    if done then done(opt) end
  end

  -- 1.1 (P38, S 11:24): auch der erste Teil laeuft als Coroutine (vorher ohne, im selben Bild wie der Klick)
  Later(Phase1)
  return true
end

------------------------------------------------------------
-- Ausfuehren: Schritt fuer Schritt
------------------------------------------------------------
local function Completed1(qid)
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  if c and c[qid] then return true end
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompleted, qid)
    if ok and v then return true end
  end
  return false
end
-- kommt die Quest selbst irgendwo in der Route vor (dann ist sie eine eigene Quest, kein Zwilling)
-- Teil einer Kette: die eine ist Vorquest der anderen (dann zwei Quests, kein Zwilling)
-- 18.1: ueber die ganze Kette, nicht nur die direkte Vorquest (Paladin "Der Foliant der Offenbarung": Teil 1 und Teil 3 beim
-- selben NPC, dazwischen Teil 2 von einem Item. Teil 1 im Log galt als Zwilling von Teil 3, das Abgeben hing)
local function Reach(x, target, pre)
  local cur, seen = { x }, {}
  for _ = 1, 15 do
    local nxt = {}
    for _, q in ipairs(cur) do
      if not seen[q] then
        seen[q] = true
        if pre then
          for _, key in ipairs({ "preQuestSingle", "preQuestGroup" }) do
            local v = Q(q, key)
            if type(v) == "table" then for _, p in ipairs(v) do if p == target then return true end; nxt[#nxt + 1] = p end end
          end
        else
          local n = Q(q, "nextQuestInChain")
          if n == target then return true end
          if type(n) == "number" and n > 0 then nxt[#nxt + 1] = n end
        end
      end
    end
    if #nxt == 0 then return false end
    cur = nxt
  end
  return false
end
local function ChainLinked(a, b)
  return Reach(a, b, true) or Reach(b, a, true) or Reach(a, b, false) or Reach(b, a, false)
end
ns.OptChainLinked = ChainLinked
-- Zwilling: dieselbe Quest unter anderer ID (Questie kennt manche doppelt). Gemerkt, wenn das Annehmen ueber den
-- Namen erkannt wurde (db.questTwin[geplant] = im Log). Dann zaehlt das Abgeben vom Zwilling auch fuer die geplante.
local twinOK = {}
local function Twin(qid)
  local t = ns.db and ns.db.questTwin
  local tw = t and t[qid]
  -- 18.1: alter Eintrag mit anderen Zielen oder aus der gleichen Kette ist kein Zwilling (gemerkt, bevor das geprueft wurde).
  -- Einmal pro Paar pruefen, das Ergebnis bleibt
  if tw then
    local k = qid .. ":" .. tw
    local ok = twinOK[k]
    if ok == nil then ok = SameObjs(qid, tw) and not ChainLinked(qid, tw); twinOK[k] = ok end
    if not ok then t[qid] = nil; return nil end
  end
  return tw
end
local function Completed(qid)
  if Completed1(qid) then return true end
  local tw = Twin(qid)
  return tw ~= nil and Completed1(tw)
end

local function PlannedQ(qid)
  local o = ns.db and ns.db.opt
  for _, st in ipairs(o and o.steps or {}) do
    for _, a in ipairs(st.acts or {}) do if a.qid == qid then return true end end
  end
  return false
end

local function PlayerCont()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return nil, map end
  return (World(map, pos:GetXY())), map
end

-- Questziel Name fuer den Vergleich mit dem Questlog: nur den eigenen Zusatz " (von Mob)" abschneiden.
-- Klammern, die zum echten Namen gehoeren (zb "SI:7 Abzeichen (Fredo)"), bleiben, sonst zaehlen alle drei als eins.
local VON = TR" (von "
local function ObjKey(obj)
  if type(obj) ~= "string" then return nil end
  local p = obj:find(VON, 1, true) or obj:find(" (von ", 1, true)
  return p and obj:sub(1, p - 1) or obj
end
ns.OptObjKey = ObjKey

-- passendes Ziel im Questlog: zuerst der genaue Name ("Plaguehound" ist nicht "Plaguehound Runt"),
-- sonst das erste Ziel, das den Namen enthaelt. objs: Liste, get(o) gibt den Text
local function ObjName(t)
  t = tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  t = t:gsub("%s*:?%s*%d+%s*/%s*%d+%s*$", ""):gsub("%s+$", "")
  for _, suf in ipairs({ " slain", " killed", " getötet", " getoetet", " erschlagen" }) do
    if t:sub(-#suf) == suf then t = t:sub(1, -#suf - 1); break end
  end
  return t
end
ns.ObjName = ObjName
function ns.ObjFind(objs, key, get, skip)
  if type(key) ~= "string" or key == "" then return nil end
  get = get or function(o) return o.text end
  local first, firstI
  for i, o in ipairs(objs or {}) do
    if not (skip and skip(i)) then
      local t = get(o)
      if type(t) == "string" and t:find(key, 1, true) then
        if ObjName(t) == key then return o, i end
        if not first then first, firstI = o, i end
      end
    end
  end
  return first, firstI
end

-- wer die Quest gibt: NPC, Gegenstand in der Welt oder Item (fuer Quests mit gleichem Namen)
local STARTER_PRE = { "n", "o", "i" }
local function QStarter(id)
  local sb = Q(id, "startedBy")
  if type(sb) ~= "table" then return nil end
  for k = 1, 3 do
    local l = sb[k]
    if type(l) == "table" and l[1] then return STARTER_PRE[k] .. tostring(l[1]) end
  end
  return nil
end

-- 19.11: kommt in der Route ab dem jetzigen Schritt noch eine Quest (annehmen, Ziel, abgeben)?
local function RouteHasQuests()
  local o = ns.db and ns.db.opt
  if not (o and o.steps) then return false end
  -- im Fahrplan kommen noch Abschnitte: dort gibt es Quests, also wie bisher nach 15 Min weiter
  local pl = ns.db.plan60
  if pl and pl.secs and (pl.cur or 0) < #pl.secs then return true end
  for i = o.idx or 1, #o.steps do
    for _, x in ipairs(o.steps[i].acts or {}) do
      if x.k == "A" or x.k == "O" or x.k == "T" then return true end
    end
  end
  return false
end

ns.optLoadT = GetTime and GetTime() or 0
local function ActDone(a)
  -- Gruppen Route vom Leiter: was du nicht machen kannst (hilf mit), zaehlt fuer dich als erledigt
  if ns.mirrorActive and ns.MirrorHelp and ns.MirrorHelp(a) then return true end
  -- Mob Grind aus der Route des Leiters: fertig, wenn er weiter geht
  if a.mirrorG then return ns.MirrorStale ~= nil and ns.MirrorStale() end
  -- Klassenquest eines Mitspielers (Gruppe): fuer dich erledigt, gewartet wird ueber die Gruppe (GroupHold)
  if a.cls and (a.k == "A" or a.k == "O" or a.k == "T") then
    local _, mc = UnitClass("player")
    if mc and a.cls ~= mc then return true end
  end
  if a.k == "P" then if ns.ProfActDone then return ns.ProfActDone(a) and true or false end return true end
  if a.k == "R" then
    -- Reise erledigt, wenn wir am Ziel angekommen sind
    local c, map = PlayerCont()
    if a.link == "fly" then
      -- Flug: erst fertig, wenn wir am Ziel Flugpunkt gelandet sind
      if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return false end
      if map and a.toX and ns.WorldDist then
        local pos = C_Map.GetPlayerMapPosition(map, "player")
        if pos then
          local px, py = pos:GetXY()
          local d = ns.WorldDist({ map, px, py }, { a.toMap, a.toX, a.toY })
          return d ~= nil and d < 150
        end
      end
      return false
    end
    if map and (map == a.toMap or (ns.cityParent and ns.cityParent[map] == a.toMap)) then return true end
    if a.cross and c and c == a.toCont then return true end
    return false
  end
  if a.k == "M" then
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (pos and ns.WorldDist) then return false end
    local px, py = pos:GetXY()
    return (ns.WorldDist({ map, px, py }, { a.map, a.x, a.y }) or 999) < 60
  end
  if a.k == "L" then
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (pos and ns.WorldDist) then return false end
    local px, py = pos:GetXY()
    return (ns.WorldDist({ map, px, py }, { a.imap, a.ix, a.iy }) or 999) < 30
  end
  if a.k == "V" and a.manual then
    -- selbst eingefuegt (Menue): erledigt, wenn du dort warst (Lehrer oder Haendler Fenster offen)
    local t
    if a.trainer then t = ns.lastTrainerAt else t = ns.lastMerchantAt end
    if t ~= nil and t >= (a.since or 0) then return true end
    -- Fenster nicht geoeffnet (zb nichts zu verkaufen): warst du beim NPC und gehst weiter weg,
    -- oder stehst du 45 Sekunden dort, geht die Route trotzdem weiter (vorher blieb der Schritt stehen)
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and a.imap and C_Map.GetPlayerMapPosition(map, "player")
    if pos and ns.WorldDist then
      local px, py = pos:GetXY()
      local d = ns.WorldDist({ map, px, py }, { a.imap, a.ix, a.iy }) or 999
      if d < 12 and not a.nearAt then
        a.nearAt = time()
        ns.Print((TR"Sprich %s an (Rechtsklick). Brauchst du nichts, geht es mit Weiter oder in 45 Sekunden von selbst weiter."):format(a.quest or (a.trainer and TR"den Lehrer" or TR"den Händler")))
      end
      if a.nearAt and (d > 40 or time() - a.nearAt > 45) then return true end
    end
    return false
  end
  if a.k == "V" and a.books then
    -- Buecher abgeben: beim Bibliothekar angekommen
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (pos and ns.WorldDist) then return false end
    local px, py = pos:GetXY()
    return (ns.WorldDist({ map, px, py }, { a.imap, a.ix, a.iy }) or 999) < 12
  end
  if a.k == "V" and a.trainer then
    -- Lehrer fuer eine andere Klasse (Gruppe): nicht deiner, der Leiter wartet, bis der andere gelernt hat
    if a.cls then local _, mc = UnitClass("player"); if mc and a.cls ~= mc then return true end end
    -- Lehrer: erledigt, wenn du dort gelernt hast (oder nichts mehr zu lernen ist)
    if (ns.db and ns.db.trainedAt or 0) >= (a.tlvl or 0) then return true end
    local L = UnitLevel("player")
    if L >= (a.tlvl or 0) and ns.TrainerSpells and #ns.TrainerSpells(L) == 0 then return true end
    -- beim Lehrer gewesen (Fenster offen), auch wenn du noch knapp unter dem geplanten Level bist: erledigt.
    -- Sonst haengt der Schritt, bis du das Level hast (Simulation: geplant Level 4, angekommen mit 3.7)
    if not a.since or a.since > time() then a.since = time() end
    if ns.lastTrainerAt and ns.lastTrainerAt >= a.since then return true end
    return false
  end
  if a.k == "V" then
    -- Einkaufen (Essen, Wasser, Munition) plant die Route nicht mehr: alte Schritte gelten als erledigt
    if a.buy then return true end
    -- Haendler besucht (nach dem Planen) oder genug Platz
    if not a.buy and ns.FreeSlots and ns.FreeSlots() >= 8 then return true end
    -- Haendler in den letzten 5 Minuten besucht zaehlt auch (auch wenn der Schritt da noch nicht dran war)
    if not a.buy and ns.lastMerchantAt and time() - ns.lastMerchantAt < 300 then return true end
    if not a.since or a.since > time() then a.since = time(); return false end
    return ns.lastMerchantAt ~= nil and ns.lastMerchantAt >= a.since
  end
  if a.k == "B" or a.k == "H" then
    if a.k == "B" then
      local bi = ns.db and ns.db.bindInn
      return bi ~= nil and ns.WorldDist ~= nil and (ns.WorldDist(bi, { a.imap, a.ix, a.iy }) or 999) < 60
    end
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (pos and ns.WorldDist) then return false end
    local px, py = pos:GetXY()
    return (ns.WorldDist({ map, px, py }, { a.imap, a.ix, a.iy }) or 999) < 200
  end
  if a.k == "G" and a.farm then
    if not (ns.FarmActive and ns.FarmActive()) then return true end
    -- 20.2 (P2): Farm Runde mit mehreren Stellen: eine Stelle ist fertig, wenn du dort warst und ihre Zeit um ist
    if not a.dwell then return false end
    local o = ns.db and ns.db.opt
    local st = o and o.steps and o.steps[o.idx or 1]
    local cur = false
    for _, b in ipairs(st and st.acts or {}) do if b == a then cur = true end end
    if not cur then return false end
    if a.arrive and a.arrive > GetTime() then a.arrive = nil end
    if not a.arrive then
      local map = ns.PlayerMap and ns.PlayerMap()
      local pos = map and C_Map.GetPlayerMapPosition(map, "player")
      if pos and ns.WorldDist then
        local px, py = pos:GetXY()
        local d = ns.WorldDist({ map, px, py }, { st.map, st.x, st.y })
        if d and d < (a.r or 60) then a.arrive = GetTime() end
      end
      return false
    end
    return GetTime() - a.arrive >= a.dwell
  end
  if a.k == "G" and a.repFarm then return not ns.repFarm end
  if a.k == "G" then
    local L = UnitLevel("player")
    local now = (ns.xpTotal[L] or 0) + (ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player"))
    if now >= (a.untilXP or 0) or L >= 60 then return true end
    -- Grind Pause und Hinweis "Level fehlt": hoechstens ns.GRIND_BLOCK_MIN am Stueck, dann geht es weiter,
    -- auch wenn die XP noch nicht ganz da sind (die Uhr laeuft ab dem ersten Kampf in diesem Schritt).
    -- Beim Hinweis rechnet danach der naechste Abschnitt ab deinem Level (oft gibt es dann wieder Quests).
    -- Nicht begrenzt: nur der Dungeon Vorschlag in der Gruppe.
    -- 20.3d: auch der Dungeon Vorschlag in der Gruppe ist jetzt in Stuecken, Grenze dort ein Dungeon Lauf (DUNG_RUN_MIN)
    if (not a.noQ or a.more or (a.hint and a.grp)) then
      local t = time and time() or 0
      local lim = ((a.hint and a.grp) and (ns.DUNG_RUN_MIN or 60) or (ns.GRIND_BLOCK_MIN or 15)) * 60
      if not a.gStart and UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player") then a.gStart = t; a.gLv = L end
      -- 19.41 (AUF K 12:46, teilP skyborne 07: 176 Min am Stueck am Routen Ende): keine Quests mehr in der Route, aber im selben
      -- Fahrplan kommt noch ein Grind Stueck. Nach GRIND_BLOCK_MIN weiter zum naechsten Stueck, ohne Neu rechnen
      if a.more and a.gStart and t - a.gStart >= lim and not RouteHasQuests() then
        if not a.gTimeUp then
          a.gTimeUp = true
          if ns.TestLog then ns.TestLog("SCHRITT", ("Grind Stueck Zeit um nach %d Min (geplant %d Min, ohne Quests), naechstes Stueck"):format(math.floor((t - a.gStart) / 60), a.min or 0)) end
        end
        return true
      end
      -- 19.11 (Sim Sammler: auf Level 59 alle 15 Min ein neuer Fahrplan ohne Quests): kommt danach keine Quest mehr,
      -- bringt Neu rechnen nach 15 Min nichts. Dann erst mit dem naechsten Level weiter (neue Quests gibt es nur so)
      if a.gStart and not RouteHasQuests() then
        if L > (a.gLv or L) then
          if ns.TestLog then ns.TestLog("SCHRITT", ("Grinden ohne Quests in der Route: Level %d erreicht, weiter"):format(L)) end
          return true
        end
        -- 20.4b2 (K 22:36 Duo Endspiel, Si 22:40: Duo Grind Bloecke 233 bis 623 Min statt 7 bis 15): nach der Block Zeit nicht
        -- bis zum Level Up weiter grinden, sondern einmal mit allen Quests nachrechnen (wie Tempo Alles, auch graue und andere
        -- Zonen). Kommen Quests, geht es mit denen weiter, sonst bleibt es beim Grinden bis zum naechsten Level
        if t - a.gStart >= lim and not a.gNoQTried then
          a.gNoQTried = true
          if ns.TestLog then ns.TestLog("SCHRITT", ("Grinden ohne Quests nach %d Min: Quests nachholen (alle Quests, auch andere Zonen)"):format(math.floor((t - a.gStart) / 60))) end
          if C_Timer and ns.GrindNoQuestRetry then C_Timer.After(1, ns.GrindNoQuestRetry) end
        end
        return false
      end
      if a.gStart and t - a.gStart >= lim then
        if not a.gTimeUp then
          a.gTimeUp = true
          if ns.TestLog then ns.TestLog("SCHRITT", ("Grind Block Zeit um nach %d Min (geplant %d Min, %s), weiter"):format(math.floor((t - a.gStart) / 60), a.min or 0, a.hint and "Hinweis" or (a.warm and "bis Quests gehen" or "Pause"))) end
          -- danach kommen Quests, die vom Level her noch nicht gehen: den Abschnitt ab deinem Level neu rechnen
          if C_Timer and ns.GrindTimeUpCheck then C_Timer.After(1, function() ns.GrindTimeUpCheck(a.hint) end) end
        end
        return true
      end
    end
    return false
  end
  if a.k == "F" then return (ns.db and ns.db.knownFP and ns.db.knownFP[a.npc]) and true or false end
  if a.k == "K" then return ns.BookDone and ns.BookDone(a.book) or false end
  if a.k == "E" then return ns.TourExplored and ns.TourExplored(a.map, a.x, a.y, a.name) or false end
  local inLog = ns.logProgress and ns.logProgress[a.qid]
  if inLog == nil and ns.logProgress then local tw = Twin(a.qid); if tw then inLog = ns.logProgress[tw] end end
  if a.k == "A" then
    if inLog ~= nil or Completed(a.qid) then return true end
    -- 20.3 (INF 13:14, Sascha: Feiertag Quests nur, wenn das Fest laeuft): Fest vorbei oder Fest Quests aus, die Quest
    -- steht aber noch in der Route: Annehmen wird uebersprungen statt zu warten
    if ns.IsEventQuestSkipped and ns.IsEventQuestSkipped(a.qid) then return true end
    -- gleiche Quest unter anderer ID im Log (Questie kennt manche doppelt, zb je Volk)
    local nm = type(a.quest) == "string" and a.quest:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(" %(.-%)$", "")
    if nm and nm ~= "" then
      -- nur wenn es wirklich dieselbe Quest ist: gleicher Questgeber (Ketten mit gleichem Namen, zb
      -- "Destruction in Deadmines" als Dungeon Quest und danach nochmal beim selben NPC, sind zwei Quests)
      -- Questgeber kann ein NPC, ein Gegenstand in der Welt oder ein Item sein (zb "Gestrandete Meereskreatur":
      -- mehrere Quests mit gleichem Namen, jede an einem anderen Tier am Strand)
      local n1 = QStarter(a.qid)
      -- und die Quest im Log steht nicht selbst in der Route (sonst ist es eine eigene Quest, zb Teil 1 und Teil 2
      -- einer Kette mit gleichem Namen beim selben NPC, oder Rear Guard Patrol 356 und 99156: beide annehmen)
      for id, q in pairs(ns.logProgress or {}) do
        if q.title == nm and id ~= a.qid then
          local n2 = QStarter(id)
          if (not (n1 and n2) or n1 == n2) and not PlannedQ(id) and not ChainLinked(a.qid, id) and SameObjs(a.qid, id) then
            if ns.db then ns.db.questTwin = ns.db.questTwin or {}; ns.db.questTwin[a.qid] = id end
            return true
          end
        end
      end
    end
    return false
  end
  if a.k == "T" then
    if Completed(a.qid) then return true end
    -- 20.2 (Log 13:30, Hawkwind: "angenommen, geht aber nicht weiter"): Abgeben einer Quest, die nicht im Log ist und
    -- im selben Schritt nicht angenommen wird, haelt den Schritt nicht mehr auf. Startet die Quest ueber ein Item in
    -- deiner Tasche (zb eine Notiz), wartet der Schritt und sagt einmal, was zu tun ist. Allgemein, keine Quest Liste
    -- erst 20 s nach dem Laden (vorher kann das Questlog noch leer gemeldet werden)
    if inLog == nil and ns.logProgress and a.qid and GetTime and GetTime() - (ns.optLoadT or 0) > 20 then
      local o = ns.db and ns.db.opt
      local st = o and o.steps and o.steps[o.idx or 1]
      local own = false
      for _, b in ipairs(st and st.acts or {}) do if b == a then own = true end end
      if own then
        for _, b in ipairs(st.acts) do
          if b ~= a and b.k == "A" and b.qid == a.qid then return false end
        end
        local sb = Q(a.qid, "startedBy")
        local items = type(sb) == "table" and sb[3]
        if type(items) == "table" then
          for _, it in ipairs(items) do
            if ns.Api.GetItemCount and (ns.Api.GetItemCount(it) or 0) > 0 then
              if not a.itemHint then
                a.itemHint = true
                local iname = ns.Api.GetItemInfo and ns.Api.GetItemInfo(it)
                ns.Print((TR"Die Quest %s startet über %s in deiner Tasche: einmal anklicken, dann geht es weiter."):format(tostring(a.quest or a.qid), tostring(iname or TR"einen Gegenstand")))
              end
              return false
            end
          end
        end
        if not a.skipLogged then
          a.skipLogged = true
          if ns.TestLog then ns.TestLog("SCHRITT", ("Abgeben ohne Quest im Log uebersprungen: %s (%s)"):format(tostring(a.quest or "?"), tostring(a.qid))) end
        end
        return true
      end
    end
    return false
  end
  -- Ziel
  if Completed(a.qid) then return true end
  -- Quest im Log: nur das zaehlt, was das Spiel meldet (die geplante Zahl kann falsch sein)
  if not inLog then
    -- vorab gesammelt, bevor die Quest angenommen ist (bei geschaetzter Zahl reicht eins)
    if a.item and ns.Api.GetItemCount and ns.Api.GetItemCount(a.item) >= math.max(1, (not a.guess and a.count) or 1) then return true end
    return false
  end
  if inLog.complete then return true end
  if a.obj then
    local o = ns.ObjFind(inLog.objs, ObjKey(a.obj))
    if o then return o.done and true or false end
  end
  -- Hilfs Item, das nicht als Ziel im Questlog steht (zb ein Schluessel): erledigt, wenn es in der Tasche ist
  if a.item and ns.Api.GetItemCount and ns.Api.GetItemCount(a.item) >= math.max(1, (not a.guess and a.count) or 1) then return true end
  -- schon benutzt: das Ziel, das daraus entsteht, ist im Log weiter (Kette geoeffnet, Ueberreste begraben)
  if a.srcFor then
    for _, nm in ipairs(a.srcFor) do
      local o = ns.ObjFind(inLog.objs, nm)
      if o and (o.done or (tonumber(o.text:match("(%d+)%s*/%s*%d+")) or 0) > 0) then return true end
    end
  end
  return false
end
ns.OptActDone = ActDone

-- Stueckzahl fuer die Anzeige: im Log der echte Stand (3/10), sonst die Zahl aus Questie, geschaetzt ohne Zahl
function ns.OptCountText(a)
  local lp = a and a.qid and ns.logProgress and (ns.logProgress[a.qid] or (Twin(a.qid) and ns.logProgress[Twin(a.qid)]))
  if lp and a.obj then
    local o = ns.ObjFind(lp.objs, ObjKey(a.obj))
    if o then
      local x, y = o.text:match("(%d+)%s*/%s*(%d+)")
      if x then return ("%s/%s"):format(x, y) end
      return o.done and (ns.EN and "done" or "fertig") or ""
    end
  end
  if a and a.count and not a.guess then return "x" .. a.count end
  return ""
end

local function StepDone(s)
  for _, a in ipairs(s.acts) do if not ActDone(a) then return false end end
  return true
end
ns.OptStepDone = StepDone

-- naechster offener Stopp
-- Gruppe: an einem Schritt mit Questziel oder Abgabe warten, bis alle mit dem Addon auch so weit sind
-- (hoechstens 10 Minuten, dann geht es trotzdem weiter)
local function GroupHold(st, idx)
  if not (IsInGroup and IsInGroup() and ns.GroupNotDone) then ns.groupWait = nil; return false end
  -- neue Route an die Gruppe verteilt: kurz warten (hoechstens 5 Sekunden), bis alle sie haben
  local sw = ns.GroupSwitchWait and ns.GroupSwitchWait()
  if sw then ns.groupWait = sw; return true end
  -- Halt fuer alle (binden, Lehrer einer anderen Klasse, Flugpunkt): warten, bis die Mitlaeufer fertig sind
  -- (hoechstens 3 Minuten, bei der Klassenquest eines Mitglieds 15 Minuten)
  local all, isClass = nil, nil
  if ns.GroupStepWait then all, isClass = ns.GroupStepWait(st, idx or 0) end
  if all then
    local now = time()
    if st.waitAll and (st.waitAll > now or now - st.waitAll > 86400) then st.waitAll = nil end
    st.waitAll = st.waitAll or now
    if now - st.waitAll <= (isClass and 900 or 180) then ns.groupWait = all; return true end
  else
    st.waitAll = nil
  end
  local names = {}
  local now0 = GetTime()
  for _, a in ipairs(st.acts or {}) do
    if a.k == "T" and a.qid and a.qid > 0 then
      for _, who in ipairs(ns.GroupNotDone(a.qid) or {}) do names[who] = true end
    elseif a.k == "O" and a.qid and a.qid > 0 and a.obj then
      -- Questziel: warten, bis der andere dieses Ziel auch voll hat (nur wer die Quest hat und sich meldet)
      local key = ObjKey(a.obj)
      for who, g in pairs(ns.group or {}) do
        local q = g.quests and g.quests[a.qid]
        if q and not q.done and now0 - (g.seen or 0) < 300 then
          local o = ns.ObjFind(q.objs, key, function(t) return t end)
          if o then
            local x, y = o:match("(%d+)%s*/%s*(%d+)")
            if x and tonumber(x) < tonumber(y) then names[who] = true end
          end
        end
      end
    end
  end
  local list = {}
  for who in pairs(names) do table.insert(list, who) end
  if #list == 0 then st.waitSince = nil; return false end
  -- time() statt GetTime(): der Wert liegt in den gespeicherten Daten und muss einen PC Neustart ueberleben
  local now = time()
  if st.waitSince and (st.waitSince > now or now - st.waitSince > 86400) then st.waitSince = nil end
  st.waitSince = st.waitSince or now
  if now - st.waitSince > 600 then return false end
  table.sort(list)
  ns.groupWait = list
  return true
end

-- Abschnitt fertig: kurz warten, dann weiter. Hat in der Zwischenzeit schon etwas den naechsten Abschnitt
-- geladen (der 5 Sekunden Takt unten), nichts mehr tun: sonst rechnet AutoOpt(true) den ganzen Fahrplan neu.
local function AfterFinished(sec, o0)
  C_Timer.After(sec, function()
    local o = ns.db and ns.db.opt
    if o ~= o0 or (o and (o.idx or 1) <= #(o.steps or {})) then return end
    -- Tour oder Farm Route fertig: Profil weg, zurueck zur Leveling Route (gleicher Schritt wie vorher)
    if o0 and ns.ProfileOf and ns.ProfileOf(o0) == "extra" and ns.ProfileBackToLevel then ns.ProfileBackToLevel(true); return end
    if ns.AskAllAtMax then ns.AskAllAtMax(o0) end
    ns.AutoOpt(true)
  end)
end
-- Leveling Route fertig auf Max Level: einmal fragen, ob es mit Tempo Alles und allen restlichen Quests weiter geht
function ns.AskAllAtMax(o0)
  local db = ns.db
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if not db or (UnitLevel("player") or 1) < maxL or db.askedAllMax then return false end
  if (ns.LevelStep and ns.LevelStep() or 2) == 1 then return false end
  if o0 and ns.ProfileOf and ns.ProfileOf(o0) ~= "level" then return false end
  db.askedAllMax = true
  if ns.TestLog then ns.TestLog("PROFIL", "Leveling fertig auf Max Level: Frage Tempo Alles mit den restlichen Quests") end
  if not ns.Confirm then return false end
  ns.Confirm(TR"Die Leveling Route ist fertig, du bist auf Max Level.\n\nAuf Tempo Alles umschalten? Dann plant die Route alle restlichen Quests, die du noch machen kannst.",
    TR"Ja, alle Quests", function()
      -- rechnet gerade etwas: kurz warten, dann umschalten (sonst geht das Neu rechnen verloren)
      local function Go(n)
        if ((ns.OptBusy and ns.OptBusy()) or ns.planBuilding) and n < 20 then C_Timer.After(3, function() Go(n + 1) end); return end
        if ns.TestLog then ns.TestLog("PROFIL", "Max Level: auf Tempo Alles umgeschaltet") end
        if ns.SetLevelStep then ns.SetLevelStep(1) end
      end
      Go(0)
    end, TR"Nein")
  return true
end

-- Level fehlt im Schritt: hoechstens alle 10 Min neu rechnen
local lvlBlockAt = -999
local foeBlockAt = -999 -- 19.13: Gegner am Ziel noch zu hoch, gleiche Regel
local function Sync()
  local opt = ns.db and ns.db.opt
  if not opt then return end
  -- zurueck geblaettert: nicht von selbst weiter (nach 5 Minuten ohne Klick geht es normal weiter)
  if opt.pin then
    local now = time and time() or 0
    if now - (opt.pinAt or 0) < 300 and now >= (opt.pinAt or 0) then return end
    ns.OptUnpin()
    opt = ns.db.opt
    if not opt then return end
  end
  local i = opt.idx or 1
  ns.groupWait = nil
  -- Gruppen Route vom Leiter: der Schritt kommt von ihm (ausser er meldet sich nicht mehr)
  if opt.mirror and ns.MirrorStale and not ns.MirrorStale() then return end
  -- Ruhestein Schritt, der so nicht geht: noch Abklingzeit oder woanders gebunden. Dann raus, du laeufst direkt weiter
  local hs = opt.steps[i]
  for ai, a in ipairs(hs and hs.acts or {}) do
    if a.k == "H" then
      local why
      if a.recall then
        -- 18.6: Astraler Rueckruf noch auf Abklingzeit (der Plan rechnet mit der Abklingzeit, du warst schneller). Ist der
        -- Ruhestein bereit, bringt der dich an den gleichen Ort, sonst faellt der Schritt weg wie beim Ruhestein (Sim Teil A)
        local rl = 0
        if ns.Api.GetSpellCooldown then
          local st, dur = ns.Api.GetSpellCooldown(556)
          if st and st > 0 and dur and dur > 1.5 then rl = math.max(0, st + dur - GetTime()) end
        end
        if rl > 60 then
          local hl = ns.HearthLeft and ns.HearthLeft() or 0
          if hl <= 60 then a.recall = nil
          else why = (TR"Astraler Rückruf hat noch %d Min Abklingzeit"):format(math.ceil(rl / 60)) end
        end
      else
        local left = ns.HearthLeft and ns.HearthLeft() or 0
        if left > 60 then why = (TR"Ruhestein hat noch %d Min Abklingzeit"):format(math.ceil(left / 60)) end
      end
      local bi = ns.db.bindInn
      -- anderer Kontinent: WorldDist gibt nichts, das ist dann auch "woanders gebunden"
      local bd = 0
      if not why and bi and a.imap and ns.WorldDist then bd = ns.WorldDist(bi, { a.imap, a.ix, a.iy }) end
      if not why and bi and a.imap and ns.WorldDist and (bd == nil or bd == math.huge or bd > 250) then
        why = TR"Dein Ruhestein ist woanders gebunden"
      end
      if why then
        -- nur der Ruhestein faellt weg: hat der Schritt noch mehr (zb Quest annehmen am Ziel), bleibt er und du laeufst hin.
        -- Vorher fiel der ganze Schritt weg, die Quest wurde nie angenommen und das Abgeben spaeter ging nicht (Sim 17.2)
        table.remove(hs.acts, ai)
        if #hs.acts == 0 then table.remove(opt.steps, i) end
        local nx = opt.steps[i]
        -- naechstes Ziel auf einem anderen Kontinent: ohne Ruhestein fehlt die Reise dorthin, Abschnitt ab hier neu
        local pc = PlayerCont()
        if nx and nx.map and pc and World(nx.map, nx.x or 0.5, nx.y or 0.5) ~= pc and ns.ProfileOf(opt) == "level" then
          if ns.TestLogWhy then ns.TestLogWhy("Ruhestein geht nicht, Ziel auf anderem Kontinent") end
          C_Timer.After(1, function()
            if ns.ProfileOf(ns.db and ns.db.opt) ~= "level" then return end
            if ns.PlanActive and ns.PlanActive() then ns.PlanSectionLive() else ns.AutoOpt("auto") end
          end)
        end
        ns.Print(why .. TR", du läufst direkt weiter" .. (nx and (": " .. ns.OptStepText(nx)) or "."))
        if ns.TestLog then ns.TestLog("SCHRITT", (TR"Ruhestein Schritt raus: %s"):format(why)) end
        if ns.TestLogWhy then ns.TestLogWhy("Ruhestein Schritt raus") end
        if ns.Draw then ns.Draw() end
        return
      end
      break
    end
  end
  -- Questlog voll: Annehmen geht nicht, bis Platz ist. Steht im Schritt kein Abgeben mehr aus, fallen die neuen
  -- Quests (mit ihren Folgequests) aus der Route, statt dass der Pfeil dort wartet (Sim 17.2, Tempo Alles)
  do
    local st = opt.steps[i]
    local nLog = 0
    for _ in pairs(ns.logProgress or {}) do nLog = nLog + 1 end
    if st and not opt.mirror and ns.LogMax and nLog >= ns.LogMax() then
      local turnLeft = false
      -- nur Abgeben von Quests, die schon im Log sind (das macht Platz). Abgeben einer Quest, die hier erst
      -- angenommen werden soll, geht ohne Platz sowieso nicht (Sim 17.2: Dragonslayer's Helm, Annehmen und Abgeben beim selben NPC)
      for _, a in ipairs(st.acts or {}) do
        if a.k == "T" and not ActDone(a) and ns.logProgress and ns.logProgress[a.qid] then turnLeft = true end
      end
      if not turnLeft then
        local drop = {}
        for _, a in ipairs(st.acts or {}) do
          if a.k == "A" and a.qid and not (ns.logProgress and ns.logProgress[a.qid]) and not Completed(a.qid) then drop[#drop + 1] = a.qid end
        end
        if #drop > 0 then
          ns.Print((TR"Questlog voll (%d von %d): neue Quests hier lässt die Route aus. Mit Platz im Log kommen sie beim nächsten Abschnitt wieder."):format(nLog, ns.LogMax()))
          for _, q in ipairs(drop) do ns.OptDropQuest(q, TR"Questlog voll") end
          -- OptDropQuest hat schon neu abgeglichen
          return
        end
      end
    end
  end
  -- Level fehlt: im Schritt sind nur noch Quests offen, die ein hoeheres Level brauchen (die Route war schneller als du,
  -- zb Tempo ohne Grinden). Sonst steht der Pfeil bei einem Questgeber ohne Quest (Sim 17.2). Einmal pro Schritt:
  -- Abschnitt ab hier neu rechnen (hoechstens alle 10 Min), sonst diese Quests hier auslassen (sie kommen spaeter wieder)
  do
    local st = opt.steps[i]
    if st and not st.lvlWait and not opt.mirror and not busy and not ns.planBuilding then
      local L = (ns.UnitLevel and ns.UnitLevel("player")) or UnitLevel("player") or 1
      local blocked, need, other = {}, 0, false
      for _, a in ipairs(st.acts or {}) do
        if not ActDone(a) then
          local rl = a.k == "A" and a.qid and tonumber((Q(a.qid, "requiredLevel")))
          if rl and rl > L then blocked[#blocked + 1] = a.qid; need = math.max(need, rl) else other = true; break end
        end
      end
      -- erst wenn du beim Questgeber bist: unterwegs kommen oft noch genug XP dazu (Sim 17.2: sonst unnoetig neu gerechnet)
      local near = false
      if #blocked > 0 and not other and st.map and ns.WorldDist then
        local pm = ns.PlayerMap and ns.PlayerMap()
        local pp = pm and C_Map.GetPlayerMapPosition(pm, "player")
        if pp then
          local px, py = pp:GetXY()
          local d = ns.WorldDist({ pm, px, py }, { st.map, st.x or 0.5, st.y or 0.5 })
          near = d ~= nil and d < 60
        end
      end
      if #blocked > 0 and not other and near then
        st.lvlWait = true
        local now = GetTime and GetTime() or 0
        if ns.ProfileOf(opt) == "level" and now - lvlBlockAt > 600 then
          lvlBlockAt = now
          ns.Print((TR"Für die nächsten Quests fehlt noch Level (Level %d nötig, du bist %d). Der Abschnitt wird ab hier neu gerechnet."):format(need, L))
          if ns.TestLogWhy then ns.TestLogWhy("Level fehlt fuer die naechsten Quests") end
          if ns.TestLog then ns.TestLog("RECHNEN", ("Neu rechnen automatisch: Level fehlt fuer Quest %d (Level %d noetig, %d)"):format(blocked[1], need, L)) end
          C_Timer.After(0.5, function()
            if ns.ProfileOf(ns.db and ns.db.opt) ~= "level" then return end
            if ns.PlanActive and ns.PlanActive() then ns.PlanSectionLive() else ns.AutoOpt("auto") end
          end)
        else
          ns.Print((TR"Für diese Quests fehlt noch Level (Level %d nötig): die Route lässt sie hier aus, sie kommen später wieder."):format(need))
          for _, q in ipairs(blocked) do ns.OptDropQuest(q, TR"Level fehlt noch") end
        end
        return
      end
    end
  end
  -- 19.13 (Sascha: keine Quests mit Gegnern 3 oder mehr Level ueber dir): die Route plant mit dem Level, das du dort
  -- haben solltest. Bist du etwas hinten (Sim: Level 16.7, Gegner 19), sind beim Ankommen die Gegner zu hoch. Dann wie
  -- bei "Level fehlt": Abschnitt ab hier neu (hoechstens alle 10 Min), sonst diese Quests hier auslassen.
  -- Toeten: ab 3 ueber dir, nur am Ort (Gegenstaende): ab 5 ueber dir, in der Gruppe je 1 mehr
  do
    local st = opt.steps[i]
    -- 19.38 (Saschas Ja f34, Sim rauch1936 und teilA: Realitaets Regel verletzt, 3 von 4 Faellen im Stunden Budget): die Pruefung gilt auch
    -- fuer Touren mit Quests (Stunden Budget, Questlog Route, Gold und Ausruestungs Quests). Dort wird nicht neu gerechnet,
    -- die Quests fallen nur raus und kommen spaeter wieder. Nicht bei Farm, Beruf, Ruf Farm und Dungeon Route (eigene Regeln)
    local pf = ns.ProfileOf(opt)
    local realCheck = pf == "level" or (pf == "extra" and not (opt.dungeonRoute or opt.farm or opt.prof or opt.repFarm or opt.tour))
    if st and not st.foeWait and not opt.mirror and not busy and not ns.planBuilding and realCheck then
      local L = math.floor((ns.UnitLevel and ns.UnitLevel("player")) or UnitLevel("player") or 1)
      -- 19.28: in der Gruppe ab dem Gruppen Schnitt statt 1 Level mehr
      local grp = -GroupGap()
      local blocked, seenQ, worst, other, eliteHit = {}, {}, 0, false, false
      for _, a in ipairs(st.acts or {}) do
        if not ActDone(a) then
          local over
          if a.k == "O" and not a.cls and not a.buyAt then
            if a.foe and a.foe - L >= 3 + grp then over = a.foe
            elseif not a.foe and a.foeA and a.foeA - L >= 5 + grp then over = a.foeA end
          end
          -- 19.31 (Realitaets Regel, Sim Probe 19.31): auch beim Annehmen mit deinem echten Level pruefen. Questlevel 4 und
          -- mehr ueber dir, oder 3 ueber dir mit einem Gegner ueber plus 2: nicht annehmen, die Quest kommt spaeter wieder
          if a.k == "A" and not a.cls and a.ql and a.qid and not (ns.logProgress and ns.logProgress[a.qid]) then
            if a.ql - L >= 4 + grp then over = a.ql
            elseif a.ql - L >= 3 + grp and a.foeQ and a.foeQ - L >= 3 + grp then over = a.foeQ end
          end
          -- 19.32 (Sim rauch1931dev: Mor'Ladim Elite 35 mit Level 36, Vagash Elite 11 mit Level 12, du warst hinter dem Plan):
          -- Elite Gegner allein erst ab N Level unter dir (ns.EliteGap, Start 2), auch beim Ankommen mit deinem echten Level
          if not over and (a.k == "O" or a.k == "A") and not a.cls and a.eliteM and not (IsInGroup and IsInGroup())
            and (a.k == "O" or not (ns.logProgress and ns.logProgress[a.qid])) then
            local gap = ns.EliteGap and ns.EliteGap() or 2
            if a.eliteM + gap > L then over = a.eliteM; eliteHit = true end
          end
          if over and a.qid then
            if not seenQ[a.qid] then seenQ[a.qid] = true; blocked[#blocked + 1] = a.qid end
            worst = math.max(worst, over)
          else other = true end -- 19.28: weiter suchen, auch neben anderen Aufgaben (vorher Abbruch)
        end
      end
      local near = false
      if #blocked > 0 and st.map and ns.WorldDist then
        local pm = ns.PlayerMap and ns.PlayerMap()
        local pp = pm and C_Map.GetPlayerMapPosition(pm, "player")
        if pp then
          local px, py = pp:GetXY()
          local d = ns.WorldDist({ pm, px, py }, { st.map, st.x or 0.5, st.y or 0.5 })
          near = d ~= nil and d < 80
        end
      end
      if #blocked > 0 and not other and near then
        st.foeWait = true
        local now = GetTime and GetTime() or 0
        if pf == "level" and now - foeBlockAt > 600 then
          foeBlockAt = now
          ns.Print((eliteHit and TR"Die Elite Gegner hier (Level %d) sind allein noch zu stark, du bist %d. Der Abschnitt wird ab hier neu gerechnet."
            or TR"Die Gegner hier sind noch zu hoch (Level %d, du bist %d). Der Abschnitt wird ab hier neu gerechnet."):format(worst, L))
          if ns.TestLogWhy then ns.TestLogWhy("Gegner am Ziel noch zu hoch") end
          if ns.TestLog then ns.TestLog("RECHNEN", ("Neu rechnen automatisch: Gegner am Ziel zu hoch fuer Quest %d (Level %d, du %d)"):format(blocked[1], worst, L)) end
          C_Timer.After(0.5, function()
            if ns.ProfileOf(ns.db and ns.db.opt) ~= "level" then return end
            if ns.PlanActive and ns.PlanActive() then ns.PlanSectionLive() else ns.AutoOpt("auto") end
          end)
        else
          ns.Print((eliteHit and TR"Die Elite Gegner hier (Level %d) sind allein noch zu stark: die Route lässt diese Quests hier aus, sie kommen später wieder."
          or TR"Die Gegner hier sind noch zu hoch (Level %d): die Route lässt diese Quests hier aus, sie kommen später wieder."):format(worst))
          if ns.TestLog then ns.TestLog("SCHRITT", ("Gegner am Ziel zu hoch, Quests ausgelassen (Level %d, du %d)"):format(worst, L)) end
          for _, q in ipairs(blocked) do ns.OptDropQuest(q, TR"Gegner noch zu hoch") end
        end
        return
      end
      -- 19.28 (Realitaets Regel): im Schritt sind auch andere Aufgaben (zb eine zweite Quest abgeben). Vorher ging die
      -- Pruefung dann gar nicht, du hast die zu hohen Gegner gemacht. Jetzt fallen nur diese Quests hier weg (kommen
      -- spaeter wieder), der Rest vom Schritt bleibt
      if #blocked > 0 and other and near then
        st.foeWait = true
        ns.Print((eliteHit and TR"Die Elite Gegner hier (Level %d) sind allein noch zu stark: die Route lässt diese Quests hier aus, sie kommen später wieder."
          or TR"Die Gegner hier sind noch zu hoch (Level %d): die Route lässt diese Quests hier aus, sie kommen später wieder."):format(worst))
        if ns.TestLog then ns.TestLog("SCHRITT", ("Gegner am Ziel zu hoch, Quests ausgelassen, Rest vom Schritt bleibt (Level %d, du %d)"):format(worst, L)) end
        for _, q in ipairs(blocked) do ns.OptDropQuest(q, TR"Gegner noch zu hoch") end
        return
      end
    end
  end
  while opt.steps[i] and StepDone(opt.steps[i]) and not GroupHold(opt.steps[i], i) do
    -- Mein Weg: nur was wirklich erledigt ist (erkannt), nichts Uebersprungenes
    if ns.MyWayAdd then pcall(ns.MyWayAdd, opt.steps[i], opt) end
    i = i + 1
  end
  if i ~= opt.idx then
    opt.idx = i
    -- v11e (Pr P29, PLAN_TURNIN_INCOMPLETE Westfall Eintopf; S L8.4): Abgabe ist dran, die Quest ist im Log aber nicht fertig
    -- (vorab gesammelt wurde zu wenig, zb Zahl aus dem Text falsch). Dann die offenen Ziele dieser Quest wieder davor
    pcall(V11.ReopenObjectives, opt, i)
    -- 20.3f (REGEL K 16:42): auch beim Spielen die Vorquest Pruefung fuer den Rest der Route, mit dem echten Stand
    -- (wurde eine Abgabe uebersprungen, kommt die Folgequest hinter die naechste Abgabe der Vorquest oder raus)
    if not opt.mirror then
      local okV, stV = pcall(VorquestOrder, opt.steps, i, Completed1, function(id) return ns.logProgress and ns.logProgress[id] end, nil, i + 59, true)
      if okV and stV and (stV.move + stV.gone) > 0 and ns.TestLog then
        ns.TestLog("SCHRITT", ("Vorquest Pruefung beim Spielen: %d geschoben, %d Quests raus"):format(stV.move, stV.gone))
      end
    end
    local s = opt.steps[i]
    if s then
      ns.Print((TR"Schritt %d von %d: %s"):format(i, #opt.steps, ns.OptStepText(s)))
      -- neuer Schritt: bist du ein ganzes Level voraus oder hinten? (dann neu rechnen)
      if ns.PlanLevelCheck then C_Timer.After(1, function() ns.PlanLevelCheck("schritt") end) end
    elseif (opt.group or opt.split) and ns.db.optParked then
      -- Gruppen Route fertig: zur gemerkten Farm oder Spezialroute zurueck
      C_Timer.After(2, function() if not ns.OptUnpark() then ns.AutoOpt(true) end end)
    elseif opt.farm and ns.FarmLoopAgain and ns.FarmLoopAgain(opt) then
      -- 20.2: Gold Farm Runde wieder ab der ersten Stelle
      local s1 = opt.steps[1]
      if s1 then ns.Print((TR"Schritt %d von %d: %s"):format(1, #opt.steps, ns.OptStepText(s1))) end
    elseif opt.prof and ns.ProfLoopAgain and ns.ProfLoopAgain(opt) then
      -- Endlos Runde: wieder ab Schritt 1
      local s1 = opt.steps[1]
      if s1 then ns.Print((TR"Schritt %d von %d: %s"):format(1, #opt.steps, ns.OptStepText(s1))) end
    elseif opt.prof then
      if ns.ProfFinish then ns.ProfFinish() end
      AfterFinished(3, opt)
    else
      if opt.opts and not opt.opts.gold then
        ns.Print(TR"|cff40ff40Abschnitt fertig!|r Der nächste wird berechnet ...")
        AfterFinished(3, opt)
      else
        ns.Print(TR"|cff40ff40Route fertig!|r Die normale Leveling Route geht gleich weiter.")
        AfterFinished(3, opt)
      end
    end
    if ns.Draw then ns.Draw() end
  end
end
ns.OptSync = Sync

local KN = { A = TR"Annehmen", O = TR"Ziel", T = TR"Abgeben" }
local KC = { P = "|cff66ff99", L = "|cffb0e0ff", M = "|cff66ccff", V = "|cffffd100", B = "|cffb0e0ff", H = "|cffb0e0ff", G = "|cffff5050", A = "|cffff9030", O = "|cffff66cc", T = "|cff40ff90", R = "|cff66ccff", F = "|cff66ff66", E = "|cffffff66", K = "|cffc080ff" }

-- "fährt in 1:20" wenn Nauticus den Takt kennt
local function WaitText(a)
  local w = ns.TravelDeparts and ns.TravelDeparts(a.link, a.side, a.li)
  if not w then return "" end
  return (TR" (fährt in %d:%02d)"):format(math.floor(w / 60), math.floor(w % 60))
end
ns.OptWaitText = WaitText

-- Name eines Questziels zum Anzeigen: interne Questie Namen ("<TXT>... Doodad") durch den Questnamen ersetzen
local function ObjShow(a)
  local o = a.obj
  if type(o) == "string" and o:find("^<") then return a.quest or (o:gsub("^<[^>]*>", "")) end
  -- Platzhalter Namen aus den Daten (unsichtbare Hilfs NPCs, zb "Credit" bei Eyes of the Sentinels): lieber der Quest Name
  if o == "Credit" or (type(o) == "string" and (o:find("^Trigger ") or o:find("Credit Marker"))) then return a.quest or o end
  return o
end
ns.OptObjShow = ObjShow

function ns.OptStepText(s)
  local parts = {}
  for _, a in ipairs(s.acts) do
    if a.k == "P" then
      table.insert(parts, ns.ProfActText and ns.ProfActText(a) or TR"Farmen")
    elseif a.k == "L" then
      table.insert(parts, (TR"%sAusloggen|r im Gasthaus bei %s (Ruhebonus)"):format(KC.L, a.quest or "?"))
      -- Forever: der Schlafsack zaehlt auch als Ruhezone (17.5, Wunsch Sascha: als Moeglichkeit nennen)
      if ns.HasSleepingBag and ns.HasSleepingBag() then table.insert(parts, TR"   oder statt Gasthaus: Schlafsack hinlegen und darin ausloggen") end
    elseif a.k == "V" and a.books then
      table.insert(parts, (TR"%sBücher abgeben|r bei %s"):format(KC.V, a.quest or TR"Bibliothekar"))
    elseif a.k == "V" and a.trainer then
      table.insert(parts, (TR"%sLehrer:|r neue Zauber lernen bei %s"):format(KC.V, a.quest or TR"Lehrer"))
    elseif a.k == "V" and a.manual then
      table.insert(parts, (TR"%sHändler:|r %s ansprechen (verkaufen, reparieren)"):format(KC.V, a.quest or TR"Händler"))
    elseif a.k == "V" and a.buy then
      table.insert(parts, (TR"%sEinkaufen|r bei %s: %s"):format(KC.V, a.quest or TR"Händler", a.buy))
    elseif a.k == "M" then
      table.insert(parts, (TR"%sTreffpunkt:|r Eingang %s, Quests teilen"):format(KC.M, a.quest or "?"))
    elseif a.k == "V" then
      table.insert(parts, (TR"%sTaschen leeren|r bei %s"):format(KC.V, a.quest or TR"Händler"))
    elseif a.k == "B" then
      table.insert(parts, (TR"%sRuhestein binden|r bei %s"):format(KC.B, a.quest or TR"Gastwirt"))
    elseif a.k == "H" then
      table.insert(parts, (TR"%s%s|r nach %s"):format(KC.H, a.recall and TR"Astraler Rückruf" or TR"Ruhestein benutzen", a.quest or "?"))
    elseif a.k == "G" and a.repFarm then
      table.insert(parts, (TR"%sRuf farmen:|r %s für %s"):format(KC.G, a.obj or TR"Mobs", a.rep or "?"))
    elseif a.k == "G" and a.farm then
      table.insert(parts, (TR"%sGold farmen:|r %s (Lvl %d bis %d), ca %s pro Stunde"):format(KC.G, a.obj or TR"Mobs", a.lo or 0, a.hi or 0, ns.Money and ns.Money(a.gph or 0) or "?"))
    elseif a.k == "G" and a.hint then
      -- fehlende Level: wie viel noch, gerechnet mit dem echten Stand
      -- Level mit Anteil jetzt (zb 12.4), fehlend = Ziel minus jetzt (nicht XP durch eine Level Spanne: das gab 110 Level)
      local L = UnitLevel("player") or 1
      local xp, mx = (ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0), (ns.Plain and ns.Plain(UnitXPMax("player")) or UnitXPMax("player") or 1)
      local Lf = L + (mx > 0 and xp / mx or 0)
      local left = math.max(0, (a.toLvl or 0) - Lf)
      if a.grp and a.dung and left > 0 and left <= 5 then
        table.insert(parts, (TR"%sGruppe: jetzt passt Dungeon %s|r. Euch fehlen noch ca %.1f Level bis %.1f, dafür ist der Dungeon mit seinen Quests besser als grinden. Die Route gibt es im Fenster unter Dungeons."):format(
          KC.G, a.dung, left, a.toLvl or 0))
      elseif a.grp and a.dung then
        table.insert(parts, (TR"%sGruppe: Dungeon %s|r bis Level %.1f, dann geht die Route weiter."):format(KC.G, a.dung, a.toLvl or 0))
      elseif left > 0 and left <= 5 and a.dung then
        table.insert(parts, (TR"%sDir fehlen noch ca %.1f Level|r bis Level %.1f für den nächsten Schritt. Am besten Dungeon %s, sonst grinden, dann geht die Route weiter."):format(
          KC.G, left, a.toLvl or 0, a.dung))
      elseif left > 0 and left <= 5 then
        table.insert(parts, (TR"%sDir fehlen noch ca %.1f Level|r bis Level %.1f für den nächsten Schritt. Jetzt grinden oder Dungeons machen, dann geht die Route weiter."):format(
          KC.G, left, a.toLvl or 0))
      elseif a.dung then
        table.insert(parts, (TR"%sLevel fehlt:|r bis Level %.1f, am besten Dungeon %s, sonst grinden. Dann geht die Route weiter."):format(KC.G, a.toLvl or 0, a.dung))
      else
        -- weit in der Zukunft (Weg zu 60): nur das Ziel Level
        table.insert(parts, (TR"%sLevel fehlt:|r bis Level %.1f grinden oder Dungeons, dann geht die Route weiter"):format(KC.G, a.toLvl or 0))
      end
    elseif a.k == "G" and a.kills then
      table.insert(parts, ((a.kills == 1) and TR"%sNoch ca %d Mob hauen|r bis Level %d, dann gleich zum Lehrer" or TR"%sNoch ca %d Mobs hauen|r bis Level %d, dann gleich zum Lehrer"):format(KC.G, a.kills, math.floor((a.toLvl or 0) + 0.01)))
    elseif a.k == "G" and (a.farm or a.repFarm or not a.toLvl or a.toLvl <= 0) then
      -- 20.3 (P2c): Farm Schritt ohne Level Ziel, vorher stand "bis Level 0.0"
      table.insert(parts, (TR"%sFarmen:|r %s (Lvl %d bis %d)"):format(KC.G, a.obj or TR"Mobs", a.lo or 0, a.hi or 0))
    elseif a.k == "G" then
      table.insert(parts, (TR"%sGrinden:|r %s (Lvl %d bis %d), ca %d Min bis Level %.1f"):format(KC.G, a.obj or TR"Mobs", a.lo or 0, a.hi or 0, a.min or 0, a.toLvl or 0))
    elseif a.k == "F" then
      table.insert(parts, (TR"%sFlugpunkt holen:|r %s"):format(KC.F, a.who or "?"))
    elseif a.k == "K" then
      table.insert(parts, (TR"%sBuch holen:|r %s%s"):format(KC.K or KC.E, a.quest or a.name or "?", a.note and (" |cff9d9d9d(" .. a.note .. ")|r") or ""))
    elseif a.k == "E" then
      table.insert(parts, (TR"%sEntdecken:|r %s"):format(KC.E, a.name or "?"))
    elseif a.k == "R" then
      table.insert(parts, (TR"%sReise:|r %s nach %s%s"):format(KC.R, a.kind or TR"Schiff", a.dest or "?", WaitText(a)))
    elseif a.tram and a.k == "A" then
      table.insert(parts, (TR"%sTiefenbahn:|r %s bei Monty annehmen |cff9d9d9d(er steht am Bahnsteig Eisenschmiede, in der Bahn gibt es keinen Pfeil)|r"):format(KC.A, a.quest or "?"))
    elseif a.tram and a.k == "O" then
      table.insert(parts, (TR"%sTiefenbahn:|r mit der Rattenfängerflöte 5 Ratten fangen |cff9d9d9d(sie laufen an den Gleisen beim Bahnsteig Eisenschmiede, Flöte benutzen, dann laufen sie dir nach)|r"):format(KC.O))
    elseif a.tram and a.k == "T" then
      table.insert(parts, (TR"%sTiefenbahn:|r %s bei Monty abgeben |cff9d9d9d(Bahnsteig Eisenschmiede, die Flöte gibst du dabei zurück)|r"):format(KC.T, a.quest or "?"))
    elseif a.dungeon then
      table.insert(parts, (TR"%sIm Dungeon:|r %s"):format(KC.O, a.quest or "?"))
    elseif a.k == "O" and a.buyAt then
      table.insert(parts, (TR"%sKaufen|r bei %s: %s %s |cff9d9d9d(für %s)|r"):format(KC.V, a.buyAt, ObjShow(a) or "?", ns.OptCountText(a), a.quest or "?"))
    elseif a.k == "O" and a.pre then
      table.insert(parts, (TR"%sUnterwegs sammeln:|r %s %s |cff9d9d9d(für %s, später)|r"):format(KC.O, ObjShow(a) or "?", ns.OptCountText(a), a.quest or "?"))
    elseif a.k == "O" then
      table.insert(parts, ("%s%s|r %s"):format(KC.O, ObjShow(a) or a.quest or "?", ns.OptCountText(a)))
    else
      local extra = ""
      if a.k == "A" and a.buy then
        local names = {}
        for _, b in ipairs(a.buy) do table.insert(names, b.name or "?") end
        extra = TR" |cffffd100(kaufen: " .. table.concat(names, ", ") .. ")|r"
      end
      -- 1.1 (S Log L9.4 "im Mini Fenster zeigt es nicht an, wie viel EP es beim Abgeben gibt"): XP beim Abgeben dazu
      if a.k == "T" and a.qid and not (ns.db and ns.db.hudXP == false) then
        local L = UnitLevel and UnitLevel("player") or 1
        local lp = ns.logProgress and ns.logProgress[a.qid]
        local okX, xpv = pcall(QuestXPAt, a.qid, lp and lp.level or a.ql, L)
        if okX and type(xpv) == "number" and xpv > 0 then extra = extra .. (" |cff9d9d9d(+%d XP)|r"):format(math.floor(xpv)) end
      end
      table.insert(parts, ("%s%s|r %s%s"):format(KC[a.k], KN[a.k], a.quest or "?", extra))
    end
    -- Klassenquest eines Mitspielers: du wartest
    if a.cls and (a.k == "A" or a.k == "O" or a.k == "T") and #parts > 0 then
      local _, mc = UnitClass("player")
      if mc and a.cls ~= mc then parts[#parts] = (TR"|cff9d9d9dWarten: %s macht die Klassenquest %s|r"):format(a.forName or "?", a.quest or "?") end
    end
    -- Gruppen Route: was du nicht machen kannst
    local hw = ns.mirrorActive and ns.MirrorHelp and ns.MirrorHelp(a)
    if hw and #parts > 0 then
      if a.k == "V" and a.trainer then parts[#parts] = (TR"|cff9d9d9dWarten: %s lernt beim Lehrer|r"):format(hw)
      elseif a.k == "H" then parts[#parts] = (TR"%sRuhestein:|r du bist woanders gebunden, mit %s mitlaufen"):format(KC.H, hw)
      elseif a.k == "F" then parts[#parts] = parts[#parts] .. TR" |cff9d9d9d(hast du schon)|r"
      else parts[#parts] = parts[#parts] .. (TR" |cff9d9d9d(für %s, hilf mit)|r"):format(hw) end
    end
  end
  return table.concat(parts, ", ")
end

-- Ziel fuer den Pfeil, mit Tags fuer die Quest Hinweise
-- pro Frame nur einmal rechnen (Pfeil, Mini Fenster und Pfad fragen alle)
local OptTargetRaw
local otCache = {}
-- herumlaufender Mob: erst zum naechsten Punkt seines Wegs, dann auf dem Weg ihm entgegen (gegen seine Laufrichtung),
-- immer etwa 40 Yards voraus. An den Enden eines offenen Wegs dreht es um, ein Rundweg geht im Kreis.
local function PatrolGuide(a, paths, map, px, py)
  local function D(x1, y1, x2, y2) return ns.WorldDist and ns.WorldDist({ map, x1, y1 }, { map, x2, y2 }) end
  local bp, bi, bd
  for pi, path in ipairs(paths) do
    for i, p in ipairs(path) do
      local d = D(px, py, p[1], p[2])
      if d and (not bd or d < bd) then bp, bi, bd = pi, i, d end
    end
  end
  if not bp then return end
  local path = paths[bp]
  if bd > 40 then a.pg = nil; return path[bi][1], path[bi][2] end
  local loop = #path > 2 and (D(path[1][1], path[1][2], path[#path][1], path[#path][2]) or 999) < 25
  local g = a.pg
  if not g or g.p ~= bp then g = { p = bp, dir = -1 }; a.pg = g end
  local j, acc, steps = bi, 0, 0
  while acc < 40 and steps < #path do
    local nj = j + g.dir
    if nj < 1 then
      if loop then nj = #path else g.dir = 1; nj = j + 1 end
    elseif nj > #path then
      if loop then nj = 1 else g.dir = -1; nj = j - 1 end
    end
    if nj < 1 or nj > #path then break end
    acc = acc + (D(path[j][1], path[j][2], path[nj][1], path[nj][2]) or 0)
    j = nj
    steps = steps + 1
  end
  return path[j][1], path[j][2]
end
ns.OptPatrolGuide = PatrolGuide

function ns.OptTarget()
  local db = ns.db
  local opt = db and db.opt
  local now = GetTime and GetTime() or 0
  if otCache.t == now and otCache.opt == opt and otCache.idx == (opt and opt.idx) and otCache.n == ns.optDoneRev then
    return otCache[1], otCache[2], otCache[3]
  end
  local a, b, c = OptTargetRaw()
  otCache.t, otCache.opt, otCache.idx, otCache.n = now, opt, opt and opt.idx, ns.optDoneRev
  otCache[1], otCache[2], otCache[3] = a, b, c
  return a, b, c
end
OptTargetRaw = function()
  local db = ns.db
  if not (db and db.optMode and db.opt) then return end
  local s = db.opt.steps and db.opt.steps[db.opt.idx or 1]
  -- Schritt ohne Aktion (kaputte oder sehr alte gespeicherte Route): nichts zeigen statt Fehler
  if not (s and type(s.acts) == "table" and s.acts[1]) then return end
  local tags = {}
  local quests, turns = {}, {}
  for _, a in ipairs(s.acts) do
    if not ActDone(a) then
      if a.k == "A" then table.insert(quests, { id = a.qid, name = a.quest }) end
      if a.k == "T" then table.insert(turns, { id = a.qid, name = a.quest }) end
      if a.k == "O" and not tags.obj then tags.obj = { qid = a.qid, obj = a.obj, quest = a.quest, npcs = a.npcs } end
    end
  end
  if #quests > 0 then tags.quest = { s.x, s.y, s.acts[1].who or "?", quests = quests } end
  if #turns > 0 then tags.turnin = { s.x, s.y, s.acts[1].who or "?", quests = turns } end
  local first
  for _, a in ipairs(s.acts) do if not ActDone(a) then first = a; break end end
  first = first or s.acts[1]
  local name
  if first.k == "P" then name = ns.ProfActText and ns.ProfActText(first, true) or TR"Farmen"
  elseif first.k == "L" then name = (TR"Ausloggen im Gasthaus bei %s"):format(first.quest or "?")
  elseif first.k == "V" and first.books then name = (TR"Bücher abgeben bei %s"):format(first.quest or TR"Bibliothekar")
  elseif first.k == "V" and first.trainer then name = (TR"Neue Zauber bei %s"):format(first.quest or TR"Lehrer")
  elseif first.k == "V" and first.buy then name = (TR"Einkaufen bei %s: %s"):format(first.quest or TR"Händler", first.buy)
  elseif first.k == "M" then name = (TR"Treffpunkt: Eingang %s"):format(first.quest or "?")
  elseif first.k == "V" then name = (TR"Taschen leeren bei %s"):format(ns.NpcName and ns.NpcName(first.npc, first.quest) or first.quest or TR"Händler")
  elseif first.k == "B" then name = (TR"Ruhestein binden bei %s"):format(first.quest or TR"Gastwirt")
  elseif first.k == "H" then name = first.recall and TR"Jetzt Astraler Rückruf" or TR"Jetzt Ruhestein benutzen"
  -- 20.2 (P2c): Farmen hat kein Level Ziel (vorher "bis Level 0.0")
  elseif first.k == "G" and first.farm then name = (TR"Gold farmen: %s"):format(first.obj or TR"Mobs")
  elseif first.k == "G" and first.repFarm then name = (TR"Ruf farmen: %s"):format(first.obj or TR"Mobs")
  elseif first.k == "G" and (not first.toLvl or first.toLvl <= 0) then name = (TR"Farmen: %s"):format(first.obj or TR"Mobs")
  elseif first.k == "G" then name = (TR"Grinden: %s bis Level %.1f"):format(first.obj or TR"Mobs", first.toLvl or 0)
  elseif first.k == "F" then name = (TR"Flugpunkt bei %s"):format(first.who or "?")
  elseif first.k == "E" then name = (TR"Entdecken: %s"):format(first.name or "?")
  elseif first.k == "K" then
    -- lange Buchtitel kuerzen (sonst drei Zeilen im Mini Fenster), der ganze Titel steht im Tooltip und im Buecher Fenster
    -- 18.0: Titel und Ort je genau auf eine Zeile (gemessen), Ort zuerst beim Komma gekuerzt. Ganzer Ort im Tooltip ("Wo:")
    local bt = tostring(first.quest or first.name or "?")
    local pre = TR"Buch holen: %s%s"
    local note = first.note
    if ns.FitLine then
      bt = ns.FitLine(bt, pre:format("", ""))
      if note then note = ns.FitLine(note, nil, true) end
    elseif #bt > 30 then bt = bt:sub(1, 28):gsub("[\192-\255][\128-\191]*$", ""):gsub("[%s:,]+$", "") .. ".." end
    name = pre:format(bt, note and ("\n|cff9d9d9d" .. note .. "|r") or "")
  elseif first.tram and first.k == "A" then name = TR"Tiefenbahn: Quest bei Monty annehmen\n|cff9d9d9dBahnsteig Eisenschmiede, ohne Pfeil|r"
  elseif first.tram and first.k == "O" then name = TR"Tiefenbahn: 5 Ratten mit der Flöte fangen\n|cff9d9d9dGleise beim Bahnsteig Eisenschmiede|r"
  elseif first.tram and first.k == "T" then name = TR"Tiefenbahn: bei Monty abgeben\n|cff9d9d9dBahnsteig Eisenschmiede, Flöte zurück|r"
  elseif first.k == "R" then name = (TR"%s nach %s nehmen%s"):format(first.kind or TR"Schiff", first.dest or "?", WaitText(first))
  elseif first.k == "O" and first.buyAt then name = (TR"Kaufen bei %s: %s"):format(first.buyAt, ObjShow(first) or "?")
    if ns.FitTwo then name = ns.FitTwo(name) end
  elseif first.k == "O" then name = (TR"Ziel: %s"):format(ObjShow(first) or first.quest or "?")
    -- 18.6: hoechstens zwei Zeilen (lange Item Namen mit Herkunft)
    if ns.FitTwo then name = ns.FitTwo(name) end
  elseif first.k == "A" then name = (TR"Annehmen bei %s"):format(ns.NpcName and ns.NpcName(first.npc, first.who) or first.who or "?")
  else name = (TR"Abgeben bei %s"):format(ns.NpcName and ns.NpcName(first.npc, first.who) or first.who or "?") end
  if first.cls and (first.k == "A" or first.k == "O" or first.k == "T") then
    local _, mc = UnitClass("player")
    if mc and first.cls ~= mc then name = (TR"Warten: %s macht die Klassenquest"):format(first.forName or "?") end
  end
  local hw = ns.mirrorActive and ns.MirrorHelp and ns.MirrorHelp(first)
  if hw then
    if first.k == "V" and first.trainer then name = (TR"Warten: %s lernt beim Lehrer"):format(hw)
    elseif first.k == "H" then name = (TR"Mit %s mitlaufen, dein Ruhestein geht woanders hin"):format(hw)
    elseif first.k == "F" then name = name .. TR" (hast du schon)"
    else name = (TR"Hilf %s: "):format(hw) .. name end
  end
  -- Questziel mit mehreren Fundorten. Viele Spawns: in Gebiete aufteilen und auf die Mitte vom Gebiet zeigen
  -- (der Pfeil bleibt beim gewaehlten Gebiet, kein Hin und Her). Wenige feste Punkte: der Reihe nach ablaufen,
  -- das Ziel wechselt erst, wenn du dort warst oder ein anderer Punkt viel naeher ist.
  -- Ziel ist ein einzelner herumlaufender Mob: seinem Weg folgen
  if first.k == "O" and type(first.npcs) == "table" and #first.npcs == 1 and not ActDone(first) and ns.Waypoints
    and (type(first.pts) ~= "table" or #first.pts <= 8) then
    local paths = ns.Waypoints(first.npcs[1], s.map)
    local pos = paths and C_Map.GetPlayerMapPosition(s.map, "player")
    if pos then
      local px, py = pos:GetXY()
      -- hoechstens zweimal pro Sekunde neu rechnen
      local tx, ty
      local now = GetTime and GetTime() or 0
      if first.pgT and now - first.pgT < 0.5 and first.pgX then tx, ty = first.pgX, first.pgY
      else
        tx, ty = PatrolGuide(first, paths, s.map, px, py)
        first.pgT, first.pgX, first.pgY = now, tx, ty
      end
      if tx then
        local nm2 = name .. TR"\n|cff9d9d9dläuft herum, Weg auf der Karte|r"
        local proxy = setmetatable({ x = tx, y = ty }, { __index = s })
        return proxy, { tx, ty, nm2, tags = tags }, nm2
      end
    end
  end
  if first.k == "O" and type(first.pts) == "table" and #first.pts > 1 and not ActDone(first) then
    local pos = C_Map.GetPlayerMapPosition(s.map, "player")
    local px, py
    if pos then px, py = pos:GetXY() end
    local function Dist(x1, y1, x2, y2)
      return ns.WorldDist and ns.WorldDist({ s.map, x1, y1 }, { s.map, x2, y2 }) or nil
    end
    -- v11d (Ka 10:36 L12.5 Zhevra: Pfeil nahm einen einzelnen Spawn statt des naechsten Haufens): Gebiete ab V11.AREA_MIN_PTS
    if #first.pts >= V11.AREA_MIN_PTS then
      -- Gebiete einmal bilden: Punkte, die nah beieinander liegen (ca 150 Yards), gehoeren zusammen
      if not first.areas then
        local areas = {}
        for _, p in ipairs(first.pts) do
          local hit
          for _, ar in ipairs(areas) do
            local d = Dist(ar.x, ar.y, p[1], p[2])
            if d and d < 150 then hit = ar; break end
          end
          if not hit then hit = { sx = 0, sy = 0, n = 0, x = p[1], y = p[2], list = {} }; areas[#areas + 1] = hit end
          hit.sx, hit.sy, hit.n = hit.sx + p[1], hit.sy + p[2], hit.n + 1
          hit.x, hit.y = hit.sx / hit.n, hit.sy / hit.n
          hit.list[#hit.list + 1] = p
        end
        for _, ar in ipairs(areas) do
          local r = 0
          for _, p in ipairs(ar.list) do local d = Dist(ar.x, ar.y, p[1], p[2]); if d and d > r then r = d end end
          ar.r = math.max(40, math.min(80, r))
          -- 1.1 (K Stufe C 23): grosses Gebiet (weit verteilte Spawns) als Runde: Punkte nach Winkel um die Mitte, hoechstens
          -- V11.RUND_MAX, Pfeil und Karte gehen sie reihum ab (Arrow.lua Feld rund)
          if ar.n >= V11.RUND_MIN_N and r >= V11.RUND_MIN_R then
            local loop = V11.RundLoop(ar.list, Dist)
            if loop and #loop >= 3 then ar.loop = loop end
          end
          ar.list = nil
        end
        first.areas = areas
      end
      local areas = first.areas
      local cur = areas[first.area or 0]
      -- im Gebiet eines anderen? dann ist das jetzt das Ziel
      -- 1.1 (S L1.5 "Pfeil schwabbelt hin und her"): Gebiete ueberlappen (Radius bis 80, Abstand ab 150 yd Mitte). Stand
      -- man in beiden, sprang das Ziel jede Pruefung hin und her. Jetzt bleibt es, solange du im aktuellen Gebiet bist
      local inCur = false
      if px and cur then local dc = Dist(px, py, cur.x, cur.y); inCur = dc and dc <= cur.r end
      if px and not inCur and (not cur or (GetTime and GetTime() or 0) - (first.areaSwAt or 0) >= V11.ARROW_HOLD_S) then
        for k, ar in ipairs(areas) do
          local d = Dist(px, py, ar.x, ar.y)
          -- 1.1 (P43): nur wenn du gut im anderen Gebiet bist (nicht am Rand, wo sich zwei Gebiete beruehren)
          if d and d <= ar.r * V11.AREA_ENTER_F and k ~= first.area then
            first.area, cur = k, ar
            first.areaSwAt = GetTime and GetTime() or 0
            break
          end
        end
      end
      -- 1.1 (K Stufe C 23, mehr Alternativen): im Gebiet, aber V11.AREA_STALE_S lang kein Fortschritt (leer gefarmt, andere
      -- Spieler): dieses Gebiet als versucht merken und das naechstbeste nehmen
      if cur and inCur then
        local prog = ns.OptCountText and ns.OptCountText(first) or ""
        local nowS = GetTime and GetTime() or 0
        if first.areaProg ~= prog or first.areaIdx ~= first.area then first.areaProg, first.areaIdx, first.areaAt = prog, first.area, nowS
        elseif nowS - (first.areaAt or nowS) >= V11.AREA_STALE_S and #areas > 1 then
          first.areaTried = first.areaTried or {}
          first.areaTried[first.area] = true
          local n0 = 0
          for k in ipairs(areas) do if not first.areaTried[k] then n0 = n0 + 1 end end
          if n0 == 0 then first.areaTried = { [first.area] = true } end
          first.area, cur, first.areaAt = nil, nil, nowS
          if ns.TestLog then ns.TestLog("PFEIL", ("Gebiet ohne Fortschritt, naechstes: %s"):format(tostring(first.quest))) end
        end
      end
      -- noch keins gewaehlt: das mit den meisten Spawns, bei aehnlich vielen das naehere
      if not cur then
        local best, bs
        for k, ar in ipairs(areas) do
          if not (first.areaTried and first.areaTried[k]) then
          local d = px and Dist(px, py, ar.x, ar.y) or 0
          local score = ar.n / (1 + (d or 0) / 400)
          if not bs or score > bs then best, bs = k, score end
          end
        end
        first.area, cur = best, areas[best]
      end
      if not cur then cur = areas[1]; first.area = 1 end
      first.radius = cur.r
      local proxy = setmetatable({ x = cur.x, y = cur.y, rund = cur.loop }, { __index = s })
      return proxy, { cur.x, cur.y, name, tags = tags }, name
    end
    if px then
      first.vis = first.vis or {}
      for k, p in ipairs(first.pts) do
        local d = Dist(px, py, p[1], p[2])
        if d and d < 15 then first.vis[k] = true end
      end
      -- alle besucht: von vorne
      local open = false
      for k in ipairs(first.pts) do if not first.vis[k] then open = true; break end end
      if not open then first.vis = {}; first.cur = nil end
      local cur = first.cur and not first.vis[first.cur] and first.pts[first.cur] and first.cur or nil
      local cd = cur and Dist(px, py, first.pts[cur][1], first.pts[cur][2])
      local best, bd
      for k, p in ipairs(first.pts) do
        local d = Dist(px, py, p[1], p[2])
        if d and not first.vis[k] and d >= 15 and (not bd or d < bd) then best, bd = k, d end
      end
      -- nur wechseln, wenn das neue Ziel deutlich naeher ist (sonst schwankt der Pfeil)
      -- 1.1 (S L1.5): und hoechstens alle V11.ARROW_HOLD_S Sekunden, ausser das alte Ziel ist erreicht (besucht)
      local nowA = GetTime and GetTime() or 0
      if best and (not cur or not cd or (bd < cd * 0.6 and nowA - (first.curAt or 0) >= V11.ARROW_HOLD_S)) then
        if cur ~= best then first.curAt = nowA end
        cur = best
      end
      first.cur = cur
      local p = cur and first.pts[cur]
      if p then
        local proxy = setmetatable({ x = p[1], y = p[2] }, { __index = s })
        return proxy, { p[1], p[2], name, tags = tags }, name
      end
    end
  end
  -- 19.17 (Sascha: "Pfeil auf den Questgeber"): Questgeber, der herumlaeuft (Laufweg aus Questie, zb Karawane in
  -- Desolace, Wachen auf Streife): seinem Weg folgen wie bei einem herumlaufenden Questziel. Vorher zeigte der Pfeil
  -- immer auf die Stelle aus den Daten, auch wenn der NPC gerade ganz woanders auf seinem Weg war.
  if (first.k == "A" or first.k == "T") and first.npc and not first.tram and not ActDone(first) and ns.Waypoints and s.map then
    local paths = ns.Waypoints(first.npc, s.map)
    local pos = paths and C_Map.GetPlayerMapPosition(s.map, "player")
    if pos then
      local px, py = pos:GetXY()
      local tx, ty
      local now = GetTime and GetTime() or 0
      if first.pgT and now - first.pgT < 0.5 and first.pgX then tx, ty = first.pgX, first.pgY
      else
        tx, ty = PatrolGuide(first, paths, s.map, px, py)
        first.pgT, first.pgX, first.pgY = now, tx, ty
      end
      if tx then
        local nm2 = name .. TR"\n|cff9d9d9dläuft herum, Weg auf der Karte|r"
        local proxy = setmetatable({ x = tx, y = ty }, { __index = s })
        return proxy, { tx, ty, nm2, tags = tags }, nm2
      end
    end
  end
  -- 17.9: Aktion mit eigenem Ort (Buecher abgeben, Haendler, Gasthaus) im gleichen Schritt, aber ein paar Yards daneben
  -- (ein Schritt fasst Stopps bis 25 Yards zusammen): Pfeil zum NPC, sonst steht man am Schritt und es geht nicht weiter
  -- (Sim 17.8: Buecher abgeben in Sturmwind und Unterstadt blieb haengen)
  -- 19.17: auch Annehmen und Abgeben. Zwei Questgeber im selben Schritt: der Pfeil blieb beim ersten, auch wenn du dort
  -- schon fertig warst (Text, Ring ueber dem Kopf und Anvisieren zeigten schon den zweiten)
  if first.imap and first.ix and first.iy and (first.k == "V" or first.k == "B" or first.k == "L"
    or ((first.k == "A" or first.k == "T") and not first.tram)) and s.map and ns.WorldDist then
    local tx, ty = first.ix, first.iy
    if first.imap ~= s.map then tx, ty = ns.ToMap(first.imap, first.ix, first.iy, s.map) end
    if tx then
      local d = ns.WorldDist({ s.map, s.x, s.y }, { s.map, tx, ty })
      if d and d > 8 then
        local proxy = setmetatable({ x = tx, y = ty }, { __index = s })
        return proxy, { tx, ty, name, tags = tags }, name
      end
    end
  end
  return s, { s.x, s.y, name, tags = tags }, name
end

-- erste offene Aktion vom aktuellen Schritt (fuer Icon und Ankunfts Radius am Pfeil)
function ns.OptCurrentAct()
  local db = ns.db
  if not (db and db.optMode and db.opt and db.opt.steps) then return end
  local s = db.opt.steps[db.opt.idx or 1]
  if not s then return end
  for _, a in ipairs(s.acts) do if not ActDone(a) then return a end end
  return s.acts[1]
end

-- Naechsten Haendler oder Lehrer als Schritt in die Route einfuegen (Menue). Nochmal klicken: Schritt wieder raus.
function ns.OptInsertService(kind)
  local db = ns.db
  if not db then return end
  local trainer = kind == "trainer"
  local opt = db.optMode and db.opt
  local idx = opt and opt.steps and (opt.idx or 1)
  local cur = idx and opt.steps[idx]
  if cur and cur.ins == kind then
    table.remove(opt.steps, idx)
    ns.Print(TR"Schritt wieder raus, weiter mit der Route")
    if ns.Draw then ns.Draw() end
    if ns.RefreshHud then ns.RefreshHud() end
    return
  end
  if not ns.svcReady then ns.Print(trainer and TR"Lehrer werden noch eingelesen, gleich nochmal versuchen." or TR"Händler werden noch eingelesen, gleich nochmal versuchen."); return end
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local t, d
  if trainer then
    t, d = ns.NearestSvc("trainer", map, px, py, true)
  else
    -- Haendler mit Reparatur bevorzugen, wenn er nicht viel weiter weg ist
    local v, dv = ns.NearestSvc("vendor", map, px, py, true)
    local r, dr = ns.NearestSvc("repair", map, px, py, true)
    t, d = v, dv
    if r and (not dv or dr <= dv * 1.3) then t, d = r, dr end
  end
  if not t then ns.Print(trainer and TR"Kein Lehrer gefunden" or TR"Kein Händler in der Nähe gefunden"); return end
  local nm = t.name or "?"
  -- Gruppen Route vom Leiter: die Schritte kommen von ihm, hier nur der Pfeil
  if not cur or opt.mirror then
    -- keine Route: nur der Pfeil
    ns.serviceTarget = { map = t.map, x = t.x, y = t.y, name = (trainer and TR"Lehrer: " or TR"Händler: ") .. nm, kind = trainer and "trainer" or "vendor" }
    ns.Print((TR"Pfeil zeigt zu %s, ca %d Yards"):format(nm, math.floor(d or 0)))
    if ns.Draw then ns.Draw() end
    return
  end
  local _, wx, wy = World(t.map, t.x, t.y)
  local act = { k = "V", quest = nm, imap = t.map, ix = t.x, iy = t.y, npc = t.id, manual = true, since = time(),
    trainer = trainer or nil, tlvl = trainer and (UnitLevel("player") or 1) or nil }
  local step = { map = t.map, x = t.x, y = t.y, wx = wx or cur.wx, wy = wy or cur.wy, acts = { act }, t = cur.t, lvl = cur.lvl, ins = kind }
  table.insert(opt.steps, idx, step)
  if ns.serviceTarget then ns.serviceTarget = nil end
  ns.Print((TR"Neuer Schritt: %s %s, ca %d Yards. Danach geht es mit der Route weiter."):format(trainer and TR"Lehrer" or TR"Händler", nm, math.floor(d or 0)))
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
end

-- Text fuer Listen (rechte Seite, Vollbild)
function ns.OptLines(n)
  local db = ns.db
  local opt = db and db.opt
  if not opt then return { TR"Noch keine Route. Menü, Neu rechnen." } end
  local out = {}
  if opt.rep then
    table.insert(out, (TR"|cffffd100Ruf: %s|r: %d Quests, ca %d Ruf in %s, |cffffd100%d pro Stunde|r"):format(
      opt.repName or "?", opt.quests or 0, opt.rep, ns.Clock(opt.sec or 0), math.floor(opt.repRate or 0)))
  elseif opt.gold then
    table.insert(out, (TR"|cffffd100Gold Quests|r: %d Quests, ca %s in %s, |cffffd100%s pro Stunde|r"):format(
      opt.quests or 0, ns.Money(opt.gold), ns.Clock(opt.sec or 0), ns.Money(opt.goldRate or 0)))
  elseif opt.title and (opt.quests or 0) == 0 then
    -- Farm Routen und Touren ohne Zeit: keine "ca 0:00 Min"
    if (opt.sec or 0) >= 30 then
      table.insert(out, (TR"|cffffd100%s|r: %d Schritte, ca %s"):format(opt.title, #opt.steps, ns.Clock(opt.sec or 0)))
    else
      table.insert(out, (TR"|cffffd100%s|r: %d Schritte"):format(opt.title or "?", #opt.steps))
    end
  else
    table.insert(out, (TR"|cffffd100%s|r bis Level %d: %d Quests, ca %s, %s XP/Std"):format(opt.title or TR"Optimiert",
      opt.target or 0, opt.quests or 0, ns.Clock(opt.sec or 0), tostring(math.floor(opt.rate or 0))))
  end
  local start = math.max(1, (opt.idx or 1))
  local last = n and math.min(#opt.steps, start + n - 1) or #opt.steps
  for i = start, last do
    local s = opt.steps[i]
    local col = (i == opt.idx) and "|cff40ff40" or "|cffffffff"
    table.insert(out, (TR"%s%d.|r %s  |cff9d9d9d%s, Lvl %.1f, %s|r"):format(col, i, ns.OptStepText(s),
      ns.ZoneName(s.map), s.lvl or 0, ns.Clock(s.t or 0)))
  end
  if last < #opt.steps then table.insert(out, (TR"... und noch %d Schritte"):format(#opt.steps - last)) end
  return out
end

-- Ganze Route fuer die Seite "Route und Plan": jeder Schritt, jede Aktion auf eigener Zeile,
-- nach Zonen gruppiert, mit Folgequests und wo sie in der Route vorkommen
function ns.FullRouteLines()
  local db = ns.db
  local opt = db and db.opt
  if not opt or not opt.steps then return { TR"Noch keine Route berechnet." } end
  local QDB = ns.QDBAccess and select(1, ns.QDBAccess())
  local function QQ(id, key)
    if not QDB then return end
    local ok, v = pcall(QDB.QueryQuestSingle, id, key)
    if ok then return v end
  end
  -- wo wird welche Quest angenommen
  local acceptAt = {}
  local nE = 0
  for i, st in ipairs(opt.steps) do
    for _, a in ipairs(st.acts) do
      if a.k == "A" and a.qid and not acceptAt[a.qid] then acceptAt[a.qid] = i end
      if a.k == "E" then nE = nE + 1 end
    end
  end
  local out = {}
  table.insert(out, (TR"|cffffd100%s|r  %d Schritte, %d Quests, ca %s"):format(opt.title or TR"Normale Route", #opt.steps, opt.quests or 0, ns.Clock(opt.sec or 0)))
  if nE > 0 then
    table.insert(out, (TR"|cff9d9d9d%d mal Entdecken: das sind neue Gebiete, die direkt am Weg liegen und XP geben. Sie kosten fast keine Zeit.|r"):format(nE))
  end
  local lastZone
  local shownMax = ns.ShownStepMax and ns.ShownStepMax(opt) or #opt.steps
  for i, st in ipairs(opt.steps) do
    if i > shownMax then
      table.insert(out, "")
      table.insert(out, (TR"|cff9d9d9dDanach noch %d Schritte bis Level %d. Den ganzen Plan siehst du unter Weg zu 60.|r"):format(#opt.steps - shownMax, opt.target or 0))
      break
    end
    if st.map ~= lastZone then
      lastZone = st.map
      table.insert(out, "")
      table.insert(out, ("|cffffd100%s|r"):format(ns.ZoneName(st.map) or "?"))
    end
    local done = i < (opt.idx or 1)
    local cur = i == (opt.idx or 1)
    local nc = done and "|cff6d6d6d" or (cur and "|cff40ff40" or "|cffffffff")
    table.insert(out, (TR"%s%d.|r  |cff9d9d9dLevel %.1f, nach %s%s|r"):format(nc, i, st.lvl or 0, ns.Clock(st.t or 0), cur and TR"  |cff40ff40jetzt|r" or ""))
    for _, a in ipairs(st.acts) do
      local line = ns.OptStepText({ acts = { a } })
      if done then line = "|cff6d6d6d" .. line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r" end
      table.insert(out, "      " .. line)
      -- Folgequest nach dem Abgeben
      if a.k == "T" and a.qid and not done then
        local nxt = QQ(a.qid, "nextQuestInChain")
        if type(nxt) == "number" and nxt > 0 then
          local nm = QQ(nxt, "name") or (TR"Quest " .. nxt)
          local at = acceptAt[nxt]
          table.insert(out, (TR"          |cff9d9d9dFolgequest:|r %s  |cff9d9d9d%s|r"):format(nm, at and (TR"kommt in Schritt " .. at) or TR"nicht in dieser Route"))
        end
      end
    end
  end
  return out
end

-- Zurueck geblaettert beenden: wieder dort, wo du warst (auch im Abschnitt danach)
function ns.OptUnpin(step)
  local db = ns.db
  local opt = db and db.opt
  if not opt then return end
  local pl = db.plan60
  -- mehrere Abschnitte zurueck: Schritt fuer Schritt erst den Abschnitt danach zeigen
  if step and opt.backSec and pl and pl.ahead and opt.plan and pl.ahead.plan and opt.plan + 1 < pl.ahead.plan then
    local k = opt.plan + 1
    local sec = pl.secs and pl.secs[k]
    if sec and #(sec.steps or {}) > 0 then
      db.opt = { steps = sec.steps, idx = 1, created = opt.created, from = sec.from, to = sec.to, target = math.floor((sec.to or 0) + 0.5),
        quests = sec.quests or 0, sec = sec.sec or 0, xp = sec.xp or 0, rate = sec.rate or 0, title = (TR"Abschnitt %d von %d"):format(k, #pl.secs), opts = sec.opts, plan = k,
        pin = true, pinTop = #sec.steps + 1, pinAt = time and time() or 0, backSec = true }
      return
    end
  end
  if opt.backSec and pl and pl.ahead then
    db.opt = pl.ahead
    pl.ahead = nil
    -- Schritt fuer Schritt vor: im Abschnitt danach warst du auch schon zurueck geblaettert
    if step and db.opt.pin then db.opt.pinAt = time and time() or 0; return end
    db.opt.idx = math.max(db.opt.idx or 1, db.opt.pinTop or 1)
  else
    opt.idx = math.max(opt.idx or 1, opt.pinTop or 1)
  end
  db.opt.pin, db.opt.pinTop, db.opt.pinAt, db.opt.backSec = nil, nil, nil, nil
end

-- 18.5 (Sascha): Ueberspringen merken. Was beim Ueberspringen nicht angenommen war, plant die Route erst 3 Level spaeter
-- wieder ein. Vorher holte der naechste Abschnitt oder Neu rechnen die Quest gleich wieder (Sim Teil S: "Mrs. Dalson's
-- Diary" zweimal hintereinander haengen geblieben). Zurueck auf den Schritt holt alles wieder, wie es war, und die Sperre
-- ist weg (aus Versehen Weiter gedrueckt, oder nur mal schauen).
local SKIP_LEVELS = 3
local skipUndo = {} -- die letzten Ueberspringen (bis zum Neuladen), neuestes zuletzt
function ns.OptSkipped(qid, L)
  local e = ns.db and ns.db.skipQ and ns.db.skipQ[qid]
  if type(e) ~= "table" then return false end
  return (L or 0) < (e.L or 0) + SKIP_LEVELS
end
local function SkipMemo(qid)
  local db = ns.db
  if not (db and qid) then return end
  local L = UnitLevel("player") or 1
  if type(db.skipQ) ~= "table" then db.skipQ = {} end
  for q, e in pairs(db.skipQ) do if type(e) ~= "table" or L >= (e.L or 0) + SKIP_LEVELS then db.skipQ[q] = nil end end
  db.skipQ[qid] = { L = L, t = time and time() or 0 }
end
local function SkipForget(qids)
  local sq = ns.db and ns.db.skipQ
  local n = 0
  if type(sq) == "table" then for _, q in ipairs(qids or {}) do if sq[q] then sq[q] = nil; n = n + 1 end end end
  return n
end
-- Zurueck direkt nach Ueberspringen, oder spaeter bis zum Schritt danach zurueck geblaettert: der Schritt kommt
-- wieder, mit seinen Zielen und der Abgabe, und ist wieder der aktuelle. true, wenn etwas zurueck kam
local function SkipUndo()
  local db = ns.db
  local opt = db and db.opt
  local rec = skipUndo[#skipUndo]
  if not (opt and opt.steps and rec) then return false end
  if rec.opt ~= opt or opt.steps[rec.idx] ~= rec.stepRef or opt.steps[opt.idx or 1] ~= rec.nextRef then return false end
  table.remove(skipUndo)
  for i = #opt.steps, rec.idx, -1 do opt.steps[i] = nil end
  for k, st in ipairs(rec.tail) do
    opt.steps[rec.idx + k - 1] = st
    st.acts = st.acts or {}
    local acts, keep = st.acts, rec.tailActs[k]
    for j = #acts, 1, -1 do acts[j] = nil end
    for j, a in ipairs(keep) do acts[j] = a end
  end
  opt.idx = rec.idx
  opt.pin, opt.pinTop, opt.pinAt, opt.backSec = nil, nil, nil, nil
  local nq = SkipForget(rec.qids)
  local st = opt.steps[opt.idx]
  ns.Print(TR"Überspringen zurückgenommen: " .. (st and ns.OptStepText(st) or ""))
  if ns.TestLog then ns.TestLog("SCHRITT", ("Ueberspringen zurueck: Schritt %d wieder da, %d Quests wieder frei"):format(rec.idx, nq)) end
  if ns.OptSync then ns.OptSync() end
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
  return true
end
ns.OptSkipUndo = SkipUndo
-- Zurueck auf einen Schritt, dessen Quest du uebersprungen hast, ohne gemerkten Stand (nach dem Neuladen):
-- Sperre weg und den Abschnitt neu rechnen, dann ist die Quest wieder in der Route
local function SkipBackShown()
  local db = ns.db
  local o = db and db.opt
  local st = o and o.steps and o.steps[o.idx or 1]
  local sq = db and db.skipQ
  if not (st and type(sq) == "table" and next(sq)) then return end
  local q = {}
  for _, a in ipairs(st.acts or {}) do if a.k == "A" and a.qid and sq[a.qid] then q[#q + 1] = a.qid end end
  if #q == 0 or SkipForget(q) == 0 then return end
  ns.Print(TR"Übersprungene Quest kommt wieder in die Route, der Abschnitt wird neu berechnet.")
  if ns.TestLog then ns.TestLog("SCHRITT", ("Ueberspringen zurueck (neu rechnen): %d Quests wieder frei"):format(#q)) end
  if ns.PlanActive and ns.PlanActive() and ns.PlanSectionLive then ns.PlanSectionLive() end
end

-- Zurueck: den Schritt davor nochmal zeigen, am Anfang eines Abschnitts den letzten vom Abschnitt davor
function ns.OptBack()
  local db = ns.db
  local opt = db and db.opt
  if not opt then return end
  -- 18.5: Zurueck auf einen uebersprungenen Schritt holt ihn wieder
  if SkipUndo() then return end
  local i = opt.idx or 1
  local now = time and time() or 0
  if i > 1 then
    opt.pinTop = math.max(opt.pinTop or 0, math.min(i, #opt.steps + 1))
    opt.idx = math.min(i, #opt.steps + 1) - 1
    opt.pin, opt.pinAt = true, now
  else
    local pl = db.plan60
    local k = opt.plan and opt.plan - 1
    local sec = k and pl and pl.secs and pl.secs[k]
    if not sec or #(sec.steps or {}) == 0 then ns.Print(TR"Das ist schon der erste Schritt."); return end
    -- der Abschnitt, in dem du warst, wird gemerkt und kommt mit Weiter zurueck
    -- pl.cur bleibt beim echten Abschnitt: Live Neurechnen und Pruefungen arbeiten nicht auf der alten Ansicht
    if not opt.backSec then pl.ahead = opt end
    db.opt = { steps = sec.steps, idx = #sec.steps, created = opt.created, from = sec.from, to = sec.to, target = math.floor((sec.to or 0) + 0.5),
      quests = sec.quests or 0, sec = sec.sec or 0, xp = sec.xp or 0, rate = sec.rate or 0, title = (TR"Abschnitt %d von %d"):format(k, #pl.secs), opts = sec.opts, plan = k,
      pin = true, pinTop = #sec.steps + 1, pinAt = now, backSec = true }
  end
  local st = db.opt.steps[db.opt.idx]
  if st then ns.Print(TR"Zurück: " .. ns.OptStepText(st)) end
  SkipBackShown()
  if ns.Draw then ns.Draw() end
end

-- Weiter: beim Zurueckblaettern einen Schritt vor, sonst den aktuellen Schritt ueberspringen
function ns.OptForward()
  local opt = ns.db and ns.db.opt
  if not opt then return end
  if not opt.pin then ns.OptSkip(); return end
  opt.idx = (opt.idx or 1) + 1
  opt.pinAt = time and time() or 0
  if opt.idx >= (opt.pinTop or 0) then
    ns.OptUnpin(true)
    local o2 = ns.db.opt
    local st = o2.steps[o2.idx]
    if o2.pin then
      if st then ns.Print(TR"Vor: " .. ns.OptStepText(st)) end
    else
      ns.Print(TR"Wieder beim aktuellen Schritt" .. (st and (": " .. ns.OptStepText(st)) or "."))
      if ns.OptSync then ns.OptSync() end
    end
  else
    local st = opt.steps[opt.idx]
    if st then ns.Print(TR"Vor: " .. ns.OptStepText(st)) end
  end
  if ns.Draw then ns.Draw() end
end

function ns.OptSkip()
  local opt = ns.db and ns.db.opt
  if not opt then return end
  local cur = opt.steps and opt.steps[opt.idx or 1]
  if cur and ns.MyWayAdd and StepDone(cur) then pcall(ns.MyWayAdd, cur, opt) end
  -- Quests, die in diesem Schritt angenommen werden sollten und nicht im Log sind: ihre Ziele, das Abgeben
  -- und Folgequests kommen auch raus (sonst haengt die Route spaeter beim Abgeben, Sim 17.2)
  local missed = {}
  for _, a in ipairs(cur and cur.acts or {}) do
    if a.k == "A" and a.qid and not (ns.logProgress and ns.logProgress[a.qid]) and not (ns.QuestStatus and ns.QuestStatus(a.qid) == "done") then
      missed[#missed + 1] = a.qid
    end
  end
  -- 18.5: fuer Zurueck merken, wie die Route ab hier war (die Schritte und ihre Teile)
  local i0 = opt.idx or 1
  local rec = { opt = opt, idx = i0, stepRef = cur, qids = missed, tail = {}, tailActs = {} }
  for i = i0, #opt.steps do
    local st = opt.steps[i]
    rec.tail[#rec.tail + 1] = st
    local c = {}
    for j, a in ipairs(st.acts or {}) do c[j] = a end
    rec.tailActs[#rec.tailActs + 1] = c
  end
  opt.idx = i0 + 1
  for _, q in ipairs(missed) do
    -- 18.5: gemerkt, damit der naechste Abschnitt oder Neu rechnen sie nicht gleich wieder holt
    SkipMemo(q)
    if ns.OptDropQuest then ns.OptDropQuest(q, TR"übersprungen") end
  end
  if cur then
    rec.nextRef = opt.steps[opt.idx]
    skipUndo[#skipUndo + 1] = rec
    if #skipUndo > 5 then table.remove(skipUndo, 1) end
  end
  local s = opt.steps[opt.idx]
  if s then
    ns.Print(TR"Schritt übersprungen. Weiter: " .. ns.OptStepText(s))
  else
    -- am Ende nie stehen bleiben: gleich den naechsten Abschnitt rechnen
    ns.Print(TR"Abschnitt fertig, der nächste wird berechnet ...")
    AfterFinished(1, opt)
  end
  if ns.Draw then ns.Draw() end
end

-- frueher: zwischen normaler und optimierter Route wechseln. Jetzt gibt es nur noch die optimierte.
function ns.ToggleOptMode()
  ns.AutoOpt(true)
  if ns.Draw then ns.Draw() end
end

function ns.OptBusy() return busy end

-- warum keine (oder wenige) Quests: auch mit /klg warum
function ns.OptWhyReport(nCands)
  local why = ns.optWhy
  if not why then ns.Print(TR"Noch keine Route gerechnet."); return end
  local lv = why[TR"passt vom Level"] or 0
  ns.Print((TR"Warum so wenig Quests: %d passen vom Level, %d kamen in die Auswahl."):format(lv, nCands or ns.optCands or 0))
  local list = {}
  for k, v in pairs(why) do if k ~= TR"passt vom Level" then table.insert(list, { k, v }) end end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  for i = 1, math.min(6, #list) do ns.Print((TR"  %d raus: %s"):format(list[i][2], list[i][1])) end
  local ws = ns.optWhySel
  if ws and next(ws) then
    ns.Print(TR"Aus der Auswahl nicht genommen:")
    for k, v in pairs(ws) do ns.Print(("  %d: %s"):format(v, k)) end
  end
  for _, l in ipairs(ns.optWhyDet or {}) do ns.Print("  |cff9d9d9d" .. l .. "|r") end
  if lv == 0 then ns.Print(TR"  Questie hat noch keine Daten geliefert. Keine Zeit Leveling Guide rechnet gleich nochmal.") end
end

ns.Ticker(0.5, function()
  if ns.db and ns.db.optMode and ns.db.opt then Sync() end
end)

-- Sicherheitsnetz: Route am Ende oder leer, aber nichts rechnet? Dann selber weiter rechnen
-- (alle 20 Sekunden, nicht im Kampf; kommt nichts raus, erst nach 2 Minuten wieder)
local lastAuto = 0
ns.Ticker(5, function()
  local db = ns.db
  if not db or not db.optMode or busy then return end
  if InCombatLockdown and InCombatLockdown() then return end
  local opt = db.opt
  if opt and (opt.idx or 1) <= #(opt.steps or {}) then return end
  if opt and opt.tour then return end
  local wait = (opt and #(opt.steps or {}) == 0) and 60 or 20
  if GetTime() - lastAuto < wait then return end
  lastAuto = GetTime()
  ns.AutoOpt(true)
end)

-- Werkzeuge fuer andere Teile (Dungeon Route)
function ns.OptTools()
  SIMLATE, SIMMAP = false, nil
  if not ns.QDBAccess then return end
  QDB, ZDB, QLib, QPlayer = ns.QDBAccess()
  if not QDB then return end
  if not XPDB then
    local okX, XPmod = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestXP")
    XPDB = okX and XPmod and XPmod.db or nil
  end
  return { World = World, Spawns = Spawns, BuildQuest = BuildQuest, Q = Q, N = N, O = O, Ui = Ui, QuestXPAt = QuestXPAt, D = D }
end

-- Gruppe uebernimmt (Gruppen Route oder Dungeon Aufteilung): laufende Farm oder Spezialroute merken,
-- nach der Gruppen Route geht sie dort weiter, wo du warst (die Zeit einer Farm Sitzung pausiert solange)
function ns.OptPark()
  local db = ns.db
  local o = db and db.opt
  if not o or db.optParked then return end
  if (o.idx or 1) > #(o.steps or {}) then return end
  if o.group or o.split or not (ns.OptSpecial and ns.OptSpecial(o)) then return end
  db.optParked = { opt = o, prof = db.profSess, at = time() }
  ns.Print(TR"Deine laufende Route ist gemerkt: " .. (o.title or TR"Route") .. TR". Nach der Gruppen Route geht sie weiter.")
end
function ns.OptUnpark()
  local db = ns.db
  local p = db and db.optParked
  if not (p and p.opt) then return false end
  db.optParked = nil
  db.opt = p.opt
  if p.prof then
    p.prof.t0 = (p.prof.t0 or 0) + math.max(0, time() - (p.at or time()))
    db.profSess = p.prof
  end
  db.optMode = true
  ns.Print(TR"Gruppen Route fertig, weiter mit deiner Route: " .. (p.opt.title or TR"Route"))
  if ns.OptSync then ns.OptSync() end
  if ns.Draw then ns.Draw() end
  return true
end

-- fertige Schrittliste (z.B. Dungeon Route) als optimierte Route uebernehmen
-- 20.3j (S Test 20.3g Punkt 6, K Code Blick C5): Zusatz Route mit weitem ersten Ziel (zb Maraudon Eingang von
-- Orgrimmar aus): gleich ein Navi dorthin (Weg, Flug, Schiff, Linie auf Karte und Minimap). Am Ziel endet das Navi, dann
-- fuehrt der Pfeil wieder die Route. Nah (unter ca 1500 Yards, gleicher Kontinent) bleibt es beim normalen Pfeil
local function FarStart(opt)
  local st = opt and opt.steps and opt.steps[opt.idx or 1]
  if not (st and st.map and ns.ZielNavi and ns.PlayerMap) then return end
  local pm = ns.PlayerMap()
  local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local d = ns.WorldDist and ns.WorldDist({ pm, px, py }, { st.map, st.x, st.y })
  if d and d < 1500 then return end
  -- 20.3o (Da Pruefung Nr 12): bei einem Fehler in OptStepText nicht die Fehler Meldung als Namen nehmen
  local okN, name = false, nil
  if ns.OptStepText then okN, name = pcall(ns.OptStepText, st) end
  if not okN or type(name) ~= "string" then name = opt.title or TR"Route" end
  name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\n.*", "")
  local ok, on = pcall(ns.ZielNavi, st.map, st.x, st.y, name, "route")
  -- ohne Navi setzt ZielNavi ein festes Pfeil Ziel: das hier nicht, sonst haengt der Pfeil spaeter wieder daran
  if not (ok and on) and ns.serviceTarget and ns.serviceTarget.kind == "route" then ns.serviceTarget = nil end
  if ns.TestLog then ns.TestLog("PFEIL", ("Zusatz Route weit weg (%s yd): Navi %s"):format(d and tostring(math.floor(d)) or "anderer Kontinent", (ok and on) and "an" or "nicht moeglich")) end
end
ns.OptFarStart = FarStart

function ns.OptLoad(steps, info)
  local db = ns.db
  -- die Leveling Route merken (Routen Profil), damit sie danach weitergeht
  if ns.ProfileBeforeExtra then ns.ProfileBeforeExtra(info.title) end
  -- 20.3l (S Punkt 25): diese Route lief schon einmal (gleicher Name) und du bist nicht weit weg: mit Fortschritt weiter
  local saved = ns.ProfileStashGet and ns.ProfileStashGet(info.title, steps)
  if saved then
    steps = saved.opt.steps
    if ns.TestLog then ns.TestLog("PROFIL", ("weiter, gemerkt bei Schritt %d von %d: %s"):format(saved.opt.idx or 1, #steps, tostring(info.title))) end
  end
  -- 20.2 (P4/P5): geladene Routen (Farmen, Touren, Dungeon) sind nie die Gold Quests Route
  db.goldMode = false
  db.opt = { steps = steps, idx = 1, created = time and time() or 0, target = info.target or UnitLevel("player"),
    quests = info.quests or 0, sec = info.sec or 0, from = UnitLevel("player"), to = info.to or UnitLevel("player"),
    rate = info.rate or 0, title = info.title, tour = info.tour, loaded = info.loaded, extra = true }
  -- 20.3l (Log 20.3j J5, Angeln und Runenstoff 0 Schritte): die Art der Route (Berufe, Gold, Ruf, Dungeon, Kreis) gleich
  -- mit setzen. Vorher setzte der Aufrufer sie erst nach OptLoad, das Navi fuer ein weites erstes Ziel (FarStart) pruefte
  -- aber schon vorher den Schritt: ohne opt.prof warf die Berufe Pruefung die Sitzung weg, alle Schritte galten als fertig
  for _, k in ipairs({ "prof", "farm", "repFarm", "dungeonRoute", "loop" }) do
    if info[k] ~= nil then db.opt[k] = info[k] end
  end
  -- Schluessel kommt von der neu gerechneten Liste (gleicher Ziel Punkt und gleiche Laenge = dieselbe Route)
  if saved then
    db.opt.idx = saved.opt.idx or 1
    db.opt.created = saved.opt.created or db.opt.created
    for _, k in ipairs({ "gearQ", "opts", "dest", "sec", "quests" }) do if saved.opt[k] ~= nil and db.opt[k] == nil then db.opt[k] = saved.opt[k] end end
    if saved.sess and db.opt.prof and db.profSess then
      -- Berufe: Zaehler ab dem alten Start, die Zeit ohne die Pause dazwischen
      local away = math.max(0, (time and time() or 0) - (saved.at or 0))
      saved.sess.t0 = (saved.sess.t0 or 0) + away
      db.profSess = saved.sess
    end
  end
  db.profileCur = "extra"
  db.optMode = true
  -- 20.3j (S Test 20.3g, S 20:38 "Zusatz Routen ohne Weg"): ein laufendes Navi (zb "Navi nach Das Brachland" oder
  -- Gruppe helfen) setzt das Pfeil Ziel immer wieder auf sein altes Ziel, und die Karte zeichnet nur die Navi Strecke.
  -- Bei einer neuen Zusatz Route das alte Navi beenden, dann folgen Pfeil, Karte und Minimap der neuen Route
  if ns.navi and ns.NaviStop then
    if ns.TestLog then ns.TestLog("PFEIL", ("altes Navi beendet bei neuer Route: %s"):format(tostring(ns.navi.dest and ns.navi.dest.name))) end
    pcall(ns.NaviStop, nil)
  end
  ns.Print(TR"Pfeil folgt jetzt: " .. (info.title or TR"Route"))
  -- erst im naechsten Bild: dann hat der Aufrufer alles gesetzt (Sitzung, Kreis), bevor Navi und Pfeil den Schritt pruefen
  local o0 = db.opt
  C_Timer.After(0, function() if ns.db and ns.db.opt == o0 then pcall(FarStart, o0) end end)
  if ns.Draw then ns.Draw() end
end

------------------------------------------------------------
-- Nach einem Tod: weit weg von der Route (z.B. beim Geistheiler)? Dann ab hier neu rechnen
------------------------------------------------------------
local df = CreateFrame("Frame")
df:RegisterEvent("PLAYER_DEAD")
df:RegisterEvent("PLAYER_UNGHOST")
df:RegisterEvent("PLAYER_ALIVE")
-- 20.3 (Na 15:15, Log 14:09 Ruhestein): PLAYER_ALIVE kommt auch nach Ladebildschirm und Ruhestein. Hinweis nur nach
-- einem echten Tod (PLAYER_DEAD vorher), danach Merker loeschen
local wasDead = false
df:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_DEAD" then wasDead = true; return end
  if not wasDead then return end
  if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then return end -- nur Geist geworden, noch nicht lebendig
  wasDead = false
  C_Timer.After(3, function()
    local db = ns.db
    local opt = db and db.optMode and db.opt
    if not opt or busy then return end
    if opt.pin then ns.OptUnpin(); opt = db.opt end -- nach dem Tod zaehlt der echte Schritt
    local s = opt.steps[opt.idx or 1]
    if not s then return end
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    local d = ns.WorldDist and ns.WorldDist({ map, px, py }, { s.map, s.x, s.y })
    if d and d < 1200 then return end
    -- nicht mehr von selbst neu rechnen: der Pfeil fuehrt zurueck zur Route, dazu der Hinweis "Neu rechnen?"
    if ns.RecalcAsk then ns.RecalcAsk("tod", TR"Nach dem Tod weit weg von der Route.") end
  end)
end)

-- Ungeplant auf einem anderen Kontinent (Quest Teleport, falsches Schiff, Skyborne verlaesst Zephras):
-- kein Schritt im Abschnitt liegt dort, wo du bist. Nur ein Besuch (Auktionshaus, Freund) aendert nichts.
-- Nimmst du dort aber eine Quest an oder gibst eine ab, spielst du da weiter: Hinweis "Neu rechnen?"
-- (hoechstens alle 10 Minuten). Geplante Reisen haben immer Schritte am neuen Ort und zaehlen nicht.
local contSeen, contOff, contAt = nil, nil, -999
local function ContOffPlan(c)
  local db = ns.db
  local opt = db and db.optMode and db.opt
  if not (opt and opt.steps) or opt.pin or opt.backSec or opt.mirror then return false end
  if ns.groupFollow and opt.group then return false end
  local idx = opt.idx or 1
  if idx > #opt.steps then return false end
  for k = idx, #opt.steps do
    local s = opt.steps[k]
    if s and s.map and World(s.map, s.x or 0.5, s.y or 0.5) == c then return false end
    for _, a in ipairs(s and s.acts or {}) do
      if a.k == "R" and a.toCont == c then return false end
    end
  end
  return true, opt
end
-- Quest abgebrochen (aus dem Log, nicht abgegeben): ihre Schritte und Folgequests, die sie brauchen, kommen aus
-- der laufenden Route. Vorher zeigte der Pfeil weiter zum Ziel und Abgeben, der Schritt wurde nie fertig (Sim 17.2).
-- Gruppen Route vom Leiter: bleibt (der Leiter rechnet). Die Quest kann spaeter wieder eingeplant werden.
function ns.OptDropQuest(qid, why)
  local db = ns.db
  local o = db and db.opt
  if not (o and o.steps and qid) or o.mirror then return 0 end
  local drop = { [qid] = true }
  local function NeedsDropped(id)
    for _, key in ipairs({ "preQuestSingle", "preQuestGroup" }) do
      local v = Q(id, key)
      if type(v) == "table" then for _, x in ipairs(v) do if drop[x] then return true end end end
    end
    return false
  end
  -- zuerst bestimmen, was alles weg muss (Ketten: Folgequest der Folgequest)
  local i0 = o.idx or 1
  for i = i0, #o.steps do
    for _, a in ipairs(o.steps[i].acts or {}) do
      if a.k == "A" and a.qid and not drop[a.qid] and NeedsDropped(a.qid) then drop[a.qid] = true end
    end
  end
  local n = 0
  for i = #o.steps, i0, -1 do
    local st = o.steps[i]
    local acts = st.acts or {}
    for j = #acts, 1, -1 do
      local a = acts[j]
      if a.qid and drop[a.qid] and (a.k == "A" or a.k == "O" or a.k == "T") then table.remove(acts, j); n = n + 1 end
    end
    if #acts == 0 then table.remove(o.steps, i) end
  end
  if n > 0 then
    local nq = 0
    for _ in pairs(drop) do nq = nq + 1 end
    ns.Print((TR"Quest %s: %d Schritte aus der Route genommen%s."):format(why or TR"abgebrochen", n, nq > 1 and (TR", mit %d Folgequests"):format(nq - 1) or ""))
    if ns.TestLog then ns.TestLog("QUEST", ("raus (%s) %d: %d Teile aus der Route, %d Quests"):format(tostring(why or "abgebrochen"), qid, n, nq)) end
    if ns.TestLogWhy then ns.TestLogWhy("Quest raus: " .. tostring(why or "abgebrochen")) end
    if ns.OptSync then ns.OptSync() end
    if ns.Draw then ns.Draw() end
    if ns.RefreshHud then ns.RefreshHud() end
  end
  return n
end
do
  local turned = {}
  local af = CreateFrame("Frame")
  af:RegisterEvent("QUEST_TURNED_IN")
  af:RegisterEvent("QUEST_REMOVED")
  af:SetScript("OnEvent", function(_, ev, qid)
    if type(qid) ~= "number" then return end
    if ev == "QUEST_TURNED_IN" then turned[qid] = GetTime() return end
    C_Timer.After(1.5, function()
      if turned[qid] and GetTime() - turned[qid] < 10 then return end
      local cq = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
      if cq and cq(qid) then return end
      if ns.LogQuestIDs then for _, id in ipairs(ns.LogQuestIDs()) do if id == qid then return end end end
      ns.OptDropQuest(qid)
    end)
  end)
end

-- v11d (K P31): Test Log Zeile INSTANZ bei Pause an und aus. Eigener Zustand, ausgeloest bei Ladebild UND Zonenwechsel
-- (Sim und manche Eingaenge ohne Ladebild), damit die Sim "kein RECHNEN drin" sicher belegen kann
do
  local lf = CreateFrame("Frame")
  lf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  -- 1.1 (P55): nach dem Ladebild erst entscheiden, wenn die Welt bereit ist (ns.WorldReadyHooks aus Route.lua)
  local function Check()
    local inI = (ns.InInstance and ns.InInstance()) and true or false
    if inI == (V11.instLogged or false) then return end
    V11.instLogged = inI
    if not ns.TestLog then return end
    if inI then
      local _, typ = IsInInstance()
      ns.TestLog("INSTANZ", ("Pause an (%s, %s): kein Rechnen, kein Pfeil, kein Navi"):format(tostring(typ), tostring(GetRealZoneText and GetRealZoneText() or "?")))
    else
      ns.TestLog("INSTANZ", "Pause aus: draussen, Route geht weiter")
    end
  end
  lf:SetScript("OnEvent", function() if ns.worldReady then Check() end end)
  if ns.WorldReadyHooks then table.insert(ns.WorldReadyHooks, Check) end
end
-- 17.9: aus dem Dungeon raus: was drin nicht gerechnet wurde (Level, Quests), jetzt einmal nachholen
local icf = CreateFrame("Frame")
-- 1.1 (P55): nicht beim Ladebild selbst, sondern wenn die Welt bereit ist (ns.WorldReadyHooks)
local function AfterWorld()
  -- (Log Zeile INSTANZ steht seit v11d im eigenen Frame unten, auch bei Zonenwechsel ohne Ladebild)
  if ns.InInstance and ns.InInstance() then
    ns.instWasIn = true; return
  end
  ns.instSaid = nil
  local wasIn = ns.instWasIn
  ns.instWasIn = nil
  -- 18.0: im Dungeon pausiert und wieder draussen: einmal daran erinnern, sonst steht die Route und man wundert sich
  if wasIn and ns.db and ns.db.paused then
    C_Timer.After(4, function()
      if ns.db and ns.db.paused and not (ns.InInstance and ns.InInstance()) then
        ns.Print(TR"Wieder draussen, die Pause ist noch an. Weiter: Menü im Mini Fenster, Weitermachen, oder /klg pause.")
      end
    end)
  end
  if not ns.instPending and not wasIn then return end
  C_Timer.After(6, function()
    if ns.InInstance and ns.InInstance() then return end
    local db = ns.db
    if not db or db.paused or busy or ns.planBuilding then return end
    if not ns.instPending then
      -- 18.0: auch ohne Level Up im Dungeon pruefen, ob du jetzt ein ganzes Level neben der Route bist
      -- (Sim Teil D: 0.4 Level im Dungeon, danach 1.3 Level neben dem Plan, Route rechnete erst beim naechsten Schritt)
      if wasIn and ns.PlanLevelCheck then ns.PlanLevelCheck("dungeon") end
      return
    end
    ns.instPending = nil
    if ns.TestLog then ns.TestLog("DUNGEON", "draussen: Route rechnet nach (Level und Quests aus dem Dungeon)") end
    if ns.ProfileOf and ns.ProfileOf(db.opt) ~= "level" then return end
    if ns.PlanActive and ns.PlanActive() then ns.PlanSectionLive() else ns.AutoOpt("auto") end
  end)
end
if ns.WorldReadyHooks then table.insert(ns.WorldReadyHooks, AfterWorld) end
local ccf = CreateFrame("Frame")
ccf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ccf:RegisterEvent("PLAYER_ENTERING_WORLD")
ccf:RegisterEvent("QUEST_ACCEPTED")
ccf:RegisterEvent("QUEST_TURNED_IN")
ccf:SetScript("OnEvent", function(_, ev)
  -- 1.1 (P42): neue oder abgegebene Quest: auf Max Level darf wieder ein Stueck gerechnet werden (Vorquests evtl erledigt)
  if ev == "QUEST_ACCEPTED" or ev == "QUEST_TURNED_IN" then
    if V11.restEmpty then V11.restEmpty = nil; ns.restRetry = nil; ns.restTried = nil end
  end
  C_Timer.After((ev == "QUEST_ACCEPTED" or ev == "QUEST_TURNED_IN") and 2 or 4, function()
    local db = ns.db
    if not db or db.paused or busy or ns.planBuilding then return end
    if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return end
    if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then return end
    local c = PlayerCont()
    if not c then
      -- Instanz oder keine Position: alten Stand behalten, im Dungeon draussen einmal nachrechnen (17.9)
      if (ev == "QUEST_ACCEPTED" or ev == "QUEST_TURNED_IN") and ns.InInstance and ns.InInstance() then ns.instPending = true end
      return
    end
    if ev == "ZONE_CHANGED_NEW_AREA" or ev == "PLAYER_ENTERING_WORLD" then
      local prev = contSeen
      contSeen = c
      if contOff and contOff ~= c then contOff = nil end -- wieder zurueck (oder weiter)
      if not prev or prev == c then return end
      if ContOffPlan(c) then
        contOff = c
        ns.Print(TR"Die Route liegt auf einem anderen Kontinent. Der Pfeil führt dich zurück. Spielst du hier weiter, kommt der Hinweis Neu rechnen.")
        if ns.TestLog then ns.TestLog("RECHNEN", "anderer Kontinent als geplant (" .. tostring(c) .. ")") end
      end
      return
    end
    -- Quest angenommen oder abgegeben
    if not contOff or contOff ~= c then return end
    local off, opt = ContOffPlan(c)
    if not off then contOff = nil; return end
    local now = GetTime and GetTime() or 0
    if now - contAt < 600 then return end
    contAt, contOff = now, nil
    -- nicht von selbst neu rechnen (neue Regel): Hinweis "Neu rechnen?" zum Wegklicken
    if ns.RecalcAsk then ns.RecalcAsk("kontinent", TR"Du spielst auf einem anderen Kontinent als die Route.") end
  end)
end)

------------------------------------------------------------
-- Die optimierte Route ist jetzt die Route: immer an, rechnet von selbst weiter
------------------------------------------------------------
-- Spielweise fuer ein Level (Regler, Bereiche im Experte Modus)
local function ModeFor(L, si)
  local db = ns.db
  si = si or (ns.LevelStep and ns.LevelStep(L)) or 2
  -- 20.3k (S Test 20.3g Punkt 5): bist du wirklich auf Max Level (echtes Level, nicht der Plan), plant die Route alle
  -- restlichen Quests wie Tempo Alles. Vorher zeigte Normal auf 60 nur Haendler und Buch
  local maxRL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  local atMax = _G.UnitLevel and (_G.UnitLevel("player") or 0) >= maxRL
  if atMax then si = 1 end
  local st = ns.LEVEL_STEPS and ns.LEVEL_STEPS[si] or {}
  -- fillGap: reichen die Quests nicht, Grind Pausen oder ein Hinweis "dir fehlen X Level"
  -- scope: welche Zonen, qlDown: wie weit unter deinem Level Quests noch zaehlen,
  -- eliteLater: Elite Quests, sobald sie allein machbar sind
  -- Schalter Grinden (17.2): an = Grinden ist eine Option. Normal: Grind Schritte, wo Grinden bei dir schneller ist als
  -- die Quest (Massstab ist dein echtes Grinden, schnelle Kills: oefter), Alles: nur im Notfall.
  -- aus = keine Grind Schritte, auch kein Hinweis "Level fehlt" (die Route nimmt dann mehr Quests aus allen Zonen)
  local m = { step = si, thrF = st.thr, capF = st.cap, fillGap = true, all = st.all, scope = st.scope, qlDown = st.qlDown,
    noGrind = st.noGrind, eliteLater = st.eliteLater, emergency = true }
  -- 19.10: Alles, Variante "möglichst viel mitnehmen, Rest auf Max Level" (graue Quests abseits kommen auf Max Level)
  if st.all and ns.AllRest and ns.AllRest() then m.allCluster = true end
  -- 20.3l (Log 20.3k K3, L60 "rechnet alle Quests" und dann keine Route): auf echtem Max Level ist das der letzte
  -- Abschnitt (Nachquesten) wie im Fahrplan: alle restlichen Quests, auch graue abseits (sonst filterte allCluster
  -- auf Level 60 fast alles weg), kein Grinden mehr
  if atMax then m.rest = true; m.fillGap = false end
  if db and db.grind == false then
    m.noGrind = true
    m.fillGap = false
  elseif not st.all then
    m.grindProf = true
    m.emergency = nil
  end
  -- 20.4b2: einmal alle Quests (Grinden ohne Quests zu lang, siehe GrindNoQuestRetry)
  if ns.allQuestsOnce and not atMax then m.all, m.emergency, m.gapFill = true, true, true end
  return m
end
ns.OptModeFor = ModeFor
-- 20.4b2 (K 22:36 Duo Endspiel): Grind Block ohne Quests zu lang. Den Abschnitt ab deinem Level einmal mit allen Quests
-- rechnen (Flag gilt nur fuer diese eine Rechnung). Hoechstens alle GRIND_NOQ_RETRY_S Sekunden
local GRIND_NOQ_RETRY_S = 900
local noqAt = -999
function ns.GrindNoQuestRetry()
  local now = GetTime and GetTime() or 0
  if now - noqAt < GRIND_NOQ_RETRY_S or busy or ns.planBuilding then return end
  noqAt = now
  ns.allQuestsOnce = true
  if ns.TestLog then ns.TestLog("RECHNEN", "Neu rechnen automatisch: Grinden ohne Quests zu lang, Abschnitt mit allen Quests") end
  local ok = pcall(function()
    if ns.PlanActive and ns.PlanActive() and ns.PlanSectionLive then ns.PlanSectionLive()
    elseif ns.AutoOpt then ns.AutoOpt("auto") end
  end)
  C_Timer.After(5, function() if not (ns.OptBusy and ns.OptBusy()) then ns.allQuestsOnce = nil else C_Timer.After(30, function() ns.allQuestsOnce = nil end) end end)
  if not ok then ns.allQuestsOnce = nil end
end
-- 19.10: hoechstes graues Quest Level bei Level L (wie die Farbe im Spiel: 1 bis 5 nie, 6 bis 39 L minus L/10 minus 5,
-- ab 40 L minus L/5 minus 1), nil = keine grau
function ns.OptGrayQL(L)
  L = math.floor(L or 1)
  if L <= 5 then return nil end
  if L < 40 then return L - math.floor(L / 10) - 5 end
  return L - math.floor(L / 5) - 1
end

-- Spezialroute (Berufe, Gold, Ruf, Ausruestung, Questlog, Tour, Zeit Budget), die nicht von selbst ersetzt wird
-- 19.33 (Saschas Wunsch 08:47, Knopf am Pfeil, baut der Navi Chat): verlangt der laufende Schritt den Ruhestein?
-- Rueckgabe: act, "hearth" (Ruhestein, Gegenstand 6948) oder "recall" (Astraler Rueckruf, Zauber 556), Zielname. Sonst nil.
-- Faellt der Schritt weg (Abklingzeit, woanders gebunden), ist er nicht mehr der laufende Schritt (siehe oben bei a.k == "H")
function ns.HearthStepNow()
  local o = ns.db and ns.db.opt
  local st = o and o.steps and o.steps[o.idx or 1]
  for _, a in ipairs(st and st.acts or {}) do
    if a.k == "H" then return a, a.recall and "recall" or "hearth", a.quest end
  end
end

function ns.OptSpecial(o)
  o = o or (ns.db and ns.db.opt)
  return o and (o.prof or o.tour or o.split or o.mirror or o.farm or o.repFarm or o.dungeonRoute or o.loaded or o.extra or (o.opts and (o.opts.gold or o.opts.rep or o.opts.logOnly or o.opts.gearQ or o.opts.endInn))) and true or false
end

-- force: true = Spieler will neu (Knopf, Einstellung), "auto" = automatischer Anlass (Taschen voll, Level Up,
-- Gruppe), der eine laufende Spezialroute nicht ersetzt, "section" = nur den Abschnitt live neu
-- Rechnen erst auf Knopfdruck: in der ersten Einrichtung (bis "Berechnen") und wenn du "Später" gewaehlt hast
function ns.CalcHold()
  local db = ns.db
  if not db then return false end
  return db.calcWait == true or (not db.setupDone and db.calcWait == nil)
end
-- Knopf "Berechnen": ab jetzt rechnet die Route (auch von selbst weiter)
function ns.CalcGo(reason)
  local db = ns.db
  if not db then return end
  db.calcWait = false
  db.planOn = true
  if ns.planBuilding or busy then ns.Print(TR"Die Route rechnet schon."); return end
  if ns.PlanArchive then ns.PlanArchive() end
  db.plan60 = nil
  ns.PlanBuild(reason or TR"von Hand")
end

-- 20.2: Einstellung geaendert: 3 s warten, ob noch mehr kommt, dann einmal neu rechnen (nicht bei jedem Klick).
-- In der Einrichtung gar nicht, dort rechnet erst Fertig oder der Knopf
function ns.AutoOptSoon()
  ns.autoSoonTok = (ns.autoSoonTok or 0) + 1
  local tok = ns.autoSoonTok
  C_Timer.After(3, function()
    if tok == ns.autoSoonTok and not ns.setupOpen and ns.AutoOpt then ns.AutoOpt(true) end
  end)
end

function ns.AutoOpt(force)
  local db = ns.db
  if not db or busy or db.paused then return end
  -- 20.3k (S Test 20.3g Punkt 22, Log J4): laeuft eine Zusatz Route (Dungeon, Ruf, Ausruestung, Farmen, Tour), rechnet
  -- die Leveling Route nur auf Klick "Neu rechnen" (force "hand") neu. Automatische Anlaesse (Einstellung, Level, leer,
  -- Questie spaet) lassen die Zusatz Route laufen, bis sie fertig ist oder du sie beendest
  local hand = force == "hand"
  if hand then force = true end
  if force == true and not hand and db.opt and ns.OptSpecial(db.opt) and not (db.opt.mirror or db.opt.group or db.opt.split)
    and (db.opt.idx or 1) <= #(db.opt.steps or {}) then
    if ns.TestLog then ns.TestLog("PROFIL", ("Zusatz Route laeuft (%s): automatisches Neu rechnen der Leveling Route uebersprungen"):format(tostring(db.opt.title))) end
    return
  end
  if ns.CalcHold() then return end
  -- 17.9: im Dungeon nicht rechnen (keine Position), sondern merken und beim Rauskommen nachholen.
  -- Von Hand gedrueckt: einmal sagen, warum nichts passiert
  if ns.InInstance and ns.InInstance() then
    ns.instPending = true
    if force == true and not ns.instSaid then ns.instSaid = true; ns.Print(TR"Im Dungeon rechnet die Route nicht, dort gibt es keine Position. Draussen geht es von selbst weiter.") end
    return
  end
  local auto = force == "auto"
  local fromExtra = false
  -- Neu rechnen von Hand, waehrend eine Tour oder Farm Route laeuft: die Tour rechnet sich neu (Touren),
  -- sonst bleibt das Profil gemerkt und die Leveling Route wird neu gerechnet
  if force == true and ns.ProfileOf(db.opt) == "extra" and (db.opt.idx or 1) <= #(db.opt.steps or {}) then
    local o = db.opt
    if o.tour and ns[o.tour] then ns[o.tour](); return end
    -- 1.1 (S Log L14.5: "Neu rechnen sollte nur die aktuelle Route berechnen"): Dungeon oder Zugang Route ab hier neu
    if o.dungeonRoute and ns.RedoCurrentRoute and ns.RedoCurrentRoute("hand") then return end
    -- 20.3y (S Test 17:05): "Neu rechnen" von Hand rechnet die offene Zusatz Route neu, nicht die Leveling Route
    if hand then
      if o.prof and ns.ProfPlan and ns.ProfStart and type(db.profLastOpt) == "table" and next(db.profLastOpt) then
        local po = {}
        for k, v in pairs(db.profLastOpt) do po[k] = v end
        ns.Print(TR"Farm Route wird neu gerechnet ...")
        ns.ProfPlan(po, function(r)
          if r and r.steps and #r.steps > 0 then ns.ProfStart(r) else ns.Print(TR"Keine Farmroute gefunden, die bisherige bleibt.") end
        end)
        return
      end
      local so = o.opts
      if so and (so.gearQ or so.rep or so.gold or so.logOnly or so.endInn) then
        local L = UnitLevel("player") or 1
        ns.Optimize(o.target or math.min((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60, L + 3), function(res)
          if res and ns.db then ns.db.optMode = true end
          if ns.RefreshBig then pcall(ns.RefreshBig) end
        end, so)
        return
      end
      ns.Print(TR"Diese Route geht beim aktuellen Schritt weiter, sie hat nichts neu zu rechnen. Für die Leveling Route erst oben Leveling Route wählen.")
      return
    end
    ns.ProfileSave()
    db.opt = nil
    db.profileCur = "level"
    fromExtra = true
  end
  -- von Hand neu gerechnet: eine gemerkte Leveling Route ist damit ueberholt
  if force == true and db.profiles then db.profiles.level = nil end
  -- keine Route geladen, aber ein Abschnitt vom Plan laeuft noch (nach einem Wechsel): den wieder laden
  if not db.opt and ns.PlanActive and ns.PlanActive() and db.plan60.curIdx and not ns.planBuilding and force ~= true then
    if ns.PlanReload() then return end
  end
  -- Gruppen Route vom Leiter: er rechnet fuer alle (solange er sich meldet)
  if db.opt and db.opt.mirror and ns.MirrorStale and not ns.MirrorStale() then
    if force == true then ns.Print((TR"Du folgst der Gruppen Route von %s, er rechnet für alle."):format(db.opt.mirror)) end
    return
  end
  -- Fahrplan aus einer aelteren Version (andere Rechnung): einmal neu rechnen, bis dahin laeuft der Abschnitt weiter
  -- oder Spielsprache gewechselt: Quest, Mob und NPC Namen im Plan sind noch in der alten Sprache
  if db.plan60 and (db.plan60.ver ~= ns.PLAN_VER or (db.plan60.loc and db.plan60.loc ~= ns.LOCALE)) and not ns.planBuilding then
    if ns.PlanArchive then ns.PlanArchive() end
    db.plan60 = nil
  end
  -- noch kein Fahrplan (neuer Charakter, nach dem Update): einmal im Hintergrund rechnen, bis dahin normal weiter
  do
    local o = db.opt
    local special = ns.OptSpecial(o)
    local Lnow = UnitLevel("player")
    if db.planOn ~= false and not db.plan60 and not ns.planBuilding and not special and Lnow < ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60)
      and not (ns.groupFollow and o and o.group) and (ns.planTriedAt or -999) + 120 < (GetTime and GetTime() or 0) then
      ns.planTriedAt = GetTime and GetTime() or 0
      ns.PlanBuild(TR"erste Route")
      if o and o.steps and #o.steps > 0 and (o.idx or 1) <= #o.steps then return end
    end
  end
  -- Fahrplan aktiv: fertiger Abschnitt = naechster Abschnitt aus dem Plan, erzwungen = Plan neu (Einstellungen geaendert)
  if ns.PlanActive and ns.PlanActive() then
    local o = db.opt
    local special = ns.OptSpecial(o)
    local fin = not o or (o.idx or 1) > #(o.steps or {})
    if not special or fin then
      if ns.planBuilding then return end
      if force == "section" then ns.PlanSectionLive(); return end
      -- automatischer Anlass: nur den Abschnitt live neu (zB Haendler frueher), nie den ganzen Plan
      if auto then if fin then ns.PlanNext() else ns.PlanSectionLive() end return end
      -- 20.1 (P7): von Hand neu, waehrend eine Zusatz Route lief: der Plan wird neu gerechnet (vorher ging es hier
      -- einen Abschnitt weiter, die Leveling Route war dann nicht mehr da, wo du warst)
      -- 1.1 (S Log L14.5): von Hand nur den laufenden Abschnitt ab hier neu, der Plan bis 60 bleibt (so steht es auch in
      -- der Hilfe). Den ganzen Plan neu gibt es weiter ueber Einstellungen (Plan neu) und nach einer Zusatz Route
      if hand and not fin and not fromExtra and ns.PlanSectionLive then ns.PlanSectionLive(); return end
      if force and (not fin or fromExtra) then ns.PlanBuild(TR"Neu berechnet"); return end
      -- ohne Anlass (zB Questie meldet sich nach dem Einloggen): der laufende Abschnitt bleibt.
      -- Vorher ging es hier jedes Mal einen Abschnitt weiter (Tester: nach 5 mal Einloggen Abschnitt 6, Zeppelin auf Level 4)
      if not fin then return end
      ns.PlanNext()
      return
    end
  end
  if not (ns.QDBAccess and ns.QDBAccess()) then
    -- nur eine Warteschleife, egal wie oft gefragt wird
    if not ns.autoOptRetry then
      ns.autoOptRetry = true
      C_Timer.After(10, function() ns.autoOptRetry = false; ns.AutoOpt(force) end)
    end
    return
  end
  db.optMode = true
  local opt = db.opt
  local L = UnitLevel("player")
  local finished = opt and (opt.idx or 1) > #(opt.steps or {})
  local stale = opt and opt.opts and ((opt.target or 0) <= L or (not opt.opts.all and L >= math.floor(opt.from or L) + 3))
  -- Gold, Ruf, Ausruestung oder Questlog Route vom Spieler: nicht automatisch ueberschreiben, solange sie laeuft
  if (not force or auto) and opt and ns.OptSpecial(opt) and not finished then return end
  -- auf Max Level gibt es keinen naechsten Level Abschnitt: nur neu rechnen, wenn die Route fertig ist
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if L >= maxL and opt and not finished then stale = false end
  -- Gruppen Route vom Leiter: nicht selbst neu rechnen, solange sie laeuft
  if (not force or auto) and ns.groupFollow and opt and opt.group and not finished then return end
  if force or not opt or finished or stale then
    -- 1.1 (P42): Max Level, nicht von Hand: nur wenn die Route abgearbeitet ist, hoechstens alle REST_MIN_GAP_S
    if L >= maxL and not hand then
      if opt and not finished then return end
      if V11.restEmpty then return end
      local nowR = GetTime and GetTime() or 0
      local wait = (V11.restLastAt or -999) + V11.REST_MIN_GAP_S - nowR
      if wait > 0 and not V11.restRetryNow then
        if not V11.restWaitOn then
          V11.restWaitOn = true
          C_Timer.After(wait + 0.1, function() V11.restWaitOn = nil; if ns.AutoOpt then ns.AutoOpt(true) end end)
        end
        return
      end
      V11.restRetryNow = nil
      V11.restLastAt = nowR
    end
    local t = ns.SectionTarget and ns.SectionTarget() or (L + 5)
    -- Spielweise aus der Einrichtung (oder aus dem Menue oben im Fenster)
    -- Spielweise aus dem Regler (Einrichtung, Menue oben im Fenster, Einstellungen)
    local mode = ModeFor(L)
    if auto and ns.ActiveObjective then mode.keepQ, mode.keepObj = ns.ActiveObjective() end
    ns.Optimize(t, function()
      if ns.RefreshBig then ns.RefreshBig() end
      -- 20.4a (K 19:09): Nach 60 in Stuecken, der Rest wird im Hintergrund hinten angehaengt
      -- v11e (Pr P26): erstes Stueck ohne Schritte, aber noch Quests offen: diese Quests merken und gleich das naechste
      local o2 = ns.db and ns.db.opt
      if mode.rest and #(o2 and o2.steps or {}) == 0 and (ns.optRestMore or 0) > 0 and ns.optRestChunk
        and (ns.restRetry or 0) < V11.REST_RETRY_MAX then
        ns.restRetry = (ns.restRetry or 0) + 1
        ns.restTried = ns.restTried or {}
        for qid in pairs(ns.optRestChunk) do ns.restTried[qid] = true end
        ns.optRestChunk = nil
        if ns.TestLog then ns.TestLog("RECHNEN", ("Nach 60 Stueck ohne Schritte, naechstes Stueck (Versuch %d)"):format(ns.restRetry)) end
        V11.restRetryNow = true
        C_Timer.After(1, function() if ns.AutoOpt then ns.AutoOpt(true) end end)
        return
      end
      -- 1.1 (P42): Stueck ohne Schritte und nichts mehr offen, oder alle Versuche aufgebraucht: Ruhe bis zur naechsten Quest
      -- (vorher wurde ns.restRetry hier zurueck gesetzt und das Ganze fing von vorne an)
      if mode.rest and #(o2 and o2.steps or {}) == 0 then
        V11.restEmpty = true
        if ns.TestLog then ns.TestLog("RECHNEN", ("Nach 60: keine machbare Quest mehr (Versuche %d), wartet auf neue Quest"):format(ns.restRetry or 0)) end
        return
      end
      ns.restRetry = nil
      if mode.rest and (ns.optRestMore or 0) > 0 and ns.RestChunkNext then ns.restChunkN = 0; C_Timer.After(2, ns.RestChunkNext) end
    end, mode)
  end
end


local lf = CreateFrame("Frame")
lf:RegisterEvent("PLAYER_LEVEL_UP")
lf:SetScript("OnEvent", function(_, _, lvl)
  -- Max Level erreicht: die Leveling Route ist fertig, einmal fragen (Tempo Alles mit den restlichen Quests)
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if (lvl or 0) >= maxL then C_Timer.After(8, function() if ns.AskAllAtMax then ns.AskAllAtMax(ns.db and ns.db.opt) end end) end
  if ns.PlanActive and ns.PlanActive() then
    -- bei jedem Level pruefen, ob du ein ganzes Level voraus oder hinten bist (dann neu rechnen)
    C_Timer.After(6, function() if ns.PlanLevelCheck then ns.PlanLevelCheck("level up") end end)
    return
  end
  local opt = ns.db and ns.db.opt
  if opt and opt.opts and (not opt.opts.all or (ns.db and ns.db.goal == "all")) and not opt.opts.logOnly and not opt.opts.rep and not opt.opts.gearQ
    and ((opt.target or 0) <= (lvl or 0) or (lvl or 0) >= math.floor(opt.from or 0) + 3) and not (ns.groupFollow and opt.group) then
    C_Timer.After(5, function() ns.AutoOpt("auto") end)
  end
end)


------------------------------------------------------------
-- Fahrplan 1 bis 60
-- Wird einmal (bei der Einrichtung oder per Knopf) im Hintergrund vorausgerechnet: Abschnitt fuer Abschnitt,
-- jeder Abschnitt geht vom geplanten Ende des vorigen weiter (Level, Ort, erledigte Quests).
-- Danach folgt der Pfeil dem Plan. Neu gerechnet wird nur:
--   * ein Abschnitt, wenn du zu weit vom Plan weg bist (Level, viele Quests im Log, die nicht im Plan sind)
--   * der ganze Plan, wenn du es willst, Einstellungen aenderst oder bei der Pruefung alle 5 Level
------------------------------------------------------------
local PLAN_STEP = 5      -- Level pro Abschnitt
-- 18.4: wieder immer 5 Level. Sim Teil S (18.2, 3 Level mit schwachem PC): Zeit bis 60 +4%, Spitzen beim Rechnen
-- nicht kleiner, 14% mehr Neurechnen. Schwacher PC heisst jetzt nur: weniger Arbeit pro Bild (5 statt 12 ms)
local function PlanStep() return PLAN_STEP end
local PLAN_MAX_SECS = 30 -- Sicherheit

function ns.PlanActive()
  local db = ns.db
  return db and db.planOn ~= false and db.plan60 and db.plan60.secs and #db.plan60.secs > 0 and true or false
end

local function Pts(acts)
  -- Spawn Punkte kuerzen, damit der Plan klein bleibt (fuer den Pfeil zum naechsten Mob reichen 12)
  for _, a in ipairs(acts or {}) do
    if type(a.pts) == "table" and #a.pts > 12 then
      local t = {}
      local stepn = #a.pts / 12
      for i = 1, 12 do t[i] = a.pts[math.floor((i - 1) * stepn) + 1] end
      a.pts = t
    end
  end
end

-- welche Quests ein Abschnitt annimmt und abgibt
local function SecQuests(steps)
  local acc, tin = {}, {}
  for _, st in ipairs(steps or {}) do
    for _, a in ipairs(st.acts or {}) do
      if a.qid and a.qid > 0 then
        if a.k == "A" then acc[a.qid] = true end
        if a.k == "T" then tin[a.qid] = true end
      end
    end
  end
  return acc, tin
end

local function Progress(text)
  ns.planProgress = text
  if ns.RefreshHud then pcall(ns.RefreshHud) end
end

-- 20.4a (K 19:09, S 19:07): naechstes Stueck der Nach 60 Route im Hintergrund rechnen, ab dem Ende der jetzigen Route
-- (Ort, schon eingeplante Quests gelten als gemacht), und hinten anhaengen. Die gezeigte Route und die gemachten
-- Schritte bleiben. Fertig: kurzer Hinweis im Mini Fenster ("Route fertig gerechnet, N Schritte")
local REST_CHUNKS_MAX = 30
-- 20.4b2 (Si 22:40 s60: a5 rechnete 40 bis 49 s statt 7 bis 13, mehr Speicher): die weiteren Stuecke nur rechnen, solange
-- weniger als REST_AHEAD_STEPS Schritte vor dir liegen. Danach prueft es alle REST_WAIT_S Sekunden, ob wieder eins noetig ist
local REST_AHEAD_STEPS = 120
local REST_WAIT_S = 60
local REST_GAP_S = 10
function ns.RestChunkNext()
  local db = ns.db
  local o = db and db.opt
  if not (o and o.steps and #o.steps > 0 and o.opts and o.opts.rest) then return end
  if #o.steps - (o.idx or 1) >= REST_AHEAD_STEPS then
    if not ns.restWaitOn then
      ns.restWaitOn = true
      C_Timer.After(REST_WAIT_S, function() ns.restWaitOn = nil; if ns.db and ns.db.opt == o then ns.RestChunkNext() end end)
    end
    return
  end
  if ns.OptBusy and ns.OptBusy() then C_Timer.After(5, ns.RestChunkNext); return end
  if ns.InInstance and ns.InInstance() then C_Timer.After(10, ns.RestChunkNext); return end
  ns.restChunkN = (ns.restChunkN or 0) + 1
  if ns.restChunkN > REST_CHUNKS_MAX then return end
  local last = o.steps[#o.steps]
  local acc, tin = SecQuests(o.steps)
  local done, log = {}, {}
  for qid in pairs(tin) do done[qid] = true end
  for qid in pairs(acc) do if not tin[qid] then log[qid] = true end end
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  local sim = { L = maxL, xp = ns.xpTotal[maxL] or 0, map = last.map, x = last.x, y = last.y, done = done, log = log,
    trained = db.trainedAt or 0, sec = 2 }
  local mode = ModeFor(maxL)
  mode.rest = true
  mode.sim = sim
  local before = #o.steps
  ns.Optimize(maxL, function(res)
    if db.opt ~= o then return end -- inzwischen andere Route: nicht mehr anhaengen
    local add = res and res.steps or {}
    local n = 0
    for _, st in ipairs(add) do
      local q = false
      for _, a in ipairs(st.acts or {}) do if a.qid and a.qid > 0 then q = true end end
      if q then o.steps[#o.steps + 1] = st; n = n + 1 end
    end
    if ns.TestLog then ns.TestLog("RECHNEN", ("Nach 60 Stueck %d im Hintergrund: %d Schritte angehaengt (vorher %d), noch %d Quests offen"):format(ns.restChunkN or 0, n, before, ns.optRestMore or 0)) end
    if ns.Draw then ns.Draw() end
    -- v11e (Pr P26): Stueck ohne Schritte, aber es gibt noch Quests: diese Quests merken (nicht wieder nehmen), gleich weiter
    if n == 0 and (ns.optRestMore or 0) > 0 and ns.optRestChunk then
      ns.restTried = ns.restTried or {}
      for qid in pairs(ns.optRestChunk) do ns.restTried[qid] = true end
      ns.optRestChunk = nil
      C_Timer.After(1, ns.RestChunkNext)
    elseif n > 0 and (ns.optRestMore or 0) > 0 then
      C_Timer.After(REST_GAP_S, ns.RestChunkNext)
    else
      ns.restDoneMsg = { t = (GetTime and GetTime() or 0) + 15, text = (TR"Route fertig gerechnet, %d Schritte"):format(#o.steps) }
      if ns.RefreshHud then pcall(ns.RefreshHud) end
    end
  end, mode)
end

-- ganzen Fahrplan ab jetzt rechnen
-- Einstellungen, mit denen der Fahrplan gerechnet wird. Aendert sich etwas davon waehrend er rechnet,
-- rechnet er danach gleich nochmal. Die Einrichtung rechnet nur neu, wenn sich etwas geaendert hat.
function ns.PlanSig()
  local db = ns.db or {}
  local function b(v) return v and "1" or "0" end
  local st = ns.LevelStep and ns.LevelStep() or 2
  -- Grinden an oder aus gilt fuer beide Stufen
  return table.concat({ tostring(st), b(db.grind ~= false), b(db.eliteSolo), b(db.eliteGroup ~= false), b(db.books ~= false),
    b(ns.DungeonQOn and ns.DungeonQOn()), b(db.escorts ~= false), b(db.contSwitch ~= false), b(db.useFlights ~= false),
    b(ns.AllRest and ns.AllRest()), tostring(ns.EliteGap and ns.EliteGap() or 2) }, ",")
end

-- Neue Zonen aus den Questie Daten: Questgeber in einer Zone, die das Addon nicht kennt (zb ein neues Forever
-- Gebiet). Aus den Questlevels dort wird der Levelbereich gebildet, dann plant die Route die Zone ganz normal ein.
-- Einmal pro Login, in kleinen Stuecken (kein Ruckeln).
function ns.DiscoverZones(done)
  local function Done() if done then done() end end
  if ns.zonesFound ~= nil or ns.zonesFinding then Done(); return end
  if not (ns.QDBAccess and ns.QDBAccess()) or not ns.zones then Done(); return end
  QDB, ZDB, QLib = ns.QDBAccess()
  if not (QDB and ZDB and QLib) then Done(); return end
  ns.zonesFinding = true
  local lib = LibQuestieDB
  local ids = lib and lib.Quest and lib.Quest.GetAllIds and lib.Quest.GetAllIds()
  if type(ids) ~= "table" then ids = {}; for id in pairs(QDB.QuestPointers or {}) do ids[#ids + 1] = id end end
  -- Kontinente der bekannten Zonen: neue Zonen nur dort (keine Schlachtfelder oder Instanzen)
  local conts = {}
  for ui in pairs(ns.zones) do local c = World(ui, 0.5, 0.5); if c then conts[c] = true end end
  local levels = {}
  local i = 0
  local function Finish()
    local found = {}
    for ui, l in pairs(levels) do
      local info = C_Map.GetMapInfo and C_Map.GetMapInfo(ui)
      local c = World(ui, 0.5, 0.5)
      if #l >= 8 and info and info.mapType == 3 and c and conts[c] and not ns.zones[ui] then
        table.sort(l)
        local lo = l[math.max(1, math.floor(#l * 0.1 + 0.5))]
        local hi = math.max(l[math.max(1, math.ceil(#l * 0.9))], lo + 3)
        ns.zones[ui] = { min = lo, max = hi, area = l[math.ceil(#l / 2)], q = #l, auto = true }
        -- in den Level Plan (ein neues Startgebiet nicht: das gehoert nur dem Volk, das dort anfaengt)
        if ns.plan and lo >= 6 then table.insert(ns.plan, { ui, lo, hi }) end
        found[#found + 1] = ("%s %d-%d"):format(info.name or tostring(ui), lo, hi)
      end
    end
    ns.zonesFound = found
    ns.zonesFinding = nil
    if #found > 0 then
      table.sort(found)
      Report(TR"Neue Zonen aus Questie: " .. table.concat(found, ", "))
      if ns.TestLog then ns.TestLog("RECHNEN", TR"Neue Zonen aus Questie: " .. table.concat(found, ", ")) end
    end
    Done()
  end
  local function Step()
    local more = Budget(50)
    local n = 0
    while i < #ids and more(n) do
      i = i + 1
      n = n + 1
      local qid = ids[i]
      local sb = Q(qid, "startedBy")
      local npc = sb and sb[1] and sb[1][1]
      local sp = npc and N(npc, "spawns")
      if type(sp) == "table" then
        for area in pairs(sp) do
          local ui = Ui(area)
          -- Klassenquests zaehlen nicht (die verzerren den Levelbereich, zb Mondlichtung fuer Druiden)
          local rc = Q(qid, "requiredClasses")
          if ui and not ns.zones[ui] and not (ns.cityParent and ns.cityParent[ui]) and not (type(rc) == "number" and rc > 0) then
            local ok, ql = pcall(QLib.GetEffectiveQuestLevel, qid)
            if ok and type(ql) == "number" and ql > 0 and ql <= 60 then
              levels[ui] = levels[ui] or {}
              table.insert(levels[ui], ql)
            end
          end
          break -- die erste Zone des Questgebers reicht
        end
      end
    end
    if i < #ids then C_Timer.After(0, function() local ok = pcall(Step); if not ok then ns.zonesFinding = nil; ns.zonesFound = {}; Done() end end); return end
    Finish()
  end
  local ok = pcall(Step)
  if not ok then ns.zonesFinding = nil; ns.zonesFound = {}; Done() end
end

function ns.PlanBuild(reason, onDone)
  local db = ns.db
  if not db or ns.planBuilding then return end
  if ns.CalcHold() then return end
  -- nochmal versuchen, wenn etwas noch nicht fertig ist: immer nur ein Versuch wartet (der neueste Aufruf zaehlt).
  -- Vorher konnten zwei Warteschleifen gleichzeitig laufen und der Plan wurde beim ersten Start zweimal gerechnet.
  local reqAt = GetTime and GetTime() or 0
  local function Retry(delay)
    ns.planRetryTok = (ns.planRetryTok or 0) + 1
    local tok = ns.planRetryTok
    C_Timer.After(delay, function()
      -- inzwischen schon gerechnet (ein anderer Aufruf war schneller): nicht nochmal
      if (ns.planStartedAt or -1) >= reqAt then return end
      if ns.planRetryTok == tok then ns.PlanBuild(reason, onDone) end
    end)
  end
  if not (ns.QDBAccess and ns.QDBAccess()) then
    -- noch nicht alles geladen (andere Addons, Questie): der Knopf zeigt das, gerechnet wird von selbst danach
    ns.planPending = (ns.StartReady and not ns.StartReady()) and "addons" or "questie"
    ns.PlanWaitAnnounce()
    Retry(2)
    return
  end
  -- Wegdaten (Mob Ebene: Elite Felder, Laufwege) zuerst fertig machen, sonst rechnet die Route mit
  -- halben Daten und kommt jedes Mal etwas anders raus
  local W = ns.Ways
  if W and W.BuildMobLayer and W.MobVersion and not (ns.wayWaitN and ns.wayWaitN > 90) then
    local ml = db.mobLayer
    if W.MobBuilding() or not (ml and ml.ver == W.MobVersion()) then
      if not W.MobBuilding() then pcall(W.BuildMobLayer) end
      if W.MobBuilding() then
        ns.planPending = "ways"
        ns.wayWaitN = (ns.wayWaitN or 0) + 1
        if ns.wayWaitN == 1 then ns.planWaitAnn = "ways"; ns.Print(TR"Wegdaten werden vorbereitet, die Route rechnet gleich danach ...") end
        Retry(1)
        return
      end
    end
  end
  ns.wayWaitN = nil
  -- 19.0 Gelaende Karte: Zonen und Zonen Wege erst fertig vorbereiten (beim Einloggen ein paar Sekunden im Hintergrund)
  local KA = ns.Karte
  if KA and KA.Preparing and KA.Preparing() and not (ns.karteWaitN and ns.karteWaitN > 120) then
    ns.planPending = "ways"
    ns.karteWaitN = (ns.karteWaitN or 0) + 1
    if ns.karteWaitN == 1 and ns.planWaitAnn ~= "ways" then ns.planWaitAnn = "ways"; ns.Print(TR"Wegdaten werden vorbereitet, die Route rechnet gleich danach ...") end
    Retry(1)
    return
  end
  ns.karteWaitN = nil
  -- erst neue Zonen aus Questie suchen (einmal pro Login), dann rechnen
  if ns.zonesFound == nil and ns.DiscoverZones then
    ns.planPending = "zones"
    ns.planRetryTok = (ns.planRetryTok or 0) + 1
    local tok = ns.planRetryTok
    if not ns.zonesFinding then ns.DiscoverZones(function() if (ns.planStartedAt or -1) < reqAt then ns.PlanBuild(reason, onDone) end end) end
    return
  end
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then ns.planPending = "pos"; Retry(2); return end
  ns.planPending = nil
  ns.planWaitAnn = nil
  local px, py = pos:GetXY()
  local L = ns.UnitLevel and ns.UnitLevel("player") or UnitLevel("player")
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if L >= maxL then return end
  local xp = (ns.xpTotal[L] or 0) + (ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0)
  local inLog = {}
  if ns.ReadLog then ns.ReadLog() end
  for qid in pairs(ns.logProgress or {}) do inLog[qid] = true end
  local sim = { L = L, xp = xp, map = mapID, x = px, y = py, done = {}, log = inLog, trained = db.trainedAt or 0 }
  local secs = {}
  -- 20.1b (P9, Sascha 13:16): der erste Abschnitt laeuft sofort, sobald er gerechnet ist (vorher erst nach allen
  -- Abschnitten, ca 2 Minuten "Route wird berechnet"). early = die Route, die schon laeuft
  local early
  local said33, said66 = false, false -- 20.3j (S Test Punkt 2): Zwischenstand im Chat
  ns.planBuilding = true
  ns.planStartedAt = GetTime and GetTime() or 0
  local sig = ns.PlanSig()
  local t0 = GetTime and GetTime() or 0
  if ns.TestLog then ns.TestLog("RECHNEN", (TR"Route Start ab Level %.1f (%s)"):format(L + 0, reason or "neu")) end
  ns.Print((TR"Route wird berechnet, Level %d bis %d. Das Spiel kann dabei kurz ruckeln, das hört von selbst auf."):format(L, maxL))
  local function Finish(ok)
    ns.simLevel = nil
    ns.planBuilding = false
    Progress(nil)
    if ok and #secs > 0 then
      -- was du vom alten Plan schon gemacht hast, bleibt als Verlauf (nur die Zukunft wird neu)
      if ns.PlanArchive then ns.PlanArchive() end
      db.plan60 = { secs = secs, cur = 0, built = time and time() or 0, fromL = L, toL = secs[#secs].to, sig = sig, ver = ns.PLAN_VER, loc = ns.LOCALE }
      local n = 0
      for _, sc in ipairs(secs) do n = n + #sc.steps end
      ns.Print((TR"Route fertig: Level %d bis %d, %d Schritte in %d Abschnitten."):format(L, math.floor(secs[#secs].to), n, #secs))
      -- 19.39 (Messung optimizer_lauf: nach dem Fahrplan ca 34 MB Lua Muell): in kleinen Stuecken wegraeumen, kein Ruckler
      if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(0.2, function() collectgarbage("step", 2000) end, 20)
      end
      -- Alles: Elite und Gruppenquests kommen spaeter (sobald allein machbar) oder mit einer Gruppe
      local m0 = ModeFor(L)
      if m0 and m0.eliteLater and not (ns.EliteAllowed and ns.EliteAllowed()) then
        ns.Print(TR"Alles erleben: Elite und Gruppenquests holt die Route später nach, sobald du sie allein schaffst. Oder ihr sucht euch eine Gruppe, dann kommen sie gleich dran.")
      end
      if ns.TestLog then
        ns.TestLog("RECHNEN", (TR"Route fertig in %.0fs: %d Abschnitte, %d Schritte, bis Level %.1f"):format((GetTime and GetTime() or 0) - t0, #secs, n, secs[#secs].to))
        -- kurz pro Abschnitt (der ganze Plan steht sowieso in den gespeicherten Daten): Level, Zeit, Quests, Grinden, Zonen
        for k, sc in ipairs(secs) do
          local zs, zn, g, hint = {}, {}, 0, 0
          for _, st in ipairs(sc.steps or {}) do
            if st.map and not zs[st.map] then zs[st.map] = true; zn[#zn + 1] = ns.ZoneName and ns.ZoneName(st.map) or tostring(st.map) end
            for _, a in ipairs(st.acts or {}) do
              if a.k == "G" and a.hint then hint = hint + (a.min or 0) elseif a.k == "G" then g = g + (a.min or 0) end
            end
          end
          ns.TestLog("RECHNEN", ("Abschnitt %d: Level %.1f bis %.1f, %s, %d Quests, %d Schritte, Grinden %d Min, Hinweis %d Min | %s"):format(
            k, sc.from or 0, sc.to or 0, ns.PlanClock and ns.PlanClock(sc.sec or 0) or tostring(sc.sec), sc.quests or 0, #(sc.steps or {}), g, hint,
            ns.U8Sub(table.concat(zn, ", "), 160)))
        end
      end
      if ns.PlanHistUpdate then pcall(ns.PlanHistUpdate) end
      -- Tempo Schaetzung (Prozent und Zeit bis 60) mit der neuen Route neu rechnen
      if ns.TempoDirty then ns.TempoDirty() end
      -- 20.1b (P9): laeuft der erste Abschnitt schon (früh gezeigt), bleibt er mit deinem Stand, nur Titel und Plan dazu.
      -- Sonst wie bisher den ersten Abschnitt laden
      local eo = early and early.steps == secs[1].steps and early
      local lvp = db.profiles and db.profiles.level
      if eo and (db.opt == eo or (lvp and lvp.opt == eo)) then
        eo.early = nil
        eo.title = (TR"Abschnitt %d von %d"):format(1, #secs)
        db.plan60.cur = 1
        if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt 1 lief schon (Schritt %d), bleibt"):format(eo.idx or 1)) end
        if ns.OptSync then ns.OptSync() end
        if ns.RefreshBig then pcall(ns.RefreshBig) end
      else
        if early then early.early = nil end
        ns.PlanNext(true)
      end
    else
      ns.Print(TR"Die ganze Route konnte nicht gerechnet werden, sie rechnet jetzt Abschnitt für Abschnitt.")
    end
    if onDone then onDone(ok) end
    -- waehrend dem Rechnen Einstellungen geaendert (zB in der Einrichtung): gleich mit den neuen nochmal
    if ok and ns.PlanSig() ~= sig and db.planOn ~= false then
      -- 20.2 (Log 14:36: 35 Rechnungen in der Einrichtung): in der Einrichtung gar nicht (gerechnet wird bei Fertig oder
      -- Route berechnen), sonst 3 s nach der letzten Aenderung, und nur einmal (neuere Aenderung ersetzt die Wartezeit)
      if ns.setupOpen then
        ns.planDirty = true
      else
        ns.planSoonTok = (ns.planSoonTok or 0) + 1
        local tok = ns.planSoonTok
        C_Timer.After(3, function()
          if tok == ns.planSoonTok and not ns.planBuilding and not ns.setupOpen and ns.PlanSig() ~= (db.plan60 and db.plan60.sig) then
            ns.PlanBuild(TR"Einstellungen geändert")
          end
        end)
      end
    end
  end
  local lastMove = GetTime and GetTime() or 0
  local finished = false
  local realFinish = Finish
  Finish = function(ok) if finished then return end; finished = true; realFinish(ok) end
  -- Sicherheit: haengt ein Abschnitt (Fehler im Hintergrund), nach 40 Sekunden mit dem fertig werden, was da ist
  local function Watch()
    if finished then return end
    -- solange ein Abschnitt noch rechnet, nicht abbrechen (der Optimierer hat selbst eine Sicherung)
    if not busy and (GetTime and GetTime() or 0) - lastMove > 40 then Finish(#secs > 0); return end
    C_Timer.After(5, Watch)
  end
  C_Timer.After(5, Watch)
  -- ext: der Abschnitt hatte zu wenig Quests (Hinweis "dir fehlen X Level"): nochmal mit 3 Leveln mehr als Ziel.
  -- Dann kommen die etwas hoeheren Quests dazu, die erst mitten im Abschnitt gehen (sonst grindet der Abschnitt
  -- stundenlang, und der naechste hat danach alle diese Quests)
  local function Next(retryAll, ext)
    if finished then return end
    if busy and (GetTime() - (busyAt or 0)) < 300 then C_Timer.After(1, Next); return end
    lastMove = GetTime and GetTime() or 0
    local rest = false
    if #secs >= PLAN_MAX_SECS or sim.L >= maxL - 0.01 then
      -- Alles erleben: auf Max Level noch ein letzter Abschnitt mit allen Quests, die noch offen sind
      local m60 = ModeFor(maxL)
      if sim.L >= maxL - 0.01 and #secs < PLAN_MAX_SECS and m60 and m60.scope == "all" and not sim.restDone then
        rest = true
        -- 20.3i (S 19:26, AUF K 19:30): interner Schalter fuer Sim und optimizer_lauf (db.allesBisFertig, nicht im
        -- Spiel einstellbar): Alles rechnet auf Max Level weiter, Abschnitt fuer Abschnitt, bis keine machbare Quest
        -- mehr offen ist (Folgequests der letzten Abschnitte kommen so auch noch). Ende: Abschnitt ohne Schritte
        sim.restDone = not (ns.db and ns.db.allesBisFertig)
      else
        Finish(true); return
      end
    end
    local fromL = math.floor(sim.L)
    -- 20.3k (S Test 20.3g Punkt 15, Log L6 bis 59 s): der erste Abschnitt ist klein (3 Level) und wird ohne Nachrechnen
    -- genommen, damit der Pfeil schnell startet. Die weiteren Abschnitte rechnen danach im Hintergrund wie bisher
    local quick = #secs == 0 and not rest and not retryAll and not ext
    local target = math.min(maxL, fromL + (quick and 3 or PlanStep()) + (ext and 3 or 0))
    local mode = ModeFor(fromL)
    if rest then mode.rest = true end
    -- ohne Grinden: reichen die Quests nicht, nochmal mit allen Quests (auch schwaechere), bevor ein Hinweis kommt
    -- ohne Grind Pausen reichen die Quests nicht: nochmal mit allen Quests aus allen Zonen deiner Fraktion
    -- 20.3f (optimizer_lauf q203e: 20.3e rechnete jede Luecke gleich wie Alles nach, Normal wurde so 222 statt 175 Std):
    -- Nachrechnen in Stufen. Stufe 1 wie bis 20.3d (Zonen deiner Fraktion, Quests nahe deinem Level). Nur ohne Grinden
    -- und nur wenn das nicht reicht: Stufe 2 alle Zonen, Stufe 3 auch tiefere Quests wie Alles
    local lv = (retryAll == true and 1) or retryAll or 0
    -- 20.3g (optimizer_lauf q203f ohne Grinden 245 Std, mehr als Alles 235): Stufe 2 und 3 ohne "all" (das nimmt JEDE Quest
    -- im Abschnitt, auch graue weit weg). Jetzt nur so viele Quests wie fuer das Ziel noetig (cap wie Normal), die besten
    -- zuerst, keine Mindest XP gegen Grinden (thr 0, ohne Grinden gibt es keinen Vergleich)
    if lv >= 3 then
      mode = { stufe = 3, fillGap = mode.fillGap, noGrind = mode.noGrind, step = mode.step, emergency = true, scope = "all", qlDown = math.max(mode.qlDown or 5, (ns.LEVEL_STEPS and ns.LEVEL_STEPS[1] and ns.LEVEL_STEPS[1].qlDown) or 60), eliteLater = true, thrF = 0, capF = mode.capF or 1.5, gapUp = 1 }
    elseif lv == 2 then
      mode = { stufe = 2, fillGap = mode.fillGap, noGrind = mode.noGrind, step = mode.step, emergency = true, scope = "all", qlDown = mode.qlDown, eliteLater = true, thrF = 0, capF = mode.capF or 1.5, gapUp = 1 }
    elseif lv == 1 then
      mode = { all = true, fillGap = mode.fillGap, noGrind = mode.noGrind, step = mode.step, emergency = true, scope = "wide", qlDown = mode.qlDown, gapFill = true, gapUp = 1 }
    end
    sim.sec = #secs + 1
    mode.sim = sim
    ns.simLevel = fromL
    Progress((TR"Route wird berechnet: Level %d bis %d ..."):format(fromL, target))
    -- 20.3j (S Test 20.3g Punkt 2): zwei Zwischenstaende im Chat (ca ein Drittel, zwei Drittel), "Route fertig" kommt am Ende
    if not rest and maxL > L then
      local pct = (fromL - L) / (maxL - L)
      if pct >= 0.66 and not said66 then
        said66, said33 = true, true
        ns.Print((TR"Route wird berechnet: %d %%, jetzt bei Level %d"):format(66, fromL))
      elseif pct >= 0.33 and not said33 then
        said33 = true
        ns.Print((TR"Route wird berechnet: %d %%, jetzt bei Level %d"):format(33, fromL))
      end
    end
    local Use
    -- Fluss: erst den Abschnitt auf dem Kontinent rechnen, auf dem du bist. Nur wenn das klar schlechter ist
    -- (Quests reichen nicht, viel Grinden), auch mit Schiff und Zeppelin. So faehrt die Route nicht fuer
    -- ein paar Quests hin und her.
    local F = ns.FLOW or {}
    local lockTry = F.contLock and not rest and not retryAll and not (db.contSwitch == false)
    local function Snap()
      local b = {}
      for k, v in pairs(sim.books or {}) do b[k] = v end
      return { books = b, bookTurned = sim.bookTurned, trainedOut = sim.trainedOut }
    end
    local function Restore(sn)
      local b = {}
      for k, v in pairs(sn.books) do b[k] = v end
      sim.books, sim.bookTurned, sim.trainedOut = b, sn.bookTurned, sn.trainedOut
    end
    local snapN = Snap()
    local function Has(o) return o and #(o.steps or {}) > 0 end
    local function Weak(o)
      if not Has(o) or o.hintGap or (o.to or 0) < target - 0.3 then return true end
      local g = 0
      for _, st in ipairs(o.steps) do for _, a in ipairs(st.acts or {}) do if a.k == "G" and not a.hint then g = g + (a.min or 0) * 60 end end end
      return g > (o.sec or 0) * (F.lockGrind or 0.25)
    end
    local function RunOpt(lock, cb)
      mode.contLock = lock or nil
      local ok = pcall(ns.Optimize, target, cb, mode)
      if not ok then Finish(#secs > 0) end
    end
    local snap0 = lockTry and Snap()
    local function Start()
      if not lockTry then RunOpt(false, function(o) Use(o) end); return end
      RunOpt(true, function(optA)
        if finished then return end
        if not Weak(optA) then Use(optA); return end
        local snapA = Snap()
        Restore(snap0)
        C_Timer.After(0.05, function()
          if finished then return end
          RunOpt(false, function(optB)
            if finished then return end
            if Has(optA) and (not Has(optB) or (optA.rate or 0) * (F.contKeep or 1.15) >= (optB.rate or 0)) then
              Restore(snapA); Use(optA)
            else
              Use(optB)
            end
          end)
        end)
      end)
    end
    Use = function(opt)
      ns.simLevel = nil
      if finished then return end
      lastMove = GetTime and GetTime() or 0
      if not opt or #(opt.steps or {}) == 0 then
        -- 20.3e/f: ohne Grinden und ohne Schritte (Normal, Level 51.7): naechste Stufe beim Nachrechnen, nach Stufe 3 fertig
        if mode.noGrind and ((not mode.all and lv == 0) or (lv > 0 and lv < 3)) and not rest and sim.L < maxL - 0.01 then
          if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt %d (Level %.1f): keine Quests, nochmal mit mehr Quests (Stufe %d)"):format(#secs + 1, sim.L, lv + 1)) end
          Restore(snapN); C_Timer.After(0.05, function() Next(lv + 1, ext) end); return
        end
        Finish(#secs > 0); return
      end
      -- 20.3e: ohne Grinden gibt es keinen Hinweis, ein zu kurzer Abschnitt (endet klar vor dem Ziel) zaehlt dann als Luecke
      local short = mode.noGrind and not opt.hintGap and (opt.to or 0) < target - 0.3 and target < maxL + 0.01
      if quick and (opt.hintGap or short) then
        if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt 1 (Level %.1f) klein und ohne Nachrechnen genommen, damit es schnell losgeht"):format(sim.L)) end
        opt.hintGap, short = nil, false
      end
      if (opt.hintGap or short) and not ext and not rest and target < maxL then
        if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt %d (Level %.1f): zu wenig Quests bis %d, nochmal bis %d"):format(#secs + 1, sim.L, target, math.min(maxL, target + 3))) end
        Restore(snapN); C_Timer.After(0.05, function() Next(retryAll, true) end); return
      end
      if (opt.hintGap or short) and not mode.all and not retryAll then Restore(snapN); C_Timer.After(0.05, function() Next(1, ext) end); return end
      -- 20.3f: ohne Grinden reicht Stufe 1 oder 2 nicht (Abschnitt endet klar vor dem Ziel): naechste Stufe
      -- 20.3i (rauch203f Duo: ab Level 55 stundenlang "grinden ohne Quests", bis 473 Min): in der Gruppe ist Grinden
      -- langsam (XP geteilt), darum dort bei "Level fehlt" auch die naechste Stufe (alle Zonen, dann tiefere Quests)
      local grpGap = opt.hintGap and IsInGroup and IsInGroup() and not mode.noGrind
      if (short or grpGap) and lv > 0 and lv < 3 then
        if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt %d (Level %.1f): %s zu wenig Quests bis %d, nochmal mit mehr Quests (Stufe %d)"):format(#secs + 1, sim.L, grpGap and "in der Gruppe" or "ohne Grinden", target, lv + 1)) end
        Restore(snapN); C_Timer.After(0.05, function() Next(lv + 1, ext) end); return
      end
      -- Abschnitt mit "Dir fehlen noch X Level": warum es zu wenig Quests gab (fuer das Test Log)
      if opt.hintGap and ns.TestLog and ns.optWhy then
        local list = {}
        for r, n in pairs(ns.optWhy) do list[#list + 1] = { r, n } end
        table.sort(list, function(a, b) return a[2] > b[2] end)
        local t = {}
        for k = 1, math.min(6, #list) do t[#t + 1] = tostring(list[k][1]) .. " " .. list[k][2] end
        -- und warum passende Kandidaten nicht eingeplant wurden
        local sl, ts = {}, {}
        for r, n in pairs(ns.optWhySel or {}) do sl[#sl + 1] = { r, n } end
        table.sort(sl, function(a, b) return a[2] > b[2] end)
        for k = 1, math.min(6, #sl) do ts[#ts + 1] = tostring(sl[k][1]) .. " " .. sl[k][2] end
        ns.TestLog("RECHNEN", ("Abschnitt %d (Level %.1f): zu wenig Quests, Gruende: %s | nicht eingeplant: %s"):format(#secs + 1, sim.L, table.concat(t, ", "), table.concat(ts, ", ")))
      end
      for _, st in ipairs(opt.steps) do Pts(st.acts) end
      local acc, tin = SecQuests(opt.steps)
      table.insert(secs, { from = sim.L, to = opt.to, steps = opt.steps, opts = opt.opts, title = opt.title,
        sec = opt.sec, quests = opt.quests, xp = opt.xp, rate = opt.rate })
      -- 20.1b (P9): erster Abschnitt fertig und es laeuft gerade keine brauchbare Leveling Route (neu, fertig oder nur
      -- die kurze Start Route): gleich zeigen, der Pfeil startet. Laeuft eine Zusatz Route, wartet er im Level Profil
      if #secs == 1 and not rest then
        local o = db.opt
        local special = o and ns.OptSpecial(o) and (o.idx or 1) <= #(o.steps or {})
        local usable = o and not special and (o.plan or #(o.steps or {}) > 1) and (o.idx or 1) <= #(o.steps or {})
        if not usable and not (o and (o.mirror or o.group or o.split)) then
          local sc = secs[1]
          early = { steps = sc.steps, idx = 1, created = time and time() or 0, from = sc.from, to = sc.to, target = math.floor((sc.to or 0) + 0.5),
            quests = sc.quests or 0, sec = sc.sec or 0, xp = sc.xp or 0, rate = sc.rate or 0, opts = sc.opts, plan = 1, early = true,
            title = TR"Abschnitt 1 (weitere werden berechnet)" }
          if not (ns.ProfileParkLevel and ns.ProfileParkLevel(early)) then
            db.opt = early
            db.optMode = true
            db.profileCur = "level"
          end
          if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt 1 gleich gezeigt: %d Schritte, Rest rechnet weiter"):format(#sc.steps)) end
          if ns.OptSync then pcall(ns.OptSync) end
          if ns.Draw then pcall(ns.Draw) end
          if ns.RefreshHud then pcall(ns.RefreshHud) end
        end
      end
      -- naechster Abschnitt startet am geplanten Ende
      for qid in pairs(tin) do sim.done[qid] = true; sim.log[qid] = nil end
      for qid in pairs(acc) do if not tin[qid] then sim.log[qid] = true end end
      local e = opt.end_ or {}
      local newXP = e.xp or ((ns.xpTotal[math.floor(opt.to)] or sim.xp))
      if rest then Finish(true); return end -- letzter Abschnitt auf Max Level: fertig
      if (opt.to or 0) <= sim.L + 0.05 then Finish(#secs > 0); return end -- kein Fortschritt mehr
      sim.L, sim.xp = opt.to, newXP
      sim.map, sim.x, sim.y = e.map or sim.map, e.x or sim.x, e.y or sim.y
      sim.trained = sim.trainedOut or sim.trained
      -- neuer Bindepunkt im Abschnitt? dann gilt der fuer den naechsten
      local lastH
      for _, st in ipairs(opt.steps) do
        for _, a in ipairs(st.acts or {}) do
          if a.k == "B" and a.imap then sim.bind = { a.imap, a.ix, a.iy } end
          if a.k == "H" and not a.recall then lastH = st.t or lastH end
        end
      end
      -- Ruhestein Abklingzeit in den naechsten Abschnitt mitnehmen
      local CDh = (ns.db and ns.db.hearthCD) or 3600
      if lastH then sim.hcd = math.max(0, CDh - math.max(0, (opt.sec or 0) - lastH))
      else sim.hcd = math.max(0, (sim.hcd or 0) - (opt.sec or 0)) end
      C_Timer.After(0.05, Next)
    end
    Start()
  end
  Next()
end

-- naechsten Abschnitt laden (flicken, wenn noetig)
-- den laufenden Abschnitt vom Plan wieder laden, beim gemerkten Schritt (nach einer Tour, ohne gemerkte Route).
-- Vorher lud die Route dann den naechsten Abschnitt und der Rest vom laufenden fiel weg.
function ns.PlanReload()
  local db = ns.db
  local pl = db and db.plan60
  local i = pl and pl.cur
  local sec = i and i >= 1 and pl.secs and pl.secs[i]
  if not sec or not sec.steps or #sec.steps == 0 then return false end
  local idx = math.max(1, math.min(pl.curIdx or 1, #sec.steps))
  db.opt = { steps = sec.steps, idx = idx, created = time and time() or 0, from = sec.from, to = sec.to, target = math.floor((sec.to or 0) + 0.5),
    quests = sec.quests or 0, sec = sec.sec or 0, xp = sec.xp or 0, rate = sec.rate or 0, title = (TR"Abschnitt %d von %d"):format(i, #pl.secs), opts = sec.opts, plan = i }
  pl.curIdx = nil
  db.optMode = true
  db.profileCur = "level"
  if ns.TestLog then ns.TestLog("PROFIL", ("Leveling Route: Abschnitt %d ab Schritt %d wieder geladen"):format(i, idx)) end
  if ns.OptSync then ns.OptSync() end
  if ns.Draw then ns.Draw() end
  if ns.RefreshBig then pcall(ns.RefreshBig) end
  return true
end

function ns.PlanNext(first)
  local db = ns.db
  local pl = db and db.plan60
  if not (pl and pl.secs) then return end
  -- Gruppen Route vom Leiter laeuft: dein Fahrplan wartet
  if db.opt and db.opt.mirror and ns.MirrorStale and not ns.MirrorStale() then return end
  local L0 = UnitLevel("player")
  -- Level mit Anteil (zB 10.6), der Plan rechnet auch so
  local L = L0 + ((ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0) / math.max(1, (ns.Plain and ns.Plain(UnitXPMax("player")) or UnitXPMax("player") or 1)))
  local i = (pl.cur or 0) + 1
  -- Abschnitte ueberspringen, die du vom Level her schon hinter dir hast
  while pl.secs[i] and (pl.secs[i].to or 0) <= L + 0.2 and pl.secs[i + 1] do i = i + 1 end
  local sec = pl.secs[i]
  if not sec then
    -- Plan zu Ende (oder Level 60): normal weiter (erledigte Schritte bleiben im Verlauf)
    if ns.PlanArchive then ns.PlanArchive(true) end
    db.plan60 = nil
    if not first then ns.AutoOpt(true) end
    return
  end
  pl.cur = i
  -- passt der Abschnitt noch? Level mehr als 1,5 daneben oder viele Quests im Log, die der Plan nicht kennt: nur diesen Abschnitt neu
  local known = {}
  for k = i, #pl.secs do
    local acc, tin = SecQuests(pl.secs[k].steps)
    for q in pairs(acc) do known[q] = true end
    for q in pairs(tin) do known[q] = true end
  end
  -- Dungeon, Raid und Elite Quests plant der Fahrplan bewusst nicht, die zaehlen nicht als fremd
  local foreign = 0
  for qid in pairs(ns.logProgress or {}) do
    if not known[qid] and not (ns.IsDungeonQuest and ns.IsDungeonQuest(qid)) and not (ns.IsEliteQuest and ns.IsEliteQuest(qid)) then
      foreign = foreign + 1
    end
  end
  -- umgekehrt: der Abschnitt will Mobs fuer eine Quest hauen oder abgeben, die du gar nicht hast
  -- (nicht im Log, nicht vorher im Abschnitt angenommen, nicht erledigt). Sonst steht "Eber hauen" da, ohne die Quest
  local missing = 0
  local missWhy = {}
  do
    local acc, tin = {}, {}
    -- Vorquest fuer ein Annehmen: erledigt oder vorher in diesem Abschnitt abgegeben. Sonst hat ein
    -- frueherer Abschnitt sie beim Anpassen weggelassen (Zwerg: The Reports ohne Frostmane Hold).
    -- 19.15: nur im Log reicht nicht (Sim 19.14 N_0104: Ormer's Revenge 1 im Log, der angepasste Abschnitt davor gab sie
    -- nicht ab, der naechste wollte Teil 2 annehmen, der Schritt ging nie)
    local function PreHave(id)
      return tin[id] or (ns.QuestStatus and ns.QuestStatus(id) == "done")
    end
    for _, st in ipairs(sec.steps or {}) do
      for _, a in ipairs(st.acts or {}) do
        local q = a.qid
        if q and q > 0 then
          if a.k == "A" and not a.cls and not (ns.logProgress and ns.logProgress[q]) then
            local ps, pg = Q(q, "preQuestSingle"), Q(q, "preQuestGroup")
            local ok = true
            if type(ps) == "table" and #ps > 0 then
              ok = false
              for _, id in ipairs(ps) do if PreHave(id) then ok = true; break end end
            end
            if ok and type(pg) == "table" then for _, id in ipairs(pg) do if not PreHave(id) then ok = false; break end end end
            if not ok then missing = missing + 1; if #missWhy < 3 then missWhy[#missWhy + 1] = "A" .. q end end
          end
          if a.k == "T" then tin[q] = true end
          if a.k == "A" then acc[q] = true
          elseif ((a.k == "O" and not a.pre) or a.k == "T") and not acc[q] and not a.cls then
            acc[q] = true
            local inLog = ns.logProgress and ns.logProgress[q]
            local done = ns.QuestStatus and ns.QuestStatus(q) == "done"
            if not inLog and not done then missing = missing + 1; if #missWhy < 3 then missWhy[#missWhy + 1] = a.k .. q end end
          end
        end
      end
    end
  end
  -- Neu rechnen nach den Regeln: ein ganzes Level voraus oder hinten. Fehlt eine Vorquest oder eine Quest,
  -- die der Abschnitt abgeben will, ist der Abschnitt kaputt: auch neu (sonst zeigt er Unmoegliches).
  -- Viele Quests im Log, die der Plan nicht kennt: nur der Hinweis "Neu rechnen?"
  if math.abs(L - (sec.from or L)) >= 1.0 or missing >= 1 then
    if ns.TestLog then ns.TestLog("RECHNEN", ("Abschnitt %d neu, Grund: %s (Level %.1f statt %.1f, %d fremde Quests, %d fehlen im Log)"):format(i,
      missing >= 1 and "Vorquest fehlt" or (L > (sec.from or L) and "Level voraus" or "Level hinten"), L, sec.from or 0, foreign, missing)
      .. (#missWhy > 0 and (" | " .. table.concat(missWhy, " ")) or "")) end
    ns.PlanSectionLive()
    return
  end
  if foreign >= 3 and ns.RecalcAsk then ns.RecalcAsk("fremd", (TR"%d Quests im Log sind nicht in der Route."):format(foreign)) end
  -- du leitest eine Gruppe, die mitlaeuft: Abschnitt live mit allen rechnen (Lehrer aller Klassen, gemeinsamer Bindepunkt)
  if ns.GroupPlanInfo and ns.GroupPlanInfo() then
    if ns.TestLog then ns.TestLog("RECHNEN", (TR"Abschnitt %d live für die Gruppe"):format(i)) end
    ns.PlanSectionLive()
    return
  end
  local nopt = { steps = sec.steps, idx = 1, created = time and time() or 0, from = sec.from, to = sec.to, target = math.floor(sec.to + 0.5),
    quests = sec.quests or 0, sec = sec.sec or 0, xp = sec.xp or 0, rate = sec.rate or 0, title = (TR"Abschnitt %d von %d"):format(i, #pl.secs), opts = sec.opts, plan = i }
  -- 20.1 (P7): Fahrplan fertig, waehrend eine Zusatz Route laeuft: der Abschnitt wartet im Level Profil
  if ns.ProfileParkLevel and ns.ProfileParkLevel(nopt) then return end
  db.opt = nopt
  db.optMode = true
  if ns.OptSync then ns.OptSync() end
  if ns.TestLog then ns.TestLog("RECHNEN", (TR"Abschnitt %d von %d geladen: Level %.1f bis %.1f, %d Schritte"):format(i, #pl.secs, sec.from or 0, sec.to or 0, #sec.steps)) end
  if ns.Draw then ns.Draw() end
  if ns.RefreshBig then pcall(ns.RefreshBig) end
end

-- Questziel, an dem du gerade bist (aktueller Schritt, Quest im Log, Ziel noch offen): qid und Name vom Ziel
function ns.ActiveObjective()
  local o = ns.db and ns.db.opt
  local st = o and o.steps and o.steps[o.idx or 1]
  if not st or o.pin or o.backSec then return end
  for _, a in ipairs(st.acts or {}) do
    if a.k == "O" and a.qid and a.qid > 0 and a.obj and not a.pre and not a.buyAt and ns.logProgress and ns.logProgress[a.qid] then
      return a.qid, a.obj
    end
  end
end

-- aktuellen Abschnitt live neu rechnen (Questlog, eingeplante Upgrades, nach dem Tod weit weg ...), der Rest vom Plan bleibt
local liveSaid = 0
function ns.PlanSectionLive()
  local db = ns.db
  local pl = db and db.plan60
  -- im Chat melden (hoechstens jede Minute einmal)
  if GetTime and GetTime() - liveSaid > 60 then
    liveSaid = GetTime()
    ns.Print(TR"Abschnitt wird neu berechnet ...")
  end
  -- gerade zurueck geblaettert: erst wieder zum echten Abschnitt
  if db and db.opt and db.opt.backSec and ns.OptUnpin then ns.OptUnpin() end
  local L = ns.UnitLevel and ns.UnitLevel("player") or UnitLevel("player")
  local i = pl and math.max(1, pl.cur or 1)
  local sec = pl and pl.secs and pl.secs[i]
  -- Abschnitt passt gar nicht zum Level (zB Level 4 und Abschnitt bis 37): den Abschnitt nehmen, in dem du gerade bist.
  -- Sonst rechnet die Route bis Level 37 und schickt dich auf Level 4 mit dem Zeppelin weg
  if sec and pl.secs then
    local Lx = L + ((ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0) / math.max(1, (ns.Plain and ns.Plain(UnitXPMax("player")) or UnitXPMax("player") or 1)))
    if Lx < (sec.from or Lx) - 1.5 or Lx > (sec.to or Lx) + 0.5 then
      for k = 1, #pl.secs do
        if (pl.secs[k].to or 0) > Lx + 0.2 or k == #pl.secs then i = k; break end
      end
      pl.cur = i
      sec = pl.secs[i]
    end
  end
  local target = sec and math.max(L + 1, math.floor((sec.to or (L + PlanStep())) + 0.5)) or (L + PlanStep())
  -- von selbst neu gerechnet (Taschen voll, Upgrade, Abschnitt passt nicht): bist du mitten in einem Questziel,
  -- bleibt es vorne. Sonst springt die Route ohne dein Zutun zu einer anderen Quest (Tester: Skorpide 1/10, dann Medaillon)
  local mode = ModeFor(L)
  if ns.ActiveObjective then mode.keepQ, mode.keepObj = ns.ActiveObjective() end
  local started = ns.Optimize(target, function(opt)
    ns.planLiveTry = 0
    if opt and pl and pl.secs and pl.secs[i] then
      opt.plan = i
      opt.title = (TR"Abschnitt %d von %d (angepasst)"):format(i, #pl.secs)
      pl.secs[i].steps = opt.steps
      pl.secs[i].live = true
      if ns.PlanHistUpdate then pcall(ns.PlanHistUpdate) end
    end
    if ns.RefreshBig then pcall(ns.RefreshBig) end
  end, mode)
  -- nicht gestartet (rechnet schon, keine Position in einer Instanz ...): spaeter nochmal, sonst fehlt der Abschnitt
  if not started then
    ns.planLiveTry = (ns.planLiveTry or 0) + 1
    if ns.planLiveTry <= 20 then C_Timer.After(5, function() if ns.PlanActive() and db.plan60 == pl then ns.PlanSectionLive() end end) end
  end
end

-- Level Pruefung (bei jedem Level up und jedem neuen Schritt): bist du ein ganzes Level voraus oder hinten
-- gegenueber dem geplanten Level an dieser Stelle, wird der Abschnitt ab hier neu gerechnet (Regel 1 von 3:
-- Level voraus oder hinten, Ende einer Tour, Einstellung geaendert). Waehrend einem Grind Schritt nicht
-- (da steigt das Level ja gerade), und hoechstens alle 5 Minuten.
local lvlCheckAt = -999
-- Grind Block nach ns.GRIND_BLOCK_MIN beendet, die XP fehlen aber noch: verlangen die naechsten Quests ein hoeheres
-- Level, waere der Pfeil bei einem Questgeber ohne Quest. Dann den Abschnitt ab deinem Level neu rechnen
-- (hoechstens alle 5 Minuten). Sonst geht es einfach weiter.
local timeUpAt = -999
function ns.GrindTimeUpCheck(wasHint)
  local db = ns.db
  local o = db and db.opt
  if not (o and o.steps and ns.PlanActive and ns.PlanActive()) or busy or ns.planBuilding then return end
  local QDB = ns.QDBAccess and select(1, ns.QDBAccess())
  if not (QDB and QDB.QueryQuestSingle) then return end
  local L = ns.UnitLevel and ns.UnitLevel("player") or UnitLevel("player") or 1
  local i0 = o.idx or 1
  local high
  for i = i0, math.min(#o.steps, i0 + 6) do
    for _, a in ipairs(o.steps[i].acts or {}) do
      if a.k == "A" and a.qid then
        local ok, rl = pcall(QDB.QueryQuestSingle, a.qid, "requiredLevel")
        if ok and tonumber(rl) and tonumber(rl) > L then high = a; break end
      end
    end
    if high then break end
  end
  -- Hinweis "Level fehlt" nach 15 Min beendet: es fehlen Quests, also mit dem neuen Level neu schauen
  if not high and not wasHint then return end
  -- nicht dauernd rechnen (Wunsch: der Plan soll nicht staendig verworfen werden): hoechstens alle 15 Minuten,
  -- hoechstens 2 Mal im gleichen Abschnitt, und nur der Abschnitt, nie der ganze Plan
  local now = GetTime and GetTime() or 0
  if now - timeUpAt < 900 then return end
  local sk = tostring(o.plan or "x")
  ns.timeUpPerSec = ns.timeUpPerSec or {}
  if (ns.timeUpPerSec[sk] or 0) >= 2 then return end
  timeUpAt = now
  ns.timeUpPerSec[sk] = (ns.timeUpPerSec[sk] or 0) + 1
  if ns.TestLog then
    if high then ns.TestLog("RECHNEN", ("Neu rechnen automatisch: Grind Block zu Ende, naechste Quest braucht hoeheres Level (Quest %d, Level %d)"):format(high.qid or 0, L))
    else ns.TestLog("RECHNEN", ("Neu rechnen automatisch: Hinweis Level fehlt nach Grind Block zu Ende (Level %d)"):format(L)) end
  end
  ns.PlanSectionLive()
end
function ns.PlanLevelCheck(why)
  local db = ns.db
  local o = db and db.opt
  if not (ns.PlanActive() and o and o.steps) or busy or ns.planBuilding then return end
  if o.pin or o.backSec or o.mirror or o.tour or ns.OptSpecial(o) then return end
  if ns.groupFollow and o.group then return end
  local st = o.steps[o.idx or 1]
  if not (st and st.lvl) then return end
  for _, a in ipairs(st.acts or {}) do if a.k == "G" then return end end
  local L = ns.UnitLevel and ns.UnitLevel("player") or UnitLevel("player")
  local xp = L + ((ns.Plain and ns.Plain(UnitXP("player")) or 0) / math.max(1, (ns.Plain and ns.Plain(UnitXPMax("player")) or 1)))
  local d = xp - st.lvl
  if math.abs(d) < 1.0 then return end
  -- 17.9: im Dungeon nur merken, draussen wird einmal nachgerechnet (sonst Meldung "wird neu gerechnet" und nichts passiert)
  if ns.InInstance and ns.InInstance() then ns.instPending = true; return end
  local now = GetTime and GetTime() or 0
  if now - lvlCheckAt < 300 then return end
  lvlCheckAt = now
  ns.Print((TR"Du bist ein ganzes Level %s als die Route (Level %.1f statt %.1f). Der Abschnitt wird ab hier neu gerechnet."):format(d > 0 and TR"schneller" or TR"langsamer", xp, st.lvl))
  if ns.TestLog then ns.TestLog("RECHNEN", ("Neu rechnen automatisch: %s (Level %.1f statt %.1f, %s)"):format(d > 0 and "Level voraus" or "Level hinten", xp, st.lvl, tostring(why or "?"))) end
  if ns.RecalcAskClear then ns.RecalcAskClear() end
  ns.PlanSectionLive()
end
ns.PlanCheck = function() ns.PlanLevelCheck("level") end

-- Erledigte Schritte des Fahrplans aufheben, bevor er ersetzt wird (Neu rechnen, neue Version, Plan zu Ende):
-- sie bleiben in "Weg zu 60" als Verlauf stehen. Nur das Noetigste pro Schritt (ohne Fundorte), hoechstens 2500 Schritte.
local function SlimStep(st)
  local acts = {}
  for _, a in ipairs(st.acts or {}) do
    acts[#acts + 1] = { k = a.k, qid = a.qid, quest = a.quest, who = a.who, obj = a.obj, count = a.count, npc = a.npc, toLvl = a.toLvl,
      min = a.min, dest = a.dest, kind = a.kind, buyAt = a.buyAt, trainer = a.trainer, hint = a.hint, dung = a.dung, grp = a.grp, imap = a.imap, ix = a.ix, iy = a.iy,
      recall = a.recall, books = a.books, buy = type(a.buy) == "string" and a.buy or nil, lo = a.lo, hi = a.hi, cls = a.cls, forName = a.forName }
  end
  return { map = st.map, x = st.x, y = st.y, lvl = st.lvl, t = st.t, travel = st.travel, acts = acts }
end
function ns.PlanArchive(allDone)
  local db = ns.db
  local pl = db and db.plan60
  if not (pl and pl.secs and #pl.secs > 0) then return end
  -- Mein Weg schreibt jetzt jeden erledigten Schritt selbst mit: kein Archiv mehr noetig
  if db.myWay and db.myWay.seeded then return 0 end
  local o = db.opt
  local real = (o and o.backSec and pl.ahead) or o
  local curSec, curIdx
  if allDone then
    curSec, curIdx = #pl.secs + 1, 1
  elseif real and real.plan then
    curSec, curIdx = real.plan, (real.pin and real.pinTop) or real.idx or 1
  else
    -- gerade eine andere Route (Berufe, Gold ...): Stand vom Fahrplan, gemerkt beim Wechsel
    curSec, curIdx = pl.cur or 0, pl.curIdx or 1
  end
  -- schon aufgehoben bis hier
  local a0 = pl.archivedTo or { 0, 0 }
  db.planPast = db.planPast or { secs = {} }
  local past = db.planPast.secs
  local added = 0
  for k = math.max(1, a0[1]), math.min(curSec, #pl.secs) do
    local sec = pl.secs[k]
    local steps = (real and real.plan == k and real.steps) or sec.steps or {}
    local from = (k == a0[1]) and (a0[2] + 1) or 1
    local to = (k < curSec) and #steps or (curIdx - 1)
    if to >= from then
      local out = {}
      for i = from, to do if steps[i] then out[#out + 1] = SlimStep(steps[i]) end end
      if #out > 0 then
        past[#past + 1] = { from = out[1].lvl, to = out[#out].lvl, title = sec.title, steps = out, at = time and time() or 0 }
        added = added + #out
      end
    end
  end
  pl.archivedTo = { curSec, curIdx - 1 }
  -- Groesse begrenzen: die aeltesten Abschnitte fallen weg
  local n = 0
  for _, ps in ipairs(past) do n = n + #ps.steps end
  while n > 2500 and #past > 1 do n = n - #past[1].steps; table.remove(past, 1) end
  if added > 0 and ns.TestLog then ns.TestLog("RECHNEN", ("Verlauf: %d erledigte Schritte aufgehoben"):format(added)) end
  return added
end

-- Mein Weg: was du wirklich gemacht hast, Schritt fuer Schritt, in der Reihenfolge, wie du es gemacht hast.
-- "Weg zu 60" zeigt das oben und danach den aktuellen Plan ab deinem jetzigen Schritt. Neu rechnen aendert nur die Zukunft,
-- nichts kommt doppelt: jede Quest wird einmal angenommen, ein Ziel einmal gemacht, einmal abgegeben.
local function ActSig(a)
  return table.concat({ tostring(a.k), tostring(a.qid or ""), tostring(a.obj or ""), tostring(a.dest or a.npc or a.trainer or a.quest or "") }, ":")
end
local function LvlNow()
  local L = UnitLevel("player") or 1
  local xp = (ns.Plain and ns.Plain(UnitXP("player")) or UnitXP("player") or 0)
  local mx = (ns.Plain and ns.Plain(UnitXPMax("player")) or UnitXPMax("player") or 1)
  return L + (tonumber(xp) or 0) / math.max(1, tonumber(mx) or 1)
end
local function WayPut(w, st, L, at, front)
  w.aq, w.tq, w.oq = w.aq or {}, w.tq or {}, w.oq or {}
  local s = SlimStep(st)
  local keep = {}
  for _, a in ipairs(s.acts) do
    local q = a.qid
    if q and q > 0 and a.k == "A" then
      if not w.aq[q] then w.aq[q] = true; keep[#keep + 1] = a end
    elseif q and q > 0 and a.k == "T" then
      if not w.tq[q] then w.tq[q] = true; keep[#keep + 1] = a end
    elseif q and q > 0 and a.k == "O" then
      local key = q .. ":" .. tostring(a.obj)
      if not w.oq[key] and not w.tq[q] then w.oq[key] = true; keep[#keep + 1] = a end
    else
      keep[#keep + 1] = a
    end
  end
  if #keep == 0 then return false end
  s.acts = keep
  -- gleicher Schritt wie direkt davor (zB Laufen, Haendler nach dem Neu rechnen nochmal erkannt): nicht doppelt
  local nb = front and w.steps[1] or w.steps[#w.steps]
  if nb and not front then
    local a1, a2 = {}, {}
    for _, a in ipairs(nb.acts or {}) do a1[#a1 + 1] = ActSig(a) end
    for _, a in ipairs(keep) do a2[#a2 + 1] = ActSig(a) end
    if table.concat(a1, "|") == table.concat(a2, "|") then return false end
  end
  s.L, s.done = L, at
  if front then table.insert(w.steps, front, s) else w.steps[#w.steps + 1] = s end
  return true
end
-- einmal beim Update: alten Verlauf (und erledigte Schritte vom Plan) uebernehmen, aber nur was sich pruefen laesst:
-- Quest angenommen (im Log oder erledigt), abgegeben (erledigt), Ziel gemacht (fertig oder erledigt).
-- Frueher kamen auch uebersprungene Abschnitte als "erledigt" in den Verlauf.
function ns.MyWaySeed()
  local db = ns.db
  if not db or (db.myWay and db.myWay.seeded) then return end
  if not (ns.QDBAccess and ns.QDBAccess() and ns.QuestStatus) then return end
  local old = db.myWay
  local w = { steps = {}, seeded = true }
  local function Try(st, at)
    local ok = false
    local fake = { acts = {} }
    for _, a in ipairs(st.acts or {}) do
      local q = a.qid
      if q and q > 0 and (a.k == "A" or a.k == "T" or a.k == "O") then
        local stt = ns.QuestStatus(q)
        local good = (a.k == "A" and (stt == "done" or stt == "ready" or stt == "log")) or (a.k == "T" and stt == "done")
          or (a.k == "O" and (stt == "done" or stt == "ready"))
        if good then fake.acts[#fake.acts + 1] = a; ok = true end
      end
    end
    if ok then
      fake.map, fake.x, fake.y, fake.lvl, fake.t, fake.travel = st.map, st.x, st.y, st.lvl, st.t, st.travel
      WayPut(w, fake, st.L or st.lvl or 1, st.done or at or 0)
    end
  end
  for _, ps in ipairs(db.planPast and db.planPast.secs or {}) do
    for _, st in ipairs(ps.steps or {}) do Try(st, ps.at) end
  end
  local pl = db.plan60
  local o = db.opt
  local real = (o and o.backSec and pl and pl.ahead) or o
  if pl and pl.secs and real and real.plan then
    local cs, ci = real.plan, (real.pin and real.pinTop) or real.idx or 1
    for k = 1, math.min(cs, #pl.secs) do
      local steps = (real.plan == k and real.steps) or pl.secs[k].steps or {}
      for i, st in ipairs(steps) do if k < cs or i < ci then Try(st) end end
    end
  end
  -- schon live mitgeschrieben (vor dem Uebernehmen): hinten anhaengen
  for _, st in ipairs(old and old.steps or {}) do WayPut(w, st, st.L, st.done) end
  db.myWay = w
  db.planPast = nil
  if ns.TestLog then ns.TestLog("RECHNEN", ("Mein Weg angelegt: %d erledigte Schritte uebernommen"):format(#w.steps)) end
end
function ns.MyWayAdd(st, o)
  local db = ns.db
  if not (db and st and st.acts) then return end
  o = o or db.opt
  -- Berufe, Gold, Ruf, Touren gehoeren nicht zum Weg zu 60
  if o and (o.prof or o.tour or o.farm or o.repFarm or (o.opts and (o.opts.gold or o.opts.rep))) then return end
  if not (db.myWay and db.myWay.seeded) then ns.MyWaySeed() end
  db.myWay = db.myWay or { steps = {} }
  local w = db.myWay
  w.steps = w.steps or {}
  if WayPut(w, st, LvlNow(), time and time() or 0) then
    while #w.steps > 2500 do table.remove(w.steps, 1) end
  end
end

-- Chat: worauf die Berechnung wartet und wann sie ungefaehr startet (einmal pro Grund)
function ns.PlanWaitAnnounce()
  local w = ns.planPending
  if not w or ns.planWaitAnn == w then return end
  ns.planWaitAnn = w
  if w == "addons" then
    ns.Print((TR"Es wird noch geladen. Die Berechnung startet in ca %d Sek."):format(ns.StartGateLeft and ns.StartGateLeft() or 3))
  elseif w == "questie" then
    ns.Print((TR"Questie startet noch. Die Berechnung startet sobald Questie fertig ist, spätestens in %d Sek."):format(ns.QuestieWaitLeft and ns.QuestieWaitLeft() or 90))
  end
end

-- worauf der Fahrplan gerade wartet (fuer den Knopf in der Einrichtung), nil = wartet auf nichts
function ns.PlanWaitText()
  local w = ns.planPending
  if not w or ns.planBuilding or (ns.CalcHold and ns.CalcHold()) then return nil end
  if w == "addons" then return (TR"Wartet, bis alle Addons geladen sind. Die Berechnung startet in ca %d Sek."):format(ns.StartGateLeft and ns.StartGateLeft() or 3) end
  if w == "questie" then return (TR"Wartet, bis Questie fertig gestartet ist. Die Berechnung startet spätestens in %d Sek."):format(ns.QuestieWaitLeft and ns.QuestieWaitLeft() or 90) end
  if w == "ways" then return TR"Wegdaten werden vorbereitet, die Route rechnet gleich danach." end
  if w == "zones" then return TR"Sucht die Zonen aus Questie, die Route rechnet gleich danach." end
  if w == "pos" then return TR"Wartet auf deine Position (Ladebildschirm), dann rechnet die Route." end
end

-- Knopf "Komplett neu berechnen" (Weg zu 60): alles weg wie bei einem neuen Charakter (Plan, Verlauf, Zeiten),
-- dann neu ab deinem jetzigen Stand
function ns.PlanResetAll()
  local db = ns.db
  if not db then return end
  if ns.planBuilding or busy then ns.Print(TR"Die Route rechnet schon."); return end
  db.planPast = nil
  db.planHist = nil
  db.myWay = nil
  db.plan60 = nil
  if db.profiles then db.profiles.level = nil end
  if ns.ProfileOf and ns.ProfileOf(db.opt) == "level" then db.opt = nil end
  ns.zonesFound = nil
  ns.lowGrindWarned = nil
  ns.Print(TR"Weg zu 60 wird komplett neu berechnet, wie bei einem neuen Charakter.")
  ns.CalcGo(TR"komplett neu")
end

-- von Hand: Fahrplan neu (Knopf "Neu rechnen")
function ns.PlanRebuild()
  ns.db.planOn = true
  ns.db.calcWait = false
  ns.PlanBuild(TR"von Hand")
end

------------------------------------------------------------
-- Weg zu 60: alle Schritte vom ganzen Plan, Zeit pro Level und Zone mit plus/minus Verlauf
------------------------------------------------------------
local function ZoneKey(map) return (ns.cityParent and ns.cityParent[map]) or map end

-- geplante Zeit pro Level und Zone merken: schon gespielt (beim Rechnen) plus was der Plan noch vorsieht.
-- Ist ein Level oder eine Zone fertig, steht dort, ob du schneller oder langsamer warst.
function ns.PlanHistUpdate()
  local db = ns.db
  local pl = db and db.plan60
  if not (pl and pl.secs) then return end
  local perf = ns.PerfData and ns.PerfData() or {}
  local lt = perf.lvlTime or {}
  local L0 = UnitLevel("player") or 1
  local lvlRest, zoneRest = {}, {}
  for k = math.max(1, pl.cur or 1), #pl.secs do
    local prevT = 0
    for _, st in ipairs(pl.secs[k].steps or {}) do
      local t = st.t or prevT
      local dt = math.max(0, t - prevT)
      prevT = t
      local lv = math.floor(st.lvl or L0)
      lvlRest[lv] = (lvlRest[lv] or 0) + dt
      if st.map then local z = ZoneKey(st.map); zoneRest[z] = (zoneRest[z] or 0) + dt end
    end
  end
  db.planHist = db.planHist or { lvl = {}, zone = {} }
  local H = db.planHist
  H.lvl, H.zone = H.lvl or {}, H.zone or {}
  for lv, sec in pairs(lvlRest) do
    if lv == L0 then H.lvl[lv] = (lt[lv] or 0) + sec
    elseif lv > L0 then H.lvl[lv] = sec end
  end
  local zst = perf.zones or {}
  for z, sec in pairs(zoneRest) do
    local zs = zst[z]
    H.zone[z] = ((zs and zs.t) or 0) + sec
  end
  H.rest = zoneRest
end

local function Clk(s)
  s = math.floor((s or 0) + 0.5)
  if s >= 3600 then return (TR"%d:%02d Std"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
  return (TR"%d Min"):format(math.max(1, math.floor(s / 60 + 0.5)))
end
-- plus/minus gegen den Plan: plus (rot) = laenger gebraucht, minus (gruen) = schneller
local function Diff(actual, plan)
  if not (actual and plan and plan > 0) then return "" end
  local d = actual - plan
  if math.abs(d) < 60 then return "|cff9d9d9d" .. TR"wie geplant" .. "|r" end
  return d > 0 and ("|cffff6060+" .. Clk(d) .. "|r") or ("|cff40ff40-" .. Clk(-d) .. "|r")
end
ns.PlanDiffText = Diff
ns.PlanClock = Clk

-- Zeilen fuer die Liste: Level Kopf (mit Zeit) und Schritte (Abschnitt, Nummer, erledigt, jetzt)
local rowsCache = { key = nil }
-- 20.4a5 Verlauf (K 17:44, 17:46, K 20:05 b): fertige Level als grauer Kopf mit Zeitstempel, Klick klappt die Schritte
-- auf. Ab Max Level nur noch abgegebene Quests, nach Monaten, jeder Monat klappbar. Auf/zu gilt fuer die Sitzung.
local wayOpen, wayOpenVer = {}, 0
function ns.WayToggle(key, open)
  if not key then return end
  if open == nil then open = not wayOpen[key] end
  wayOpen[key] = open and true or false
  wayOpenVer = wayOpenVer + 1
end
local MONTHS = { "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" }
local function MonthName(m) return TR(MONTHS[m] or "?") end
local function DateText(t, withDay)
  if not (t and t > 0 and date) then return nil end
  return date(withDay and "%d.%m. %H:%M" or "%H:%M", t)
end
local function HasTurnIn(st)
  for _, a in ipairs(st.acts or {}) do if a.k == "T" then return true end end
  return false
end
function ns.PlanRows()
  local db = ns.db
  if not db then return {} end
  local pl = db.plan60
  local o = db.opt
  local real = (o and o.backSec and pl and pl.ahead) or o
  local curSec = real and real.plan
  local curIdx = real and ((real.pin and real.pinTop) or real.idx) or 1
  -- gerade eine andere Route (Berufe, Gold ...): Stand vom Fahrplan, gemerkt beim Wechsel
  if not curSec and pl then curSec, curIdx = pl.cur, pl.curIdx or 1 end
  local L0 = UnitLevel("player") or 1
  if not (db.myWay and db.myWay.seeded) and ns.MyWaySeed then pcall(ns.MyWaySeed) end
  local way = db.myWay and db.myWay.steps or {}
  local pastN = #way
  local key = tostring(pl) .. ":" .. tostring(pl and pl.built) .. ":" .. tostring(pl and #(pl.secs or {})) .. ":" .. tostring(curSec) .. ":" .. curIdx .. ":" .. L0
    .. ":" .. tostring(real and real.steps) .. ":" .. pastN .. ":" .. wayOpenVer
  if rowsCache.key == key then return rowsCache.rows end
  local rows = {}
  local H = db.planHist or { lvl = {}, zone = {} }
  local perf = ns.PerfData and ns.PerfData() or {}
  local lt = perf.lvlTime or {}
  local heads = {}
  -- geplant immer ab Level 1: gespielte Level mit der echten Zeit, ab jetzt mit dem Plan (bei 59 steht dann ca 150 Std)
  local cum, sum = {}, 0
  for lv = 1, 59 do
    local t
    if lv < L0 then t = (lt[lv] and lt[lv] > 0) and lt[lv] or (H.lvl and H.lvl[lv]) or 0
    elseif lv == L0 then t = math.max(lt[lv] or 0, (H.lvl and H.lvl[lv]) or 0)
    else t = (H.lvl and H.lvl[lv]) or 0 end
    sum = sum + t
    cum[lv] = sum
  end
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  -- erste und letzte Zeit je Level aus dem Verlauf (falls kein Level Zeitstempel da ist, aeltere Charaktere)
  local wayT0, wayT1 = {}, {}
  for _, st in ipairs(way) do
    local lv = math.floor(st.L or st.lvl or 1)
    local t = st.done
    if t and t > 0 then
      if not wayT0[lv] or t < wayT0[lv] then wayT0[lv] = t end
      if not wayT1[lv] or t > wayT1[lv] then wayT1[lv] = t end
    end
  end
  local function Head(lv, isHist)
    if heads[lv] then return end
    heads[lv] = true
    local plan, act = H.lvl and H.lvl[lv], lt[lv]
    local right
    if lv < L0 then
      -- 20.4a5: fertiges Level, zugeklappt: Zeitstempel, Dauer, Quests, Mobs zusammengefasst
      local ls = perf.lvl and perf.lvl[lv] or {}
      local cnt, src = ls.cnt or {}, ls.src or {}
      local t0 = ls.at or wayT0[lv]
      local t1 = ls.upAt or wayT1[lv]
      local parts = {}
      local d0 = DateText(t0, true)
      if d0 then
        local sameDay = t1 and date and date("%d.%m.", t0) == date("%d.%m.", t1)
        parts[#parts + 1] = t1 and (d0 .. TR" bis " .. (DateText(t1, not sameDay) or "")) or d0
      end
      if act and act > 0 then parts[#parts + 1] = Clk(act) end
      local sum = {}
      if (cnt.quest or 0) > 0 then sum[#sum + 1] = (TR"%d Quests"):format(cnt.quest) end
      if (cnt.kill or 0) > 0 then sum[#sum + 1] = (TR"ca %d Mobs, %s XP aus Mobs"):format(cnt.kill, ns.Num and ns.Num(src.kill or 0) or tostring(src.kill or 0)) end
      local open = wayOpen["L" .. lv] and true or false
      rows[#rows + 1] = { head = true, lv = lv, fold = "L" .. lv, open = open, done = true,
        text = (open and "- " or "+ ") .. (TR"Level %d"):format(lv), right = table.concat(parts, ", "), sum = table.concat(sum, ", "),
        t0 = t0, t1 = t1, dur = act, dim = true }
      return
    end
    if lv < L0 then
      right = act and act > 0 and (TR"gebraucht %s"):format(Clk(act)) or ""
    elseif lv == L0 then
      right = (TR"jetzt, bisher %s"):format(Clk(act or 0)) .. ((cum[lv] or 0) > 0 and ((TR", geplant gesamt ca %s"):format(Clk(cum[lv]))) or "")
    else
      right = (plan and (cum[lv] or 0) > 0) and (TR"geplant gesamt ca %s"):format(Clk(cum[lv])) or ""
    end
    rows[#rows + 1] = { head = true, lv = lv, text = (TR"Level %d"):format(lv), right = right, dim = lv < L0 }
  end
  local num = 0
  -- Mein Weg: was du wirklich gemacht hast, auf dem Level, auf dem du es gemacht hast
  -- 20.4a5: fertige Level zugeklappt (nur der Kopf), Max Level nach Monaten (nur abgegebene Quests)
  local months, monthN = {}, {}
  for i, st in ipairs(way) do
    local lv = math.floor(st.L or st.lvl or 1)
    num = num + 1
    if lv >= maxL then
      if HasTurnIn(st) then
        local ym = (st.done and st.done > 0 and date) and date("%Y%m", st.done) or "0"
        if not monthN[ym] then monthN[ym] = 0; months[#months + 1] = ym end
        monthN[ym] = monthN[ym] + 1
      end
    else
      Head(lv)
      if lv >= L0 or wayOpen["L" .. lv] then
        rows[#rows + 1] = { sec = "w", i = i, num = num, st = st, done = true, past = true }
      end
    end
  end
  -- Nach Max Level: je Monat ein Kopf, der laufende Monat offen
  if #months > 0 then
    local nowYm = date and date("%Y%m") or ""
    local byMonth = {}
    for i, st in ipairs(way) do
      if math.floor(st.L or st.lvl or 1) >= maxL and HasTurnIn(st) then
        local ym = (st.done and st.done > 0 and date) and date("%Y%m", st.done) or "0"
        byMonth[ym] = byMonth[ym] or {}
        table.insert(byMonth[ym], i)
      end
    end
    for _, ym in ipairs(months) do
      local key = "M" .. ym
      local open = wayOpen[key]
      if open == nil then open = (ym == nowYm) end
      local y, m = tonumber(ym:sub(1, 4)), tonumber(ym:sub(5, 6))
      local title = (y and m) and (MonthName(m) .. " " .. y) or TR"ohne Datum"
      rows[#rows + 1] = { head = true, fold = key, open = open, done = true, dim = ym ~= nowYm,
        text = (open and "- " or "+ ") .. title, right = (TR"%d Quests abgegeben"):format(monthN[ym]) }
      if open then
        for _, i in ipairs(byMonth[ym]) do
          local st = way[i]
          rows[#rows + 1] = { sec = "w", i = i, num = "", pre = (st.done and st.done > 0 and date) and date("%d.%m.%y", st.done) or nil, st = st, done = true, past = true, month = true }
        end
      end
    end
  end
  -- Level, die du schon hinter dir hast (auch ohne Schritte im Verlauf)
  for lv = 1, L0 - 1 do if (lt[lv] or 0) > 0 then Head(lv, true) end end
  -- laufende Level Route ohne Fahrplan Abschnitt (zB von selbst neu gerechnet): genau die Schritte vom Mini Fenster
  local loose = o and not o.plan and o.steps and not (ns.OptSpecial and ns.OptSpecial(o)) and not o.backSec
  if loose then
    for i = o.idx or 1, #o.steps do
      local st = o.steps[i]
      num = num + 1
      Head(math.floor(st.lvl or L0))
      rows[#rows + 1] = { sec = "o", i = i, num = num, st = st, cur = (i == (o.idx or 1)) }
    end
    curSec = (pl and pl.cur or 0) + 1
    curIdx = 1
  end
  -- danach nur noch die Zukunft: der Plan ab deinem jetzigen Schritt (was davor liegt, steht oben oder wurde ausgelassen)
  for k, sec in ipairs(pl and pl.secs or {}) do
    if not curSec or k >= curSec then
      -- der laufende Abschnitt kann live neu gerechnet sein: dann die Schritte von dort
      local steps = (real and real.plan == k and real.steps) or sec.steps or {}
      for i, st in ipairs(steps) do
        if not (curSec and k == curSec and i < curIdx) then
          num = num + 1
          Head(math.floor(st.lvl or L0))
          rows[#rows + 1] = { sec = k, i = i, num = num, st = st, cur = (not loose) and (k == curSec and i == curIdx) or nil }
        end
      end
    end
  end
  rowsCache.key, rowsCache.rows = key, rows
  return rows
end

-- Zonen: geplant gesamt, bisher gespielt, plus/minus wenn fertig (kein Schritt mehr dort)
function ns.PlanZoneRows()
  local db = ns.db
  local H = db and db.planHist or {}
  local out = {}
  local cur = ns.CurZone and ns.CurZone()
  local perf = ns.PerfData and ns.PerfData() or {}
  local zst = perf.zones or {}
  for z, plan in pairs(H.zone or {}) do
    local zs = zst[z]
    local act = zs and zs.t or 0
    local rest = H.rest and H.rest[z] or 0
    local fin = rest < 1 and z ~= cur and act > 0
    out[#out + 1] = { map = z, name = ns.ZoneName and ns.ZoneName(z) or tostring(z), plan = plan, act = act, fin = fin,
      text = fin and (TR"gebraucht %s"):format(Clk(act))
        or (act < 30 and (TR"noch nicht dort, geplant ca %s"):format(Clk(plan)) or (TR"bisher %s, geplant ca %s"):format(Clk(act), Clk(plan))),
      order = fin and 0 or 1 }
  end
  table.sort(out, function(a, b) if a.order ~= b.order then return a.order > b.order end return a.plan > b.plan end)
  return out
end

-- Pfeil zu einem Schritt aus dem ganzen Plan: im laufenden Abschnitt wie "Meine Route",
-- sonst den Abschnitt ansehen (wie zurueck blaettern, nach 5 Minuten oder mit Weiter wieder zurueck)
function ns.PlanJump(k, i)
  local db = ns.db
  -- Schritt aus dem Verlauf (frueherer Plan): nur der Pfeil zeigt dorthin, die Route bleibt
  if type(k) == "string" then
    local st
    if k == "o" then
      local o = db and db.opt
      if o and o.steps and o.steps[i] then
        local top = (o.pin and o.pinTop) or o.idx or 1
        if i < top then o.pinTop = math.max(o.pinTop or 0, top); o.pin, o.pinAt = true, time and time() or 0
        else o.pin, o.pinTop, o.pinAt = nil, nil, nil end
        o.idx = i
        ns.Print(TR"Pfeil zeigt jetzt zu: " .. ns.OptStepText(o.steps[i]))
        if ns.Draw then ns.Draw() end
      end
      return
    end
    if k == "w" then st = db and db.myWay and db.myWay.steps and db.myWay.steps[i]
    elseif k:sub(1, 1) == "p" then
      local ps = db and db.planPast and db.planPast.secs[tonumber(k:sub(2)) or 0]
      st = ps and ps.steps[i]
    end
    if not st then return end
    local ok, txt = pcall(ns.OptStepText, st)
    ns.serviceTarget = { map = st.map, x = st.x, y = st.y, name = ok and txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") or "?", kind = "past" }
    ns.Print(TR"Pfeil zeigt jetzt zu: " .. (ok and txt or "?"))
    if ns.Draw then ns.Draw() end
    return
  end
  local pl = db and db.plan60
  if not (pl and pl.secs and pl.secs[k]) then return end
  local o = db.opt
  local real = (o and o.backSec and pl.ahead) or o
  local now = time and time() or 0
  if real and real.plan == k then
    if o ~= real then db.opt = real; pl.ahead = nil; o = real end
    local top = (o.pin and o.pinTop) or o.idx or 1
    -- zurueck: gemerkt, nach 5 Minuten oder mit Weiter geht es dort weiter; vor: wie Ueberspringen
    if i < top then o.pinTop = math.max(o.pinTop or 0, top); o.pin, o.pinAt = true, now
    else o.pin, o.pinTop, o.pinAt = nil, nil, nil end
    o.idx = i
  else
    local sec = pl.secs[k]
    if not (o and o.backSec) then pl.ahead = o end
    db.opt = { steps = sec.steps, idx = i, created = (real and real.created) or now, from = sec.from, to = sec.to,
      target = math.floor((sec.to or 0) + 0.5), quests = sec.quests or 0, sec = sec.sec or 0, xp = sec.xp or 0, rate = sec.rate or 0,
      title = (TR"Abschnitt %d von %d"):format(k, #pl.secs), opts = sec.opts, plan = k,
      pin = true, pinTop = #sec.steps + 1, pinAt = now, backSec = true }
  end
  db.optMode = true
  local st = db.opt.steps[db.opt.idx]
  if st then ns.Print(TR"Pfeil zeigt jetzt zu: " .. ns.OptStepText(st)) end
  if ns.Draw then ns.Draw() end
end

------------------------------------------------------------
-- Routen Profile: die Leveling Route (immer, solange du nicht 60 bist) und hoechstens ein zusaetzliches Profil
-- (Tour oder Farm Route: Berufe, Gold, Ruf, Buecher, Dungeon, Flugpunkte, Entdecken, Questlog, Stunden Budget,
-- Ausruestung, geladene Route). Im Mini Fenster wechselst du zwischen den beiden, keins verliert seinen Stand.
-- Ist das Profil fertig oder wird es beendet, verschwindet es und es geht mit der Leveling Route weiter.
------------------------------------------------------------
ns.PROFILES = {
  { key = "level", name = TR"Leveling Route" },
  { key = "extra", name = TR"Tour" },
}
-- Profil einer Route: "level", "extra" oder nil (Gruppen Route vom Leiter, Dungeon Aufteilung: eigenes Parken)
function ns.ProfileOf(o)
  if not o then return nil end
  if o.mirror or o.group or o.split then return nil end
  if o.prof or o.farm or o.repFarm or o.tour or o.dungeonRoute or o.loaded or o.extra
    or (o.opts and (o.opts.gold or o.opts.rep or o.opts.logOnly or o.opts.gearQ or o.opts.endInn)) then return "extra" end
  return "level"
end
local function RouteOpen(o) return o and o.steps and #o.steps > 0 and (o.idx or 1) <= #o.steps end
-- Name vom zusaetzlichen Profil (laufend oder gemerkt), nil wenn es keins gibt
function ns.ProfileExtraName()
  local db = ns.db
  if not db then return nil end
  local o = db.opt
  if ns.ProfileOf(o) == "extra" and RouteOpen(o) then return o.title or TR"Tour" end
  local p = db.profiles and db.profiles.extra
  if p and RouteOpen(p.opt) then return p.opt.title or TR"Tour" end
end
function ns.ProfileCur() return ns.ProfileOf(ns.db and ns.db.opt) end
-- laufende Route in ihrem Profil merken (vor dem Wechsel, oder wenn eine andere Route sie ersetzt)
function ns.ProfileSave()
  local db = ns.db
  local o = db and db.opt
  -- zurueck geblaettert: erst wieder zum echten Schritt
  if o and (o.pin or o.backSec) and ns.OptUnpin then ns.OptUnpin(); o = db.opt end
  local k = ns.ProfileOf(o)
  if not (k and RouteOpen(o)) then return end
  db.profiles = db.profiles or {}
  local p = { opt = o, at = time and time() or 0, L = UnitLevel("player") }
  if o.prof then p.sess = db.profSess end
  if o.repFarm or (o.opts and o.opts.rep) then p.rep = ns.repFarm end
  if o.farm then p.farm = ns.farmSess end
  if k == "level" and db.plan60 and o.plan then db.plan60.cur = o.plan; db.plan60.curIdx = o.idx end
  db.profiles[k] = p
end
-- eine neue Tour oder Farm Route startet: Leveling Route merken, ein altes zusaetzliches Profil ist damit beendet
function ns.ProfileBeforeExtra(title)
  local db = ns.db
  if not db then return end
  local k = ns.ProfileOf(db.opt)
  if k == "level" then ns.ProfileSave()
  elseif k == "extra" and RouteOpen(db.opt) then
    -- 20.3l (S Punkt 25): die laufende Zusatz Route nicht wegwerfen, sondern unter ihrem Namen merken. Startest du sie
    -- spaeter wieder (gleicher Name), geht sie mit Fortschritt weiter statt neu gerechnet (ns.OptLoad)
    ns.ProfileStash(db.opt)
    if ns.TestLog then ns.TestLog("PROFIL", "gemerkt (neues Profil): " .. tostring(db.opt.title)) end
  end
  if db.profiles then db.profiles.extra = nil end
  if ns.TestLog then ns.TestLog("PROFIL", "Start: " .. tostring(title or "?")) end
end
-- 20.3l (S Punkt 25): gemerkte Zusatz Routen nach Namen (Dungeon, Ruf, Gold, Beruf, Ausruestung ...), hoechstens 8
local STASH_MAX = 8
-- 20.3o (Da Pruefung Nr 11): Schluessel Titel plus Karte und Lage des letzten Schritts (grob), sonst laedt eine andere
-- Route mit gleichem Titel (Gold farmen anderes Gebiet, Dungeon neu gerechnet) die alte Liste
local function StashKey(title, steps)
  local last = steps and steps[#steps]
  if not (title and last and last.map) then return title end
  return ("%s|%d|%d|%d|%d"):format(title, last.map, math.floor((last.x or 0) * 20), math.floor((last.y or 0) * 20), #steps)
end
ns.ProfileStashKey = StashKey
function ns.ProfileStash(o)
  local db = ns.db
  if not (db and o and o.title and RouteOpen(o)) then return end
  db.profiles = db.profiles or {}
  local st = db.profiles.stash or {}
  db.profiles.stash = st
  local p = { opt = o, at = time and time() or 0, L = UnitLevel("player") }
  if o.prof then p.sess = db.profSess end
  st[StashKey(o.title, o.steps)] = p
  -- zu viele: die aelteste weg
  local n, oldK, oldAt = 0, nil, math.huge
  for k, v in pairs(st) do n = n + 1; if (v.at or 0) < oldAt then oldK, oldAt = k, v.at or 0 end end
  if n > STASH_MAX and oldK then st[oldK] = nil end
end
-- gemerkte Zusatz Route mit diesem Namen, wenn sie noch offen ist und du nicht weit weg bist (sonst nil: neu rechnen)
function ns.ProfileStashGet(title, steps)
  local db = ns.db
  local st = db and db.profiles and db.profiles.stash
  local key = title and StashKey(title, steps)
  local p = st and key and st[key]
  if not p then return nil end
  st[key] = nil
  if not RouteOpen(p.opt) then return nil end
  -- aelter als 12 Stunden oder Level seither gestiegen: neu
  if (time and time() or 0) - (p.at or 0) > 12 * 3600 or (UnitLevel("player") or 0) > (p.L or 0) then return nil end
  local s = p.opt.steps[p.opt.idx or 1]
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not (s and s.map and pos) then return nil end
  local px, py = pos:GetXY()
  local d = ns.WorldDist and ns.WorldDist({ map, px, py }, { s.map, s.x, s.y })
  -- anderer Kontinent (d nil) oder weit weg vom gemerkten Stand: der Ausgangspunkt hat sich stark geaendert
  if not d or d > 3000 then
    if ns.TestLog then ns.TestLog("PROFIL", ("gemerkt, aber weit weg (%s yd): neu gerechnet: %s"):format(d and tostring(math.floor(d)) or "anderer Kontinent", tostring(title))) end
    return nil
  end
  return p
end
-- 20.1 (P7): neue Leveling Route, waehrend eine Zusatz Route laeuft: ins Level Profil statt die Zusatz Route ersetzen.
-- true, wenn sie dort gemerkt wurde
function ns.ProfileParkLevel(o)
  local db = ns.db
  if not (db and o) or ns.profResuming then return false end
  local cur = db.opt
  if cur == o or ns.ProfileOf(cur) ~= "extra" or not RouteOpen(cur) then return false end
  if ns.ProfileOf(o) ~= "level" then return false end
  db.profiles = db.profiles or {}
  db.profiles.level = { opt = o, at = time and time() or 0, L = UnitLevel("player") }
  if db.plan60 and o.plan then db.plan60.cur = o.plan; db.plan60.curIdx = o.idx end
  if ns.TestLog then ns.TestLog("PROFIL", ("Leveling Route im Hintergrund neu (%d Schritte), weiter mit: %s"):format(#(o.steps or {}), tostring(cur.title))) end
  return true
end
-- gemerkte Route eines Profils wieder laden (true, wenn es eine gab)
function ns.ProfileResume(k)
  ns.profResuming = true
  local okc, r = pcall(ns.ProfileResumeDo, k)
  ns.profResuming = false
  if not okc then error(r, 0) end
  return r
end
function ns.ProfileResumeDo(k)
  local db = ns.db
  local p = db and db.profiles and db.profiles[k]
  -- Gold Quests: Karte und Pfeil zeigen die Gold Route nur, solange sie das laufende Profil ist
  if db then
    local po = p and p.opt
    db.goldMode = (k == "extra" and po and (po.gold or (po.opts and po.opts.gold))) and true or false
  end
  if not (p and RouteOpen(p.opt)) then
    if k == "level" and ns.PlanReload and ns.PlanReload() then return true end
    return false
  end
  db.profiles[k] = nil
  if k == "level" then
    -- Abschnitt nicht mehr im Plan, oder Plan seither neu gerechnet: den aktuellen Abschnitt vom Plan laden
    local stale = (p.opt.plan and not (db.plan60 and db.plan60.secs and db.plan60.secs[p.opt.plan]))
      or (db.plan60 and (db.plan60.built or 0) > (p.at or 0))
    if stale then return ns.PlanReload and ns.PlanReload() or false end
  end
  db.opt = p.opt
  db.optMode = true
  local away = math.max(0, (time and time() or 0) - (p.at or 0))
  if p.sess then p.sess.t0 = (p.sess.t0 or 0) + away; db.profSess = p.sess end
  if p.rep then ns.repFarm = p.rep end
  if p.farm then ns.farmSess = p.farm end
  db.profileCur = k
  ns.Print((TR"%s: weiter, wo du warst (Schritt %d von %d)."):format(k == "level" and TR"Leveling Route" or (p.opt.title or TR"Tour"), p.opt.idx or 1, #p.opt.steps))
  if ns.TestLog then ns.TestLog("PROFIL", ("zurueck zu %s, Schritt %d von %d, Level %d (beim Wechsel %d)"):format(k == "level" and "Leveling Route" or tostring(p.opt.title), p.opt.idx or 1, #p.opt.steps, UnitLevel("player") or 0, p.L or 0)) end
  if ns.OptSync then ns.OptSync() end
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
  return true
end
-- Wechsel im Mini Fenster: jetzige Route merken, die andere laden. Nichts wird neu gerechnet.
function ns.ProfileSwitch(k)
  local db = ns.db
  if not db then return end
  if k ~= "level" and k ~= "extra" then k = (k == "prof" or k == "gold" or k == "rep") and "extra" or "level" end
  local cur = ns.ProfileOf(db.opt)
  if cur == k then return end
  if k == "extra" and not (db.profiles and db.profiles.extra and RouteOpen(db.profiles.extra.opt)) then
    ns.Print(TR"Es läuft gerade keine Tour oder Farm Route.")
    return
  end
  ns.ProfileSave()
  if ns.TestLog then ns.TestLog("PROFIL", "Wechsel zu " .. k) end
  if ns.ProfileResume(k) then return end
  -- Leveling Route ohne Stand (zb nach Level 60 oder ganz neu): normal rechnen
  if k == "level" then
    db.opt = nil
    ns.farmSess = nil
    ns.repFarm = nil
    db.profileCur = "level"
    -- 20.1 (P7): noch nicht berechnet ("Später" gewaehlt): AutoOpt tat dann nichts, es lief gar keine Route
    local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    if (UnitLevel("player") or 1) >= maxL then
      -- 20.3z3 (S Test 20.3z2 Z1, "wird die route nicht berechnet?"): auf Max Level ist die Leveling Route die Nach 60 Route
      -- (alle offenen Quests), statt leer zu bleiben
      if ns.RestQuestsRoute then C_Timer.After(0.2, ns.RestQuestsRoute) elseif ns.Draw then ns.Draw() end
    elseif ns.CalcHold and ns.CalcHold() and ns.CalcGo then ns.CalcGo(TR"Leveling Route")
    elseif ns.AutoOpt then ns.AutoOpt(true) end
  end
end
-- eine Tour oder Farm Route ist fertig oder gestoppt: zusaetzliches Profil weg, zurueck zur Leveling Route.
-- Ende einer Tour ist eine Regel fuer Neu rechnen: der Abschnitt wird ab hier neu gerechnet (du bist woanders).
function ns.ProfileBackToLevel(finished)
  local db = ns.db
  if db and db.profiles then db.profiles.extra = nil end
  if ns.TestLog then ns.TestLog("PROFIL", (finished and "fertig: " or "beendet: ") .. tostring(db and db.opt and db.opt.title)) end
  local ok = ns.ProfileResume and ns.ProfileResume("level")
  if ok and ns.PlanActive and ns.PlanActive() and ns.PlanSectionLive and not (ns.groupFollow and db.opt and db.opt.group) then
    if ns.TestLog then ns.TestLog("RECHNEN", "Neu rechnen automatisch: Ende Tour") end
    C_Timer.After(1, function() if ns.ProfileOf(ns.db and ns.db.opt) == "level" then ns.PlanSectionLive() end end)
    return
  end
  -- 20.3o (Log 20.3m M2): auf Max Level nach "Tour beenden" nicht von selbst alle Quests der Welt rechnen (dauert,
  -- und eine neue Zusatz Route wartete dann auf "rechnet schon"). Hinweis auf den Knopf "Alle übrigen Quests"
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if not ok and (UnitLevel("player") or 1) >= maxL then
    if db then db.opt = nil end
    -- 20.3z3 (Z1): nach Tour Ende auf Max Level gleich die Nach 60 Route (eine neue Zusatz Route bricht sie ab, 20.3o)
    if ns.RestQuestsRoute then C_Timer.After(0.5, ns.RestQuestsRoute) elseif ns.Draw then ns.Draw() end
    return
  end
  if not ok and ns.AutoOpt then
    if db then db.opt = nil end
    if ns.CalcHold and ns.CalcHold() then
      ns.Print(TR"Die Leveling Route ist noch nicht berechnet: im Mini Fenster Menü auf Neu rechnen.")
    end
    ns.AutoOpt(true)
  end
end
-- 1.1 (S Log L14.5: Ruhestein benutzt, Plan blieb alt, auch bei Neu rechnen): die laufende Route ab hier neu.
-- Dungeon oder Zugang Route: neu aus den Dungeon Daten (gleicher Dungeon). Leveling Route mit Fahrplan: der Abschnitt.
-- Rueckgabe true, wenn neu gerechnet wurde
function ns.RedoCurrentRoute(why)
  local db = ns.db
  local o = db and db.opt
  if not o then return false end
  if ns.TestLog then ns.TestLog("RECHNEN", "Route ab hier neu: " .. tostring(why)) end
  if o.dungeonRoute then
    local name = o.dungeonName
    if not (name and ns.DungeonRoute) then return false end
    for _, d in ipairs(ns.dungeons or {}) do
      if d.name == name then
        local steps, info = ns.DungeonRoute(d)
        if not steps then return false end
        info.dungeonRoute = true
        ns.OptLoad(steps, info)
        ns.db.opt.dungeonRoute, ns.db.opt.dungeonName = true, name
        ns.Print((TR"Route %s ab hier neu gerechnet."):format(tostring(info.title or name)))
        return true
      end
    end
    return false
  end
  if ns.ProfileOf(o) == "level" and ns.PlanActive and ns.PlanActive() and ns.PlanSectionLive then
    ns.PlanSectionLive()
    return true
  end
  return false
end
-- 1.1 (K Stufe B 14): Dungeon Route nachfuehren. Nach jedem Schritt und sonst alle DUNG_EVERY_S Sekunden aus den Daten
-- neu bauen, was noch fehlt; nur laden, wenn sich etwas geaendert hat (andere Quests oder Reihenfolge)
V11.DUNG_EVERY_S = 20
function V11.DungSig(steps, from)
  local t = {}
  for i = from or 1, #(steps or {}) do
    -- Reise Schritte zaehlen nicht (die haengen nur davon ab, wo du gerade stehst)
    for _, a in ipairs(steps[i].acts or {}) do if a.k ~= "R" then t[#t + 1] = tostring(a.k) .. (a.qid or a.quest or "") end end
  end
  return table.concat(t, ",")
end
V11.dungAt, V11.dungIdx = 0, nil
function V11.DungTick()
  local db = ns.db
  local o = db and db.opt
  if not (o and o.dungeonRoute and o.dungeonName and o.steps and ns.DungeonRoute) or db.paused then V11.dungIdx = nil; return end
  if ns.InInstance and ns.InInstance() then return end
  local now = GetTime()
  local idx = o.idx or 1
  if V11.dungIdx == idx and now - V11.dungAt < V11.DUNG_EVERY_S then return end
  V11.dungIdx, V11.dungAt = idx, now
  if idx > #o.steps then return end
  for _, d in ipairs(ns.dungeons or {}) do
    if d.name == o.dungeonName then
      local ok, steps, info = pcall(ns.DungeonRoute, d)
      if ok and steps and #steps > 0 and V11.DungSig(steps, 1) ~= V11.DungSig(o.steps, idx) then
        info.dungeonRoute = true
        ns.OptLoad(steps, info)
        ns.db.opt.dungeonRoute, ns.db.opt.dungeonName = true, d.name
        V11.dungIdx = 1
        if ns.TestLog then ns.TestLog("RECHNEN", ("Dungeon Route nachgefuehrt: %s, %d Schritte"):format(d.name, #steps)) end
      end
      return
    end
  end
end
if ns.Ticker then ns.Ticker(1, function() pcall(V11.DungTick) end) end
-- nach dem Ruhestein (oder Rueckruf): ist der aktuelle Schritt weit weg, die Route ab hier neu, sonst nur Live pruefen
V11.HEARTH_REDO_YD = 400
function ns.AfterHearth()
  local db = ns.db
  local o = db and db.opt
  if not (o and o.steps) then return end
  local s = o.steps[o.idx or 1]
  if not s then return end
  -- der Schritt war der Ruhestein selbst: der wird von allein fertig
  for _, a in ipairs(s.acts or {}) do if a.k == "H" or a.k == "B" then return end end
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
  local d
  if pos and s.map and s.x and ns.WorldDistXY then
    local px, py = pos:GetXY()
    d = ns.WorldDistXY(pm, px, py, s.map, s.x, s.y)
  end
  if d == nil or d > V11.HEARTH_REDO_YD then
    if not ns.RedoCurrentRoute("Ruhestein") and ns.LiveFire then pcall(ns.LiveFire, "ruhestein") end
  elseif ns.LiveFire then
    pcall(ns.LiveFire, "ruhestein")
  end
end
-- alte Profile (Berufe, Gold, Ruf einzeln) auf das eine zusaetzliche Profil: das zuletzt benutzte bleibt
function ns.ProfileMigrate(db)
  local pr = db and db.profiles
  if not pr then return end
  local best
  for _, k in ipairs({ "prof", "gold", "rep" }) do
    local p = pr[k]
    if p and RouteOpen(p.opt) and (not best or (p.at or 0) > (best.at or 0)) then best = p end
    pr[k] = nil
  end
  if best and not pr.extra then pr.extra = best end
end

------------------------------------------------------------
-- 20.4a3 Live Nachrechnen (K 17:40 Plan, K 19:33 GO, Absprache absprache\live_nachrechnen.md mit Na)
-- Na prueft in Arrow.lua alle 10 s und ruft bei einem Ausloeser ns.LiveReplan(reason, ctx). Hier wird nur gerechnet:
--  B: die naechsten 2 bis 5 Schritte ab deiner echten Position neu ordnen (Quest Reihenfolge bleibt: Annehmen vor
--     Ziel vor Abgeben, alles was dieselbe Quest betrifft behaelt seine Reihenfolge)
--  C: Ziel fast fertig: die Stelle des Questziels nehmen, die auf dem Weg zum naechsten Schritt liegt
--  D: ns.LiveChance: Quest annehmen, die spaeter in der Route kommt und gerade nah am Weg ist
-- Die Hysterese (lohnt es sich, 30 s oder 10 Prozent) und das Mini Fenster sind bei Na. Schalter db.liveCalc = false.
------------------------------------------------------------
local LIVE_WIN_MIN = 2          -- so viele Schritte muessen mindestens umstellbar sein
-- 1.1 (K Stufe B 13): Fenster bis 10 Schritte (vorher 5), nur Schritte nahe bei dir, gerechnet in Stuecken ueber mehrere
-- Bilder (ns.LiveReplanAsync). Pr misst 5 gegen 10 ueber LIVE_WIN_MAX
local LIVE_WIN_MAX = 10         -- hoechstens so viele Schritte ab dem aktuellen
-- v11e (P29): offene Ziele einer Quest vor ihre Abgabe holen, wenn sie im Log nicht fertig ist
function V11.ReopenObjectives(opt, i)
  local s = opt.steps[i]
  if not (s and ns.logProgress) then return end
  for _, a in ipairs(s.acts or {}) do
    local lp = a.k == "T" and a.qid and ns.logProgress[a.qid]
    if lp and not lp.complete then
      local later = false
      for j = i, #opt.steps do
        for _, b in ipairs(opt.steps[j].acts or {}) do
          if b.k == "O" and b.qid == a.qid and not ActDone(b) then later = true; break end
        end
        if later or opt.steps[j] == s then break end
      end
      if not later then
        local add = {}
        for j = 1, i - 1 do
          local sj = opt.steps[j]
          for _, b in ipairs(sj.acts or {}) do
            if b.k == "O" and b.qid == a.qid and not ActDone(b) then
              local c = {}
              for k, v in pairs(b) do c[k] = v end
              c.pre, c.reopen = nil, true
              add[#add + 1] = { map = sj.map, x = sj.x, y = sj.y, lvl = s.lvl, t = s.t, acts = { c } }
            end
          end
        end
        for k = #add, 1, -1 do table.insert(opt.steps, i, add[k]) end
        if #add > 0 and ns.TestLog then
          ns.TestLog("SCHRITT", ("Abgabe vor fertig: %d Ziele von %s wieder davor"):format(#add, tostring(a.quest or a.qid)))
        end
      end
    end
  end
end
-- Schritt st gibt eine Vorquest von qid ab?
function V11.NeedsTurnIn(qid, st)
  local ids = {}
  local ps, pg = Q(qid, "preQuestSingle"), Q(qid, "preQuestGroup")
  for _, id in ipairs(type(ps) == "table" and ps or {}) do ids[id] = true end
  for _, id in ipairs(type(pg) == "table" and pg or {}) do if type(id) == "number" then ids[math.abs(id)] = true end end
  for _, b in ipairs(st.acts or {}) do if b.k == "T" and b.qid and ids[b.qid] then return true end end
  return false
end
V11.LIVE_WIN_STD = 7           -- v11d: Fenster Standard (Sim: V11.LIVE_WIN_STD oder db.liveWin setzen)
V11.LIVE_NEAR_YD = 600        -- nur Schritte, die so nah bei dir liegen (Luftlinie)
local LIVE_MAX_PERMS = 5000     -- hoechstens so viele fertige Reihenfolgen pruefen
V11.LIVE_MAX_NODES = 40000    -- hoechstens so viele Teil Reihenfolgen (Suche mit Schranke)
V11.LIVE_FRAME_MS = 2         -- Rechenzeit pro Bild beim Nachrechnen in Stuecken
V11.LIVE_YIELD_EVERY = 150    -- so oft (Teil Reihenfolgen) die Zeit pruefen
V11.liveT0 = 0
function V11.LiveYield()
  if V11.liveCo and coroutine.running() == V11.liveCo and debugprofilestop and debugprofilestop() - V11.liveT0 > V11.LIVE_FRAME_MS then
    coroutine.yield()
    V11.liveT0 = debugprofilestop()
  end
end
local LIVE_KINDS = { A = true, T = true, O = true } -- nur Annehmen, Ziel, Abgeben wird umgestellt
local LIVE_CACHE_YD = 25        -- gleiche Frage aus fast derselben Position: Antwort aus dem Speicher
local LIVE_CHANCE_YD = 150      -- Gelegenheit: Questgeber hoechstens so weit weg (wie Na Abweichung)
local LIVE_CHANCE_AHEAD = 40    -- so viele Schritte voraus nach Gelegenheiten suchen
local LIVE_CHANCE_SKIP = 2      -- die naechsten Schritte kommen sowieso gleich, keine Gelegenheit
local LIVE_CHANCE_MAX_S = 90    -- Umweg hoechstens so viele Sekunden
local LIVE_CHANCE_LVL = 0       -- Schritt Level hoechstens so viel ueber deinem Level

local function LiveLog(txt) if ns.TestLog then ns.TestLog("LIVE", txt) end end
-- 20.4b2 (K 22:36, Si s60 Last): auf Max Level (Nach 60 Route) rechnet Live nicht
local function LiveOn()
  local db = ns.db
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if (UnitLevel and UnitLevel("player") or 1) >= maxL then return false end
  return db and db.liveCalc ~= false and db.opt and db.opt.steps and not db.opt.mirror and not db.opt.pin
    and not (ns.groupFollow and db.opt.group) and not (db.opt.opts and db.opt.opts.rest)
end

-- Weltpunkt eines Schritts (Kontinent, x, y in Yards)
local function LiveW(map, x, y)
  if not (map and x and y and ns.MapWorld) then return end
  return ns.MapWorld(map, x, y)
end

-- Bezugspunkt: du, in der Gruppe das Mitglied, das am weitesten vom Ziel weg ist (K 17:40)
local function LiveRef(st)
  local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local pos = here and C_Map.GetPlayerMapPosition(here, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local c, wx, wy = LiveW(here, px, py)
  if not c then return end
  if IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid()) and st and st.map then
    local sc, sx, sy = LiveW(st.map, st.x, st.y)
    local far = sc == c and math.sqrt((wx - sx) ^ 2 + (wy - sy) ^ 2) or nil
    for i = 1, 4 do
      local u = "party" .. i
      -- v11d (K P33): nur Mitglieder mit dem Addon (ns.group), ein Partner ohne Addon zieht die Reihenfolge nicht mit
      local un = UnitName and UnitName(u)
      local hasAddon = un and ns.group and (ns.group[un] or ns.group[(ns.Plain and ns.Plain(un)) or un])
      if hasAddon and UnitExists and ns.Api.U(UnitExists, u) and not (UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, u)) then
        local p = C_Map.GetPlayerMapPosition(here, u)
        if p then
          local ux, uy = p:GetXY()
          local uc, uwx, uwy = LiveW(here, ux, uy)
          if uc == c and far and ux > 0 and uy > 0 then
            local d = math.sqrt((uwx - sx) ^ 2 + (uwy - sy) ^ 2)
            if d > far then far, wx, wy = d, uwx, uwy end
          end
        end
      end
    end
  end
  return c, wx, wy, here, px, py
end

-- Schritt umstellbar: Ort da, keine Reise, kein Warten, nur Annehmen, Ziel, Abgeben
local function LiveMovable(st)
  if not st or not st.map or not st.x or st.travel or st.lvlWait or st.foeWait then return false end
  if not st.acts or #st.acts == 0 then return false end
  for _, a in ipairs(st.acts) do
    if not LIVE_KINDS[a.k] or a.link or a.toMap then return false end
  end
  return true
end

local function LiveQids(st)
  local q = {}
  for _, a in ipairs(st.acts or {}) do if a.qid then q[a.qid] = true end end
  return q
end

local liveCache = { key = nil, res = nil }

-- C: Questziel fast fertig. Die Stelle (Spawn Punkt oder Gebiet), die zwischen dir und dem naechsten Schritt liegt
local function LiveSpot(opt, ctx, c, wx, wy, speed)
  local i = opt.idx or 1
  local st, nx = opt.steps[i], opt.steps[i + 1]
  if not (st and nx and st.map and nx.map) then return end
  local nc, nwx, nwy = LiveW(nx.map, nx.x, nx.y)
  if nc ~= c then return end
  for _, a in ipairs(st.acts or {}) do
    if a.k == "O" and (not ctx or not ctx.qid or a.qid == ctx.qid) and type(a.pts) == "table" and #a.pts > 1 and not ActDone(a) then
      local function Cost(x, y)
        local pc, pwx, pwy = LiveW(st.map, x, y)
        if pc ~= c then return end
        return math.sqrt((wx - pwx) ^ 2 + (wy - pwy) ^ 2) + math.sqrt((pwx - nwx) ^ 2 + (pwy - nwy) ^ 2)
      end
      -- jetziges Ziel des Pfeils (Gebiet oder Punkt), sonst die Schritt Mitte
      local curX, curY = st.x, st.y
      if a.areas and a.area and a.areas[a.area] then curX, curY = a.areas[a.area].x, a.areas[a.area].y
      elseif a.cur and a.pts[a.cur] then curX, curY = a.pts[a.cur][1], a.pts[a.cur][2] end
      local old = Cost(curX, curY)
      if not old then return end
      -- 1.1 (P43): nicht dauernd die Stelle wechseln und nicht gleich wieder zurueck
      local nowSp = GetTime and GetTime() or 0
      if a.spotAt and nowSp - a.spotAt < V11.SPOT_HOLD_S then return end
      local noBack = (a.spotPrev and nowSp - (a.spotAt or 0) < V11.SPOT_HOLD_S * 2) and a.spotPrev or nil
      local best, bc
      if a.areas then
        for k, ar in ipairs(a.areas) do
          local v = Cost(ar.x, ar.y)
          if v and k ~= noBack and (not bc or v < bc) then best, bc = k, v end
        end
      else
        for k, p in ipairs(a.pts) do
          if not (a.vis and a.vis[k]) and k ~= noBack then local v = Cost(p[1], p[2]); if v and (not bc or v < bc) then best, bc = k, v end end
        end
      end
      if best and bc < old then
        return { oldSec = math.floor(old / speed), newSec = math.floor(bc / speed), kind = "spot",
          apply = function()
            a.spotPrev = a.areas and a.area or a.cur
            a.spotAt = GetTime and GetTime() or 0
            if a.areas then a.area = best; a.areaSwAt = a.spotAt else a.cur = best; a.curAt = a.spotAt end
            LiveLog(("Stelle gewechselt: %s, Ziel %d"):format(tostring(a.quest), best))
          end }
      end
    end
  end
end

-- B: Reihenfolge der naechsten Schritte
function ns.LiveReplan(reason, ctx)
  if not LiveOn() then return end
  local opt = ns.db.opt
  local i0 = opt.idx or 1
  local c, wx, wy = LiveRef(opt.steps[i0])
  if not c then return end
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local key = ("%s|%d|%s|%d|%d"):format(tostring(opt.created or opt.title), i0, tostring(reason),
    math.floor(wx / LIVE_CACHE_YD), math.floor(wy / LIVE_CACHE_YD))
  if liveCache.key == key and liveCache.opt == opt then return liveCache.res end
  local res
  if reason == "fast_fertig" then res = LiveSpot(opt, ctx, c, wx, wy, speed) end
  if not res then
    -- Fenster: zusammenhaengende umstellbare Schritte auf deinem Kontinent
    local win = {}
    -- v11d (K P30, Pr: 10 gegen 5 kein Vorteil, 10 bis 20 ms): Standard 7, hoechstens LIVE_WIN_MAX (db.liveWin aendert)
    local winN = math.min(LIVE_WIN_MAX, tonumber(ns.db and ns.db.liveWin) or V11.LIVE_WIN_STD)
    for i = i0, math.min(#opt.steps, i0 + winN - 1) do
      local st = opt.steps[i]
      if not LiveMovable(st) then break end
      local sc, sx, sy = LiveW(st.map, st.x, st.y)
      if sc ~= c then break end
      if #win >= LIVE_WIN_MIN and math.sqrt((sx - wx) ^ 2 + (sy - wy) ^ 2) > V11.LIVE_NEAR_YD then break end
      win[#win + 1] = { st = st, x = sx, y = sy, q = LiveQids(st) }
    end
    local n = #win
    if n >= LIVE_WIN_MIN then
      -- danach geht es hier weiter (Weg dorthin zaehlt mit)
      local after = opt.steps[i0 + n]
      local ac, ax, ay
      if after and after.map then ac, ax, ay = LiveW(after.map, after.x, after.y) end
      if ac ~= c then ax = nil end
      -- Vorgaenger: frueherer Schritt mit gleicher Quest muss frueher bleiben
      -- v11d (Pr P28, ACCEPT_FAIL 6385): und Annehmen einer Quest erst nach der Abgabe ihrer Vorquest (Feld 13 und 12 mit
      -- Daten Korrektur, wie die Planung)
      local pre = {}
      for k = 1, n do
        pre[k] = {}
        for j = 1, k - 1 do
          for q in pairs(win[k].q) do if win[j].q[q] then pre[k][j] = true; break end end
          if not pre[k][j] then
            for _, a in ipairs(win[k].st.acts or {}) do
              if a.k == "A" and a.qid and V11.NeedsTurnIn(a.qid, win[j].st) then pre[k][j] = true; break end
            end
          end
        end
      end
      local function D(x1, y1, x2, y2) return math.sqrt((x1 - x2) ^ 2 + (y1 - y2) ^ 2) end
      local function Cost(order)
        local s, x, y = 0, wx, wy
        for _, k in ipairs(order) do s = s + D(x, y, win[k].x, win[k].y); x, y = win[k].x, win[k].y end
        if ax then s = s + D(x, y, ax, ay) end
        return s
      end
      local orig = {}
      for k = 1, n do orig[k] = k end
      local oldC = Cost(orig)
      local bestO, bestC, perms = nil, oldC, 0
      local used, cur = {}, {}
      -- 1.1: erst eine schnelle Reihenfolge (immer der naechste erlaubte Schritt), das gibt der Suche eine gute Schranke
      do
        local gUsed, gOrd, gx, gy, gs = {}, {}, wx, wy, 0
        for _ = 1, n do
          local bk, bd
          for k = 1, n do
            if not gUsed[k] then
              local ok = true
              for j in pairs(pre[k]) do if not gUsed[j] then ok = false; break end end
              if ok then local d = D(gx, gy, win[k].x, win[k].y); if not bd or d < bd then bk, bd = k, d end end
            end
          end
          if not bk then break end
          gUsed[bk] = true; gOrd[#gOrd + 1] = bk; gs = gs + bd; gx, gy = win[bk].x, win[bk].y
        end
        if #gOrd == n then
          gs = gs + (ax and D(gx, gy, ax, ay) or 0)
          if gs < bestC then bestC, bestO = gs, gOrd end
        end
      end
      local nodes = 0
      local function Rec(depth, acc, x, y)
        if perms >= LIVE_MAX_PERMS or nodes >= V11.LIVE_MAX_NODES or acc >= bestC then return end
        nodes = nodes + 1
        if nodes % V11.LIVE_YIELD_EVERY == 0 then V11.LiveYield() end
        if depth > n then
          perms = perms + 1
          local total = acc + (ax and D(x, y, ax, ay) or 0)
          if total < bestC then bestC = total; bestO = { unpack(cur) } end
          return
        end
        for k = 1, n do
          if not used[k] then
            local ok = true
            for j in pairs(pre[k]) do if not used[j] then ok = false; break end end
            if ok then
              used[k] = true; cur[depth] = k
              Rec(depth + 1, acc + D(x, y, win[k].x, win[k].y), win[k].x, win[k].y)
              used[k] = nil; cur[depth] = nil
            end
          end
        end
      end
      Rec(1, 0, wx, wy)
      if bestO then
        local changed = false
        for k = 1, n do if bestO[k] ~= k then changed = true; break end end
        if changed then
          local order = bestO
          res = { oldSec = math.floor(oldC / speed), newSec = math.floor(bestC / speed), kind = "order",
            oldFirst = win[1].st, newFirst = win[order[1]].st,
            apply = function()
              -- nur wenn die Route noch dieselbe ist
              if ns.db.opt ~= opt or (opt.idx or 1) ~= i0 then return end
              for k = 1, n do if opt.steps[i0 + k - 1] ~= win[k].st then return end end
              -- Level und Zeit bleiben an der Stelle (die Route laeuft weiter in derselben Zeit), nur die Schritte tauschen
              local lv, tt = {}, {}
              for k = 1, n do lv[k], tt[k] = win[k].st.lvl, win[k].st.t end
              for k = 1, n do
                local st = win[order[k]].st
                st.lvl, st.t = lv[k], tt[k]
                opt.steps[i0 + k - 1] = st
              end
              liveCache.key = nil
              LiveLog(("Reihenfolge ab Schritt %d: %s"):format(i0, table.concat(order, " ")))
            end }
        end
      end
      LiveLog(("%s: %d Schritte, %d Reihenfolgen, vorher %d s, beste %d s"):format(tostring(reason), n, perms,
        math.floor(oldC / speed), math.floor(bestC / speed)))
    end
  end
  liveCache.key, liveCache.opt, liveCache.res = key, opt, res
  return res
end

-- 1.1: dasselbe in Stuecken ueber mehrere Bilder (LIVE_FRAME_MS pro Bild), Ergebnis kommt an cb(res, err).
-- Laeuft schon eine, wird die alte verworfen (die neue Lage zaehlt)
V11.liveGen = 0
function ns.LiveReplanAsync(reason, ctx, cb)
  V11.liveGen = V11.liveGen + 1
  local myGen = V11.liveGen
  local co = coroutine.create(function() return ns.LiveReplan(reason, ctx) end)
  local function Step()
    if myGen ~= V11.liveGen then return end
    V11.liveCo, V11.liveT0 = co, debugprofilestop and debugprofilestop() or 0
    local ok, res = coroutine.resume(co)
    V11.liveCo = nil
    if not ok then if cb then cb(nil, res) end return end
    if coroutine.status(co) ~= "dead" then C_Timer.After(0, Step); return end
    if cb then cb(res) end
  end
  Step()
end

-- D: Gelegenheit am Weg. Quest annehmen, die spaeter in der Route kommt, Geber gerade nah
local liveChance
local LIVE_CHANCE_EVERY_S = 10
local liveChanceAt, liveChanceRes = -999, nil
function ns.LiveChance()
  local now = GetTime and GetTime() or 0
  if now - liveChanceAt < LIVE_CHANCE_EVERY_S then return liveChanceRes end
  liveChanceAt, liveChanceRes = now, nil
  liveChance = nil
  if not LiveOn() then return end
  local opt = ns.db.opt
  local i0 = opt.idx or 1
  local c, wx, wy = LiveRef(nil)
  if not c then return end
  local nLog = 0
  for _ in pairs(ns.logProgress or {}) do nLog = nLog + 1 end
  if ns.LogMax and nLog >= ns.LogMax() then return end
  local myL = (UnitLevel and UnitLevel("player")) or 1
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local best, bs
  for i = i0 + LIVE_CHANCE_SKIP, math.min(#opt.steps, i0 + LIVE_CHANCE_AHEAD) do
    local st = opt.steps[i]
    if st and st.map and not st.travel and math.floor(st.lvl or 0) <= myL + LIVE_CHANCE_LVL then
      local onlyA = #(st.acts or {}) > 0
      for _, a in ipairs(st.acts or {}) do
        if a.k ~= "A" or a.pre or not a.qid or (ns.logProgress and ns.logProgress[a.qid]) or Completed1(a.qid) then onlyA = false; break end
        -- v11d (Pr P28, Log "Gelegenheit: Doras der Windreitermeister"): nur wenn alle Vorquests schon abgegeben sind
        if PreMissing and #PreMissing(a.qid, Completed1) > 0 then onlyA = false; break end
      end
      if onlyA then
        local sc, sx, sy = LiveW(st.map, st.x, st.y)
        if sc == c then
          local d = math.sqrt((wx - sx) ^ 2 + (wy - sy) ^ 2)
          local sec = math.floor(2 * d / speed)
          if d <= LIVE_CHANCE_YD and sec <= LIVE_CHANCE_MAX_S and (not bs or sec < bs) then best, bs = i, sec end
        end
      end
    end
  end
  -- 1.1 (K Stufe B 12): fertige Reserve Quest im Log, Abgabe nah: als Gelegenheit (Klick macht einen Schritt daraus)
  do
    local rs, rsec = V11.ReserveTurnIn(c, wx, wy, speed)
    if rs and (not bs or rsec < bs) then
      liveChance = { opt = opt, st = rs, idx = i0, new = true }
      liveChanceRes = { text = (TR"Reserve abgeben: %s"):format(tostring(rs.acts[1].quest)), sec = rsec }
      return liveChanceRes
    end
  end
  if not best then return end
  local st = opt.steps[best]
  local names = {}
  for _, a in ipairs(st.acts) do names[#names + 1] = a.quest or tostring(a.qid) end
  liveChance = { opt = opt, st = st, idx = i0 }
  liveChanceRes = { text = table.concat(names, ", "), sec = bs }
  return liveChanceRes
end

------------------------------------------------------------
-- 1.1 (K Stufe B 12) Reserve Quests: Quests, die nicht in der Route stehen, aber ganz nah an den naechsten Schritten
-- liegen (Annehmen hier, Ziele und Abgabe nahe der Route). Auto Quest nimmt sie mit, solange im Log genug Platz bleibt.
-- Fertig (zb Glueck beim Droppen): Gelegenheit "Reserve abgeben". Liegt die Route nicht mehr in ihrer Naehe: Hinweis
-- "kann abgebrochen werden". Alles aus den Quest Daten, keine Liste
------------------------------------------------------------
V11.RESERVE_YD = 80            -- Ziele und Abgabe hoechstens so weit von einem der naechsten Schritte
V11.RESERVE_AHEAD = 30         -- so viele Schritte voraus zaehlen
V11.RESERVE_LOG_FREE = 4       -- so viele Plaetze im Log bleiben fuer die Route frei
V11.RESERVE_MAX = 5            -- hoechstens so viele Reserve Quests gleichzeitig im Log
V11.RESERVE_LVL_UP = 2         -- Questlevel hoechstens so viel ueber dir
V11.reserveCache = {}
local function ReserveSteps(opt)
  local pts, i0 = {}, opt.idx or 1
  for i = i0, math.min(#opt.steps, i0 + V11.RESERVE_AHEAD) do
    local st = opt.steps[i]
    if st and st.map and st.x and not st.travel then
      local c, x, y = LiveW(st.map, st.x, st.y)
      if c then pts[#pts + 1] = { c, x, y } end
    end
  end
  return pts
end
local function NearAny(pts, n, lim)
  if not (n and n.wx and n.cont) then return false end
  for _, p in ipairs(pts) do
    if p[1] == n.cont and (p[2] - n.wx) ^ 2 + (p[3] - n.wy) ^ 2 <= lim * lim then return true end
  end
  return false
end
-- v11d (Pr P5): gebaute Quests merken (je Quest und Route), sonst baute jeder Aufbau des Mini Fensters neu
V11.reserveBuilt = {}
local function ReserveBuild(qid)
  local o = ns.db and ns.db.opt
  local key = qid .. ":" .. tostring(o and o.created)
  local c = V11.reserveBuilt[key]
  if c ~= nil then return c or nil end
  local tools = ns.OptTools and ns.OptTools()
  if not tools then return nil end
  local any = setmetatable({}, { __index = function() return true end })
  local ok, q = pcall(tools.BuildQuest, qid, any, nil, false, nil)
  q = ok and type(q) == "table" and q or nil
  V11.reserveBuilt[key] = q or false
  return q
end
function ns.IsReserveQuest(qid)
  local db = ns.db
  if not (qid and db and db.liveCalc ~= false and db.reserveQuests ~= false and LiveOn()) then return false end
  local opt = db.opt
  -- Platz im Log
  local nLog, nRes = 0, 0
  for id in pairs(ns.logProgress or {}) do
    nLog = nLog + 1
    if db.reserveQ and db.reserveQ[id] then nRes = nRes + 1 end
  end
  if ns.LogMax and nLog > ns.LogMax() - V11.RESERVE_LOG_FREE then return false end
  if nRes >= V11.RESERVE_MAX then return false end
  if ns.IsDungeonQuest and ns.IsDungeonQuest(qid) then return false end
  if ns.IsEliteQuest and ns.IsEliteQuest(qid) and not (IsInGroup and IsInGroup()) then return false end
  local key = tostring(opt.created or opt.title) .. ":" .. tostring(math.floor((opt.idx or 1) / 5)) .. ":" .. qid
  local hit = V11.reserveCache[key]
  if hit == nil then
    hit = false
    local q = ReserveBuild(qid)
    local myL = (UnitLevel and UnitLevel("player")) or 1
    if q and (q.ql or 0) <= myL + V11.RESERVE_LVL_UP and q.T and not q.eliteMob then
      local pts = ReserveSteps(opt)
      hit = #pts > 0
      for _, n in ipairs(q.nodes or {}) do
        if n ~= q.A and not NearAny(pts, n, V11.RESERVE_YD) then hit = false; break end
      end
      if hit and V11.TimedTooLong(q) then hit = false end
    end
    V11.reserveCache[key] = hit
  end
  -- v11d (Pr P6): erst beim Annehmen (QUEST_ACCEPTED, ns.ReserveAccepted) als Reserve merken
  if hit then V11.reservePending = V11.reservePending or {}; V11.reservePending[qid] = GetTime() end
  return hit
end
function ns.ReserveAccepted(qid)
  local p = V11.reservePending and qid and V11.reservePending[qid]
  if not (p and GetTime() - p < 120 and ns.db) then return end
  V11.reservePending[qid] = nil
  ns.db.reserveQ = ns.db.reserveQ or {}
  ns.db.reserveQ[qid] = true
  if ns.TestLog then ns.TestLog("LIVE", ("Reserve Quest mitgenommen: %s"):format(tostring(qid))) end
end
-- fertige Reserve Quest: Abgabe Schritt, wenn nah bei dir
function V11.ReserveTurnIn(c, wx, wy, speed)
  local db = ns.db
  if not (db and db.reserveQ) then return end
  for qid in pairs(db.reserveQ) do
    local lp = ns.logProgress and ns.logProgress[qid]
    if not lp then
      if not (ns.logProgress and next(ns.logProgress)) then return end
      db.reserveQ[qid] = nil   -- nicht mehr im Log (abgegeben oder abgebrochen)
    elseif lp.complete then
      local q = ReserveBuild(qid)
      local t = q and q.T
      if t and t.cont == c and t.wx then
        local d = math.sqrt((wx - t.wx) ^ 2 + (wy - t.wy) ^ 2)
        local sec = math.floor(2 * d / speed)
        if d <= LIVE_CHANCE_YD and sec <= LIVE_CHANCE_MAX_S then
          return { map = t.map, x = t.x, y = t.y, acts = { { k = "T", qid = qid, quest = lp.title or q.name, who = t.who, npc = t.npc } } }, sec
        end
      end
    end
  end
end
-- Reserve Quest im Log, die Route ist nicht mehr in der Naehe: Hinweis Text (oder nil)
function ns.ReserveDropHint()
  local db = ns.db
  if not (db and db.reserveQ and db.opt and db.opt.steps and LiveOn()) then return end
  local pts
  for qid in pairs(db.reserveQ) do
    local lp = ns.logProgress and ns.logProgress[qid]
    if lp and not lp.complete then
      local q = ReserveBuild(qid)
      if q then
        pts = pts or ReserveSteps(db.opt)
        local near = false
        for _, n in ipairs(q.nodes or {}) do if n ~= q.A and NearAny(pts, n, V11.RESERVE_YD * 2) then near = true; break end end
        if not near then return (TR"Reserve Quest %s liegt nicht mehr am Weg, kann abgebrochen werden."):format(tostring(lp.title or q.name)), qid end
      end
    end
  end
end

-- Klick auf die Gelegenheit: der Schritt kommt jetzt dran (vor den aktuellen)
function ns.LiveChanceTake()
  local ch = liveChance
  liveChance, liveChanceRes = nil, nil
  local opt = ns.db and ns.db.opt
  if not ch or ch.opt ~= opt or (opt.idx or 1) ~= ch.idx then return end
  -- 1.1: Reserve Abgabe ist ein neuer Schritt (steht noch nicht in der Route)
  if ch.new then
    local cur = opt.steps[ch.idx]
    ch.st.lvl, ch.st.t = cur and cur.lvl or 0, cur and cur.t or 0
    table.insert(opt.steps, ch.idx, ch.st)
    liveCache.key = nil
    LiveLog(("Reserve Abgabe als Schritt %d: %s"):format(ch.idx, tostring(ch.st.acts[1].quest)))
    if ns.Draw then ns.Draw() end
    if ns.RefreshHud then ns.RefreshHud() end
    return
  end
  local from
  for i = ch.idx, #opt.steps do if opt.steps[i] == ch.st then from = i; break end end
  if not from then return end
  local cur = opt.steps[ch.idx]
  table.remove(opt.steps, from)
  ch.st.lvl, ch.st.t = cur and cur.lvl or ch.st.lvl, cur and cur.t or ch.st.t
  table.insert(opt.steps, ch.idx, ch.st)
  liveCache.key = nil
  LiveLog(("Gelegenheit genommen: Schritt %d jetzt %d"):format(from, ch.idx))
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
end
