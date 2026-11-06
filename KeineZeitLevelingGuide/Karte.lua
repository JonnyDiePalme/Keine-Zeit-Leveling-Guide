local ADDON, ns = ...
local TR = ns.TR or function(s) return s end

------------------------------------------------------------
-- 19.0 Gelaende aus dem Werkzeug Karte (Sascha). Es liest die Spieldaten und baut zwei Daten Addons:
-- KeineZeitLevelingGuide_Karte_Forever (Forever) und KeineZeitLevelingGuide_Karte_Era (Era), pro Zone:
--  Felder im 80 x 80 Raster: Berg (b), Weg (r), Wasser (w), tiefes Wasser (d), Klippe (c, mit Richtung nach unten)
--  ein Wegnetz: Knoten (p, mit Prio), Kanten k1 (Grundnetz) und k2 (dicht) mit Zwischenpunkten,
--  Wegzeiten Tabellen zwischen den Prio 1 Knoten (t schnell, tsH / tsA sicher), Mobs neben den Kanten (g1 / g2),
--  Reitwege (rH / rA) und die Uebergaenge in die Nachbarzonen (xpass).
-- Ebenen: gelaufene und geteilte Wege gehen vor (ein Feld, auf dem du gelaufen bist, ist nie Berg), darunter die Daten.
-- Das Netz steuert die Planung (Tabelle t), den Pfeil (kuerzester Weg auf k1 oder k2 mit Zwischenpunkten) und den
-- Weg ueber Zonen (Uebergaenge, feste Verbindungen PAINT_XLINK aus FesteDaten.lua, selbst gelaufene Uebergaenge).
-- Schwacher PC: nur Prio 1 Knoten, k1 und die Tabellen.
-- Zugriff: FWW_AutoKarte(uiMap) baut die Tabelle einer Zone beim ersten Aufruf, FWW_AutoKarteFrei(uiMap) gibt sie frei.
-- Behalten wird pro Zone nur, was klein ist (Felder, Tabelle t, Knoten der Tabelle); das volle Netz nur fuer wenige Zonen.
------------------------------------------------------------
local K = {}
ns.Karte = K
local EMPTY = {}
local CELL, N = 0.0125, 80
local floor, sqrt, huge = math.floor, math.sqrt, math.huge
local byte = string.byte

local SAFE_MAX = 1.2     -- Pfeil: sicherer Weg nur, wenn er hoechstens so viel laenger ist als der schnelle (Sascha)
local MOB_PEN = 60       -- Umweg in Yards pro zaehlendem Mob neben einer Kante (wie das Werkzeug), Elite dreifach
local RIDE_MUL = 0.85    -- Reitwege mit Reittier: so viel billiger
local K3_STEEP = 2       -- 19.2 Notkanten k3 (Werkzeug Stand 27): steile Meter zaehlen so viel mehr, dazu ein fester Zuschlag
local K3_ADD = 20
-- 19.27 (Sascha Teil 1 Punkt 5, Werkzeug Stand 46): Sprungkanten k4 { a, b, Meter, Fallhoehe } nur bergab von a nach b,
-- nur im Pfeil. Kleiner Zuschlag fuers Anlaufen an die Kante. Bei wenig Leben nur kleine Spruenge, sehr wenig Leben und
-- Hardcore gar keine (Schalter in den Einstellungen)
local K4_ADD = 8
-- 19.31 (Koordination 23:55, wie das Gelaende ab Stand 63): nie tiefer als 20 Yards (unter 15 Prozent Fallschaden)
local JUMP_HP_ALL, JUMP_HP_LOW, JUMP_LOW, JUMP_TOP = 0.6, 0.3, 12, 20
-- 19.22 (Sascha Teil 1 Punkt 1): geschwommene Meter (Werkzeug Stand 18, 4. Wert der Kante) kosten mehr als Laufen:
-- Meter plus Schwimm Meter mal (Tempo durch Schwimm Tempo minus 1). Gleiches Gewicht im Pfeil und in der Planung.
local SWIM_SPEED = 4.72  -- Yards pro Sekunde im Wasser (ohne Wasserform und Buffs)
local SWIM_TOOL = 7      -- so waehlt das Werkzeug die Wege fuer t (Schwimmen achtmal so teuer wie Laufen)
local NEAR_K = 4         -- so viele naechste Knoten als Einstieg ins Netz pruefen
local NEAR_MAX = 700     -- Yards: weiter weg ist kein Einstieg
local OFF_BAD = 1.8      -- Einstieg, dessen Luftlinie ueber einen Berg geht: so viel teurer
local CLUSTER = 250      -- Planung: Uebergaenge zwischen denselben zwei Zonen naeher als so viele Yards zaehlen als einer
local XLINK = 1.1        -- feste Verbindung (Tunnel, Bruecke, Aufzug): Luftlinie mal 1.1
local XDUP_YD = 20       -- 19.25: feste Verbindung, die das Netz schon als Kante hat (Enden so nah)
local LIFT_SPEED = 7     -- 19.25: Uebergang mit fester Zeit (Aufzug): Sekunden mal Lauftempo als Yards
local QMAX = 4           -- so viele Zonen mit vollem Netz im Speicher (aktuelle Zone und Nachbarn)
local UNREACH = 8099     -- "~~" in der Tabelle

local function Parent(m) return (ns.cityParent and ns.cityParent[m]) or m end
-- Punkt einer Karte auf die Zone (Stadt liegt in ihrer Zone; Orgrimmar liegt zum Teil neben der Karte von Durotar,
-- darum auch knapp ausserhalb 0..1)
local function OnZone(m, x, y)
  local z = Parent(m)
  if z ~= m then
    local f = ns.ToMapLoose or ns.ToMap
    if not f then return nil end
    local a, b = f(m, x, y, z)
    if not a then return nil end
    return z, a, b
  end
  return m, x, y
end
K.OnZone = OnZone
-- 19.25: Enden einer festen Verbindung (PAINT_XLINK, auf Era Karten gemalt) in Zonen Koordinaten. Auf Forever erst auf
-- die neu vermessenen Karten umrechnen (ns.EraXY, wie die anderen gemalten Daten), vorher stimmten sie in Mulgore und den
-- Oestlichen Pestlaendern nicht
local function XLinkEnds(h)
  local ax, ay, bx, by = h[2], h[3], h[5], h[6]
  if ns.FixXY then ax, ay = ns.FixXY(h[1], ax, ay); bx, by = ns.FixXY(h[4], bx, by) end
  local za, xa, ya = OnZone(h[1], ax, ay)
  local zb, xb, yb = OnZone(h[4], bx, by)
  return za, xa, ya, zb, xb, yb
end
K.XLinkEnds = XLinkEnds
local function Key(cx, cy) return cy * 100 + cx end
local function Cell(x, y)
  -- 19.9 (Code Pruefung): NaN wird sonst zum Tabellen Schluessel NaN ("table index is NaN")
  if x ~= x then x = 0 end
  if y ~= y then y = 0 end
  local cx, cy = floor(x / CELL), floor(y / CELL)
  if cx < 0 then cx = 0 elseif cx >= N then cx = N - 1 end
  if cy < 0 then cy = 0 elseif cy >= N then cy = N - 1 end
  return cx, cy
end
K.Key, K.Cell = Key, Cell

local DEC
local function Dec()
  if DEC then return DEC end
  local A = ns.PAINT_ABC
  if not A then return nil end
  DEC = {}
  for i = 1, #A do DEC[byte(A, i)] = i - 1 end
  return DEC
end

local function Yards(ui)
  if ns.ZoneYards then
    local z = ns.ZoneYards(ui)
    if z then return z[1], z[2] end
  end
  return 3500, 3500
end

------------------------------------------------------------
-- 1. Quelle: Daten Addon (FWW_AutoKarte), sonst FWW_AUTO_KARTE, sonst ns.AUTO_KARTE (Sim, alles in einer Datei)
------------------------------------------------------------
local function Want() return "forever" end -- 1.2e (P47): nur Forever
-- 19.4: Karten im Addon (Karte\Laden_*.lua legt den Teil vom eigenen Client nach ns.KARTE_RAW). Geht vor einem alten
-- Daten Addon (KeineZeitLevelingGuide_Karte_*), das nur noch als Notbehelf gelesen wird.
local ICACHE = {}
local function IRaw()
  local r = ns.KARTE_RAW
  if type(r) == "table" and next(r) ~= nil then return r end
end
function K.Inside() return IRaw() ~= nil end
function K.Info()
  if IRaw() then return ns.KARTE_INFO or { client = ns.KARTE_CLIENT } end
  local i = _G.FWW_AUTO_KARTE_INFO
  if type(i) == "table" then return i end
  local a = ns.AUTO_KARTE
  if type(a) == "table" then return { client = a.client, stand = a.stand, build = a.build, erstellt = a.erstellt } end
end
-- 19.31: Server Daten 1.12 (Karte\Server.lua, VMaNGOS): pro Quest { level, mindestlevel, xp, kupfer, kupfer_auf_60 }.
-- Index ueber alle Zonen erst beim ersten Aufruf. Ohne Datei nil (dann wie bisher Questie und Schaetzung)
local SQ
function ns.ServerQuest(qid)
  local s = ns.SERVER
  if not (qid and type(s) == "table") then return nil end
  if not SQ then
    SQ = {}
    for _, z in pairs(s) do
      local qs = type(z) == "table" and z.quests
      if type(qs) == "table" then
        for id, v in pairs(qs) do if type(v) == "table" then SQ[id] = v end end
      end
    end
  end
  return SQ[qid]
end
local state
-- 19.31: Format der Gelaende Daten (FWW_AUTO_KARTE_INFO.format). Fehlt das Feld, gilt 1. Neuere Formate kennt dieser Code
-- nicht: dann wie ohne Daten (Raster oder Luftlinie), nie ein Lua Fehler
-- 19.31: Format 2 (Werkzeug Stand 61): Sprungkanten k4 koennen Zwischenpunkte haben { a, b, Meter, Fall, x, y, ... }
local FORMAT_MAX = 2
K.FORMAT_MAX = FORMAT_MAX
function K.Format()
  local i = K.Info()
  local f = type(i) == "table" and tonumber(i.format) or nil
  return f or 1
end
-- "ok", "none" (kein Daten Addon), "client" (Daten vom anderen Client), "format" (Daten neuer als der Code)
function K.State()
  if state then return state end
  if K.Format() > FORMAT_MAX then state = "format"; return state end
  if IRaw() then state = "ok"; return state end
  local have = type(_G.FWW_AutoKarte) == "function" or type(_G.FWW_AUTO_KARTE) == "table" or type(ns.AUTO_KARTE) == "table"
  local i = K.Info()
  if not have then state = "none"
  elseif i and i.client and i.client ~= Want() then state = "client"
  else state = "ok" end
  return state
end
function K.Ok() return K.State() == "ok" end
-- 19.28 (Forever Daten sind beweglich): Build der Gelaende Daten gegen den Client (GetBuildInfo). Gibt passt (true/false,
-- nil wenn unbekannt), Daten Build, Client Build. Nur fuer Test Log und /klg karte, keine Meldung im Chat
function K.BuildCheck()
  local i = K.Info() or EMPTY
  local d = type(i.build) == "string" and tonumber(i.build:match("WOW%-(%d+)")) or nil
  local c = GetBuildInfo and tonumber((select(2, GetBuildInfo())))
  if not (d and c) then return nil, d, c end
  return d == c, d, c
end
-- nach dem Laden der Daten (Sim, Tests) neu pruefen
function K.Reset()
  state = nil
  if K.ResetMapCheck then K.ResetMapCheck() end
  K.Flush()
end

local noZone = {}
-- gibt es Daten fuer die Zone (ohne sie zu bauen)? nil: unbekannt
local function HasRaw(ui)
  local ir = IRaw()
  if ir then return ir[ui] ~= nil end
  local r = _G.FWW_AUTO_KARTE_RAW
  if type(r) == "table" then return r[ui] ~= nil end
  local g = _G.FWW_AUTO_KARTE
  if type(g) == "table" then return g[ui] ~= nil end
  local a = ns.AUTO_KARTE
  if type(a) == "table" then return a[ui] ~= nil end
end
function K.HasZone(ui)
  if not (ui and K.Ok()) then return false end
  ui = Parent(ui)
  if noZone[ui] then return false end
  local h = HasRaw(ui)
  if h ~= nil then return h end
  return true
end
local function Raw(ui)
  if not K.Ok() or noZone[ui] then return nil end
  local ir = IRaw()
  if ir then
    -- wie FWW_AutoKarte im Daten Addon: Text erst beim ersten Aufruf zur Tabelle bauen, gemerkt bis FreeRaw
    local t = ICACHE[ui]
    if t == nil then
      t = false
      local raw = ir[ui]
      if type(raw) == "string" then
        local fn = loadstring("return " .. raw)
        if fn then local ok, r = pcall(fn); if ok and type(r) == "table" then t = r end end
      end
      ICACHE[ui] = t
    end
    if not t then noZone[ui] = true; return nil end
    return t
  end
  local f = _G.FWW_AutoKarte
  local t
  if type(f) == "function" then
    local ok, r = pcall(f, ui)
    if ok and type(r) == "table" then t = r end
  else
    local g = _G.FWW_AUTO_KARTE
    if type(g) == "table" and type(g[ui]) == "table" then t = g[ui] end
    local a = ns.AUTO_KARTE
    if not t and type(a) == "table" and type(a[ui]) == "table" then t = a[ui] end
  end
  if not t then noZone[ui] = true end
  return t
end
local function FreeRaw(ui)
  if IRaw() then ICACHE[ui] = nil; return end
  local f = _G.FWW_AutoKarteFrei
  if type(f) == "function" then pcall(f, ui) end
