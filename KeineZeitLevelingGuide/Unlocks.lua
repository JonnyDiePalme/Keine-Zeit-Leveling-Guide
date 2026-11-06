local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Freischaltungen nach Level (Modus Geführt). Im Modus Experte ist alles sofort da.
-- Gleiche Stufen fuer alle (Basis: die frueheren Stufen vom Modus Lernen, ohne "Alle Einstellungen").

-- Stufen fuer "Mein Weg": Level, Titel, Liste der Funktionen
ns.UNLOCK_STEPS = {
  { lvl = 1, items = { "arrow", "mini", "map" } },
  { lvl = 4, items = { "share" } },
  { lvl = 6, items = { "shop" } },
  { lvl = 8, items = { "vendor" } },
  { lvl = 10, items = { "gear", "berufe" } },
  { lvl = 12, items = { "books" } },
  { lvl = 13, items = { "plan", "questlog" } },
  { lvl = 14, items = { "hearth" } },
  { lvl = 15, items = { "dungeons", "split" } },
  { lvl = 17, items = { "sleep", "budget" } },
  { lvl = 20, items = { "pvp" } },
  { lvl = 22, items = { "flights", "explore" } },
  { lvl = 25, items = { "perf", "export" } },
  { lvl = 30, items = { "grind", "rep" } },
  { lvl = 34, items = { "stats" } },
  { lvl = 35, items = { "farm", "gold" } },
  { lvl = 40, items = { "mount" } },
  { lvl = 60, items = { "raids" } },
}

