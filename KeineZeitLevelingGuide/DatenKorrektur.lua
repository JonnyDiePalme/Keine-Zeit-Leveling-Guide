local ADDON, ns = ...
-- 19.32 (Daten Chat, Daten 1): Korrekturen zu den Questie Daten, die die Route sonst falsch rechnet (Dropper Ausreisser,
-- Gegner die keine sind, Items nur aus Objekten). Die Daten stehen in Daten\FWW_Daten_Korrektur.lua (schreibt der Daten
-- Chat oder spaeter der Pflege Automat, kein Code). Die Datei darf fehlen, unbekannte Felder werden ignoriert.
-- Hier bleiben nur Nummern und Arten im Speicher, grund und quelle werden nicht behalten (schwacher PC).
--   ns.DK.quest[id] = { skip = true (allein nicht planen), noFoe = { [npc] = true }, noLvl = { [npc] = true },
--                       pre = { qid, ... } (19.33, vorquest_fehlt: zusaetzliche Vorquests, ODER mit denen von Questie) }
--   ns.DK.item[id]  = { objOnly = true, drop = { [npc] = true }, noFight = true }
--   ns.DK.npc[id]   = { noFoe = true } (19.33, npc[id].kein_gegner: nie ein Gegner, in keiner Quest)
local DK = { quest = {}, item = {}, npc = {}, nQ = 0, nI = 0, nN = 0 }
ns.DK = DK
-- 1.1 (K Stufe B 11): Zeitlimit einer Quest in Sekunden. Aus den Daten (quest[id].zeitlimit_s, schreibt Pr) oder vom
-- Spiel gelernt, sobald die Quest im Log ist (db.questTimer, siehe Quest.lua). nil = kein Zeitlimit bekannt
function ns.QuestTimer(qid)
  if not qid then return nil end
  local e = DK.quest[qid]
  if e and e.timer then return e.timer end
  local db = ns.db
  return db and db.questTimer and db.questTimer[qid] or nil
end

