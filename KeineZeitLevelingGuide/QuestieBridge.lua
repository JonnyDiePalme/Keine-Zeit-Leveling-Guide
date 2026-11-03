local ADDON, ns = ...
local TR = ns.TR

-- Verbindung zu Questie: echte Questgeber und Abgabe NPCs in die Route.
-- Ohne Questie bleiben die geschaetzten Quest Hubs aus Route.lua.

local QDB, ZDB, QLib, QPlayer, QAvail
ns.qStarts = nil -- [uiMapID] = { {x, y, npcName, minL, maxL, anzahl, quests = {...}}, ... }
ns.qEnds = nil   -- [uiMapID] = { {x, y, npcName, quests = {...}}, ... }
ns.qObjs = nil   -- [uiMapID] = { {x, y, "Questziel: ...", qid = , obj = Name}, ... }

local function Import(name)
  local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, name)
  if ok then return m end
end

local loadT = GetTime and GetTime() or 0
-- Questie noch nicht fertig: hoechstens so viele Sekunden, dann rechnet der Wegweiser trotzdem
function ns.QuestieWaitLeft()
  if Questie and Questie.started == true then return 0 end
  return math.max(1, math.ceil(90 - (GetTime() - loadT)))
end
local function Ready()
  -- erst wenn alle Addons geladen sind und der Ladebildschirm weg ist (Core.lua)
  if ns.StartReady and not ns.StartReady() then return false end
  if not (QuestieLoader and Questie and Questie.db and Questie.db.char) then return false end
  -- Questie startet in Stufen. Vor dem Ende (Questie.started) kennt es dein Volk noch nicht: fragt man dann,
  -- ob eine Quest machbar ist, merkt es sich "nein" fuer alle Quests deines Volkes, die ganze Sitzung lang
  -- (dann fehlen zb alle Startquests der Menschen und die Route grindet). Darum erst nach dem Start fragen.
  -- Manche Questie Versionen haben vor dem Start gar keinen Merker (nil statt false), auch das heisst: noch nicht fertig
  -- (Tester Log: "Questie ohne Startmeldung" und dann fehlten alle Startquests). Nach 90 Sekunden trotzdem, aber ohne Machbar Frage.
  if Questie.started ~= true then
    if (GetTime() - loadT) < 90 then return false end
    -- Questie haengt noch (baut zb beim ersten Start seine Datenbank): weiter, aber ohne Questie "machbar" Frage,
    -- sonst fehlen die Startquests (Eleneutil Fall). Sobald Questie fertig ist, rechnet die Route neu.
    if not ns.questieEarly then
      ns.questieEarly = true
      if ns.TestLog then ns.TestLog("RECHNER", "Questie ist nach 90s noch nicht gestartet, rechne ohne Questie Machbar Pruefung") end
      local function Watch()
        if Questie.started ~= true then C_Timer.After(5, Watch); return end
        ns.questieEarly = nil
        if ns.TestLog then ns.TestLog("RECHNER", "Questie jetzt fertig gestartet, Route wird neu gerechnet") end
        if ns.QuestieFull then ns.QuestieFull() end
        if ns.QuestieScan then ns.QuestieScan() end
        local db = ns.db
        if db and db.setupDone and db.planOn ~= false and ns.CalcGo then
          C_Timer.After(2, function() if not ns.planBuilding then ns.CalcGo(TR"Questie bereit") end end)
        end
      end
      C_Timer.After(5, Watch)
    end
  end
  if not QDB then
    QDB, ZDB, QLib, QPlayer = Import("QuestieDB"), Import("ZoneDB"), Import("QuestieLib"), Import("QuestiePlayer")
    QAvail = Import("AvailableQuests")
  end
  return QDB and QDB.QuestPointers and QDB.QueryQuestSingle and QDB.QueryNPCSingle
    and ZDB and ZDB.GetUiMapIdByAreaId and QLib and QLib.GetEffectiveQuestLevel
end

-- Feiertag Quests: nicht in die Leveling Route (ausser in den Einstellungen eingeschaltet und das Fest laeuft)
local QEvent
function ns.IsEventQuestSkipped(qid)
  if QEvent == nil then QEvent = (QuestieLoader and Import("QuestieEvent")) or false end
  if not QEvent or not QEvent.IsEventQuest then return false end
  local ok, isEv = pcall(QEvent.IsEventQuest, qid)
  if not (ok and isEv) then return false end
  if ns.db and ns.db.eventQuests and QEvent.IsEventActiveForQuest and QEvent.IsEventActiveForQuest(qid) then return false end
  return true
