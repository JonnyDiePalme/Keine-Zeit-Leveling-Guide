-- NaviFlug (19.32, Navi Chat, Saschas Log 30.10. 00:42): Fluege, Magier Teleport und Schamanen Rueckruf fuer das Navi.
-- 1. Bekannte Flugpunkte auch ohne Flugkarte lernen: nach jeder Landung (dort kennst du den Flugpunkt sicher) und, wenn
--    das Spiel es sagt (C_TaxiMap.GetTaxiNodesForMap mit isUndiscovered), alle auf einmal. Bisher lernte das Addon sie
--    nur beim Oeffnen der Flugkarte: ein Level 60 nach dem Einrichten kannte keinen einzigen, das Navi lief zu Fuss.
-- 2. Flug Tipp: kennt das Addon die Flugpunkte fuer einen viel schnelleren Weg noch nicht, sagt das Navi das einmal und
--    wie man es aendert (Flugkarte einmal oeffnen). Geplant wird nie ueber Flugpunkte, die du nicht sicher kennst.
-- 3. Teleport (Magier, Rune der Teleportation im Gepaeck) und Astraler Rueckruf (Schamane) als Abkuerzung ab dir.
-- Alles nil sicher: fehlt eine Spiel Funktion oder ein Datenfeld (Forever kann sich aendern), gibt es den Teil einfach nicht.
local ADDON, ns = ...
local TR = ns.TR

local function Now() return GetTime and GetTime() or 0 end
local function Log(kind, text) if ns.TestLog then ns.TestLog(kind, text) end end

------------------------------------------------------------
-- 1. Bekannte Flugpunkte lernen
------------------------------------------------------------
local function Bump()
  local db = ns.db
  if not db then return end
  db.knownFPRev = (db.knownFPRev or 0) + 1
  db.learnedRev = (db.learnedRev or 0) + 1
  if ns.TaxiReset then pcall(ns.TaxiReset) end
end

local function MarkKnown(npc)
  local db = ns.db
  if not (db and npc) then return false end
  db.knownFP = type(db.knownFP) == "table" and db.knownFP or {}
  if db.knownFP[npc] then return false end
  db.knownFP[npc] = true
  return true
end
-- 20.2: sicher bekannt (Landung, Flugkarte): aus den vermuteten nehmen
local function Sicher(npc)
  local db = ns.db
  if db and npc and type(db.fpVermutet) == "table" then db.fpVermutet[npc] = nil end
end
-- ab hier glaubt das Navi dem Spiel auch ohne gemeldete unentdeckte Flugpunkte (FEH K 14:20)
local FP_VERMUTET_LEVEL, FP_VERMUTET_ANZAHL = 30, 8

local function MyFac()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  if f == "Horde" then return "H" elseif f == "Alliance" then return "A" end
end

-- Flugpunkte aus den Spieldaten (Karte\<Client>\Flug.lua): knoten[id] = { ui, x, y, fraktion, en, de, kont, wx, wy, bit, npc }
local function Taxi() local T = ns.TAXI; if type(T) == "table" and type(T.knoten) == "table" then return T end end

-- 20.3l (FEH S 21:47, K J1/J2): offene Flugkarte per Knoten ID lesen (C_TaxiMap.GetAllTaxiNodes), nicht nur per Position.
-- Liefert t[nodeID] = { slot = Nummer fuer TakeTaxiNode, state = Zustand, name = Knoten Name } oder nil (API fehlt, Karte leer).
local function GameSlots(cm)
  if not (cm and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes) then return nil end
  local ok, list = pcall(C_TaxiMap.GetAllTaxiNodes, cm)
  if not (ok and type(list) == "table") then return nil end
  local t, n = {}, 0
  for _, nd in ipairs(list) do
    if type(nd) == "table" and nd.nodeID then
      t[nd.nodeID] = { slot = nd.slotIndex, state = nd.state, name = nd.name }
      n = n + 1
    end
  end
  if n == 0 then return nil end
  return t
end
-- Kontinent Karte (Welt) zur Spieler Karte
local function ContMap()
  local cm = ns.PlayerMap and ns.PlayerMap()
  for _ = 1, 6 do
    local info = cm and C_Map.GetMapInfo(cm)
    if not info or info.mapType == 2 or not info.parentMapID then break end
    cm = info.parentMapID
  end
  return cm
end

-- a) Landung: wo du landest, kennst du den Flugpunkt
local wasTaxi, landAt = false, nil
local function LandCheck()
  local on = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") and true or false
  if on then wasTaxi = true; return end
  if not wasTaxi then return end
  wasTaxi = false
  landAt = Now()
  C_Timer.After(1.5, function()
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (pos and ns.NearestSvc) then return end
    local px, py = pos:GetXY()
    local ok, best, d = pcall(ns.NearestSvc, "fly", map, px, py)
    -- in Staedten stehen die Flugmeister auch unter der Zone (Orgrimmar in Durotar)
    local par = ns.cityParent and ns.cityParent[map]
    if not (ok and best and d and d < 90) and par and ns.ToMap then
      local zx, zy = ns.ToMap(map, px, py, par)
      if zx then ok, best, d = pcall(ns.NearestSvc, "fly", par, zx, zy) end
    end
    if ok and best and best.id then Sicher(best.id) end
    if ok and best and best.id and d and d < 90 and MarkKnown(best.id) then
      Bump()
      Log("FLUG", ("Flugpunkt gelernt bei der Landung: %s"):format(tostring(best.name)))
    end
  end)
end

