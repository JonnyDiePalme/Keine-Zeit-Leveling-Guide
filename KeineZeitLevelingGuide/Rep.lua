local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Ruf farmen: welche Fraktionen kann man ueber Quests hochbringen, wie viel Ruf gibt es,
-- und eine optimierte Route nur fuer eine Fraktion.

local building
local REPNAME = { [1] = TR"Hasserfüllt", [2] = TR"Feindselig", [3] = TR"Unfreundlich", [4] = TR"Neutral", [5] = TR"Freundlich",
  [6] = TR"Wohlwollend", [7] = TR"Respektvoll", [8] = TR"Ehrfürchtig" }

-- Bit pruefen ohne 32 Bit Grenze (Forever Voelker haben hohe Bits)
local function HasBit(mask, i) return math.floor(mask / 2 ^ i) % 2 == 1 end

function ns.FactionInfo(fid)
  if not GetFactionInfoByID then return end
  local ok, name, _, standing, bmin, bmax, value = pcall(GetFactionInfoByID, fid)
  if not ok or not name then return end
  return { name = name, standing = standing, standingName = REPNAME[standing] or "?", min = bmin, max = bmax, value = value }
end

-- alle Quests einmal durchgehen: welche Fraktion, wie viele Quests, wie viel Ruf
function ns.BuildFactionIndex(done)
  if ns.factions then if done then done() end return end
  if building then return end
  if not ns.QDBAccess then return end
  local QDB, _, QLib = ns.QDBAccess()
  if not (QDB and QLib) then
    building = false
    if not ns.repWarned then ns.repWarned = true; ns.Print(TR"Questie Daten sind noch nicht geladen") end
    return
  end
  building = true
  local lib = LibQuestieDB
  local ids = (lib and lib.Quest and lib.Quest.GetAllIds and lib.Quest.GetAllIds()) or {}
  if type(ids) ~= "table" or #ids == 0 then ids = {}; for id in pairs(QDB.QuestPointers or {}) do ids[#ids + 1] = id end end
  local complete = (Questie and Questie.db and Questie.db.char and Questie.db.char.complete) or {}
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local L = UnitLevel("player")
  local by = {}
  local i = 0
  local function Q(id, k) local ok, v = pcall(QDB.QueryQuestSingle, id, k); if ok then return v end end
  local SafeStep
  local function Step()
    local n = 0
    while i < #ids and n < 300 do
      i = i + 1
      n = n + 1
      local qid = ids[i]
      local rr = Q(qid, "reputationReward")
      if type(rr) == "table" and #rr > 0 then
        local rc, rra = Q(qid, "requiredClasses"), Q(qid, "requiredRaces")
        local ok = not (rc and rc > 0 and classID and not HasBit(rc, classID - 1))
          and not (rra and rra > 0 and raceID and not ns.RaceOK(rra, raceID))
        local rep = QDB.IsRepeatable and QDB.IsRepeatable(qid)
        if ok and complete[qid] and not rep then
          -- schon erledigt: nur mitzaehlen, damit fertige Fraktionen erkannt werden
          for _, pr in ipairs(rr) do
            local fid, amt = pr[1], pr[2] or 0
            if fid and amt > 0 then
              local f = by[fid] or { id = fid, quests = 0, now = 0, nowRep = 0, later = 0, rep = 0, repeatable = 0 }
              by[fid] = f
              f.qids = f.qids or {}; table.insert(f.qids, qid)
            end
          end
        elseif ok then
          local okL, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
          for _, pr in ipairs(rr) do
            local fid, amt = pr[1], pr[2] or 0
            if fid and amt > 0 then
              local f = by[fid] or { id = fid, quests = 0, now = 0, nowRep = 0, later = 0, rep = 0, repeatable = 0 }
              by[fid] = f
              f.quests = f.quests + 1
              f.rep = f.rep + amt
              if rep then f.repeatable = f.repeatable + 1 else f.qids = f.qids or {}; table.insert(f.qids, qid) end
              -- "jetzt" wie die Ruf Route rechnet: Mindestlevel erreicht und Questlevel hoechstens 2 ueber dir
              if okL and rl and rl <= L and (not ql or ql <= L + 2) then f.now = f.now + 1; f.nowRep = f.nowRep + amt else f.later = f.later + 1 end
            end
          end
        end
      end
    end
    if i < #ids then C_Timer.After(0, SafeStep); return end
    local list = {}
    for fid, f in pairs(by) do
      local info = ns.FactionInfo(fid)
      f.name = info and info.name
      f.info = info
      -- ohne Namen (kennt das Spiel nicht): weglassen
      -- die Sammel Fraktionen "Horde" und "Allianz" (67, 469) sind keine echten Ruf Ziele
      if f.name and fid ~= 67 and fid ~= 469 and #(f.qids or {}) + f.repeatable >= 2 then table.insert(list, f) end
    end
    -- Fraktionen, bei denen es Ruf fuer Mobs gibt, auch ohne Quests in die Liste
    local have = {}
    for _, f in ipairs(list) do have[f.id] = f end
    local side = UnitFactionGroup and UnitFactionGroup("player")
    for fid, k in pairs(ns.KILLREP) do
      if not k.side or k.side == side then
        local f = have[fid] or by[fid]
        if not f then
          local info = ns.FactionInfo(fid)
          f = { id = fid, quests = 0, now = 0, nowRep = 0, later = 0, rep = 0, repeatable = 0, name = info and info.name or k.name, info = info }
        end
        f.kill = k
        f.name = f.name or k.name or (TR"Fraktion " .. fid)
        if not have[fid] then table.insert(list, f); have[fid] = f end
      end
    end
    -- gelernte Ruf Mobs
    for fid in pairs(ns.db and ns.db.killRep or {}) do
      if not have[fid] then
        local info = ns.FactionInfo(fid)
        if info and info.name then
          local f = { id = fid, quests = 0, now = 0, nowRep = 0, later = 0, rep = 0, repeatable = 0, name = info.name, info = info, kill = {} }
          table.insert(list, f); have[fid] = f
        end
      elseif not have[fid].kill then have[fid].kill = {} end
    end
    table.sort(list, function(a, b) return a.nowRep > b.nowRep end)
    ns.factions = list
    building = false
    if done then done() end
  end
  -- Fehler im Aufbau: nicht fuer immer "building" lassen
  SafeStep = function()
    local ok, err = pcall(Step)
    if not ok then
      building = false
      if ns.TestLog then ns.TestLog("FEHLER", "Ruf Index: " .. tostring(err)) end
    end
  end
  SafeStep()
