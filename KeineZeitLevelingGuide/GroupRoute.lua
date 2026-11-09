local ADDON, ns = ...
local TR = ns.TR

-- Gruppen Route: der Gruppenfuehrer rechnet fuer alle, alle mit Wegweiser folgen seinen Schritten 1 zu 1.
-- Abstecher: Klassenquests und Quests, die nur einer braucht. Die anderen sehen es im Mini Fenster
-- und waehlen Helfen oder Eigenes machen. Mit Hexer ab 20 kommt ein Hinweis zum Herbeirufen.
-- Dungeon Aufteilen: vorher fragt der Leiter bei allen den Stand der Dungeon Quests ab.

ns.groupAbst = {}      -- [Name] = { qid, name, sec, at, elite }
ns.groupFollow = nil   -- Name des Leiters, solange wir seiner Route folgen
local myAbst = nil     -- eigener Abstecher { qid, name, at }
local dqStatus = {}    -- [key] = { [Name] = { [qid] = "done"/"log"/"open"/"pre"/"level" } }
local SendDone         -- erledigte Quests an den Leiter (weiter unten)

local function Me() return UnitName("player") end
local function Leader() return UnitIsGroupLeader and ns.Api.U(UnitIsGroupLeader, "player") end
local function Mates() local n = 0; for _ in pairs(ns.group or {}) do n = n + 1 end; return n end
local function Send(m) if ns.GroupSend then ns.GroupSend(m) end end
local function QName(qid)
  local qdb = ns.QDBAccess and ns.QDBAccess()
  if not qdb then return TR"Quest " .. qid end
  local ok, n = pcall(qdb.QueryQuestSingle, qid, "name")
  return ok and n or (TR"Quest " .. qid)
end

-- Liste in Nachrichten unter 240 Zeichen aufteilen
local function SendList(kind, ids, extra)
  local chunk = {}
  local len = 0
  local function Flush()
    if #chunk > 0 then Send(kind .. "|" .. (extra or "") .. "|" .. table.concat(chunk, ",")) end
    chunk, len = {}, 0
  end
  for _, id in ipairs(ids) do
    local s = tostring(id)
    if len + #s + 1 > 200 then Flush() end
    table.insert(chunk, s); len = len + #s + 1
  end
  Flush()
end

------------------------------------------------------------
-- Gruppen Route 1 zu 1: der Leiter rechnet fuer alle und schickt die Schritte, alle zeigen genau diese.
-- Fenster von ca 12 Schritten, kommt der Leiter ans Ende, schickt er die naechsten. Bei jedem Schritt
-- springen alle mit (G3). Was du nicht machen kannst, steht als "fuer <Leiter>, hilf mit" da.
-- Mitglieder melden Klasse, Level, Lehrer Stand, Bindepunkt und Ruhestein (GM), so plant der Leiter
-- Lehrer aller Klassen und einen gemeinsamen Bindepunkt mit ein.
------------------------------------------------------------
local WIN, MORE, LOOK = 12, 8, 5
local function MyClass() local _, c = UnitClass("player"); return c end

-- Schritte als kurzer Text ohne | (das trennt die Nachricht), Laufzeit Felder bleiben weg
local SKIP = { pg = true, pgT = true, pgX = true, pgY = true, areas = true, area = true, waitSince = true, since = true,
  wx = true, wy = true, help = true }
local function Esc(s) return (s:gsub("[%%|{};=,'\001-\031\127]", function(c) return ("%%%02X"):format(c:byte()) end)) end
local function Num(n)
  if n ~= n or n == math.huge or n == -math.huge then return "0" end
  if n == math.floor(n) and math.abs(n) < 1e15 then return ("%d"):format(n) end
  return (("%.4f"):format(n):gsub("0+$", ""):gsub("%.$", ""))
