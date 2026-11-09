local ADDON, ns = ...
local TR = ns.TR
-- Name je nach Sprache vom Spiel, fuer Namen ohne TR, die mit dem Spiel verglichen werden (Entdecken)
local function DE_EN(de, en) return ns.EN and en or de end
ns.DE_EN = DE_EN
local RATCHET = DE_EN("Ratschet", "Ratchet")

-- Forever: Mulgore, Oestliche Pestlaender, Rotkammgebirge und Sturmwind sind auf Forever anders vermessen als in Era
-- (QuestieDB eraToForever, DBC 1.15.9 nach 1.60.1, Welt Positionen gleich). Questie liefert auf Forever schon die neuen
-- Werte, die fest eingetragenen Era Punkte im Addon (Hubs, Bücher, Startpunkt, gemalte Berge) werden hier umgerechnet.
-- Je Karte: Faktor x, Versatz x, Faktor y, Versatz y (in Prozent der Karte)
local ERA2FOR = {
  [1412] = { 0.8348002068275978, 7.007453108736848, 0.8349418225477033, 13.15387327724201 },    -- Mulgore
  [1423] = { 0.8997577709204458, -1.6464926382438023, 0.9004358590984077, -3.7790494664060477 }, -- Oestliche Pestlaender
  [1433] = { 0.9999996626080551, -5.086374584221827, 1.0, 0.0 },                                  -- Rotkammgebirge
  [1453] = { 0.7736792385183993, 19.680449646264936, 0.773826866980289, 24.433287807510073 },   -- Sturmwind
}
-- 1.2e (P47, S 12:44): nur noch Forever. Die Umrechnung bleibt, weil die fest eingetragenen Punkte im Addon in der alten
-- Vermessung stehen (4 Karten). Sie gilt jetzt immer, ohne Era Zweig
ns.FOREVER = true
ns.FIXMAPS = ERA2FOR
-- fester Punkt (0 bis 1, alte Vermessung) auf die Forever Karte
function ns.FixXY(map, x, y)
  local t = map and ERA2FOR[map]
  if not (t and type(x) == "number" and type(y) == "number") then return x, y end
  return (x * 100 * t[1] + t[2]) / 100, (y * 100 * t[3] + t[4]) / 100
end
-- Liste von Punkten { x, y, ..., map = Stadtkarte } pro Karte umrechnen
function ns.FixLists(tbl)
  if type(tbl) ~= "table" then return end
  for map, list in pairs(tbl) do
    if type(list) == "table" then
      for _, e in ipairs(list) do
        if type(e) == "table" and type(e[1]) == "number" and type(e[2]) == "number" then
          e[1], e[2] = ns.FixXY(e.map or map, e[1], e[2])
        end
      end
    end
  end
end

-- Bit in einer Maske pruefen, ohne 32 Bit Grenze (Volk Masken der Forever Voelker haben hohe Bits)
function ns.HasBit(mask, i)
  if not mask or not i or i < 0 then return false end
  return math.floor(mask / 2 ^ i) % 2 == 1
end

-- Passt eine Quest (Volk Maske requiredRaces) zu deinem Volk? Die Masken in Questie kennen oft nur die 8 alten
-- Voelker. Ein Volk, das es nur auf Forever gibt (Volk ID ueber 8), steht dort meist nicht drin: dann zaehlt die
-- Fraktion. Eine Quest fuer ein Volk deiner Fraktion (zb Orc und Troll im Tal der Pruefungen) geht dann auch fuer dich.
local HORDE_RACES, ALLY_RACES = { 1, 4, 5, 7 }, { 0, 2, 3, 6 } -- Bit = Volk ID - 1
-- Kennen die Questie Daten das Volk schon (Forever Daten haben eigene Bits, zb Skyborne 33 und 34)?
-- Dann gilt die Maske genau: eine Quest nur fuer Tauren ist dann nichts fuer Skyborne.
-- Vorher plante die Route fuer Skyborne Tauren und Zwergen Quests ("A Bundle of Hides", "Honor Students").
local raceKnown = {}
local RACE_PROBE = { 95349, 94946 } -- letzte Startquests auf Zephras, haben die Skyborne Bits
function ns.RaceKnown(rid)
  if not rid or rid <= 8 then return true end
  local k = raceKnown[rid]
  if k ~= nil then return k end
  local qdb = ns.QDBAccess and ns.QDBAccess()
  if not (qdb and qdb.QueryQuestSingle) then return false end -- noch nicht geladen: spaeter nochmal schauen
  local function Has(id)
    local ok, rr = pcall(qdb.QueryQuestSingle, id, "requiredRaces")
    return ok and type(rr) == "number" and rr > 0 and ns.HasBit(rr, rid - 1)
  end
  local found = false
  for _, id in ipairs(RACE_PROBE) do if Has(id) then found = true; break end end
  if not found and qdb.QuestPointers then
    local n = 0
    for id in pairs(qdb.QuestPointers) do
      n = n + 1
      if n > 4000 then break end
      if Has(id) then found = true; break end
    end
  end
  raceKnown[rid] = found
  return found
end
function ns.RaceOK(rr, rid, faction)
  if not rr or rr <= 0 or not rid then return true end
  if ns.HasBit(rr, rid - 1) then return true end
  if rid <= 8 then return false end
  if ns.RaceKnown(rid) then return false end
  faction = faction or (UnitFactionGroup and UnitFactionGroup("player"))
  local list = faction == "Horde" and HORDE_RACES or (faction == "Alliance" and ALLY_RACES) or {}
  for _, b in ipairs(list) do if ns.HasBit(rr, b) then return true end end
  return false
end
-- eigenes Volk der Forever Server (nicht in den Questie Masken)?
function ns.CustomRace()
  local _, _, rid = UnitRace("player")
  return rid ~= nil and rid > 8
end

-- Test Level (nur zum Testen, /klg tlvl 30): gilt fuer Freischaltungen und Fenster, nicht fuer die Route
function ns.UnitLevel(unit)
  if ns.testLevel and unit == "player" then return ns.testLevel end
  return UnitLevel(unit)
end

-- Alle wiederkehrenden Arbeiten laufen ueber ns.Ticker:
--  * Pause (Menue, /klg pause): nichts wird mehr gerechnet oder gezeichnet
--  * Max Level ohne laufende Route: seltener (kurze Takte nur noch jedes 4. Mal, mittlere jedes 2. Mal)
function ns.Paused() return ns.db and ns.db.paused and true or false end
-- 17.9: im Dungeon oder Schlachtzug (keine Position, keine Wege): Route und Pfeil warten bis draussen
function ns.InInstance()
  if not IsInInstance then return false end
  -- 1.1 (P55, K 13:30: "Pause an (party, ?)" beim Einloggen mit Karte ? 0,0): erst entscheiden, wenn die Welt geladen ist
  -- (kurz nach PLAYER_ENTERING_WORLD) und das Spiel eine Karte kennt. Vorher zaehlt nichts als Instanz
  if not ns.worldReady then return false end
  local okM, m = pcall(C_Map.GetBestMapForUnit, "player")
  if not (okM and m) then return false end
  local inI, typ = IsInInstance()
  inI, typ = ns.Api.Plain(inI), ns.Api.Plain(typ)
  if not inI then return false end
  -- 1.1 (P60, K 14:33: "Pause an (party, Orgrimmar)" mitten in OG im Duo): Instanz nur, wenn das Spiel dort keine Position
  -- auf der Karte gibt oder die Karte eine Dungeon Karte ist. Hauptstaedte und Zonen haben immer eine Position
  local okP, pos = pcall(C_Map.GetPlayerMapPosition, m, "player")
  local hasPos = okP and pos ~= nil
  local okI, info = pcall(C_Map.GetMapInfo, m)
  local dung = okI and info and Enum and Enum.UIMapType and info.mapType == Enum.UIMapType.Dungeon
  -- 20.4a (K 17:49, S 17:48): auch Schlachtfeld und Arena, dort rechnet und prueft das Addon ebenfalls nichts
  if typ == "pvp" or typ == "arena" then return true end
  if hasPos and not dung then return false end
  return (typ == "party" or typ == "raid") or false