end

-- Stand der Fraktionen (jetzt annehmbar, erledigt) nach Level Up und Abgabe neu bauen
do
  local rf = CreateFrame("Frame")
  rf:RegisterEvent("PLAYER_LEVEL_UP")
  rf:RegisterEvent("QUEST_TURNED_IN")
  rf:SetScript("OnEvent", function() if not building then ns.factions = nil end end)
end

-- Ruf pro Stufe (Breite der Stufe) und Ziel
local SPAN = { 36000, 3000, 3000, 3000, 6000, 12000, 21000, 999 }
ns.REPNAME = REPNAME
function ns.RepGoal(fid)
  local g = ns.db and ns.db.repGoal and ns.db.repGoal[fid]
  return g or 8
end
function ns.SetRepGoal(fid, g)
  ns.db.repGoal = ns.db.repGoal or {}
  ns.db.repGoal[fid] = g
end
-- wie viel Ruf fehlt bis zum Ziel
function ns.RepToGoal(f)
  local info = ns.FactionInfo(f.id)
  if not info or not info.standing then return nil end
  local goal = ns.RepGoal(f.id)
  if info.standing >= goal then return 0 end
  local need = (info.max or 0) - (info.value or 0)
  for st = info.standing + 1, goal - 1 do need = need + (SPAN[st] or 0) end
  return need
