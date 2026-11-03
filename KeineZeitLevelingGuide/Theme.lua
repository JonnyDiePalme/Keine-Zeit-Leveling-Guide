local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Look System: Classic UI (Blizzard Rahmen, rote Knoepfe, Gold Schrift)
-- oder ElvUI (graue Flaechen, schwarzer Pixel Rand, ElvUI Wertfarbe).
-- Alle Fenster des Addons bauen ihre Teile hier, damit beide Looks ueberall gleich sind.

local T = {}
ns.T = T

local E, S
local function LoadElv()
  if ElvUI and not E then
    local ok, e = pcall(unpack, ElvUI)
    if ok and type(e) == "table" then
      E = e
      local ok2, s = pcall(E.GetModule, E, "Skins", true)
      if ok2 then S = s end
    end
  end
  return E
end

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
T.MEDIA = MEDIA

-- welcher Look: "auto" nimmt ElvUI, wenn es da ist
function T.IsElv()
  local pref = ns.db and ns.db.look or "auto"
  if pref == "classic" then return false end
  return LoadElv() ~= nil
end
function T.ElvLoaded() return LoadElv() ~= nil end

-- Akzentfarbe: ElvUI Wertfarbe (folgt deiner ElvUI Einstellung) oder Blizzard Gold
function T.Acc()
  if T.IsElv() then
    local c = E and E.media and E.media.rgbvaluecolor
    if type(c) == "table" then
      if c.r then return c.r, c.g, c.b end
      if c[1] then return c[1], c[2], c[3] end
    end
    return 0.09, 0.52, 0.82
  end
  return 1, 0.82, 0
end
function T.AccHex()
  local r, g, b = T.Acc()
  return ("%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end
function T.AccT() local r, g, b = T.Acc(); return { r, g, b } end
function T.C(text) return TR"|cff" .. T.AccHex() .. text .. "|r" end

-- Ueberschrift im Text: Classic gelb wie Blizzard, ElvUI in der Wertfarbe und gross geschrieben
function T.Section(text)
  if T.IsElv() then return TR"|cff" .. T.AccHex() .. text:upper() .. "|r" end
  return "|cffffd100" .. text .. "|r"
end

function T.BarTexture()
  if T.IsElv() and E and E.media and E.media.normTex then return E.media.normTex end
  return "Interface\\TargetingFrame\\UI-StatusBar"
end

local BD = BackdropTemplateMixin and "BackdropTemplate" or nil
T.BD = BD

------------------------------------------------------------
-- Flaechen
------------------------------------------------------------
local CL = {
  window = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } },
  inset = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } },
  tooltip = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } },
  thin = { bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 },
}

-- kind: "window", "inset", "sel" (ausgewaehlt), "lock" (gesperrt), "tooltip", "thin"
function T.Skin(f, kind, alpha)
  kind = kind or "inset"
  if T.IsElv() and f.SetTemplate then
    local tpl = (kind == "window" or kind == "tooltip") and "Transparent" or "Default"
    if pcall(f.SetTemplate, f, tpl) then
      if kind == "sel" then
        local r, g, b = T.Acc(); f:SetBackdropBorderColor(r, g, b, 1)
      elseif kind == "lock" then
        f:SetBackdropColor(0.08, 0.08, 0.08, 0.6); f:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
      elseif kind == "window" and f.GetBackdropColor then
        -- grosse Fenster nicht zu durchsichtig, sonst stoert die Welt dahinter beim Lesen
        local r, g, b, a = f:GetBackdropColor()
        if r and (a or 1) < 0.92 then f:SetBackdropColor(r, g, b, 0.92) end
        -- ElvUI setzt Transparent spaeter wieder auf seinen Wert: fester Grund darunter
        local solid = rawget(f, "fwSolid")
        if not solid and f.CreateTexture then
          solid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
          solid:SetPoint("TOPLEFT", 1, -1)
          solid:SetPoint("BOTTOMRIGHT", -1, 1)
          f.fwSolid = solid
        end
        if solid then solid:SetColorTexture(0.06, 0.06, 0.06, 0.94) end
      end
      f.fwKind = kind
      return "elv"
    end
  end
  if not f.SetBackdrop then return end
  -- Classic: fester Grund unter dem Blizzard Hintergrund, sonst scheint die Welt durch
  if kind == "window" or kind == "tooltip" or kind == "inset" or kind == "sel" or kind == "lock" then
    if not rawget(f, "fwSolid") then
      f.fwSolid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    end
    local ins = (kind == "window") and 11 or 3
    f.fwSolid:ClearAllPoints()
    f.fwSolid:SetPoint("TOPLEFT", ins, -ins); f.fwSolid:SetPoint("BOTTOMRIGHT", -ins, ins)
    if kind == "window" then f.fwSolid:SetColorTexture(0.05, 0.045, 0.04, 0.9)
    elseif kind == "tooltip" then f.fwSolid:SetColorTexture(0.02, 0.02, 0.04, 0.9)
    else f.fwSolid:SetColorTexture(0.03, 0.03, 0.03, 0.55) end
    f.fwSolid:Show()
  end
  local bd = CL[kind] or CL.inset
  if kind == "sel" or kind == "lock" then bd = CL.inset end
  f:SetBackdrop(bd)
  if kind == "window" then
    f:SetBackdropColor(1, 1, 1, alpha or 1)
    f:SetBackdropBorderColor(1, 1, 1, 1)
  elseif kind == "tooltip" then
    f:SetBackdropColor(0.02, 0.02, 0.07, alpha or 0.95)
    f:SetBackdropBorderColor(0.75, 0.75, 0.75, 1)
  elseif kind == "thin" then
    f:SetBackdropColor(0, 0, 0, alpha or 0.6)
    f:SetBackdropBorderColor(0, 0, 0, 1)
  elseif kind == "sel" then
    f:SetBackdropColor(0.22, 0.16, 0.02, alpha or 0.8)
    f:SetBackdropBorderColor(1, 0.82, 0, 1)
  elseif kind == "lock" then
    f:SetBackdropColor(0, 0, 0, alpha or 0.4)
    f:SetBackdropBorderColor(0.35, 0.3, 0.22, 0.8)
  else
    f:SetBackdropColor(0, 0, 0, alpha or 0.75)
    f:SetBackdropBorderColor(0.6, 0.5, 0.3, 1) -- goldbrauner Rand wie die Blizzard Kaesten
  end
  f.fwKind = kind
  return "classic"
end

-- Zustand wechseln (normal, ausgewaehlt, gesperrt), ohne neu zu bauen
function T.SetState(f, kind)
  if f.fwKind == kind then return end
  T.Skin(f, kind)
end

function T.Panel(parent, kind)
  local f = CreateFrame("Frame", nil, parent, BD)
  T.Skin(f, kind or "inset")
  return f
end

------------------------------------------------------------
-- Logo
------------------------------------------------------------
function T.Logo(parent, size)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size or 32, size or 32)
  if T.IsElv() then
    local base = f:CreateTexture(nil, "ARTWORK", nil, 1)
    base:SetAllPoints(); base:SetTexture(MEDIA .. "LogoElvBase")
    local acc = f:CreateTexture(nil, "ARTWORK", nil, 2)
    acc:SetAllPoints(); acc:SetTexture(MEDIA .. "LogoElvAcc")
    local acc2 = f:CreateTexture(nil, "ARTWORK", nil, 2)
    acc2:SetAllPoints(); acc2:SetTexture(MEDIA .. "LogoElvAcc2")
    local r, g, b = T.Acc()
    acc:SetVertexColor(r, g, b)
    acc2:SetVertexColor(r * 0.6, g * 0.6, b * 0.6)
    f.tex = { base, acc, acc2 }
  else
    local t = f:CreateTexture(nil, "ARTWORK")
    t:SetAllPoints(); t:SetTexture(MEDIA .. "fw_logo_classic")
    f.tex = { t }
  end
  return f
end

-- Landschaft je Zone: 10 Banner in 3 Dateien (je 4 untereinander)
-- 1 rote Wueste, 2 Savanne, 3 gruener Wald, 4 dunkler Nadelwald, 5 Schnee, 6 Sumpf, 7 Dschungel, 8 Pestland, 9 Vulkan, 10 Hauptstadt
local BIOME = {
  [1411] = 1, [1446] = 1, [1441] = 1, [1451] = 1, [1418] = 1, [1443] = 1, [1442] = 1, [1414] = 1,
  [1413] = 2, [1412] = 2,
  [1429] = 3, [1436] = 3, [1433] = 3, [1432] = 3, [1424] = 3, [1417] = 3, [1438] = 3, [1439] = 3, [1450] = 3, [1425] = 3, [1444] = 3, [1447] = 3, [1415] = 3,
  [1431] = 4, [1421] = 4, [1420] = 4, [1440] = 4, [1448] = 4,
  [1426] = 5, [1452] = 5, [1416] = 5,
  [1437] = 6, [1435] = 6, [1445] = 6,
  [1434] = 7, [1449] = 7,
  [1422] = 8, [1423] = 8, [1430] = 8, [1419] = 8,
  [1427] = 9, [1428] = 9,
  [1453] = 10, [1455] = 10, [1457] = 10, [1454] = 10, [1456] = 10, [1458] = 10,
}
function T.Biome(mapID)
  local b = mapID and BIOME[mapID]
  if not b and mapID and C_Map and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(mapID)
    local guard = 0
    while info and not BIOME[info.mapID] and info.parentMapID and info.parentMapID > 0 and guard < 4 do
      info = C_Map.GetMapInfo(info.parentMapID); guard = guard + 1
    end
    b = info and BIOME[info.mapID]
  end
  return b or 3
