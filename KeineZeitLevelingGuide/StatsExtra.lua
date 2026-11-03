local ADDON, ns = ...
local TR = ns.TR

-- Statistik Zusaetze: Bestwerte, Gold und Ruf pro Stunde (Session), Treffer der Schaetzung, Tipps

local sess = { money = nil, at = nil, rep = {}, deathAt = nil }
ns.statSess = sess

local function DB()
  local db = ns.db
  if not db then return end
  db.best = db.best or {}
  return db
end

-- Ruf Gewinne mitzaehlen ("Euer Ruf bei X hat sich um N verbessert.")
local repPat
local function RepPattern()
  if repPat ~= nil then return repPat end
  local s = FACTION_STANDING_INCREASED
  if type(s) ~= "string" then repPat = false; return false end
  local order = {}
  local p = s:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
  p = p:gsub("%%(%d?)%%?%$?([sd])", function(n, t)
    table.insert(order, t)
    return t == "d" and "(%d+)" or "(.-)"
  end)
  repPat = { pat = "^" .. p .. "$", order = order }
  return repPat
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
f:RegisterEvent("PLAYER_DEAD")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:SetScript("OnEvent", function(_, ev, msg)
  local db = DB()
  if ev == "PLAYER_LOGIN" then
    sess.money = GetMoney and GetMoney() or 0
    sess.at = GetTime()
    sess.deathAt = GetTime()
    sess.levelAt = GetTime()
    return
  end
  if not db then return end
  if ev == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
    local rp = RepPattern()
    msg = ns.Plain and ns.Plain(msg) or msg
    if not (rp and type(msg) == "string") then return end
    local a, b = msg:match(rp.pat)
    if not a then return end
    local name, n = a, b
    if rp.order[1] == "d" then name, n = b, a end
    n = tonumber(n)
    if name and n then sess.rep[name] = (sess.rep[name] or 0) + n end
  elseif ev == "PLAYER_DEAD" then
    local run = GetTime() - (sess.deathAt or GetTime())
    if run > (db.best.noDeath or 0) then db.best.noDeath = run end
    sess.deathAt = GetTime()
  elseif ev == "PLAYER_LEVEL_UP" then
    local lv = tonumber(msg)
    -- schnellstes Level: nur wenn die Session das ganze Level gesehen hat
    if lv and sess.levelFull and sess.levelAt then
      local t = GetTime() - sess.levelAt
      if t > 60 and (not db.best.level or t < db.best.level.sec) then db.best.level = { lv = lv - 1, sec = t } end
    end
    sess.levelAt = GetTime()
    sess.levelFull = true
  end
end)

-- beste Stunde: jede Minute nachsehen
ns.Ticker(60, function()
  local db = DB()
  if not (db and ns.Stats) then return end
  local s = ns.Stats()
  if s and s.xph and s.xph > (db.best.hour or 0) and (GetTime() - (sess.at or GetTime())) > 1800 then db.best.hour = s.xph end
  local run = GetTime() - (sess.deathAt or GetTime())
  if run > (db.best.noDeath or 0) then db.best.noDeath = run end
end)

-- Bestwerte als eine Zeile
function ns.BestLine()
  local db = DB()
  if not db then return "" end
  local b = db.best
  local p = {}
  if b.level then table.insert(p, (TR"schnellstes Level: %d in %s"):format(b.level.lv, ns.Clock(b.level.sec))) end
  if b.hour then table.insert(p, (TR"beste Stunde: %s XP"):format(ns.FormatNum and ns.FormatNum(b.hour) or math.floor(b.hour))) end
  if b.noDeath and b.noDeath > 300 then table.insert(p, (TR"ohne Tod: %s"):format(ns.Clock(b.noDeath))) end
  if b.goldHour then table.insert(p, (TR"beste Gold Stunde: %s"):format(ns.Money(b.goldHour))) end
  return #p > 0 and (TR"|cffffd100Bestwerte:|r " .. table.concat(p, ", ")) or ""
end

-- Wie gut trifft die Schaetzung der Route (geplant gegen echt)
function ns.EstimateHit()
  local pt = ns.PerfTiles and ns.PerfTiles() or {}
  if not (pt.optPlan and pt.optReal and pt.optPlan > 300) then return nil end
  local hit = 1 - math.abs(pt.optReal - pt.optPlan) / pt.optPlan
  return math.max(0, math.min(1, hit))
