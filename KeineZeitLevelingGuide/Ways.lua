local ADDON, ns = ...
local TR = ns.TR

-- Wissen fuer die Laufwege, neben den Bergen der Karte (Karte.lua):
--  * geteilte Wege: Felder, durch die andere Spieler mit dem Addon gelaufen sind (Sync.lua bringt sie)
--  * Mob Ebene: wo NPCs stehen und laufen (aus Questie, einmal pro Questie Version berechnet)
--  * eigene Spur: was du selbst gelaufen bist, mit Richtung, Schwimmen und Spruengen (zum Teilen)
-- Raster wie in Path.lua: 80 x 80 Felder pro Zone, Feld = y * 100 + x.

local floor, fmod, abs = math.floor, math.fmod, math.abs
local unpack = unpack or table.unpack
local CELL, N = 0.0125, 80
local EMPTY = {}
local W = {}
ns.Ways = W
W.CELL, W.N = CELL, N

------------------------------------------------------------
-- Zahlen ohne Bit Bibliothek (alles ganze Zahlen unter 2^53, damit exakt)
------------------------------------------------------------
local POW2 = {}
for i = 0, 52 do POW2[i] = 2 ^ i end
local P31 = POW2[31]
local PC = {}
for i = 0, 255 do local n, v = 0, i; while v > 0 do n = n + v % 2; v = floor(v / 2) end; PC[i] = n end
local function Pop31(sk)
  local b0 = sk % 256; sk = (sk - b0) / 256
  local b1 = sk % 256; sk = (sk - b1) / 256
  local b2 = sk % 256; sk = (sk - b2) / 256
  return PC[b0] + PC[b1] + PC[b2] + PC[sk % 256]
end
local function HasBit(v, b) return floor(v / POW2[b]) % 2 == 1 end
local function SetBit(v, b) if floor(v / POW2[b]) % 2 == 0 then return v + POW2[b] end return v end
W.HasBit, W.SetBit = HasBit, SetBit

-- Spieler schaetzen aus der Skizze (31 Bit, jedes Bit steht fuer einen Teil der Spieler Namen):
-- wenige Spieler fast genau, ab etwa 100 ist sie voll (dann "100 oder mehr")
local EST = {}
for p = 0, 31 do
  local z = 31 - p
  EST[p] = (z == 0) and 150 or (-31 * math.log(z / 31))
end
W.EST = EST
-- Schwellen in gesetzten Bits (statt geschaetzten Spielern, damit es exakt bleibt)
local B3, B5, B15, B100 = 3, 5, 12, 30

-- Richtungen: 0 Ost, 1 Suedost, 2 Sued, 3 Suedwest, 4 West, 5 Nordwest, 6 Nord, 7 Nordost (y geht nach unten)
local DX = { [0] = 1, 1, 0, -1, -1, -1, 0, 1 }
local DY = { [0] = 0, 1, 1, 1, 0, -1, -1, -1 }
local DIR = {}
for d = 0, 7 do DIR[(DY[d] + 1) * 3 + DX[d] + 1] = d end
W.DX, W.DY = DX, DY
function W.Dir(dx, dy)
  if dx > 0 then dx = 1 elseif dx < 0 then dx = -1 end
  if dy > 0 then dy = 1 elseif dy < 0 then dy = -1 end
  return DIR[(dy + 1) * 3 + dx + 1]
end
-- Richtung einer Strecke (beliebig lang) auf 8 Richtungen gerundet
function W.DirOf(dx, dy)
  if dx == 0 and dy == 0 then return nil end
  local a = math.atan2(dy, dx)
  local d = floor(a / (math.pi / 4) + 0.5) % 8
  return d
end
-- passt die Bewegung in Richtung d zu den Richtungen der Maske (d und die zwei daneben)?
local NEAR = {}
for d = 0, 7 do NEAR[d] = POW2[d] + POW2[(d + 1) % 8] + POW2[(d + 7) % 8] end
local okTab = {}
local function MaskHas(mask, d)
  local t = okTab[mask]
  if not t then
    t = {}
    for dd = 0, 7 do
      t[dd] = HasBit(mask, dd) or HasBit(mask, (dd + 1) % 8) or HasBit(mask, (dd + 7) % 8)
    end
    okTab[mask] = t
  end
  return t[d]
end
W.MaskHas = MaskHas

local function Key(cx, cy) return cy * 100 + cx end
local function Cell(x, y)
  local cx, cy = floor(x / CELL), floor(y / CELL)
  if cx < 0 then cx = 0 elseif cx >= N then cx = N - 1 end
  if cy < 0 then cy = 0 elseif cy >= N then cy = N - 1 end
  return cx, cy
end
W.Key, W.Cell = Key, Cell
local function Today() return floor((time() or 0) / 86400) end
W.Today = Today

------------------------------------------------------------
-- Alphabete: Speicher (90 Zeichen, wie FesteDaten und die Karte) und Chat (88 Zeichen, ohne s S % | , : und Leerzeichen,
-- damit Sprachfilter und Chat nichts daran aendern)
------------------------------------------------------------
local SA, SD
local function Alpha()
  if SA then return true end
  local A = ns.PAINT_ABC
  if not A or #A < 90 then return false end
  SA, SD = {}, {}
  for i = 1, 90 do local b = A:byte(i); SA[i - 1] = b; SD[b] = i - 1 end
  return true
end
W.Alpha = Alpha
local SAFE = "0123456789ABCDEFGHIJKLMNOPQRTUVWXYZabcdefghijklmnopqrtuvwxyz!\"#$&'()*+-./;<=>?@[\\]^_`{}~"
local CA, CD = {}, {}
for i = 1, #SAFE do local b = SAFE:byte(i); CA[i - 1] = b; CD[b] = i - 1 end
W.SAFE, W.CA, W.CD = SAFE, CA, CD