end

-- fuer andere Teile des Addons (Services, Optimierer)
function ns.QDBAccess()
  if Ready() then return QDB, ZDB, QLib, QPlayer end
end

local function Q(id, key)
  local ok, v = pcall(QDB.QueryQuestSingle, id, key)
  if not ok then return end
  -- 19.33 (Daten Korrektur vorquest_fehlt): gleich wie in der Route, damit der Pfeil die fehlende Vorquest zeigt
  if key == "preQuestSingle" and ns.DKPreSingle then return ns.DKPreSingle(id, v) end
  if key == "preQuestGroup" and ns.DKPreGroup then return ns.DKPreGroup(id, v) end -- 19.34 (vorquest_1934): negative Id
  return v
end

-- Stadtkarte in die Zone drumherum umrechnen (Donnerfels liegt in Mulgore usw)
local function Remap(ui, x, y, wantMaps)
  if wantMaps[ui] then return ui, x, y end
  local parent = ns.cityParent and ns.cityParent[ui]
  if parent and wantMaps[parent] and ns.ToMap then
    local px, py = ns.ToMap(ui, x, y, parent)
    if px then return parent, px, py, ui end
  end
end

-- Positionen eines NPCs auf den gewuenschten Karten
local function NpcPoints(npcId, wantMaps)
  local out = {}
  local ok, spawns = pcall(QDB.QueryNPCSingle, npcId, "spawns")
  if not ok or type(spawns) ~= "table" then return out end
  local _, name = pcall(QDB.QueryNPCSingle, npcId, "name")
  for areaId, coords in pairs(spawns) do
    local ok2, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, areaId)
    if ok2 and ui and type(coords) == "table" and type(coords[1]) == "table" then
      local c = coords[1]
      if c[1] and c[1] > 0 then
        local u2, x2, y2, city = Remap(ui, c[1] / 100, c[2] / 100, wantMaps)
        if u2 then table.insert(out, { u2, x2, y2, name or "NPC", city = city }) end
      end
    end
  end
  return out
end

-- alle Spawn Punkte auf den gewuenschten Karten
local function SpawnList(spawns, wantMaps, out)
  if type(spawns) ~= "table" then return end
  for areaId, coords in pairs(spawns) do
    local ok2, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, areaId)
    if ok2 and ui and type(coords) == "table" then
      for _, c in ipairs(coords) do
        if type(c) == "table" and c[1] and c[1] > 0 then
          local u2, x2, y2 = Remap(ui, c[1] / 100, c[2] / 100, wantMaps)
          if u2 then
            out[u2] = out[u2] or {}
            table.insert(out[u2], { x2, y2 })
          end
        end
      end
    end
  end
end

