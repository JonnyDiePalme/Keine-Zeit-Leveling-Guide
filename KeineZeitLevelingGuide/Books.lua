local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Bibliotheksbuecher auf Forever: liegen in der Welt, aufheben, in Unterstadt (Horde) oder Sturmwind (Allianz) abgeben.
-- Belohnungen ab 10, 20 und 25 Buechern. Orte nach den Forever Guides (Method, Warcraft Tavern).
-- Eingesammelt wird erkannt: du warst am Ort und hast gleich danach etwas aufgehoben. Von Hand abhaken geht auch.

-- tier: ab welchem Level sinnvoll, dungeon: liegt in einem Dungeon, side: nur fuer diese Fraktion gut erreichbar
-- name: englischer Item Name aus dem Spiel, absichtlich ohne TR (englischer Client vergleicht ihn mit Beute und Taschen)
ns.BOOKS = {
  { id = "theocritus", name = "Archmage Theocritus's Research Journal", map = 1429, x = 0.654, y = 0.701, tier = 1, side = "Alliance", note = TR"Turm von Azora, 3. Stock" },
  { id = "bewitch", name = "Bewitchments and Glamours", map = 1436, x = 0.454, y = 0.705, tier = 1, side = "Alliance", note = TR"Mondbruch, erstes Haus von Osten" },
  { id = "rumi", name = "Rumi of Gnomeregan: The Collected Works", map = 1436, x = 0.527, y = 0.538, tier = 1, side = "Alliance", note = TR"Gasthaus Späherkuppe, gleiches Buch wie Loch Modan" },
  { id = "rumi", name = "Rumi of Gnomeregan: The Collected Works", map = 1432, x = 0.356, y = 0.489, tier = 1, side = "Alliance", note = TR"Gasthaus Thelsamar, oben" },
  { id = "anatomy", name = "Crimes Against Anatomy", map = 1431, x = 0.167, y = 0.285, tier = 1, note = TR"Gruft am Rabenhügel, unterirdisch" },
  { id = "sorcerer", name = "Runes of the Sorcerer-Kings", map = 1432, x = 0.775, y = 0.141, tier = 1, note = TR"Ogerhöhle, linker Weg" },
  { id = "goaz", name = "Goaz Scrolls", map = 1437, x = 0.336, y = 0.479, tier = 1, note = TR"Grabungsstätte, untere Ebene" },
  { id = "antonidas", name = "Archmage Antonidas: The Unabridged Autobiography", map = 1455, x = 0.757, y = 0.105, tier = 1, side = "Alliance", note = TR"Halle der Forscher" },
  { id = "apothecary", name = "The Apothecary's Metaphysical Primer", map = 1420, x = 0.594, y = 0.523, tier = 1, side = "Horde", note = TR"Brill, Alchemieladen" },
  { id = "dalaran", name = "The Dalaran Digest, Vol. 23", map = 1421, x = 0.635, y = 0.631, tier = 1, note = TR"Ambermühle" },
  { id = "arcanic", name = "Arcanic Systems Manual", map = 1413, x = 0.563, y = 0.088, tier = 1, note = TR"oben auf der Bohrinsel" },
  { id = "baxtan", name = "Baxtan: On Destructive Magics", map = 1413, x = 0.627, y = 0.363, tier = 1, note = TR"Ingenieursgebäude" },
  { id = "dreamers", name = "Secrets of the Dreamers", map = 1413, x = 0.460, y = 0.365, tier = 1, note = TR"Höhle der Nebel, nicht im Dungeon" },
  { id = "narthalas", name = "Nar'thalas Almanac, Vol. 74", map = 1439, x = 0.596, y = 0.222, tier = 1, note = TR"Treppe in den Ruinen" },
  { id = "fury", name = "Fury of the Land", map = 1442, x = 0.744, y = 0.857, tier = 1, note = TR"Zelt beim grossen Totem" },
  { id = "tazo", name = "The Lessons of Ta'zo", map = 1454, x = 0.386, y = 0.784, tier = 1, side = "Horde", note = TR"Tafel in der Darkbriar Hütte" },
  { id = "basilisk", name = "Basilisks: Should Petrification be Feared?", map = 1434, x = 0.413, y = 0.509, tier = 30, note = TR"vor der Basiliskenhöhle, Weg beginnt bei 37.1, 48.8" },
  { id = "geomancy", name = "Geomancy: The Stone-Cold Truth", map = 1441, x = 0.344, y = 0.400, tier = 30, note = TR"Hütte am Grimmtotem Hügel, Weg ab 31.9, 38.5" },
  { id = "defensive", name = "Defensive Magics 101", map = 1416, x = 0.484, y = 0.575, tier = 30, note = TR"Ogerturm, Oger Level 40 als Wache" },
  { id = "rwl", name = "RwlRwlRwlRwl!", map = 1445, x = 0.571, y = 0.208, tier = 30, note = TR"Ofen im Murloc Lager" },
  { id = "web", name = "A Web of Lies: Debunking Myths and Legends", map = 1417, x = 0.736, y = 0.652, tier = 30, note = TR"Hütte im Dorf der Witherbork" },
  { id = "demons", name = "Demons and You", map = 1443, x = 0.551, y = 0.262, tier = 30, note = TR"Donneraxtfestung, innerer Ring" },
  { id = "mummies", name = "Mummies: A Guide to the Unsavory Undead", map = 1418, x = 0.567, y = 0.397, tier = 30, note = TR"Gruft hinter dem Zwergenlager" },
  { id = "necro", name = "Necromancy 101", map = 1422, x = 0.6918, y = 0.7227, tier = 40, dungeon = true, note = TR"Scholomance, oben (Dungeon)" },
  { id = "potatoes", name = "Undead Potatoes", map = 1422, x = 0.3826, y = 0.5462, tier = 40, note = TR"2. Stock im Haus bei der Scheune, ein Mob bewacht es" },
  { id = "light", name = "A Study of the Light", map = 1423, x = 0.718, y = 0.482, tier = 40, note = TR"Kapelle des Hoffnungsvollen Lichts" },
  { id = "knight", name = "The Knight and the Lady", map = 1423, x = 0.473, y = 0.423, tier = 40, note = TR"abgebranntes Haus am See, Fledermäuse stören" },
  { id = "scourge", name = "Scourge: Undead Menace or Misunderstood?", map = 1423, x = 0.266, y = 0.145, tier = 40, note = TR"Zonenseite der Brücke beim Dungeon" },
  { id = "sanguine", name = "Sanguine Sorcery", map = 1435, x = 0.702, y = 0.519, tier = 40, dungeon = true, note = TR"Dungeon Atal'Hakkar, oben" },
  { id = "venom", name = "Venomous Journeys", map = 1425, x = 0.358, y = 0.725, tier = 40, note = TR"erste Pyramide links" },
  { id = "northern", name = "Northern Kalimdor - A Comprehensive Guide", map = 1448, x = 0.651, y = 0.032, tier = 40, note = TR"Höhle der Holzschlundfeste, links der Brücke" },
  { id = "kaboom", name = "Ka-Boom!", map = 1452, x = 0.604, y = 0.374, tier = 40, note = TR"Ewige Warte" },
  { id = "stonewrought", name = "Stonewrought Design", map = 1428, x = 0.311, y = 0.301, tier = 40, brm = true, note = TR"Schwarzfels: Franclorns Grab, beim Versammlungsstein" },
  { id = "magma", name = "Magma or Lava?", map = 1428, x = 0.311, y = 0.301, tier = 40, brm = true, note = TR"Schwarzfels: hinter Lothos Riftwaker, vor den Tiefen" },
  { id = "mindmetal", name = "A Mind of Metal", map = 1427, x = 0.381, y = 0.498, tier = 40, note = TR"Zelt neben einem Dunkeleisenzwerg" },
  { id = "etiquette", name = "Everyday Etiquette", map = 1447, x = 0.204, y = 0.623, tier = 40, note = TR"nördlich vom Flugpunkt, vor den Ruinen" },
  { id = "tidesages", name = "Legends of the Tidesages", map = 1446, x = 0.726, y = 0.475, tier = 40, note = TR"Bucht der Verlorenen Takelage, mittleres der drei Häuser" },
}
ns.BOOK_TURNIN = {
  Horde = { map = 1458, x = 0.740, y = 0.325, name = TR"Owen Thadd (Unterstadt, Magieviertel)" },
  Alliance = { map = 1453, x = 0.490, y = 0.863, name = TR"Garion Wendell (Sturmwind, Magierturm)" },
}
-- Forever: Era Punkte auf die neuen Karten (Oestliche Pestlaender, Sturmwind)
if ns.EraXY then
  for _, b in ipairs(ns.BOOKS) do b.x, b.y = ns.EraXY(b.map, b.x, b.y) end
  for _, t in pairs(ns.BOOK_TURNIN) do t.x, t.y = ns.EraXY(t.map, t.x, t.y) end
