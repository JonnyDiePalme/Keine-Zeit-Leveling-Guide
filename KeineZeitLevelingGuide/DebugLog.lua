-- Test Log (nur fuer die Testphase): schreibt mit, was das Addon tut und wo es hakt.
-- Seit 17.2 im eigenen Addon KeineZeitLevelingGuide_Log, eigene Datei:
-- WTF\Account\<Name>\SavedVariables\KeineZeitLevelingGuide_Log.lua (Tabelle ForeverWegweiserTestLog).
-- Ohne dieses Addon gibt es kein Log. Blizzard schreibt die Datei erst beim Ausloggen oder /reload.
-- Verschluesselt (LogCrypt.lua): lesen kann es nur, wer den geheimen Schluessel hat, Aenderungen fallen auf.
-- Anonym: andere Spieler stehen als "Spieler 1", "Spieler 2" (pro Sitzung neu gezaehlt), der eigene Name als "ich".
-- Keine Chat Texte, keine Konto Daten. Hoechstens etwa 1.8 MB, pro Sitzung und Art begrenzt.
-- Neue Addon Version: das alte Log wird geloescht (keine Reste). Beta: Standard an, Release: Standard aus.
-- /klg testlog            Stand zeigen
-- /klg testlog an | aus   ein und aus
-- /klg testlog leeren     alles loeschen
-- /klg testlog notiz TEXT eigene Notiz, zb "hier lief er in den Berg" (mit Stand vom Addon dazu)
local ADDON, ns = ...
local TR = ns.TR

-- Beim Release auf false: dann ist das Test Log aus, bis man es mit /klg testlog an einschaltet
-- 1.0 (K 23:17, S 23:16): Release, Standard aus. Nur an, wenn der Spieler es selbst einschaltet (/klg log start,
-- Einstellungen "Test Log schreiben"). Das merkt LOG.byHand
local BETA = false
ns.LOG_BETA = BETA
-- v11e (K P36, S 10:55): statt fest 20000 Zeilen alles der letzten KEEP_H Stunden, harte Grenze MAXL. Beim Kuerzen zuerst
-- ganze Sitzungen aelter als KEEP_H, dann Takt Zeilen (THIN) alter Sitzungen ausduennen, zuletzt von vorne kuerzen.
-- Ausgeduennte Zeilen stehen je Sitzung in LOG.sess[si].gone (Folge Nummern), damit die Auswertung die Luecken kennt.
local MAXL = 60000
local KEEP_H = 48
local MAXB = 9000000 -- alle Zeilen zusammen (Datei bis etwa 9 MB, Ladezeit im LT ansehen)
local THIN = { POS = true, BUFFS = true, GPS = true, MARKE = true, ZIELKNOPF = true }
local BIG_HINT_LINES = 30000 -- ab so vielen Zeilen seit dem Einloggen ein Hinweis (/reload sichert)
local LINE_OVH = 12 -- so viel schreibt das Spiel pro Zeile dazu ("...", -- [123])
local MAXLEN = 700 -- eine Zeile hoechstens so lang
-- pro Sitzung hoechstens so viele Zeilen je Art, der Rest wird nur gezaehlt (steht am Ende in der Zusammenfassung)
local CAP = { HINWEIS = 400, RECHNER = 600, PFEIL = 600, QUEST = 1200, NPC = 300, ZONE = 300, RUCKLER = 80, FEHLER = 450,
  BLOCKIERT = 40, GPS = 60, BUFFS = 80, ROUTE = 300, RECHNEN = 500, PLAN = 200, SCHRITT = 2500, GRIND = 300, REISE = 400,
  TOD = 120, NACHRICHT = 120, PROFIL = 100, GRUPPE = 100, LANGSAM = 100, HAENGT = 200, STAND = 400,
  EINSTELLUNG = 300, FENSTER = 600, DARSTELLUNG = 100, POS = 1200 }
local capN, capDrop = {}, {}
-- v11e (P34): Fehler je Art einmal mit Stack, dann gezaehlt
local ERRS = {}
local ERR_UNIQ_MAX = 400
local function ErrSum()
  for k, e in pairs(ERRS) do
    if type(e) == "table" and e.n > e.said and e.n > 1 then
      e.said = e.n
      if ns.TestLog then ns.TestLog("FEHLER_ZAHL", ("%dx in dieser Sitzung: %s"):format(e.n, e.msg)) end
    end
  end
end
ns.TestLogErrSum = ErrSum
local LOG, CUR
local CR, SI -- Schluessel und Nummer der laufenden Sitzung
local SEQ = 0
local t0 = GetTime()

local function On() return LOG and LOG.on ~= false end
-- fuer andere Dateien: Test Notiz Kasten, Einstellung und Hilfe nur zeigen, wenn das Log wirklich schreibt
function ns.TestLogActive() return On() and true or false end
-- 1.0: gibt es das Log Addon (dann kann man das Log in den Einstellungen einschalten)?
function ns.TestLogAvailable() return LOG ~= nil end

-- 19.31: beim Ausloggen kennt das Spiel Ort und XP nicht mehr ("? 0,0", L1.00): dann die letzten bekannten Werte
local lastM, lastX, lastY, lastLv
local function Where()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local x, y = 0, 0
  if m then
    local p = C_Map.GetPlayerMapPosition(m, "player")
    if p then x, y = p:GetXY() end
  end
  if m and x and (x ~= 0 or y ~= 0) then lastM, lastX, lastY = m, x, y
  elseif lastM then return lastM, lastX, lastY end
  return m, x or 0, y or 0
end

local function Clean(s)
  s = tostring(s or "")
  s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("\n", " / ")
  return s
end

