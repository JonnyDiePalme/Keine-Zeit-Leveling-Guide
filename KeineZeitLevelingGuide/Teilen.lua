local ADDON, ns = ...
local TR = ns.TR

-- 1.3zzd (P133 Teil 1, S 04:07 und 04:11: "alle Daten, die das Addon besser machen, untereinander sharen. Sicher machen,
-- aber nicht so, dass es keine Daten annimmt, wenn nur 5 Leute sharen"): Daten teilen ueber den Weg der Wege (Kanal,
-- Gilde, Gruppe), eigener Praefix, je Art ein Buchstabe. Teil 1: Wert pro Kill je Mob (Art "k").
-- Regeln: eigene Messung geht immer vor, fremde Werte nur, wo du nichts Eigenes hast. Ein Absender reicht, wenn der Wert
-- plausibel ist, ab 2 Absendern Median, mit 3 und mehr fallen Ausreisser raus. Wer mehrfach Unsinn schickt, ist fuer die
-- Sitzung stumm. Nie Namen, Chat, Position oder Account Daten: Absender nur als Kennzahl (Hash).
ns.DATA_SHARE = {
  TAG = "FWD", PREFIX = "FWDat", VER = "1",
  EVERY_S = 600,        -- so oft die eigenen Werte senden
  FIRST_S = 120,        -- erste Sendung nach dem Einloggen
  LOG_AFTER_S = 15,     -- 1.3zzj: Log DATEN so lange nach dem Login
  MAX_ENTRIES = 12,     -- Eintraege je Paket
  IN_MAX_H = 30,        -- Pakete je Absender pro Stunde
  BAD_MUTE = 3,         -- so viele unplausible Pakete, dann Absender fuer die Sitzung stumm
  KEEP_SENDERS = 8,     -- je Schluessel hoechstens so viele Absender gemerkt
  KEEP_DAYS = 30,       -- fremde Werte so lange behalten
  OUTLIER_F = 3,        -- ab 3 Absendern: weiter als Faktor 3 vom Median weg = Ausreisser
  K = { MIN_KILLS = 10, FACTOR = 3, SLACK_C = 200, ABS_MAX_C = 20000 },
  -- 1.3zzg (Teil b): Art g = Stueck pro Std je Sache und Gebiet, Schluessel Item mal KEY_F plus Karte, Wert mal SCALE
  G = { KEY_F = 10000, SCALE = 10, MAX_PH = 1000 },
  -- 1.3zzh (Teil c): Art s = Faktor echte Ziel Zeit gegen geplante je Quest, Wert mal SCALE (100 = wie geplant)
  S = { SCALE = 100, MIN_R = 0.2, MAX_R = 5, MIN_PLAN_S = 20, MAX_QID = 100000, KEEP_N = 5 },
  -- 1.3zzi (Teil d): Art h = Haenge Stellen, Schluessel Karte mal MAP_F plus Zelle (CELLS mal CELLS je Karte), Wert = wie oft
  H = { CELLS = 100, MAP_F = 10000, MAX_MAP = 99999, MAX_N = 100, KEEP = 300 },
  -- 1.3zzm (Teil f): Art o = Quest wird vom NPC nicht angeboten, Wert = Level bei der Ablehnung. Gesendet nur nach MIN_N
  -- Ablehnungen ohne bekannte fehlende Vorquest. Genutzt ab MIN_SENDERS Absendern, die mindestens dein Level hatten
  O = { MIN_N = 2, MIN_SENDERS = 2, MAX_QID = 100000, MAX_LVL = 80 },
}
local DS = ns.DATA_SHARE

local function Enabled()
  local db = ns.db
  return db and db.shareData ~= false and (not ns.ShareWaysOn or ns.ShareWaysOn())
end
ns.DataShareOn = Enabled
local function Log(t) if ns.TestLog then ns.TestLog("TEILEN", t) end end
local function Store()
  local db = ns.db
  if not db then return nil end
  db.dataShared = db.dataShared or {}
  return db.dataShared