end

local function DB()
  local db = ns.db
  if not db then return end
  db.booksDone = db.booksDone or {}
  return db
end

function ns.BookDone(id) local db = DB(); return db and db.booksDone[id] and true or false end
function ns.BookToggle(id)
  local db = DB(); if not db then return end
  db.booksDone[id] = not db.booksDone[id] or nil
  if ns.DrawBooks then ns.DrawBooks() end
end

-- Buecher, die du jetzt holen kannst: nicht erledigt, Level passt, kein Dungeon, keine gegnerische Hauptstadt
function ns.OpenBooks(includeDungeon)
  local L = UnitLevel("player")
  local side = UnitFactionGroup and UnitFactionGroup("player")
  local out, seen = {}, {}
  -- doppelte (Rumi): nur einmal, der Ort naeher bei dir
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local me = pos and { map, pos:GetXY() }
  local function Dist(b)
    local d = me and ns.WorldDist and ns.WorldDist(me, { b.map, b.x, b.y })
    return d or math.huge
  end
  for _, b in ipairs(ns.BOOKS) do
    if not ns.BookDone(b.id) and (not b.side or b.side == side) then
      local zmin = (ns.zones and ns.zones[b.map] and ns.zones[b.map].min) or 1
      local need = math.max(b.tier or 1, zmin - 2)
      if (includeDungeon or not b.dungeon) and L >= need then
        local k = seen[b.id]
        if not k then
          table.insert(out, b)
          seen[b.id] = #out
        elseif Dist(b) < Dist(out[k]) then
          out[k] = b
        end
      end
    end
  end
  return out