end
-- Wege, Ruf zu holen, mit Ruf pro Stunde (geschaetzt oder gelernt)
function ns.RepWays(f)
  local out = {}
  if f.now > 0 and f.nowRep > 0 then
    local sec = f.now * 420 -- ca 7 Min pro Quest mit Laufen
    table.insert(out, { kind = TR"Quests", rate = f.nowRep / sec * 3600, total = f.nowRep, text = (TR"%d Quests jetzt, zusammen ca %d Ruf"):format(f.now, f.nowRep) })
  end
  local mobs = ns.db and ns.db.killRep and ns.db.killRep[f.id]
  if mobs then
    local best
    for _, e in pairs(mobs) do
      local per = e.n > 0 and e.sum / e.n or 0
      if per > 0 and (not best or per > best.per) then best = { per = per, name = e.name } end
    end
    if best then
      local ks = ns.KillSeconds and ns.KillSeconds(0) or 30
      table.insert(out, { kind = TR"Mobs", rate = 3600 / ks * best.per, text = (TR"%s, ca %d Ruf pro Kill"):format(best.name or TR"Mobs", math.floor(best.per)) })
    end
  elseif f.kill and f.kill.mobs then
    table.insert(out, { kind = TR"Mobs", rate = nil, text = f.kill.mobs .. TR" (Menge lernt Keine Zeit Leveling Guide beim ersten Kill)" })
  end
  if f.repeatable > 0 then
    table.insert(out, { kind = TR"Abgaben", rate = nil, text = (TR"%d wiederholbare Abgaben (zum Beispiel Stoff oder Seuchenstücke)"):format(f.repeatable) })
  end
  table.sort(out, function(a, b) return (a.rate or 0) > (b.rate or 0) end)
  return out
end
-- lohnt sich die Fraktion gerade? (sonst nur mit "Alle zeigen")
function ns.FactionRelevant(f)
  if ns.FactionDone(f) then return false end
  local info = ns.FactionInfo(f.id)
  if info and info.standing and info.standing >= ns.RepGoal(f.id) then return false end
  return f.now > 0 or f.kill ~= nil or f.repeatable > 0 or (info and info.standing and info.standing <= 3)
end

-- Fraktion fertig: Ehrfuerchtig, oder alle Quests erledigt und nichts Wiederholbares
function ns.FactionDone(f)
  local info = ns.FactionInfo(f.id)
  if info and info.standing and info.standing >= 8 then return true, TR"Ehrfürchtig" end
  if f.repeatable > 0 or f.kill then return false end
  local complete = (Questie and Questie.db and Questie.db.char and Questie.db.char.complete) or {}
  for _, q in ipairs(f.qids or {}) do if not complete[q] then return false end end
  return true, TR"alle Quests erledigt"
end

