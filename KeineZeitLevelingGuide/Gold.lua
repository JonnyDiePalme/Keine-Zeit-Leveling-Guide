local ADDON, ns = ...
local TR = ns.TR

-- Gold Quests: Questgeber nach Gold pro Stunde abklappern.
-- Gold pro Quest: gelernt (beim NPC gesehen oder abgegeben) oder nach Quest Level geschaetzt.

local QUEST_MIN = 6      -- Minuten pro Quest fuer Ziele erledigen und zurueck
local MAX_HOURS = 2      -- so lange wird die Route geplant

-- nur auf Maximallevel
-- Gold farmen ab Level 35 (Sparen fuers Reittier mit 40), im Experte Modus sofort
ns.GOLD_LEVEL = 35
function ns.GoldAllowed()
  if ns.Expert and ns.Expert() then return true end
  return UnitLevel("player") >= ns.GOLD_LEVEL
end

-- Gold einer Quest in Kupfer
-- Schaetzung mit Questie: auf Maximallevel gibt es statt XP Gold (6 Kupfer pro XP Punkt),
-- dazu die normale Geldbelohnung (grob nach Quest Level)
function ns.QuestMoney(q)
  local db = ns.db
  if q.id and db.questMoney and db.questMoney[q.id] then return db.questMoney[q.id], true end
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  -- 19.31: Geld aus den Server Daten 1.12 (VMaNGOS): Belohnung, auf Maximallevel dazu das Geld statt XP.
  -- Negativ heisst dort "kostet Geld", das zaehlt hier als 0
  local sv = q.id and ns.ServerQuest and ns.ServerQuest(q.id)
  if sv and tonumber(sv[4]) then
    local k = math.max(0, sv[4])
    if (UnitLevel("player") or 1) >= maxL then k = k + math.max(0, tonumber(sv[5]) or 0) end
    return k, false
  end
  local L = q.level or UnitLevel("player")
  local base = math.floor(L * L * 8) -- Level 60 ca 2g 90s
  local xp = q.id and ns.QuestBaseXP and ns.QuestBaseXP(q.id, L)
  if xp then
    -- XP wird nur auf Maximallevel zu Gold (vorher gibt es XP statt Gold)
    local conv = (UnitLevel("player") or 1) >= maxL and math.floor(xp * 6) or 0
    return base + conv, false
  end
  -- 19.21: ohne XP Daten die gleiche Schaetzung wie mit (vorher L*L*20, also 2.5 mal so viel, je nachdem ob XP Daten da sind)
  return base, false
end

function ns.Money(c)
  c = math.floor(c or 0)
  local g, s, k = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
  if g > 0 then return (TR"%dg %02ds"):format(g, s) end
  if s > 0 then return (TR"%ds %02dc"):format(s, k) end
  return k .. "c"
end

local function PlayerPoint()
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  return { mapID, x, y }
end