end

-- offene Buecher in der Naehe (gleicher Kontinent, bis yd Yards, ohne Dungeon und ohne andere Fraktion)
function ns.BookNearCount(yd)
  yd = yd or 2500
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not (pos and ns.WorldDist) then return 0 end
  local px, py = pos:GetXY()
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local n, seen = 0, {}
  for _, b in ipairs(ns.BOOKS) do
    if not ns.BookDone(b.id) and not seen[b.id] and not b.dungeon and not (b.side and b.side ~= fac) then
      local d = ns.WorldDist({ map, px, py }, { b.map, b.x, b.y })
      if d and d <= yd then seen[b.id] = true; n = n + 1 end
    end
  end
  return n
end
function ns.BookCount()
  local n, ids = 0, {}
  for _, b in ipairs(ns.BOOKS) do if ns.BookDone(b.id) and not ids[b.id] then ids[b.id] = true; n = n + 1 end end
  local total = {}
  for _, b in ipairs(ns.BOOKS) do total[b.id] = true end
  local t = 0
  for _ in pairs(total) do t = t + 1 end
  return n, t
end

------------------------------------------------------------
-- Erkennen, dass du ein Buch aufgehoben hast
------------------------------------------------------------
local near
local function Tick()
  local db = DB()
  if not db or not ns.WorldDist then return end
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  px, py = ns.Plain and ns.Plain(px) or px, ns.Plain and ns.Plain(py) or py
  if not (px and py) then return end
  if db.books == false then return end
  local cp = ns.cityParent or {}
  for _, b in ipairs(ns.BOOKS) do
    -- nur Buecher in deiner Zone (30 Yards), spart die Weltumrechnung fuer alle anderen
    if not db.booksDone[b.id] and (b.map == map or cp[b.map] == map or cp[map] == b.map) then
      local d = ns.WorldDist({ map, px, py }, { b.map, b.x, b.y })
      if d and d < 30 then near = { book = b, t = GetTime() } end
    end
  end
