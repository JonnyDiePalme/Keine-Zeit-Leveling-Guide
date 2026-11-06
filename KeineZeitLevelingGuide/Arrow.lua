local ADDON, ns = ...
-- 1.2e (P62): Flugzeit Balken unter dem Pfeil
ns.FLIGHT_BAR_W, ns.FLIGHT_BAR_H = 150, 14
local TR = ns.TR

-- 19.31 (Saschas Runde: Startgebiet Durotar gewaehlt, "er macht mir keinen Weg dorthin"): bei einem Ziel in einer
-- anderen Zone sagen, wohin es geht und ueber welche Zone (zb "Ziel in Durotar, zuerst nach Brachland")
-- 19.33 (Pruefer 05:14): kommt der Uebergang aus ZoneCrossing (Rueckfall, wenn XZoneNext keinen kennt), dann ist
-- K.lastCross von einer frueheren Rechnung und nannte eine alte Zone. Dann nur "Ziel in X, zuerst zum Uebergang".
local function ViaText(tmap, fromX)
  local lc = fromX and ns.Karte and ns.Karte.lastCross
  local tz = ns.ZoneName and ns.ZoneName(tmap)
  local nz = lc and lc.z and lc.z ~= tmap and ns.ZoneName and ns.ZoneName(lc.z)
  if tz and nz then return ("\n|cff9d9d9d" .. TR"Ziel in %s, zuerst nach %s" .. "|r"):format(tz, nz) end
  if tz then return ("\n|cff9d9d9d" .. TR"Ziel in %s, zuerst zum Übergang" .. "|r"):format(tz) end
  return TR"\n|cff9d9d9dzuerst zum Übergang in die nächste Zone|r"
end
local arrow, hoverBox

-- 19.33 (Koordination 07:35, vorgemerkt 05:14): du bist in einer Hauptstadt, das Ziel liegt in ihrer Zone, aber
-- ausserhalb der Stadtkarte (zb in Orgrimmar, Ziel in Durotar vor dem Tor). ToMap gibt ausserhalb 0..1 nil, und Stadt
-- nach Zone ist kein Zonenwechsel fuer XZoneNext, also zeigte der Pfeil die Luftlinie durch die Stadtmauer. Jetzt wird
-- wie bei der Laufstrecke (Path.lua WalkNet) in der Zone gerechnet: deine Stelle auf die Karte der Zone (auch knapp
-- neben dem Kartenrand, Orgrimmar liegt zum Teil neben Durotar).
local function CityToParent(mapID, px, py, gmap)
  local cp = ns.cityParent
  if not (cp and cp[mapID] == gmap) then return end
  local f = ns.ToMapLoose or ns.ToMapFree or ns.ToMap
  if not f then return end
  local x, y = f(mapID, px, py, gmap)
  if x and y then return gmap, x, y end
end

-- Breite und Hoehe einer Karte in Yards, aus den Ecken berechnet
local sizeCache = {}
local function MapSize(mapID)
  local c = sizeCache[mapID]
  if c then return c[1], c[2] end
  local w = ns.WorldDist({ mapID, 0, 0 }, { mapID, 1, 0 })
  local h = ns.WorldDist({ mapID, 0, 0 }, { mapID, 0, 1 })
  if not (w and h and w > 0 and h > 0) and C_Map.GetMapWorldSize then
    local ok, a, b = pcall(C_Map.GetMapWorldSize, mapID)
    if ok then w, h = a, b end
  end
  if not (w and h and w > 0) then w, h = 3000, 2000 end
  sizeCache[mapID] = { w, h }
  return w, h
end

local function Speed() return ns.speed or 7 end

-- Kontinent einer Karte suchen
local function ContinentOf(mapID)
  local id = mapID
  for _ = 1, 6 do
    local info = id and C_Map.GetMapInfo(id)
    if not info then return nil end
    if info.mapType == Enum.UIMapType.Continent then return id end
    id = info.parentMapID
  end
end

-- Punkt einer anderen Karte auf die Karte des Spielers (oder den Kontinent) bringen
local function OnPlayerMap(mapID, px, py, tmap, tx, ty)
  if tmap == mapID then return mapID, px, py, tx, ty end
  local x, y = ns.ToMap(tmap, tx, ty, mapID)
  if x then return mapID, px, py, x, y end
  local cont = ContinentOf(mapID)
  local cpos = cont and C_Map.GetPlayerMapPosition(cont, "player")
  if cpos then
    x, y = ns.ToMap(tmap, tx, ty, cont)
    if x then
      local cx, cy = cpos:GetXY()
      return cont, cx, cy, x, y
    end
  end
end

-- herumlaufender NPC: naechster Punkt auf seinem Weg
local function PatrolPoint(npc, mapID, px, py)
  local paths = npc and ns.Waypoints and ns.Waypoints(npc, mapID)
  if not paths then return end
  local p = ns.NearestOnPaths(paths, px, py)
  if p then return p[1], p[2] end
end

-- Ziel bestimmen: Empfehlung vom Level Check oder naechster Routenpunkt.
-- Gibt Karte, Spieler x/y und Ziel x/y auf derselben Karte zurueck.
-- Symbole neben dem Pfeil je Art (einmal angelegt, nicht in jedem Frame)
local KIND_ICON = {
  A = "Interface\\Icons\\INV_Misc_Note_01", T = "Interface\\RaidFrame\\ReadyCheck-Ready",
  F = "Interface\\Icons\\Ability_Hunter_Pet_Wyvern", H = "Interface\\Icons\\INV_Misc_Rune_01",
  B = "Interface\\Icons\\INV_Misc_Rune_01", V = "Interface\\Icons\\INV_Misc_Bag_10", L = "Interface\\Icons\\INV_Misc_Rune_01",
  G = "Interface\\Icons\\Ability_DualWield", K = "Interface\\Icons\\INV_Misc_Book_09", E = "Interface\\Icons\\INV_Misc_Spyglass_03",
  R = "Interface\\Icons\\Ability_Hunter_Pet_Wyvern", M = "Interface\\Icons\\INV_Misc_Key_03",
}
local SVC_ICON = { repair = "Interface\\Icons\\Trade_BlackSmithing", vendor = "Interface\\Icons\\INV_Misc_Bag_10",
  trainer = "Interface\\Icons\\INV_Misc_Book_11", inn = "Interface\\Icons\\INV_Misc_Rune_01", fly = "Interface\\Icons\\Ability_Hunter_Pet_Wyvern",
  book = "Interface\\Icons\\INV_Misc_Book_09", books = "Interface\\Icons\\INV_Misc_Book_09", help = "Interface\\Icons\\Spell_Holy_PrayerOfHealing" }
local resolveSrc -- woher das Ziel kommt: "opt" (Route), "svc" (Haendler, Lehrer ...) oder nil
local resolveFinal -- Pfeil zeigt auf einen Zwischenpunkt (Weg ums Gelaende, Zonenuebergang): Yards bis zum echten Ziel
-- 20.3 (Navi Chat, abs farm_route): Farm Rundweg. Hat der Opt Schritt eine Runde (Feld rund = { {x,y}, ... }, 3 oder mehr Punkte auf
-- st.map, kommt von Optimizer/Farm), fuehrt der Pfeil zum naechsten Rundpunkt und dann reihum (unter 25 yd = Punkt erledigt, am Ende
-- wieder vorne). Ohne Feld rund aendert sich nichts. ns.NaviRundPts(mapID) gibt die Runde als geschlossene Linie fuer die Minimap/Weltkarte.
local RUND_NAH = 25
local RUND_SKIP_S = 90    -- v11f: Punkt ohne Fortschritt so lange auslassen
local rundState = { key = nil, i = 1, n = 0 }
local function RundOf(stp, mapID)
  local r = stp and stp.rund
  if type(r) ~= "table" or #r < 3 or stp.map ~= mapID then return nil end
  for _, p in ipairs(r) do if type(p) ~= "table" or not tonumber(p[1]) or not tonumber(p[2]) then return nil end end
  return r
