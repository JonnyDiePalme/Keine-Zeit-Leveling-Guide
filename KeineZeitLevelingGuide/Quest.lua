local ADDON, ns = ...
local TR = ns.TR

-- Automatisch Quests annehmen und abgeben.
-- Shift gedrueckt halten beim Ansprechen = Automatik fuer dieses Mal aus.
-- Bei mehreren Belohnungen waehlt der Spieler selber.

local tried = {}

-- Questlog, alte und neue API
local function NumEntries()
  if GetNumQuestLogEntries then return GetNumQuestLogEntries() end
  if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then return C_QuestLog.GetNumQuestLogEntries() end
  return 0, 0
end

local function LogEntry(i)
  if GetQuestLogTitle then
    local title, _, _, isHeader, _, isComplete = GetQuestLogTitle(i)
    return title, isHeader, (isComplete == 1 or isComplete == true)
  end
  if C_QuestLog and C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(i)
    if not info then return end
    local done = info.questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID)
    return info.title, info.isHeader, done
  end
end

local function Enabled()
  return ns.db and ns.db.autoQuest and not IsShiftKeyDown()
end

local function LogFull()
  local n = select(2, NumEntries())
  local max = ns.LogMax()
  return n and n >= max
end

-- Quest passt zum Level? Nicht grau und nicht mehr als 3 Level drueber
-- Soll Auto Quest diese Quest annehmen? Standard: nur was in der Route (Fahrplan) steht, plus Klassenquests.
-- Mit dem Schalter "alle Quests" wie frueher jede passende.
local wantCache, wantAt
local function RouteQuests()
  local opt = ns.db and ns.db.opt
  if wantCache and wantAt == opt and opt and wantCache.n == #(opt.steps or {}) then return wantCache end
  local ids, names = {}, {}
  local function Add(a)
    if a.qid then ids[a.qid] = true end
    if type(a.quest) == "string" then
      names[(a.quest:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(" %(.-%)$", ""))] = true
    end
  end
  for _, st in ipairs(opt and opt.steps or {}) do for _, a in ipairs(st.acts or {}) do Add(a) end end
  for _, st in ipairs(ns.db and ns.db.plan60 and ns.db.plan60.steps or {}) do for _, a in ipairs(st.acts or {}) do Add(a) end end
  wantCache, wantAt = { ids = ids, names = names, n = #(opt and opt.steps or {}) }, opt
  return wantCache
end
local function IsClassQuest(qid)
  if not qid or not ns.QDBAccess then return false end
  local qdb = ns.QDBAccess()
  if not qdb then return false end
  local ok, rc = pcall(qdb.QueryQuestSingle, qid, "requiredClasses")
  return ok and type(rc) == "number" and rc > 0
end
-- "alle annehmen": trotzdem keine roten, Dungeon oder Elite Quests (die landen sonst ungefragt im Log)
local function OkForAll(qid)
  if not qid or qid <= 0 then return true end
  if ns.IsDungeonQuest and ns.IsDungeonQuest(qid) then return false end
  if ns.IsEliteQuest and ns.IsEliteQuest(qid) and not (IsInGroup and IsInGroup()) then return false end
  local QL
  if ns.QDBAccess then local _, _, l = ns.QDBAccess(); QL = l end
  if type(QL) == "table" and QL.GetEffectiveQuestLevel then
    local ok, ql = pcall(QL.GetEffectiveQuestLevel, qid)
    if ok and type(ql) == "number" and ql > (UnitLevel("player") or 1) + 3 then return false end
  end
  return true
end
-- 1.1 (S Log L6.2 und L8.4: "Quest abgeben oder annehmen nur die, die es betrifft"): Auto Quest nimmt nur noch Quests,
-- die im aktuellen Schritt stehen oder in den naechsten Schritten an derselben Stelle (Buendel beim selben NPC oder Hub),
-- dazu die Schritte bei dir in der Naehe. Vorher galt die ganze Route (auch Quests, die erst Stunden spaeter dran sind)
local STEP_NEAR_YD = 40     -- Schritte so nah am aktuellen Schritt oder an dir gehoeren zum Buendel
local STEP_NEAR_MAX = 8     -- so viele Schritte voraus hoechstens
local function PlainQ(t) return (tostring(t):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub(" %(.-%)$", "")) end
function ns.StepWindowQuests()
  local opt = ns.db and ns.db.opt
  if not (opt and opt.steps and #opt.steps > 0) then return nil end
  local i0 = opt.idx or 1
  local s0 = opt.steps[i0]
  if not s0 then return nil end
  local ids, names = {}, {}
  local function Add(s)
    for _, a in ipairs(s.acts or {}) do
      if a.qid then ids[a.qid] = ids[a.qid] or a.k or true end
      if type(a.quest) == "string" then names[PlainQ(a.quest)] = true end
    end
  end
  Add(s0)
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm and C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(pm, "player")
  local px, py
  if pos then px, py = pos:GetXY() end
  local D = ns.WorldDistXY
  local chain = true
  for i = i0 + 1, math.min(#opt.steps, i0 + STEP_NEAR_MAX) do
    local s = opt.steps[i]
    if not (s and s.map and s.x and s.y and D) then break end
    local near = false
    if chain and s0.map and s0.x and s0.y then
      local d = D(s0.map, s0.x, s0.y, s.map, s.x, s.y)
      if d and d <= STEP_NEAR_YD then near = true else chain = false end
    end
    if not near and px then
      local d = D(pm, px, py, s.map, s.x, s.y)
      if d and d <= STEP_NEAR_YD then near = true end
    end
    if near then Add(s) end
  end
  return ids, names
end

function ns.WantQuest(qid, title)
  if not ns.db then return true end
  if ns.db.autoQuestAll then return OkForAll(qid) end
  if IsClassQuest(qid) then return true end
  -- noch keine Route (Questie laedt noch): nicht blockieren
  local opt = ns.db.opt
  if not (opt and opt.steps and #opt.steps > 0) and not (ns.db.plan60 and ns.db.plan60.secs) then return true end
  local ids, names = ns.StepWindowQuests()
  if ids then
    if qid and ids[qid] then return true end
    if title and names[PlainQ(title)] then return true end
    -- Reserve Quests (nahe der Route, siehe Optimizer ns.ReserveQuests): duerfen mit, solange Platz im Log ist
    if qid and ns.IsReserveQuest and ns.IsReserveQuest(qid) then return true end
    return false
  end
  local r = RouteQuests()
  if qid and r.ids[qid] then return true end
  if title and r.names[title] then return true end
  return false
end
-- Abgeben: nur fertige Quests, und nur solche aus dem aktuellen Buendel oder ohne geplante Abgabe in der Route
local function WantTurnIn(qid, title)
  if not ns.db then return true end
  if ns.db.autoQuestAll then return true end
  local ids, names = ns.StepWindowQuests()
  if not ids then return true end
  if qid and ids[qid] then return true end
  if title and names[PlainQ(title)] then return true end
  local r = RouteQuests()
  if (qid and r.ids[qid]) or (title and r.names[PlainQ(title)]) then return false end
  return true
end
ns.WantTurnIn = WantTurnIn

local function GoodLevel(level, trivial)
  if trivial then return false end
  if not level or level <= 0 then return true end
  return level <= UnitLevel("player") + 3
end

-- welcher Quest Hub ist in der Naehe
local function NearHub()
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  for _, h in ipairs(ns.hubs[mapID] or {}) do
    if math.sqrt((px - h[1]) ^ 2 + (py - h[2]) ^ 2) < 0.05 then
      return mapID .. ":" .. h[3]
    end
  end
end

local function RememberQuest(title)
  local key = NearHub()
  if not key or not title then return end
  local mapID, name = key:match("^(%d+):(.+)$")
  for _, h in ipairs(ns.hubs[tonumber(mapID)] or {}) do
    if h[3] == name and ns.MarkHubVisited then ns.MarkHubVisited(tonumber(mapID), h) end
  end
  ns.db.hubQuests = ns.db.hubQuests or {}
  ns.db.hubQuests[key] = ns.db.hubQuests[key] or {}
  ns.db.hubQuests[key][title] = true
end

-- erwartete Quests, die der NPC nicht anbietet, fuer die Route sperren
local function CheckOffered(offered)
  local ag = ns.atGiver
  if not (ag and ns.qStarts and ns.db) or ag.turnin then return end
  for _, e in ipairs(ns.qStarts[ag.map] or {}) do
    if e.npc == ag.npc then
      for _, q in ipairs(e.quests) do
        if q.id and not offered[q.id] then
          ns.db.questBlocked = ns.db.questBlocked or {}
          ns.db.questBlocked[q.id] = true
          local pre = ns.MissingPre and ns.MissingPre(q.id)
          if pre and pre.inLog then
            ns.Print((TR"%s gibt %s erst nach |cffffd100%s|r, die hast du schon im Log. Erst die fertig machen."):format(ag.name or "NPC", q.name or "?", pre.name))
          elseif pre then
            ns.Print((TR"%s gibt %s erst nach der Vorquest |cffffd100%s|r%s. Lohnt sich nur, wenn du eh dort bist, sonst auslassen.")
              :format(ag.name or "NPC", q.name or "?", pre.name, pre.npc and (TR" bei " .. pre.npc .. (pre.map and (TR" in " .. ns.ZoneName(pre.map)) or "")) or ""))
          else
            ns.Print((TR"%s bietet %s nicht an, wird aus der Route genommen"):format(ag.name or "NPC", q.name or "?"))
          end
        end
      end
    end
  end
end

-- 1.2i (P70, K 17:00: "Annehmen Der Zorn von Rath'mael" ging nicht, HAENGT 43 yd): beim NPC vom jetzigen Schritt bietet
-- er eine Quest zum Annehmen nicht an (Vorquest fehlt, andere Fassung der Quest auf Forever ...): Quest aus der Route nehmen
-- statt davor zu haengen, mit Grund ins Log (fehlende Vorquest laut Questie, wenn bekannt). Nur fuer den NPC dieses Schritts
-- 1.3u (P101 Punkt 1, S Log 98094 Darthalia: "NPC bietet sie nicht an" 3 mal, nach jeder neuen Route wieder drin):
-- gemerkt pro Charakter in db.offerNo[qid] = { lvl, pre, at }. Gilt, bis du ein Level hoeher bist, die fehlende Vorquest
-- erledigt ist oder OFFER_NO_MAX_S vorbei sind. Die Route plant sie so lange nicht ein (Optimizer, ns.OfferNo)
local OFFER_NO_MAX_S = 3600
-- 1.3ze (Pr 07:35 Befund 1: NPC bietet nie an, Route lief nach jedem Level wieder hin): ab der OFFER_NO_LONG_N ten Ablehnung
-- derselben Quest laenger merken, OFFER_NO_LONG_L Level oder OFFER_NO_LONG_S Sekunden (Vorquest fertig gibt immer frei)
local OFFER_NO_LONG_N, OFFER_NO_LONG_L, OFFER_NO_LONG_S = 2, 3, 3 * 3600
function ns.OfferNo(qid)
  local t = qid and ns.db and ns.db.offerNo and ns.db.offerNo[qid]
  -- 1.3zzm (P133 Teil f): ohne eigene Erfahrung zaehlt, was andere Spieler gemeldet haben (Teilen.lua ns.OfferNoShared)
  if not t then return ns.OfferNoShared and ns.OfferNoShared(qid) or false end
  if t.free then return false end
  local L = UnitLevel and UnitLevel("player") or 0
  local now = time and time() or 0
  local long = (t.n or 1) >= OFFER_NO_LONG_N
  local lvlFree = (t.lvl or 0) + (long and OFFER_NO_LONG_L or 1)
  if L >= lvlFree or (t.pre and QDone(t.pre)) or now - (t.at or 0) > (long and OFFER_NO_LONG_S or OFFER_NO_MAX_S) then
    -- frei, aber die Zahl der Ablehnungen bleibt (beim naechsten Mal laenger)
    t.free = true
    if ns.TestLog then ns.TestLog("SCHRITT", ("Quest %d wieder einplanbar (Level, Vorquest oder Zeit, Ablehnungen %d)"):format(qid, t.n or 1)) end
    return false
  end
  return true
end
local function OfferNoSet(qid, pre)
  if not (qid and ns.db) then return end
  ns.db.offerNo = ns.db.offerNo or {}
  local old = ns.db.offerNo[qid]
  ns.db.offerNo[qid] = { lvl = UnitLevel and UnitLevel("player") or 0, pre = pre and pre.id or nil, at = time and time() or 0,
    n = ((old and old.n) or (old and 1) or 0) + 1 }
end

local function OptOfferCheck(ids, nothing)
  if not (ns.db and ns.db.optMode and ns.OptCurrentAct and ns.OptDropQuest) then return end
  local st = ns.db.opt and ns.db.opt.steps and ns.db.opt.steps[ns.db.opt.idx or 1]
  if not st then return end
  local nm = ns.Api.U(UnitName, "npc")
  if type(nm) ~= "string" then return end
  -- sicher nur mit Quest Nummern (Gossip) oder wenn der NPC gar nichts zum Annehmen anbietet (Namen vergleichen waere
  -- unsicher, Schreibweisen weichen ab)
  if not (nothing or (ids and next(ids))) then return end
  -- 1.3u (P101 Punkt 2, S Log 20:01 Kampf um Hillsbrad 527/528): im selben Schritt steht noch eine Abgabe, die im Log ist.
  -- Erst nach der Abgabe bietet der NPC die Folgequest an, darum jetzt nicht pruefen (das Fenster kommt danach neu)
  for _, a in ipairs(st.acts or {}) do
    if a.k == "T" and a.qid and ns.logProgress and ns.logProgress[a.qid] then
      if ns.TestLog then ns.TestLog("SCHRITT", ("Annehmen Pruefung wartet: erst Abgabe %s"):format(tostring(a.quest))) end
      return
    end
  end
  -- 1.3v (P102 Punkt 3, S Log 02:01: 2842 "bietet sie nicht an" und 6 s spaeter angenommen): nicht sofort, sondern nach
  -- OFFER_RECHECK_S nochmal schauen. Nur wenn das Fenster beim selben NPC dann noch offen ist und die Quest weiter fehlt,
  -- kommt sie raus und wird gemerkt. Fenster zu oder Quest jetzt da = nichts
  local cand = {}
  for _, a in ipairs(st.acts or {}) do
    local who = a.k == "A" and a.qid and (ns.NpcName and ns.NpcName(a.npc, a.who) or a.who)
    if who and who == nm and not (ns.logProgress and ns.logProgress[a.qid]) and not (ids and ids[a.qid]) then cand[#cand + 1] = a end
  end
  if #cand == 0 then return end
  local gossip = ids ~= nil
  C_Timer.After(OFFER_RECHECK_S, function()
    local nm2 = ns.Api.U(UnitName, "npc")
    if nm2 ~= nm then
      if ns.TestLog then ns.TestLog("SCHRITT", ("Annehmen Pruefung bei %s: Fenster zu, nichts gemerkt"):format(nm)) end
      return
    end
    local now = {}
    local anyAvail = false
    if gossip and C_GossipInfo and C_GossipInfo.GetAvailableQuests then
      for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do if q.questID then now[q.questID] = true; anyAvail = true end end
      for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do if q.questID then now[q.questID] = true end end
    elseif GetNumAvailableQuests then
      anyAvail = GetNumAvailableQuests() > 0
    end
    for _, a in ipairs(cand) do
      local still = not (ns.logProgress and ns.logProgress[a.qid]) and not now[a.qid] and (gossip or not anyAvail)
      if still then
        local pre = ns.MissingPre and ns.MissingPre(a.qid)
        local why = pre and ((TR"Vorquest fehlt: %s"):format(tostring(pre.name or pre.id or "?"))) or TR"NPC bietet sie nicht an"
        if ns.TestLog then ns.TestLog("SCHRITT", ("Annehmen geht nicht: %s bei %s (%s), Quest raus, gemerkt bis Level, Vorquest oder 1 Std"):format(tostring(a.quest), nm, why)) end
        OfferNoSet(a.qid, pre)
        ns.OptDropQuest(a.qid, why)
      elseif ns.TestLog then
        ns.TestLog("SCHRITT", ("Annehmen Pruefung bei %s: %s jetzt da, bleibt"):format(nm, tostring(a.quest)))
      end
    end
  end)
end

-- Gossip Fenster (normale NPCs mit Text)
local function HandleGossip()
  if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
    local offered = {}
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do if q.questID then offered[q.questID] = true end end
    for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do if q.questID then offered[q.questID] = true end end
    CheckOffered(offered)
    pcall(OptOfferCheck, offered, #(C_GossipInfo.GetAvailableQuests() or {}) == 0)
  end
  if not Enabled() then return end
  if C_GossipInfo and C_GossipInfo.GetActiveQuests then
    for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
      if q.isComplete and WantTurnIn(q.questID, q.title) then ns.Api.Prot("C_GossipInfo.SelectActiveQuest", C_GossipInfo.SelectActiveQuest, q.questID); return end
    end
    if LogFull() then return end
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
      if GoodLevel(q.questLevel, q.isTrivial) and not q.repeatable and ns.WantQuest(q.questID, q.title) then
        ns.Api.Prot("C_GossipInfo.SelectAvailableQuest", C_GossipInfo.SelectAvailableQuest, q.questID); return
      end
    end
  elseif GetGossipActiveQuests then
    local a = { GetGossipActiveQuests() }
    for i = 1, #a / 6 do
      if a[(i - 1) * 6 + 4] and WantTurnIn(nil, a[(i - 1) * 6 + 1]) then ns.Api.Prot("SelectGossipActiveQuest", SelectGossipActiveQuest, i); return end
    end
    if LogFull() then return end
    local v = { GetGossipAvailableQuests() }
    for i = 1, #v / 7 do
      local lvl, triv, rep = v[(i - 1) * 7 + 2], v[(i - 1) * 7 + 3], v[(i - 1) * 7 + 5]
      if GoodLevel(lvl, triv) and not rep and ns.WantQuest(nil, v[(i - 1) * 7 + 1]) then ns.Api.Prot("SelectGossipAvailableQuest", SelectGossipAvailableQuest, i); return end
    end
  end
end

-- Quest Begruessung (NPCs mit Questliste ohne Gossip)
local function HandleGreeting()
  -- 1.2i (P70): angebotene Titel fuer die Pruefung oben
  if GetNumAvailableQuests and GetNumAvailableQuests() == 0 then pcall(OptOfferCheck, nil, true) end
  if not Enabled() then return end
  local now = GetTime()
  for i = 1, GetNumActiveQuests() do
    -- 1.1 (S L8.4 "probiert Quests abzugeben, die noch nicht fertig sind"): nur fertige (zweiter Wert von GetActiveTitle,
    -- sonst laut Questlog) und nur die aus dem aktuellen Buendel
    local title, isDone = GetActiveTitle(i)
    if isDone == nil and title and ns.logProgress then
      for _, lp in pairs(ns.logProgress) do if lp.title == title then isDone = lp.complete end end
    end
    if title and isDone and WantTurnIn(nil, title) and (not tried[title] or now - tried[title] > 10) then
      tried[title] = now
      ns.Api.Prot("SelectActiveQuest", SelectActiveQuest, i)
      return
    end
  end
  if LogFull() then return end
  for i = 1, GetNumAvailableQuests() do
    local triv, _, rep = false, nil, false
    if GetAvailableQuestInfo then triv, _, rep = GetAvailableQuestInfo(i) end
    local lvl = GetAvailableLevel and GetAvailableLevel(i)
    if GoodLevel(lvl, triv) and not rep and ns.WantQuest(nil, GetAvailableTitle and GetAvailableTitle(i)) then ns.Api.Prot("SelectAvailableQuest", SelectAvailableQuest, i); return end
  end
end

local f = CreateFrame("Frame")
ns.RegEv(f, "GOSSIP_SHOW")
ns.RegEv(f, "QUEST_GREETING")
ns.RegEv(f, "QUEST_DETAIL")
ns.RegEv(f, "QUEST_PROGRESS")
ns.RegEv(f, "QUEST_COMPLETE")
ns.RegEv(f, "QUEST_ACCEPTED")
ns.RegEv(f, "QUEST_TURNED_IN")
f:SetScript("OnEvent", function(_, event, ...)
  if not ns.db then return end
  if event == "GOSSIP_SHOW" then
    HandleGossip()
  elseif event == "QUEST_GREETING" then
    HandleGreeting()
  elseif event == "QUEST_DETAIL" then
    -- Gold der Quest merken
    local qid, m = GetQuestID and GetQuestID(), GetRewardMoney and GetRewardMoney()
    if qid and qid > 0 and m then ns.db.questMoney = ns.db.questMoney or {}; ns.db.questMoney[qid] = m end
    if Enabled() and not LogFull() and ns.WantQuest(qid, GetTitleText and GetTitleText()) then ns.Api.Prot("AcceptQuest", AcceptQuest) end
  elseif event == "QUEST_PROGRESS" then
    if Enabled() and IsQuestCompletable() then ns.Api.Prot("CompleteQuest", CompleteQuest) end
  elseif event == "QUEST_COMPLETE" then
    local qid, m = GetQuestID and GetQuestID(), GetRewardMoney and GetRewardMoney()
    if qid and qid > 0 and m then ns.db.questMoney = ns.db.questMoney or {}; ns.db.questMoney[qid] = m end
    if not Enabled() then return end
    local n = GetNumQuestChoices()
    if n <= 1 then
      ns.Api.Prot("GetQuestReward", GetQuestReward, n)
    else
      ns.Print(TR"Mehrere Belohnungen, bitte selber auswählen")
      if SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN then PlaySound(SOUNDKIT.IG_QUEST_LIST_OPEN) end
    end
  elseif event == "QUEST_TURNED_IN" then
    local qid, _, money = ...
    if qid and money and money > 0 then
      ns.db.questMoney = ns.db.questMoney or {}
      ns.db.questMoney[qid] = money
    end
  elseif event == "QUEST_ACCEPTED" then
    -- Classic: (Log Index, Quest ID), neuere Clients: nur (Quest ID)
    local a, b = ...
    local idx, qid
    if type(b) == "number" then idx, qid = a, b
    else
      qid = a
      idx = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(a)
    end
    -- 1.3v (P102 Punkt 3): angenommen = wird offensichtlich angeboten, Merker weg
    if qid and ns.db and ns.db.offerNo and ns.db.offerNo[qid] then
      ns.db.offerNo[qid] = nil
      if ns.TestLog then ns.TestLog("SCHRITT", ("Quest %d doch angenommen, Merker \"bietet sie nicht an\" weg"):format(qid)) end
    end
    local title = idx and LogEntry(idx)
    if not title and qid and C_QuestLog and C_QuestLog.GetTitleForQuestID then
      title = C_QuestLog.GetTitleForQuestID(qid)
    end
    if title then RememberQuest(title) end
    if qid and ns.ReserveAccepted then pcall(ns.ReserveAccepted, qid) end
    -- 1.1 (K Stufe B 11): Zeitlimit lernen (Sekunden), damit die Route die Quest nur nimmt, wenn sie in der Zeit geht
    if qid and C_Timer then
      C_Timer.After(1, function()
        local lim
        if C_QuestLog and C_QuestLog.GetTimeAllowed then
          local ok, total = pcall(C_QuestLog.GetTimeAllowed, qid)
          if ok and type(total) == "number" and total > 0 then lim = total end
        end
        if not lim and GetQuestTimers and idx then
          -- alte Schnittstelle: Restzeit je Quest mit Zeitlimit, direkt nach dem Annehmen = ganzes Limit
          local ok, t1 = pcall(GetQuestTimers)
          if ok and type(t1) == "number" and t1 > 0 and GetQuestIndexForTimer then
            local ok2, li = pcall(GetQuestIndexForTimer, 1)
            if ok2 and li == idx then lim = t1 end
          end
        end
        if lim and ns.db then
          ns.db.questTimer = ns.db.questTimer or {}
          ns.db.questTimer[qid] = math.floor(lim + 0.5)
        end
      end)
    end
  end
end)

-- Anzahl Quests im Log und wie viele fertig sind
function ns.QuestCounts()
  local total, done = 0, 0
  local n = NumEntries() or 0
  for i = 1, n do
    local title, isHeader, isComplete = LogEntry(i)
    if title and not isHeader then
      total = total + 1
      if isComplete then done = done + 1 end
    end
  end
  return total, done
end

-- XP aller fertigen Quests im Log, als waeren sie jetzt abgegeben
-- gibt: XP gesamt, Level danach, Anteil im Level danach
-- 1.3x (P108 Punkt 2, S 03:41: zweiter Teil im Balken fehlt): lief nur mit GetQuestLogTitle. Den gibt es im Forever
-- Client (1.60) nicht mehr, darum war die Summe immer 0. Jetzt auch ueber C_QuestLog.GetInfo und IsComplete
local function LogQuest(i)
  if GetQuestLogTitle then
    local _, qlevel, _, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
    return qid, qlevel, isHeader, (isComplete == 1 or isComplete == true)
  end
  if C_QuestLog and C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(i)
    if not info then return end
    local qid = info.questID
    local done = qid and C_QuestLog.IsComplete and C_QuestLog.IsComplete(qid)
    return qid, info.level, info.isHeader, done and true or false
  end
end
-- Wert aus dem Spiel, je Quest und Level einmal gemerkt (Auswahl im Questlog nur kurz und nicht im Kampf umstellen)
local rewardXP = {}
local function GameRewardXP(qid, logIndex)
  if not (qid and GetQuestLogRewardXP) then return nil end
  local L = UnitLevel and UnitLevel("player") or 0
  local c = rewardXP[qid]
  if c and c.L == L then return c.v end
  local v
  if SelectQuestLogEntry and GetQuestLogSelection and logIndex then
    if InCombatLockdown and InCombatLockdown() then return c and c.v or nil end
    local prev = GetQuestLogSelection()
    pcall(SelectQuestLogEntry, logIndex)
    local ok, r = pcall(GetQuestLogRewardXP)
    if prev and prev > 0 then pcall(SelectQuestLogEntry, prev) end
    v = ok and r or nil
  else
    local ok, r = pcall(GetQuestLogRewardXP, qid)
    v = ok and r or nil
  end
  v = v and (ns.Plain and ns.Plain(v) or v) or nil
  if type(v) ~= "number" then v = nil end
  rewardXP[qid] = { L = L, v = v }
  return v
end
ns.GameRewardXP = GameRewardXP
function ns.PendingQuestXP()
  if not ns.QuestXPAt then return 0 end
  local L = UnitLevel("player") or 1
  if L >= 60 then return 0 end
  local cur = tonumber(UnitXP("player")) or 0
  local mx = tonumber(UnitXPMax("player")) or 0
  local tot = ns.xpTotal or {}
  local function Need(lv)
    if lv == L and mx > 0 then return mx end
    if tot[lv] and tot[lv + 1] then return tot[lv + 1] - tot[lv] end
    return nil
  end
  local sum, lv, xp = 0, L, cur
  for i = 1, (NumEntries() or 0) do
    local qid, qlevel, isHeader, isComplete = LogQuest(i)
    if not isHeader and isComplete and qid then
      -- 1.3z (P110 Punkt 5, S 05:18 "2450 XP, ist aber 5800"): die Belohnung zuerst aus dem Spiel (Forever gibt mehr als
      -- die Daten), nur ohne Wert aus dem Spiel die Rechnung aus den Daten
      local g = GameRewardXP(qid, i)
      if not g or g <= 0 then g = ns.QuestXPAt(qid, qlevel, lv) or 0 end
      sum = sum + g
      xp = xp + g
      local need = Need(lv)
      while need and xp >= need and lv < 60 do
        xp = xp - need; lv = lv + 1; need = Need(lv)
      end
    end
  end
  local need = Need(lv)
  return sum, lv, (need and need > 0) and (xp / need) or 0
end

-- Text fuer den Pfeil, wenn das Ziel ein Quest Hub ist
local function NameList(quests, max)
  local names = {}
  for i, q in ipairs(quests) do
    if i > max then break end
    table.insert(names, q.level and ("[%d] %s"):format(q.level, q.name) or q.name)
  end
  local more = #quests - max
  return table.concat(names, ", ") .. (more > 0 and (TR" und " .. more .. TR" weitere") or "")
end

-- Fuer den Pfeil: bei mehreren Quests eine klare Liste, Abgeben und Annehmen getrennt
function ns.QuestHintLines(pt, max)
  max = max or 4
  if not pt or not pt.tags then return {} end
  local out = {}
  local function List(head, col, quests)
    local n = #quests
    if n == 0 then return end
    if n == 1 then
      local q = quests[1]
      local ch = q.chain and (TR" |cff7fd1b9(Kette %d/%d)|r"):format(q.chain.part, q.chain.parts) or ""
      table.insert(out, ("%s%s: %s%s|r%s"):format(col, head, q.level and ("[" .. q.level .. "] ") or "", q.name or "?", ch))
      if q.chain and q.chain.part < q.chain.parts and q.chain.lastName then
        table.insert(out, (TR"|cff9d9d9d   führt zu: %s|r"):format(q.chain.lastName))
      end
      return
    end
    table.insert(out, (TR"%s%d Quests %s|r"):format(col, n, head:lower()))
    for i, q in ipairs(quests) do
      if i > max then
        table.insert(out, (TR"|cff9d9d9d   und %d weitere|r"):format(n - max))
        break
      end
      local mark = q.class and TR" |cffff80ff(Klasse)|r" or ""
      if q.chain then mark = mark .. (TR" |cff7fd1b9(Kette %d/%d)|r"):format(q.chain.part, q.chain.parts) end
      table.insert(out, ("   |cffffffff%s%s|r%s"):format(q.level and ("[" .. q.level .. "] ") or "", q.name or "?", mark))
    end
  end
  local te = pt.tags.turnin
  if type(te) == "table" and te.quests then List(TR"Abgeben", "|cff40ff90", te.quests) end
  local h = pt.tags.quest
  if type(h) == "table" and h.quests then List(TR"Annehmen", "|cffff9030", h.quests) end
  if #out == 0 then
    local one = ns.QuestHint(pt)
    if one then table.insert(out, "|cffff9030" .. one .. "|r") end
  end
  return out
end

function ns.QuestHint(pt)
  if not pt or not pt.tags then return nil end
  local ob = pt.tags.obj
  if type(ob) == "table" then
    return ns.ProgressText and ns.ProgressText(ob.qid) or ob.quest
  end
  local te = pt.tags.turnin
  if type(te) == "table" and te.quests then
    return TR"Abgeben bei " .. (te[3] or "?") .. ": " .. NameList(te.quests, 3)
  end
  if type(pt.tags.quest) ~= "table" then return nil end
  local h = pt.tags.quest
  if h.quests then
    return TR"Annehmen bei " .. (h[3] or "?") .. ": " .. NameList(h.quests, 3)
  end
  local mapID = ns.PlayerMap()
  local known = ns.db.hubQuests and ns.db.hubQuests[(mapID or 0) .. ":" .. h[3]]
  local names = {}
  if known then
    for title in pairs(known) do
      table.insert(names, title)
      if #names >= 3 then break end
    end
  end
  local L = UnitLevel("player")
  if h[5] < L - 4 then return TR"Quests hier sind grau, auslassen" end
  if h[4] > L + 3 then return (TR"Quests hier erst ab Level %d, später wiederkommen"):format(h[4]) end
  if #names > 0 then
    return TR"Annehmen: " .. table.concat(names, ", ")
  end
  local lo, hi = math.max(h[4], L - 2), math.min(h[5], L + 3)
  if lo >= hi then return (TR"Quests Level %d annehmen"):format(lo) end
  return (TR"Alle Quests Level %d bis %d annehmen"):format(lo, hi)
end

function ns.ToggleAutoQuest()
  ns.db.autoQuest = not ns.db.autoQuest
  ns.Print(ns.db.autoQuest and TR"Auto Quest an (Shift halten = einmal aus)" or TR"Auto Quest aus")
end

function ns.InitQuest()
  if ns.db.autoQuest == nil then ns.db.autoQuest = true end
  SLASH_TAURENROUTEAQ1 = "/trquest"
  SlashCmdList.TAURENROUTEAQ = ns.ToggleAutoQuest
end

------------------------------------------------------------
-- Quest Check: passen die Quests im Log?
------------------------------------------------------------
-- alle Infos zu einem Log Eintrag
local function LogInfo(i)
  if GetQuestLogTitle then
    local title, level, group, isHeader, _, isComplete, frequency, questID = GetQuestLogTitle(i)
    return { title = title, level = level, group = group, isHeader = isHeader,
      done = (isComplete == 1 or isComplete == true), failed = (isComplete == -1),
      repeatable = frequency and frequency > 1, id = questID }
  end
  if C_QuestLog and C_QuestLog.GetInfo then
    local info = C_QuestLog.GetInfo(i)
    if not info then return end
    return { title = info.title, level = info.level, group = info.suggestedGroup, isHeader = info.isHeader,
      done = info.questID and C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID),
      id = info.questID }
  end
end

-- Namen der Zonen und Staedte auf der Route
local function RouteZoneNames()
  local set = {}
  local ids = {}
  for _, id in ipairs(ns.zoneOrder) do table.insert(ids, id) end
  for _, id in ipairs({ 1456, 1454, 1458 }) do table.insert(ids, id) end -- Donnerfels, Orgrimmar, Unterstadt
  for _, id in ipairs(ids) do
    local info = C_Map.GetMapInfo(id)
    if info and info.name then set[info.name] = true end
  end
  return set
end

function ns.QuestCheck()
  local L = UnitLevel("player")
  local onRoute = RouteZoneNames()
  local n = NumEntries() or 0
  local header
  local groups = { done = {}, gray = {}, high = {}, group = {}, away = {}, failed = {}, ok = {} }
  local total = 0
  for i = 1, n do
    local q = LogInfo(i)
    if q and q.isHeader then
      header = q.title
    elseif q and q.title then
      total = total + 1
      local lvl = q.level or L
      local label = ("[%d] %s"):format(lvl, q.title)
      if q.failed then
        table.insert(groups.failed, label)
      elseif q.done then
        table.insert(groups.done, label .. (header and (" (" .. header .. ")") or ""))
      elseif lvl <= L - 5 then
        table.insert(groups.gray, label)
      elseif lvl >= L + 4 then
        table.insert(groups.high, label)
      elseif (tonumber(q.group) or 0) > 1 then
        table.insert(groups.group, label .. (TR" (Gruppe %d)"):format(tonumber(q.group)))
      elseif header and not onRoute[header] then
        table.insert(groups.away, label .. " (" .. header .. ")")
      else
        table.insert(groups.ok, label)
      end
    end
  end

  local out = {}
  local problems = 0
  local function Section(list, title, color, isProblem)
    if #list == 0 then return end
    if isProblem then problems = problems + #list end
    table.insert(out, color .. title .. " (" .. #list .. ")|r")
    for _, l in ipairs(list) do table.insert(out, "   " .. l) end
  end
  local max = ns.LogMax()
  table.insert(out, (TR"|cffffd100Quest Check:|r %d von %d im Log"):format(total, max))
  if total >= ns.LogWarn() then
    table.insert(out, TR"|cffff5050Log fast voll, Platz machen!|r")
    problems = problems + 1
  end
  Section(groups.done, TR"Fertig, abgeben", "|cff40ff40", false)
  Section(groups.failed, TR"Fehlgeschlagen, abbrechen", "|cffff5050", true)
  Section(groups.gray, TR"Grau, kaum XP, abbrechen oder schnell abgeben", "|cff9d9d9d", true)
  Section(groups.high, TR"Zu schwer, später machen", "|cffff5050", true)
  Section(groups.group, TR"Nur mit Gruppe", "|cffff9030", true)
  Section(groups.away, TR"Nicht auf eurer Route", "|cffff9030", true)
  Section(groups.ok, TR"Passt", "|cffffffff", false)
  if problems == 0 then table.insert(out, TR"|cff40ff40Alles passt, weiter so!|r") end

  ns.questCheck = { lines = out, problems = problems, done = #groups.done }
  return out, problems
end

-- bei Aenderungen im Log neu pruefen, gebremst
local pending
local qf = CreateFrame("Frame")
ns.RegEv(qf, "QUEST_LOG_UPDATE")
ns.RegEv(qf, "PLAYER_LEVEL_UP")
qf:SetScript("OnEvent", function()
  if not ns.db or pending then return end
  pending = true
  C_Timer.After(0.7, function()
    pending = false
    ns.QuestCheck()
    if ns.RefreshUI then ns.RefreshUI() end
  end)
end)

function ns.PrintQuestCheck()
  local out = ns.QuestCheck()
  for _, l in ipairs(out) do ns.Print(l) end
end

------------------------------------------------------------
-- Quest Fortschritt aus dem Log (z.B. "Kodohorn: 1/7")
------------------------------------------------------------
ns.logProgress = {}

-- 1.1 (S Log L9.7 "Questziel nicht erkannt": Marinesoldat 8/8, Schritt blieb stehen): manche Clients melden das Ziel bei
-- voller Zahl nicht als fertig. Fertig ist es auch, wenn der Text x/y mit x >= y zeigt
local function ObjDone(text, finished)
  if finished and finished ~= 0 then return true end
  local x, y = tostring(text or ""):match("(%d+)%s*/%s*(%d+)")
  x, y = tonumber(x), tonumber(y)
  return (x and y and y > 0 and x >= y) and true or false
end
function ns.ReadLog()
  local out = {}
  local n = NumEntries() or 0
  local header
  for i = 1, n do
    if GetQuestLogTitle then
      local title, level, _, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
      if isHeader then
        header = title
      elseif title and qid then
        local objs = {}
        local nb = GetNumQuestLeaderBoards and GetNumQuestLeaderBoards(i) or 0
        for j = 1, nb do
          local text, typ, finished = GetQuestLogLeaderBoard(j, i)
          -- 1.1 (P40): Art vom Ziel (monster, item, object, event ...) fuer die Farbe im Mini Fenster
          if text then table.insert(objs, { text = text, done = ObjDone(text, finished), typ = typ }) end
        end
        local link, icon = nil, nil
        if GetQuestLogSpecialItemInfo then link, icon = GetQuestLogSpecialItemInfo(i) end
        out[qid] = { title = title, level = level, zone = header, objs = objs, complete = (isComplete == 1 or isComplete == true),
          itemLink = link, itemIcon = icon }
      end
    elseif C_QuestLog and C_QuestLog.GetInfo then
      local info = C_QuestLog.GetInfo(i)
      if info and info.isHeader then
        header = info.title
      elseif info and info.questID then
        local objs = {}
        for _, o in ipairs((C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(info.questID)) or {}) do
          table.insert(objs, { text = o.text, done = ObjDone(o.text, o.finished), typ = o.type })
        end
        local link, icon = nil, nil
        if GetQuestLogSpecialItemInfo then link, icon = GetQuestLogSpecialItemInfo(i) end
        out[info.questID] = { title = info.title, level = info.level, zone = header, objs = objs,
          complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID), itemLink = link, itemIcon = icon }
      end
    end
  end
  ns.logProgress = out
  return out
end

-- offene Aufgaben einer Quest als kurzer Text
function ns.ProgressText(qid)
  local q = ns.logProgress[qid]
  if not q then return nil end
  if q.complete then return q.title .. TR": |cff40ff40fertig, abgeben|r" end
  local open = {}
  for _, o in ipairs(q.objs) do
    if not o.done then table.insert(open, o.text) end
  end
  if #open == 0 then return q.title end
  return q.title .. ": " .. table.concat(open, ", ")
end

-- Quests der aktuellen Zone mit Fortschritt
function ns.ZoneProgressLines(max)
  local out = {}
  local mapID = ns.PlayerMap()
  local zname = mapID and ns.ZoneName(mapID)
  for qid, q in pairs(ns.logProgress) do
    if #out >= (max or 3) then break end
    if q.zone == zname and not q.complete then
      local t = ns.ProgressText(qid)
      if t then table.insert(out, t) end
    end
  end
  return out
end

local lf = CreateFrame("Frame")
ns.RegEv(lf, "QUEST_LOG_UPDATE")
ns.RegEv(lf, "PLAYER_LOGIN")
lf:SetScript("OnEvent", function()
  ns.ReadLog()
  -- Questziel fertig? Sofort weiter, nicht erst beim naechsten Takt
  if ns.TickNow then ns.TickNow() end
end)