end
if C_Timer and C_Timer.NewTicker then ns.Ticker(1, function() pcall(Tick) end) end

-- Beute aus einem Gegenstand (Buch liegt als Objekt in der Welt), nicht von einem Mob daneben
local objLoot -- { items = { [itemID] = true }, t }
local lf = CreateFrame("Frame")
lf:RegisterEvent("CHAT_MSG_LOOT")
lf:RegisterEvent("LOOT_OPENED")
lf:SetScript("OnEvent", function(_, event, msg)
  if event == "LOOT_OPENED" then
    objLoot = nil
    if not (near and GetTime() - near.t < 15) or not (GetNumLootItems and GetLootSourceInfo and GetLootSlotLink) then return end
    local items = {}
    for i = 1, GetNumLootItems() do
      local guid = GetLootSourceInfo(i)
      guid = ns.Plain and ns.Plain(guid) or guid
      local link = GetLootSlotLink(i)
      local id = link and tonumber(link:match("item:(%d+)"))
      if id and type(guid) == "string" and guid:find("^GameObject") then items[id] = true end
    end
    if next(items) then objLoot = { items = items, t = GetTime() } end
    return
  end
  if not (near and GetTime() - near.t < 15) then return end
  msg = ns.Plain and ns.Plain(msg) or msg
  if type(msg) ~= "string" then return end
  -- nur eigene Beute (die Vorlage fuer "Ihr bekommt Beute" beginnt so)
  local mine = LOOT_ITEM_SELF and msg:find((LOOT_ITEM_SELF:gsub("%%s.*", "")), 1, true) == 1
  if LOOT_ITEM_SELF and not mine then return end
  local db = DB()
  if not db then return end
  -- das Buch selbst muss in der Beute stehen: aus einem Objekt, oder der Name passt (englischer Client)
  local id = tonumber(msg:match("item:(%d+)"))
  local nm = msg:match("%[(.-)%]")
  local byObj = id and objLoot and GetTime() - objLoot.t < 15 and objLoot.items[id]
  local byName = nm and nm:lower() == near.book.name:lower()
  local known = id and db.bookItems and db.bookItems[id] == near.book.id
  local canCheck = GetLootSourceInfo ~= nil
  if canCheck and not (byObj or byName or known) then return end
  if id then db.bookItems = db.bookItems or {}; db.bookItems[id] = near.book.id end
  db.booksDone[near.book.id] = true
  ns.Print((TR"Buch eingesammelt: %s. Abgeben bei %s."):format(near.book.name,
    (ns.BOOK_TURNIN[UnitFactionGroup("player")] or {}).name or TR"der Bibliothek"))
  near = nil
  if ns.RefreshBig then ns.RefreshBig() end
end)

------------------------------------------------------------
-- Tour zu allen offenen Buechern
------------------------------------------------------------
-- Wichtigkeit: wie viel Umweg ein Buch auf der normalen Route wert ist
-- Umweg pro Buch: Standard 600 Yards, unter Einstellungen frei einstellbar (in beiden Modi)
ns.BOOK_YARDS_DEFAULT = 600
function ns.BookYards()
  local db = ns.db
  if db and tonumber(db.bookYards) then
    return math.max(50, math.min(5000, tonumber(db.bookYards)))
  end
  return ns.BOOK_YARDS_DEFAULT
end
function ns.SetBookYards(v)
  local db = ns.db
  v = tonumber(v)
  if not db or not v then return end
  db.bookYards = math.max(50, math.min(5000, math.floor(v)))
  ns.Print((TR"Bücher Umweg: %d Yards pro Buch. Gilt ab der nächsten Berechnung der Route."):format(db.bookYards))
end
-- alte Schnittstelle: liefert den Wert als Tabelle
function ns.BookPrio()
  local yd = ns.BookYards()
  local std = yd == ns.BOOK_YARDS_DEFAULT
  return { key = std and "low" or "custom", yd = yd, text = (TR"%d Yards%s"):format(yd, std and TR" (Standard)" or "") }
