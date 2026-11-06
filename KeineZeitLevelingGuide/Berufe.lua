local ADDON, ns = ...
local TR = ns.TR

-- Farmberufe: Kraeuter, Erz, Leder, Stoff, Fleisch und Fische.
-- Woher die Daten kommen:
--   Kraeuter und Erz: GatherMate2 (wenn da), sonst die Gebietslisten aus BerufeData.lua, dazu selber gelernt
--   Stoff und Teile vom Fleisch: QuestieDB Drop Tabelle (Wowhead, mit Dropchance), Mobs aus Questie
--   Leder: nur Wildtiere, grob nach Mob Level, genauer durch Lernen (Kuerschnern, Ziel anschauen)
--   Fische: Gebiete nach Angel Skill, Stellen und Schwaerme lernen, Schwaerme aus GatherMate2
--   Rezepte: AtlasLoot (wenn da), sonst was deine Charaktere im Berufsfenster gesehen haben
-- Gelerntes liegt accountweit in ns.db.prof und ns.db.recipes, nicht im Testlog.

local B = {}
ns.Berufe = B

local function Plain(v) if ns.Plain then return ns.Plain(v) end return v end
local function L0() return (ns.UnitLevel and ns.UnitLevel("player")) or UnitLevel("player") or 1 end
local function Now() return (time and time()) or 0 end
local IS_FOREVER = true -- 1.2e (P47): nur Forever

local function DB()
  local db = ns.db
  if not db then return end
  db.prof = db.prof or {}
  local p = db.prof
  p.nodes = p.nodes or {}   -- [map] = { [coord] = gathermate node id }  selber gesehene Kraeuter und Erz
  p.fish = p.fish or {}     -- [map] = { [cell] = { x, y, n, items = { [id] = n } } } Angelstellen
  p.ctype = p.ctype or {}   -- [npc] = 1 Wildtier, 0 anderes
  p.fishZone = p.fishZone or {} -- [map] = { [fish] = n } gefangene Fische pro Zone
  db.recipes = db.recipes or {} -- [char] = { [rezept] = { c = item, r = { [item] = n }, p = Beruf } }
  return db
end

------------------------------------------------------------
-- Berufe und Gegenstaende
------------------------------------------------------------
local ICON = "Interface\\Icons\\"
ns.PROFS = {
  { key = "herb", name = TR"Kräuterkunde", short = TR"Kräuter", skills = { "Kräuterkunde", "Herbalism" }, icon = ICON .. "Spell_Nature_NatureTouchGrow", banner = "fw_beruf_kraeuter", kind = "node", gm = "Herb Gathering" },
  { key = "mine", name = TR"Bergbau", short = TR"Bergbau", skills = { "Bergbau", "Mining" }, icon = ICON .. "Trade_Mining", banner = "fw_beruf_bergbau", kind = "node", gm = "Mining" },
  { key = "skin", name = TR"Kürschnerei", short = TR"Kürschner", skills = { "Kürschnerei", "Skinning" }, icon = ICON .. "INV_Misc_Pelt_Wolf_01", banner = "fw_beruf_kuerschner", kind = "mob" },
  { key = "cloth", name = TR"Stoff", short = TR"Stoff", skills = { "Schneiderei", "Tailoring" }, icon = ICON .. "Trade_Tailoring", banner = "fw_beruf_stoff", kind = "mob", free = true },
  { key = "cook", name = TR"Kochkunst", short = TR"Kochen", skills = { "Kochkunst", "Cooking" }, icon = ICON .. "INV_Misc_Food_15", banner = "fw_beruf_kochen", kind = "mob", free = true },
  { key = "fish", name = TR"Angeln", short = TR"Angeln", skills = { "Angeln", "Fishing" }, icon = ICON .. "Trade_Fishing", banner = "fw_beruf_angeln", kind = "fish" },
}
local PROF = {}
for _, p in ipairs(ns.PROFS) do PROF[p.key] = p end
ns.PROF = PROF

-- Kraeuter: Item, Name, Skill, GatherMate Knoten
local HERBS = {
  { 2447, TR"Friedensblume", 1, 401 }, { 765, TR"Silberblatt", 1, 402 }, { 2449, TR"Erdwurzel", 15, 403 },
  { 785, TR"Maguskönigskraut", 50, 404 }, { 2450, TR"Wilddornrose", 70, 405 }, { 3820, TR"Würgetang", 85, 407 },
  { 2453, TR"Beulengras", 100, 408 }, { 3355, TR"Wildstahlblume", 115, 409 }, { 3369, TR"Grabmoos", 120, 410 },
  { 3356, TR"Königsblut", 125, 411 }, { 3357, TR"Lebenswurz", 150, 412 }, { 3818, TR"Blassblatt", 160, 413 },
  { 3821, TR"Golddorn", 170, 414 }, { 3358, TR"Khadgars Schnurrbart", 185, 415 }, { 3819, TR"Winterbiss", 195, 416 },
  { 4625, TR"Feuerblüte", 205, 417 }, { 8831, TR"Lila Lotus", 210, 418 }, { 8836, TR"Arthas' Tränen", 220, 420 },
  { 8838, TR"Sonnengras", 230, 421 }, { 8839, TR"Blindkraut", 235, 422 }, { 8845, TR"Geisterpilz", 245, 423 },
  { 8846, TR"Gromsblut", 250, 424 }, { 13464, TR"Goldener Sansam", 260, 425 }, { 13463, TR"Traumblatt", 270, 426 },
  { 13465, TR"Bergsilbersalbei", 280, 427 }, { 13466, TR"Pestblüte", 285, 428 }, { 13467, TR"Eiskappe", 290, 429 },
  { 13468, TR"Schwarzer Lotus", 300, 431 },
}
-- Erz: Item, Name, { Knoten = Skill }
local ORES = {
  { 2770, TR"Kupfererz", { [201] = 1 } }, { 2771, TR"Zinnerz", { [202] = 65 } }, { 3340, TR"Pyrophorerz", { [219] = 65 } },
  { 2775, TR"Silbererz", { [204] = 75, [209] = 75 } }, { 4278, TR"Blutsteinerz", { [218] = 75 } }, { 2772, TR"Eisenerz", { [203] = 125 } },
  { 5833, TR"Induriumerz", { [220] = 150 } }, { 2776, TR"Golderz", { [205] = 155, [210] = 155 } },
  { 3858, TR"Mithrilerz", { [206] = 175, [207] = 175 } }, { 7911, TR"Echtsilbererz", { [208] = 230, [211] = 230 } },
  { 11370, TR"Dunkeleisenerz", { [217] = 230 } }, { 10620, TR"Thoriumerz", { [214] = 245, [213] = 245, [215] = 275, [212] = 275 } },
}
-- Leder nach Mob Level (nur Wildtiere)
local LEATHER = {
  { 2318, TR"Leichtes Leder", 1, 20 }, { 2319, TR"Mittleres Leder", 20, 30 }, { 4234, TR"Schweres Leder", 30, 40 },
  { 4304, TR"Dickes Leder", 40, 50 }, { 8170, TR"Unverwüstliches Leder", 50, 63 },
}
local CLOTH = {
  { 2589, TR"Leinenstoff" }, { 2592, TR"Wollstoff" }, { 4306, TR"Seidenstoff" }, { 4338, TR"Magiestoff" }, { 14047, TR"Runenstoff" }, { 14256, TR"Teufelsstoff" },
}
-- Tierarten (Wortteile im Mob Namen, deutsch und englisch), fuer Fleisch und um Wildtiere zu erkennen
-- (absichtlich ohne TR: wird mit Mob Namen aus dem Spiel verglichen)
local ANIMALS = {
  wolf = { "wolf", "wölf", "worg" }, boar = { "eber", "keiler", "boar", "hauer" }, bear = { "bär", "bear" },
  spider = { "spinne", "spider", "weber", "lauerer" }, croc = { "krokilisk", "crocolisk" }, raptor = { "raptor" },
  lion = { "löwe", "lion" }, tiger = { "tiger", "säbler", "saber" }, kodo = { "kodo" }, crab = { "krebs", "krabbe", "crab" },
  crawler = { "krabbler", "crawler" }, lizard = { "donnerechse", "lizard", "echse" }, strider = { "schreiter", "strider" },
  turtle = { "schildkröte", "turtle" }, coyote = { "kojote", "coyote" }, bird = { "geier", "vulture", "bussard", "buzzard", "kondor", "condor", "aasvogel", "carrion" },
  cat = { "panther", "puma", "pirscher", "stalker", "luchs", "lynx", "katze" }, hyena = { "hyäne", "hyena" }, scorpid = { "skorpid", "scorpid" },
  ape = { "gorilla", "affe", "ape" }, basilisk = { "basilisk" }, stag = { "hirsch", "stag" }, snake = { "natter", "serpent", "schlange", "snake" },
  bat = { "fledermaus", "bat" }, hawk = { "falke", "hawk", "eule", "owl" }, chimaera = { "chimäre", "chimaera" }, worm = { "sandwurm", "worm" },
}
-- Fleisch: Item, Name, Tierart, Mob Level von bis (Drop Tabelle hat nur einen Teil, der Rest geht ueber die Tierart)
local MEATS = {
  { 769, TR"Brocken Eberfleisch", "boar", 1, 15 }, { 2672, TR"Sehniges Wolfsfleisch", "wolf", 1, 11 }, { 2886, TR"Felseneberrippe", "boar", 5, 12 },
  { 1015, TR"Mageres Wolfsflankensteak", "wolf", 10, 22 }, { 2673, TR"Kojotenfleisch", "coyote", 8, 16 }, { 2677, TR"Eberrippchen", "boar", 10, 22 },
  { 2674, TR"Krabblerfleisch", "crawler", 12, 22 }, { 2675, TR"Krabblerschere", "crawler", 12, 22 }, { 1081, TR"Knuspriges Spinnenfleisch", "spider", 10, 20 },
  { 5465, TR"Kleines Spinnenbein", "spider", 5, 15 }, { 2251, TR"Klebriges Spinnenbein", "spider", 15, 25 }, { 3173, TR"Bärenfleisch", "bear", 10, 22 },
  { 729, TR"Sehniges Geierfleisch", "bird", 10, 20 }, { 1080, TR"Zähes Kondorfleisch", "bird", 15, 25 }, { 3404, TR"Bussardflügel", "bird", 25, 35 },
  { 5469, TR"Schreiterfleisch", "strider", 12, 25 }, { 5467, TR"Kodofleisch", "kodo", 12, 28 }, { 5470, TR"Donnerechsenschwanz", "lizard", 15, 25 },
  { 2924, TR"Krokiliskfleisch", "croc", 15, 25 }, { 3667, TR"Zartes Krokiliskfleisch", "croc", 25, 42 }, { 3712, TR"Schildkrötenfleisch", "turtle", 25, 40 },
  { 3730, TR"Großes Bärenfleisch", "bear", 25, 40 }, { 3731, TR"Löwenfleisch", "lion", 25, 40 }, { 3685, TR"Raptorei", "raptor", 25, 45 },
  { 12184, TR"Raptorfleisch", "raptor", 40, 55 }, { 12202, TR"Tigerfleisch", "tiger", 40, 55 }, { 12203, TR"Rotes Wolfsfleisch", "wolf", 40, 55 },
  { 12204, TR"Schweres Kodofleisch", "kodo", 40, 55 }, { 12205, TR"Weißes Spinnenfleisch", "spider", 40, 55 }, { 12206, TR"Zartes Krebsfleisch", "crab", 40, 55 },
  { 12208, TR"Zartes Wolfsfleisch", "wolf", 45, 60 }, { 12207, TR"Riesenei", "bird", 40, 55 }, { 20424, TR"Sandwurmfleisch", "worm", 55, 60 },
  { 21024, TR"Chimärokfilet", "chimaera", 55, 60 }, { 1468, TR"Murlocflosse", nil, 1, 60 }, { 730, TR"Murlocauge", nil, 1, 60 },
}
-- Angeln: Zonen mit Grundwert (Skill ab etwa Grundwert plus 70, ganz ohne Entkommen ab Grundwert plus 95)
local FISH_ZONE = {
  [1411] = -70, [1412] = -70, [1420] = -70, [1426] = -70, [1429] = -70, [1438] = -70,
  [1413] = -20, [1421] = -20, [1432] = -20, [1436] = -20, [1439] = -20, [1453] = -20, [1454] = -20, [1455] = -20, [1456] = -20, [1457] = -20, [1458] = -20,
  [1424] = 55, [1431] = 55, [1433] = 55, [1437] = 55, [1440] = 55, [1442] = 55,
  [1416] = 130, [1417] = 130, [1434] = 130, [1435] = 130, [1441] = 130, [1443] = 130, [1445] = 130,
  [1419] = 205, [1422] = 205, [1425] = 205, [1444] = 205, [1446] = 205, [1447] = 205, [1448] = 205, [1449] = 205, [1450] = 205,
  [1423] = 330, [1428] = 330, [1430] = 330, [1451] = 330, [1452] = 330,
}
-- Fische: Item, Name, Zonen Stufen, Schwarm (GatherMate Knoten)
local FISH = {
  { 6291, TR"Roher glänzender Kleinfisch", { -70, -20 } }, { 6289, TR"Roher Langkiefer-Schlammschnapper", { -70, -20 } },
  { 6303, TR"Rohe Glitschhautmakrele", { -70, -20 } }, { 6317, TR"Roher Lochfrenzy", { -20 } }, { 6522, TR"Deviatfisch", { -20 }, 109 },
  { 6308, TR"Roher Borstenbart-Wels", { -20, 55 } }, { 6361, TR"Roher Regenbogenflossen-Albacore", { -20, 55 } },
  { 6362, TR"Roher Steinschuppenkabeljau", { 55, 130 } }, { 21071, TR"Roher Weisenfisch", { 55, 130 }, 108 },
  { 8365, TR"Rohe Mithrilkopfforelle", { 130 } }, { 4603, TR"Roher gefleckter Gelbschwanz", { 130, 205 } },
  { 6358, TR"Öliger Schwarzmaul", { 130 }, 107 }, { 6359, TR"Feuerflossenschnapper", { 130, 205 }, 105 },
  { 13758, TR"Roher Rotkiemer", { 205 } }, { 13754, TR"Roher glasiger Mächtigfisch", { 205 } }, { 13759, TR"Roher Nachtflossenschnapper", { 205, 330 } },
  { 13760, TR"Roher Sonnenschuppenlachs", { 205, 330 } }, { 13756, TR"Winterkalmar", { 205 } }, { 13757, TR"Roher Sommerbarsch", { 205 } },
  { 21153, TR"Roher großer Weisenfisch", { 205 }, 106 }, { 13889, TR"Roher Weißschuppenlachs", { 330 } }, { 13422, TR"Steinschuppenaal", { 205, 330 }, 110 },
}
local function FishNeed(base) return math.min(300, math.max(1, base + 70)) end