-- b) das Spiel sagt, welche Flugpunkte unentdeckt sind (gibt es nur in neueren Clients, sonst nichts tun)
local function FromGame()
  local T = Taxi()
  if not (T and C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap and C_Map and C_Map.GetMapInfo) then return 0 end
  local fac = MyFac()
  local conts, seen = {}, {}
  for _, k in pairs(T.knoten) do
    local ui = type(k) == "table" and k[1]
    for _ = 1, 6 do
      local info = ui and C_Map.GetMapInfo(ui)
      if not info then ui = nil; break end
      if info.mapType == 2 or not info.parentMapID then break end
      ui = info.parentMapID
    end
    if ui and not seen[ui] then seen[ui] = true; conts[#conts + 1] = ui end
  end
  -- Pruefer B1: erst sammeln, nur uebernehmen, wenn das Spiel mindestens einen Flugpunkt als unentdeckt meldet (sonst
  -- koennte isUndiscovered vor dem ersten Oeffnen der Flugkarte immer false sein und alles waere "bekannt")
  local n, field, undis, cand = 0, false, 0, {}
  for _, cm in ipairs(conts) do
    local ok, list = pcall(C_TaxiMap.GetTaxiNodesForMap, cm)
    if ok and type(list) == "table" then
      for _, nd in ipairs(list) do
        if type(nd) == "table" and type(nd.isUndiscovered) == "boolean" then
          field = true
          -- Fraktion: 0 neutral, 1 Horde, 2 Allianz
          local f = nd.faction
          local mine = f == nil or f == 0 or (f == 1 and fac == "H") or (f == 2 and fac == "A")
          local k = nd.nodeID and T.knoten[nd.nodeID]
          if mine and nd.isUndiscovered then undis = undis + 1 end
          if mine and not nd.isUndiscovered and type(k) == "table" and (k[11] or 0) > 0 then cand[#cand + 1] = k[11] end
        end
      end
    end
  end
  local db = ns.db
  if field and undis > 0 then
    for _, npc in ipairs(cand) do if MarkKnown(npc) then n = n + 1 end end
    -- 20.2: jetzt sicher, vermutete Flugpunkte sind damit bestaetigt oder falsch
    if db and type(db.fpVermutet) == "table" then
      local ja = {}
      for _, npc in ipairs(cand) do ja[npc] = true end
      for npc in pairs(db.fpVermutet) do if not ja[npc] and db.knownFP then db.knownFP[npc] = nil end end
      db.fpVermutet = nil
    end
    if n > 0 then Bump() end
    Log("FLUG", ("Flugpunkte aus dem Spiel gelesen: %d bekannt, %d unentdeckt, %d neu uebernommen"):format(#cand, undis, n))
  -- 20.3k (K Log Z.6756, Ad FRA 21:40): beim Level 6 Tauren meldete das Spiel 30 Flugpunkte als bekannt (ohne Flugkarte meldet es
  -- alle als bekannt) und die Regel "ab 8 gemeldeten" griff trotz Level 6. Jetzt nur noch nach Level (FP_VERMUTET_LEVEL).
  elseif field and #cand > 0 and not (db and db.fpKarteGesehen) and (UnitLevel and UnitLevel("player") or 1) >= FP_VERMUTET_LEVEL then
    -- 20.2 (FEH K 14:20, Log 14:07 Level 60 ohne Fluege, Loch Modan 1103 s zu Fuss): meldet das Spiel keinen Flugpunkt als
    -- unentdeckt, war das bisher "unsicher" und es wurde nichts uebernommen. Ab Level FP_VERMUTET_LEVEL oder ab
    -- FP_VERMUTET_ANZAHL gemeldeten Flugpunkten gelten sie jetzt als vermutlich bekannt (db.fpVermutet). Beim Oeffnen der
    -- Flugkarte, bei der Landung oder wenn das Spiel spaeter unentdeckte meldet, wird es richtig gestellt.
    db.fpVermutet = type(db.fpVermutet) == "table" and db.fpVermutet or {}
    for _, npc in ipairs(cand) do
      if MarkKnown(npc) then n = n + 1; db.fpVermutet[npc] = true end
    end
    if n > 0 then Bump() end
    Log("FLUG", ("Spiel meldet %d Flugpunkte als bekannt und keinen als unentdeckt: %d als vermutlich bekannt uebernommen (Level %d)")
      :format(#cand, n, UnitLevel and UnitLevel("player") or 0))
  elseif field and db and db.fpKarteGesehen then
    Log("FLUG", ("Spiel meldet %d Flugpunkte als bekannt und keinen als unentdeckt: nichts vermutet (Flugkarte war schon offen, es gilt ihr Stand)"):format(#cand))
  elseif field then
    Log("FLUG", ("Spiel meldet %d Flugpunkte als bekannt und keinen als unentdeckt: nicht uebernommen (unsicher, Level klein)"):format(#cand))
  else
    Log("FLUG", "Spiel sagt nicht, welche Flugpunkte bekannt sind (nur Flugkarte und Landung)")
  end
  return n
end
ns.NaviFlugFromGame = FromGame

-- bekannte Flugmeister auf einem Kontinent (Welt Kontinent wie ns.MapWorld)
function ns.NaviKnownFPOn(cont)
  local n = 0
  for _, f in ipairs(ns.TravelFlightPoints and ns.TravelFlightPoints() or {}) do if f.cont == cont then n = n + 1 end end
  return n
end

------------------------------------------------------------
-- 2. Flug Tipp: wie schnell waere es mit allen Flugpunkten deiner Fraktion?
------------------------------------------------------------
-- pro Kontinent einmal: alle Flugpunkte deiner Fraktion mit NPC und die kuerzesten Flugzeiten dazwischen (Floyd)
local hyp = {}
local function HypNet(cont, fac)
  local T = Taxi()
  if not (T and type(T.kanten) == "table" and ns.MapWorld) then return nil end
  local key = tostring(cont) .. fac
  local h = hyp[key]
  if h and h.src == T then return h end
  local nodes, on = {}, {}
  for id, k in pairs(T.knoten) do
    if type(k) == "table" and (k[11] or 0) > 0 and type(k[4]) == "string" and k[4]:find(fac, 1, true) then
      local c, wx, wy = ns.MapWorld(k[1], k[2], k[3])
      if c == cont then
        nodes[#nodes + 1] = { id = id, npc = k[11], map = k[1], x = k[2], y = k[3], cont = c, wx = wx, wy = wy, name = (ns.EN and k[5] or k[6]) or k[5] or k[6] }
        on[id] = true
      end
    end
  end
  local d = {}
  for _, n in ipairs(nodes) do d[n.id] = { [n.id] = 0 } end
  for _, e in ipairs(T.kanten) do
    local a, b, s = e[1], e[2], e[3]
    if on[a] and on[b] and type(s) == "number" and (not d[a][b] or s < d[a][b]) then d[a][b] = s end
  end
  for _, kk in ipairs(nodes) do
    local k = kk.id
    local dk = d[k]
    for _, ii in ipairs(nodes) do
      local di = d[ii.id]
      local ik = di[k]
      if ik then
        for _, jj in ipairs(nodes) do
          local kj = dk[jj.id]
          if kj and (not di[jj.id] or ik + kj < di[jj.id]) then di[jj.id] = ik + kj end
        end
      end
    end
  end
  h = { src = T, nodes = nodes, d = d }
  hyp[key] = h
  return h
end

local TIP_MIN_SAVE, TIP_MIN_PART = 180, 0.25
-- S, G: Navi Punkte { map, x, y, cont, wx, wy }. total: geplante Zeit ohne diese Fluege. Ergebnis { save, at, to } oder nil
function ns.NaviFlugTipp(S, G, speed, total)
  if not (S and G and S.cont and S.cont == G.cont and total and total > TIP_MIN_SAVE) then return nil end
  if ns.db and ns.db.useFlights == false then return nil end
  local lvl = UnitLevel and UnitLevel("player") or 1
  if lvl < 10 then return nil end
  local fac = MyFac()
  if not fac then return nil end
  local h = HypNet(S.cont, fac)
  if not (h and #h.nodes > 1) then return nil end
  local TV = ns.TRAVEL or { PATH = 1.2, FLY_OVER = 25 }
  local path, over = TV.PATH or 1.2, TV.FLY_OVER or 25
  local function Near(p)
    local t = {}
    for _, n in ipairs(h.nodes) do
      t[#t + 1] = { n = n, d = math.sqrt((n.wx - p.wx) ^ 2 + (n.wy - p.wy) ^ 2) }
    end
    table.sort(t, function(a, b) return a.d < b.d end)
    return t
  end
  local na, nb = Near(S), Near(G)
  local best, ba, bb
  for i = 1, math.min(3, #na) do
    for j = 1, math.min(3, #nb) do
      local a, b = na[i], nb[j]
      local fly = a.n ~= b.n and h.d[a.n.id] and h.d[a.n.id][b.n.id]
      if fly then
        local t = (a.d + b.d) * path / speed + fly + over
        if not best or t < best then best, ba, bb = t, a.n, b.n end
      end
    end
  end
  if not best then return nil end
  local save = total - best
  if save < TIP_MIN_SAVE or save < total * TIP_MIN_PART then return nil end
  local known = (ns.db and ns.db.knownFP) or {}
  -- kennst du beide schon, plant das Navi den Flug ohnehin selbst (dann fehlt nur eine Strecke dazwischen)
  if known[ba.npc] and known[bb.npc] then return nil end
  return { save = save, at = ba, to = bb, atKnown = known[ba.npc] and true or false, toKnown = known[bb.npc] and true or false }
end

-- Text fuer Chat und Mini Fenster
function ns.NaviFlugTippText(tp, short)
  if not tp then return nil end
  local clock = ns.Clock and ns.Clock(tp.save) or (math.floor(tp.save / 60) .. " Min")
  if short then return (TR"Mit Flug ca %s schneller, Flugpunkte unbekannt"):format(clock) end
  local nk = ns.db and ns.db.knownFP and next(ns.db.knownFP) and true or false
  if not nk then
    return (TR"Navi: Mit Flug wäre es ca %s schneller, aber das Addon kennt deine Flugpunkte noch nicht. Öffne einmal bei einem Flugmeister die Flugkarte, dann rechnet das Navi mit deinen Flügen neu."):format(clock)
  end
  local miss = (not tp.atKnown) and tp.at or tp.to
  return (TR"Navi: Mit Flug wäre es ca %s schneller, dafür fehlt der Flugpunkt %s. Kennst du ihn schon, öffne einmal die Flugkarte, dann rechnet das Navi neu."):format(clock, tostring(miss and miss.name or "?"))
end

------------------------------------------------------------
-- 3. Teleport (Magier) und Astraler Rueckruf (Schamane)
------------------------------------------------------------
-- Ankunft aus den Server Daten (spell_target_position): Kontinent, Welt X, Welt Y, Stadt Karte. Der echte Ort wird nach
-- dem ersten eigenen Teleport gemessen und geht dann vor (db.naviPortal, fuer den ganzen Account).
local RUNE = 17031 -- Rune der Teleportation
local PORTS = {
  { spell = 3567, fac = "H", cont = 1, wx = 1469.85, wy = -4221.52, map = 1454, name = "Orgrimmar" },
  { spell = 3563, fac = "H", cont = 0, wx = 1773.47, wy = 61.12, map = 1458, name = "Undercity" },
  { spell = 3566, fac = "H", cont = 1, wx = -964.98, wy = 283.43, map = 1456, name = "Thunder Bluff" },
  { spell = 3561, fac = "A", cont = 0, wx = -9003.46, wy = 870.03, map = 1453, name = "Stormwind" },
  { spell = 3562, fac = "A", cont = 0, wx = -4613.62, wy = -915.38, map = 1455, name = "Ironforge" },
  { spell = 3565, fac = "A", cont = 1, wx = 9660.81, wy = 2513.64, map = 1457, name = "Darnassus" },
}
local CAST_PORT = 10
local RECALL = 556 -- Astraler Rueckruf, bringt dich zum Ruhestein Ort

local function Known(spell)
  if IsPlayerSpell then local ok, r = pcall(IsPlayerSpell, spell); if ok and r then return true end end
  if IsSpellKnown then local ok, r = pcall(IsSpellKnown, spell); if ok and r then return true end end
  return false
end
local function SpellLeft(spell)
  local gc = (C_Spell and C_Spell.GetSpellCooldown) or ns.Api.GetSpellCooldown
  if not gc then return 0 end
  local ok, a, b = pcall(gc, spell)
  if not ok then return 0 end
  local st, dur
  if type(a) == "table" then st, dur = a.startTime, a.duration else st, dur = a, b end
  if st and st > 0 and dur and dur > 1.5 then return math.max(0, st + dur - Now()) end
  return 0
end

-- Ziel Punkt eines Teleports als Navi Knoten (Stadt Karte), nil wenn das Spiel ihn nicht umrechnen kann
local function PortNode(p)
  local m = ns.db and type(ns.db.naviPortal) == "table" and ns.db.naviPortal[p.spell]
  if type(m) == "table" and m[1] and m[2] and m[3] and ns.MapWorld then
    local c, wx, wy = ns.MapWorld(m[1], m[2], m[3])
    if c then return { map = m[1], x = m[2], y = m[3], cont = c, wx = wx, wy = wy, name = (ns.ZoneName and ns.ZoneName(p.map)) or p.name, port = p.spell, measured = true } end
  end
  if not (C_Map and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return nil end
  local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, p.cont, CreateVector2D(p.wx, p.wy), p.map)
  if not (ok and pos) then return nil end
  local x, y = pos:GetXY()
  if not (x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1) then return nil end
  local c, wx, wy = ns.MapWorld(p.map, x, y)
  if not c then return nil end
  local zn = ns.ZoneName and ns.ZoneName(p.map)
  return { map = p.map, x = x, y = y, cont = c, wx = wx, wy = wy, name = zn or p.name, port = p.spell }
end

------------------------------------------------------------
-- 5. Portale der Gruppe (AUF 06:44, S 06:40, f72; ANT 07:34: EIN Kanal, die Nachrichten macht Group.lua von Ad)
------------------------------------------------------------
-- Group.lua tauscht die Portale der Mitspieler MIT Addon aus (ns.GroupPortals() = Liste { who, portal, tele, runes },
-- nur Partner mit Rune der Portale und Nachricht juenger als 10 Min) und ihre Position (ns.group[who].pos = { Karte, x, y }).
-- Hier nur der Weg: ein Mitspieler in der Naehe (PARTNER_NEAR yd), der das Portal kann, ist wie ein Teleport, aber mit
-- Wartezeit: "Portal von <Name> nach X". Ohne Addon beim Partner, zu weit weg oder Gruppe weg: nichts.
-- Schalter ns.db.partyPorts (Standard an).
local PARTNER_NEAR, PARTNER_WAIT = 120, 45
local function PartyOn() return ns.db and ns.db.partyPorts ~= false and ns.db.naviPorts ~= false end
local function MyWorld()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(map, "player")
  if not (pos and ns.MapWorld) then return nil end
  local x, y = pos:GetXY()
  if not (x and y) then return nil end
  return ns.MapWorld(map, x, y)
end
local function PartyJumps(out)
  if not (PartyOn() and ns.GroupPortals and type(ns.group) == "table") then return end
  local list = ns.GroupPortals()
  if type(list) ~= "table" or #list == 0 then return end
  local mc, mwx, mwy = MyWorld()
  if not mc then return end
  local fac = MyFac()
  for _, e in ipairs(list) do
    local g = ns.group[e.who]
    local gp = g and g.pos
    if gp and gp[1] and gp[2] and gp[3] and not (UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, e.who))
      and not (UnitIsConnected and ns.Api.U(UnitIsConnected, e.who) == false) then
      local c, wx, wy = ns.MapWorld(gp[1], gp[2], gp[3])
      if c and c == mc then
        local d = math.sqrt((wx - mwx) ^ 2 + (wy - mwy) ^ 2)
        if d <= PARTNER_NEAR then
          for _, p in ipairs(PORTS) do
            if p.spell == e.tele and p.fac == fac then
              local n = PortNode(p)
              if n then
                local cp = {}
                for k, v in pairs(n) do cp[k] = v end
                cp.port, cp.partner = nil, e.who -- kein eigener Zauber, das Portal macht der Partner
                out[#out + 1] = { node = cp, sec = PARTNER_WAIT + d * 1.2 / 7, kind = "portal", partner = e.who,
                  text = (TR"Portal von %s nach %s"):format(e.who, cp.name or p.name) }
              end
            end
          end
        end
      end
    end
  end
end

-- Abkuerzungen ab deinem Standort: { node, sec, text, kind }
function ns.NaviJumps()
  local out = {}
  if ns.db and ns.db.naviPorts == false then return out end
  local _, cls
  if UnitClass then _, cls = UnitClass("player") end -- nicht "x and f()", das gibt nur den ersten Wert
  if cls == "MAGE" and ns.Api.GetItemCount and (ns.Api.GetItemCount(RUNE) or 0) > 0 then
    local fac = MyFac()
    for _, p in ipairs(PORTS) do
      if p.fac == fac and Known(p.spell) and SpellLeft(p.spell) <= 0 then
        local n = PortNode(p)
        if n then out[#out + 1] = { node = n, sec = CAST_PORT, kind = "portal", text = (TR"Teleport nach %s"):format(n.name or p.name) } end
      end
    end
  end
  pcall(PartyJumps, out)
  return out
end

-- Schamane: Astraler Rueckruf, wenn der Ruhestein abklingt (gleiches Ziel wie der Ruhestein)
function ns.NaviRecallReady()
  local _, cls
  if UnitClass then _, cls = UnitClass("player") end -- nicht "x and f()", das gibt nur den ersten Wert
  if cls ~= "SHAMAN" then return false end
  return Known(RECALL) and SpellLeft(RECALL) <= 0
end

------------------------------------------------------------
-- 4. Ruhestein Ort nach dem Einrichten (19.32, Freigabe Koordination 02:05): das Addon lernt ihn beim Binden und nach
--    jedem Ruhestein (Services.lua). Vorher war er unbekannt, das Navi nahm den Ruhestein dann nie. Hier zusaetzlich aus
--    GetBindLocation (Name des Ortes):
--    Regeln siehe ns.RateBind (19.33 gemeinsam mit Services.lua). Sonst bleibt der Ort unbekannt.
--    Ist er falsch, plant das Navi nach dem Ruhestein ab dort neu.
------------------------------------------------------------
local function SetBind(map, x, y, why)
  local db = ns.db
  if not (db and map and x and y) or db.bindInn then return end
  db.bindInn, db.bindZone = { map, x, y }, map
  Log("NAVI", ("Ruhestein Ort aus dem Spiel gelernt (%s): Karte %s %.3f,%.3f"):format(why, tostring(map), x, y))
end
-- 19.33 (Koordination 07:35, Pruefer 04:50 LEICHT): EIN Ruhestein Rater fuer das Navi (BindGuess unten) und den ersten
-- Start in Services.lua (InnByBindName ruft ns.RateBind auf). Vorher hatten beide eigene Regeln und konnten fuer den
-- gleichen Ort Verschiedenes sagen. ns.RateBind(home): home = GetBindLocation(). Rueckgabe { map, x, y }, wie
-- ("Hauptstadt", "Gastwirt", "hier", "Zone") oder nil, "noidx" (Gastwirt Index noch leer, nochmal versuchen) oder nil.
-- Reihenfolge, jeweils nur wenn sicher:
--  1. der Name ist eine Hauptstadt: der Gastwirt dort (bei mehreren der naechste zur Stadtmitte)
--  2. du stehst im Ort (Unterzone, Minimap Name oder Zone heisst wie home): Gastwirt bis 40 yd
--  3. dito, sonst der naechste Gastwirt bis 600 yd, sonst deine eigene Stelle (wie Services.lua bis 19.32).
--     Pruefer 08:00 MITTEL 1: nur fuer den ersten Start, NICHT fuers Navi (strict = true), sonst aendert sich die
--     Ruhestein Planung der Route (Optimizer.lua nimmt db.bindInn) ohne Saschas Ja.
--  4. der Name ist eine Zone mit genau einem Gastwirt: dieser (ns.Inns zaehlt die Stadt Kopien nicht mit)
local RATE_NEAR, RATE_PLACE = 40, 600
-- Pruefer 08:33: Regel 4 im strict Modus (Navi) erst nach Saschas Ja (f20). Bis dahin false: das Navi bleibt beim
-- Ruhestein wie 19.32 (nur Hauptstadt und Gastwirt unter 40 yd). Der erste Start (nicht strict) nimmt Regel 4 wie 19.32.
ns.BIND_REGEL4 = true -- Saschas Ja zu f20 (Koordination 08:47)
function ns.RateBind(home, strict)
  if type(home) ~= "string" or home == "" or not (ns.Inns and ns.ToMap and ns.ZoneName) then return nil end
  local inns = ns.Inns()
  if #inns == 0 then return nil, "noidx" end -- Questie oder Service Index noch nicht fertig
  -- 1. Hauptstadt
  for city in pairs(ns.cityParent or {}) do
    if ns.ZoneName(city) == home then
      local best, bd
      for _, e in ipairs(inns) do
        local cx, cy = ns.ToMap(e.map, e.x, e.y, city)
        if cx then
          local d = (cx - 0.5) ^ 2 + (cy - 0.5) ^ 2
          if not bd or d < bd then best, bd = e, d end
        end
      end
      if best then return { best.map, best.x, best.y }, "Hauptstadt" end
    end
  end
  -- 2. und 3. du stehst im Ort
  local sub = (GetSubZoneText and GetSubZoneText()) or ""
  local zone = (GetZoneText and GetZoneText()) or ""
  local mini = (GetMinimapZoneText and GetMinimapZoneText()) or ""
  if home == sub or home == mini or home == zone then
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if pos then
      local px, py = pos:GetXY()
      local best, bd
      if ns.WorldDist then
        for _, e in ipairs(inns) do
          local d = ns.WorldDist({ map, px, py }, { e.map, e.x, e.y })
          if d and (not bd or d < bd) then best, bd = e, d end
        end
      end
      if best and bd < RATE_NEAR then return { best.map, best.x, best.y }, "Gastwirt" end
      if not strict then
        if best and bd < RATE_PLACE then return { best.map, best.x, best.y }, "hier" end
        if px then return { map, px, py }, "hier" end
      end
    end
  end
  -- 5. (19.39, Saschas Log 31.10. 13:20) Ortsname eines Gastwirts: aus festen Daten (ns.INN_ORTE, Daten Chat, Name in
  --    deDE oder enUS) oder selbst gelernt (db.innSub: du standest schon einmal bei diesem Gastwirt, siehe LearnInnSub)
  local fest = ns.INN_ORTE and ns.INN_ORTE[home]
  if type(fest) == "table" and fest[1] and fest[2] and fest[3] and type(fest[1]) ~= "table" then return { fest[1], fest[2], fest[3] }, "Ortsname" end
  -- 20.2 (FEH K 14:20): Daten Chat Liste INN_ORTE[Name] = { {map,x,y}, ... } aus allen Gastwirten (Spiel Daten, Ortsname
  -- deDE und enUS je Client). Mehrere Gastwirte mit gleichem Ortsnamen: der naechste zu dir, sonst der erste
  if type(fest) == "table" and type(fest[1]) == "table" then
    local best, bd = nil, nil
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map and C_Map.GetPlayerMapPosition(map, "player")
    local px, py
    if pos then px, py = pos:GetXY() end
    for _, e in ipairs(fest) do
      if type(e) == "table" and e[1] and e[2] and e[3] then
        local d = (px and ns.WorldDist and ns.WorldDist({ map, px, py }, { e[1], e[2], e[3] })) or math.huge
        if not best or d < bd then best, bd = e, d end
      end
    end
    if best then return { best[1], best[2], best[3] }, (#fest > 1) and "Ortsname (mehrdeutig, naechster)" or "Ortsname" end
  end
  local gel = ns.db and type(ns.db.innSub) == "table" and ns.db.innSub[home]
  if type(gel) == "table" and gel[1] and gel[2] and gel[3] then return { gel[1], gel[2], gel[3] }, "Ortsname gelernt" end
  -- 4. Zone mit genau einem Gastwirt
  if strict and not ns.BIND_REGEL4 then return nil end
  local n, hit = {}, {}
  for _, e in ipairs(inns) do n[e.map] = (n[e.map] or 0) + 1; hit[e.map] = e end
  for map, c in pairs(n) do
    if c == 1 and ns.ZoneName(map) == home then
      local e = hit[map]
      return { e.map, e.x, e.y }, "Zone"
    end
  end
  return nil
end

-- 19.39: steht man bis 40 yd bei einem Gastwirt, den Ortsnamen (Unterzone, Minimap) zu diesem Gastwirt merken. Damit
-- findet Regel 5 den Ruhestein Ort auch spaeter, wenn man woanders steht (zb Level 60, gebunden bevor das Addon lief).
local function LearnInnSub()
  local db = ns.db
  if not (db and ns.Inns and ns.WorldDist and ns.PlayerMap and C_Map and C_Map.GetPlayerMapPosition) then return end
  local map = ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local best, bd
  for _, e in ipairs(ns.Inns()) do
    local d = ns.WorldDist({ map, px, py }, { e.map, e.x, e.y })
    if d and (not bd or d < bd) then best, bd = e, d end
  end
  if not (best and bd < RATE_NEAR) then return end
  db.innSub = type(db.innSub) == "table" and db.innSub or {}
  local neu = false
  for _, name in ipairs({ GetSubZoneText and GetSubZoneText() or "", GetMinimapZoneText and GetMinimapZoneText() or "" }) do
    if name ~= "" and not db.innSub[name] then db.innSub[name] = { best.map, best.x, best.y }; neu = true end
  end
  if neu then Log("NAVI", ("Gastwirt Ort gelernt: %s (Karte %s)"):format(tostring(GetSubZoneText and GetSubZoneText()), tostring(best.map))) end
end
ns.NaviLearnInnSub = LearnInnSub

-- 19.39: Hinweis "Ruhestein Ort unbekannt" nur einmal pro Sitzung
local bindTipSaid = false
function ns.NaviBindTippNeu() if bindTipSaid then return false end bindTipSaid = true; return true end

local function BindGuess()
  local db = ns.db
  if not db or db.bindInn then return true end
  local home = GetBindLocation and GetBindLocation()
  local b, how = ns.RateBind(home, true) -- ohne Regel 3 (Pruefer 08:00)
  if b then SetBind(b[1], b[2], b[3], tostring(how) .. ", " .. tostring(home)); return true end
  if how == "noidx" then return false, "noidx" end -- zaehlt nicht als Versuch
  return false
end
ns.NaviBindGuess = BindGuess

------------------------------------------------------------
-- 5. Flugkarte offen (Neu 02:24, Saschas Frage): ALLE bekannten Flugpunkte des Kontinents uebernehmen, auch die, zu
--    denen von hier keine Strecke geht. Services.lua nimmt nur REACHABLE und CURRENT, die Flugkarte zeigt bekannte
--    Punkte ohne Verbindung aber als DISTANT. Unbekannte heissen NONE und bleiben draussen.
--    Der andere Kontinent kommt dazu, sobald du dort eine Flugkarte oeffnest oder dort landest (Fluege gehen nie ueber
--    zwei Kontinente).
------------------------------------------------------------
local function FromTaxiMap()
  local T = Taxi()
  if not (T and NumTaxiNodes and TaxiNodeGetType and TaxiNodePosition) then return 0 end
  local cm = ContMap()
  if not cm then return 0 end
  local pts, types = {}, {}
  for i = 1, NumTaxiNodes() do
    local typ = TaxiNodeGetType(i)
    types[typ or "?"] = (types[typ or "?"] or 0) + 1
    if typ and typ ~= "NONE" then
      local x, y = TaxiNodePosition(i)
      local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, cm, CreateVector2D(x, y))
      if ok and c and w then
        local wx, wy = w:GetXY()
        pts[#pts + 1] = { c, wx, wy, (TaxiNodeName and TaxiNodeName(i)) or "?", i, typ }
      end
    end
  end
  local slots = GameSlots(cm)
  -- 20.3d (ANT 07:34, Ad 07:48): nur loeschen, wenn die Karte wirklich Knoten zeigt (mindestens einer erreichbar oder
  -- aktuell). Eine Karte ohne lesbare Knoten (Sim, Ladefehler) heisst keine Information, nicht "nicht da".
  local lesbar = #pts > 0 and ((types.REACHABLE or 0) + (types.CURRENT or 0)) > 0
  local n, raus = 0, 0
  local db = ns.db
  local verm = db and type(db.fpVermutet) == "table" and db.fpVermutet or nil
  local contC = ns.MapWorld and (ns.MapWorld(cm, 0.5, 0.5)) or nil
  -- 1. Durchgang: welche Knoten unserer Daten sind auf der Flugkarte (per ID, sonst per Position)
  local daSet, idHit, posHit, gotPt = {}, 0, 0, {}
  for id, k in pairs(T.knoten) do
    if type(k) == "table" and (k[11] or 0) > 0 and ns.MapWorld then
      local c, wx, wy = ns.MapWorld(k[1], k[2], k[3])
      if c then
        local da, how = false, nil
        if slots and slots[id] then da, how = true, "id" end
        if not da then
          for j, q in ipairs(pts) do
            if q[1] == c and math.sqrt((q[2] - wx) ^ 2 + (q[3] - wy) ^ 2) < 250 then da, how = true, "pos"; gotPt[j] = true; break end
          end
        end
        if da then
          if how == "id" then idHit = idHit + 1 else posHit = posHit + 1 end
          daSet[id] = true
          if MarkKnown(k[11]) then n = n + 1 end
          Sicher(k[11])
        end
      end
    end
  end
  -- Sicherheit: stimmt der Abgleich fuer weniger als 3 von 4 Knoten der Karte nicht, glauben wir ihm nicht (Position oder
  -- Knoten Nummern weichen ab, zb SoD auf dem Era Client). Dann bleiben vermutete Flugpunkte stehen.
  local ndata = 0
  if slots then for _ in pairs(slots) do ndata = ndata + 1 end else ndata = #pts end
  local trefferAnteil = ndata > 0 and ((idHit + posHit) / ndata) or 0
  local vertrauen = lesbar and trefferAnteil >= 0.75
  -- 2. Durchgang: vermutet, aber auf der Flugkarte dieses Kontinents nicht da: doch unbekannt
  if lesbar and verm and vertrauen then
    for id, k in pairs(T.knoten) do
      if type(k) == "table" and (k[11] or 0) > 0 and ns.MapWorld and not daSet[id] and verm[k[11]] then
        local c = ns.MapWorld(k[1], k[2], k[3])
        if c and c == contC then
          verm[k[11]] = nil
          if db.knownFP then db.knownFP[k[11]] = nil end
          raus = raus + 1
        end
      end
    end
  end
  if db and lesbar then db.fpKarteGesehen = true end
  if raus > 0 then Log("FLUG", ("Flugkarte: %d vermutete Flugpunkte doch unbekannt, entfernt"):format(raus)) end
  if n > 0 or raus > 0 then Bump() end
  local parts = {}
  for t2, c2 in pairs(types) do parts[#parts + 1] = t2 .. " " .. c2 end
  table.sort(parts)
  Log("FLUG", ("Flugkarte offen: %s, %d Flugpunkte neu (auch ohne Strecke von hier)"):format(table.concat(parts, ", "), n))
  Log("FLUG", ("Flugkarte Abgleich: %d von %d Knoten erkannt (%d per Nummer, %d per Position)%s"):format(idHit + posHit, ndata, idHit, posHit,
    (lesbar and not vertrauen) and ", unter 75 %, vermutete Flugpunkte bleiben" or ""))
  -- Knoten der Karte, die zu keinem Flugpunkt in unseren Daten passen: Name, Lage, naechster Daten Knoten (hoechstens 12 Zeilen)
  local shown = 0
  for j, q in ipairs(pts) do
    if not gotPt[j] and shown < 12 then
      local bid, bd, bname
      for id, k in pairs(T.knoten) do
        if type(k) == "table" and ns.MapWorld then
          local c, wx, wy = ns.MapWorld(k[1], k[2], k[3])
          if c and c == q[1] then
            local d = math.sqrt((q[2] - wx) ^ 2 + (q[3] - wy) ^ 2)
            if not bd or d < bd then bid, bd, bname = id, d, k[5] end
          end
        end
      end
      local gid
      if slots then for id, s in pairs(slots) do if s.slot == q[5] then gid = id; break end end end
      if not (gid and daSet[gid]) then
        shown = shown + 1
        Log("FLUG_KNOTEN", ("Karte Knoten %d '%s' (%s) Nr %s, Lage %d,%d: naechster Daten Knoten %s '%s' %s yd"):format(
          q[5], tostring(q[4]), tostring(q[6]), tostring(gid or "?"), math.floor(q[2]), math.floor(q[3]), tostring(bid), tostring(bname), bd and tostring(math.floor(bd)) or "?"))
      end
    end
  end
  return n
end
ns.NaviFlugFromTaxiMap = FromTaxiMap

------------------------------------------------------------
-- 4. Flugkarte: Ziel der Route markieren und automatisch losfliegen (AUF 02:00, S 01:57, f70)
------------------------------------------------------------
-- Oeffnest du bei einem Flugmeister die Flugkarte und der aktuelle Schritt vom Navi ist ein Flug, leuchtet der Flugpunkt
-- (Ziel dieses Fluges) auf der Karte und ein Hinweis steht oben. Ist alles klar (Ziel erreichbar, genug Gold, Schalter
-- "Automatisch fliegen" an = Standard, kein Shift), fliegt das Addon nach 1,2 s selbst los (TakeTaxiNode). Shift beim
-- Oeffnen oder in der Wartezeit: kein Auto Flug. Ohne klares Ziel oder ohne Gold wird nur markiert. Log FLUG_AUTO.
local taxiOpen = false
local flewByHand = false -- 20.3d: der Spieler (oder der Sim) hat selbst einen Flug genommen
if hooksecurefunc and TakeTaxiNode then pcall(hooksecurefunc, "TakeTaxiNode", function() flewByHand = true end) end
local glow, hint
local function GlowHide()
  if glow then glow:Hide() end
  if hint then hint:Hide() end
end
local function MakeGlow()
  if glow then return end
  glow = CreateFrame("Frame", nil, UIParent)
  glow:SetFrameStrata("TOOLTIP")
  glow:SetSize(44, 44)
  local t = glow:CreateTexture(nil, "OVERLAY")
  t:SetAllPoints()
  t:SetTexture("Interface\\Cooldown\\star4")
  t:SetBlendMode("ADD")
  t:SetVertexColor(1, 0.85, 0.2, 1)
  glow.tex = t
  glow:SetScript("OnUpdate", function(self, el)
    self.t = (self.t or 0) + el
    local k = math.sin(self.t * 5)
    self.tex:SetAlpha(0.6 + 0.4 * k)
    local sz = 46 + 10 * k
    self:SetSize(sz, sz)
  end)
  glow:Hide()
  hint = CreateFrame("Frame", nil, UIParent)
  hint:SetFrameStrata("TOOLTIP")
  hint:SetSize(480, 24)
  local fs = hint:CreateFontString(nil, "OVERLAY", ns.FontName and ns.FontName("GameFontNormalLarge") or "GameFontNormalLarge")
  fs:SetPoint("CENTER")
  fs:SetTextColor(1, 0.85, 0.2)
  fs:SetShadowOffset(1, -1)
  hint.fs = fs
  hint:Hide()
end
-- 20.4 (Na, K 19:33): Auto Flug auch bei einem Reise Schritt der Route (Tour "Alle Flugpunkte", Dungeon Anreise, Optimizer Reise):
-- der Schritt ist ein Flug (acts k="R", link="fly") mit Ziel toMap/toX/toY. Ohne Navi gab es dafuer kein Flug Leg, die Flugkarte
-- ging ohne Markierung und ohne Auto Flug auf. Jetzt wie beim Navi: Ziel leuchtet, Start wird geprueft, nach 1,2 s TakeTaxiNode.
local optLegCache = {}
local function OptFlugLeg()
  local db = ns.db
  if not (db and db.optMode and db.opt and db.opt.steps and ns.OptCurrentAct and ns.MapWorld) then return nil end
  if ns.navi and not ns.navi.hidden then return nil end
  local a = ns.OptCurrentAct()
  if not (a and a.k == "R" and a.link == "fly" and a.toMap and a.toX and a.toY) then return nil end
  if ns.OptActDone and ns.OptActDone(a) then return nil end
  if optLegCache.a == a and optLegCache.lg then return optLegCache.lg end
  local c, wx, wy = ns.MapWorld(a.toMap, a.toX, a.toY)
  if not (c and wx) then return nil end
  local s = db.opt.steps[db.opt.idx or 1]
  local fc, fx, fy
  if s and s.map and s.x and s.y then fc, fx, fy = ns.MapWorld(s.map, s.x, s.y) end
  local lg = { kind = "fly", opt = true, to = { cont = c, wx = wx, wy = wy, name = a.dest or a.quest or a.who } }
  if fc and fx then lg.from = { cont = fc, wx = fx, wy = fy } end
  optLegCache.a, optLegCache.lg = a, lg
  return lg
end
-- Flug Schritt, um den es gerade geht: der jetzige, oder der naechste, wenn du schon beim Flugmeister stehst
local NaviFlugLeg
local function FlugLeg()
  return NaviFlugLeg() or OptFlugLeg()
end
NaviFlugLeg = function()
  local nv = ns.navi
  if not (nv and not nv.hidden and nv.legs and nv.cur) then return nil end
  local lg = nv.legs[nv.cur]
  if not lg then return nil end
  if lg.kind == "fly" then return lg end
  local nx = nv.legs[nv.cur + 1]
  if lg.kind == "walk" and nx and nx.kind == "fly" and lg.to and ns.WorldDist and ns.PlayerMap then
    local pm = ns.PlayerMap()
    local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
    if pos then
      local px, py = pos:GetXY()
      local d = ns.WorldDist({ pm, px, py }, { lg.to.map, lg.to.x, lg.to.y })
      if d and d < 80 then return nx end
    end
  end
  return nil
end
-- Knoten auf der offenen Flugkarte, der zum Ziel (Welt Position) passt: Nummer, Abstand in yd
local function FindNode(to)
  if not (to and to.wx and NumTaxiNodes and TaxiNodePosition and TaxiNodeGetType and C_Map and C_Map.GetWorldPosFromMapPos) then return nil end
  -- 20.3l: zuerst per Knoten Nummer (Daten Knoten am Ziel -> Nummer auf der offenen Karte), sonst wie bisher per Position
  do
    local T = Taxi()
    local cm0 = ContMap()
    local slots = cm0 and GameSlots(cm0)
    if T and slots and ns.MapWorld then
      local bid, bd
      for id, k in pairs(T.knoten) do
        if type(k) == "table" then
          local c, wx, wy = ns.MapWorld(k[1], k[2], k[3])
          if c and (not to.cont or c == to.cont) then
            local d = math.sqrt((wx - to.wx) ^ 2 + (wy - to.wy) ^ 2)
            if not bd or d < bd then bid, bd = id, d end
          end
        end
      end
      local s = bid and bd < 250 and slots[bid]
      if s and s.slot then
        local typ0 = TaxiNodeGetType(s.slot)
        if typ0 and typ0 ~= "NONE" and typ0 ~= "CURRENT" then return s.slot, bd end
      end
    end
  end
  local cm = ns.PlayerMap and ns.PlayerMap()
  for _ = 1, 6 do
    local info = cm and C_Map.GetMapInfo(cm)
    if not info or info.mapType == 2 or not info.parentMapID then break end
    cm = info.parentMapID
  end
  if not cm then return nil end
  local best, bd
  for i = 1, NumTaxiNodes() do
    local typ = TaxiNodeGetType(i)
    if typ and typ ~= "NONE" and typ ~= "CURRENT" then
      local x, y = TaxiNodePosition(i)
      local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, cm, CreateVector2D(x, y))
      if ok and c and w and (not to.cont or c == to.cont) then
        local wx, wy = w:GetXY()
        local d = math.sqrt((wx - to.wx) ^ 2 + (wy - to.wy) ^ 2)
        if not bd or d < bd then best, bd = i, d end
      end
    end
  end
  if best and bd < 250 then return best, bd end
  return nil
end
local function MarkNode(i, text)
  pcall(MakeGlow)
  if not (glow and hint) then return end
  local b = _G["TaxiButton" .. i]
  if b and b.IsShown and b:IsShown() then
    glow:ClearAllPoints()
    glow:SetPoint("CENTER", b, "CENTER", 0, 0)
    glow:Show()
  else
    glow:Hide()
  end
  hint:ClearAllPoints()
  if TaxiFrame then hint:SetPoint("BOTTOM", TaxiFrame, "TOP", 0, 4) else hint:SetPoint("TOP", UIParent, "TOP", 0, -90) end
  hint.fs:SetText(text)
  hint:Show()
end
-- 20.3p (Da Nr 7): ist der Flugmeister, an dem die Karte offen ist, der Start des geplanten Fluges? true = ja oder unklar
-- 20.3y (K 17:20 Punkt 1, S Test 20.3x: FLUG_AUTO "anderer Flugmeister als geplant (Abstand zum Start 877 yd)" beim Wegekreuz, obwohl
-- der Plan "Devrak (5 yd)" sagte): die Position der Flugkarte (TaxiNodePosition) laesst sich nicht verlaesslich in Weltmasse
-- umrechnen (hier 877 yd daneben). Jetzt: 1. per Knoten Nummer (aktueller Knoten der Karte = Knoten unserer Daten, dessen Position
-- mit dem Start vergleichen, wie FindNode), 2. sonst Abstand des Spielers zum Start (du stehst am Flugmeister), 3. sonst ja.
local function CurrentIsFrom(from)
  if not (from and from.wx and NumTaxiNodes and TaxiNodeGetType) then return true end
  local cur
  for i = 1, NumTaxiNodes() do
    if TaxiNodeGetType(i) == "CURRENT" then cur = i; break end
  end
  if not cur then return true end
  local why
  -- 1. Knoten Nummer
  local T, cm = Taxi(), ContMap()
  local slots = cm and GameSlots(cm)
  if T and slots and ns.MapWorld then
    for id, s in pairs(slots) do
      if s.slot == cur then
        local k = T.knoten[id]
        if type(k) == "table" then
          local c, wx, wy = ns.MapWorld(k[1], k[2], k[3])
          if c then
            local d = math.sqrt((wx - from.wx) ^ 2 + (wy - from.wy) ^ 2)
            if d < 400 then return true, d end
            why = ("Knoten %s %d yd"):format(tostring(s.name or id), math.floor(d))
          end
        end
        break
      end
    end
  end
  -- 2. Abstand Spieler zum Start (nur wenn die Knoten Nummer nichts Eindeutiges ergab oder daneben liegt: du stehst am Flugmeister)
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm and C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(pm, "player")
  if pos and ns.MapWorld then
    local px, py = pos:GetXY()
    local c, wx, wy = ns.MapWorld(pm, px, py)
    if c and wx then
      local dp = math.sqrt((wx - from.wx) ^ 2 + (wy - from.wy) ^ 2)
      if dp < 150 then return true, dp end
      return false, dp, why
    end
  end
  if why then return false, 9999, why end
  return true
end
local function AutoFly()
  GlowHide()
  local db = ns.db
  if not taxiOpen or not db or db.useFlights == false then return end
  local lg = FlugLeg()
  if not (lg and lg.to) then return end
  -- nur fliegen, wenn die Route genau von diesem Flugmeister aus fliegt (sonst nichts tun, kein Auto Flug)
  if lg.kind == "fly" and lg.from then
    local okFrom, dFrom, why0 = CurrentIsFrom(lg.from)
    if not okFrom then
      Log("FLUG_AUTO", ("anderer Flugmeister als geplant (Abstand zum Start %d yd%s), kein Auto Flug"):format(math.floor(dFrom or 0), why0 and (", " .. why0) or ""))
      return
    end
  end
  local i, dist = FindNode(lg.to)
  local want = lg.to.name or "?"
  if not i then
    Log("FLUG_AUTO", ("Ziel %s nicht auf der Flugkarte gefunden, nichts markiert"):format(tostring(want)))
    return
  end
  local name = (TaxiNodeName and TaxiNodeName(i)) or want
  local typ = TaxiNodeGetType(i)
  local cost = (TaxiNodeCost and tonumber(TaxiNodeCost(i))) or 0
  local money = (GetMoney and GetMoney()) or 0
  local shift = IsShiftKeyDown and IsShiftKeyDown() or false
  local why
  if db.autoFly == false or not TakeTaxiNode then why = TR"Automatisch fliegen ist aus"
  elseif typ ~= "REACHABLE" then why = TR"von hier nicht direkt erreichbar"
  elseif cost > money then why = TR"zu wenig Gold für den Flug"
  elseif shift then why = TR"Shift: kein Auto Flug" end
  if why then
    MarkNode(i, (TR"Ziel der Route: %s (%s)"):format(name, why))
    Log("FLUG_AUTO", ("nur markiert: %s (%s), Typ %s, Kosten %s, Gold %s, Abstand %d yd"):format(tostring(name), tostring(why), tostring(typ), tostring(cost), tostring(money), math.floor(dist or 0)))
    return
  end
  MarkNode(i, (TR"Flug nach %s startet gleich. Abbrechen: Shift halten oder die Flugkarte schliessen"):format(name))
  Log("FLUG_AUTO", ("Auto Flug in 1,2 s: %s (Typ %s, Kosten %s)"):format(tostring(name), tostring(typ), tostring(cost)))
  if not C_Timer then return end
  C_Timer.After(1.2, function()
    if not taxiOpen then Log("FLUG_AUTO", "Flugkarte inzwischen zu, kein Flug"); return end
    if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return end
    if flewByHand then Log("FLUG_AUTO", "schon selbst geflogen, kein Auto Flug"); return end
    if IsShiftKeyDown and IsShiftKeyDown() then
      MarkNode(i, (TR"Ziel der Route: %s (%s)"):format(name, TR"Shift: kein Auto Flug"))
      Log("FLUG_AUTO", "Shift gedrueckt, kein Flug")
      return
    end
    local j = FindNode(lg.to)
    if j ~= i then Log("FLUG_AUTO", "Ziel hat sich auf der Karte geaendert, kein Flug"); return end
    local ok, err = ns.Api.Prot("TakeTaxiNode", TakeTaxiNode, i)
    Log("FLUG_AUTO", ("TakeTaxiNode %d (%s): %s"):format(i, tostring(name), ok and "ok" or ("Fehler " .. tostring(err))))
    GlowHide()
  end)
end
ns.NaviFlugAuto = AutoFly

-- Neu 02:24: ab Level 10 und 0 bekannten Flugpunkten einmal ein klarer Hinweis (Mini Fenster und Einrichtung, die
-- Stellen baut der Addon Chat). true, solange der Hinweis gezeigt werden soll
function ns.NaviFlugHinweisNoetig()
  local db = ns.db
  if not db or db.useFlights == false then return false end
  local lvl = UnitLevel and UnitLevel("player") or 1
  if lvl < 10 then return false end
  if type(db.fpVermutet) == "table" and next(db.fpVermutet) then return true end -- 20.2: nur vermutet, Flugkarte bestaetigt
  return not (type(db.knownFP) == "table" and next(db.knownFP))
end
ns.NAVI_FLUG_HINWEIS = TR"Öffne einmal die Flugkarte bei einem Flugmeister, dann kennt das Addon alle deine Flugpunkte."

-- Pruefer A9: den Flug Tipp pro Ziel nur einmal pro Sitzung im Chat sagen (Mini Fenster zeigt ihn weiter)
local tipSaid = {}
function ns.NaviFlugTippNeu(dest)
  if not dest then return true end
  local key = ("%s:%.2f:%.2f"):format(tostring(dest.map), dest.x or 0, dest.y or 0)
  if tipSaid[key] then return false end
  tipSaid[key] = true
  return true
end

-- Ankunft messen: Teleport gewirkt, nach dem Ladebildschirm die Position merken
local portPending
local bindTries, bindPending, bindNoIdx = 0, false, 0
local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("PLAYER_ENTERING_WORLD")
ef:RegisterEvent("TAXIMAP_OPENED")
ef:RegisterEvent("TAXIMAP_CLOSED")
ef:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ef:RegisterEvent("PLAYER_UPDATE_RESTING")
ef:RegisterEvent("HEARTHSTONE_BOUND")
pcall(ef.RegisterUnitEvent, ef, "UNIT_SPELLCAST_SUCCEEDED", "player")
ef:SetScript("OnEvent", function(_, e, a1, a2, a3)
  if e == "PLAYER_LOGIN" then
    if ns.Ticker then ns.Ticker(1, function() pcall(LandCheck) end, true) end
    if C_Timer then C_Timer.After(12, function() pcall(FromGame) end) end
    -- Ruhestein Ort: hoechstens 6 Versuche alle 10 s nach dem Einloggen (Pruefer 04:50), danach nur bei Zonenwechsel,
    -- beim Betreten eines Gasthauses (ausruhen) und nach dem Binden
    if ns.Ticker then
      local tk
      tk = ns.Ticker(10, function()
        local db = ns.db
        if not db then return end
        local ok, done, why = true, db.bindInn and true or false, nil
        if not done then ok, done, why = pcall(BindGuess) end
        -- Pruefer 05:14: ein Fehler zaehlt als Versuch (pcall gibt dann die Fehlermeldung statt done zurueck),
        -- leerer Gastwirt Index hat eine eigene Grenze, damit der Ticker nie endlos laeuft
        if not ok then done, why = false, nil end
        if why == "noidx" then bindNoIdx = bindNoIdx + 1 else bindTries = bindTries + 1 end
        -- Pruefer 05:08: nach Erfolg oder dem 6. Versuch den Ticker beenden
        if (done == true or bindTries >= 6 or bindNoIdx >= 30) and tk and tk.Cancel then tk:Cancel() end
      end, true)
    end
  elseif e == "ZONE_CHANGED_NEW_AREA" or e == "PLAYER_UPDATE_RESTING" or e == "HEARTHSTONE_BOUND" then
    local db = ns.db
    -- 19.39: im Gasthaus (ausruhen) den Ortsnamen zum Gastwirt lernen
    if e == "PLAYER_UPDATE_RESTING" and C_Timer then C_Timer.After(1, function() pcall(LearnInnSub) end) end
    -- Pruefer 05:08: nur ein 2 s Timer auf einmal
    if db and not db.bindInn and C_Timer and not bindPending then
      bindPending = true
      C_Timer.After(2, function() bindPending = false; pcall(BindGuess) end)
    end
  elseif e == "TAXIMAP_OPENED" then
    taxiOpen = true
    flewByHand = false
    -- kurz warten, bis die Flugkarte ihre Knoten hat
    if C_Timer then C_Timer.After(0.2, function() pcall(FromTaxiMap) end) else pcall(FromTaxiMap) end
    -- 20.3 (AUF 02:00): Ziel markieren und ggf. automatisch fliegen, nach dem Lernen der Flugpunkte
    -- 20.3l: nach dem Oeffnen kennt das Spiel meist die unentdeckten Flugpunkte (isUndiscovered), dann gilt das statt Vermutung
    if C_Timer then C_Timer.After(0.35, function() pcall(FromGame) end) end
    if C_Timer then C_Timer.After(0.5, function() pcall(AutoFly) end) end
  elseif e == "TAXIMAP_CLOSED" then
    taxiOpen = false
    GlowHide()
  elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
    local spell = a3
    for _, p in ipairs(PORTS) do if p.spell == spell then portPending = { spell = spell, t = Now() } end end
  elseif e == "PLAYER_ENTERING_WORLD" then
    local pp = portPending
    if pp and Now() - pp.t < 90 and C_Timer then
      portPending = nil
      C_Timer.After(3, function()
        local map = ns.PlayerMap and ns.PlayerMap()
        local pos = map and C_Map.GetPlayerMapPosition(map, "player")
        if not (pos and ns.db) then return end
        local x, y = pos:GetXY()
        ns.db.naviPortal = type(ns.db.naviPortal) == "table" and ns.db.naviPortal or {}
        ns.db.naviPortal[pp.spell] = { map, math.floor(x * 10000 + 0.5) / 10000, math.floor(y * 10000 + 0.5) / 10000 }
        Log("NAVI", ("Teleport Ankunft gemessen: Zauber %d, Karte %s %.3f,%.3f"):format(pp.spell, tostring(map), x, y))
      end)
    end
  end
end)
