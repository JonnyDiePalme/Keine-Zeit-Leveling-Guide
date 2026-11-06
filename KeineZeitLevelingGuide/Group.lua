local ADDON, ns = ...
local TR = ns.TR

-- Gruppen Sync: wer in der Gruppe Keine Zeit Leveling Guide hat, schickt seinen Quest Fortschritt.
-- Im HUD steht dann bei gemeinsamen Quests: Spieler, Quest, 3/8.
-- Nachrichten sind klein und gebremst: nur geaenderte Quests, hoechstens 5 pro Sekunde.

local PREFIX = "TaurenRt"
ns.group = {}            -- [Name] = { quests = { [qid] = { objs = {"3/8"}, done = bool, t = } }, lvl, seen }
local sent = {}          -- [qid] = zuletzt gesendeter Text
local queue, sending = {}, false
local tries = 0

local function Channel()
  if IsInRaid and IsInRaid() then return "RAID" end
  if IsInGroup and IsInGroup() then return "PARTY" end
end

local function Enabled() return ns.db and ns.db.groupSync ~= false end

-- Nachricht ueber den Gruppen Kanal und von jemandem in deiner Gruppe?
local function FromGroup(ch, sender)
  if ch ~= "PARTY" and ch ~= "RAID" and ch ~= "INSTANCE_CHAT" then return false end
  if type(sender) ~= "string" then return false end
  local n = (Ambiguate and Ambiguate(sender, "none")) or sender:gsub("%-.*$", "")
  if UnitIsUnit and ns.Api.U(UnitIsUnit, n, "player") then return true end
  return ((UnitInParty and ns.Api.U(UnitInParty, n)) or (UnitInRaid and ns.Api.U(UnitInRaid, n))) and true or false
end

-- verschicken, gebremst. Sagt das Spiel "zu viele Nachrichten", bleibt die Nachricht vorne und es geht spaeter weiter.
local function Pump()
  if #queue == 0 then sending = false; return end
  local ch = Channel()
  if not ch then wipe(queue); sending = false; return end
  local msg = queue[1]
  local ok, r = true, nil
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, ch) end
  -- neuere Clients geben einen Code zurueck (0 = verschickt), aeltere true oder nichts
  -- 3 = zu viele Nachrichten vom Addon, 8 = Kanal gebremst
  local throttled = ok and type(r) == "number" and (r == 3 or r == 8)
  if throttled and tries < 20 then
    tries = tries + 1
    C_Timer.After(1.2, Pump)
    return
  end
  tries = 0
  table.remove(queue, 1)
  C_Timer.After(0.25, Pump)
end
local function Send(msg)
  if not Channel() then return end
  -- gleiche Nachricht nicht doppelt in der Schlange
  for _, m in ipairs(queue) do if m == msg then return end end
  table.insert(queue, msg)
  if not sending then sending = true; C_Timer.After(0, Pump) end
end

ns.GroupSend = function(msg) if Enabled() then Send(msg) end end

-- Fortschritt einer Quest als kurzer Text: "3/8;0/1" und fertig ja/nein
local function Pack(p)
  local parts = {}
  for _, o in ipairs(p.objs or {}) do
    local a, b = (o.text or ""):match("(%d+)%s*/%s*(%d+)")
    table.insert(parts, a and (a .. "/" .. b) or (o.done and "1/1" or "0/1"))
  end
  return table.concat(parts, ";") .. "|" .. (p.complete and "1" or "0")
end

