-- Fluege messen und teilen (17.4, Wunsch Sascha).
-- Jeder Flug wird gemessen: Flugmeister beim Start (NPC Nummer), Flugmeister bei der Landung, Dauer in der Luft.
-- Gespeichert fuer den ganzen Account (db.flights), ein Flug dauert fuer alle Charaktere gleich lange.
-- Geteilt ueber den Wege Kanal (Sync.lua, eigene Kennung FWF) und Gilde/Gruppe (eigener Praefix, alte Versionen
-- sehen die Nachricht gar nicht). Empfangen wird nur, was passt: beide Flugmeister gibt es, die Zeit passt zur Strecke.
-- Navi und Route rechnen dann mit der echten Zeit: eigene Messung zuerst, sonst der Median der geteilten.
local ADDON, ns = ...
local TR = ns.TR

local MINS, MAXS = 15, 1500        -- plausible Flugdauer in Sekunden
local SHARE_EVERY = 1800           -- hoechstens alle 30 Minuten ein Paket
local MAXSEND = 18                 -- Fluege pro Nachricht
local KEEP = 9                     -- geteilte Werte pro Flug (je Absender einer)

local function Key(a, b) return a .. ">" .. b end

local function NpcId(guid)
  if type(guid) ~= "string" or (issecretvalue and issecretvalue(guid)) then return nil end
  local kind, _, _, _, _, id = strsplit("-", guid)
  if kind ~= "Creature" then return nil end
  return tonumber(id)
end

