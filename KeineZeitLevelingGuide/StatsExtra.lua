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
ns.RegEv(f, "PLAYER_LOGIN")
ns.RegEv(f, "CHAT_MSG_COMBAT_FACTION_CHANGE")
ns.RegEv(f, "PLAYER_DEAD")
ns.RegEv(f, "PLAYER_LEVEL_UP")
f:SetScript("OnEvent", function(_, ev, msg)
  local db = DB()
  if ev == "PLAYER_LOGIN" then
    sess.money = GetMoney and ns.Api and ns.Api.Num(GetMoney()) or nil
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
end, nil, true) -- 1.4zzg (M51): auch in der Pause

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
-- 1.1 (S Log L7.0 "Statistik Gold und Ruf zeigt nix an, Ruf raus, nur Gold"): nur noch Gold, und immer mit Zahlen:
-- Gold jetzt, diese Session (auch in den ersten Minuten), gesamt nach Quelle (Ledger), Beute in den Taschen
-- 1.3g (P92, K 04:05 und 04:08, S 03:58 "Gold Bereich uebersichtlicher", keine EP Zeile hier): oben eine kurze Uebersicht
-- (Gold jetzt, pro Stunde fuer Sitzung, heute und gesamt), dann Einnahmen und Ausgaben nach Art, dann je Level wo wie viel
-- ausgegeben wurde (Fluege, Lehrer, Haendler, AH, Reparatur, Summe). Platzhalter weg, nur was es gibt
local GOLD_IN_ORDER = { "quest", "loot", "sell", "mail", "auction", "trade", "other" }
local GOLD_OUT_ORDER = { "flight", "train", "buy", "auction", "repair", "mail", "trade", "other" }
local GOLD_LVL_COLS = { { "flight", TR"Flüge" }, { "train", TR"Lehrer" }, { "buy", TR"Händler" }, { "auction", TR"AH" }, { "repair", TR"Reparatur" } }
local GOLD_LVL_SHOW = 12 -- so viele Level (die neuesten) in der Liste
-- 1.3y (P109 Punkt 2): Zahlen fuer die Gold Seite mit Kacheln und Balken (die Textliste bleibt unten fuer die Details)
local GOLD_COL = { quest = { 1, 0.6, 0.1 }, loot = { 0.9, 0.25, 0.25 }, sell = { 0.3, 0.8, 0.4 }, mail = { 0.5, 0.6, 1 },
  auction = { 0.85, 0.75, 0.2 }, trade = { 0.6, 0.4, 0.9 }, flight = { 0.3, 0.7, 1 }, train = { 1, 0.85, 0.2 }, buy = { 0.9, 0.5, 0.3 },
  repair = { 0.7, 0.7, 0.7 }, other = { 0.5, 0.5, 0.5 } }