function ns.FactionLines(f)
  local out = {}
  if not f then return { TR"Links eine Fraktion anklicken." } end
  local info = ns.FactionInfo(f.id) or f.info
  table.insert(out, ("|cffffd100%s|r"):format(f.name))
  if info then
    local cur = (info.value or 0) - (info.min or 0)
    local span = (info.max or 0) - (info.min or 0)
    table.insert(out, (TR"Dein Stand: |cffffffff%s|r  %d / %d"):format(info.standingName, cur, span))
  else
    table.insert(out, TR"|cff9d9d9dDiese Fraktion kennst du noch nicht.|r")
  end
  local fin, why = ns.FactionDone(f)
  if fin then table.insert(out, TR"|cff40ff40Fertig: " .. why .. ".|r") end
  -- Ziel und Zeit bis dahin
  local need = ns.RepToGoal(f)
  local ways = ns.RepWays(f)
  if need and need > 0 then
    local best = ways[1] and ways[1].rate
    table.insert(out, (TR"Ziel: |cffffd100%s|r, noch %d Ruf%s"):format(REPNAME[ns.RepGoal(f.id)] or "?", need,
      best and best > 0 and (TR", ca " .. ns.Clock(need / best * 3600) .. TR" über " .. ways[1].kind) or ""))
  elseif need == 0 then
    table.insert(out, (TR"|cff40ff40Ziel %s erreicht.|r"):format(REPNAME[ns.RepGoal(f.id)] or "?"))
  end
  if #ways > 0 then
    table.insert(out, "")
    table.insert(out, TR"|cffffd100So geht es am schnellsten|r")
    for i, w in ipairs(ways) do
      table.insert(out, ("%d. %s%s: %s"):format(i, w.kind, w.rate and (TR" (ca %d Ruf pro Std)"):format(math.floor(w.rate)) or "", w.text))
    end
  end
  -- Ruf reparieren bei feindlichen Fraktionen
  if info and info.standing and info.standing <= 3 then
    table.insert(out, "")
    local k = ns.KILLREP[f.id]
    table.insert(out, TR"|cffff9030Ruf reparieren:|r " .. (k and k.mobs or TR"Quests der Fraktion machen, sobald sie dich wieder ansprechen. Gegner der Fraktion nicht töten."))
  end
  table.insert(out, "")
  table.insert(out, (TR"Quests mit Ruf: %d, davon jetzt annehmbar: |cff40ff40%d|r, später: %d"):format(f.quests, f.now, f.later))
  table.insert(out, (TR"Ruf aus den Quests, die du jetzt machen kannst: |cff40ff40ca %d|r"):format(f.nowRep))
  if f.repeatable > 0 then table.insert(out, (TR"Wiederholbare Quests (z.B. Abgaben): %d"):format(f.repeatable)) end
  table.insert(out, "")
  for _, l in ipairs(ns.KillRepLines(f, info)) do table.insert(out, l) end
  table.insert(out, "")
  table.insert(out, TR"|cff9d9d9dQuests farmen plant die schnellste Reihenfolge für diese Quests (bis 2 Stunden), mit Reisen und Ketten.|r")
  if f.kill then table.insert(out, TR"|cff9d9d9dMobs farmen schickt dich zu den Mobs, die dir schon Ruf gegeben haben (am Ort mit den meisten).|r") end
  return out
end

function ns.RepFarm(f)
  if not f then return end
  local L = UnitLevel("player")
  ns.Optimize(L + 3, function(opt)
    if opt and ns.db then ns.db.optMode = true end
    if ns.RefreshBig then ns.RefreshBig() end
  end, { rep = f.id, repName = f.name, maxTime = 7200 })
end


------------------------------------------------------------
-- Ruf durch Mobs
-- Bekannte Fraktionen mit Ruf fuer Kills (Beschreibung), dazu wird gelernt:
-- toetest du einen Mob und bekommst gleich danach Ruf, merkt sich das Addon Mob, Fraktion und Menge.
------------------------------------------------------------
ns.KILLREP = {
  [576] = { name = TR"Holzschlundfeste", mobs = TR"Furbolgs der Totholz (Teufelswald) und der Winterfell (Winterquell)" },
  [529] = { name = TR"Argentumdämmerung", mobs = TR"Untote der Geissel in den Westlichen und Östlichen Pestländern, Stratholme, Scholomance" },
  [609] = { name = TR"Zirkel des Cenarius", mobs = TR"Kultisten des Schattenhammers in Silithus, Ruinen von Ahn'Qiraj" },
  [749] = { name = TR"Hydraxianer", mobs = TR"Feuerelementare und Bosse im Geschmolzenen Kern" },
  [270] = { name = TR"Stamm der Zandalar", mobs = TR"Mobs und Bosse in Zul'Gurub" },
  [910] = { name = TR"Brut Nozdormus", mobs = TR"Mobs und Bosse im Tempel von Ahn'Qiraj" },
  [349] = { name = TR"Rabenholdt", mobs = TR"Mitglieder des Syndikats im Alteracgebirge und im Arathihochland" },
  [92]  = { name = TR"Gelkisklan", mobs = TR"Zentauren der Magram in Desolace (senkt Magram)" },
  [93]  = { name = TR"Magramklan", mobs = TR"Zentauren der Gelkis in Desolace (senkt Gelkis)" },
  [87]  = { name = TR"Blutsegelbukaniere", mobs = TR"Goblins der Dampfdruckkartelle, z.B. in Beutebucht (senkt deren Ruf)" },
  [729] = { name = TR"Frostwolfklan", mobs = TR"Gegner im Alteractal", side = "Horde" },
  [730] = { name = TR"Sturmlanzengarde", mobs = TR"Gegner im Alteractal", side = "Alliance" },
}