end
-- Ein Bild pro Zone: 46 Banner in 6 Dateien (je 8 untereinander, 512 x 128)
local ZONE = {
  [1411] = 1, [1412] = 2, [1413] = 3, [1438] = 4, [1439] = 5, [1440] = 6, [1441] = 7, [1442] = 8, [1443] = 9, [1444] = 10,
  [1445] = 11, [1446] = 12, [1447] = 13, [1448] = 14, [1449] = 15, [1450] = 16, [1451] = 17, [1452] = 18, [1454] = 19, [1456] = 20,
  [1457] = 21, [1416] = 22, [1417] = 23, [1418] = 24, [1419] = 25, [1420] = 26, [1421] = 27, [1422] = 28, [1423] = 29, [1424] = 30,
  [1425] = 31, [1426] = 32, [1427] = 33, [1428] = 34, [1429] = 35, [1430] = 36, [1431] = 37, [1432] = 38, [1433] = 39, [1434] = 40,
  [1435] = 41, [1436] = 42, [1437] = 43, [1453] = 44, [1455] = 45, [1458] = 46,
}
function T.ZoneIndex(mapID)
  local z = mapID and ZONE[mapID]
  if not z and mapID and C_Map and C_Map.GetMapInfo then
    local info = C_Map.GetMapInfo(mapID)
    local guard = 0
    while info and not ZONE[info.mapID] and info.parentMapID and info.parentMapID > 0 and guard < 4 do
      info = C_Map.GetMapInfo(info.parentMapID); guard = guard + 1
    end
    z = info and ZONE[info.mapID]
  end
  return z
end
-- Datei und Ausschnitt fuer ein Bild Feld (T.Art): passt zur Zone
function T.BiomeArt(art, mapID)
  local z = T.ZoneIndex(mapID)
  if z then
    local j = (z - 1) % 8
    return art.SetFile(MEDIA .. "fw_zone" .. math.floor((z - 1) / 8) + 1, 4, { 0, 1, j / 8, (j + 1) / 8 })
  end
  local b = T.Biome(mapID)
  local file = MEDIA .. "fw_biome" .. math.floor((b - 1) / 4) + 1
  local j = (b - 1) % 4
  return art.SetFile(file, 4, { 0, 1, j / 4, (j + 1) / 4 })
end

-- Symbole aus Figma (Karte Leiste): je UI ein Atlas mit 4 x 2 Feldern
function T.MapIcon(tex, idx)
  tex:SetTexture(MEDIA .. (T.IsElv() and "fw_map_icons_elv" or "fw_map_icons"))
  local c, r = idx % 4, math.floor(idx / 4)
  tex:SetTexCoord(c / 4, (c + 1) / 4, r / 2, (r + 1) / 2)
end
-- HUD Symbole aus Figma: je UI ein Atlas 4 x 4 (64 px Felder), als Text Baustein
local HUDI = ns.TRKeys{ [TR"Händler"] = 0, Feierabend = 1, [TR"Stunden Budget"] = 2, Einkaufsliste = 3,
  Dungeons = 4, [TR"Ausrüstung"] = 5, [TR"Bücher"] = 6, Ruf = 7,
  [TR"Gold Grinden"] = 8, [TR"Gold Mobs"] = 8, [TR"Neu rechnen"] = 9, [TR"Route planen"] = 10, Questlog = 11,
  [TR"Grosses Fenster"] = 12, Weiter = 13, Karte = 14, [TR"Menü"] = 15,
  -- Ziel waehlen: die Karte mit Stecknadel, Gruppen Ansicht: das Banner
  [TR"Ziel wählen"] = 14, [TR"Gruppen Ansicht"] = 7,
  -- 17.4 (Wunsch Tester: jeder Knopf im Menue mit Symbol): Leveling Route wie Route planen, Tour wie Karte
  [TR"Leveling Route"] = 10, [TR"Tour"] = 14,
  -- 17.5: Navi als eigenes Profil im Menue (wie die Tour), Symbol wie Ziel waehlen
  [TR"Navi"] = 14 }
-- Pause, Weitermachen und Lehrer: eigene kleine Datei (4 Felder nebeneinander, das letzte ist frei)
-- 17.4: Farmen stoppen und Tour beenden mit dem Pause Symbol
local HUDP = ns.TRKeys{ Pause = 0, Weitermachen = 1, Lehrer = 2, [TR"Farmen stoppen"] = 0, [TR"Tour beenden"] = 0, [TR"Navi beenden"] = 0 }
-- 20.1 (P1, Wunsch Sascha): Mehr Schritte und Weniger Schritte, eigene kleine Datei (2 Felder, Pfeile nach unten und oben)
local HUDS = ns.TRKeys{ [TR"Mehr Schritte"] = 0, [TR"Weniger Schritte"] = 1 }
function T.HudIcon(name, size)
  local sx = HUDS[name]
  if sx then
    size = size or 14
    return ("|T%s:%d:%d:0:0:128:64:%d:%d:0:64|t"):format(MEDIA .. (T.IsElv() and "fw_hud_steps_elv" or "fw_hud_steps"), size, size, sx * 64, sx * 64 + 64)
  end
  local p = HUDP[name]
  if p then
    size = size or 14
    return ("|T%s:%d:%d:0:0:256:64:%d:%d:0:64|t"):format(MEDIA .. (T.IsElv() and "fw_hud_pause_elv" or "fw_hud_pause"), size, size, p * 64, p * 64 + 64)
  end
  -- Zurueck: das Weiter Symbol gespiegelt
  local flip = name == TR"Zurück"
  local i = HUDI[flip and TR"Weiter" or name]
  if not i then return nil end
  local c, r = i % 4, math.floor(i / 4)
  size = size or 14
  local l, rr = c * 64, c * 64 + 64
  if flip then l, rr = rr, l end
  return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(MEDIA .. (T.IsElv() and "fw_hud_icons_elv" or "fw_hud_icons"),
    size, size, l, rr, r * 64, r * 64 + 64)
end
-- dasselbe Symbol als Textur (Datei und Ausschnitt), fuer Knoepfe mit Symbol und Text genau in der Mitte
function T.HudIconTex(name)
  local sx = HUDS[name]
  if sx then return MEDIA .. (T.IsElv() and "fw_hud_steps_elv" or "fw_hud_steps"), sx / 2, (sx + 1) / 2, 0, 1 end
  local p = HUDP[name]
  if p then return MEDIA .. (T.IsElv() and "fw_hud_pause_elv" or "fw_hud_pause"), p * 64 / 256, (p * 64 + 64) / 256, 0, 1 end
  local flip = name == TR"Zurück"
  local i = HUDI[flip and TR"Weiter" or name]
  if not i then return nil end
  local c, r = i % 4, math.floor(i / 4)
  local l, rr = c / 4, (c + 1) / 4
  if flip then l, rr = rr, l end
  return MEDIA .. (T.IsElv() and "fw_hud_icons_elv" or "fw_hud_icons"), l, rr, r / 4, (r + 1) / 4
end
-- Knopf: Symbol links vom Text, beides zusammen genau in der Mitte vom Knopf
function T.IconLabel(b, label, size)
  size = size or 16
  b:SetText(label)
  local fs = b.fs or b:GetFontString()
  if not fs then return end
  local file, l, r, t, bt = T.HudIconTex(label)
  if type(rawget(b, "fwIcon")) ~= "table" then rawset(b, "fwIcon", b:CreateTexture(nil, "OVERLAY")) end
  local ic = rawget(b, "fwIcon")
  fs:ClearAllPoints()
  if file then
    ic:SetTexture(file); ic:SetTexCoord(l, r, t, bt); ic:SetSize(size, size); ic:Show()
    local tw = fs.GetStringWidth and fs:GetStringWidth() or 0
    local total = size + 6 + tw
    ic:ClearAllPoints()
    ic:SetPoint("LEFT", b, "CENTER", -total / 2, 0)
    fs:SetPoint("LEFT", ic, "RIGHT", 6, 0)
  else
    ic:Hide()
    fs:SetPoint("CENTER", b, "CENTER", 0, 0)
  end
end
-- Dungeon Bilder aus Figma: 30 Felder 2:1 in 4 Dateien (je 2 x 4, 512 x 256)
local DNG = {
  ["Ragefire Chasm"] = 1, ["Wailing Caverns"] = 2, ["The Deadmines"] = 3, ["Ruins of Lordaeron"] = 4, ["Shadowfang Keep"] = 5,
  ["Blackfathom Deeps"] = 6, ["The Stockade"] = 7, ["Excavation Site: Wetlands"] = 8, ["City of Dalaran"] = 9, ["Gnomeregan"] = 10,
  ["Razorfen Kraul"] = 11, ["Scarlet Monastery"] = 12, ["Razorfen Downs"] = 13, ["Uldaman"] = 14, ["Zul'Farrak"] = 15,
  ["Maraudon"] = 16, ["The Temple of Atal'Hakkar"] = 17, ["Blackrock Depths"] = 18, ["Blackrock Spire"] = 19, ["Dire Maul"] = 20,
  ["Scholomance"] = 21, ["Stratholme"] = 22, ["Zul'Gurub"] = 23, ["Molten Core"] = 24, ["Onyxia's Lair"] = 25,
  ["Blackwing Lair"] = 26, ["Ruins of Ahn'Qiraj"] = 27, ["Temple of Ahn'Qiraj"] = 28, ["Naxxramas"] = 29,
}
-- Neue Dungeons ohne eigenes Bild: nach Stichwort im Namen ein passendes nehmen
local DNG_WORD = {
  { "Scarlet", 12 }, { "Karazhan", 5 }, { "Crypt", 21 }, { TR"Gruft", 21 }, { "Necro", 29 }, { "Plague", 22 },
  { "Blackrock", 18 }, { "Molten", 24 }, { "Ahn'Qiraj", 27 }, { "Zul", 15 }, { "Troll", 23 }, { "Gnome", 10 },
  { "Dalaran", 9 }, { "Stockade", 7 }, { "Prison", 7 }, { "Deeps", 6 }, { "Temple", 17 }, { "Cavern", 2 },
  { "Dragon", 25 }, { "Lair", 25 }, { "Dire", 20 }, { "Lordaeron", 4 }, { "Uldaman", 14 }, { "Razorfen", 11 },
}
local function DngIndex(key)
  if not key then return end
  if DNG[key] then return DNG[key] end
  for _, w in ipairs(DNG_WORD) do if key:find(w[1], 1, true) then return w[2] end end