-- Felder als Text (2 Zeichen pro Feld, wie FesteDaten und die Karte) und zurueck
function W.EncodeSet(set, withCount)
  if not Alpha() then return "" end
  local parts, n, ch = {}, 0, string.char
  for k, v in pairs(set) do
    n = n + 1
    if withCount then
      local c = (type(v) == "number") and math.min(89, math.max(1, floor(v))) or 1
      parts[n] = ch(SA[floor(k / 90)], SA[k % 90], SA[c])
    else
      parts[n] = ch(SA[floor(k / 90)], SA[k % 90])
    end
  end
  return table.concat(parts)
end
function W.DecodeSet(s, set, withCount)
  set = set or {}
  if not (s and Alpha()) then return set end
  local step = withCount and 3 or 2
  for p = 1, #s - step + 1, step do
    local a, b = SD[s:byte(p)], SD[s:byte(p + 1)]
    if a and b then set[a * 90 + b] = withCount and (SD[s:byte(p + 2)] or 1) or true end
  end
  return set
end

------------------------------------------------------------
-- Geteilte Wege: Speicher pro Zone
-- Wert eines Feldes (eine Zahl): Spieler Skizze 31 Bit, Richtungen 8, geschwommen, trocken, Tage 0..15,
-- letzter Tag (6 Bit), Zustand 0..3. Gespeichert als Text, 2 Zeichen Feld und 9 Zeichen Wert.
-- Auf Bergfeldern zusaetzlich: zweite Skizze (Spieler an einem anderen Tag als dem ersten) und erster Tag.
------------------------------------------------------------
local function Unpack(v)
  local sk = v % P31
  local h = (v - sk) / P31
  local dm = h % 256; h = (h - dm) / 256
  local sw = h % 2; h = (h - sw) / 2
  local dr = h % 2; h = (h - dr) / 2
  local days = h % 16; h = (h - days) / 16
  local ld = h % 64; h = (h - ld) / 64
  return sk, dm, sw, dr, days, ld, h
end
local function Pack(sk, dm, sw, dr, days, ld, st)
  return sk + P31 * (dm + 256 * (sw + 2 * (dr + 2 * (days + 16 * (ld + 64 * st)))))
end
W.Unpack, W.Pack = Unpack, Pack

local function EncodeVals(V, digits)
  local parts, n, ch = {}, 0, string.char
  local d = {}
  for k, v in pairs(V) do
    if v and v > 0 then
      local x = v
      d[1], d[2] = SA[floor(k / 90)], SA[k % 90]
      for i = digits + 2, 3, -1 do local r = fmod(x, 90); d[i] = SA[r]; x = (x - r) / 90 end
      n = n + 1
      parts[n] = ch(unpack(d, 1, digits + 2))
    end
  end
  return table.concat(parts), n
end
local function DecodeVals(s, V, digits)
  local step = 2 + digits
  local byte = string.byte
  local n = 0
  for p = 1, #s - step + 1, step do
    local a, b = SD[byte(s, p)], SD[byte(s, p + 1)]
    if a and b then
      local v = 0
      for q = p + 2, p + step - 1 do v = v * 90 + (SD[byte(s, q)] or 0) end
      V[a * 90 + b] = v
      n = n + 1
    end
  end
  return n
end

local Z, nZ = {}, 0      -- entpackte Zonen: [ui] = { V, X, dirty, used }
local MAXZ = 6
local zrev = {}          -- Stand pro Zone (zaehlt jede neue Meldung)
local pending = {}       -- [ui] = { gepackte Meldungen }, fuer Zonen, die gerade nicht entpackt sind
local pendT = {}
W.stats = { reports = 0, decoded = 0, saved = 0 }

-- Berge der Werkzeug Karte (Karte.lua)
local function Blocks(ui)
  local F = ns.Felder and ns.Felder(ui)
  return F and F.block or EMPTY
end

local function SaveZone(ui, z)
  local db = ns.db
  if not db then return end
  db.shared = db.shared or {}
  db.sharedX = db.sharedX or {}
  local s = EncodeVals(z.V, 9)
  db.shared[ui] = (s ~= "") and s or nil
  local x = EncodeVals(z.X, 6)
  db.sharedX[ui] = (x ~= "") and x or nil
  db.sharedD = db.sharedD or {}
  local dd = EncodeVals(z.D, 7)
  db.sharedD[ui] = (dd ~= "") and dd or nil
  z.dirty = false
  W.stats.saved = W.stats.saved + 1
end
W.active = {}            -- Zonen, die entpackt bleiben (deine Zone)
local function Evict()
  while nZ > MAXZ do
    local old, ot
    for ui, z in pairs(Z) do if not W.active[ui] and (not ot or z.used < ot) then old, ot = ui, z.used end end
    if not old then break end
    if Z[old].dirty then SaveZone(old, Z[old]) end
    Z[old] = nil
    nZ = nZ - 1
  end
end

-- eine Meldung in ein Feld eintragen
local function Report(z, ui, k, dir, swim, sbit, d64)
  local v = z.V[k] or 0
  local sk, dm, sw, dr, days, ld, st = Unpack(v)
  sk = SetBit(sk, sbit)
  if dir then dm = SetBit(dm, dir) end
  if swim == 1 then sw = 1 else dr = 1 end
  if v == 0 then days, ld = 1, d64
  elseif ld ~= d64 then ld = d64; if days < 15 then days = days + 1 end end
  z.V[k] = Pack(sk, dm, sw, dr, days, ld, st)
  -- Berg: merken, wer an einem anderen Tag als dem ersten durchgelaufen ist
  if Blocks(ui)[k] then
    local x = z.X[k]
    if not x then z.X[k] = d64 * P31
    else
      local s2 = x % P31
      local fd = (x - s2) / P31
      if fd ~= d64 then z.X[k] = SetBit(s2, sbit) + fd * P31 end
    end
  end
  z.dirty = true
  zrev[ui] = (zrev[ui] or 0) + 1
  W.stats.reports = W.stats.reports + 1
end

-- Sprung: von Feld k aus sind Spieler heruntergesprungen, in Richtung up geht es dort wohl nicht hoch
-- Wert: Spieler Skizze (31 Bit) und Richtungen nach oben (8 Bit)
local function ReportDrop(z, ui, k, up, sbit)
  local v = z.D[k] or 0
  local sk = v % P31
  local m = (v - sk) / P31
  z.D[k] = SetBit(sk, sbit) + SetBit(m, up) * P31
  z.dirty = true
  zrev[ui] = (zrev[ui] or 0) + 1