end
local lowCache, lowAt = false, 0
function ns.LowPower()
  local now = GetTime()
  if now - lowAt < 5 then return lowCache end
  lowAt = now
  local db = ns.db
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  local busy = false
  if db then
    local opt = db.opt
    local open = opt and opt.steps and (opt.idx or 1) <= #opt.steps
    busy = db.goldMode or ns.serviceTarget ~= nil or (open and opt.opts and (opt.opts.gold or opt.opts.rep or opt.opts.gearQ or opt.opts.logOnly)) or ns.repFarm
  end
  lowCache = (UnitLevel("player") or 1) >= maxL and not busy
  return lowCache
end
-- keep: nie ausduennen (Zeit messen zaehlt jeden Takt als eine Sekunde)
-- Jeder Takt wird gemessen: dauert einer laenger als 40 ms, merkt sich das Test Log, welcher es war (Datei:Zeile)
local function Site()
  if not debugstack then return "?" end
  local st = debugstack(3, 1, 0) or ""
  local f, l = st:match("([%w_]+%.lua)%D+(%d+)")
  return f and (f .. ":" .. l) or "?"
end
ns.slowCount = {}
function ns.SlowMark(site, ms)
  ns.slowLast = { site = site, ms = ms, t = GetTime() }
  ns.slowCount[site] = (ns.slowCount[site] or 0) + 1
end
-- 1.3x (P108): inPause = laeuft auch in der Pause weiter (nur Anzeige, zb Mini Fenster mit XP Balken und Tempo)
function ns.Ticker(interval, fn, keep, inPause)
  local n = 0
  local site = Site()
  local clock = debugprofilestop
  return C_Timer.NewTicker(interval, function(...)
    if ns.db and ns.db.paused and not inPause then return end
    if not keep and interval < 3 and ns.LowPower() then
      n = n + 1
      if n % (interval < 1 and 4 or 2) ~= 0 then return end
    end
    if not clock then return fn(...) end
    local t0 = clock()
    local r = fn(...)
    local ms = clock() - t0
    if ms > 40 then ns.SlowMark(site, ms) end
    return r
  end)
end