end
-- Feld 30: allgemeiner Dungeon Eingang
function T.DungeonArt(tex, key, generic, h, aspect)
  local i = DngIndex(key) or (generic and 30)
  if not i then return false end
  local f = math.floor((i - 1) / 8) + 1
  local j = (i - 1) % 8
  local c, r = j % 2, math.floor(j / 2)
  -- h: wie viel der Hoehe sichtbar ist (1 = ganz), mittig
  h = h or 1
  -- aspect: Breite durch Hoehe der Flaeche. Ein Bild im Atlas ist 2:1, der Rest wird mittig abgeschnitten
  local wv = 1
  if aspect and aspect > 0 then
    if aspect * h > 2 then h = 2 / aspect else wv = math.min(1, aspect * h / 2) end
  end
  local top, bot = (1 - h) / 2, (1 + h) / 2
  local l, rr = (1 - wv) / 2, (1 + wv) / 2
  if tex:SetTexture(MEDIA .. "fw_dng" .. f) == false then return false end
  tex:SetTexCoord((c + l) / 2, (c + rr) / 2, (r + top) / 4, (r + bot) / 4)
  tex:SetVertexColor(1, 1, 1, 1)
  return true
end

-- Punkte fuer Karte und Minimap: je UI ein Atlas 4 x 4 (64 px)
local PIN = { quest = 0, turnin = 1, obj = 2, grind = 3, fp = 4, via = 5, explore = 6, travel = 7,
  vendor = 8, hearth = 9, book = 10, danger = 11, gold = 12, both = 13, inn = 14, next = 15 }
-- Classic: die Symbole aus dem Spiel selbst (passen zur Blizzard Karte); fehlt eine Datei, der eigene Atlas
local ICO = "Interface\\Icons\\"
local RT = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
-- Annehmen, Abgeben und beides: immer die eigenen Symbole (Schriftrolle, Haken), nicht ! und ? vom Spiel
local BLIZ = {
  obj = { RT .. "3" }, grind = { "Interface\\CURSOR\\Attack" },
  fp = { "Interface\\CURSOR\\Taxi" }, via = { RT .. "4" }, explore = { "Interface\\CURSOR\\Inspect" },
  travel = { ICO .. "INV_Misc_Map02", true }, vendor = { "Interface\\CURSOR\\Buy" }, hearth = { ICO .. "INV_Misc_Rune_01", true },
  book = { ICO .. "INV_Misc_Book_09", true }, danger = { "Interface\\TargetingFrame\\UI-TargetingFrame-Skull" },
  gold = { ICO .. "INV_Misc_Coin_01", true }, inn = { ICO .. "Spell_Nature_Sleep", true }, next = { RT .. "1" },
}
function T.PinTex(tex, kind)
  if ns.db and ns.db.pinIcons == false then return false end
  local i = PIN[kind]
  if not i then return false end
  local b = not T.IsElv() and BLIZ[kind]
  if b and tex:SetTexture(b[1]) ~= false then
    if b[2] then tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) else tex:SetTexCoord(0, 1, 0, 1) end
    tex:SetVertexColor(1, 1, 1, 1)
    return true
  end
  tex:SetTexture(MEDIA .. (T.IsElv() and "fw_pins_elv" or "fw_pins"))
  local c, r = i % 4, math.floor(i / 4)
  tex:SetTexCoord(c / 4, (c + 1) / 4, r / 4, (r + 1) / 4)
  tex:SetVertexColor(1, 1, 1, 1)
  return true
end
function T.LogoPath() return MEDIA .. (T.IsElv() and "LogoElvBase" or "fw_logo_classic") end

------------------------------------------------------------
-- Knoepfe
------------------------------------------------------------
-- Aktions Knopf: Classic der rote Blizzard Knopf, ElvUI der flache ElvUI Knopf
function T.Button(parent, text, w, h, primary)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w or 120, h or 22)
  b:SetText(text or "")
  local fs = b:GetFontString()
  if type(fs) ~= "table" then fs = type(b.Text) == "table" and b.Text or false end
  b.fs = fs
  if T.IsElv() and S and S.HandleButton then
    pcall(S.HandleButton, S, b)
  end
  T.SetPrimary(b, primary)
  -- Tooltip Skripte nur dazu haengen, nie ersetzen: sonst ist das Leuchten beim Drueberfahren weg
  -- (ElvUI faerbt den Rand in seinem OnEnter, 17.3: Route planen bei Berufe leuchtete nicht)
  local setScript = b.SetScript
  b.SetScript = function(self, ev, fn)
    if ev == "OnEnter" or ev == "OnLeave" then
      self["_fw" .. ev] = fn
      if not self["_fwHook" .. ev] then
        self["_fwHook" .. ev] = true
        self:HookScript(ev, function(...) local f = self["_fw" .. ev]; if f then f(...) end end)
      end
      return
    end
    return setScript(self, ev, fn)
  end
  return b
end

-- Pro Bereich nur ein roter Hauptknopf: alle anderen Knoepfe grau (gleiche Form, nur entsaettigt)
function T.SetPrimary(b, on)
  b.primary = on and true or nil
  if T.IsElv() then
    if b.fs then
      if on then local r, g, bb = T.Acc(); b.fs:SetTextColor(r, g, bb) else b.fs:SetTextColor(1, 1, 1) end
    end
    return
  end
  for _, k in ipairs({ "Left", "Middle", "Right" }) do
    local t = b[k]
    if type(t) == "table" and t.SetDesaturated then
      t:SetDesaturated(not on)
      t:SetVertexColor(on and 1 or 0.78, on and 1 or 0.78, on and 1 or 0.78)
    end
  end
end

-- Knopf sperren mit Hinweis, ab welchem Level er kommt
function T.Lock(b, lockText)
  if lockText then
    b:Disable()
    b.lockText = lockText
  else
    b:Enable()
    b.lockText = nil
  end
  if not b.lockHooked then
    b.lockHooked = true
    b:SetMotionScriptsWhileDisabled(true)
    b:HookScript("OnEnter", function(self)
      if self.lockText then
        ns.TipOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(self.lockText, 1, 0.82, 0)
        GameTooltip:Show()
      end
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
  end
end

-- Listen Zeile oder Menue Punkt: Classic wie im Questlog (gelbe Schrift, Leuchten), ElvUI flach
function T.Row(parent, w, h)
  local b = CreateFrame("Button", nil, parent, BD)
  b:SetSize(w or 200, h or 22)
  local fs = b:CreateFontString(nil, "OVERLAY", T.IsElv() and ns.FontName("GameFontHighlight") or ns.FontName("GameFontNormal"))
  fs:SetPoint("LEFT", 8, 0)
  fs:SetPoint("RIGHT", -6, 0)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  b:SetFontString(fs)
  b.fs = fs
  local sel = b:CreateTexture(nil, "BACKGROUND")
  sel:SetAllPoints()
  local bar = b:CreateTexture(nil, "ARTWORK")
  bar:SetPoint("TOPLEFT", 0, 0); bar:SetPoint("BOTTOMLEFT", 0, 0); bar:SetWidth(2)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  if T.IsElv() then
    local r, g, bb = T.Acc()
    sel:SetColorTexture(r, g, bb, 0.14)
    bar:SetColorTexture(r, g, bb, 1)
    hl:SetColorTexture(r, g, bb, 0.10)
    if b.SetTemplate then pcall(b.SetTemplate, b, "Default") end
  else
    sel:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    sel:SetBlendMode("ADD")
    sel:SetVertexColor(1, 0.82, 0, 0.9)
    bar:SetColorTexture(1, 0.82, 0, 0)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")
    hl:SetVertexColor(1, 1, 1, 0.45)
  end
  sel:Hide(); bar:Hide()
  b.selTex, b.bar = sel, bar
  function b.SetSelected(on)
    sel:SetShown(on and true or false)
    bar:SetShown(on and T.IsElv() and true or false)
    if not b.keepColor then
      if on then fs:SetTextColor(1, 1, 1)
      elseif T.IsElv() then fs:SetTextColor(0.82, 0.82, 0.82)
      else fs:SetTextColor(1, 0.82, 0) end
    end
  end
  b.SetSelected(false)
  return b
end

-- Karte: Flaeche mit Titel und Untertitel, klickbar (Startseite, Alle Funktionen, Mein Weg)
function T.Card(parent, w, h)
  local b = CreateFrame("Button", nil, parent, BD)
  b:SetSize(w or 180, h or 46)
  T.Skin(b, "inset")
  b.title = b:CreateFontString(nil, "OVERLAY", T.IsElv() and ns.FontName("GameFontHighlight") or ns.FontName("GameFontNormal"))
  b.title:SetPoint("TOPLEFT", 10, -8); b.title:SetPoint("RIGHT", -8, 0)
  b.title:SetJustifyH("LEFT"); b.title:SetWordWrap(false)
  b.sub = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  b.sub:SetPoint("TOPLEFT", b.title, "BOTTOMLEFT", 0, -3); b.sub:SetPoint("RIGHT", -8, 0)
  b.sub:SetJustifyH("LEFT"); b.sub:SetJustifyV("TOP")
  b.sub:SetTextColor(0.75, 0.72, 0.62)
  b.state = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  b.state:SetPoint("BOTTOMLEFT", 10, 7); b.state:SetPoint("RIGHT", -8, 0)
  b.state:SetJustifyH("LEFT"); b.state:SetWordWrap(false)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3)
  local r, g, bb = T.Acc()
  hl:SetColorTexture(r, g, bb, 0.10)
  b.hl = hl
  function b.Set(title, sub, state, kind)
    b.title:SetText(title or "")
    b.sub:SetText(sub or "")
    b.state:SetText(state or "")
    T.SetState(b, kind or "inset")
    if kind == "lock" then
      b.title:SetTextColor(0.55, 0.52, 0.45); b.state:SetTextColor(0.6, 0.55, 0.45)
    elseif T.IsElv() then
      b.title:SetTextColor(1, 1, 1); b.state:SetTextColor(T.Acc())
    else
      b.title:SetTextColor(1, 0.82, 0); b.state:SetTextColor(0.25, 1, 0.25)
    end
  end
  return b