end

local function ApplyPending(ui, z)
  local p = pending[ui]
  if not p then return end
  for _, e in ipairs(p) do
    if e < 0 then
      e = -e - 1
      local k = e % 8000; e = (e - k) / 8000
      local up = e % 8
      ReportDrop(z, ui, k, up, (e - up) / 8)
    else
    local k = e % 8000; e = (e - k) / 8000
    local dc = e % 9; e = (e - dc) / 9
    local sw = e % 2; e = (e - sw) / 2
    local sbit = e % 31; e = (e - sbit) / 31
    Report(z, ui, k, (dc < 8) and dc or nil, sw, sbit, e % 64)
    end
  end
  pending[ui], pendT[ui] = nil, nil
end

function W.Zone(ui, noCreate)
  local z = Z[ui]
  if z then z.used = GetTime(); return z end
  local db = ns.db
  if not (db and ui and Alpha()) then return nil end
  local s = db.shared and db.shared[ui]
  local sd = db.sharedD and db.sharedD[ui]
  if noCreate and not s and not sd and not pending[ui] then return nil end
  z = { V = {}, X = {}, D = {}, dirty = false, used = GetTime() }
  if s then DecodeVals(s, z.V, 9) end
  local x = db.sharedX and db.sharedX[ui]
  if x then DecodeVals(x, z.X, 6) end
  if sd then DecodeVals(sd, z.D, 7) end
  Z[ui] = z
  nZ = nZ + 1
  W.stats.decoded = W.stats.decoded + 1
  ApplyPending(ui, z)
  Evict()
  return z
end