end
local Ser
Ser = function(v, depth, key)
  local t = type(v)
  if t == "number" then return Num(v) end
  if t == "string" then return "'" .. Esc(v) end
  if t == "boolean" then return v and "T" or "F" end
  if t ~= "table" or depth > 7 then return nil end
  local parts = {}
  local n = #v
  -- viele Fundorte: jeden x-ten nehmen (hoechstens 30), reicht fuer Pfeil und Gebiete
  local stepN = (key == "pts" and n > 30) and (n / 30) or 1
  local i = 1
  while i <= n do parts[#parts + 1] = Ser(v[math.floor(i)], depth + 1) or "F"; i = i + stepN end
  local keys = {}
  for k in pairs(v) do
    if type(k) == "string" and not SKIP[k] and k:find("^[%a_][%w_]*$") then keys[#keys + 1] = k end
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local x = Ser(v[k], depth + 1, k)
    if x then parts[#parts + 1] = k .. "=" .. x end
  end
  return "{" .. table.concat(parts, ";") .. "}"
end
local function Unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local Parse
Parse = function(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t, n = {}, 0
    i = i + 1
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local key
      local ks, ke = s:find("^[%a_][%w_]*=", i)
      if ks then key = s:sub(ks, ke - 1); i = ke + 1 end
      local v
      v, i = Parse(s, i)
      if key then t[key] = v else n = n + 1; t[n] = v end
      local d = s:sub(i, i)
      if d == ";" then i = i + 1 elseif d == "}" then return t, i + 1 else error("bad route data") end
    end
  elseif c == "'" then
    local e = s:find("[;}]", i + 1) or (#s + 1)
    return Unesc(s:sub(i + 1, e - 1)), e
  elseif c == "T" then return true, i + 1
  elseif c == "F" then return false, i + 1
  end
  local e = s:find("[;}]", i) or (#s + 1)
  return tonumber(s:sub(i, e - 1)), e
end
ns.GroupSer = function(v) return Ser(v, 0) end
ns.GroupDeser = function(s) local v = Parse(s, 1); return v end

------------------------------------------------------------
-- Leiter
------------------------------------------------------------
ns.groupMirror = {}    -- [Name] = { at, idx, key, cls, lvl, trained, bind = { map, x, y }, hcd, hcdAt }
local lead = { key = nil, sentTo = 0, idx = nil, beat = 0 }

-- Route, die alle mitlaufen koennen (Berufe, Dungeon Aufteilung, Tour, Farm sind nur fuer dich)
local function Mirrorable(opt)
  return opt and opt.steps and #opt.steps > 0 and not (opt.prof or opt.split or opt.farm or opt.repFarm or opt.tour or opt.mirror or opt.backSec)
end
local function RouteKey(opt) return ("%d.%d.%d"):format(opt.created or 0, opt.plan or 0, #opt.steps) end
-- zurueck geblaettert zaehlt nicht: die anderen bleiben beim echten Schritt
local function RealIdx(opt) return (opt.pin and opt.pinTop) or opt.idx or 1 end
-- Mitglieder, die gerade mitlaufen (in den letzten 3 Minuten gemeldet und noch in der Gruppe)
local function Followers()
  local out = {}
  local now = GetTime()
  for who, m in pairs(ns.groupMirror) do
    if now - (m.at or 0) < 180 and ns.group and ns.group[who] then out[#out + 1] = who end
  end
  table.sort(out)
  return out
end
ns.GroupFollowers = Followers

-- fuer die Planung: Klassen, Lehrer Stand, Bindepunkte und Ruhestein der Mitlaeufer
function ns.GroupPlanInfo()
  if not (ns.db and ns.db.groupSync ~= false) then return nil end
  local list = {}
  local now = GetTime()
  -- 1.3zd (P111): Mitspieler ohne unser Addon, deren Questlog Questie meldet (qonly: nur Log, Level, Klasse, Volk; keine
  -- erledigten Quests, kein Ruhestein, kein Lehrer Halt). Sie laufen nicht mit, darum auch ohne Leiter Rolle
  local qonly = {}
  for who, g in pairs((ns.QuestieGroup and ns.QuestieGroup()) or {}) do
    qonly[#qonly + 1] = { name = who, lvl = g.lvl, cid = g.cid, rid = g.rid, hcd = 0, log = g.quests, qonly = true }
  end
  if not Leader() then
    if #qonly == 0 then return nil end
    return { members = qonly, addon = 0 }
  end
  for _, who in ipairs(Followers()) do
    local m = ns.groupMirror[who]
    local g = ns.group and ns.group[who]
    list[#list + 1] = { name = who, cls = m.cls, lvl = m.lvl, trained = m.trained, bind = m.bind,
      hcd = m.hcd and math.max(0, m.hcd - (now - (m.hcdAt or now))) or 0,
      rid = m.rid, cid = m.cid, done = m.done, log = g and g.quests or nil }
  end
  local nA = #list
  for _, m in ipairs(qonly) do list[#list + 1] = m end
  if #list == 0 then return nil end
  return { members = list, addon = nA }
end

local function SendWindow(opt, from, count)
  local steps = {}
  for i = from, math.min(#opt.steps, from + count - 1) do
    -- Kopie fuer den Versand: Quests, NPCs und Ziele als Nummern, Texte vom Addon als Schluessel (jeder sieht seine Sprache)
    local st = opt.steps[i]
    local c = {}
    for k, v in pairs(st) do c[k] = v end
    if ns.WireOutAct and type(st.acts) == "table" then
      c.acts = {}
      for j, a in ipairs(st.acts) do c.acts[j] = ns.WireOutAct(a) end
    end
    steps[#steps + 1] = c
  end
  if #steps == 0 then return end
  local data = Ser(steps, 0) or "{}"
  local chunks = {}
  -- Stuecke von hoechstens 200 Bytes, nie mitten in einem Umlaut (der Empfaenger setzt sie wieder zusammen)
  local i = 1
  while i <= #data do
    local c = ns.U8Sub and ns.U8Sub(data:sub(i), 200) or data:sub(i, i + 199)
    if c == "" then c = data:sub(i, i + 199) end
    chunks[#chunks + 1] = c
    i = i + #c
  end
  local key = RouteKey(opt)
  Send(("G1|%s|%d|%d|%d|%d|%s|%d|%s"):format(key, from, #steps, #chunks, #opt.steps, MyClass() or "", math.floor(opt.target or 0), ns.LOCALE or ""))
  for i, c in ipairs(chunks) do Send(("G2|%d|%s"):format(i, c)) end
  lead.sentTo = math.max(lead.sentTo or 0, from + #steps - 1)
end

-- jede Sekunde: neue Route, naechste Schritte, Fortschritt
local function LeadTick(force)
  if not (Leader() and Mates() > 0 and ns.db and ns.db.optMode) then lead.key = nil; return end
  local opt = ns.db.opt
  if not Mirrorable(opt) then return end
  local followers = #Followers()
  if followers == 0 and not force then return end
  local key = RouteKey(opt)
  local real = RealIdx(opt)
  if key ~= lead.key or force then
    -- neue Route: zuerst nur die naechsten 3 Schritte (kommt schnell an), der Rest im naechsten Takt.
    -- Bis alle die neue Route bestaetigt haben (hoechstens 5 Sekunden), wartet dein Pfeil, damit alle zusammen wechseln
    if key ~= lead.key then lead.keyAt = GetTime() end
    lead.key, lead.sentTo, lead.idx = key, real - 1, nil
    SendWindow(opt, real, force and WIN or 3)
  elseif real <= #opt.steps and lead.sentTo - real < LOOK and lead.sentTo < #opt.steps then
    SendWindow(opt, lead.sentTo + 1, MORE)
  end
  local now = GetTime()
  -- Quests werden knapp und es passt ein Dungeon: der Leiter bekommt den Vorschlag einmal im Chat
  -- (die Mitlaeufer sehen ihn als Gruppen Schritt)
  local cs = opt.steps[real]
  if cs and lead.dungAnn ~= key .. real then
    for _, a in ipairs(cs.acts or {}) do
      if a.k == "G" and a.grp and a.dung then
        lead.dungAnn = key .. real
        ns.Print((TR"Die Quests werden knapp. Für eure Gruppe passt jetzt Dungeon %s, mit den Dungeon Quests geht das schneller als grinden. Die Route gibt es im Fenster unter Dungeons."):format(a.dung))
        break
      end
    end
  end
  if real ~= lead.idx or now - lead.beat > 30 then
    lead.idx, lead.beat = real, now
    Send(("G3|%s|%d"):format(key, real))
  end
end
ns.Ticker(1, function() LeadTick(false) end)
function ns.GroupRouteSend(force) LeadTick(force and true or false) end

-- neue Route verteilt: wer sie noch nicht bestaetigt hat (nur die ersten 5 Sekunden)
function ns.GroupSwitchWait()
  if not (Leader() and lead.key and lead.keyAt) or GetTime() - lead.keyAt > 5 then return nil end
  local out = {}
  for _, who in ipairs(Followers()) do
    local m = ns.groupMirror[who]
    if m.key ~= lead.key then out[#out + 1] = who end
  end
  return #out > 0 and out or nil
end

-- Halt fuer alle: binden und Lehrer fuer eine andere Klasse. Der Leiter wartet, bis die Mitlaeufer
-- diesen Schritt gemeldet haben (hoechstens 3 Minuten)
function ns.GroupStepWait(st, idx)
  if not (Leader() and ns.db and ns.db.opt and lead.key) then return nil end
  local need = false
  local mine = MyClass()
  for _, a in ipairs(st.acts or {}) do
    if a.k == "B" or (a.k == "V" and a.trainer) or a.k == "F" then need = true end
    -- Klassenquest eines Mitglieds: warten, bis er sie gemacht hat
    if a.cls and a.cls ~= mine and (a.k == "A" or a.k == "O" or a.k == "T") then need = "class" end
  end
  if not need then return nil end
  local out = {}
  for _, who in ipairs(Followers()) do
    local m = ns.groupMirror[who]
    if not (m.key == lead.key and (m.idx or 0) >= idx) then out[#out + 1] = who end
  end
  return #out > 0 and out or nil, need == "class"
end

------------------------------------------------------------
-- Mitglied: Schritte vom Leiter bekommen und genau so zeigen
------------------------------------------------------------
local rx = nil          -- Fenster, das gerade ankommt
local mir = nil         -- { leader, key, base, total, opt, beat, lcls, rep }
local askedKey, askWait = 0, 8
ns.mirrorActive = false

-- beim Leiter das Fenster anfordern. Kommt nichts, immer seltener fragen (hoechstens jede Minute)
local function Ask(why)
  if GetTime() - askedKey < askWait then return end
  askedKey = GetTime()
  askWait = math.min(60, askWait * 1.5)
  Send("GN|" .. (why or "1"))
end

-- kannst du diese Quest selbst annehmen?
local function CanTake(qid)
  local st = ns.QuestStatus and ns.QuestStatus(qid)
  if st == "log" or st == "ready" then return true end
  -- Vorquest fehlt noch, ist aber in deinem Log (gibst du gleich ab, oft beim selben NPC): dann kannst du sie auch
  if st == "pre" then
    local pre = ns.MissingPre and ns.MissingPre(qid)
    if not (pre and pre.inLog) then return false end
    st = "open"
  end
  if st ~= "open" then return false end
  local qdb = ns.QDBAccess and ns.QDBAccess()
  if qdb then
    local _, _, cid = UnitClass("player")
    local _, _, rid = UnitRace("player")
    local okC, rc = pcall(qdb.QueryQuestSingle, qid, "requiredClasses")
    local okR, rr = pcall(qdb.QueryQuestSingle, qid, "requiredRaces")
    if ns.DKRaces then rr = ns.DKRaces(qid, okR and rr or nil); okR = true end -- 1.3p (P96): fraktion aus der Daten Korrektur
    if okC and rc and rc > 0 and cid and ns.HasBit and not ns.HasBit(rc, cid - 1) then return false end
    if okR and rr and rr > 0 and rid and ns.RaceOK and not ns.RaceOK(rr, rid) then return false end
  end
  return true
end

-- Schritt Teil, den du nicht machen kannst: Name des Leiters (du hilfst ihm), sonst nil.
-- Kurz gemerkt, die Frage kommt oft (Pfeil, Mini Fenster, Liste)
local helpCache = setmetatable({}, { __mode = "k" })
-- Questlog geaendert (angenommen, abgegeben): gleich neu pruefen
local hcf = CreateFrame("Frame")
ns.RegEv(hcf, "QUEST_ACCEPTED")
ns.RegEv(hcf, "QUEST_TURNED_IN")
ns.RegEv(hcf, "QUEST_REMOVED")
ns.RegEv(hcf, "PLAYER_LEVEL_UP")
hcf:SetScript("OnEvent", function() for k in pairs(helpCache) do helpCache[k] = nil end end)
function ns.MirrorHelp(a)
  if not (ns.mirrorActive and mir and a) then return nil end
  local now = GetTime()
  local c = helpCache[a]
  if c and now - c.t < 2 then return c.v end
  local v
  local L = mir.leader
  -- Klassenquest eines anderen Mitspielers: das ist kein "hilf mit", da wartet die Gruppe auf ihn
  if a.cls and a.cls ~= MyClass() and (a.k == "A" or a.k == "O" or a.k == "T") then helpCache[a] = { t = now, v = nil }; return nil end
  if a.k == "V" and a.trainer then
    local cls = a.cls or mir.lcls
    if cls and cls ~= MyClass() then v = a.forName or L end
  elseif a.k == "A" and a.qid then
    if not CanTake(a.qid) then v = L end
  elseif (a.k == "O" or a.k == "T") and a.qid then
    -- nicht im Log: kommt die Annahme noch (gleicher Schritt, Unterwegs sammeln) und kannst du sie, dann machst du mit
    if not (ns.logProgress and ns.logProgress[a.qid]) and not ((a.pre or (mir.acc and mir.acc[a.qid])) and CanTake(a.qid)) then v = L end
  elseif a.k == "H" then
    local bi = ns.db and ns.db.bindInn
    if not (bi and ns.WorldDist and (ns.WorldDist(bi, { a.imap, a.ix, a.iy }) or 999) < 200) then v = L end
  elseif a.k == "F" then
    if ns.db and ns.db.knownFP and a.npc and ns.db.knownFP[a.npc] then v = L end
  end
  helpCache[a] = { t = now, v = v }
  return v
end

local function MirrorQids(steps)
  local set, acc = {}, {}
  for _, st in ipairs(steps) do
    for _, a in ipairs(st.acts or {}) do
      if a.qid then set[a.qid] = true end
      if a.k == "A" and a.qid then acc[a.qid] = true end
    end
  end
  return set, acc
end

local function ShowMirror()
  if not (mir and ns.db) then return end
  -- eigener Abstecher laeuft: der bleibt, die Gruppen Route wird im Hintergrund weiter gefuehrt
  if myAbst then return end
  -- deine eigene Spezialroute (Dungeon Aufteilung, Berufe, Farm, Tour ...) laeuft noch: die bleibt auch,
  -- danach geht es mit der Gruppen Route weiter
  local o = ns.db.opt
  if o and o ~= mir.opt and not o.mirror and (o.idx or 1) <= #(o.steps or {}) and (o.split or (ns.OptSpecial and ns.OptSpecial(o))) then return end
  if ns.db.opt ~= mir.opt then ns.db.opt = mir.opt end
  ns.db.optMode = true
  ns.groupFollow = mir.leader
  ns.mirrorActive = true
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
end

local function Merge(from, key, start, steps, total, lcls, target)
  if ns.TestLogWhy then ns.TestLogWhy("Gruppen Route vom Leiter") end
  if not (ns.db and type(steps) == "table") then return end
  for _, st in ipairs(steps) do
    for _, a in ipairs(st.acts or {}) do
      -- Mob Grind: fertig, wenn der Leiter weiter geht (seine XP Zahl gilt nicht fuer dich)
      if a.k == "G" then a.untilXP = nil; a.mirrorG = true end
      if a.k == "V" and a.trainer and not a.cls then a.cls = lcls end
    end
  end
  if not mir or mir.key ~= key or mir.leader ~= from or start <= mir.base then
    local L = UnitLevel("player")
    local opt = { steps = steps, idx = 1, created = time and time() or 0, from = L, to = math.max(L, target or L), target = target or L,
      quests = 0, sec = 0, xp = 0, rate = 0, title = (TR"Gruppe: folgt %s"):format(from), group = from, mirror = from, key = key, base = start - 1 }
    local isNew = not mir or mir.leader ~= from
    mir = { leader = from, key = key, base = start - 1, total = total, opt = opt, beat = GetTime(), lcls = lcls, rep = nil }
    -- dem Leiter sagen: neue Route ist da (er wartet kurz, damit alle zusammen wechseln)
    Send("GA|" .. key)
    if isNew then ns.Print((TR"Gruppen Route: du folgst %s Schritt für Schritt. Was du nicht machen kannst, steht als 'hilf mit' da."):format(from)) end
  else
    local opt = mir.opt
    local off = start - mir.base
    if off > #opt.steps + 1 then Ask("gap"); return end
    for i, st in ipairs(steps) do opt.steps[off + i - 1] = st end
    mir.total = total
  end
  mir.lcls = lcls
  askWait = 8
  ns.groupSet, mir.acc = MirrorQids(mir.opt.steps)
  if mir.lidx then mir.opt.idx = math.max(1, math.min(#mir.opt.steps + 1, mir.lidx - mir.base)) end
  ShowMirror()
end

local function Progress(from, key, idx)
  if not mir or mir.leader ~= from then Ask("start"); return end
  if mir.key ~= key then
    -- neue Route beim Leiter: das Fenster sollte gleich kommen, sonst nachfragen
    mir.wantKey = key
    C_Timer.After(6, function() if mir and mir.wantKey == key and mir.key ~= key then Ask("key") end end)
    return
  end
  mir.beat = GetTime()
  mir.lidx = idx
  local i = idx - mir.base
  if i > #mir.opt.steps then Ask("more") end
  local o = mir.opt
  local ni = math.max(1, math.min(#o.steps + 1, i))
  if ni ~= o.idx then
    o.idx = ni
    if ns.db.opt == o then
      local s = o.steps[ni]
      if s and ns.OptStepText then ns.Print((TR"Gruppe, Schritt %d: %s"):format(idx, ns.OptStepText(s))) end
      if ns.Draw then ns.Draw() end
    end
  end
end

-- kein Fortschritt vom Leiter seit 90 Sekunden (offline, Addon aus): dann laeuft deine Route selbst weiter
-- Gruppen Ansicht im Mini Fenster: wer ist bei welchem Schritt der Gruppen Route (Leiter und Mitglieder)
-- Liste { name, idx, total, me, leader, pos = { map, x, y } }, eigener Eintrag zuerst. Leer ohne Gruppen Route.
function ns.GroupProgress()
  local out = {}
  local me = UnitName("player")
  local key, total, myIdx, leaderName
  local o = ns.db and ns.db.opt
  if Leader() and lead.key and o and o.steps then
    key, total, myIdx, leaderName = lead.key, #o.steps, RealIdx(o), me
  elseif mir and mir.opt then
    key, total, myIdx, leaderName = mir.key, mir.total or (mir.base + #(mir.opt.steps or {})), mir.base + (mir.opt.idx or 1), mir.leader
    if mir.lidx and leaderName then
      local g = ns.group and ns.group[leaderName]
      out[#out + 1] = { name = leaderName, idx = mir.lidx, total = total, leader = true, pos = g and g.pos }
    end
  end
  if not key then return out end
  table.insert(out, 1, { name = me, idx = myIdx, total = total, me = true, leader = leaderName == me })
  local now = GetTime()
  for who, m in pairs(ns.groupMirror or {}) do
    if who ~= me and who ~= leaderName and m.key == key and now - (m.at or 0) < 300 and ns.group and ns.group[who] then
      out[#out + 1] = { name = who, idx = math.max(0, m.idx or 0), total = total, pos = ns.group[who].pos }
    end
  end
  table.sort(out, function(a, b)
    if a.me ~= b.me then return a.me end
    if a.leader ~= b.leader then return a.leader end
    return a.name < b.name
  end)
  return out
end

function ns.MirrorStale()
  return not mir or GetTime() - (mir.beat or 0) > 90
end

-- erledigte Quests fuer den Leiter: einmal ganz (Abstaende sortiert, 36er Zahlen), danach jede Abgabe einzeln
local function B36(n)
  local dg, out = "0123456789abcdefghijklmnopqrstuvwxyz", ""
  repeat local r = n % 36; out = dg:sub(r + 1, r + 1) .. out; n = math.floor(n / 36) until n == 0
  return out
end
SendDone = function()
  local ids = {}
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  if type(c) ~= "table" and GetQuestsCompleted then c = GetQuestsCompleted() end
  for q, v in pairs(type(c) == "table" and c or {}) do if v and type(q) == "number" and q > 0 then ids[#ids + 1] = q end end
  table.sort(ids)
  local parts, prev = {}, 0
  for _, q in ipairs(ids) do parts[#parts + 1] = B36(q - prev); prev = q end
  local data = table.concat(parts, ".")
  local chunks = {}
  for k = 1, #data, 200 do chunks[#chunks + 1] = data:sub(k, k + 199) end
  if #chunks == 0 then chunks[1] = "" end
  for k, ch in ipairs(chunks) do Send(("GD|%d|%d|%s"):format(k, #chunks, ch)) end
end
local tf = CreateFrame("Frame")
ns.RegEv(tf, "QUEST_TURNED_IN")
tf:SetScript("OnEvent", function(_, _, qid)
  if IsInGroup and IsInGroup() and not Leader() and tonumber(qid) then Send("GT|" .. tonumber(qid)) end
end)

-- eigener Stand fuer den Leiter
local lastGM, lastGMt = nil, 0
local function SendState(force)
  if Leader() or not (IsInGroup and IsInGroup()) then return end
  local db = ns.db or {}
  local bi = db.bindInn
  local hcd = 0
  if ns.Api.GetItemCooldown then
    local st, dur = ns.Api.GetItemCooldown(6948)
    if st and st > 0 and dur and dur > 0 then hcd = math.max(0, math.floor(st + dur - GetTime())) end
  end
  local _, _, rid = UnitRace("player")
  local _, _, cid = UnitClass("player")
  local msg = ("GM|%s|%d|%d|%s|%s|%s|%d|%d|%d"):format(MyClass() or "", UnitLevel("player") or 1, db.trainedAt or 0,
    bi and tostring(bi[1]) or "", bi and ("%.4f"):format(bi[2] or 0) or "", bi and ("%.4f"):format(bi[3] or 0) or "", math.ceil(hcd / 300) * 300,
    rid or 0, cid or 0)
  if force or msg ~= lastGM or GetTime() - lastGMt > 60 then
    lastGM, lastGMt = msg, GetTime()
    Send(msg)
  end
end
ns.GroupSendState = SendState

local EndMirror
-- alle 2 Sekunden: eigener Teil des Schritts fertig? Dann dem Leiter melden. Ohne Route vom Leiter: nachfragen
ns.Ticker(2, function()
  if Leader() or not (IsInGroup and IsInGroup()) or (ns.db and ns.db.groupSync == false) then return end
  SendState(false)
  if not mir then
    if Mates() > 0 then Ask("start") end
    return
  end
  -- eigene Route (Abstecher, Spezialroute) fertig: zurueck zur Gruppen Route
  local cur = ns.db and ns.db.opt
  if cur ~= mir.opt and not myAbst and (not cur or (cur.idx or 1) > #(cur.steps or {})) then ShowMirror() end
  ns.mirrorActive = ns.db and ns.db.opt == mir.opt or false
  if GetTime() - (mir.beat or 0) > 300 then
    EndMirror(TR"Vom Gruppenleiter kommt nichts mehr, jetzt wieder deine eigene Route.")
    return
  end
  local o = mir.opt
  local st = o.steps[o.idx or 1]
  local abs = mir.base + (o.idx or 1)
  if st and ns.OptStepDone and ns.OptStepDone(st) and mir.rep ~= abs then
    mir.rep = abs
    Send(("G4|%s|%d"):format(mir.key, abs))
  end
end)

EndMirror = function(msg)
  if not mir then return end
  local o = mir.opt
  mir = nil
  ns.mirrorActive = false
  ns.groupFollow, ns.groupSet = nil, nil
  if ns.db and ns.db.opt == o then
    if msg then ns.Print(msg) end
    if not (ns.OptUnpark and ns.OptUnpark()) and ns.AutoOpt then
      ns.db.opt = nil
      ns.AutoOpt("auto")
    end
  end
end
ns.GroupEndMirror = EndMirror

------------------------------------------------------------
-- Abstecher: eigene Klassenquests und Quests nur fuer dich
------------------------------------------------------------
local function OwnExtras()
  local out = {}
  local opt = ns.db and ns.db.opt
  if not (ns.groupFollow or (opt and opt.group)) then return out end
  local qdb = ns.QDBAccess and ns.QDBAccess()
  -- Quests des Leiters (sein Questlog ueber den Gruppen Sync): die macht ihr zusammen
  local lq = ns.groupFollow and ns.group and ns.group[ns.groupFollow] and ns.group[ns.groupFollow].quests or {}
  for qid, p in pairs(ns.logProgress or {}) do
    if not (ns.groupSet and ns.groupSet[qid]) and not lq[qid] then
      local cls = false
      if qdb then local ok, rc = pcall(qdb.QueryQuestSingle, qid, "requiredClasses"); cls = ok and rc and rc > 0 end
      table.insert(out, { qid = qid, name = p.title or QName(qid), cls = cls })
    end
  end
  table.sort(out, function(a, b) return (a.cls and 1 or 0) > (b.cls and 1 or 0) end)
  return out
end
ns.GroupOwnExtras = OwnExtras

function ns.StartAbstecher(qid)
  if not (qid and ns.Optimize) then return end
  local name = QName(qid)
  local elite = ns.IsEliteQuest and ns.IsEliteQuest(qid) or false
  ns.Optimize(UnitLevel("player") + 2, function(opt)
    if not opt then return end
    ns.db.optMode = true
    opt.title = TR"Abstecher: " .. name
    myAbst = { qid = qid, name = name, at = GetTime(), sec = opt.sec or 300 }
    Send(("GB|%d|%d|%d"):format(qid, math.floor(opt.sec or 300), elite and 1 or 0))
    if ns.RefreshBig then ns.RefreshBig() end
  end, { gearQ = { [qid] = true } })
end

local function EndAbstecher()
  if not myAbst then return end
  myAbst = nil
  Send("GF|1")
  -- zurueck zur Gruppen Route (lief im Hintergrund weiter)
  if mir then ShowMirror(); Ask("abst")
  elseif Leader() and ns.AutoOpt then ns.AutoOpt(true) end
end

-- eigener Abstecher fertig, sobald die Quest abgegeben ist
local qf = CreateFrame("Frame")
ns.RegEv(qf, "QUEST_TURNED_IN")
qf:SetScript("OnEvent", function(_, _, qid)
  if myAbst and tonumber(qid) == myAbst.qid then C_Timer.After(1, EndAbstecher) end
end)

------------------------------------------------------------
-- Hinweis fuer das Mini Fenster (wichtigster Platz)
------------------------------------------------------------
local helping
-- am Dungeon Eingang: wer hat welche Quest noch nicht, die du teilen kannst
local function EntranceHint()
  local d = ns.splitDungeon
  if not (d and d.entrance and ns.WorldDist) then return nil end
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return nil end
  local px, py = pos:GetXY()
  local de = ns.WorldDist({ map, px, py }, { d.entrance[1], d.entrance[2], d.entrance[3] })
  if not de or de > 80 then return nil end
  for who, g in pairs((ns.GroupAll and ns.GroupAll()) or ns.group or {}) do
    for _, qid in ipairs(d.quests or {}) do
      local mine = ns.logProgress and ns.logProgress[qid]
      local st = dqStatus[d.key or d.name] and dqStatus[d.key or d.name][who] and dqStatus[d.key or d.name][who][qid]
      if mine and not (g.quests and g.quests[qid]) and st ~= "done" and st ~= "pre" and st ~= "level" then
        return { kind = "group", text = (TR"%s hat %s noch nicht, du kannst sie teilen"):format(who, mine.title or QName(qid)),
          tip = TR"Quest im Questlog anklicken und Teilen drücken.", entrance = true }
      end
    end
  end
end

function ns.GroupHint()
  local db = ns.db
  if not (db and IsInGroup and IsInGroup()) then return nil end
  local eh = EntranceHint()
  if eh and not (db.svcSnooze and db.svcSnooze.entrance and time() < db.svcSnooze.entrance) then return eh end
  -- jemand anders macht gerade einen Abstecher
  for who, a in pairs(ns.groupAbst) do
    local left = math.max(0, (a.sec or 300) - (GetTime() - a.at))
    -- nichts mehr gehoert (Nachricht "fertig" verloren): nach der geplanten Zeit plus 5 Minuten verwerfen
    if not a.done and GetTime() - a.at > (a.sec or 300) + 300 then ns.groupAbst[who] = nil; a = nil end
    if not a then
      -- weg
    elseif a.done then
      -- fertig und weit weg: Hexer ruft ihn herbei
      if a.summon and GetTime() - a.done < 120 then
        return { kind = "group", text = (TR"%s ist fertig: %s ruft ihn herbei, zwei klicken mit"):format(who, a.summon), tip = TR"Hexer: Ritual der Beschwörung. Zwei Mitspieler klicken das Portal an." }
      end
    elseif not (db.svcSnooze and db.svcSnooze["abst" .. who] and time() < db.svcSnooze["abst" .. who]) then
      local rec = a.elite and TR" (helfen empfohlen)" or ""
      return { kind = "group", text = (TR"%s: %s, ca %s%s"):format(who, a.name or TR"Abstecher", ns.Clock(left), rec),
        tip = (TR"Klick: helfen, der Pfeil zeigt zu %s. X: eigenes machen, die Route füllt die Zeit, Treffpunkt in ca %s."):format(who, ns.Clock(left)),
        onClick = function() helping = who; ns.Print(TR"Du hilfst " .. who .. TR". Der Pfeil zeigt zu ihm.") end,
        abst = who }
    elseif left > 0 then
      return { kind = "group", text = (TR"Eigenes machen, Treffpunkt in ca %s"):format(ns.Clock(left)), tip = TR"Danach geht die Gruppen Route weiter.", abst = who, own = true }
    end
  end
  -- eigener Abstecher moeglich
  if not myAbst and (ns.groupFollow or Leader()) and not (db.svcSnooze and db.svcSnooze.ownAbst and time() < db.svcSnooze.ownAbst) then
    local ex = OwnExtras()
    if ex[1] then
      local e = ex[1]
      return { kind = "group", text = (TR"Abstecher: %s%s. Klick: starten"):format(e.name, e.cls and TR" (Klasse)" or ""),
        tip = TR"Nur du brauchst diese Quest. Die anderen sehen es und können helfen oder Eigenes machen.",
        onClick = function() ns.StartAbstecher(e.qid) end, ownStart = true }
    end
  end
  if myAbst then
    return { kind = "group", text = (TR"Dein Abstecher: %s"):format(myAbst.name), tip = TR"Klick: abbrechen und zurück zur Gruppe", onClick = EndAbstecher }
  end
  return nil
end

-- X am Gruppen Hinweis
function ns.GroupHintDismiss(h)
  local db = ns.db
  db.svcSnooze = db.svcSnooze or {}
  if h.abst then db.svcSnooze["abst" .. h.abst] = time() + 3600
  elseif h.ownStart then db.svcSnooze.ownAbst = time() + 900
  elseif h.entrance then db.svcSnooze.entrance = time() + 300 end
end

-- beim Helfen: Pfeil zum Mitspieler (Position kommt alle 10 Sekunden)
ns.Ticker(3, function()
  if not helping then return end
  local a = ns.groupAbst[helping]
  local g = ns.group and ns.group[helping]
  if not a or a.done or not (g and g.pos) then
    helping = nil
    if ns.serviceTarget and ns.serviceTarget.kind == "help" then ns.serviceTarget = nil; if ns.Draw then ns.Draw() end end
    return
  end
  ns.serviceTarget = { map = g.pos[1], x = g.pos[2], y = g.pos[3], name = TR"Helfen: " .. helping, kind = "help" }
  if ns.Draw then ns.Draw() end
end)

------------------------------------------------------------
-- Nachrichten
------------------------------------------------------------
local function Warlock()
  for i = 1, 4 do
    local u = "party" .. i
    if UnitExists and ns.Api.U(UnitExists, u) then
      local _, c = UnitClass(u)
      if c == "WARLOCK" and (UnitLevel(u) or 0) >= 20 then return (UnitName(u)) end
    end
  end
  local _, c = UnitClass("player")
  if c == "WARLOCK" and UnitLevel("player") >= 20 then return Me() end
end

local function Dist(who)
  local g = ns.group and ns.group[who]
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not (g and g.pos and pos and ns.WorldDist) then return nil end
  local px, py = pos:GetXY()
  return ns.WorldDist({ map, px, py }, { g.pos[1], g.pos[2], g.pos[3] })
end

local orig = ns.PartyOnMessage
-- Gruppen Route kommt nur vom Leiter
local function IsLeader(who)
  local n = who and ((Ambiguate and Ambiguate(who, "none")) or who:gsub("%-.*$", ""))
  return n and UnitIsGroupLeader and ns.Api.U(UnitIsGroupLeader, n) and true or false
end
local followSet, replanAt = "", nil
-- Leiter: Abschnitt neu rechnen (kommt mehreres kurz nacheinander, nur einmal: d Sekunden nach dem letzten)
local function Replan(d)
  replanAt = GetTime() + d
  C_Timer.After(d + 0.1, function()
    if replanAt and GetTime() >= replanAt and Leader() and ns.AutoOpt and not (ns.OptSpecial and ns.OptSpecial()) then
      replanAt = nil
      ns.AutoOpt("section")
    end
  end)
end
local rxDone = {}   -- [Name] = { n, parts, got }
-- Bremse gegen Spam aus der Gruppe: dieselbe Anfrage hoechstens alle sec Sekunden
local rate = {}
local function Rate(key, sec)
  local now = GetTime()
  if rate[key] and now - rate[key] < sec then return false end
  rate[key] = now
  return true
end
ns.PartyOnMessage = function(kind, from, a, b, c, d, e, f, g, h, i)
  -- alte Version (nur Quest Liste): nichts mehr machen, die Schritte kommen mit G1 und G2
  if kind == "GS" or kind == "GQ" or kind == "GE" then return end
  if (kind == "G1" or kind == "G2" or kind == "G3") and not IsLeader(from) then if ns.MsgReject then ns.MsgReject("Route: nicht vom Leiter") end return end
  if kind == "G1" then
    rx = { from = from, key = a, start = tonumber(b) or 1, count = tonumber(c) or 0, n = tonumber(d) or 0, total = tonumber(e) or 0,
      lcls = f ~= "" and f or nil, target = tonumber(g), loc = h, parts = {}, got = 0 }
    -- unsinnige Zahlen (kaputt oder Absicht): nicht warten
    if rx.n < 1 or rx.n > 80 or rx.count < 1 or rx.count > 40 then rx = nil; if ns.MsgReject then ns.MsgReject("Route: unsinnige Zahlen") end end
  elseif kind == "G2" then
    local i = tonumber(a)
    if not (rx and rx.from == from and i and not rx.parts[i]) then return end
    rx.parts[i] = b or ""
    rx.got = rx.got + 1
    if rx.got >= rx.n then
      local r = rx
      rx = nil
      for k = 1, r.n do if not r.parts[k] then if ns.MsgReject then ns.MsgReject("Route: Teile fehlen") end Ask("lost"); return end end
      local ok, steps = pcall(ns.GroupDeser, table.concat(r.parts))
      if not ok or type(steps) ~= "table" or #steps ~= r.count then if ns.MsgReject then ns.MsgReject("Route: kaputt") end Ask("bad"); return end
      -- Namen in deiner Sprache (Quest, NPC, Ziel aus den Nummern), fremde Texte ohne Bilder und Links
      if ns.WireInAct then
        local same = r.loc ~= nil and r.loc ~= "" and r.loc == ns.LOCALE
        for _, st in ipairs(steps) do
          if type(st) == "table" and type(st.acts) == "table" then
            for _, a in ipairs(st.acts) do if type(a) == "table" then ns.WireInAct(a, same) end end
          end
        end
      end
      Merge(r.from, r.key, r.start, steps, r.total, r.lcls, r.target)
    end
  elseif kind == "G3" then
    Progress(from, a, tonumber(b) or 1)
  elseif kind == "G4" then
    -- Mitglied: mit diesem Schritt fertig
    local m = ns.groupMirror[from] or {}
    ns.groupMirror[from] = m
    m.at, m.key, m.idx = GetTime(), a, tonumber(b) or 0
  elseif kind == "GA" then
    -- Mitglied hat die neue Route
    if Leader() then
      local m = ns.groupMirror[from] or {}
      ns.groupMirror[from] = m
      m.at, m.key = GetTime(), a
      if (m.idx or 0) < 1 then m.idx = 0 end
    end
  elseif kind == "GM" then
    local m = ns.groupMirror[from] or {}
    local isNew = not m.cls
    ns.groupMirror[from] = m
    m.at, m.cls, m.lvl, m.trained = GetTime(), a ~= "" and a or nil, tonumber(b), tonumber(c)
    local bm = tonumber(d)
    m.bind = bm and { bm, tonumber(e) or 0, tonumber(f) or 0 } or nil
    m.hcd, m.hcdAt = tonumber(g) or 0, GetTime()
    m.rid, m.cid = tonumber(h), tonumber(i)
    if Leader() then
      -- erledigte Quests noch nicht bekannt: einmal anfordern (fuer gemeinsame Quests in der Planung)
      if not m.done and GetTime() - (m.askedDone or -999) > 60 then m.askedDone = GetTime(); Send("GW|" .. from) end
      -- jemand Neues laeuft mit: Abschnitt mit seiner Klasse (Lehrer) und Bindepunkt neu rechnen
      if isNew then
        local fs = table.concat(Followers(), ",")
        if fs ~= followSet then followSet = fs; Replan(5) end
      end
    end
  elseif kind == "GW" then
    -- Leiter will deine erledigten Quests (nur vom Leiter, hoechstens alle 30 Sekunden: die Liste sind viele Nachrichten)
    if a == Me() and SendDone and IsLeader(from) and Rate("GW", 30) then SendDone() end
  elseif kind == "GD" then
    -- Mitglied: erledigte Quests (Abstaende in 36er Zahlen, mit Punkt getrennt), in Stuecken
    if not Leader() then return end
    local idx, n = tonumber(a) or 1, tonumber(b) or 1
    -- unsinnige Stueckzahl (kaputt oder Absicht): verwerfen
    if n < 1 or n > 60 or idx < 1 or idx > n then return end
    local r = rxDone[from]
    if idx == 1 or not r or r.n ~= n then r = { n = n, parts = {}, got = 0 }; rxDone[from] = r end
    if not r.parts[idx] then r.parts[idx] = c or ""; r.got = r.got + 1 end
    if r.got >= r.n then
      rxDone[from] = nil
      local data = table.concat(r.parts)
      local set, prev, cnt = {}, 0, 0
      for tok in data:gmatch("[^%.]+") do
        local v = tonumber(tok, 36)
        if v then prev = prev + v; set[prev] = true; cnt = cnt + 1 end
      end
      local m = ns.groupMirror[from] or {}
      ns.groupMirror[from] = m
      local first = not m.done
      m.done, m.doneN = set, cnt
      -- mit dem Stand neu rechnen, Quests fuer alle bevorzugen
      if first then Replan(3) end
    end
  elseif kind == "GT" then
    -- Mitglied hat eine Quest abgegeben
    local m = ns.groupMirror[from]
    local q = tonumber(a)
    if m and m.done and q then m.done[q] = true end
  elseif kind == "GN" then
    -- ein Mitglied hat noch nichts oder nicht alles bekommen: Fenster ab dem aktuellen Schritt nochmal
    -- (hoechstens alle 5 Sekunden pro Mitglied, sonst schickt der Leiter staendig alles)
    if Leader() and Rate("GN" .. tostring(from), 5) then
      local m = ns.groupMirror[from] or {}
      ns.groupMirror[from] = m
      m.at = GetTime()
      LeadTick(true)
    end
  elseif kind == "GR" then
    -- Mitglied bittet um Neu rechnen: hoechstens alle 30 Sekunden (Rechnen ruckelt kurz)
    if Leader() and ns.AutoOpt and Rate("GR", 30) then ns.AutoOpt("auto") end
  elseif kind == "GB" then
    local qid = tonumber(a)
    ns.groupAbst[from] = { qid = qid, name = qid and QName(qid), sec = tonumber(b) or 300, at = GetTime(), elite = c == "1" }
  elseif kind == "GF" then
    local ab = ns.groupAbst[from]
    if ab then
      ab.done = GetTime()
      local d = Dist(from)
      local wl = Warlock()
      if wl and wl ~= from and d and d > 800 then ab.summon = wl end
      if not ab.summon then ns.groupAbst[from] = nil end
      if helping == from then helping = nil end
    end
  elseif kind == "DQ" then
    -- Leiter fragt den Stand der Dungeon Quests ab (hoechstens alle 10 Sekunden pro Dungeon)
    if not Rate("DQ" .. tostring(a), 10) then return end
    local d
    for _, x in ipairs(ns.dungeons or {}) do if (x.key or x.name) == a then d = x end end
    if d and ns.QuestStatus then
      local parts = {}
      for _, qid in ipairs(d.quests or {}) do
        local st = ns.QuestStatus(qid)
        table.insert(parts, qid .. ":" .. (st == "ready" and "log" or st))
      end
      SendList("DS", parts, a)
    end
  elseif kind == "DS" then
    if type(a) ~= "string" or #a > 60 then return end
    dqStatus[a] = dqStatus[a] or {}
    dqStatus[a][from] = dqStatus[a][from] or {}
    for qid, st in (b or ""):gmatch("(%d+):(%a+)") do dqStatus[a][from][tonumber(qid)] = st end
  elseif orig then
    orig(kind, from, a, b, c)
  end
end

-- Stand der Mitspieler fuer eine Dungeon Quest (fuers Aufteilen)
function ns.DungeonGroupStatus(key) return dqStatus[key] or {} end
function ns.AskDungeonStatus(key) dqStatus[key] = {}; Send("DQ|" .. key) end

-- Gruppe verlassen oder Leiter weg: wieder eigene Route
local gf = CreateFrame("Frame")
ns.RegEv(gf, "GROUP_ROSTER_UPDATE")
ns.RegEv(gf, "PARTY_LEADER_CHANGED")
-- wer ist in der Gruppe und wer leitet: nur bei echter Aenderung die Route neu schicken (im Raid feuert das staendig)
local rosterKey, rosterWait
local function RosterKey()
  local n = GetNumGroupMembers and GetNumGroupMembers() or 0
  local names = {}
  local pre = (IsInRaid and IsInRaid()) and "raid" or "party"
  for i = 1, n do local u = pre .. i; if ns.Api.U(UnitExists, u) then names[#names + 1] = (UnitName(u) or "?") .. (ns.Api.U(UnitIsGroupLeader, u) and "*" or "") end end
  table.sort(names)
  return table.concat(names, ",") .. (ns.Api.U(UnitIsGroupLeader, "player") and "|L" or "")
end
gf:SetScript("OnEvent", function()
  if rosterWait then return end
  rosterWait = true
  C_Timer.After(2, function()
    rosterWait = false
    local L = mir and mir.leader
    local leader = L and UnitIsGroupLeader and ns.Api.U(UnitIsGroupLeader, L)
    if L and not (IsInGroup() and leader) then
      ns.groupAbst = {}
      EndMirror(TR"Gruppen Route beendet, jetzt wieder deine eigene Route.")
    end
    -- selbst Leiter geworden: die Route ab hier selbst rechnen
    if Leader() and mir then EndMirror(TR"Du leitest jetzt die Gruppe, deine Route rechnet für alle.") end
    -- Gruppe ganz weg: geteilte Route und Dungeon Route der Gruppe beenden
    local o = ns.db and ns.db.opt
    if not IsInGroup() and o and (o.split or o.group) and not o.mirror and (o.idx or 1) <= #(o.steps or {}) then
      o.idx = #(o.steps or {}) + 1
      ns.Print(TR"Gruppe aufgelöst, jetzt wieder deine eigene Route.")
      if not (ns.OptUnpark and ns.OptUnpark()) and ns.AutoOpt then ns.AutoOpt(true) end
    end
    local k = RosterKey()
    if k ~= rosterKey then
      rosterKey = k
      if Leader() then LeadTick(true) end
    end
  end)
end)

-- Nach dem Einloggen (Reload): Gruppen Route aus den gespeicherten Daten, gleich beim Leiter den Stand holen
local lf = CreateFrame("Frame")
ns.RegEv(lf, "PLAYER_LOGIN")
lf:SetScript("OnEvent", function()
  C_Timer.After(6, function()
    local o = ns.db and ns.db.opt
    if o and o.mirror then
      if IsInGroup and IsInGroup() and not Leader() and UnitIsGroupLeader and ns.Api.U(UnitIsGroupLeader, o.mirror) then
        mir = { leader = o.mirror, key = o.key, base = o.base or 0, total = #o.steps, opt = o, beat = GetTime() }
        ShowMirror()
        Ask("login")
      else
        -- nicht mehr in der Gruppe: wieder eigene Route
        mir = { leader = o.mirror, key = o.key, base = 0, opt = o }
        EndMirror(TR"Gruppen Route beendet, jetzt wieder deine eigene Route.")
      end
    end
    SendState(true)
  end)
end)

-- Stand an den Leiter, wenn sich etwas aendert (Level, Lehrer, Bindepunkt)
local sf = CreateFrame("Frame")
ns.RegEv(sf, "PLAYER_LEVEL_UP")
ns.RegEv(sf, "TRAINER_CLOSED")
ns.RegEv(sf, "PLAYER_ENTERING_WORLD")
sf:SetScript("OnEvent", function() C_Timer.After(2, function() SendState(false) end) end)