end

-- Haken mit Text (Classic: Blizzard Haken, ElvUI: kleines ElvUI Kaestchen)
function T.Check(parent, label, sub)
  local r = CreateFrame("Frame", nil, parent)
  r:SetHeight(sub and 34 or 24)
  local cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", 0, 0)
  if T.IsElv() and S and S.HandleCheckBox then pcall(S.HandleCheckBox, S, cb) end
  r.cb = cb
  r.label = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  r.label:SetPoint("TOPLEFT", cb, "TOPRIGHT", 4, -5)
  r.label:SetPoint("RIGHT", r, "RIGHT", -4, 0)
  r.label:SetJustifyH("LEFT"); r.label:SetWordWrap(false)
  r.label:SetText(label or "")
  if sub then
    r.sub = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    r.sub:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -2)
    r.sub:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.sub:SetJustifyH("LEFT"); r.sub:SetWordWrap(false)
    r.sub:SetText(sub)
  end
  return r
end

-- Frage mit Ja und Nein (Einsteiger Einstellungen)
function T.YesNo(parent, text, get, set, help)
  local r = CreateFrame("Frame", nil, parent)
  r:SetHeight(30)
  r.q = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  r.q:SetPoint("LEFT", 0, 0)
  r.q:SetPoint("RIGHT", r, "RIGHT", -128, 0)
  r.q:SetJustifyH("LEFT")
  -- ohne Fragezeichen am Ende, Ja und Nein daneben sagt schon, dass es eine Frage ist
  r.q:SetText((tostring(text or ""):gsub("%s*%?%s*$", "")))
  local yes = T.Button(r, TR"Ja", 46, 22)
  local no = T.Button(r, TR"Nein", 46, 22)
  local q = CreateFrame("Button", nil, r, BD)
  q:SetSize(22, 22)
  q:SetPoint("RIGHT", 0, 0)
  T.Skin(q, "inset")
  local qt = q:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  qt:SetPoint("CENTER", 0, 0); qt:SetText("?")
  -- kein Fragezeichen mehr: Ja und Nein ganz rechts, die Erklaerung kommt mit der Maus auf der Frage
  q:Hide()
  no:SetPoint("RIGHT", r, "RIGHT", 0, 0)
  r.q:SetPoint("RIGHT", r, "RIGHT", -100, 0)
  if help and help ~= "" then
    r:EnableMouse(true)
    r:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(text, 1, 1, 1, true)
      GameTooltip:AddLine(help, 1, 0.82, 0, true)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  yes:SetPoint("RIGHT", no, "LEFT", -2, 0)
  q:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(text, 1, 1, 1, true)
    GameTooltip:AddLine(help or "", 1, 0.82, 0, true)
    GameTooltip:Show()
  end)
  q:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local function Mark(btn, on)
    if T.IsElv() then
      local rr, gg, bb = T.Acc()
      if btn.SetBackdropBorderColor then
        if on then btn:SetBackdropBorderColor(rr, gg, bb, 1) else btn:SetBackdropBorderColor(0, 0, 0, 1) end
      end
      if btn.fs then if on then btn.fs:SetTextColor(1, 1, 1) else btn.fs:SetTextColor(0.55, 0.55, 0.55) end end
    else
      if on then btn:LockHighlight() else btn:UnlockHighlight() end
      if btn.fs then if on then btn.fs:SetTextColor(1, 1, 1) else btn.fs:SetTextColor(0.6, 0.5, 0.3) end end
    end
  end
  function r.Update()
    local on = get() and true or false
    Mark(yes, on); Mark(no, not on)
    -- 19.10: Frage gilt gerade nicht (zb nur bei Tempo Alles): grau, Knoepfe aus
    if r.active then
      local act = r.active() and true or false
      if act then r.q:SetTextColor(1, 1, 1) else r.q:SetTextColor(0.5, 0.5, 0.5) end
      if yes.SetEnabled then yes:SetEnabled(act); no:SetEnabled(act) end
      -- 20.1 (P6): nicht klickbar heisst sichtbar grau, auch die Knoepfe
      if not act then
        if yes.fs then yes.fs:SetTextColor(0.35, 0.35, 0.35) end
        if no.fs then no.fs:SetTextColor(0.35, 0.35, 0.35) end
      end
      -- 20.1 (P6, Wunsch Sascha): Fragen, die nur bei einer Stufe gelten, ganz ausblenden (Zeile ohne Hoehe)
      if r.hideInactive ~= false then
        r.fullH = r.fullH or ((r:GetHeight() or 0) > 2 and r:GetHeight() or 30)
        r:SetShown(act)
        r:SetHeight(act and r.fullH or 1)
      end
    end
  end
  yes:SetScript("OnClick", function() set(true); r.Update() end)
  no:SetScript("OnClick", function() set(false); r.Update() end)
  -- ElvUI setzt den Rand beim Verlassen zurueck, danach neu markieren
  yes:HookScript("OnLeave", r.Update); no:HookScript("OnLeave", r.Update)
  r.Update()
  return r
end

-- Reiter oben in einem Fenster: Text mit Linie unter dem aktiven
function T.Tabs(parent, items, onPick)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(24)
  f.btns, f.items = {}, items
  local line = f:CreateTexture(nil, "ARTWORK")
  line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1)
  line:SetColorTexture(1, 1, 1, 0.12)
  for i, it in ipairs(items) do
    local b = CreateFrame("Button", nil, f)
    b:SetHeight(24)
    local fs = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    fs:SetPoint("CENTER", 0, 1)
    fs:SetText(it[2])
    b:SetFontString(fs)
    b.fs = fs
    b.key = it[1]
    -- Reiter Look: aktiv hell mit goldener Linie oben
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.u = b:CreateTexture(nil, "OVERLAY")
    b.u:SetPoint("TOPLEFT", 0, 0); b.u:SetPoint("TOPRIGHT", 0, 0); b.u:SetHeight(2)
    b.u:SetColorTexture(1, 0.82, 0, 1)
    local r, g, bb = T.Acc()
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetColorTexture(r, g, bb, 0.08)
    b:SetScript("OnClick", function() onPick(it[1]) end)
    f.btns[i] = b
  end
  function f.Lay()
    local x = 0
    for _, b in ipairs(f.btns) do
      if b:IsShown() then
        b:ClearAllPoints()
        local w = math.max(56, (b.fs:GetStringWidth() or 50) + 18)
        b:SetWidth(w)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 0)
        x = x + w + 2
      end
    end
  end
  function f.Select(key)
    for _, b in ipairs(f.btns) do
      local on = (b.key == key)
      b.u:SetShown(on)
      b.bg:SetColorTexture(on and 1 or 0, on and 1 or 0, on and 1 or 0, on and 0.16 or 0.45)
      if on then b.fs:SetTextColor(1, 1, 1)
      elseif T.IsElv() then b.fs:SetTextColor(0.65, 0.65, 0.65)
      else b.fs:SetTextColor(1, 0.82, 0) end
    end
  end
  f.Lay()
  return f
end

-- Reiter (Tabs) wie Karteikarten: der aktive ist hell mit goldener Linie oben, die anderen dunkel.
-- Gleich in jedem Fenster (Statistik, Dungeons, Sortieren, Berufe, Meine Route, Gold).
-- defs = { { key, Text, gesperrt (Text fuer den Tooltip) }, ... }
local function TabSkin(b, on)
  local r, g, bb = T.Acc()
  if on then
    b.bg:SetColorTexture(1, 1, 1, T.IsElv() and 0.14 or 0.18)
    b.top:SetColorTexture(1, 0.82, 0, 1); b.top:Show()
    b.fs:SetTextColor(1, 1, 1)
  else
    b.bg:SetColorTexture(0, 0, 0, T.IsElv() and 0.45 or 0.5)
    b.top:Hide()
    if b.locked then b.fs:SetTextColor(0.45, 0.45, 0.45)
    elseif T.IsElv() then b.fs:SetTextColor(0.7, 0.7, 0.7) else b.fs:SetTextColor(0.85, 0.7, 0.3) end
  end
  b.hl:SetColorTexture(r, g, bb, 0.10)