local function List(list)
  if type(list) ~= "table" then return nil end
  local l
  for _, id in ipairs(list) do
    if type(id) == "number" then l = l or {}; l[#l + 1] = id end
  end
  return l
end

local function Set(list)
  if type(list) ~= "table" then return nil end
  local s
  for _, id in ipairs(list) do
    if type(id) == "number" then s = s or {}; s[id] = true end
  end
  return s
end

-- Teil "alle", dann der Teil vom laufenden Client (era oder forever) ersetzt den Eintrag fuer dieselbe Nummer
local function Take(part)
  if type(part) ~= "table" then return end
  if type(part.quest) == "table" then
    for id, e in pairs(part.quest) do
      if type(id) == "number" and type(e) == "table" then
        local t = { skip = (e.ueberspringen == true) or nil, noFoe = Set(e.kein_gegner_npc), noLvl = Set(e.dropper_nicht_fuers_level),
          pre = List(e.vorquest_fehlt), timer = (type(e.zeitlimit_s) == "number" and e.zeitlimit_s > 0) and e.zeitlimit_s or nil }
        if t.skip or t.noFoe or t.noLvl or t.pre or t.timer then
          if not DK.quest[id] then DK.nQ = DK.nQ + 1 end
          DK.quest[id] = t
        end
      end
    end
  end
  if type(part.npc) == "table" then
    for id, e in pairs(part.npc) do
      if type(id) == "number" and type(e) == "table" and e.kein_gegner == true then
        if not DK.npc[id] then DK.nN = DK.nN + 1 end
        DK.npc[id] = { noFoe = true }
      end
    end
  end
  if type(part.item) == "table" then
    for id, e in pairs(part.item) do
      if type(id) == "number" and type(e) == "table" then
        local t = { objOnly = (e.nur_objekt == true) or nil, drop = Set(e.dropper_entfernen), noFight = (e.kein_kampf == true) or nil }
        if t.objOnly or t.drop or t.noFight then
          if not DK.item[id] then DK.nI = DK.nI + 1 end
          DK.item[id] = t
        end
      end
    end
  end
end

do
  local src = rawget(_G, "FWW_DATEN_KORREKTUR")
  -- grund und quelle (rund 100 KB Text) nicht im Speicher halten
  _G.FWW_DATEN_KORREKTUR = nil
  -- nur im Sim (SCEN gibt es im Spiel nicht): Vergleich mit und ohne Korrektur und mit und ohne neue Dropper Wahl
  -- in einer Kopie des Addons (SCEN.ohneDatenKorrektur, SCEN.ohneDropperWahl)
  local scen = rawget(_G, "SCEN")
  if type(scen) == "table" and scen.ohneDatenKorrektur then src = nil end
  if type(scen) == "table" and scen.ohneDropperWahl then ns.dbgItemLowOff = true end
  local fmt = type(src) == "table" and tonumber(src.format)
  if fmt and fmt >= 1 then
    DK.format = fmt
    DK.stand = type(src.stand) == "string" and src.stand or nil
    -- kurzer Name fuer die Anzeige, zb "Daten 1" aus "2026-10-30 00:30 Daten 1"
    DK.short = DK.stand and DK.stand:match("(Daten%s+%S+)%s*$") or (DK.stand and DK.stand:sub(1, 24)) or tostring(fmt)
    local ok = pcall(function()
      Take(src.alle)
      Take(src.forever) -- 1.2e (P47): nur Forever
    end)
    if not ok then DK.quest, DK.item, DK.npc, DK.nQ, DK.nI, DK.nN, DK.bad = {}, {}, {}, 0, 0, 0, true end
  end
  -- 19.33 (Koordination 08:02, Teil A 19.31: alle 7 Ueber Fenster Faelle): NPC 1140 ist das Objekt Ziel "Turm von
  -- Althalaxx", kein echter Gegner (Questie fuehrt es mit Level 123). Fest drin, bis die Daten Datei es als
  -- npc[1140].kein_gegner fuehrt, und auch ohne Daten Datei
  if not DK.npc[1140] then DK.npc[1140] = { noFoe = true }; DK.nN = DK.nN + 1 end
end

-- Hilfen fuer die Route und den Sim (play\pagent.lua nutzt dieselben)
function ns.DKQuest(qid) return qid and DK.quest[qid] or nil end
function ns.DKItem(id) return id and DK.item[id] or nil end
-- npc ist fuer diese Quest kein Gegner (kein_gegner_npc)
function ns.DKNoFoe(qid, npc)
  if npc and DK.npc[npc] and DK.npc[npc].noFoe then return true end
  local e = qid and DK.quest[qid]
  return (e and e.noFoe and npc and e.noFoe[npc]) and true or false
end
-- 19.33 (vorquest_fehlt): Vorquests "eine davon" (preQuestSingle) mit den zusaetzlichen aus der Daten Korrektur.
-- Ohne Eintrag kommt die Liste von Questie unveraendert zurueck. Ergebnis pro Quest gemerkt (kein neuer Speicher pro Aufruf)
local preMemo = {}
function ns.DKPreSingle(qid, single)
  local e = qid and DK.quest[qid]
  if not (e and e.pre) then return single end
  local m = preMemo[qid]
  if m and m.src == single then return m.out end
  local out, seen = {}, {}
  if type(single) == "table" then for _, id in ipairs(single) do if not seen[id] then seen[id] = true; out[#out + 1] = id end end end
  for _, id in ipairs(e.pre) do if not seen[id] then seen[id] = true; out[#out + 1] = id end end
  preMemo[qid] = { src = single, out = out }
  if ns.DKLog then ns.DKLog("Quest", qid, "vorquest_fehlt") end
  return out
end
-- 19.34 (absprache vorquest_1934): Questie schreibt in preQuestGroup bei 2 Quests (4964, 4975) eine negative Id. "-4962"
-- heisst dort "4962 muss erledigt sein, die exklusive Geschwister Quest zaehlt nicht" (QuestieDB IsPreQuestGroupFulfilled).
-- Das Addon braucht die positive Id, sonst gilt die Vorquest nie als erledigt und die Quest kommt nie in die Route.
-- Ohne negative Id kommt die Liste von Questie unveraendert zurueck
local grpMemo = {}
function ns.DKPreGroup(qid, group)
  if type(group) ~= "table" then return group end
  local neg = false
  for _, id in ipairs(group) do if type(id) == "number" and id < 0 then neg = true; break end end
  if not neg then return group end
  local m = qid and grpMemo[qid]
  if m and m.src == group then return m.out end
  local out = {}
  for i, id in ipairs(group) do out[i] = (type(id) == "number" and id < 0) and -id or id end
  if qid then grpMemo[qid] = { src = group, out = out } end
  return out
end
-- Dropper eines Items fuer diese Quest, ohne die gestrichenen (dropper_entfernen beim Item, dropper_nicht_fuers_level bei
-- der Quest), VOR der Grenze "erste 6 Dropper", damit passende Mobs nachruecken. Zweiter Wert: was angewendet wurde.
-- nur_objekt: keine Dropper. Bleibt durch dropper_nicht_fuers_level keiner uebrig, gilt die alte Liste (nie schlechter
-- als ohne Korrektur)
function ns.DKDroppers(qid, item, list)
  if type(list) ~= "table" then return list end
  local ei, eq = item and DK.item[item], qid and DK.quest[qid]
  if not (ei or (eq and eq.noLvl)) then return list end
  if ei and ei.objOnly then return {}, "nur_objekt" end
  local out, why = {}, nil
  local drop, noL = ei and ei.drop, eq and eq.noLvl
  local nDrop = 0
  for _, npc in ipairs(list) do
    if drop and drop[npc] then nDrop = nDrop + 1; why = "dropper_entfernen"
    elseif not (noL and noL[npc]) then out[#out + 1] = npc end
  end
  if #out < #list - nDrop then why = why and (why .. ", dropper_nicht_fuers_level") or "dropper_nicht_fuers_level" end
  if #out == 0 and noL then
    -- nur durch dropper_nicht_fuers_level leer: alte Liste ohne die wirklich gestrichenen
    out = {}
    for _, npc in ipairs(list) do if not (drop and drop[npc]) then out[#out + 1] = npc end end
    why = nDrop > 0 and "dropper_entfernen" or nil
  end
  return out, why
end
-- Item von freundlichem NPC (kein_kampf): kein Gegner, kein Level
function ns.DKNoFight(item) local e = item and DK.item[item]; return (e and e.noFight) and true or false end
-- Anzeige und Test Log
function ns.DKInfo()
  local nPre = 0
  for _, e in pairs(DK.quest) do if e.pre then nPre = nPre + 1 end end
  return { stand = DK.stand, short = DK.short, format = DK.format, quests = DK.nQ, items = DK.nI, npcs = DK.nN, pre = nPre, bad = DK.bad }
end
-- einmal pro Quest und Art ins Test Log (nicht bei jeder Planung)
local logged = {}
function ns.DKLog(kind, id, why)
  if not (why and ns.TestLog) then return end
  local key = kind .. id .. why
  if logged[key] then return end
  logged[key] = true
  ns.TestLog("DATEN", ("Daten Korrektur %s %d: %s"):format(kind, id, why))
end
