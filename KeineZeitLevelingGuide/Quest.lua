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
function ns.WantQuest(qid, title)
  if not ns.db then return true end
  if ns.db.autoQuestAll then return OkForAll(qid) end
  if IsClassQuest(qid) then return true end
  -- noch keine Route (Questie laedt noch): nicht blockieren
  local opt = ns.db.opt
  if not (opt and opt.steps and #opt.steps > 0) and not (ns.db.plan60 and ns.db.plan60.secs) then return true end
  local r = RouteQuests()
  if qid and r.ids[qid] then return true end
  if title and r.names[title] then return true end
  return false
end

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

-- Gossip Fenster (normale NPCs mit Text)
local function HandleGossip()
  if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
    local offered = {}
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do if q.questID then offered[q.questID] = true end end
    for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do if q.questID then offered[q.questID] = true end end
    CheckOffered(offered)
  end
  if not Enabled() then return end
  if C_GossipInfo and C_GossipInfo.GetActiveQuests then
    for _, q in ipairs(C_GossipInfo.GetActiveQuests() or {}) do
      if q.isComplete then C_GossipInfo.SelectActiveQuest(q.questID); return end
    end
    if LogFull() then return end
    for _, q in ipairs(C_GossipInfo.GetAvailableQuests() or {}) do
      if GoodLevel(q.questLevel, q.isTrivial) and not q.repeatable and ns.WantQuest(q.questID, q.title) then
        C_GossipInfo.SelectAvailableQuest(q.questID); return
      end
    end
  elseif GetGossipActiveQuests then
    local a = { GetGossipActiveQuests() }
    for i = 1, #a / 6 do
      if a[(i - 1) * 6 + 4] then SelectGossipActiveQuest(i); return end
    end
    if LogFull() then return end
    local v = { GetGossipAvailableQuests() }
    for i = 1, #v / 7 do
      local lvl, triv, rep = v[(i - 1) * 7 + 2], v[(i - 1) * 7 + 3], v[(i - 1) * 7 + 5]
      if GoodLevel(lvl, triv) and not rep and ns.WantQuest(nil, v[(i - 1) * 7 + 1]) then SelectGossipAvailableQuest(i); return end
    end
  end
end

-- Quest Begruessung (NPCs mit Questliste ohne Gossip)
local function HandleGreeting()
  if not Enabled() then return end
  local now = GetTime()
  for i = 1, GetNumActiveQuests() do
    local title = GetActiveTitle(i)
    if title and (not tried[title] or now - tried[title] > 10) then
      tried[title] = now
      SelectActiveQuest(i)
      return
    end
  end
  if LogFull() then return end
  for i = 1, GetNumAvailableQuests() do
    local triv, _, rep = false, nil, false
    if GetAvailableQuestInfo then triv, _, rep = GetAvailableQuestInfo(i) end
    local lvl = GetAvailableLevel and GetAvailableLevel(i)
    if GoodLevel(lvl, triv) and not rep and ns.WantQuest(nil, GetAvailableTitle and GetAvailableTitle(i)) then SelectAvailableQuest(i); return end
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("GOSSIP_SHOW")
f:RegisterEvent("QUEST_GREETING")
f:RegisterEvent("QUEST_DETAIL")
f:RegisterEvent("QUEST_PROGRESS")
f:RegisterEvent("QUEST_COMPLETE")
f:RegisterEvent("QUEST_ACCEPTED")
f:RegisterEvent("QUEST_TURNED_IN")
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
    if Enabled() and not LogFull() and ns.WantQuest(qid, GetTitleText and GetTitleText()) then AcceptQuest() end
  elseif event == "QUEST_PROGRESS" then
    if Enabled() and IsQuestCompletable() then CompleteQuest() end
  elseif event == "QUEST_COMPLETE" then
    local qid, m = GetQuestID and GetQuestID(), GetRewardMoney and GetRewardMoney()
    if qid and qid > 0 and m then ns.db.questMoney = ns.db.questMoney or {}; ns.db.questMoney[qid] = m end
    if not Enabled() then return end
    local n = GetNumQuestChoices()
    if n <= 1 then
      GetQuestReward(n)
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
    local title = idx and LogEntry(idx)
    if not title and qid and C_QuestLog and C_QuestLog.GetTitleForQuestID then
      title = C_QuestLog.GetTitleForQuestID(qid)
    end
    if title then RememberQuest(title) end
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
function ns.PendingQuestXP()
  if not GetQuestLogTitle or not ns.QuestXPAt then return 0 end
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
    local _, qlevel, _, isHeader, _, isComplete, _, qid = GetQuestLogTitle(i)
    if not isHeader and (isComplete == 1 or isComplete == true) and qid then
      local g = ns.QuestXPAt(qid, qlevel, lv) or 0
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
qf:RegisterEvent("QUEST_LOG_UPDATE")
qf:RegisterEvent("PLAYER_LEVEL_UP")
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
          local text, _, finished = GetQuestLogLeaderBoard(j, i)
          if text then table.insert(objs, { text = text, done = finished and true or false }) end
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
          table.insert(objs, { text = o.text, done = o.finished and true or false })
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
lf:RegisterEvent("QUEST_LOG_UPDATE")
lf:RegisterEvent("PLAYER_LOGIN")
lf:SetScript("OnEvent", function()
  ns.ReadLog()
  -- Questziel fertig? Sofort weiter, nicht erst beim naechsten Takt
  if ns.TickNow then ns.TickNow() end
end)