end
-- Knopf auf der Bücher Seite: springt zur Einstellung (Einstellungen sind nie gesperrt)
function ns.BookPrioToggle()
  if ns.db and not ns.Expert() then ns.db.allSettings = true end
  if ns.ShowBig then ns.ShowBig("set") end
  local pg = ns.BigJPage and ns.BigJPage("set")
  if pg and pg.Pick then pg.Pick(TR"Tempo") end
  ns.Print(TR"Bücher Umweg stellst du unter Einstellungen, Bereich Tempo, ein.")
end

-- fuer die eigene Buecher Route: abgewaehlte Buecher
-- Standard: alles angehakt ausser Dungeon Buecher
local function IsDungeonBook(id)
  for _, b in ipairs(ns.BOOKS) do if b.id == id and b.dungeon then return true end end
  return false
end
function ns.BookPicked(id)
  local db = ns.db
  local v = db and db.bookPick and db.bookPick[id]
  if v == nil then return not IsDungeonBook(id) end
  return v
end
function ns.BookPickToggle(id)
  local db = ns.db; if not db then return end
  db.bookPick = db.bookPick or {}
  db.bookPick[id] = not ns.BookPicked(id)
end

function ns.TourBooks(onlyPicked)
  local list = ns.OpenBooks(onlyPicked and true or false)
  if onlyPicked then
    local f = {}
    for _, b in ipairs(list) do if ns.BookPicked(b.id) then table.insert(f, b) end end
    list = f
  end
  if #list == 0 then ns.Print(onlyPicked and TR"Keine Bücher ausgewählt." or TR"Keine offenen Bücher für dein Level."); return end
  local pts = {}
  for _, b in ipairs(list) do
    table.insert(pts, { map = b.map, x = b.x, y = b.y, dur = 20, act = { k = "K", book = b.id, quest = b.name, name = b.name, note = b.note } })
  end
  if ns.TourPoints then ns.TourPoints(onlyPicked and TR"Bücher (Auswahl)" or TR"Alle Bücher", pts, onlyPicked and "TourBooksPicked" or "TourBooks") end
end
function ns.TourBooksPicked() ns.TourBooks(true) end

function ns.BookLines(b)
  local out = {}
  local n, t = ns.BookCount()
  table.insert(out, (TR"|cffffd100Bibliotheksbücher:|r %d von %d eingesammelt"):format(n, t))
  local ti = ns.BOOK_TURNIN[UnitFactionGroup and UnitFactionGroup("player") or "Horde"]
  if ti then table.insert(out, TR"Abgeben bei " .. ti.name) end
  table.insert(out, TR"Belohnungen: 10 Bücher (Halskette), 20 Bücher ab Level 20 (Ring), 25 Bücher ab Level 30 (Bogen, Schild oder Nebenhand)")
  table.insert(out, TR"|cffff9030Bücher nicht löschen, man kann sie nicht nochmal aufheben.|r")
  table.insert(out, (TR"Wichtigkeit auf der normalen Route: |cffffffff%s|r Umweg pro Buch"):format(ns.BookPrio().text))
  table.insert(out, TR"|cff9d9d9dEingesammelt erkennt Keine Zeit Leveling Guide selbst: am Fundort aufgehoben oder in deinen Taschen. Bücher Route führt zu allen offenen Büchern ausser denen in Dungeons.|r")
  table.insert(out, "")
  if b then
    table.insert(out, ("|cffffd100%s|r"):format(b.name))
    table.insert(out, ("%s  %.1f, %.1f"):format(ns.ZoneName and ns.ZoneName(b.map) or "?", b.x * 100, b.y * 100))
    if b.note then table.insert(out, b.note) end
    table.insert(out, (TR"Ab etwa Level %d%s"):format(b.tier or 1, b.dungeon and TR", liegt in einem Dungeon" or ""))
    table.insert(out, ns.BookDone(b.id) and TR"|cff40ff40Eingesammelt|r" or TR"|cffffd100Noch offen|r")
  else
    table.insert(out, TR"Links ein Buch anklicken. Grüner Haken = schon eingesammelt.")
  end
  table.insert(out, "")
  table.insert(out, TR"|cff9d9d9dOrte aus den Forever Guides. Ist ein Ort falsch, sag Bescheid.|r")
  return out
end

------------------------------------------------------------
-- Buecher auf der Weltkarte: Symbol pro offenem Buch, Tooltip mit Ort und was zu tun ist
------------------------------------------------------------
local pinLayer, bookPins = nil, {}

