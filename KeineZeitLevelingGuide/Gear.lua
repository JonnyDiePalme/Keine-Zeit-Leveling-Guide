local ADDON, ns = ...
local TR = ns.TR

-- Ausruestung Quests: Quests suchen, deren Belohnung fuer dich eine Verbesserung ist.
-- Questie weiss pro Item, welche Quests es als Belohnung geben (questRewards).
-- Ob es besser ist, rechnet die gleiche Wertung wie der Belohnungs Vorschlag (Werte fuer deine Klasse,
-- Ruestungstyp, Waffen die du tragen kannst) gegen das, was du gerade anhast.

local AHEAD = 3   -- auch Quests, die du in ein paar Levels annehmen kannst

local busy = false
function ns.GearBusy() return busy end

local function Complete(qid)
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  return c and c[qid] and true or false
end

-- Bit pruefen ohne 32 Bit Grenze (Forever Voelker haben hohe Bits)
local function HasBit(mask, i) return math.floor(mask / 2 ^ i) % 2 == 1 end

local function RequestItem(id)
  if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  return ns.Api.GetItemInfo(id)
end

function ns.GearScan(done)
  if busy then return end
  if not ns.QDBAccess then return end
  local QDB, ZDB, QLib, QPlayer = ns.QDBAccess()
  if not (QDB and QLib) then ns.Print(TR"Ausrüstung Quests brauchen Questie, die Daten sind noch nicht geladen."); return end
  local lib = LibQuestieDB
  local IF = lib and lib.Item
  local ids = IF and IF.GetAllIds and IF.GetAllIds()
  if type(ids) ~= "table" or #ids == 0 then
    ns.Print(TR"Questie liefert keine Item Liste, Ausrüstung Quests gehen damit nicht.")
    ns.gearQuests, ns.gearLvl = {}, UnitLevel("player")
    return
  end
  busy = true
  local L = UnitLevel("player")
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local inLog = (QPlayer and QPlayer.currentQuestlog) or {}
  local function I(id, k)
    if IF.Get then local ok, v = pcall(IF.Get, id, k); if ok and v ~= nil then return v end end
    if QDB.QueryItemSingle then local ok, v = pcall(QDB.QueryItemSingle, id, k); if ok then return v end end
  end
  local function Q(id, k) local ok, v = pcall(QDB.QueryQuestSingle, id, k); if ok then return v end end
  -- 19.34 (Pruefer 09:42 LEICHT 4): Vorquest Kette mit der Daten Korrektur (vorquest_fehlt), wie die Route
  local function QP(id) local v = Q(id, "preQuestSingle"); if ns.DKPreSingle then return ns.DKPreSingle(id, v) end return v end
  local function N(id, k) if not QDB.QueryNPCSingle then return end local ok, v = pcall(QDB.QueryNPCSingle, id, k); if ok then return v end end
  local function O(id, k) if not QDB.QueryObjectSingle then return end local ok, v = pcall(QDB.QueryObjectSingle, id, k); if ok then return v end end
  local function Ui(area) local ok, u = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area); return ok and u or nil end

  local byQuest = {}   -- [qid] = { items = { id, ... } }
  local i = 0
  local qOk = {}
  local function QuestOk(qid)
    if qOk[qid] ~= nil then return qOk[qid] end
    local r = false
    if not Complete(qid) then
      local ok, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
      local rc, rr = Q(qid, "requiredClasses"), ns.DKRaces(qid, Q(qid, "requiredRaces"))
      local fine = ok and rl and rl <= L + AHEAD and ql and ql >= L - 12
      if fine and rc and rc > 0 and classID and not HasBit(rc, classID - 1) then fine = false end
      if fine and rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then fine = false end
      if fine and QDB.IsRepeatable and QDB.IsRepeatable(qid) then fine = false end
      if fine and ((QDB.IsRaidQuest and QDB.IsRaidQuest(qid)) or (QDB.IsPvPQuest and QDB.IsPvPQuest(qid))) then fine = false end
      if fine and QDB.IsDoable and not inLog[qid] and not ns.questieEarly then
        local okD, doable = pcall(QDB.IsDoable, qid)
        if okD and doable == false and not (Q(qid, "preQuestSingle") or Q(qid, "preQuestGroup")) then fine = false end
      end
      if fine and ns.RepCheck and not inLog[qid] and not ns.RepCheck(qid) then fine = false end
      r = fine and { ql = ql, rl = rl } or false
    end
    qOk[qid] = r
    return r
  end

  local Evaluate
  local SafeStep
  local function Step()
    local n = 0
    while i < #ids and n < 400 do
      i = i + 1
      n = n + 1
      local id = ids[i]
      local qr = I(id, "questRewards")
      if type(qr) == "table" and #qr > 0 then
        local cls = I(id, "class")
        local req = I(id, "requiredLevel") or 0
        if (cls == 2 or cls == 4) and req <= L + AHEAD then
          for _, qid in ipairs(qr) do
            if QuestOk(qid) then
              byQuest[qid] = byQuest[qid] or { items = {} }
              table.insert(byQuest[qid].items, id)
              RequestItem(id)
            end
          end
        end
      end
    end
    if i < #ids then C_Timer.After(0, SafeStep); return end
    C_Timer.After(1, function() Evaluate(1) end)
  end

  Evaluate = function(round)
    local missing = 0
    local out = {}
    for qid, e in pairs(byQuest) do
      local items, best, bestPct = {}, nil, nil
      for _, id in ipairs(e.items) do
        local name, link = ns.Api.GetItemInfo(id)
        if not link then
          missing = missing + 1
        else
          local gain, loc, slot, empty
          if ns.UpgradeGain then gain, loc, slot, empty = ns.UpgradeGain(link) end
          if gain and gain > 0.5 then
            -- ungefaehre Verbesserung in Prozent gegenueber dem jetzigen Teil
            local sc = ns.ItemScore and ns.ItemScore(link)
            local base = sc and (sc - gain) or 0
            local pct = (base and base > 1) and (gain / base * 100) or nil
            table.insert(items, { id = id, link = link, gain = gain, loc = loc, slot = slot, pct = pct, empty = empty })
            if not best or gain > best then best = gain; bestPct = pct end
          end
        end
      end
      if best then
        table.sort(items, function(a, b) return a.gain > b.gain end)
        local q = QuestOk(qid)
        local by = Q(qid, "startedBy")
        local npc = by and by[1] and by[1][1]
        local obj = by and by[2] and by[2][1]
        local giver, sp
        if npc then giver, sp = N(npc, "name"), N(npc, "spawns") elseif obj then giver, sp = O(obj, "name"), O(obj, "spawns") end
        local zone
        for area, coords in pairs(type(sp) == "table" and sp or {}) do
          local u = Ui(area)
          if u and type(coords) == "table" and coords[1] then zone = u; break end
        end
        local dungeon = QDB.IsDungeonQuest and QDB.IsDungeonQuest(qid) or false
        local elite = ns.IsEliteQuest and ns.IsEliteQuest(qid) or false
        -- offene Vorquests
        -- alle offenen Vorquests, auch mehrere Stufen tief:
        -- Gruppe (preQuestGroup) = alle noetig, Einzeln (preQuestSingle) = eine davon reicht
        local pre, seen = {}, { [qid] = true }
        local function Need(id, depth)
          if depth > 10 then return end
          local pg = Q(id, "preQuestGroup")
          if ns.DKPreGroup then pg = ns.DKPreGroup(id, pg) end -- 19.34 (vorquest_1934): negative Id
          for _, p in ipairs(type(pg) == "table" and pg or {}) do
            if not seen[p] and not Complete(p) and not inLog[p] then
              seen[p] = true; Need(p, depth + 1); table.insert(pre, p)
            end
          end
          local ps = QP(id)
          if type(ps) == "table" and #ps > 0 then
            local done = false
            for _, p in ipairs(ps) do if Complete(p) or inLog[p] then done = true end end
            if not done then
              -- die erste, die fuer dich machbar ist
              local pick
              for _, p in ipairs(ps) do
                local rc, rr = Q(p, "requiredClasses"), ns.DKRaces(p, Q(p, "requiredRaces"))
                local okC = not (rc and rc > 0 and classID and not HasBit(rc, classID - 1))
                local okR = not (rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID))
                if okC and okR then pick = p; break end
              end
              if pick and not seen[pick] then seen[pick] = true; Need(pick, depth + 1); table.insert(pre, pick) end
            end
          end
        end
        Need(qid, 0)
        table.insert(out, { id = qid, name = Q(qid, "name") or (TR"Quest " .. qid), ql = q.ql, rl = q.rl, items = items, gain = best, pct = bestPct,
          giver = giver, zone = zone, dungeon = dungeon, elite = elite, pre = pre, inLog = inLog[qid] and true or false })
      end
    end
    if missing > 0 and round < 4 then
      C_Timer.After(1.5, function() Evaluate(round + 1) end)
      return
    end
    table.sort(out, function(a, b)
      local na, nb = a.rl <= L, b.rl <= L
      if na ~= nb then return na end
      return a.gain > b.gain
    end)
    ns.gearQuests = out
    ns.gearLvl = L
    ns.gearScanAt = GetTime()
    busy = false
    if done then done(out) end
  end
  -- Fehler im Aufbau: nicht fuer immer "busy" lassen
  SafeStep = function()
    local ok, err = pcall(Step)
    if not ok then
      busy = false
      if ns.TestLog then ns.TestLog("FEHLER", "Ausruestung Scan: " .. tostring(err)) end
    end
  end
  SafeStep()