end
local function RundNext(stp, mapID, px, py)
  local r = RundOf(stp, mapID)
  if not r then return nil end
  local key = ("%d:%d:%.4f:%.4f"):format(mapID, #r, r[1][1], r[1][2])   -- gleiche Runde, auch wenn der Schritt jedes Mal neu gebaut wird
  if rundState.key ~= key then
    -- neue Runde: mit dem Punkt anfangen, der dir am naechsten ist
    local bi, bd = 1, math.huge
    for i, p in ipairs(r) do
      local d = ns.WorldDist and ns.WorldDist({ mapID, px, py }, { mapID, p[1], p[2] }) or math.huge
      if d < bd then bi, bd = i, d end
    end
    rundState.key, rundState.i, rundState.n, rundState.skip, rundState.prog = key, bi, 0, {}, nil
  end
  local p = r[rundState.i]
  local d = ns.WorldDist and ns.WorldDist({ mapID, px, py }, { mapID, p[1], p[2] })
  if d and d < RUND_NAH then
    -- v11f (K P37): kein Fortschritt seit dem letzten Punkt (abgeraeumt, andere Spieler): diesen Punkt eine Weile auslassen
    local now = GetTime()
    local act = ns.OptCurrentAct and ns.OptCurrentAct()
    local prog = act and ns.OptCountText and ns.OptCountText(act) or ""
    rundState.skip = rundState.skip or {}
    if rundState.prog ~= nil and rundState.prog == prog then rundState.skip[rundState.i] = now + RUND_SKIP_S end
    rundState.prog = prog
    local tries = 0
    repeat
      rundState.i = rundState.i % #r + 1
      if rundState.i == 1 then rundState.n = rundState.n + 1 end
      tries = tries + 1
    until tries >= #r or not ((rundState.skip[rundState.i] or 0) > now)
    p = r[rundState.i]
  end
  return p[1], p[2], rundState.n + 1, #r, rundState.i
end
function ns.NaviRundPts(mapID)
  if not (ns.OptTarget and ns.db and ns.db.optMode) then return nil end
  local ok, stp = pcall(ns.OptTarget)
  local r = ok and RundOf(stp, mapID)
  if not r then return nil end
  local out = {}
  for i, p in ipairs(r) do out[i] = { p[1], p[2] } end
  out[#out + 1] = { r[1][1], r[1][2] }
  return out
end

local function ResolveRaw(db)
  resolveSrc, resolveFinal = nil, nil
  local mapID = ns.PlayerMap()
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local px, py = pos:GetXY()

  -- tot als Geist: zur Leiche
  if UnitIsGhost and ns.Api.U(UnitIsGhost, "player") and C_DeathInfo and C_DeathInfo.GetCorpseMapPosition then
    local ok, v = pcall(C_DeathInfo.GetCorpseMapPosition, mapID)
    if ok and v then
      local cx, cy = v:GetXY()
      if cx and cx > 0 then return mapID, px, py, cx, cy, TR"|cffb0b0b0Zur Leiche|r" end
    end
  end

  -- Gold Modus: naechster Gold Stopp
  local gt = ns.GoldTarget and ns.GoldTarget()
  if gt then
    local name = (TR"Gold: %s (%s)"):format(gt.name or "?", ns.Money(gt.gold))
    if ns.goldPreview then name = name .. TR"\n|cffff5050Vorschau, Gold farmen erst ab Level 35|r" end
    local gp = { gt.x, gt.y, gt.name, tags = gt.turnin and { turnin = gt } or { quest = { gt.x, gt.y, gt.name, 0, 0, #gt.quests, quests = gt.quests } } }
    if gt.map == mapID then return mapID, px, py, gt.x, gt.y, name, gp end
    local tx, ty = ns.ToMap(gt.map, gt.x, gt.y, mapID)
    if tx then return mapID, px, py, tx, ty, name, gp end
    local cont = ContinentOf(mapID)
    local cpos = cont and C_Map.GetPlayerMapPosition(cont, "player")
    if cpos then
      tx, ty = ns.ToMap(gt.map, gt.x, gt.y, cont)
      if tx then
        local cx, cy = cpos:GetXY()
        return cont, cx, cy, tx, ty, name, gp
      end
    end
  end

  -- Service Ziel (Lehrer, Haendler, Reparatur, Flugpunkt, Gastwirt), vom Spieler gewaehlt
  local st = ns.serviceTarget
  -- 19.32 (Navi Chat, Saschas Wunsch "Wege auf Weltkarte und Minimap gleich"): beim Navi ging der Pfeil in gerader Linie
  -- auf den naechsten Navi Punkt, die Weltkarte zeichnete aber den Weg um das Gelaende (und die Minimap hatte keinen
  -- Pfeil Weg, dem sie folgen konnte). Jetzt geht der Pfeil den gleichen Weg ueber das Netz wie die Route.
  -- Pruefer 03:30: nur bei Lauf oder Reit Abschnitt und nicht auf dem Taxi (1), Yards und "Da!" zum echten Navi Punkt (2),
  -- zuerst der Uebergang ueber das Netz, Umrechnen nur bei Stadt und ihrer Zone (3), Uebergang auch bei freier Linie (4),
  -- Rueckfall ZoneCrossing, Text "um das Gelaende" nur, wenn der Pfeil nicht schon aufs Ziel zeigt (5)
  local nvA = ns.navi
  -- Pruefer 03:45: nur das Navi, zu dem dieses Pfeil Ziel gehoert (nach einem stillen Neustart bis zum naechsten Tick
  -- ein anderes), und Schiff oder Zeppelin nur, solange du nah am Abfahrtssteg bist (nicht auf dem Schiff zurueck)
  local lgA = st and st.kind == "navi" and nvA and nvA.st == st and nvA.legs and nvA.legs[nvA.cur]
  local okKind = lgA and (lgA.kind == "walk" or st.fm or (lgA.kind == "ride" and lgA.at and ns.WorldDist
    and (ns.WorldDist({ mapID, px, py }, { lgA.at.map, lgA.at.x, lgA.at.y }) or math.huge) < 150))
  if okKind and st.map and st.x and st.y and ns.WalkNext
    and not (UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")) then
    local gx, gy, gmap = st.x, st.y, st.map
    local via, viaX
    -- m0, x0, y0: Karte, auf der gerechnet wird (deine Karte, oder die Zone deiner Stadt, siehe CityToParent)
    local m0, x0, y0 = mapID, px, py
    local cp = ns.cityParent or {}
    if gmap ~= mapID and ns.ToMap and (cp[gmap] == mapID or cp[mapID] == gmap or (cp[gmap] and cp[gmap] == cp[mapID])) then
      local x2, y2 = ns.ToMap(gmap, gx, gy, mapID)
      if x2 then gx, gy, gmap = x2, y2, mapID
      else
        local zm, zx, zy = CityToParent(mapID, px, py, gmap)
        if zm then m0, x0, y0 = zm, zx, zy end
      end
    end
    if gmap ~= m0 and ns.XZoneNext then
      local cx, cy = ns.XZoneNext(m0, x0, y0, gmap, gx, gy)
      if cx then gx, gy, gmap, via, viaX = cx, cy, m0, true, true end
    end
    if gmap ~= m0 and ns.ZoneCrossing then
      local cx, cy = ns.ZoneCrossing(m0, x0, y0, gmap, gx, gy)
      if cx then gx, gy, gmap, via = cx, cy, m0, true end
    end
    if gmap == m0 then
      local wx, wy = ns.WalkNext(m0, x0, y0, gx, gy)
      resolveSrc = "svc"
      if (wx or via) and ns.WorldDist then resolveFinal = ns.WorldDist({ m0, x0, y0 }, { st.map, st.x, st.y }) end
      local name = st.name or "?"
      if wx then
        if via then return m0, x0, y0, wx, wy, name .. ViaText(st.map, viaX), nil end
        -- 19.39 (Navi Chat, abs stadt_pfeil, S 08:48): in der Stadt ohne Weg oder festgehangen zeigt WalkNext (Addon) direkt
        -- aufs Ziel und setzt ns.walkCity, dann ein kurzer Hinweis statt "um das Gelaende"
        if ns.walkCity then return m0, x0, y0, wx, wy, name .. (ns.walkGate and TR"\n|cff9d9d9dStadt: erst zum Tor|r" or TR"\n|cff9d9d9dStadt: Richtung Ziel|r"), nil end
        if math.abs(wx - gx) < 1e-4 and math.abs(wy - gy) < 1e-4 then resolveFinal = nil; return m0, x0, y0, wx, wy, name, nil end
        return m0, x0, y0, wx, wy, name .. TR"\n|cff9d9d9dauf bekanntem Weg um das Gelände|r", nil
      end
      if via then return m0, x0, y0, gx, gy, name .. ViaText(st.map, viaX), nil end
      -- in der Zone deiner Stadt ohne Weg: zuerst ein selbst gelaufener Uebergang aus der Stadt (Tor, wie in 19.32,
      -- Pruefer 08:00 MITTEL 2), sonst Ziel direkt (Luftlinie auf der Karte der Zone), wie vorher OnPlayerMap
      if m0 ~= mapID then
        local cx, cy
        if ns.ZoneCrossing then cx, cy = ns.ZoneCrossing(mapID, px, py, gmap, gx, gy) end
        if cx and cy then
          -- Pruefer 08:33 LEICHT 1: unter dem Pfeil die Entfernung zum Ziel, nicht "Da!" am Tor
          if ns.WorldDist then resolveFinal = ns.WorldDist({ mapID, px, py }, { st.map, st.x, st.y }) end
          return mapID, px, py, cx, cy, name .. ViaText(st.map, false), nil
        end
        resolveFinal = nil; return m0, x0, y0, gx, gy, name, nil
      end
      resolveSrc, resolveFinal = nil, nil
    end
  end
  if st then
    local m, a, b, tx, ty = OnPlayerMap(mapID, px, py, st.map, st.x, st.y)
    if m then resolveSrc = "svc"; return m, a, b, tx, ty, (st.kind == "navi" and "" or TR"Service: ") .. (st.name or "?"), nil end
  end

  -- Optimierte Route: Schritt fuer Schritt
  if db.optMode and ns.OptTarget then
    local stp, opt_pt, oname = ns.OptTarget()
    -- Ruhestein: wird benutzt, wo du stehst. Das Gasthaus kann auf einem anderen Kontinent liegen, dann fand der Pfeil
    -- keinen Weg und zeigte "Kein Weg gefunden" (Sim 17.2). Ziel ist darum deine eigene Stelle.
    local ca = stp and ns.OptCurrentAct and ns.OptCurrentAct()
    -- (nicht in der Gruppe, wenn dein Ruhestein woanders hin geht: dann mit dem Leiter mitlaufen)
    if ca and ca.k == "H" and not (ns.OptActDone and ns.OptActDone(ca)) then resolveSrc = "opt"; return mapID, px, py, px, py, oname, opt_pt end
    if stp then
      -- 20.3 Farm Rundweg: Schritt mit Runde, Ziel ist der naechste Rundpunkt (sonst unveraendert)
      local rx, ry, rn, rc, ri = RundNext(stp, mapID, px, py)
      if rx then
        stp = setmetatable({ x = rx, y = ry }, { __index = stp })
        oname = (oname or "") .. (TR"\n|cff9d9d9dRunde %d, Punkt %d von %d|r"):format(rn, ri, rc)
      end
      -- zu Fuss: um Berge herum ueber bekannte Wege, in andere Zonen ueber bekannte Uebergaenge
      -- 20.3k (K Punkt 19a, Test 20.3j: Pfeil gerade zum Zeppelin Turm, keine Linie): Reise Schritte (Zeppelin, Schiff, Flug)
      -- sind auch Orte, zu denen man laeuft. Der Pfeil geht jetzt den Weg wie bei jedem Schritt. Schalter db.reiseWeg=false = alt
      local isTravel = stp.travel and (ns.db and ns.db.reiseWeg == false)
      if not isTravel and ns.WalkNext then
        local gx, gy, gmap = stp.x, stp.y, stp.map
        local via, viaX
        -- 19.33: in einer Hauptstadt mit Ziel in ihrer Zone ausserhalb der Stadtkarte in der Zone rechnen (CityToParent)
        -- (gleich wie beim Navi oben: liegt das Ziel auf der Stadtkarte, dort rechnen)
        local m0, x0, y0 = mapID, px, py
        local cp = ns.cityParent or {}
        if gmap ~= mapID and ns.ToMap and (cp[gmap] == mapID or cp[mapID] == gmap or (cp[gmap] and cp[gmap] == cp[mapID])) then
          local x2, y2 = ns.ToMap(gmap, gx, gy, mapID)
          if x2 then gx, gy, gmap = x2, y2, mapID
          else
            local zm, zx, zy = CityToParent(mapID, px, py, gmap)
            if zm then m0, x0, y0 = zm, zx, zy end
          end
        end
        -- 19.0 (immer): zum ersten Uebergang auf dem besten Weg ueber die Zonen (Gelaende Karte, auch ueber mehrere Zonen)
        if gmap ~= m0 and ns.XZoneNext then
          local cx, cy = ns.XZoneNext(m0, x0, y0, gmap, gx, gy)
          if cx then gx, gy, gmap, via, viaX = cx, cy, m0, true, true end
        end
        if gmap ~= m0 and ns.ZoneCrossing then
          local cx, cy = ns.ZoneCrossing(m0, x0, y0, gmap, gx, gy)
          if cx then gx, gy, gmap, via = cx, cy, m0, true end
        end
        if gmap == m0 then
          local wx, wy = ns.WalkNext(m0, x0, y0, gx, gy)
          resolveSrc = "opt"
          if (wx or via) and ns.WorldDist then resolveFinal = ns.WorldDist({ m0, x0, y0 }, { stp.map, stp.x, stp.y }) end
          if wx then
            -- 19.27: Sprungstelle vor dir (Werkzeug k4)
            if ns.Karte and ns.Karte.JumpNear and ns.Karte.JumpNear() then return m0, x0, y0, wx, wy, oname .. TR"\n|cffffd100hier runter springen|r", opt_pt end
            -- 19.39 (Navi Chat): Stadt Pfeil wie oben beim Navi
            if ns.walkCity and not via then return m0, x0, y0, wx, wy, oname .. (ns.walkGate and TR"\n|cff9d9d9dStadt: erst zum Tor|r" or TR"\n|cff9d9d9dStadt: Richtung Ziel|r"), opt_pt end
            if via then return m0, x0, y0, wx, wy, oname .. ViaText(stp.map, viaX), opt_pt end
            return m0, x0, y0, wx, wy, oname .. TR"\n|cff9d9d9dauf bekanntem Weg um das Gelände|r", opt_pt
          end
          if via then return m0, x0, y0, gx, gy, oname .. ViaText(stp.map, viaX), opt_pt end
          if m0 ~= mapID then
            local cx, cy
            if ns.ZoneCrossing then cx, cy = ns.ZoneCrossing(mapID, px, py, gmap, gx, gy) end
            if cx and cy then
              if ns.WorldDist then resolveFinal = ns.WorldDist({ mapID, px, py }, { stp.map, stp.x, stp.y }) end
              return mapID, px, py, cx, cy, oname .. ViaText(stp.map, false), opt_pt
            end
            resolveFinal = nil; return m0, x0, y0, gx, gy, oname, opt_pt
          end
          resolveSrc, resolveFinal = nil, nil
        end
      end
      local m, a, b, tx, ty = OnPlayerMap(mapID, px, py, stp.map, stp.x, stp.y)
      if m then resolveSrc = "opt"; return m, a, b, tx, ty, oname, opt_pt end
    elseif db.opt then
      return nil, TR"Route fertig"
    end
  end

  local w = ns.levelWarn
  if w and w.target and not w.ignored then
    local t = w.target
    local name = TR"Empfehlung: " .. (t[4] or "?")
    local wp = { t[2], t[3], t[4], tags = (w.kind == "quest") and { quest = w.hub } or nil }
    if t[1] == mapID then return mapID, px, py, t[2], t[3], name, wp end
    local tx, ty = ns.ToMap(t[1], t[2], t[3], mapID)
    if tx then return mapID, px, py, tx, ty, name, wp end
    local cont = ContinentOf(mapID)
    local cpos = cont and C_Map.GetPlayerMapPosition(cont, "player")
    if cpos then
      tx, ty = ns.ToMap(t[1], t[2], t[3], cont)
      if tx then
        local cx, cy = cpos:GetXY()
        return cont, cx, cy, tx, ty, name, wp
      end
    end
  end

  -- 20.3y (K 17:20 Punkt 2, S 16:58: "pfeil zeigt irgendwo hin und minimap auch obwohl keine route berechnet ist"): ohne berechnete
  -- Route (Tour beendet, noch nichts gerechnet) fiel der Pfeil auf die alte Zonen Route zurueck (Wegekreuz). Jetzt Pfeil aus.
  -- db.zonenRouteOhneOpt = true bringt den alten Rueckfall zurueck.
  if db.optMode and not db.zonenRouteOhneOpt and not (db.opt and db.opt.steps and #db.opt.steps > 0) then return nil, "" end
  if not db.show then return end
  -- zuerst die Quests im naechsten offenen Hub holen
  local hub = ns.PendingHub and ns.PendingHub(mapID, px, py)
  if hub then
    -- gleicher NPC: Abgaben und neue Quests zusammen zeigen
    local function Same(list)
      if not hub.hub.npc then return nil end
      for _, e in ipairs(list or {}) do if e.npc == hub.hub.npc then return e end end
    end
    if hub.turnin then
      local hp = { hub[1], hub[2], hub[3], tags = { turnin = hub.hub, quest = Same(ns.qStarts and ns.qStarts[mapID]) } }
      local wx, wy = PatrolPoint(hub.hub.npc, mapID, px, py)
      if wx then return mapID, px, py, wx, wy, TR"Zuerst abgeben: " .. hub[3] .. TR"\n|cff9d9d9dläuft herum, Weg auf der Karte|r", hp end
      return mapID, px, py, hub[1], hub[2], TR"Zuerst abgeben: " .. hub[3], hp
    end
    local hp = { hub[1], hub[2], hub[3], tags = { quest = hub.hub, turnin = Same(ns.qEnds and ns.qEnds[mapID]) } }
    local wx, wy = PatrolPoint(hub.hub.npc, mapID, px, py)
    if wx then return mapID, px, py, wx, wy, TR"Zuerst Quests: " .. hub[3] .. TR"\n|cff9d9d9dläuft herum, Weg auf der Karte|r", hp end
    return mapID, px, py, hub[1], hub[2], TR"Zuerst Quests: " .. hub[3], hp
  end
  local route = ns.GetRoute(mapID)
  local pt = route and route[db.progress[mapID] or 1]
  if not pt then return nil, route and TR"Zone fertig" or "" end
  -- geht der direkte Weg durch eine Gefahrenstelle? Dann zuerst zum Umweg
  local path = ns.DetourPath and ns.DetourPath(mapID, px, py, pt[1], pt[2])
  local dt = path and path[1]
  if dt then
    return mapID, px, py, dt[1], dt[2], TR"Umweg wegen Gefahr", nil
  end
  -- Questziel mit einem einzelnen herumlaufenden Mob: zum naechsten Punkt seines Wegs
  local ob = pt.tags and type(pt.tags.obj) == "table" and pt.tags.obj
  if ob and ob.npcs and #ob.npcs == 1 then
    local wx, wy = PatrolPoint(ob.npcs[1], mapID, px, py)
    if wx then return mapID, px, py, wx, wy, pt[3] .. TR"\n|cff9d9d9dläuft herum, Weg auf der Karte|r", pt end
  end
  return mapID, px, py, pt[1], pt[2], pt[3], pt
end

-- 20.2 (Navi Chat, AUF K 14:08, S P14): der Pfeil lief bei manchen Zielen gerade drauf (Luftlinie), weil nur die
-- Route (opt) und das Navi den Weg ueber das Netz nahmen. Hub "Zuerst Quests/abgeben", Empfehlung, Gold Stopp,
-- Haendler/Lehrer (Service ohne Navi), Zonen Route Punkt und die Rueckfaelle zeigten direkt aufs Ziel. Jetzt geht jedes
-- Ziel auf deiner Karte ueber ns.WalkNext (gleicher Weg wie die Route: Netz, Neu rechnen bei Abweichung und Ziel Wechsel
-- macht Karte.FollowNext). Ist die Luftlinie frei, bleibt sie (WalkNext gibt dann nil). Kosten: Zeit je Rechnung wird
-- gemessen und einmal pro Minute ins Test Log geschrieben (WEGE Pfeil Weg ...). Nie fest verdrahtet: alles ueber die Karte.
local wegStat = { n = 0, sum = 0, max = 0, t0 = 0, um = 0 }
local wegLast -- letztes Ziel, fuer das "Weg statt Luftlinie" geloggt wurde
local function WegZeit(fn, ...)
  local t0 = debugprofilestop and debugprofilestop()
  local a, b = fn(...)
  if t0 then
    local ms = debugprofilestop() - t0
    wegStat.n, wegStat.sum = wegStat.n + 1, wegStat.sum + ms
    if ms > wegStat.max then wegStat.max = ms end
  end
  local now = GetTime and GetTime() or 0
  if wegStat.t0 == 0 then wegStat.t0 = now end
  if now - wegStat.t0 >= 60 and wegStat.n > 0 then
    if ns.TestLog then ns.TestLog("WEGE", ("Pfeil Weg: %d Rechnungen in %d s, im Mittel %.2f ms, hoechstens %.1f ms, %d mal Weg statt Luftlinie")
      :format(wegStat.n, math.floor(now - wegStat.t0 + 0.5), wegStat.sum / wegStat.n, wegStat.max, wegStat.um)) end
    wegStat.n, wegStat.sum, wegStat.max, wegStat.t0, wegStat.um = 0, 0, 0, now, 0
  end
  return a, b
end
-- 20.2 (K AUF 19:36 / KORR 19:38, S 19:32) Regel Wegfindung: liegt ein Ziel (Quest Mob Gebiet, Abgabe, Punkt) laut Netz
-- nicht erreichbar, rechnet die Karte (K.ReachPoint) den naechsten erreichbaren Punkt daneben. Ist der hoechstens
-- WEG_FERN_YD weg: Ausnahme, der Pfeil fuehrt bis dorthin, dann gerade aufs Ziel (Zeile WEG_NAH). Weiter weg: nicht
-- akzeptiert, Fehler der Weg Rechnung (Zeile WEG_FERN mit Zone, Ziel, Abstand, Grund), der Pfeil bleibt wie bisher.
-- Der Abstand ist KEINE Spiel Einstellung: ein Wert in der Konfig Datei des Addons (ns.Konfig.WEG_FERN_YD, Start 50,
-- hoechstens 80). Fehlt die Konfig Datei, gilt der Rueckfall hier. Je Ziel einmal gerechnet (60 s Zwischenspeicher).
local WEG_FERN_RUECKFALL, WEG_FERN_MAX = 50, 80
local function WegFernLimit()
  local k = ns.Konfig
  local v = k and tonumber(k.WEG_FERN_YD) or WEG_FERN_RUECKFALL
  if v > WEG_FERN_MAX then v = WEG_FERN_MAX end
  return v
end
local fernCache, fernN = {}, 0
local function WegFern(m, px, py, tx, ty, name)
  local K = ns.Karte
  if not (K and K.ReachPoint and K.HasZone and K.HasZone(m)) then return nil end
  if K.InCity and K.InCity(m, tx, ty) then return nil end
  local key = ("%d:%.3f:%.3f"):format(m, tx, ty)
  local now = GetTime and GetTime() or 0
  local c = fernCache[key]
  if not c or now - c.t > 60 then
    local ok, rx, ry, rd, why = pcall(K.ReachPoint, m, tx, ty)
    local alt = c
    c = { t = now, logged = alt and alt.logged }
    if ok and rx and rd and rd > 0 then c.rx, c.ry, c.rd, c.why = rx, ry, rd, why end
    if fernN > 200 then fernCache, fernN = {}, 0 end
    if not alt then fernN = fernN + 1 end
    fernCache[key] = c
    if c.rd and not c.logged and ns.TestLog then
      c.logged = true
      local zn = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(m)
      local txt = ("Zone %s (%d), Ziel %.3f %.3f, Abstand zum naechsten Weg %d yd, Grund %s, Grenze %d yd, %s"):format(
        tostring(zn and zn.name or "?"), m, tx, ty, math.floor(c.rd + 0.5), tostring(c.why), WegFernLimit(), tostring(name or "?"):gsub("\n.*", ""))
      ns.TestLog(c.rd <= WegFernLimit() and "WEG_NAH" or "WEG_FERN", txt)
    end
  end
  if not (c.rd and c.rd <= WegFernLimit()) then return nil end
  -- Ausnahme: erst zum erreichbaren Punkt neben dem Ziel, die letzten Meter gerade
  local d = ns.WorldDist and ns.WorldDist({ m, px, py }, { m, c.rx, c.ry })
  if d and d > 10 then return c.rx, c.ry end
  return nil
end

local function ResolveTarget(db)
  local m, px, py, tx, ty, name, tpt = ResolveRaw(db)
  if not tx or type(px) ~= "number" then return m, px, py, tx, ty, name, tpt end
  -- 1.2j (P66, Ka 17:06): auf Zeppelin, Schiff oder Flug kein WEG_FERN und kein Umweg ums Gelaende (Position in der Luft / auf See)
  if ns.OnRide and ns.OnRide() then return m, px, py, tx, ty, name, tpt end
  local fx, fy = WegFern(m, px, py, (tpt and tonumber(tpt[1])) or tx, (tpt and tonumber(tpt[2])) or ty, name)
  -- schon ueber den Weg gerechnet (Route, Navi Lauf Abschnitt, Uebergang): nichts mehr tun
  if resolveSrc == "opt" or resolveFinal then return m, px, py, tx, ty, name, tpt end
  local st = ns.serviceTarget
  if resolveSrc == "svc" and st and st.kind == "navi" then return m, px, py, tx, ty, name, tpt end -- Flug, Schiff, Portal
  if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return m, px, py, tx, ty, name, tpt end
  if not (ns.WalkNext and m == ns.PlayerMap()) then return m, px, py, tx, ty, name, tpt end -- Kontinent Karte: so lassen
  if math.abs(tx - px) < 1e-6 and math.abs(ty - py) < 1e-6 then return m, px, py, tx, ty, name, tpt end -- Ruhestein hier
  if fx and fy then tx, ty = fx, fy; name = (name or "") .. TR"\n|cff9d9d9dZiel abseits des Wegs, bis zum naechsten Weg Punkt" end
  local ok, wx, wy = pcall(WegZeit, ns.WalkNext, m, px, py, tx, ty)
  if not (ok and wx and wy) then return m, px, py, tx, ty, name, tpt end
  if math.abs(wx - tx) < 1e-4 and math.abs(wy - ty) < 1e-4 then return m, px, py, tx, ty, name, tpt end
  if ns.WorldDist then resolveFinal = ns.WorldDist({ m, px, py }, { m, tx, ty }) end
  local key = ("%d:%.3f:%.3f"):format(m, tx, ty)
  if wegLast ~= key then
    wegLast = key
    wegStat.um = wegStat.um + 1
    if ns.TestLog then ns.TestLog("PFEIL", ("Weg statt Luftlinie (%s): %s"):format(resolveSrc or "anderes", tostring(name or "?"):gsub("\n.*", ""))) end
  end
  if ns.walkCity then return m, px, py, wx, wy, (name or "") .. (ns.walkGate and TR"\n|cff9d9d9dStadt: erst zum Tor|r" or TR"\n|cff9d9d9dStadt: Richtung Ziel|r"), tpt end
  return m, px, py, wx, wy, (name or "") .. TR"\n|cff9d9d9dauf bekanntem Weg um das Gelände|r", tpt
end

------------------------------------------------------------
-- Pfeil zum naechsten Punkt
------------------------------------------------------------
local function BuildArrow()
  local db = ns.db
  if db.arrow == nil then db.arrow = true end

  arrow = CreateFrame("Frame", "TaurenRouteArrow", UIParent)
  arrow:SetSize(260, 120)
  arrow:SetFrameStrata("MEDIUM")
  arrow:SetClampedToScreen(true)
  arrow:SetMovable(true)
  arrow:EnableMouse(true)
  arrow:RegisterForDrag("LeftButton")

  arrow.tex = arrow:CreateTexture(nil, "ARTWORK")
  -- Classic: goldener Pfeil aus Figma, ElvUI: schlichter Pfeil in der ElvUI Farbe
  local classicArrow = not (ns.T and ns.T.IsElv and ns.T.IsElv())
  arrow.tex:SetTexture(classicArrow and ((ns.APATH or "Interface\\AddOns\\KeineZeitLevelingGuide\\") .. "Media\\fw_arrow") or "Interface\\Minimap\\MinimapArrow")
  arrow.base = classicArrow and 30 or 48
  arrow.tex:SetSize(arrow.base, arrow.base)
  arrow.classic = classicArrow
  arrow.tex:SetPoint("TOP", arrow, "TOP", 0, 0)
  -- Classic: dunkle Scheibe mit Goldring wie im Journal. ElvUI: schlicht ohne Ring.
  local elv = ns.T and ns.T.IsElv and ns.T.IsElv()
  local M = (ns.APATH or "Interface\\AddOns\\KeineZeitLevelingGuide\\") .. "Media\\"
  if false and not elv then -- Ring passte nicht, kommt mit dem neuen Pfeil Bild weg
    arrow.disc = arrow:CreateTexture(nil, "BACKGROUND")
    arrow.disc:SetSize(54, 54); arrow.disc:SetPoint("CENTER", arrow.tex, "CENTER")
    arrow.disc:SetTexture("Interface\\Buttons\\WHITE8x8"); arrow.disc:SetVertexColor(0, 0, 0, 0.55)
    if arrow.disc.SetMask then pcall(arrow.disc.SetMask, arrow.disc, M .. "fw_mask_circle") end
    arrow.ring = arrow:CreateTexture(nil, "BORDER")
    arrow.ring:SetSize(62, 62); arrow.ring:SetPoint("CENTER", arrow.tex, "CENTER")
    arrow.ring:SetTexture(M .. "fw_ring")
  end
  -- Icon fuer die Art vom Ziel, links neben dem Pfeil
  arrow.kind = arrow:CreateTexture(nil, "OVERLAY")
  arrow.kind:SetSize(20, 20)
  arrow.kind:SetPoint("RIGHT", arrow.tex, "LEFT", -10, 0)
  arrow.kind:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- Kreuz, wenn es kein Ziel oder keinen Weg gibt (Sanduhr, solange gerechnet wird)
  arrow.cross = arrow:CreateTexture(nil, "ARTWORK")
  arrow.cross:SetSize(36, 36)
  arrow.cross:SetPoint("CENTER", arrow.tex, "CENTER", 0, 0)
  arrow.cross:Hide()

  arrow.text = arrow:CreateFontString(nil, "OVERLAY", ns.FontName and ns.FontName("GameFontHighlightSmall") or "GameFontHighlightSmall")   -- 20.3 P12: Schrift Faktor
  arrow.text:SetPoint("TOP", arrow.tex, "BOTTOM", 0, -6)
  arrow.text:SetWidth(260)
  arrow.text:SetJustifyH("CENTER")

  -- Groesse aus den Einstellungen: nur der Pfeil selbst, Text und Symbol bleiben gleich gross.
  -- Vorher wurde das ganze Fenster skaliert: gespeicherte Position einmal umrechnen.
  if not db.arrowTexOnly then
    local s0 = db.arrowScale or 1
    if db.arrowPos and s0 ~= 1 then
      db.arrowPos[3] = (db.arrowPos[3] or 0) * s0
      db.arrowPos[4] = (db.arrowPos[4] or 0) * s0
    end
    db.arrowTexOnly = true
  end
  ns.ApplyArrowSize()
  local p = db.arrowPos
  if p then
    arrow:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    arrow:SetPoint("TOP", UIParent, "TOP", 0, -140)
  end

  arrow:SetScript("OnDragStart", function(self)
    if not db.arrowLocked then self:StartMoving() end
  end)
  arrow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local a, _, b, x, y = self:GetPoint()
    db.arrowPos = { a, b, x, y }
    if ns.RefreshItemBar then ns.RefreshItemBar() end
  end)
  arrow:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then
      db.arrowLocked = not db.arrowLocked
      ns.Print(db.arrowLocked and TR"Pfeil gesperrt" or TR"Pfeil verschiebbar")
    end
  end)

  -- 19.32: kein AzerothGPS mehr (vorher Andocken und Folgen an seinem Pfeil)
  local following, docked, gpsTex = false, false, nil

  local acc, slow = 0, 1
  local cm, ctx, cty -- zuletzt bestimmtes Ziel (Karte und Punkt)
  -- Pfeil drehen: schnell und billig, nur mit dem gemerkten Ziel
  local function Rotate(self, m, px, py, tx, ty)
    local w, h = MapSize(m)
    local east = (tx - px) * w
    local north = -(ty - py) * h
    local facing = GetPlayerFacing and ns.Plain(GetPlayerFacing())
    if not facing then self.tex:Hide(); return end
    local bearing = (math.atan2 or math.atan)(-east, north)
    local rel = bearing - facing
    while rel > math.pi do rel = rel - 2 * math.pi end
    while rel < -math.pi do rel = rel + 2 * math.pi end
    self.tex:SetRotation(rel)
    local a = math.abs(rel)
    local elv = ns.T and ns.T.IsElv and ns.T.IsElv()
    if a < 0.26 then
      if elv then self.tex:SetVertexColor(ns.T.Acc()) else self.tex:SetVertexColor(1, 1, 1) end -- passt
    elseif a < 1.2 then
      if elv then self.tex:SetVertexColor(0.8, 0.8, 0.8) else self.tex:SetVertexColor(1, 0.7, 0.45) end -- leicht daneben
    else
      self.tex:SetVertexColor(1, 0.25, 0.25) -- falsche Richtung
    end
    self.tex:Show()
  end
  arrow:SetScript("OnUpdate", function(self, elapsed)
    if ns.db and ns.db.paused then self:Hide(); return end
    acc = acc + elapsed
    if acc < 0.05 then return end
    slow = slow + acc
    acc = 0
    -- 20 mal pro Sekunde nur drehen, 4 mal pro Sekunde Ziel und Text neu
    if slow < 0.25 then
      if following and gpsTex then
        local rel = gpsTex:GetRotation() or 0
        self.tex:SetRotation(rel)
        local a = math.abs(rel)
        local elv = ns.T and ns.T.IsElv and ns.T.IsElv()
        if a < 0.35 then if elv then self.tex:SetVertexColor(ns.T.Acc()) else self.tex:SetVertexColor(1, 1, 1) end
        elseif a < 1.75 then if elv then self.tex:SetVertexColor(0.8, 0.8, 0.8) else self.tex:SetVertexColor(1, 0.7, 0.45) end
        else self.tex:SetVertexColor(1, 0.25, 0.25) end
        self.tex:Show()
      elseif cm and not docked then
        local pos = C_Map.GetPlayerMapPosition(cm, "player")
        if pos then
          local px, py = pos:GetXY()
          Rotate(self, cm, px, py, ctx, cty)
        end
      end
      return
    end
    slow = 0

    local m, px, py, tx, ty, name, tpt = ResolveTarget(db)
    -- fuers Test Log: wohin zeigt der Pfeil und woher kommt das Ziel
    ns.arrowNow, ns.arrowSrc = tx and name or nil, resolveSrc
    -- 19.31 (Saschas Runde: "Questmob in falscher Richtung"): Ziel Punkt des Pfeils fuers Test Log (Notiz mit Ort)
    ns.arrowAt = tx and { m, tx, ty, px, py } or nil
    if not tx then
      cm = nil
      self.tex:Hide()
      self.kind:Hide()
      local why = type(px) == "string" and px ~= "" and px or nil
      local busy = ns.OptBusy and ns.OptBusy()
      local fertig = why and (why:find("fertig") or why == TR"Route fertig" or why == TR"Zone fertig")
      if not why then
        -- (ohne TR, darum englisch direkt hier)
        if busy then why = ns.EN and "|cffffd100Calculating route ...|r" or "|cffffd100Route wird gerechnet ...|r"
        elseif db.show == false then why = ns.EN and "|cff9d9d9dRoute is off|r" or "|cff9d9d9dRoute ist aus|r"
        -- 17.9: im Dungeon gibt es keine Position, das ist kein Fehler
        elseif ns.InTram and ns.InTram() then why = ns.EN and "|cff9d9d9dIn the Deeprun Tram. What to do is in the mini window.|r" or "|cff9d9d9dIn der Tiefenbahn. Was zu tun ist, steht im Mini Fenster.|r"
        elseif ns.InInstance and ns.InInstance() then why = ns.EN and "|cff9d9d9dIn a dungeon. The arrow continues outside.|r" or "|cff9d9d9dIm Dungeon. Draussen geht der Pfeil weiter.|r"
        else why = ns.EN and "|cffff5050No path found.|r |cff9d9d9dIn the mini window: Menu, Recalculate|r" or "|cffff5050Kein Weg gefunden.|r |cff9d9d9dIm Mini Fenster: Menü, Neu rechnen|r" end
      end
      local inInst = (ns.InInstance and ns.InInstance()) or (ns.InTram and ns.InTram())
      self.cross:SetTexture((busy or inInst) and "Interface\\RaidFrame\\ReadyCheck-Waiting" or (fertig and "Interface\\RaidFrame\\ReadyCheck-Ready") or "Interface\\RaidFrame\\ReadyCheck-NotReady")
      self.cross:Show()
      self.text:SetText(why)
      return
    end
    self.cross:Hide()
    cm, ctx, cty = m, tx, ty

    local w, h = MapSize(m)
    local east = (tx - px) * w
    local north = -(ty - py) * h
    local dist = math.sqrt(east * east + north * north)

    -- Art vom Ziel: Icon und wie nah man sein muss (nur wenn der Pfeil wirklich auf den Routen Schritt zeigt)
    local act = resolveSrc == "opt" and ns.OptCurrentAct and ns.OptCurrentAct() or nil
    local ic, near = nil, 15
    if act then
      if act.k == "O" then ic = act.npcs and "Interface\\Icons\\Ability_DualWield" or "Interface\\Icons\\INV_Misc_Bag_08"; near = act.radius or 20
      else ic = KIND_ICON[act.k] end
      if act.k == "F" or act.k == "V" or act.k == "B" or act.k == "L" then near = 20 end
    elseif resolveSrc == "svc" and ns.serviceTarget then
      ic = SVC_ICON[ns.serviceTarget.kind]; near = 20
    end
    self.kind:SetTexture(ic)
    self.kind:SetShown(ic ~= nil)
    -- 20.3z4 (K 19:06, S 18:51 "kein Feld mit Target neben dem Pfeil" bei Flugpunkt holen: Georgia): einmal je Schritt ins Test Log,
    -- was der Ziel Knopf (UI.lua TargetInfo) fuer diesen Schritt liefert, damit man sieht, woran es liegt
    if act and ns.TestLog and ns.TargetInfo then
      local key = tostring(resolveSrc) .. tostring(act.k) .. tostring(act.npc) .. tostring(act.who) .. tostring(act.quest)
      if key ~= self.tiKey then
        self.tiKey = key
        local ok, n, kd = pcall(ns.TargetInfo)
        ns.TestLog("ZIELKNOPF", ("Schritt k=%s npc=%s who=%s quest=%s: Knopf Name=%s (%s), Quelle %s, Einstellung %s, Symbol %s"):format(
          tostring(act.k), tostring(act.npc), tostring(act.who), tostring(act.quest), ok and tostring(n) or ("Fehler " .. tostring(n)), tostring(kd),
          tostring(resolveSrc), tostring(ns.db and ns.db.targetBtn), tostring(ic ~= nil)))
      end
    end
    -- Zwischenpunkt (Weg ums Gelaende, Zonenuebergang): Yards und Zeit bis zum echten Ziel, "Da!" erst dort
    local shown = resolveFinal or dist
    local eta = shown / Speed()
    -- unter dem Pfeil nur kurz: was zu tun ist, Entfernung, ungefaehre Zeit. Quests und Fortschritt stehen im Mini Fenster.
    local label = (resolveSrc == "opt" or resolveSrc == "svc") and ns.ArrowLabel(resolveSrc == "opt" and act or nil, resolveSrc == "svc")
    if not label then label = tostring(name or "?"):gsub("\n.*", "") end
    -- schlank darunter: offene Ziele mit Stand oder die Quest (hoechstens 3 kurze Zeilen)
    local det = resolveSrc == "opt" and ns.ArrowDetail and ns.ArrowDetail(act)
    if det then label = label .. "\n|cffd8d8d8" .. det .. "|r" end
    local info = (TR"%s\n%d Yards, ca %s"):format(label, math.floor(shown), ns.Clock(eta))
    if dist < near and not resolveFinal then info = label .. "\nDa!" end
    -- Ruhestein: wird da benutzt, wo du stehst. Kein Pfeil zum Gasthaus (sonst laeuft man die 3000 Yards hin)
    local hearthNow = act and act.k == "H" and not docked
    -- 19.33 (Pruefer 09:08 LEICHT 3): auch beim Navi Abschnitt Ruhestein, Rueckruf oder Teleport (Knopf darunter)
    if not hearthNow and not docked and resolveSrc == "svc" and ns.NaviHearthWanted and ns.NaviHearthWanted() then hearthNow = true end
    -- 19.31: klar sagen, dass jetzt der Moment ist, und wo der Knopf ist
    if hearthNow then info = "|cffffd100" .. TR"Jetzt" .. "|r " .. label .. "\n" .. TR"jetzt benutzen, wo du stehst" .. "\n" .. TR"Knopf darunter klicken" end
    if hearthNow then self.tex:Hide(); cm = nil end
    -- 1.1 (S Wunsch): im Flug die Flugzeit, wenn sie bekannt ist (eigene Messung oder von anderen geteilt)
    -- 1.2e (P62, S 14:30): als Balken, der sich fuellt, mit der Restzeit drin ("2:10 von 3:27")
    local flying = (ns.InFlight and ns.InFlight()) or (not ns.InFlight and UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player"))
    local fLeft, fTotal, fSrc
    if flying and ns.FlightNow then
      local okF, left, total, src = pcall(ns.FlightNow)
      if okF and left and total and total > 0 then fLeft, fTotal, fSrc = left, total, src end
    end
    if fLeft then
      local fb = self.flightBar
      if not fb then
        fb = CreateFrame("StatusBar", nil, self)
        fb:SetSize(ns.FLIGHT_BAR_W, ns.FLIGHT_BAR_H)
        fb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        fb:SetStatusBarColor(0.4, 0.8, 1, 0.9)
        fb.bg = fb:CreateTexture(nil, "BACKGROUND")
        fb.bg:SetAllPoints()
        fb.bg:SetColorTexture(0, 0, 0, 0.55)
        fb.txt = fb:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
        fb.txt:SetPoint("CENTER")
        self.flightBar = fb
      end
      fb:ClearAllPoints()
      fb:SetPoint("TOP", self.text, "BOTTOM", 0, -3)
      fb:SetMinMaxValues(0, fTotal)
      fb:SetValue(math.max(0, fTotal - fLeft))
      fb.txt:SetText((TR"%s von %s%s"):format(ns.Clock(fLeft), ns.Clock(fTotal), fSrc == "geteilt" and TR" (geteilt)" or ""))
      fb:Show()
    elseif self.flightBar then
      self.flightBar:Hide()
    end
    self.text:SetText(info)
    if not docked and not following and not hearthNow then Rotate(self, m, px, py, tx, ty) end
  end)

  if db.arrow then arrow:Show() else arrow:Hide() end
end

-- woher das Ziel des Pfeils kommt ("opt", "svc" oder nil); ohne sichtbaren Pfeil gilt die Route
function ns.ArrowSource()
  local a = _G.TaurenRouteArrow
  if a and a:IsShown() then return resolveSrc end
  return "opt"
end

-- Kurzer Text unter dem Pfeil: nur was zu tun ist (Details stehen im Mini Fenster)
local SVC_LABEL = { vendor = TR"Händler", repair = TR"Reparieren", inn = TR"Gasthaus", trainer = TR"Lehrer", fly = TR"Flugpunkt", book = TR"Buch",
  books = TR"Bücher abgeben", prof = TR"Farmgebiet", missed = TR"Vergessene Quest", help = TR"Gruppe helfen", dungeon = TR"Dungeon Eingang",
  quest = TR"Questgeber" }
function ns.ArrowLabel(act, svc)
  local st = ns.serviceTarget
  if svc then return st and SVC_LABEL[st.kind] or TR"Ziel" end
  if not act then return nil end
  local k = act.k
  if k == "A" then return TR"Annehmen" end
  if k == "T" then return TR"Abgeben" end
  if k == "O" then return act.buyAt and TR"Kaufen" or act.npcs and TR"Mobs" or TR"Questziel" end
  if k == "V" then
    if act.trainer then return TR"Lehrer" end
    if act.books then return TR"Bücher abgeben" end
    if act.buy then return TR"Einkaufen" end
    return TR"Verkaufen"
  end
  if k == "F" then return TR"Flugpunkt holen" end
  if k == "R" then return (TR"%s nehmen"):format(act.kind or TR"Schiff") end
  if k == "G" then return act.hint and ((act.grp and act.dung) and TR"Dungeon" or (act.dung and TR"Dungeon oder grinden" or TR"Grinden oder Dungeons")) or (act.farm and TR"Gold farmen" or (act.repFarm and TR"Ruf farmen" or TR"Grinden")) end
  if k == "K" then return TR"Buch holen" end
  if k == "E" then return TR"Entdecken" end
  if k == "L" then return TR"Ausloggen" end
  if k == "B" then return TR"Ruhestein binden" end
  if k == "H" then return act.recall and TR"Astraler Rückruf" or TR"Ruhestein benutzen" end
  if k == "M" then return TR"Treffpunkt" end
  if k == "P" then return act.fish and TR"Angeln" or (act.school and TR"Schwarm" or (act.mob and TR"Farmen" or TR"Sammeln")) end
  return nil
end

-- Unter dem Pfeil, ganz kurz: was genau zu tun ist. Questziele mit Stand ("Ebenenschreiter 3/8"),
-- beim Annehmen und Abgeben die Quest, sonst der Name vom Ziel. Hoechstens 3 Zeilen.
local function Plain(t) return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function Short(t, n)
  t = tostring(t or "")
  if #Plain(t) <= n then return t end
  -- zu lang: farbigen Zusatz am Ende (zb "(Klasse)") weglassen, dann ohne Farben kuerzen (sonst bleibt ein Farbcode offen)
  local base = t:gsub("%s*|c%x%x%x%x%x%x%x%x%(.-%)|r%s*$", "")
  if #Plain(base) <= n then return base end
  return (Plain(base):sub(1, n - 2):gsub("[\192-\255][\128-\191]*$", "")) .. ".."
end
local function ObjLine(o)
  local txt = tostring(o.text or "")
  local name, prog = txt:match("^(.-):%s*(%d+%s*/%s*%d+)%s*$")
  if name then
    name = name:gsub(" getötet$", ""):gsub(" slain$", ""):gsub(" killed$", "")
    -- 1.1 (P40): Zaehler gruen, wenn fast voll (gleiche Regel wie im Mini Fenster)
    local h, nd = prog:match("(%d+)%s*/%s*(%d+)")
    h, nd = tonumber(h), tonumber(nd)
    local p2 = prog:gsub("%s", "")
    if h and nd and nd > 0 and ns.HUD_NEAR_DONE and (h / nd >= ns.HUD_NEAR_DONE or nd - h <= ns.HUD_NEAR_LEFT) then
      p2 = "|cff" .. ns.HUD_NEAR_COL .. p2 .. "|r"
    end
    return Short(name, 26) .. " " .. p2
  end
  return Short(txt, 32)
end
ns.ArrowObjLine = ObjLine
local det = { t = -10 }
function ns.ArrowDetail(act)
  local db = ns.db
  local opt = db and db.optMode and db.opt
  local st = opt and opt.steps and opt.steps[opt.idx or 1]
  if not (st and act and st.acts) then return nil end
  local now = GetTime and GetTime() or 0
  if det.st == st and det.a == act and now - det.t < 1 then return det.v end
  local lines = {}
  local k = act.k
  if k == "O" then
    local seen = {}
    for _, a in ipairs(st.acts) do
      if a.k == "O" and #lines < 3 then
        local lp = a.qid and ns.logProgress and ns.logProgress[a.qid]
        local want = ns.OptObjKey and ns.OptObjKey(a.obj)
        local hit = false
        local o, oi = nil, nil
        if want and want ~= "" and lp then
          o, oi = ns.ObjFind(lp.objs, want, function(x) return tostring(x.text or "") end, function(k2) return seen[a.qid .. ":" .. k2] end)
        end
        if o then
          seen[a.qid .. ":" .. oi] = true; hit = true
          if not o.done then table.insert(lines, ObjLine(o)) end
        end
        if not hit then
          if lp then
            for oi, o in ipairs(lp.objs or {}) do
              local key = a.qid .. ":" .. oi
              if not seen[key] and not o.done and #lines < 3 then seen[key] = true; table.insert(lines, ObjLine(o)) end
            end
          elseif a.obj and not (ns.OptActDone and ns.OptActDone(a)) then
            table.insert(lines, Short(ns.OptObjShow and ns.OptObjShow(a) or a.obj, 32))
          end
        end
      end
    end
  elseif k == "A" or k == "T" then
    local names = {}
    for _, a in ipairs(st.acts) do
      if a.k == k and a.quest and not (ns.OptActDone and ns.OptActDone(a)) then table.insert(names, a.quest) end
    end
    if #names > 0 then lines[1] = Short(names[1], 34) .. (#names > 1 and ("  +" .. (#names - 1)) or "") end
  elseif k == "G" and act.kills then
    lines[1] = ((act.kills == 1) and TR"Noch ca %d Mob, dann Lehrer" or TR"Noch ca %d Mobs, dann Lehrer"):format(act.kills)
  elseif k == "G" and not act.hint and not act.farm and not act.repFarm then
    lines[1] = Short(act.obj or TR"Mobs", 24) .. (act.toLvl and (TR", bis Level %.1f"):format(act.toLvl) or "")
  else
    local nm = (k == "F" and act.who) or (k == "R" and act.dest) or (k == "E" and act.name) or act.quest or act.name
    if nm and nm ~= "" then lines[1] = Short(nm, 34) end
  end
  local v = #lines > 0 and table.concat(lines, "\n") or nil
  det.st, det.a, det.t, det.v = st, act, now, v
  return v
end

-- Pruefen, warum der Pfeil nicht zu sehen ist (/fw pfeil)
function ns.ArrowCheck()
  local db = ns.db or {}
  local ON, OFF = ns.EN and "on" or "an", ns.EN and "off" or "aus"
  local shown = arrow and arrow:IsShown()
  ns.Print((TR"Pfeil: %s, Route: %s, Rechnet gerade: %s"):format(shown and ON or OFF, db.show == false and OFF or ON, (ns.OptBusy and ns.OptBusy()) and (ns.EN and "yes" or "ja") or (ns.EN and "no" or "nein")))
  local opt = db.opt
  ns.Print(opt and opt.steps and (TR"Route: %s, Schritt %d von %d"):format(opt.title or TR"Normal", opt.idx or 1, #opt.steps) or TR"Keine Route berechnet.")
  if db.paused then ns.Print(TR"Pause ist an: mit Weitermachen kommt der Pfeil wieder.") end
  if not shown and not db.paused then ns.Print(TR"Pfeil war aus und ist jetzt wieder an.") ; db.arrow = true; if arrow then arrow:Show() end end
  if db.show == false then db.show = true; ns.Print(TR"Route war aus und ist jetzt wieder an.") end
  if not opt or (opt.idx or 1) > #(opt.steps or {}) then if ns.AutoOpt then ns.AutoOpt(true) end end
end

-- Pfeil groesser oder kleiner: nur das Pfeil Bild (und Kreuz oder Sanduhr an seiner Stelle).
-- Text und Symbol bleiben gleich, der Text rutscht einfach unter den Pfeil.
ns.ARROW_MIN, ns.ARROW_MAX = 0.5, 3
function ns.ApplyArrowSize()
  if not (arrow and ns.db) then return end
  local s = math.max(ns.ARROW_MIN, math.min(ns.ARROW_MAX, ns.db.arrowScale or 1))
  if arrow:GetScale() ~= 1 then arrow:SetScale(1) end
  local b = arrow.base or 30
  arrow.tex:SetSize(b * s, b * s)
  arrow.cross:SetSize(36 * s, 36 * s)
  -- Schrift unter dem Pfeil: eigene Groesse
  local ts = math.max(ns.ARROW_TEXT_MIN, math.min(ns.ARROW_TEXT_MAX, ns.db.arrowText or 1))
  -- 20.3 P12: Basis ist das Schrift Objekt mit dem Schrift Faktor aus den Einstellungen (ns.FontName, Locale.lua), dazu die Pfeil Text Groesse
  local fo = _G[(ns.FontName and ns.FontName("GameFontHighlightSmall")) or "GameFontHighlightSmall"] or _G.GameFontHighlightSmall
  local font, size, flags
  if fo and fo.GetFont then font, size, flags = fo:GetFont() end
  if font and size then
    arrow.text:SetFont(font, math.floor(size * ts + 0.5), flags)
    arrow.text:SetWidth(260 * math.max(1, ts))
  end
  arrow:SetHeight(120 + math.max(0, b * s - b))
end

-- 20.3 P12: aendert sich der Schrift Faktor (Einstellungen, oder beim Betreten der Welt neu von der Vorlage), Pfeil Text neu setzen
if hooksecurefunc then
  for _, nm in ipairs({ "SetFontScale", "ApplyFontScale" }) do
    if type(ns[nm]) == "function" then pcall(hooksecurefunc, ns, nm, function() if ns.ApplyArrowSize then pcall(ns.ApplyArrowSize) end end) end
  end
end

ns.ARROW_TEXT_MIN, ns.ARROW_TEXT_MAX = 0.8, 2
function ns.SetArrowTextScale(v)
  local db = ns.db
  if not db then return end
  v = math.floor(math.max(ns.ARROW_TEXT_MIN, math.min(ns.ARROW_TEXT_MAX, v or 1)) * 10 + 0.5) / 10
  if db.arrowText == v then return end
  db.arrowText = v
  ns.ApplyArrowSize()
end

function ns.SetArrowScale(v)
  local db = ns.db
  if not db then return end
  v = math.floor(math.max(ns.ARROW_MIN, math.min(ns.ARROW_MAX, v or 1)) * 10 + 0.5) / 10
  if db.arrowScale == v then return end
  db.arrowScale = v
  ns.ApplyArrowSize()
  if ns.RefreshItemBar then ns.RefreshItemBar() end
end

function ns.ToggleArrow()
  if not arrow then return end
  ns.db.arrow = not arrow:IsShown()
  -- in der Pause bleibt er weg (kommt mit Weitermachen wieder)
  if ns.db.arrow and ns.db.paused then ns.Print(TR"Pause ist an: mit Weitermachen kommt der Pfeil wieder.") end
  if ns.db.arrow and not ns.db.paused then arrow:Show() else arrow:Hide() end
  if ns.RefreshItemBar then ns.RefreshItemBar() end
end

------------------------------------------------------------
-- Zeit bis zum Mauszeiger auf der Weltkarte
------------------------------------------------------------
local function BuildHover()
  if not WorldMapFrame then return end
  local holder = CreateFrame("Frame", nil, WorldMapFrame)
  holder:SetAllPoints(WorldMapFrame)

  hoverBox = CreateFrame("Frame", nil, holder, BackdropTemplateMixin and "BackdropTemplate" or nil)
  hoverBox:SetFrameStrata("TOOLTIP")
  hoverBox:SetSize(170, 36)
  if hoverBox.SetBackdrop then
    hoverBox:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 10,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    hoverBox:SetBackdropColor(0, 0, 0, 0.75)
  end
  hoverBox.text = hoverBox:CreateFontString(nil, "OVERLAY", ns.FontName and ns.FontName("GameFontHighlightSmall") or "GameFontHighlightSmall")
  hoverBox.text:SetPoint("CENTER")
  hoverBox.text:SetJustifyH("LEFT")
  hoverBox:Hide()

  -- Kartenposition unter der Maus, falls noetig auf die Zone umgerechnet
  local function CursorZonePos(sc)
    -- OpenMap: Maus Position auf der zusammengesetzten Karte in die Zone darunter umrechnen
    local OM = OpenMapAPI
    if OM and OM.IsStitched and OM.IsStitched() then
      local u, v = OM.CursorPosition()
      if not u then return end
      local zone = OM.MapAt(u, v)
      if ns.cityParent and zone and ns.cityParent[zone] then zone = ns.cityParent[zone] end
      local zx, zy
      if zone then zx, zy = OM.MapFromWorld(zone, u, v) end
      if zx then return zone, zx, zy, false end
      return
    end
    if not sc.GetNormalizedCursorPosition then return end
    local cx, cy = sc:GetNormalizedCursorPosition()
    local mapID = WorldMapFrame:GetMapID()
    if not (cx and cy and mapID) then return end
    local info = C_Map.GetMapInfo(mapID)
    if info and info.mapType and info.mapType < Enum.UIMapType.Zone and C_Map.GetMapInfoAtPosition then
      local zi = C_Map.GetMapInfoAtPosition(mapID, cx, cy)
      if zi and zi.mapID then
        local zx, zy = ns.ToMap(mapID, cx, cy, zi.mapID)
        if zx then return zi.mapID, zx, zy, true end
      end
      return nil
    end
    return mapID, cx, cy, false
  end

  -- Shift + Klick (Wegpunkte auf der alten Zonenroute) gibt es nicht mehr: die Route ist jetzt die optimierte

  -- Alt + Klick: Gefahr setzen oder loeschen, Alt + Strg + Klick: grosse Gefahr
  local sc0 = WorldMapFrame.ScrollContainer
  if sc0 and sc0.HookScript then
    sc0:HookScript("OnMouseUp", function(self, button)
      if button ~= "LeftButton" or not IsAltKeyDown() then return end
      if OpenMapAPI and OpenMapAPI.IsStitched and OpenMapAPI.IsStitched() then
        local zm, zx, zy = CursorZonePos(self)
        if zm then ns.ToggleDangerAt(zm, zx, zy, IsControlKeyDown()) end
        return
      end
      if not self.GetNormalizedCursorPosition then return end
      local cx, cy = self:GetNormalizedCursorPosition()
      local mapID = WorldMapFrame:GetMapID()
      if not (cx and cy and mapID) then return end
      local info = C_Map.GetMapInfo(mapID)
      -- auf Kontinent oder Welt: die Zone unter der Maus suchen
      if info and info.mapType and info.mapType < Enum.UIMapType.Zone and C_Map.GetMapInfoAtPosition then
        local zi = C_Map.GetMapInfoAtPosition(mapID, cx, cy)
        if zi and zi.mapID then
          local zx, zy = ns.ToMap(mapID, cx, cy, zi.mapID)
          if zx then mapID, cx, cy = zi.mapID, zx, zy end
        end
      end
      ns.ToggleDangerAt(mapID, cx, cy, IsControlKeyDown())
    end)
  end

  local acc = 0
  holder:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc < 0.1 then return end
    acc = 0

    local sc = WorldMapFrame.ScrollContainer
    if not ns.db.mapHover or not sc or not sc:IsMouseOver() or not sc.GetNormalizedCursorPosition then
      hoverBox:Hide()
      return
    end
    local cx, cy = sc:GetNormalizedCursorPosition()
    local mapID = WorldMapFrame:GetMapID()
    -- OpenMap: Zone unter der Maus nehmen
    if OpenMapAPI and OpenMapAPI.IsStitched and OpenMapAPI.IsStitched() then
      mapID, cx, cy = CursorZonePos(sc)
    end
    if not (cx and cy and mapID) or cx < 0 or cx > 1 or cy < 0 or cy > 1 then
      hoverBox:Hide()
      return
    end

    local txt
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then
      txt = ns.EN and "You are not on this map" or "Du bist nicht auf dieser Karte"
    else
      local px, py = pos:GetXY()
      local d = ns.WorldDist({ mapID, px, py }, { mapID, cx, cy })
      if not d then
        txt = "Anderer Kontinent"
      else
        txt = (TR"%d yd Luftlinie\nca %s bei %d%% Tempo\n|cff9d9d9dAlt+Klick: Gefahr markieren|r"):format(math.floor(d), ns.Clock(d / Speed()), math.floor(Speed() / 7 * 100 + 0.5))
      end
    end
    -- ueber einem Punkt oder einer Gefahr: was ist dort zu tun
    local zMap, zx, zy, fromCont = CursorZonePos(sc)
    if zMap and not fromCont then
      -- Punkte der alten Zonenroute nur, wenn die gezeigt wird
      local p = not (ns.db and ns.db.optMode) and ns.PointAt(zMap, zx, zy, 0.012)
      if p then
        txt = table.concat(ns.PointHint(zMap, p), "\n") .. "\n" .. txt
      else
        for _, d in ipairs(ns.Dangers(zMap)) do
          if math.sqrt((d[1] - zx) ^ 2 + (d[2] - zy) ^ 2) < d[3] then
            txt = (TR"|cffff2020Gefahr:|r %s\n|cff9d9d9dAlt+Klick löscht sie|r\n"):format(d[4] or "?") .. txt
            break
          end
        end
      end
    end
    hoverBox.text:SetText(txt)
    hoverBox:SetWidth(hoverBox.text:GetStringWidth() + 16)
    hoverBox:SetHeight(hoverBox.text:GetStringHeight() + 12)

    -- 19.32 (Navi Chat, UI Pruefer): mit der eigenen Skalierung des Kastens rechnen, nicht mit der von UIParent
    -- (der Kasten haengt an der Karte, bei UI Scale 0.70 und gezoomter Karte sass er sonst neben der Maus)
    local x, y = GetCursorPosition()
    local s = hoverBox:GetEffectiveScale() or UIParent:GetEffectiveScale()
    if not s or s <= 0 then s = 1 end
    hoverBox:ClearAllPoints()
    hoverBox:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 18, y / s + 10)
    hoverBox:Show()
  end)
end

function ns.InitArrow()
  -- Kasten an der Maus auf der Karte: standardmaessig aus (nur noch per /trmap)
  if not ns.db.mapHoverOff2 then ns.db.mapHover = false; ns.db.mapHoverOff2 = true end
  BuildArrow()
  if ns.db.paused and arrow then arrow:Hide() end
  BuildHover()
  SLASH_TAURENROUTEPFEIL1 = "/trpfeil"
  SlashCmdList.TAURENROUTEPFEIL = function() ns.ToggleArrow() end
  SLASH_TAURENROUTEMAP1 = "/trmap"
  SlashCmdList.TAURENROUTEMAP = function()
    ns.db.mapHover = not ns.db.mapHover
    ns.Print(ns.db.mapHover and TR"Zeit auf der Karte an" or TR"Zeit auf der Karte aus")
  end
end

-- 20.3h (Na, test_203g Punkt 6/7/8/13/14): ein altes Pfeil Ziel (Haendler, Gruppe helfen, Pfeil zum Geber, Farmgebiet) steht im
-- Pfeil vor jeder Route und blieb nach "Route folgen", Ruf, Angeln, Gold farmen und Rundgang stehen. Der Pfeil zeigte
-- weiter dorthin ("Pfeil zeigt zu: Je'neu Sancrea"), obwohl das Mini Fenster die neue Route zeigte. Jetzt: wird eine Route
-- geladen (ns.OptLoad, alle Seiten laufen darueber), faellt das alte Pfeil Ziel weg.
local optHook = CreateFrame("Frame")
optHook:RegisterEvent("PLAYER_LOGIN")
optHook:SetScript("OnEvent", function(self)
  self:UnregisterAllEvents()
  if not (hooksecurefunc and ns.OptLoad) then return end
  -- 20.3l (K1, Log 20.3k 22:04): vorher lief das Loeschen NACH ns.OptLoad (hooksecurefunc) und damit nach dem Navi Start der
  -- neuen Zusatz Route (Ad OptFarStart) - es beendete das gerade gestartete Navi. Jetzt VOR dem Laden: altes Pfeil Ziel weg,
  -- dann laedt die Route und darf ihr eigenes Ziel/Navi setzen.
  local orig = ns.OptLoad
  ns.OptLoad = function(...)
    local st = ns.serviceTarget
    if st then
      ns.serviceTarget = nil
      if ns.TestLog then ns.TestLog("PFEIL", ("altes Pfeil Ziel weg bei neuer Route: %s %s"):format(tostring(st.kind), tostring(st.name))) end
    end
    return orig(...)
  end
end)

-- 20.4 (Na, K 19:33 GO, Plan K 17:40 "Live Nachrechnen"), Teil A: Auslöser, Pfeil Hysterese, Mini Fenster Text.
-- Der Optimizer Teil (B Reihenfolge, C beste Stelle, D Gelegenheit) kommt von Ad ueber diese Schnittstelle (absprache\live_nachrechnen.md):
--   ns.LiveReplan(reason, ctx) -> nil oder { oldSec=, newSec=, apply=function() ... end }   (rechnet nur, aendert NICHTS)
--   ns.LiveChance()            -> nil oder { text=, sec= }                                   (Gelegenheit am Weg, aendert NICHTS)
--   ns.LiveChanceTake()        optional: wird bei Klick auf den Hinweis aufgerufen
-- Hier: wann gerechnet wird (alle 10 s billig pruefen, nur bei Ausloeser rechnen) und wann der Pfeil wirklich wechselt.
-- Schalter: ns.db.liveCalc = false schaltet alles aus. Fehlt ns.LiveReplan, laeuft nur das Test Log (LIVE Zeilen).
do
  local LIVE_EVERY   = 10     -- Sekunden zwischen Positions Pruefungen
  local DEV_YARDS    = 150    -- Abweichung vom geplanten Weg
  local NEAR_RATIO   = 0.875  -- 7/8 gilt als fast fertig
  -- 1.1 (S Notiz L6.7 "neu rechnen scheint nicht zu gehen", Log: 198 Rechnungen, 104 mal nur wegen der Hysterese nicht
  -- gewechselt, meist 8 bis 20 s Gewinn bei 300 bis 480 s): Schwelle tiefer, dazu ein Ausloeser alle LIVE_PERIOD_S
  -- Sekunden (vorher nur bei Abweichung, erledigt, fast fertig, Tod, Zone) und eine kurze Meldung, wenn umgestellt wurde
  local MIN_GAIN_SEC = 15     -- Hysterese: mindestens 15 s ...
  local MIN_GAIN_PCT = 0.04   -- ... oder 4 Prozent schneller
  local LIVE_PERIOD_S = 60    -- spaetestens so oft neu pruefen, auch ohne anderen Ausloeser
  local LIVE_SAY_S = 300      -- v11d: Chat Zeile "Route angepasst" hoechstens so oft
  local LOCK_SEC     = 60     -- nach einem Wechsel oder Wegklicken keine Gelegenheit
  local MIN_GAP      = 20     -- gleicher Ausloeser frueher nicht nochmal
  -- 1.1 (P43, Pr Schluss 1.1f: Pfeil hin und her +25 %): wieder zurueck zum Schritt, den eine Umstellung gerade nach hinten
  -- geschoben hat, nur mit BACK_F mal so viel Gewinn und erst nach BACK_S Sekunden ganz normal
  local BACK_S       = 180
  local BACK_F       = 3
  local L = { acc = 0, fired = {}, lastReason = {}, lockUntil = 0, devHits = 0 }
  ns.liveState = L

  local function Log(tag, msg) if ns.TestLog then ns.TestLog(tag, msg) end end

  local function Enabled()
    local db = ns.db
    return db and db.liveCalc ~= false and db.optMode and db.opt and db.opt.steps and not db.paused
  end

  local function PlayerPos()
    local map = ns.PlayerMap and ns.PlayerMap()
    if not map or not C_Map or not C_Map.GetPlayerMapPosition then return end
    local pos = C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return end
    return map, x, y
  end

  local function Dist(m1, x1, y1, m2, x2, y2)
    if not (m1 and m2 and ns.WorldDistXY) then return end
    return ns.WorldDistXY(m1, x1, y1, m2, x2, y2)
  end

  -- Abstand eines Punktes zur Strecke Start -> Ziel (Yards), alles in Welt Yards der Karte des Spielers
  local function OffLine(sm, sx, sy, tm, tx, ty, pm, px, py)
    local d = Dist(sm, sx, sy, tm, tx, ty)
    local a = Dist(sm, sx, sy, pm, px, py)
    local b = Dist(pm, px, py, tm, tx, ty)
    if not (d and a and b) or d < 40 then return end
    -- Dreieck: Hoehe ueber der Grundlinie, nur wenn der Fuss der Hoehe zwischen Start und Ziel liegt
    local s = (a + b + d) / 2
    local area2 = s * (s - a) * (s - b) * (s - d)
    if area2 <= 0 then return 0 end
    return 2 * math.sqrt(area2) / d
  end

  local function Reset(idx)
    L.idx = idx
    L.fixed = nil
    L.devHits = 0
    L.start = nil
    L.lastD = nil
  end

  -- ein Ausloeser: nur rechnen, wenn ns.LiveReplan da ist, und nur wechseln, wenn es sich lohnt
  local function Fire(reason, ctx)
    local now = GetTime()
    if L.lastReason[reason] and now - L.lastReason[reason] < MIN_GAP then return end
    L.lastReason[reason] = now
    L.periodAt = now
    -- 1.2a (P45): beim Abdriften die Reserve Quests neu bewerten (nah: Schritt)
    if reason == "abweichung" and ns.ReserveOnDrift then
      local okR, took = pcall(ns.ReserveOnDrift)
      if okR and took then Reset(ns.db.opt.idx or 1); return end
    end
    if not ns.LiveReplan then
      Log("LIVE", ("Ausloeser %s (ns.LiveReplan fehlt, nichts gerechnet)"):format(reason))
      return
    end
    -- nach einem Wechsel bleibt es fest, bis der Schritt erledigt ist (Tod und Zonenwechsel duerfen trotzdem)
    local idx = ns.db.opt.idx
    if L.fixed and L.fixed == idx and reason ~= "tod" and reason ~= "zone" and reason ~= "ruhestein" then
      Log("LIVE", ("Ausloeser %s ignoriert: Schritt %s steht fest"):format(reason, tostring(idx)))
      return
    end
    -- 1.1: in Stuecken ueber mehrere Bilder rechnen (bis 10 Schritte), Entscheid danach in Decide
    if ns.LiveReplanAsync then
      ns.LiveReplanAsync(reason, ctx, function(r, err)
        if err then Log("LIVE", ("Ausloeser %s: Fehler %s"):format(reason, tostring(err))); return end
        local okD, eD = pcall(L.Decide, reason, r)
        if not okD then Log("LIVE", ("Ausloeser %s: Fehler %s"):format(reason, tostring(eD))) end
      end)
      return
    end
    local ok, r = pcall(ns.LiveReplan, reason, ctx)
    if not ok then Log("LIVE", ("Ausloeser %s: Fehler %s"):format(reason, tostring(r))); return end
    L.Decide(reason, r)
  end
  -- Ergebnis einer Rechnung: wechseln, wenn es sich lohnt
  function L.Decide(reason, r)
    local now = GetTime()
    if not r then Log("LIVE", ("Ausloeser %s: Reihenfolge bleibt"):format(reason)); return end
    local old, new = tonumber(r.oldSec) or 0, tonumber(r.newSec) or 0
    local gain = old - new
    local f = 1
    if r.newFirst and r.newFirst == L.leftStep and now - (L.leftAt or -999) < BACK_S then f = BACK_F end
    if gain >= MIN_GAIN_SEC * f or (old > 0 and gain / old >= MIN_GAIN_PCT * f) then
      if r.oldFirst and r.newFirst and r.oldFirst ~= r.newFirst then L.leftStep, L.leftAt = r.oldFirst, now end
      local ok2, err = pcall(r.apply or function() end)
      Log("LIVE", ("Ausloeser %s: neue Reihenfolge, %d s schneller (vorher %d s, jetzt %d s)%s"):format(
        reason, gain, old, new, ok2 and "" or (" Fehler " .. tostring(err))))
      Reset(ns.db.opt.idx or 1)       -- neuer Schritt durch unser Umordnen, kein "erledigt"
      L.fixed = ns.db.opt.idx
      L.lockUntil = now + LOCK_SEC
      L.chance = nil
      if ns.Draw then ns.Draw() end
      if ns.RefreshHud then ns.RefreshHud() end
      -- v11d (Pr P4): hoechstens alle LIVE_SAY_S eine Chat Zeile
      if ok2 and ns.Print and ns.db and ns.db.liveSay ~= false and now - (L.saidAt or -999) > LIVE_SAY_S then
        L.saidAt = now
        ns.Print((TR"Route angepasst: neue Reihenfolge, ca %d s schneller."):format(gain))
      end
    else
      Log("LIVE", ("Ausloeser %s: nur %d s schneller (vorher %d s), Pfeil bleibt (Hysterese%s)"):format(reason, gain, old, f > 1 and ", waere zurueck" or ""))
    end
  end
  ns.LiveFire = Fire

  -- Gelegenheit abfragen (billig, Ad cached). Text fuers Mini Fenster
  local function Chance()
    if not ns.LiveChance or GetTime() < L.lockUntil then L.chance = nil; return end
    local ok, c = pcall(ns.LiveChance)
    if ok and type(c) == "table" and c.text then
      if not L.chance or L.chance.text ~= c.text then Log("LIVE", ("Gelegenheit: %s (%s s)"):format(tostring(c.text), tostring(c.sec))) end
      L.chance = { text = c.text, sec = c.sec, t = GetTime() }
    else
      L.chance = nil
    end
  end

  local function Check()
    if not Enabled() then return end
    if ns.navi and not ns.navi.hidden then return end   -- Navi fuehrt gerade, nicht die Route
    if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then return end
    if (ns.InInstance and ns.InInstance()) or (ns.InTram and ns.InTram()) then return end
    if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then return end
    if UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player") then return end   -- im Kampf nicht rechnen
    local opt = ns.db.opt
    local idx = opt.idx or 1
    local s = opt.steps[idx]
    if not s then return end
    local pm, px, py = PlayerPos()
    if not pm then return end
    -- Schritt erledigt = naechster Schritt
    if L.idx ~= idx then
      local first = L.idx == nil
      Reset(idx)
      L.start = { pm, px, py }
      if not first then Fire("erledigt") end
    end
    if not L.start then L.start = { pm, px, py } end
    -- Ziel fast fertig (7/8 usw.)
    for _, a in ipairs(s.acts or {}) do
      if a.k == "O" and a.qid and ns.logProgress then
        local lp = ns.logProgress[a.qid]
        for oi, o in ipairs(lp and lp.objs or {}) do
          if not o.done then
            local c, m = tostring(o.text or ""):match("(%d+)%s*/%s*(%d+)")
            c, m = tonumber(c), tonumber(m)
            if c and m and m > 1 and c < m and c / m >= NEAR_RATIO then
              local key = a.qid .. ":" .. oi
              if not L.fired[key] then L.fired[key] = true; Fire("fast_fertig", { qid = a.qid, text = o.text }) end
            end
          end
        end
      end
    end
    if opt.steps[opt.idx or 1] ~= s then return end   -- ein Ausloeser hat umgeordnet: naechste Pruefung nimmt den neuen Schritt
    -- 1.1: regelmaessig neu pruefen (auch wenn du genau auf dem Weg bist)
    local nowP = GetTime()
    if not L.periodAt then L.periodAt = nowP end
    if nowP - L.periodAt >= LIVE_PERIOD_S then
      L.periodAt = nowP
      Fire("zeit")
      if opt.steps[opt.idx or 1] ~= s then return end
    end
    if not L.start then L.start = { pm, px, py } end
    -- Abweichung vom geplanten Weg: Spieler ist weit neben der Linie Start -> Ziel oder weiter weg als am Start (zwei Pruefungen hintereinander)
    if s.map and s.x and s.y and not s.travel then
      local d = Dist(pm, px, py, s.map, s.x, s.y)
      local off = OffLine(L.start[1], L.start[2], L.start[3], s.map, s.x, s.y, pm, px, py)
      local d0 = Dist(L.start[1], L.start[2], L.start[3], s.map, s.x, s.y)
      local away = d and d0 and d - d0 > DEV_YARDS
      local noCloser = d and L.lastD and d >= L.lastD - 5
      if d and ((off and off > DEV_YARDS and noCloser) or away) then
        L.devHits = L.devHits + 1
        if L.devHits >= 2 then L.devHits = 0; Fire("abweichung", { yards = off or (d - d0) }) end
      else
        L.devHits = 0
      end
      L.lastD = d
    end
    Chance()
  end

  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_DEAD")
  f:RegisterEvent("PLAYER_UNGHOST")
  f:RegisterEvent("PLAYER_ALIVE")
  f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  f:SetScript("OnEvent", function(_, ev)
    if ev == "PLAYER_DEAD" then L.dead = true
    elseif ev == "PLAYER_UNGHOST" or ev == "PLAYER_ALIVE" then
      if L.dead and not (UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player")) then L.dead = false; L.pending = { "tod", GetTime() + 3 } end
    elseif ev == "ZONE_CHANGED_NEW_AREA" then
      L.devHits = 0; L.start = nil; L.lastD = nil
      L.pending = { "zone", GetTime() + 2 }
    end
  end)
  f:SetScript("OnUpdate", function(_, el)
    L.acc = L.acc + el
    if L.acc < 1 then return end
    L.acc = 0
    local now = GetTime()
    if L.pending and now >= L.pending[2] and not (UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player")) then
      local r = L.pending[1]; L.pending = nil
      if Enabled() and not (ns.navi and not ns.navi.hidden) then pcall(Fire, r) end
    end
    L.tick = (L.tick or 0) + 1
    if L.tick >= LIVE_EVERY then
      L.tick = 0
      local ok, err = pcall(Check)
      if not ok then Log("LIVE", "Pruefung Fehler: " .. tostring(err)) end
    end
  end)

  -- Mini Fenster: Gelegenheit als niedrigster Hinweis (nach Taschen, Lehrer, Questlog ...). Klick nimmt sie, X sperrt sie 60 s.
  local pl = CreateFrame("Frame")
  pl:RegisterEvent("PLAYER_LOGIN")
  pl:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if ns.HintList then
      local origList = ns.HintList
      ns.HintList = function(...)
        local out = origList(...)
        local c = L.chance
        if out and c and GetTime() - c.t < LIVE_EVERY * 3 and Enabled() and GetTime() >= L.lockUntil then
          local secs = tonumber(c.sec)
          local txt = tostring(c.text)
          if not txt:find("^Gelegenheit") and not txt:find("^Chance") then
            txt = (ns.EN and "Opportunity: " or "Gelegenheit: ") .. txt
          end
          if secs and not txt:find("%d+ s") then txt = txt .. (", %d s " .. (ns.EN and "detour" or "Umweg")):format(secs) end
          table.insert(out, { kind = "live", text = txt,
            tip = ns.EN and "Click: take it. X: not now (60 s quiet)." or "Klick: mitnehmen. X: jetzt nicht (60 s Ruhe).",
            onClick = function()
              if ns.LiveChanceTake then pcall(ns.LiveChanceTake) end
              L.lockUntil = GetTime() + LOCK_SEC; L.chance = nil
              if ns.Draw then ns.Draw() end
              if ns.RefreshHud then ns.RefreshHud() end
            end })
        end
        -- 1.1 (K Stufe B 12): Reserve Quest liegt nicht mehr am Weg
        if out and ns.ReserveDropHint and Enabled() then
          local okR, txt, rq = pcall(ns.ReserveDropHint)
          if okR and txt and not (L.reserveQuiet and L.reserveQuiet[rq]) then
            table.insert(out, { kind = "reserve", text = txt, rq = rq,
              tip = ns.EN and "Click: hide this hint for this quest." or "Klick: Hinweis für diese Quest ausblenden.",
              onClick = function()
                L.reserveQuiet = L.reserveQuiet or {}
                L.reserveQuiet[rq] = true
                if ns.RefreshHud then ns.RefreshHud() end
              end })
          end
        end
        return out
      end
    end
    if ns.HintDismiss then
      local origDis = ns.HintDismiss
      ns.HintDismiss = function(h, ...)
        if h and h.kind == "live" then L.lockUntil = GetTime() + LOCK_SEC; L.chance = nil; return end
        -- 1.2l (P75): x am Reserve Hinweis = fuer diese Quest still (wie Klick), keine Meldung "15 Min ausgeblendet"
        if h and h.kind == "reserve" then
          if h.rq then L.reserveQuiet = L.reserveQuiet or {}; L.reserveQuiet[h.rq] = true end
          if ns.RefreshHud then ns.RefreshHud() end
          return
        end
        return origDis(h, ...)
      end
    end
  end)
end