-- dichteste Stelle: der Spawn mit den meisten Nachbarn
local function Densest(list)
  local best, bn
  local n = math.min(#list, 80)
  for i = 1, n do
    local a = list[i]
    local cnt = 0
    for j = 1, n do
      local b = list[j]
      if (a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2 < 0.0025 then cnt = cnt + 1 end
    end
    if not bn or cnt > bn then best, bn = a, cnt end
  end
  return best, bn or 0
end

local function N(id, key) local ok, v = pcall(QDB.QueryNPCSingle, id, key); if ok then return v end end

-- Elite oder Gruppenquest? Questie Markierung, sonst Elite Mobs als Ziel
local eliteMemo = {}
function ns.IsEliteQuest(qid)
  if not (qid and QDB) then return false end
  local m = eliteMemo[qid]
  if m ~= nil then return m end
  local e = false
  if QDB.IsGroupQuest then
    local ok, v = pcall(QDB.IsGroupQuest, qid)
    if ok and v then e = true end
  end
  if not e then
    local objs = Q(qid, "objectives")
    for _, c in ipairs(type(objs) == "table" and objs[1] or {}) do
      local r = N(c[1], "rank")
      -- Rang 1 Elite, 2 seltene Elite, 3 Boss (gleich wie bei den Grind Spots)
      if r == 1 or r == 2 or r == 3 then e = true; break end
    end
  end
  eliteMemo[qid] = e
  return e
end

-- Ruf: hat die Quest einen Mindest (oder Hoechst) Ruf bei einer Fraktion?
local function RepName(v)
  if v >= 42000 then return TR"Ehrfürchtig" elseif v >= 21000 then return TR"Respektvoll" elseif v >= 9000 then return TR"Wohlwollend"
  elseif v >= 3000 then return TR"Freundlich" elseif v >= 0 then return TR"Neutral" elseif v >= -3000 then return TR"Unfreundlich" end
  return TR"Feindselig"
end
local function MyRep(fid)
  if not GetFactionInfoByID then return nil end
  local ok, name, _, _, _, _, value = pcall(GetFactionInfoByID, fid)
  if not ok or not name then return nil end
  return value or 0, name
end
-- liefert ok, Text (Text nur wenn Ruf fehlt)
function ns.RepCheck(qid)
  if not (qid and QDB) then return true end
  local mn, mx = Q(qid, "requiredMinRep"), Q(qid, "requiredMaxRep")
  if type(mn) == "table" and mn[1] then
    local v, name = MyRep(mn[1])
    if v and v < (mn[2] or 0) then
      return false, (TR"%s bei %s (du: %s)"):format(RepName(mn[2] or 0), name or "?", RepName(v))
    end
  end
  if type(mx) == "table" and mx[1] then
    local v, name = MyRep(mx[1])
    if v and v >= (mx[2] or 0) then return false, (TR"Ruf bei %s schon zu hoch"):format(name or "?") end
  end
  return true
end

-- Elite Quests mitnehmen? Solo nur wenn eingeschaltet, in der Gruppe standardmaessig ja
function ns.EliteAllowed()
  local db = ns.db or {}
  if db.eliteSolo then return true end
  if db.eliteGroup ~= false and IsInGroup and IsInGroup() then return true end
  return false
end
local function O(id, key) if not QDB.QueryObjectSingle then return end local ok, v = pcall(QDB.QueryObjectSingle, id, key); if ok then return v end end
local function I(id, key) if not QDB.QueryItemSingle then return end local ok, v = pcall(QDB.QueryItemSingle, id, key); if ok then return v end end

-- Zielpunkte einer Quest im Log, nur fuer noch offene Aufgaben
local objMobs -- [Mobname] = { qid = , obj = Aufgabe }
local objMobIds -- 20.2 (P11): [NPC Nummer] = gleicher Eintrag, Erkennung ueber die GUID (Name kann geheim oder anders sein)
local function ObjectivePoints(qid, wantMaps, store)
  local objs = Q(qid, "objectives")
  if type(objs) ~= "table" then return end
  local prog = ns.logProgress and ns.logProgress[qid]
  local title = (prog and prog.title) or Q(qid, "name") or (TR"Quest " .. qid)
  local function IsDone(name)
    if not (prog and name) then return false end
    for _, o in ipairs(prog.objs) do
      if o.text and o.text:find(name, 1, true) then return o.done end
    end
    return false
  end
  local function Place(name, spawnsByMap, npcs)
    if IsDone(name) then return end
    local bestUi, bestPt, bestN
    for ui, list in pairs(spawnsByMap) do
      local pt, cnt = Densest(list)
      if pt and (not bestN or cnt > bestN) then bestUi, bestPt, bestN = ui, pt, cnt end
    end
    if bestUi then
      store[bestUi] = store[bestUi] or {}
      table.insert(store[bestUi], { bestPt[1], bestPt[2], TR"Questziel: " .. (name or title), qid = qid, obj = name, quest = title, npcs = npcs })
    end
  end
  for _, c in ipairs(objs[1] or {}) do -- Mobs
    local sp = {}
    SpawnList(N(c[1], "spawns"), wantMaps, sp)
    local nm = N(c[1], "name")
    if nm and objMobs and not IsDone(nm) then
      objMobs[nm] = { qid = qid, obj = nm }
      if objMobIds and tonumber(c[1]) then objMobIds[tonumber(c[1])] = objMobs[nm] end
    end
    Place(nm, sp, { c[1] })
  end
  for _, c in ipairs(objs[2] or {}) do -- Objekte
    local sp = {}
    SpawnList(O(c[1], "spawns"), wantMaps, sp)
    Place(O(c[1], "name"), sp)
  end
  for _, c in ipairs(objs[3] or {}) do -- Items: wo sie droppen
    local sp = {}
    local iname = I(c[1], "name")
    -- 19.32 (Daten 1): gestrichene Dropper vor der Grenze 6 raus, wie in der Route
    local drops = I(c[1], "npcDrops") or {}
    if ns.DKDroppers then drops = ns.DKDroppers(qid, c[1], drops) or {} end
    -- 19.33 (Fall 418): bei mehr als 6 Droppern dieselben 6 wie die Route (Fundort in deinen Zonen, Level zum Questlevel)
    -- 19.33b (Pruefer 09:42 LEICHT 5): Questlevel wie in der Route (GetEffectiveQuestLevel, Rueckfall questLevel)
    if ns.PickDroppers then
      local okL, ql = pcall(QLib.GetEffectiveQuestLevel, qid)
      if not (okL and type(ql) == "number" and ql > 0) then ql = Q(qid, "questLevel") end
      drops = ns.PickDroppers(drops, wantMaps, ql, 6) or drops
    end
    for k, npc in ipairs(drops) do
      if k > 6 then break end
      SpawnList(N(npc, "spawns"), wantMaps, sp)
      local nm = N(npc, "name")
      if nm and objMobs and not IsDone(iname) then
        objMobs[nm] = { qid = qid, obj = iname }
        if objMobIds and tonumber(npc) then objMobIds[tonumber(npc)] = objMobs[nm] end
      end
    end
    for k, obj in ipairs(I(c[1], "objectDrops") or {}) do
      if k > 6 then break end
      SpawnList(O(obj, "spawns"), wantMaps, sp)
    end
    Place(I(c[1], "name"), sp)
  end
end

local function Add(store, ui, npc, x, y, name, quest)
  store[ui] = store[ui] or {}
  local e = store[ui][npc]
  if not e then
    e = { x, y, name, 99, 0, 0, quests = {}, npc = npc }
    store[ui][npc] = e
  end
  table.insert(e.quests, quest)
  e[6] = #e.quests
  if quest.level then
    if quest.level < e[4] then e[4] = quest.level end
    if quest.level > e[5] then e[5] = quest.level end
  end
end

local function ToLists(store)
  local out = {}
  for ui, byNpc in pairs(store) do
    out[ui] = {}
    for _, e in pairs(byNpc) do
      table.sort(e.quests, function(a, b) return (a.level or 0) < (b.level or 0) end)
      table.insert(out[ui], e)
    end
  end
  return out
end

------------------------------------------------------------
-- Quest Ketten
------------------------------------------------------------
local function Done(qid, complete)
  return complete[qid] and true or false
end

-- fehlende Vorquest einer Quest (oder nil, wenn alles erfuellt ist)
local function MissingPre(qid, complete, depth)
  depth = depth or 0
  if depth > 4 then return nil end
  local single = Q(qid, "preQuestSingle")
  if type(single) == "table" and #single > 0 then
    local any = false
    for _, id in ipairs(single) do if Done(id, complete) then any = true; break end end
    if not any then
      local first = single[1]
      return MissingPre(first, complete, depth + 1) or first
    end
  end
  local group = Q(qid, "preQuestGroup")
  if type(group) == "table" then
    for _, id in ipairs(group) do
      if not Done(id, complete) then return MissingPre(id, complete, depth + 1) or id end
    end
  end
  return nil
end

-- fuer den Pfeil: welche Vorquest fehlt, und wo gibt es sie?
function ns.MissingPre(qid)
  if not (QDB and Questie and Questie.db and Questie.db.char) then return end
  local complete = Questie.db.char.complete or {}
  local inLog = (QPlayer and QPlayer.currentQuestlog) or {}
  local pre = MissingPre(qid, complete)
  if not pre then return end
  local info = { id = pre, name = Q(pre, "name") or (TR"Quest " .. pre), inLog = inLog[pre] and true or false }
  local sb = Q(pre, "startedBy")
  local npc = sb and sb[1] and sb[1][1]
  if npc then
    local any = setmetatable({}, { __index = function() return true end })
    local p = NpcPoints(npc, any)[1]
    if p then info.npc, info.map = p[4], ns.cityParent and ns.cityParent[p[1]] or p[1] end
  end
  return info
end

-- Kette ab einer Quest: wie viele Teile, wie hoch geht sie, wo endet sie
local chainMemo, fzMemo = {}, {}
local ChainInfoRaw
local function ChainInfo(qid)
  local m = chainMemo[qid]
  if m == nil then m = { ChainInfoRaw(qid) }; chainMemo[qid] = m end
  return (unpack or table.unpack)(m)
end
ChainInfoRaw = function(qid)
  local n, maxL, last = 1, 0, qid
  local seen = { [qid] = true }
  local nxt = Q(qid, "nextQuestInChain")
  while type(nxt) == "number" and nxt > 0 and not seen[nxt] and n < 8 do
    seen[nxt] = true
    n = n + 1
    local okL, l = pcall(QLib.GetEffectiveQuestLevel, nxt)
    if okL and l and l > maxL then maxL = l end
    last = nxt
    nxt = Q(nxt, "nextQuestInChain")
  end
  -- Teil x von n: rueckwaerts zaehlen ueber die Vorquest
  local part = 1
  local cur = qid
  for _ = 1, 8 do
    local pre = Q(cur, "preQuestSingle")
    local prev = type(pre) == "table" and pre[1]
    if not prev or Q(prev, "nextQuestInChain") ~= cur then break end
    part = part + 1
    cur = prev
  end
  if n == 1 and part == 1 then return nil end
  return { parts = n + part - 1, part = part, maxLevel = maxL, last = last, lastName = Q(last, "name") }
end

-- In welcher Zone wird die Quest abgegeben?
local FinishZoneRaw
local function FinishZone(qid)
  local m = fzMemo[qid]
  if m == nil then m = FinishZoneRaw(qid) or false; fzMemo[qid] = m end
  return m or nil
end
FinishZoneRaw = function(qid)
  local fb = Q(qid, "finishedBy")
  local npc = fb and fb[1] and fb[1][1]
  if not npc then return nil end
  local any = setmetatable({}, { __index = function() return true end })
  local p = NpcPoints(npc, any)[1]
  if not p then return nil end
  return ns.cityParent and ns.cityParent[p[1]] or p[1]
end

-- Zonen in der Naehe der Route: aktuelle Zone und die naechsten zwei
local function NearZones(ui)
  local near = { [ui] = true }
  for k, id in ipairs(ns.zoneOrder or {}) do
    if id == ui then
      for j = k - 1, k + 2 do if ns.zoneOrder[j] then near[ns.zoneOrder[j]] = true end end
    end
  end
  -- Hauptstaedte zaehlen zur Zone drumherum
  for city, parent in pairs(ns.cityParent or {}) do if near[parent] then near[city] = true end end
  return near
end

local scanning, again, announced
-- Pruefsumme, damit die Route nur bei echten Aenderungen neu gebaut wird
local lastSig
local function Sig(...)
  local h = 0
  for k = 1, select("#", ...) do
    local store = select(k, ...)
    for ui, list in pairs(store or {}) do
      for _, e in pairs(list) do
        -- Reihenfolge egal: jeder Eintrag wird einzeln gehasht und aufaddiert
        local eh = (ui * 31 + math.floor((e[1] or 0) * 9973) * 7 + math.floor((e[2] or 0) * 9967) * 3 + k * 101) % 2147483629
        for _, q in ipairs(e.quests or {}) do eh = (eh + (q.id or 0) * 17) % 2147483629 end
        if e.qid then eh = (eh * 13 + e.qid) % 2147483629 end
        h = (h + eh) % 2147483629
      end
    end
  end
  return h
end
local fullNeeded, lastL = true, nil
function ns.QuestieFull() fullNeeded = true end

function ns.QuestieScan()
  if scanning then again = true; return end
  if not Ready() then
    C_Timer.After(5, ns.QuestieScan) -- Questie ist noch nicht fertig geladen
    return
  end
  scanning = true

  local L = UnitLevel("player")
  -- nur Fortschritt im Log geaendert? Dann nur Abgaben und Questziele neu, Questgeber bleiben
  local light = not fullNeeded and ns.qStarts ~= nil and L == lastL
  fullNeeded, lastL = false, L
  local complete = Questie.db.char.complete or {}
  local inLog = (QPlayer and QPlayer.currentQuestlog) or {}
  local wantMaps = {}
  for _, id in ipairs(ns.zoneOrder) do wantMaps[id] = true end
  local cur = ns.PlayerMap and ns.PlayerMap()
  if cur then wantMaps[cur] = true end

  local starts, ends, objPts = {}, {}, {}
  objMobs = {}
  objMobIds = {}
  if ns.ReadLog then ns.ReadLog() end

  -- fertige Quests im Log: wo abgeben (Stueck fuer Stueck im Step unten, mit vollem Log gab das sonst ein Ruckeln von 100 ms)
  local logIds, li = {}, 0
  for qid in pairs(inLog) do logIds[#logIds + 1] = qid end
  local function DoLog(qid)
    local ok, st = pcall(QDB.IsComplete, qid)
    if ok and st == 0 then pcall(ObjectivePoints, qid, wantMaps, objPts) end
    if ok and st == 1 then
      local fb = Q(qid, "finishedBy")
      local qname = Q(qid, "name") or (TR"Quest " .. qid)
      local okL, qlvl = pcall(QLib.GetEffectiveQuestLevel, qid)
      if not okL then qlvl = nil end
      for _, npc in ipairs((fb and fb[1]) or {}) do
        for _, p in ipairs(NpcPoints(npc, wantMaps)) do
          Add(ends, p[1], npc, p[2], p[3], p[4], { id = qid, name = qname, level = qlvl })
        end
      end
    end
  end

  -- neue Quests, die zum Level passen
  -- Questie prueft hier schon Klasse, Rasse, Vorquests, Ruf, Berufe und was der NPC wirklich anbietet
  local avail = QAvail and QAvail.__availableQuests
  local useAvail = type(avail) == "table" and next(avail) ~= nil
  local ids = {}
  if light then
    -- nichts, Questgeber bleiben wie sie sind
  elseif useAvail then
    for id in pairs(avail) do ids[#ids + 1] = id end
  else
    for id in pairs(QDB.QuestPointers) do ids[#ids + 1] = id end
  end
  local blocked = (ns.db and ns.db.questBlocked) or {}
  local classQ, classSeen = {}, {}
  local anyMap = setmetatable({}, { __index = function() return true end })
  local i = 0
  local SafeStep
  local function Step()
    local n = 0
    -- erst die Quests im Log, hoechstens ca 8 ms pro Bild
    local clock = debugprofilestop
    local t0 = clock and clock()
    while li < #logIds do
      li = li + 1
      DoLog(logIds[li])
      if t0 and clock() - t0 > 8 and li < #logIds then C_Timer.After(0, SafeStep); return end
    end
    while i < #ids and n < 300 do
      i = i + 1
      n = n + 1
      local qid = ids[i]
      if not complete[qid] and not inLog[qid] and not blocked[qid] then
        local ok, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
        if ok and ql and rl and rl <= L and ql >= L - 4 and ql <= L + 3 then
          local okD, doable = true, true
          if not useAvail and not ns.questieEarly then okD, doable = pcall(QDB.IsDoable, qid) end
          -- Klassen und Rassen Quests immer selber nachpruefen
          local rc, rr = Q(qid, "requiredClasses"), Q(qid, "requiredRaces")
          local _, _, classID = UnitClass("player")
          local _, _, raceID = UnitRace("player")
          if rc and rc > 0 and classID and not ns.HasBit(rc, classID - 1) then doable = false end
          if rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then doable = false end
          local skip = (QDB.IsRepeatable and QDB.IsRepeatable(qid)) or (QDB.IsDungeonQuest and QDB.IsDungeonQuest(qid))
            or (QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or (QDB.IsPvPQuest and QDB.IsPvPQuest(qid))
          -- Vorquest fehlt? Dann ist die Quest noch nicht annehmbar
          if okD and doable and not skip and MissingPre(qid, complete) then skip = true end
          if okD and doable and not skip and ns.IsEventQuestSkipped(qid) then skip = true end
          if okD and doable and not skip and not ns.RepCheck(qid) then skip = true end
          local elite = okD and doable and not skip and ns.IsEliteQuest(qid)
          if elite and not ns.EliteAllowed() then skip = true end
          if okD and doable and not skip then
            local sb = Q(qid, "startedBy")
            local qname = Q(qid, "name") or (TR"Quest " .. qid)
            if elite then qname = qname .. TR" |cffff5050(Gruppe)|r" end
            local isClass = rc and rc > 0
            local chain = ChainInfo(qid)
            local fz = FinishZone(qid)
            for _, npc in ipairs((sb and sb[1]) or {}) do
              for _, p in ipairs(NpcPoints(npc, wantMaps)) do
                -- schickt die Quest weit weg (Abgabe in einer ganz anderen Gegend)? Dann auslassen,
                -- ausser es ist eine Klassenquest
                local far = fz and not NearZones(p[1])[fz]
                if far and not isClass then
                  ns.skippedFar = ns.skippedFar or {}
                  ns.skippedFar[qid] = { name = qname, zone = fz }
                else
                  Add(starts, p[1], npc, p[2], p[3], p[4], { id = qid, name = qname, level = ql, class = isClass, chain = chain })
                end
              end
              -- Klassenquests extra merken, egal in welcher Zone der NPC steht
              if isClass and not classSeen[qid] then
                local all = NpcPoints(npc, anyMap)
                local p = all[1]
                classSeen[qid] = true
                table.insert(classQ, { id = qid, name = qname, level = ql, npc = p and p[4] or N(npc, "name") or "NPC",
                  map = p and p[1], x = p and p[2], y = p and p[3] })
              end
            end
          end
        end
      end
    end
    if i < #ids then
      C_Timer.After(0, SafeStep)
      return
    end
    if not light then ns.qStarts = ToLists(starts) end
    ns.qEnds = ToLists(ends)
    ns.qObjs = objPts
    ns.objMobs = objMobs
    ns.objMobIds = objMobIds
    if light then classQ = ns.classQuests or {} end
    table.sort(classQ, function(a, b) return (a.level or 0) < (b.level or 0) end)
    -- neue Klassenquest? einmal im Chat melden
    local db = ns.db
    if db then
      db.classSeen = db.classSeen or {}
      for _, c in ipairs(classQ) do
        if not db.classSeen[c.id] then
          db.classSeen[c.id] = true
          ns.Print((TR"|cffff80ffKlassenquest:|r %s (Level %d) bei %s in %s"):format(c.name, c.level or 0, c.npc, c.map and ns.ZoneName(c.map) or "?"))
        end
      end
    end
    ns.classQuests = classQ
    scanning = false
    local sig = Sig(ns.qStarts, ns.qEnds, ns.qObjs)
    local changed = sig ~= lastSig
    lastSig = sig
    if changed and ns.db then ns.db.learnedRev = (ns.db.learnedRev or 0) + 1 end
    if not announced then
      announced = true
      local nz, nn = 0, 0
      for _, list in pairs(ns.qStarts) do nz = nz + 1; nn = nn + #list end
      ns.Print((TR"Questie verbunden: %d Questgeber in %d Zonen eingeplant"):format(nn, nz))
      if ns.AutoOpt then C_Timer.After(2, function() ns.AutoOpt() end) end
    end
    if changed then
      if ns.Draw then ns.Draw() end
      if ns.RefreshUI then ns.RefreshUI() end
    end
    if again then again = false; ns.QuestieScan() end
  end
  -- ein Fehler im Lesen: nicht fuer immer "scanning" lassen (sonst bleibt die Route eingefroren)
  SafeStep = function()
    local ok, err = pcall(Step)
    if not ok then
      scanning = false
      if ns.TestLog then ns.TestLog("FEHLER", "Questie Scan: " .. tostring(err)) end
      if again then again = false; C_Timer.After(2, ns.QuestieScan) end
    end
  end
  SafeStep()
end

-- Vorschau fuer die Gold Route: Quests Level 55 bis 60, auch wenn man noch tiefer ist
local goldScanning
function ns.ScanGoldQuests(done)
  if goldScanning then return end
  if not Ready() then ns.Print(TR"Questie Daten sind noch nicht geladen"); return end
  goldScanning = true
  local complete = Questie.db.char.complete or {}
  local inLog = (QPlayer and QPlayer.currentQuestlog) or {}
  local wantMaps = {}
  for _, id in ipairs(ns.zoneOrder) do wantMaps[id] = true end
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local starts = {}
  local ids = {}
  for id in pairs(QDB.QuestPointers) do ids[#ids + 1] = id end
  local i = 0
  local SafeStep
  local function Step()
    local n = 0
    while i < #ids and n < 400 do
      i = i + 1
      n = n + 1
      local qid = ids[i]
      if not complete[qid] and not inLog[qid] then
        local ok, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
        if ok and ql and ql >= 55 and ql <= 60 and (not rl or rl <= 60) then
          local good = true
          local rc, rr = Q(qid, "requiredClasses"), Q(qid, "requiredRaces")
          if rc and rc > 0 and classID and not ns.HasBit(rc, classID - 1) then good = false end
          if rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then good = false end
          if good and ((QDB.IsRepeatable and QDB.IsRepeatable(qid)) or (QDB.IsDungeonQuest and QDB.IsDungeonQuest(qid))
            or (QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or (QDB.IsPvPQuest and QDB.IsPvPQuest(qid))) then good = false end
          if good then
            local sb = Q(qid, "startedBy")
            local qname = Q(qid, "name") or (TR"Quest " .. qid)
            for _, npc in ipairs((sb and sb[1]) or {}) do
              for _, p in ipairs(NpcPoints(npc, wantMaps)) do
                Add(starts, p[1], npc, p[2], p[3], p[4], { id = qid, name = qname, level = ql })
              end
            end
          end
        end
      end
    end
    if i < #ids then C_Timer.After(0, SafeStep); return end
    ns.goldStarts = ToLists(starts)
    goldScanning = false
    if done then done() end
  end
  SafeStep = function()
    local ok, err = pcall(Step)
    if not ok then
      goldScanning = false
      if ns.TestLog then ns.TestLog("FEHLER", "Gold Scan: " .. tostring(err)) end
    end
  end
  SafeStep()
end

function ns.HasQuestie()
  return ns.qStarts ~= nil
end

-- bei Aenderungen neu rechnen, gebremst
local timer
-- Neu scannen; ein frueherer Termin gewinnt immer
local dueAt
local function Later(sec)
  sec = sec or 2
  local t = GetTime() + sec
  if dueAt and dueAt <= t then return end
  dueAt = t
  C_Timer.After(sec, function()
    if dueAt and GetTime() >= dueAt - 0.05 then
      dueAt = nil
      ns.QuestieScan()
    end
  end)
end

-- sofort aus der Route nehmen, ohne auf den Scan zu warten
local function DropQuest(store, qid)
  if not (store and qid) then return false end
  local changed = false
  for _, list in pairs(store) do
    for i = #list, 1, -1 do
      local e = list[i]
      for j = #(e.quests or {}), 1, -1 do
        if e.quests[j].id == qid then table.remove(e.quests, j); changed = true end
      end
      if e.quests and #e.quests == 0 then table.remove(list, i) end
    end
  end
  return changed
end
local function Changed()
  lastSig = nil
  if ns.db then ns.db.learnedRev = (ns.db.learnedRev or 0) + 1 end
  if ns.Draw then ns.Draw() end
  if ns.TickNow then ns.TickNow() end
  if ns.RefreshUI then ns.RefreshUI() end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_TURNED_IN")
f:RegisterEvent("QUEST_REMOVED")
f:RegisterEvent("QUEST_LOG_UPDATE")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("GOSSIP_SHOW")
f:RegisterEvent("QUEST_GREETING")
-- Quest angenommen: bestaetigen, wenn sie zum aktuellen Questgeber gehoert
local function ConfirmAccepted(questID)
  local ag = ns.atGiver
  if not (ag and ns.qStarts and questID) then return end
  for _, e in ipairs(ns.qStarts[ag.map] or {}) do
    if e.npc == ag.npc then
      local open, total, got = 0, #e.quests, nil
      for _, q in ipairs(e.quests) do
        if q.id == questID then got = q.name else open = open + 1 end
      end
      if got then
        ns.Print((TR"Angenommen: %s (%d von %d bei %s)"):format(got, total - open, total, ag.name or "?"))
        if open == 0 then ns.Print(TR"|cff40ff40Alle Quests bei " .. (ag.name or "?") .. TR" angenommen!|r") end
      end
    end
  end
end

f:SetScript("OnEvent", function(_, event, a1, a2)
  if event == "QUEST_ACCEPTED" then
    local qid = type(a2) == "number" and a2 or a1
    ConfirmAccepted(qid)
    if DropQuest(ns.qStarts, qid) then Changed() end
  elseif event == "QUEST_TURNED_IN" then
    if DropQuest(ns.qEnds, a1) then Changed() end
  end
  -- gesperrte Quests nach Level Up oder Abgabe wieder pruefen (neue Kettenquests)
  if (event == "PLAYER_LEVEL_UP" or event == "QUEST_TURNED_IN") and ns.db then ns.db.questBlocked = {} end
  if event == "PLAYER_LOGIN" then
    if not QuestieLoader then return end -- kein Questie installiert
    C_Timer.After(8, ns.QuestieScan)
  elseif QuestieLoader then
    -- Annehmen und Abgeben schnell, Fortschritt im Log etwas gebremst
    local wait = 1.5
    if event ~= "QUEST_LOG_UPDATE" then fullNeeded = true end
    if event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" or event == "QUEST_REMOVED" then wait = 0.4 end
    if event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then wait = 0.2 end
    Later(wait)
  end
end)