end

-- Tipps, wo Zeit verloren geht (Leveln)
function ns.StatTips()
  local out = {}
  local db = ns.db
  local pt = ns.PerfTiles and ns.PerfTiles() or {}
  local sp = pt.split or {}
  local tot = (sp.fight or 0) + (sp.walk or 0) + (sp.fly or 0) + (sp.dead or 0) + (sp.idle or 0)
  if tot > 600 then
    if (sp.idle or 0) / tot > 0.15 then table.insert(out, (TR"Diese Session %d%% Stillstand. Pausen mit dem Feierabend Modus planen?"):format(math.floor((sp.idle or 0) / tot * 100))) end
    if (sp.walk or 0) / tot > 0.5 then table.insert(out, TR"Viel Laufen. Fehlende Flugpunkte holen spart Wege (Meine Route, Planen, Flugpunkte).") end
  end
  local dz = db and db.stats and db.stats.deathZones
  if dz then
    local worst, n
    for m, c in pairs(dz) do if not n or c > n then worst, n = m, c end end
    if worst and n >= 3 then table.insert(out, (TR"%d Tode in %s. Gefährliche Quests dort plant die Route jetzt später ein."):format(n, ns.ZoneName and ns.ZoneName(worst) or "?")) end
  end
  local hit = ns.EstimateHit()
  if hit then table.insert(out, (TR"Die Schätzung der Route trifft zu %d%%. Sie lernt dein Tempo mit."):format(math.floor(hit * 100))) end
  return out
end

-- Seite "Gold und Ruf"
function ns.GoldRepLines()
  local out = {}
  local db = DB()
  local el = GetTime() - (sess.at or GetTime())
  local money = GetMoney and GetMoney() or 0
  local got = money - (sess.money or money)
  table.insert(out, TR"|cffffd100Gold diese Session|r")
  if el < 300 then
    table.insert(out, TR"Spiel ein paar Minuten, dann kommen hier die Zahlen.")
  else
    local gph = got / el * 3600
    table.insert(out, (TR"Bargeld: %s, also ca %s pro Stunde"):format(ns.Money(math.max(0, got)), ns.Money(math.max(0, gph))))
    if db and gph > (db.best.goldHour or 0) and el > 1800 then db.best.goldHour = gph end
    -- Beute in den Taschen nach AH Preis
    if ns.SellWorth and (GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)) then
      local nslots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
      local info = (C_Container and C_Container.GetContainerItemInfo)
      local ah, vend = 0, 0
      for bag = 0, 4 do
        for slot = 1, (nslots(bag) or 0) do
          local link, cnt, id
          if info then local i = info(bag, slot); if i then link, cnt, id = i.hyperlink, i.stackCount, i.itemID end
          elseif GetContainerItemInfo then local _, c, _, _, _, _, l, _, _, i2 = GetContainerItemInfo(bag, slot); link, cnt, id = l, c, i2 end
          if link and id then
            local w, a, v = ns.SellWorth(id, link)
            if w == "ah" and a then ah = ah + a * (cnt or 1) else vend = vend + (v or 0) * (cnt or 1) end
          end
        end
      end
      table.insert(out, (TR"Beute in den Taschen: ca %s im AH, %s beim Händler"):format(ns.Money(ah), ns.Money(vend)))
      if ah > 400000 then table.insert(out, TR"|cff7fd1b9Tipp:|r die Beute ist im AH einiges wert. Verkaufen, bevor du weiter farmst?") end
    end
  end
  local gl = ns.GoldTargetLine and ns.GoldTargetLine()
  if gl then table.insert(out, TR"Ziel: " .. gl) end
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Ruf diese Session|r")
  local list = {}
  for name, n in pairs(sess.rep) do table.insert(list, { name = name, n = n }) end
  table.sort(list, function(a, b) return a.n > b.n end)
  if #list == 0 then table.insert(out, TR"Noch kein Ruf dazugekommen.") end
  for _, e in ipairs(list) do
    local rate = el > 300 and e.n / el * 3600 or nil
    table.insert(out, ("%s: +%d%s"):format(e.name, e.n, rate and (TR", ca %d pro Stunde"):format(math.floor(rate)) or ""))
  end
  table.insert(out, "")
  local bl = ns.BestLine()
  if bl ~= "" then table.insert(out, bl) end
  return out
end