end
function T.TabBar(parent, h)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(h or 26)
  f.btns = {}
  f.base = f:CreateTexture(nil, "ARTWORK")
  f.base:SetPoint("BOTTOMLEFT"); f.base:SetPoint("BOTTOMRIGHT"); f.base:SetHeight(1)
  f.base:SetColorTexture(1, 0.82, 0, 0.35)
  local function Btn(i)
    local b = f.btns[i]
    if b then return b end
    b = CreateFrame("Button", nil, f)
    b:SetHeight(f:GetHeight() - 1)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.edgeL = b:CreateTexture(nil, "BORDER"); b.edgeL:SetPoint("TOPLEFT"); b.edgeL:SetPoint("BOTTOMLEFT"); b.edgeL:SetWidth(1); b.edgeL:SetColorTexture(1, 1, 1, 0.12)
    b.edgeR = b:CreateTexture(nil, "BORDER"); b.edgeR:SetPoint("TOPRIGHT"); b.edgeR:SetPoint("BOTTOMRIGHT"); b.edgeR:SetWidth(1); b.edgeR:SetColorTexture(1, 1, 1, 0.12)
    b.top = b:CreateTexture(nil, "ARTWORK"); b.top:SetPoint("TOPLEFT"); b.top:SetPoint("TOPRIGHT"); b.top:SetHeight(2)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT"); b.hl:SetAllPoints()
    local fs = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    fs:SetPoint("CENTER", 0, 0)
    b:SetFontString(fs)
    b.fs = fs
    b:SetMotionScriptsWhileDisabled(true)
    b:SetScript("OnClick", function(self)
      if self.locked then return end
      if f.onPick then f.onPick(self.key) end
    end)
    b:SetScript("OnEnter", function(self)
      if not (self.tip or self.locked) then return end
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(self.label or "")
      if self.locked then GameTooltip:AddLine(self.locked, 1, 0.82, 0, true) end
      if self.tip then GameTooltip:AddLine(self.tip, 1, 1, 1, true) end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.btns[i] = b
    return b
  end
  -- defs neu setzen, active = Schluessel vom aktiven Reiter, fill = alle gleich breit ueber die ganze Breite
  function f.Set(defs, active, fill)
    local x = 0
    local n = #(defs or {})
    local fw = fill and n > 0 and ((f:GetWidth() or 0) - 3 * (n - 1)) / n or nil
    if fw and fw < 40 then fw = nil end
    for i, d in ipairs(defs or {}) do
      local b = Btn(i)
      b.key, b.label, b.locked, b.tip = d[1], d[2], d[3], d.tip
      b:SetText(d[2])
      local w = fw or math.max(70, (b.fs:GetStringWidth() or 60) + 28)
      b:SetWidth(w)
      b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 1)
      TabSkin(b, d[1] == active)
      b:Show()
      x = x + w + 3
    end
    for i = #(defs or {}) + 1, #f.btns do f.btns[i]:Hide() end
    f.width = x
  end
  return f
end

-- Kachel mit grosser Zahl
function T.Tile(parent, big)
  local t = CreateFrame("Frame", nil, parent, BD)
  T.Skin(t, "inset")
  if big then
    -- Vollbild: grosse Zahl links, Text darunter (wie im Konzept)
    t.value = t:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    t.value:SetPoint("TOPLEFT", 14, -12)
    t.value:SetTextColor(T.Acc())
    t.label = t:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    t.label:SetPoint("BOTTOMLEFT", 14, 10)
    t.label:SetPoint("RIGHT", -8, 0)
    -- schmale Kacheln (grosser UI Scale): Text darf auf zwei Zeilen, waechst nach oben
    t.label:SetJustifyH("LEFT"); t.label:SetWordWrap(true); t.label:SetMaxLines(2)
    t.label:SetTextColor(0.7, 0.68, 0.6)
    return t
  end
  t.value = t:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightLarge"))
  t.value:SetPoint("TOP", 0, -9)
  t.value:SetTextColor(T.Acc())
  t.label = t:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  t.label:SetPoint("BOTTOM", 0, 7)
  t.label:SetPoint("LEFT", 4, 0); t.label:SetPoint("RIGHT", -4, 0)
  -- lange Texte (Pro Kill: Kampf und Pause) auf zwei Zeilen statt abgeschnitten
  t.label:SetWordWrap(true); t.label:SetMaxLines(2)
  return t
end

-- Balken (Zone, XP)
function T.Bar(parent, h)
  local bar = CreateFrame("StatusBar", nil, parent, BD)
  bar:SetHeight(h or 14)
  bar:SetStatusBarTexture(T.BarTexture())
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  if T.IsElv() and bar.SetTemplate then pcall(bar.SetTemplate, bar, "Default")
  elseif bar.SetBackdrop then
    bar:SetBackdrop(CL.thin); bar:SetBackdropColor(0, 0, 0, 0.6); bar:SetBackdropBorderColor(0.3, 0.25, 0.15, 1)
  end
  bar.text = bar:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  bar.text:SetPoint("LEFT", 6, 0)
  bar.right = bar:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  bar.right:SetPoint("RIGHT", -6, 0)
  return bar
end

function T.SkinScroll(sf)
  local bar = sf.ScrollBar or (sf:GetName() and _G[sf:GetName() .. "ScrollBar"])
  if T.IsElv() and S and S.HandleScrollBar and bar then pcall(S.HandleScrollBar, S, bar) end
end
function T.SkinEdit(eb)
  if T.IsElv() and S and S.HandleEditBox then pcall(S.HandleEditBox, S, eb) end
end
function T.SkinClose(b)
  if T.IsElv() and S and S.HandleCloseButton then pcall(S.HandleCloseButton, S, b) end
end

-- Text mit Scroll
function T.ScrollText(parent, name, font)
  local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
  T.SkinScroll(sf)
  local c = CreateFrame("Frame", nil, sf)
  c:SetSize(10, 10)
  sf:SetScrollChild(c)
  local fs = c:CreateFontString(nil, "OVERLAY", font or ns.FontName("GameFontHighlight"))
  fs:SetPoint("TOPLEFT")
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  fs:SetSpacing(4)
  sf:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then c:SetWidth(w); fs:SetWidth(w - 4) end end)
  function sf.Set(lines)
    fs:SetText(type(lines) == "table" and table.concat(lines, "\n") or (lines or ""))
    c:SetHeight(fs:GetStringHeight() + 20)
  end
  sf.fs = fs
  return sf
end

------------------------------------------------------------
-- Fenster
------------------------------------------------------------
-- Fenster mit Titel, Schliessen Knopf und Verschieben
-- Classic: Dialog Rahmen mit Titel Schild oben, ElvUI: flach mit Logo und Titel links
function T.Window(name, w, h, title, strata)
  local f = CreateFrame("Frame", name, UIParent, BD)
  f:SetSize(w, h)
  f:SetPoint("CENTER")
  -- ueber dem grossen Fenster (das ist DIALOG), sonst liegt es dahinter
  f:SetFrameStrata(strata or "FULLSCREEN")
  if f.SetToplevel then f:SetToplevel(true) end
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  T.Skin(f, "window")
  if T.IsElv() then
    f.logo = T.Logo(f, 22)
    f.logo:SetPoint("TOPLEFT", 10, -9)
    f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    f.title:SetPoint("LEFT", f.logo, "RIGHT", 8, 0)
    f.title:SetText(title or "")
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 1, -38); line:SetPoint("TOPRIGHT", -1, -38); line:SetHeight(1)
    line:SetColorTexture(0, 0, 0, 1)
    f.top = 46
  else
    local hd = f:CreateTexture(nil, "ARTWORK")
    hd:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    hd:SetSize(math.min(360, math.max(256, w * 0.5)), 64)
    hd:SetPoint("TOP", 0, 12)
    f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    f.title:SetPoint("TOP", hd, "TOP", 0, -14)
    f.title:SetText(title or "")
    f.top = 34
  end
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", T.IsElv() and -4 or -6, T.IsElv() and -4 or -6)
  close:SetScript("OnClick", function() f:Hide() end)
  T.SkinClose(close)
  f.close = close
  if ns.CloseOnEscape then ns.CloseOnEscape(f) end
  f:Hide()
  return f
end

-- kleines Hinweis Fenster (Einkaufsliste, Warnung, neue Funktion)
function T.Popup(name, w, title)
  local f = CreateFrame("Frame", name, UIParent, BD)
  f:SetSize(w or 340, 140)
  f:SetPoint("TOP", UIParent, "TOP", 0, -170)
  -- Hinweise immer ganz oben (auch ueber dem grossen Fenster und seinen Seiten)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  if f.SetToplevel then f:SetToplevel(true) end
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  T.Skin(f, T.IsElv() and "window" or "tooltip")
  f.logo = T.Logo(f, 20)
  f.logo:SetPoint("TOPLEFT", 12, -11)
  f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  f.title:SetPoint("LEFT", f.logo, "RIGHT", 8, 0)
  f.title:SetPoint("RIGHT", f, "RIGHT", -34, 0)
  f.title:SetJustifyH("LEFT")
  f.title:SetText(title or "")
  if T.IsElv() then f.title:SetTextColor(T.Acc()) end
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -2, -2)
  close:SetScript("OnClick", function() f:Hide() end)
  T.SkinClose(close)
  f.close = close
  f.body = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  f.body:SetPoint("TOPLEFT", 14, -40)
  f.body:SetPoint("RIGHT", f, "RIGHT", -14, 0)
  f.body:SetJustifyH("LEFT"); f.body:SetJustifyV("TOP")
  f.body:SetSpacing(3)
  if ns.CloseOnEscape then ns.CloseOnEscape(f) end
  f:Hide()
  return f
end

-- Hoehe eines Popups an den Text anpassen (extra: Platz fuer Knoepfe und Listen)
function T.FitPopup(f, extra)
  local h = (f.body:GetStringHeight() or 20) + 52 + (extra or 40)
  f:SetHeight(math.max(110, h))