end

-- ausgewaehlte Quests (ohne die rausgenommenen) als Route, mit Vorquests
-- 17.3: nichts ist vorausgewaehlt, du waehlst gezielt (db.gearPick). Nicht gewaehlt heisst: kommt nicht in die Route.
function ns.GearPicked(qid) return ns.db and ns.db.gearPick and ns.db.gearPick[qid] and true or false end
function ns.GearSkipped(qid) return not ns.GearPicked(qid) end
function ns.GearToggle(qid)
  local db = ns.db
  db.gearPick = db.gearPick or {}
  db.gearPick[qid] = not db.gearPick[qid] or nil
end
function ns.GearPickAll(on)
  local db = ns.db
  if not db then return end
  db.gearPick = {}
  if on then for _, q in ipairs(ns.gearQuests or {}) do db.gearPick[q.id] = true end end
end

function ns.GearRoute()
  local list = ns.gearQuests
  if not list or #list == 0 then ns.Print(TR"Keine Ausrüstung Quests gefunden. Erst suchen."); return end
  local L = UnitLevel("player")
  -- 20.3j (S Test 20.3g Punkt 7): nichts angehakt heisst jetzt alle (vorher kam nur "Keine Quest ausgewaehlt")
  if not next(ns.db.gearPick or {}) then
    ns.GearPickAll(true)
    ns.Print(TR"Nichts angehakt: alle Ausrüstung Quests sind jetzt gewählt. Links kannst du einzelne wieder abwählen.")
  end
  local set, n = {}, 0
  for _, q in ipairs(list) do
    if not ns.GearSkipped(q.id) and not q.dungeon then
      -- Vorquests immer mit, auch wenn die Belohnungs Quest selbst erst in ein paar Levels geht
      for _, p in ipairs(q.pre or {}) do set[p] = true end
      if q.rl <= L then set[q.id] = true; n = n + 1 elseif #(q.pre or {}) > 0 then n = n + 1 end
    end
  end
  if n == 0 then ns.Print(TR"Keine Quest ausgewählt. Links die Haken bei den Quests setzen, die du willst (Dungeon Quests laufen über die Dungeon Seite)."); return end
  -- 20.3j (S Test 20.3g Punkt 7, Na Befund A): eigene Zusatz Route wie Ruf und Dungeon, die Leveling Route bleibt und geht
  -- danach an der gleichen Stelle weiter (vorher kamen die Quests in die Leveling Route und haben sie neu gerechnet)
  ns.Print((TR"Ausrüstung Route: %d Quests mit Vorquests, wird berechnet. Danach geht die Leveling Route weiter, wo du warst."):format(n))
  ns.Optimize(math.min(60, L + 3), function(opt)
    if opt and ns.db then ns.db.optMode = true end
    if ns.RefreshBig then ns.RefreshBig() end
  end, { gearQ = set, maxTime = 7200 })
  if ns.RefreshBig then ns.RefreshBig() end