-- eine geteilte Meldung annehmen: Feld k der Zone ui, Richtung (0..7 oder nil), geschwommen (1/0), Bit des Absenders
function W.Add(ui, k, dir, swim, sbit)
  local d64 = Today() % 64
  local z = Z[ui]
  if z then Report(z, ui, k, dir, swim, sbit, d64); return end
  local p = pending[ui]
  if not p then p = {}; pending[ui] = p; pendT[ui] = GetTime() end
  if #p < 20000 then
    p[#p + 1] = k + 8000 * ((dir or 8) + 9 * ((swim == 1 and 1 or 0) + 2 * (sbit + 31 * d64)))
  end
  zrev[ui] = (zrev[ui] or 0) + 1
end

-- geteilter Sprung: Spieler sind von Feld k in Richtung (up + 4) heruntergesprungen
function W.AddDrop(ui, k, up, sbit)
  local z = Z[ui]
  if z then ReportDrop(z, ui, k, up, sbit); return end
  local p = pending[ui]
  if not p then p = {}; pending[ui] = p; pendT[ui] = GetTime() end
  if #p < 20000 then p[#p + 1] = -(k + 8000 * (up + 8 * sbit)) - 1 end
  zrev[ui] = (zrev[ui] or 0) + 1
end

-- Wartende Meldungen nach und nach einarbeiten (eine Zone pro Takt, nie im Kampf)
local function FlushOne(force)
  if InCombatLockdown and InCombatLockdown() and not force then return end
  local best, bt
  local now = GetTime()
  for ui, p in pairs(pending) do
    if force or #p >= 1500 or now - (pendT[ui] or now) > 300 then
      if not bt or (pendT[ui] or 0) < bt then best, bt = ui, pendT[ui] or 0 end
    end
  end
  if not best then return end
  local z = W.Zone(best)
  if z and not W.active[best] then
    SaveZone(best, z)
    Z[best] = nil
    nZ = nZ - 1
  end
  return true
end
W.FlushOne = FlushOne

-- alles speichern (beim Ausloggen und fuer /reload): entpackte Zonen als Text, Wartendes bleibt als Liste
function W.SaveAll()
  local db = ns.db
  if not db then return end
  for ui, z in pairs(Z) do if z.dirty then SaveZone(ui, z) end end
  local keep
  for ui, p in pairs(pending) do keep = keep or {}; keep[ui] = p end
  db.sharedPending = keep
  W.EndSeg()
end
function W.LoadPending()
  local db = ns.db
  if not (db and db.sharedPending) then return end
  for ui, p in pairs(db.sharedPending) do
    if type(p) == "table" then pending[ui] = p; pendT[ui] = GetTime() end
  end
  db.sharedPending = nil
end

------------------------------------------------------------
-- Auswerten: welche Felder gelten als frei, unsicher, Berg frei (mit Nachbarschaft und Rueckfall)
-- c: 1 extrem zuverlaessig, 2 sehr zuverlaessig, 3 wohl frei, 4 Berg unsicher, 5 Berg durch geteilte Wege frei
-- dm: Richtungen (nur Felder mit genug Spielern, fuer Klippen), w: Wasser, ov: fuer die Routen Rechnung
------------------------------------------------------------
local L, nL = {}, 0
local OV = {}
local function Evaluate(ui, z)
  local B = Blocks(ui)
  local pop = {}
  local rows = {}
  for k, v in pairs(z.V) do
    pop[k] = Pop31(v % P31)
    local cy = floor(k / 100)
    for dy = -2, 2 do rows[cy + dy] = true end
  end
  -- Maximum rundherum (5 x 5) in zwei Durchgaengen: erst pro Zeile, dann pro Spalte
  local rm = {}
  for cy in pairs(rows) do
    if cy >= 0 and cy < N then
      local base = cy * 100
      local a, b, c0, d, e = 0, 0, pop[base] or 0, pop[base + 1] or 0, pop[base + 2] or 0
      for cx = 0, N - 1 do
        local m = c0
        if a > m then m = a end
        if b > m then m = b end
        if d > m then m = d end
        if e > m then m = e end
        if m > 0 then rm[base + cx] = m end
        a, b, c0, d = b, c0, d, e
        e = (cx + 3 < N) and (pop[base + cx + 3] or 0) or 0
      end
    end
  end
  local c, dm, w, ov = {}, {}, {}, {}
  for k, p in pairs(pop) do
    local mx = p
    for dy = -200, 200, 100 do
      local o = rm[k + dy]
      if o and o > mx then mx = o end
    end
    local em = EST[mx]
    local ratio = (em > 0) and EST[p] / em or 0
    local v = z.V[k]
    local sk, dmask, sw, dr, days, ld, st = Unpack(v)
    local nst = 0
    if B[k] then
      local x = z.X[k]
      local p2 = x and Pop31(x % P31) or 0
      -- Berg faellt weg: mind. 15 Spieler, 30% vom Verkehr rundherum, mind. 5 davon an einem anderen Tag
      if p >= B15 and p2 >= B5 and (ratio >= 0.30 or (st == 3 and ratio >= 0.15)) then nst = 3
      -- Berg wird unsicher: mind. 5 Spieler und 20% (zurueck erst unter 10%)
      elseif p >= B5 and (ratio >= 0.20 or (st >= 2 and ratio >= 0.10)) then nst = 2 end
      if nst == 3 then c[k] = 5; ov[k] = 3 elseif nst == 2 then c[k] = 4; ov[k] = 2 end
    else
      -- unbekannt wird wohl frei: mind. 3 Spieler und 10% (zurueck erst unter 5%)
      if p >= B3 and (ratio >= 0.10 or (st == 1 and ratio >= 0.05)) then nst = 1 end
      if nst == 1 then
        if p >= B100 and ratio >= 0.30 then c[k] = 1 elseif p >= B100 then c[k] = 2 else c[k] = 3 end
      end
    end
    if nst ~= st then z.V[k] = Pack(sk, dmask, sw, dr, days, ld, nst); z.dirty = true end
    if p >= B5 and dmask > 0 then dm[k] = dmask end
    -- Wasser: geschwommen, nie trocken (mind. 2 Spieler)
    if sw == 1 and dr == 0 and p >= 2 then w[k] = true; if not ov[k] then ov[k] = 4 end end
  end
  -- Spruenge: ab 3 Spielern ist der Weg nach oben unsicher, ab 8 eine Klippe
  -- 19.18: nicht am Steg und am Zeppelin Turm (dort springen viele vom Deck oder vom Turm, das ist keine Klippe;
  -- so kommen auch alte geteilte Spruenge von dort nicht mehr als Klippe an)
  local up, upl = {}, {}
  for k, v in pairs(z.D or EMPTY) do
    local sk = v % P31
    local p = Pop31(sk)
    if p >= 3 and not (ns.NearDock and ns.NearDock(ui, ((k % 100) + 0.5) * CELL, (floor(k / 100) + 0.5) * CELL, 60)) then
      up[k] = (v - sk) / P31; upl[k] = (p >= 8) and 2 or 1
    end
  end
  return { c = c, dm = dm, w = w, ov = ov, up = up, upl = upl }
end

local function SameOv(a, b)
  if not a then return next(b) == nil end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end

-- ausgewertete Ebene einer Zone (nil: keine geteilten Daten). Hoechstens jede Minute neu (spart Rechenzeit).
function W.Layer(ui)
  if not ui then return nil end
  local db = ns.db
  if not db or db.shareWays == false then return nil end
  local l = L[ui]
  local brev = ns.blockRev or 0
  local zr = zrev[ui] or 0
  if l and l.brev == brev and (l.rev == zr or GetTime() - l.t < 60) then l.used = GetTime(); return l end
  local z = W.Zone(ui, true)
  if not z then
    if l then L[ui] = nil; nL = nL - 1 end
    if OV[ui] then OV[ui] = nil; ns.blockRev = brev + 1 end
    return nil
  end
  local nl = Evaluate(ui, z)
  nl.rev, nl.brev, nl.t, nl.used = zr, brev, GetTime(), GetTime()
  if not l then nL = nL + 1 end
  L[ui] = nl
  -- Berge, die unsicher oder frei geworden sind: die Routen Rechnung muss neu messen
  if not SameOv(OV[ui], nl.ov) then
    OV[ui] = nl.ov
    ns.blockRev = (ns.blockRev or 0) + 1
    nl.brev = ns.blockRev
  end
  -- nicht zu viele ausgewertete Zonen im Speicher (die kleinen ov Listen bleiben)
  while nL > 4 do
    local old, ot
    for u, e in pairs(L) do if u ~= ui and (not ot or e.used < ot) then old, ot = u, e.used end end
    if not old then break end
    L[old] = nil
    nL = nL - 1
  end
  return nl
end

-- fuer die Routen Rechnung: Berge mit geteilten Wegen (2 unsicher, 3 frei) und geteiltes Wasser (4)
function W.Overrides(ui)
  local db = ns.db
  if not db or db.shareWays == false then return EMPTY end
  local o = OV[ui]
  if o then return o end
  if not (db.shared and db.shared[ui]) and not pending[ui] then return EMPTY end
  local l = W.Layer(ui)
  return (l and l.ov) or EMPTY
end

-- alles speichern und den Speicher leeren (Tests, Platz)
function W.DropAll()
  for ui, z in pairs(Z) do if z.dirty then SaveZone(ui, z) end end
  Z, nZ, L, nL, OV = {}, 0, {}, 0, {}
  zrev = {}
end

-- alles ueber ein Feld (fuer die Mal Ansicht): Spieler, Spieler rundherum, Tage, Richtungen, Zustand
function W.CellInfo(ui, k)
  local z = W.Zone(ui, true)
  local v = z and z.V[k]
  if not v then return nil end
  local sk, dm, sw, dr, days, ld, st = Unpack(v)
  local p = Pop31(sk)
  local mx = p
  local cx = k % 100
  local cy = (k - cx) / 100
  for dy = -2, 2 do
    for dx = -2, 2 do
      local o = z.V[(cy + dy) * 100 + cx + dx]
      if o then local q = Pop31(o % P31); if q > mx then mx = q end end
    end
  end
  local x = z.X[k]
  local p2 = x and Pop31(x % P31) or 0
  local dv = z.D and z.D[k]
  local dsk = dv and dv % P31 or 0
  return { drops = EST[Pop31(dsk)], dropDirs = dv and (dv - dsk) / P31 or 0, players = EST[p], bits = p, around = EST[mx], days = days, dirs = dm, swim = sw == 1, dry = dr == 1,
    state = st, otherDay = EST[p2], ratio = (EST[mx] > 0) and EST[p] / EST[mx] or 0 }
end

-- gesetzte Bits (etwa Spieler) aller Felder einer Zone, fuer die Mal Ansicht
function W.Pops(ui)
  local z = W.Zone(ui, true)
  local out = {}
  if z then for k, v in pairs(z.V) do out[k] = Pop31(v % P31) end end
  return out
end
W.Pop31 = Pop31

-- Zahlen fuer /klg wege
function W.Summary(ui)
  local db = ns.db
  local zones, bytes = 0, 0
  for _, s in pairs(db and db.shared or EMPTY) do zones = zones + 1; bytes = bytes + #s end
  for _, s in pairs(db and db.sharedX or EMPTY) do bytes = bytes + #s end
  for _, s in pairs(db and db.sharedD or EMPTY) do bytes = bytes + #s end
  local pend = 0
  for _, p in pairs(pending) do pend = pend + #p end
  local out = { zones = zones, bytes = bytes, cells = floor(bytes / 11), pending = pend }
  local l = ui and W.Layer(ui)
  if l then
    local n = { 0, 0, 0, 0, 0 }
    for _, c in pairs(l.c) do n[c] = n[c] + 1 end
    local cl = 0
    for _ in pairs(l.up or EMPTY) do cl = cl + 1 end
    out.zone = { extreme = n[1], high = n[2], free = n[3], unsure = n[4], freed = n[5], cliffs = cl }
    local z = W.Zone(ui, true)
    local all = 0
    for _ in pairs(z and z.V or EMPTY) do all = all + 1 end
    out.zone.cells = all
  end
  return out
end

-- Platz begrenzen: ueber 5 MB fallen die am wenigsten bestaetigten Felder weg (nur ein Spieler, nur ein Tag).
-- Eigene Laufwege sind davon nie betroffen (die liegen woanders).
local CAP = 5 * 1024 * 1024
function W.Trim()
  local db = ns.db
  if not (db and db.shared) then return end
  local total = 0
  for _, s in pairs(db.shared) do total = total + #s end
  if total <= CAP then return end
  local minBits = 1
  while total > CAP * 0.9 and minBits <= 3 do
    for ui in pairs(db.shared) do
      local z = W.Zone(ui)
      if z then
        for k, v in pairs(z.V) do
          local sk, _, _, _, days = Unpack(v)
          if Pop31(sk) <= minBits and days <= 1 then z.V[k] = nil; z.X[k] = nil; z.dirty = true end
        end
        local before = #(db.shared[ui] or "")
        SaveZone(ui, z)
        total = total - before + #(db.shared[ui] or "")
      end
      if total <= CAP * 0.9 then break end
    end
    minBits = minBits + 1
  end
  zrev = {}
  L, nL = {}, 0
end

------------------------------------------------------------
-- Eigene Spur zum Teilen: zusammenhaengende Abschnitte (Start plus Schritte), erst nach 45 Minuten geteilt
-- Abschnitt als Chat Text: Startfeld (2 Zeichen, y * 80 + x), Laenge plus Schwimmen am Start (1 Zeichen),
-- dann je Schritt 1 Zeichen: Richtung, plus 8 wenn geschwommen, plus 16 wenn der Schritt ein Sprung nach unten war.
------------------------------------------------------------
local seg
local function Idx(k) local cx = k % 100; return ((k - cx) / 100) * 80 + cx end
local function FromIdx(i) local cx = i % 80; return ((i - cx) / 80) * 100 + cx end
W.Idx, W.FromIdx = Idx, FromIdx
local MAXSTEP = 43
function W.WireSeg(k0, sw0, steps)
  local i = Idx(k0)
  local ch = string.char
  local parts = { ch(CA[floor(i / 88)], CA[i % 88], CA[#steps + 44 * (sw0 == 1 and 1 or 0)]) }
  for n, c in ipairs(steps) do parts[n + 1] = ch(CA[c]) end
  return table.concat(parts)
end
-- Abschnitt lesen: gibt Liste { k, dir, swim } (erstes ohne Richtung) und die Laenge im Text, oder nil
function W.ReadSeg(s, p)
  local a, b, c = CD[s:byte(p) or 0], CD[s:byte(p + 1) or 0], CD[s:byte(p + 2) or 0]
  if not (a and b and c) then return nil end
  local i = a * 88 + b
  if i >= 6400 then return nil end
  local len, sw0 = c % 44, (c >= 44) and 1 or 0
  if p + 2 + len > #s then return nil end
  local cx, cy = i % 80, floor(i / 80)
  local out = { { cy * 100 + cx, nil, sw0 } }
  for q = p + 3, p + 2 + len do
    local v = CD[s:byte(q)]
    if not v or v >= 32 then return nil end
    local d = v % 8
    cx, cy = cx + DX[d], cy + DY[d]
    if cx < 0 or cx >= N or cy < 0 or cy >= N then return nil end
    out[#out + 1] = { cy * 100 + cx, d, floor(v / 8) % 2, (v >= 16) and 1 or 0 }
  end
  return out, 3 + len
end

function W.EndSeg()
  local s = seg
  seg = nil
  if not (s and #s.st > 0) then return end
  local db = ns.db
  if not db then return end
  db.trail = db.trail or {}
  local tr = db.trail
  tr[#tr + 1] = { t = s.t, z = s.z, s = W.WireSeg(s.k0, s.sw0, s.st) }
  while #tr > 800 do table.remove(tr, 1) end
end
local function Sharing() local db = ns.db; return db and db.shareWays ~= false end
function W.TrailStart(ui, k, swim)
  W.EndSeg()
  if not Sharing() then return end
  seg = { z = ui, k0 = k, sw0 = swim, st = {}, lk = k, t = time() }
end
function W.TrailStep(ui, k, d, swim, drop)
  if not Sharing() then seg = nil; return end
  if not seg or seg.z ~= ui then W.TrailStart(ui, k, swim); return end
  if #seg.st >= MAXSTEP then
    -- voll: neuer Abschnitt ab dem letzten Feld, damit die Richtung dieses Schritts erhalten bleibt
    local lk, lsw = seg.lk, seg.lsw or seg.sw0
    W.EndSeg()
    seg = { z = ui, k0 = lk, sw0 = lsw, st = {}, lk = lk, t = time() }
  end
  -- Schritt: Richtung, plus 8 geschwommen, plus 16 heruntergesprungen
  seg.st[#seg.st + 1] = d + 8 * (swim == 1 and 1 or 0) + (drop and 16 or 0)
  seg.lk, seg.lsw, seg.t = k, swim, time()
end
function W.TrailIdle()
  if seg and time() - seg.t > 60 then W.EndSeg() end
end
function W.OpenSeg() return seg end

------------------------------------------------------------
-- Mob Ebene: alle NPC Positionen und Laufwege aus Questie, einmal pro Questie Version, in Haeppchen und nie im Kampf.
-- Wirkt nur in Zonen mit Karte Daten und nimmt nie einen Berg weg (das prueft Path.lua).
------------------------------------------------------------
local mobBuilding, mobCache, nMob = false, {}, 0
function W.MobVersion()
  local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local a, b = "", ""
  if get then
    local ok1, v1 = pcall(get, "Questie", "Version")
    local ok2, v2 = pcall(get, "QuestieDB", "Version")
    a, b = ok1 and v1 or "", ok2 and v2 or ""
  end
  return tostring(a) .. "/" .. tostring(b) .. "/3"
end
function W.MobBuilding() return mobBuilding end
function W.BuildMobLayer(force)
  local db = ns.db
  if mobBuilding or not db or not Alpha() then return end
  local ver = W.MobVersion()
  if not force and db.mobLayer and db.mobLayer.ver == ver then return end
  if not (ns.svcReady and ns.QDBAccess) then
    W.mobWait = (W.mobWait or 0) + 1
    if W.mobWait < 60 then C_Timer.After(10, function() W.BuildMobLayer(force) end) end
    return
  end
  local QDB, ZDB = ns.QDBAccess()
  local lib = LibQuestieDB
  local ids = lib and lib.Npc and lib.Npc.GetAllIds and lib.Npc.GetAllIds()
  if not (QDB and ZDB and type(ids) == "table" and #ids > 0) then return end
  mobBuilding = true
  -- S: Spawns pro Feld, P: Laufweg Stuecke, E: Elite Felder (H: fuer die Horde feindlich, A: fuer die Allianz), T: Patrouillen
  local S, P, E, T = {}, {}, { H = {}, A = {} }, {}
  local EN = { H = {}, A = {} }
  local zoneOk = {}
  local function Zone(area)
    local u = zoneOk[area]
    if u == nil then
      local ok, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
      u = false
      if ok and ui and not (ns.cityParent and ns.cityParent[ui]) then
        local info = C_Map.GetMapInfo(ui)
        if info and info.mapType == Enum.UIMapType.Zone then u = ui end
      end
      zoneOk[area] = u
    end
    return u or nil
  end
  local i = 0
  local t0 = GetTime()
  local function Step()
    if InCombatLockdown and InCombatLockdown() then C_Timer.After(2, Step); return end
    local n = 0
    -- pro Bild nur so lange rechnen, wie das Budget erlaubt (schwacher PC: weniger), mindestens ein NPC
    -- (vorher mindestens 10: NPCs mit vielen Punkten gaben so Ruckler bis 30 ms)
    local budget = math.max(2, (ns.CalcMs and ns.CalcMs() or 12) - 2)
    local t1 = debugprofilestop and debugprofilestop()
    while i < #ids and n < 400 and (n < 1 or not t1 or debugprofilestop() - t1 < budget) do
      i = i + 1
      n = n + 1
      local id = ids[i]
      local okR, rank = pcall(QDB.QueryNPCSingle, id, "rank")
      rank = okR and tonumber(rank) or 0
      local elite = rank == 1 or rank == 2 or rank == 3
      local lvl, hostH, hostA
      local okW, wp = pcall(QDB.QueryNPCSingle, id, "waypoints")
      if not okW or type(wp) ~= "table" or not next(wp) then wp = nil end
      if elite or wp then
        local okL, ml = pcall(QDB.QueryNPCSingle, id, "maxLevel")
        lvl = okL and tonumber(ml) or 0
        local okF, fr = pcall(QDB.QueryNPCSingle, id, "friendlyToFaction")
        fr = (okF and type(fr) == "string") and fr or ""
        hostH, hostA = not fr:find("H", 1, true), not fr:find("A", 1, true)
      end
      local ok, sp = pcall(QDB.QueryNPCSingle, id, "spawns")
      if ok and type(sp) == "table" then
        for area, coords in pairs(sp) do
          local ui = Zone(area)
          if ui and type(coords) == "table" then
            local s = S[ui]
            if not s then s = {}; S[ui] = s end
            for _, c in ipairs(coords) do
              if type(c) == "table" and type(c[1]) == "number" and c[1] > 0 and type(c[2]) == "number" then
                local k = Key(Cell(c[1] / 100, c[2] / 100))
                s[k] = (s[k] or 0) + 1
                if elite and lvl and lvl > 0 then
                  for fac, host in pairs({ H = hostH, A = hostA }) do
                    if host then
                      local e = E[fac][ui]
                      if not e then e = {}; E[fac][ui] = e; EN[fac][ui] = {} end
                      if (e[k] or 0) < lvl then e[k] = math.min(89, lvl) end
                      local en = EN[fac][ui]
                      en[k] = math.min(89, (en[k] or 0) + 1)
                    end
                  end
                end
              end
            end
          end
        end
      end
      if wp then
        for area, list in pairs(wp) do
          local ui = Zone(area)
          if ui and type(list) == "table" then
            -- Patrouille merken (fuer Warnungen und den Pfeil)
            local t = T[ui]
            if not t then t = {}; T[ui] = t end
            if #t < 400 then t[#t + 1] = { id, lvl or 0, elite and 1 or 0, (hostH and 1 or 0) + (hostA and 2 or 0) } end
            local pp = P[ui]
            if not pp then pp = {}; P[ui] = pp end
            for _, path in ipairs(list) do
              local pk
              for _, c in ipairs(type(path) == "table" and path or EMPTY) do
                if type(c) == "table" and type(c[1]) == "number" and c[1] > 0 and type(c[2]) == "number" then
                  local k = Key(Cell(c[1] / 100, c[2] / 100))
                  if pk and pk ~= k then
                    -- grosse Spruenge (mehr als 4 Felder) gehoeren nicht zum Laufweg
                    if abs(k % 100 - pk % 100) <= 4 and abs(floor(k / 100) - floor(pk / 100)) <= 4 then
                      local a, b = math.min(pk, k), math.max(pk, k)
                      pp[a * 10000 + b] = true
                    end
                  end
                  pk = k
                end
              end
            end
          end
        end
      end
    end
    if i < #ids then C_Timer.After(0, Step); return end
    local out = { ver = ver, s = {}, p = {}, t = time(), eH = {}, eA = {}, nH = {}, nA = {}, pat = T }
    for fac, byZone in pairs(E) do
      for ui, e in pairs(byZone) do
        out["e" .. fac][ui] = W.EncodeSet(e, true)
        out["n" .. fac][ui] = W.EncodeSet(EN[fac][ui], true)
      end
    end
    for ui, s in pairs(S) do out.s[ui] = W.EncodeSet(s, true) end
    for ui, pp in pairs(P) do
      local parts, ch = {}, string.char
      for pair in pairs(pp) do
        local a = floor(pair / 10000)
        local b = pair - a * 10000
        parts[#parts + 1] = ch(SA[floor(a / 90)], SA[a % 90], SA[floor(b / 90)], SA[b % 90])
      end
      if #parts > 0 then out.p[ui] = table.concat(parts) end
    end
    db.mobLayer = out
    mobBuilding = false
    mobCache, nMob = {}, 0
    W.mobSecs = GetTime() - t0
    if lib.InvalidateCache then pcall(lib.InvalidateCache, "Npc") end
  end
  Step()
end

-- Felder einer Strecke von a nach b (beide Felder dabei)
local function LineCells(a, b, fn)
  local ax, ay = a % 100, floor(a / 100)
  local bx, by = b % 100, floor(b / 100)
  local n = math.max(abs(bx - ax), abs(by - ay))
  if n == 0 then return fn(a) end
  for s = 0, n do
    local t = s / n
    if fn(Key(floor(ax + (bx - ax) * t + 0.5), floor(ay + (by - ay) * t + 0.5))) == false then return false end
  end
end
W.LineCells = LineCells

-- Mob Ebene einer Zone: set[k] = true (hier stehen oder laufen NPCs), cnt[k] = wie viele stehen dort
-- Laufwege, die durch Berge der Karte gehen, fallen weg.
function W.MobCells(ui)
  local m = mobCache[ui]
  local brev = ns.blockRev or 0
  if m and m.brev == brev then return m.set, m.cnt end
  local db = ns.db
  local ml = db and db.mobLayer
  -- 19.29 (Sascha Teil 1 Punkt 3): Zonen mit Gelaende Karte: feindliche Mobs pro Feld aus der Karte (gH / gA) statt
  -- aller NPCs aus Questie. Die Laufwege kommen weiter aus der Mob Ebene (Questie), sobald sie fertig ist
  local KA = ns.Karte
  local fac = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and "A" or "H"
  local mg = ui and KA and KA.MobGrid and KA.MobGrid(ui, fac)
  if not (mg or (ml and ui and Alpha())) then return EMPTY, EMPTY end
  local cnt
  if mg then
    cnt = {}
    for k, n in pairs(mg.n) do cnt[k] = n end
  else
    cnt = W.DecodeSet(ml.s and ml.s[ui], {}, true)
  end
  local set = {}
  for k in pairs(cnt) do set[k] = true end
  local B = Blocks(ui)
  local KF = ns.Felder and ns.Felder(ui)
  local wat = KF and KF.water or EMPTY
  local s = ml and ml.p and ml.p[ui]
  if s and Alpha() then
    for p = 1, #s - 3, 4 do
      local a = (SD[s:byte(p)] or 0) * 90 + (SD[s:byte(p + 1)] or 0)
      local b = (SD[s:byte(p + 2)] or 0) * 90 + (SD[s:byte(p + 3)] or 0)
      local cells, bad = {}, false
      LineCells(a, b, function(k)
        if B[k] or wat[k] == 2 then bad = true; return false end
        cells[#cells + 1] = k
      end)
      if not bad then for _, k in ipairs(cells) do set[k] = true end end
    end
  end
  if not m then nMob = nMob + 1 end
  mobCache[ui] = { set = set, cnt = cnt, brev = brev, used = GetTime() }
  while nMob > 8 do
    local old, ot
    for u, e in pairs(mobCache) do if u ~= ui and (not ot or e.used < ot) then old, ot = u, e.used end end
    if not old then break end
    mobCache[old] = nil
    nMob = nMob - 1
  end
  return set, cnt
end

------------------------------------------------------------
-- Elite in der Naehe (fuer Spots: Solo Spieler nie zu Elite Gruppen schicken)
------------------------------------------------------------
local eliteCache = {}
local function Fac()
  local f = UnitFactionGroup and UnitFactionGroup("player")
  return (f == "Alliance") and "A" or "H"
end
function W.Elites(ui, fac)
  fac = fac or Fac()
  local db = ns.db
  local ml = db and db.mobLayer
  if not (ml and ui and Alpha()) then return EMPTY end
  local key = fac .. ui
  local c = eliteCache[key]
  if c and c.ver == ml.t then return c.set, c.cnt end
  local set = W.DecodeSet(ml["e" .. fac] and ml["e" .. fac][ui], {}, true)
  local cnt = W.DecodeSet(ml["n" .. fac] and ml["n" .. fac][ui], {}, true)
  eliteCache[key] = { ver = ml.t, set = set, cnt = cnt }
  return set, cnt
end
-- Elite im Umkreis von r Feldern um (x, y): hoechstes Level und wie viele (nil wenn keine)
function W.EliteNear(ui, x, y, r, fac)
  local set, cnt = W.Elites(ui, fac)
  if not next(set) then return nil, 0 end
  local cx, cy = Cell(x, y)
  local best, n = nil, 0
  r = r or 2
  for dy = -r, r do
    for dx = -r, r do
      if dx * dx + dy * dy <= r * r + 1 then
        local k = (cy + dy) * 100 + cx + dx
        local lv = set[k]
        if lv then
          if not best or lv > best then best = lv end
          n = n + ((cnt and cnt[k] ~= true and cnt[k]) or 1)
        end
      end
    end
  end
  return best, n
end

-- Patrouillen in einer Zone, die fuer dich gefaehrlich sind: Elite bis 2 Level unter dir, sonst 3 Level ueber dir
function W.DangerPatrols(ui, L, fac)
  local db = ns.db
  local ml = db and db.mobLayer
  local list = ml and ml.pat and ml.pat[ui]
  if not list then return EMPTY end
  fac = fac or Fac()
  local bit = (fac == "A") and 2 or 1
  local out = {}
  for _, e in ipairs(list) do
    local id, lvl, elite, host = e[1], e[2] or 0, e[3] == 1, e[4] or 3
    if floor(host / bit) % 2 == 1 and ((elite and lvl >= L - 2) or lvl >= L + 3) then
      out[#out + 1] = { id = id, lvl = lvl, elite = elite }
    end
  end
  return out
end

-- Entfernung (Yards) vom Punkt zum naechsten Stueck eines Laufwegs
function W.PathDist(ui, paths, x, y)
  local zy = ns.ZoneYards and ns.ZoneYards(ui)
  local w, h = zy and zy[1] or 3500, zy and zy[2] or 3500
  local best
  for _, path in ipairs(paths or EMPTY) do
    for i = 1, #path do
      local a = path[i]
      local b = path[i + 1] or a
      local ax, ay, bx, by = a[1] * w, a[2] * h, b[1] * w, b[2] * h
      local px, py = x * w, y * h
      local dx, dy = bx - ax, by - ay
      local t = 0
      local l2 = dx * dx + dy * dy
      if l2 > 0 then t = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) end
      local qx, qy = ax + dx * t - px, ay + dy * t - py
      local d = math.sqrt(qx * qx + qy * qy)
      if not best or d < best then best = d end
    end
  end
  return best
end

-- Warnung, wenn eine starke Patrouille in der Naehe vorbeilaeuft (einmal pro Mob alle 10 Minuten)
local warned = {}
function W.PatrolWarnTick()
  local db = ns.db
  if not db or db.patrolWarn == false then return end
  if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then return end
  -- 1.1 (P61, K 14:36, S Bild im Flug "Achtung: Elite Patrouille"): im Flug keine Patrouillen Hinweise, auch nichts Altes
  if ns.InFlight and ns.InFlight() then W.lastWarn = nil; return end
  local pm = ns.PlayerMap and ns.PlayerMap()
  if not pm or not ns.Waypoints then return end
  local L = UnitLevel and UnitLevel("player") or 1
  local list = W.DangerPatrols(pm, L)
  if #list == 0 then return end
  local pos = C_Map.GetPlayerMapPosition(pm, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  px, py = ns.Plain and ns.Plain(px) or px, ns.Plain and ns.Plain(py) or py
  if not (px and py) then return end
  local now = GetTime()
  for _, e in ipairs(list) do
    if not warned[e.id] or now - warned[e.id] > 600 then
      local paths = ns.Waypoints(e.id, pm)
      local d = paths and W.PathDist(pm, paths, px, py)
      if d and d < 70 then
        warned[e.id] = now
        local name = (ns.NpcName and ns.NpcName(e.id)) or TR"Mob"
        local msg = (e.elite and TR"Achtung: Elite Patrouille %s (Level %d) läuft hier vorbei." or TR"Achtung: starke Patrouille %s (Level %d) läuft hier vorbei."):format(name, e.lvl)
        ns.Print("|cffff4040" .. msg .. "|r")
        if UIErrorsFrame and UIErrorsFrame.AddMessage then UIErrorsFrame:AddMessage(msg, 1, 0.3, 0.2) end
        if PlaySound and SOUNDKIT and SOUNDKIT.RAID_WARNING then pcall(PlaySound, SOUNDKIT.RAID_WARNING) end
        W.lastWarn = { id = e.id, t = now, text = msg }
      end
    end
  end
end

------------------------------------------------------------
-- Takt: Wartendes einarbeiten, deine Zone entpackt halten, Platz pruefen
------------------------------------------------------------
do
  local f = CreateFrame("Frame")
  ns.RegEv(f, "PLAYER_LOGIN")
  ns.RegEv(f, "PLAYER_LOGOUT")
  f:SetScript("OnEvent", function(_, ev)
    if ev == "PLAYER_LOGOUT" then pcall(W.SaveAll); return end
    C_Timer.After(5, function()
      pcall(W.LoadPending)
      pcall(W.Trim)
    end)
    -- Mob Ebene: erst wenn Questie fertig ist (Services wartet darauf), dann einmal pro Questie Version
    C_Timer.After(40, function() pcall(W.BuildMobLayer) end)
    if C_Timer and C_Timer.NewTicker then
      ns.Ticker(15, function()
        local pm = ns.PlayerMap and ns.PlayerMap()
        W.active = {}
        if pm then W.active[(ns.cityParent and ns.cityParent[pm]) or pm] = true end
        pcall(FlushOne)
        W.TrailIdle()
      end)
      ns.Ticker(2, function() pcall(W.PatrolWarnTick) end)
    end
  end)
end
