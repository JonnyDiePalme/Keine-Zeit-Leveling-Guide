local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Route auf der Minimap, und Ein/Aus Knoepfe auf der Weltkarte.

local overlay
local lines, pins = {}, {}

-- Minimap Durchmesser in Yards je Zoomstufe (draussen und drinnen)
local OUTDOOR = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 }
local INDOOR = { [0] = 300, 240, 180, 120, 80, 50 }

local sizeCache = {}
local function MapSize(mapID)
  local c = sizeCache[mapID]
  if c then return c[1], c[2] end
  local w = ns.WorldDist({ mapID, 0, 0 }, { mapID, 1, 0 })
  local h = ns.WorldDist({ mapID, 0, 0 }, { mapID, 0, 1 })
  if not (w and h and w > 0) then return end
  sizeCache[mapID] = { w, h }
  return w, h
end

local function HideAll()
  for _, l in ipairs(lines) do l:Hide() end
  for _, p in ipairs(pins) do p:Hide() end
end

local function GetLine(i)
  local l = lines[i]
  if not l then
    l = overlay:CreateLine(nil, "OVERLAY", nil, 5)
    l:SetThickness(2)
    lines[i] = l
  end
  return l
end

local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"
-- 17.7 (Wunsch Sascha): Symbole auf der Minimap etwas groesser
local PS = 1.4
local function GetPin(i)
  local p = pins[i]
  if not p then
    p = overlay:CreateTexture(nil, "OVERLAY", nil, 6)
    pins[i] = p
  end
  p:SetTexture("Interface\\Buttons\\WHITE8X8")
  p:SetTexCoord(0, 1, 0, 1)
  p:SetDrawLayer("OVERLAY", 6)
  return p
end

-- nur neu zeichnen, wenn sich etwas geaendert hat (Position, Drehung, Zoom, Ziel)
local last = {}
local forceAt = 0
-- naechste Schritte der optimierten Route auf dieser Karte
local OKIND = { A = "quest", T = "turnin", O = "obj", G = "grind" }
local OPIN = { A = "quest", T = "turnin", O = "obj", G = "grind", F = "fp", E = "explore", R = "travel",
  V = "vendor", B = "hearth", H = "hearth", L = "inn", K = "book", M = "via" }