end

local SLOTNAME = { INVTYPE_HEAD = TR"Kopf", INVTYPE_NECK = TR"Hals", INVTYPE_SHOULDER = TR"Schulter", INVTYPE_CHEST = TR"Brust", INVTYPE_ROBE = TR"Brust",
  INVTYPE_WAIST = TR"Taille", INVTYPE_LEGS = TR"Beine", INVTYPE_FEET = TR"Füsse", INVTYPE_WRIST = TR"Handgelenke", INVTYPE_HAND = TR"Hände",
  INVTYPE_FINGER = TR"Finger", INVTYPE_TRINKET = TR"Schmuck", INVTYPE_CLOAK = TR"Rücken", INVTYPE_WEAPON = TR"Einhand", INVTYPE_2HWEAPON = TR"Zweihand",
  INVTYPE_WEAPONMAINHAND = TR"Waffenhand", INVTYPE_WEAPONOFFHAND = TR"Schildhand", INVTYPE_SHIELD = TR"Schild", INVTYPE_HOLDABLE = TR"Schildhand",
  INVTYPE_RANGED = TR"Distanz", INVTYPE_RANGEDRIGHT = TR"Distanz", INVTYPE_THROWN = TR"Wurfwaffe" }
function ns.SlotName(loc) return SLOTNAME[loc] or "?" end