-- 1.1 (P53, K 13:30): bei BLOCKIERT den Stack mitschreiben (Datei:Zeile statt nur UNKNOWN). Eigene Zeilen dieser
-- Funktion und vom Ereignis fallen raus, damit man sieht, welcher Code gerade lief
function ns.BlockStack()
  if not debugstack then return nil end
  local raw = debugstack(2, 14, 0) or ""
  local out = {}
  for ln in tostring(raw):gmatch("[^\n]+") do
    if not ln:find("Route.lua", 1, true) and not ln:find("DebugLog.lua", 1, true) then
      local f, l = ln:match("([%w_]+%.lua)%D+(%d+)")
      out[#out + 1] = f and (f .. ":" .. l) or ln:gsub("^%s+", ""):sub(1, 40)
    end
    if #out >= 6 then break end
  end
  return #out > 0 and table.concat(out, " < ") or "leer"
end

-- 1.1 (P55): Welt geladen? Bei jedem Ladebild kurz nein, INSTANCE_WAIT_S nach PLAYER_ENTERING_WORLD ja
ns.INSTANCE_WAIT_S = 1.5
do
  local wf = CreateFrame("Frame")
  ns.RegEv(wf, "PLAYER_ENTERING_WORLD")
  ns.RegEv(wf, "LOADING_SCREEN_ENABLED")
  wf:SetScript("OnEvent", function(_, ev)
    ns.worldReady = false
    ns.worldTok = (ns.worldTok or 0) + 1
    if ev ~= "PLAYER_ENTERING_WORLD" then return end
    local tok = ns.worldTok
    C_Timer.After(ns.INSTANCE_WAIT_S, function()
      if tok ~= ns.worldTok then return end
      ns.worldReady = true
      if ns.WorldReadyHooks then for _, f in ipairs(ns.WorldReadyHooks) do pcall(f) end end
    end)
  end)
end
ns.WorldReadyHooks = ns.WorldReadyHooks or {}

-- ganz frueh: blockierte Aktionen schon beim Laden mitbekommen (Deps.lua wertet sie aus)
ns.blockedQueue = {}
do
  local eb = CreateFrame("Frame")
  ns.RegEv(eb, "ADDON_ACTION_BLOCKED")
  ns.RegEv(eb, "ADDON_ACTION_FORBIDDEN")
  eb:SetScript("OnEvent", function(_, ev, addon, func)
    -- 1.1 (P48): bis das Test Log laeuft hier merken, DebugLog traegt es nach
    if not ns.testLogLive then
      ns.blockedEarly = ns.blockedEarly or {}
      if #ns.blockedEarly < 20 then
        ns.blockedEarly[#ns.blockedEarly + 1] = { ev, addon, func, ns.Api and ns.Api.LastProt and ns.Api.LastProt() or nil,
          ns.BlockStack and ns.BlockStack() or nil }
      end
    end
    if ns.OnBlocked then ns.OnBlocked(ev, addon, func) else table.insert(ns.blockedQueue, { ev, addon, func }) end
  end)
end

-- Alle Koordinaten sind ca Werte aus Classic (0 bis 1, also 44,76 = 0.44, 0.76).
-- Das Addon lernt beim Entdecken die echten Positionen dazu und korrigiert sich selbst.

-- Gemeinsamer Teil fuer alle Horde Voelker, ab da laufen die Wege zusammen.
-- Reihenfolge abgeglichen mit Forever Guides (Eternadex, Skycoach, Wowhead).
-- Texte wie "SHENDRALAS" sind neue Forever Zonen, deren Karten ID beim Einloggen gesucht wird.
local SHARED = {
  1442, 1440, 1424, 1441,                         -- Steinkrallen 21, Eschental 24, Huegelland 27, Nadeln 30
  1417, 1445, 1443, 1434,                         -- Arathi 32, Duestermarschen 34, Desolace 36, Schlingendorn 38
  "SHENDRALAS", 2548, 1418, 1435,                 -- Shen'dralas 41, Riverglades 43, Oedland, Suempfe
  1446, 1444, 1425, 1427,                         -- Tanaris 45, Feralas 47, Hinterland 49, Sengende Schlucht
  1449, 1447, 1428, 1448,                         -- Un'Goro 51, Azshara, Brennende Steppe 53, Teufelswald 54
  1422, 1423, 1451, 1452, 2482,                   -- West Pest 56, Ost Pest 57, Silithus 58, Winterquell 59, Hyjal 60
}

-- neue Forever Zonen: Name zum Suchen und Levelbereich
ns.foreverZones = {
  SHENDRALAS = { find = { "shen'dralas", "shendralas" }, min = 40, max = 45, area = 42, q = 16 },
  ZEPHRAS    = { find = { "zephras" }, min = 1, max = 12, area = 6, q = 40 },
}

-- Startgebiet und erste Zonen je Volk, bis sie sich im Brachland treffen
-- entry: welcher Punkt der Zone zuerst angelaufen wird (da kommt man an)
-- Wie der gratis RestedXP Forever Guide: Orc und Troll (ausser Jaeger und Schamane) machen mit 10
-- noch Tirisfal und den Silberwald mit, weil es dort neue Forever Quests gibt. Jaeger und Schamanen
-- gehen direkt ins Brachland (Klassenquests dort). Tauren gehen immer direkt ins Brachland.
-- direct = Route fuer Jaeger und Schamanen
local ORC_ENTRY = { [1411] = TR"Tal der Prüfungen", [1420] = "Brill", [1421] = TR"Maldens Obstgarten", [1413] = TR"Wegekreuz" }
ns.racePlans = {
  Tauren  = { name = "Tauren", start = { 1412, 1413 }, entry = { [1412] = TR"Camp Narache" } },
  Orc     = { name = "Orc", start = { 1411, 1420, 1421, 1413 }, direct = { 1411, 1413 }, entry = ORC_ENTRY },
  Troll   = { name = "Troll", start = { 1411, 1420, 1421, 1413 }, direct = { 1411, 1413 }, entry = ORC_ENTRY },
  Scourge = { name = DE_EN("Untote", "Undead"), start = { 1420, 1421, 1413 }, entry = { [1420] = TR"Todesmal", [1421] = TR"Maldens Obstgarten", [1413] = TR"Wegekreuz" } },
}
-- Skyborne (Forever): Zephras Isle bis ca 12, dann Silberwald (Jaeger direkt ins Brachland)
ns.racePlans.Skyborne = { name = "Skyborne", start = { "ZEPHRAS", 1421, 1413 }, directClass = { HUNTER = true },
  direct = { "ZEPHRAS", 1413 }, entry = { [1421] = TR"Maldens Obstgarten", [1413] = TR"Wegekreuz" } }
ns.racePlans.Windshaper = ns.racePlans.Skyborne
-- unbekanntes Volk: wie Orc, ausser man steht auf Zephras Isle
ns.racePlans.Goblin = ns.racePlans.Orc
ns.racePlans.BloodElf = ns.racePlans.Scourge

------------------------------------------------------------
-- Allianz: eigene Startgebiete und eigener Level Plan
-- Reihenfolge wie die bekannten Classic Allianz Wege (Westfall, Loch Modan, Dunkelkueste, Rotkamm,
-- Daemmerwald, Sumpfland ...), ab 30 viele gemeinsame Zonen mit Allianz Lagern.
-- levels = feste Abschnitte fuers Startgebiet
------------------------------------------------------------
ns.racePlansAlliance = {
  Human    = { name = DE_EN("Mensch", "Human"), start = { 1429, 1436 }, levels = { { 1429, 1, 10 }, { 1436, 10, 14 } }, entry = { [1429] = TR"Nordhaintal" } },
  Dwarf    = { name = DE_EN("Zwerg", "Dwarf"), start = { 1426, 1432 }, levels = { { 1426, 1, 11 }, { 1432, 11, 14 } }, entry = { [1426] = TR"Coldridge Tal" } },
  Gnome    = { name = DE_EN("Gnom", "Gnome"), start = { 1426, 1432 }, levels = { { 1426, 1, 11 }, { 1432, 11, 14 } }, entry = { [1426] = TR"Coldridge Tal" } },
  NightElf = { name = DE_EN("Nachtelf", "Night Elf"), start = { 1438, 1439 }, levels = { { 1438, 1, 11 }, { 1439, 11, 16 } }, entry = { [1438] = "Shadowglen" } },
  -- Skyborne gibt es auch bei der Allianz: Start auf Zephras Isle (bis ca 13, dann mit dem Himmelsschiff nach Dalaran,
  -- die Questreihe geht weiter nach Sturmwind und Westfall).
  -- Vorher fiel die Allianz Skyborne auf den Menschen Plan zurueck und die Route schickte sie nach Elwynn.
  Skyborne = { name = "Skyborne", start = { "ZEPHRAS" }, levels = { { "ZEPHRAS", 1, 13 } }, entry = {} },
}
ns.racePlansAlliance.Windshaper = ns.racePlansAlliance.Skyborne
ns.levelPlanAlliance = nil -- wird aus den Zonen erzeugt
local STARTZONES_A = { 1429, 1426, 1438, 1436, 1432, 1439 }
ns.travelHintAlliance = {
  ["1429>1436"] = TR"Aus Elwynn nach Westen über die Brücke nach Westfall, Spähkuppe ist das Lager.",
  ["1426>1432"] = TR"Durch den Tunnel im Osten von Dun Morogh nach Loch Modan, Thelsamar ist das Lager.",
  ["1438>1439"] = TR"In Rut'theran das Boot nach Auberdine nehmen.",
  ["1436>1432"] = TR"Mit der Tiefenbahn von Sturmwind nach Eisenschmiede, dann durch Dun Morogh nach Loch Modan.",
  ["1429>1432"] = TR"Mit der Tiefenbahn von Sturmwind nach Eisenschmiede, dann durch Dun Morogh nach Loch Modan.",
  ["1433>1432"] = TR"Mit der Tiefenbahn von Sturmwind nach Eisenschmiede, dann durch Dun Morogh nach Loch Modan.",
  ["1432>1429"] = TR"Durch Dun Morogh nach Eisenschmiede, dann mit der Tiefenbahn nach Sturmwind.",
  ["1432>1436"] = TR"Durch Dun Morogh nach Eisenschmiede, dann mit der Tiefenbahn nach Sturmwind.",
  ["1432>1433"] = TR"Durch Dun Morogh nach Eisenschmiede, dann mit der Tiefenbahn nach Sturmwind.",
  ["1432>1439"] = TR"Über das Sumpfland nach Menethil, dort das Schiff nach Auberdine.",
  ["1439>1433"] = TR"Schiff Auberdine nach Menethil, dann fliegen oder laufen nach Seenhain.",
  ["ZEPHRAS>1436"] = TR"Nach der letzten Startquest mit dem Himmelsschiff nach Dalaran, dann nach Sturmwind zu Bolvar und weiter nach Westfall zur Spähkuppe.",
}

-- Startzonen, die ein Volk nicht braucht, kommen ganz ans Ende zum Erkunden
local STARTZONES = { 1412, 1411, 1420, 1421 }

-- Hauptstaedte liegen in einer Zone, Questgeber dort werden in die Zone umgerechnet
ns.cityParent = { [1454] = 1411, [1456] = 1412, [1458] = 1420, -- Orgrimmar, Donnerfels, Unterstadt
  [1453] = 1429, [1455] = 1426, [1457] = 1438 }                  -- Sturmwind, Eisenschmiede, Darnassus

-- Hinweis beim Wechsel in die naechste Zone
ns.travelHint = {
  ["1412>1413"] = TR"Aus Mulgore nach Osten raus ins Brachland. Ruhestein in Wegekreuz oder Camp Taurajo setzen, Flugpunkte mitnehmen.",
  ["1411>1413"] = TR"Aus Durotar nach Westen über die Brücke nach Wegekreuz. Ruhestein in Wegekreuz setzen.",
  ["1411>1420"] = TR"Vor Orgrimmar den Zeppelin nach Tirisfal nehmen, dann nach Brill. Ruhestein in Brill setzen.",
  ["1420>1421"] = TR"Von Brill nach Südwesten, der Strasse nach in den Silberwald. Flugpunkt beim Grabmal holen.",
  ["1421>1413"] = TR"Zurück nach Tirisfal, beim Turm vor Unterstadt den Zeppelin nach Orgrimmar nehmen, dann über Durotar nach Wegekreuz.",
  ["ZEPHRAS>1413"] = TR"Nach der letzten Startquest mit dem Himmelsschiff nach Mulgore, dann nach Orgrimmar zu Thrall und über Durotar nach Wegekreuz.",
  ["ZEPHRAS>1421"] = TR"Nach der letzten Startquest mit dem Himmelsschiff nach Mulgore, dann nach Orgrimmar zu Thrall, Zeppelin nach Tirisfal und in den Silberwald zum Grabmal.",
  ["1434>SHENDRALAS"] = TR"Shen'dralas liegt zwischen Desolace und Mulgore, rein geht es durchs Knochental im Süden von Desolace.",
  ["SHENDRALAS>2548"] = TR"Riverglades liegt östlich vom Ödland. Zu Fuss über das Ödland, oder mit dem Schiff von Steamwheedle Port in Tanaris nach Powderfuse Port. Die Horde Quests starten bei Rog'mar.",
  ["1452>2482"] = TR"Hyjal: durch die Darkwhisper Schlucht im Süden von Winterquell.",
}

-- Karten ID einer neuen Forever Zone ueber den Namen suchen (einmal pro Login)
local resolved = {}
function ns.ResolveForeverZones()
  if not (C_Map and C_Map.GetMapInfo) then return end
  local todo = {}
  for key, z in pairs(ns.foreverZones) do if not resolved[key] then todo[key] = z end end
  if not next(todo) then return end
  -- zuerst echte Zonen Karten (Typ 3), sonst irgendeine Karte mit dem Namen
  local loose = {}
  for id = 1, 3500 do
    local ok, info = pcall(C_Map.GetMapInfo, id)
    if ok and info and type(info.name) == "string" then
      local n = info.name:lower()
      for key, z in pairs(todo) do
        if not resolved[key] then
          for _, pat in ipairs(z.find) do
            if n:find(pat, 1, true) then
              if info.mapType == 3 then resolved[key] = id elseif not loose[key] then loose[key] = id end
              break
            end
          end
        end
      end
    end
  end
  for key, id in pairs(loose) do if not resolved[key] then resolved[key] = id end end
  for key, id in pairs(resolved) do
    local z = ns.foreverZones[key]
    if not ns.zones[id] then ns.zones[id] = { min = z.min, max = z.max, area = z.area, q = z.q } end
  end
end

local function R(id)
  if type(id) == "string" then return resolved[id] end
  return id
end

-- Startgebiet waehlen (Forever): zb als Taure mit einem Freund im Skyborne Startgebiet anfangen.
-- db.startPlan = Schluessel vom Volk, dessen Startgebiet du nimmst (nil = dein eigenes)
local OWNKEY = { Troll = "Orc", Gnome = "Dwarf", Windshaper = "Skyborne", Goblin = "Orc", BloodElf = "Scourge" }
function ns.OwnStartKey()
  local _, race = UnitRace("player")
  return OWNKEY[race or ""] or race or "Orc"
end
function ns.CurStartKey() return (ns.db and ns.db.startPlan) or ns.OwnStartKey() end
function ns.StartZoneOf(key)
  local p = ns.racePlans[key or ""] or ns.racePlansAlliance[key or ""]
  return p and R(p.start[1]) or nil
end
-- alle Startgebiete deiner Fraktion: { key, zone, name }
function ns.StartAreas()
  local out = {}
  local ally = UnitFactionGroup and UnitFactionGroup("player") == "Alliance"
  local keys = ally and { "Human", "Dwarf", "NightElf" } or { "Tauren", "Orc", "Scourge", "Skyborne" }
  for _, k in ipairs(keys) do
    local p = ally and ns.racePlansAlliance[k] or ns.racePlans[k]
    local z = p and R(p.start[1])
    if z then
      local zn = ns.ZoneName and ns.ZoneName(z) or tostring(z)
      local e = p.entry and p.entry[z]
      out[#out + 1] = { key = k, zone = z, name = (e and e ~= zn) and (zn .. ", " .. e) or zn }
    end
  end
  return out
end

function ns.SetupRace()
  ns.ResolveForeverZones()
  local _, race = UnitRace("player")
  local over = ns.db and ns.db.startPlan
  if UnitFactionGroup and UnitFactionGroup("player") == "Alliance" then
    return ns.SetupAlliance((over and ns.racePlansAlliance[over]) and over or race)
  end
  local plan = (over and ns.racePlans[over]) or ns.racePlans[race or ""]
  -- unbekanntes Volk auf Zephras Isle: Skyborne
  if not plan then
    local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if here and here == resolved.ZEPHRAS then plan = ns.racePlans.Skyborne end
  end
  plan = plan or ns.racePlans.Orc
  ns.race, ns.racePlan = race, plan
  ns.levelPlan = ns.AutoLevelPlan(false)
  local order, seen = {}, {}
  local function Push(id)
    id = R(id)
    if id and not seen[id] then seen[id] = true; table.insert(order, id) end
  end
  local _, cls = UnitClass("player")
  local directCls = plan.directClass or { HUNTER = true, SHAMAN = true }
  local start = (plan.direct and cls and directCls[cls]) and plan.direct or plan.start
  ns.raceStart = start
  for _, id in ipairs(start) do Push(id) end
  -- Reihenfolge ab Brachland wie im Level Plan (erster Besuch zaehlt), danach der Rest
  for _, sg in ipairs(ns.levelPlan or {}) do Push(sg[1]) end
  for _, id in ipairs(SHARED) do Push(id) end
  for _, id in ipairs(STARTZONES) do Push(id) end
  ns.zoneOrder = order
  -- Plan Abschnitte mit echten Karten IDs: zuerst die Startgebiete (wie RestedXP), dann der Level Plan
  ns.plan = {}
  local steps = { 12, 14 } -- bis wann Startgebiet, bis wann der Abstecher (Tirisfal, Silberwald)
  local lv = 1
  for k, id in ipairs(start) do
    local rid = R(id)
    if rid == 1413 then break end
    local upto = (k == 1) and ((#start > 2 and rid == 1411) and 10 or 12) or ((rid == 1420) and 12 or 14)
    if rid then table.insert(ns.plan, { rid, lv, upto }) end
    lv = upto
  end
  -- Silberwald nur fuer die, deren Start ihn hat (Orc und Troll mit 10, Untote). Tauren, Jaeger und Schamanen
  -- gehen direkt ins Brachland (wie im RestedXP Guide)
  local inStart = {}
  for _, id in ipairs(start) do local rid = R(id); if rid then inStart[rid] = true end end
  for _, sg in ipairs(ns.levelPlan or {}) do
    local id = R(sg[1])
    if id and not (id == 1421 and not inStart[1421]) then table.insert(ns.plan, { id, sg[2], sg[3] }) end
  end
  ns.entry = plan.entry or {}
  -- Reisehinweise mit gefundenen IDs
  local hints = {}
  for k, v in pairs(ns.travelHint) do
    local a, b = k:match("^(.-)>(.-)$")
    local ra, rb = R(tonumber(a) or a), R(tonumber(b) or b)
    if ra and rb then hints[ra .. ">" .. rb] = v end
  end
  ns.travelHint = hints
end

-- Allianz: eigener Plan, Horde Hubs und Horde Flugpunkte gelten nicht
function ns.SetupAlliance(race)
  local plan = ns.racePlansAlliance[race or ""] or ns.racePlansAlliance.Human
  ns.race, ns.racePlan, ns.faction = race, plan, "Alliance"
  ns.levelPlan = ns.AutoLevelPlan(true)
  ns.hubs, ns.fp = {}, {}
  ns.travelHint = ns.travelHintAlliance
  local order, seen = {}, {}
  local function Push(id)
    id = R(id)
    if id and not seen[id] then seen[id] = true; table.insert(order, id) end
  end
  ns.raceStart = plan.start
  for _, id in ipairs(plan.start) do Push(id) end
  for _, sg in ipairs(ns.levelPlan) do Push(sg[1]) end
  for _, id in ipairs(SHARED) do Push(id) end
  for _, id in ipairs(STARTZONES_A) do Push(id) end
  ns.zoneOrder = order
  ns.plan = {}
  for _, sg in ipairs(plan.levels) do
    -- neue Forever Zonen (zB "ZEPHRAS") erst ueber die Karten ID, sonst weglassen
    local id = R(sg[1])
    if id then table.insert(ns.plan, { id, sg[2], sg[3] }) end
  end
  for _, sg in ipairs(ns.levelPlan) do
    local id = R(sg[1])
    if id then table.insert(ns.plan, { id, sg[2], sg[3] }) end
  end
  ns.entry = plan.entry or {}
  local hints = {}
  for k, v in pairs(ns.travelHint) do
    local a, b = k:match("^(.-)>(.-)$")
    local ra, rb = R(tonumber(a) or a), R(tonumber(b) or b)
    if ra and rb then hints[ra .. ">" .. rb] = v end
  end
  ns.travelHint = hints
end

-- Standard bis zum Einloggen
ns.zoneOrder = { 1412, 1413 }
for _, id in ipairs(SHARED) do if type(id) == "number" then table.insert(ns.zoneOrder, id) end end
for _, id in ipairs({ 1411, 1420, 1421 }) do table.insert(ns.zoneOrder, id) end
ns.entry = {}

-- Level Plan wird aus den Levelbereichen der Zonen erzeugt (keine Guide Daten mehr).
-- Die optimierte Route sucht sich die besten Quests in allen passenden Zonen selbst.
local START_H = { [1412] = true, [1411] = true, [1420] = true }
local START_A = { [1429] = true, [1426] = true, [1438] = true, [1436] = true, [1432] = true, [1439] = true }
-- Zonen der anderen Fraktion ohne eigene Quest Lager: Silberwald (Horde), Rotkamm, Daemmerwald, Sumpfland (Allianz)
local ONLY_H = { [1421] = true }
local ONLY_A = { [1433] = true, [1431] = true, [1437] = true }
-- Gebiet der anderen Fraktion (Startgebiete, Hauptstaedte, Zonen ohne eigene Lager): dort nicht farmen
local CAP_A = { [1453] = true, [1455] = true, [1457] = true }
local CAP_H = { [1454] = true, [1456] = true, [1458] = true }
function ns.EnemyZone(map)
  if not map then return false end
  local alliance = UnitFactionGroup and UnitFactionGroup("player") == "Alliance"
  if alliance then return (START_H[map] or ONLY_H[map] or CAP_H[map]) and true or false end
  return (START_A[map] or ONLY_A[map] or CAP_A[map]) and true or false
end
function ns.AutoLevelPlan(alliance)
  local list = {}
  for id, z in pairs(ns.zones) do
    local skip = alliance and (START_H[id] or ONLY_H[id]) or (not alliance and (START_A[id] or ONLY_A[id]))
    if not skip and (z.min or 0) >= 10 then table.insert(list, { id, z.min, z.max, z.area or z.min }) end
  end
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[4] < b[4] end)
  local out = {}
  for _, e in ipairs(list) do table.insert(out, { e[1], e[2], e[3] }) end
  return out
end
ns.levelPlan = {}

-- Levelbereich der Zone und durchschnittliches Gebiets Level fuer die Erkundungs XP
ns.zones = {
  [1412] = { min = 1,  max = 12, area = 6 },  -- Mulgore
  [1413] = { min = 12, max = 25, area = 16 }, -- Brachland (RestedXP: 12 bis 22)
  [1411] = { min = 1,  max = 12, area = 6 },  -- Durotar
  [1420] = { min = 1,  max = 12, area = 6 },  -- Tirisfal
  [1421] = { min = 11, max = 20, area = 15 }, -- Silberwald (RestedXP: 12 bis 14)
  [1424] = { min = 20, max = 30, area = 25 }, -- Huegelland
  [1440] = { min = 18, max = 30, area = 25 }, -- Eschental
  [1442] = { min = 15, max = 27, area = 22 }, -- Steinkrallen
  [1443] = { min = 30, max = 40, area = 35 }, -- Desolace
  [1441] = { min = 25, max = 35, area = 30 }, -- Tausend Nadeln
  -- ab hier ohne eigene Erkundungspunkte, die Questgeber kommen aus Questie
  [1445] = { min = 35, max = 45, area = 40, q = 25 }, -- Duestermarschen
  [1434] = { min = 30, max = 45, area = 38, q = 35 }, -- Schlingendorntal
  [1417] = { min = 30, max = 40, area = 35, q = 20 }, -- Arathihochland
  [1418] = { min = 35, max = 45, area = 40, q = 15 }, -- Oedland
  [1435] = { min = 35, max = 45, area = 40, q = 12 }, -- Suempfe des Elends
  [2548] = { min = 35, max = 45, area = 40, q = 25 }, -- Riverglades (Forever)
  [1446] = { min = 40, max = 50, area = 45, q = 25 }, -- Tanaris
  [1444] = { min = 40, max = 50, area = 45, q = 25 }, -- Feralas
  [1425] = { min = 40, max = 50, area = 45, q = 20 }, -- Hinterland
  [1427] = { min = 43, max = 50, area = 47, q = 15 }, -- Sengende Schlucht
  [1447] = { min = 45, max = 55, area = 50, q = 12 }, -- Azshara
  [1449] = { min = 48, max = 55, area = 52, q = 20 }, -- Un'Goro Krater
  [1448] = { min = 48, max = 55, area = 52, q = 20 }, -- Teufelswald
  [1428] = { min = 50, max = 58, area = 54, q = 20 }, -- Brennende Steppe
  [1422] = { min = 51, max = 58, area = 55, q = 20 }, -- Westliche Pestlaender
  [1423] = { min = 53, max = 60, area = 57, q = 25 }, -- Oestliche Pestlaender
  [1452] = { min = 55, max = 60, area = 57, q = 20 }, -- Winterquell
  [1451] = { min = 55, max = 60, area = 58, q = 20 }, -- Silithus
  [1430] = { min = 55, max = 60, area = 58, q = 4 },  -- Gebirgspass der Totenwinde (kaum Quests, aber gute Mobs und Kraeuter)
  [1416] = { min = 30, max = 40, area = 35, q = 8 },  -- Alteracgebirge
  [1419] = { min = 45, max = 55, area = 50, q = 10 }, -- Verwuestete Lande
  [2482] = { min = 58, max = 60, area = 60, q = 20 }, -- Hyjal (Forever, laut Guides ab 60, Mobs 54 bis 60)
  -- Allianz Zonen
  [1429] = { min = 1,  max = 10, area = 6, q = 30 },  -- Wald von Elwynn
  [1426] = { min = 1,  max = 12, area = 6, q = 30 },  -- Dun Morogh
  [1438] = { min = 1,  max = 12, area = 6, q = 30 },  -- Teldrassil
  [1436] = { min = 10, max = 20, area = 15, q = 30 }, -- Westfall
  [1432] = { min = 10, max = 20, area = 15, q = 25 }, -- Loch Modan
  [1439] = { min = 10, max = 20, area = 15, q = 30 }, -- Dunkelkueste
  [1433] = { min = 15, max = 25, area = 20, q = 25 }, -- Rotkammgebirge
  [1431] = { min = 18, max = 30, area = 25, q = 30 }, -- Daemmerwald
  [1437] = { min = 20, max = 30, area = 25, q = 25 }, -- Sumpfland
}

-- Erkundungs Wegpunkte pro Zone: { x, y, "Name" }
ns.routes = {
  [1412] = { -- Mulgore
    { 0.44, 0.76, TR"Camp Narache" },
    { 0.54, 0.81, TR"Brachklingenschlucht" },
    { 0.55, 0.73, TR"Die sanften Ebenen" },
    { 0.53, 0.66, TR"Winterhufbrunnen" },
    { 0.47, 0.58, TR"Bluthufdorf" },
    { 0.33, 0.62, TR"Palemane Felsen" },
    { 0.38, 0.56, TR"Steinbullensee" },
    { 0.32, 0.49, TR"Bael'dun Grabungsstätte" },
    { 0.44, 0.44, TR"Donnerhornbrunnen" },
    { 0.53, 0.48, TR"Geplünderte Karawane" },
    { 0.62, 0.45, TR"Mine der Venture Co" },
    { 0.51, 0.30, TR"Die goldenen Ebenen" },
    { 0.61, 0.21, TR"Rote Felsen" },
    { 0.43, 0.15, TR"Wildmähnenbrunnen" },
    { 0.43, 0.09, TR"Windfury Grat" },
    { 0.38, 0.30, TR"Donnerfels" },
  },
  [1413] = { -- Brachland
    { 0.45, 0.58, TR"Camp Taurajo" },
    { 0.47, 0.75, TR"Feld der Riesen" },
    { 0.42, 0.80, TR"Schwarzdornkamm" },
    { 0.48, 0.84, TR"Bael Modan" },
    { 0.51, 0.63, TR"Dornennarbe" },
    { 0.61, 0.54, TR"Nordwacht" },
    { 0.57, 0.52, TR"Raptorgrund" },
    { 0.55, 0.43, TR"Stagnierende Oase" },
    { 0.62, 0.37, RATCHET },
    { 0.46, 0.38, TR"Oase der Wassergrube" },
    { 0.45, 0.23, TR"Die vergessenen Teiche" },
    { 0.47, 0.19, TR"Schreckensnebelgipfel" },
    { 0.56, 0.08, TR"Schlammfenn" },
    { 0.62, 0.05, TR"Felsbrockenmine" },
    { 0.56, 0.20, TR"Grol'doms Hof" },
    { 0.59, 0.26, TR"Dornenhügel" },
    { 0.52, 0.30, TR"Wegekreuz" },
    { 0.61, 0.21, TR"Ferne Wacht" },
  },
  [1411] = { -- Durotar
    { 0.43, 0.68, TR"Tal der Prüfungen" },
    { 0.48, 0.78, TR"Kolkarfelsen" },
    { 0.55, 0.74, TR"Sen'jin" },
    { 0.62, 0.82, TR"Die Echoinseln" },
    { 0.52, 0.43, TR"Klingenhügel" },
    { 0.58, 0.57, TR"Burg Tiragarde" },
    { 0.44, 0.52, TR"Höhle der Brennenden Klinge" },
    { 0.41, 0.47, TR"Klingenmähnengrund" },
    { 0.53, 0.25, TR"Trockenrinnenschlucht" },
    { 0.55, 0.12, TR"Schädelfels" },
    { 0.40, 0.25, TR"Donnergrat" },
    { 0.45, 0.12, "Orgrimmar" },
  },
  [1420] = { -- Tirisfal
    { 0.32, 0.63, TR"Todesmal" },
    { 0.37, 0.62, TR"Sollidens Hof" },
    { 0.46, 0.59, TR"Albtraumtal" },
    { 0.55, 0.55, TR"Kaltherdgut" },
    { 0.61, 0.52, "Brill" },
    { 0.47, 0.33, TR"Agamands Mühlen" },
    { 0.58, 0.34, TR"Garrens Bau" },
    { 0.64, 0.40, TR"Klarwassersee" },
    { 0.84, 0.32, TR"Scharlachrotes Kloster" },
    { 0.85, 0.47, TR"Giftwebtal" },
    { 0.79, 0.56, TR"Vorposten der Kreuzfahrer" },
    { 0.61, 0.67, TR"Ruinen von Lordaeron" },
  },
  [1421] = { -- Silberwald
    { 0.50, 0.14, TR"Maldens Obstgarten" },
    { 0.35, 0.15, TR"Die wuselnde Finsternis" },
    { 0.45, 0.22, TR"Das tote Feld" },
    { 0.52, 0.25, TR"Nordflutmulde" },
    { 0.65, 0.25, TR"Fenrisinsel" },
    { 0.53, 0.32, TR"Valgans Feld" },
    { 0.45, 0.42, TR"Das Grabmal" },
    { 0.56, 0.46, TR"Tiefenelementarmine" },
    { 0.45, 0.56, TR"Olsens Acker" },
    { 0.62, 0.64, "Ambermill" },
    { 0.45, 0.68, TR"Burg Schattenfang" },
    { 0.46, 0.72, TR"Lohenscheit" },
    { 0.56, 0.80, TR"Berens Gefahr" },
  },
  [1424] = { -- Huegelland
    { 0.20, 0.48, TR"Südspitzturm" },
    { 0.28, 0.64, TR"Azurmine" },
    { 0.34, 0.45, TR"Felder von Hügelland" },
    { 0.40, 0.26, TR"Darrowhügel" },
    { 0.54, 0.30, TR"Corrahns Dolch" },
    { 0.60, 0.20, TR"Tarrens Mühle" },
    { 0.75, 0.40, TR"Burg Durnholde" },
    { 0.65, 0.57, TR"Nethanders Hof" },
    { 0.50, 0.57, TR"Süderstade" },
    { 0.40, 0.72, TR"Westlicher Strand" },
  },
  [1440] = { -- Eschental
    { 0.66, 0.82, TR"Gefallener Sternensee" },
    { 0.83, 0.70, TR"Teufelsfeuerhügel" },
    { 0.88, 0.60, TR"Holzfällerlager der Kriegshymnen" },
    { 0.73, 0.61, TR"Splitterholzposten" },
    { 0.67, 0.55, TR"Der nächtliche Lauf" },
    { 0.80, 0.50, "Satyrnaar" },
    { 0.93, 0.37, TR"Astschatten" },
    { 0.60, 0.50, TR"Laubschattentiefe" },
    { 0.52, 0.38, TR"Das heulende Tal" },
    { 0.47, 0.47, TR"Irissee" },
    { 0.50, 0.67, TR"Silberwindzuflucht" },
    { 0.49, 0.70, TR"Mystralsee" },
    { 0.36, 0.50, "Astranaar" },
    { 0.35, 0.35, TR"Dorf der Distelfelle" },
    { 0.30, 0.27, TR"Ruinen von Ordil'Aran" },
    { 0.26, 0.38, TR"Maestras Posten" },
    { 0.20, 0.40, TR"See Falathim" },
    { 0.12, 0.34, TR"Zoram'gar Vorposten" },
    { 0.12, 0.30, TR"Zoramstrand" },
  },
  [1442] = { -- Steinkrallengebirge
    { 0.66, 0.45, TR"Windschnittfelsen" },
    { 0.50, 0.40, TR"Mirkfallonsee" },
    { 0.33, 0.15, TR"Felsenteichsee" },
    { 0.37, 0.10, TR"Steinkrallengipfel" },
    { 0.47, 0.60, TR"Sonnenfels" },
    { 0.55, 0.70, TR"Netzweberpfad" },
    { 0.61, 0.90, TR"Felsrutschschlucht" },
    { 0.73, 0.85, TR"Grimmtotemposten" },
    { 0.72, 0.94, TR"Malaka'jin" },
    { 0.33, 0.65, TR"Das verbrannte Tal" },
  },
  [1443] = { -- Desolace
    { 0.52, 0.10, TR"Tethris Aran" },
    { 0.65, 0.10, TR"Nijelspitze" },
    { 0.75, 0.20, "Sargeron" },
    { 0.55, 0.28, TR"Donneraxtfestung" },
    { 0.56, 0.46, TR"Geistwandlerposten" },
    { 0.72, 0.45, TR"Dorf der Kolkar" },
    { 0.72, 0.72, TR"Dorf der Magram" },
    { 0.80, 0.80, TR"Schattenbruchschlucht" },
    { 0.52, 0.78, TR"Zirkel von Mannoroc" },
    { 0.50, 0.58, TR"Kodofriedhof" },
    { 0.35, 0.55, TR"Tal der Speere" },
    { 0.36, 0.85, TR"Dorf der Gelkis" },
    { 0.40, 0.90, TR"Sar'therisstrand" },
    { 0.24, 0.72, TR"Schattenflucht" },
  },
  [1441] = { -- Tausend Nadeln
    { 0.32, 0.22, TR"Der grosse Aufzug" },
    { 0.35, 0.32, TR"Dunkelwolkenspitze" },
    { 0.12, 0.35, TR"Hochnest" },
    { 0.30, 0.50, TR"Kreischende Schlucht" },
    { 0.38, 0.40, TR"Windbruchschlucht" },
    { 0.46, 0.50, TR"Freiwindposten" },
    { 0.45, 0.60, TR"Bau der Grimmfedern" },
    { 0.62, 0.40, TR"Spalthufklippe" },
    { 0.70, 0.60, TR"Wieselkrater" },
    { 0.85, 0.70, TR"Ruinen von Tahonda" },
    { 0.80, 0.77, TR"Schimmerrennbahn" },
    { 0.77, 0.77, TR"Die Schimmernde Ebene" },
    { 0.71, 0.92, TR"Rostmauls Grabungsstätte" },
  },
}

-- Quest Hubs: { x, y, "Name", minLevel, maxLevel, AnzahlQuests }
ns.hubs = {
  -- Startgebiete und Brachland: Lage, Level und Anzahl Quests abgeglichen mit dem
  -- gratis RestedXP Forever Guide (1 bis 22). Reihenfolge = wann man dort ist.
  [1412] = { -- Mulgore
    { 0.446, 0.764, TR"Camp Narache", 1, 7, 11 },
    { 0.519, 0.807, TR"Brachklingenschlucht", 1, 7, 2 },
    { 0.426, 0.922, TR"Narache Süd", 2, 4, 2 },
    { 0.479, 0.609, TR"Bluthufdorf", 6, 13, 22 },
    { 0.475, 0.559, TR"Bluthufdorf Nord", 6, 11, 10 },
    { 0.551, 0.607, TR"Winterhufbrunnen", 7, 11, 2 },
  },
  [1411] = { -- Durotar
    { 0.426, 0.687, TR"Tal der Prüfungen", 1, 7, 24 },
    { 0.406, 0.626, TR"Tal der Prüfungen Nord", 1, 3, 2 },
    { 0.520, 0.428, TR"Klingenhügel", 4, 15, 30 },
    { 0.455, 0.778, TR"Kolkarfelsen", 5, 8, 2 },
    { 0.555, 0.742, TR"Sen'jin", 6, 10, 8 },
    { 0.520, 0.473, TR"Klingenhügel Süd", 7, 9, 5 },
    { 0.423, 0.302, TR"Donnergrat", 9, 13, 2 },
    { 0.464, 0.229, TR"Nord Durotar", 9, 12, 2 },
    { 0.415, 0.186, TR"Vor Orgrimmar", 9, 13, 2 },
    { 0.564, 0.200, TR"Trockenrinnenschlucht", 10, 12, 2 },
    { 0.386, 0.588, TR"Westrand Durotar", 10, 15, 3 },
  },
  [1420] = { -- Tirisfal
    { 0.315, 0.661, TR"Todesmal", 1, 7, 20 },
    { 0.396, 0.555, TR"Tirisfal Mitte", 5, 8, 2 },
    { 0.606, 0.521, "Brill", 6, 13, 34 },
    { 0.656, 0.605, TR"Brill Süd", 6, 13, 7 },
    { 0.569, 0.545, TR"Kaltherdgut", 6, 8, 2 },
    { 0.593, 0.467, TR"Brill Nord", 7, 12, 2 },
    { 0.219, 0.452, TR"Westliches Tirisfal", 10, 13, 11 },
  },
  [1421] = { -- Silberwald
    { 0.562, 0.092, TR"Silberwald Nord", 12, 14, 2 },
    { 0.535, 0.132, TR"Maldens Obstgarten", 12, 14, 5 },
    { 0.438, 0.408, TR"Das Grabmal", 12, 15, 18 },
    { 0.499, 0.603, TR"Olsens Acker", 12, 14, 2 },
  },
  [1413] = { -- Brachland
    { 0.518, 0.306, TR"Wegekreuz", 11, 22, 43 },
    { 0.558, 0.200, TR"Grol'doms Hof", 10, 15, 3 },
    { 0.621, 0.200, TR"Ferne Wacht", 10, 15, 6 },
    { 0.567, 0.293, TR"Dornenhügel", 12, 14, 2 },
    { 0.628, 0.372, RATCHET, 13, 20, 17 },
    { 0.453, 0.284, TR"Die vergessenen Teiche", 14, 21, 8 },
    { 0.426, 0.117, TR"Nordwestliches Brachland", 14, 22, 6 },
    { 0.516, 0.115, TR"Schlammfenn", 14, 22, 2 },
    { 0.562, 0.070, TR"Felsbrockenmine", 14, 23, 3 },
    { 0.448, 0.591, TR"Camp Taurajo", 11, 23, 10 },
    { 0.501, 0.533, TR"Mittleres Brachland", 16, 19, 2 },
    { 0.352, 0.278, TR"Westrand Brachland", 16, 22, 12 },
    { 0.494, 0.600, TR"Dornennarbe", 18, 20, 2 },
    { 0.434, 0.774, TR"Schwarzdornkamm", 18, 20, 2 },
  },
}

-- Grind Spots: { x, y, "Name", minMobLevel, maxMobLevel }
ns.grind = {
  [1412] = { { 0.52, 0.62, TR"Ebenenschreiter und Präriewölfe", 5, 8 }, { 0.33, 0.60, TR"Gnolle am Palemane Felsen", 6, 9 }, { 0.62, 0.45, TR"Venture Co bei der Mine", 8, 10 } },
  [1413] = { { 0.52, 0.24, TR"Zhevras und Ebenenschreiter", 10, 13 }, { 0.59, 0.25, TR"Klingenmähnen am Dornenhügel", 11, 14 }, { 0.55, 0.42, TR"Kolkar an der Oase", 13, 16 }, { 0.57, 0.52, TR"Raptoren", 15, 18 }, { 0.48, 0.84, TR"Zwerge in Bael Modan", 20, 24 } },
  [1411] = { { 0.58, 0.57, TR"Menschen in Burg Tiragarde", 7, 9 }, { 0.44, 0.52, TR"Brennende Klinge", 7, 9 }, { 0.53, 0.25, TR"Harpyien Trockenrinne", 9, 11 } },
  [1420] = { { 0.37, 0.62, TR"Scharlachrote bei Solliden", 5, 7 }, { 0.47, 0.33, TR"Untote bei Agamand", 8, 11 }, { 0.79, 0.56, TR"Scharlachrote Vorposten", 9, 12 } },
  [1421] = { { 0.52, 0.25, TR"Mondwut Gnolle", 11, 13 }, { 0.56, 0.46, TR"Tiefenelementarmine", 14, 16 }, { 0.65, 0.25, TR"Fenrisinsel", 15, 17 }, { 0.62, 0.64, "Ambermill", 18, 20 } },
  [1424] = { { 0.34, 0.45, TR"Felder von Hügelland", 20, 26 }, { 0.75, 0.40, TR"Burg Durnholde", 25, 30 } },
  [1440] = { { 0.60, 0.50, TR"Laubschattentiefe", 24, 27 }, { 0.35, 0.35, TR"Distelfelle", 24, 27 }, { 0.80, 0.50, "Satyrnaar", 26, 29 } },
  [1442] = { { 0.61, 0.90, TR"Kobolde Felsrutsch", 18, 21 }, { 0.66, 0.45, TR"Venture Co Windschnitt", 19, 23 }, { 0.33, 0.65, TR"Verbranntes Tal", 23, 27 } },
  [1443] = { { 0.72, 0.45, TR"Kolkar Zentauren", 31, 34 }, { 0.72, 0.72, TR"Magram Zentauren", 33, 36 }, { 0.36, 0.85, TR"Gelkis Zentauren", 33, 36 } },
  [1441] = { { 0.62, 0.40, TR"Galak Zentauren", 25, 29 }, { 0.35, 0.32, TR"Grimmtotem Dunkelwolke", 26, 30 }, { 0.77, 0.77, TR"Basilisken Schimmernde Ebene", 30, 34 } },
  [1445] = { { 0.55, 0.70, TR"Krokilisken und Murlocs", 35, 39 }, { 0.40, 0.70, TR"Schlammflossen Murlocs", 37, 41 } },
  [1434] = { { 0.35, 0.12, TR"Raptoren und Tiger Nord", 30, 34 }, { 0.48, 0.40, TR"Mosh'Ogg Oger", 41, 44 }, { 0.30, 0.70, TR"Blutsegel Piraten", 40, 45 } },
  [1417] = { { 0.70, 0.70, TR"Witherbark Trolle", 33, 36 }, { 0.30, 0.60, TR"Syndikat Stromgarde", 34, 38 } },
  [1418] = { { 0.60, 0.70, TR"Staubgurt Oger", 38, 42 }, { 0.20, 0.55, TR"Bussarde und Steinwächter", 37, 41 } },
  [1435] = { { 0.65, 0.70, TR"Sumpf Murlocs", 36, 40 } },
  [1446] = { { 0.60, 0.30, TR"Wüstenwanderer", 41, 45 }, { 0.40, 0.70, TR"Wüstenwanderer Süd", 45, 48 } },
  [1444] = { { 0.72, 0.62, TR"Waldpfoten Gnolle", 41, 44 }, { 0.70, 0.45, TR"Grimmtotem Feralas", 45, 48 } },
  [1425] = { { 0.62, 0.70, TR"Vilebranch Trolle", 45, 50 } },
  [1427] = { { 0.40, 0.40, TR"Dunkeleisen Zwerge", 44, 48 } },
  [1447] = { { 0.25, 0.60, TR"Satyrn Haldarr", 45, 49 } },
  [1449] = { { 0.50, 0.50, TR"Dinosaurier", 48, 54 } },
  [1448] = { { 0.38, 0.60, TR"Jadefeuer Satyrn", 48, 52 }, { 0.62, 0.12, TR"Totholz Furbolgs", 49, 53 } },
  [1428] = { { 0.60, 0.40, TR"Schwarzfels Orcs", 50, 55 } },
  [1422] = { { 0.40, 0.70, TR"Untote in Andorhal", 52, 56 } },
  [1423] = { { 0.50, 0.50, TR"Untote Pestländer", 55, 60 } },
  [1452] = { { 0.68, 0.35, TR"Winterfell Furbolgs", 54, 58 }, { 0.60, 0.60, TR"Chimären", 55, 59 } },
  [1451] = { { 0.50, 0.60, TR"Silithiden", 55, 60 } },
}

-- Horde Flugpunkte: { x, y, "Name", map = andere MapID falls auf einer Stadtkarte }
ns.fp = {
  [1412] = { { 0.469, 0.499, TR"Donnerfels", map = 1456 } },
  [1413] = { { 0.444, 0.591, TR"Camp Taurajo" }, { 0.631, 0.372, RATCHET }, { 0.515, 0.303, TR"Wegekreuz" } },
  [1411] = { { 0.451, 0.639, "Orgrimmar", map = 1454 } },
  [1420] = { { 0.633, 0.486, TR"Unterstadt", map = 1458 } },
  [1421] = { { 0.456, 0.425, TR"Grabmal" } },
  [1424] = { { 0.601, 0.186, TR"Tarrens Mühle" } },
  [1440] = { { 0.732, 0.616, TR"Splitterholzposten" }, { 0.122, 0.338, TR"Zoram'gar Vorposten" } },
  [1442] = { { 0.451, 0.599, TR"Sonnenfels" } },
  [1443] = { { 0.216, 0.741, TR"Schattenflucht" } },
  [1441] = { { 0.451, 0.491, TR"Freiwindposten" } },
  [1445] = { { 0.356, 0.318, "Brackenwall" } },
  [1434] = { { 0.325, 0.293, TR"Grom'gol" }, { 0.269, 0.771, TR"Beutebucht" } },
  [1417] = { { 0.730, 0.327, "Hammerfall" } },
  [1418] = { { 0.040, 0.448, "Kargath" } },
  [1435] = { { 0.461, 0.548, DE_EN("Steinard", "Stonard") } },
  [1446] = { { 0.516, 0.254, "Gadgetzan" } },
  [1444] = { { 0.754, 0.444, TR"Camp Mojache" } },
  [1425] = { { 0.817, 0.818, "Revantusk" } },
  [1427] = { { 0.348, 0.308, TR"Thoriumspitze" } },
  [1447] = { { 0.220, 0.496, "Valormok" } },
  [1449] = { { 0.452, 0.058, TR"Marschalls Zuflucht" } },
  [1448] = { { 0.344, 0.539, TR"Blutgiftposten" } },
  [1428] = { { 0.656, 0.242, TR"Flammenkamm" } },
  [1423] = { { 0.802, 0.570, TR"Kapelle des Hoffnungsvollen Lichts" } },
  [1452] = { { 0.605, 0.363, TR"Ewige Warte" } },
  [1451] = { { 0.487, 0.367, TR"Burg Cenarius" } },
}
-- auf Forever: fest eingetragene Era Punkte auf die neuen Karten
ns.FixLists(ns.routes); ns.FixLists(ns.hubs); ns.FixLists(ns.grind); ns.FixLists(ns.fp)

-- Total XP, um ein Level zu erreichen
ns.xpTotal = {
  [1]=0, [2]=400, [3]=1300, [4]=2700, [5]=4800, [6]=7600, [7]=11200, [8]=15700, [9]=21100, [10]=27600,
  [11]=35200, [12]=44000, [13]=54100, [14]=65500, [15]=78400, [16]=92800, [17]=108800, [18]=126500, [19]=145900, [20]=167200,
  [21]=190400, [22]=215600, [23]=242900, [24]=272300, [25]=304000, [26]=338000, [27]=374400, [28]=413300, [29]=454700, [30]=499000,
  [31]=546400, [32]=597200, [33]=651700, [34]=710300, [35]=773100, [36]=840200, [37]=911800, [38]=987900, [39]=1068700, [40]=1154400,
  [41]=1245100, [42]=1340900, [43]=1441900, [44]=1548200, [45]=1660000, [46]=1777500, [47]=1900700, [48]=2029800, [49]=2164900, [50]=2306100,
  [51]=2453600, [52]=2607500, [53]=2767900, [54]=2935000, [55]=3108900, [56]=3289700, [57]=3477600, [58]=3672600, [59]=3874900, [60]=4084700,
}