local function OptPoints(mapID)
  local opt = ns.db.opt
  local out = {}
  local i0 = opt.idx or 1
  -- nur der aktuelle Schritt (die Karte zeigt die naechsten 10)
  for i = i0, math.min(#opt.steps, i0) do
    local st = opt.steps[i]
    local x, y = st.x, st.y
    if st.map ~= mapID and ns.ToMap then
      local x0, y0 = st.x, st.y
      x, y = ns.ToMap(st.map, x0, y0, mapID)
      -- 1.2i (P71): Ziel knapp ausserhalb der Karte (Zeppelin Turm vor der Stadt): trotzdem zeigen
      if not x and ns.ToMapFree then x, y = ns.ToMapFree(st.map, x0, y0, mapID) end
    end
    if x then
      local hasA, hasT = false, false
      for _, a in ipairs(st.acts or {}) do if a.k == "A" then hasA = true elseif a.k == "T" then hasT = true end end
      -- 1.3zg (Pr 08:15 Lua Fehler: Dungeon Eingang Schritt mit leerer acts Liste)
      local a1 = st.acts and st.acts[1]
      local k = a1 and a1.k or (st.dungeon and "O") or nil
      local pin = (hasA and hasT and "both") or (hasT and "turnin") or (hasA and "quest") or (k and OPIN[k])
      if k == "V" and a1 and a1.books then pin = "book" end
      table.insert(out, { x, y, kind = OKIND[k] or "via", target = (i == i0), giver = hasA or hasT, both = hasA and hasT, pin = pin })
    end
  end
  return out
end

-- 20.3h: Ersatzweg fuer die Minimap Linie, wenn der Pfeil keinen Weg liefert (siehe Update)
local pathFb = { key = nil, t = -99, pts = nil }
local function FallbackPath(K, mapID, px, py, p1, slow)
  if not (K and K.PathPts and K.HasZone) then return nil end
  local now = GetTime()
  local key = ("%d:%.3f:%.3f"):format(mapID, p1[1], p1[2])
  if pathFb.key == key and now - pathFb.t < (slow and 4 or 2) then return pathFb.pts end
  pathFb.key, pathFb.t, pathFb.pts = key, now, nil
  local ok, got = pcall(K.PathPts, mapID, px, py, p1[1], p1[2])
  if ok and type(got) == "table" and #got > 0 then
    local out = {}
    for _, q in ipairs(got) do
      if q[1] and q[2] then out[#out + 1] = { q[1], q[2] } end
    end
    if #out > 0 then pathFb.pts = out end
  end
  return pathFb.pts
end

local function Update()
  if not overlay then return end
  if ns.db and ns.db.paused then HideAll(); last.map = nil; return end
  local db = ns.db
  if not (db and db.show and db.miniShow) then HideAll(); last.map = nil; return end
  -- 20.3z3 (Ad AN Na P7, fps 6 bis 7 beim Navi Flug 16:59:48): im Taxi bewegt sich die Position dauernd, jede 0,1 s wurde alles neu
  -- aufgebaut. Im Taxi hoechstens alle 0,5 s.
  if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then
    local tn = GetTime()
    if tn - (last.taxiAt or 0) < 0.5 then return end
    last.taxiAt = tn
  end
  local mapID = ns.PlayerMap()
  local useOpt = db.optMode and db.opt and db.opt.steps
  -- 20.3y (K 17:20 Punkt 2): ohne berechnete Route keine Zonen Route auf der Minimap (wie der Pfeil, db.zonenRouteOhneOpt = alt)
  local noOpt = db.optMode and not db.zonenRouteOhneOpt and not (db.opt and db.opt.steps and #db.opt.steps > 0)
  local route = mapID and not noOpt and (useOpt and db.opt or ns.GetRoute(mapID)) or nil
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  -- 19.32 (Navi Chat): fuehrt das Navi, zeigt die Minimap den Navi Weg (auch in Zonen ohne Route)
  local nv = ns.navi
  local naviOn = nv and not nv.hidden and nv.legs and ns.NaviMiniPts and true or false
  if not ((route or naviOn) and pos) then HideAll(); last.map = nil; return end
  local w, h = MapSize(mapID)
  if not w then return end
  local px, py = pos:GetXY()
  local zoomNow = Minimap:GetZoom() or 0
  local rot = GetCVar and GetCVar("rotateMinimap") == "1"
  local faceNow = 0
  if rot then
    -- im Kampf ist die Blickrichtung manchmal geheim: dann die alten Linien lassen statt auf Norden zu springen
    faceNow = GetPlayerFacing and ns.Plain(GetPlayerFacing())
    if faceNow == nil then return end
  end
  local startNow = useOpt and (db.opt.idx or 1) or (db.progress[mapID] or 1)
  local now = GetTime()
  local naviKey = naviOn and (tostring(nv) .. ":" .. tostring(nv.cur)) or nil
  if last.map == mapID and last.route == route and last.start == startNow and last.navi == naviKey and last.zoom == zoomNow
    and math.abs(last.px - px) < 0.0002 and math.abs(last.py - py) < 0.0002 and math.abs(last.face - faceNow) < 0.02
    and now < forceAt then
    return
  end
  last.map, last.route, last.start, last.zoom, last.px, last.py, last.face = mapID, route, startNow, zoomNow, px, py, faceNow
  last.navi = naviKey
  forceAt = now + ((db.slowPC and 2) or 1) -- spaetestens jede Sekunde trotzdem (z.B. neues Quest Ziel), schwacher PC alle 2 s
  HideAll()

  local zoom = zoomNow
  local diameter = (IsIndoors and ns.Api.U(IsIndoors) and INDOOR[zoom] or OUTDOOR[zoom]) or 466
  local half = Minimap:GetWidth() / 2
  local scale = half / (diameter / 2) -- Pixel pro Yard
  local rotate = rot
  local facing = faceNow
  local square = GetMinimapShape and GetMinimapShape() == "SQUARE"

  -- Punkt in Minimap Pixel umrechnen, nil wenn ausserhalb
  local function ToMini(x, y)
    local east = (x - px) * w * scale
    local south = (y - py) * h * scale
    if rotate then
      local c, s = math.cos(facing), math.sin(facing)
      east, south = east * c - south * s, east * s + south * c
    end
    local inside
    if square then inside = math.abs(east) < half - 2 and math.abs(south) < half - 2
    else inside = (east * east + south * south) < (half - 3) ^ 2 end
    return east, -south, inside
  end

  -- Ziel vom Pfeil zuerst, dann die naechsten Punkte der Route
  local pts = {}
  local ph = (not useOpt) and (not naviOn) and route and ns.PendingHub and ns.PendingHub(mapID, px, py)
  local function Flags(t)
    t = t or {}
    return type(t.turnin) == "table", type(t.quest) == "table"
  end
  if ph then
    local both = false
    for _, p in ipairs(route) do
      if math.abs(p[1] - ph[1]) < 0.004 and math.abs(p[2] - ph[2]) < 0.004 then
        local a, b = Flags(p.tags); both = a and b
      end
    end
    table.insert(pts, { ph[1], ph[2], kind = ph.turnin and "turnin" or "quest", target = true, giver = true, both = both })
  end
  local start = db.progress[mapID] or 1
  if useOpt then pts = OptPoints(mapID); route = {} end
  if naviOn then
    local okN, np0 = pcall(ns.NaviMiniPts, mapID, db.slowPC and 2 or 4)
    pts = (okN and np0) or {}
    route = {}
  end
  route = route or {}
  for i = start, math.min(#route, start + 7) do
    local p = route[i]
    local tu, qu = Flags(p.tags)
    table.insert(pts, { p[1], p[2], kind = p.kind, target = (i == start and not ph), giver = tu or qu, both = tu and qu })
  end

  local gps = false
  -- 19.32 (Saschas Runde 1 Punkt 6, AzerothGPS raus): die Linie geht den gleichen Weg wie der Pfeil (Gelaende Karte,
  -- K.FollowPts, nichts neu gerechnet), erst danach zu den Punkten der Route. Schwacher PC: weniger Punkte
  local K = ns.Karte
  local fp = K and K.FollowPts and K.FollowPts(mapID, db.slowPC and 12 or 40)
  -- 20.3h (Na, K Hinweis C6, Test 20.3g): folgt der Pfeil gerade keinem Weg (Stadt: nach 20 s ohne Fortschritt zeigt er
  -- 30 s gerade aufs Ziel, oder die Zusatz Route ist neu), gab es keine Wegpunkte und die Linie ging gerade. Dann den Weg
  -- selbst holen (K.PathPts), hoechstens alle 2 s (schwacher PC 4 s)
  if not (fp and #fp > 0) and pts[1] and not naviOn and not pts[1].path then
    fp = FallbackPath(K, mapID, px, py, pts[1], db.slowPC)
  end
  if fp and #fp > 0 and pts[1] then
    local kind = pts[1].kind
    local way = {}
    for _, q in ipairs(fp) do way[#way + 1] = { q[1], q[2], kind = kind, path = true } end
    for _, p in ipairs(pts) do way[#way + 1] = p end
    pts = way
  end
  local lastX, lastY, lastIn = 0, 0, true -- Linie startet beim Spieler
  local nl, np = 0, 0
  for _, p in ipairs(pts) do
    local x, y, inside = ToMini(p[1], p[2])
    if (inside or lastIn) and not gps then
      -- Linie bis zum Rand kuerzen, falls ein Ende draussen ist
      local ax, ay, bx, by = lastX, lastY, x, y
      local r = half - 3
      local function Clip(ix, iy, ox, oy)
        for t = 1, 0, -0.05 do
          local cx, cy = ix + (ox - ix) * t, iy + (oy - iy) * t
          local ok = square and (math.abs(cx) < r and math.abs(cy) < r) or (not square and cx * cx + cy * cy < r * r)
          if ok then return cx, cy end
        end
        return ix, iy
      end
      if not inside then bx, by = Clip(ax, ay, bx, by) end
      if not lastIn then ax, ay = Clip(bx, by, ax, ay) end
      nl = nl + 1
      local l = GetLine(nl)
      local c = p.col or (ns.KINDCOL and ns.KINDCOL[p.kind]) or { 1, 0.75, 0.1 }
      l:SetColorTexture(c[1], c[2], c[3], 0.9)
      l:ClearAllPoints()
      l:SetStartPoint("CENTER", overlay, ax, ay)
      l:SetEndPoint("CENTER", overlay, bx, by)
      l:Show()
    end
    if inside and not p.path then
      local c = p.target and { 0.1, 1, 0.3 } or p.col or ((ns.KINDCOL and ns.KINDCOL[p.kind]) or { 1, 0.75, 0.1 })
      local T = ns.T
      -- Symbol aus Figma (nur wenn es das gibt und Symbole an sind), sonst die Kreise
      local drawn = false
      if p.pin and T and T.PinTex then
        local pin = GetPin(np + 1)
        if T.PinTex(pin, p.pin) then
          np = np + 1
          -- Questgeber und Ziel etwas groesser
          local sz = math.floor(((p.giver or p.both) and 14 or 11) * PS + 0.5)
          if p.target then sz = sz + 4 end
          pin:SetDrawLayer("OVERLAY", p.target and 7 or 6)
          pin:SetSize(sz, sz)
          pin:ClearAllPoints()
          pin:SetPoint("CENTER", overlay, "CENTER", x, y)
          pin:Show()
          drawn = true
        else
          pin:Hide()
        end
      end
      if drawn then
        -- schon gezeichnet
      elseif p.both then
        -- aussen orange (annehmen), innen gruen (abgeben)
        np = np + 1
        local outer = GetPin(np)
        outer:SetTexture(CIRCLE)
        outer:SetDrawLayer("OVERLAY", 5)
        outer:SetVertexColor(1, 0.5, 0, 1)
        outer:SetSize(math.floor(13 * PS + 0.5), math.floor(13 * PS + 0.5))
        outer:ClearAllPoints()
        outer:SetPoint("CENTER", overlay, "CENTER", x, y)
        outer:Show()
        np = np + 1
        local inner = GetPin(np)
        inner:SetTexture(CIRCLE)
        inner:SetVertexColor(0.3, 1, 0.6, 1)
        inner:SetSize(math.floor(7 * PS + 0.5), math.floor(7 * PS + 0.5))
        inner:ClearAllPoints()
        inner:SetPoint("CENTER", overlay, "CENTER", x, y)
        inner:Show()
      else
        np = np + 1
        local pin = GetPin(np)
        if p.giver then pin:SetTexture(CIRCLE) end
        pin:SetVertexColor(c[1], c[2], c[3], 1)
        local sz = math.floor((p.giver and (p.target and 10 or 8) or (p.target and 7 or 5)) * PS + 0.5)
        pin:SetSize(sz, sz)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", overlay, "CENTER", x, y)
        pin:Show()
      end
    end
    lastX, lastY, lastIn = x, y, inside
  end

  -- 20.3 (AUF 01:08, Vorschlag Ad): Farm Runde als geschlossene Linie (letzter Punkt zurueck zum ersten).
  -- Nur wenn die Route eine Runde ist (db.opt.loop) und das Navi nicht fuehrt. Punkte aller Schritte dieser Karte.
  local opt = db.opt
  -- 20.3l (Release Punkt 23): auch Berufe Routen (db.opt.prof) zeigen die Runde, nicht nur der Endlos Modus (opt.loop). Die Schritte
  -- wiederholen die Runde mehrfach, der Ring endet vor der ersten Wiederholung des ersten Punkts.
  -- 20.3y (K 17:22 P5, S 17:04/17:06): der Kreislauf bleibt auch sichtbar, solange das Navi den Weg dorthin (Anweg) fuehrt
  -- v11f (K P37): Runde in einem grossen Gegner Gebiet (Feld rund am Ziel, Arrow.lua NaviRundPts) wie die Farm Runde zeichnen
  local rundPts = useOpt and ns.NaviRundPts and ns.NaviRundPts(mapID)
  if rundPts and #rundPts >= 4 then
    local LC = { 0.35, 0.95, 0.5 }
    local ring = {}
    for i = 1, #rundPts - 1 do
      local ex, ey, ins = ToMini(rundPts[i][1], rundPts[i][2])
      ring[#ring + 1] = { ex, ey, ins }
    end
    rundPts = ring
  else
    rundPts = nil
  end
  if rundPts or (useOpt and (opt.loop or opt.prof) and type(opt.steps) == "table" and #opt.steps >= 3) then
    local LC = { 0.35, 0.95, 0.5 }
    local ring = rundPts or {}
    for i = 1, (rundPts and 0) or math.min(#opt.steps, db.slowPC and 12 or 40) do
      local st = opt.steps[i]
      local s1 = opt.steps[1]
      if i > 1 and s1 and st.map == s1.map and st.x and s1.x and math.abs(st.x - s1.x) < 0.0005 and math.abs(st.y - s1.y) < 0.0005 then break end
      local rx, ry = st.x, st.y
      if rx and st.map ~= mapID then
        rx, ry = nil, nil
        if ns.ToMap and st.map then rx, ry = ns.ToMap(st.map, st.x, st.y, mapID) end
      end
      if rx and ry then
        local ex, ey, ins = ToMini(rx, ry)
        local pr = ring[#ring]
        if not (pr and math.abs(pr[1] - ex) < 0.5 and math.abs(pr[2] - ey) < 0.5) then ring[#ring + 1] = { ex, ey, ins } end
      end
    end
    if #ring >= 3 then
      local r = half - 3
      local function Okp(cx, cy)
        if square then return math.abs(cx) < r and math.abs(cy) < r end
        return cx * cx + cy * cy < r * r
      end
      -- Stueck einer Strecke, das in der Minimap liegt (auch wenn beide Enden draussen sind)
      local function Seg(a, b)
        local t1, t2
        for k = 0, 24 do
          local t = k / 24
          if Okp(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t) then
            if not t1 then t1 = t end
            t2 = t
          end
        end
        if not t1 then return end
        local ax, ay = a[1] + (b[1] - a[1]) * t1, a[2] + (b[2] - a[2]) * t1
        local bx, by = a[1] + (b[1] - a[1]) * t2, a[2] + (b[2] - a[2]) * t2
        nl = nl + 1
        local l = GetLine(nl)
        l:SetColorTexture(LC[1], LC[2], LC[3], 0.75)
        l:ClearAllPoints()
        l:SetStartPoint("CENTER", overlay, ax, ay)
        l:SetEndPoint("CENTER", overlay, bx, by)
        l:Show()
      end
      for i = 1, #ring do
        Seg(ring[i], ring[i % #ring + 1])
      end
      -- kleine Punkte an den Stellen der Runde (das aktuelle Ziel ist schon gezeichnet)
      for i = 1, #ring do
        local q = ring[i]
        if q[3] then
          np = np + 1
          local pin = GetPin(np)
          pin:SetVertexColor(LC[1], LC[2], LC[3], 0.9)
          pin:SetSize(4, 4)
          pin:ClearAllPoints()
          pin:SetPoint("CENTER", overlay, "CENTER", q[1], q[2])
          pin:Show()
        end
      end
    end
  end
end

------------------------------------------------------------
-- Knoepfe auf der Weltkarte
------------------------------------------------------------
local function Skin(b)
  if ns.T then return end -- Look kommt schon von Theme.lua
  if ElvUI then
    local ok, E = pcall(unpack, ElvUI)
    local S = ok and E and E:GetModule("Skins", true)
    if S and S.HandleButton then pcall(S.HandleButton, S, b) end
  end
end

-- Zwischen OpenMap und der normalen Karte umschalten (braucht ein Neuladen)
local function AddonLoaded(name)
  if C_AddOns and C_AddOns.IsAddOnLoaded then return C_AddOns.IsAddOnLoaded(name) end
  return IsAddOnLoaded and IsAddOnLoaded(name)
end
local function SetAddon(name, on)
  local f = on and ((C_AddOns and C_AddOns.EnableAddOn) or EnableAddOn) or ((C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn)
  if f then pcall(f, name, UnitName("player")) end
end
local function AddonExists(name)
  local info = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  if not info then return false end
  local ok, n = pcall(info, name)
  return ok and n ~= nil
end
function ns.OpenMapActive() return AddonLoaded("OpenMap") end
function ns.SwitchMap()
  if not AddonExists("OpenMap") then
    ns.Print(TR"OpenMap ist nicht installiert.")
    return
  end
  local db = ns.db
  if AddonLoaded("OpenMap") then
    SetAddon("OpenMap", false)
    if db.leatrixMapsWas then SetAddon("Leatrix_Maps", true); db.leatrixMapsWas = nil end
    ns.Print(TR"Beim Neuladen: normale Karte" .. (AddonExists("Leatrix_Maps") and TR" (Leatrix Maps wieder an)" or ""))
  else
    SetAddon("OpenMap", true)
    if AddonLoaded("Leatrix_Maps") then SetAddon("Leatrix_Maps", false); db.leatrixMapsWas = true end
    ns.Print(TR"Beim Neuladen: OpenMap" .. (db.leatrixMapsWas and TR" (Leatrix Maps aus, die zwei vertragen sich nicht)" or ""))
  end
  ns.Confirm(TR"Keine Zeit Leveling Guide: Karte umschalten. Jetzt neu laden?", TR"Neu laden", function() ReloadUI() end, TR"Später")
end

-- Knoepfe an der Weltkarte: schlanke Leiste mit Symbolen am rechten Kartenrand.
-- Classic UI: Symbole wie Aktionsknoepfe mit Leuchten, ElvUI: flache Kaestchen mit Rand in der Wertfarbe.
-- Oben das Logo klappt die Leiste auf und zu.
local mapBtns = {}
local mapBar
local MAPBTN = {
  { key = "route", icon = "Interface\\Icons\\INV_Misc_Map_01", name = TR"Route auf der Karte",
    tip = TR"Die nächsten Schritte als Linie mit Nummern.", on = function() return ns.db.mapShow ~= false end,
    click = function() ns.db.mapShow = (ns.db.mapShow == false); if ns.Draw then ns.Draw() end end },
  { key = "mini", icon = "Interface\\Icons\\INV_Misc_Spyglass_02", name = TR"Route auf der Minimap",
    tip = TR"Die nächsten Schritte als Linie auf der Minimap.", on = function() return ns.db.miniShow end,
    click = function() ns.db.miniShow = not ns.db.miniShow; Update() end },
  { key = "books", icon = "Interface\\Icons\\INV_Misc_Book_09", name = TR"Bücher zeigen",
    tip = TR"Offene Bücher als Symbol auf der Karte. Maus drauf zeigt mehr, Klick setzt den Pfeil.",
    on = function() return ns.db.mapBooks ~= false end, lock = "books",
    click = function() ns.db.mapBooks = (ns.db.mapBooks == false); if ns.DrawBookPins then ns.DrawBookPins() end end },
  -- 1.3x (P107, S 03:30): Knopf "OpenMap Karte" an der grossen Karte raus. Umschalten geht weiter in den Einstellungen
  -- ("OpenMap als Karte nutzen?", nur wenn OpenMap installiert ist)
}

local function MarkOn(b, on)
  local T = ns.T
  if T and T.IsElv() then
    local r, g, bb = T.Acc()
    if b.SetBackdropBorderColor then
      if on then b:SetBackdropBorderColor(r, g, bb, 1) else b:SetBackdropBorderColor(0, 0, 0, 1) end
    end
  else
    b.glow:SetShown(on and true or false)
  end
  b.icon:SetDesaturated(not on)
  b.icon:SetAlpha(on and 1 or 0.6)
end

local function MapButtonText()
  if not mapBar then return end
  local db = ns.db
  local open = db.mapBarOpen ~= false
  -- 17.7: sichtbarer Knopf zum Auf und Zuklappen (Plus oder Minus) unter dem Logo
  if mapBar.tog then
    mapBar.tog.tex:SetTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
  end
  local y = -52
  for _, d in ipairs(MAPBTN) do
    local b = mapBtns[d.key]
    local show = open and (not d.only or d.only()) and (not d.lock or not ns.Unlocked or ns.Unlocked(d.lock))
      and (not d.expert or not ns.Expert or ns.Expert() or (d.on and d.on()))
    b:SetShown(show and true or false)
    if show then
      b:ClearAllPoints(); b:SetPoint("TOP", mapBar, "TOP", 0, y)
      y = y - 32
      MarkOn(b, d.on and d.on())
    end
  end
  mapBar:SetHeight(-y + 2)
  -- ueber der OpenMap Karte bleiben
  local top = OpenMapAPI and OpenMapAPI.ArtTopLevel and OpenMapAPI.ArtTopLevel()
  if top and mapBar:GetFrameLevel() <= top then mapBar:SetFrameLevel(top + 30) end
end
ns.MapButtonText = MapButtonText

local function MakeMapBtn(d)
  if not mapBar or mapBtns[d.key] then return end
  local T = ns.T
  local b = CreateFrame("Button", nil, mapBar, BackdropTemplateMixin and "BackdropTemplate" or nil)
  b:SetSize(28, 28)
  if T then T.Skin(b, "inset") end
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("TOPLEFT", 3, -3); b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
  -- Symbole aus Figma, je UI eigene; sonst das WoW Icon
  local IDX = { route = 0, mini = 1, books = 2, gold = 3, omap = 4, paint = 5 }
  if T and T.MapIcon and IDX[d.key] then T.MapIcon(b.icon, IDX[d.key])
  else b.icon:SetTexture(d.icon); b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
  b.glow = b:CreateTexture(nil, "OVERLAY")
  b.glow:SetTexture("Interface\\Buttons\\CheckButtonHilight")
  b.glow:SetBlendMode("ADD")
  b.glow:SetAllPoints(b.icon)
  b.glow:Hide()
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(b.icon); hl:SetColorTexture(1, 1, 1, 0.2)
  b:SetScript("OnClick", function() d.click(); MapButtonText() end)
  b:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(d.name)
    local on = d.on and d.on()
    GameTooltip:AddLine(on and (ns.EN and "on" or "an") or (ns.EN and "off" or "aus"), on and 0.25 or 0.6, on and 1 or 0.6, on and 0.25 or 0.6)
    GameTooltip:AddLine(d.tip, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mapBtns[d.key] = b
end

-- weitere Knoepfe von aussen (andere Addons): { key, icon, name, tip, on, click, idx }
function ns.AddMapButton(d)
  if type(d) ~= "table" or not d.key then return end
  for i, e in ipairs(MAPBTN) do if e.key == d.key then table.remove(MAPBTN, i); break end end
  table.insert(MAPBTN, d)
  if mapBar then MakeMapBtn(d); MapButtonText() end
end

local function BuildMapButtons()
  if not WorldMapFrame or mapBar then return end
  local T = ns.T
  local anchor = WorldMapFrame.ScrollContainer or WorldMapFrame
  mapBar = CreateFrame("Frame", nil, WorldMapFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  mapBar:SetWidth(36)
  mapBar:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -6, -6)
  mapBar:SetFrameLevel((anchor:GetFrameLevel() or 1) + 200)
  if T then T.Skin(mapBar, T.IsElv() and "window" or "tooltip", 0.75) end
  -- Logo: Leiste auf und zu
  local head = CreateFrame("Button", nil, mapBar)
  head:SetSize(28, 28)
  head:SetPoint("TOP", 0, -4)
  if T and T.MapIcon then
    local lt = head:CreateTexture(nil, "ARTWORK"); lt:SetAllPoints(); T.MapIcon(lt, 6)
  elseif T then local lg = T.Logo(head, 26); lg:SetPoint("CENTER") end
  local hh = head:CreateTexture(nil, "HIGHLIGHT"); hh:SetAllPoints(); hh:SetColorTexture(1, 1, 1, 0.15)
  head:SetScript("OnClick", function() ns.db.mapBarOpen = (ns.db.mapBarOpen == false); MapButtonText() end)
  head:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(TR"Keine Zeit Leveling Guide")
    GameTooltip:AddLine(ns.db.mapBarOpen ~= false and TR"Klick: Leiste zuklappen" or TR"Klick: Leiste aufklappen", 1, 1, 1)
    GameTooltip:Show()
  end)
  head:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Plus oder Minus unter dem Logo (Wunsch Sascha): zeigt, dass sich die Leiste aufklappen laesst
  local tog = CreateFrame("Button", nil, mapBar)
  tog:SetSize(28, 16)
  tog:SetPoint("TOP", head, "BOTTOM", 0, -1)
  tog.tex = tog:CreateTexture(nil, "ARTWORK")
  tog.tex:SetSize(14, 14)
  tog.tex:SetPoint("CENTER")
  local th = tog:CreateTexture(nil, "HIGHLIGHT"); th:SetAllPoints(); th:SetColorTexture(1, 1, 1, 0.15)
  tog:SetScript("OnClick", function() ns.db.mapBarOpen = (ns.db.mapBarOpen == false); MapButtonText() end)
  tog:SetScript("OnEnter", head:GetScript("OnEnter"))
  tog:SetScript("OnLeave", function() GameTooltip:Hide() end)
  mapBar.tog = tog
  for _, d in ipairs(MAPBTN) do MakeMapBtn(d) end
  MapButtonText()
  WorldMapFrame:HookScript("OnShow", MapButtonText)
  -- beim ersten Oeffnen der Karte jeden Knopf kurz erklaeren
  WorldMapFrame:HookScript("OnShow", function()
    if not ns.CoachLater then return end
    ns.CoachLater("map", function()
      local steps = { { target = head, side = "LEFT", title = TR"Keine Zeit Leveling Guide Leiste",
        text = TR"Rechts an der Karte sind die Knöpfe von Keine Zeit Leveling Guide. Das Logo oder Plus und Minus klappt die Leiste auf und zu." } }
      for _, d in ipairs(MAPBTN) do
        local bt = mapBtns[d.key]
        if bt and bt:IsShown() then table.insert(steps, { target = bt, side = "LEFT", title = d.name, text = d.tip .. TR"\nLeuchtend heisst an." }) end
      end
      table.insert(steps, { target = mapBar, side = "LEFT", title = TR"Auf der Karte",
        text = TR"Die Linie zeigt die nächsten Schritte mit Nummern. Orange annehmen, rosa Questziel, grün abgeben, rot grinden, blau Reise.\nShift+Klick setzt einen eigenen Wegpunkt." })
      return steps
    end, 0.6)
  end)
end

function ns.MiniRouteRefresh() Update() end
function ns.InitMiniRoute()
  local db = ns.db
  if db.miniShow == nil then db.miniShow = true end
  if db.mapShow == nil then db.mapShow = true end
  overlay = CreateFrame("Frame", nil, Minimap)
  overlay:SetAllPoints(Minimap)
  overlay:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 5)
  ns.Ticker(0.1, Update)
  BuildMapButtons()
end