function ns.GoldStatData()
  local d = { inn = {}, out = {}, levels = {} }
  local Num = ns.Api and ns.Api.Num or function(v) return v end
  local p = ns.PerfData and ns.PerfData()
  d.money = GetMoney and Num(GetMoney()) or nil
  local inn, outt = p and p.moneyIn or {}, p and p.moneyOut or {}
  d.sumIn, d.sumOut = 0, 0
  for _, v in pairs(inn) do d.sumIn = d.sumIn + v end
  for _, v in pairs(outt) do d.sumOut = d.sumOut + v end
  local tot = p and p.total or 0
  d.perHour = tot >= 300 and ((d.sumIn - d.sumOut) / tot * 3600) or nil
  for _, k in ipairs(GOLD_IN_ORDER) do if (inn[k] or 0) > 0 then d.inn[#d.inn + 1] = { name = ns.MONEY_NAMES[k] or k, v = inn[k], col = GOLD_COL[k] or GOLD_COL.other } end end
  for _, k in ipairs(GOLD_OUT_ORDER) do if (outt[k] or 0) > 0 then d.out[#d.out + 1] = { name = ns.MONEY_NAMES[k] or k, v = outt[k], col = GOLD_COL[k] or GOLD_COL.other } end end
  -- der Balken kann 6 Teile: groesste 5, der Rest als Sonstiges
  local function Top(list)
    table.sort(list, function(a, b) return a.v > b.v end)
    if #list <= 6 then return list end
    local o, rest = {}, 0
    for i, e in ipairs(list) do if i <= 5 then o[i] = e else rest = rest + e.v end end
    o[6] = { name = TR"Sonstiges", v = rest, col = GOLD_COL.other }
    return o
  end
  d.inn, d.out = Top(d.inn), Top(d.out)
  local lv = p and p.lvl
  if lv then
    local ls = {}
    -- 1.3z (P110 Punkt 2): je Level Einnahmen und Ausgaben (zwei Balken)
    for L, e in pairs(lv) do if type(L) == "number" and (e.moneyOut or e.moneyIn) then ls[#ls + 1] = L end end
    table.sort(ls, function(x, y) return x > y end)
    local M = ns.Money or tostring
    for _, L in ipairs(ls) do
      local si, so = 0, 0
      for _, v in pairs(lv[L].moneyIn or {}) do si = si + v end
      for _, v in pairs(lv[L].moneyOut or {}) do so = so + v end
      if si > 0 or so > 0 then
        -- 1.4l (P161 soll4): zwei Spalten und Saldo kurz
        local net = si - so
        d.levels[#d.levels + 1] = { L = L, name = (TR"Level %d"):format(L), vin = si, vout = so,
          tin = "|cff40ff40+" .. M(si) .. "|r", tout = "|cffff6050-" .. M(so) .. "|r",
          net = (net >= 0 and "|cff40ff40+" or "|cffff6050-") .. ns.MoneyShort(math.abs(net)) .. "|r" }
      end
    end
  end
  return d
end
-- 1.4l (P161 soll4): Geld kurz, "2.5g", "45s", "12c"
function ns.MoneyShort(c)
  c = math.floor(c or 0)
  if c >= 10000 then
    local g = c / 10000
    return (g >= 100 and ("%dg"):format(math.floor(g + 0.5)) or ("%.1fg"):format(g)):gsub("%.0g$", "g")
  elseif c >= 100 then return ("%ds"):format(math.floor(c / 100 + 0.5)) end
  return ("%dc"):format(c)
end
-- 1.4l (P161 soll4, S: "klickbar, um rechts die Einnahmen und Ausgaben von Level 1 bis zu dem Level zu sehen")
function ns.GoldLinesTo(L)
  local out = {}
  local p = ns.PerfData and ns.PerfData()
  local lv = p and p.lvl
  local M = ns.Money or tostring
  if not lv then return { TR"|cff9d9d9dnoch keine Daten|r" } end
  local function Sum(fromL, toL)
    local si, so, sum_i, sum_o = {}, {}, 0, 0
    for l, e in pairs(lv) do
      if type(l) == "number" and l >= fromL and l <= toL then
        for k, v in pairs(e.moneyIn or {}) do si[k] = (si[k] or 0) + v; sum_i = sum_i + v end
        for k, v in pairs(e.moneyOut or {}) do so[k] = (so[k] or 0) + v; sum_o = sum_o + v end
      end
    end
    return si, so, sum_i, sum_o
  end
  local function Block(title, fromL, toL)
    local si, so, ti, to = Sum(fromL, toL)
    out[#out + 1] = ("|cffffd100%s|r  %s"):format(title, ((ti - to) >= 0 and "|cff40ff40+" or "|cffff6050-") .. M(math.abs(ti - to)) .. "|r")
    out[#out + 1] = (TR"   Einnahmen %s"):format(M(ti))
    for _, k in ipairs(GOLD_IN_ORDER) do
      if (si[k] or 0) > 0 then out[#out + 1] = ("      |cff40ff40+ %s|r  %s"):format(M(si[k]), ns.MONEY_NAMES[k] or k) end
    end
    out[#out + 1] = (TR"   Ausgaben %s"):format(M(to))
    for _, k in ipairs(GOLD_OUT_ORDER) do
      if (so[k] or 0) > 0 then out[#out + 1] = ("      |cffff8060- %s|r  %s"):format(M(so[k]), ns.MONEY_NAMES[k] or k) end
    end
  end
  Block((TR"Level %d"):format(L), L, L)
  out[#out + 1] = ""
  Block((TR"Level 1 bis %d"):format(L), 1, L)
  return out
end
function ns.GoldRepLines()
  local out = {}
  local db = DB()
  local Num = ns.Api and ns.Api.Num or function(v) return v end
  local M = ns.Money or tostring
  local el = GetTime() - (sess.at or GetTime())
  local money = GetMoney and Num(GetMoney()) or nil
  if money and not sess.money then sess.money, sess.at, el = money, GetTime(), 0 end
  local p = ns.PerfData and ns.PerfData()
  local inn, outt = p and p.moneyIn or {}, p and p.moneyOut or {}
  local sumIn, sumOut = 0, 0
  for _, v in pairs(inn) do sumIn = sumIn + v end
  for _, v in pairs(outt) do sumOut = sumOut + v end
  -- heute: Stand beim ersten Blick an diesem Tag merken (je Charakter, in der Perf Tabelle)
  local today = date and date("%Y%m%d") or "?"
  if p and money then
    if not (p.goldDay and p.goldDay.day == today) then p.goldDay = { day = today, money = money, t0 = p.total or 0 } end
  end
  local function PerH(got, sec)
    if not (sec and sec >= 300) then return TR"ab 5 Min" end
    return (got >= 0 and "+" or "-") .. M(math.abs(got) / sec * 3600)
  end
  table.insert(out, TR"|cffffd100Übersicht|r")
  if money then table.insert(out, (TR"   Gold jetzt: |cffffffff%s|r"):format(M(money))) end
  local got = (money and sess.money) and (money - sess.money) or 0
  local dayGot = (p and p.goldDay and money) and (money - p.goldDay.money) or 0
  local daySec = p and p.goldDay and ((p.total or 0) - (p.goldDay.t0 or 0)) or 0
  table.insert(out, (TR"   Pro Stunde: Sitzung %s, heute %s, gesamt %s"):format(PerH(got, el), PerH(dayGot, daySec), PerH(sumIn - sumOut, p and p.total or 0)))
  if el >= 1800 and db and db.best and got / el * 3600 > (db.best.goldHour or 0) then db.best.goldHour = got / el * 3600 end
  if sumIn + sumOut > 0 then
    table.insert(out, "")
    table.insert(out, (TR"|cffffd100Einnahmen|r gesamt %s"):format(M(sumIn)))
    for _, k in ipairs(GOLD_IN_ORDER) do
      if (inn[k] or 0) > 0 then table.insert(out, ("   |cff40ff40+ %s|r  %s (%d%%)"):format(M(inn[k]), ns.MONEY_NAMES[k] or k, math.floor(inn[k] / sumIn * 100 + 0.5))) end
    end
    table.insert(out, "")
    table.insert(out, (TR"|cffffd100Ausgaben|r gesamt %s"):format(M(sumOut)))
    for _, k in ipairs(GOLD_OUT_ORDER) do
      if (outt[k] or 0) > 0 then table.insert(out, ("   |cffff8060- %s|r  %s (%d%%)"):format(M(outt[k]), ns.MONEY_NAMES[k] or k, math.floor(outt[k] / math.max(1, sumOut) * 100 + 0.5))) end
    end
  end
  -- je Level: wo wie viel ausgegeben (neueste oben)
  local lv = p and p.lvl
  if lv then
    local ls = {}
    for L, e in pairs(lv) do if type(L) == "number" and e.moneyOut then ls[#ls + 1] = L end end
    table.sort(ls, function(x, y) return x > y end)
    if #ls > 0 then
      table.insert(out, "")
      table.insert(out, TR"|cffffd100Ausgaben je Level|r")
      for i = 1, math.min(#ls, GOLD_LVL_SHOW) do
        local L = ls[i]
        local mo = lv[L].moneyOut or {}
        local parts, sum = {}, 0
        for _, c in ipairs(GOLD_LVL_COLS) do
          local v = mo[c[1]] or 0
          if v > 0 then parts[#parts + 1] = ("%s %s"):format(c[2], M(v)) end
        end
        for _, v in pairs(mo) do sum = sum + v end
        table.insert(out, ("   |cffffffff%s %d|r: %s  |cffffd100= %s|r"):format(TR"Level", L, #parts > 0 and table.concat(parts, ", ") or TR"Sonstiges", M(sum)))
      end
      if #ls > GOLD_LVL_SHOW then table.insert(out, (TR"   (und %d Level davor)"):format(#ls - GOLD_LVL_SHOW)) end
    end
  end
  -- Beute in den Taschen nach AH Preis
  if ns.SellWorth and (GetContainerNumSlots or (C_Container and C_Container.GetContainerNumSlots)) then
    local nslots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local ah, vend = 0, 0
    for bag = 0, 4 do
      for slot = 1, (nslots(bag) or 0) do
        local _, cnt, _, _, _, _, link, _, _, id = ns.Api.GetContainerItemInfo(bag, slot)
        if link and id then
          local w, a, v = ns.SellWorth(id, link)
          if w == "ah" and a then ah = ah + a * (cnt or 1) else vend = vend + (v or 0) * (cnt or 1) end
        end
      end
    end
    table.insert(out, "")
    table.insert(out, (TR"Beute in den Taschen: ca %s im AH, %s beim Händler"):format(M(ah), M(vend)))
    if ah > 400000 then table.insert(out, TR"|cff7fd1b9Tipp:|r die Beute ist im AH einiges wert. Verkaufen, bevor du weiter farmst?") end
  end
  local gl = ns.GoldTargetLine and ns.GoldTargetLine()
  if gl then table.insert(out, TR"Ziel: " .. gl) end
  table.insert(out, "")
  -- nur Gold Bestwert hier (EP gehoeren in den Level Teil der Statistik)
  if db and db.best and db.best.goldHour then table.insert(out, (TR"|cffffd100Bestwert:|r beste Gold Stunde %s"):format(ns.Money(db.best.goldHour))) end
  return out
end

-- 1.3zze (K 04:30, 04:33, S 04:28, 04:31): Level Zeit nach Art. Nur Route Zeit zaehlt fuer Tempo, Prognose und Eichung
-- (Profil level, keine Pause, nicht AFK ueber AFK_S, nicht in Instanz, nicht Berufe, Farm oder Tour). Rest getrennt.
-- Gespeichert in perf.lvlAct[Level][Art] und perf.act[Art] (Sekunden), perf.rtotal und perf.rxp fuer die Route
ns.ACT_SPLIT = {
  AFK_S = 120, LEVELS = 15, MIN_S = 60, BAR_W = 200, BAR_H = 10, MAX_GAP_S = 1800,
  KEYS = { "route", "beruf", "dungeon", "farm", "stadt", "afk", "frei" },
  NAME = { route = TR"Route", beruf = TR"Berufe", dungeon = TR"Dungeon", farm = TR"Farm", stadt = TR"Stadt", afk = TR"AFK", frei = TR"freies Spiel" },
  COL = { route = { 64, 200, 255 }, beruf = { 255, 209, 0 }, dungeon = { 190, 90, 255 }, farm = { 80, 220, 100 },
    stadt = { 210, 160, 110 }, afk = { 110, 110, 110 }, frei = { 225, 225, 225 } },
}
-- 1.4zzi (K 20:36, S Log 20:02: StatsExtra 355 "boolean test on a secret boolean" 318x): "Plain(x) or x" gab bei einem
-- geheimen Wert (Plain = nil) wieder den geheimen Wert zurueck. Jetzt nil, wie Plain sagt
local function Pl(x)
  if ns.Api and ns.Api.Plain then return ns.Api.Plain(x) end
  if issecretvalue and issecretvalue(x) then return nil end
  return x
end
-- 1.3zzj (Pr 05:34/05:48: 3 Min stehen zaehlte nicht als AFK): Stillstand auch ueber die Position (Tempo allein reichte nicht),
-- ns.stillFor = Sekunden ohne Ortswechsel und ohne Kampf. Ab AFK_S zaehlt die ganze Steh Zeit als AFK (ns.actMove schiebt
-- die schon gezaehlten Sekunden um, Core PerfTick)
ns.ACT_SPLIT_STILL = { EPS = 0.001 } -- 1.3zzl: etwa 3 bis 5 yd, kleines Wackeln zaehlt als still
local still = { m = nil, x = nil, y = nil, n = 0, act = nil }
local function StillTick(dt)
  dt = dt or 1
  local fight = UnitAffectingCombat and Pl(UnitAffectingCombat("player"))
  local taxi = UnitOnTaxi and Pl(UnitOnTaxi("player"))
  local m = ns.PlayerMap and ns.PlayerMap()
  local pos = m and C_Map and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(m, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  local e = ns.ACT_SPLIT_STILL.EPS
  if fight or taxi or not x then still.n = 0
  elseif still.m == m and still.x and math.abs(x - still.x) < e and math.abs(y - still.y) < e then still.n = still.n + dt
  else still.n = 0 end
  if not (still.m == m and still.n > 0) then still.m, still.x, still.y = m, x, y end
  ns.stillFor = math.max(still.n, ns.idleFor or 0)
  return ns.stillFor
end
function ns.ActNow(dt)
  local db = ns.db
  if not db then return nil end
  dt = dt or 1
  local A = ns.ACT_SPLIT
  local sf = StillTick(dt)
  local afk = (UnitIsAFK and Pl(UnitIsAFK("player"))) or sf > A.AFK_S
  if afk then
    -- erste AFK Sekunde: die Steh Zeit davor von den Arten, in denen sie gezaehlt wurde, nach afk schieben
    -- 1.3zzn (Pr 07:03: abgezogen bei beruf statt route): je Art mitzaehlen, was waehrend des Stehens dort lief
    if still.act ~= "afk" and still.cnt then
      local mv = {}
      for k, n in pairs(still.cnt) do if n > 0 then mv[#mv + 1] = { from = k, n = n } end end
      if #mv > 0 then ns.actMove = mv end
    end
    still.act, still.cnt = "afk", nil
    return "afk"
  end
  local a = ns.ActKind(db)
  still.act = a
  -- Steh Zeit je Art (erster Takt im Stehen zaehlt mit, danach bis AFK_S)
  if sf > 0 then
    still.cnt = still.cnt or {}
    still.cnt[a] = (still.cnt[a] or 0) + dt
  else
    still.cnt = nil
  end
  return a
end
function ns.ActKind(db)
  local A = ns.ACT_SPLIT
  if ns.InInstance and ns.InInstance() then return "dungeon" end
  if db.paused then return "frei" end
  local o = db.opt
  if db.optMode and o and o.steps and (o.idx or 1) <= #o.steps then
    if o.prof then return "beruf" end
    if o.farm or o.repFarm or (o.opts and (o.opts.gold or o.opts.rep)) then return "farm" end
    if o.dungeonRoute or o.split then return "dungeon" end
    if o.mirror or o.group or (ns.ProfileOf and ns.ProfileOf(o) == "level") then return "route" end
  end
  if IsResting and Pl(IsResting()) then return "stadt" end
  return "frei"
end
ns.ActStill = function() return still.n end
local function Sum(e)
  local n = 0
  for _, k in ipairs(ns.ACT_SPLIT.KEYS) do n = n + (e[k] or 0) end
  return n
end
local function Bar(e, sum)
  local A, parts = ns.ACT_SPLIT, {}
  for _, k in ipairs(A.KEYS) do
    local v = e[k] or 0
    if v > 0 then
      local w = math.max(1, math.floor(v / sum * A.BAR_W + 0.5))
      local c = A.COL[k]
      parts[#parts + 1] = ("|TInterface\\Buttons\\WHITE8X8:%d:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t"):format(A.BAR_H, w, c[1], c[2], c[3])
    end
  end
  return table.concat(parts)
end
local function Hex(c) return ("|cff%02x%02x%02x"):format(c[1], c[2], c[3]) end
local function Parts(e, sum)
  local A, out = ns.ACT_SPLIT, {}
  local fmt = ns.Clock or tostring
  for _, k in ipairs(A.KEYS) do
    local v = e[k] or 0
    if v >= A.MIN_S then out[#out + 1] = Hex(A.COL[k]) .. A.NAME[k] .. "|r " .. fmt(v) end
  end
  return table.concat(out, ", ")
end
-- Anteil Route je Level (0 bis 1), nil ohne Daten. Fuer Eichung: unter 0.5 nicht nehmen
function ns.ActRouteShare(lv)
  local p = ns.PerfData and ns.PerfData() or {}
  local e = p.lvlAct and p.lvlAct[lv]
  if not e then return nil end
  local s = Sum(e)
  if s <= 0 then return nil end
  return (e.route or 0) / s, s
end
-- kurz fuers Log: "route 3120 beruf 300 ..." (Sekunden)
function ns.ActLogText(lv)
  local p = ns.PerfData and ns.PerfData() or {}
  local e = p.lvlAct and p.lvlAct[lv]
  if not e then return "keine Daten" end
  local out = {}
  for _, k in ipairs(ns.ACT_SPLIT.KEYS) do
    if (e[k] or 0) > 0 then out[#out + 1] = ("%s %d"):format(k, e[k]) end
  end
  return table.concat(out, " ")
end
-- Zeilen fuer die Statistik Seite: Summe oben, darunter je Level ein Balken
-- 1.4n (P161 soll1 Punkt 3): sel = aufgeklapptes Level. Zweite Rueckgabe map[Zeile] = Level fuer die Klick Knoepfe
function ns.ActLines(sel)
  local A, out, map = ns.ACT_SPLIT, {}, {}
  local p = ns.PerfData and ns.PerfData() or {}
  local tot = p.act or {}
  local sum = Sum(tot)
  if sum < A.MIN_S then return out end
  local fmt = ns.Clock or tostring
  out[#out + 1] = TR"|cffffd100Zeit nach Art|r  |cff9d9d9dTempo und Prognose rechnen nur mit der Route Zeit|r"
  out[#out + 1] = (TR"   Gesamt %s  %s"):format(fmt(sum), Bar(tot, sum))
  out[#out + 1] = "   " .. Parts(tot, sum)
  local L = UnitLevel("player") or 1
  for lv = L, math.max(1, L - A.LEVELS + 1), -1 do
    local e = p.lvlAct and p.lvlAct[lv]
    local s = e and Sum(e) or 0
    if s >= A.MIN_S then
      out[#out + 1] = (TR"   Level %d  %s  %s, Route %d%%"):format(lv, Bar(e, s), fmt(s), math.floor((e.route or 0) / s * 100 + 0.5))
      map[#out] = lv
      if sel == lv and ns.LvlDetailLines then
        for _, l in ipairs(ns.LvlDetailLines(lv)) do out[#out + 1] = l end
      end
    end
  end
  if next(map) then out[1] = out[1] .. TR"  |cff9d9d9dKlick auf ein Level zeigt mehr|r" end
  return out, map
end

-- Aufgeklapptes Level: Zeit nach Art, XP und Woher, Zaehler, Zonen dieses Levels
function ns.LvlDetailLines(lv)
  local p = ns.PerfData and ns.PerfData() or {}
  local e = p.lvl and p.lvl[lv]
  local out = {}
  local fmt = ns.Clock or tostring
  local G = "      |cffb0b0b0"
  local a = p.lvlAct and p.lvlAct[lv]
  if a and Sum(a) > 0 then out[#out + 1] = G .. TR"Art:|r " .. Parts(a, Sum(a)) end
  if not e then out[#out + 1] = G .. TR"noch keine Daten|r"; return out end
  local t = e.t or 0
  local function num(n) local s = tostring(math.floor(n or 0)):reverse():gsub("(%d%d%d)", "%1'"):reverse(); return (s:gsub("^'", "")) end
  out[#out + 1] = (G .. TR"XP:|r %s, %s pro Std"):format(num(e.xp or 0), t > 60 and num(math.floor((e.xp or 0) / t * 3600)) or "?")
  local src = e.src or {}
  local sum = (src.quest or 0) + (src.kill or 0) + (src.explore or 0)
  if sum > 0 then
    out[#out + 1] = (G .. TR"Woher:|r Quests %d%%, Kills %d%%, Entdecken %d%%"):format(math.floor((src.quest or 0) / sum * 100 + 0.5),
      math.floor((src.kill or 0) / sum * 100 + 0.5), math.floor((src.explore or 0) / sum * 100 + 0.5))
  end
  local c = e.cnt or {}
  out[#out + 1] = (G .. TR"Zähler:|r Kills %d, Quests %d, Tode %d"):format(c.kill or 0, c.quest or 0, c.death or 0)
  local zl = ns.ZoneLevelList and ns.ZoneLevelList(lv) or {}
  if #zl > 0 then
    local zs = {}
    for i, z in ipairs(zl) do if i <= 6 then zs[#zs + 1] = z.name .. " " .. fmt(z.t) end end
    out[#out + 1] = G .. TR"Zonen:|r " .. table.concat(zs, ", ")
  end
  return out
end