-- Liste aller Sachen eines Berufs, in einer Form: { id, name, skill, prof, nodes = { [knoten] = skill }, lo, hi, animal, tiers, school }
local ITEMS, BYID = {}, {}
local function Add(key, it) it.prof = key; table.insert(ITEMS[key], it); BYID[it.id] = it end
for _, p in ipairs(ns.PROFS) do ITEMS[p.key] = {} end
for _, h in ipairs(HERBS) do Add("herb", { id = h[1], name = h[2], skill = h[3], nodes = { [h[4]] = h[3] } }) end
for _, o in ipairs(ORES) do
  local mn = 999
  for _, s in pairs(o[3]) do mn = math.min(mn, s) end
  Add("mine", { id = o[1], name = o[2], skill = mn, nodes = o[3] })
end
local function SkinNeed(lv) if lv <= 10 then return 1 elseif lv <= 20 then return (lv - 10) * 10 end return lv * 5 end
B.SkinNeed = SkinNeed
for _, l in ipairs(LEATHER) do Add("skin", { id = l[1], name = l[2], skill = SkinNeed(l[3]), lo = l[3], hi = l[4], beast = true }) end
for _, c in ipairs(CLOTH) do Add("cloth", { id = c[1], name = c[2], skill = 0, drop = true }) end
for _, m in ipairs(MEATS) do Add("cook", { id = m[1], name = m[2], skill = 0, animal = m[3], lo = m[4], hi = m[5], drop = true }) end
for _, f in ipairs(FISH) do
  local mn = 999
  for _, b in ipairs(f[3]) do mn = math.min(mn, FishNeed(b)) end
  Add("fish", { id = f[1], name = f[2], skill = mn, tiers = f[3], school = f[4] })
end
-- Knoten zu Item (fuers Lernen und fuer GatherMate)
local NODE_ITEM = {}
for _, it in ipairs(ITEMS.herb) do for n in pairs(it.nodes) do NODE_ITEM[n] = it end end
for _, it in ipairs(ITEMS.mine) do for n in pairs(it.nodes) do NODE_ITEM[n] = it end end
local SCHOOL_ITEM = {}
for _, it in ipairs(ITEMS.fish) do if it.school then SCHOOL_ITEM[it.school] = it end end

function ns.ProfItems(key) return ITEMS[key] or {} end
function ns.ProfItem(id) return BYID[id] end

-- Name aus dem Spiel (Sprache vom Client), sonst der eingetragene
local asked = {}
function ns.ProfItemName(it)
  if type(it) == "number" then it = BYID[it] or { id = it } end
  local n = ns.Api.GetItemInfo and ns.Api.GetItemInfo(it.id)
  if n then return n end
  if not asked[it.id] then
    asked[it.id] = true
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, it.id) end
  end
  return it.name or (TR"Item " .. it.id)
end
function ns.ProfItemIcon(id)
  local ic = ns.Api.GetItemIcon and ns.Api.GetItemIcon(id)
  if ic then return ic end
  return select(10, ns.Api.GetItemInfo(id)) or (ICON .. "INV_Misc_QuestionMark")
end

-- Skill aus dem Spiel: Stufe und Maximum, nil wenn nicht gelernt
local skillCache, skillAt = {}, -10
function ns.ProfSkill(key)
  local p = PROF[key]
  if not (p and GetNumSkillLines and GetSkillLineInfo) then return end
  if GetTime() - skillAt < 1 then local c = skillCache[key]; if c then return c[1], c[2] end; if c == false then return end end
  if GetTime() - skillAt >= 1 then skillCache = {}; skillAt = GetTime() end
  local r, m = B.ReadSkill(p)
  skillCache[key] = r and { r, m } or false
  return r, m
end
function B.ReadSkill(p)
  for i = 1, (Plain(GetNumSkillLines()) or 0) do
    local name, header, _, rank, _, _, max = GetSkillLineInfo(i)
    if name and not header then
      for _, n in ipairs(p.skills) do if name == n then return Plain(rank) or 0, Plain(max) or 0 end end
    end
  end
end

-- kann man das mit dem Skill farmen? (Stoff und Fleisch immer), plus wie viel fehlt
function ns.ProfCan(it)
  if not it then return false, 0 end
  local p = PROF[it.prof]
  if p.free then return true, 0 end
  local r = ns.ProfSkill(it.prof)
  if not r then return false, it.skill, true end
  if r >= (it.skill or 0) then return true, 0 end
  return false, (it.skill or 0) - r
end

------------------------------------------------------------
-- Auswahl (pro Charakter): Haken bei Sachen und Gebieten
------------------------------------------------------------
function ns.ProfSel()
  local db = ns.db
  if not db then return { items = {}, zones = {} } end
  db.profSel = db.profSel or {}
  db.profSel.items = db.profSel.items or {}
  db.profSel.zones = db.profSel.zones or {}
  return db.profSel
end
function ns.ProfSelCount(key)
  local n = 0
  for id in pairs(ns.ProfSel().items) do local it = BYID[id]; if it and (not key or it.prof == key) then n = n + 1 end end
  return n
end
function ns.ProfReset()
  local s = ns.ProfSel()
  s.items = {}; s.zones = {}
end
function ns.ProfToggleItem(id)
  local s = ns.ProfSel()
  local it = BYID[id]
  if not it then return end
  if s.items[id] then s.items[id] = nil; return true end
  local ok, miss, none = ns.ProfCan(it)
  if not ok then
    if none then return false, (TR"Du hast %s noch nicht gelernt."):format(PROF[it.prof].name) end
    return false, (TR"Dir fehlen noch %d Skillpunkte."):format(miss)
  end
  s.items[id] = true
  return true
end

------------------------------------------------------------
-- Kraeuter und Erz: Stellen pro Zone
------------------------------------------------------------
local GM_CELL = 0.04
local function GM()
  local g = _G.GatherMate2
  if not g and LibStub then
    local ok, ace = pcall(LibStub, "AceAddon-3.0", true)
    if ok and ace and ace.GetAddon then local ok2, a = pcall(ace.GetAddon, ace, "GatherMate2", true); if ok2 then g = a end end
  end
  return g
end
function ns.HasGatherMate() return GM() ~= nil end
local function GMDB(kind)
  local g = GM()
  if not g then return nil end
  local ok, t = pcall(function() return g.GetDB and g:GetDB(kind) end)
  if ok and type(t) == "table" then return t end
  local glob = ({ ["Herb Gathering"] = "GatherMate2HerbDB", Mining = "GatherMate2MineDB", Fishing = "GatherMate2FishDB" })[kind]
  return glob and _G[glob]
end
local function Decode(coord)
  return math.floor(coord / 1000000) / 10000, math.floor(coord % 1000000 / 100) / 10000
end
local function DecChar(s, i)
  local c = s:byte(i)
  if c > 92 then c = c - 1 end
  return c - 35
end

-- Zellen einer Zone: [knoten] = { { x, y, n, learned }, ... }  (Cache fuer 5 Minuten)
local cellCache = {}
local function ZoneCells(map)
  local c = cellCache[map]
  if c and GetTime() - c.t < 300 then return c.cells end
  local cells = {}
  local function Put(node, x, y, n, learned)
    local list = cells[node]
    if not list then list = {}; cells[node] = list end
    local key = math.floor(x / GM_CELL) * 100 + math.floor(y / GM_CELL)
    local e = list[key]
    if not e then e = { 0, 0, 0, learned = learned, nl = 0 }; list[key] = e end
    e[1] = e[1] + x * n; e[2] = e[2] + y * n; e[3] = e[3] + n
    if learned then e.learned = true; e.nl = e.nl + n end
  end
  -- GatherMate pro Art (Kraeuter, Erz): hat es fuer eine Art keine Daten in der Zone, kommen dafuer die eingebauten Stellen
  local gm = { herb = false, mine = false }
  for _, kind in ipairs({ "Herb Gathering", "Mining" }) do
    local t = GMDB(kind)
    local z = t and t[map]
    if type(z) == "table" then
      for coord, node in pairs(z) do
        local it = NODE_ITEM[node]
        if it then local x, y = Decode(coord); Put(node, x, y, 1); gm[it.prof] = true end
      end
    end
  end
  local hot = ns.PROF_HOT_FOREVER or {}
  for node, s in pairs(hot[map] or {}) do
    local it = NODE_ITEM[node]
    if it and not gm[it.prof] then
      for i = 1, #s - 2, 3 do
        Put(node, DecChar(s, i) / 90, DecChar(s, i + 1) / 90, DecChar(s, i + 2))
      end
    end
  end
  -- selbst gesehene Stellen: GatherMate speichert die schon selbst, dann nicht doppelt zaehlen
  local db = DB()
  for coord, node in pairs(db and db.prof.nodes[map] or {}) do
    local it = NODE_ITEM[node]
    if not (it and gm[it.prof]) then
      local x, y = Decode(coord)
      Put(node, x, y, 1, true)
    end
  end
  -- Zellen zu Listen mit Mittelpunkt
  local out = {}
  for node, list in pairs(cells) do
    local l = {}
    for _, e in pairs(list) do table.insert(l, { e[1] / e[3], e[2] / e[3], e[3], learned = e.learned, nl = e.nl }) end
    out[node] = l
  end
  cellCache[map] = { t = GetTime(), cells = out }
  return out
end
B.ZoneCells = ZoneCells

-- alle Zonen mit Daten fuer Kraeuter und Erz
local function NodeZones()
  local z = {}
  local hot = ns.PROF_HOT_FOREVER or {}
  for map in pairs(hot) do z[map] = true end
  for _, kind in ipairs({ "Herb Gathering", "Mining" }) do
    for map in pairs(GMDB(kind) or {}) do if type(map) == "number" then z[map] = true end end
  end
  local db = DB()
  for map in pairs(db and db.prof.nodes or {}) do z[map] = true end
  return z
end

------------------------------------------------------------
-- Gefahr: starke Mobs und Elite Gebiete (aus den Questie Mob Daten, wie bei der Route)
------------------------------------------------------------
local dangerCache = {}
local function DangerAt(map, x, y)
  if not (ns.Dangers and map) then return nil end
  local dc = dangerCache[map]
  if not dc or GetTime() - dc.t > 10 then
    if ns.GrindList then pcall(ns.GrindList, map) end -- Zone auswerten lassen (laeuft im Hintergrund)
    local ok, list = pcall(ns.Dangers, map)
    dc = { t = GetTime(), list = ok and list or {} }
    dangerCache[map] = dc
  end
  local st
  for _, d in ipairs(dc.list) do
    if d.mob and d[1] and math.sqrt((d[1] - x) ^ 2 + (d[2] - y) ^ 2) <= (d[3] or 0.03) then
      if d.elite then return "elite" end
      st = "danger"
    end
  end
  return st