end
local function Chk(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 65521 end
  return h
end

-- Plausibel? je Art. Gibt true oder false, Grund
local CHECK = {}
CHECK.k = function(key, v)
  if not (key and key > 0 and key < 1000000 and v and v >= 0) then return false, "Werte" end
  local cm = ns.CMNpc and ns.CMNpc(key)
  if cm then
    local est = (cm.m or 0) + (cm.v or 0)
    if v > DS.K.FACTOR * est + DS.K.SLACK_C then return false, "zu hoch gegen Daten" end
  elseif v > DS.K.ABS_MAX_C then return false, "zu hoch" end
  return true
end

CHECK.g = function(key, v)
  if not (key and key > 0 and v and v >= 0) then return false, "Werte" end
  local map, id = key % DS.G.KEY_F, math.floor(key / DS.G.KEY_F)
  if map <= 0 or not (ns.ProfItem and ns.ProfItem(id)) then return false, "unbekannt" end
  if v > DS.G.MAX_PH * DS.G.SCALE then return false, "zu hoch" end
  return true
end

CHECK.s = function(key, v)
  if not (key and key > 0 and key < DS.S.MAX_QID and v) then return false, "Werte" end
  if v < DS.S.MIN_R * DS.S.SCALE or v > DS.S.MAX_R * DS.S.SCALE then return false, "Faktor" end
  return true
end

CHECK.h = function(key, v)
  if not (key and key > 0 and v and v >= 1 and v <= DS.H.MAX_N) then return false, "Werte" end
  local map = math.floor(key / DS.H.MAP_F)
  if map <= 0 or map > DS.H.MAX_MAP then return false, "Karte" end
  if ns.ZoneName and not ns.ZoneName(map) then return false, "Karte" end
  return true
end

CHECK.b = function(key, v)
  if not ns.BookShareCheck then return false, "Buch" end
  return ns.BookShareCheck(key, v)
end

CHECK.o = function(key, v)
  if not (key and key > 0 and key < DS.O.MAX_QID and v and v >= 1 and v <= DS.O.MAX_LVL) then return false, "Werte" end
  return true
end

-- eigene Werte zum Senden: { key = wert }
local OWN = {}
OWN.o = function()
  local out = {}
  for qid, t in pairs(ns.db and ns.db.offerNo or {}) do
    if type(t) == "table" and (t.n or 1) >= DS.O.MIN_N and not t.pre and (t.lvl or 0) >= 1 then out[qid] = math.min(t.lvl, DS.O.MAX_LVL) end
  end
  return out
end
OWN.b = function() return ns.BookFoundAll and ns.BookFoundAll() or {} end
OWN.h = function()
  local out = {}
  for k, n in pairs(ns.db and ns.db.hang or {}) do out[k] = math.min(n, DS.H.MAX_N) end
  return out
end
OWN.s = function()
  local out = {}
  local st = ns.db and ns.db.stepT or {}
  for qid, e in pairs(st) do
    if (e.n or 0) > 0 then out[qid] = math.floor(e.r / e.n * DS.S.SCALE + 0.5) end
  end
  return out
end
OWN.g = function() return ns.ProfMeasAll and ns.ProfMeasAll() or {} end
OWN.k = function()
  local out = {}
  for id, v, k in (ns.NpcLearnedAll and ns.NpcLearnedAll() or function() end) do
    if k >= DS.K.MIN_KILLS then out[id] = math.floor(v + 0.5) end
  end
  return out
end

-- Wert aus geteilten Daten: Median, Zahl der Absender
function ns.SharedValue(kind, key)
  local S = Store()
  local m = S and S[kind] and S[kind][key]
  if not m then return nil, 0 end
  local vals = {}
  local now = time and time() or 0
  for _, e in pairs(m) do if now - (e.t or 0) < DS.KEEP_DAYS * 86400 then vals[#vals + 1] = e.v end end
  if #vals == 0 then return nil, 0 end
  table.sort(vals)
  local med = vals[math.floor((#vals + 1) / 2)]
  if #vals >= 3 and med and med > 0 then
    local keep = {}
    for _, v in ipairs(vals) do if v <= med * DS.OUTLIER_F and v >= med / DS.OUTLIER_F then keep[#keep + 1] = v end end
    if #keep > 0 then vals = keep; med = vals[math.floor((#vals + 1) / 2)] end
  end
  return med, #vals
end

-- Paket bauen: FWD1|k|id:wert;id:wert|pruef
local function Pack(kind, list)
  local parts = {}
  for _, e in ipairs(list) do parts[#parts + 1] = e[1] .. ":" .. e[2] end
  local body = DS.VER .. "|" .. kind .. "|" .. table.concat(parts, ";")
  return DS.TAG .. body .. "|" .. Chk(body)
end

-- senden: alle Arten, je MAX_ENTRIES ein Paket (die mit den meisten Kills zuerst ist bei k nicht noetig, alles gleich)
local function SendAll()
  if not (Enabled() and ns.SyncQueue) then return end
  local nP = 0
  for kind, fn in pairs(OWN) do
    local ok, vals = pcall(fn)
    if ok and vals then
      local list = {}
      for key, v in pairs(vals) do list[#list + 1] = { key, v } end
      table.sort(list, function(a, b) return a[1] < b[1] end)
      for i = 1, #list, DS.MAX_ENTRIES do
        local chunk = {}
        for j = i, math.min(#list, i + DS.MAX_ENTRIES - 1) do chunk[#chunk + 1] = list[j] end
        ns.SyncQueue(Pack(kind, chunk), "data")
        nP = nP + 1
      end
    end
  end
  if nP > 0 then Log(("raus %d Pakete"):format(nP)) end
end
ns.DataShareSend = SendAll

-- empfangen (Sync.lua ruft das, Absender nur als Kennzahl)
local inCount, bad, mutedS = {}, {}, {}
function ns.DataShareReceive(text, sbit)
  if not Enabled() then return false, "aus" end
  if type(text) ~= "string" or text:sub(1, 3) ~= DS.TAG then return false, "Kennung" end
  if mutedS[sbit] then return false, "stumm" end
  local body, chk = text:sub(4):match("^(.*)|(%d+)$")
  if not body or tonumber(chk) ~= Chk(body) then return false, "Pruefsumme" end
  local ver, kind, list = body:match("^(%d+)|(%a)|(.*)$")
  if ver ~= DS.VER or not CHECK[kind] then return false, "Art" end
  local now = GetTime and GetTime() or 0
  local c = inCount[sbit]
  if not c or now - c.t > 3600 then c = { t = now, n = 0 }; inCount[sbit] = c end
  c.n = c.n + 1
  if c.n > DS.IN_MAX_H then return false, "zu viele" end
  local S = Store()
  S[kind] = S[kind] or {}
  local took, drop, why, n = 0, 0, nil, 0
  local tnow = time and time() or 0
  for ks, vs in (list or ""):gmatch("(%d+):(%d+)") do
    n = n + 1
    if n > DS.MAX_ENTRIES then break end
    local k, v = tonumber(ks), tonumber(vs)
    local ok, w = CHECK[kind](k, v)
    if ok then
      local m = S[kind][k] or {}
      S[kind][k] = m
      local cnt = 0
      for _ in pairs(m) do cnt = cnt + 1 end
      if m[sbit] or cnt < DS.KEEP_SENDERS then m[sbit] = { v = v, t = tnow }; took = took + 1 else drop = drop + 1; why = "voll" end
    else
      drop = drop + 1; why = w
    end
  end
  if drop > 0 and took == 0 then
    bad[sbit] = (bad[sbit] or 0) + 1
    if bad[sbit] >= DS.BAD_MUTE then mutedS[sbit] = true; why = (why or "") .. ", Absender stumm" end
  end
  Log(("rein %s %d Eintraege von Absender %d, angenommen %d, verworfen %d%s"):format(kind, n, sbit, took, drop, why and (" Grund " .. why) or ""))
  -- 1.3zzk: neue Buch Fundorte gleich einrechnen
  if took > 0 and kind == "b" and ns.BookApplyFound then pcall(ns.BookApplyFound) end
  return took > 0, why
end
-- 1.3zzk: alle geteilten Eintraege einer Art (nur lesen)
function ns.SharedTable(kind)
  local S = Store()
  return S and S[kind] or {}
end

-- 1.3zzh (P133 Teil c): Ziel Zeit je Quest. Gemessen beim Schritt Ende (DebugLog): echte Zeit minus Weg dorthin (Luftlinie
-- durch Tempo) gegen die geplante Zeit ohne Faktor (act.pdur). Nur Schritte mit genau einer Quest mit Ziel (Art O).
-- db.stepT[qid] = { r = Summe Faktoren, n }, hoechstens KEEP_N Messungen gemittelt (gleitend)
function ns.StepLearn(s, used, line)
  local db = ns.db
  if not (db and s and s.acts and used) then return end
  local S = DS.S
  local qid, plan
  for _, a in ipairs(s.acts) do
    if a.k == "O" then
      if qid and a.qid ~= qid then return end
      qid = a.qid
      plan = (plan or 0) + (a.pdur or 0)
    end
  end
  if not (qid and plan and plan >= S.MIN_PLAN_S) then return end
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or ns.speed or 7
  local work = math.max(0, used - (line or 0) / speed)
  local r = work / plan
  if r < S.MIN_R or r > S.MAX_R then
    if ns.TestLog then ns.TestLog("SCHRITT", ("Ziel Zeit Quest %d nicht gelernt: echt %d s, geplant %d s, Faktor %.2f ausserhalb"):format(qid, math.floor(work), math.floor(plan), r)) end
    return
  end
  db.stepT = db.stepT or {}
  local e = db.stepT[qid] or { r = 0, n = 0 }
  db.stepT[qid] = e
  if e.n >= S.KEEP_N then e.r = e.r / e.n * (S.KEEP_N - 1); e.n = S.KEEP_N - 1 end
  e.r, e.n = e.r + r, e.n + 1
  if ns.TestLog then ns.TestLog("SCHRITT", ("Ziel Zeit Quest %d gelernt: echt %d s, geplant %d s, Faktor %.2f (Schnitt %.2f aus %d)"):format(qid, math.floor(work), math.floor(plan), r, e.r / e.n, e.n)) end
end
-- Faktor fuer die Planung: eigen, sonst geteilt ab 2 Absendern, sonst geteilt von 1. nil = wie geplant
function ns.StepRatio(qid)
  local db = ns.db
  if not (db and qid) then return nil end
  local e = db.stepT and db.stepT[qid]
  if e and (e.n or 0) > 0 then return e.r / e.n, "eigen" end
  if ns.SharedValue then
    local v = ns.SharedValue("s", qid)
    if v then return v / DS.S.SCALE, "geteilt" end
  end
end

-- 1.3zzi (P133 Teil d): Haenge Stelle merken (DebugLog HAENGT). Nur Karte und Zelle, nie genaue Position oder Namen.
-- db.hang[schluessel] = wie oft. Die Daten landen ueber die Speicher Datei bei gelernt_auslesen (Ka bessert das Gelaende)
local function HangKey(map, x, y)
  local H = DS.H
  local cx = math.max(0, math.min(H.CELLS - 1, math.floor(x * H.CELLS)))
  local cy = math.max(0, math.min(H.CELLS - 1, math.floor(y * H.CELLS)))
  return map * H.MAP_F + cx * H.CELLS + cy
end
function ns.HangNote(map, x, y)
  local db = ns.db
  if not db then return end
  if not map then
    map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    x, y = pos:GetXY()
  end
  if not (map and x and y) or map > DS.H.MAX_MAP then return end
  db.hang = db.hang or {}
  local k = HangKey(map, x, y)
  if not db.hang[k] then
    local n = 0
    for _ in pairs(db.hang) do n = n + 1 end
    if n >= DS.H.KEEP then return end
  end
  db.hang[k] = (db.hang[k] or 0) + 1
  if ns.TestLog then ns.TestLog("TEILEN", ("Haenge Stelle gemerkt Karte %d Zelle %d, %d mal"):format(map, k % DS.H.MAP_F, db.hang[k])) end
end
-- alle Haenge Stellen (eigen plus geteilt): { [schluessel] = { n = eigen, s = Absender } }
function ns.HangSpots()
  local out = {}
  for k, n in pairs(ns.db and ns.db.hang or {}) do out[k] = { n = n, s = 0 } end
  local S = Store()
  for k, m in pairs(S and S.h or {}) do
    local e = out[k] or { n = 0, s = 0 }
    for _ in pairs(m) do e.s = e.s + 1 end
    out[k] = e
  end
  return out
end

-- 1.3zzm (P133 Teil f): bieten NPCs die Quest anderen Spielern (mindestens so hohes Level wie du) nicht an, plant die Route
-- sie nicht ein. Eigene Erfahrung geht vor (Quest.lua ns.OfferNo fragt das nur ohne eigenen Eintrag)
local offerSaid = {}
function ns.OfferNoShared(qid)
  local m = qid and ns.SharedTable and ns.SharedTable("o")[qid]
  if not m or (ns.logProgress and ns.logProgress[qid]) then return false end
  local L = UnitLevel and UnitLevel("player") or 0
  local n = 0
  for _, e in pairs(m) do if (e.v or 0) >= L then n = n + 1 end end
  if n < DS.O.MIN_SENDERS then return false end
  if not offerSaid[qid] and ns.TestLog then
    offerSaid[qid] = true
    ns.TestLog("SCHRITT", ("Quest %d nicht eingeplant: %d Spieler melden, der NPC bietet sie nicht an"):format(qid, n))
  end
  return true
end

-- 1.3zzf (K 04:44): Startdaten aus echtem Spiel (Daten\FWW_Gelernt.lua, gelernt_auslesen.py). Reihenfolge ueberall:
-- eigene Messung, geteilt mit mindestens GL.MIN_SENDERS Absendern, Startdaten gelernt, geteilt mit 1 Absender, cMaNGOS
ns.GELERNT = { MIN_SENDERS = 2, MIN_KILLS = 1 }
-- Wert pro Kill in Kupfer (Geld plus Beute zum Haendler bzw AH Preis), nil ohne Daten
function ns.GelerntMob(id)
  local G = ns.FWW_GELERNT
  local m = G and G.mob and G.mob[id]
  if type(m) ~= "table" or math.max(m.k or 0, m.kc or 0) < ns.GELERNT.MIN_KILLS then return nil end
  local v = m.cpk or 0
  for item, q in pairs(m.it or {}) do v = v + q * ((ns.ItemValue and ns.ItemValue(item)) or 0) end
  return v
end
-- Flugzeit in Sekunden von Flugmeister a nach b (NPC Nummern), nil ohne Daten
function ns.GelerntFlug(a, b)
  local G = ns.FWW_GELERNT
  local f = G and G.flug
  if not f then return nil end
  local e = f[a .. ">" .. b] or f[b .. ">" .. a]
  if type(e) == "table" and (e.n or 0) > 0 and type(e.t) == "number" then return e.t end
end

do
  local f = CreateFrame("Frame")
  ns.RegEv(f, "PLAYER_LOGIN")
  f:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    -- 1.3zzj (Pr 05:34: Log DATEN fehlte): beim Login schreibt das Test Log noch nicht, darum etwas spaeter
    local function DatenLog()
      local G, nm, nf = ns.FWW_GELERNT, 0, 0
      if G then
        for _ in pairs(G.mob or {}) do nm = nm + 1 end
        for _ in pairs(G.flug or {}) do nf = nf + 1 end
      end
      if ns.TestLog then ns.TestLog("DATEN", ("Startdaten gelernt Stand %s, %d Mobs, %d Fluege"):format(tostring(G and G.stand or "ohne Datum"), nm, nf)) end
    end
    -- 1.3zzl (Pr 06:29: auch nach 15 s kein Log): ueber ns.Ticker (laeuft sicher), einmal
    local said = false
    if ns.Ticker then ns.Ticker(DS.LOG_AFTER_S, function() if not said and ns.TestLogActive and ns.TestLogActive() then said = true; pcall(DatenLog) end end, true, true) end
    if ns.BookApplyFound then pcall(ns.BookApplyFound) end
    if ns.ProfMeasTick and ns.Ticker then ns.Ticker(ns.PROF_MEAS.TICK_S, function() pcall(ns.ProfMeasTick) end) end
    if C_Timer and C_Timer.After then C_Timer.After(DS.FIRST_S, function() pcall(SendAll) end) end
    if ns.Ticker then ns.Ticker(DS.EVERY_S, function() pcall(SendAll) end) end
  end)
end

function ns.ToggleShareData()
  local db = ns.db
  if not db then return end
  db.shareData = (db.shareData == false)
  ns.Print(db.shareData ~= false and TR"Daten teilen an: gemessene Werte (zb Wert pro Kill) gehen an andere, ihre kommen zu dir." or TR"Daten teilen aus.")
end