function ns.GearLines(q)
  local out = {}
  if not q then return { TR"Links eine Quest anklicken." } end
  local L = UnitLevel("player")
  table.insert(out, (TR"|cffffd100%s|r  Level %d"):format(q.name, q.ql or 0))
  if q.rl > L then
    table.insert(out, (TR"|cffff9030Annehmbar ab Level %d|r"):format(q.rl))
  elseif q.inLog then
    table.insert(out, TR"|cff4dccffSchon im Questlog|r")
  else
    table.insert(out, TR"|cff40ff40Jetzt annehmbar|r")
  end
  table.insert(out, (TR"Questgeber: %s%s"):format(q.giver or "?", q.zone and (TR" in " .. (ns.ZoneName and ns.ZoneName(q.zone) or "?")) or ""))
  if q.dungeon then table.insert(out, TR"|cffff5050Dungeon Quest: läuft über die Seite Dungeons, nicht in dieser Route.|r") end
  if q.elite then table.insert(out, TR"|cffff5050Elite oder Gruppenquest|r") end
  if #q.pre > 0 then
    local names = {}
    for _, p in ipairs(q.pre) do
      local QDB = ns.QDBAccess and ns.QDBAccess()
      local ok, nm = pcall(QDB.QueryQuestSingle, p, "name")
      table.insert(names, ok and nm or (TR"Quest " .. p))
    end
    table.insert(out, (TR"|cffff9030Vorquests: %s (kommen mit in die Route)|r"):format(table.concat(names, ", ")))
  end
  if ns.GearSkipped(q.id) then table.insert(out, TR"|cff9d9d9dNicht ausgewählt: Haken setzen, dann kommt sie mit Route berechnen in die Route.|r") end
  return out
end