end
B.DangerAt = DangerAt

local function ZoneRange(map)
  local z = ns.zones and ns.zones[map]
  if z then return z.min or 1, z.max or 60 end
  return nil
end

------------------------------------------------------------
-- Mobs: Questie Daten, Drop Tabelle, Wildtiere
------------------------------------------------------------
local QDB, ZDB
local function Q()
  if not QDB and ns.QDBAccess then QDB, ZDB = ns.QDBAccess() end
  return QDB
end
local function N(id, k)
  if not Q() then return end
  local ok, v = pcall(QDB.QueryNPCSingle, id, k)
  if ok then return v end
end
local areaUi = {}
local function Ui(area)
  local u = areaUi[area]
  if u == nil then
    local ok, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
    u = (ok and ui) or false
    areaUi[area] = u
  end
  return u or nil
end
-- Spawns eines Mobs pro Zone: { [map] = { {x, y}, ... } }
local spawnCache = {}
local function MobSpawns(npc)
  local c = spawnCache[npc]
  if c ~= nil then return c end
  local out = {}
  local sp = N(npc, "spawns")
  for area, coords in pairs(type(sp) == "table" and sp or {}) do
    local ui = Ui(area)
    if ui and type(coords) == "table" then
      local l = out[ui] or {}
      for k, cc in ipairs(coords) do
        if k > 80 then break end
        if type(cc) == "table" and cc[1] and cc[1] > 0 then table.insert(l, { cc[1] / 100, cc[2] / 100 }) end
      end
      if #l > 0 then out[ui] = l end
    end
  end
  spawnCache[npc] = out
  return out
end
B.MobSpawns = MobSpawns

-- Drop Tabelle nach Item: [item] = { [npc] = Prozent }
local dropByItem
local function DropByItem()
  if dropByItem then return dropByItem end
  local by = ns.DropTable and ns.DropTable()
  if not by then return nil end
  dropByItem = {}
  for npc, list in pairs(by) do
    for _, d in ipairs(list) do
      if BYID[d[1]] then
        dropByItem[d[1]] = dropByItem[d[1]] or {}
        dropByItem[d[1]][npc] = d[2]
      end
    end
  end
  return dropByItem
end

local function AnimalOf(name)
  if type(name) ~= "string" then return nil end
  local low = name:lower()
  for key, words in pairs(ANIMALS) do
    for _, w in ipairs(words) do if low:find(w, 1, true) then return key end end
  end
end
B.AnimalOf = AnimalOf

-- Mob Index: alle feindlichen Mobs mit Level, Rang, Tierart (einmal im Hintergrund)
local mobIdx, mobBusy, mobWait = nil, false, {}
local jobQ, jobRun = {}, false
local function RunJobs()
  if jobRun then return end
  local j = table.remove(jobQ, 1)
  if not j then return end
  jobRun = true
  local co = coroutine.create(j.fn)
  local function Step()
    B.t0 = debugprofilestop and debugprofilestop() or nil
    B.cnt = 0
    local ok, err = coroutine.resume(co)
    if not ok then
      jobRun = false
      if ns.TestLog then ns.TestLog("FEHLER", "Berufe: " .. tostring(err)) end
      if j.done then pcall(j.done, nil, err) end
      C_Timer.After(0, RunJobs)
      return
    end
    if coroutine.status(co) == "dead" then
      jobRun = false
      if j.done then pcall(j.done, j.result) end
      C_Timer.After(0, RunJobs)
      return
    end
    C_Timer.After(0, Step)
  end
  Step()
end
local function Job(fn, done)
  local j = { done = done }
  j.fn = function() j.result = fn() end
  table.insert(jobQ, j)
  RunJobs()
end
-- im Job: dem Spiel Luft lassen (ca 8 ms pro Bild)
-- B.noYield > 0: gerade in einem pcall (Lua 5.1 kann dort nicht pausieren), also durchrechnen
local function Tick()
  if (B.noYield or 0) > 0 then return end
  local co, main = coroutine.running()
  if not co or main then return end
  B.cnt = (B.cnt or 0) + 1
  if B.t0 and debugprofilestop then
    if debugprofilestop() - B.t0 > ((InCombatLockdown and InCombatLockdown()) and 3 or 8) then coroutine.yield() end
  elseif B.cnt % 300 == 0 then
    coroutine.yield()
  end
end

local function BuildMobIndex()
  local idx = {}
  local db = DB()
  local ctype = db and db.prof.ctype or {}
  local loot = db and db.loot or {}
  local meatNpc = {}
  local dbi = DropByItem() or {}
  for _, it in ipairs(ITEMS.cook) do
    if it.animal then for npc in pairs(dbi[it.id] or {}) do meatNpc[npc] = true end end
  end
  for ui, list in pairs(ns.hostileIds or {}) do
    for _, id in ipairs(list) do
      if not idx[id] then
        Tick()
        local name = N(id, "name")
        local lo, hi = N(id, "minLevel") or 0, N(id, "maxLevel") or 0
        local rank = N(id, "rank") or 0
        local animal = AnimalOf(name)
        local beast
        if ctype[id] == 1 or (loot[id] and (loot[id].sk or 0) > 0) or meatNpc[id] then beast = true
        elseif ctype[id] == 0 then beast = false
        elseif animal then beast = true end
        idx[id] = { name = name or "?", lo = lo, hi = hi, rank = rank, zone = ui, animal = animal, beast = beast,
          learned = (ctype[id] ~= nil) or (loot[id] and (loot[id].sk or 0) > 0) or nil }
      end
    end
  end
  return idx
end
function ns.ProfMobIndex(cb)
  if mobIdx then if cb then cb(mobIdx) end return mobIdx end
  if not (ns.svcReady and Q()) then
    if ns.BuildSvcIndex then pcall(ns.BuildSvcIndex) end
    if cb then
      table.insert(mobWait, cb)
      if not B.waitTimer then
        B.waitTimer = true
        local tries = 0
        local function W()
          tries = tries + 1
          if ns.svcReady and Q() then B.waitTimer = nil; ns.ProfMobIndex() elseif tries < 30 then C_Timer.After(3, W) else B.waitTimer = nil end
        end
        C_Timer.After(3, W)
      end
    end
    return nil
  end
  if cb then table.insert(mobWait, cb) end
  if mobBusy then return nil end
  mobBusy = true
  Job(BuildMobIndex, function(res)
    -- Fehler oder leer (Questie noch nicht fertig): nicht fuer die ganze Sitzung merken, beim naechsten Mal neu
    local list = res or {}
    mobIdx = next(list) and list or nil
    mobBusy = false
    local w = mobWait; mobWait = {}
    for _, f in ipairs(w) do pcall(f, list) end
  end)
  return nil
end
function ns.ProfMobIndexReset() mobIdx = nil end

-- erwartete Stueck pro Kill eines Mobs fuer ein Item (0 = gibt es nicht)
local QTY = { cloth = 1.4, cook = 1.0, skin = 1.2 }
local function MobYield(it, npc, m)
  local db = ns.db
  local r = db and db.loot and db.loot[npc]
  -- Startwert aus cMaNGOS (Stoff pro Kill, Leder pro Kuerschnern)
  local cm = ns.CMNpc and ns.CMNpc(npc)
  local prior = cm and ((it.prof == "skin" and cm.s[it.id]) or (it.prof == "cloth" and cm.c[it.id])) or nil
  -- gelernt: echte Beute auf Forever, mit dem Startwert gemischt (ab 12 Kills zaehlt nur noch das Gelernte)
  if r then
    if it.prof == "skin" then
      if (r.sk or 0) >= 2 and r.si then
        local got = (r.si[it.id] or 0) / r.sk
        if prior then local w = math.min(1, r.sk / 12); return w * got + (1 - w) * prior, true end
        if r.si[it.id] then return got, true end
      end
    else
      local kills = math.max(r.k or 0, r.kc or 0)
      if kills >= 4 and r.it then
        local got = (r.it[it.id] or 0) / kills
        if prior then local w = math.min(1, kills / 12); return w * got + (1 - w) * prior, true end
        if r.it[it.id] then return got, true end
        if kills >= 12 and it.prof ~= "cloth" then return 0, true end
      end
    end
  end
  if prior then return prior end
  local dbi = DropByItem() or {}
  local pct = dbi[it.id] and dbi[it.id][npc]
  if pct then return pct / 100 * (QTY[it.prof] or 1) end
  if not m then return 0 end
  if it.prof == "skin" then
    if m.beast and m.hi >= it.lo and m.lo < it.hi then return QTY.skin end
    return 0
  end
  if it.prof == "cook" and it.animal and m.animal == it.animal and m.hi >= it.lo and m.lo <= it.hi then
    return 0.35
  end
  return 0
end
B.MobYield = MobYield

-- Mobs fuer ein Item: { [npc] = Stueck pro Kill }, nur normale Mobs (keine Elite)
local mobsForCache = {}
-- 20.2 (P3, Sascha: Haeuptling Spitzhauer in der endlosen Runde): ein Mob mit hoechstens 2 Fundorten insgesamt
-- (benannter Einzel Mob, langer Respawn) gehoert nicht in eine Farm Runde. Allgemein ueber die Spawn Zahl
local function FewSpawns(npc)
  local n = 0
  for _, l in pairs(MobSpawns(npc)) do n = n + #l; if n > 2 then return false end end
  return true
end
local function MobsFor(it, idx)
  local mc = mobsForCache[it.id]
  if mc and mc.idx == idx and GetTime() - mc.t < 30 then return mc.out end
  local out = {}
  mobsForCache[it.id] = { idx = idx, t = GetTime(), out = out }
  local dbi = DropByItem() or {}
  for npc in pairs(dbi[it.id] or {}) do
    local m = idx and idx[npc]
    if not (m and m.rank and m.rank > 0) then
      local y = MobYield(it, npc, m)
      if y > 0 and not FewSpawns(npc) then out[npc] = y end
    end
  end
  -- Mobs aus cMaNGOS, die Questie fuer dieses Item nicht kennt
  for npc in pairs(ns.CMNpcsWith and ns.CMNpcsWith(it.id) or {}) do
    -- nur Mobs, die das Addon als feindlich mit Fundorten kennt (Mob Index)
    local m = idx and idx[npc]
    if not out[npc] and m then
      if not (m.rank and m.rank > 0) then
        local y = MobYield(it, npc, m)
        if y > 0 and not FewSpawns(npc) then out[npc] = y end
      end
    end
  end
  if it.prof == "skin" or (it.prof == "cook" and it.animal) then
    for npc, m in pairs(idx or {}) do
      Tick()
      if not out[npc] and (m.rank or 0) == 0 then
        local y = MobYield(it, npc, m)
        if y > 0 and not FewSpawns(npc) then out[npc] = y end
      end
    end
  end
  -- gelernte Beute (Mobs, die die Drop Tabelle nicht kennt)
  local db = ns.db
  for npc, r in pairs(db and db.loot or {}) do
    if not out[npc] then
      local m = idx and idx[npc]
      if not (m and (m.rank or 0) > 0) then
        local y = MobYield(it, npc, m)
        if y > 0 and not FewSpawns(npc) then out[npc] = y end
      end
    end
  end
  return out
end
B.MobsFor = MobsFor

------------------------------------------------------------
-- Gebiete fuer eine Sache (Reiter Gebiete)
-- { map, name, lo, hi, n (Stellen), status ("ok", "danger", "elite"), learned }
------------------------------------------------------------
local areaCache = {}
local function NodeAreas(it)
  local out = {}
  local L = L0()
  for map in pairs(NodeZones()) do
    local cells = ZoneCells(map)
    local n, nd, ne, learned = 0, 0, 0, false
    for node in pairs(it.nodes) do
      for _, c in ipairs(cells[node] or {}) do
        n = n + c[3]
        if c.learned then learned = true end
        local st = DangerAt(map, c[1], c[2])
        if st == "elite" then ne = ne + c[3] elseif st == "danger" then nd = nd + c[3] end
      end
    end
    if n > 0 then
      local lo, hi = ZoneRange(map)
      local st = "ok"
      if ne > n * 0.4 then st = "elite" elseif nd > n * 0.4 or (lo and lo > L + 4) then st = "danger" end
      table.insert(out, { map = map, n = n, lo = lo, hi = hi, status = st, learned = learned })
    end
  end
  return out
