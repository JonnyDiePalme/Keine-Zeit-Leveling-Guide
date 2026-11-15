local ADDON, ns = ...
local TR = ns.TR

-- 1. Quests automatisch teilen: hat ein Gruppenmitglied mit Keine Zeit Leveling Guide eine Quest aus deinem Log noch nicht,
--    wird sie geteilt, wenn es in Reichweite ist. Schlaegt es fehl (schon erledigt, schon im Log ...), nie wieder.
-- 2. Dungeon Quests aufteilen: wer holt welche Questgeber, Treffpunkt am Eingang, dort wird geteilt.

------------------------------------------------------------
-- Hilfen
------------------------------------------------------------
local function Units()
  local out = {}
  local raid = IsInRaid and IsInRaid()
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  for i = 1, raid and n or math.max(0, n - 1) do
    local u = (raid and "raid" or "party") .. i
    local name = UnitName(u)
    if name and not ns.Api.U(UnitIsUnit, u, "player") then out[(Ambiguate and Ambiguate(name, "short")) or name] = u end
  end
  return out
end

local function InRange(u)
  if not (UnitIsConnected and ns.Api.U(UnitIsConnected, u)) then return false end
  if UnitInRange then
    local inR, checked = ns.Api.U(UnitInRange, u)
    inR, checked = ns.Plain(inR), ns.Plain(checked)
    if checked then return inR and true or false end
  end
  return CheckInteractDistance and CheckInteractDistance(u, 4) and true or false
end

local function QDB() return ns.QDBAccess and ns.QDBAccess() end
local function Q(id, k)
  local qdb = QDB()
  if not qdb then return end
  local ok, v = pcall(qdb.QueryQuestSingle, id, k)
  if not ok then return end
  -- 19.34 (Pruefer 09:42 LEICHT 4): Vorquests mit der Daten Korrektur (vorquest_fehlt), wie die Route
  if k == "preQuestSingle" and ns.DKPreSingle then return ns.DKPreSingle(id, v) end
  if k == "preQuestGroup" and ns.DKPreGroup then return ns.DKPreGroup(id, v) end -- 19.34 (vorquest_1934): negative Id
  return v
end

-- darf der Mitspieler die Quest ueberhaupt haben? (Level, Klasse, Volk)
local function Eligible(qid, u, lvl)
  local rl = Q(qid, "requiredLevel")
  if rl and lvl and lvl < rl then return false end
  local rc = Q(qid, "requiredClasses")
  if rc and rc > 0 and bit then
    local _, _, cid = UnitClass(u)
    if cid and not ns.HasBit(rc, cid - 1) then return false end
  end
  local rr = ns.DKRaces(qid, Q(qid, "requiredRaces"))
  if rr and rr > 0 and bit then
    local _, _, rid = UnitRace(u)
    if rid and not ns.RaceOK(rr, rid) then return false end
  end
  return true
end

local function LogIndex(qid)
  local n = (GetNumQuestLogEntries and GetNumQuestLogEntries()) or 0
  for i = 1, n do
    local _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
    if not isHeader and id == qid then return i end
  end
end

------------------------------------------------------------
-- Automatisch teilen
------------------------------------------------------------
local tries = {}         -- [qid..who] = { n =, at = }
local lastPush           -- { qid, at, who = {names} }
local noShare = {}       -- Quests, die man nicht teilen kann

local function Failed(who, qid)
  local f = ns.db and ns.db.shareFail
  return f and f[who] and f[who][qid]
end
local function MarkFailed(who, qid)
  ns.db.shareFail = ns.db.shareFail or {}
  ns.db.shareFail[who] = ns.db.shareFail[who] or {}
  ns.db.shareFail[who][qid] = true
end