-- 1.3c (P85): besondere Ziele (ns.SPECIALS, Daten in FesteDaten.lua), zb der Schlafsack. Eigene Zusatz Route ueber die ganze
-- Reihe (Objekte, Kontinent Wechsel, Navi mit Flug und Schiff fuer weite Schritte), nie automatisch in der Leveling Route.
-- Die Kette kommt aus den Daten: von der letzten Quest rueckwaerts ueber die Vorquests (Questie plus Daten Korrektur).
-- Vorquests "eine davon" (zb Horde 79007 oder Allianz 79008) kommen alle in die Auswahl, die Route nimmt die, die fuer dich geht
local function QPre(qid)
  local QDB = ns.QDBAccess and ns.QDBAccess()
  local single, group
  if QDB then
    local ok1, v1 = pcall(QDB.QueryQuestSingle, qid, "preQuestSingle")
    local ok2, v2 = pcall(QDB.QueryQuestSingle, qid, "preQuestGroup")
    single, group = ok1 and v1 or nil, ok2 and v2 or nil
  end
  if ns.DKPreSingle then single = ns.DKPreSingle(qid, single) end
  if ns.DKPreGroup then group = ns.DKPreGroup(qid, group) end
  local out = {}
  for _, id in ipairs(type(single) == "table" and single or {}) do out[#out + 1] = id end
  for _, id in ipairs(type(group) == "table" and group or {}) do out[#out + 1] = id end
  return out
end
local SPECIAL_CHAIN_MAX = 30
function ns.SpecialChain(key)
  local sp = ns.SPECIALS and ns.SPECIALS[key]
  if not (sp and sp.lastQuest) then return nil end
  local set, todo, n = {}, { sp.lastQuest }, 0
  while #todo > 0 and n < SPECIAL_CHAIN_MAX do
    local q = table.remove(todo)
    if not set[q] then
      set[q] = true; n = n + 1
      for _, p in ipairs(QPre(q)) do if not set[p] then todo[#todo + 1] = p end end
    end
  end
  return set, n
end
local function Done(qid)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
    local ok, v = pcall(C_QuestLog.IsQuestFlaggedCompleted, qid)
    if ok then return ns.Plain and ns.Plain(v) or v end
  end
  return false
end
function ns.SpecialHave(key)
  local sp = ns.SPECIALS and ns.SPECIALS[key]
  if not sp then return false end
  if sp.lastQuest and Done(sp.lastQuest) then return true end
  local c = sp.item and ns.Api and ns.Api.GetItemCount and ns.Api.GetItemCount(sp.item)
  return (tonumber(c) or 0) > 0
end
function ns.SpecialAvailable(key)
  local sp = ns.SPECIALS and ns.SPECIALS[key]
  if not sp then return false end
  if sp.forever and not ns.FOREVER then return false end
  return true
end
function ns.SpecialName(key)
  local sp = ns.SPECIALS and ns.SPECIALS[key]
  if not sp then return "?" end
  local nm = sp.item and ((C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(sp.item)) or (GetItemInfo and GetItemInfo(sp.item)))
  return (type(nm) == "string" and nm ~= "") and nm or TR"Schlafsack"
end
function ns.SpecialVendor(key)
  local sp = ns.SPECIALS and ns.SPECIALS[key]
  local v = sp and sp.vendor
  if not (v and v.map and v.x and v.y) then return end
  local nm = v.npc and ns.NpcName and ns.NpcName(v.npc, nil) or TR"Händler"
  if ns.ZielNavi then ns.ZielNavi(v.map, v.x, v.y, nm, "vendor") end
end
function ns.SpecialRoute(key)
  if not ns.SpecialAvailable(key) then return end
  local name = ns.SpecialName(key)
  if ns.SpecialHave(key) then ns.Print((TR"%s hast du schon."):format(name)); return end
  local set, n = ns.SpecialChain(key)
  if not set or n == 0 then ns.Print(TR"Keine Quests für dieses Ziel gefunden."); return end
  -- schon erledigte Quests der Reihe brauchen keinen Schritt (die Route kennt sie selbst), offene bleiben
  local L = UnitLevel("player")
  -- 1.3f (P85, Pr 02:42: Ziel Level L+3 = 17, die Reihe hat Questlevel 22 bis 32): bis zum hoechsten Questlevel der Kette
  local QDB = ns.QDBAccess and ns.QDBAccess()
  local top = L + 3
  for qid in pairs(set) do
    local ok, ql = false, nil
    if QDB then ok, ql = pcall(QDB.QueryQuestSingle, qid, "questLevel") end
    if ok and type(ql) == "number" and ql + 1 > top then top = ql + 1 end
  end
  ns.Print((TR"%s holen: Route über %d Quests wird berechnet. Danach geht die Leveling Route weiter, wo du warst."):format(name, n))
  if ns.TestLog then ns.TestLog("RECHNEN", ("Besonderes Ziel %s: %d Quests in der Reihe"):format(tostring(key), n)) end
  ns.Optimize(math.min(60, top), function(opt)
    if opt and ns.db then ns.db.optMode = true end
    if ns.RefreshBig then ns.RefreshBig() end
  end, { gearQ = set, special = key, minLevel = ns.SPECIALS[key].level, title = (TR"%s holen"):format(name) })
  -- 1.3l (Pr 13:45: 79974 bis 79976 nie in der Route): vorher maxTime 7200, das Zeit Budget nahm von hinten ganze Quests
  -- weg, also genau die letzten der Reihe. Die Reihe laeuft ueber viele Level, darum hier kein Zeit Budget
  if ns.RefreshBig then ns.RefreshBig() end
end