------------------------------------------------------------
-- Zeiten
------------------------------------------------------------
local function Median(t)
  local v = {}
  for _, x in pairs(t) do if type(x) == "number" then v[#v + 1] = x end end
  if #v == 0 then return nil end
  table.sort(v)
  local m = math.floor((#v + 1) / 2)
  if #v % 2 == 0 then return (v[m] + v[m + 1]) / 2 end
  return v[m]
end

-- Flugzeit in der Luft von Flugmeister a nach b (NPC Nummern), nil wenn nichts bekannt.
-- Zweiter Wert: woher ("eigen", "geteilt")
function ns.FlightTime(a, b)
  local db = ns.db
  if not (db and a and b) then return nil end
  for _, k in ipairs({ Key(a, b), Key(b, a) }) do
    local o = db.flights and db.flights[k]
    if type(o) == "table" and (o.n or 0) > 0 and o.s then return o.s / o.n, "eigen" end
  end
  -- 1.3zzf (K 04:44): geteilt ab 2 Absendern, dann Startdaten gelernt, dann geteilt von 1 Absender
  local one
  for _, k in ipairs({ Key(a, b), Key(b, a) }) do
    local sh = db.flightsShared and db.flightsShared[k]
    if type(sh) == "table" then
      local m = Median(sh)
      if m then
        local n = 0
        for _, x in pairs(sh) do if type(x) == "number" then n = n + 1 end end
        if n >= ((ns.GELERNT and ns.GELERNT.MIN_SENDERS) or 2) then return m, "geteilt" end
        one = one or m
      end
    end
  end
  local g = ns.GelerntFlug and ns.GelerntFlug(a, b)
  if g then return g, "gelernt" end
  if one then return one, "geteilt" end
  return nil
end

------------------------------------------------------------
-- 19.21 (Sascha): Flugnetz aus den Spieldaten (Werkzeug Stand 47 bis 49, ns.TAXI aus Karte\<Client>\Flug.lua).
-- Knoten = TaxiNodes mit Fraktion und Flugmeister NPC, Kanten = direkte Strecken nur in einer Richtung mit echter Zeit
-- und Preis. Fliegen geht nur ueber Flugpunkte, die du kennst (wie im Spiel). Gemessene Zeiten gehen weiter vor.
------------------------------------------------------------
local taxiByNpc, taxiNpcRev, taxiNpcSrc
-- TaxiNodes ID zum Flugmeister (NPC Nummer): zuerst aus den Daten, sonst der Knoten bis 60 Yards neben dem Flugmeister
local function TaxiIdOf(npc)
  local T = ns.TAXI
  if not (T and T.knoten and npc) then return nil end
  if not taxiByNpc or taxiNpcSrc ~= T then
    taxiByNpc, taxiNpcSrc = {}, T
    for id, k in pairs(T.knoten) do if type(k) == "table" and (k[11] or 0) > 0 then taxiByNpc[k[11]] = id end end
  end
  local id = taxiByNpc[npc]
  if id then return id end
  if id == false then return nil end
  local fm = ns.FlightMasterById and ns.FlightMasterById(npc)
  if fm and ns.WorldDistXY then
    local best, bd
    for kid, k in pairs(T.knoten) do
      if type(k) == "table" then
        local d = ns.WorldDistXY(fm.map, fm.x, fm.y, k[1], k[2], k[3])
        if d and d < 60 and (not bd or d < bd) then best, bd = kid, d end
      end
    end
    taxiByNpc[npc] = best or false
    return best
  end
  return nil
end
ns.TaxiIdOf = TaxiIdOf

-- kuerzeste Flugzeiten zwischen allen bekannten Flugpunkten (Floyd, gemerkt bis du einen neuen Flugpunkt lernst)
local taxiT, taxiRev, taxiSrc
local function TaxiTable()
  local T = ns.TAXI
  if not (T and T.kanten and T.knoten) then return nil end
  -- 1.4zzd (P206 fp): ueber ns.KnownFP / ns.KnownFPRev (Szenario Test kann eine eigene Liste setzen)
  local rev = ns.KnownFPRev and ns.KnownFPRev() or ((ns.db and ns.db.knownFPRev) or 0)
  if taxiT and taxiRev == rev and taxiSrc == T then return taxiT end
  taxiRev, taxiSrc = rev, T
  local ids, on = {}, {}
  for npc, v in pairs(ns.KnownFP and ns.KnownFP() or ((ns.db and ns.db.knownFP) or {})) do
    if v then
      local id = TaxiIdOf(npc)
      if id and not on[id] then on[id] = true; ids[#ids + 1] = id end
    end
  end
  local d = {}
  for _, a in ipairs(ids) do d[a] = { [a] = 0 } end
  for _, e in ipairs(T.kanten) do
    local a, b, s = e[1], e[2], e[3]
    if on[a] and on[b] and type(s) == "number" and (not d[a][b] or s < d[a][b]) then d[a][b] = s end
  end
  for _, k in ipairs(ids) do
    local dk = d[k]
    for _, i in ipairs(ids) do
      local di = d[i]
      local ik = di[k]
      if ik then
        for _, j in ipairs(ids) do
          local kj = dk[j]
          if kj and (not di[j] or ik + kj < di[j]) then di[j] = ik + kj end
        end
      end
    end
  end
  taxiT = d
  return d
end

-- Flugzeit nach den Spieldaten von Flugmeister a nach b (NPC Nummern). nil: keine Daten zu diesen Flugmeistern,
-- false: beide bekannt, aber keine Strecke ueber deine Flugpunkte (dann gibt es diesen Flug nicht)
function ns.TaxiTime(a, b)
  local d = TaxiTable()
  if not d then return nil end
  local ia, ib = TaxiIdOf(a), TaxiIdOf(b)
  if not (ia and ib) then return nil end
  if not d[ia] then return nil end
  local t = d[ia][ib]
  if t then return t end
  return false
end
function ns.TaxiReset() taxiT = nil; taxiByNpc = nil end

-- passt die Zeit zur Strecke? (Flug etwa 32 Yards pro Sekunde, Umwege bis zu gut doppelt so lang)
local function Plausible(a, b, sec)
  if type(sec) ~= "number" or sec < MINS or sec > MAXS then return false end
  local fa, fb = ns.FlightMasterById and ns.FlightMasterById(a), ns.FlightMasterById and ns.FlightMasterById(b)
  if not (fa and fb) then return false end
  local d = ns.WorldDistXY and ns.WorldDistXY(fa.map, fa.x, fa.y, fb.map, fb.x, fb.y)
  if not d then return false end
  return sec >= d / 45 and sec <= d / 12 + 90
end
ns.FlightPlausible = Plausible

-- 1.4zzq (M58, S Ja 13:39): Forever Talent Vielflieger (Vermaechtnis Baum, Spell 1225490, Flug 20 Prozent schneller).
-- Wer es hat, misst zu kurze Zeiten: dann nichts merken und nichts teilen, nur Log (Pr misst den Faktor, Umrechnen kommt 1.5)
ns.VIELFLIEGER_SPELL = 1225490
local vfT, vfV = -999, false
function ns.Vielflieger()
  local now = GetTime and GetTime() or 0
  if now - vfT < 30 then return vfV end
  vfT = now
  local id, has = ns.VIELFLIEGER_SPELL, false
  if IsPlayerSpell then local ok, r = pcall(IsPlayerSpell, id); has = ok and r and true or false end
  if not has and IsSpellKnown then local ok, r = pcall(IsSpellKnown, id); has = ok and r and true or false end
  if not has and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
    local ok, r = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id); has = ok and r ~= nil
  end
  vfV = has
  return has
end

local function Record(a, b, sec)
  local db = ns.db
  if not (db and a and b and a ~= b) then return end
  if ns.Vielflieger() then
    local norm = ns.FlightTime and ns.FlightTime(a, b)
    local fa, fb = ns.FlightMasterById(a), ns.FlightMasterById(b)
    if ns.TestLog then ns.TestLog("FLUG", ("%s nach %s: %.0f s gemessen, vielflieger=1, nicht gemerkt und nicht geteilt (bekannt %s s)")
      :format(fa and fa.name or tostring(a), fb and fb.name or tostring(b), sec or -1, norm and ("%.0f"):format(norm) or "-")) end
    return
  end
  if not Plausible(a, b, sec) then
    if ns.TestLog then ns.TestLog("FLUG", ("Flug %s nach %s, %.0f s: passt nicht zur Strecke, nicht gemerkt"):format(tostring(a), tostring(b), sec or -1)) end
    return
  end
  db.flights = type(db.flights) == "table" and db.flights or {}
  local k = Key(a, b)
  local o = db.flights[k]
  if type(o) ~= "table" then o = { s = 0, n = 0 }; db.flights[k] = o end
  -- gleitender Mittelwert ueber hoechstens 5 Fluege
  if o.n >= 5 then o.s = o.s / o.n * 4; o.n = 4 end
  o.s, o.n, o.t = o.s + sec, o.n + 1, time()
  db.flightsOut = type(db.flightsOut) == "table" and db.flightsOut or {}
  db.flightsOut[k] = math.floor(o.s / o.n + 0.5)
  if ns.TravelResetCache then ns.TravelResetCache() end
  local fa, fb = ns.FlightMasterById(a), ns.FlightMasterById(b)
  if ns.TestLog then ns.TestLog("FLUG", ("%s nach %s: %.0f s gemessen (Schnitt %.0f s aus %d)"):format(fa and fa.name or a, fb and fb.name or b, sec, o.s / o.n, o.n)) end
end
ns.FlightRecord = Record

------------------------------------------------------------
-- Messen: Flugkarte offen -> Flug genommen -> in der Luft -> gelandet
------------------------------------------------------------
local fromId, taking, startT
local ef = CreateFrame("Frame")
ns.RegEv(ef, "TAXIMAP_OPENED")
ns.RegEv(ef, "PLAYER_ENTERING_WORLD")
ef:SetScript("OnEvent", function(_, e)
  if e == "TAXIMAP_OPENED" then
    fromId = NpcId(UnitGUID and UnitGUID("npc"))
  elseif e == "PLAYER_ENTERING_WORLD" then
    -- Neuladen oder Ladebildschirm mitten im Flug: diese Messung zaehlt nicht
    taking, startT = nil, nil
    if hooksecurefunc and TakeTaxiNode and not ef.hooked then
      ef.hooked = true
      hooksecurefunc("TakeTaxiNode", function(slot)
        if fromId then
          taking = { from = fromId, t = GetTime() }
          -- 1.1 (S Wunsch: Flugzeit unter dem Pfeil): Ziel Flugmeister aus dem Knopf (Slot) ueber die Flug Daten (ns.TAXI)
          local okD, toNpc = pcall(function()
            local mapID = GetTaxiMapID and GetTaxiMapID()
            local nodes = C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and mapID and C_TaxiMap.GetAllTaxiNodes(mapID)
            for _, n in ipairs(nodes or {}) do
              if n.slotIndex == slot and n.nodeID and ns.TAXI and ns.TAXI.knoten then
                local k = ns.TAXI.knoten[n.nodeID]
                return type(k) == "table" and k[11] or nil
              end
            end
          end)
          taking.to = okD and toNpc or nil
        end
      end)
    end
  end
end)

-- 1.1: laufender Flug: Rest Sekunden, ganze Zeit, Quelle ("eigen" oder "geteilt"), oder nil wenn unbekannt
-- 1.1 (P61, K 14:36): im Flug? UnitOnTaxi, wenn der Wert nicht geheim ist, sonst ob ein Flug von uns laeuft
function ns.InFlight()
  local t = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  if t ~= nil then return t and true or false end
  return ns.FlightNow and ns.FlightNow() ~= nil or false
end
-- 1.3.1a (P119): Ziel Flugmeister (NPC id) vom laufenden Flug, sonst nil
function ns.FlightTo() return taking and startT and taking.to or nil end
function ns.FlightNow()
  if not (taking and startT and taking.to and taking.from) then return nil end
  local total, src = ns.FlightTime(taking.from, taking.to)
  if not total then return nil end
  return math.max(0, total - (GetTime() - startT)), total, src
end

local function Landed()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return nil end
  local px, py = pos:GetXY()
  -- 17.9: "x and f()" gab nur best zurueck, d war immer nil: keine Landung erkannt, kein Flug gemerkt
  local best, d
  if ns.NearestSvc then best, d = ns.NearestSvc("fly", map, px, py) end
  if best and d and d < 90 then return best.id end
end

local function Tick()
  if not taking then return end
  local onTaxi = UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player")
  if not startT then
    if onTaxi then startT = GetTime()
    elseif GetTime() - taking.t > 30 then taking = nil end
    return
  end
  if onTaxi then
    if GetTime() - startT > MAXS + 60 then taking, startT = nil, nil end
    return
  end
  local dur = GetTime() - startT
  local from = taking.from
  taking, startT = nil, nil
  -- kurz warten, bis die Position nach der Landung stimmt
  C_Timer.After(1, function()
    local to = Landed()
    if to and from and to ~= from then Record(from, to, dur) end
  end)
end

------------------------------------------------------------
-- Teilen
------------------------------------------------------------
local TAG = "FWF"
local A36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function B36(n)
  -- 19.16: nur endliche Zahlen (unendlich lief hier endlos, Sim Teil E), hoechstens 36^8
  n = tonumber(n) or 0
  if n ~= n or n < 1 then return "0" end
  if n > 2821109907455 then n = 2821109907455 end
  n = math.floor(n)
  local s = ""
  while n > 0 do local r = n % 36; s = A36:sub(r + 1, r + 1) .. s; n = math.floor(n / 36) end
  return s
end
local function Chk(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 1296 end
  return A36:sub(math.floor(h / 36) + 1, math.floor(h / 36) + 1) .. A36:sub(h % 36 + 1, h % 36 + 1)
end

-- Nachricht: FWF a.b.s,a.b.s,...|cc  (Zahlen in Basis 36, cc Pruefsumme)
function ns.FlightsPack(list)
  local body = {}
  for _, e in ipairs(list) do body[#body + 1] = B36(e[1]) .. "." .. B36(e[2]) .. "." .. B36(e[3]) end
  local s = TAG .. table.concat(body, ",")
  return s .. "|" .. Chk(s)
end

function ns.FlightsParse(text)
  if type(text) ~= "string" or #text > 255 or text:sub(1, 3) ~= TAG then return nil end
  local body, c = text:match("^(.-)|(%w%w)$")
  if not body or Chk(body) ~= c then return nil end
  local out = {}
  for a, b, s in body:sub(4):gmatch("(%w+)%.(%w+)%.(%w+)") do
    out[#out + 1] = { tonumber(a, 36), tonumber(b, 36), tonumber(s, 36) }
    if #out > 30 then return nil end
  end
  return #out > 0 and out or nil
end

-- empfangen (aus Sync.lua): pro Absender begrenzt, nur plausible Fluege
local senders = {}
function ns.FlightsReceive(text, sender, senderHash)
  local db = ns.db
  if not db then return end
  local list = ns.FlightsParse(text)
  if not list then return end
  local s = senders[sender]
  local now = GetTime()
  if not s then s = { t = now, n = 0 }; senders[sender] = s end
  if now - s.t > 3600 then s.t, s.n = now, 0 end
  if s.n >= 60 then return end
  db.flightsShared = type(db.flightsShared) == "table" and db.flightsShared or {}
  local took = 0
  for _, e in ipairs(list) do
    local a, b, sec = e[1], e[2], e[3]
    if a and b and a ~= b and Plausible(a, b, sec) and s.n < 60 then
      local k = Key(a, b)
      local sh = db.flightsShared[k]
      if type(sh) ~= "table" then sh = {}; db.flightsShared[k] = sh end
      local n = 0
      for _ in pairs(sh) do n = n + 1 end
      local who = tostring(senderHash or sender)
      if sh[who] or n < KEEP then sh[who] = sec; took = took + 1; s.n = s.n + 1 end
    end
  end
  if took > 0 and ns.TravelResetCache then ns.TravelResetCache() end
  return took
end

-- alle 30 Minuten: neue eigene Fluege als ein Paket
local lastShare = 0
local function Share()
  local db = ns.db
  if not (db and type(db.flightsOut) == "table" and next(db.flightsOut)) then return end
  if not (ns.ShareWaysOn and ns.ShareWaysOn()) or not ns.SyncQueue then return end
  if GetTime() - lastShare < SHARE_EVERY then return end
  local list = {}
  for k, sec in pairs(db.flightsOut) do
    local a, b = k:match("^(%d+)>(%d+)$")
    if a and #list < MAXSEND then list[#list + 1] = { tonumber(a), tonumber(b), sec } end
  end
  for _, e in ipairs(list) do db.flightsOut[Key(e[1], e[2])] = nil end
  if #list == 0 then return end
  lastShare = GetTime()
  ns.SyncQueue(ns.FlightsPack(list), "flights")
end
ns.FlightsShare = Share

local tf = CreateFrame("Frame")
ns.RegEv(tf, "PLAYER_LOGIN")
tf:SetScript("OnEvent", function()
  -- 1.4zzg (M51, S 17:16): sammeln und teilen auch in der Pause
  ns.Ticker(0.5, function() pcall(Tick) end, true, true)
  ns.Ticker(120, function() pcall(Share) end, nil, true)
end)

-- /klg fluege
function ns.FlightsStatus()
  local db = ns.db or {}
  local own, shared = 0, 0
  for _ in pairs(type(db.flights) == "table" and db.flights or {}) do own = own + 1 end
  for _ in pairs(type(db.flightsShared) == "table" and db.flightsShared or {}) do shared = shared + 1 end
  ns.Print((TR"Flüge: %d selbst gemessen, %d von anderen bekommen"):format(own, shared))
end

------------------------------------------------------------
-- 1.4b (P153, S 11.11. Flugkarte soll2): Maus auf einen Flugpunkt der Flugkarte zeigt die Flugzeit, sobald sie bekannt ist:
-- gesamt (gemessen von hier bis dort) und bei Fluegen ueber mehrere Punkte jede Strecke. Quelle wie ns.FlightTime
-- (eigen, geteilt, gelernt). Die Zeiten werden schon geteilt (Teilen/Sync, flightsShared). Log FLUGKARTE einmal je Ziel.
------------------------------------------------------------
local function SlotNodes()
  local t = {}
  local cm = GetTaxiMapID and GetTaxiMapID()
  local ok, list = pcall(function() return C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and cm and C_TaxiMap.GetAllTaxiNodes(cm) end)
  for _, n in ipairs(ok and list or {}) do
    if type(n) == "table" and n.slotIndex and n.nodeID then
      local k = ns.TAXI and ns.TAXI.knoten and ns.TAXI.knoten[n.nodeID]
      t[n.slotIndex] = { npc = type(k) == "table" and k[11] or nil, name = n.name }
    end
  end
  return t
end
local function SrcLabel(src) return src == "eigen" and "" or (src == "geteilt" and TR" (geteilt)" or (src and TR" (gelernt)" or "")) end
local tipLogged = {}
function ns.FlightTipLines(slot)
  local out = {}
  if not (GetNumRoutes and TaxiGetNodeSlot) then return out end
  local okN, hops = pcall(GetNumRoutes, slot)
  if not okN or not hops or hops < 1 then return out end
  local nodes = SlotNodes()
  local first, last
  local legs, sum, allKnown = {}, 0, true
  for h = 1, hops do
    local okA, a = pcall(TaxiGetNodeSlot, slot, h, true)
    local okB, b = pcall(TaxiGetNodeSlot, slot, h, false)
    local na, nb = okA and nodes[a], okB and nodes[b]
    if h == 1 then first = na end
    last = nb
    local t, src
    if na and nb and na.npc and nb.npc then t, src = ns.FlightTime(na.npc, nb.npc) end
    if t then sum = sum + t else allKnown = false end
    legs[#legs + 1] = { from = na and na.name, to = nb and nb.name, t = t, src = src }
  end
  local total, tsrc
  if first and last and first.npc and last.npc then total, tsrc = ns.FlightTime(first.npc, last.npc) end
  if total then
    out[#out + 1] = (TR"Flugzeit %s%s"):format(ns.Clock(total), SrcLabel(tsrc))
  elseif allKnown and hops > 1 then
    out[#out + 1] = (TR"Flugzeit ca %s (Summe der Strecken)"):format(ns.Clock(sum))
  elseif hops == 1 then
    out[#out + 1] = TR"Flugzeit noch unbekannt"
  end
  if hops > 1 then
    for _, l in ipairs(legs) do
      out[#out + 1] = ("  %s > %s  %s"):format(tostring(l.from or "?"):gsub(",.*", ""), tostring(l.to or "?"):gsub(",.*", ""),
        l.t and (ns.Clock(l.t) .. SrcLabel(l.src)) or TR"unbekannt")
    end
  end
  local key = tostring(last and last.name) .. hops
  if ns.TestLog and not tipLogged[key] then
    tipLogged[key] = true
    ns.TestLog("FLUGKARTE", ("Tooltip %s: %d Strecken, %s"):format(tostring(last and last.name), hops, table.concat(out, " | ")))
  end
  return out
end
local hooked = {}
local function HookButtons()
  for i = 1, (NumTaxiNodes and NumTaxiNodes() or 0) do
    local b = _G["TaxiButton" .. i]
    if b and not hooked[b] and b.HookScript then
      hooked[b] = true
      b:HookScript("OnEnter", function(self)
        local slot = self.GetID and self:GetID() or i
        local ok, lines = pcall(ns.FlightTipLines, slot)
        if not (ok and lines and #lines > 0 and GameTooltip:IsShown()) then return end
        for k, l in ipairs(lines) do
          if k == 1 then GameTooltip:AddLine(l, 0.4, 0.8, 1) else GameTooltip:AddLine(l, 0.85, 0.85, 0.85) end
        end
        GameTooltip:Show()
      end)
    end
  end
end
do
  local tf = CreateFrame("Frame")
  ns.RegEv(tf, "TAXIMAP_OPENED")
  tf:SetScript("OnEvent", function() C_Timer.After(0.1, function() pcall(HookButtons) end) end)
end