local function Tick()
  local db = ns.db
  if not db or db.autoShare == false or not (IsInGroup and IsInGroup()) then return end
  if InCombatLockdown and InCombatLockdown() then return end
  if ns.ShareState and ns.ShareState() then return end   -- 1.4r: "Mit Gruppe teilen" laeuft
  if not (QuestLogPushQuest and SelectQuestLogEntry) then return end
  if lastPush and GetTime() - lastPush.at < 4 then return end
  local log = ns.logProgress or {}
  local units = Units()
  local now = GetTime()
  for qid, p in pairs(log) do
    if not noShare[qid] then
      local targets = {}
      -- 1.3zd (P111): auch Mitspieler ohne unser Addon, deren Quest Stand Questie meldet
      for who, g in pairs((ns.GroupAll and ns.GroupAll()) or ns.group or {}) do
        local u = units[who]
        if u and g.quests and not g.quests[qid] and not Failed(who, qid) and InRange(u) and Eligible(qid, u, g.lvl) then
          local t = tries[qid .. who]
          -- hoechstens 3 Versuche (abgelehnt), dazwischen 1 Minute; zu weit weg oder beschaeftigt zaehlt nicht
          if not t or (t.n < 3 and now - t.at > 60) then table.insert(targets, who) end
        end
      end
      if #targets > 0 then
        local idx = LogIndex(qid)
        if idx then
          SelectQuestLogEntry(idx)
          if GetQuestLogPushable and not GetQuestLogPushable() then
            noShare[qid] = true
          else
            ns.Api.Prot("QuestLogPushQuest", QuestLogPushQuest)
            lastPush = { qid = qid, at = now, who = targets }
            for _, who in ipairs(targets) do
              local t = tries[qid .. who] or { n = 0 }
              t.n, t.at = t.n + 1, now
              tries[qid .. who] = t
            end
            ns.Print((TR"Teile %s mit %s"):format(p.title or (TR"Quest " .. qid), table.concat(targets, ", ")))
            return
          end
        end
      end
    end
  end
end

-- Antworten auf das Teilen: endgueltig fehlgeschlagen oder spaeter nochmal
local patterns
local function BuildPatterns()
  patterns = {}
  local function Add(g, final, again)
    local s = _G[g]
    if type(s) ~= "string" then return end
    -- Platzhalter (%s oder %1$s) erst merken, dann alles maskieren, dann zum Fangen machen
    local t = s:gsub("%%%d*%$?s", "\001")
    t = t:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    t = t:gsub("\001", "(.+)")
    local pat = "^" .. t .. "$"
    if pcall(string.match, "", pat) then table.insert(patterns, { pat = pat, final = final, again = again }) end
  end
  Add("ERR_QUEST_PUSH_ALREADY_DONE_S", true)
  Add("ERR_QUEST_PUSH_ONQUEST_S", true)
  Add("ERR_QUEST_PUSH_INVALID_S", false) -- kann spaeter gehen (Level, Vorquest)
  Add("ERR_QUEST_PUSH_NOT_ALLOWED_S", true)
  Add("ERR_QUEST_PUSH_LOG_FULL_S", false, true)
  Add("ERR_QUEST_PUSH_TOO_FAR_S", false, true)
  Add("ERR_QUEST_PUSH_BUSY_S", false, true)
  Add("ERR_QUEST_PUSH_DECLINED_S", false)
end