-- key: Name, kurze Erklaerung, Schritte, wo es ist, was der Knopf "Ausprobieren" macht
local U = {
  arrow = { name = TR"Pfeil", text = TR"Zeigt dir den Weg zum nächsten Questgeber oder Questziel." },
  mini = { name = TR"Mini Fenster", text = TR"Sagt dir in Worten, was zu tun ist." },
  map = { name = TR"Route auf der Karte", text = TR"Auf der Weltkarte siehst du die nächsten Schritte als Linie." },
  share = { name = TR"Quests mit der Gruppe teilen", text = TR"Bist du in einer Gruppe, teilt Keine Zeit Leveling Guide passende Quests von selbst und zeigt im Mini Fenster, wie weit die anderen sind." },
  shop = { name = TR"Einkaufsliste", text = TR"Brauchen Quests Sachen vom Händler, siehst du in Städten eine Einkaufsliste.",
    how = { TR"Im Mini Fenster Menü auf Einkaufsliste klicken.", TR"Oder /klg einkaufen im Chat." }, try = function() if ns.ShowShopping then ns.ShowShopping() end end },
  vendor = { name = TR"Händler Suche", text = TR"Werden die Taschen voll oder ist die Rüstung kaputt, zeigt der Pfeil zum nächsten Händler mit Reparatur.",
    how = { TR"Im Mini Fenster Menü auf Händler klicken.", TR"Nochmal klicken bringt dich zurück auf die Route." }, try = function() if ns.FindVendor then ns.FindVendor() end end },
  gear = { name = TR"Ausrüstung", text = TR"Keine Zeit Leveling Guide sucht jetzt Quests mit besserer Belohnung als deine Ausrüstung. So wirst du unterwegs besser, ohne Händler oder Auktionshaus.",
    how = { TR"Im grossen Fenster unter Ziele auf Ausrüstung klicken.", TR"Maus auf ein Teil: du siehst den Vergleich mit deinem.", TR"Route berechnen: der Pfeil führt dich zu allen Quests, Vorquests inklusive." }, page = "gear" },
  books = { name = TR"Bibliotheksbücher", text = TR"In der Welt liegen Bücher, die du abgeben kannst. Liegen sie nah am Weg, plant die Route sie mit ein.",
    how = { TR"Im grossen Fenster unter Ziele auf Bücher klicken.", TR"Standard: ein Buch darf bis 600 Yards Umweg sein. Im Modus Alles frei stellst du das unter Einstellungen selbst ein." }, page = "books" },
  questlog = { name = TR"Questlog Route", text = TR"Plant nur die Quests, die schon in deinem Log sind. Gut wenn du wenig Zeit hast oder das Log aufräumen willst.",
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Planen." }, try = function() if ns.TourQuestLog then ns.TourQuestLog() end end, page = "plan" },
  -- Ruhestein gehoert immer zur Planung (keine Stufe dafuer), hier nur das Gasthaus
  hearth = { name = TR"Gasthaus", text = TR"Die Route sagt dir, in welchem Gasthaus du dich binden sollst. Dort ausloggen gibt Ruhebonus." },
  plan = { name = TR"Planen", page = "plan", text = TR"In Meine Route kommt der Reiter Planen dazu: Questlog Route, später Stunden Budget, Flugpunkte und Entdecken Tour.",
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Planen." } },
  dungeons = { name = TR"Dungeons", text = TR"Für passende Dungeons holt die Route alle Quests vorher ab, mit Vorquests. In der Gruppe kann jeder einen Teil holen.",
    how = { TR"Im grossen Fenster unter Ziele auf Dungeons klicken.", TR"Route starten holt alle Quests.", TR"Aufteilen verteilt die Questgeber in der Gruppe (nur der Gruppenleiter)." }, page = "dungeons" },
  split = { name = TR"Quests in der Gruppe aufteilen", text = TR"Jeder holt einen Teil der Quests, danach teilt ihr sie. Spart viel Laufen.", page = "dungeons" },
  sleep = { name = TR"Feierabend", text = TR"Ein Klick und der Pfeil führt dich zum nächsten Gasthaus, mit Abgaben auf dem Weg. Dort ausloggen gibt Ruhebonus.",
    how = { TR"Im Mini Fenster Menü auf Feierabend klicken.", TR"Nochmal klicken bringt dich zurück auf die Route." }, try = function() if ns.EndSession then ns.EndSession() end end },
  budget = { name = TR"Stunden Budget", text = TR"Gib ein, wie lange du spielst, oder bis wann (Serverzeit). Die Route passt sich an und endet im Gasthaus.", try = function() if ns.ShowBudget then ns.ShowBudget() end end,
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Planen." }, page = "plan" },
  pvp = { name = TR"Schlachtfelder", text = TR"Quests für Schlachtfelder kommen mit in die Route. Anmelden kannst du während du questest.", page = "pvp" },
  flights = { name = TR"Flugpunkte Tour", text = TR"Eine Runde zu allen Flugpunkten, die dir noch fehlen.", try = function() if ns.TourFlights then ns.TourFlights() end end, page = "plan",
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Planen." } },
  explore = { name = TR"Entdecken Tour", text = TR"Eine Runde zu allen Gebieten, die du noch nicht aufgedeckt hast.", try = function() if ns.TourExplore then ns.TourExplore() end end, page = "plan",
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Planen." } },
  grind = { name = TR"Grind Spots auf der Karte", text = TR"Gute Stellen zum Grinden für dein Level siehst du auf der Weltkarte." },
  mount = { name = TR"Reittier", text = TR"Mit Reittier rechnet die Route mit schnellerem Laufen. Wege und Zeiten werden kürzer." },
  farm = { name = TR"Gold: Mobs", text = TR"Mobs, die bei dir am meisten Gold pro Stunde bringen, mit Preisen aus dem Auktionshaus.", page = "farm" },
  gold = { name = TR"Gold: Quests", text = TR"Eine Runde mit mehreren Spots, Händler und Auktionshaus.", page = "gold" },
  berufe = { name = TR"Berufe", text = TR"Kräuter, Erz, Leder, Stoff, Fleisch und Fische farmen. Du wählst, was du brauchst, Keine Zeit Leveling Guide plant die Runde, auch für mehrere Berufe.",
    how = { TR"Im grossen Fenster unter Farmen auf Berufe klicken (Farmen erscheint, wenn Farmberufe Routen auf Ja steht).", TR"Oben den Beruf wählen, links die Sachen anhaken.", TR"Route planen: Menge oder Zeit wählen, dann Route starten." }, page = "berufe" },
  -- immer da (keine Stufe), fuer Mein Weg Klicks und Hinweise
  overview = { name = TR"Übersicht", page = "overview", text = TR"Level, Tempo, Zeit bis zum nächsten Level, dein Schritt und deine Ziele auf einer Seite." },
  export = { name = TR"Route exportieren und laden", page = "overview", text = TR"Deine Route als Text teilen oder die Route von jemand anderem laden. Eine geladene Route zeigt Namen in deiner Sprache.",
    how = { TR"Im grossen Fenster unter Start auf Route exportieren und laden klicken.", TR"Klick teilt deine Route, Rechtsklick lädt eine." } },
  perf = { name = TR"Statistik", page = "perf", text = TR"Wie gut läuft es? XP pro Stunde, Zeit bis zum nächsten Level und Vergleich mit der Route.",
    how = { TR"Im grossen Fenster unter Start auf Statistik klicken." } },
  routeplan = { name = TR"Zonenplan", page = "route", text = TR"Deine Route bis Level 60 zum Anklicken: was du schon gemacht hast und was noch kommt, mit Zeit pro Level und Zone.",
    how = { TR"Im grossen Fenster unter Meine Route, Reiter Zonenplan." } },
  stats = { name = TR"Statistik: Pro Level und Gesamt", page = "stats", text = TR"Mehr Zahlen: Zeiten pro Abschnitt und Zone, Quests pro Gebiet und XP Anteile.",
    how = { TR"Im grossen Fenster unter Statistik, Reiter Pro Level und Gesamt." } },
  raids = { name = TR"Raids", text = TR"Schlachtzüge mit ihren Quests und Vorquests, wie bei den Dungeons.", page = "raids" },
  rep = { name = TR"Ruf farmen", text = TR"Ruf bei Fraktionen steigern, mit Quests, Mobs und Abgaben. Ab etwa Level 30 kannst du Ruf auch an Mobs farmen, zum Beispiel Rabenholdt.", page = "rep" },
}
ns.UNLOCKS = U
local LEVEL = {}
for _, st in ipairs(ns.UNLOCK_STEPS) do for _, k in ipairs(st.items) do LEVEL[k] = st.lvl end end
ns.UNLOCK_LEVEL = LEVEL

-- Modus: guided (Geführt: Funktionen kommen mit dem Level) oder free (Experte).
-- Alte Werte: easy und learn werden Geführt, expert wird Experte (siehe ns.MigrateSettings).
function ns.Mode()
  local m = ns.db and ns.db.mode
  if m == "free" or m == "expert" then return "free" end
  return "guided"
end
function ns.Expert() return ns.Mode() == "free" end
-- Dungeon Quests in der Route: eigene Wahl (Einrichtung, Einstellungen), Standard an.
-- Der Modus aendert nur die Ansicht, nie die Berechnung (Wunsch von Sascha, 17.2)
function ns.DungeonQOn()
  local v = ns.db and ns.db.dungeonQ
  if v ~= nil then return v and true or false end
  return true
end
function ns.Learn() return ns.Mode() == "guided" end
function ns.Guided() return ns.Mode() == "guided" end
ns.MODES = {
  { "guided", TR"Geführt", TR"Funktionen kommen mit dem Level dazu, jede kurz erklärt. Bei den Einstellungen erst die wichtigsten, der Rest unter Alle Einstellungen." },
  { "free", TR"Alles frei", TR"Alles sofort da: alle Seiten, alle Funktionen, alle Einstellungen." },
}
function ns.ModeName(m)
  m = m or ns.Mode()
  if m == "expert" then m = "free" elseif m == "easy" or m == "learn" then m = "guided" end
  for _, e in ipairs(ns.MODES) do if e[1] == m then return e[2] end end
  return TR"Geführt"
end
function ns.SetMode(m)
  if not ns.db then return end
  if m == "expert" then m = "free" elseif m == "easy" or m == "learn" then m = "guided" end
  ns.db.mode = (m == "free") and "free" or "guided"
  if ns.OnModeChanged then ns.OnModeChanged() end
end
-- Übersicht ist die Startseite in jedem Modus. Einstellungen: im Modus Geführt die wichtigsten, sonst alle
function ns.UseOverview() return true end
function ns.UseFunc() return ns.Expert() or (ns.db and ns.db.allSettings) and true or false end

-- Tempo: 2 Stufen (Alles, Normal ist Standard) und der Schalter Grinden (17.2, Wunsch von Sascha:
-- Schnell war im Sim so schnell wie Normal, darum nur noch zwei Stufen zur Auswahl).
-- thr: wie viel eine Quest mindestens bringen muss (im Vergleich zum Grinden), cap: wie viele Quests pro Abschnitt.
-- scope "wide": Quests aus allen passenden Zonen deiner Fraktion (ohne fremde Startgebiete), "all": alle Zonen.
-- Grinden an (Standard): Grinden ist eine Option. Bei Normal nimmt die Route Grind Schritte, wo sie bei dir schneller
-- sind als Quests (schnelle Kill Zeiten: oefter), bei Alles nur, wenn im Level sonst nichts geht. Aus: keine Grind Schritte.
ns.LEVEL_STEPS = {
  { name = TR"Alles", short = TR"Alles", all = true, goal = "all", scope = "all", qlDown = 60, eliteLater = true,
    text = TR"Wirklich alle machbaren Quests, auch mit wenig XP. Zonen werden fertig gemacht, bevor es weitergeht. Elite Quests kommen, sobald du sie allein schaffst." },
  { name = TR"Normal", short = TR"Normal", scope = "wide", thr = 0.4, cap = 1.5, goal = "normal", std = true,
    text = TR"Gute Quests in sinnvoller Reihenfolge, der Standard. Mit Grinden an kommen Grind Schritte dazu, wo das für dich schneller ist." },
}
local GOAL_STEP = { all = 1, normal = 2, speed = 2 }
ns.STEP_NORMAL = 2

-- aktuelle Stufe (1 Alles, 2 Normal). Altes Schnell (3) zaehlt als Normal.
function ns.LevelStep(L)
  local db = ns.db
  if not db then return 2 end
  if db.stepRanges then db.stepRanges = nil end
  local i = tonumber(db.levelStep) or GOAL_STEP[db.goal or "normal"] or 2
  if not ns.LEVEL_STEPS[i] then i = 2 end
  return i
end
function ns.LevelStepInfo(i) return ns.LEVEL_STEPS[i or ns.LevelStep()] end
-- Grinden an? Schalter fuer beide Stufen, Standard an
function ns.GrindOn()
  local db = ns.db
  return not (db and db.grind == false)
end

function ns.SetLevelStep(i, quiet)
  local db = ns.db
  if not db then return end
  i = math.max(1, math.min(#ns.LEVEL_STEPS, math.floor(tonumber(i) or 2)))
  local st = ns.LEVEL_STEPS[i]
  local old = ns.LevelStep()
  -- in der Einrichtung: nur merken, gerechnet wird mit dem Knopf "Berechnen"
  if ns.setupOpen then
    db.levelStep = i
    db.goal = st.goal
    if old ~= i then db.stepChanged = time() end
    if ns.TempoDirty then ns.TempoDirty() end
    if ns.QuestRowsRefresh then ns.QuestRowsRefresh() end
    return
  end
  -- schon aktiv und die Route passt dazu: nichts neu rechnen (Neu rechnen gibt es im Menue extra)
  if old == i and db.plan60 and ns.PlanSig and db.plan60.sig == ns.PlanSig() then
    if not quiet then ns.Print(TR"Tempo: " .. st.name .. TR" ist schon aktiv.") end
    return
  end
  db.levelStep = i
  db.goal = st.goal
  if ns.QuestRowsRefresh then ns.QuestRowsRefresh() end
  if not quiet then ns.Print(TR"Tempo: " .. st.name .. TR". Die Route wird neu gerechnet.") end
  if old ~= i then db.stepChanged = time() end
  if ns.TempoDirty then ns.TempoDirty() end
  -- 20.2: entprellt (mehrmals am Regler = eine Rechnung)
  if ns.AutoOptSoon then ns.AutoOptSoon() elseif ns.AutoOpt then ns.AutoOpt(true) end
  if ns.OnModeChanged then ns.OnModeChanged() end
end
-- Grinden an oder aus (beide Stufen)
function ns.SetGrind(on)
  local db = ns.db
  if not db then return end
  db.grind = on and true or false
  if ns.TempoDirty then ns.TempoDirty() end
  if not ns.setupOpen and ns.AutoOptSoon then ns.AutoOptSoon() end
  if ns.OnModeChanged then ns.OnModeChanged() end
end

-- Was die Route mitnimmt (Einrichtung Schritt 2 und Einstellungen, Tempo): Ja oder Nein, Maus drauf erklaert kurz.
-- setup: in der Einrichtung wird nur gemerkt, gerechnet wird mit dem Knopf "Route berechnen"
function ns.QuestRowDefs(setup)
  local db = ns.db or {}
  local function Re() if not setup and not ns.setupOpen and ns.AutoOptSoon then ns.AutoOptSoon() end end
  return {
    { text = TR"Grinden?", get = function() return (ns.db and ns.db.grind) ~= false end,
      set = function(v) if ns.SetGrind then ns.SetGrind(v) end end,
      tip = TR"Ja: Grind Stopps, wo Grinden schneller ist als die nächste Quest, höchstens 15 Minuten. Nein: nur Quests." },
    { text = TR"Dungeon Quests einplanen?", get = function() return ns.DungeonQOn() end,
      set = function(v) ns.db.dungeonQ = v and true or false; Re() end,
      tip = TR"Ja: Quests für einen Dungeon kommen mit kleinem Umweg mit, damit du sie dort dabei hast. Nein: nur ihre Vorquests." },
    { text = TR"Eskorten einplanen?", get = function() return (ns.db and ns.db.escorts) ~= false end,
      set = function(v) ns.db.escorts = v and true or false; Re() end,
      tip = TR"Ja: Quests, bei denen du jemanden begleitest oder etwas auslöst, kommen mit. Nein: sie fallen weg." },
    { text = TR"Kontinent wechseln?", get = function() return (ns.db and ns.db.contSwitch) ~= false end,
      set = function(v) ns.db.contSwitch = v and true or false; Re() end,
      tip = TR"Ja: für gute Quests darf die Route per Schiff oder Zeppelin den Kontinent wechseln. Nein: sie bleibt hier." },
    { text = TR"Bibliotheksbücher am Weg mitnehmen?", get = function() return (ns.db and ns.db.books) ~= false end,
      set = function(v) ns.db.books = v and true or false; Re() end,
      tip = TR"Ja: Bücher nahe der Route kommen mit, der Umweg ist einstellbar. Nein: keine Bücher, du kannst sie trotzdem gezielt holen." },
    -- 19.10 (Wunsch Sascha): zwei Varianten von Alles
    { text = TR"Alles: graue Quests abseits erst auf 60?", get = function() return ns.AllRest() end,
      set = function(v) ns.db.allRest = v and true or nil; if ns.TempoDirty then ns.TempoDirty() end; Re() end,
      active = function() return ns.LevelStep and ns.LevelStep() == 1 end,
      tip = TR"Nur bei Tempo Alles. Ja: graue Quests weit weg kommen erst auf 60, alles am Weg kommt mit. Nein: jede Quest von Anfang an, der lange Weg bis 60." },
  }
end
-- 19.10: Alles mit "graue Quests abseits erst auf 60" (nur wirksam bei Tempo Alles)
function ns.AllRest() return (ns.db and ns.db.allRest) and true or false end
-- Fragen, die vom Tempo abhaengen, neu zeichnen (Einrichtung und Einstellungen)
ns.questRowUpd = ns.questRowUpd or {}
function ns.QuestRowsRefresh() for _, f in ipairs(ns.questRowUpd) do pcall(f) end end

-- alte Aufrufe: Einfach leveln, Schnell leveln, Alles erleben
function ns.SetGoal(g)
  ns.SetLevelStep(GOAL_STEP[g] or 2)
end

------------------------------------------------------------
-- Tempo Schaetzung pro Charakter: Zeit bis Ende vom Abschnitt und bis 60 fuer alle 3 Stufen, Prozent zu Normal.
-- Grundlage: Simulationen 1 bis 60 (alle Voelker) liefern pro 10 Level und Stufe: Laufen (Sekunden bei 7 Yards/s,
-- ab 40 mit Reittier), Anzahl Kills und den Rest (Reisen, Sammeln, Reden). Das wird mit dem gerechnet, was das
-- Addon bei dir misst: Lauftempo, Reittier, Zeit pro Kill (Kampf und Pause). Je mehr gemessen, desto genauer.
-- Bis 60 kommt aus dem Modell, der laufende Abschnitt aus deiner Route (im Verhaeltnis Modell zu Plan).
-- [Stufe][Band] = { Laufen Sek, Kills, Rest Sek }, Band 1 = Level 1 bis 10, 2 = 10 bis 20 ... 6 = 50 bis 60.
-- Stufe 3 = Schnell mit Grinden, 4 = Schnell ohne Grinden (aus 17.1, 4 gilt jetzt fuer Normal mit Grinden aus).
ns.TEMPO_BASE = ns.TEMPO_BASE or {
  -- aus den Simulationen 1 bis 60 (Version 17.1, alle 10 Voelker, Mittelwert, neuer Charakter)
  [1] = { { 2334, 219, 661 }, { 9943, 682, 1589 }, { 19275, 1127, 2726 }, { 37019, 1666, 4514 }, { 36032, 2530, 6335 }, { 48163, 2804, 7131 } },
  [2] = { { 2493, 219, 684 }, { 10273, 625, 1522 }, { 20250, 946, 2272 }, { 37169, 1322, 3323 }, { 37534, 1869, 4684 }, { 46002, 1835, 5549 } },
  [3] = { { 2400, 222, 628 }, { 10011, 614, 1429 }, { 19424, 915, 2242 }, { 38317, 1348, 3338 }, { 35401, 1860, 4478 }, { 45868, 1872, 5704 } },
  [4] = { { 2275, 249, 639 }, { 11568, 624, 1523 }, { 18597, 982, 1970 }, { 34666, 1388, 3087 }, { 37974, 1958, 4997 }, { 45161, 1913, 5602 } },
}
local tempoCache, tempoDirty = nil, true
function ns.TempoDirty() tempoDirty = true end
do
  local tf = CreateFrame("Frame")
  tf:RegisterEvent("PLAYER_LEVEL_UP")
  tf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  tf:SetScript("OnEvent", function() tempoDirty = true end)
end
-- Modell Zeit fuer ein Band (Teil frac davon) mit deinen Werten
local function BandTime(variant, b, frac, me)
  local row = ns.TEMPO_BASE[variant] and ns.TEMPO_BASE[variant][b]
  if not row then return 0 end
  local Lmid = (b - 1) * 10 + 5
  local vf = (Lmid >= 40) and (10.6 / math.max(7, me.mount or 10.6)) or (7 / math.max(5, me.run or 7))
  local kill = (me.kill or 30) * (1 + Lmid / 120) / (1 + (me.L or 1) / 120)
  return ((row[1] or 0) * vf + (row[2] or 0) * kill + (row[3] or 0)) * frac
end
-- Rest bis 60 (ab Level L mit Bruchteil) und Rest im jetzigen Band
local function ModelRest(variant, Lx, me)
  local total, band = 0, 0
  for b = 1, 6 do
    local lo, hi = (b - 1) * 10, b * 10
    if b == 1 then lo = 1 end
    if Lx < hi then
      local frac = (Lx > lo) and (hi - Lx) / (hi - lo) or 1
      local t = BandTime(variant, b, frac, me)
      total = total + t
      if Lx >= lo then band = t / math.max(0.05, frac) end -- ganzes Band, fuer Verhaeltnisse
    end
  end
  return total, band
end
local function Variant(i)
  if i == 2 and ns.db and ns.db.grind == false then return 4 end
  return i
end
-- Ergebnis: { [1..3] = { to60 = Sek, sec = Sek bis Ende Abschnitt (oder nil), pct = Prozent zu Normal (+ langsamer) }, guess = true/false }
function ns.TempoEstimate()
  if tempoCache and not tempoDirty then return tempoCache end
  local db = ns.db
  local L = UnitLevel("player") or 1
  local Lx = L + ((ns.Plain and ns.Plain(UnitXP("player")) or 0) / math.max(1, (ns.Plain and ns.Plain(UnitXPMax("player")) or 1)))
  local me = { L = L }
  local f, d, n = nil, nil, 0
  if ns.KillBreakdown then f, d, n = ns.KillBreakdown(0) end
  me.kill = ns.KillSeconds and ns.KillSeconds() or 30
  me.run = db and db.runSpeed or 7
  me.mount = db and db.mountSpeed or 10.6
  local measured = (n or 0) >= 20 and db and db.runSpeed ~= nil
  local out = { guess = not measured }
  local rest, band = {}, {}
  local NS = #ns.LEVEL_STEPS
  for i = 1, NS do rest[i], band[i] = ModelRest(Variant(i), Lx, me) end
  -- aktive Stufe: Zeit aus der Route (Abschnitte bis 60), die anderen im Verhaeltnis
  local act = ns.LevelStep and ns.LevelStep() or 2
  local pl = db and db.plan60
  local planRest, secRest
  if pl and pl.secs and #pl.secs > 0 then
    planRest = 0
    local o = db.opt
    local cur = math.max(1, (o and o.plan) or pl.cur or 1)
    for k = cur, #pl.secs do planRest = planRest + (pl.secs[k].sec or 0) end
    if o and o.steps and o.plan == cur then
      local st = o.steps[math.min(o.idx or 1, #o.steps)]
      local done = st and st.t or 0
      secRest = math.max(0, (o.sec or pl.secs[cur].sec or 0) - done)
      planRest = math.max(secRest, planRest - done)
    end
  end
  -- Bis 60 zeigt das Modell (mit deinen gemessenen Werten). Die Summe der geplanten Abschnitte lag in den
  -- Simulationen 1 bis 60 (17.2) 30 bis 80 Prozent ueber der echten Zeit (du levelst schneller als geplant,
  -- spaetere Abschnitte fangen dann hoeher an), das Modell lag bei 0.9 bis 1.03.
  -- Der laufende Abschnitt kommt aus der Route, im selben Verhaeltnis wie Modell zu Plan.
  local k = 1
  if planRest and planRest > 0 and rest[act] > 0 then k = math.max(0.4, math.min(1.5, rest[act] / planRest)) end
  for i = 1, NS do
    local r = { to60 = rest[i] }
    if secRest and band[act] > 0 then r.sec = secRest * k * band[i] / band[act] end
    out[i] = r
  end
  local norm = out[2].to60
  for i = 1, NS do out[i].pct = (norm and norm > 0) and ((out[i].to60 / norm) - 1) * 100 or 0 end
  out.L = Lx
  -- fuer Tests: Rest aus dem Plan (aktive Stufe) und aus dem Modell
  out.planRest, out.model, out.act = planRest, rest, act
  tempoCache, tempoDirty = out, false
  return out
end
-- gespielte Zeit gerundet auf volle Stunden: "ca 4 Tage 6 Std"
function ns.TempoClock(sec)
  local h = math.floor((sec or 0) / 3600 + 0.5)
  if h < 1 then return TR"unter 1 Std" end
  local dd, hh = math.floor(h / 24), h % 24
  if dd == 0 then return (TR"ca %d Std"):format(hh) end
  if hh == 0 then return (dd == 1 and TR"ca 1 Tag" or (TR"ca %d Tage"):format(dd)) end
  return (dd == 1 and (TR"ca 1 Tag %d Std"):format(hh) or (TR"ca %d Tage %d Std"):format(dd, hh))
end
-- Vergleich zu Normal, auf 5 Prozent gerundet
function ns.TempoPctText(i)
  local e = ns.TempoEstimate()
  if i == 2 then return TR"Standard" end
  local p = e[i] and e[i].pct or 0
  local r = math.floor(math.abs(p) / 5 + 0.5) * 5
  if math.abs(p) < 5 or r == 0 then return TR"etwa gleich schnell" end
  return p > 0 and (TR"ca %d%% langsamer"):format(r) or (TR"ca %d%% schneller"):format(r)
end
-- eine Zeile pro Stufe, nur im Verhaeltnis zu Normal (Wunsch: keine Stunden und Tage):
-- "Alles: ca 20% langsamer. Nach Level 60 geht die Route weiter, bis alle Quests fertig sind."
function ns.TempoLine(i)
  local st = ns.LEVEL_STEPS[i]
  -- 20.1 (P6): bei Normal nicht "Normal: Standard" (stand so schon zweimal darueber)
  if st and st.std then return TR"Normal ist der Standard, die anderen Stufen sind damit verglichen." end
  local t = (TR"%s: %s"):format(st and st.name or "?", ns.TempoPctText(i))
  if st and st.all then t = t .. TR". Nach Level 60 geht die Route weiter, bis alle Quests fertig sind." end
  return t
end

-- Gespeicherte Daten auf das Neue uebernehmen (einmal pro Charakter, nichts geht verloren):
-- Tempo 7 Stufen auf 3 (Alles, Fast alles, Viele: Alles. Einfach: Normal. Zuegig, Sehr zuegig, Schnell: Schnell),
-- Modus Einsteiger und Lernen: Geführt, Experte: Experte, Mini Fenster "Nur Pfeil": klein.
ns.SETTINGS_VER = 3
-- Teil pro Charakter (Route und Profile liegen pro Charakter): laufende Touren Speed Leveling und Alle Quests
-- werden die normale Leveling Route, alte Profile Berufe, Gold und Ruf werden ein zusaetzliches Profil.
-- Laeuft bei jedem Charakter einmal (db.charSetVer liegt pro Charakter).
local function MigrateChar(db, old, ls)
  if (db.charSetVer or 0) >= ns.SETTINGS_VER then return end
  local function Clean(o)
    if not (o and o.opts and (o.opts.speed or (o.opts.all and not o.opts.step))) then return nil end
    local was = o.opts.speed and "speed" or "all"
    o.opts.speed, o.opts.all = nil, nil
    o.speed = nil
    return was
  end
  local o = db.opt
  local was = Clean(o)
  if was then
    old.tour = was
    -- nur beim ersten Charakter (Konto Teil laeuft gerade mit): Tempo passend zur laufenden Tour, wenn es keins gab
    if old.account and not ls then
      db.levelStep = (was == "speed") and 2 or 1
      db.goal = (ns.LEVEL_STEPS[db.levelStep] or ns.LEVEL_STEPS[2]).goal
    end
    db.migrateRecalc = true
  end
  for _, p in pairs(type(db.profiles) == "table" and db.profiles or {}) do if type(p) == "table" then Clean(p.opt) end end
  -- Routen Profile: frueher Berufe, Gold und Ruf einzeln, jetzt ein zusaetzliches Profil (das zuletzt benutzte)
  if ns.ProfileMigrate then pcall(ns.ProfileMigrate, db) end
  db.charSetVer = ns.SETTINGS_VER
end
function ns.MigrateSettings(db)
  db = db or ns.db
  if not db then return end
  local old = {}
  local ls
  if (db.setVer or 0) < ns.SETTINGS_VER then
    old.account = true
    local sv = db.setVer or 0
    ls = tonumber(db.levelStep)
    if sv < 2 then
      -- Tempo 7 Stufen auf 3 (Daten von 16.x)
      if ls then
        old.levelStep = ls
        if ls <= 3 then db.levelStep = 1 elseif ls == 4 then db.levelStep = 2 else db.levelStep = 3 end
      elseif db.goal == "all" then db.levelStep = 1
      elseif db.goal == "speed" then db.levelStep = 3 end
      -- Modus (der Modus aendert nur die Ansicht)
      local m = db.mode
      old.mode = m
      if m == "expert" then db.mode = "free"
      elseif m == "learn" or m == "easy" then db.mode = "guided" end
      -- Mini Fenster: nur noch klein und gross
      if db.hudSize == "arrow" then old.arrowOnly = true; db.hudSize = "small"; db.hud = true end
    end
    -- 17.2: Schnell gibt es nicht mehr, wird Normal (Grinden an oder aus bleibt wie es war)
    if tonumber(db.levelStep) == 3 then old.speed = true; db.levelStep = 2 end
    -- 17.2: Dungeon Quests sind Standard an (17.0 hatte sie fuer alte Einsteiger aus gesetzt). Einmal auf Standard
    if sv < 3 and db.dungeonQ == false then old.dungeonQ = false; db.dungeonQ = nil end
    db.goal = (ns.LEVEL_STEPS[db.levelStep or 2] or ns.LEVEL_STEPS[2]).goal
  end
  MigrateChar(db, old, ls)
  if old.account then
    -- alte Werte merken (frueheres Update bleibt dabei)
    db.migrated = type(db.migrated) == "table" and db.migrated or {}
    for k, v in pairs(old) do db.migrated[k] = v end
    db.setVer = ns.SETTINGS_VER
  elseif old.tour then
    db.migrated = db.migrated or {}
    db.migrated.tourChars = (db.migrated.tourChars or 0) + 1
  end
end

function ns.UnlockLevel(key)
  return LEVEL[key] or 1
end

-- frei? (Experte: alles sofort, Geführt: nach Level)
function ns.Unlocked(key)
  local lv = LEVEL[key]
  if not lv then return true end
  if ns.Expert() then return true end
  return (UnitLevel("player") or 1) >= lv
end

local function StepItems(st) return st.items end
ns.StepItems = StepItems
-- 20.4b (K 19:02, KORR 19:28): Farmen (Berufe, Gold) gibt es nur mit dem Zusatz Addon <Ordner>_Farming
-- ("Keine Zeit Leveling Guide: Farming"). Fehlt es oder ist es aus, blendet das Hauptaddon alles zum Farmen aus,
-- ohne Fehlermeldung. Der Schalter "Farmberufe Routen" bleibt dazu (aus = auch mit Zusatz Addon versteckt).
local FARM_SUFFIX = "_Farming"
function ns.FarmAddonName() return ADDON .. FARM_SUFFIX end
function ns.FarmAddonLoaded()
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not isLoaded then return false end
  local ok, v = pcall(isLoaded, ns.FarmAddonName())
  return ok and v and true or false
end
function ns.FarmOn()
  if not ns.FarmAddonLoaded() then return false end
  return not (ns.db and ns.db.profOn == false)
end

function ns.VisibleSteps()
  local out = {}
  -- 20.4b: ohne Farming Zusatz Addon keine Farm Stufen (Berufe, Gold) auf Mein Weg
  local FARM = { berufe = true, farm = true, gold = true }
  local farm = ns.FarmOn()
  for _, st in ipairs(ns.UNLOCK_STEPS) do
    local items = {}
    for _, k in ipairs(st.items) do if farm or not FARM[k] then items[#items + 1] = k end end
    if #items > 0 then table.insert(out, { lvl = st.lvl, items = items }) end
  end
  return out
end

-- Text fuer gesperrte Knoepfe
function ns.LockText(key)
  if ns.Unlocked(key) then return nil end
  return (TR"Kommt ab Level %d"):format(ns.UnlockLevel(key))
end

function ns.UnlockName(key) return U[key] and U[key].name or key end
function ns.UnlockInfo(key) return U[key] end

-- naechste Stufe, die noch nicht frei ist
function ns.NextUnlock()
  if ns.Expert() then return nil end
  local L = UnitLevel("player") or 1
  for _, st in ipairs(ns.VisibleSteps()) do
    if st.lvl > L then
      local names = {}
      for _, k in ipairs(st.items) do table.insert(names, U[k].name) end
      return st, table.concat(names, ", ")
    end
  end
end

function ns.UnlockProgress()
  local L = UnitLevel("player") or 1
  local n = 0
  local list = ns.VisibleSteps()
  for _, st in ipairs(list) do if st.lvl <= L or ns.Expert() then n = n + 1 end end
  return n, #list
end

------------------------------------------------------------
-- Hinweis bei neuer Funktion
------------------------------------------------------------
local pop
-- wo eine Funktion zu finden ist: Seite im Vollbild, sonst das Menue vom Mini Fenster oder die Karte
local JUMP = {
  arrow = "arrow", mini = "hud", map = "map", grind = "map", share = "set", split = "dungeons", shop = "hud", vendor = "hud",
  hearth = "set", sleep = "hud", mount = "set",
}
function ns.JumpTo(key)
  local u = U[key]
  if not u then return end
  local where = u.page or JUMP[key] or "weg"
  -- genauere Erklaerung gleich an der Stelle
  local lines = { u.text }
  for i, h in ipairs(u.how or {}) do table.insert(lines, ("%d  %s"):format(i, h)) end
  local text = table.concat(lines, "\n")
  local target
  -- 19.31 (Saschas Runde: "Pfeil" auf Mein Weg erklaerte das Mini Fenster und schaltete die erweiterte Ansicht ein):
  -- der Pfeil zeigt auf den Pfeil, und keine Einstellung wird dabei umgestellt
  if where == "arrow" then
    target = function()
      local a = _G.TaurenRouteArrow
      if a and a:IsVisible() then return a end
      return _G.TaurenRouteHUD
    end
  elseif where == "hud" then
    if ns.RefreshHud then ns.RefreshHud() end
    target = function() return _G.TaurenRouteHUD end
  elseif where == "map" then
    if ToggleWorldMap and not (WorldMapFrame and WorldMapFrame:IsShown()) then pcall(ToggleWorldMap) end
    target = function() return WorldMapFrame end
  else
    if ns.ShowBig then ns.ShowBig(where) end
    target = function()
      local b = ns.BigNavButton and ns.BigNavButton(where)
      if b and b:IsVisible() then return b end
      return _G.TaurenRouteBig
    end
  end
  C_Timer.After(0.5, function()
    if ns.CoachHide then ns.CoachHide() end
    if ns.Coach then ns.Coach("jump_" .. key, { { target = target, title = u.name, text = text } }, true) end
  end)
end

-- Hinweise im Kampf zurueckhalten, danach zeigen
local queued
local function InCombat() return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player")) end

local function ShowUnlock(key, lvl)
  local u = U[key]
  if not u or not ns.T then return end
  if InCombat() then queued = { key, lvl }; return end
  if not pop then
    pop = ns.T.Popup("ForeverWegweiserUnlock", 400, "")
    pop.later = ns.T.Button(pop, TR"Später", 100, 22)
    pop.later:SetPoint("BOTTOMLEFT", 14, 12)
    pop.later:SetScript("OnClick", function() pop:Hide() end)
    pop.jump = ns.T.Button(pop, TR"Zur Funktion", 130, 22, true)
    pop.jump:SetPoint("BOTTOMRIGHT", -14, 12)
    pop.try = ns.T.Button(pop, TR"Ausprobieren", 120, 22)
    pop.try:SetPoint("RIGHT", pop.jump, "LEFT", -6, 0)
  end
  pop.title:SetText((TR"Neu ab Level %d: %s"):format(lvl or ns.UnlockLevel(key), u.name))
  local lines = { u.text }
  if u.how then
    table.insert(lines, "")
    table.insert(lines, ns.T.Section(TR"So geht es"))
    for i, h in ipairs(u.how) do table.insert(lines, ("%d  %s"):format(i, h)) end
  end
  pop.body:SetText(table.concat(lines, "\n"))
  ns.T.FitPopup(pop, 44)
  pop.try:SetShown(u.try ~= nil)
  pop.try:SetScript("OnClick", function() pop:Hide(); if u.try then u.try() end end)
  pop.jump:SetScript("OnClick", function() pop:Hide(); ns.JumpTo(key) end)
  pop:Show()
end
do
  local ce = CreateFrame("Frame")
  ce:RegisterEvent("PLAYER_REGEN_ENABLED")
  ce:SetScript("OnEvent", function()
    if not queued then return end
    local q = queued
    queued = nil
    C_Timer.After(2, function() if not InCombat() then ShowUnlock(q[1], q[2]) else queued = q end end)
  end)
end
ns.ShowUnlock = ShowUnlock

-- Erklaerung fuer eine ganze Stufe (Mein Weg, Klick auf eine Stufe)
function ns.ShowUnlockStep(st)
  if not st then return end
  ShowUnlock(st.items[1], st.lvl)
  if #st.items > 1 and pop then
    local lines = {}
    for _, k in ipairs(st.items) do
      table.insert(lines, ns.T.Section(U[k].name))
      table.insert(lines, U[k].text)
      table.insert(lines, "")
    end
    pop.title:SetText((TR"Level %d"):format(st.lvl))
    pop.body:SetText(table.concat(lines, "\n"))
    ns.T.FitPopup(pop, 44)
  end
end

-- offene Hinweise fuer das Mini Fenster
ns.unlockPending = {}

local function Announce(newLevel)
  local db = ns.db
  if not db then return end
  db.unlockSeen = db.unlockSeen or {}
  local fresh = {}
  for _, st in ipairs(ns.VisibleSteps()) do
    if st.lvl <= newLevel then
      for _, k in ipairs(st.items) do
        if not db.unlockSeen[k] then
          db.unlockSeen[k] = true
          table.insert(fresh, k)
        end
      end
    end
  end
  if #fresh == 0 then return end
  -- Experte: alles ist schon frei, keine Hinweise
  if ns.Expert() then fresh = {} end
  -- neue Seiten im grossen Fenster und im Menue (Einsteiger und Lernen)
  if #fresh > 0 and ns.OnModeChanged then ns.OnModeChanged() end
  if #fresh == 0 or db.unlockHints == false then return end
  for _, k in ipairs(fresh) do table.insert(ns.unlockPending, k) end
  ShowUnlock(fresh[1], newLevel)
  if ns.RefreshHud then ns.RefreshHud() end
  if ns.RefreshCharTab then ns.RefreshCharTab() end
end

-- Test: Level simulieren. Hoeher: neue Stufen werden erklaert. Tiefer: Stufen darueber gelten wieder als neu.
function ns.SimLevel(n)
  local db = ns.db
  if not db then return end
  db.unlockSeen = db.unlockSeen or {}
  if not n then
    ns.testLevel = nil
    ns.Print(TR"Test Level aus, wieder echtes Level " .. (_G.UnitLevel("player") or 1) .. ".")
  else
    n = math.max(1, math.min(60, math.floor(n)))
    local old = UnitLevel("player") or 1
    ns.testLevel = n
    for _, list in ipairs({ ns.UNLOCK_STEPS }) do
      for _, st in ipairs(list) do
        if st.lvl > n then for _, k in ipairs(st.items) do db.unlockSeen[k] = nil end end
      end
    end
    ns.unlockPending = {}
    ns.Print((TR"Test Level %d (echt %d). Gilt für Freischaltungen und Fenster, die Route rechnet mit dem echten Level. Aus mit /klg tlvl aus"):format(n, _G.UnitLevel("player") or 1))
    if n > old then Announce(n) end
  end
  if ns.OnModeChanged then ns.OnModeChanged() end
  if ns.RefreshCharTab then ns.RefreshCharTab() end
  if ns.RefreshHud then ns.RefreshHud() end
end

function ns.TakePendingUnlock()
  local k = table.remove(ns.unlockPending, 1)
  if k then ShowUnlock(k) end
  return k
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:SetScript("OnEvent", function(_, event, lvl)
  if event == "PLAYER_LOGIN" then
    C_Timer.After(1, function()
      local db = ns.db
      if not db then return end
      db.unlockSeen = db.unlockSeen or {}
      -- bestehende Charaktere: alles bis zum jetzigen Level gilt als gesehen, keine Flut von Hinweisen
      local L = UnitLevel("player") or 1
      -- je nach Modus zaehlt das passende Level (Einsteiger hat eigene Stufen)
      for _, list in ipairs({ ns.UNLOCK_STEPS }) do
        for _, st in ipairs(list) do
          for _, k in ipairs(st.items) do
            if ns.UnlockLevel(k) <= L and ns.Unlocked(k) then db.unlockSeen[k] = true end
          end
        end
      end
    end)
  else
    local n = tonumber(ns.Plain and ns.Plain(lvl) or nil) or (UnitLevel("player") or 1)
    C_Timer.After(2, function() Announce(n) end)
  end
end)