end

-- einzelner Haken ohne Text (Listen)
function T.CheckButton(parent)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  if T.IsElv() and S and S.HandleCheckBox then pcall(S.HandleCheckBox, S, cb) end
  return cb
end

------------------------------------------------------------
-- Aufbau wie im Konzept: Kopfleiste, Seitenleiste, Modus Schild
------------------------------------------------------------
-- Kopfleiste oben im Fenster (dunkler Streifen mit Linie unten)
function T.HeadStrip(parent, h, inset)
  local f = CreateFrame("Frame", nil, parent)
  inset = inset or 0
  f:SetPoint("TOPLEFT", inset, -inset)
  f:SetPoint("TOPRIGHT", -inset, -inset)
  f:SetHeight(h or 56)
  local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetAllPoints()
  local line = f:CreateTexture(nil, "BORDER")
  line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(T.IsElv() and 1 or 2)
  if T.IsElv() then
    bg:SetColorTexture(0.1, 0.1, 0.1, 1)
    line:SetColorTexture(0, 0, 0, 1)
  else
    bg:SetColorTexture(0.14, 0.11, 0.08, 0.95)
    line:SetColorTexture(0.56, 0.48, 0.3, 1)
  end
  return f
end

-- Seitenleiste links (Menue)
function T.SideStrip(parent, w)
  local f = CreateFrame("Frame", nil, parent)
  f:SetWidth(w or 190)
  local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetAllPoints()
  local line = f:CreateTexture(nil, "BORDER")
  line:SetPoint("TOPRIGHT"); line:SetPoint("BOTTOMRIGHT"); line:SetWidth(T.IsElv() and 1 or 2)
  if T.IsElv() then
    bg:SetColorTexture(0.09, 0.09, 0.09, 1)
    line:SetColorTexture(0, 0, 0, 1)
  else
    bg:SetColorTexture(0, 0, 0, 0.35)
    line:SetColorTexture(0.29, 0.24, 0.15, 1)
  end
  return f
end

-- kleines Auswahl Menue (Liste unter einem Knopf)
local menu
function T.ShowMenu(owner, entries)
  if not menu then
    menu = CreateFrame("Frame", "ForeverWegweiserMenu", UIParent, BD)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:EnableMouse(true)
    menu.rows = {}
    menu:SetScript("OnUpdate", function(self, el)
      -- zu, wenn die Maus eine Weile weg ist
      if self:IsMouseOver() or (self.owner and self.owner:IsMouseOver()) then self.away = 0
      else self.away = (self.away or 0) + el; if self.away > 1.2 then self:Hide() end end
    end)
    if ns.CloseOnEscape then ns.CloseOnEscape(menu) end
  end
  if menu:IsShown() and menu.owner == owner then menu:Hide(); return end
  T.Skin(menu, T.IsElv() and "window" or "tooltip")
  if not rawget(menu, "solid") then
    menu.solid = menu:CreateTexture(nil, "BACKGROUND", nil, -7)
    menu.solid:SetPoint("TOPLEFT", 3, -3); menu.solid:SetPoint("BOTTOMRIGHT", -3, 3)
  end
  menu.solid:SetColorTexture(0.04, 0.04, 0.05, 0.97)
  menu.owner = owner
  menu.away = 0
  for _, r in ipairs(menu.rows) do r:Hide() end
  local y, w = 8, 220
  for i, e in ipairs(entries) do
    local r = menu.rows[i]
    if not r then
      r = T.Row(menu, w - 12, 20)
      r.check = r:CreateTexture(nil, "OVERLAY")
      r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
      r.check:SetSize(16, 16); r.check:SetPoint("LEFT", 2, 0)
      r.fs:ClearAllPoints(); r.fs:SetPoint("LEFT", 22, 0); r.fs:SetPoint("RIGHT", -4, 0)
      menu.rows[i] = r
    end
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", 6, -y)
    if not rawget(r, "line") then
      r.line = r:CreateTexture(nil, "ARTWORK")
      r.line:SetPoint("BOTTOMLEFT", 4, 0); r.line:SetPoint("BOTTOMRIGHT", -4, 0); r.line:SetHeight(1)
    end
    r.line:SetShown(e.head and true or false)
    if e.head then
      local ar, ag, ab = T.Acc()
      r.line:SetColorTexture(ar, ag, ab, 0.5)
      r:SetText(T.Section(e.text)); r.check:Hide(); r:EnableMouse(false); r.keepColor = true
      r.fs:SetFontObject(ns.FontName("GameFontNormalSmall"))
      r.SetSelected(false)
      if i > 1 then y = y + 6; r:ClearAllPoints(); r:SetPoint("TOPLEFT", 6, -y) end
    else
      r.fs:SetFontObject(T.IsElv() and ns.FontName("GameFontHighlight") or ns.FontName("GameFontHighlight"))
      r.keepColor = e.disabled
      r:SetText(e.disabled and ("|cff7d7d7d" .. e.text .. "|r") or e.text)
      r.check:SetShown(e.checked and true or false)
      r:EnableMouse(true)
      r.SetSelected(false)
      r:SetScript("OnClick", function()
        menu:Hide()
        if not e.disabled and e.fn then e.fn() end
      end)
      r:SetScript("OnEnter", function(self)
        if e.tip then ns.TipOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(e.text); GameTooltip:AddLine(e.tip, 1, 1, 1, true); GameTooltip:Show() end
      end)
      r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    r:Show()
    y = y + (e.head and 20 or 22)
  end
  menu:SetSize(w, y + 6)
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
  menu:Show()
end

-- Schild oben im Fenster: Modus und Tempo, Klick oeffnet die Auswahl
local GOALS = {
  { "all", TR"Alles", "" }, { "normal", TR"Normal", "" } }
T.GOALS_ALL = TR"Bei beiden: Pfeil, Abgaben, Folgequests, Klassenquests, Questlog bis 40 und Entdecken auf dem Weg."
T.GOALS = GOALS
function T.GoalName(g)
  if ns.LevelStepInfo then
    local st = ns.LevelStepInfo()
    if st then return st.name .. ((ns.db and ns.db.grind == false) and TR" ohne Grinden" or "") end
  end
  for _, x in ipairs(GOALS) do if x[1] == g then return x[2] end end
  return GOALS[2][2]
end
function T.Chip(parent)
  local f = CreateFrame("Button", nil, parent, BD)
  f:SetSize(150, 20)
  f.text = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  f.text:SetPoint("LEFT", 10, 0)
  f.arrow = f:CreateTexture(nil, "OVERLAY")
  f.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
  f.arrow:SetSize(12, 12); f.arrow:SetPoint("RIGHT", -5, 0)
  f.arrow:SetRotation(-math.pi / 2)
  local hl = f:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.1)
  function f.Set()
    local expert = ns.Expert and ns.Expert()
    f.text:SetText((TR"%s, Tempo %s"):format(ns.ModeName and ns.ModeName() or TR"Geführt", T.GoalName(ns.db and ns.db.goal)))
    f:SetWidth((f.text:GetStringWidth() or 100) + 32)
    if T.IsElv() then
      T.Skin(f, "inset")
      if expert then f.text:SetTextColor(0.9, 0.72, 0.3) else f.text:SetTextColor(T.Acc()) end
    else
      T.Skin(f, expert and "sel" or "inset")
      f.text:SetTextColor(1, 0.82, 0)
    end
  end
  f:SetScript("OnClick", function(self)
    local db = ns.db or {}
    local list = { { head = true, text = TR"Tempo" } }
    local cur = ns.LevelStep and ns.LevelStep() or 2
    for i, st in ipairs(ns.LEVEL_STEPS or {}) do
      local label = st.name .. (st.std and TR"  (Standard)" or "")
      table.insert(list, { text = label, checked = cur == i,
        tip = st.text .. "\n\n" .. (ns.TempoLine and ns.TempoLine(i) or "") .. "\n\n" .. T.GOALS_ALL,
        fn = function() if ns.SetLevelStep then ns.SetLevelStep(i) end end })
    end
    table.insert(list, { text = TR"Grinden: " .. (db.grind ~= false and TR"an" or TR"aus"), checked = db.grind ~= false,
      tip = T.GRIND_TIP, fn = function() if ns.SetGrind then ns.SetGrind(db.grind == false) end end })
    table.insert(list, { head = true, text = TR"Modus" })
    for _, m in ipairs(ns.MODES or {}) do
      table.insert(list, { text = m[2], checked = ns.Mode() == m[1], tip = m[3], fn = function() ns.SetMode(m[1]) end })
    end
    T.ShowMenu(self, list)
  end)
  f:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(TR"Tempo und Modus")
    GameTooltip:AddLine(TR"Klick: auswählen, wie du spielen willst", 1, 1, 1)
    GameTooltip:Show()
  end)
  f:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return f
end

------------------------------------------------------------
-- Journal Stil: Bildflaechen wie im Dungeon Journal
------------------------------------------------------------
-- dunkler Verlauf von unten nach oben ueber einem Bild (Text bleibt lesbar)
function T.Shade(parent, bottomA, topA, layer)
  local s = parent:CreateTexture(nil, layer or "ARTWORK", nil, 5)
  s:SetColorTexture(1, 1, 1, 1)
  local b, t = bottomA or 0.85, topA or 0.10
  local ok = false
  if s.SetGradient and CreateColor then
    ok = pcall(s.SetGradient, s, "VERTICAL", CreateColor(0, 0, 0, b), CreateColor(0, 0, 0, t))
  end
  if not ok and s.SetGradientAlpha then
    ok = pcall(s.SetGradientAlpha, s, "VERTICAL", 0, 0, 0, b, 0, 0, 0, t)
  end
  if not ok then s:SetColorTexture(0, 0, 0, (b + t) / 2) end
  return s