end
-- 19.31 (Koordination 23:55): kleine Schnittstelle fuer das Editor Addon, nur lesen, nil sicher. Zone gibt dieselbe
-- Zonen Tabelle wie intern (bitte nicht veraendern), Frei gibt den Zwischenspeicher der Zone frei, Info den Kopf der Daten.
-- Dazu (Koordination 00:10, der Editor liest sie schon) die alten Namen vom Daten Addon FWW_AutoKarte, FWW_AutoKarteFrei
-- und FWW_AUTO_KARTE_INFO, nur wenn kein altes Daten Addon sie belegt. Laden_Ende ruft das am Schluss
function K.Schnittstelle()
  if IRaw() then
    if _G.FWW_AutoKarte == nil and _G.FWW_AutoKarteFrei == nil then
      _G.FWW_AutoKarte = function(ui) if type(ui) == "number" and IRaw() then return Raw(ui) end end
      _G.FWW_AutoKarteFrei = function(ui) if ui and IRaw() then ICACHE[ui] = nil end end
    end
    if _G.FWW_AUTO_KARTE_INFO == nil and type(ns.KARTE_INFO) == "table" then _G.FWW_AUTO_KARTE_INFO = ns.KARTE_INFO end
  end
  _G.FWW_EDITOR_API = {
    -- 19.35 (absprache editor2 Punkt 4, ABGESEGNET 17:02): version 2 mit Route(n), nur lesen, nil sicher
    version = 2,
    -- geplante Route ab dem aktuellen Schritt, hoechstens n Schritte (Standard 300). Je Schritt eine Kopie:
    -- { map, x, y, typ = k des ersten Ziels, text = Schritt Text ohne Farben (eine Zeile), lvl, t }. nil: keine Route
    Route = function(n)
      local ok, r = pcall(function()
        local o = ns.db and ns.db.opt
        if not (type(o) == "table" and type(o.steps) == "table" and o.steps[1]) then return nil end
        n = math.max(1, math.min(math.floor(tonumber(n) or 300), 2000))
        local out, i0 = {}, math.max(1, tonumber(o.idx) or 1)
        for i = i0, math.min(#o.steps, i0 + n - 1) do
          local st = o.steps[i]
          if type(st) == "table" then
            local a = type(st.acts) == "table" and st.acts[1] or nil
            local txt
            if ns.OptStepText then
              local okT, s = pcall(ns.OptStepText, st)
              if okT and type(s) == "string" then
                txt = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):match("^[^\n]*")
              end
            end
            out[#out + 1] = { map = st.map, x = st.x, y = st.y, typ = a and a.k or nil, text = txt, lvl = st.lvl, t = st.t }
          end
        end
        return out
      end)
      if ok and type(r) == "table" then return r end
      return nil
    end,
    Zone = function(ui)
      if type(ui) ~= "number" then return nil end
      local ok, t = pcall(Raw, ui)
      if ok and type(t) == "table" then return t end
      return nil
    end,
    Frei = function(ui) if type(ui) == "number" then pcall(FreeRaw, ui) end end,
    Info = function()
      local ok, i = pcall(K.Info)
      i = ok and type(i) == "table" and i or {}
      return { client = i.client or ns.KARTE_CLIENT, stand = tonumber(i.stand) or i.stand, build = i.build, format = tonumber(i.format) or 1 }
    end,
  }
end
-- alle Zonen mit Daten (Liste uiMap)
function K.Zones()
  local out = {}
  if K.State() == "format" then return out end
  local src = IRaw() or _G.FWW_AUTO_KARTE_RAW
  if type(src) ~= "table" then src = _G.FWW_AUTO_KARTE end
  if type(src) ~= "table" then src = ns.AUTO_KARTE end
  if type(src) == "table" then
    for z in pairs(src) do if type(z) == "number" then out[#out + 1] = z end end
  elseif K.Ok() and C_Map and C_Map.GetMapChildrenInfo then
    -- nur FWW_AutoKarte ohne Liste: die Zonen der Kontinente probieren
    for _, c in ipairs({ 1414, 1415 }) do
      for _, k in ipairs(C_Map.GetMapChildrenInfo(c, 3, false) or EMPTY) do
        if k.mapID and not (ns.cityParent and ns.cityParent[k.mapID]) then out[#out + 1] = k.mapID end
      end
    end
  end
  table.sort(out)
  return out
end

------------------------------------------------------------
-- Pruefung (nur Anzeige, rechnet nichts um): passen die Uebergaenge der Karte zu den Karten des Clients? Beide Seiten
-- eines Uebergangs sind derselbe Weltpunkt; ueber C_Map umgerechnet muessen sie aufeinander liegen. Fuer /klg karte und
-- das Test Log (19.0: im Sim lagen Mulgore, Oestliche Pestlaender und Rotkammgebirge daneben, Fehler war der Sim).
------------------------------------------------------------
local FZ, PZ, QZ = {}, {}, {}   -- Felder, Planungs Paket, volles Netz
local mapCheck
function K.MapCheck()
  if mapCheck then return mapCheck end
  local f = ns.ToMapLoose or ns.ToMap
  if not f or not K.Ok() then return nil end
  local res = { n = 0, sum = 0, max = 0, bad = {} }
  for _, z in ipairs(K.Zones()) do
    local P = PZ[z]
    local k = 0
    for _, ps in ipairs(P and P.pass or EMPTY) do
      if k >= 4 then break end
      local u, v = f(ps.z2, ps.x2, ps.y2, z)
      if u then
        local w, h = Yards(z)
        local d = sqrt(((u - ps.x) * w) ^ 2 + ((v - ps.y) * h) ^ 2)
        res.n, res.sum, k = res.n + 1, res.sum + d, k + 1
        if d > res.max then res.max = d end
        if d > 50 then res.bad[z] = math.max(res.bad[z] or 0, floor(d)) end
      end
    end
  end
  if res.n == 0 then return nil end
  res.mean = res.sum / res.n
  mapCheck = res
  if ns.TestLog then
    local l = {}
    for z, d in pairs(res.bad) do l[#l + 1] = z .. ":" .. d end
    ns.TestLog("WEGE", ("Karte Uebergaenge gegen Client Karten: %d geprueft, im Mittel %d yd, hoechstens %d yd%s"):format(res.n, floor(res.mean), floor(res.max),
      #l > 0 and (", daneben (Zone:yd) " .. table.concat(l, " ")) or ""))
  end
  return res
end
function K.ResetMapCheck() mapCheck = nil end
local function Conv(ui, x, y) return x, y end
local function ConvSet(ui, set) return set end

------------------------------------------------------------
-- 2. Felder einer Zone (klein, bleiben im Speicher): block, road, water (1 flach, 2 tief), cliff (Richtung nach unten)
------------------------------------------------------------
local qOrder = {}
local function Pairs2(s, set, val)
  local D = Dec()
  if not (s and D) then return set end
  for p = 1, #s - 1, 2 do
    local a, b = D[byte(s, p)], D[byte(s, p + 1)]
    if a and b then set[a * 90 + b] = val end
  end
  return set
end
local function BuildFields(ui, d)
  local D = Dec()
  local F = { block = ConvSet(ui, Pairs2(d.b, {}, true)), road = {}, water = {}, cliff = {} }
  local B = F.block
  for k in pairs(ConvSet(ui, Pairs2(d.r, {}, true))) do if not B[k] then F.road[k] = true end end
  local wt = Pairs2(d.w, {}, 1)
  Pairs2(d.d, wt, 2)
  F.water = ConvSet(ui, wt)
  local c = d.c
  if c and D then
    local cl = {}
    for p = 1, #c - 2, 3 do
      local a, b, v = D[byte(c, p)], D[byte(c, p + 1)], D[byte(c, p + 2)]
      if a and b and v and v >= 1 and v <= 8 then cl[a * 90 + b] = v - 1 end
    end
    for k, v in pairs(ConvSet(ui, cl)) do if not B[k] then F.cliff[k] = v end end
  end
  -- 19.9 Werkzeug Stand 36: Hang (viele steile Stellen, kein Berg). Das Netz meidet ihn, die Luftlinie ist dort nicht frei
  F.hang = {}
  if d.h then for k in pairs(ConvSet(ui, Pairs2(d.h, {}, true))) do if not B[k] then F.hang[k] = true end end end
  -- 19.29: feindliche Mobs pro Feld (Werkzeug gH / gA, ab Stand 55 richtig), erst bei Bedarf entpackt (K.MobGrid)
  F.mobS = { H = d.gH, A = d.gA }
  F.mobS = { H = d.gH, A = d.gA }
  -- du bist hier gelaufen: kein Berg und kein Hang
  local db = ns.db
  for k in pairs(db and db.walk and db.walk[ui] or EMPTY) do B[k] = nil; F.hang[k] = nil end
  -- Quest Punkte nie im Berg und vom Hauptgebiet aus erreichbar (Path.lua)
  if ns.CleanBlocks then pcall(ns.CleanBlocks, ui, B) end
  return F
end

------------------------------------------------------------
-- 3. Planungs Paket einer Zone (klein, bleibt): Prio 1 Knoten der Tabelle, Tabelle t, Uebergaenge
------------------------------------------------------------
local BK = 20 -- Eimer fuer die Suche nach dem naechsten Knoten (20 x 20 pro Zone)
local function BucketOf(x, y)
  local bx, by = floor(x * BK), floor(y * BK)
  if bx < 0 then bx = 0 elseif bx >= BK then bx = BK - 1 end
  if by < 0 then by = 0 elseif by >= BK then by = BK - 1 end
  return bx, by
end
local function MakeBuckets(xs, ys, n)
  local b = {}
  for i = 1, n do
    local bx, by = BucketOf(xs[i], ys[i])
    local k = by * BK + bx
    local l = b[k]
    if not l then l = {}; b[k] = l end
    l[#l + 1] = i
  end
  return b
end
-- naechste Knoten um x, y: Liste { i, Yards } nach Abstand, hoechstens k, nur use(i) == true (wenn gesetzt)
local function Near(b, xs, ys, x, y, w, h, k, use, maxYd)
  local bx, by = BucketOf(x, y)
  local out = {}
  local cellYd = math.min(w, h) / BK
  for r = 0, BK do
    for dy = -r, r do
      for dx = -r, r do
        if math.abs(dx) == r or math.abs(dy) == r then
          local qx, qy = bx + dx, by + dy
          if qx >= 0 and qx < BK and qy >= 0 and qy < BK then
            local l = b[qy * BK + qx]
            if l then
              for _, i in ipairs(l) do
                if not use or use(i) then
                  local d = sqrt(((xs[i] - x) * w) ^ 2 + ((ys[i] - y) * h) ^ 2)
                  if not maxYd or d <= maxYd then out[#out + 1] = { i, d } end
                end
              end
            end
          end
        end
      end
    end
    -- genug gefunden und der naechste Ring ist sicher weiter weg als der k-te
    if #out >= k then
      table.sort(out, function(p, q) return p[2] < q[2] end)
      if out[k][2] <= r * cellYd then break end
    end
    if maxYd and r * cellYd > maxYd then break end
  end
  table.sort(out, function(p, q) return p[2] < q[2] end)
  for i = #out, k + 1, -1 do out[i] = nil end
  return out
end
K.Near = Near

local function BuildPlan(ui, d)
  local n = d.netz
  if not (n and n.p and n.ti and n.t) then return false end
  local p, ti = n.p, n.ti
  local P = { ui = ui, n = #ti, nx = {}, ny = {}, pos = {}, t = n.t, tsH = n.tsH, tsA = n.tsA, pass = {}, tiN = {},
    tsw = (type(n.tsw) == "string" and #n.tsw == #n.t) and n.tsw or nil }
  for i, node in ipairs(ti) do
    P.nx[i], P.ny[i] = Conv(ui, p[node * 3 - 2], p[node * 3 - 1])
    P.pos[node] = i
    P.tiN[i] = node
  end
  -- 19.23: Level der feindlichen Mobs neben den Kanten von k1 (g1, wie das Werkzeug die sicheren Tabellen rechnet), pro
  -- Fraktion: 90 % der Mobs sind hoechstens so hoch (89 = Level unbekannt zaehlt nicht, sonst entscheidet ein einzelner
  -- Boss). Ist das fuer dich grau, nimmt die Planung die schnelle Tabelle
  local D = DEC or Dec()
  local g1 = n.g1
  if D and type(g1) == "string" then
    local hist = { H = {}, A = {} }
    for i = 1, #(n.k1 or EMPTY) do
      local c = (i - 1) * 6
      for f, o in pairs({ H = 0, A = 3 }) do
        local cnt, lv = D[byte(g1, c + o + 1) or 0], D[byte(g1, c + o + 2) or 0]
        if cnt and cnt > 0 and lv and lv < 89 then hist[f][lv] = (hist[f][lv] or 0) + cnt end
      end
    end
    local mm = {}
    for f, h in pairs(hist) do
      local tot = 0
      for _, c in pairs(h) do tot = tot + c end
      local acc, q = 0, 0
      for lv = 0, 88 do
        if h[lv] then acc = acc + h[lv]; q = lv; if acc >= tot * 0.9 then break end end
      end
      mm[f] = q
    end
    P.mobMax = mm
  end
  -- 19.22: Grundnetz k1 mit den Schwimm Metern, nur wenn darin geschwommen wird (fuer die Schwimm Zeit in der Planung)
  -- 19.26: ab Werkzeug Stand 53 kommen die geschwommenen Meter pro Paar fertig (netz.tsw), dann keine Schaetzung
  local hasSw = false
  if not P.tsw then
    for _, e in ipairs(n.k1 or EMPTY) do if #e % 2 == 0 and (e[4] or 0) > 0 then hasSw = true; break end end
  end
  if hasSw then
    local W = { a = {}, b = {}, m = {}, s = {}, adj = {} }
    for i, e in ipairs(n.k1) do
      local a, b = e[1], e[2]
      W.a[i], W.b[i], W.m[i] = a, b, e[3] or 0
      W.s[i] = (#e % 2 == 0) and (e[4] or 0) or 0
      local la, lb = W.adj[a], W.adj[b]
      if not la then la = {}; W.adj[a] = la end
      if not lb then lb = {}; W.adj[b] = lb end
      la[#la + 1] = i
      lb[#lb + 1] = i
    end
    P.sw, P.swRow = W, {}
  end
  P.bk = MakeBuckets(P.nx, P.ny, P.n)
  -- Uebergaenge: die Seite dieser Zone ist ein Knoten des Netzes (gleiche Stelle)
  local idx = {}
  for i = 1, #p / 3 do idx[("%.4f:%.4f"):format(p[i * 3 - 2], p[i * 3 - 1])] = i end
  for _, e in ipairs(d.xpass or EMPTY) do
    local x, y, z2, x2, y2
    if e[1] == ui then x, y, z2, x2, y2 = e[2], e[3], e[4], e[5], e[6]
    elseif e[4] == ui then x, y, z2, x2, y2 = e[5], e[6], e[1], e[2], e[3] end
    if x then
      local node = idx[("%.4f:%.4f"):format(x, y)]
      x, y = Conv(ui, x, y)
      x2, y2 = Conv(z2, x2, y2)
      -- 19.25 Werkzeug Stand 52: 9 Werte = fester Uebergang mit Zeit (Aufzug), 8. Sekunden, 9. Ort geschaetzt (1)
      local sec = (type(e[8]) == "number" and e[8] > 0) and e[8] or nil
      P.pass[#P.pass + 1] = { x = x, y = y, z2 = z2, x2 = x2, y2 = y2, prio = e[7] or 1, node = node, pos = node and P.pos[node],
        sec = sec, est = (e[9] == 1 or e[9] == true) or nil }
    end
  end
  -- 19.25 (Sascha Teil 1 Punkt 6): feste Verbindungen von Hand (PAINT_XLINK), die das Werkzeug schon als Kante im Netz
  -- hat (ab Stand 50): eine Kante in k1 oder k2 mit beiden Enden hoechstens XDUP_YD neben den Enden der Verbindung.
  -- Die zaehlen dann nicht nochmal (sonst doppelt), die Kosten kommen aus der Kante
  local XL = ns.PAINT_XLINK
  if XL then
    local w, h = Yards(ui)
    for xi, L in ipairs(XL) do
      local za, ax, ay, zb, bx, by = XLinkEnds(L)
      if za == ui and zb == ui and ax and bx then
        local function Near2(i, x0, y0)
          local dx, dy = (p[i * 3 - 2] - x0) * w, (p[i * 3 - 1] - y0) * h
          return dx * dx + dy * dy <= XDUP_YD * XDUP_YD
        end
        local dup = false
        local function Match(e)
          local a, b = e and e[1], e and e[2]
          return a and b and p[a * 3] and p[b * 3] and ((Near2(a, ax, ay) and Near2(b, bx, by)) or (Near2(a, bx, by) and Near2(b, ax, ay)))
        end
        if type(n.lift) == "table" then
          -- 19.26 Werkzeug Stand 53: netz.lift { Nummer in k1, Nummer in k2, Art } (Art 2 = Hand Verbindung): nur diese Kanten
          for _, l in ipairs(n.lift) do
            if l[3] == 2 and (Match((n.k1 or EMPTY)[l[1] or 0]) or Match((n.k2 or EMPTY)[l[2] or 0])) then dup = true; break end
          end
        else
          for _, set in ipairs({ n.k1 or EMPTY, n.k2 or EMPTY }) do
            for _, e in ipairs(set) do
              if Match(e) then dup = true; break end
            end
            if dup then break end
          end
        end
        if dup then P.xdup = P.xdup or {}; P.xdup[xi] = true end
      end
    end
  end
  return P
end

-- Wegzeit zwischen zwei Prio 1 Knoten (Stelle in ti), Yards, nil = nicht erreichbar
local ENC
local function Enc()
  if ENC then return ENC end
  local A = ns.PAINT_ABC or ""
  ENC = {}
  for i = 1, #A do ENC[i - 1] = A:sub(i, i) end
  return ENC
end
-- Strecke zwischen Knoten i und j im Zonen Graph g (Zeilen als Text), nil = nicht erreichbar
local function DV(g, i, j)
  if i == j then return 0 end
  local s = g.D[i]
  if not s then return nil end
  local c = j * 2 - 1
  local D = DEC or Dec()
  local a, b = D[byte(s, c) or 0], D[byte(s, c + 1) or 0]
  if not (a and b) then return nil end
  local v = a * 90 + b
  if v >= UNREACH then return nil end
  return v * 5
end
local function TVal(s, n, i, j)
  if i == j then return 0 end
  if not s then return nil end
  if i > j then i, j = j, i end
  local q = ((i - 1) * (2 * n - i)) / 2 + (j - i)
  local c = q * 2 - 1
  local D = DEC or Dec()
  local a, b = D[byte(s, c) or 0], D[byte(s, c + 1) or 0]
  if not (a and b) then return nil end
  local v = a * 90 + b
  if v >= UNREACH then return nil end
  return v * 5
end
K.TVal = TVal

-- 19.22: Schwimm Gewicht: (Tempo durch Schwimm Tempo) minus 1, mit dem Tempo der Planung (mit Reittier mehr, weil du
-- im Wasser absteigst). Alle 10 Sekunden neu, auf 0.1 gerundet (die Planung fragt sehr oft)
local swimF, swimAt = nil, -999
function K.SwimF()
  local now = GetTime and GetTime() or 0
  if swimF and now - swimAt < 10 and now >= swimAt then return swimF end
  swimAt = now
  local sp = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  if type(sp) ~= "number" or sp ~= sp then sp = 7 end
  local f = sp / SWIM_SPEED - 1
  if f < 0 then f = 0 end
  swimF = floor(f * 10 + 0.5) / 10
  return swimF
end
-- geschwommene Meter auf dem Weg von ti Knoten i zu allen anderen ti Knoten (Weg ueber k1, gewaehlt wie das Werkzeug
-- die Tabelle t rechnet: Schwimmen achtmal so teuer). Nur Paare mit Schwimm Metern, gemerkt pro Zone
local function SwimRow(P, i)
  local row = P.swRow[i]
  if row then return row end
  row = {}
  P.swRow[i] = row
  local W = P.sw
  local src = P.tiN[i]
  if not (src and W.adj[src]) then return row end
  local H = K.Heap()
  local dist, swum, done = { [src] = 0 }, { [src] = 0 }, {}
  H.push(0, src)
  while H.size() > 0 do
    local u, du = H.pop()
    if not done[u] then
      done[u] = true
      local pu = P.pos[u]
      if pu and swum[u] > 0 then row[pu] = swum[u] end
      for _, ei in ipairs(W.adj[u]) do
        local v = (W.a[ei] == u) and W.b[ei] or W.a[ei]
        if not done[v] then
          local nd = du + W.m[ei] + SWIM_TOOL * W.s[ei]
          if not dist[v] or nd < dist[v] then
            dist[v] = nd
            swum[v] = swum[u] + W.s[ei]
            H.push(nd, v)
          end
        end
      end
    end
  end
  return row
end
-- Strecke der Planung zwischen den ti Knoten i und j: Tabelle t plus die Schwimm Zeit als Yards, nil = nicht erreichbar
local function PVal(P, i, j)
  local v = TVal(P.t, P.n, i, j)
  if not v or i == j then return v end
  local tsw = P.tsw
  -- 19.23 (Sascha Teil 1 Punkt 2): "sicherer Weg" an: die sichere Tabelle (tsH / tsA), wenn sie hoechstens 20 % laenger
  -- ist und in der Zone nicht (fast) alle Mobs fuer dich grau sind. Gleiche Regel wie der Pfeil
  local PM = K.PlanMode()
  if PM.safe then
    local s, mm = P[PM.ts], P.mobMax and P.mobMax[PM.fac]
    if s and mm and mm > PM.gray then
      local vs = TVal(s, P.n, i, j)
      if vs and vs > v and vs <= v * SAFE_MAX then v = vs end
    end
  end
  if not (tsw or P.sw) then return v end
  local f = K.SwimF()
  if f <= 0 then return v end
  if i > j then i, j = j, i end
  -- 19.26: geschwommene Meter aus der Karte (netz.tsw, Werkzeug Stand 53), sonst geschaetzt ueber k1
  local sm
  if tsw then sm = TVal(tsw, P.n, i, j) else sm = SwimRow(P, i)[j] end
  if sm and sm > 0 then v = v + f * sm end
  return v
end
K.PVal = PVal

-- Zone laden: Felder und Planungs Paket bauen, dann freigeben (ausser das volle Netz bleibt)
-- 19.9 (Code Pruefung): kaputte Zone Daten werfen beim Bauen nicht jedes Mal neu (Pfeil fragt 4 Mal pro Sekunde),
-- die Zone gilt dann als ohne Daten (false) und der Fehler kommt einmal ins Test Log
local badZone = {}
local function SafeBuild(what, f, ui, d)
  local ok, r = pcall(f, ui, d)
  if ok then return r end
  if not badZone[ui] then
    badZone[ui] = true
    if ns.TestLog then ns.TestLog("FEHLER", ("Karte %s Zone %s: %s"):format(what, tostring(ui), tostring(r))) end
  end
  return false
end
K.badZone = badZone
local function Ensure(ui)
  if FZ[ui] ~= nil and PZ[ui] ~= nil then return FZ[ui], PZ[ui] end
  local d = Raw(ui)
  if not d then FZ[ui], PZ[ui] = false, false; return false, false end
  if FZ[ui] == nil then FZ[ui] = SafeBuild("Felder", BuildFields, ui, d) end
  if PZ[ui] == nil then PZ[ui] = SafeBuild("Plan", BuildPlan, ui, d) end
  if not QZ[ui] then FreeRaw(ui) end
  return FZ[ui], PZ[ui]
end
K.Ensure = Ensure

local EMPTY_F = { block = EMPTY, road = EMPTY, water = EMPTY, cliff = EMPTY, hang = EMPTY }
-- Felder einer Zone (fuer alle, die frueher db.block / road / water / cliff gelesen haben)
function ns.Felder(ui)
  if not ui then return EMPTY_F end
  ui = Parent(ui)
  local F = FZ[ui]
  if F == nil then
    if not K.HasZone(ui) then return EMPTY_F end
    F = Ensure(ui)
  end
  return F or EMPTY_F
end
-- nur wenn schon geladen (im Lern Takt kein Laden)
function K.FelderIfLoaded(ui) return ui and FZ[Parent(ui)] or nil end
-- 19.29 (Sascha Teil 1 Punkt 3): feindliche Mobs pro Feld aus der Karte (Werkzeug gH / gA, je 5 Zeichen: Feld, Anzahl,
-- mittleres Level, Elite). fac "H" oder "A". Gibt { n = {}, lv = {}, e = {} } nach Feld (y * 100 + x), nil ohne Daten.
-- Nur fuer Zonen (Staedte haben andere Koordinaten, dort nil)
function K.MobGrid(ui, fac)
  if not ui or Parent(ui) ~= ui or not K.HasZone(ui) then return nil end
  local F = ns.Felder(ui)
  local s = F and F.mobS and F.mobS[fac]
  if type(s) ~= "string" then return nil end
  F.mobG = F.mobG or {}
  local g = F.mobG[fac]
  if g then return g end
  local D = DEC or Dec()
  if not D then return nil end
  g = { n = {}, lv = {}, e = {} }
  for p = 1, #s - 4, 5 do
    local a, b = D[byte(s, p)], D[byte(s, p + 1)]
    local n, lv, el = D[byte(s, p + 2)], D[byte(s, p + 3)], D[byte(s, p + 4)]
    if a and b and n and n > 0 then
      local k = a * 90 + b
      g.n[k], g.lv[k], g.e[k] = n, lv or 0, el or 0
    end
  end
  F.mobG[fac] = g
  return g
end
function K.Plan(ui)
  ui = Parent(ui)
  local P = PZ[ui]
  if P == nil then
    if not K.HasZone(ui) then return nil end
    local _
    _, P = Ensure(ui)
  end
  return P or nil
end

------------------------------------------------------------
-- 4. Volles Netz (Pfeil): Knoten, Kanten mit Zwischenpunkten, Mobs, Reitwege. Hoechstens QMAX Zonen.
------------------------------------------------------------
local function EdgeSet(list)
  local E = { a = {}, b = {}, m = {}, sw = {}, off = {}, raw = list or EMPTY }
  for i, e in ipairs(list or EMPTY) do
    E.a[i], E.b[i], E.m[i] = e[1], e[2], e[3] or 0
    -- Werkzeug Stand 18: 4. Wert geschwommene Meter (dann gerade Laenge), Stand 17 ohne (ungerade)
    if #e % 2 == 0 then E.sw[i], E.off[i] = e[4] or 0, 5 else E.sw[i], E.off[i] = 0, 4 end
  end
  E.n = #(list or EMPTY)
  return E
end
local function PairKey(a, b) if a > b then a, b = b, a end return a * 100000 + b end
local function BuildNet(ui, d)
  local n = d.netz
  if not (n and n.p) then return false end
  local p = n.p
  local Q = { ui = ui, np = #p / 3, px = {}, py = {}, pr = {}, E = { EdgeSet(n.k1), EdgeSet(n.k2) }, g = { n.g1, n.g2 }, ride = {},
    k3 = n.k3, k4 = n.k4 }
  -- 20.3 (Ge Netz Feld nr, Vorschlag Na 00:35): graue Kanten (nicht relevant) kosten mal faktor, die echte Laenge bleibt.
  -- Kantennummer = Stelle in k1 bzw k2. Alte Daten ohne nr: nichts aendert sich
  if type(n.nr) == "table" then
    local f = tonumber(n.nr.faktor) or 5
    if f > 1 and f <= 20 then
      Q.nrf, Q.nrset = f, { {}, {} }
      for md = 1, 2 do for _, i in ipairs(n.nr["k" .. md] or EMPTY) do Q.nrset[md][i] = true end end
    end
  end
  for i = 1, Q.np do
    Q.px[i], Q.py[i] = Conv(ui, p[i * 3 - 2], p[i * 3 - 1])
    Q.pr[i] = p[i * 3] or 1
  end
  Q.bk = MakeBuckets(Q.px, Q.py, Q.np)
  -- Reitwege: Kanten aus k1; fuer k2 ueber das Knotenpaar
  for _, fac in ipairs({ "H", "A" }) do
    local r = n["r" .. fac]
    if r then
      local s1, s2 = {}, {}
      local E1 = Q.E[1]
      for _, i in ipairs(r) do
        if E1.a[i] then s1[i] = true; s2[PairKey(E1.a[i], E1.b[i])] = true end
      end
      Q.ride[fac] = { s1, s2 }
    end
  end
  return Q
end
local function Touch(ui)
  for i, u in ipairs(qOrder) do if u == ui then table.remove(qOrder, i); break end end
  table.insert(qOrder, ui)
  while #qOrder > QMAX do
    local old = table.remove(qOrder, 1)
    QZ[old] = nil
    FreeRaw(old)
  end
end
function K.Net(ui)
  ui = Parent(ui)
  local Q = QZ[ui]
  if Q then Touch(ui); return Q end
  if Q == false or not K.HasZone(ui) then return nil end
  local d = Raw(ui)
  if not d then return nil end
  if FZ[ui] == nil then FZ[ui] = SafeBuild("Felder", BuildFields, ui, d) end
  if PZ[ui] == nil then PZ[ui] = SafeBuild("Plan", BuildPlan, ui, d) end
  Q = SafeBuild("Netz", BuildNet, ui, d)
  -- 19.9: Kanten Listen gleich hier bauen (billig), eine Kante ohne Knoten macht das Netz dann einmal ungueltig
  if Q and K.Adj and not SafeBuild("Kanten", function() K.Adj(Q, 1); K.Adj(Q, 2); return true end, ui, d) then Q = false end
  if not Q then QZ[ui] = false; FreeRaw(ui); return nil end
  QZ[ui] = Q
  Touch(ui)
  return Q
end

-- alles vergessen (neue Daten, Tests)
function K.Flush()
  for _, u in ipairs(qOrder) do FreeRaw(u) end
  FZ, PZ, QZ, qOrder, noZone = {}, {}, {}, {}, {}
  K.ResetCaches()
  ns.blockRev = (ns.blockRev or 0) + 1
end

------------------------------------------------------------
-- 5. Luftlinie ueber die Felder: frei, wenn kein Berg, kein tiefes Wasser und keine Klippe hoch.
-- Gelaufene Felder sind nie Berg (beim Bauen entfernt), geteilte Wege machen Berge unsicher oder frei.
-- Klippe hoch: nur deine eigene Spur in diese Richtung hebt das auf.
------------------------------------------------------------
local function W() return ns.Ways end
local function HasBit(v, b) return floor(v / 2 ^ b) % 2 == 1 end
local function Up(down, d) local x = (d - (down + 4)) % 8; return x == 0 or x == 1 or x == 7 end
-- v11e (Ka 10:58, S Log L3.7 Galgar und L5.1 Zureetha: Pfeil Luftlinie ueber Klippen Baender, im Spiel Sackgasse): fuer die
-- Luftlinie zaehlt eine Klippe nur noch als frei, wenn du genau bergab gehst (Richtung hoechstens 45 Grad neben "runter").
-- Seitlich oder schraeg ueber das Band ist nicht mehr frei, dann rechnet der Pfeil den Weg ueber das Netz. db.klippeStreng=false: alt
local function DownOk(down, d) local x = (d - down) % 8; return x == 0 or x == 1 or x == 7 end
local function DirOf(dx, dy)
  if dx == 0 and dy == 0 then return nil end
  return floor(math.atan2(dy, dx) / (math.pi / 4) + 0.5) % 8
end
local HANG_RUN = 2
local function LineFree(ui, x1, y1, x2, y2, F)
  F = F or ns.Felder(ui)
  local B, Wt, C, Hg = F.block, F.water, F.cliff, F.hang or EMPTY
  if not (next(B) or next(Wt) or next(C) or next(Hg)) then return true end
  local ov = (W() and W().Overrides(ui)) or EMPTY
  local db = ns.db
  local own = db and db.walkDir and db.walkDir[ui] or EMPTY
  local s, t = Key(Cell(x1, y1)), Key(Cell(x2, y2))
  if s == t then return true end
  local dir = DirOf(x2 - x1, y2 - y1)
  -- alle Felder, durch die die echte Linie geht, der Reihe nach (nicht von Feldmitte zu Feldmitte): so ist ein Stueck
  -- der Linie nie schlechter als die ganze (sonst springt der Pfeil zwischen Luftlinie und Umweg hin und her)
  local gx, gy = x1 / CELL, y1 / CELL
  local ex, ey = x2 / CELL, y2 / CELL
  local cx, cy = floor(gx), floor(gy)
  local tcx, tcy = floor(ex), floor(ey)
  local dx, dy = ex - gx, ey - gy
  local sx = (dx > 0) and 1 or -1
  local sy = (dy > 0) and 1 or -1
  local tdx = (dx ~= 0) and math.abs(1 / dx) or huge
  local tdy = (dy ~= 0) and math.abs(1 / dy) or huge
  local tmx = (dx ~= 0) and (((dx > 0) and (cx + 1 - gx) or (gx - cx)) * tdx) or huge
  local tmy = (dy ~= 0) and (((dy > 0) and (cy + 1 - gy) or (gy - cy)) * tdy) or huge
  local pk = s
  local hRun = 0
  for _ = 1, 400 do
    if cx == tcx and cy == tcy then break end
    local tin
    if tmx < tmy then tin = tmx; cx = cx + sx; tmx = tmx + tdx else tin = tmy; cy = cy + sy; tmy = tmy + tdy end
    if tin > 1 then break end
    local qx, qy = cx, cy
    if qx < 0 then qx = 0 elseif qx >= N then qx = N - 1 end
    if qy < 0 then qy = 0 elseif qy >= N then qy = N - 1 end
    local k = Key(qx, qy)
    if k ~= pk then
      if k ~= t then
        if B[k] then
          local o = ov[k]
          if o ~= 3 and o ~= 2 then return false end
        end
        -- 19.10 Hang (Werkzeug Stand 36): ein einzelnes Hang Feld geht noch, ab HANG_RUN Feldern am Stueck nicht mehr
        -- (alle Hang Felder sperren war zu streng: t10 Forever 270 > 264 von 280 angekommen)
        if Hg[k] and ov[k] ~= 3 and ov[k] ~= 2 then
          hRun = hRun + 1
          if hRun >= HANG_RUN then return false end
        else
          hRun = 0
        end
        if Wt[k] == 2 then return false end
      end
      if dir then
        local c1, c2 = C[k], C[pk]
        local strict = not (db and db.klippeStreng == false)
        -- 1.2j (P66, Ka 16:05 L3.7 Galgar und L5.1 Zureetha: Pfeil Luftlinie ueber Klippen Ringe, Sackgasse): eine Klippe ist
        -- fuer die Luftlinie nur noch frei, wenn es bergab geht UND die Fallhoehe bekannt und hoechstens JumpMax ist
        -- (F.cliffH je Feld, sobald Ka sie liefert). Ohne Hoehe: zu, der Pfeil nimmt den Weg ueber Netz und Karte.
        -- Eigene Spur in diese Richtung hebt es wie bisher auf. db.klippeStreng=false = alt (nur Richtung)
        local function CliffBad(c, kk)
          if not c then return false end
          if Up(c, dir) then return true end
          if not strict then return false end
          if not DownOk(c, dir) then return true end
          local hh = F.cliffH and F.cliffH[kk]
          local jm = K.JumpMax and K.JumpMax()
          return not (hh and jm and hh <= jm)
        end
        if CliffBad(c1, k) or CliffBad(c2, pk) then
          local m = own[k]
          if not (m and HasBit(m, dir)) then return false end
        end
      end
      pk = k
    end
  end
  return true
end
K.LineFree = LineFree

local function Slow() return ns.db and ns.db.slowPC and true or false end
K.Slow = Slow

-- feste Verbindungen mit beiden Enden in derselben Zone (zb Aufzuege von Donnerfels, FesteDaten.lua): die fehlen im
-- Netz der Karte (liegen auf dem Server). { ax, ay, bx, by, Yards }
local linkCache = {}
local function ZoneLinks(z)
  local ck = z * 10 + (Slow() and 1 or 0)
  local c = linkCache[ck]
  if c then return c end
  c = {}
  local P = K.Plan(z)
  local dup = P and P.xdup or EMPTY
  for xi, h in ipairs(ns.PAINT_XLINK or EMPTY) do
    if not (Slow() and h[7] == 2) and not dup[xi] then
      local za, ax, ay, zb, bx, by = XLinkEnds(h)
      if za == z and zb == z then
        local w, hh = Yards(z)
        c[#c + 1] = { ax, ay, bx, by, sqrt(((bx - ax) * w) ^ 2 + ((by - ay) * hh) ^ 2) * XLINK }
      end
    end
  end
  linkCache[ck] = c
  return c
end
K.ZoneLinks = ZoneLinks

------------------------------------------------------------
-- 6. Planung in einer Zone: Strecke in Yards ueber das Netz (Tabelle t), nil = Luftlinie ist frei oder keine Daten
------------------------------------------------------------
local zdCache, zdN, zdRev = {}, 0, -1
-- Einstiege ins Netz um einen Punkt: { Stelle in ti, Yards (mal OFF_BAD, wenn die Luftlinie nicht frei ist) }
-- 19.9: toPt = Zielseite (vom Knoten zum Punkt laufen, wichtig fuer Klippen)
local function Entries(ui, P, x, y, w, h, F, toPt)
  local list = Near(P.bk, P.nx, P.ny, x, y, w, h, NEAR_K, nil, NEAR_MAX * 2)
  -- weit weg vom Netz (Rand der Zone, wenig Prio 1 Knoten): die naechsten zwei, egal wie weit
  if #list == 0 then list = Near(P.bk, P.nx, P.ny, x, y, w, h, 2) end
  for _, e in ipairs(list) do
    local nx, ny = P.nx[e[1]], P.ny[e[1]]
    local free
    if toPt then free = LineFree(ui, nx, ny, x, y, F) else free = LineFree(ui, x, y, nx, ny, F) end
    if not free then e[2] = e[2] * OFF_BAD + 30 end
  end
  return list
end
-- kuerzeste Strecke zwischen zwei Einstiegs Listen ueber die Tabelle
local function ViaTable(P, A, B)
  local best
  for _, a in ipairs(A) do
    for _, b in ipairs(B) do
      local v = PVal(P, a[1], b[1])
      if v then
        v = v + a[2] + b[2]
        if not best or v < best then best = v end
      end
    end
  end
  return best
end
function K.ZoneDist(ui, x1, y1, x2, y2)
  if not (ui and x1 and x2) then return nil end
  local z = Parent(ui)
  if z ~= ui and ns.ToMap then
    local a, b = ns.ToMap(ui, x1, y1, z)
    local c, d = ns.ToMap(ui, x2, y2, z)
    if not (a and c) then return nil end
    x1, y1, x2, y2 = a, b, c, d
  end
  -- die Route fragt sehr oft (Millionen mal pro Rechnung): zuerst im Speicher nachsehen
  local rev = (ns.blockRev or 0) .. ":" .. K.SwimF() .. ":" .. K.PlanMode().sig
  if zdRev ~= rev or zdN > 60000 then zdCache, zdN, zdRev = {}, 0, rev end
  local s, t = Key(Cell(x1, y1)), Key(Cell(x2, y2))
  if s == t then return nil end
  -- 19.9: mit Richtung (Klippen gelten nur in eine Richtung, vorher gab die zuerst gefragte Richtung beide vor)
  local ck = z * 100000000 + s * 10000 + t
  local c = zdCache[ck]
  if c ~= nil then return c or nil end
  zdN = zdN + 1
  local P = K.HasZone(z) and K.Plan(z)
  if not (P and P.n > 1) then zdCache[ck] = false; return nil end
  local F = ns.Felder(z)
  local res
  if not LineFree(z, x1, y1, x2, y2, F) then
    local w, h = Yards(z)
    local Es, Eg = Entries(z, P, x1, y1, w, h, F), Entries(z, P, x2, y2, w, h, F, true)
    res = ViaTable(P, Es, Eg)
    -- ueber eine feste Verbindung in der Zone (Aufzug, Tunnel)
    local links = ZoneLinks(z)
    if #links > 0 then
      -- 19.9: Start Seite vom Punkt zum Verbindungs Ende, Ziel Seite vom Verbindungs Ende zum Ziel
      local function Leg(E, x, y, px, py, back)
        local free
        if back then free = LineFree(z, px, py, x, y, F) else free = LineFree(z, x, y, px, py, F) end
        if free then return sqrt(((px - x) * w) ^ 2 + ((py - y) * h) ^ 2) end
        if back then return ViaTable(P, Entries(z, P, px, py, w, h, F), E) end
        return ViaTable(P, E, Entries(z, P, px, py, w, h, F, true))
      end
      for _, L in ipairs(links) do
        for dir = 1, 2 do
          local ax, ay, bx, by = L[1], L[2], L[3], L[4]
          if dir == 2 then ax, ay, bx, by = bx, by, ax, ay end
          local d1 = Leg(Es, x1, y1, ax, ay)
          local d2 = d1 and Leg(Eg, x2, y2, bx, by, true)
          if d2 and (not res or d1 + L[5] + d2 < res) then res = d1 + L[5] + d2 end
        end
      end
    end
    if not res then
      ns.gridFails = ns.gridFails or {}
      if #ns.gridFails < 200 then ns.gridFails[#ns.gridFails + 1] = { z, x1, y1, x2, y2 } end
    end
  end
  zdCache[ck] = res or false
  return res
end

------------------------------------------------------------
-- 7. Pfeil in einer Zone: kuerzester Weg auf dem Netz (k1 schwacher PC, sonst k2), mit Zwischenpunkten.
-- Sicherer Weg (Einstellung, Standard an): Mobs neben den Kanten, die fuer dich nicht grau sind, kosten Umweg.
-- Er wird genommen, wenn er hoechstens 20 % laenger ist. Mit Reittier sind die Reitwege billiger.
------------------------------------------------------------
local function GrayLevel(L)
  if L <= 5 then return 0 end
  if L <= 39 then return L - floor(L / 10) - 5 end
  if L <= 59 then return L - floor(L / 5) - 1 end
  return L - 9
end
K.GrayLevel = GrayLevel
local function Faction()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  return (f == "Alliance") and "A" or "H"
end
-- 19.5 feindliche Hauptstaedte (Sascha 29.10.: als Horde fuehrte das Navi durch Sturmwind Richtung Eisenschmiede):
-- Netz Knoten in einer feindlichen Hauptstadt sind fuer Pfeil, Navi und den Zonen Graph gesperrt, ausser Start oder
-- Ziel liegt selbst in der Stadt. Stadt = Rechteck der Stadtkarte (ns.cityParent), knapp innen.
local CITY_FAC = { [1454] = "H", [1456] = "H", [1458] = "H", [1453] = "A", [1455] = "A", [1457] = "A" }
local CITY_EDGE = 0.02
local hcCache = {}
local function HostileCities(z)
  local fac = Faction()
  local key = (z or 0) .. fac
  local l = hcCache[key]
  if l then return l end
  l = {}
  for c, f in pairs(CITY_FAC) do
    if f ~= fac and ns.cityParent and ns.cityParent[c] == z then l[#l + 1] = c end
  end
  hcCache[key] = l
  return l
end
-- Punkt (Zone z, Zonen Koordinaten) in einer feindlichen Hauptstadt: Stadt Karte, sonst nil
function K.HostileCity(z, x, y)
  if not (z and x and y and ns.ToMap) then return nil end
  for _, c in ipairs(HostileCities(z)) do
    local u, v = ns.ToMap(z, x, y, c)
    if u and v and u > CITY_EDGE and u < 1 - CITY_EDGE and v > CITY_EDGE and v < 1 - CITY_EDGE then return c end
  end
end
-- 19.39 (Sascha 08:48, abs\stadt_pfeil): bist du in einer Hauptstadt (beide Fraktionen)? Stadt Karte oder nil.
-- Liste als Daten Feld ns.STADT_KARTEN (ein Daten Update darf sie ersetzen). m ist die Stadt selbst oder die Elternzone
-- mit Punkt im Stadt Rechteck (knapp innen, wie K.HostileCity)
ns.STADT_KARTEN = ns.STADT_KARTEN or { [1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true }
function K.InCity(m, x, y)
  local L = ns.STADT_KARTEN
  if not (m and type(L) == "table") then return nil end
  if L[m] then return m end
  if not (x and y and ns.ToMap and ns.cityParent) then return nil end
  for c in pairs(L) do
    if ns.cityParent[c] == m then
      local u, v = ns.ToMap(m, x, y, c)
      if u and v and u > CITY_EDGE and u < 1 - CITY_EDGE and v > CITY_EDGE and v < 1 - CITY_EDGE then return c end
    end
  end
end
-- geht die gerade Strecke durch eine feindliche Hauptstadt?
local function SegHostile(z, x1, y1, x2, y2)
  if #HostileCities(z) == 0 then return false end
  for k = 0, 24 do
    local t = k / 24
    if K.HostileCity(z, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t) then return true end
  end
  return false
end
K.SegHostile = SegHostile
-- gesperrte Netz Knoten einer Zone (oder false)
local function HostileSet(Q)
  local fac = Faction()
  if Q.hostFac == fac then return Q.host end
  local set, any = {}, false
  if #HostileCities(Q.ui) > 0 then
    for i = 1, Q.np do
      if K.HostileCity(Q.ui, Q.px[i], Q.py[i]) then set[i] = true; any = true end
    end
  end
  Q.hostFac, Q.host = fac, any and set or false
  return Q.host
end
local function PlayerLevel()
  local L = (ns.UnitLevel and ns.UnitLevel("player")) or (UnitLevel and UnitLevel("player")) or 1
  return tonumber(L) or 1
end
local function HasMount()
  if IsMounted and ns.Api.U(IsMounted) then return true end
  local db = ns.db
  return db and (db.mountSpeed or 0) > 8 and true or false
end
function K.SafeOn() return not (ns.db and ns.db.arrowSafe == false) end
-- 19.27: wie tief der Pfeil springen darf (Fallhoehe der Sprungkanten k4), nil = gar nicht. Schalter "Pfeil: runter
-- springen?" (Standard an), aus auf Hardcore, unter 60 % Leben nur kleine Spruenge, unter 30 % keine. Als Geist ohne
-- Fallschaden alle
local function Num(v) if ns.Plain then v = ns.Plain(v) end return type(v) == "number" and v or nil end
function K.JumpMax()
  local db = ns.db
  if db and db.arrowJump == false then return nil end
  if C_GameRules and C_GameRules.IsHardcoreActive then
    local ok, hc = pcall(C_GameRules.IsHardcoreActive)
    if ok and hc then return nil end
  end
  if UnitIsGhost and ns.Api.U(UnitIsGhost, "player") then return 99 end
  local hp = UnitHealth and Num(UnitHealth("player"))
  local mx = UnitHealthMax and Num(UnitHealthMax("player"))
  if not (hp and mx and mx > 0) then return 99 end
  local f = hp / mx
  -- 19.31 (Werkzeug Stand 61: steile Hänge werden Sprungkanten bis 69 Yards Fall): dazu die Grenze aus dem Fallschaden
  -- 1.12 (ab 14.57 Yards, 0.018 mal Hoehe minus 0.2426 vom Leben): nach dem Sprung bleibt mindestens ein Viertel Leben.
  -- Nie mehr als vorher erlaubt, in 5 Yards Stufen (sonst rechnet der Pfeil bei jedem Treffer neu)
  local cap = math.floor(((f - 0.25 + 0.2426) / 0.018) / 5) * 5
  if f >= JUMP_HP_ALL then return math.max(10, math.min(JUMP_TOP, cap)) end
  if f >= JUMP_HP_LOW then return math.max(10, math.min(JUMP_LOW, cap)) end
  return nil
end
-- 19.23: Einstellung "sicherer Weg", Fraktion und Grau Grenze fuer die Planung, alle 10 Sekunden neu (die Planung fragt
-- sehr oft). sig aendert sich nur, wenn sich etwas davon aendert (dann rechnen die gemerkten Strecken neu)
local planMode, planModeAt = nil, -999
function K.PlanMode()
  local now = GetTime and GetTime() or 0
  if planMode and now - planModeAt < 10 and now >= planModeAt then return planMode end
  planModeAt = now
  local safe, fac = K.SafeOn(), Faction()
  local gray = GrayLevel(PlayerLevel())
  local sig = (safe and ("s" .. fac .. gray)) or "f"
  if not (planMode and planMode.sig == sig) then planMode = { safe = safe, fac = fac, ts = "ts" .. fac, gray = gray, sig = sig } end
  return planMode
end

-- Binaerer Heap auf zwei Feldern (Schluessel, Knoten)
local function Heap()
  local hk, hv, n = {}, {}, 0
  local H = {}
  function H.push(k, v)
    n = n + 1
    local i = n
    while i > 1 do
      local p = floor(i / 2)
      if hk[p] <= k then break end
      hk[i], hv[i] = hk[p], hv[p]
      i = p
    end
    hk[i], hv[i] = k, v
  end
  function H.pop()
    if n == 0 then return nil end
    local tk, tv = hk[1], hv[1]
    local lk, lv = hk[n], hv[n]
    hk[n], hv[n] = nil, nil
    n = n - 1
    if n > 0 then
      local i = 1
      while true do
        local l = i * 2
        if l > n then break end
        local r = l + 1
        local m = (r <= n and hk[r] < hk[l]) and r or l
        if hk[m] >= lk then break end
        hk[i], hv[i] = hk[m], hv[m]
        i = m
      end
      hk[i], hv[i] = lk, lv
    end
    return tv, tk
  end
  function H.size() return n end
  function H.reset() n = 0 end
  return H
end
K.Heap = Heap

local function Adj(Q, md)
  Q.adj = Q.adj or {}
  local A = Q.adj[md]
  if A then return A end
  A = {}
  local E = Q.E[md]
  for i = 1, E.n do
    local a, b = E.a[i], E.b[i]
    local la, lb = A[a], A[b]
    if not la then la = {}; A[a] = la end
    if not lb then lb = {}; A[b] = lb end
    la[#la + 1] = i
    lb[#lb + 1] = i
  end
  Q.adj[md] = A
  return A
end
K.Adj = Adj
-- Mobs neben Kante i: zaehlende (nicht grau) mal Gewicht (Elite dreifach)
local function EdgeMobs(Q, md, i, fac, gray)
  local s = Q.g[md]
  if not s then return 0 end
  local D = DEC or Dec()
  local c = (i - 1) * 6 + ((fac == "A") and 4 or 1)
  local n, lv, el = D[byte(s, c) or 0], D[byte(s, c + 1) or 0], D[byte(s, c + 2) or 0]
  if not (n and n > 0 and lv) then return 0 end
  if lv <= gray then return 0 end
  return n + 2 * (el or 0)
end
-- Zusatz Kanten (Nummer negativ):
--  feste Verbindungen in der Zone zwischen den naechsten Knoten ihrer Enden (Aufzug, Tunnel)
--  Bruecken aus der Tabelle t: das Netz k1 / k2 hat Luecken, die Tabelle kennt den Weg (Werkzeug Stand 17: in Mulgore
--  ist die Haelfte der erreichbaren Paare im Netz getrennt). Zwei Prio 1 Knoten in verschiedenen Teilen des Netzes,
--  hoechstens BRIDGE_YD auseinander, deren Wegzeit fast die Luftlinie ist, bekommen eine gerade Kante.
local BRIDGE_YD, BRIDGE_F, BRIDGE_ADD = 600, 1.25, 30
local function VLinks(Q, md)
  Q.vl = Q.vl or {}
  local V = Q.vl[md]
  if V then return V end
  V = { list = {}, adj = {}, nb = 0, nk3 = 0 }
  local use = (md == 1) and function(i) return Q.pr[i] == 1 end or nil
  local w, h = Yards(Q.ui)
  local function Add(e)
    local i = #V.list + 1
    V.list[i] = e
    local la, lb = V.adj[e.a], V.adj[e.b]
    if not la then la = {}; V.adj[e.a] = la end
    if not lb then lb = {}; V.adj[e.b] = lb end
    la[#la + 1] = i
    lb[#lb + 1] = i
  end
  for _, L in ipairs(ZoneLinks(Q.ui)) do
    local na = Near(Q.bk, Q.px, Q.py, L[1], L[2], w, h, 1, use, NEAR_MAX)[1]
    local nb = Near(Q.bk, Q.px, Q.py, L[3], L[4], w, h, 1, use, NEAR_MAX)[1]
    if na and nb and na[1] ~= nb[1] then
      Add({ a = na[1], b = nb[1], m = na[2] + L[5] + nb[2], pa = { L[1], L[2] }, pb = { L[3], L[4] } })
    end
  end
  -- 19.2 Werkzeug Stand 27: Notkanten k3 { a, b, Meter, davon steil }, gerade Linie ueber einen kurzen Hang oder eine
  -- kleine Luecke. Unsicherer als k1 / k2, darum etwas teurer. Sie verbinden Netz Teile, bevor die Bruecken ueber t kommen.
  for _, e in ipairs(Q.k3 or EMPTY) do
    local a, b = e[1], e[2]
    if a and b and a ~= b and Q.px[a] and Q.px[b] and (md == 2 or (Q.pr[a] == 1 and Q.pr[b] == 1)) then
      local m = e[3] or 0
      Add({ a = a, b = b, m = m + K3_STEEP * (e[4] or 0) + K3_ADD, r = m, k3 = true })
      V.nk3 = V.nk3 + 1
    end
  end
  local P = K.Plan(Q.ui)
  if P and P.n > 1 then
    local par = {}
    local function Find(x)
      local r = x
      while par[r] do r = par[r] end
      while par[x] do local nx = par[x]; par[x] = r; x = nx end
      return r
    end
    local E = Q.E[md]
    for i = 1, E.n do local a, b = Find(E.a[i]), Find(E.b[i]); if a ~= b then par[a] = b end end
    for _, e in ipairs(V.list) do local a, b = Find(e.a), Find(e.b); if a ~= b then par[a] = b end end
    local tiN = {}
    for node, pos in pairs(P.pos) do tiN[pos] = node end
    local comp = {}
    for i = 1, P.n do comp[i] = Find(tiN[i]) end
    for i = 1, P.n do
      local ni, ci = tiN[i], comp[i]
      local xi, yi = Q.px[ni], Q.py[ni]
      for j = i + 1, P.n do
        if comp[j] ~= ci then
          local nj = tiN[j]
          local dx, dy = (Q.px[nj] - xi) * w, (Q.py[nj] - yi) * h
          local st = sqrt(dx * dx + dy * dy)
          if st <= BRIDGE_YD then
            local t = TVal(P.t, P.n, i, j)
            if t and t <= st * BRIDGE_F + BRIDGE_ADD then
              Add({ a = ni, b = nj, m = math.max(t, st) })
              V.nb = V.nb + 1
            end
          end
        end
      end
    end
  end
  -- 19.27: Sprungkanten k4 nur in der Richtung a (oben) nach b (unten), darum nur bei a eingetragen. Erst nach den
  -- Bruecken (die Bruecken sollen nur Wege in beide Richtungen als verbunden zaehlen)
  V.nk4 = 0
  for _, e in ipairs(Q.k4 or EMPTY) do
    local a, b = e[1], e[2]
    if a and b and a ~= b and Q.px[a] and Q.px[b] and (md == 2 or (Q.pr[a] == 1 and Q.pr[b] == 1)) then
      local m = e[3] or 0
      local i = #V.list + 1
      -- 19.31 (Format 2): Zwischenpunkte der Kante, damit der Pfeil dem Weg folgt und nicht der geraden Linie
      local pts
      if #e >= 6 then
        pts = {}
        for k = 5, #e - 1, 2 do if e[k] and e[k + 1] then pts[#pts + 1] = { e[k], e[k + 1] } end end
        if #pts == 0 then pts = nil end
      end
      V.list[i] = { a = a, b = b, m = m + K4_ADD, r = m, k4 = e[4] or 0, pts = pts }
      local la = V.adj[a]
      if not la then la = {}; V.adj[a] = la end
      la[#la + 1] = i
      V.nk4 = V.nk4 + 1
    end
  end
  Q.vl[md] = V
  return V
end
K.VLinks = VLinks
-- Dijkstra von den Einstiegen A zu den Ausstiegen B. safe: Mob Umweg. Gibt Ende, Vorgaenger Kanten, Strecke (echt)
local function Search(Q, md, A, B, opt)
  local E = Q.E[md]
  local adj = Adj(Q, md)
  local V = VLinks(Q, md)
  local fac, gray = opt.fac, opt.gray
  local ride = opt.mount and Q.ride[fac]
  local rset = ride and ((md == 1) and ride[1] or ride[2])
  local swx = opt.swim or 0
  local jump = opt.jump
  local dist, real, prevE = {}, {}, {}
  local blk = opt.block
  local H = Heap()
  for _, a in ipairs(A) do
    local i = a[1]
    if not (blk and blk[i]) and (not dist[i] or a[2] < dist[i]) then dist[i] = a[2]; real[i] = a[3] or a[2]; prevE[i] = false; H.push(a[2], i) end
  end
  local exit = {}
  for _, b in ipairs(B) do exit[b[1]] = b end
  local best, bestN = huge, nil
  local done = {}
  while H.size() > 0 do
    local u, du = H.pop()
    if du >= best then break end
    if not done[u] then
      done[u] = true
      local x = exit[u]
      if x and du + x[2] < best then best, bestN = du + x[2], u end
      for _, ei in ipairs(adj[u] or EMPTY) do
        local v = (E.a[ei] == u) and E.b[ei] or E.a[ei]
        if not done[v] and (md == 2 or Q.pr[v] == 1) and not (blk and blk[v]) then
          local m = E.m[ei]
          local c = m
          -- 19.22: geschwommene Meter teurer (gleiches Gewicht wie in der Planung)
          local sw = E.sw[ei]
          if sw and sw > 0 and swx > 0 then c = c + sw * swx end
          if opt.safe then
            local mobs = EdgeMobs(Q, md, ei, fac, gray)
            if mobs > 0 then c = c + MOB_PEN * mobs end
          end
          if rset then
            local hit = (md == 1) and rset[ei] or rset[PairKey(E.a[ei], E.b[ei])]
            if hit then c = c * RIDE_MUL end
          end
          local nrs = Q.nrset and Q.nrset[md]
          if nrs and nrs[ei] then c = c * Q.nrf end
          local nd = du + c
          if not dist[v] or nd < dist[v] then
            dist[v] = nd
            real[v] = real[u] + m
            prevE[v] = ei
            H.push(nd, v)
          end
        end
      end
      for _, vi in ipairs(V.adj[u] or EMPTY) do
        local L = V.list[vi]
        local v = (L.a == u) and L.b or L.a
        local nd = du + L.m
        -- 19.27: Sprungkante nur, wenn Springen erlaubt ist und die Hoehe passt
        local okJ = not L.k4 or (jump and L.k4 <= jump)
        if okJ and not done[v] and not (blk and blk[v]) and (not dist[v] or nd < dist[v]) then
          dist[v] = nd
          real[v] = real[u] + (L.r or L.m)
          prevE[v] = -vi
          H.push(nd, v)
        end
      end
    end
  end
  if not bestN then return nil end
  return bestN, prevE, real[bestN] + exit[bestN][3]
end
-- Punkte einer Kante von Knoten u aus (ohne u, mit dem anderen Ende)
local function EdgePts(Q, md, ei, u, out)
  if ei < 0 then
    local L = Q.vl[md].list[-ei]
    local fromA = (L.a == u)
    local p1, p2, v = L.pa, L.pb, L.b
    if not fromA then p1, p2, v = L.pb, L.pa, L.a end
    if p1 then out[#out + 1] = { p1[1], p1[2] } end
    if p2 then out[#out + 1] = { p2[1], p2[2] } end
    -- 19.31 (Format 2): Zwischenpunkte einer Sprungkante, in Richtung der Kante
    if L.pts then
      if fromA then for k = 1, #L.pts do out[#out + 1] = { L.pts[k][1], L.pts[k][2] } end
      else for k = #L.pts, 1, -1 do out[#out + 1] = { L.pts[k][1], L.pts[k][2] } end end
    end
    -- 19.27: Landepunkt einer Sprungkante merken (Pfeil sagt "hier runter springen"), Wert = Fallhoehe
    out[#out + 1] = { Q.px[v], Q.py[v], jump = L.k4 }
    return v
  end
  local E = Q.E[md]
  local e = E.raw[ei]
  local off = E.off[ei]
  local last = #e
  local toB = (E.a[ei] == u)
  local v = toB and E.b[ei] or E.a[ei]
  if toB then
    for p = off, last - 1, 2 do out[#out + 1] = { e[p], e[p + 1] } end
  else
    for p = last - 1, off, -2 do out[#out + 1] = { e[p], e[p + 1] } end
  end
  out[#out + 1] = { Q.px[v], Q.py[v] }
  return v
end
local function Trace(Q, md, endN, prevE)
  local chain = {}
  local u = endN
  for _ = 1, 100000 do
    local ei = prevE[u]
    if not ei then break end
    table.insert(chain, 1, ei)
    if ei < 0 then
      local L = Q.vl[md].list[-ei]
      u = (L.a == u) and L.b or L.a
    else
      u = (Q.E[md].a[ei] == u) and Q.E[md].b[ei] or Q.E[md].a[ei]
    end
  end
  return u, chain
end

-- Notweg nur ueber die Tabelle t (wenn das Netz keinen Weg hat): von Prio 1 Knoten zu Prio 1 Knoten, immer zu dem, ueber
-- den der Rest am kuerzesten ist, und nur in fast gerader Linie (Wegzeit fast die Luftlinie). Punkte, Laenge oder nil
local function Greedy(ui, P, fx, fy, tx, ty, w, h, F)
  local Bt = Near(P.bk, P.nx, P.ny, tx, ty, w, h, NEAR_K, nil, NEAR_MAX)
  if #Bt == 0 then Bt = Near(P.bk, P.nx, P.ny, tx, ty, w, h, 2) end
  if #Bt == 0 then return nil end
  for _, b in ipairs(Bt) do if not LineFree(ui, P.nx[b[1]], P.ny[b[1]], tx, ty, F) then b[2] = b[2] * OFF_BAD + 30 end end
  local restC = {}
  local function Rest(pos)
    local r = restC[pos]
    if r ~= nil then return r or nil end
    for _, b in ipairs(Bt) do
      local v = TVal(P.t, P.n, pos, b[1])
      if v then v = v + b[2]; if not r or v < r then r = v end end
    end
    restC[pos] = r or false
    return r
  end
  local pts, len = { { fx, fy } }, 0
  local cx, cy, cur = fx, fy, nil
  local curRest
  for _ = 1, 80 do
    local dGoal = sqrt(((tx - cx) * w) ^ 2 + ((ty - cy) * h) ^ 2)
    if dGoal < 450 and LineFree(ui, cx, cy, tx, ty, F) then break end
    local cand = Near(P.bk, P.nx, P.ny, cx, cy, w, h, 14, nil, 800)
    local best, bv, br
    local loose, lv, lr
    for _, c in ipairs(cand) do
      local pos = c[1]
      if pos ~= cur then
        local r = Rest(pos)
        if r and (not curRest or r < curRest - 1) then
          local hop
          if cur then hop = TVal(P.t, P.n, cur, pos)
          elseif LineFree(ui, cx, cy, P.nx[pos], P.ny[pos], F) then hop = c[2] end
          if hop then
            local v = hop + r
            if hop <= c[2] * BRIDGE_F + BRIDGE_ADD then
              if not bv or v < bv - 1 or (v < bv + 1 and r < br) then best, bv, br = c, v, r end
            elseif not lv or v < lv then loose, lv, lr = c, v, r end
          end
        end
      end
    end
    if not best then best, bv, br = loose, lv, lr end
    if not best then
      -- vom Start aus kein freier Knoten: den naechsten nehmen, der zum Ziel fuehrt
      if cur then return nil end
      for _, c in ipairs(cand) do local r = Rest(c[1]); if r then best, br = c, r; break end end
      if not best then return nil end
    end
    cur = best[1]
    local nx, ny = P.nx[cur], P.ny[cur]
    len = len + sqrt(((nx - cx) * w) ^ 2 + ((ny - cy) * h) ^ 2)
    cx, cy, curRest = nx, ny, br
    pts[#pts + 1] = { cx, cy }
    for _, b in ipairs(Bt) do if b[1] == cur then curRest = nil; break end end
    if not curRest then break end
  end
  len = len + sqrt(((tx - cx) * w) ^ 2 + ((ty - cy) * h) ^ 2)
  pts[#pts + 1] = { tx, ty }
  return pts, len
end

-- Schleifen aus einem Weg nehmen: kommt ein spaeterer Punkt wieder an einem frueheren vorbei (unter 6 Yards), faellt
-- das Stueck dazwischen weg (Kanten mit Zwischenpunkten koennen sich ueberlappen)
function K.NoLoops(pts, w, h)
  local out = {}
  for _, p in ipairs(pts) do
    local cut
    for k = 1, #out do
      local q = out[k]
      if ((p[1] - q[1]) * w) ^ 2 + ((p[2] - q[2]) * h) ^ 2 < 36 then cut = k; break end
    end
    if cut then
      for k = #out, cut + 1, -1 do out[k] = nil end
      out[cut] = p
    else
      out[#out + 1] = p
    end
  end
  -- Start und Ziel bleiben
  if out[1] ~= pts[1] then table.insert(out, 1, pts[1]) end
  if out[#out] ~= pts[#pts] then out[#out + 1] = pts[#pts] end
  return out
end

local routeCache, routeN = {}, 0
-- 19.9 (Code Pruefung): jeder Eintrag zaehlt (auch Notwege und Fehlschlaege), alte nach 30 Sekunden weg
local function RouteStore(ck, e, now)
  routeN = routeN + 1
  if routeN > 80 then
    routeN = 0
    for k, x in pairs(routeCache) do if now - x.t > 30 then routeCache[k] = nil else routeN = routeN + 1 end end
  end
  routeCache[ck] = e
end
-- Weg von f nach t in Zone ui (Zone, nicht Stadt): Punkte { {x, y}, ... } mit Start und Ziel, Laenge Yards, Info
function K.Route(ui, fx, fy, tx, ty)
  local Q = K.Net(ui)
  if not Q then return nil end
  local md = Slow() and 1 or 2
  if Q.E[md].n == 0 then md = 1 end
  if Q.E[md].n == 0 then return nil end
  local w, h = Yards(ui)
  local F = ns.Felder(ui)
  local safe = K.SafeOn()
  local mount = HasMount()
  local L = PlayerLevel()
  local swim = K.SwimF()
  local jump = K.JumpMax()
  local ck = ("%d:%d:%d:%.3f:%.3f:%d:%s:%s:%d:%d:%.1f:%d"):format(ui, Key(Cell(fx, fy)), md, tx, ty, ns.blockRev or 0, safe and 1 or 0, mount and 1 or 0, L, Q.np, swim, jump or 0)
  local now = GetTime and GetTime() or 0
  local c = routeCache[ck]
  if c and now - c.t < 30 then return c.pts, c.len, c.info end
  local use = (md == 1) and function(i) return Q.pr[i] == 1 end or nil
  -- 19.9: die Zielseite bleibt hier bewusst Ziel > Knoten (wie bis 19.8). Mit Knoten > Ziel sprang der Pfeil an einem
  -- Uebergang auf einer Kante zwischen zwei Uebergaengen hin und her (t10 Era Feralas > Un'Goro, 267 > 266 von 279).
  -- In der Planung (ZoneDist, FromPoint) gilt die Richtung, dort aendert sie nur die Schaetzung.
  local function Ends(x, y, toPt)
    local list = Near(Q.bk, Q.px, Q.py, x, y, w, h, NEAR_K, use, NEAR_MAX)
    if #list == 0 then list = Near(Q.bk, Q.px, Q.py, x, y, w, h, 2, use) end
    local out = {}
    for _, e in ipairs(list) do
      local d = e[2]
      local cost = d
      local nx, ny = Q.px[e[1]], Q.py[e[1]]
      local free
      if toPt then free = LineFree(ui, nx, ny, x, y, F) else free = LineFree(ui, x, y, nx, ny, F) end
      if not free then cost = d * OFF_BAD + 30 end
      out[#out + 1] = { e[1], cost, d }
    end
    return out
  end
  local A, B = Ends(fx, fy), Ends(tx, ty)
  local opt = { fac = Faction(), gray = GrayLevel(L), mount = mount, swim = swim, jump = jump }
  -- 19.5: feindliche Hauptstadt sperren (nicht, wenn Start oder Ziel drin liegt)
  local blk = HostileSet(Q)
  if blk and (K.HostileCity(ui, fx, fy) or K.HostileCity(ui, tx, ty)) then blk = nil end
  opt.block = blk or nil
  local endN, prevE, len
  if #A > 0 and #B > 0 then endN, prevE, len = Search(Q, md, A, B, opt) end
  -- ohne Weg um die Stadt herum: lieber durch die Stadt als quer uebers Gelaende
  if not endN and opt.block and #A > 0 and #B > 0 then
    opt.block = nil
    endN, prevE, len = Search(Q, md, A, B, opt)
  end
  if not endN then
    -- Notweg ueber die Tabelle
    local P = K.Plan(ui)
    local gp, gl
    if P and P.n > 1 then gp, gl = Greedy(ui, P, fx, fy, tx, ty, w, h, F) end
    local gi = gp and { md = md, greedy = true } or nil
    RouteStore(ck, { t = now, pts = gp, len = gl, info = gi }, now)
    return gp, gl, gi
  end
  local info = { md = md }
  if safe and Q.g[md] then
    opt.safe = true
    local e2, p2, l2 = Search(Q, md, A, B, opt)
    if e2 and l2 <= len * SAFE_MAX then
      if l2 > len + 1 then info.safe = true end
      endN, prevE, len = e2, p2, l2
    end
  end
  local first, chain = Trace(Q, md, endN, prevE)
  local pts = { { fx, fy }, { Q.px[first], Q.py[first] } }
  local u = first
  for _, ei in ipairs(chain) do
    if ei < 0 and Q.vl[md].list[-ei].k4 then info.jump = (info.jump or 0) + 1 end
    u = EdgePts(Q, md, ei, u, pts)
  end
  pts[#pts + 1] = { tx, ty }
  pts = K.NoLoops(pts, w, h)
  -- Laenge der Strecke vom Start bis zum ersten Knoten und vom letzten bis zum Ziel steckt in len
  RouteStore(ck, { t = now, pts = pts, len = len, info = info }, now)
  return pts, len, info
end

-- 19.12 (Sascha): Navi Ziel, das zu Fuss nicht erreichbar ist (im Berg, im tiefen Wasser, abgeschlossen von Berg und
-- Wasser). Von allen Feldern mit Wegknoten aus ueber begehbare Felder fluten (Klippen und Hang zaehlen als begehbar,
-- damit nichts faelschlich als unerreichbar gilt). Erreicht die Flut das Ziel nicht: naechstes erreichtes Feld.
-- nil = erreichbar, sonst x, y (Mitte des Feldes), Abstand in Yards, Grund ("berg", "wasser" oder "abseits")
local reachCache = {}
function K.ReachPoint(ui, x, y)
  if not (ui and x and y) or x ~= x or y ~= y then return nil end
  local okN, Q = pcall(K.Net, ui)
  local F = ns.Felder and ns.Felder(ui)
  if not (okN and Q and Q.np and Q.np > 0 and F) then return nil end
  local B, Wt = F.block or EMPTY, F.water or EMPTY
  local tx, ty = Cell(x, y)
  local tk = Key(tx, ty)
  local ck = ui .. ":" .. tk .. ":" .. (ns.blockRev or 0)
  local c = reachCache[ck]
  if c then if c.ok then return nil end return c.x, c.y, c.d, c.why end
  local function Walk(k) return not B[k] and Wt[k] ~= 2 end
  -- 19.13: ein Netz Knoten ganz nah am Ziel (Bruecke, Gebaeude, Stadt auf dem Berg): erreichbar, auch wenn das Feld
  -- im Raster gesperrt ist
  do
    local w0, h0 = Yards(ui)
    for i = 1, Q.np do
      if ((Q.px[i] - x) * w0) ^ 2 + ((Q.py[i] - y) * h0) ^ 2 < 900 then reachCache[ck] = { ok = true }; return nil end
    end
  end
  local seen, queue, qh = {}, {}, 1
  for i = 1, Q.np do
    local k = Key(Cell(Q.px[i], Q.py[i]))
    if not seen[k] and Walk(k) then seen[k] = true; queue[#queue + 1] = k end
  end
  while qh <= #queue and not seen[tk] do
    local k = queue[qh]; qh = qh + 1
    local cx, cy = k % 100, floor(k / 100)
    for dy = -1, 1 do
      for dx = -1, 1 do
        if dx ~= 0 or dy ~= 0 then
          local nx, ny = cx + dx, cy + dy
          if nx >= 0 and nx < N and ny >= 0 and ny < N then
            local nk = Key(nx, ny)
            -- schraeg nur, wenn nicht beide Ecken gesperrt sind
            if not seen[nk] and Walk(nk) and (dx == 0 or dy == 0 or Walk(Key(cx + dx, cy)) or Walk(Key(cx, cy + dy))) then
              seen[nk] = true; queue[#queue + 1] = nk
            end
          end
        end
      end
    end
  end
  if seen[tk] then reachCache[ck] = { ok = true }; return nil end
  -- naechstes erreichte Feld (in Yards)
  local w, h = Yards(ui)
  local best, bd
  for k in pairs(seen) do
    local cx, cy = k % 100, floor(k / 100)
    local d = ((cx - tx) * CELL * w) ^ 2 + ((cy - ty) * CELL * h) ^ 2
    if not bd or d < bd then best, bd = k, d end
  end
  if not best then reachCache[ck] = { ok = true }; return nil end
  local why = B[tk] and "berg" or (Wt[tk] == 2 and "wasser") or "abseits"
  local bx, by = (best % 100 + 0.5) * CELL, (floor(best / 100) + 0.5) * CELL
  c = { x = bx, y = by, d = math.sqrt(bd), why = why }
  reachCache[ck] = c
  return c.x, c.y, c.d, c.why
end

-- 20.3x (K 14:13, Ruckler seit 20.3v): schnelle Ja/Nein Frage fuer viele Punkte (Quest Fundorte). Je Zone EINMAL von
-- allen Netz Knoten aus fluten (wie ReachPoint) und das Ergebnis merken, danach nur noch nachschauen. Erreichbar ist ein
-- Feld, das die Flut erreicht, ein Feld mit Netz Knoten, Wasser, oder ein Nachbarfeld davon (etwa 50 yd). Ohne Daten: ja
local reachSet = {}
function K.ReachOK(ui, x, y)
  if not (ui and x and y) or x ~= x or y ~= y then return true end
  local ck = ui .. ":" .. (ns.blockRev or 0)
  local S = reachSet[ck]
  if S == nil then
    local okN, Q = pcall(K.Net, ui)
    local F = ns.Felder and ns.Felder(ui)
    if not (okN and Q and Q.np and Q.np > 0 and F) then reachSet[ck] = false; return true end
    local B, Wt = F.block or EMPTY, F.water or EMPTY
    local function Walk(k) return not B[k] and Wt[k] ~= 2 end
    local ok, queue, qh = {}, {}, 1
    for i = 1, Q.np do
      local k = Key(Cell(Q.px[i], Q.py[i]))
      if not ok[k] then
        ok[k] = true
        if Walk(k) then queue[#queue + 1] = k end
      end
    end
    while qh <= #queue do
      local k = queue[qh]; qh = qh + 1
      local cx, cy = k % 100, floor(k / 100)
      for dy = -1, 1 do
        for dx = -1, 1 do
          if dx ~= 0 or dy ~= 0 then
            local nx, ny = cx + dx, cy + dy
            if nx >= 0 and nx < N and ny >= 0 and ny < N then
              local nk = Key(nx, ny)
              if not ok[nk] and Walk(nk) and (dx == 0 or dy == 0 or Walk(Key(cx + dx, cy)) or Walk(Key(cx, cy + dy))) then
                ok[nk] = true; queue[#queue + 1] = nk
              end
            end
          end
        end
      end
    end
    S = { ok = ok, Wt = Wt }
    reachSet[ck] = S
  end
  if not S then return true end
  local tx, ty = Cell(x, y)
  if S.Wt[Key(tx, ty)] == 2 then return true end
  for dy = -1, 1 do
    for dx = -1, 1 do
      local nx, ny = tx + dx, ty + dy
      if nx >= 0 and nx < N and ny >= 0 and ny < N and S.ok[Key(nx, ny)] then return true end
    end
  end
  return false
end

------------------------------------------------------------
-- 8. Weg ueber Zonen (Planung und Pfeil): Graph pro Kontinent aus den Uebergaengen (fuer die Planung zusammengelegt,
-- wenn sie naeher als CLUSTER Yards beieinander liegen), festen Verbindungen und selbst gelaufenen Uebergaengen.
-- Strecken in einer Zone aus der Tabelle t. Kuerzeste Wege zwischen allen Knoten einmal pro Kontinent (im Hintergrund).
------------------------------------------------------------
local contCache = {}
local function ContMap(ui)
  if not ui then return nil end
  local c = contCache[ui]
  if c ~= nil then return c or nil end
  local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(ui)
  for _ = 1, 6 do
    if not info then break end
    if info.mapType == 2 then c = info.mapID; break end
    if not info.parentMapID or info.parentMapID == 0 then break end
    info = C_Map.GetMapInfo(info.parentMapID)
  end
  contCache[ui] = c or false
  return c
end
K.ContMap = ContMap
local XG = {}
local xgenHook
function K.XGen() if xgenHook then xgenHook() end end
-- selbst gelaufene Uebergaenge, die die Karte nicht kennt (kein Uebergang der Karte zwischen denselben Zonen naeher als
-- 150 Yards): nur die kommen in den Zonen Graph. Liste { za, ax, ay, zb, bx, by }
local NOVEL_YD = 150
local function WalkedNovel()
  local db = ns.db
  local out = {}
  for a, tbl in pairs(db and db.cross or EMPTY) do
    for b, list in pairs(tbl) do
      local za, zb = Parent(a), Parent(b)
      if za ~= zb and K.HasZone(za) and K.HasZone(zb) then
        local P = K.Plan(za)
        local w, h = Yards(za)
        for _, c in ipairs(list) do
          local ax, ay = c[1], c[2]
          if za ~= a and ns.ToMap then ax, ay = ns.ToMap(a, c[1], c[2], za) end
          local bx, by
          if ax and ns.ToMapLoose then bx, by = ns.ToMapLoose(za, ax, ay, zb) end
          if bx then
            local near = false
            for _, ps in ipairs(P and P.pass or EMPTY) do
              if Parent(ps.z2) == zb and sqrt(((ps.x - ax) * w) ^ 2 + ((ps.y - ay) * h) ^ 2) < NOVEL_YD then near = true; break end
            end
            if not near then out[#out + 1] = { za, ax, ay, zb, bx, by } end
          end
        end
      end
    end
  end
  return out
end
-- Stand des Zonen Graphen: neu rechnen nur bei neuen unbekannten Uebergaengen oder "schwacher PC" an/aus
local xrv = { cr = -1 }
local function XRev()
  local db = ns.db
  local cr = db and db.crossRev or 0
  local sl = Slow()
  if xrv.cr ~= cr then
    xrv.cr = cr
    local ok, l = pcall(WalkedNovel)
    xrv.novel = ok and l or {}
    xrv.n = #xrv.novel
  end
  -- neue unbekannte Uebergaenge hoechstens alle 10 Minuten einrechnen (der Graph braucht etwa eine Sekunde)
  local now = GetTime and GetTime() or 0
  local sf = K.SwimF() .. ":" .. K.PlanMode().sig
  if xrv.sl ~= sl or xrv.sf ~= sf or (xrv.ns ~= xrv.n and (not xrv.t or now - xrv.t > 600)) then
    xrv.sl, xrv.ns, xrv.t, xrv.sf = sl, xrv.n, now, sf
    xrv.str = tostring(xrv.n) .. ":" .. (sl and "s" or "f") .. ":" .. sf
  end
  return xrv.str
end
-- Punkt (Zone z, x, y) an die Tabelle haengen: naechster Prio 1 Knoten und Abstand
local function Anchor(z, x, y)
  local P = K.Plan(z)
  if not (P and P.n > 0) then return nil end
  local w, h = Yards(z)
  local l = Near(P.bk, P.nx, P.ny, x, y, w, h, 1)
  if not l[1] then return nil end
  return { z = z, x = x, y = y, pos = l[1][1], off = l[1][2] }
end
-- Strecke zwischen zwei angehaengten Punkten in derselben Zone
local function AnchorDist(a, b)
  if a.z ~= b.z then return nil end
  local P = K.Plan(a.z)
  local v = PVal(P, a.pos, b.pos)
  if not v then return nil end
  return v + a.off + b.off
end

-- 19.5: Strecken zwischen den Uebergaengen einer Zone auf dem Netz, Knoten in der feindlichen Hauptstadt gesperrt.
-- rows[ia][ib] (Yards) oder nil, wenn kein Weg um die Stadt herum geht. nil ganz: keine Sperre noetig / kein Netz.
local function BlockedRows(z, list)
  local P = K.Plan(z)
  local Q = P and K.Net(z)
  if not Q then return nil end
  local blk = HostileSet(Q)
  if not blk then return nil end
  local md = (Slow() or Q.E[2].n == 0) and 1 or 2
  local E, adj = Q.E[md], Adj(Q, md)
  -- 19.9 (Code Pruefung): auch die Zusatz Kanten (Aufzug, Tunnel, k3, Bruecken ueber t) wie in Search, sonst fehlt der
  -- Weg um die Stadt, wenn das Netz dort eine Luecke hat
  local V = VLinks(Q, md)
  local tiN = {}
  for node, pos in pairs(P.pos) do tiN[pos] = node end
  local rows = {}
  local H = Heap()
  for ia, u in ipairs(list) do
    local au = u.at[z]
    local src = au and tiN[au.pos]
    local row = {}
    rows[ia] = row
    if src and not blk[src] then
      -- 20.3: dist = Kosten fuer die Wahl (graue Kanten mal faktor), rl = echte Laenge fuer die Zeit der Planung
      local dist, done, rl = { [src] = 0 }, {}, { [src] = 0 }
      H.reset()
      H.push(0, src)
      while H.size() > 0 do
        local x, dx = H.pop()
        if not done[x] then
          done[x] = true
          for _, ei in ipairs(adj[x] or EMPTY) do
            local y = (E.a[ei] == x) and E.b[ei] or E.a[ei]
            if not done[y] and not blk[y] and (md == 2 or Q.pr[y] == 1) then
              local nd = dx + E.m[ei] * ((Q.nrset and Q.nrset[md] and Q.nrset[md][ei]) and Q.nrf or 1)
              if not dist[y] or nd < dist[y] then dist[y] = nd; rl[y] = rl[x] + E.m[ei]; H.push(nd, y) end
            end
          end
          for _, vi in ipairs(V.adj[x] or EMPTY) do
            local e = V.list[vi]
            local y = (e.a == x) and e.b or e.a
            -- 19.27: Sprungkanten nur fuer den Pfeil (je nach Leben), nicht in der Planung
            if not e.k4 and not done[y] and not blk[y] then
              local nd = dx + e.m
              if not dist[y] or nd < dist[y] then dist[y] = nd; rl[y] = rl[x] + e.m; H.push(nd, y) end
            end
          end
        end
      end
      for ib, v in ipairs(list) do
        local av = v.at[z]
        local t = av and tiN[av.pos]
        if t and dist[t] then row[ib] = (rl[t] or dist[t]) + au.off + av.off end
      end
    end
  end
  return rows
end

local function XBuild(cont, Tick)
  local zones, inCont = {}, {}
  for _, z in ipairs(K.Zones()) do
    if ContMap(z) == cont then zones[#zones + 1] = z; inCont[z] = true end
  end
  local slow = Slow()
  -- 1. Uebergaenge sammeln (jede Zone traegt sie ein, einmal pro Paar und Stelle)
  local seen, byPair, lifts = {}, {}, {}
  for _, z in ipairs(zones) do
    local P = K.Plan(z)
    for _, ps in ipairs(P and P.pass or EMPTY) do
      local z2 = Parent(ps.z2)
      if inCont[z2] and z2 ~= z and not (slow and ps.prio == 2) then
        local a = (z < z2) and ("%d:%.4f:%.4f"):format(z, ps.x, ps.y) or ("%d:%.4f:%.4f"):format(z2, ps.x2, ps.y2)
        if not seen[a] then
          seen[a] = true
          local A1, A2 = Anchor(z, ps.x, ps.y), Anchor(z2, ps.x2, ps.y2)
          -- 19.25: Uebergang mit fester Zeit (Aufzug, 9 Werte): zwei Enden mit fester Strecke wie eine feste Verbindung
          if A1 and A2 and ps.sec then
            lifts[#lifts + 1] = { z = z, z2 = z2, A1 = A1, A2 = A2, d = ps.sec * LIFT_SPEED, est = ps.est }
          elseif A1 and A2 then
            local pk = PairKey(z, z2)
            byPair[pk] = byPair[pk] or {}
            table.insert(byPair[pk], { [z] = A1, [z2] = A2, prio = ps.prio, src = "pass" })
          end
        end
      end
      if Tick then Tick() end
    end
  end
  -- selbst gelaufene Uebergaenge, die die Karte nicht kennt (gelaufene Wege gehen vor)
  XRev()
  for _, c in ipairs(xrv.novel or EMPTY) do
    local za, zb = c[1], c[4]
    if inCont[za] and inCont[zb] then
      local A1, A2 = Anchor(za, c[2], c[3]), Anchor(zb, c[5], c[6])
      if A1 and A2 then
        local pk = PairKey(za, zb)
        byPair[pk] = byPair[pk] or {}
        table.insert(byPair[pk], { [za] = A1, [zb] = A2, prio = 1, src = "walk" })
      end
    end
  end
  -- 2. zusammenlegen: pro Zonenpaar, beide Seiten naeher als CLUSTER
  local nodes, byZone = {}, {}
  local function Add(nd)
    nd.id = #nodes + 1
    nodes[nd.id] = nd
    for z in pairs(nd.at) do byZone[z] = byZone[z] or {}; table.insert(byZone[z], nd) end
    return nd
  end
  for pk, list in pairs(byPair) do
    local z1, z2 = floor(pk / 100000), pk % 100000
    local reps = {}
    for _, ps in ipairs(list) do
      local hit
      for _, r in ipairs(reps) do
        local d1 = AnchorDist(r.at[z1], ps[z1])
        local d2 = d1 and d1 <= CLUSTER and AnchorDist(r.at[z2], ps[z2])
        if d2 and d2 <= CLUSTER then hit = r; break end
      end
      if hit then
        table.insert(hit.members, ps)
      else
        reps[#reps + 1] = Add({ at = { [z1] = ps[z1], [z2] = ps[z2] }, members = { ps }, src = ps.src, z1 = z1, z2 = z2 })
      end
    end
    if Tick then Tick() end
  end
  -- 3. feste Verbindungen von Hand (Tunnel, Bruecke, Aufzug): zwei Knoten mit fester Strecke
  local fixed = {}
  for _, L in ipairs(lifts) do
    local na = Add({ at = { [L.z] = L.A1 }, members = {}, src = "link", est = L.est, lift = true })
    local nb = Add({ at = { [L.z2] = L.A2 }, members = {}, src = "link", est = L.est, lift = true })
    na.link, nb.link = nb.id, na.id
    fixed[#fixed + 1] = { na.id, nb.id, L.d }
  end
  for xi, h in ipairs(ns.PAINT_XLINK or EMPTY) do
    local Pz = K.Plan(Parent(h[1]))
    -- 19.25: hat das Netz die Verbindung schon als Kante (Werkzeug ab Stand 50), nicht nochmal
    if not (slow and h[7] == 2) and not (Pz and Pz.xdup and Pz.xdup[xi]) then
      -- 19.25: auf Forever umgerechnet wie die anderen gemalten Daten (XLinkEnds)
      local za, ax, ay, zb, bx, by = XLinkEnds(h)
      local A1, A2 = ax and inCont[za] and Anchor(za, ax, ay), bx and inCont[zb] and Anchor(zb, bx, by)
      local d = A1 and A2 and ns.WorldDistXY and ns.WorldDistXY(za, ax, ay, zb, bx, by)
      if d then
        local na = Add({ at = { [za] = A1 }, members = {}, src = "link" })
        local nb = Add({ at = { [zb] = A2 }, members = {}, src = "link" })
        na.link, nb.link = nb.id, na.id
        fixed[#fixed + 1] = { na.id, nb.id, d * XLINK }
      end
    end
  end
  -- 4. Kanten: in jeder Zone zwischen allen Knoten (Tabelle), dazu die festen Verbindungen
  local adj = {}
  for i = 1, #nodes do adj[i] = {} end
  local function Edge(u, v, d)
    local au, av = adj[u], adj[v]
    if not au[v] or d < au[v] then au[v] = d; av[u] = d end
  end
  for z, list in pairs(byZone) do
    -- 19.5: Zone mit feindlicher Hauptstadt: Strecken ueber das Netz ohne die Stadt (statt Tabelle t)
    local rows = (#HostileCities(z) > 0) and BlockedRows(z, list) or nil
    for ia = 1, #list do
      local u = list[ia]
      for ib = ia + 1, #list do
        local v = list[ib]
        local d = AnchorDist(u.at[z], v.at[z])
        -- nur Strecken, die auch die Tabelle t kennt (sonst passt der Graph nicht zum Pfeil in der Zone), mit Sperre
        -- mindestens so lang wie ohne
        if d and rows then
          local r = rows[ia] and rows[ia][ib]
          d = r and math.max(r, d) or nil
        end
        if d then Edge(u.id, v.id, d) end
      end
      if Tick then Tick() end
    end
  end
  for _, f in ipairs(fixed) do Edge(f[1], f[2], f[3]) end
  -- 5. kuerzeste Wege zwischen allen Knoten, pro Knoten eine Zeile als Text (je 2 Zeichen mal 5 Yards wie die Tabelle t,
  -- "~~" nicht erreichbar): spart viel Speicher (ein Kontinent hat ueber 100 000 Paare)
  local nn = #nodes
  local D = {}
  local E = Enc()
  local UN = E[89] .. E[89]
  -- Nachbarn als Felder (schneller als pairs), Tabellen fuer alle Quellen wiederverwenden (wenig Muell fuer den GC)
  local AV, AW = {}, {}
  for u = 1, nn do
    local av, aw = {}, {}
    for v, w in pairs(adj[u]) do av[#av + 1] = v; aw[#aw + 1] = w end
    AV[u], AW[u] = av, aw
  end
  local dist, mark, fin = {}, {}, {}
  local H = Heap()
  local row = {}
  for s = 1, nn do
    H.reset()
    mark[s], dist[s] = s, 0
    H.push(0, s)
    while H.size() > 0 do
      local u, du = H.pop()
      if fin[u] ~= s then
        fin[u] = s
        local av, aw = AV[u], AW[u]
        for i = 1, #av do
          local v = av[i]
          local nd = du + aw[i]
          if fin[v] ~= s and (mark[v] ~= s or nd < dist[v]) then mark[v], dist[v] = s, nd; H.push(nd, v) end
        end
      end
    end
    for j = 1, nn do
      local v = (mark[j] == s) and dist[j] or nil
      if v then
        local q = floor(v / 5 + 0.5)
        if q >= UNREACH then q = UNREACH - 1 end
        row[j] = E[floor(q / 90)] .. E[q % 90]
      else
        row[j] = UN
      end
    end
    D[s] = table.concat(row)
    if Tick then Tick() end
  end
  local cnt = { pass = 0, walk = 0, link = 0 }
  for _, nd in ipairs(nodes) do cnt[nd.src] = (cnt[nd.src] or 0) + 1 end
  return { nodes = nodes, byZone = byZone, D = D, zones = #zones, cnt = cnt }
end
K.XBuild = XBuild

local building = {}
-- 19.9 (Code Pruefung): ging der Bau fuer diesen Datenstand schief, nicht sofort wieder bauen und den alten Graph behalten
local xFail = {}
-- Graph fuer den Kontinent (nil solange er rechnet, dann im Hintergrund). Der alte Graph gilt weiter, bis der neue fertig ist
local function XGraph(cont)
  if not cont then return nil end
  local g = XG[cont]
  local rev = XRev()
  if g and g.rev == rev then return g end
  if g and xFail[cont] == rev then return g end
  if not building[cont] then
    building[cont] = true
    local function Finish(res)
      building[cont] = nil
      if not res then
        xFail[cont] = rev
        if XG[cont] then K.XGen(); return end
        res = { nodes = {}, byZone = {}, D = {}, failed = true }
      end
      res.rev = rev
      XG[cont] = res
      K.XGen()
      if ns.TestLog then ns.TestLog("WEGE", ("Karte Zonen Wege fertig: Kontinent %s, %d Zonen, %d Knoten"):format(tostring(cont), res.zones or 0, #(res.nodes or EMPTY))) end
    end
    if ns.xzoneSync or not (C_Timer and C_Timer.After and coroutine) then
      local ok, res = pcall(XBuild, cont, nil)
      Finish(ok and res or nil)
    else
      local co = coroutine.create(function()
        local t0 = debugprofilestop and debugprofilestop() or 0
        local function Tick()
          if debugprofilestop and debugprofilestop() - t0 > (Slow() and 4 or 8) then coroutine.yield(); t0 = debugprofilestop() end
        end
        return XBuild(cont, Tick)
      end)
      local function Step()
        local ok, res = coroutine.resume(co)
        if not ok then
          if ns.TestLog then ns.TestLog("FEHLER", "Karte Zonen Wege: " .. tostring(res)) end
          Finish(nil)
          return
        end
        if coroutine.status(co) == "dead" then Finish(res); return end
        C_Timer.After(0, Step)
      end
      C_Timer.After(0, Step)
    end
  end
  g = XG[cont]
  if g then return g end
  return nil
end
K.XGraph = XGraph
function K.Busy()
  for _ in pairs(building) do return true end
  return false
end

-- Strecke vom Punkt (z, x, y) zu vielen angehaengten Punkten derselben Zone: Funktion Anker -> Yards
-- 19.9: toPt = Zielseite (vom Anker zum Punkt laufen, Klippen gelten nur in eine Richtung)
local function FromPoint(z, x, y, toPt)
  local P = K.Plan(z)
  if not (P and P.n > 0) then return nil end
  local w, h = Yards(z)
  local F = ns.Felder(z)
  local A = Entries(z, P, x, y, w, h, F, toPt)
  local A2
  local function Try(list, an)
    local best
    for _, a in ipairs(list) do
      local v = PVal(P, a[1], an.pos)
      if v then
        v = v + a[2] + an.off
        if not best or v < best then best = v end
      end
    end
    return best
  end
  return function(an)
    local straight = sqrt(((an.x - x) * w) ^ 2 + ((an.y - y) * h) ^ 2)
    if straight < 150 then
      local free
      if toPt then free = LineFree(z, an.x, an.y, x, y, F) else free = LineFree(z, x, y, an.x, an.y, F) end
      if free then return straight end
    end
    local best = Try(A, an)
    if not best then
      -- die naechsten Knoten liegen auf einem abgetrennten Stueck des Netzes: weiter suchen (mehr Knoten, teurer)
      if not A2 then
        A2 = Near(P.bk, P.nx, P.ny, x, y, w, h, NEAR_K * 3, nil, NEAR_MAX * 3)
        for _, e in ipairs(A2) do e[2] = e[2] * OFF_BAD + 30 end
      end
      best = Try(A2, an)
    end
    if best and best < straight then best = straight end
    return best
  end
end

local xcache, xcacheN = {}, 0
-- Planung: Strecken von einer Stelle zu allen Knoten ihrer Zone, gemerkt pro Feld (die erste Stelle im Feld zaehlt,
-- hoechstens ein Feld daneben). Und pro Feld und Zielzone die beste Strecke zu jedem Knoten der Zielzone. So kostet eine
-- weitere Abfrage vom selben Feld nur noch eine Schleife ueber die Knoten der Zielzone (die Route fragt sehr oft).
local fcCache, fcN, rcCache, rcN = {}, 0, {}, 0
local function FromCell(z, x, y, g, toPt)
  local k = (z * 10000 + Key(Cell(x, y))) * 2 + (toPt and 1 or 0)
  local c = fcCache[k]
  if c and c.rev == g.rev then return c.d end
  local fs = FromPoint(z, x, y, toPt)
  local d = {}
  if fs then for _, u in ipairs(g.byZone[z] or EMPTY) do d[u.id] = fs(u.at[z]) or false end end
  fcN = fcN + 1
  if fcN > 20000 then fcCache, fcN = {}, 0 end
  fcCache[k] = { rev = g.rev, d = d }
  return d
end
local function Reach(z1, x1, y1, z2, g)
  local k = (z1 * 10000 + Key(Cell(x1, y1))) * 10000 + z2
  local c = rcCache[k]
  if c and c.rev == g.rev then return c.r end
  local dU = FromCell(z1, x1, y1, g)
  local r = {}
  local U = g.byZone[z1] or EMPTY
  for _, v in ipairs(g.byZone[z2] or EMPTY) do
    local best
    for _, u in ipairs(U) do
      local du = dU[u.id]
      if du then
        local mid = DV(g, u.id, v.id)
        if mid and (not best or du + mid < best) then best = du + mid end
      end
    end
    r[v.id] = best or false
  end
  rcN = rcN + 1
  if rcN > 20000 then rcCache, rcN = {}, 0 end
  rcCache[k] = { rev = g.rev, r = r }
  return r
end
local xgen = 0 -- zaehlt hoch, wenn ein Zonen Graph neu ist: dann gelten die gemerkten Strecken nicht mehr
xgenHook = function() xgen = xgen + 1 end
function K.XGenNow() return xgen end
local function PlanCross(z1, a1, b1, z2, a2, b2)
  -- 19.9 (Code Pruefung): vorher z2 * 1e13 (ueber 2^53, Nachbar Felder bekamen denselben Schluessel), jetzt unter 1.2e15
  local ck = ((z1 * 4096 + z2) * 1e4 + Key(Cell(a1, b1))) * 1e4 + Key(Cell(a2, b2))
  local c = xcache[ck]
  if c ~= nil and c.gen == xgen then return c.d end
  if not (K.HasZone(z1) and K.HasZone(z2)) then return nil end
  local cont = ContMap(z1)
  if not cont or cont ~= ContMap(z2) then return nil end
  local g = XGraph(cont)
  if not (g and g.nodes and g.byZone[z1] and g.byZone[z2]) then return nil end
  local r = Reach(z1, a1, b1, z2, g)
  local dV = FromCell(z2, a2, b2, g, true)
  local best
  for _, v in ipairs(g.byZone[z2]) do
    local a, b = r[v.id], dV[v.id]
    if a and b and (not best or a + b < best) then best = a + b end
  end
  xcacheN = xcacheN + 1
  if xcacheN > 50000 then xcache, xcacheN = {}, 0 end
  xcache[ck] = { d = best, gen = xgen }
  return best
end
-- bester Weg ueber Zonen (Pfeil, genau von der Stelle aus): Strecke, Startknoten, Zielknoten, Graph, Zonen und Punkte,
-- dazu pro Startknoten die beste Strecke
local function XBest(m1, x1, y1, m2, x2, y2)
  if not (m1 and x1 and m2 and x2) then return end
  local z1, a1, b1 = OnZone(m1, x1, y1)
  local z2, a2, b2 = OnZone(m2, x2, y2)
  if not (z1 and z2) or z1 == z2 then return end
  if not (K.HasZone(z1) and K.HasZone(z2)) then return end
  local cont = ContMap(z1)
  if not cont or cont ~= ContMap(z2) then return end
  local g = XGraph(cont)
  if not (g and g.nodes) then return end
  local U, V = g.byZone[z1], g.byZone[z2]
  if not (U and V and #U > 0 and #V > 0) then return end
  local fs = FromPoint(z1, a1, b1)
  local inV = FromCell(z2, a2, b2, g, true)
  local best, bu, bv
  -- bester Weg pro erstem Knoten (fuer den Pfeil: bei fast gleich guten bleibt er beim alten)
  local byU = {}
  if fs then
    for _, u in ipairs(U) do
      local du = fs(u.at[z1])
      if du then
        local bu1
        for _, v in ipairs(V) do
          local mid, dv = DV(g, u.id, v.id), inV[v.id]
          if mid and dv then
            local t = du + mid + dv
            if not bu1 or t < bu1[1] then bu1 = { t, v.id } end
            if not best or t < best then best, bu, bv = t, u.id, v.id end
          end
        end
        byU[u.id] = bu1
      end
    end
  end
  return best, bu, bv, g, z1, a1, b1, z2, a2, b2, byU
end
-- Planung: Strecke in Yards ueber Zonen auf einem Kontinent, nil = nicht bekannt
function K.CrossDist(m1, x1, y1, m2, x2, y2)
  if not (m1 and m2 and x1 and x2) then return nil end
  local z1, a1, b1 = OnZone(m1, x1, y1)
  local z2, a2, b2 = OnZone(m2, x2, y2)
  if not (z1 and z2) then return nil end
  -- Stadt und ihre Zone: dieselbe Zone
  if z1 == z2 then return K.ZoneDist(z1, a1, b1, a2, b2) end
  return PlanCross(z1, a1, b1, z2, a2, b2)
end

-- Pfeil: welcher Uebergang ist der erste auf dem besten Weg? In der zusammengelegten Gruppe der beste einzelne
-- (Weg bis dahin plus Weg danach in der naechsten Zone). Punkt auf der Karte m1 oder nil.
-- Steht der Spieler schon am Uebergang, zeigt der Pfeil weiter in die naechste Zone (sonst zappelt er auf der Grenze).
local AT_PASS = 25
local ncLast
local NextCrossRaw
-- der Pfeil fragt 4 mal pro Sekunde: im selben Feld und zum selben Ziel 2 Sekunden lang dieselbe Antwort
function K.NextCross(m1, x1, y1, m2, x2, y2)
  if not (m1 and x1 and m2 and x2) then return end
  local now = GetTime and GetTime() or 0
  local key = ("%d:%d:%d:%.4f:%.4f"):format(m1, Key(Cell(x1, y1)), m2, x2, y2)
  local c = ncLast
  if c and c.key == key and now - c.t < 2 then return c.x, c.y end
  local x, y = NextCrossRaw(m1, x1, y1, m2, x2, y2)
  ncLast = { key = key, t = now, x = x, y = y }
  return x, y
end
-- naechster Knoten nach u auf einem kuerzesten Weg nach v (nil, wenn u schon v ist)
local function NextOnPath(g, u, v)
  local total = DV(g, u, v)
  if not total or u == v then return nil end
  local nd = g.nodes[u]
  local best, bd
  local function Try(w2)
    if w2 and w2.id ~= u then
      local m = DV(g, u, w2.id)
      local rest = DV(g, w2.id, v)
      if m and m > 0 and rest and m + rest <= total + 8 and (not bd or m < bd) then best, bd = w2, m end
    end
  end
  for zz in pairs(nd.at) do
    for _, w2 in ipairs(g.byZone[zz] or EMPTY) do Try(w2) end
  end
  if nd.link then Try(g.nodes[nd.link]) end
  return best
end
K.NextOnPath = NextOnPath
-- Wahl merken (pro Ziel): erster Uebergang, Mitglied der Gruppe, schon am Uebergang
local ncPick
local estLogAt = {}
NextCrossRaw = function(m1, x1, y1, m2, x2, y2)
  local d, u, v, g, z1, a1, b1, z2, a2, b2, byU = XBest(m1, x1, y1, m2, x2, y2)
  if not d then return end
  local tkey = ("%d:%.3f:%.3f"):format(m2, x2, y2)
  local pk = ncPick
  if not (pk and pk.tkey == tkey and pk.rev == g.rev and pk.z1 == z1) then pk = { tkey = tkey, rev = g.rev, z1 = z1 } end
  ncPick = pk
  -- fast gleich gut (12 % oder 120 Yards): beim alten Uebergang bleiben, sonst springt der Pfeil hin und her (die
  -- Strecke bis zum Uebergang ist nur geschaetzt und schwankt beim Laufen)
  local old = pk.u and byU and byU[pk.u]
  local now = GetTime and GetTime() or 0
  -- 19.7: feste Verbindung in derselben Zone (Bruecke, Tunnel) schon durch, der beste Knoten ist jetzt ihr anderes Ende:
  -- nicht beim alten Eingang bleiben (sonst zeigt der Pfeil zurueck zum Eingang und der Spieler laeuft hin und her)
  local oldN = pk.u and g.nodes[pk.u]
  if oldN and oldN.link and oldN.link == u then old = nil; pk.u, pk.v, pk.t = nil, nil, nil end
  if old and old[1] <= d * 1.12 + 120 then u, v = pk.u, old[2]
  elseif not old and pk.u and pk.v and pk.t and now - pk.t < 8 then
    -- von hier aus ist die Strecke zum alten Uebergang gerade nicht zu schaetzen (anderes Feld): kurz beim alten bleiben
    u, v = pk.u, pk.v
  end
  if old or pk.u ~= u then pk.t = now end
  pk.v = v
  local u0 = u
  -- geht der kuerzeste Weg ab u zuerst wieder durch die eigene Zone zu einem anderen Knoten? dann gleich dorthin
  -- (die Strecke bis u ist geschaetzt, die Tabelle danach genau)
  for _ = 1, 6 do
    if u == v then break end
    local w2 = NextOnPath(g, u, v)
    if not w2 or g.nodes[u].link == w2.id then break end
    -- in welcher Zone liegt das Stueck u -> w2 (liegen beide an denselben zwei Zonen, die kuerzere)?
    local nu = g.nodes[u]
    local hz, hd
    for z in pairs(nu.at) do
      if w2.at[z] then
        local dd = AnchorDist(nu.at[z], w2.at[z])
        if dd and (not hd or dd < hd) then hz, hd = z, dd end
      end
    end
    if hz ~= z1 then break end
    u = w2.id
  end
  if pk.u ~= u0 or pk.uf ~= u then pk.u, pk.uf, pk.member, pk.at = u0, u, nil, nil end
  local nd = g.nodes[u]
  if not nd then return end
  local an, oz, tx, ty, bm
  if nd.src == "link" then
    an = nd.at[z1]
  else
    -- andere Zone dieses Uebergangs und das naechste Ziel dort
    for z in pairs(nd.at) do if z ~= z1 then oz = z end end
    if oz == z2 then tx, ty = a2, b2 else
      -- naechster Knoten auf einem kuerzesten Weg nach v (in der anderen Zone)
      local w2 = NextOnPath(g, u, v)
      local an2 = w2 and (w2.at[oz] or select(2, next(w2.at)))
      if an2 then tx, ty = an2.x, an2.y; if not w2.at[oz] then oz = next(w2.at) end end
    end
    local fs = FromPoint(z1, a1, b1)
    local ft = (tx and oz) and FromPoint(oz, tx, ty, true)
    local bmd, oldd
    for _, ps in ipairs(nd.members) do
      local d1 = fs and fs(ps[z1])
      local d2 = (ft and ps[oz]) and ft(ps[oz]) or 0
      if d1 and d2 then
        if not bmd or d1 + d2 < bmd then bm, bmd = ps, d1 + d2 end
        if ps == pk.member then oldd = d1 + d2 end
      end
    end
    if oldd and bmd and oldd <= bmd + 80 then bm = pk.member end
    pk.member = bm
    an = (bm and bm[z1]) or nd.at[z1]
  end
  local px, py = an.x, an.y
  local w, h = Yards(z1)
  local dPass = sqrt(((px - a1) * w) ^ 2 + ((py - b1) * h) ^ 2)
  -- am Uebergang: weiter zeigen, bis du 60 Yards davon weg bist (oder in der anderen Zone)
  if dPass < AT_PASS then pk.at = an elseif pk.at ~= an or dPass > 60 then pk.at = nil end
  K.lastCross = nil
  -- feste Verbindung (Tunnel, Aufzug): am Eingang zeigt der Pfeil zum anderen Ende
  if nd.src == "link" and pk.at == an and nd.link then
    local other = g.nodes[nd.link]
    local oz2, oa = next(other.at)
    K.lastCross = { z = oz2, x = oa.x, y = oa.y, fx = an.x, fy = an.y, link = true, lift = nd.lift, est = nd.est }
    -- 19.25: geschaetzter Uebergang (Ort nur aus den Wegweiser Schildern): ins Test Log, damit der Sim ihn findet
    if nd.est and ns.TestLog and now - (estLogAt[nd.id] or -999) > 120 then
      estLogAt[nd.id] = now
      ns.TestLog("WEGE", ("Uebergang geschaetzt (Aufzug): Zone %d %.3f %.3f nach Zone %d %.3f %.3f"):format(z1, an.x, an.y, oz2, oa.x, oa.y))
    end
    -- 19.9 (Code Pruefung): ohne Grenze 0..1, sonst gibt es auf einer Hauptstadt Karte keinen Pfeil Punkt
    local f = ns.ToMapFree or ns.ToMapLoose or ns.ToMap
    if f then
      local a, b = f(oz2, oa.x, oa.y, m1)
      if a then return a, b end
    end
  end
  if oz and tx and pk.at == an then
    local o = (bm and bm[oz]) or nd.at[oz]
    if o then K.lastCross = { z = oz, x = o.x, y = o.y, fx = an.x, fy = an.y } end
    local pts = o and K.Route(oz, o.x, o.y, tx, ty)
    local q = pts and (pts[3] or pts[#pts]) or { tx, ty }
    local f = ns.ToMapFree or ns.ToMapLoose or ns.ToMap
    if q and f then
      local a, b = f(oz, q[1], q[2], m1)
      if a then return a, b end
    end
  end
  if z1 ~= m1 and ns.ToMap then
    local a, b = (ns.ToMapFree or ns.ToMap)(z1, px, py, m1)
    if not a then return end
    return a, b
  end
  return px, py
end

-- 19.5: gibt es ueberhaupt einen Landweg zwischen zwei Zonen (Zonen Graph)? true / false, nil = unbekannt
local reach = {}
function K.Reachable(z1, z2)
  z1, z2 = Parent(z1), Parent(z2)
  if not (z1 and z2) then return nil end
  if z1 == z2 then return true end
  if not (K.HasZone(z1) and K.HasZone(z2)) then return nil end
  local cont = ContMap(z1)
  if not cont or cont ~= ContMap(z2) then return false end
  local g = XGraph(cont)
  -- 19.9: leerer Graph (Bau ging schief) heisst "weiss nicht", nicht "kein Landweg"
  if not (g and g.nodes) or g.failed or #g.nodes == 0 then return nil end
  if reach.g ~= g then reach = { g = g } end
  local k = z1 * 100000 + z2
  local r = reach[k]
  if r ~= nil then return r end
  r = false
  for _, u in ipairs(g.byZone[z1] or EMPTY) do
    for _, v in ipairs(g.byZone[z2] or EMPTY) do
      if DV(g, u.id, v.id) then r = true; break end
    end
    if r then break end
  end
  reach[k] = r
  return r
end

-- Weg als Punkte { Zone, x, y } ueber die Zonen (Planung, Anzeige): Start, Uebergaenge, Ziel
function K.CrossPath(m1, x1, y1, m2, x2, y2)
  local d, u, v, g, z1, a1, b1 = XBest(m1, x1, y1, m2, x2, y2)
  if not d then return end
  -- Weg rekonstruieren: von u gierig zum Nachbarn, der auf dem kuerzesten Weg nach v liegt
  local out = { { z1, a1, b1 } }
  local cur = u
  for _ = 1, 60 do
    local nd = g.nodes[cur]
    local z, an = next(nd.at)
    out[#out + 1] = { z, an.x, an.y, src = nd.src }
    if cur == v then break end
    local total = DV(g, cur, v)
    local nxt, nb
    for _, list in pairs(g.byZone) do
      for _, w2 in ipairs(list) do
        if w2.id ~= cur and total then
          local rest = DV(g, w2.id, v)
          local step = DV(g, cur, w2.id)
          if rest and step and step > 0 and step + rest <= total + 8 and (not nb or step < nb) then nxt, nb = w2.id, step end
        end
      end
    end
    if not nxt then break end
    cur = nxt
  end
  out[#out + 1] = { m2, x2, y2 }
  return out, d
end

-- 19.2 (Navi, Sascha 29.10. "da passt was nicht", Era Tirisfal nach Pestlaender): der Weg ueber die Zonen als
-- Stuecke pro Zone { z, fx, fy, tx, ty } ueber die Uebergaenge der Karte (statt Zonengrenzen auf der Luftlinie, die
-- quer ueber die Berge gingen). Feste Verbindungen (Tunnel, Aufzug) sind ein Stueck mit jump = true.
function K.CrossLegs(m1, x1, y1, m2, x2, y2)
  local d, u, v, g, z1, a1, b1, z2, a2, b2 = XBest(m1, x1, y1, m2, x2, y2)
  if not d then return end
  -- Knoten Kette wie K.CrossPath
  local chain, cur = { u }, u
  for _ = 1, 60 do
    if cur == v then break end
    local total = DV(g, cur, v)
    local nxt, nb
    for _, list in pairs(g.byZone) do
      for _, w2 in ipairs(list) do
        if w2.id ~= cur and total then
          local rest = DV(g, w2.id, v)
          local step = DV(g, cur, w2.id)
          if rest and step and step > 0 and step + rest <= total + 8 and (not nb or step < nb) then nxt, nb = w2.id, step end
        end
      end
    end
    if not nxt then return end
    chain[#chain + 1] = nxt
    cur = nxt
  end
  if chain[#chain] ~= v then return end
  local legs = {}
  local cz, fx, fy = z1, a1, b1
  for i, id in ipairs(chain) do
    local nd = g.nodes[id]
    local an = nd.at[cz]
    if not an then
      -- feste Verbindung: vom vorigen Knoten (Eingang) zu diesem (Ausgang) springen
      local z, an2 = next(nd.at)
      legs[#legs + 1] = { z, an2.x, an2.y, an2.x, an2.y, jump = true }
      cz, fx, fy = z, an2.x, an2.y
    else
      legs[#legs + 1] = { cz, fx, fy, an.x, an.y }
      fx, fy = an.x, an.y
      -- naechste Zone: die andere Seite dieses Uebergangs, die der naechste Knoten (oder das Ziel) auch kennt
      -- (teilt der naechste Knoten nur die jetzige Zone, bleibt es in der Zone; feste Verbindung: naechste Runde springt)
      local nx = chain[i + 1] and g.nodes[chain[i + 1]]
      local nz
      if nx then
        for z in pairs(nd.at) do if z ~= cz and nx.at[z] then nz = z end end
      elseif cz ~= z2 and nd.at[z2] then
        nz = z2
      end
      if nz then
        local o = nd.at[nz]
        cz, fx, fy = nz, o.x, o.y
      end
    end
  end
  if cz ~= z2 then return end
  legs[#legs + 1] = { z2, fx, fy, a2, b2 }
  return legs, d
end

-- Uebergang zwischen zwei Nachbarzonen a und b, der am wenigsten Umweg macht (Punkt in Zone a, Karte a)
function K.Crossing(a, px, py, b, tx, ty)
  local za, ax, ay = OnZone(a, px, py)
  local zb, bx, by = OnZone(b, tx, ty)
  if not (za and zb) or za == zb then return end
  local P = K.Plan(za)
  if not P then return end
  local slow = Slow()
  local fs, ft = FromPoint(za, ax, ay), FromPoint(zb, bx, by, true)
  if not fs then return end
  local best, bd
  for _, ps in ipairs(P.pass) do
    if Parent(ps.z2) == zb and not (slow and ps.prio == 2) then
      local A1 = Anchor(za, ps.x, ps.y)
      local A2 = ft and Anchor(zb, ps.x2, ps.y2)
      local d1 = A1 and fs(A1)
      local d2 = (A2 and ft(A2)) or (ns.WorldDistXY and ns.WorldDistXY(zb, ps.x2, ps.y2, zb, bx, by))
      if d1 and d2 and (not bd or d1 + d2 < bd) then best, bd = ps, d1 + d2 end
    end
  end
  if not best then return end
  local x, y = best.x, best.y
  if za ~= a and ns.ToMap then x, y = (ns.ToMapFree or ns.ToMap)(za, x, y, a) end
  if not x then return end
  return x, y, bd
end

------------------------------------------------------------
-- 9. Pfeil folgen: Weg einmal rechnen, dann Stueck fuer Stueck abgehen (naechster Punkt, der mehr als 12 Yards weg ist).
-- Neu rechnen: anderes Ziel, mehr als 60 Yards neben dem Weg oder nach 30 Sekunden.
------------------------------------------------------------
local follow, lastFree
local jumpNear, jumpLand = 0, nil -- 19.27: bis zu dieser Zeit sagt der Pfeil "hier runter springen"
local JUMP_NEAR = 30
function K.JumpNear() local now = GetTime and GetTime() or 0; return now < jumpNear end
-- Landepunkt (Karte des Aufrufs von FollowNext) und Fallhoehe der Sprungstelle vor dir, sonst nil (fuer den Sim Spieler)
function K.JumpLand()
  if not (jumpLand and K.JumpNear()) then return nil end
  return jumpLand[1], jumpLand[2], jumpLand[3]
end
-- neu rechnen: anderes Ziel, mehr als FOLLOW_OFF Yards neben dem Weg, oder nach FOLLOW_AGE Sekunden, wenn du
-- mehr als FOLLOW_DRIFT neben dem Weg bist (sonst bleibt der Weg, der Pfeil soll nicht hin und her springen)
-- 20.3 (abs pfeil_weg ABG K 14:24, P14): FOLLOW_OFF 35 statt 60, Pfeil reagiert schneller auf Abweichung
local FOLLOW_NEAR, FOLLOW_OFF, FOLLOW_AGE, FOLLOW_DRIFT = 12, 35, 30, 25
local function SegDist(px, py, ax, ay, bx, by, w, h)
  local ux, uy = (bx - ax) * w, (by - ay) * h
  local vx, vy = (px - ax) * w, (py - ay) * h
  local l2 = ux * ux + uy * uy
  local t = 0
  if l2 > 0 then t = (vx * ux + vy * uy) / l2; if t < 0 then t = 0 elseif t > 1 then t = 1 end end
  local dx, dy = vx - ux * t, vy - uy * t
  return sqrt(dx * dx + dy * dy), t
end
-- naechster Punkt fuer den Pfeil auf der Karte m: x, y, oder nil, "free" (Luftlinie ist frei) oder nil, "fail"
function K.FollowNext(m, px, py, gx, gy)
  local z, zx, zy = OnZone(m, px, py)
  local _, tx, ty = OnZone(m, gx, gy)
  if not (z and tx) or not K.HasZone(z) then return nil, "fail" end
  local F = ns.Felder(z)
  local now = GetTime and GetTime() or 0
  local w, h = Yards(z)
  -- 19.5: Luftlinie durch eine feindliche Hauptstadt zaehlt nicht als frei
  local through = SegHostile(z, zx, zy, tx, ty) and not (K.HostileCity(z, zx, zy) or K.HostileCity(z, tx, ty))
  if not through and LineFree(z, zx, zy, tx, ty, F) then
    follow = nil
    lastFree = { z = z, tx = tx, ty = ty, t = now, x = zx, y = zy }
    return nil, "free"
  end
  -- eben war die Luftlinie noch frei (unter 4 Sekunden und 30 Yards): dabei bleiben, sonst springt der Pfeil am Rand
  -- eines Berges hin und her
  local lf = lastFree
  if lf and lf.z == z and math.abs(lf.tx - tx) < 0.002 and math.abs(lf.ty - ty) < 0.002 and now - lf.t < 4
    and sqrt(((lf.x - zx) * w) ^ 2 + ((lf.y - zy) * h) ^ 2) < 30 then
    return nil, "free"
  end
  local f = follow
  -- 19.27: aendert sich, wie tief du springen darfst (Leben, Schalter, Geist), gleich neu rechnen
  local jm = K.JumpMax() or 0
  local fresh = f and f.z == z and math.abs(f.tx - tx) < 0.002 and math.abs(f.ty - ty) < 0.002 and (f.rev == (ns.blockRev or 0) or now - f.t < FOLLOW_AGE)
    and f.jm == jm
  local keep
  if fresh then
    -- wo auf dem Weg stehe ich (ab dem aktuellen Stueck, ein paar voraus)
    local bi, bd
    -- 19.31 (Oedland, Gelaende Stand 60: der Weg macht eine Haarnadel, der Pfeil nahm die Abkuerzung und sprang dann
    -- wieder auf das Stueck davor, hin und her): ist eine Abkuerzung nach vorne aktiv, geht es nicht mehr zurueck
    local i0 = (f.la and f.la > f.i) and f.i or math.max(1, f.i - 1)
    for i = i0, math.min(#f.pts - 1, f.i + 8) do
      local a, b = f.pts[i], f.pts[i + 1]
      local d = SegDist(zx, zy, a[1], a[2], b[1], b[2], w, h)
      -- fast gleich nah: das weitere Stueck (vorwaerts, nie zurueck)
      if not bd or d < bd - 3 or (d <= bd + 3 and i > bi) then bi, bd = i, math.min(d, bd or d) end
    end
    -- 19.30: gehst du die Abkuerzung (gerade Linie zum Punkt weiter vorne, den der Pfeil zeigt)? Dann bist du neben der
    -- Linie des Weges, aber nicht falsch. Neu gerechnet wird trotzdem, der alte Weg bleibt aber, wenn er nicht klar
    -- schlechter ist (siehe unten). Vorher kippte der Pfeil an manchen Stellen immer wieder hin und her
    local la = f.la and f.pts[f.la]
    local dLA = la and f.la > f.i and SegDist(zx, zy, f.lax, f.lay, la[1], la[2], w, h)
    if not bd or bd > FOLLOW_OFF or (bd > FOLLOW_DRIFT and now - f.t >= FOLLOW_AGE) then
      fresh = false
      if f.rev == (ns.blockRev or 0) then
        if dLA and dLA <= FOLLOW_DRIFT then keep = f.la - 1
        elseif bd and bd <= FOLLOW_OFF then keep = bi end
      end
    else f.i = bi end
  end
  if not fresh then
    local pts = K.Route(z, zx, zy, tx, ty)
    if not pts then follow = nil; return nil, "fail" end
    -- 19.30 (Hysterese): ist der alte Weg ab hier hoechstens 15 % (plus 30 Yards) laenger als der neue, bleibt der alte.
    -- Sonst kippt der Pfeil zwischen zwei fast gleich guten Wegen hin und her (Sumpfland Sued mit Sprungstellen: zwei
    -- Wege mit je 2 Spruengen, der Pfeil zeigte abwechselnd nach Osten und Westen)
    if keep then
      local function Len(list, i0, x0, y0)
        local sum, px, py = 0, x0, y0
        for i = i0, #list do
          local q = list[i]
          sum = sum + sqrt(((q[1] - px) * w) ^ 2 + ((q[2] - py) * h) ^ 2)
          px, py = q[1], q[2]
        end
        return sum
      end
      local oldL = Len(f.pts, keep + 1, zx, zy)
      local newL = Len(pts, 2, zx, zy)
      if oldL <= newL * 1.15 + 30 then
        f.i, f.t = keep, now
        pts = nil
      end
    end
    if pts then
      f = { z = z, tx = tx, ty = ty, t = now, pts = pts, i = 1, rev = ns.blockRev or 0, jm = jm }
      follow = f
    end
  end
  -- 19.32: fuer die Minimap Linie und die Weltkarte (K.FollowPts): wann der Pfeil diesen Weg zuletzt benutzt hat
  f.used, f.m = now, m
  -- naechster Punkt nach dem aktuellen Stueck, der weit genug weg ist; so weit voraus, wie die Luftlinie frei ist
  local j = f.i + 1
  while j < #f.pts do
    local q = f.pts[j]
    if sqrt(((q[1] - zx) * w) ^ 2 + ((q[2] - zy) * h) ^ 2) > FOLLOW_NEAR then break end
    j = j + 1
  end
  for k = math.min(#f.pts, j + 4), j + 1, -1 do
    local q = f.pts[k]
    local dq = sqrt(((q[1] - zx) * w) ^ 2 + ((q[2] - zy) * h) ^ 2)
    if dq > FOLLOW_NEAR and dq < 250 and LineFree(z, zx, zy, q[1], q[2], F) then
      -- 19.30: Abkuerzung merken (Start und Ziel), siehe oben
      if f.la ~= k then f.la, f.lax, f.lay = k, zx, zy end
      j = k; break
    end
  end
  local q = f.pts[j]
  if not q then return nil, "fail" end
  -- 19.27: ein Sprung (Landepunkt mit jump) bis zum Ziel des Pfeils und du bist nah an der Kante oben: Hinweis
  for k = f.i + 1, math.min(j, #f.pts) do
    local p = f.pts[k]
    if p.jump then
      local s0 = f.pts[k - 1]
      if s0 and sqrt(((s0[1] - zx) * w) ^ 2 + ((s0[2] - zy) * h) ^ 2) < JUMP_NEAR then
        jumpNear = now + 2
        local lx, ly = p[1], p[2]
        if z ~= m and ns.ToMap then lx, ly = (ns.ToMapFree or ns.ToMap)(z, lx, ly, m) end
        jumpLand = lx and { lx, ly, p.jump } or nil
      end
      break
    end
  end
  local x, y = q[1], q[2]
  if z ~= m and ns.ToMap then x, y = (ns.ToMapFree or ns.ToMap)(z, x, y, m); if not x then return nil, "fail" end end
  return x, y
end
function K.FollowReset() follow = nil; lastFree = nil; jumpNear = 0; jumpLand = nil end
-- 19.32 (Saschas Runde 1 Punkt 6: Minimap, Karte und Pfeil sollen den gleichen Weg zeigen): der Weg, dem der Pfeil
-- gerade folgt, als Punkte auf der Karte m, ab dem Stueck, auf dem du bist, bis zu seinem Ziel (letzter Punkt). Nichts
-- wird neu gerechnet. nil: der Pfeil folgt gerade keinem Weg (Luftlinie frei, anderes Ziel, Pfeil aus)
function K.FollowPts(m, maxN)
  local f = follow
  local now = GetTime and GetTime() or 0
  if not (f and f.used and now - f.used < 2 and f.pts and f.i) then return nil end
  local out = {}
  local n = #f.pts
  local last = math.min(n, f.i + (maxN or 60))
  for k = f.i + 1, last do
    local q = f.pts[k]
    local x, y = q[1], q[2]
    if f.z ~= m and ns.ToMap then x, y = (ns.ToMapFree or ns.ToMap)(f.z, x, y, m) end
    if x then out[#out + 1] = { x, y, jump = q.jump } end
  end
  -- zu viele Punkte: das Ziel trotzdem als letzter Punkt
  if last < n then
    local x, y = f.tx, f.ty
    if f.z ~= m and ns.ToMap then x, y = (ns.ToMapFree or ns.ToMap)(f.z, x, y, m) end
    if x then out[#out + 1] = { x, y } end
  end
  if #out == 0 then return nil end
  return out
end

-- ganzer Weg fuer die Karte und die Navi: Punkte ohne Start, mit Ziel, auf der Karte m.
-- nil, "free": Luftlinie ist frei. nil, "fail": kein Weg auf dem Netz
function K.PathPts(m, fx, fy, tx, ty)
  local z, a, b = OnZone(m, fx, fy)
  local _, c, d = OnZone(m, tx, ty)
  if not (z and c) or not K.HasZone(z) then return nil, "fail" end
  local through = SegHostile(z, a, b, c, d) and not (K.HostileCity(z, a, b) or K.HostileCity(z, c, d))
  if not through and LineFree(z, a, b, c, d) then return nil, "free" end
  local pts = K.Route(z, a, b, c, d)
  if not pts then return nil, "fail" end
  local out = {}
  for i = 2, #pts do
    local x, y = pts[i][1], pts[i][2]
    if z ~= m and ns.ToMap then x, y = (ns.ToMapFree or ns.ToMap)(z, x, y, m) end
    if x then out[#out + 1] = { x, y } end
  end
  out[#out] = { tx, ty }
  return out
end

function K.ResetRoutes()
  routeCache, routeN = {}, 0
  follow, lastFree = nil, nil
  ncLast, ncPick = nil, nil
  linkCache = {}
  for _, Q in pairs(QZ) do if Q then Q.vl = nil end end
end
function K.ResetCaches()
  zdCache, zdN = {}, 0
  xcache, xcacheN = {}, 0
  fcCache, fcN, rcCache, rcN = {}, 0, {}, 0
  XG = {}
  K.ResetRoutes()
end

------------------------------------------------------------
-- 10. Beim Einloggen: Zonen des Kontinents vorbereiten (eine pro Bild), dann den Zonen Graph (im Hintergrund),
-- danach der andere Kontinent. Die Route rechnet erst, wenn das fertig ist (Optimizer wartet auf K.Busy).
------------------------------------------------------------
local prep
-- 19.31 (Saschas Hardcore Fall: Karte nie fertig vorbereitet, keine Route): Zeitgrenze 30 s pro Versuch, dann neu
-- starten (hoechstens 2 mal), danach ohne Vorbereiten weiter, damit die Route nicht ewig wartet. Log Zeile pro Kontinent
local PREP_MAX_S, PREP_TRIES = 30, 2
local prepTry = 0
function K.Preparing() return prep ~= nil or K.Busy() end
function K.Prepare(done)
  if not K.Ok() then if done then done() end return end
  if prep then return end
  local zones = K.Zones()
  local pm = ns.PlayerMap and ns.PlayerMap()
  local here = pm and ContMap(Parent(pm))
  local conts, cset = {}, {}
  if here then conts[1] = here; cset[here] = true end
  local byCont = {}
  for _, z in ipairs(zones) do
    local c = ContMap(z)
    if c then
      byCont[c] = byCont[c] or {}
      table.insert(byCont[c], z)
      if not cset[c] then cset[c] = true; conts[#conts + 1] = c end
    end
  end
  local list = {}
  for _, c in ipairs(conts) do for _, z in ipairs(byCont[c] or EMPTY) do list[#list + 1] = z end end
  local me = { i = 0 }
  prep = me
  local t0 = debugprofilestop and debugprofilestop()
  local tc = t0
  local ci = 0
  local function NextCont()
    if prep ~= me then return end
    if ci > 0 and ns.TestLog and tc then
      ns.TestLog("WEGE", ("Karte Kontinent %s vorbereitet: %d ms"):format(tostring(conts[ci]), floor(debugprofilestop() - tc)))
      tc = debugprofilestop()
    end
    ci = ci + 1
    local c = conts[ci]
    if not c then
      prep = nil
      prepTry = 0
      if ns.TestLog and t0 then ns.TestLog("WEGE", ("Karte vorbereitet: %d Zonen, %d ms"):format(#list, floor(debugprofilestop() - t0))) end
      pcall(K.MapCheck)
      if done then done() end
      return
    end
    XGraph(c)
    local function Wait()
      if prep ~= me then return end
      if building[c] then C_Timer.After(0.1, Wait) else NextCont() end
    end
    Wait()
  end
  local function Step()
    if prep ~= me then return end
    me.i = me.i + 1
    local z = list[me.i]
    if not z then NextCont(); return end
    -- 20.3 (Na 15:15, Log: Bild 1.76 s beim Einloggen): Felder und Plan einer Zone je in einem eigenen Bild, und ein
    -- Bild ueber 150 ms ins Test Log (Zone, was, ms), damit man sieht, welche Zone bremst
    local ts = debugprofilestop and debugprofilestop()
    local what = "Plan"
    if FZ[z] == nil and PZ[z] == nil then
      what = "Felder"
      pcall(function()
        local d = Raw(z)
        if not d then FZ[z], PZ[z] = false, false else FZ[z] = SafeBuild("Felder", BuildFields, z, d) end
      end)
      if FZ[z] == nil then FZ[z] = false end -- Fehler beim Laden: nicht im Kreis drehen
      if PZ[z] == nil then me.i = me.i - 1 end -- gleiche Zone im naechsten Bild fertig machen (Plan)
    else
      pcall(Ensure, z)
    end
    if ts and ns.TestLog then
      local ms = debugprofilestop() - ts
      if ms > 150 then ns.TestLog("WEGE", ("Karte vorbereiten langsam: Zone %s %s %d ms"):format(tostring(z), what, floor(ms))) end
    end
    C_Timer.After(0, Step)
  end
  if ns.xzoneSync or not (C_Timer and C_Timer.After) then
    for _, z in ipairs(list) do pcall(Ensure, z) end
    for _, c in ipairs(conts) do XGraph(c) end
    prep = nil
    if done then done() end
    return
  end
  -- Zeitgrenze: haengt das Vorbereiten, neu starten oder ohne weiter
  C_Timer.After(PREP_MAX_S, function()
    if prep ~= me then return end
    prepTry = prepTry + 1
    local why = ("Zone %d von %d, Kontinent %d von %d, Wege im Bau %s"):format(me.i, #list, ci, #conts, tostring(K.Busy()))
    prep = nil
    if prepTry <= PREP_TRIES then
      if ns.TestLog then ns.TestLog("WEGE", ("Karte vorbereiten haengt nach %d s (%s), Versuch %d"):format(PREP_MAX_S, why, prepTry + 1)) end
      K.Prepare(done)
    else
      if ns.TestLog then ns.TestLog("FEHLER", ("Karte vorbereiten haengt (%s), weiter ohne Vorbereiten"):format(why)) end
      prepTry = 0 -- 19.32 (Pruefer 02:45 Hinweis 3): ein spaeterer Neustart (Reset) bekommt wieder 3 Versuche
      if done then done() end
    end
  end)
  -- erst im naechsten Bild (nicht im Ladebildschirm Ereignis)
  C_Timer.After(0, Step)
end

-- Hinweis, wenn das Daten Addon fehlt oder vom anderen Client ist (einmal pro Login)
local warned
function K.Hint()
  local s = K.State()
  if s == "none" then
    return TR"Gelände Daten fehlen: im Ordner KeineZeitLevelingGuide fehlt der Unterordner Karte. Der Pfeil zeigt dann die Luftlinie und deine gelaufenen Wege."
  elseif s == "client" then
    return TR"Gelände Daten passen nicht zu diesem Client. Bitte Keine Zeit Leveling Guide neu installieren."
  elseif s == "format" then
    return (TR"Gelände Daten sind neuer als dieses Addon (Format %d, das Addon kennt bis %d). Der Pfeil nimmt bis zum Update die Luftlinie und deine gelaufenen Wege."):format(K.Format(), FORMAT_MAX)
  end
end
-- 19.4: altes Daten Addon noch da? Die Karten sind jetzt im Addon, der Ordner kann weg
function K.OldAddon()
  if not IRaw() then return end
  local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not f then return end
  for _, n in ipairs({ "KeineZeitLevelingGuide_Karte_Forever" }) do
    local ok, l = pcall(f, n)
    if ok and l then return n end
  end
end
function K.Warn()
  if warned then return end
  warned = true
  local old = K.OldAddon()
  if old and ns.Print then ns.Print((TR"Die Karten sind jetzt im Addon. Den Ordner %s in Interface\\AddOns kannst du löschen."):format(old)) end
  -- 19.31: neueres Daten Format nicht beim Einloggen melden (nur /klg karte und Test Log)
  local h = K.State() ~= "format" and K.Hint()
  if h and ns.Print then ns.Print(h) end
end

-- Stand fuer /klg karte
function K.Status()
  local i = K.Info() or EMPTY
  local nz, nf, nq = #K.Zones(), 0, 0
  for _, v in pairs(FZ) do if v then nf = nf + 1 end end
  for _, v in pairs(QZ) do if v then nq = nq + 1 end end
  local gs = {}
  for c, g in pairs(XG) do gs[#gs + 1] = ("%d: %d Knoten"):format(c, #(g.nodes or EMPTY)) end
  local mc = mapCheck
  return { state = K.State(), client = i.client, stand = i.stand, build = i.build, erstellt = i.erstellt, zones = nz, fields = nf, nets = nq,
    graphs = table.concat(gs, ", "), busy = K.Preparing(), check = mc and floor(mc.mean + 0.5), checkMax = mc and floor(mc.max + 0.5) }
end

do
  local f = CreateFrame and CreateFrame("Frame")
  if f then
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- 19.31 (Hardcore Fall): das Ereignis erst abmelden, wenn das Vorbereiten wirklich startet. Sind die Daten beim
    -- ersten Mal noch nicht bereit, beim naechsten Ereignis oder nach 5 s nochmal (hoechstens 6 mal)
    local tries = 0
    local function TryPrep(self)
      if self.fwPrepOk then return end
      if K.Ok() then
        self.fwPrepOk = true
        self:UnregisterAllEvents()
        K.Reset()
        K.Prepare()
      else
        tries = tries + 1
        if tries == 1 then K.Reset() end
        if tries <= 6 and C_Timer and C_Timer.After then C_Timer.After(5, function() TryPrep(self) end) end
      end
    end
    f:SetScript("OnEvent", function(self)
      local first = not self.fwSeen
      self.fwSeen = true
      TryPrep(self)
      if not first then return end
      -- 19.28: anderer Build als die Gelaende Daten (Patch): nur ins Test Log
      if C_Timer and C_Timer.After then
        C_Timer.After(12, function()
          local ok, d, c = K.BuildCheck()
          if ok == false and ns.TestLog then ns.TestLog("KARTE", ("Gelaende Daten Build %d, Client Build %d: Daten von einem anderen Stand"):format(d, c)) end
          if K.State() == "format" and ns.TestLog then ns.TestLog("KARTE", ("Gelaende Daten Format %d, Code kennt bis %d: Rueckfall ohne Karte"):format(K.Format(), FORMAT_MAX)) end
        end)
      end
      -- Hinweis (fehlende Daten, oder 19.4: altes Daten Addon kann weg)
      if C_Timer and C_Timer.After then C_Timer.After(8, K.Warn) end
    end)
  end
end