-- Punkt einer Karte auf eine andere umrechnen (z.B. Zone auf Kontinent)
local function ToMap(fromMap, x, y, toMap)
  if fromMap == toMap then return x, y end
  if ns.MapToMap then return ns.MapToMap(fromMap, x, y, toMap) end
  if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetMapPosFromWorldPos and CreateVector2D) then return end
  local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, fromMap, CreateVector2D(x, y))
  if not ok or not cont or not world then return end
  local ok2, _, pos = pcall(C_Map.GetMapPosFromWorldPos, cont, world, toMap)
  if not ok2 or not pos then return end
  local u, v = pos:GetXY()
  if not u or u < 0 or u > 1 or v < 0 or v > 1 then return end
  return u, v
end

local function PinTooltip(self)
  local b = self.book
  if not b then return end
  ns.TipOwner(self, "ANCHOR_RIGHT")
  GameTooltip:AddLine(b.name, 1, 0.82, 0)
  GameTooltip:AddLine(ns.ZoneName and ns.ZoneName(b.map) or "", 0.7, 0.7, 0.7)
  if b.note then GameTooltip:AddLine(TR"Wo: " .. b.note, 1, 1, 1, true) end
  local t = ns.BOOK_TURNIN and ns.BOOK_TURNIN[UnitFactionGroup("player")]
  GameTooltip:AddLine((TR"Aufheben und bei %s abgeben."):format(t and t.name or TR"der Bibliothek"), 1, 1, 1, true)
  if b.dungeon then GameTooltip:AddLine(TR"Liegt in einem Dungeon.", 1, 0.3, 0.3, true) end
  if (b.tier or 1) > (UnitLevel("player") or 1) then GameTooltip:AddLine(TR"Gebiet ist für dein Level noch schwer.", 1, 0.6, 0.2, true) end
  GameTooltip:AddLine(TR"Klick: Pfeil hin", 0.5, 0.8, 1)
  GameTooltip:Show()
end

function ns.DrawBookPins()
  for _, p in ipairs(bookPins) do p:Hide() end
  local db = ns.db
  if not db or db.mapBooks == false or not WorldMapFrame or not WorldMapFrame:IsShown() then return end
  if ns.Unlocked and not ns.Unlocked("books") then return end
  local canvas = WorldMapFrame:GetCanvas()
  if not pinLayer then
    pinLayer = CreateFrame("Frame", nil, canvas)
    pinLayer:SetAllPoints(canvas)
    pinLayer:SetFrameStrata(WorldMapFrame:GetFrameStrata())
    pinLayer:SetFrameLevel(9050)
  end
  local mapID = WorldMapFrame:GetMapID()
  if not mapID then return end
  local w, h = pinLayer:GetWidth(), pinLayer:GetHeight()
  local side = UnitFactionGroup("player")
  -- Pins sollen auf der Karte gleich gross bleiben, egal wie weit gezoomt
  local scale = (canvas.GetScale and canvas:GetScale()) or 1
  local size = 22 / math.max(0.2, scale)
  local n = 0
  local seen = {}
  for _, b in ipairs(ns.BOOKS or {}) do
    if not ns.BookDone(b.id) and (not b.side or b.side == side) then
      local x, y = ToMap(b.map, b.x, b.y, mapID)
      local key = b.id .. ":" .. b.map
      if x and not seen[key] then
        seen[key] = true
        n = n + 1
        local p = bookPins[n]
        if not p then
          p = CreateFrame("Button", nil, pinLayer)
          -- dunkler Rand, damit das Symbol auf jeder Karte gut sichtbar ist
          p.bg = p:CreateTexture(nil, "BACKGROUND")
          p.bg:SetPoint("TOPLEFT", -2, 2); p.bg:SetPoint("BOTTOMRIGHT", 2, -2)
          p.bg:SetColorTexture(0, 0, 0, 0.85)
          p.icon = p:CreateTexture(nil, "ARTWORK")
          local T = ns.T
          if T and T.IsElv() and T.PinTex and T.PinTex(p.icon, "book") then
            -- ElvUI: flaches Buch aus dem Punkte Atlas, ohne Kasten
            p.icon:SetAllPoints()
            p.bg:Hide()
          else
            -- Classic: rundes Buch Symbol mit Goldring wie die Minimap Knoepfe
            p.classic = true
            p.bg:Hide()
            p.round = p:CreateTexture(nil, "BACKGROUND")
            p.round:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
            p.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
            if p.icon.SetMask then pcall(p.icon.SetMask, p.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
            p.ring = p:CreateTexture(nil, "OVERLAY")
            p.ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
          end
          local hl = p:CreateTexture(nil, "HIGHLIGHT")
          hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.25)
          p:SetScript("OnEnter", PinTooltip)
          p:SetScript("OnLeave", function() GameTooltip:Hide() end)
          p:SetScript("OnClick", function(self)
            local bk = self.book
            if not bk then return end
            ns.serviceTarget = { map = bk.map, x = bk.x, y = bk.y, name = TR"Buch: " .. bk.name, kind = "book" }
            ns.Print(TR"Pfeil zeigt zum Buch: " .. bk.name)
            if ns.Draw then ns.Draw() end
          end)
          bookPins[n] = p
        end
        p.book = b
        if p.classic then
          -- Masse wie ein Minimap Knopf (31 px), auf die Pin Groesse skaliert
          local sz = math.floor(size * 1.5 + 0.5)
          local k = sz / 31
          p:SetSize(sz, sz)
          p.round:ClearAllPoints(); p.round:SetSize(20 * k, 20 * k); p.round:SetPoint("TOPLEFT", 7 * k, -5 * k)
          p.icon:ClearAllPoints(); p.icon:SetSize(18 * k, 18 * k); p.icon:SetPoint("TOPLEFT", 6.5 * k, -5.5 * k)
          p.ring:ClearAllPoints(); p.ring:SetSize(53 * k, 53 * k); p.ring:SetPoint("TOPLEFT", 0, 0)
        else
          p:SetSize(size, size)
        end
        p.icon:SetVertexColor(b.dungeon and 1 or 1, b.dungeon and 0.5 or 1, b.dungeon and 0.5 or 1)
        p:ClearAllPoints()
        p:SetPoint("CENTER", pinLayer, "TOPLEFT", x * w, -y * h)
        p:Show()
      end
    end
  end