-- Route berechnen: immer den naechsten Stopp mit dem meisten Gold pro Sekunde nehmen
function ns.BuildGoldRoute(force)
  local db = ns.db
  if not ns.qStarts then
    ns.goldRoute = nil
    ns.Print(TR"Gold Quests braucht Questie, die Quest Daten sind noch nicht geladen.")
    return
  end
  local preview = not ns.GoldAllowed()
  if preview and (not ns.goldStarts or force or GetTime() - (ns.goldStartsAt or 0) > 300) then
    ns.Print(TR"Gold Quests Vorschau wird berechnet ...")
    ns.ScanGoldQuests(function() ns.goldStartsAt = GetTime(); ns.BuildGoldRoute() end)
    return
  end
  ns.goldPreview = preview
  -- auf Maximallevel: echte Planung wie die optimierte Route (Annehmen, Ziele, Abgeben, Laufwege),
  -- aber nach Gold pro Stunde statt XP
  if not preview and ns.Optimize then
    if ns.OptBusy and ns.OptBusy() then ns.Print(TR"Rechnet gerade schon ..."); return end
    -- echte Quest Route: jeder Stopp ist erst fertig, wenn angenommen oder abgegeben ist (keine alte Vorschau mehr)
    ns.goldRoute = nil
    local tgt = db.goldTarget
    local maxT = (tgt and tgt.kind == "time" and tgt.sec) or MAX_HOURS * 3600
    ns.Optimize(60, function(opt)
      if opt and db.goldMode then db.optMode = true end
      if ns.RefreshUI then ns.RefreshUI() end
    end, { gold = true, maxTime = maxT, goldAll = ns.goldAllOnce or nil })
    ns.goldAllOnce = nil
    return
  end
  local start = PlayerPoint()
  if not start then return end
  local speed = ns.speed or 7

  -- Kandidaten: Abgaben (Gold ohne Questzeit) und Questgeber
  local cand = {}
  for ui, list in pairs(preview and {} or (ns.qEnds or {})) do
    for _, e in ipairs(list) do
      local gold, known = 0, true
      for _, q in ipairs(e.quests) do
        local m, k = ns.QuestMoney(q)
        gold = gold + m
        known = known and k
      end
      table.insert(cand, { e[1], e[2], e[3], map = ui, x = e[1], y = e[2], name = e[3], quests = e.quests, gold = gold, work = 30, turnin = true, known = known })
    end
  end
  for ui, list in pairs(preview and ns.goldStarts or ns.qStarts) do
    for _, e in ipairs(list) do
      local gold, known = 0, true
      for _, q in ipairs(e.quests) do
        local m, k = ns.QuestMoney(q)
        gold = gold + m
        known = known and k
      end
      table.insert(cand, { e[1], e[2], e[3], map = ui, x = e[1], y = e[2], name = e[3], quests = e.quests, gold = gold, work = #e.quests * QUEST_MIN * 60, known = known })
    end
  end

  local route, used = {}, {}
  local here, time, total = start, 0, 0
  while time < MAX_HOURS * 3600 do
    local best, bestScore, bestTravel
    for i, c in ipairs(cand) do
      if not used[i] then
        local d = ns.WorldDist(here, { c.map, c.x, c.y })
        if d then -- gleicher Kontinent
          local travel = d / speed
          local score = c.gold / (travel + c.work + 1)
          if not bestScore or score > bestScore then best, bestScore, bestTravel = i, score, travel end
        end
      end
    end
    if not best then break end
    local c = cand[best]
    used[best] = true
    time = time + bestTravel + c.work
    total = total + c.gold
    c.travel, c.cum, c.cumGold = bestTravel, time, total
    table.insert(route, c)
    here = { c.map, c.x, c.y }
  end

  ns.goldRoute = route
  ns.goldTotal, ns.goldTime = total, time
  db.goldIdx = 1
  if ns.Draw then ns.Draw() end
  ns.Print((TR"Gold Quests: %d Stopps, ca %s in %s, also ca %s pro Stunde"):format(#route, ns.Money(total), ns.Clock(time),
    ns.Money(time > 0 and total / time * 3600 or 0)))
end

function ns.ToggleGold()
  local db = ns.db
  db.goldMode = not db.goldMode
  if db.goldMode and not ns.GoldAllowed() then
    ns.Print(TR"|cffff5050Achtung:|r Gold farmen geht erst ab Level 35. Die Route ist nur eine Vorschau.")
  end
  if db.goldMode then
    ns.BuildGoldRoute()
    ns.Print(TR"Gold Quests an. Pfeil und Karte folgen jetzt den Gold Quests.")
  else
    -- Gold Route als fertig markieren: dann geht es mit dem Fahrplan weiter (nicht mit einem freien Abschnitt)
    if db.opt and (db.opt.gold or (db.opt.opts and db.opt.opts.gold)) and ns.AutoOpt then
      db.opt.idx = #(db.opt.steps or {}) + 1
      ns.AutoOpt(true)
    end
    ns.Print(TR"Gold Quests aus, zurück zur normalen Route.")
  end
  if ns.Draw then ns.Draw() end
  if ns.RefreshUI then ns.RefreshUI() end
  if ns.MapButtonText then ns.MapButtonText() end
end

-- naechster Stopp fuer den Pfeil
function ns.GoldTarget()
  local db = ns.db
  -- die Vorschau (unter 35) zeigt nur, wie es aussieht; der Pfeil folgt immer der echten Quest Route
  if not (db and db.goldMode and ns.goldRoute) or ns.goldPreview then return end
  return ns.goldRoute[db.goldIdx or 1]
end

-- Text fuer die Charakterseite
function ns.GoldLines()
  local out = { TR"|cffffd100Gold Quests|r" }
  local db = ns.db
  local gl = ns.GoldTargetLine and ns.GoldTargetLine()
  if gl then table.insert(out, TR"Ziel: " .. gl) end
  if db.opt and db.opt.gold and ns.OptLines then
    for _, l in ipairs(ns.OptLines(40)) do table.insert(out, l) end
    table.insert(out, "")
    table.insert(out, TR"|cff9d9d9dGold: gelernte Belohnungen sind genau, sonst geschätzt (Belohnung plus Gold statt XP auf 60, plus Beute der Quest Mobs). Item Belohnungen nicht eingerechnet.|r")
    return out
  end
  if not ns.qStarts then
    table.insert(out, TR"Braucht Questie, die Daten werden nach dem Einloggen geladen.")
    return out
  end
  if not ns.goldRoute then
    table.insert(out, TR"Noch nicht berechnet. Oben auf \"Route rechnen\" klicken.")
    table.insert(out, TR"Ziel wählen: nach Zeit (1 oder 2 Std) oder nach Gold (90 Gold fürs Reittier, 500 Gold). Der Fortschritt läuft im Mini Fenster mit.")
    return out
  end
  local r = ns.goldRoute
  if ns.goldPreview then
    table.insert(out, TR"|cffff5050Vorschau: Gold farmen geht erst ab Level 35.|r")
  end
  table.insert(out, (TR"%s, %d Stopps, ca %s in %s"):format(db.goldMode and TR"|cff40ff40aktiv|r" or TR"|cff9d9d9daus|r", #r, ns.Money(ns.goldTotal), ns.Clock(ns.goldTime)))
  table.insert(out, (TR"Ertrag: ca |cffffd100%s pro Stunde|r"):format(ns.Money(ns.goldTime > 0 and ns.goldTotal / ns.goldTime * 3600 or 0)))
  local earned = 0
  for i = 1, (db.goldIdx or 1) - 1 do earned = earned + (r[i] and r[i].gold or 0) end
  table.insert(out, (TR"Schon eingesammelt laut Route: %s"):format(ns.Money(earned)))
  table.insert(out, "")
  for i, c in ipairs(r) do
    local col = (i < (db.goldIdx or 1)) and "|cff9d9d9d" or ((i == (db.goldIdx or 1)) and "|cff40ff40" or "|cffffffff")
    table.insert(out, ("%s%d. %s %s|r  %s%s"):format(col, i, c.turnin and TR"[Abgeben]" or TR"[Quests]", c.name or "?",
      ns.Money(c.gold), c.known and "" or TR" (geschätzt)"))
    local names = {}
    for j, q in ipairs(c.quests) do
      if j > 4 then table.insert(names, "..."); break end
      table.insert(names, q.name)
    end
    table.insert(out, (TR"     %s | %s, nach %s, Summe %s"):format(ns.ZoneName(c.map), table.concat(names, ", "), ns.Clock(c.cum), ns.Money(c.cumGold)))
  end
  table.insert(out, "")
  table.insert(out, TR"|cff9d9d9dGold wird geschätzt, bis du die Quest einmal beim NPC gesehen hast. Item Belohnungen sind nicht eingerechnet.|r")
  return out
end

-- angekommen? dann naechster Stopp
local function Tick()
  local db = ns.db
  local c = ns.GoldTarget()
  if not c then return end
  local pos = C_Map.GetPlayerMapPosition(c.map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  if math.sqrt((x - c.x) ^ 2 + (y - c.y) ^ 2) < (db.radius or 0.02) then
    db.goldIdx = (db.goldIdx or 1) + 1
    local n = ns.GoldTarget()
    if n then
      ns.Print((TR"Gold Stopp erledigt. Nächster: %s (%s)"):format(n.name or "?", ns.Money(n.gold)))
    else
      ns.Print(TR"Gold Quests fertig! Neu berechnen unter Farmen, Gold.")
    end
    if ns.Draw then ns.Draw() end
  end
end

function ns.InitGold()
  local db = ns.db
  db.questMoney = db.questMoney or {}
  ns.Ticker(1, Tick)
  SLASH_TAURENROUTEGOLD1 = "/trgold"
  SlashCmdList.TAURENROUTEGOLD = ns.ToggleGold
end


-- Gold Ziel: Zeit (Sekunden) oder Gold (Kupfer). Fortschritt im Mini Fenster.
function ns.SetGoldTarget(kind, value)
  local db = ns.db
  if not db then return end
  if not kind then db.goldTarget = nil; ns.Print(TR"Gold Ziel entfernt."); return end
  db.goldTarget = { kind = kind, sec = kind == "time" and value or nil, gold = kind == "gold" and value or nil,
    startMoney = GetMoney and GetMoney() or 0, startAt = time and time() or 0 }
  if kind == "time" then ns.Print((TR"Gold Ziel: %s farmen."):format(ns.Clock(value)))
  else ns.Print((TR"Gold Ziel: %s."):format(ns.Money(value))) end
  if db.goldMode and ns.BuildGoldRoute then ns.BuildGoldRoute(true) end
end

-- Zeile fuers Mini Fenster
function ns.GoldTargetLine()
  local db = ns.db
  local t = db and db.goldTarget
  if not t or not GetMoney then return nil end
  local have = GetMoney()
  if t.kind == "gold" then
    local left = t.gold - have
    if left <= 0 then return TR"|cff40ff40Gold Ziel erreicht!|r" end
    local rate = (db.opt and db.opt.goldRate) or 0
    return (TR"Noch %s%s"):format(ns.Money(left), rate > 0 and (TR", ca " .. ns.Clock(left / rate * 3600)) or "")
  else
    local el = (time and time() or 0) - (t.startAt or 0)
    local left = (t.sec or 0) - el
    local got = have - (t.startMoney or have)
    if left <= 0 then return (TR"|cff40ff40Zeit um.|r Verdient: %s"):format(ns.Money(math.max(0, got))) end
    return (TR"Gold Zeit: noch %s, verdient %s"):format(ns.Clock(left), ns.Money(math.max(0, got)))
  end
end

-- Auf 60 gibt es statt XP Gold: einmal fragen, ob alle offenen Quests fuer Gold gemacht werden sollen
local gf = CreateFrame("Frame")
gf:RegisterEvent("PLAYER_LEVEL_UP")
gf:SetScript("OnEvent", function(_, _, lvl)
  local max = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if tonumber(lvl) ~= max or not ns.Confirm then return end
  C_Timer.After(4, function()
    ns.Confirm(TR"Level " .. max .. TR"! Quests geben jetzt Gold statt XP.\n\nAlle offenen Quests für Gold machen? Gold Quests plant sie nach Gold pro Stunde, Quests nah beieinander zusammen.",
      TR"Ja, Gold Quests", function()
        ns.goldAllOnce = true
        if not ns.db.goldMode and ns.ToggleGold then ns.ToggleGold() elseif ns.BuildGoldRoute then ns.BuildGoldRoute(true) end
      end, TR"Später")
  end)
end)