local lastKill, pendingRep = nil, {}
local function FactionIdByName(name)
  if not (GetNumFactions and GetFactionInfo) then return end
  for i = 1, GetNumFactions() do
    local n, _, _, _, _, _, _, _, isHeader, _, _, _, _, fid = GetFactionInfo(i)
    if n == name and not isHeader then return fid end
  end
end

local function Learn(npc, mobName, fid, amt)
  local db = ns.db
  if not (db and npc and fid and amt) then return end
  db.killRep = db.killRep or {}
  db.killRep[fid] = db.killRep[fid] or {}
  local e = db.killRep[fid][npc] or { n = 0, sum = 0, name = mobName }
  e.n = e.n + 1
  e.sum = e.sum + amt
  e.last = amt
  e.name = e.name or mobName
  db.killRep[fid][npc] = e
end

function ns.OnKill(npc, name)
  local kill = { npc = npc, name = name, t = GetTime() }
  lastKill = kill
  -- Ruf kam schon vor der Kill Erkennung?
  for i = #pendingRep, 1, -1 do
    local p = pendingRep[i]
    if GetTime() - p.t < 3 then Learn(npc, name, p.fid, p.amt); kill.got = true end
    table.remove(pendingRep, i)
  end
  -- bekannter Ruf Mob ohne Ruf danach: Grenze fuer Kills erreicht (zb ab Wohlwollend)
  local kr = ns.db and ns.db.killRep
  if kr and npc then
    C_Timer.After(3, function()
      if kill.got then return end
      for _, mobs in pairs(kr) do
        local e = mobs[npc]
        if e and (e.n or 0) >= 2 then e.last = 0 end
      end
    end)
  end
end

local repPat
local function RepPattern()
  if repPat ~= nil then return repPat end
  local s = FACTION_STANDING_INCREASED
  if type(s) ~= "string" then repPat = false; return false end
  local order = {}
  local p = s:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
  p = p:gsub("%%(%d?)%%?%$?([sd])", function(n, t)
    table.insert(order, t)
    return t == "s" and "(.-)" or "(%d+)"
  end)
  repPat = { "^" .. p .. "$", order }
  return repPat
end

local rf = CreateFrame("Frame")
rf:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
rf:SetScript("OnEvent", function(_, _, msg)
  msg = ns.Plain and ns.Plain(msg) or msg
  if type(msg) ~= "string" then return end
  local pat = RepPattern()
  local name, amt
  if pat then
    local caps = { msg:match(pat[1]) }
    for i, t in ipairs(pat[2]) do
      if t == "s" then name = caps[i] else amt = tonumber(caps[i]) end
    end
  end
  if not (name and amt) then return end
  local fid = FactionIdByName(name)
  if not fid then return end
  if lastKill and GetTime() - lastKill.t < 3 then
    Learn(lastKill.npc, lastKill.name, fid, amt)
    lastKill.got = true
  else
    table.insert(pendingRep, { fid = fid, amt = amt, t = GetTime() })
  end
end)

-- bester Ort fuer einen Mob: die Stelle mit den meisten Spawns
local function BestSpot(npc)
  if not ns.QDBAccess then return end
  local QDB, ZDB = ns.QDBAccess()
  if not (QDB and ZDB) then return end
  local ok, sp = pcall(QDB.QueryNPCSingle, npc, "spawns")
  if not ok or type(sp) ~= "table" then return end
  local best, bn
  for area, coords in pairs(sp) do
    local okU, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
    if okU and ui and type(coords) == "table" then
      for _, c in ipairs(coords) do
        if type(c) == "table" and c[1] and c[1] > 0 then
          local n = 0
          for _, d in ipairs(coords) do
            if type(d) == "table" and d[1] and math.abs(d[1] - c[1]) < 6 and math.abs(d[2] - c[2]) < 6 then n = n + 1 end
          end
          if not bn or n > bn then best, bn = { map = ui, x = c[1] / 100, y = c[2] / 100, n = n }, n end
        end
      end
    end
  end
  return best
end