end

local function MobAreas(it, idx)
  local out = {}
  local L = L0()
  local by = {}
  for npc, y in pairs(MobsFor(it, idx)) do
    Tick()
    local m = idx and idx[npc]
    for map, pts in pairs(MobSpawns(npc)) do
      local a = by[map]
      if not a then a = { map = map, n = 0, lo = 99, hi = 0, mobs = {}, learned = false }; by[map] = a end
      a.n = a.n + #pts
      a.mobs[npc] = #pts
      if m then a.lo = math.min(a.lo, m.lo); a.hi = math.max(a.hi, m.hi); if m.learned then a.learned = true end end
      if ns.db and ns.db.loot and ns.db.loot[npc] then a.learned = true end
    end
  end
  for _, a in pairs(by) do
    if a.lo == 99 then a.lo, a.hi = ZoneRange(a.map) end
    a.status = (a.hi and a.hi > L + 2) and "danger" or "ok"
    table.insert(out, a)
  end
  return out
end

local function FishAreas(it)
  local out = {}
  local db = DB()
  local L = L0()
  local tiers = {}
  for _, b in ipairs(it.tiers or {}) do tiers[b] = true end
  for map, base in pairs(FISH_ZONE) do
    local caught = db and db.prof.fishZone[map] and db.prof.fishZone[map][it.id]
    if tiers[base] or caught then
      local spots = 0
      for _, s in pairs(db and db.prof.fish[map] or {}) do spots = spots + 1 end
      local schools = 0
      if it.school then
        local t = GMDB("Fishing")
        for _, node in pairs(t and t[map] or {}) do if node == it.school then schools = schools + 1 end end
      end
      local lo, hi = ZoneRange(map)
      table.insert(out, { map = map, n = spots + schools, spots = spots, schools = schools, lo = lo, hi = hi,
        status = (lo and lo > L + 4) and "danger" or "ok", learned = caught and true or (spots > 0), need = FishNeed(base) })
    end
  end
  return out
end

-- Gebiete berechnen (Mobs brauchen den Index, darum mit Rueckruf)
function ns.ProfAreas(id, cb)
  local it = BYID[id]
  if not it then if cb then cb({}) end return {} end
  local key = id .. ":" .. L0()
  local c = areaCache[key]
  if c and GetTime() - c.t < 60 then if cb then cb(c.list) end return c.list end
  local function Done(list)
    -- Gebiet der anderen Fraktion markieren, kommt ans Ende
    for _, a in ipairs(list) do if ns.EnemyZone and ns.EnemyZone(a.map) then a.status = "enemy" end end
    -- Reihenfolge: passende zuerst, dann nach Anzahl Stellen
    local rank = { ok = 0, danger = 1, elite = 2, enemy = 3 }
    table.sort(list, function(a, b)
      if rank[a.status] ~= rank[b.status] then return rank[a.status] < rank[b.status] end
      return a.n > b.n
    end)
    areaCache[key] = { t = GetTime(), list = list }
    if cb then cb(list) end
    return list
  end
  local kind = PROF[it.prof].kind
  if kind == "node" then return Done(NodeAreas(it)) end
  if kind == "fish" then return Done(FishAreas(it)) end
  local idx = ns.ProfMobIndex(function(ix) Job(function() return MobAreas(it, ix) end, function(list) Done(list or {}) end) end)
  return nil
end
function ns.ProfAreasCached(id)
  local c = areaCache[id .. ":" .. L0()]
  return c and c.list
end

------------------------------------------------------------
-- Rezepte: AtlasLoot plus was deine Charaktere im Berufsfenster gesehen haben
------------------------------------------------------------
local PROF_NAMES = { [1] = TR"Erste Hilfe", [2] = TR"Schmiedekunst", [3] = TR"Lederverarbeitung", [4] = TR"Alchemie", [5] = TR"Kräuterkunde",
  [6] = TR"Kochkunst", [7] = TR"Bergbau", [8] = TR"Schneiderei", [9] = TR"Ingenieurskunst", [10] = TR"Verzauberkunst", [11] = TR"Angeln",
  [12] = TR"Kürschnerei", [13] = TR"Gifte" }
local function CharKey() return (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?") end
B.CharKey = CharKey

local ALMODS = { "AtlasLootContinued_Crafting", "AtlasLootClassic_Crafting", "AtlasLoot_Crafting" }
-- fremdes Addon kann alt oder kaputt sein: nur Tabellen anfassen (Sim 17.2: AtlasLoot.Data war eine Zahl)
local function Tbl(v) return type(v) == "table" and v or nil end
local function ALProf() local AL = Tbl(_G.AtlasLoot); local D = AL and Tbl(AL.Data); return AL, D and Tbl(D.Profession) end
local function ALStorage() local AL = Tbl(_G.AtlasLoot); local I = AL and Tbl(AL.ItemDB); return I and Tbl(I.Storage) end
function ns.HasAtlasLoot() local _, P = ALProf(); return P ~= nil end
local recipeIdx -- [reagent] = { { spell, created, prof, skill, count } }
local function LoadAL()
  local ST = ALStorage()
  if not ST then return end
  local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
  local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  for _, m in ipairs(ALMODS) do
    if not ST[m] and load and not (InCombatLockdown and InCombatLockdown()) then
      if not (isLoaded and isLoaded(m)) then pcall(load, m) end
    end
  end
end
local function BuildRecipes()
  local AL, P = ALProf()
  if not (P and type(P.GetProfessionData) == "function") then return {} end
  LoadAL()
  local idx = {}
  local seen = {}
  for _, m in ipairs(ALMODS) do
    local ST = ALStorage()
    local st = ST and ST[m]
    for _, content in pairs(type(st) == "table" and st or {}) do
      if type(content) == "table" and type(rawget(content, "items")) == "table" then
        for _, boss in ipairs(content.items) do
          for _, dif in pairs(type(boss) == "table" and boss or {}) do
            if type(dif) == "table" then
              for _, e in ipairs(dif) do
                local spell = type(e) == "table" and e[2]
                if type(spell) == "number" and not seen[spell] then
                  seen[spell] = true
                  Tick()
                  local ok, d = pcall(P.GetProfessionData, spell)
                  if ok and type(d) == "table" and type(d[6]) == "table" then
                    for i, rid in ipairs(d[6]) do
                      if BYID[rid] then
                        idx[rid] = idx[rid] or {}
                        table.insert(idx[rid], { spell = spell, created = d[1], prof = PROF_NAMES[d[2]] or "?", skill = d[3] or 0, count = (d[7] and d[7][i]) or 1 })
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  return idx
end
local recipeBusy, recipeWait = false, {}
function ns.ProfRecipeIndex(cb)
  if recipeIdx then if cb then cb(recipeIdx) end return recipeIdx end
  if cb then table.insert(recipeWait, cb) end
  if recipeBusy then return end
  recipeBusy = true
  Job(BuildRecipes, function(res)
    local list = res or {}
    -- leer (AtlasLoot noch nicht geladen, im Kampf uebersprungen): spaeter neu versuchen
    recipeIdx = next(list) and list or nil
    recipeBusy = false
    local w = recipeWait; recipeWait = {}
    for _, f in ipairs(w) do pcall(f, list) end
  end)
end

-- 19.31: fuer Hinweise und das Test Log, ohne neu zu rechnen
function ns.ProfRecipeIndexNow() return recipeIdx end
-- Rezepte fuer eine Sache: { { name, prof, skill, count, who = { "du", "Name" }, known } }
function ns.ProfRecipes(id)
  local out, byKey = {}, {}
  local db = DB()
  local me = CharKey()
  local function Who(created, name)
    local who, mine = {}, false
    for ck, list in pairs(db and db.recipes or {}) do
      for rn, r in pairs(list) do
        if (created and r.c == created) or rn == name then
          if ck == me then mine = true; table.insert(who, 1, TR"du") else table.insert(who, (ck:match("^([^%-]+)") or ck)) end
          break
        end
      end
    end
    return who, mine
  end
  for _, r in ipairs(recipeIdx and recipeIdx[id] or {}) do
    local name = (ns.Api.GetSpellInfo and ns.Api.GetSpellInfo(r.spell)) or (r.created and ns.Api.GetItemInfo(r.created)) or (TR"Rezept " .. r.spell)
    local who, mine = Who(r.created, name)
    local e = { name = name, prof = r.prof, skill = r.skill, count = r.count, who = who, known = mine, created = r.created }
    byKey[r.created or name] = e
    table.insert(out, e)
  end
  -- Rezepte aus dem Berufsfenster, die AtlasLoot nicht kennt
  for ck, list in pairs(db and db.recipes or {}) do
    for rn, r in pairs(list) do
      if r.r and r.r[id] then
        local e = byKey[r.c or rn]
        if not e then
          local who, mine = Who(r.c, rn)
          e = { name = rn, prof = r.p or "?", skill = r.s or 0, count = r.r[id], who = who, known = mine, created = r.c, learned = true }
          byKey[r.c or rn] = e
          table.insert(out, e)
        end
      end
    end
  end
  table.sort(out, function(a, b) if a.skill ~= b.skill then return a.skill < b.skill end return a.name < b.name end)
  return out
end

-- Berufsfenster lesen (alle Rezepte mit Zutaten) und accountweit merken
local function ReadTrade(craft)
  local db = DB()
  if not db then return end
  local me = CharKey()
  db.recipes[me] = db.recipes[me] or {}
  local list = db.recipes[me]
  local prof, num
  if craft then
    prof = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine() or (GetCraftName and GetCraftName())
    num = GetNumCrafts and GetNumCrafts() or 0
  else
    prof = GetTradeSkillLine and GetTradeSkillLine()
    num = GetNumTradeSkills and GetNumTradeSkills() or 0
  end
  for i = 1, (Plain(num) or 0) do
    local name, typ, _
    if craft then name, _, typ = GetCraftInfo(i) else name, typ = GetTradeSkillInfo(i) end
    if name and typ ~= "header" then
      local link = craft and (GetCraftItemLink and GetCraftItemLink(i)) or (not craft and GetTradeSkillItemLink and GetTradeSkillItemLink(i))
      local created = type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
      local reag = {}
      local nr = craft and (GetCraftNumReagents and GetCraftNumReagents(i)) or (not craft and GetTradeSkillNumReagents and GetTradeSkillNumReagents(i)) or 0
      for r = 1, (Plain(nr) or 0) do
        local rl = craft and (GetCraftReagentItemLink and GetCraftReagentItemLink(i, r)) or (not craft and GetTradeSkillReagentItemLink and GetTradeSkillReagentItemLink(i, r))
        local rid = type(rl) == "string" and tonumber(rl:match("item:(%d+)")) or nil
        local cnt
        if craft then cnt = select(3, GetCraftReagentInfo(i, r)) else cnt = select(3, GetTradeSkillReagentInfo(i, r)) end
        if rid then reag[rid] = Plain(cnt) or 1 end
      end
      list[name] = { c = created, r = reag, p = prof }
    end
  end
end

------------------------------------------------------------
-- Lernen: Kraeuter, Erz, Angelstellen, Wildtiere
------------------------------------------------------------
local BEAST = { ["Wildtier"] = true, ["Beast"] = true, ["Bête"] = true, ["Bestia"] = true }
local function NpcFromGUID(g)
  if type(g) ~= "string" then return end
  local t, _, _, _, _, id = strsplit("-", g)
  if t == "Creature" then return tonumber(id) end
end
local function LearnType(unit)
  if not (UnitExists and ns.Api.U(UnitExists, unit)) or (UnitIsPlayer and ns.Api.U(UnitIsPlayer, unit)) then return end
  local npc = NpcFromGUID(Plain(UnitGUID(unit)))
  if not npc then return end
  local db = DB()
  if not db then return end
  local ct = UnitCreatureType and UnitCreatureType(unit)
  if not ct then return end
  local v = BEAST[ct] and 1 or 0
  if db.prof.ctype[npc] ~= v then
    db.prof.ctype[npc] = v
    if mobIdx and mobIdx[npc] then mobIdx[npc].beast = (v == 1); mobIdx[npc].learned = true end
  end
end
local function PlayerPos()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local x, y = pos:GetXY()
  return map, x, y
end
local ITEM_NODE = {}
for _, it in ipairs(ITEMS.herb) do for n in pairs(it.nodes) do ITEM_NODE[it.id] = n end end
for _, it in ipairs(ITEMS.mine) do
  local best, bs
  for n, s in pairs(it.nodes) do if not bs or s < bs then best, bs = n, s end end
  ITEM_NODE[it.id] = best
end
local FISH_ID = {}
for _, it in ipairs(ITEMS.fish) do FISH_ID[it.id] = it end

local function LearnLoot()
  if not GetNumLootItems then return end
  local db = DB()
  if not db then return end
  local map, x, y = PlayerPos()
  if not map then return end
  local fishing = IsFishingLoot and IsFishingLoot()
  local num = Plain(GetNumLootItems()) or 0
  for slot = 1, num do
    local link = GetLootSlotLink and GetLootSlotLink(slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    if id then
      if fishing then
        local fx = FISH_ID[id]
        if fx then
          db.prof.fish[map] = db.prof.fish[map] or {}
          local key = math.floor(x / 0.02) * 100 + math.floor(y / 0.02)
          local s = db.prof.fish[map][key]
          if not s then s = { x = x, y = y, n = 0, items = {} }; db.prof.fish[map][key] = s end
          s.n = s.n + 1
          s.items[id] = (s.items[id] or 0) + 1
          db.prof.fishZone[map] = db.prof.fishZone[map] or {}
          db.prof.fishZone[map][id] = (db.prof.fishZone[map][id] or 0) + 1
        end
      else
        local node = ITEM_NODE[id]
        if node then
          -- nur wenn die Beute von einem Objekt kommt (Kraut oder Ader), nicht von einem Mob
          local fromObj = false
          local ok, src = pcall(function() return { GetLootSourceInfo(slot) } end)
          if ok and type(src) == "table" then
            for k = 1, #src, 2 do
              local g = src[k]
              if type(g) == "string" and g:find("^GameObject") then fromObj = true end
            end
          end
          if fromObj then
            db.prof.nodes[map] = db.prof.nodes[map] or {}
            local coord = math.floor(x * 10000 + 0.5) * 1e6 + math.floor(y * 10000 + 0.5) * 100.0
            -- in der Naehe schon bekannt? Dann nicht doppelt
            local near = false
            for c in pairs(db.prof.nodes[map]) do
              local cx, cy = Decode(c)
              if math.abs(cx - x) < 0.004 and math.abs(cy - y) < 0.004 then near = true; break end
            end
            if not near then db.prof.nodes[map][coord] = node; cellCache[map] = nil end
          end
        end
      end
    end
  end
end

local lf = CreateFrame("Frame")
lf:RegisterEvent("LOOT_OPENED")
lf:RegisterEvent("PLAYER_TARGET_CHANGED")
lf:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
lf:RegisterEvent("NAME_PLATE_UNIT_ADDED")
lf:RegisterEvent("TRADE_SKILL_SHOW")
lf:RegisterEvent("TRADE_SKILL_UPDATE")
lf:RegisterEvent("CRAFT_SHOW")
lf:RegisterEvent("CRAFT_UPDATE")
lf:RegisterEvent("PLAYER_LOGIN")
local tradeAt = 0
B.frame = lf
lf:SetScript("OnEvent", function(_, e, arg)
  if e == "LOOT_OPENED" then pcall(LearnLoot)
  elseif e == "PLAYER_TARGET_CHANGED" then pcall(LearnType, "target")
  elseif e == "UPDATE_MOUSEOVER_UNIT" then pcall(LearnType, "mouseover")
  elseif e == "NAME_PLATE_UNIT_ADDED" then if arg then pcall(LearnType, arg) end
  elseif e == "TRADE_SKILL_SHOW" or e == "TRADE_SKILL_UPDATE" or e == "CRAFT_SHOW" or e == "CRAFT_UPDATE" then
    -- nicht bei jedem Update, das Fenster feuert oft
    if GetTime() - tradeAt > 2 then
      tradeAt = GetTime()
      local craft = e:find("CRAFT") and true or false
      C_Timer.After(0.5, function() pcall(ReadTrade, craft) end)
    end
  elseif e == "PLAYER_LOGIN" then
    -- alte Zeitstempel aus der letzten Sitzung (GetTime faengt neu an)
    local db = ns.db
    for _, st in ipairs(db and db.opt and db.opt.prof and db.opt.steps or {}) do
      for _, a in ipairs(st.acts or {}) do a.arrive = nil end
    end
  end
end)

------------------------------------------------------------
-- Route planen
------------------------------------------------------------
local ACT_NODE = 0.12    -- Anteil der bekannten Stellen (Wowhead kennt alle moeglichen), an denen gerade etwas waechst
local ACT_LEARNED = 0.3  -- selber gesehene Stellen sind oefter besetzt
local PER_NODE = { herb = 1.6, mine = 2.0 }
local GATHER_SEC = 5     -- Absitzen, sammeln, weiter
local RESPAWN_MOB = 330
local MAX_PTS = 22

-- Welt Koordinaten (fuer Laengen)
local function W(map, x, y)
  if ns.MapWorld then return ns.MapWorld(map, x, y) end
  if not (C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
  local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x, y))
  if not ok or not w then return end
  local wx, wy = w:GetXY()
  return c, wx, wy
end

-- Runde: naechster Nachbar ab dem Punkt nahe beim Start, dann 2 opt
local function Tour(pts, sx, sy)
  if #pts <= 1 then return pts end
  local left = {}
  for i, p in ipairs(pts) do left[i] = p end
  local out = {}
  local cx, cy = sx or left[1].wx, sy or left[1].wy
  while #left > 0 do
    local bi, bd
    for i, p in ipairs(left) do
      local d = (p.wx - cx) ^ 2 + (p.wy - cy) ^ 2
      if not bd or d < bd then bi, bd = i, d end
    end
    local p = table.remove(left, bi)
    table.insert(out, p)
    cx, cy = p.wx, p.wy
  end
  local function D(a, b) return math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) end
  local n = #out
  local improved, guard = true, 0
  while improved and guard < 30 do
    improved = false; guard = guard + 1
    for i = 1, n - 2 do
      for j = i + 2, n do
        local a, b = out[i], out[i + 1]
        local c, d = out[j], out[j % n + 1]
        if d ~= a then
          local delta = D(a, c) + D(b, d) - D(a, b) - D(c, d)
          if delta < -1 then
            local l, r = i + 1, j
            while l < r do out[l], out[r] = out[r], out[l]; l = l + 1; r = r - 1 end
            improved = true
          end
        end
      end
    end
  end
  return out