end

do
  local bf = CreateFrame("Frame")
  bf:RegisterEvent("PLAYER_ENTERING_WORLD")
  bf:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    if not WorldMapFrame then return end
    WorldMapFrame:HookScript("OnShow", function() C_Timer.After(0, ns.DrawBookPins) end)
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", function() ns.DrawBookPins() end) end
    if WorldMapFrame.ScrollContainer then
      WorldMapFrame.ScrollContainer:HookScript("OnSizeChanged", function() ns.DrawBookPins() end)
    end
  end)
end

ns.DrawBooks = ns.DrawBookPins


-- Buch in den Taschen? Dann gilt es als eingesammelt (ohne Haken setzen zu muessen)
do
  local byName = {}
  for _, b in ipairs(ns.BOOKS) do byName[b.name:lower()] = b.id end
  local function Scan()
    local db = DB()
    if not db then return end
    local nslots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local info = C_Container and C_Container.GetContainerItemInfo
    if not nslots then return end
    local changed = false
    for bag = 0, 4 do
      for slot = 1, (nslots(bag) or 0) do
        local link
        if info then local i = info(bag, slot); link = i and i.hyperlink
        elseif ns.Api.GetContainerItemLink then link = ns.Api.GetContainerItemLink(bag, slot) end
        local nm = link and link:match("%[(.-)%]")
        local iid = link and tonumber(link:match("item:(%d+)"))
        -- gelernte Item IDs (deutscher Client: andere Namen), sonst der englische Name
        local id = (iid and db.bookItems and db.bookItems[iid]) or (nm and byName[nm:lower()])
        if id and not db.booksDone[id] then db.booksDone[id] = true; changed = true end
      end
    end
    if changed and ns.RefreshBig then ns.RefreshBig() end
  end
  local bf = CreateFrame("Frame")
  bf:RegisterEvent("BAG_UPDATE_DELAYED")
  bf:RegisterEvent("PLAYER_LOGIN")
  bf:SetScript("OnEvent", function() C_Timer.After(1, Scan) end)
end
