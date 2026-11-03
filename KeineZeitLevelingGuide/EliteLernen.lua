local ADDON, ns = ...
local TR = ns.TR
-- 19.32 (Sascha 23:35, Realitaets Regel): Elite allein erst, wenn alle Elite Gegner eines Ziels mindestens N Level unter
-- dir sind. N startet bei 2 und lernt pro Charakter mit:
--   strenger (N plus 1): 3 Tode an Elite Gegnern oder 5 Tode ueberhaupt in 3 Stunden Spielzeit
--   lockerer (N minus 1): 3 Stunden Spielzeit ohne Tod, bis 1 (Sascha 02:15 "automatisch auch bis 1")
-- Von Hand in den Einstellungen 1 bis 5, das Lernen kann man dort ausschalten (nie gesperrt).
-- Gespeichert in db.stats.eliteGap (stats ist pro Charakter, siehe CHAR_FIELDS in Core.lua)
local START, AUTO_MIN, MIN, MAX = 2, 1, 1, 5
-- 19.32 (Sascha 01:24 "Lockerer lernen"): strenger erst nach 3 Elite Toden oder 5 Toden in 3 Std, lockerer nach 3 Std ohne Tod
local WIN, ELITE_N, ALL_N, CALM = 3 * 3600, 3, 5, 3 * 3600

local function S()
  local db = ns.db
  if not (db and type(db) == "table") then return nil end
  db.stats = db.stats or {}
  local s = db.stats.eliteGap
  if type(s) ~= "table" then
    s = { gap = START, deaths = {}, calm = 0 }
    db.stats.eliteGap = s
  end
  if type(s.gap) ~= "number" then s.gap = START end
  s.gap = math.max(MIN, math.min(MAX, math.floor(s.gap + 0.5)))
  if type(s.deaths) ~= "table" then s.deaths = {} end
  if type(s.calm) ~= "number" then s.calm = 0 end
  return s
end

function ns.EliteGap()
  local s = S()
  return s and s.gap or START
end
function ns.EliteGapLearn() return not (ns.db and ns.db.eliteLearn == false) end

local function Changed(old, new, why, manual)
  if old == new then return end
  if ns.TestLog then ns.TestLog("ELITE", ("Elite allein ab %d Level unter dir (vorher %d), %s"):format(new, old, why)) end
  -- Von Hand: ganze Route neu (wie bei den Elite Schaltern). Von selbst gelernt: nur der laufende Abschnitt neu,
  -- die naechsten Abschnitte nehmen die Grenze beim Rechnen mit, die Ankunfts Pruefung (Optimizer) gilt sofort.
  -- 19.32 (Sim Teil Y 06:10): vorher rechnete jedes Lernen den ganzen Fahrplan 1 bis 60 neu (alle 3 Std ohne Tod)
  if ns.AutoOpt then pcall(ns.AutoOpt, manual and true or "section") end
end

-- von Hand (Einstellungen): plus oder minus 1
function ns.EliteGapStep(d)
  local s = S()
  if not s then return START end
  local old = s.gap
  s.gap = math.max(MIN, math.min(MAX, old + (d or 0)))
  s.calm, s.deaths = 0, {}
  Changed(old, s.gap, "von Hand", true)
  return s.gap
end

-- Spielzeit Uhr: GetTime laeuft nur, solange du eingeloggt bist (Zeiten aus frueheren Sitzungen als Summe)
local played0 = (GetTime and GetTime()) or 0
local function Played()
  local s = S()
  return ((s and s.played) or 0) + ((GetTime and GetTime()) or 0) - played0
end

local function OnDeath()
  local s = S()
  if not s then return end
  local now = Played()
  -- Tod an einem Elite: das Ziel war Elite (rare elite und Boss zaehlen mit)
  local cl = UnitClassification and UnitExists and UnitExists("target") and UnitClassification("target")
  local elite = cl == "elite" or cl == "rareelite" or cl == "worldboss"
  table.insert(s.deaths, { t = now, e = elite or nil })
  s.calm = 0
  -- nur Tode im Fenster behalten
  local keep, nE = {}, 0
  for _, d in ipairs(s.deaths) do
    if type(d) == "table" and type(d.t) == "number" and now - d.t <= WIN then keep[#keep + 1] = d; if d.e then nE = nE + 1 end end
  end
  s.deaths = keep
  if ns.TestLog then ns.TestLog("ELITE", ("Tod%s, in 3 Std %d Tode, davon %d an Elite, Grenze %d"):format(elite and " an Elite" or "", #keep, nE, s.gap)) end
  if not ns.EliteGapLearn() then return end
  if (nE >= ELITE_N or #keep >= ALL_N) and s.gap < MAX then
    local old = s.gap
    s.gap = old + 1
    s.deaths = {}
    Changed(old, s.gap, nE >= ELITE_N and "nach Toden an Elite" or "nach vielen Toden")
  end
end

-- jede Minute: Zeit ohne Tod zaehlen, nach 3 Std eine Stufe lockerer (bis 1)
local function Tick()
  local s = S()
  if not s then return end
  s.calm = s.calm + 60
  s.played = Played()
  played0 = (GetTime and GetTime()) or 0
  if s.calm >= CALM then
    s.calm = 0
    if ns.EliteGapLearn() and s.gap > AUTO_MIN then
      local old = s.gap
      s.gap = old - 1
      Changed(old, s.gap, "3 Std ohne Tod")
    end
  end
end

if CreateFrame then
  local f = CreateFrame("Frame")
  f:RegisterEvent("PLAYER_DEAD")
  f:SetScript("OnEvent", function() pcall(OnDeath) end)
end
if ns.Ticker then ns.Ticker(60, function() pcall(Tick) end)
elseif C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(60, function() pcall(Tick) end) end

-- Text fuer die Einstellungen und die Hilfe
function ns.EliteGapText()
  return (TR"Elite allein ab %d Level unter dir"):format(ns.EliteGap())
end
-- fuer den Trockenlauf und den Sim (Tode und Minuten von aussen anstossen)
ns.EliteOnDeath, ns.EliteTick = OnDeath, Tick