end
local function TourLen(pts)
  local len = 0
  for i = 1, #pts do
    local a, b = pts[i], pts[i % #pts + 1]
    -- 19.24 (Sascha Teil 1 Punkt 4): Laufweg ueber das Netz wie in der Route (vorher Luftlinie mal 1.2)
    len = len + ((ns.WalkYards and ns.WalkYards(a, b)) or math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * 1.2)
  end
  return len
end

-- Punkte einer Zone fuer die gewaehlten Sachen
local function ZonePoints(map, sel, opt, idx)
  local pts = {}
  local value = 0  -- Stueck pro Runde (Schaetzung)
  local warn = {}
  local found = {}
  -- Kraeuter und Erz (gemischt in einer Runde)
  local cells = ZoneCells(map)
  local merge = {}
  for _, it in ipairs(sel.node) do
    local skill = opt.ignoreSkill and 999 or (ns.ProfSkill(it.prof) or 0)
    for node, need in pairs(it.nodes) do
      if skill >= need then
        for _, c in ipairs(cells[node] or {}) do
          local st = DangerAt(map, c[1], c[2])
          if not ((st == "elite" and opt.avoidElite) or (st and st ~= "elite" and opt.avoidDanger)) then
            local key = math.floor(c[1] / 0.06) * 100 + math.floor(c[2] / 0.06)
            local m = merge[key]
            if not m then m = { sx = 0, sy = 0, n = 0, names = {}, st = st, items = {} }; merge[key] = m end
            m.sx = m.sx + c[1] * c[3]; m.sy = m.sy + c[2] * c[3]; m.n = m.n + c[3]
            m.names[it.id] = true
            -- selbst gesehene Stellen hoeher gewichten, aber nur die, nicht die ganze Zelle
            local nl = math.min(c[3], c.nl or 0)
            m.items[it.prof] = (m.items[it.prof] or 0) + (c[3] - nl) * ACT_NODE + nl * ACT_LEARNED
            if st then m.st = st end
            found[it.id] = true
          end
        end
      end
    end
  end
  for _, m in pairs(merge) do
    local x, y = m.sx / m.n, m.sy / m.n
    local c, wx, wy = W(map, x, y)
    if wx then
      local per = 0
      for prof, n in pairs(m.items) do per = per + n * (PER_NODE[prof] or 1.5) end
      table.insert(pts, { map = map, x = x, y = y, wx = wx, wy = wy, cont = c, n = m.n, per = per, names = m.names, st = m.st, kind = "node" })
    end
  end
  -- Mobs (Stoff, Leder, Fleisch): Stellen mit vielen passenden Mobs
  if #sel.mob > 0 and idx then
    local L = L0()
    local mcells = {}
    local skinSkill = opt.ignoreSkill and 999 or (ns.ProfSkill("skin") or 0)
    -- erst pro Mob: Ausbeute aller gewaehlten Sachen zusammen (Leder und Fleisch vom selben Wolf zaehlen den Wolf einmal)
    local npcY, npcNames, npcLv = {}, {}, {}
    for _, it in ipairs(sel.mob) do
      for npc, y in pairs(MobsFor(it, idx)) do
        local m = idx[npc]
        -- Mob nicht im Index: Level und Rang direkt aus Questie
        local lo, hi = m and m.lo, m and m.hi
        if not lo then
          lo, hi = N(npc, "minLevel"), N(npc, "maxLevel")
          lo = tonumber(lo) or L; hi = tonumber(hi) or lo
          local rank = tonumber((N(npc, "rank"))) or 0
          if rank == 1 or rank == 2 or rank == 3 then lo, hi = nil, nil end -- Elite, seltene Elite, Boss: nicht solo farmen
        end
        if lo then
          local tooHigh = hi > L + 2
          -- Kuerschnern: nur Wildtiere, die dein Skill schafft
          local skinOk = it.prof ~= "skin" or SkinNeed(lo) <= skinSkill
          if skinOk and not (tooHigh and opt.avoidDanger) and not (hi > L + 5) then
            npcY[npc] = (npcY[npc] or 0) + y
            npcNames[npc] = npcNames[npc] or {}
            npcNames[npc][it.id] = true
            npcLv[npc] = { lo, hi }
          end
        end
      end
    end
    for npc, y in pairs(npcY) do
      local lv = npcLv[npc]
      for _, p in ipairs(MobSpawns(npc)[map] or {}) do
        local cx, cy = math.floor(p[1] / 0.05), math.floor(p[2] / 0.05)
        local key = cx * 100 + cy
        local mc = mcells[key]
        if not mc then mc = { cx = cx, cy = cy, sx = 0, sy = 0, n = 0, y = 0, names = {}, mobs = {}, hi = 0, lo = 99 }; mcells[key] = mc end
        mc.sx = mc.sx + p[1]; mc.sy = mc.sy + p[2]; mc.n = mc.n + 1
        mc.y = mc.y + y
        for id in pairs(npcNames[npc]) do mc.names[id] = true; found[id] = true end
        mc.mobs[npc] = (mc.mobs[npc] or 0) + 1
        mc.hi = math.max(mc.hi, lv[2]); mc.lo = math.min(mc.lo, lv[1])
      end
    end
    -- jede Zelle mit ihren Nachbarn zusammen (Mobs stehen selten genau in einer Zelle)
    local list = {}
    for _, mc in pairs(mcells) do
      local ag = { sx = 0, sy = 0, n = 0, y = 0, names = {}, mobs = {}, hi = 0, lo = 99, cx = mc.cx, cy = mc.cy }
      for dx = -1, 1 do
        for dy = -1, 1 do
          local o = mcells[(mc.cx + dx) * 100 + (mc.cy + dy)]
          if o then
            ag.sx = ag.sx + o.sx; ag.sy = ag.sy + o.sy; ag.n = ag.n + o.n; ag.y = ag.y + o.y
            for id in pairs(o.names) do ag.names[id] = true end
            for npc, c in pairs(o.mobs) do ag.mobs[npc] = (ag.mobs[npc] or 0) + c end
            ag.hi = math.max(ag.hi, o.hi); ag.lo = math.min(ag.lo, o.lo)
          end
        end
      end
      if ag.n >= 3 then table.insert(list, ag) end
    end
    table.sort(list, function(a, b) return a.y > b.y end)
    -- keine zwei Stellen direkt nebeneinander
    local picked = {}
    for _, ag in ipairs(list) do
      local near = false
      for _, o in ipairs(picked) do if math.abs(o.cx - ag.cx) <= 1 and math.abs(o.cy - ag.cy) <= 1 then near = true; break end end
      if not near then table.insert(picked, ag) end
    end
    list = picked
    for i, mc in ipairs(list) do
      if i > 6 then break end
      local x, y = mc.sx / mc.n, mc.sy / mc.n
      local st = DangerAt(map, x, y)
      if not ((st == "elite" and opt.avoidElite)) then
        local c, wx, wy = W(map, x, y)
        if wx then
          local diff = ((mc.hi + mc.lo) / 2) - L
          local ks = ns.KillSeconds and ns.KillSeconds(diff) or 25
          local kph = math.min(3600 / (ks + 12), mc.n * 3600 / RESPAWN_MOB)
          local perKill = mc.y / mc.n
          -- so lange bleiben, bis das Lager leer ist (grosses Lager laenger), dann weiter: die Runde kommt
          -- zurueck, wenn die Mobs wieder da sind. Mehr Kills pro Besuch als ein fester Halt von 2 Minuten.
          local kills = math.min(mc.n, 10)
          local dwell = math.max(60, math.min(300, (ks + 12) * kills))
          kills = math.min(kills, dwell / (ks + 12))
          local names = {}
          for npc, cnt in pairs(mc.mobs) do table.insert(names, { npc = npc, n = cnt, name = (idx[npc] and idx[npc].name) or N(npc, "name") or "?" }) end
          table.sort(names, function(a, b) return a.n > b.n end)
          table.insert(pts, { map = map, x = x, y = y, wx = wx, wy = wy, cont = c, n = mc.n, kind = "mob", dwell = dwell,
            perHour = kph * perKill, per = kills * perKill, names = mc.names, mobs = names, st = (mc.hi > L + 2) and "danger" or st, lo = mc.lo, hi = mc.hi })
        end
      end
    end
  end
  -- Fischschwaerme (GatherMate2)
  if #sel.fish > 0 and opt.fishMode == "school" then
    local t = GMDB("Fishing")
    local skill = ns.ProfSkill("fish") or 0
    local base = FISH_ZONE[map]
    if base and skill >= FishNeed(base) then
      local merge2 = {}
      for coord, node in pairs(t and t[map] or {}) do
        local fit = SCHOOL_ITEM[node]
        if fit then
          for _, it in ipairs(sel.fish) do
            if it.id == fit.id then
              local x, y = Decode(coord)
              local key = math.floor(x / 0.03) * 100 + math.floor(y / 0.03)
              if not merge2[key] then
                local c, wx, wy = W(map, x, y)
                if wx then
                  merge2[key] = true
                  table.insert(pts, { map = map, x = x, y = y, wx = wx, wy = wy, cont = c, n = 1, kind = "school", dwell = 50, per = 4 * 0.3,
                    names = { [it.id] = true } })
                  found[it.id] = true
                end
              end
            end
          end
        end
      end
    end
  end
  for _, p in ipairs(pts) do value = value + (p.per or 0) end
  return pts, value, found
end

B.ZonePoints = ZonePoints

-- nur die besten Punkte nehmen, Mob Stellen und Schwaerme behalten (sonst verdraengen viele Kraeuter sie)
function B.Trim(pts)
  table.sort(pts, function(a, b) return (a.per or 0) > (b.per or 0) end)
  local keep, rest = {}, {}
  local nm = 0
  for _, p in ipairs(pts) do
    if p.kind ~= "node" and nm < 6 then table.insert(keep, p); nm = nm + 1 else table.insert(rest, p) end
  end
  for _, p in ipairs(rest) do if #keep >= MAX_PTS then break end table.insert(keep, p) end
  return keep
end

-- Ufer aus den Wasser Feldern der Karte (Raster 80 x 80 wie bei den Wegen): ein Land Feld (kein Berg) direkt
-- neben Wasser. Gestanden wird am Rand zum Wasser hin. Bevorzugt grosse Wasserflaechen (See, Kueste),
-- kleine Pfuetzen und schmale Baeche zaehlen weniger.
local shoreCache = {}
-- 20.3y (S Test 17:02, Tanaris gewaehlt, Ziel Tanaris 0.061,0.306 = am Rand, Weg ueber Un'Goro): die Zonen Karte ist ein
-- Rechteck, am Rand liegt Wasser der Nachbarzone mit drin. Ufer nur, wo die Zone auch wirklich diese Zone ist
local function InZone(map, x, y)
  if not (C_Map and C_Map.GetMapInfo and C_Map.GetMapInfoAtPosition and ns.ToMap) then return true end
  local info = C_Map.GetMapInfo(map)
  local cont = info and info.parentMapID
  if not cont then return true end
  local cx, cy = ns.ToMap(map, x, y, cont)
  if not cx then return true end
  local zi = C_Map.GetMapInfoAtPosition(cont, cx, cy)
  local z = zi and zi.mapID
  if not z then return true end
  if z == map then return true end
  local zi2 = C_Map.GetMapInfo(z)
  return (zi2 and zi2.parentMapID == map) and true or false
end

local function ShoreSpots(map)
  local KF = ns.Felder and ns.Felder(map)
  local Wt = KF and KF.water
  if not (Wt and next(Wt)) then return {} end
  local c = shoreCache[map]
  if c and c.rev == (ns.blockRev or 0) then return c.list end
  local Bk = KF.block or {}
  local list = {}
  for k, v in pairs(Wt) do
    local cx, cy = k % 100, math.floor(k / 100)
    -- Wasser rundherum (5 x 5): Groesse der Wasserflaeche
    local wn = 0
    for dx = -2, 2 do for dy = -2, 2 do if Wt[(cy + dy) * 100 + cx + dx] then wn = wn + 1 end end end
    for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local nx, ny = cx + d[1], cy + d[2]
      if nx >= 0 and nx < 80 and ny >= 0 and ny < 80 then
        local nk = ny * 100 + nx
        -- 20.3q (Log 20.3m M3, Na 23:43: Ziel y 0.006 am Kartenrand): Ufer am Rand der Karte (unter 2 % oder ueber 98 %)
        -- ist meist nur der Raster Rand, nicht nehmen
        local ux, uy = (nx + 0.5 - d[1] * 0.35) / 80, (ny + 0.5 - d[2] * 0.35) / 80
        if not Wt[nk] and not Bk[nk] and ux > 0.02 and ux < 0.98 and uy > 0.02 and uy < 0.98 and InZone(map, ux, uy) then
          list[#list + 1] = { x = ux, y = uy, wn = wn, deep = v == 2 }
          break
        end
      end
    end
  end
  shoreCache[map] = { rev = ns.blockRev or 0, list = list }
  return list
end
B.ShoreSpots = ShoreSpots

-- Angeln Open World: beste Stelle (gelernt, sonst ein Ufer aus den Wasser Feldern der Karte,
-- sonst ein Flugpunkt in einer passenden Zone, sonst die Mitte)
local function FishSpot(sel, opt, lockerer)
  local db = DB()
  -- 20.3o (Log 20.3m M3 "da kommt man nicht hin", Na 23:30): Ufer aus den Wasser Feldern muss zu Fuss erreichbar sein
  -- (nicht Insel, Bucht, Klippe). Findet sich so keins, wie bisher das naechste (lockerer)
  local strict = not lockerer
  local skill = ns.ProfSkill("fish") or 0
  local pm, px, py = PlayerPos()
  local want = {}
  for _, it in ipairs(sel.fish) do want[it.id] = it end
  local zones = {}
  -- 20.3j (S Test 20.3g Punkt 13): eine Zone, die du selbst waehlst, gilt auch, wenn der Angel Skill noch nicht reicht
  -- (mit Hinweis). Ohne passende Zone sagt die Route warum (ns.profWhy) statt nur "keine Farmroute"
  local low, minNeed = nil, nil
  ns.profWhy = nil
  for map, base in pairs(FISH_ZONE) do
    local picked = next(opt.zones) and opt.zones[map]
    local fits = false
    for _, it in pairs(want) do
      for _, b in ipairs(it.tiers) do if b == base then fits = true end end
      if db.prof.fishZone[map] and db.prof.fishZone[map][it.id] then fits = true end
    end
    if fits and (not minNeed or FishNeed(base) < minNeed) then minNeed = FishNeed(base) end
    if (skill >= FishNeed(base) or picked) and (not next(opt.zones) or opt.zones[map]) then
      if fits then
        zones[map] = base
        if skill < FishNeed(base) then low = { map = map, need = FishNeed(base) } end
      end
    end
  end
  if not next(zones) then
    ns.profWhy = minNeed and (TR"Angel Skill %d, die gewählten Fische gibt es erst ab Skill %d. Wähle die Zone selbst, dann geht es trotzdem."):format(skill, minNeed)
      or TR"Für die gewählten Fische ist keine Zone bekannt."
  elseif low then
    ns.Print((TR"Hinweis: in %s braucht es Angel Skill %d, du hast %d. Du fängst dort vielleicht noch wenig."):format(ns.ZoneName and ns.ZoneName(low.map) or "?", low.need, skill))
  end
  local best, bd
  local function Try(map, x, y, learned, hint)
    local d = (pm and ns.WorldDist and ns.WorldDist({ pm, px, py }, { map, x, y })) or 1e6
    if strict and not learned and not hint and ns.Karte and ns.Karte.ReachPoint then
      local okR, rx = pcall(ns.Karte.ReachPoint, map, x, y)
      if okR and rx then return end
    end
    if learned then d = d * 0.6 end
    -- ohne bekannte Stelle und ohne Wasser der Karte nur, wenn sonst nichts in der Naehe ist
    if hint then d = d * 3 + 2000 end
    local st = DangerAt(map, x, y)
    if (st == "elite" and opt.avoidElite) or (st == "danger" and opt.avoidDanger) then return end
    if not bd or d < bd then best, bd = { map = map, x = x, y = y, learned = learned, hint = hint, st = st }, d end
  end
  for map in pairs(zones) do
    local any = false
    for _, s in pairs(db.prof.fish[map] or {}) do Try(map, s.x, s.y, true); any = true end
    if not any then
      -- Wasser der Karte: Ufer an grossen Wasserflaechen (mindestens 8 Wasser Felder rundherum)
      local shore = ShoreSpots(map)
      local big = {}
      for _, sp in ipairs(shore) do if sp.wn >= 8 then big[#big + 1] = sp end end
      if #big == 0 then big = shore end
      -- nicht jedes Ufer Feld pruefen: jedes n-te reicht (sonst viele Abstaende)
      local step = math.max(1, math.floor(#big / 60))
      for i = 1, #big, step do
        local sp = big[i]
        -- etwas naeher am Questgebiet als am Rand: Ufer nahe beim Spieler gewinnt (Try nimmt den kuerzesten Weg)
        Try(map, sp.x, sp.y, false, false)
        any = true
      end
    end
    if not any then
      local fp = false
      for _, f in ipairs(ns.KnownFlightMasters and ns.KnownFlightMasters() or {}) do
        if f.map == map then Try(map, f.x, f.y, false, true); fp = true end
      end
      if not fp then Try(map, 0.5, 0.5, false, true) end
    end
  end
  if not best and strict then return FishSpot(sel, opt, true) end
  return best
end

-- gewaehlte Sachen nach Art
local function Selected()
  local sel = { node = {}, mob = {}, fish = {}, all = {} }
  for id in pairs(ns.ProfSel().items) do
    local it = BYID[id]
    if it then
      local k = PROF[it.prof].kind
      table.insert(sel[k], it)
      table.insert(sel.all, it)
    end
  end
  return sel
end
B.Selected = Selected

-- Plan rechnen. opt: { mode = "count"/"time", amount, minutes, avoidElite, avoidDanger, fishMode = "open"/"school" }
-- Ergebnis: { steps, min, items, zones = { map }, missing = { Text }, title, loops }
function ns.ProfPlan(opt, cb)
  opt = opt or {}
  opt.zones = opt.zones or ns.ProfSel().zones
  local sel = Selected()
  if #sel.all == 0 then if cb then cb({ steps = {}, missing = { TR"Noch nichts angehakt." } }) end return end
  local function Calc(idx)
    local res = { steps = {}, missing = {}, zones = {}, items = 0, min = 0 }
    local pm, px, py = PlayerPos()
    local pc, pwx, pwy
    if pm then pc, pwx, pwy = W(pm, px, py) end
    local speed = (ns.PlanSpeed and ns.PlanSpeed()) or ns.speed or 7
    -- Endlos: eine Runde, die immer wieder von vorne laeuft (bewertet wie eine Stunde farmen)
    local endless = opt.mode == "loop"
    local target = (opt.mode == "count") and (opt.amount or 20) or (endless and 3600 or ((opt.minutes or 30) * 60))
    -- Kandidaten Zonen
    local zones = {}
    if next(opt.zones) then
      for map in pairs(opt.zones) do zones[map] = true end
    else
      if #sel.node > 0 then for map in pairs(NodeZones()) do zones[map] = true end end
      if #sel.mob > 0 and idx then
        for _, it in ipairs(sel.mob) do
          for npc in pairs(MobsFor(it, idx)) do for map in pairs(MobSpawns(npc)) do zones[map] = true end end
          Tick()
        end
      end
      if #sel.fish > 0 and opt.fishMode == "school" then for map in pairs(FISH_ZONE) do zones[map] = true end end
      -- nicht im Gebiet der anderen Fraktion (Wachen, weite Reise)
      if ns.EnemyZone then for map in pairs(zones) do if ns.EnemyZone(map) then zones[map] = nil end end end
    end
    -- eine Zone bewerten: Stueck pro Stunde, mit Anreise
    local Lme = L0()
    -- 19.24: Startpunkt der Anreise (deine Stelle, dann das Ende der letzten Runde) fuer den Weg ueber das Netz
    local fromPt = pm and { map = pm, x = px, y = py, cont = pc, wx = pwx, wy = pwy } or nil
    local function Eval(map, sub, fromX, fromY, fromC, later)
      local pts, value, found = ZonePoints(map, sub, opt, idx)
      if #pts == 0 or value <= 0 then return nil, found end
      -- Zone viel hoeher als du (Mobs auf dem Weg, Wachen): weit drueber gar nicht, etwas drueber nur wenn nichts anderes geht
      local zl = ns.zones and ns.zones[map]
      local zlPen = 1
      if opt.avoidDanger and zl and zl.min then
        if zl.min > Lme + 8 then return nil, found end
        if zl.min > Lme + 3 then zlPen = 0.4 end
      end
      pts = B.Trim(pts)
      -- was die Runde nach dem Kuerzen wirklich enthaelt (found sagt nur: gibt es in der Zone)
      local inRound = {}
      for _, p in ipairs(pts) do for id in pairs(p.names or {}) do inRound[id] = true end end
      local v = 0
      for _, p in ipairs(pts) do v = v + (p.per or 0) end
      local t = Tour(pts, fromX, fromY)
      local loopT = TourLen(t) / speed
      for _, p in ipairs(t) do loopT = loopT + (p.dwell or ((p.per or 0) / (PER_NODE.herb) * GATHER_SEC + 10)) end
      loopT = math.max(60, loopT)
      local perHour = v / loopT * 3600
      if loopT < 300 then perHour = perHour * loopT / 300 end -- Respawn: zu kurze Runde findet weniger
      local travel = 0
      local c1 = t[1] and t[1].cont
      if fromX and fromC and c1 == fromC then
        local wy = fromPt and fromPt.wx == fromX and fromPt.wy == fromY and ns.WalkYards and ns.WalkYards(fromPt, t[1])
        travel = (wy or math.sqrt((t[1].wx - fromX) ^ 2 + (t[1].wy - fromY) ^ 2) * 1.2) / speed
      elseif fromX then
        -- anderer Kontinent: Schiff oder Zeppelin hin und wieder zurueck
        travel = 1800
      end
      -- kurze Sitzung: fuer den Rest (zweite Zone) nicht auf einen anderen Kontinent
      if later and travel >= 1800 and opt.mode ~= "count" and target <= 7200 then return nil, found end
      local score
      if opt.mode == "count" then
        local work = target / math.max(1, perHour) * 3600
        score = perHour * work / (work + travel)
      else
        -- Zeit Modus: die Anreise geht von der Zeit ab (Stueck in der ganzen Zeit)
        score = perHour * math.max(target * 0.25, target - travel) / target
      end
      score = score * zlPen
      -- Zonen mit allen gewaehlten Sachen vorziehen (gemischte Runde)
      local want, cov = 0, 0
      for _, it in ipairs(sub.all) do want = want + 1; if inRound[it.id] then cov = cov + 1 end end
      if want > 0 then score = score * (0.2 + 0.8 * cov / want) end
      return { map = map, pts = t, loopT = loopT, perHour = perHour, travel = travel, score = score, found = inRound, cov = cov }, found
    end
    -- Abschnitte: erst die beste Zone, fehlt dort etwas, eine zweite (und dritte) Zone nur dafuer
    local segs = {}
    local foundAll = {}
    local rest = {}
    for _, it in ipairs(sel.all) do
      if PROF[it.prof].kind ~= "fish" or opt.fishMode == "school" then rest[it.id] = it end
    end
    local fx, fy, fc = pwx, pwy, pc
    for _ = 1, 3 do
      if not next(rest) then break end
      local sub = { node = {}, mob = {}, fish = {}, all = {} }
      for _, it in pairs(rest) do local k = PROF[it.prof].kind; table.insert(sub[k], it); table.insert(sub.all, it) end
      local bestSeg
      local all1 = {}
      for map in pairs(zones) do
        Tick()
        if not (#segs == 0 and opt.skip and opt.skip[map]) then
          local sg, found = Eval(map, sub, fx, fy, fc, #segs > 0)
          for id in pairs(found or {}) do foundAll[id] = true end
          if sg and (not bestSeg or sg.score > bestSeg.score) then bestSeg = sg end
          if sg and #segs == 0 then all1[#all1 + 1] = sg end
        end
      end
      -- andere gute Zonen fuer die erste Runde (Knopf "Andere Zone")
      if #segs == 0 then
        table.sort(all1, function(a, b) return a.score > b.score end)
        res.alts = {}
        for i2, sg in ipairs(all1) do if i2 <= 6 then res.alts[i2] = { map = sg.map, perHour = sg.perHour, score = sg.score } end end
      end
      if not bestSeg then break end
      -- weitere Zone nur fuer den Rest: lohnt sie sich kaum (weniger als ein Drittel der ersten), lieber weglassen
      if #segs > 0 and bestSeg.score < segs[1].score * 0.33 then
        for id, it in pairs(rest) do
          if bestSeg.found[id] then
            table.insert(res.missing, (TR"%s liegt in einer anderen Zone und lohnt sich in dieser Runde kaum, die Route lässt es weg."):format(ns.ProfItemName(it)))
            rest[id] = nil; foundAll[id] = nil
          end
        end
        break
      end
      bestSeg.items = {}
      for id in pairs(bestSeg.found) do if rest[id] then bestSeg.items[id] = true; rest[id] = nil end end
      if not next(bestSeg.items) then break end
      table.insert(segs, bestSeg)
      local last = bestSeg.pts[#bestSeg.pts]
      fx, fy, fc = last.wx, last.wy, last.cont
      fromPt = last
    end
    for id, it in pairs(rest) do
      if not foundAll[id] then
        table.insert(res.missing, (TR"%s gibt es in %s nicht."):format(ns.ProfItemName(it), next(opt.zones) and TR"deinen Gebieten" or TR"den bekannten Gebieten für dich"))
      else
        table.insert(res.missing, (TR"%s passt in keine Runde, die Route lässt es weg."):format(ns.ProfItemName(it)))
      end
    end
    local L = L0()
    local steps = {}
    local tsum = 0
    local function Push(p, act)
      table.insert(steps, { map = p.map, x = p.x, y = p.y, lvl = L, t = tsum, acts = { act } })
    end
    local function Names(set)
      local out = {}
      for id in pairs(set or {}) do table.insert(out, ns.ProfItemName(id)) end
      table.sort(out)
      return table.concat(out, ", ")
    end
    -- Anteil Angeln (Open World) an der Zeit
    local fishOpen = #sel.fish > 0 and opt.fishMode ~= "school"
    local loopShare = (fishOpen and #segs > 0) and 0.5 or 1
    -- Kreislauf: eine Zone ohne offenes Angeln wird eine Runde, die sich wiederholt (Na 01:15)
    local closed = endless or (#segs == 1 and not fishOpen)
    -- Zeit (oder Menge) auf die Abschnitte nach Anzahl Sachen verteilen
    local nItems = 0
    for _, sg in ipairs(segs) do for _ in pairs(sg.items) do nItems = nItems + 1 end end
    res.loops = 0
    local travelSum = 0
    for si, sg in ipairs(segs) do
      local k = 0
      for _ in pairs(sg.items) do k = k + 1 end
      local share = loopShare * k / math.max(1, nItems)
      local work
      -- Zeit Modus: Anreise zaehlt zur Zeit (eine Stunde ist eine Stunde mit Hin und Weg)
      if opt.mode == "count" then work = target * share / math.max(1, sg.perHour) * 3600 else work = math.max(300, target * share - sg.travel) end
      local loops = closed and 1 or math.max(1, math.min(12, math.ceil(work / sg.loopT)))
      res.loops = res.loops + loops
      for _ = 1, loops do
        for _, p in ipairs(sg.pts) do
          tsum = tsum + (p.dwell or GATHER_SEC * 2)
          local warnTxt
          if p.st == "elite" then warnTxt = TR"Elite in der Nähe" elseif p.st == "danger" then warnTxt = TR"starke Mobs" end
          local names = {}
          for id in pairs(p.names or {}) do if sg.items[id] then names[id] = true end end
          if not next(names) then names = p.names end
          if p.kind == "mob" then
            local mobNames = {}
            for i, m in ipairs(p.mobs or {}) do if i > 3 then break end table.insert(mobNames, m.name) end
            Push(p, { k = "P", mob = true, what = Names(names), mobs = table.concat(mobNames, ", "), lo = p.lo, hi = p.hi, dwell = p.dwell, r = 90, warn = warnTxt })
          elseif p.kind == "school" then
            Push(p, { k = "P", school = true, what = Names(names), dwell = p.dwell, r = 30, warn = warnTxt })
          else
            Push(p, { k = "P", gather = true, what = Names(names), r = 40, warn = warnTxt })
          end
        end
      end
      table.insert(res.zones, sg.map)
      res.items = res.items + math.floor(sg.perHour * (work / 3600) + 0.5)
      res.min = res.min + (sg.travel + work) / 60
      travelSum = travelSum + sg.travel
    end
    if fishOpen then
      local spot = FishSpot(sel, opt)
      if spot then
        local secs = (opt.mode == "count") and (target * (#segs > 0 and 0.5 or 1) / 120 * 3600) or (target * (#segs > 0 and 0.5 or 1))
        local names = {}
        for _, it in ipairs(sel.fish) do names[it.id] = true end
        tsum = tsum + secs
        Push(spot, { k = "P", fish = true, what = Names(names), dwell = secs, r = 40, hint = spot.hint, warn = spot.st == "danger" and TR"starke Mobs" or (spot.st == "elite" and TR"Elite in der Nähe" or nil) })
        table.insert(res.zones, spot.map)
        res.items = res.items + math.floor(secs / 3600 * 120 + 0.5)
        res.min = res.min + secs / 60
        if spot.hint then table.insert(res.missing, (TR"In %s kennt Keine Zeit Leveling Guide noch keine Angelstelle: dort eine Stelle am Wasser suchen."):format(ns.ZoneName and ns.ZoneName(spot.map) or "?")) end
      else
        table.insert(res.missing, TR"Für deinen Angel Skill passt keine Zone in deiner Auswahl.")
      end
    elseif #sel.fish > 0 and opt.fishMode == "school" and #segs == 0 then
      table.insert(res.missing, ns.HasGatherMate() and TR"Für deine Fische sind noch keine Schwärme bekannt." or TR"Schwärme kennt Keine Zeit Leveling Guide nur mit GatherMate2.")
    end
    res.steps = steps
    res.endless = endless or nil
    res.closed = closed or nil
    if endless and #segs > 1 then
      -- endlos: nur die erste Zone im Kreis (eine zweite Zone waere ein Hin und Her)
      local keepMap = segs[1].map
      local kept = {}
      for _, st in ipairs(steps) do if st.map == keepMap or (st.acts[1] and st.acts[1].fish) then kept[#kept + 1] = st end end
      res.steps = kept
      res.zones = { keepMap }
    end
    local first = sel.all[1]
    res.title = (TR"Farmen: %s%s"):format(ns.ProfItemName(first), #sel.all > 1 and (TR" und " .. (#sel.all - 1) .. TR" mehr") or "")
    res.opt = opt
    res.sel = sel
    return res
  end
  if #sel.mob > 0 then
    ns.ProfMobIndex(function(ix) Job(function() return Calc(ix) end, function(r) if cb then cb(r or { steps = {}, missing = { TR"Fehler beim Rechnen." } }) end end) end)
  else
    Job(function() return Calc(nil) end, function(r) if cb then cb(r or { steps = {}, missing = { TR"Fehler beim Rechnen." } }) end end)
  end
end

------------------------------------------------------------
-- Farmroute laufen lassen
------------------------------------------------------------
local function Count(id) return ns.Api.GetItemCount and (Plain(ns.Api.GetItemCount(id)) or 0) or 0 end
local function SessCount(s)
  local n = 0
  for id, c0 in pairs(s.start or {}) do n = n + math.max(0, Count(id) - c0) end
  return n
end
local function SessDone(s)
  if not s then return true end
  if s.mode == "loop" then return false end
  if s.mode == "count" then return SessCount(s) >= (s.amount or 0) end
  return Now() - (s.t0 or 0) >= (s.secs or 0)
end

function ns.ProfStart(res)
  if not (res and res.steps and #res.steps > 0) then ns.Print(TR"Keine Farmroute gefunden." .. (ns.profWhy and (" " .. ns.profWhy) or "")); return end
  local db = ns.db
  local s = { t0 = Now(), mode = res.opt.mode, amount = res.opt.amount, secs = (res.opt.minutes or 30) * 60, start = {}, title = res.title }
  for _, it in ipairs(res.sel.all) do s.start[it.id] = Count(it.id) end
  -- Gold Mobs oder Ruf Mobs liefen noch: damit beendet
  ns.farmSess, ns.repFarm = nil, nil
  db.profSess = s
  -- 20.3y: Einstellungen merken, damit "Neu rechnen" die Farm Route neu rechnen kann
  if res.opt then local c = {}; for k, v in pairs(res.opt) do c[k] = v end; db.profLastOpt = c end
  if ns.OptLoad then ns.OptLoad(res.steps, { title = res.title, target = L0(), prof = true, loop = (res.endless or res.closed) or nil }) end
  db.opt.prof = true
  db.opt.loop = (res.endless or res.closed) or nil
  ns.profPreview = nil
  if ns.FarmActive and ns.FarmActive() and ns.FarmStop then ns.farmSess = nil end
  if ns.Draw then ns.Draw() end
end

function ns.ProfSession()
  local db = ns.db
  local s = db and db.profSess
  if not s then return nil end
  if not (db.opt and db.opt.prof) then db.profSess = nil; return nil end
  return s
end

function ns.ProfActDone(a)
  local s = ns.ProfSession()
  if not s then return true end
  if SessDone(s) then return true end
  local map, x, y = PlayerPos()
  local st = ns.db.opt and ns.db.opt.steps[ns.db.opt.idx or 1]
  local cur = false
  for _, b in ipairs(st and st.acts or {}) do if b == a then cur = true end end
  if not cur then return false end
  local d = map and ns.WorldDist and ns.WorldDist({ map, x, y }, { st.map, st.x, st.y })
  if a.dwell then
    if a.arrive and a.arrive > GetTime() then a.arrive = nil end
    if not a.arrive then
      if d and d < (a.r or 80) then a.arrive = GetTime() end
      return false
    end
    return GetTime() - a.arrive >= a.dwell
  end
  return d ~= nil and d < (a.r or 40)
end

function ns.ProfActText(a, plainName)
  local col = "|cff66ff99"
  local t
  if a.fish then
    t = (TR"%sAngeln:|r %s%s"):format(col, a.what or TR"Fische", a.hint and TR" |cff9d9d9d(such dir hier eine Stelle am Wasser)|r" or "")
  elseif a.school then
    t = (TR"%sSchwarm abfischen:|r %s"):format(col, a.what or TR"Fische")
  elseif a.mob then
    t = (TR"%sFarmen:|r %s bei %s%s"):format(col, a.what or "?", a.mobs or TR"Mobs", a.lo and (TR" (Lvl %d bis %d)"):format(a.lo, a.hi or a.lo) or "")
  else
    t = (TR"%sSammeln:|r %s"):format(col, a.what or "?")
  end
  if a.warn then t = t .. " |cffff5050(" .. a.warn .. ")|r" end
  if plainName then t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
  return t
end

-- Zeile im Mini Fenster
function ns.ProfHudLine()
  local s = ns.ProfSession()
  if not s then return nil end
  local got = SessCount(s)
  local min = math.floor((Now() - (s.t0 or 0)) / 60)
  local rd = (s.round and s.round > 1) and (TR", Runde %d"):format(s.round) or ""
  if s.mode == "count" then return (TR"Farmen: %d von %d Stück, %d Min"):format(got, s.amount or 0, min) .. rd end
  if s.mode == "loop" then return (TR"Farmen: %d Stück in %d Min, Runde %d (endlos)"):format(got, min, s.round or 1) end
  return (TR"Farmen: %d Stück, %d von %d Min"):format(got, min, math.floor((s.secs or 0) / 60)) .. rd
end

-- Endlos Runde: am Ende wieder von vorne (true), solange die Sitzung laeuft
function ns.ProfLoopAgain(opt)
  local s = ns.ProfSession()
  if not (s and not SessDone(s) and opt and opt.prof and opt.loop and #(opt.steps or {}) > 0) then return false end
  for _, st in ipairs(opt.steps) do for _, a in ipairs(st.acts or {}) do a.arrive = nil end end
  opt.idx = 1
  s.round = (s.round or 1) + 1
  ns.Print((TR"Runde %d: wieder von vorne, die Stellen sind inzwischen nachgewachsen."):format(s.round))
  return true
end

-- Route zu Ende: kurze Bilanz, dann zurueck zum Leveln
function ns.ProfFinish()
  local db = ns.db
  local s = db and db.profSess
  if s then
    ns.Print((TR"Farmroute fertig: %d Stück in %d Min."):format(SessCount(s), math.floor((Now() - (s.t0 or 0)) / 60 + 0.5)))
  end
  if db then db.profSess = nil end
end

-- Pfeil zum besten Gebiet einer Sache
function ns.ProfArrowBest(id)
  local list = ns.ProfAreasCached(id) or ns.ProfAreas(id)
  local a = list and list[1]
  if not a then ns.Print(TR"Noch kein Gebiet bekannt."); return end
  local it = BYID[id]
  local x, y = 0.5, 0.5
  if it and it.nodes then
    local cells = ZoneCells(a.map)
    local bn
    for node in pairs(it.nodes) do for _, c in ipairs(cells[node] or {}) do if not bn or c[3] > bn then bn, x, y = c[3], c[1], c[2] end end end
  end
  local nm = ns.ProfItemName(it or id) .. ": " .. (ns.ZoneName and ns.ZoneName(a.map) or "?")
  if ns.ZielNavi then ns.ZielNavi(a.map, x, y, nm, "prof")
  else ns.serviceTarget = { map = a.map, x = x, y = y, name = nm, kind = "prof" }; if ns.Draw then ns.Draw() end end
  ns.Print(TR"Pfeil zeigt zum besten Gebiet: " .. (ns.ZoneName and ns.ZoneName(a.map) or "?"))
end

------------------------------------------------------------
-- Gold Berufe: grobe Schaetzung Gold pro Stunde pro Farmstelle
------------------------------------------------------------
function ns.ProfGoldList(cb)
  local function Calc(idx)
    local out = {}
    local L = L0()
    local speed = (ns.PlanSpeed and ns.PlanSpeed()) or ns.speed or 7
    -- Lua 5.1: in einem pcall darf der Job nicht pausieren. Darum nur die kurzen Teile im pcall (ohne Pause),
    -- die Schleife ueber die Gebiete draussen (dort pausiert Tick).
    local function Safe(fn, ...)
      B.noYield = (B.noYield or 0) + 1
      local r = { pcall(fn, ...) }
      B.noYield = B.noYield - 1
      return (unpack or table.unpack)(r)
    end
    local function Prep(it)
      local price = ns.ItemValue and ns.ItemValue(it.id) or 0
      if price <= 0 then return end
      local can, miss, none = ns.ProfCan(it)
      local sel = { node = {}, mob = {}, fish = {}, all = { it } }
      local kind = PROF[it.prof].kind
      if kind == "fish" then return end
      table.insert(sel[kind], it)
      local zones = {}
      if kind == "node" then
        for map in pairs(NodeZones()) do zones[map] = true end
      elseif idx then
        for npc in pairs(MobsFor(it, idx)) do for map in pairs(MobSpawns(npc)) do zones[map] = true end end
      end
      if ns.EnemyZone then for map in pairs(zones) do if ns.EnemyZone(map) then zones[map] = nil end end end
      return { price = price, can = can, miss = miss, none = none, sel = sel, zones = zones }
    end
    local function Eval(it)
      local okP, pr = Safe(Prep, it)
      if not (okP and pr) then return end
      local price, can, miss, none, sel, zones = pr.price, pr.can, pr.miss, pr.none, pr.sel, pr.zones
      local best
      for map in pairs(zones) do
        Tick()
        -- auch ohne Skill rechnen (Spalte Skill sagt dann "fehlt")
        local ok, pts, value = Safe(ZonePoints, map, sel, { avoidElite = true, avoidDanger = false, zones = {}, ignoreSkill = true }, idx)
        if ok and #pts > 0 then
          pts = B.Trim(pts)
          local v = 0
          for _, p in ipairs(pts) do v = v + (p.per or 0) end
          local t = Tour(pts)
          local loopT = TourLen(t) / speed
          for _, p in ipairs(t) do loopT = loopT + (p.dwell or ((p.per or 0) / (PER_NODE.herb) * GATHER_SEC + 10)) end
          loopT = math.max(60, loopT)
          local ph = v / loopT * 3600
          if loopT < 300 then ph = ph * loopT / 300 end
          local danger = false
          for _, p in ipairs(t) do if p.st then danger = true end end
          if not best or ph > best.ph then best = { map = map, ph = ph, danger = danger } end
        end
      end
      if best then
        table.insert(out, { id = it.id, prof = it.prof, map = best.map, perHour = best.ph, gph = best.ph * price, price = price,
          can = can, miss = miss, none = none, danger = best.danger })
      end
    end
    for _, key in ipairs({ "herb", "mine", "skin", "cloth" }) do
      for _, it in ipairs(ITEMS[key]) do
        -- nur was zum Level passt: Stoff und Leder nach Mob Level, Kraeuter und Erz bis Skill plus 50
        local ok = true
        if it.prof == "skin" then ok = it.lo <= L + 2
        elseif it.prof == "herb" or it.prof == "mine" then
          -- Kraeuter und Erz bis Skill plus 50 (ohne Beruf grob nach Level), sonst steht Schwarzer Lotus bei Level 20 da
          local sk = (ns.ProfSkill and ns.ProfSkill(it.prof)) or 0
          ok = (it.skill or 1) <= math.max(sk + 50, L * 5)
        end
        if ok then Eval(it) end
      end
    end
    table.sort(out, function(a, b) if a.can ~= b.can then return a.can end return a.gph > b.gph end)
    return out
  end
  ns.itemInfoMissing = 0
  ns.ProfMobIndex(function(ix) Job(function() return Calc(ix) end, function(r)
    ns.profGold = r or {}; ns.profGoldAt = GetTime()
    -- Preise fehlten (Items noch nicht im Spiel Cache, gleich nach dem Einloggen): bald nochmal rechnen, hoechstens 3 mal
    if (ns.itemInfoMissing or 0) > 0 and (B.goldRetry or 0) < 3 then
      B.goldRetry = (B.goldRetry or 0) + 1
      C_Timer.After(5, function() ns.profGold = nil; if ns.RefreshBig then pcall(ns.RefreshBig) end end)
    else
      B.goldRetry = 0
    end
    if cb then cb(ns.profGold) end
  end) end)
end

-- Route fuer eine Zeile von Gold Berufe: nur diese Sache, nur dieses Gebiet, 30 Minuten
function ns.ProfGoldRoute(row)
  if not row then return end
  local s = ns.ProfSel()
  local oldI, oldZ = s.items, s.zones
  s.items = { [row.id] = true }; s.zones = { [row.map] = true }
  local zones = s.zones
  -- die Auswahl wird beim Start des Plans gelesen: gleich wieder zuruecksetzen, deine Haken bleiben
  local ok = pcall(ns.ProfPlan, { mode = "time", minutes = 30, avoidElite = true, avoidDanger = false, zones = zones }, function(res)
    if res and res.steps and #res.steps > 0 then ns.ProfStart(res) else ns.Print(TR"Für diese Stelle gibt es gerade keine Route.") end
  end)
  s.items, s.zones = oldI, oldZ
  if not ok then ns.Print(TR"Für diese Stelle gibt es gerade keine Route.") end
end

-- fuer Tests
B.IS_FOREVER = IS_FOREVER
B.FISH_ZONE = FISH_ZONE
B.FishNeed = FishNeed
B.SessDone = SessDone
B.SessCount = SessCount