end

-- Bildflaeche: Weltkarte einer Zone (aus Kacheln), ein Ladebildschirm oder ein grosses Symbol
function T.Art(parent)
  local a = CreateFrame("Frame", nil, parent)
  if a.SetClipsChildren then a:SetClipsChildren(true) end
  a.tiles = {}
  a.single = a:CreateTexture(nil, "BACKGROUND", nil, 1)
  a.single:SetAllPoints()
  a.single:Hide()
  a.bg = a:CreateTexture(nil, "BACKGROUND", nil, 0)
  a.bg:SetAllPoints()
  a.bg:SetColorTexture(0.06, 0.05, 0.04, 1)
  local function Crop()
    local ar = a.aspect
    local W, H = a:GetWidth(), a:GetHeight()
    if not (ar and W and H and W > 0 and H > 0) then return end
    local want = W / H
    local x0, x1, y0, y1 = 0, 1, 0, 1
    if want > ar then
      local h = ar / want
      y0, y1 = 0.5 - h / 2, 0.5 + h / 2
    else
      local w = want / ar
      x0, x1 = 0.5 - w / 2, 0.5 + w / 2
    end
    -- Teil eines Atlas (zB ein Banner von vier in einer Datei)
    local r = a.region
    if type(r) == "table" then
      local du, dv = r[2] - r[1], r[4] - r[3]
      x0, x1, y0, y1 = r[1] + x0 * du, r[1] + x1 * du, r[3] + y0 * dv, r[3] + y1 * dv
    end
    a.single:SetTexCoord(x0, x1, y0, y1)
  end
  local function Lay()
    Crop()
    local m = a.map
    if not m then return end
    local W, H = a:GetWidth(), a:GetHeight()
    if not W or W <= 0 then return end
    local s = W / m.lw
    local mh = m.lh * s
    -- Ausschnitt: um den Fokus (zB Spieler) herum, sonst Mitte
    local fy = (a.focusY or 0.5) * mh
    local off = math.max(0, math.min(mh - H, fy - H / 2))
    for i, tx in ipairs(a.tiles) do
      local c, r = (i - 1) % m.cols, math.floor((i - 1) / m.cols)
      tx:ClearAllPoints()
      tx:SetSize(m.tw * s, m.th * s)
      tx:SetPoint("TOPLEFT", a, "TOPLEFT", c * m.tw * s, -r * m.th * s + off)
    end
  end
  a:SetScript("OnSizeChanged", Lay)
  function a.Clear()
    a.map = nil
    a.aspect = nil
    a.region = nil
    for _, t in ipairs(a.tiles) do t:Hide() end
    a.single:Hide()
  end
  -- Zone als Bild: die Weltkarte der Zone, abgedunkelt
  function a.SetMap(mapID, focusY)
    a.Clear()
    if not (mapID and C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then return false end
    local okL, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local L = okL and layers and layers[1]
    local okT, files = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if not (L and okT and type(files) == "table" and #files > 0) then return false end
    local tw, th = L.tileWidth or 256, L.tileHeight or 256
    local lw, lh = L.layerWidth or 1002, L.layerHeight or 668
    local cols = math.ceil(lw / tw)
    for i, f in ipairs(files) do
      local tx = a.tiles[i]
      if not tx then tx = a:CreateTexture(nil, "BACKGROUND", nil, 1); a.tiles[i] = tx end
      tx:SetTexture(f)
      tx:SetTexCoord(0, 1, 0, 1)
      tx:Show()
    end
    a.map = { tw = tw, th = th, lw = lw, lh = lh, cols = cols }
    a.focusY = focusY
    Lay()
    return true
  end
  -- Datei oder Datei Nummer (Ladebildschirm): fuellt die Flaeche, Seitenverhaeltnis bleibt
  function a.SetFile(file, aspect, region)
    a.Clear()
    a.region = region
    if not file or a.single:SetTexture(file) == false then return false end
    a.single:SetVertexColor(1, 1, 1, 1)
    a.aspect = aspect or (4 / 3)
    Crop()
    a.single:Show()
    return true
  end
  -- Symbol gross und gedimmt, wenn es kein Bild gibt
  function a.SetIcon(icon)
    a.Clear()
    a.single:SetTexture(icon)
    a.single:SetTexCoord(0.15, 0.85, 0.3, 0.7)
    a.single:Show()
  end
  return a
end

-- Bildkarte: Bild, Verlauf, Schild oben rechts, Titel und Zeile unten links
function T.ArtCard(parent, w, h)
  local b = CreateFrame("Button", nil, parent, BD)
  b:SetSize(w or 200, h or 120)
  T.Skin(b, "inset")
  local IN = T.IsElv() and 1 or 3
  b.art = T.Art(b)
  b.art:SetPoint("TOPLEFT", IN, -IN); b.art:SetPoint("BOTTOMRIGHT", -IN, IN)
  b.art:SetFrameLevel(b:GetFrameLevel() + 1)
  local top = CreateFrame("Frame", nil, b)
  top:SetAllPoints(b.art)
  top:SetFrameLevel(b:GetFrameLevel() + 3)
  b.tint = top:CreateTexture(nil, "ARTWORK", nil, 4)
  b.tint:SetAllPoints(); b.tint:SetColorTexture(0, 0, 0, T.IsElv() and 0.25 or 0.12)
  b.shade = T.Shade(top, 0.88, 0.05)
  b.shade:SetAllPoints()
  local hl = top:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.07)
  b:SetHighlightTexture(hl)
  b.title = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
  b.title:SetPoint("BOTTOMLEFT", 12, 26); b.title:SetPoint("RIGHT", -12, 0)
  b.title:SetJustifyH("LEFT"); b.title:SetWordWrap(false)
  if T.IsElv() then b.title:SetTextColor(1, 1, 1) end
  b.sub = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  b.sub:SetPoint("BOTTOMLEFT", 12, 10); b.sub:SetPoint("RIGHT", -12, 0)
  b.sub:SetJustifyH("LEFT"); b.sub:SetWordWrap(false)
  b.sub:SetTextColor(0.85, 0.85, 0.85)
  b.badgeBg = top:CreateTexture(nil, "OVERLAY", nil, 1)
  b.badgeBg:SetColorTexture(0, 0, 0, 0.6)
  b.badge = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  b.badge:SetPoint("TOPRIGHT", -10, -9)
  b.badgeBg:SetPoint("TOPLEFT", b.badge, "TOPLEFT", -6, 3)
  b.badgeBg:SetPoint("BOTTOMRIGHT", b.badge, "BOTTOMRIGHT", 6, -3)
  function b.Set(title, sub, badge, badgeCol, dim)
    -- 20.2 (Log 14:36: Plan 2 Texte abgeschnitten): passend kuerzen, ganz steht er im Tooltip bzw der Seite
    if ns.FitText then ns.FitText(b.title, title or ""); ns.FitText(b.sub, sub or "")
    else b.title:SetText(title or ""); b.sub:SetText(sub or "") end
    b.badge:SetText(badge or "")
    b.badgeBg:SetShown(badge ~= nil and badge ~= "")
    local c = badgeCol or { T.Acc() }
    b.badge:SetTextColor(c[1], c[2], c[3])
    b.art:SetAlpha(dim and 0.45 or 1)
    if b.art.single.SetDesaturated then b.art.single:SetDesaturated(dim and true or false) end
    for _, t in ipairs(b.art.tiles) do if t.SetDesaturated then t:SetDesaturated(dim and true or false) end end
  end
  return b
end

-- Banner oben auf einer Seite: Bild, Schilder oben links, grosser Titel, Knoepfe rechts
function T.Hero(parent, h)
  local f = CreateFrame("Frame", nil, parent, BD)
  f:SetHeight(h or 150)
  T.Skin(f, "inset")
  local IN = T.IsElv() and 1 or 3
  f.art = T.Art(f)
  f.art:SetPoint("TOPLEFT", IN, -IN); f.art:SetPoint("BOTTOMRIGHT", -IN, IN)
  f.art:SetFrameLevel(f:GetFrameLevel() + 1)
  local top = CreateFrame("Frame", nil, f)
  top:SetAllPoints(f.art)
  top:SetFrameLevel(f:GetFrameLevel() + 3)
  f.top = top
  -- Kartenbilder sind hell (Pergament): etwas abdunkeln, damit es ruhig wirkt und Text lesbar bleibt
  f.tint = top:CreateTexture(nil, "ARTWORK", nil, 4)
  f.tint:SetAllPoints(); f.tint:SetColorTexture(0, 0, 0, T.IsElv() and 0.5 or 0.38)
  f.shade = T.Shade(top, 0.9, 0.12)
  f.shade:SetAllPoints()
  f.title = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
  f.title:SetPoint("BOTTOMLEFT", 18, 34); f.title:SetPoint("RIGHT", -240, 0)
  f.title:SetJustifyH("LEFT"); f.title:SetWordWrap(false)
  if T.IsElv() then f.title:SetTextColor(1, 1, 1) end
  f.sub = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  f.sub:SetPoint("BOTTOMLEFT", 18, 14); f.sub:SetPoint("RIGHT", -240, 0)
  f.sub:SetJustifyH("LEFT"); f.sub:SetWordWrap(false)
  f.sub:SetTextColor(0.88, 0.88, 0.88)
  f.pills = {}
  function f.Pills(list)
    local x = 16
    for i, p in ipairs(list or {}) do
      local pl = f.pills[i]
      if not pl then
        pl = {}
        pl.bg = top:CreateTexture(nil, "OVERLAY", nil, 1); pl.bg:SetColorTexture(0, 0, 0, 0.6)
        pl.t = top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
        f.pills[i] = pl
      end
      pl.t:ClearAllPoints(); pl.t:SetPoint("TOPLEFT", x + 6, -14)
      pl.t:SetText(p[1])
      local c = p[2] or { 0.9, 0.9, 0.9 }
      pl.t:SetTextColor(c[1], c[2], c[3])
      pl.bg:ClearAllPoints()
      pl.bg:SetPoint("TOPLEFT", pl.t, "TOPLEFT", -6, 4); pl.bg:SetPoint("BOTTOMRIGHT", pl.t, "BOTTOMRIGHT", 6, -4)
      pl.t:Show(); pl.bg:Show()
      x = x + (pl.t:GetStringWidth() or 60) + 20
    end
    for i = #(list or {}) + 1, #f.pills do f.pills[i].t:Hide(); f.pills[i].bg:Hide() end
  end
  -- Knoepfe rechts unten, von unten nach oben
  f.btns = {}
  function f.Button(text, primary, fn)
    local b = T.Button(top, text, 200, primary and 32 or 26, primary)
    b:SetScript("OnClick", fn)
    table.insert(f.btns, b)
    for i, x in ipairs(f.btns) do
      x:ClearAllPoints()
      local yy = 14
      for j = #f.btns, i + 1, -1 do yy = yy + f.btns[j]:GetHeight() + 6 end
      x:SetPoint("BOTTOMRIGHT", top, "BOTTOMRIGHT", -14, yy)
    end
    return b
  end
  return f
end

------------------------------------------------------------
-- Regler fuer die Spielweise: 7 Stufen auf einer Linie, Standard in der Mitte markiert.
-- Stufen, die Grinden brauchen, sind gesperrt, wenn Grinden aus ist.
------------------------------------------------------------
-- Simulation 1 bis 60 (Version 13.5): { Zeit im Verhaeltnis zu Standard, Quests mehr (minus: weniger) als Standard }
-- Tempo Regler: 2 Stufen als Schieberegler (Alles, Normal). Bei jeder Stufe steht, wie viel schneller
-- oder langsamer sie fuer dich ist als Normal (ns.TempoEstimate, mit deinen gemessenen Werten). Darunter der
-- Schalter Grinden an oder aus (gilt fuer beide).
T.GRIND_TIP = TR"An: die Route nimmt Grind Schritte, wo Grinden für dich schneller ist als eine Quest. Bei Alles nur, wenn es sonst keine Quests gibt.\n\nAus: nur Quests, kein Grinden."
function T.StepSlider(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(136)
  f.name = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
  f.name:SetPoint("TOPLEFT", 0, 0)
  f.text = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  f.text:SetPoint("TOPLEFT", f.name, "BOTTOMLEFT", 0, -4); f.text:SetPoint("RIGHT", f, "RIGHT", 0, 0)
  f.text:SetJustifyH("LEFT")
  f.line = f:CreateTexture(nil, "ARTWORK")
  f.line:SetHeight(4)
  f.line:SetColorTexture(1, 1, 1, 0.15)
  f.fill = f:CreateTexture(nil, "ARTWORK", nil, 1)
  f.fill:SetHeight(4)
  f.est = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  f.est:SetPoint("BOTTOMLEFT", 0, 0); f.est:SetPoint("RIGHT", f, "RIGHT", 0, 0); f.est:SetJustifyH("LEFT")
  f.est:SetWordWrap(true)
  -- Grinden ist jetzt ein eigener Ja/Nein Schalter darunter (T.QuestRows), nicht mehr im Regler
  f.dots, f.labels, f.pcts = {}, {}, {}
  local steps = ns.LEVEL_STEPS or {}
  for i, st in ipairs(steps) do
    local b = CreateFrame("Button", nil, f)
    b:SetSize(18, 18)
    b.t = b:CreateTexture(nil, "OVERLAY")
    b.t:SetAllPoints()
    b.t:SetTexture("Interface\\Buttons\\WHITE8x8")
    if b.t.SetMask then pcall(b.t.SetMask, b.t, ns.APATH .. "Media\\fw_mask_circle") end
    b:SetScript("OnClick", function() if ns.SetLevelStep then ns.SetLevelStep(i) end; f.Update() end)
    b:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(st.name .. (st.std and TR"  (Standard)" or ""))
      GameTooltip:AddLine(st.text, 1, 1, 1, true)
      if ns.TempoLine then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(ns.TempoLine(i), 0.5, 0.9, 1, true)
      end
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.dots[i] = b
    local l = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
    -- 20.1 (P6): "(Standard)" steht schon darunter als Vergleichswert, nicht doppelt
    l:SetText(st.short)
    f.labels[i] = l
    local pc = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    f.pcts[i] = pc
  end
  local function Lay()
    local w = f:GetWidth()
    if not w or w < 50 then return end
    local x0, x1, y = 46, w - 46, -50
    f.line:ClearAllPoints()
    f.line:SetPoint("LEFT", f, "TOPLEFT", x0, y); f.line:SetPoint("RIGHT", f, "TOPLEFT", x1, y)
    for i, b in ipairs(f.dots) do
      local x = x0 + (x1 - x0) * (i - 1) / math.max(1, #f.dots - 1)
      b:ClearAllPoints(); b:SetPoint("CENTER", f, "TOPLEFT", x, y)
      -- aussen buendig (links und rechts), damit lange Texte nicht aus dem Rahmen ragen
      local pt, px = "TOP", x
      if i == 1 then pt, px = "TOPLEFT", 0 elseif i == #f.dots then pt, px = "TOPRIGHT", w end
      f.labels[i]:ClearAllPoints(); f.labels[i]:SetPoint(pt, f, "TOPLEFT", px, y - 13)
      f.pcts[i]:ClearAllPoints(); f.pcts[i]:SetPoint(pt, f, "TOPLEFT", px, y - 27)
    end
  end
  f:SetScript("OnSizeChanged", Lay)
  function f.Update()
    Lay()
    local cur = ns.LevelStep and ns.LevelStep() or 2
    local st = steps[cur] or {}
    f.name:SetText(st.name and (TR"Tempo: " .. st.name .. (st.std and TR"  |cff9d9d9d(Standard)|r" or "")) or "")
    f.text:SetText(st.text or "")
    local r, g, bb = T.Acc()
    for i, b in ipairs(f.dots) do
      if i == cur then b.t:SetVertexColor(r, g, bb, 1) else b.t:SetVertexColor(0.75, 0.75, 0.75, 1) end
      f.pcts[i]:SetText(ns.TempoPctText and ns.TempoPctText(i) or "")
    end
    local d = f.dots[cur]
    f.fill:ClearAllPoints()
    if d then
      f.fill:SetPoint("LEFT", f.line, "LEFT", 0, 0); f.fill:SetPoint("RIGHT", d, "CENTER", 0, 0)
      f.fill:SetColorTexture(r, g, bb, 0.8)
    end
    f.est:SetText(ns.TempoLine and ns.TempoLine(cur) or "")
  end
  f:SetScript("OnShow", f.Update)
  -- Prozent kommen aus deinen gemessenen Werten: ab und zu neu zeigen
  local acc = 0
  f:SetScript("OnUpdate", function(_, e)
    acc = acc + e
    if acc < 5 then return end
    acc = 0
    f.Update()
  end)
  return f
end

-- Einfacher Schieberegler im Look vom Schritt Regler: Linie, Fuellung in der Akzentfarbe, runder Knopf.
-- get() liefert den Wert, set(v) wird beim Ziehen aufgerufen.
function T.ValueSlider(parent, lo, hi, step, get, set)
  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetHeight(20)
  s:SetMinMaxValues(lo, hi)
  s:SetValueStep(step)
  if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
  s:EnableMouse(true)
  s.line = s:CreateTexture(nil, "BACKGROUND")
  s.line:SetHeight(4)
  s.line:SetPoint("LEFT", s, "LEFT", 0, 0); s.line:SetPoint("RIGHT", s, "RIGHT", 0, 0)
  s.line:SetColorTexture(1, 1, 1, 0.15)
  s.thumb = s:CreateTexture(nil, "OVERLAY")
  s.thumb:SetSize(14, 14)
  s.thumb:SetTexture("Interface\\Buttons\\WHITE8x8")
  if s.thumb.SetMask then pcall(s.thumb.SetMask, s.thumb, ns.APATH .. "Media\\fw_mask_circle") end
  s:SetThumbTexture(s.thumb)
  s.fill = s:CreateTexture(nil, "ARTWORK")
  s.fill:SetHeight(4)
  s.fill:SetPoint("LEFT", s.line, "LEFT", 0, 0)
  -- Fuellung bis zur Mitte vom Knopf
  local function Fill()
    local w = s:GetWidth() or 0
    local v = s:GetValue() or lo
    local k = (hi > lo) and (v - lo) / (hi - lo) or 0
    s.fill:SetWidth(math.max(1, 7 + k * math.max(0, w - 14)))
  end
  s:SetScript("OnSizeChanged", Fill)
  local quiet = false
  function s.Update()
    local r, g, b = T.Acc()
    s.thumb:SetVertexColor(r, g, b, 1)
    s.fill:SetColorTexture(r, g, b, 0.8)
    quiet = true
    s:SetValue(get() or lo)
    quiet = false
    Fill()
    if s.OnChanged then s.OnChanged() end
  end
  s:SetScript("OnValueChanged", function(_, v)
    Fill()
    if quiet then return end
    v = math.floor(v / step + 0.5) * step
    set(v)
    if s.OnChanged then s.OnChanged() end
  end)
  s:SetScript("OnShow", s.Update)
  return s
end