------------------------------------------------------------
-- 1.4r (P194, K 16:32 und 16:35): Knopf "Mit Gruppe teilen". Teilt der Reihe nach alle teilbaren Quests der Route, die im
-- Log sind. Die naechste erst, wenn alle Mitspieler geantwortet haben (Systemzeilen ERR_QUEST_PUSH_* des Clients, keine
-- festen Texte), spaetestens nach SHARE.WAIT_S. Am Ende eine Zeile "n Quests geteilt" und je Spieler, was nicht ankam.
-- Blockt der Client das Teilen ohne Klick, geht es je Klick weiter ("Teilen 3/7")
------------------------------------------------------------
ns.SHARE = { WAIT_S = 5, PAUSE_S = 0.6 }
local share
local sharePat
local function SharePatterns()
  sharePat = {}
  local function Add(g, why)
    local s = _G[g]
    if type(s) ~= "string" then return end
    local t = s:gsub("%%%d*%$?s", "\001")
    t = t:gsub("([%%%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    t = t:gsub("\001", "(.+)")
    local pat = "^" .. t .. "$"
    if pcall(string.match, "", pat) then sharePat[#sharePat + 1] = { pat = pat, why = why } end
  end
  Add("ERR_QUEST_PUSH_ACCEPTED_S", false)
  Add("ERR_QUEST_PUSH_DECLINED_S", TR"abgelehnt")
  Add("ERR_QUEST_PUSH_ALREADY_DONE_S", TR"schon erledigt")
  Add("ERR_QUEST_PUSH_ONQUEST_S", TR"hat sie schon")
  Add("ERR_QUEST_PUSH_BUSY_S", TR"beschäftigt")
  Add("ERR_QUEST_PUSH_INVALID_S", TR"nicht berechtigt")
  Add("ERR_QUEST_PUSH_NOT_ALLOWED_S", TR"nicht berechtigt")
  Add("ERR_QUEST_PUSH_LOG_FULL_S", TR"Log voll")
  Add("ERR_QUEST_PUSH_TOO_FAR_S", TR"zu weit weg")
end
local function RouteQuestsInLog()
  local opt = ns.db and ns.db.opt
  local log = ns.logProgress or {}
  local out, seen = {}, {}
  for k = (opt and opt.idx or 1), #(opt and opt.steps or {}) do
    for _, a in ipairs(opt.steps[k].acts or {}) do
      local q = a.qid
      if q and q > 0 and log[q] and not seen[q] then seen[q] = true; out[#out + 1] = q end
    end
  end
  return out
end
local ShareNext
local function ShareFinish()
  local sh = share
  share = nil
  if not sh then return end
  ns.Print((TR"%d Quests geteilt."):format(sh.n))
  for who, l in pairs(sh.miss) do
    ns.Print((TR"  %s: nicht angekommen: %s"):format(who, table.concat(l, ", ")))
  end
  if ns.TestLog then ns.TestLog("TEILEN", ("fertig %d von %d, Spieler mit Luecken %d"):format(sh.n, #sh.list, (function() local c = 0; for _ in pairs(sh.miss) do c = c + 1 end; return c end)())) end
end
local function ShareDone(qid)
  if not share or share.cur ~= qid then return end
  local title = (ns.logProgress and ns.logProgress[qid] and ns.logProgress[qid].title) or (TR"Quest " .. qid)
  for who in pairs(share.wait or {}) do
    share.miss[who] = share.miss[who] or {}
    table.insert(share.miss[who], title .. TR" (keine Antwort)")
  end
  share.cur, share.wait = nil, nil
  if share.manual then
    ns.Print((TR"Teilen %d/%d: nochmal klicken für die nächste Quest."):format(share.i, #share.list))
    if share.i >= #share.list then ShareFinish() end
    return
  end
  C_Timer.After(ns.SHARE.PAUSE_S, function() if share then ShareNext() end end)
end
ShareNext = function()
  local sh = share
  if not sh then return end
  while sh.i < #sh.list do
    sh.i = sh.i + 1
    local qid = sh.list[sh.i]
    local idx = LogIndex(qid)
    if idx and not (InCombatLockdown and InCombatLockdown()) then
      SelectQuestLogEntry(idx)
      if not (GetQuestLogPushable and not GetQuestLogPushable()) then
        local ok = ns.Api.Prot("QuestLogPushQuest", QuestLogPushQuest)
        local forb = ns.db and ns.db.forbidden and (tonumber(ns.db.forbidden.QuestLogPushQuest) or 0) > 0
        if not ok or forb then
          -- ohne Klick geblockt: ab jetzt je Klick eine Quest
          sh.manual = true
          if not ok then sh.i = sh.i - 1; ns.Print((TR"Teilen %d/%d: nochmal klicken für die nächste Quest."):format(sh.i, #sh.list)); return end
        end
        sh.n = sh.n + 1
        sh.cur, sh.wait = qid, {}
        for who in pairs(Units()) do sh.wait[who] = true end
        local cur = qid
        C_Timer.After(ns.SHARE.WAIT_S, function() ShareDone(cur) end)
        return
      end
    end
  end
  ShareFinish()
end
-- 1.4zzf (M49, M50): wahlweise eine eigene Liste (angehakte Quests im Questlog Route Fenster, Quests eines Dungeons),
-- davon nur die im Log. Teilbar prueft ShareNext wie bisher
function ns.ShareRouteQuests(only)
  if not (IsInGroup and IsInGroup()) then ns.Print(TR"Teilen geht nur in einer Gruppe."); return end
  if not (QuestLogPushQuest and SelectQuestLogEntry) then return end
  if share then
    -- laeuft schon: je Klick weiter (wenn der Client nur mit Klick teilt)
    if share.manual and not share.cur then ShareNext() else ns.Print((TR"Teilen läuft: %d/%d"):format(share.i, #share.list)) end
    return
  end
  local list
  if type(only) == "table" then
    list = {}
    local seen = {}
    for _, q in ipairs(only) do
      q = tonumber(q)
      if q and not seen[q] and LogIndex(q) then seen[q] = true; list[#list + 1] = q end
    end
    if #list == 0 then ns.Print(TR"Keine dieser Quests im Questlog zum Teilen."); return end
  else
    list = RouteQuestsInLog()
    if #list == 0 then ns.Print(TR"Keine Quest der Route im Questlog zum Teilen."); return end
  end
  if not sharePat then SharePatterns() end
  share = { list = list, i = 0, n = 0, miss = {} }
  ns.Print(((type(only) == "table") and TR"Teile %d Quests mit der Gruppe ..." or TR"Teile %d Quests der Route mit der Gruppe ..."):format(#list))
  ShareNext()
end
function ns.ShareState() return share and ("%d/%d"):format(share.i, #share.list) or nil end
-- 1.4zzf (M49, M50, K 13:55): Teilen Knoepfe ohne Gruppe grau (nicht weg), damit man sie findet. Tip sagt warum
do
  local btns = setmetatable({}, { __mode = "k" })
  function ns.ShareButtonState(b)
    local on = (IsInGroup and IsInGroup()) and true or false
    if b then
      if b.SetEnabled then b:SetEnabled(on) end
      b:SetAlpha(on and 1 or 0.45)
    end
    return on
  end
  function ns.ShareButtonSetup(b, title, tip)
    if not b then return end
    btns[b] = true
    b:HookScript("OnEnter", function(self)
      if ns.TipOwner then ns.TipOwner(self, "ANCHOR_RIGHT") else GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
      GameTooltip:AddLine(title, 1, 0.82, 0)
      if tip then GameTooltip:AddLine(tip, 1, 1, 1, true) end
      if not (IsInGroup and IsInGroup()) then GameTooltip:AddLine(TR"Geht nur in einer Gruppe.", 1, 0.4, 0.4, true) end
      GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    b:HookScript("OnShow", function(self) ns.ShareButtonState(self) end)
    ns.ShareButtonState(b)
  end
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("GROUP_ROSTER_UPDATE")
  ev:SetScript("OnEvent", function() for b in pairs(btns) do ns.ShareButtonState(b) end end)
end
local function ShareSystem(msg)
  if not (share and share.cur and share.wait) then return end
  if not sharePat then SharePatterns() end
  for _, p in ipairs(sharePat) do
    local ok, name = pcall(string.match, msg, p.pat)
    if ok and name then
      name = (Ambiguate and Ambiguate(name, "short")) or name
      if share.wait[name] then
        share.wait[name] = nil
        if p.why then
          local title = (ns.logProgress and ns.logProgress[share.cur] and ns.logProgress[share.cur].title) or (TR"Quest " .. share.cur)
          share.miss[name] = share.miss[name] or {}
          table.insert(share.miss[name], title .. " (" .. p.why .. ")")
        end
        if not next(share.wait) then ShareDone(share.cur) end
      end
      return
    end
  end
end

local function OnSystem(msg)
  if share then ShareSystem(msg) end
  if not lastPush or GetTime() - lastPush.at > 15 then return end
  if not patterns then BuildPatterns() end
  for _, p in ipairs(patterns) do
    local ok, name = pcall(string.match, msg, p.pat)
    if not ok then name = nil end
    if name then
      name = (Ambiguate and Ambiguate(name, "short")) or name
      if p.final then
        MarkFailed(name, lastPush.qid)
      else
        local t = tries[lastPush.qid .. name]
        if t then
          t.at = GetTime()
          -- zu weit weg, beschaeftigt, Log voll: zaehlt nicht als Versuch, sobald in Reichweite nochmal
          if p.again then t.n = math.max(0, t.n - 1) end
        end
      end
      return
    end
  end
end

function ns.ToggleAutoShare()
  local db = ns.db
  db.autoShare = (db.autoShare == false)
  ns.Print(db.autoShare and TR"Quests werden automatisch mit der Gruppe geteilt (nur Mitspieler mit Keine Zeit Leveling Guide, in Reichweite)" or TR"Automatisches Teilen aus")
end

------------------------------------------------------------
-- Dungeon Quests aufteilen
------------------------------------------------------------
local function World(map, x, y)
  if not (map and x) then return end
  local c, wx, wy
  if ns.MapWorld then c, wx, wy = ns.MapWorld(map, x, y)
  else
    if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    local ok, w
    ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
    if not ok or not w then return end
    wx, wy = w:GetXY()
  end
  if not wx then return end
  return { cont = c, wx = wx, wy = wy, map = map, x = x, y = y }
end

local function Secs(a, b)
  local sp = ns.PlanSpeed and ns.PlanSpeed() or 7
  if not (a and b) then return 600 end
  if a.cont ~= b.cont then
    local t = ns.TravelBest and ns.TravelBest(a, b, sp)
    return t or 900
  end
  -- 19.24 (Sascha Teil 1 Punkt 4): Laufweg ueber das Netz wie in der Route
  local d = ((ns.WalkYards and ns.WalkYards(a, b)) or math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * 1.2) / sp
  local t = (d > 300 and ns.TravelBest) and ns.TravelBest(a, b, sp)
  return (t and t < d) and t or d
end

-- Questgeber einer Quest als Punkt
local function Giver(qid)
  local tools = ns.OptTools and ns.OptTools()
  if not tools then return end
  local sb = tools.Q(qid, "startedBy")
  local npc = sb and sb[1] and sb[1][1]
  if not npc then return end
  local any = setmetatable({}, { __index = function() return true end })
  local pts = tools.Spawns(tools.N(npc, "spawns"), any, nil, 1)
  local p = pts[1]
  if not p then return end
  local w = World(p[1], p[2], p[3])
  if w then w.npc, w.who = npc, tools.N(npc, "name") end
  return w
end

-- Schritte fuer einen Spieler: seine Questgeber (kuerzeste Reihenfolge), dann Treffpunkt am Eingang
local function BuildSteps(d, qids, startPos)
  local nodes = {}
  for _, qid in ipairs(qids) do
    local g = Giver(qid)
    if g then
      local found
      for _, n in ipairs(nodes) do
        if n.cont == g.cont and math.sqrt((n.wx - g.wx) ^ 2 + (n.wy - g.wy) ^ 2) < 40 then found = n end
      end
      if found then table.insert(found.qids, qid) else g.qids = { qid }; table.insert(nodes, g) end
    end
  end
  local steps, cur, t = {}, startPos, 0
  while #nodes > 0 do
    local bi, bt
    for i, n in ipairs(nodes) do
      local s = Secs(cur, n)
      if not bt or s < bt then bi, bt = i, s end
    end
    local n = table.remove(nodes, bi)
    t = t + bt + 8 * #n.qids
    local acts = {}
    for _, qid in ipairs(n.qids) do
      table.insert(acts, { k = "A", qid = qid, quest = Q(qid, "name") or (TR"Quest " .. qid), who = n.who })
    end
    table.insert(steps, { map = n.map, x = n.x, y = n.y, t = t, lvl = UnitLevel("player"), acts = acts })
    cur = n
  end
  if d.entrance then
    local e = World(d.entrance[1], d.entrance[2], d.entrance[3])
    t = t + Secs(cur, e)
    table.insert(steps, { map = d.entrance[1], x = d.entrance[2], y = d.entrance[3], t = t, lvl = UnitLevel("player"),
      acts = { { k = "M", quest = d.name, map = d.entrance[1], x = d.entrance[2], y = d.entrance[3] } } })
  end
  return steps, t
end

local function LoadMine(d, qids)
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local me = pos and World(map, pos:GetXY())
  local steps, t = BuildSteps(d, qids, me)
  if #steps == 0 then return end
  if ns.OptPark then ns.OptPark() end
  ns.OptLoad(steps, { title = TR"Dungeon Quests: " .. d.name, sec = t, quests = #qids })
  if ns.db and ns.db.opt then ns.db.opt.split = true end
  local names = {}
  for _, qid in ipairs(qids) do table.insert(names, Q(qid, "name") or qid) end
  ns.Print((TR"Deine Aufgabe für %s: %s. Danach zum Eingang, dort werden die Quests geteilt."):format(d.name,
    #names > 0 and table.concat(names, ", ") or TR"nichts holen, direkt zum Eingang"))
end

local SplitNow
function ns.PartySplit(d)
  if not d then return end
  if not (IsInGroup and IsInGroup()) then ns.Print(TR"Du bist in keiner Gruppe."); return end
  -- nur der Gruppenleiter teilt auf (er rechnet die Schritte aller Mitglieder, sonst gibt es zwei Aufteilungen)
  if UnitIsGroupLeader and not ns.Api.U(UnitIsGroupLeader, "player") then ns.Print(TR"Nur der Gruppenleiter kann die Dungeon Quests aufteilen."); return end
  -- zuerst bei allen mit Wegweiser den Stand der Dungeon Quests abfragen, dann aufteilen
  if ns.AskDungeonStatus then
    ns.AskDungeonStatus(d.key or d.name)
    ns.Print(TR"Frage den Stand der Dungeon Quests in der Gruppe ab ...")
    C_Timer.After(3, function() SplitNow(d) end)
  else
    SplitNow(d)
  end
end

SplitNow = function(d)
  local key0 = d.key or d.name
  local others = ns.DungeonGroupStatus and ns.DungeonGroupStatus(key0) or {}
  -- offene Quests des Dungeons. Nicht teilbar (Klasse, aus einem Item) und mit Vorquest: jeder selbst
  local open, chain, self = {}, {}, {}
  for _, qid in ipairs(d.quests or {}) do
    local st = ns.QuestStatus and ns.QuestStatus(qid)
    local need = st ~= "done" and st ~= "log"
    for _, list in pairs(others) do local o = list[qid]; if o and o ~= "done" and o ~= "log" then need = true end end
    if need then
      local pre = Q(qid, "preQuestSingle") or Q(qid, "preQuestGroup")
      local rc = Q(qid, "requiredClasses")
      local sb = Q(qid, "startedBy")
      local fromItem = type(sb) == "table" and sb[3] and #sb[3] > 0
      if (rc and rc > 0) or fromItem then table.insert(self, qid)
      elseif type(pre) == "table" and #pre > 0 then table.insert(chain, qid)
      else table.insert(open, qid) end
    end
  end
  -- Spieler mit Keine Zeit Leveling Guide und ihre Position
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local me = pos and World(map, pos:GetXY())
  local players = { { name = UnitName("player"), pos = me, load = 0, qids = {} } }
  for who, g in pairs(ns.group or {}) do
    local p = g.pos and World(g.pos[1], g.pos[2], g.pos[3]) or me
    table.insert(players, { name = who, pos = p, load = 0, qids = {} })
  end
  -- Questgeber nach Ort buendeln, dann immer dem zuteilen, der am schnellsten fertig waere
  local clusters = {}
  for _, qid in ipairs(open) do
    local g = Giver(qid)
    if g then
      local found
      for _, c in ipairs(clusters) do
        if c.cont == g.cont and math.sqrt((c.wx - g.wx) ^ 2 + (c.wy - g.wy) ^ 2) < 80 then found = c end
      end
      if found then table.insert(found.qids, qid) else g.qids = { qid }; table.insert(clusters, g) end
    end
  end
  -- weit entfernte zuerst verteilen, die sind am teuersten
  table.sort(clusters, function(a, b) return Secs(me, a) > Secs(me, b) end)
  local function CanTake(p, c)
    if p.name == UnitName("player") then
      for _, q in ipairs(c.qids) do local st = ns.QuestStatus and ns.QuestStatus(q); if st == "level" or st == "pre" or st == "rep" then return false end end
      return true
    end
    local o = others[p.name]
    if not o then return true end
    for _, q in ipairs(c.qids) do local st = o[q]; if st == "level" or st == "pre" or st == "rep" then return false end end
    return true
  end
  for _, c in ipairs(clusters) do
    local best, bc
    for _, p in ipairs(players) do
      local cost = p.load + Secs(p.pos, c) + 8 * #c.qids
      if CanTake(p, c) and (not bc or cost < bc) then best, bc = p, cost end
    end
    -- keiner kann es (alle zu tief): trotzdem dem Ersten geben, Last weiter rechnen
    best = best or players[1]
    best.load = bc or (best.load + Secs(best.pos, c) + 8 * #c.qids)
    best.pos = c
    for _, qid in ipairs(c.qids) do table.insert(best.qids, qid) end
  end
  -- verschicken und eigene Route laden
  local key = d.key or d.name
  for _, p in ipairs(players) do
    if p.name ~= UnitName("player") and ns.GroupSend then
      ns.GroupSend(("D|%s|%s|%s"):format(key, p.name, table.concat(p.qids, ",")))
    end
  end
  local lines = {}
  for _, p in ipairs(players) do
    table.insert(lines, (TR"%s: %d Quests, ca %s"):format(p.name, #p.qids, ns.Clock and ns.Clock(p.load) or math.floor(p.load)))
  end
  ns.Print(TR"Dungeon Quests aufgeteilt: " .. table.concat(lines, " | "))
  if #chain > 0 then
    local names = {}
    for _, qid in ipairs(chain) do table.insert(names, Q(qid, "name") or qid) end
    ns.Print(TR"Kettenquests mit Vorquest muss jeder selbst holen: " .. table.concat(names, ", "))
  end
  if #self > 0 then
    local names = {}
    for _, qid in ipairs(self) do table.insert(names, Q(qid, "name") or qid) end
    ns.Print(TR"Kann man nicht teilen (Klasse oder aus einem Item), jeder selbst: " .. table.concat(names, ", "))
  end
  -- wer kann was nicht bekommen (Vorquest oder Level fehlt)
  for who, list in pairs(others) do
    local miss = {}
    for qid, st in pairs(list) do if st == "pre" or st == "level" then table.insert(miss, Q(qid, "name") or qid) end end
    if #miss > 0 then ns.Print((TR"%s kann nicht bekommen: %s"):format(who, table.concat(miss, ", "))) end
  end
  -- Mitspieler ohne Wegweiser: kurze Nachricht mit der Liste
  local allNames = {}
  for _, qid in ipairs(d.quests or {}) do table.insert(allNames, Q(qid, "name") or qid) end
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  for i = 1, math.max(0, n - 1) do
    local u = "party" .. i
    local nm = UnitName(u)
    if nm and not (ns.group and ns.group[(Ambiguate and Ambiguate(nm, "short")) or nm]) and SendChatMessage then
      local msg = (TR"Keine Zeit Leveling Guide: Quests für %s: %s. Am Eingang wird geteilt."):format(d.name or "?", table.concat(allNames, ", "))
      pcall(SendChatMessage, ns.U8Sub(msg, 250), "WHISPER", nil, nm)
    end
  end
  ns.splitDungeon = d
  LoadMine(d, players[1].qids)
end

-- Zuteilung von einem Mitspieler bekommen
function ns.PartyOnMessage(kind, from, key, target, list)
  if kind ~= "D" then return end
  if target ~= UnitName("player") then return end
  -- nur vom Gruppenleiter annehmen (Mitglieder mit alter Version oder aus Versehen ueberschreiben sonst die Aufteilung)
  local n = type(from) == "string" and ((Ambiguate and Ambiguate(from, "none")) or from:gsub("%-.*$", "")) or nil
  if not (n and UnitIsGroupLeader and ns.Api.U(UnitIsGroupLeader, n)) then
    if ns.MsgReject then ns.MsgReject("Dungeon Aufteilung: nicht vom Leiter") end
    return
  end
  local function Go()
    for _, d in ipairs(ns.dungeons or {}) do
      if (d.key or d.name) == key then
        local qids = {}
        for x in (list or ""):gmatch("%d+") do table.insert(qids, tonumber(x)) end
        ns.Print((TR"%s hat die Dungeon Quests aufgeteilt."):format(from))
        LoadMine(d, qids)
        return
      end
    end
  end
  if ns.dungeons then Go() elseif ns.BuildDungeonIndex then ns.BuildDungeonIndex(Go) end
end

------------------------------------------------------------
local f = CreateFrame("Frame")
ns.RegEv(f, "CHAT_MSG_SYSTEM")
f:SetScript("OnEvent", function(_, _, msg) if type(msg) == "string" then OnSystem(msg) end end)
ns.Ticker(3, Tick)