-- eigene Aenderungen verschicken
local function Broadcast(full)
  if not (Enabled() and Channel()) then return end
  local log = (ns.ReadLog and ns.ReadLog()) or ns.logProgress or {}
  if full then wipe(sent) end
  -- mehrere Quests in eine Nachricht (bis ca 230 Zeichen): "QM|qid,3/8;0/1,0~qid,..."
  local chunk, len = {}, 0
  local function Flush()
    if #chunk > 0 then Send("QM|" .. table.concat(chunk, "~")) end
    chunk, len = {}, 0
  end
  for qid, p in pairs(log) do
    local s = Pack(p)
    if sent[qid] ~= s then
      sent[qid] = s
      local objs, done = s:match("^(.-)|(%d)$")
      local e = qid .. "," .. (objs or "") .. "," .. (done or "0")
      if len + #e + 1 > 230 then Flush() end
      chunk[#chunk + 1] = e; len = len + #e + 1
    end
  end
  Flush()
  local gone = {}
  for qid in pairs(sent) do
    if not log[qid] then sent[qid] = nil; gone[#gone + 1] = qid end
  end
  if #gone > 0 then Send("XM|" .. table.concat(gone, ",")) end
  Send("L|" .. UnitLevel("player"))
  if ns.GroupSendPorts then ns.GroupSendPorts(full) end
end

local pending
local function Later(full)
  if pending then if full then pending = "full" end return end
  pending = full and "full" or true
  C_Timer.After(1.5, function()
    local f = pending == "full"
    pending = nil
    Broadcast(f)
  end)
end
ns.GroupBroadcast = Later

local function Short(name)
  if Ambiguate then return Ambiguate(name, "short") end
  return (name:gsub("%-.*", ""))
end

local helloAt = {}
-- hoechstens so viele Quests pro Mitspieler merken (Questlog hat 40 Plaetze), mehr ist kaputt oder Absicht
local MAXQ = 80
local function CountQ(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
local function OnMessage(msg, sender)
  local who = Short(sender)
  if who == UnitName("player") then return end
  local g = ns.group[who] or { quests = {} }
  ns.group[who] = g
  g.seen = GetTime()
  local kind, a, b, c = strsplit("|", msg)
  if kind == "QM" then
    -- mehrere Quests auf einmal
    for e in (a or ""):gmatch("[^~]+") do
      local qs, objsS, doneS = e:match("^(%d+),([^,]*),(%d)$")
      local qid = tonumber(qs)
      if qid and (g.quests[qid] or CountQ(g.quests) < MAXQ) then
        local objs = {}
        -- nur Zahlen wie 3/8 (der Text kommt ins Mini Fenster: keine fremden Farben, Links oder Bilder)
        for part in (objsS or ""):gmatch("[^;]+") do if #objs < 10 and part:match("^%d+/%d+$") then table.insert(objs, part) end end
        local old = g.quests[qid]
        local done = doneS == "1"
        g.quests[qid] = { objs = objs, done = done, t = GetTime() }
        if done and old and not old.done and ns.logProgress and ns.logProgress[qid] then
          ns.Print((TR"|cff66ccff%s|r hat %s fertig"):format(who, ns.logProgress[qid].title or (TR"Quest " .. qid)))
        end
      end
    end
  elseif kind == "XM" then
    for x in (a or ""):gmatch("%d+") do g.quests[tonumber(x)] = nil end
  elseif kind == "Q" then
    local qid = tonumber(a)
    if not qid then return end
    if not g.quests[qid] and CountQ(g.quests) >= MAXQ then if ns.MsgReject then ns.MsgReject("Gruppe: zu viele Quests") end return end
    local objs = {}
    for part in (b or ""):gmatch("[^;]+") do if #objs < 10 and part:match("^%d+/%d+$") then table.insert(objs, part) end end
    local old = g.quests[qid]
    local done = c == "1"
    g.quests[qid] = { objs = objs, done = done, t = GetTime() }
    -- gemeinsame Quest fertig? kurz melden
    if done and old and not old.done and ns.logProgress and ns.logProgress[qid] then
      ns.Print((TR"|cff66ccff%s|r hat %s fertig"):format(who, ns.logProgress[qid].title or (TR"Quest " .. qid)))
    end
  elseif kind == "X" then
    local qid = tonumber(a)
    if qid then g.quests[qid] = nil end
  elseif kind == "L" then
    g.lvl = tonumber(a)
  elseif kind == "H" then
    -- jemand ist neu in der Gruppe: alles schicken (pro Mitspieler hoechstens alle 10 Sekunden)
    local now = GetTime()
    if not helloAt[who] or now - helloAt[who] > 10 then helloAt[who] = now; Later(true) end
  elseif kind == "P" then
    g.pos = { tonumber(a), tonumber(b), tonumber(c) }
  elseif kind == "TP" then
    -- 20.3d (S f72 A): Portale eines Mitspielers mit Addon. "TP|11417,11418|3" = bekannte Portal Zauber und Runen der
    -- Portale im Gepaeck. Nur Zahlen aus der Liste PORTALS, alles andere wird verworfen
    local list = {}
    for x in (a or ""):gmatch("%d+") do
      local id = tonumber(x)
      if id and ns.PORTAL_TELE[id] and #list < 12 then list[#list + 1] = id end
    end
    g.ports = { ids = list, runes = math.min(tonumber(b) or 0, 999), t = GetTime() }
    if ns.TestLog then ns.TestLog("GRUPPE", ("Portale von %s: %s, Runen %d"):format(who, #list > 0 and table.concat(list, ",") or "keine", g.ports.runes)) end
  elseif ns.PartyOnMessage then
    ns.PartyOnMessage(kind, who, select(2, strsplit("|", msg)))
  end
  if ns.RefreshHud then ns.RefreshHud() end
end

-- Mitglieder, die nicht mehr in der Gruppe sind, entfernen
local function Prune()
  local inGroup = {}
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  local unit = (IsInRaid and IsInRaid()) and "raid" or "party"
  for i = 1, n do
    local name = UnitName(unit .. i)
    if name then inGroup[Short(name)] = true end
  end
  for name in pairs(ns.group) do if not inGroup[name] then ns.group[name] = nil end end
end

-- Zeilen fuer das HUD: gemeinsame Quests mit Fortschritt der anderen
-- Quests am aktuellen Ziel (qids) zuerst, dann offene, dann fertige
function ns.GroupLines(qids, max)
  if not Enabled() then return {} end
  local log = ns.logProgress or {}
  local want = {}
  for _, id in ipairs(qids or {}) do want[id] = true end
  local rows = {}
  for who, g in pairs(ns.group) do
    for qid, q in pairs(g.quests) do
      if log[qid] or want[qid] then
        local prog = q.done and TR"|cff40ff40fertig|r" or table.concat(q.objs, " ")
        local title = (log[qid] and log[qid].title) or (TR"Quest " .. qid)
        if #title > 22 then title = ns.U8Sub(title, 21) .. "." end
        table.insert(rows, { pri = (want[qid] and 0 or 2) + (q.done and 1 or 0),
          text = ("|cff66ccff%s|r %s %s"):format(who, title, prog) })
      end
    end
  end
  table.sort(rows, function(a, b) if a.pri ~= b.pri then return a.pri < b.pri end return a.text < b.text end)
  local out = {}
  for i = 1, math.min(#rows, max or 4) do out[i] = rows[i].text end
  if #rows > (max or 4) then table.insert(out, (TR"|cff9d9d9d... und %d mehr|r"):format(#rows - (max or 4))) end
  return out
end

-- wartet jemand noch? (fuer Abgabe Hinweise)
function ns.GroupNotDone(qid)
  local list = {}
  for who, g in pairs(ns.group) do
    local q = g.quests[qid]
    if q and not q.done then table.insert(list, who) end
  end
  return list
end

-- 20.3d (S f72 Antwort A, 06:40): Portale in der Gruppe tauschen, nur zwischen Spielern mit Keine Zeit Leveling Guide.
-- Portal Zauber (Gruppe) -> Teleport Zauber mit demselben Ziel (Ziele und Orte stehen in NaviFlug PORTS, Navi Teil)
ns.PORTAL_TELE = ns.PORTAL_TELE or {
  [11417] = 3567, -- Portal Orgrimmar
  [11418] = 3563, -- Portal Unterstadt
  [11420] = 3566, -- Portal Donnerfels
  [10059] = 3561, -- Portal Sturmwind
  [11416] = 3562, -- Portal Eisenschmiede
  [11419] = 3565, -- Portal Darnassus
}
local RUNE_PORTALS = 17032
local function KnownSpell(id)
  if IsPlayerSpell then local ok, r = pcall(IsPlayerSpell, id); if ok and r then return true end end
  if IsSpellKnown then local ok, r = pcall(IsSpellKnown, id); if ok and r then return true end end
  return false
end
local portsSent
function ns.GroupSendPorts(full)
  if not (Enabled() and Channel()) then return end
  local ids = {}
  -- Schalter "Portale der Gruppe nutzen?" aus: auch keine eigenen Portale schicken (leere Liste)
  if not (ns.db and ns.db.partyPorts == false) then
    for portal in pairs(ns.PORTAL_TELE) do if KnownSpell(portal) then ids[#ids + 1] = portal end end
  end
  table.sort(ids)
  local runes = (ns.Api.GetItemCount and ns.Api.GetItemCount(RUNE_PORTALS)) or 0
  local msg = "TP|" .. table.concat(ids, ",") .. "|" .. runes
  -- Nicht Magier schicken nichts (ausser bei full einmal leer, damit alte Angaben beim Partner verschwinden)
  if #ids == 0 and not full then return end
  if msg == portsSent and not full then return end
  portsSent = msg
  Send(msg)
end
-- Portale der Mitspieler mit Addon fuer die Wege (Navi): Liste { who, portal, tele, runes }. Nur wer Runen hat und in
-- den letzten 10 Minuten gesendet hat. Ohne Gruppe oder Sync aus: leere Liste
function ns.GroupPortals()
  local out = {}
  if not (Enabled() and Channel()) or (ns.db and ns.db.partyPorts == false) then return out end
  local now = GetTime()
  for who, g in pairs(ns.group) do
    local p = g.ports
    if p and p.runes and p.runes > 0 and now - (p.t or 0) < 600 then
      for _, id in ipairs(p.ids or {}) do out[#out + 1] = { who = who, portal = id, tele = ns.PORTAL_TELE[id], runes = p.runes } end
    end
  end
  return out
end

function ns.ToggleGroupSync()
  local db = ns.db
  db.groupSync = (db.groupSync == false)
  if db.groupSync then Send("H|"); Later(true) else wipe(ns.group) end
  ns.Print(db.groupSync and TR"Gruppen Sync an: Fortschritt wird mit der Gruppe geteilt" or TR"Gruppen Sync aus")
  if ns.RefreshHud then ns.RefreshHud() end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("LEARNED_SPELL_IN_TAB")
f:RegisterEvent("BAG_UPDATE_DELAYED")
local wasGrouped = false
f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
  if event == "PLAYER_LOGIN" then
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    wasGrouped = Channel() ~= nil
    if wasGrouped and Enabled() then C_Timer.After(5, function() Send("H|"); Later(true) end) end
  elseif event == "CHAT_MSG_ADDON" then
    -- nur aus der eigenen Gruppe (sonst koennte ein Fremder per Fluester Nachricht deine Route ersetzen)
    if a1 == PREFIX and Enabled() and type(a2) == "string" and type(a4) == "string" then
      if FromGroup(a3, a4) then OnMessage(a2, a4) elseif ns.MsgReject then ns.MsgReject("Gruppe: nicht aus der Gruppe") end
    end
  elseif event == "GROUP_ROSTER_UPDATE" then
    Prune()
    local now = Channel() ~= nil
    if now and not wasGrouped and Enabled() then Send("H|"); Later(true) end
    if not now then wipe(ns.group); wipe(sent) end
    -- Gruppe neu oder aufgeloest: Elite Quests kommen dazu oder fallen weg
    if now ~= wasGrouped and ns.QuestieFull and ns.QuestieScan then ns.QuestieFull(); ns.QuestieScan() end
    wasGrouped = now
    if ns.RefreshHud then ns.RefreshHud() end
  elseif event == "LEARNED_SPELL_IN_TAB" or event == "BAG_UPDATE_DELAYED" then
    -- 20.3d: nur die Portal Nachricht, und nur wenn sie sich geaendert hat
    -- 20.3o (Da Pruefung Nr 16): bei viel Loot hoechstens alle 10 s pruefen (Taschen Ereignis kommt sehr oft)
    if Enabled() and Channel() and not ns.portsPending then
      ns.portsPending = true
      C_Timer.After(event == "BAG_UPDATE_DELAYED" and 10 or 1, function()
        ns.portsPending = nil
        if Enabled() and Channel() then ns.GroupSendPorts(false) end
      end)
    end
  elseif Enabled() and Channel() then
    Later(event == "PLAYER_LEVEL_UP")
  end
end)

-- eigene Position alle 10 Sekunden (fuer das Aufteilen von Dungeon Quests)
local lastPos
ns.Ticker(10, function()
  if not (Enabled() and Channel()) then return end
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  local key = ("%d|%.3f|%.3f"):format(map, x, y)
  if key ~= lastPos then lastPos = key; Send("P|" .. key) end
end)