-- gelernte Mobs einer Fraktion, beste zuerst (meiste Kills)
function ns.KillRepMobs(fid)
  local out = {}
  for npc, e in pairs(ns.db and ns.db.killRep and ns.db.killRep[fid] or {}) do
    table.insert(out, { npc = npc, name = e.name or (TR"Mob " .. npc), n = e.n, per = e.sum / math.max(1, e.n), last = e.last })
  end
  table.sort(out, function(a, b) return a.n > b.n end)
  return out
end

function ns.KillRepLines(f, info)
  local out = {}
  if not f.kill then return out end
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Ruf durch Mobs|r")
  if f.kill.mobs then table.insert(out, "   " .. f.kill.mobs) end
  local mobs = ns.KillRepMobs(f.id)
  if #mobs == 0 then
    table.insert(out, TR"   |cff9d9d9dNoch nichts gelernt. Töte einen dieser Mobs, dann weiss Keine Zeit Leveling Guide Ruf pro Kill und wo es die meisten gibt.|r")
    return out
  end
  local left = info and info.max and info.value and (info.max - info.value) or nil
  for i, m in ipairs(mobs) do
    if i > 5 then break end
    local need = (left and m.per > 0) and math.ceil(left / m.per) or nil
    local spot = BestSpot(m.npc)
    table.insert(out, (TR"   %s: ca %d Ruf pro Kill (%d gelernt)%s%s"):format(m.name, math.floor(m.per + 0.5), m.n,
      need and (TR", noch ca " .. need .. TR" Kills bis zur nächsten Stufe") or "",
      spot and (" |cff9d9d9d" .. (ns.ZoneName and ns.ZoneName(spot.map) or "?") .. (" %.0f, %.0f"):format(spot.x * 100, spot.y * 100) .. "|r") or ""))
    if m.last == 0 then table.insert(out, TR"   |cffff5050Letzter Kill gab keinen Ruf mehr, die Grenze für Kills ist wohl erreicht.|r") end
  end
  return out
end

-- zu den Mobs mit dem besten Ruf pro Zeit (gelernter Mob mit den meisten Spawns)
function ns.RepMobFarm(f)
  local mobs = ns.KillRepMobs(f.id)
  local best, bs
  for _, m in ipairs(mobs) do
    local s = BestSpot(m.npc)
    if s and (not bs or s.n * m.per > bs.n * bs.per) then best, bs = m, { map = s.map, x = s.x, y = s.y, n = s.n, per = m.per } end
  end
  if not best then
    ns.Print(TR"Noch keine Ruf Mobs gelernt. Töte einen Mob, der dieser Fraktion Ruf gibt (" .. ((f.kill and f.kill.mobs) or TR"siehe Liste") .. ").")
    return
  end
  -- eine andere Farm Route lief noch (Gold Mobs, Berufe): die ist damit beendet
  ns.farmSess = nil
  if ns.db then ns.db.profSess = nil end
  ns.repFarm = { fid = f.id, name = f.name }
  local steps = { { map = bs.map, x = bs.x, y = bs.y, t = 0, lvl = UnitLevel("player"),
    acts = { { k = "G", repFarm = true, obj = best.name, lo = 0, hi = 0, rep = f.name } } } }
  if ns.OptLoad then ns.OptLoad(steps, { title = TR"Ruf farmen: " .. f.name, target = UnitLevel("player"), repFarm = true }); ns.db.opt.repFarm = true end
  ns.Print((TR"Ruf farmen bei %s: %s, ca %d Ruf pro Kill. Beenden mit Stop auf der Seite Ruf."):format(f.name, best.name, math.floor(best.per + 0.5)))
end
function ns.RepMobStop()
  if not ns.repFarm then return end
  ns.repFarm = nil
  ns.Print(TR"Ruf farmen beendet.")
  -- Ruf Route als fertig markieren: zurueck zum Fahrplan
  local o = ns.db and ns.db.opt
  if o and o.repFarm then o.idx = #(o.steps or {}) + 1 end
  if ns.ProfileBackToLevel then ns.ProfileBackToLevel() elseif ns.AutoOpt then ns.AutoOpt(true) end
end