------------------------------------------------------------
-- Namen anonym: jeder bekannte Name (Gruppe, Absender, wer auf mich schlaegt) bekommt eine Nummer.
-- Die Liste ist nur im Speicher (nie in der Datei), darum zaehlt jede Sitzung neu.
------------------------------------------------------------
local anonMap, anonList, anonN = {}, {}, 0
local function Esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
local function AddName(name, alias)
  if type(name) ~= "string" then return nil end
  name = name:gsub("%-.*$", "")
  if #name < 2 then return nil end
  if anonMap[name] then return anonMap[name] end
  if not alias then anonN = anonN + 1; alias = ("Spieler %d"):format(anonN) end
  anonMap[name] = alias
  -- nur ganze Woerter (auch mit Umlauten), damit "Bo" nicht in "Bogen" ersetzt wird
  anonList[#anonList + 1] = { "%f[%w\128-\255]" .. Esc(name) .. "%f[^%w\128-\255]", alias }
  return alias
end
local function Anon(name) return AddName(name) or "?" end
ns.LogAnon = Anon
local function Scrub(s)
  for i = 1, #anonList do
    local e = anonList[i]
    s = s:gsub(e[1], e[2])
  end
  return s
end
local function Roster()
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  local unit = (IsInRaid and IsInRaid()) and "raid" or "party"
  for i = 1, n do
    local nm = UnitName(unit .. i)
    if nm and nm ~= UnitName("player") then AddName(nm) end
  end
end

local function LineSi(l) return tonumber(l:match("^(%d+)|")) end
-- Folge Nummer jeder Zeile (je Sitzung: ab first, gone uebersprungen)
-- Mengen nur zur Laufzeit (gespeichert sind die Listen low und gone je Sitzung)
local setC = setmetatable({}, { __mode = "k" })
local function SetOf(se, f)
  local c = setC[se]
  if not c then c = {}; setC[se] = c end
  local t = c[f]
  if not t or t.n ~= #(se[f] or {}) then
    t = { n = #(se[f] or {}) }
    for _, q in ipairs(se[f] or {}) do t[q] = true end
    c[f] = t
  end
  return t
end
local function SeqWalker()
  local nextSeq = {}
  return function(si)
    local se = LOG.sess and LOG.sess[si]
    local q = nextSeq[si] or (se and se.first) or 1
    local gs = se and SetOf(se, "gone")
    while gs and gs[q] do q = q + 1 end
    nextSeq[si] = q + 1
    return q
  end
end
local function GoneAdd(se, q)
  se.gone = se.gone or {}
  se.gone[#se.gone + 1] = q
  local gs = SetOf(se, "gone")
  gs[q] = true; gs.n = #se.gone
end
local function Trim()
  local lines = LOG.lines
  local n, b = #lines, LOG.bytes or 0
  local limN, limB = MAXL * 0.9, MAXB * 0.9
  local now = time and time() or 0
  local function Rebuild(dropFn)
    local keep, bb, walk = {}, 0, SeqWalker()
    for k = 1, #lines do
      local l = lines[k]
      local si = LineSi(l)
      local q = si and walk(si)
      if dropFn(l, si, q) then
        -- weg
      else
        keep[#keep + 1] = l
        bb = bb + #l + LINE_OVH
      end
    end
    lines, b = keep, bb
  end
  -- 1. ganze alte Sitzungen
  do
    local old = {}
    for si, se in pairs(LOG.sess or {}) do if si ~= SI and (se.t or now) < now - KEEP_H * 3600 then old[si] = true end end
    if next(old) then Rebuild(function(_, si) return si and old[si] end) end
  end
  -- 2. Takt Zeilen alter Sitzungen ausduennen
  if #lines > limN or b > limB then
    Rebuild(function(_, si, q)
      local se = si and si ~= SI and LOG.sess and LOG.sess[si]
      if se and se.low and q and SetOf(se, "low")[q] then GoneAdd(se, q); return true end
      return false
    end)
  end
  -- 3. von vorne kuerzen
  if #lines > limN or b > limB then
    local cut = 0
    local walk = SeqWalker()
    local nn, bb = #lines, b
    while cut < nn and (nn - cut > limN or bb > limB) do
      cut = cut + 1
      local l = lines[cut]
      local si = LineSi(l)
      local q = si and walk(si)
      local se = si and LOG.sess and LOG.sess[si]
      if se and q then se.first = q + 1 end
      bb = bb - #l - LINE_OVH
    end
    local keep = {}
    for k = cut + 1, nn do keep[#keep + 1] = lines[k] end
    lines, b = keep, bb
  end
  LOG.lines, LOG.bytes = lines, b
  -- Sitzungen ohne Zeilen weg (ihr Schluessel wird nicht mehr gebraucht)
  local have = {}
  for k = 1, #lines do local si = LineSi(lines[k]); if si then have[si] = true end end
  for k in pairs(LOG.sess or {}) do if k ~= SI and not have[k] then LOG.sess[k] = nil end end
end
ns.TestLogTrim = function() if LOG and LOG.lines then pcall(Trim) end end

-- neue Sitzung im Log: Nummer, Zeitstempel, eigener Schluessel (RSA laeuft nebenbei, ein Stueck pro Bild)
local function NewSession()
  if not (LOG and ns.LogCryptNew) then return end
  CR = ns.LogCryptNew()
  LOG.nextSi = (LOG.nextSi or 0) + 1
  SI = LOG.nextSi
  SEQ = 0
  local id = (date("%Y%m%d-%H%M%S") .. ("-%04x"):format(math.random(0, 65535)))
  LOG.sess = LOG.sess or {}
  LOG.sess[SI] = { id = id, t = time and time() or 0, kid = CR.kid }
  local function Step()
    if not CR or not CR.job then return true end
    if CR.job.Run(2) then
      if LOG.sess[SI] then LOG.sess[SI].k = CR.key end
      return true
    end
  end
  local tk
  tk = C_Timer.NewTicker and C_Timer.NewTicker(0.05, function() if Step() and tk then tk:Cancel() end end)
  if not tk then while not Step() do end end
end

local function L(cat, msg)
  if not On() then return end
  local c = CAP[cat]
  if c then
    local n = (capN[cat] or 0) + 1
    capN[cat] = n
    if n > c then capDrop[cat] = (capDrop[cat] or 0) + 1; return end
  end
  local m, x, y = Where()
  local lvl = UnitLevel("player") or 0
  local xp, mx = UnitXP("player") or 0, UnitXPMax("player") or 1
  local lv = lvl + (mx > 0 and xp / mx or 0)
  -- 19.31: beim Ausloggen fehlt die XP (Level x.00 statt x.56): letzter Wert, wenn er zum gleichen Level passt
  if lastLv and math.floor(lastLv) == lvl and xp == 0 and lastLv > lv then lv = lastLv else lastLv = lv end
  local txt = Scrub(Clean(msg))
  if #txt > MAXLEN then txt = txt:sub(1, MAXLEN) .. " ..." end
  local plain = ("%s +%ds L%.2f %s %d,%d | %s | %s"):format(date("%H:%M:%S"), math.floor(GetTime() - t0),
    lv, tostring(m or "?"), math.floor(x * 1000), math.floor(y * 1000), cat, txt)
  if not CR then NewSession() end
  if not CR then return end
  SEQ = SEQ + 1
  local line = SI .. "|" .. ns.LogCryptSeal(CR, SEQ, plain)
  if LOG.sess[SI] then
    LOG.sess[SI].n = SEQ
    -- v11e (P36): Takt Zeilen merken, die duerfen beim Kuerzen zuerst raus
    if THIN[cat] then local se = LOG.sess[SI]; se.low = se.low or {}; se.low[#se.low + 1] = SEQ end
  end
  local lines = LOG.lines
  lines[#lines + 1] = line
  LOG.bytes = (LOG.bytes or 0) + #line + LINE_OVH
  if #lines > MAXL or LOG.bytes > MAXB then Trim() end
  if CUR then
    CUR.lines = (CUR.lines or 0) + 1
    -- v11e (P36): grosses Log seit dem Einloggen: Hinweis, /reload sichert (nicht im Kampf, hoechstens 1x pro Std)
    if CUR.lines >= BIG_HINT_LINES and not (InCombatLockdown and InCombatLockdown()) and GetTime() - (CUR.bigHintAt or -99999) > 3600 then
      CUR.bigHintAt = GetTime()
      if ns.Print then ns.Print(TR"Test Log ist gross, /reload sichert es.") end
    end
  end
end
ns.TestLog = L

------------------------------------------------------------
-- Nachrichten zwischen Spielern zaehlen (rein, raus, abgelehnt mit Grund)
------------------------------------------------------------
local MSG = { inG = 0, inS = 0, outG = 0, outS = 0, rej = {} }
local MSG_PREFIX = { TaurenRt = "G", FWWege = "S" }
function ns.MsgReject(why)
  why = tostring(why or "?")
  MSG.rej[why] = (MSG.rej[why] or 0) + 1
end
local msgLast = ""
local syncLast = {}
local function MsgLine(final)
  local S = ns.SyncStats
  local parts = {}
  -- Wege Sync zaehlt selber (Kanal und Gilde)
  if S then
    for _, k in ipairs({ "bad", "dropped", "secret" }) do
      local d = (S[k] or 0) - (syncLast[k] or 0)
      if d > 0 then MSG.rej["Wege " .. k] = (MSG.rej["Wege " .. k] or 0) + d end
      syncLast[k] = S[k] or 0
    end
  end
  local nr = 0
  for why, n in pairs(MSG.rej) do parts[#parts + 1] = why .. " " .. n; nr = nr + n end
  table.sort(parts)
  -- Wege: Addon Nachrichten (Gilde, Gruppe) plus Kanal (zaehlt Sync selber)
  local wIn, wOut = MSG.inS + (S and S.readable or 0), MSG.outS + (S and S.sent or 0)
  local s = ("rein Gruppe %d, Wege %d, raus Gruppe %d, Wege %d, abgelehnt %d%s"):format(MSG.inG, wIn, MSG.outG, wOut, nr,
    #parts > 0 and (": " .. table.concat(parts, ", ")) or "")
  if CUR then CUR.msgIn, CUR.msgOut, CUR.msgRej = MSG.inG + wIn, MSG.outG + wOut, nr end
  if s ~= msgLast and (final or MSG.inG + wIn + MSG.outG + wOut + nr > 0) then msgLast = s; L("NACHRICHT", s) end
end

------------------------------------------------------------
-- Was laeuft gerade: Schritt der Route
------------------------------------------------------------
local function StepInfo()
  local db = ns.db
  local opt = db and db.opt
  if not (opt and opt.steps) then return nil end
  local idx = opt.idx or 1
  local s = opt.steps[idx]
  if not s then return idx, TR"Route fertig", nil end
  local ok, txt = pcall(ns.OptStepText or function() return "?" end, s)
  return idx, ok and txt or "?", s
end

local function ActPos()
  local db = ns.db
  local opt = db and db.opt
  local s = opt and opt.steps and opt.steps[opt.idx or 1]
  if s and s.map and s.x and s.y then return s.map, s.x, s.y end
end

local function Dist()
  local am, ax, ay = ActPos()
  if not am or not ns.WorldDist then return end
  local m, x, y = Where()
  if not m then return end
  local ok, d = pcall(ns.WorldDist, { m, x, y }, { am, ax, ay })
  return ok and d or nil
end

-- Schritt als kurzer Schluessel (fuer "was hat sich an der Route geaendert")
local function StepKey(s)
  local a = s.acts and s.acts[1]
  return ("%s:%d:%d:%s:%s"):format(tostring(s.map), math.floor((s.x or 0) * 200), math.floor((s.y or 0) * 200),
    a and tostring(a.k) or "", a and tostring(a.qid or a.mob or a.quest or "") or "")
end
local NEXT = 15
local function Upcoming(opt)
  local t = {}
  if not (opt and opt.steps) then return t end
  local i0 = opt.idx or 1
  for i = i0, math.min(#opt.steps, i0 + NEXT - 1) do t[#t + 1] = StepKey(opt.steps[i]) end
  return t
end

-- Gesamt XP (Level eingerechnet), wie die Route sie fuer Grind Bloecke nimmt
local function AbsXP()
  local L0 = UnitLevel("player") or 1
  return ((ns.xpTotal and ns.xpTotal[L0]) or 0) + (UnitXP("player") or 0)
end

-- Grund fuer ein Neu Rechnen: wer hat gerufen (Datei und Zeile, ohne dieses Log)
local WHY_FILE = { CharTab = "Knopf oder Einstellung", UI = "Mini Fenster Menue", Setup = "Einrichtung", Unlocks = "Tempo, Grinden oder Modus",
  Core = "Befehl", Farm = "Farmen zu Ende", Rep = "Ruf zu Ende", Gear = "Ausruestung", UpgradeHelper = "Ausruestung", Gold = "Gold",
  GroupRoute = "Gruppe", Hints = "Hinweis Knopf", QuestieBridge = "Questie Daten", Arrow = "Route fertig", Optimizer = "Route" }
local function Caller()
  if not debugstack then return "?" end
  local ok, s = pcall(debugstack, 2, 6, 0)
  if not ok or type(s) ~= "string" then return "?" end
  for f, ln in s:gmatch("([%w_]+)%.lua\"?%]?:(%d+)") do
    if f ~= "DebugLog" then return (WHY_FILE[f] or f) .. " (" .. f .. ".lua:" .. ln .. ")" end
  end
  return "?"
end
local whyLast, whyT = nil, -999
local function SetWhy(w) whyLast, whyT = w, GetTime() end
ns.TestLogWhy = SetWhy
-- 19.31 (Saschas Log: 17 von 42 Rechnungen "ohne bekannten Anlass"): ein Fahrplan rechnet Abschnitt fuer Abschnitt, das
-- dauert oft laenger als 8 s. Solange er rechnet, gilt der Anlass vom Anfang weiter
local function Why()
  if whyLast and (GetTime() - whyT < 8 or ns.planBuilding) then return whyLast end
  return "ohne bekannten Anlass"
end

------------------------------------------------------------
-- Ueberwachung jede Sekunde
------------------------------------------------------------
local last = { idx = nil, txt = nil, since = GetTime(), est = 0, bestD = nil, bestT = GetTime(), slowWarn = false, lastOpt = nil }
local optStart
-- Werte pro Schritt: gelaufen, Kampfzeit, Kills
local stepStat = { walk = 0, fight = 0, kills = 0, from = nil }
-- 19.31 (Sim Befund 22:54: im Sim Log stehen Kills 0 und gelaufen 0 yd): der Sim springt grosse Stuecke und kennt kein
-- Kampf Log. Er meldet Kills und Laufweg hiermit selbst. Im Spiel ruft das niemand auf
function ns.TestLogAddKill(n) if stepStat then stepStat.kills = stepStat.kills + (n or 1) end end
function ns.TestLogAddWalk(yd) if stepStat and yd and yd > 0 then stepStat.walk = stepStat.walk + yd end end
local lastPos
local lastHit -- wer zuletzt auf mich geschlagen hat (Mob Name, bei Spielern "Spieler N")
local winXP, winT, winStart = 0, GetTime(), nil
local lastHint, lastGPS
-- XP Summe ueber Level Aufstiege hinweg (fuer XP pro Stunde im Stand)
local xpSum, xpLast, xpLastMax = 0, nil, nil
local function XPTotal()
  local cur, mx = UnitXP("player") or 0, UnitXPMax("player") or 1
  if xpLast then
    if cur >= xpLast then xpSum = xpSum + (cur - xpLast)
    else xpSum = xpSum + ((xpLastMax or xpLast) - xpLast) + cur end -- Level hoch
  end
  xpLast, xpLastMax = cur, mx
  return xpSum
end
local tickMs, tickN, tickMax = 0, 0, 0

-- Grind Block fertig: geplant gegen echt
local function GrindDone(how)
  local g = last.gr
  if not g then return end
  last.gr = nil
  local real = (GetTime() - g.t) / 60
  local got = XPTotal() - g.xp
  local why = g.act and g.act.gTimeUp and "Zeit um" or (how == "von selbst" and "XP erreicht") or how
  L("GRIND", ("%s fertig: geplant %d Min und %d XP, echt %.1f Min und %d XP, Kampf %ds, Kills %d, Ende: %s"):format(
    g.hint and "Hinweis Level fehlt" or (g.warm and "Grinden bis Quests gehen" or "Grind Pause"), g.min or 0, math.max(0, g.plan or 0),
    real, got, math.floor(stepStat.fight), stepStat.kills, tostring(why)))
  if CUR then
    CUR.grindN = (CUR.grindN or 0) + 1
    CUR.grindPlan = (CUR.grindPlan or 0) + (g.min or 0)
    CUR.grindReal = (CUR.grindReal or 0) + real
  end
end

-- Pfeil Ziel als Text mit Grund (aus dem Pfeil: ns.arrowNow, ns.arrowSrc)
-- dieselben Texte wie im Pfeil (in der Sprache vom Spiel)
local A_CORPSE = Clean(TR"|cffb0b0b0Zur Leiche|r")
local A_GOLD = (TR"Gold: %s (%s)"):match("^(.-)%%s") or "Gold"
local A_DETOUR = Clean(TR"\n|cff9d9d9dauf bekanntem Weg um das Gelände|r")
local A_VIA = Clean(TR"\n|cff9d9d9dzuerst zum Übergang in die nächste Zone|r")
-- 19.31: neuer Text mit Zonen ("Ziel in %s, zuerst nach %s"), erkannt am Anfang
local A_VIA2 = Clean((TR"Ziel in %s, zuerst nach %s"):match("^(.-)%%s") or "Ziel in")
local function ArrowKind(src, name)
  if not name then return "kein Ziel" end
  if name:find(A_CORPSE, 1, true) then return "Tod, zur Leiche" end
  if src == "svc" then return "Service Ziel" end
  if name:sub(1, #A_GOLD) == A_GOLD then return "Gold Stopp" end
  if src == "opt" then return "Route" end
  return tostring(src or "anderes")
end

------------------------------------------------------------
-- Einstellungen, Fenster und Darstellung (alle 2 Sekunden, billig)
------------------------------------------------------------
local SETKEYS = { "mode", "levelStep", "goal", "grind", "dungeonQ", "escorts", "contSwitch", "books", "hudGroup", "hudSize", "hud", "look", "arrow", "useHearth", "useFlights", "naviPorts",
  "walkPaths", "escorts", "contSwitch", "eventQuests", "eliteGroup", "eliteSolo", "logMax", "logWarn", "profOn", "allSettings", "testerBox", "slowPC",
  "showGrind", "planOn", "pinIcons", "optMode", "noMountPlan", "markBags", "mapShow", "mapBooks", "hudLocked", "hudScale", "groupSync", "gearHints",
  "farmAH", "autoShare", "autoQuestAll", "autoQuest", "bookYards", "radius", "questFirst", "trainerPopup", "unlockHints", "weaponHint", "paused",
  "hudVendor", "hudSleep", "miniShow", "noticeWin", "mobDanger", "patrolWarn", "minimap", "goldMode", "hudExt" }
local setLast
local function Val(v) if type(v) == "table" then return "{..}" end return tostring(v) end
local win = { big = false, page = nil, pageT = 0, bigT = 0, hud = nil, hudKey = nil, setup = false, map = false, seenCut = {}, outShown = {} }
-- abgeschnittene Texte in einem Fenster (nur sichtbare), hoechstens n Beispiele
local function CutTexts(frame, n)
  local hits, cnt, seen = {}, 0, 0
  local function Scan(f, depth)
    if depth > 14 or seen > 2500 or not f.IsVisible or not f:IsVisible() then return end
    for _, r in ipairs({ f:GetRegions() }) do
      seen = seen + 1
      -- 19.31: Texte mit Tooltip beim Drueberfahren (fwTip) zaehlen nicht als abgeschnitten
      if r.IsTruncated and r.IsVisible and r:IsVisible() and not r.fwTip then
        local okT, tr = pcall(r.IsTruncated, r)
        if okT and tr then
          cnt = cnt + 1
          if #hits < n then hits[#hits + 1] = Clean(r:GetText() or ""):sub(1, 60) end
        end
      end
    end
    for _, c in ipairs({ f:GetChildren() }) do Scan(c, depth + 1) end
  end
  pcall(Scan, frame, 0)
  return cnt, hits
end
-- ragt ein Fenster aus dem Bild?
local function OutOfScreen(f)
  if not (f and f.IsVisible and f:IsVisible() and f.GetLeft and UIParent) then return nil end
  local sc = (f:GetEffectiveScale() or 1) / math.max(0.01, UIParent:GetEffectiveScale() or 1)
  local l, r, t, b = f:GetLeft(), f:GetRight(), f:GetTop(), f:GetBottom()
  if not (l and r and t and b) then return nil end
  l, r, t, b = l * sc, r * sc, t * sc, b * sc
  local W, H = UIParent:GetWidth() or 0, UIParent:GetHeight() or 0
  local out = {}
  if l < -2 then out[#out + 1] = ("links %d"):format(math.floor(-l)) end
  if r > W + 2 then out[#out + 1] = ("rechts %d"):format(math.floor(r - W)) end
  if t > H + 2 then out[#out + 1] = ("oben %d"):format(math.floor(t - H)) end
  if b < -2 then out[#out + 1] = ("unten %d"):format(math.floor(-b)) end
  return #out > 0 and table.concat(out, ", ") or nil
end
local cutN = 0
local function CheckLook(name, frame, key)
  if win.seenCut[key] or cutN > 150 then return end
  win.seenCut[key] = true
  cutN = cutN + 1
  local n, hits = CutTexts(frame, 5)
  if n > 0 then L("DARSTELLUNG", ("%s: %d Texte abgeschnitten: %s"):format(name, n, table.concat(hits, " / "))) end
  local o = OutOfScreen(frame)
  if o then L("DARSTELLUNG", ("%s ragt aus dem Bild (%s)"):format(name, o)) end
end
local function WatchUI()
  local db = ns.db
  -- Einstellungen: jede Aenderung mit altem und neuem Wert
  local cur = {}
  for _, k in ipairs(SETKEYS) do cur[k] = Val(db[k]) end
  if setLast then
    for _, k in ipairs(SETKEYS) do
      if cur[k] ~= setLast[k] then L("EINSTELLUNG", ("%s: %s -> %s"):format(k, setLast[k], cur[k])) end
    end
  end
  setLast = cur
  -- grosses Fenster: auf, zu, Seite und wie lange
  local big = _G.TaurenRouteBig
  local bigOn = big and big:IsShown() or false
  local page = bigOn and ns.BigViewName and ns.BigViewName() or nil
  local now = GetTime()
  if bigOn ~= win.big then
    if bigOn then win.bigT = now; L("FENSTER", ("grosses Fenster auf, Seite %s"):format(tostring(page)))
    else L("FENSTER", ("grosses Fenster zu nach %ds (Seite %s %ds)"):format(math.floor(now - win.bigT), tostring(win.page), math.floor(now - win.pageT))) end
    win.big = bigOn
  elseif bigOn and page ~= win.page and win.page then
    L("FENSTER", ("Seite %s (vorher %s, %ds)"):format(tostring(page), tostring(win.page), math.floor(now - win.pageT)))
  end
  if page ~= win.page then win.page, win.pageT = page, now end
  if bigOn and page then CheckLook("Seite " .. tostring(page), big, "big:" .. tostring(page) .. ":" .. tostring(db.look)) end
  -- Mini Fenster: an, aus, Groesse, Massstab, Ort
  local hud = _G.TaurenRouteHUD
  if hud then
    local shown = hud:IsShown() and true or false
    local l, t = hud:GetLeft(), hud:GetTop()
    local key = ("%s %s %.2f %s,%s"):format(tostring(shown), tostring(db.hudSize or "normal"), hud:GetScale() or 1,
      l and math.floor(l / 20) * 20 or "?", t and math.floor(t / 20) * 20 or "?")
    if key ~= win.hudKey then
      if win.hudKey then
        L("FENSTER", ("Mini Fenster %s, Groesse %s, Massstab %.2f, Ort %s,%s"):format(shown and "an" or "aus", tostring(db.hudSize or "normal"),
          hud:GetScale() or 1, l and math.floor(l) or "?", t and math.floor(t) or "?"))
      end
      win.hudKey = key
    end
    if shown then CheckLook("Mini Fenster " .. tostring(db.hudSize or "normal"), hud, "hud:" .. key) end
  end
  -- Einrichtung und Weltkarte
  local setupW = _G.ForeverWegweiserSetup or _G.TaurenRouteSetup
  local su = setupW and setupW:IsShown() or false
  if su ~= win.setup then win.setup = su; L("FENSTER", su and "Einrichtung offen" or "Einrichtung zu") end
  local mp = WorldMapFrame and WorldMapFrame:IsShown() or false
  if mp ~= win.map then
    if mp then win.mapT = now; L("FENSTER", "Karte auf") else L("FENSTER", ("Karte zu nach %ds"):format(math.floor(now - (win.mapT or now)))) end
    win.map = mp
  end
end
local uiTick = 0

local function Tick()
  if not On() then return end
  local db = ns.db
  if not db then return end
  local tStart = debugprofilestop and debugprofilestop()
  -- 19.30 (Auswertung: Heatmap und Replay): Position alle 15 s, solange du dich bewegst, sonst alle 60 s. Ort und Level
  -- stehen wie in jeder Zeile vorne, dazu Tempo in Yards pro Sekunde, beritten, schwimmend, Geist, Flug (je 1 oder 0)
  do
    local now = GetTime()
    local spd = ns.Api.GetUnitSpeed and ns.Api.GetUnitSpeed("player") or 0
    local gap = (spd and spd > 0) and 15 or 60
    if not last.posAt or now - last.posAt >= gap then
      last.posAt = now
      local function B(f, ...) if not f then return 0 end local ok, v = pcall(f, ...); return (ok and v) and 1 or 0 end
      L("POS", ("Tempo %.1f, beritten %d, schwimmt %d, Geist %d, Flug %d"):format(spd or 0, B(IsMounted), B(IsSwimming),
        B(UnitIsGhost, "player"), B(UnitOnTaxi, "player")))
    end
  end
  uiTick = uiTick + 1
  if uiTick % 2 == 0 then local okU, eU = pcall(WatchUI); if not okU then L("FEHLER", "Log Fenster: " .. tostring(eU)) end end
  -- neue Meldungen vom Optimierer
  local ol = ns.optLog
  if ol and #ol > 0 and ol[#ol] ~= last.lastOpt then
    local from = #ol
    for i = #ol, 1, -1 do
      if ol[i] == last.lastOpt then break end
      from = i
    end
    for i = from, #ol do L("RECHNER", ol[i]) end
    last.lastOpt = ol[#ol]
  end
  -- Route ausgetauscht oder umgebaut: wie viel bleibt gleich?
  local opt = db.opt
  local rk = opt and (tostring(opt) .. "#" .. #(opt.steps or {})) or "none"
  local routeNew = false
  local openNow = opt and math.max(0, #(opt.steps or {}) - (opt.idx or 1) + 1) or 0
  if rk ~= last.routeKey then
    local up = Upcoming(opt)
    if last.routeKey then
      local old = {}
      for _, k in ipairs(last.up or {}) do old[k] = true end
      local same = 0
      for _, k in ipairs(up) do if old[k] then same = same + 1 end end
      local replaced = opt ~= last.optRef
      -- alles was vorher offen war bleibt, nur hinten kommt mehr dazu (Gruppen Route vom Leiter nachgeladen): keine echte Änderung
      local nOld = #(last.up or {})
      local longer = opt and nOld > 0 and same >= math.min(nOld, #up) - 1 and openNow >= (last.openN or 0)
      routeNew = not longer
      L("ROUTE", ("%s: %s, %d Schritte offen (vorher %d), von den naechsten %d gleich %d, Grund: %s"):format(
        not opt and "keine Route" or (longer and "Route verlaengert" or (replaced and "neue Route" or "Route geaendert")), opt and Clean(opt.title or "?") or "-",
        openNow, last.openN or 0, #up, same, Why()))
    end
    last.routeKey, last.optRef, last.up = rk, opt, up
  elseif opt and (opt.idx or 1) ~= last.upIdx then
    -- weiter in derselben Route: Vergleichsliste nachziehen
    last.up = Upcoming(opt)
  end
  last.openN, last.upIdx = openNow, opt and (opt.idx or 1) or nil
  -- Profil gewechselt (Leveling oder Tour)
  local pc = db.profileCur or "level"
  if pc ~= last.prof then
    if last.prof then L("PROFIL", ("%s -> %s: %s"):format(last.prof, pc, opt and Clean(opt.title or "?") or "-")) end
    last.prof = pc
  end
  -- Schritt Wechsel
  local idx, txt, s = StepInfo()
  -- derselbe Schritt bleibt derselbe, auch wenn die Zahl im Text steigt (Eber 1/10, 2/10 ...)
  local key = tostring(idx) .. "|" .. (s and tostring(s) or tostring(txt))
  if key == last.key then last.txt = txt end
  local stepNew = false
  if key ~= last.key then
    stepNew = true
    local how = (last.how and GetTime() - (last.howT or 0) < 3 and last.how) or (routeNew and "neue Route") or "von selbst"
    last.how = nil
    if last.key and last.idx and last.txt then
      local used = GetTime() - last.since
      local slow = (last.est or 0) > 30 and used > last.est * 2
      local lvNow = (UnitLevel("player") or 0) + (UnitXP("player") or 0) / math.max(1, UnitXPMax("player") or 1)
      local lvPlan = last.lvlPlan
      L("SCHRITT", ("fertig (%s) nach %ds (geschaetzt %ds)%s, gelaufen %d yd (Luftlinie %s), Kampf %ds, Kills %d, XP %d, Level geplant %s echt %.2f: %s"):format(how, math.floor(used), math.floor(last.est or 0),
        slow and " ZU LANGSAM" or "", math.floor(stepStat.walk),
        stepStat.line and tostring(math.floor(stepStat.line)) or "?", math.floor(stepStat.fight), stepStat.kills, XPTotal() - (last.xp0 or XPTotal()),
        lvPlan and ("%.2f"):format(lvPlan) or "?", lvNow, tostring(last.txt)))
      if CUR and lvPlan then CUR.lvlDiff = (CUR.lvlDiff or 0) + (lvNow - lvPlan); CUR.lvlN = (CUR.lvlN or 0) + 1 end
      GrindDone(how)
      if CUR then
        CUR.steps = (CUR.steps or 0) + 1
        local k = ({ ["von selbst"] = "auto", ["weiter von Hand"] = "manual", ["zurueck von Hand"] = "manual", ["uebersprungen"] = "skip", ["neue Route"] = "replaced" })[how] or "auto"
        CUR[k] = (CUR[k] or 0) + 1
        if slow then CUR.slow = (CUR.slow or 0) + 1 end
      end
    end
    if idx then L("SCHRITT", ("neu %d/%d: %s"):format(idx, #(db.opt.steps or {}), tostring(txt))) end
    last.key, last.idx, last.txt, last.since = key, idx, txt, GetTime()
    last.xp0, last.lvlPlan = XPTotal(), s and s.lvl
    -- s.t ist die Zeit seit Routen Start, Dauer = Abstand zum Schritt davor
    local prev = idx and db.opt.steps[idx - 1]
    last.est = s and (s.t or 0) - (prev and prev.t or 0) or 0
    last.bestD, last.bestT, last.slowWarn = nil, GetTime(), false
    stepStat.walk, stepStat.fight, stepStat.kills = 0, 0, 0
    stepStat.line = Dist()
    -- Grind Block startet: Plan merken
    last.gr = nil
    for _, a in ipairs(s and s.acts or {}) do
      if a.k == "G" and not a.farm and not a.repFarm then
        last.gr = { act = a, min = a.min, t = GetTime(), xp = XPTotal(), plan = a.untilXP and (a.untilXP - AbsXP()) or nil, hint = a.hint, warm = a.warm }
        break
      end
    end
  end
  -- Pfeil Ziel gewechselt (Zahlen wie Entfernung oder 3/8 zaehlen nicht, Umweg Zeile auch nicht)
  if not ns.Api.U(UnitOnTaxi, "player") then
    local an, asrc = ns.arrowNow, ns.arrowSrc
    local first = an and Clean(an):gsub(" / .*$", "") or nil
    local ak = first and (tostring(asrc) .. "|" .. first:gsub("%d+", "#")) or "none"
    if ak ~= last.arrowKey then
      local ca = an and Clean(an)
      local sub = ca and ((ca:find(A_DETOUR, 1, true) and ", Umweg ums Gelaende") or ((ca:find(A_VIA, 1, true) or ca:find(A_VIA2, 1, true)) and ", ueber den Zonen Uebergang")) or ""
      if last.arrowKey or ak ~= "none" then
        L("PFEIL", ("%s%s, %s: %s"):format(ArrowKind(asrc, an and Clean(an)), sub, stepNew and "neuer Schritt" or (routeNew and "neue Route" or "im Schritt"), first or "-"))
      end
      last.arrowKey = ak
    end
  end
  -- gelaufen und Kampfzeit
  local m, x, y = Where()
  if m and lastPos and ns.WorldDist and not ns.Api.U(UnitOnTaxi, "player") then
    local ok, dd = pcall(ns.WorldDist, lastPos, { m, x, y })
    if ok and dd and dd < 60 then stepStat.walk = stepStat.walk + dd end
  end
  lastPos = m and { m, x, y } or nil
  if ns.Api.U(UnitAffectingCombat, "player") then stepStat.fight = stepStat.fight + 1 end
  -- welcher Hinweis steht oben im Fenster
  if ns.TopHint and not ns.Api.U(UnitAffectingCombat, "player") then
    local ok, h = pcall(ns.TopHint)
    local ht = ok and type(h) == "table" and (h.text or h[1]) or (ok and type(h) == "string" and h) or nil
    -- Zahlen (Restzeit, Entfernung) zaehlen nicht als neuer Hinweis, sonst steht jede Sekunde eine Zeile drin
    local hk = ht and ht:gsub("%d", "")
    if hk ~= lastHint then lastHint = hk; if ht then L("HINWEIS", ht) end end
  end
  -- alle 5 Minuten: Stand
  local xpNow = XPTotal() -- jede Sekunde, damit Level Aufstiege sauber mitgezaehlt werden
  if not winStart then winStart = xpNow; winT = GetTime() end
  if CUR then CUR.sec = math.floor(GetTime() - t0); CUR.L1 = (UnitLevel("player") or 0) + ((UnitXP("player") or 0) / math.max(1, UnitXPMax("player") or 1)); CUR.xp = xpNow end
  if GetTime() - winT >= 300 then
    local gained = XPTotal() - winStart
    local mem = 0
    -- Lua Speicher aller Addons (billig). UpdateAddOnMemoryUsage geht durch den ganzen Speicher und ruckelt.
    if collectgarbage then mem = math.floor(collectgarbage("count")) end
    local free = 0
    for b = 0, 4 do
      local f = (C_Container and C_Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots)
      if f then free = free + (f(b) or 0) end
    end
    -- Buffs mitschreiben: so sehen wir, wie die Forever Boni im Spiel heissen (Essen, Schlafsack, Zelt)
    local bl = {}
    if ns.PlayerAuras then
      local okA, list = pcall(ns.PlayerAuras)
      for _, a in ipairs(okA and list or {}) do if #bl < 12 then bl[#bl + 1] = tostring(a.name) .. ((a.count or 0) > 1 and (" x" .. a.count) or "") end end
    end
    local xb = {}
    for _, x in ipairs(ns.XPBuffs and ns.XPBuffs() or {}) do xb[#xb + 1] = ("%s +%.0f %% noch %d Min"):format(x.kind, x.pct * 100, math.floor((x.left or 0) / 60)) end
    if #bl > 0 then L("BUFFS", table.concat(bl, ", ") .. (#xb > 0 and ("  (XP Buffs: " .. table.concat(xb, ", ") .. ")") or "")) end
    L("STAND", ("XP pro Std echt %d, Route sagt %d, %d fps, Speicher %d KB, Taschen frei %d, Gold %s, Questlog %d, Log Takt %.2f ms (hoechstens %.1f), Log %d KB"):format(
      math.floor(gained * 3600 / (GetTime() - winT)), math.floor(opt and opt.rate or 0), math.floor(GetFramerate() or 0),
      math.floor(mem), free, ns.Money and ns.Money(GetMoney() or 0) or tostring(GetMoney()),
      (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and select(2, C_QuestLog.GetNumQuestLogEntries())) or (GetNumQuestLogEntries and select(2, GetNumQuestLogEntries())) or 0,
      tickN > 0 and tickMs / tickN or 0, tickMax, math.floor((LOG.bytes or 0) / 1024)))
    tickMs, tickN, tickMax = 0, 0, 0
    -- welche Takte waren in den letzten 5 Minuten langsam (ueber 40 ms)?
    if ns.slowCount and next(ns.slowCount) then
      local t = {}
      for site, n in pairs(ns.slowCount) do t[#t + 1] = site .. " x" .. n end
      table.sort(t)
      L("LANGSAM", table.concat(t, ", "))
      ns.slowCount = {}
    end
    MsgLine()
    winStart, winT = XPTotal(), GetTime()
  end
  -- haengt: kommt dem Ziel 90 Sekunden nicht naeher (nicht im Kampf, nicht tot, nicht auf Reise)
  local d = Dist()
  if d then
    -- 17.4: bei Sammel und Kill Zielen zaehlt Fortschritt (5/10 -> 6/10) als weiter kommen, Mobs suchen im Gebiet ist kein Haengen
    local prog = type(last.txt) == "string" and last.txt:match("(%d+)/%d+") or nil
    if prog ~= last.prog then
      last.prog = prog
      if prog and last.bestT then last.bestT, last.bestWalk = GetTime(), stepStat.walk end
    end
    if not last.bestD or d < last.bestD - 15 then
      last.bestD, last.bestT, last.bestWalk = d, GetTime(), stepStat.walk
    elseif d > 40 and not last.slowWarn and GetTime() - last.bestT > 90
      and stepStat.walk - (last.bestWalk or 0) > 30 -- nur wenn er sich bewegt, nicht wenn er einfach steht
      and not ns.Api.U(UnitAffectingCombat, "player") and not ns.Api.U(UnitIsDeadOrGhost, "player") and not ns.Api.U(UnitOnTaxi, "player") then
      last.slowWarn = true
      L("HAENGT", ("90s nicht naeher ans Ziel, noch %d Yards: %s"):format(math.floor(d), tostring(last.txt)))
      if CUR then CUR.stuck = (CUR.stuck or 0) + 1 end
    end
  end
  if tStart then
    local ms = debugprofilestop() - tStart
    tickMs, tickN = tickMs + ms, tickN + 1
    if ms > tickMax then tickMax = ms end
  end
end

------------------------------------------------------------
-- Ruckler: ein Bild dauert ueber 0.25 s
------------------------------------------------------------
local hitchFrame = CreateFrame("Frame")
local hitchCount, hitchLast = 0, 0
hitchFrame:SetScript("OnUpdate", function(_, el)
  if el > 0.25 and On() and GetTime() - t0 > 20 then
    hitchCount = hitchCount + 1
    if CUR then CUR.hitch = hitchCount end
    if GetTime() - hitchLast > 5 then
      hitchLast = GetTime()
      local sl = ns.slowLast
      local who = (sl and GetTime() - sl.t < 1.5) and ("  langsam: " .. sl.site .. (" %d ms"):format(sl.ms)) or ""
      L("RUCKLER", ("Bild %.2fs, %s, %d fps"):format(el, (optStart and GetTime() - optStart < 60) and "Route wird gerechnet" or "normal", math.floor(GetFramerate() or 0)) .. who)
    end
  end
end)

------------------------------------------------------------
-- Haken an wichtigen Funktionen
------------------------------------------------------------
local function Wrap(name, pre)
  local orig = ns[name]
  if type(orig) ~= "function" or ns["fwLog" .. name] then return end
  ns["fwLog" .. name] = true
  ns[name] = function(...)
    pcall(pre, ...)
    return orig(...)
  end
end
local function Hooks()
  -- Rechnen: wie lange, wie viele Schritte, warum
  if ns.Optimize and not ns.fwLogOpt then
    ns.fwLogOpt = true
    local orig = ns.Optimize
    ns.Optimize = function(target, done, opts)
      local st = GetTime()
      optStart = st
      local o = opts or {}
      local why = Why()
      -- 20.1 (P7, Log 12:08 "Anlass ohne bekannten Anlass" bei Ruf farmen): Zusatz Route vom Knopf
      if why == "ohne bekannten Anlass" and (o.rep or o.gold or o.gearQ or o.logOnly or o.endInn) then
        why = "Zusatz Route vom Knopf (" .. ((o.rep and ("Ruf " .. Clean(o.repName or "?"))) or (o.gold and "Gold Quests") or (o.gearQ and "Ausruestung")
          or (o.logOnly and "Questlog") or "Zeit Budget") .. ")"
        SetWhy(why)
      end
      L("RECHNEN", ("Start bis Level %s, Stufe %s%s%s%s%s, Anlass %s"):format(tostring(target), tostring(o.step or (o.all and "alles") or "?"),
        o.noGrind and ", ohne Grinden" or "", o.grindProf and ", Grind Schritte" or "", o.gold and ", Gold" or "", o.gearQ and ", Ausruestung" or "", why))
      if CUR then
        CUR.recalc = (CUR.recalc or 0) + 1
        local k = why:gsub(" %(.-%)$", "")
        CUR.why[k] = (CUR.why[k] or 0) + 1
      end
      return orig(target, function(...)
        optStart = nil
        -- das Ergebnis dieser Rechnung (beim Fahrplan ein Abschnitt), nicht die laufende Route
        local res = ...
        local r = (type(res) == "table" and res.steps) and res or (ns.db and ns.db.opt)
        local dur = GetTime() - st
        if CUR and dur > (CUR.calcMax or 0) then CUR.calcMax = dur end
        L("RECHNEN", ("Fertig in %.1fs: %d Schritte, %d Quests, ca %s, %s XP/Std, bis Level %.1f"):format(dur,
          r and r.steps and #r.steps or 0, r and r.quests or 0, ns.Clock and ns.Clock(r and r.sec or 0) or "?",
          tostring(math.floor(r and r.rate or 0)), r and r.to or 0))
        -- wie die Auswahl war: wie viele Quests passten, warum andere wegfielen
        pcall(function()
          local why = ns.optWhy or {}
          local lv = why[TR"passt vom Level"] or 0
          local list = {}
          for k, v in pairs(why) do if k ~= TR"passt vom Level" then list[#list + 1] = { k, v } end end
          table.sort(list, function(a, b) return a[2] > b[2] end)
          local t = {}
          for i = 1, math.min(8, #list) do t[#t + 1] = Clean(list[i][1]) .. " " .. list[i][2] end
          local sel = {}
          for k, v in pairs(ns.optWhySel or {}) do sel[#sel + 1] = Clean(k) .. " " .. v end
          table.sort(sel)
          L("RECHNEN", ("Auswahl: %d passen vom Level, %d in der Auswahl%s%s"):format(lv, ns.optCands or 0,
            #t > 0 and ("; raus: " .. table.concat(t, ", ")) or "", #sel > 0 and ("; nicht genommen: " .. table.concat(sel, ", ")) or ""))
        end)
        if done then return done(...) end
      end, opts)
    end
  end
  if ns.AutoOpt and not ns.fwLogAuto then
    ns.fwLogAuto = true
    local orig = ns.AutoOpt
    ns.AutoOpt = function(force, ...)
      local opt = ns.db and ns.db.opt
      local kind = (force == true and "erzwungen") or (force == "auto" and "automatisch") or (force == "section" and "Abschnitt")
        or (not opt and "keine Route") or ((opt.idx or 1) > #(opt.steps or {}) and "Route fertig") or "ohne Anlass"
      -- 20.1 (Log 11:57, 9 mal "ohne Anlass, Questie Daten"): waehrend der Fahrplan rechnet, gilt sein Anlass weiter.
      -- Der Aufruf von Questie hat dort nichts gerechnet, nur den Anlass ueberschrieben
      if not (ns.planBuilding and force ~= true) then SetWhy(kind .. ", " .. Caller()) end
      return orig(force, ...)
    end
  end
  -- 20.2 (Log 14:36): nur zaehlen, wenn der Fahrplan wirklich losrechnet (Warten auf Questie oder Wege rief PlanBuild
  -- alle 1 bis 2 s nochmal auf, jedes Mal stand "Fahrplan neu" im Log)
  if ns.PlanBuild and not ns.fwLogPlanBuild then
    ns.fwLogPlanBuild = true
    local orig = ns.PlanBuild
    ns.PlanBuild = function(reason, ...)
      local w = "Fahrplan neu (" .. Clean(reason or "?") .. "), " .. Caller()
      SetWhy(w)
      local before = ns.planStartedAt
      local r = orig(reason, ...)
      if ns.planStartedAt ~= before then L("PLAN", w) end
      return r
    end
  end
  Wrap("PlanNext", function(first) local w = first and "erster Abschnitt" or "naechster Abschnitt"; SetWhy(w); L("PLAN", w) end)
  Wrap("PlanSectionLive", function() local w = "Abschnitt neu ab jetzt, " .. Caller(); SetWhy(w); L("PLAN", w) end)
  Wrap("GrindTimeUpCheck", function() SetWhy("Grind Block Zeit um") end)
  Wrap("ProfileSwitch", function(k) SetWhy("Profil gewechselt (" .. tostring(k) .. ")") end)
  Wrap("ProfileBackToLevel", function() SetWhy("zurueck zur Leveling Route") end)
  Wrap("OptLoad", function(_, info) SetWhy("Zusatz Route Start (" .. Clean(type(info) == "table" and info.title or "?") .. ")") end)
  Wrap("ExtraStop", function() SetWhy("Tour beendet") end)
  Wrap("ImportRoute", function() SetWhy("Route importiert") end)
  Wrap("OptInsertService", function(kind) SetWhy("Service Schritt eingefuegt (" .. tostring(kind) .. ")") end)
  Wrap("OptUnpin", function() SetWhy("festgehaltener Schritt geloest") end)
  -- von Hand vor, zurueck, ueberspringen: so steht beim Schritt, wie er fertig wurde
  -- (Weiter ruft intern Ueberspringen: das erste in einer halben Sekunde zaehlt)
  local function How(h) if not (last.how and GetTime() - (last.howT or 0) < 0.5) then last.how, last.howT = h, GetTime() end end
  Wrap("OptForward", function() How("weiter von Hand") end)
  Wrap("OptBack", function() How("zurueck von Hand") end)
  Wrap("OptSkip", function() How("uebersprungen") end)
  -- Weiter Knopf und andere Befehle
  if SlashCmdList.TAURENROUTE and not ns.fwLogSlash then
    ns.fwLogSlash = true
    hooksecurefunc(SlashCmdList, "TAURENROUTE", function(msg)
      if (msg or "") == "next" then L("WEITER", "von Hand weiter bei: " .. tostring(last.txt)) end
    end)
  end
  -- Nachrichten raus zaehlen
  if C_ChatInfo and C_ChatInfo.SendAddonMessage and hooksecurefunc and not ns.fwLogSend then
    ns.fwLogSend = true
    pcall(hooksecurefunc, C_ChatInfo, "SendAddonMessage", function(prefix)
      local k = MSG_PREFIX[prefix]
      if k == "G" then MSG.outG = MSG.outG + 1 elseif k == "S" then MSG.outS = MSG.outS + 1 end
    end)
  end
  -- Fehler aus dem Addon mitschreiben, die alte Fehleranzeige bleibt
  -- v11e (K P34, S 10:51, Log "nicht geschrieben: FEHLER 1331"): alle Fehler, die uns betreffen: Meldung ODER Stack geht durch
  -- unsere Dateien (auch _Log, _Farming und fremde Addons, die uns aufrufen). Gleiche Fehler einmal mit Stack, danach nur
  -- gezaehlt; alle 5 Min und beim Ausloggen eine Zeile FEHLER_ZAHL je Fehler mit neuen Treffern. Neue Fehler bis ERR_UNIQ_MAX
  if geterrorhandler and seterrorhandler and not ns.fwLogErr then
    ns.fwLogErr = true
    local prev = geterrorhandler()
    local function Ours(t)
      return type(t) == "string" and (t:find(ADDON, 1, true) or t:find("ForeverWegweiser", 1, true) or t:find("KeineZeitLevelingGuide", 1, true)) and true or false
    end
    seterrorhandler(function(msg, ...)
      -- 1.1 (P48, K 12:55): Stack hier holen, nicht im pcall, und unsere eigene Fehler Funktion weglassen. Vorher stand
      -- DebugLog.lua (dieser Handler) in JEDEM Stack, darum kamen fremde Fehler (ElvUI, Details) als unsere ins Log
      local raw = (debugstack and debugstack(2, 14, 0)) or ""
      local ok = pcall(function()
        if type(msg) ~= "string" then return end
        local keep = {}
        for ln in tostring(raw):gmatch("[^\n]+") do
          if not ln:find("DebugLog.lua", 1, true) and not ln:find("in function 'pcall'", 1, true) then keep[#keep + 1] = ln end
        end
        local stack = table.concat(keep, "\n")
        if not (Ours(msg) or Ours(stack)) then return end
        local key = msg:gsub("%d+%.%d+", "#"):sub(1, 240)
        local e = ERRS[key]
        if not e then
          ERRS.n = (ERRS.n or 0) + 1
          e = { n = 0, said = 0, msg = msg:sub(1, 300) }
          ERRS[key] = e
          if ERRS.n <= ERR_UNIQ_MAX then L("FEHLER", msg .. " / " .. Clean(stack)) end
        end
        e.n = e.n + 1
        if CUR then CUR.errors = (CUR.errors or 0) + 1 end
      end)
      if prev then return prev(msg, ...) end
    end)
  end
end

------------------------------------------------------------
-- Ereignisse
------------------------------------------------------------
local lvlStart = GetTime()
local ev = CreateFrame("Frame")
-- 1.1 (P57, K 14:33, Log 14:12:32 BLOCKIERT frueh UNKNOWN bei +0 s, Stack pcall): COMBAT_LOG_EVENT_UNFILTERED ist auf Forever
-- fuer Addons gesperrt. Das Anmelden (auch im pcall) loeste beim Laden die Blizzard Sperre aus. Nicht mehr anmelden
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_REMOVED", "PLAYER_LEVEL_UP", "PLAYER_DEAD",
  "PLAYER_ALIVE", "PLAYER_UNGHOST", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_CONTROL_LOST",
  "PLAYER_CONTROL_GAINED", "GROUP_ROSTER_UPDATE", "MERCHANT_SHOW", "TRAINER_SHOW", "TAXIMAP_OPENED",
  "CHAT_MSG_ADDON", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
  pcall(ev.RegisterEvent, ev, e)
end
local onTaxi = false
local function QName(id)
  if C_QuestLog and C_QuestLog.GetQuestInfo then return C_QuestLog.GetQuestInfo(id) end
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then return C_QuestLog.GetTitleForQuestID(id) end
end
local function InRoute(qid)
  local opt = ns.db and ns.db.opt
  if not (opt and opt.steps) then return "keine Route" end
  for i, s in ipairs(opt.steps) do
    for _, a in ipairs(s.acts or {}) do
      if a.qid == qid then return ("in Route Schritt %d"):format(i) end
    end
  end
  return "nicht in Route"
end
local function Cont(m)
  local i = 0
  while m and i < 8 and C_Map and C_Map.GetMapInfo do
    local inf = C_Map.GetMapInfo(m)
    if not inf then return nil end
    if inf.mapType == 2 then return m end
    m, i = inf.parentMapID, i + 1
  end
end

-- Zusammenfassung der letzten Sitzung (steht in LOG.cur, wird beim naechsten Start eine Zeile)
local function SumLines(c)
  local why = {}
  for k, n in pairs(c.why or {}) do why[#why + 1] = k .. " " .. n end
  table.sort(why)
  local drop = {}
  for k, n in pairs(c.drop or {}) do drop[#drop + 1] = k .. " " .. n end
  table.sort(drop)
  local sec = c.sec or 0
  return {
    ("Sitzung vom %s, %d:%02d Std, Version %s, %s, Level %.1f bis %.1f, XP %d"):format(date("%Y-%m-%d %H:%M", c.t or 0), math.floor(sec / 3600), math.floor(sec % 3600 / 60),
      tostring(c.ver), tostring(c.who), c.L0 or 0, c.L1 or 0, c.xp or 0),
    ("Schritte %d (von selbst %d, von Hand %d, uebersprungen %d, neue Route %d), zu langsam %d, haengt %d, Grind %d Bloecke geplant %d Min echt %d Min"):format(
      c.steps or 0, c.auto or 0, c.manual or 0, c.skip or 0, c.replaced or 0, c.slow or 0, c.stuck or 0, c.grindN or 0, c.grindPlan or 0, math.floor(c.grindReal or 0)),
    ("Gerechnet %d mal (laengste %.1fs)%s, Tode %d, Fehler %d, blockiert %d, Ruckler %d, Nachrichten rein %d raus %d abgelehnt %d, Zeilen %d%s"):format(
      c.recalc or 0, c.calcMax or 0, #why > 0 and (": " .. table.concat(why, ", ")) or "", c.deaths or 0, c.errors or 0, c.blocked or 0, c.hitch or 0,
      c.msgIn or 0, c.msgOut or 0, c.msgRej or 0, c.lines or 0, #drop > 0 and (", nicht geschrieben: " .. table.concat(drop, ", ")) or ""),
  }
end

local deadAt
ev:SetScript("OnEvent", function(_, e, a1, a2, a3, a4)
  if e == "PLAYER_LOGIN" then
    -- alter Ort (bis 17.1 in KeineZeitLevelingGuide.lua) ist nicht mehr gespeichert: nichts davon uebernehmen
    ForeverWegweiserLog = nil
    -- das Log gibt es nur mit dem Addon KeineZeitLevelingGuide_Log (eigene Datei)
    if type(ForeverWegweiserTestLog) ~= "table" then return end
    LOG = ForeverWegweiserTestLog
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ver = tostring(meta and meta(ADDON, "Version") or "?")
    -- neue Version oder altes Format: altes Log ganz weg (keine Reste), Schalter an oder aus bleibt
    if LOG.ver ~= ver or LOG.fmt ~= 2 then
      -- 1.0: nur ein von Hand eingeschaltetes Log bleibt an (in der Beta war es fuer alle von selbst an)
      local on, hand = LOG.on, LOG.byHand
      if not hand then on = nil end
      for k in pairs(LOG) do LOG[k] = nil end
      LOG.on, LOG.byHand, LOG.ver, LOG.fmt = on, hand, ver, 2
    end
    LOG.lines = LOG.lines or {}
    LOG.sess = LOG.sess or {}
    if LOG.on == nil then LOG.on = BETA end
    local b = 0
    for i = 1, #LOG.lines do b = b + #LOG.lines[i] + LINE_OVH end
    LOG.bytes = b
    -- v11e (P36): alte Sitzungen (ueber KEEP_H Stunden) gleich beim Laden weg
    pcall(Trim)
    if not On() then return end
    NewSession()
    -- 1.1 (P48): blockierte Aktionen von vor dem Log Start (Route.lua faengt sie ab dem Laden) jetzt nachtragen
    ns.testLogLive = true
    for _, b in ipairs(ns.blockedEarly or {}) do
      L("BLOCKIERT", ("frueh %s %s: %s, letzte Aktion %s, Stack %s"):format(tostring(b[2]), b[1] == "ADDON_ACTION_FORBIDDEN" and "verboten" or "blockiert",
        tostring(b[3]), tostring(b[4] or "unbekannt"), tostring(b[5] or "-")))
    end
    ns.blockedEarly = nil
    -- Test Kasten neben dem Mini Fenster (nur mit Log)
    if ns.TesterBoxStart then C_Timer.After(3, ns.TesterBoxStart) end
    C_Timer.After(3, function() if ns.TestLogStart then ns.TestLogStart() end end)
    return
  end
  if not On() then return end
  if e == "COMBAT_LOG_EVENT_UNFILTERED" then
    if not CombatLogGetCurrentEventInfo then return end
    local _, sub, _, sg, sn, _, _, dg = CombatLogGetCurrentEventInfo()
    local me = UnitGUID("player")
    if dg == me and sub and sub:find("_DAMAGE$") and sn then
      -- andere Spieler und Begleiter (Namen vom Spieler gewaehlt) nur anonym
      if type(sg) == "string" and sg:find("^Player") then lastHit = Anon(sn)
      elseif type(sg) == "string" and sg:find("^Pet") then lastHit = "Begleiter"
      else lastHit = sn end
    elseif sub == "PARTY_KILL" and sg == me then stepStat.kills = stepStat.kills + 1 end
    return
  end
  if e == "CHAT_MSG_ADDON" then
    local k = MSG_PREFIX[a1]
    if k then
      if type(a4) == "string" then AddName(a4) end
      if k == "G" then MSG.inG = MSG.inG + 1 else MSG.inS = MSG.inS + 1 end
    end
    return
  end
  if e == "ADDON_ACTION_BLOCKED" or e == "ADDON_ACTION_FORBIDDEN" then
    -- 1.1 (P48): fremde Addons nur kurz (hilft beim Suchen), unsere mit letzter geschuetzter Aktion
    if a1 ~= ADDON then
      L("BLOCKIERT", ("fremd %s: %s %s, Stack %s"):format(tostring(a1), e == "ADDON_ACTION_FORBIDDEN" and "verboten" or "blockiert", tostring(a2),
        tostring(ns.BlockStack and ns.BlockStack() or "-")))
      return
    end
    do
      -- 1.1: bei "UNKNOWN()" die letzte geschuetzte Aktion aus Compat.lua dazu (gleiches Bild)
      local guess = ns.Api and ns.Api.LastProt and ns.Api.LastProt()
      L("BLOCKIERT", ("%s: %s (im Kampf %s)%s"):format(e == "ADDON_ACTION_FORBIDDEN" and "verboten" or "blockiert", tostring(a2), tostring(InCombatLockdown and InCombatLockdown() or false),
        (guess and (", letzte Aktion " .. guess) or ", letzte Aktion unbekannt") .. ", Stack " .. tostring(ns.BlockStack and ns.BlockStack() or "-")))
      if CUR then CUR.blocked = (CUR.blocked or 0) + 1 end
    end
    return
  end
  if e == "MERCHANT_SHOW" then L("NPC", "Haendler offen") return end
  if e == "TRAINER_SHOW" then L("NPC", "Lehrer offen") return end
  if e == "TAXIMAP_OPENED" then L("NPC", "Flugmeister offen") return end
  ns.TestLogEvent(e, a1, a2, a3, a4)
end)

-- Sitzung starten (beim Login, oder spaeter mit /klg testlog an): Hooks, START Zeilen, 1s Takt
local started = false
function ns.TestLogStart()
  if started then return end
  started = true
  Hooks()
  local db = ns.db or {}
  local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
  local ver = tostring(meta and meta(ADDON, "Version") or "?")
  local _, cls = UnitClass("player")
  local _, race = UnitRace("player")
  -- eigener Name nie im Log
  AddName(UnitName("player"), "ich")
  Roster()
  -- Kopf: Version, Server, Sprache, Charakter, Einstellungen, Bildschirm, Addons
  local hc = C_GameRules and C_GameRules.IsHardcoreActive and C_GameRules.IsHardcoreActive()
  local server = (ns.FOREVER and "Forever" or "Era") .. (hc and " Hardcore" or "")
  L("START", ("==== Sitzung %s, Version %s, Server %s, Sprache %s, Build %s, %s %s %s, Level %d"):format(LOG.sess and LOG.sess[SI] and LOG.sess[SI].id or "?", ver, server, tostring(GetLocale and GetLocale()),
    tostring((select(4, GetBuildInfo()))), tostring(race), tostring(cls), tostring(UnitFactionGroup("player")), UnitLevel("player") or 0))
  -- v11e (K P35, S 10:51): Versionen (unser Addon, Zusatz Addons, Questie, QuestieDB, Client). Aendert sich etwas gegen die
  -- letzte Sitzung oder waehrend der Sitzung (Pruefung alle 60 s), eine Zeile VERSIONEN mit alt und neu
  do
    local function V(nm) local ok, v = pcall(meta, nm, "Version"); return ok and v or nil end
    local function Sig()
      local cver, cbuild = GetBuildInfo()
      local t = {
        ("Addon %s"):format(tostring(ver)),
        ("Log %s"):format(tostring(V(ADDON .. "_Log") or "-")),
        ("Farming %s"):format(tostring(V(ADDON .. "_Farming") or "-")),
        ("Questie %s"):format(tostring(V("Questie") or "-")),
        ("QuestieDB %s"):format(tostring(V("QuestieDB") or "-")),
        ("Client %s %s"):format(tostring(cver), tostring(cbuild)),
      }
      return table.concat(t, ", ")
    end
    local sig = Sig()
    L("VERSIONEN", sig)
    if LOG.verSig and LOG.verSig ~= sig then L("VERSIONEN", "geaendert seit der letzten Sitzung, vorher: " .. LOG.verSig) end
    LOG.verSig = sig
    if C_Timer and C_Timer.NewTicker then
      C_Timer.NewTicker(60, function()
        local okS, s2 = pcall(Sig)
        if okS and s2 ~= LOG.verSig then L("VERSIONEN", "geaendert waehrend der Sitzung, vorher: " .. tostring(LOG.verSig) .. " | jetzt: " .. s2); LOG.verSig = s2 end
      end)
      C_Timer.NewTicker(300, function() pcall(ErrSum) end)
    end
  end
  -- gleich danach: Zusammenfassung der letzten Sitzung
  if type(LOG.cur) == "table" then
    for _, s in ipairs(SumLines(LOG.cur)) do L("LETZTE", s) end
  end
  CUR = { t = time and time() or 0, ver = ver, who = tostring(race) .. " " .. tostring(cls), L0 = UnitLevel("player") or 0, why = {}, drop = capDrop, lines = 0 }
  LOG.cur = CUR
  local step = ns.LevelStep and ns.LevelStep(UnitLevel("player"))
  local si = step and ns.LEVEL_STEPS and ns.LEVEL_STEPS[step]
  L("START", ("Modus %s, Tempo %s, Grinden %s, Dungeon Quests %s, Mini Fenster %s, Look %s, Pfeil %s, GPS %s, Profil %s, Abschnitt %s, Gruppe %d"):format(
    tostring(ns.Mode and ns.Mode()), si and si.short or tostring(step), db.grind == false and "aus" or "an",
    (ns.DungeonQOn and ns.DungeonQOn()) and "an" or "aus", tostring(db.hudSize or "normal"), tostring(db.look or "auto"),
    db.arrow == false and "aus" or "an", "raus", tostring(db.profileCur or "level"),
    tostring(db.plan60 and db.plan60.curIdx or "-"), GetNumGroupMembers and GetNumGroupMembers() or 0))
  -- 19.30: Client Build, Stand und Build der Gelaende Daten, Modus, Tempo Stufe, schwacher PC (Forever Daten koennen
  -- sich mit jedem Patch aendern, so sieht die Auswertung, womit gespielt wurde)
  do
    local cver, cbuild = GetBuildInfo()
    local K = ns.Karte
    local ki = (K and K.Info and K.Info()) or {}
    local okB = K and K.BuildCheck and K.BuildCheck()
    L("START", ("Client Build %s (%s), Daten Stand %s, Daten Build %s (%s), Daten Format %s, Modus %s, Tempo %s, schwacher PC %s"):format(tostring(cbuild),
      tostring(cver), tostring(ki.stand or "?"), tostring(ki.build or "?"), okB == false and "anders als der Client" or (okB and "passt" or "unbekannt"),
      tostring(K and K.Format and K.Format() or "?"),
      tostring(ns.Mode and ns.Mode()), si and si.short or tostring(step), db.slowPC and "an" or "aus"))
  end
  -- 19.32: Daten Korrektur (Daten Chat): Stand und Anzahl, damit die Auswertung sieht, womit gerechnet wurde
  do
    local dk = ns.DKInfo and ns.DKInfo()
    L("START", dk and dk.format and ("Daten Korrektur %s, Format %s, Quests %d, Items %d%s"):format(tostring(dk.stand or "?"), tostring(dk.format),
      dk.quests or 0, dk.items or 0, dk.bad and ", Lesefehler" or "") or "Daten Korrektur: keine Datei")
  end
  do
    local okR, w, h = pcall(function() return GetPhysicalScreenSize() end)
    L("START", ("Bildschirm %s, UI Scale %.2f, Fenster %dx%d"):format(okR and w and (w .. "x" .. h) or "?", UIParent and UIParent:GetEffectiveScale() or 1,
      math.floor(UIParent and UIParent:GetWidth() or 0), math.floor(UIParent and UIParent:GetHeight() or 0)))
  end
  -- alle geladenen Addons mit Version (Namen von Addons sind keine Spieler Daten)
  do
    local num = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local info = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    local add, n = {}, 0
    if num and info and loaded then
      for i = 1, num() do
        local nm = info(i)
        if nm and loaded(nm) then
          n = n + 1
          if #add < 80 then
            local v = meta and meta(nm, "Version")
            add[#add + 1] = nm .. (v and (" " .. tostring(v)) or "")
          end
        end
      end
    end
    L("START", ("Addons %d: %s%s"):format(n, table.concat(add, ", "), n > #add and (", und " .. (n - #add) .. " weitere") or ""))
  end
  L("START", "Namen anderer Spieler stehen als Spieler 1, Spieler 2 (pro Sitzung neu gezaehlt), keine Chat Texte")
  ns.Ticker(1, function() if not On() then return end local ok, err = pcall(Tick); if not ok then L("FEHLER", "Log Tick: " .. tostring(err)) end end)
end

function ns.TestLogEvent(e, a1, a2, a3)
  if e == "PLAYER_LOGOUT" then
    pcall(ErrSum)
    -- beim Ausloggen darf es kurz haken: Speicher genau messen (erst aufraeumen, dann pro Addon)
    local okM, msg = pcall(function()
      collectgarbage("collect")
      local total = collectgarbage("count")
      local up = (C_AddOns and C_AddOns.UpdateAddOnMemoryUsage) or UpdateAddOnMemoryUsage
      local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
      local parts = {}
      if up and get then
        up()
        for _, nm in ipairs({ ADDON, "Questie", "QuestieDB" }) do
          local okG, kb = pcall(get, nm)
          if okG and kb and kb > 0 then parts[#parts + 1] = ("%s %.0f MB"):format(nm, kb / 1024) end
        end
      end
      return ("%.0f MB, davon %s"):format(total / 1024, #parts > 0 and table.concat(parts, ", ") or "?")
    end)
    L("SPEICHER", okM and msg or tostring(msg))
    pcall(MsgLine, true)
    L("ENDE", ("Sitzung zu, Ruckler gesamt %d, Log %d KB"):format(hitchCount, math.floor((LOG.bytes or 0) / 1024)))
    -- Schluessel der Sitzung fertig rechnen (falls das Ausloggen sehr frueh kommt)
    if CR and CR.job then while not CR.job.Run(99) do end; if LOG.sess[SI] then LOG.sess[SI].k = CR.key end end
  elseif e == "QUEST_ACCEPTED" then
    local qid = a2 or a1
    if type(a1) == "number" and a2 == nil then qid = a1 end
    L("QUEST", ("angenommen %s %s (%s)"):format(tostring(qid), tostring(QName(qid) or ""), InRoute(qid)))
  elseif e == "QUEST_TURNED_IN" then
    -- mit aktiven XP Buffs: so laesst sich pruefen, ob der Schlafsack auch Quest XP erhoeht
    local xb = {}
    for _, x in ipairs(ns.XPBuffs and ns.XPBuffs() or {}) do xb[#xb + 1] = ("%s +%.0f %%"):format(x.kind, x.pct * 100) end
    L("QUEST", ("abgegeben %s %s, %s XP (%s)%s"):format(tostring(a1), tostring(QName(a1) or ""), tostring(a2 or 0), InRoute(a1), #xb > 0 and (", Buffs " .. table.concat(xb, ", ")) or ""))
  elseif e == "QUEST_REMOVED" then
    L("QUEST", ("aus dem Log %s"):format(tostring(a1)))
  elseif e == "PLAYER_LEVEL_UP" then
    L("LEVEL", ("Level %s nach %s"):format(tostring(a1), ns.Clock and ns.Clock(GetTime() - lvlStart) or math.floor(GetTime() - lvlStart)))
    lvlStart = GetTime()
  elseif e == "PLAYER_DEAD" then
    deadAt = GetTime()
    local d = Dist()
    L("TOD", ("gestorben durch %s, Ziel war: %s%s"):format(tostring(lastHit or "?"), tostring(last.txt), d and (", noch %d yd"):format(math.floor(d)) or ""))
    if CUR then CUR.deaths = (CUR.deaths or 0) + 1 end
  elseif e == "PLAYER_ALIVE" then
    if UnitIsGhost and ns.Api.U(UnitIsGhost, "player") then L("TOD", "als Geist unterwegs zur Leiche")
    elseif deadAt then L("TOD", ("wiederbelebt nach %ds"):format(math.floor(GetTime() - deadAt))); deadAt = nil end
  elseif e == "PLAYER_UNGHOST" then
    L("TOD", ("lebt wieder%s"):format(deadAt and (" nach %ds"):format(math.floor(GetTime() - deadAt)) or ""))
    deadAt = nil
  elseif e == "ZONE_CHANGED_NEW_AREA" then
    L("ZONE", tostring(GetZoneText and GetZoneText() or "?"))
    local c = Cont(ns.PlayerMap and ns.PlayerMap() or (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")))
    if c and last.cont and c ~= last.cont and not onTaxi then
      L("REISE", ("anderer Kontinent %s -> %s (Schiff, Zeppelin, Portal oder Ruhestein)"):format(tostring(last.cont), tostring(c)))
    end
    if c then last.cont = c end
  elseif e == "PLAYER_ENTERING_WORLD" then
    if a1 == false and a2 == false then L("REISE", "Ladebildschirm") end
  elseif e == "UNIT_SPELLCAST_SUCCEEDED" and a1 == "player" then
    if a3 == 8690 then L("REISE", "Ruhestein benutzt")
    elseif a3 == 556 then L("REISE", "Astraler Rueckruf") end
  elseif e == "PLAYER_CONTROL_LOST" then
    C_Timer.After(1, function() if ns.Api.U(UnitOnTaxi, "player") and not onTaxi then onTaxi = true; L("REISE", "Flug gestartet") end end)
  elseif e == "PLAYER_CONTROL_GAINED" then
    if onTaxi then onTaxi = false; L("REISE", "Flug gelandet") end
  elseif e == "GROUP_ROSTER_UPDATE" then
    Roster()
    local n = GetNumGroupMembers and GetNumGroupMembers() or 0
    if n ~= last.group then last.group = n; L("GRUPPE", ("%d in der Gruppe"):format(n)) end
  end
end

-- Stand vom Addon bei einer Notiz oder Meldung (was zeigt es gerade)
local function Snapshot()
  local db = ns.db or {}
  local idx, txt = StepInfo()
  local opt = db.opt
  local step = ns.LevelStep and ns.LevelStep(UnitLevel("player"))
  -- 19.31: wohin der Pfeil gerade zeigt (Karte, Punkt, Abstand), damit "falsche Richtung" nachpruefbar ist
  local aa, pz = ns.arrowAt, ""
  if aa and aa[2] then
    local d = ns.WorldDist and aa[4] and ns.WorldDist({ aa[1], aa[4], aa[5] }, { aa[1], aa[2], aa[3] })
    pz = (" (Pfeil Punkt %s %d,%d, %s yd)"):format(tostring(aa[1]), math.floor(aa[2] * 1000), math.floor(aa[3] * 1000), d and tostring(math.floor(d)) or "?")
  end
  return ("Stand: Schritt %s/%s %s, Pfeil %s" .. pz .. ", Hinweis %s, Profil %s, Route %s, Abschnitt %s, Tempo %s, Grinden %s, Modus %s, Gruppe %d, fps %d"):format(
    tostring(idx or "-"), tostring(opt and opt.steps and #opt.steps or 0), tostring(txt or "-"),
    ns.arrowNow and Clean(ns.arrowNow):gsub(" / .*$", "") or "kein Ziel", tostring(lastHint or "-"), tostring(db.profileCur or "level"),
    opt and Clean(opt.title or "?") or "-", tostring(db.plan60 and db.plan60.curIdx or "-"), tostring(step), db.grind == false and "aus" or "an",
    tostring(ns.Mode and ns.Mode()), GetNumGroupMembers and GetNumGroupMembers() or 0, math.floor(GetFramerate and GetFramerate() or 0))
end

------------------------------------------------------------
-- Befehl
------------------------------------------------------------
function ns.TestLogCmd(rest)
  rest = rest or ""
  local sub, txt = rest:match("^(%S*)%s*(.-)$")
  if not LOG then
    ns.Print((TR"Für das Test Log braucht es das Addon %s (eigener Ordner in AddOns, im Charakter Menü bei AddOns einschalten)."):format(ADDON .. "_Log"))
    return
  end
  -- englische Befehle gehen auf jedem Client
  sub = ({ on = "an", off = "aus", clear = "leeren", note = "notiz" })[sub] or sub
  if sub == "an" then
    LOG.on, LOG.byHand = true, true; ns.TestLogStart(); if ns.TesterBoxStart then ns.TesterBoxStart() end; ns.Print(TR"Test Log an.")
  elseif sub == "aus" then
    L("ENDE", "von Hand aus"); LOG.on, LOG.byHand = false, nil; ns.Print(TR"Test Log aus. Was drin ist, bleibt gespeichert.")
  elseif sub == "leeren" then
    LOG.lines = {}; LOG.bytes = 0; LOG.sess = {}; CR = nil; ns.Print(TR"Test Log geleert.")
  elseif sub == "notiz" and txt ~= "" then
    local was = LOG.on; LOG.on = true; L("NOTIZ", txt); L("NOTIZ", Snapshot()); LOG.on = was; ns.Print(TR"Notiz gespeichert.")
  else
    ns.Print((TR"Test Log %s, %d Zeilen, Sitzung %s. Gespeichert wird beim Ausloggen oder /reload in WTF, SavedVariables, %s.lua (verschlüsselt)."):format(
      On() and (ns.EN and "on" or "an") or (ns.EN and "off" or "aus"), #LOG.lines, tostring(SI and LOG.sess[SI] and LOG.sess[SI].id or "-"), ADDON .. "_Log"))
    ns.Print(TR"/klg testlog an, aus, leeren, notiz TEXT")
    -- 19.31 (ein Tester schickte KeineZeitLevelingGuide.lua, darin ist kein Log)
    ns.Print((TR"Zum Schicken: %s.lua aus WTF, Account, dein Konto, SavedVariables. Nicht %s.lua, das sind nur die Einstellungen."):format(ADDON .. "_Log", ADDON))
  end
end

------------------------------------------------------------
-- Test Kasten: links neben dem Mini Fenster "Fehler melden" und "Verbesserung".
-- Der Text landet im Test Log (FEHLER_MELDUNG oder VERBESSERUNG), mit Schritt, Zone und Level.
------------------------------------------------------------
function ns.TestReport(kind, text)
  text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" or not LOG then return false end
  local was = LOG.on
  LOG.on = true
  local idx, stepTxt = StepInfo()
  local ver = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON, "Version")) or "?"
  L(kind == "bug" and "FEHLER_MELDUNG" or "VERBESSERUNG", ("%s || Version %s, Schritt %s: %s"):format(text, tostring(ver), tostring(idx or "-"), tostring(stepTxt or "-")))
  -- 19.31: dazu der ganze Stand (Pfeil Ziel mit Punkt und Abstand, Hinweis, Profil), wie bei /klg testlog notiz
  L("NOTIZ", Snapshot())
  LOG.on = was
  return true
end

local rep
local function OpenReport(kind)
  local T = ns.T
  if not T then return end
  if not rep then
    rep = T.Window("ForeverWegweiserReport", 460, 260, "")
    local top = rep.top or 40
    rep.hint = rep:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    rep.hint:SetPoint("TOPLEFT", 18, -top - 6)
    rep.hint:SetPoint("RIGHT", rep, "RIGHT", -18, 0)
    rep.hint:SetJustifyH("LEFT")
    local box = CreateFrame("Frame", nil, rep, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetPoint("TOPLEFT", 16, -top - 30)
    box:SetPoint("BOTTOMRIGHT", -16, 50)
    if T.Skin then T.Skin(box, "inset") end
    local sf = CreateFrame("ScrollFrame", "ForeverWegweiserReportScroll", box, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject("ChatFontNormal"); eb:SetWidth(390)
    eb:SetMaxLetters(600)
    eb:SetScript("OnEscapePressed", function() rep:Hide() end)
    sf:SetScrollChild(eb)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() eb:SetFocus() end)
    rep.eb = eb
    rep.save = T.Button(rep, TR"Speichern", 120, 24, true)
    rep.save:SetPoint("BOTTOMRIGHT", -16, 14)
    rep.cancel = T.Button(rep, TR"Abbrechen", 110, 24)
    rep.cancel:SetPoint("RIGHT", rep.save, "LEFT", -8, 0)
    rep.cancel:SetScript("OnClick", function() rep:Hide() end)
    rep.save:SetScript("OnClick", function()
      if ns.TestReport(rep.kind, eb:GetText()) then
        ns.Print(rep.kind == "bug" and TR"Fehler gespeichert, danke! Er landet beim Ausloggen oder /reload im Log." or TR"Verbesserung gespeichert, danke! Sie landet beim Ausloggen oder /reload im Log.")
        rep:Hide()
      else
        ns.Print(TR"Bitte zuerst etwas eintippen.")
      end
    end)
  end
  rep.kind = kind
  rep.title:SetText(kind == "bug" and TR"Fehler melden" or TR"Verbesserung vorschlagen")
  rep.hint:SetText(kind == "bug" and TR"Was ist passiert, was hast du erwartet? Schritt, Zone und Level kommen von selbst dazu."
    or TR"Was sollte besser oder anders sein? Schritt, Zone und Level kommen von selbst dazu.")
  rep.eb:SetText("")
  rep:Show()
  rep.eb:SetFocus()
end
ns.OpenReport = OpenReport

local tbox
local function TesterBox()
  local db = ns.db
  local hud = _G.TaurenRouteHUD
  local T = ns.T
  if not (db and hud and T) then return end
  if not tbox then
    tbox = CreateFrame("Frame", "ForeverWegweiserTester", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tbox:SetSize(116, 76)
    tbox:SetFrameStrata("MEDIUM")
    if T.Skin then T.Skin(tbox, T.IsElv() and "window" or "tooltip") end
    tbox.t = tbox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
    tbox.t:SetPoint("TOP", 0, -6)
    tbox.t:SetText(TR"Test Notiz")
    tbox.bug = T.Button(tbox, TR"Fehler melden", 104, 22)
    tbox.bug:SetPoint("TOP", 0, -22)
    tbox.idea = T.Button(tbox, TR"Verbesserung", 104, 22)
    tbox.idea:SetPoint("TOP", tbox.bug, "BOTTOM", 0, -3)
    if tbox.bug.fs then tbox.bug.fs:SetTextColor(1, 0.45, 0.45) end
    if tbox.idea.fs then tbox.idea.fs:SetTextColor(0.5, 1, 0.5) end
    tbox.bug:SetScript("OnClick", function() OpenReport("bug") end)
    tbox.idea:SetScript("OnClick", function() OpenReport("idea") end)
  end
  local on = db.testerBox ~= false and hud:IsShown() and not db.paused and On()
  tbox:SetShown(on and true or false)
  if not on then return end
  tbox:SetScale(hud:GetScale() or 1)
  -- links neben dem Mini Fenster, steht es ganz links am Rand: rechts daneben
  tbox:ClearAllPoints()
  local left = hud:GetLeft() or 200
  if left * (hud:GetScale() or 1) < 130 then
    tbox:SetPoint("TOPLEFT", hud, "TOPRIGHT", 6, 0)
  else
    tbox:SetPoint("TOPRIGHT", hud, "TOPLEFT", -6, 0)
  end
end
ns.TesterBoxUpdate = TesterBox
local tbStarted = false
function ns.TesterBoxStart()
  if tbStarted then return end
  tbStarted = true
  TesterBox()
  if ns.Ticker then ns.Ticker(1, TesterBox) end
end
