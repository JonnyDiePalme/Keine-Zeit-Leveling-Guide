local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Dungeons: alle Dungeons mit Level, ihre Quests (mit Vorquests und Folgequests)
-- und eine optimale Route: Vorquests und Annehmen, zum Eingang, danach Abgeben.

local QDB, ZDB, QLib, QPlayer
local areaUi = {}

-- Level und deutscher Name (Questie Namen sind englisch)
-- Schlachtzuege (eigener Reiter) mit deutschen Namen
ns.RAID_KEYS = {
  ["Zul'Gurub"] = true, ["Molten Core"] = true, ["Blackwing Lair"] = true, ["Ruins of Ahn'Qiraj"] = true,
  ["Temple of Ahn'Qiraj"] = true, ["Naxxramas"] = true, ["Onyxia's Lair"] = true,
  ["Karazhan"] = true, ["Gruul's Lair"] = true, ["Magtheridon's Lair"] = true, ["Serpentshrine Cavern"] = true,
  ["Tempest Keep"] = true, ["The Eye"] = true, ["Hyjal Summit"] = true, ["Black Temple"] = true, ["Sunwell Plateau"] = true, ["Zul'Aman"] = true,
}
ns.RAID_NAMES = {
  ["Molten Core"] = TR"Geschmolzener Kern", ["Blackwing Lair"] = TR"Pechschwingenhort", ["Ruins of Ahn'Qiraj"] = "Ruinen von Ahn'Qiraj",
  ["Temple of Ahn'Qiraj"] = "Tempel von Ahn'Qiraj", ["Onyxia's Lair"] = "Onyxias Hort",
}
-- Bilder: Blizzard Dungeon Symbole (Interface\LFGFrame), sonst ein Ersatz
ns.DUNGEON_ICON = {
  ["Ragefire Chasm"] = "RagefireChasm", ["Wailing Caverns"] = "WailingCaverns", ["The Deadmines"] = "Deadmines",
  ["Shadowfang Keep"] = "ShadowfangKeep", ["Blackfathom Deeps"] = "BlackfathomDeeps", ["The Stockade"] = "StormwindStockades",
  ["Gnomeregan"] = "Gnomeregan", ["Razorfen Kraul"] = "RazorfenKraul", ["Scarlet Monastery"] = "ScarletMonastery",
  ["Razorfen Downs"] = "RazorfenDowns", ["Uldaman"] = "Uldaman", ["Zul'Farrak"] = "ZulFarak", ["Maraudon"] = "Maraudon",
  ["The Temple of Atal'Hakkar"] = "SunkenTemple", ["Blackrock Depths"] = "BlackrockDepths", ["Blackrock Spire"] = "BlackrockSpire",
  ["Dire Maul"] = "DireMaul", ["Scholomance"] = "Scholomance", ["Stratholme"] = "Stratholme",
  ["Zul'Gurub"] = "ZulGurub", ["Molten Core"] = "MoltenCore", ["Blackwing Lair"] = "BlackwingLair", ["Ruins of Ahn'Qiraj"] = "AQRuins",
  ["Temple of Ahn'Qiraj"] = "AQTemple", ["Naxxramas"] = "Naxxramas", ["Onyxia's Lair"] = "OnyxiasLair",
}
ns.BG_ICON = {
  ["Warsong Gulch"] = "Interface\\Icons\\INV_Misc_Rune_07", ["Arathi Basin"] = "Interface\\Icons\\INV_Jewelry_Amulet_07",
  ["Alterac Valley"] = "Interface\\Icons\\INV_Jewelry_Necklace_21",
}
function ns.DungeonIcon(d)
  if not d then return "Interface\\Icons\\INV_Misc_Key_03", false end
  if d.pvp then return ns.BG_ICON[d.key] or "Interface\\Icons\\INV_BannerPVP_02", false end
  local n = ns.DUNGEON_ICON[d.key]
  if n then return "Interface\\LFGFrame\\LFGIcon-" .. n, true end
  return d.raid and "Interface\\Icons\\INV_Misc_Head_Dragon_01" or "Interface\\Icons\\INV_Misc_Key_03", false
end
-- Bild setzen, mit Ersatz falls das Spiel die Datei nicht hat
function ns.SetDungeonIcon(tex, d)
  local path, lfg = ns.DungeonIcon(d)
  local ok = tex:SetTexture(path)
  if ok == false then tex:SetTexture(d and d.raid and "Interface\\Icons\\INV_Misc_Head_Dragon_01" or "Interface\\Icons\\INV_Misc_Key_03"); lfg = false end
  if lfg then tex:SetTexCoord(0, 1, 0, 1) else tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
end

-- Grosse Bilder wie im Dungeon Journal: Ladebildschirme aus dem Spiel, mehrere Namen probieren
local LS = "Interface\\Glues\\LoadingScreens\\"
local DJ = "Interface\\AddOns\\ForeverDungeonJournal\\Media\\"
local ART = {
  ["Ragefire Chasm"] = { "LoadScreenRagefireChasm" }, ["Wailing Caverns"] = { "LoadScreenWailingCaverns" },
  ["The Deadmines"] = { "LoadScreenDeadmines" }, ["Shadowfang Keep"] = { "LoadScreenShadowFangKeep" },
  ["Blackfathom Deeps"] = { "LoadScreenBlackFathomDeeps" }, ["The Stockade"] = { 131870, "LoadScreenStormwindStockade" },
  ["Gnomeregan"] = { "LoadScreenGnomeregan" }, ["Razorfen Kraul"] = { 131865, "LoadScreenRazorfenKraul" },
  ["Scarlet Monastery"] = { "LoadScreenMonastery", "LoadScreenScarletMonastery" }, ["Razorfen Downs"] = { "LoadScreenRazorfenDowns" },
  ["Uldaman"] = { "LoadScreenUldaman" }, ["Zul'Farrak"] = { "LoadScreenZulFarrak" }, ["Maraudon"] = { "LoadScreenMaraudon" },
  ["The Temple of Atal'Hakkar"] = { "LoadScreenSunkenTemple" }, ["Blackrock Depths"] = { "LoadScreenBlackrockDepths" },
  ["Blackrock Spire"] = { "LoadScreenBlackrockSpire" }, ["Dire Maul"] = { "LoadScreenDireMaul" },
  ["Scholomance"] = { "LoadScreenScholomance" }, ["Stratholme"] = { "LoadScreenStrathome", "LoadScreenStratholme" },
  ["Excavation Site: Wetlands"] = { 7963777 }, ["City of Dalaran"] = { 7963775 },
  ["Molten Core"] = { "LoadScreenMoltenCore" }, ["Blackwing Lair"] = { "LoadScreenBlackwingLair" },
  ["Zul'Gurub"] = { "LoadScreenZulGurub" }, ["Onyxia's Lair"] = { "LoadScreenOnyxia", "LoadScreenOnyxiasLair" },
  ["Ruins of Ahn'Qiraj"] = { "LoadScreenAhnQiraj", "LoadScreenAQ20" },
  ["Temple of Ahn'Qiraj"] = { "LoadScreenAhnQiraj", "LoadScreenAQ40" },
  ["Naxxramas"] = { "LoadScreenNaxxramas" },
  ["Warsong Gulch"] = { "LoadScreenWarsongGulch" }, ["Arathi Basin"] = { "LoadScreenArathiBasin" },
  ["Alterac Valley"] = { "LoadScreenAlteracValley", "LoadScreenPvPBattleground" },
  -- Kontinente (Journal Stil: Bilder fuer Leveln, Reisen usw.)
  ["Kalimdor"] = { "LoadScreenKalimdor", "LoadScreenKalimdorClassic" },
  ["Eastern Kingdoms"] = { "LoadScreenEasternKingdom", "LoadScreenEasternKingdoms", "LoadScreenEasternKingdomClassic" },
}
local artCache = {}
local function HasDJ()
  local info = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
  if not info then return false end
  local ok, name = pcall(info, "ForeverDungeonJournal")
  return ok and name ~= nil
end
local function ResolveArt(key)
  if artCache[key] ~= nil then return artCache[key] end
  local found = false
  for _, c in ipairs(ART[key] or {}) do
    if type(c) == "number" then found = c; break end
    if c:find("^Interface\\AddOns") then
      if HasDJ() then found = c; break end
    else
      local path = LS .. c
      if GetFileIDFromPath then
        local ok, id = pcall(GetFileIDFromPath, path)
        if ok and type(id) == "number" and id > 0 then found = id; break end
      else
        found = path; break
      end
    end
  end
  -- sonst der Hintergrund aus dem Gruppensucher
  if not found and ns.DUNGEON_ICON[key] and GetFileIDFromPath then
    local ok, id = pcall(GetFileIDFromPath, "Interface\\LFGFrame\\UI-LFG-BACKGROUND-" .. ns.DUNGEON_ICON[key])
    if ok and type(id) == "number" and id > 0 then found = id end
  end
  artCache[key] = found
  return found
end
-- Bild setzen: Ladebildschirm, sonst das kleine Symbol gross mit Stein dahinter
-- Einheitlicher Look fuer alle Dungeon Bilder (Original bleibt, nur beim Anzeigen angepasst):
-- leicht entsaettigt, Farbton passend zur Oberflaeche, Rand und Unterkante dunkler fuer den Text
local function Grad(t, orient, a1, a2)
  t:SetColorTexture(1, 1, 1, 1)
  if CreateColor and pcall(t.SetGradient, t, orient, CreateColor(0, 0, 0, a1), CreateColor(0, 0, 0, a2)) then return end
  if t.SetGradientAlpha then pcall(t.SetGradientAlpha, t, orient, 0, 0, 0, a1, 0, 0, 0, a2); return end
  t:SetColorTexture(0, 0, 0, (a1 + a2) / 2)
end
local function Style(tex, on)
  local f = tex.fwStyle
  if not f then
    if not on then return end
    local p = tex:GetParent()
    if type(p) ~= "table" or not p.CreateTexture then return end
    local layer, sub = tex:GetDrawLayer()
    sub = math.min(7, (tonumber(sub) or 0) + 1)
    f = {}
    for _, k in ipairs({ "bot", "top", "left", "right" }) do
      local t = p:CreateTexture(nil, layer or "ARTWORK", nil, sub)
      f[k] = t
    end
    f.bot:SetPoint("BOTTOMLEFT", tex); f.bot:SetPoint("BOTTOMRIGHT", tex); f.bot:SetPoint("TOP", tex, "CENTER", 0, 0)
    Grad(f.bot, "VERTICAL", 0.8, 0)
    f.top:SetPoint("TOPLEFT", tex); f.top:SetPoint("TOPRIGHT", tex); f.top:SetHeight(18)
    Grad(f.top, "VERTICAL", 0, 0.45)
    f.left:SetPoint("TOPLEFT", tex); f.left:SetPoint("BOTTOMLEFT", tex); f.left:SetWidth(24)
    Grad(f.left, "HORIZONTAL", 0.45, 0)
    f.right:SetPoint("TOPRIGHT", tex); f.right:SetPoint("BOTTOMRIGHT", tex); f.right:SetWidth(24)
    Grad(f.right, "HORIZONTAL", 0, 0.45)
    tex.fwStyle = f
  end
  for _, t in pairs(f) do t:SetShown(on and true or false) end
  if on then
    local elv = ns.T and ns.T.IsElv and ns.T.IsElv()
    if tex.SetDesaturation then tex:SetDesaturation(elv and 0.35 or 0.15) end
    if elv then tex:SetVertexColor(0.86, 0.9, 0.95, 1) else tex:SetVertexColor(1, 0.93, 0.8, 1) end
  elseif tex.SetDesaturation then
    tex:SetDesaturation(0)
  end
end
local function Styled(tex, ok)
  pcall(Style, tex, ok)
  return ok
end

function ns.SetDungeonArt(tex, d, bottomCrop)
  local art = d and ResolveArt(d.key)
  if art and tex:SetTexture(art) ~= false then
    tex:SetTexCoord(0.02, 0.98, 0.22, bottomCrop or 0.82)
    tex:SetVertexColor(1, 1, 1, 1)
    return Styled(tex, true)
  end
  -- Original Ladebildschirm fehlt im Spiel: eigenes Bild, sonst allgemeiner Eingang
  if d and d.key and ns.TestLog and not artCache["log:" .. d.key] then
    artCache["log:" .. d.key] = true
    ns.TestLog("BILD", "kein Ladebildschirm im Spiel fuer " .. d.key)
  end
  -- eigenes Bild: so zuschneiden, dass es zur Flaeche passt (nicht verzerrt)
  local tw, th = tex:GetWidth() or 0, tex:GetHeight() or 0
  local asp = (tw > 4 and th > 4) and tw / th or nil
  if d and not d.pvp and ns.T and ns.T.DungeonArt and ns.T.DungeonArt(tex, d.key, true,  math.min(1, ((bottomCrop or 0.82) - 0.22) / 0.6), asp) then return Styled(tex, true) end
  tex:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock")
  tex:SetTexCoord(0, 1, 0, 0.4)
  tex:SetVertexColor(0.55, 0.55, 0.55, 1)
  return Styled(tex, false)
end

local INFO = {
  ["Ragefire Chasm"]            = { 13, 18, TR"Flammenschlund" },
  ["Wailing Caverns"]           = { 17, 24, TR"Höhlen des Wehklagens" },
  ["The Deadmines"]             = { 17, 26, TR"Die Todesminen" },
  ["Ruins of Lordaeron"]        = { 15, 20, TR"Ruinen von Lordaeron (Forever)" },
  ["Shadowfang Keep"]           = { 22, 30, TR"Burg Schattenfang" },
  ["Blackfathom Deeps"]         = { 24, 32, TR"Tiefschwarze Grotte" },
  ["The Stockade"]              = { 24, 32, TR"Das Verlies" },
  ["Excavation Site: Wetlands"] = { 24, 29, TR"Ausgrabung Sumpfland (Forever)" },
  ["City of Dalaran"]           = { 28, 33, TR"Stadt Dalaran (Forever)" },
  ["Gnomeregan"]                = { 29, 38, "Gnomeregan" },
  ["Razorfen Kraul"]            = { 29, 38, TR"Kral der Klingenhauer" },
  ["Scarlet Monastery"]         = { 26, 45, TR"Scharlachrotes Kloster" },
  ["Razorfen Downs"]            = { 37, 46, TR"Hügel der Klingenhauer" },
  ["Uldaman"]                   = { 41, 51, "Uldaman" },
  ["Zul'Farrak"]                = { 44, 54, "Zul'Farrak" },
  ["Maraudon"]                  = { 46, 55, "Maraudon" },
  ["The Temple of Atal'Hakkar"] = { 50, 56, "Tempel von Atal'Hakkar" },
  ["Blackrock Depths"]          = { 52, 60, TR"Schwarzfelstiefen" },
  ["Blackrock Spire"]           = { 55, 60, TR"Schwarzfelsspitze" },
  ["Dire Maul"]                 = { 55, 60, TR"Düsterbruch" },
  ["Scholomance"]               = { 58, 60, "Scholomance" },
  ["Stratholme"]                = { 58, 60, "Stratholme" },
}

-- passender Dungeon fuer einen "Level fehlt" Hinweis: ein bis zwei Namen fuer dein Level (deine Seite zuerst)
local SIDE = { ["Ragefire Chasm"] = "Horde", ["Wailing Caverns"] = "Horde", ["Razorfen Kraul"] = "Horde", ["Razorfen Downs"] = "Horde",
  ["The Deadmines"] = "Alliance", ["The Stockade"] = "Alliance", ["Gnomeregan"] = "Alliance" }
function ns.DungeonSuggest(L, one)
  L = math.floor(L or 1)
  local fac = UnitFactionGroup and UnitFactionGroup("player")
  local list = {}
  for key, info in pairs(INFO) do
    local nm = info[3]
    local forever = type(nm) == "string" and nm:find("Forever", 1, true)
    local side = SIDE[key]
    if not forever and info[1] <= L + 1 and info[2] >= L + 2 and (not side or side == fac) then
      if ns.EN then nm = key end
      list[#list + 1] = { nm = nm, d = math.abs((info[1] + info[2]) / 2 - (L + 1)) }
    end
  end
  if #list == 0 then return nil end
  table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.nm < b.nm end)
  if #list >= 2 and not one then return (TR"%s oder %s"):format(list[1].nm, list[2].nm) end
  return list[1].nm
end

-- 17.9: Questie fuehrt die Tiefenbahn als Dungeon. Sie ist aber eine Bahn mit normalen Solo Quests (Monty, Nipsy):
-- nicht in die Dungeon Liste und ihre Quests nicht als Dungeon Quests (sonst fehlen sie bei Dungeon Quests aus)
local NOT_DUNGEON = { ["Deeprun Tram"] = true }
ns.NOT_DUNGEON = NOT_DUNGEON
ns.dungeons = nil      -- Liste, nach Level sortiert
local byArea = {}      -- Dungeon Zone (areaId) -> Dungeon
local building

local function Q(id, k)
  local ok, v = pcall(QDB.QueryQuestSingle, id, k)
  if not ok then return end
  -- 19.34 (Pruefer 09:42 LEICHT 4): Vorquest Ketten mit der Daten Korrektur (vorquest_fehlt), wie die Route
  if k == "preQuestSingle" and ns.DKPreSingle then return ns.DKPreSingle(id, v) end
  if k == "preQuestGroup" and ns.DKPreGroup then return ns.DKPreGroup(id, v) end -- 19.34 (vorquest_1934): negative Id
  -- 1.3q (Daten 13): Quest fehlt in Questie ganz, Name aus der Korrektur (Questie geht vor)
  if k == "name" and ns.DKMissQuest then
    local fq = ns.DKMissQuest(id, v ~= nil)
    if fq then return fq.name end
  end
  return v
end
-- 1.3q: Questlevel und Mindestlevel, fuer Quests ohne Questie Eintrag aus der Korrektur. Gibt ok, ql, rl wie pcall
local function QLv(qid)
  local ok, ql, rl = pcall(QLib.GetEffectiveQuestLevel, qid)
  if ok and ql then return ok, ql, rl end
  local fq = ns.DKMissQuest and ns.DKMissQuest(qid, false)
  if fq and fq.level then return true, fq.level, fq.min or fq.level end
  return ok, ql, rl
end
-- 1.3q: Geber aus der Korrektur, nur wenn Questie keinen hat (by leer). Gibt Name, Zone (uiMap), x, y, innen
local function DKGiverOf(qid, by)
  local has = by and ((by[1] and by[1][1]) or (by[2] and by[2][1])) and true or false
  local g = ns.DKGiver and ns.DKGiver(qid, has)
  if not g then return nil end
  return g.name, g.map, g.x, g.y, g.innen
end
local function N(id, k) local ok, v = pcall(QDB.QueryNPCSingle, id, k); if ok then return v end end
local function O(id, k)
  if not QDB.QueryObjectSingle then return end
  local ok, v = pcall(QDB.QueryObjectSingle, id, k); if ok then return v end
end

local function Ui(area)
  local u = areaUi[area]
  if u == nil then
    local ok, ui = pcall(ZDB.GetUiMapIdByAreaId, ZDB, area)
    u = (ok and ui) or false
    areaUi[area] = u
  end
  return u or nil
end

-- Volk Bit pruefen ohne 32 Bit Grenze (Forever Voelker haben hohe Bits)
local function HasBit(mask, bitIndex)
  if not mask or mask == 0 then return true end
  return math.floor(mask / 2 ^ bitIndex) % 2 == 1
end

local function Allowed(qid)
  local _, _, classID = UnitClass("player")
  local _, _, raceID = UnitRace("player")
  local rc, rr = Q(qid, "requiredClasses"), ns.DKRaces(qid, Q(qid, "requiredRaces"))
  if rc and rc > 0 and classID and not HasBit(rc, classID - 1) then return false end
  if rr and rr > 0 and raceID and not ns.RaceOK(rr, raceID) then return false end
  return true
end

-- Dungeon ohne eine Quest fuer dich (andere Fraktion, Klasse): wird in den Listen ausgeblendet
function ns.DungeonHidden(d)
  return d and not d.pvp and #(d.quests or {}) == 0 and true or false
end

------------------------------------------------------------
-- Index: Dungeons und ihre Quests
------------------------------------------------------------
function ns.BuildDungeonIndex(done)
  if ns.dungeons then if done then done() end return end
  if building then return end
  if not ns.QDBAccess then return end
  QDB, ZDB, QLib, QPlayer = ns.QDBAccess()
  if not QDB then
    -- Questie braucht nach dem Start etwas: selbst nochmal versuchen statt ewig "wird geladen"
    -- nur eine Warteschleife, auch wenn die Seite jede Sekunde fragt
    if ns.dungRetry then return end
    ns.dungRetry = true
    if ns.TestLog then ns.TestLog("DUNGEON", "Questie Daten noch nicht da, neuer Versuch in 3s") end
    C_Timer.After(3, function() ns.dungRetry = false; ns.BuildDungeonIndex(done) end)
    return
  end
  local src = ZDB.private and ZDB.private.dungeons
  if type(src) ~= "table" then
    if not ns.dungWarned then ns.dungWarned = true; ns.Print(TR"Questie hat keine Dungeon Liste") end
    return
  end
  building = true
  local byName = {}
  for area, e in pairs(src) do
    local info = not NOT_DUNGEON[e[1]] and INFO[e[1]] or nil
    if NOT_DUNGEON[e[1]] then e = {} end
    -- neuer Dungeon, den ich nicht kenne (z.B. nach einem Questie Update): Name aus Questie,
    -- Level wird spaeter aus seinen Quests bestimmt
    if not info and type(e[1]) == "string" then info = { 0, 0, e[1], auto = true } end
    if info then
      local d = byName[e[1]]
      if not d then
        -- englischer Client: der Questie Schluessel ist schon der englische Name (ausser Forever Dungeons)
        local nm = info[3]
        if ns.EN and not info.auto and type(nm) == "string" and not nm:find("Forever", 1, true) then nm = e[1] end
        d = { key = e[1], name = nm, min = info[1], max = info[2], areas = {}, quests = {}, auto = info.auto }
        byName[e[1]] = d
        local loc = type(e[4]) == "table" and e[4][1]
        if loc then
          local ui = Ui(loc[1])
          if ui then d.entrance = { ui, loc[2] / 100, loc[3] / 100 } end
        end
      end
      byArea[area] = d
      for _, alt in ipairs(e[2] or {}) do byArea[alt] = d end
    end
  end
  local list = {}
  for _, d in pairs(byName) do table.insert(list, d) end
  table.sort(list, function(a, b) return a.min < b.min end)

  -- alle Quests einmal durchgehen: zu welchem Dungeon gehoeren sie?
  local ids = {}
  local lib = LibQuestieDB
  local all = lib and lib.Quest and lib.Quest.GetAllIds and lib.Quest.GetAllIds()
  if type(all) == "table" then ids = all else for id in pairs(QDB.QuestPointers or {}) do ids[#ids + 1] = id end end
  local i = 0
  local SafeStep
  local function Step()
    local n = 0
    while i < #ids and n < 400 do
      i = i + 1
      n = n + 1
      local qid = ids[i]
      local zs = Q(qid, "zoneOrSort")
      local d = zs and byArea[zs]
      if d and Allowed(qid) then table.insert(d.quests, qid) end
    end
    if i < #ids then C_Timer.After(0, SafeStep); return end
    -- 1.3q (Daten 13): Quests, die Questie gar nicht hat, aus der Korrektur in ihren Dungeon (nur eigene Fraktion)
    if ns.DKMissQuestIds then
      local fac = UnitFactionGroup and UnitFactionGroup("player")
      for _, qid in ipairs(ns.DKMissQuestIds()) do
        local okN, nm = pcall(QDB.QueryQuestSingle, qid, "name")
        local fq = ns.DKMissQuest(qid, okN and nm ~= nil)
        if fq and fq.dungeon and (not fq.fac or fq.fac == fac) then
          for _, d in ipairs(list) do
            if d.key == fq.dungeon or d.name == fq.dungeon then
              local dup = false
              for _, q0 in ipairs(d.quests) do if q0 == qid then dup = true end end
              if not dup then table.insert(d.quests, qid); d.dkQ = d.dkQ or {}; d.dkQ[qid] = true end
              break
            end
          end
        end
      end
    end
    -- unbekannte Dungeons: Level aus den Quests, ohne Quests weglassen
    for k = #list, 1, -1 do
      local d = list[k]
      if d.auto then
        local lo, hi
        for _, qid in ipairs(d.quests) do
          local ok, ql = QLv(qid)
          if ok and ql then lo = math.min(lo or ql, ql); hi = math.max(hi or ql, ql) end
        end
        if lo then d.min, d.max = math.max(1, lo - 3), hi + 2 else table.remove(list, k) end
      end
    end
    table.sort(list, function(a, b) return a.min < b.min end)
    -- Schlachtfelder in eine eigene Liste (Reiter PvP)
    local BG = { ["Alterac Valley"] = true, ["Warsong Gulch"] = true, ["Arathi Basin"] = true }
    local bgs = {}
    for k = #list, 1, -1 do
      local d = list[k]
      if BG[d.key] or (d.name and (d.name:find("Alteractal") or d.name:find("Kriegshymnenschlucht") or d.name:find("Arathibecken"))) then
        d.pvp = true
        table.insert(bgs, 1, d)
        table.remove(list, k)
      end
    end
    ns.battlegrounds = bgs
    -- Schlachtzuege in eine eigene Liste (Reiter Raids)
    local raids = {}
    for k = #list, 1, -1 do
      local d = list[k]
      if ns.RAID_KEYS[d.key] then
        d.raid = true
        if ns.RAID_NAMES[d.key] and not ns.EN then d.name = ns.RAID_NAMES[d.key] end
        table.insert(raids, 1, d)
        table.remove(list, k)
      end
    end
    ns.raids = raids
    local both = {}
    for _, d in ipairs(list) do table.insert(both, d) end
    for _, d in ipairs(bgs) do table.insert(both, d) end
    for _, d in ipairs(raids) do table.insert(both, d) end
    for _, d in ipairs(both) do
      table.sort(d.quests, function(a, b)
        local okA, la = QLv(a)
        local okB, lb = QLv(b)
        return (okA and la or 0) < (okB and lb or 0)
      end)
    end
    ns.dungeons = list
    building = false
    if ns.TestLog then ns.TestLog("DUNGEON", (TR"Liste fertig: %d Dungeons, %d Raids, %d Schlachtfelder"):format(#list, #raids, #bgs)) end
    if done then done() end
  end
  -- Fehler beim Aufbau: nicht haengen bleiben, mitschreiben und mit dem weitermachen, was da ist
  SafeStep = function()
    local ok, err = pcall(Step)
    if not ok then
      if ns.TestLog then ns.TestLog("FEHLER", "Dungeon Liste: " .. tostring(err)) end
      building = false
      ns.dungeons = ns.dungeons or list
      if done then pcall(done) end
    end
  end
  SafeStep()
end

------------------------------------------------------------
-- Quest Status und Kette
------------------------------------------------------------
local function Complete(qid)
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  return c and c[qid] and true or false
end
local function InLog(qid)
  local l = QPlayer and QPlayer.currentQuestlog
  return l and l[qid] and true or false
end

local function Who(by)
  local npc = by and by[1] and by[1][1]
  local obj = by and by[2] and by[2][1]
  local name, sp
  if npc then name, sp = N(npc, "name"), N(npc, "spawns")
  elseif obj then name, sp = O(obj, "name"), O(obj, "spawns") end
  local zone
  for area, coords in pairs(type(sp) == "table" and sp or {}) do
    local ui = Ui(area)
    if ui and type(coords) == "table" and coords[1] then zone = ui; break end
  end
  return name or "?", zone, npc
end

function ns.QuestReqLevel(qid)
  local ok, ql, rl = QLv(qid)
  if ok then return ql, rl end
end

function ns.QuestStatus(qid)
  if not QLib and ns.QDBAccess then QDB, ZDB, QLib, QPlayer = ns.QDBAccess() end
  if not QLib then return "open", "" end
  if Complete(qid) then return "done", TR"|cff6d6d6derledigt|r" end
  if InLog(qid) then
    local p = ns.logProgress and ns.logProgress[qid]
    if p and p.complete then return "ready", TR"|cff40ff40fertig, abgeben|r" end
    return "log", TR"|cff4dccffim Log|r"
  end
  local okL, ql, rl = QLv(qid)
  local L = UnitLevel("player")
  if okL and rl and L < rl then return "level", (TR"|cffff5050ab Level %d|r"):format(rl) end
  local repOk, repTxt = true, nil
  if ns.RepCheck then repOk, repTxt = ns.RepCheck(qid) end
  if not repOk then return "rep", (TR"|cffff5050Ruf fehlt: %s|r"):format(repTxt or "?") end
  local pre = ns.MissingPre and ns.MissingPre(qid)
  if pre then return "pre", (TR"|cffff9030Vorquest fehlt: %s|r"):format(pre.name) end
  return "open", TR"|cffffd100annehmbar|r"
end

-- Kette: Vorquests zurueck bis zum Anfang, dann diese Quest, dann Folgequests
function ns.QuestChain(qid)
  local back = {}
  local cur = qid
  for _ = 1, 8 do
    local pre = Q(cur, "preQuestSingle")
    local grp = Q(cur, "preQuestGroup")
    local p = (type(pre) == "table" and pre[1]) or (type(grp) == "table" and grp[1])
    if not p then break end
    table.insert(back, 1, p)
    cur = p
  end
  local chain = {}
  for _, id in ipairs(back) do table.insert(chain, id) end
  table.insert(chain, qid)
  local nxt = Q(qid, "nextQuestInChain")
  local seen = { [qid] = true }
  for _ = 1, 8 do
    if type(nxt) ~= "number" or nxt <= 0 or seen[nxt] then break end
    seen[nxt] = true
    table.insert(chain, nxt)
    nxt = Q(nxt, "nextQuestInChain")
  end
  return chain
end

------------------------------------------------------------
-- Zugang: lange Questreihen fuer Schluessel und Einstimmung
-- (IDs aus der Questie Forever Datenbank geprueft). Mehrere Enden = Allianz und Horde
-- oder verschiedene Rufstufen, es zaehlt das erste, das fuer dich passt.
-- need: true = ohne geht es nicht rein, sonst nur eine Abkuerzung
------------------------------------------------------------
ns.ATTUNE = {
  ["Onyxia's Lair"]     = { what = TR"Drachenfeueramulett", need = true, ends = { 6502, 6602 },
    note = TR"Ohne das Amulett kommst du nicht zu Onyxia. Lange Reihe, Teile davon in Schwarzfelstiefen und der Schwarzfelsspitze." },
  ["Molten Core"]       = { what = TR"Einstimmung auf den Kern", ends = { 7848 },
    note = TR"Danach bringt dich Lothos Riftwaker direkt in den Kern, ohne Weg durch Schwarzfelstiefen." },
  ["Blackwing Lair"]    = { what = TR"Befehl von Schwarzfaust", need = true, ends = { 7761 },
    note = TR"Der Brief droppt in der oberen Schwarzfelsspitze. Ohne ihn lässt dich die Kugel nicht in den Hort." },
  ["Naxxramas"]         = { what = "Zugang Naxxramas", need = true, ends = { 9121, 9122, 9123 },
    note = TR"Je nach Ruf bei der Argentumdämmerung brauchst du mehr oder weniger Material." },
  ["Blackrock Spire"]   = { what = TR"Siegel des Aufstiegs", need = true, ends = { 4743 },
    note = TR"Ohne Siegel geht die Tür zur oberen Schwarzfelsspitze nicht auf." },
  ["Scholomance"]       = { what = TR"Skelettschlüssel", need = true, ends = { 5505, 5511 },
    note = TR"Ohne Schlüssel kommst du nicht in die Scholomance." },
  ["Blackrock Depths"]  = { what = TR"Schattenschmiedeschlüssel", ends = { 3802 },
    note = TR"Öffnet Türen in Schwarzfelstiefen und spart viel Weg." },
  ["Maraudon"]          = { what = TR"Szepter von Celebras", ends = { 7046 },
    note = TR"Damit kommst du direkt in den inneren Teil von Maraudon." },
}

-- bei Vorquest "eine von mehreren" die nehmen, die schon erledigt ist oder fuer dich passt
local function PickOne(list)
  local first
  for _, id in ipairs(list) do
    if type(id) == "number" and Allowed(id) and Q(id, "name") then
      if Complete(id) or InLog(id) then return id end
      first = first or id
    end
  end
  return first
end

-- ganze Reihe in der richtigen Reihenfolge (Vorquests zuerst), ohne doppelte
local attuneCache = {}
function ns.AttuneChain(d)
  local a = d and ns.ATTUNE[d.key]
  if not a or not QDB then return nil end
  local fin
  -- Ende: erledigt oder im Log zuerst, sonst das erste, das du annehmen kannst
  for _, id in ipairs(a.ends) do
    if Allowed(id) and Q(id, "name") and (Complete(id) or InLog(id)) then fin = id; break end
  end
  if not fin then
    for _, id in ipairs(a.ends) do
      if Allowed(id) and Q(id, "name") then
        local st = ns.QuestStatus(id)
        if st ~= "rep" then fin = id; break end
        fin = fin or id
      end
    end
  end
  if not fin then return nil end
  local c = attuneCache[fin]
  if c then return c, a end
  local out, seen = {}, {}
  local function Add(id, depth)
    if seen[id] or depth > 40 then return end
    seen[id] = true
    local single = Q(id, "preQuestSingle")
    if type(single) == "table" and #single > 0 then
      local p = PickOne(single)
      if p then Add(p, depth + 1) end
    end
    local grp = Q(id, "preQuestGroup")
    if type(grp) == "table" then
      for _, p in ipairs(grp) do if type(p) == "number" and Allowed(p) and Q(p, "name") then Add(p, depth + 1) end end
    end
    table.insert(out, id)
  end
  Add(fin, 0)
  attuneCache[fin] = out
  return out, a
end

-- Fortschritt: erledigt, gesamt, naechste offene Quest
function ns.AttuneProgress(d)
  local chain, a = ns.AttuneChain(d)
  if not chain then return nil end
  local done, nextQ = 0, nil
  for _, id in ipairs(chain) do
    if Complete(id) then done = done + 1 elseif not nextQ then nextQ = id end
  end
  return done, #chain, nextQ, a, chain
end

-- ist diese Quest Teil einer Zugangs Reihe? (Stelle, Laenge)
function ns.AttuneIndex(d, qid)
  local chain = ns.AttuneChain(d)
  if not chain then return nil end
  for i, id in ipairs(chain) do if id == qid then return i, #chain end end
end

-- Route nur fuer die Reihe: genau in Reihenfolge, Teile im Dungeon am Eingang
function ns.AttuneRoute(d)
  local tools = ns.OptTools and ns.OptTools()
  if not tools then return nil, TR"keine Daten" end
  local chain, a = ns.AttuneChain(d)
  if not chain then return nil, TR"keine Questreihe" end
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil, TR"keine Position" end
  local px, py = pos:GetXY()
  local pc, pwx, pwy = tools.World(mapID, px, py)
  if not pc then return nil, TR"keine Position" end
  local any = setmetatable({}, { __index = function() return true end })
  local speed = ns.speed or 7
  local steps, t, prev, last = {}, 0, { c = pc, wx = pwx, wy = pwy, map = mapID, x = px, y = py }, nil
  local count, stopAt = 0, nil
  local function Dist(p, q)
    if p.c ~= q.c then
      local y = ns.TravelYards and ns.TravelYards({ cont = p.c, wx = p.wx, wy = p.wy }, { cont = q.c, wx = q.wx, wy = q.wy }, speed)
      return y or 4000
    end
    -- 19.24 (Sascha Teil 1 Punkt 4): Laufweg ueber das Netz wie in der Route
    return (ns.WalkYards and ns.WalkYards(p, q)) or math.sqrt((p.wx - q.wx) ^ 2 + (p.wy - q.wy) ^ 2) * 1.2
  end
  local function Put(map, x, y, act, dur, dname)
    local c, wx, wy = tools.World(map, x, y)
    if not c then return false end
    local n = { c = c, wx = wx, wy = wy, map = map, x = x, y = y }
    if last and last.map == map and Dist(last, n) < 25 then
      table.insert(last.acts, act)
    else
      t = t + Dist(prev, n) / speed
      last = { map = map, x = x, y = y, c = c, wx = wx, wy = wy, acts = { act }, t = t, lvl = UnitLevel("player"), dungeon = dname, attune = true }
      table.insert(steps, last)
    end
    t = t + (dur or 8)
    last.t = t
    prev = n
    return true
  end
  local function Place(by)
    local npc = by and by[1] and by[1][1]
    local obj = by and by[2] and by[2][1]
    local pts = {}
    if npc then tools.Spawns(N(npc, "spawns"), any, pts, 3) end
    if #pts == 0 and obj then tools.Spawns(O(obj, "spawns"), any, pts, 3) end
    local p = pts[1]
    if p then return p[1], p[2], p[3], npc and N(npc, "name") or (obj and O(obj, "name")) end
  end
  for _, qid in ipairs(chain) do
    local st = ns.QuestStatus(qid)
    if st ~= "done" then
      -- noch zu tiefes Level oder Ruf fehlt: hier hoert die Route auf, der Rest kommt spaeter
      if st == "level" or st == "rep" then stopAt = qid; break end
      local name = Q(qid, "name") or (TR"Quest " .. qid)
      local zs = Q(qid, "zoneOrSort")
      local dd = zs and byArea[zs]
      local inD = dd and dd.entrance
      local function Inside(act)
        act.dungeon = true
        return Put(dd.entrance[1], dd.entrance[2], dd.entrance[3], act, 0, dd.name)
      end
      if st ~= "log" and st ~= "ready" then
        local m, x, y, who = Place(Q(qid, "startedBy"))
        local act = { k = "A", qid = qid, quest = name, who = who }
        if m then Put(m, x, y, act, 8)
        elseif inD then act.dungeon = nil; Put(dd.entrance[1], dd.entrance[2], dd.entrance[3], act, 0, dd.name)
        elseif (Q(qid, "startedBy") or {})[3] then act.item = true; table.insert(last and last.acts or {}, act) end
      end
      if st ~= "ready" then
        if inD then Inside({ k = "O", qid = qid, quest = name })
        else
          local bq = tools.BuildQuest(qid, any, nil, false, nil)
          for _, o in ipairs(bq and bq.objNodes or {}) do
            Put(o.map, o.x, o.y, { k = "O", qid = qid, quest = name, obj = o.obj, count = o.count }, o.dur)
          end
        end
      end
      local m, x, y, who = Place(Q(qid, "finishedBy"))
      local act = { k = "T", qid = qid, quest = name, who = who }
      if m then Put(m, x, y, act, 8)
      elseif inD then Put(dd.entrance[1], dd.entrance[2], dd.entrance[3], act, 0, dd.name) end
      count = count + 1
    end
  end
  for _, s in ipairs(steps) do s.c, s.wx, s.wy = nil, nil, nil end
  if #steps == 0 then
    if stopAt then
      local _, rl = ns.QuestReqLevel(stopAt)
      return nil, (ns.QuestStatus(stopAt) == "rep") and TR"Ruf fehlt noch" or (TR"nächster Teil ab Level " .. tostring(rl or "?"))
    end
    return nil, TR"schon alles erledigt"
  end
  local later
  if stopAt then
    local _, rl = ns.QuestReqLevel(stopAt)
    later = rl
  end
  return steps, { title = TR"Zugang: " .. a.what, quests = count, sec = t, target = UnitLevel("player") }, later
end

-- Zahlen fuer die Karten: erledigt, gesamt, offen, ab welchem Level alles annehmbar
function ns.DungeonCounts(d)
  local done, open, need = 0, 0, 0
  for _, qid in ipairs(d.quests or {}) do
    local st = ns.QuestStatus(qid)
    if st == "done" then done = done + 1 else
      open = open + 1
      local ok, _, rl = QLv(qid)
      if ok and rl and rl > need then need = rl end
    end
  end
  return done, #(d.quests or {}), open, need
end

-- Wo steht ein NPC oder Objekt (erste Stelle), fuer den Pfeil
local function Where(by)
  local npc = by and by[1] and by[1][1]
  local obj = by and by[2] and by[2][1]
  local sp = npc and N(npc, "spawns") or (obj and O(obj, "spawns"))
  for area, coords in pairs(type(sp) == "table" and sp or {}) do
    local ui = Ui(area)
    local c = type(coords) == "table" and coords[1]
    if ui and type(c) == "table" and c[1] then return ui, c[1] / 100, c[2] / 100 end
  end
end

function ns.QuestName(qid) if QDB then return Q(qid, "name") end end

-- Alles zu einer Quest fuer die Detail Seite
function ns.DungeonQuestInfo(qid)
  if not QDB then return { name = TR"Quest " .. qid } end
  local okL, ql, rl = QLv(qid)
  local st, stText = ns.QuestStatus(qid)
  local by, fin = Q(qid, "startedBy"), Q(qid, "finishedBy")
  local gName, gZone = Who(by)
  local fName, fZone = Who(fin)
  local gm, gx, gy = Where(by)
  -- 1.3q: Geber aus der Korrektur (nur wenn Questie keinen hat)
  local kn, km, kx, ky, kin = DKGiverOf(qid, by)
  local gZoneText
  if kn then
    gName, gZone = kn, km
    if km and kx then gm, gx, gy = km, kx, ky end
    if kin then gZoneText = (TR"im Dungeon %s"):format(kin) end
  end
  local chain = ns.QuestChain(qid)
  local cnames = {}
  for i, id in ipairs(chain) do cnames[i] = { id = id, name = Q(id, "name") or (TR"Quest " .. id), st = (ns.QuestStatus(id)) } end
  local text = Q(qid, "objectivesText")
  if type(text) == "table" then text = table.concat(text, " ") end
  return {
    id = qid, name = Q(qid, "name") or (TR"Quest " .. qid), level = okL and ql or 0, req = okL and rl or 0,
    st = st, stText = stText, giver = gName, giverZone = gZoneText or (gZone and ns.ZoneName(gZone)), ender = fName, enderZone = fZone and ns.ZoneName(fZone),
    gm = gm, gx = gx, gy = gy, chain = cnames, text = type(text) == "string" and text or nil,
  }
end

-- Text fuer die rechte Seite
function ns.DungeonLines(d)
  local out = {}
  local L = UnitLevel("player")
  local col = (L < d.min - 2) and "|cffff5050" or ((L > d.max) and "|cff9d9d9d" or "|cff40ff40")
  table.insert(out, (TR"|cffffd100%s|r  %sLevel %d bis %d|r"):format(d.name, col, d.min, d.max))
  -- ganz oben: ab welchem Level alle offenen Quests annehmbar sind, und was sonst noch fehlt
  local need, open, reps, pres = 0, 0, {}, 0
  for _, qid in ipairs(d.quests) do
    local st = ns.QuestStatus(qid)
    if st ~= "done" then
      open = open + 1
      local okL, _, rl = QLv(qid)
      if okL and rl and rl > need then need = rl end
      if st == "rep" and ns.RepCheck then local _, t = ns.RepCheck(qid); if t then reps[t] = true end end
      if st == "pre" then pres = pres + 1 end
    end
  end
  if open > 0 then
    if L >= need then
      table.insert(out, (TR"|cff40ff40Alle %d offenen Quests annehmbar ab Level %d, passt.|r"):format(open, need))
    else
      table.insert(out, (TR"|cffff5050Alle %d offenen Quests annehmbar ab Level %d, dir fehlen noch %d Level.|r"):format(open, need, need - L))
    end
    for t in pairs(reps) do table.insert(out, TR"|cffff5050Ruf nötig: " .. t .. "|r") end
    if pres > 0 then table.insert(out, (TR"|cffff9030%d Quests brauchen noch eine Vorquest (siehe Kette).|r"):format(pres)) end
  else
    table.insert(out, TR"|cff6d6d6dAlle Quests hier hast du schon erledigt.|r")
  end
  local zd, zt, znext, za = ns.AttuneProgress(d)
  if zd then
    if zd >= zt then table.insert(out, (TR"|cff40ff40Zugang %s: erledigt.|r"):format(za.what))
    else
      table.insert(out, (TR"|cffff9a30Zugang %s: %d von %d Quests erledigt.|r%s"):format(za.what, zd, zt, za.need and TR" Ohne geht es nicht rein." or TR" Ist eine Abkürzung."))
      if znext then table.insert(out, TR"     Weiter mit: " .. (Q(znext, "name") or "?") .. "  " .. select(2, ns.QuestStatus(znext))) end
    end
  end
  if d.entrance then
    table.insert(out, (TR"Eingang: %s (%.0f, %.0f)"):format(ns.ZoneName(d.entrance[1]), d.entrance[2] * 100, d.entrance[3] * 100))
  end
  table.insert(out, "")
  if #d.quests == 0 then
    table.insert(out, TR"Keine Quests für deine Fraktion, Klasse oder dein Volk.")
    return out
  end
  local shown = {}
  for _, qid in ipairs(d.quests) do
    if not shown[qid] then
      local okL, ql, rl = QLv(qid)
      local _, st = ns.QuestStatus(qid)
      table.insert(out, ("|cffffffff[%d] %s|r  %s"):format(okL and ql or 0, Q(qid, "name") or (TR"Quest " .. qid), st))
      local sb = Q(qid, "startedBy")
      local gName, gZone = Who(sb)
      local fName, fZone = Who(Q(qid, "finishedBy"))
      local gTxt = gZone and (" (" .. ns.ZoneName(gZone) .. ")") or ""
      -- 1.3q: Geber aus der Korrektur (nur wenn Questie keinen hat)
      local kn, km, _, _, kin = DKGiverOf(qid, sb)
      if kn then
        gName = kn
        gTxt = kin and (" (" .. (TR"im Dungeon %s"):format(kin) .. ")") or (km and (" (" .. ns.ZoneName(km) .. ")") or "")
      end
      table.insert(out, (TR"     |cff9d9d9dGeber: %s%s, Abgabe: %s%s|r"):format(gName, gTxt,
        fName, fZone and (" (" .. ns.ZoneName(fZone) .. ")") or ""))
      if d.dkQ and d.dkQ[qid] then table.insert(out, TR"     |cff9d9d9dNur aus dem Dungeon Journal: Ziele unbekannt, nicht in der Route.|r") end
      local chain = ns.QuestChain(qid)
      if #chain > 1 then
        local parts = {}
        for _, id in ipairs(chain) do
          local s = ns.QuestStatus(id)
          local c = (s == "done") and "|cff6d6d6d" or ((id == qid) and "|cffffd100" or "|cffffffff")
          table.insert(parts, c .. (Q(id, "name") or "?") .. "|r")
          shown[id] = true
        end
        table.insert(out, TR"     Kette: " .. table.concat(parts, " > "))
      end
      shown[qid] = true
    end
  end
  return out
end

------------------------------------------------------------
-- Route: Vorquests und Annehmen, Eingang, Abgeben
------------------------------------------------------------
-- 1.3zc (Pr 07:00, K 07:02): DUNGEON Zeilen kamen bei jedem Nachfuehren (alle 20 s), jetzt nur wenn sich der Text aendert
local dungLogLast = {}
local function DungLogOnce(name, key, text)
  if not ns.TestLog then return end
  local k = tostring(name) .. "|" .. key
  if dungLogLast[k] == text then return end
  dungLogLast[k] = text
  ns.TestLog("DUNGEON", text)
end

-- 1.3zg (Pr 08:15, alle Dungeons): nur Quests, die du annehmen kannst (Klasse, Volk, Beruf wie die Leveling Route), und
-- je Dungeon Quest hoechstens ns.DUNG_PRE_MAX offene Vorquests draussen (58er Dungeons hatten 25 bis 30 Quests mit Ketten)
ns.DUNG_PRE_MAX = ns.DUNG_PRE_MAX or 1
local dungProf
local function DungCanTake(qid)
  local _, _, cid = UnitClass("player")
  local _, _, rid = UnitRace("player")
  local rc = Q(qid, "requiredClasses")
  if type(rc) == "number" and rc > 0 and cid and ns.HasBit and not ns.HasBit(rc, cid - 1) then return false, "Klasse" end
  local rr = Q(qid, "requiredRaces")
  if ns.DKRaces then rr = ns.DKRaces(qid, rr) end
  if type(rr) == "number" and rr > 0 and rid and ns.RaceOK and not ns.RaceOK(rr, rid) then return false, "Volk" end
  local sk = Q(qid, "requiredSkill")
  if type(sk) == "table" and sk[1] then
    if dungProf == nil then
      local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieProfessions")
      dungProf = ok and m or false
    end
    if dungProf and dungProf.HasProfessionAndSkillLevel then
      local ok, hp, hl = pcall(dungProf.HasProfessionAndSkillLevel, dungProf, sk)
      if ok and not (hp and hl) then return false, "Beruf" end
    end
  end
  return true
end

function ns.DungeonRoute(d)
  local tools = ns.OptTools and ns.OptTools()
  if not tools or not d.entrance then return nil, TR"keine Daten" end
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return nil, TR"keine Position" end
  local px, py = pos:GetXY()
  local pc, pwx, pwy = tools.World(mapID, px, py)
  if not pc then return nil, TR"keine Position" end
  local any = setmetatable({}, { __index = function() return true end })
  local L = UnitLevel("player")
  local nodes, byQ = {}, {}
  -- 1.3zu (P121, S Log 19:03 bis 22:09 Stadt Dalaran: 3x "Annehmen Heart of Disruption" beim gleichen Geber): gleiche Quest
  -- (gleicher Name beim gleichen Geber) nur einmal annehmen. Die erste aus der Liste bleibt (Questie Reihenfolge), nimmst
  -- du eine andere ID davon an, zaehlt sie als dieselbe (ActDone, Zwilling)
  local seenAN = {}
  local function Node(kind, q, map, x, y, dur, extra)
    local c, wx, wy = tools.World(map, x, y)
    if not c then return nil end
    local n = { kind = kind, qid = q.id, quest = q.name, map = map, x = x, y = y, c = c, wx = wx, wy = wy, dur = dur, preds = {} }
    for k, v in pairs(extra or {}) do n[k] = v end
    table.insert(nodes, n)
    return n
  end
  local function Place(by)
    local npc = by and by[1] and by[1][1]
    local obj = by and by[2] and by[2][1]
    local pts = {}
    if npc then tools.Spawns(N(npc, "spawns"), any, pts, 3) end
    if #pts == 0 and obj then tools.Spawns(O(obj, "spawns"), any, pts, 3) end
    -- Stadt in die Zone drumherum (Stadtkarten liegen sonst ausserhalb)
    local p = pts[1]
    if p then return p[1], p[2], p[3], npc and N(npc, "name") or (obj and O(obj, "name")) end
  end
  local entrance = Node("D", { id = 0, name = d.name }, d.entrance[1], d.entrance[2], d.entrance[3], 0, { dungeon = d.name })
  if not entrance then return nil, TR"Eingang unbekannt" end
  entrance.acts = {}

  local function AddQuest(qid, isDungeonQuest)
    if byQ[qid] ~= nil then return byQ[qid] or nil end
    local st = ns.QuestStatus(qid)
    if st == "done" then return nil end
    -- jetzt nicht annehmbar (Level zu tief, Ruf fehlt): gar nicht einplanen, sonst haengt die Route am Annehmen
    if st == "level" or st == "rep" then byQ[qid] = false; return nil end
    -- 1.3q: Quest nur aus der Korrektur (Questie hat sie nicht): Ziele unbekannt, nicht in die Route
    if d.dkQ and d.dkQ[qid] then byQ[qid] = false; return nil end
    -- 1.3zu (P121): der Geber hat sie dir nicht angeboten (ns.OfferNo, Quest.lua): nicht wieder einplanen
    if st ~= "log" and st ~= "ready" and ns.OfferNo and ns.OfferNo(qid) then
      byQ[qid] = false
      DungLogOnce(d.name, "offerNo" .. qid, ("%s: Quest %d wurde nicht angeboten, nicht in der Route"):format(tostring(d.name), qid))
      return nil
    end
    if st ~= "log" and st ~= "ready" then
      local okT, why = DungCanTake(qid)
      if not okT then
        byQ[qid] = false
        -- 1.3zx (Pr 01:35: alle 20 s die gleiche Zeile aus DungTick): nur bei Aenderung ins Log
        DungLogOnce(d.name, "take" .. qid, ("%s: Quest %d nicht annehmbar (%s), nicht in der Route"):format(tostring(d.name), qid, tostring(why)))
        return nil
      end
    end
    local chain = ns.QuestChain(qid)
    if isDungeonQuest and st ~= "log" and st ~= "ready" then
      local open = 0
      for _, pid in ipairs(chain) do
        if pid == qid then break end
        if ns.QuestStatus(pid) ~= "done" then open = open + 1 end
      end
      if open > ns.DUNG_PRE_MAX then
        byQ[qid] = false
        DungLogOnce(d.name, "pre" .. qid, ("%s: Quest %d braucht %d offene Vorquests (hoechstens %d), nicht in der Route"):format(tostring(d.name), qid, open, ns.DUNG_PRE_MAX))
        return nil
      end
    end
    local q = { id = qid, name = Q(qid, "name") or (TR"Quest " .. qid) }
    local e = {}
    byQ[qid] = e
    -- Vorquests zuerst (geht eine davon noch nicht, faellt die ganze Quest weg)
    local prevT
    local preTs = {}
    for _, pid in ipairs(chain) do
      if pid == qid then break end
      local pe = AddQuest(pid, false)
      if not pe and ns.QuestStatus(pid) ~= "done" then byQ[qid] = false; return nil end
      if pe and pe.T then prevT = pe.T end
    end
    -- 1.3zg (Pr 08:15: Uldaman 726 braucht 725, Todesminen 92752 Gruppe 92751): die Kette nimmt nur die erste Vorquest.
    -- Hier alle: Gruppe = jede erledigt oder eingeplant, Einzeln = eine davon. Sonst faellt die Quest weg
    if st ~= "log" and st ~= "ready" then
      local function PreOK(pid)
        if ns.QuestStatus(pid) == "done" then return true end
        local pe = AddQuest(pid, false)
        if pe and pe.T then preTs[#preTs + 1] = pe.T end
        return pe ~= nil
      end
      local pg = Q(qid, "preQuestGroup")
      for _, pid in ipairs(type(pg) == "table" and pg or {}) do
        if type(pid) == "number" and pid > 0 and not PreOK(pid) then byQ[qid] = false; return nil end
      end
      local ps = Q(qid, "preQuestSingle")
      if type(ps) == "table" and #ps > 0 then
        local anyP = false
        for _, pid in ipairs(ps) do if type(pid) == "number" and pid > 0 and PreOK(pid) then anyP = true; break end end
        if not anyP then byQ[qid] = false; return nil end
      end
    end
    if st ~= "log" and st ~= "ready" then
      local sb = Q(qid, "startedBy")
      local m, x, y, who = Place(sb)
      -- 1.3q: Geber aus der Korrektur, wenn Questie keinen hat. Geber im Dungeon: Annehmen drinnen, kein eigener Schritt
      local kn, km, kx, ky, kin = nil, nil, nil, nil, nil
      if not m then kn, km, kx, ky, kin = DKGiverOf(qid, sb) end
      if not m and kn and km and kx then m, x, y, who = km, kx, ky, kn end
      if not m and not (kn and kin and isDungeonQuest) then byQ[qid] = false; return nil end
      if m then
        local anKey = tostring(q.name) .. "|" .. tostring(who)
        local twin = seenAN[anKey]
        if twin and twin ~= qid then
          byQ[qid] = false
          DungLogOnce(d.name, "dupA" .. qid, ("%s: Quest %d gleich wie %d (%s bei %s), nur einmal in der Route"):format(tostring(d.name), qid, twin, tostring(q.name), tostring(who)))
          return nil
        end
        seenAN[anKey] = qid
        e.A = Node("A", q, m, x, y, 8, { who = who })
        if prevT and e.A then table.insert(e.A.preds, prevT) end
        for _, pt in ipairs(preTs) do if e.A and pt ~= prevT then table.insert(e.A.preds, pt) end end
      end
    end
    -- fertig im Log: nur noch abgeben, nicht nochmal zum Eingang
    if isDungeonQuest and st ~= "ready" then
      if e.A then table.insert(entrance.preds, e.A) end
      table.insert(entrance.acts, { k = "O", qid = qid, quest = q.name, dungeon = true })
    elseif st ~= "ready" and not isDungeonQuest then
      -- Vorquest ausserhalb: Ziele wie im Optimierer (dichteste Stelle)
      local bq = tools.BuildQuest(qid, any, nil, false, nil)
      if bq then
        for _, o in ipairs(bq.objNodes or {}) do
          local on = Node("O", q, o.map, o.x, o.y, o.dur, { obj = o.obj, count = o.count })
          if on and e.A then table.insert(on.preds, e.A) end
          e.O = e.O or {}
          table.insert(e.O, on)
        end
      end
    end
    local m, x, y, who = Place(Q(qid, "finishedBy"))
    if m then
      e.T = Node("T", q, m, x, y, 8, { who = who })
      if e.T then
        if e.A then table.insert(e.T.preds, e.A) end
        for _, on in ipairs(e.O or {}) do table.insert(e.T.preds, on) end
        if isDungeonQuest and st ~= "ready" then table.insert(e.T.preds, entrance) end
      end
    end
    return e
  end

  local count = 0
  for _, qid in ipairs(d.quests) do
    local okL, ql, rl = QLv(qid)
    -- nur was bis zum Dungeon Level machbar ist
    if not (okL and rl and rl > math.max(L + 3, d.max)) then
      if AddQuest(qid, true) then count = count + 1 end
    end
  end
  if count == 0 then return nil, TR"keine offenen Quests" end

  -- Reihenfolge: immer zum naechsten Schritt, dessen Vorgaenger erledigt sind
  local speed = ns.speed or 7
  local function Dist(a, b)
    if a.c ~= b.c then -- anderer Kontinent: Schiff oder Zeppelin
      local y = ns.TravelYards and ns.TravelYards({ cont = a.c, wx = a.wx, wy = a.wy }, { cont = b.c, wx = b.wx, wy = b.wy }, speed)
      return y or 4000
    end
    -- 19.24 (Sascha Teil 1 Punkt 4): Laufweg ueber das Netz wie in der Route
    return (ns.WalkYards and ns.WalkYards(a, b)) or math.sqrt((a.wx - b.wx) ^ 2 + (a.wy - b.wy) ^ 2) * 1.2
  end
  local done, order = {}, {}
  local cur = { c = pc, wx = pwx, wy = pwy, map = mapID, x = px, y = py }
  local left = #nodes
  -- 1.3zu (P122, S Bild 23:22 Kloster aus Orgrimmar: Zeppelin UC, Annehmen, Zeppelin Org, Donnerfels, Zeppelin UC): erst alles,
  -- was auf dem jetzigen Kontinent bereit ist, dann einmal den Kontinent wechseln. Gilt fuer alle Dungeons
  while left > 0 do
    local best, bd, sameC = nil, nil, false
    for _, n in ipairs(nodes) do
      if not done[n] then
        local ready = true
        for _, p in ipairs(n.preds) do if not done[p] then ready = false; break end end
        if ready then
          local same = n.c == cur.c
          local dd = Dist(cur, n)
          if (same and not sameC) or (same == sameC and (not bd or dd < bd)) then best, bd, sameC = n, dd, same end
        end
      end
    end
    -- 1.3v (P102 Punkt 5, S Log Gnomeregan: nur Annehmen in der Route, Eingang, Ziele und Abgaben fehlten): bleibt die
    -- Reihenfolge haengen (Vorgaenger im Kreis oder nie erreichbar), nicht abbrechen, sondern den Knoten mit den wenigsten
    -- offenen Vorgaengern nehmen und es ins Log schreiben
    if not best then
      local bn
      for _, n in ipairs(nodes) do
        if not done[n] then
          local open = 0
          for _, p in ipairs(n.preds) do if not done[p] then open = open + 1 end end
          local dd = Dist(cur, n)
          if not best or open < bn or (open == bn and dd < bd) then best, bn, bd = n, open, dd end
        end
      end
      if not best then break end
      if ns.TestLog then
        local miss = {}
        for _, p in ipairs(best.preds) do if not done[p] then miss[#miss + 1] = tostring(p.kind) .. " " .. tostring(p.qid) end end
        DungLogOnce(d.name, "hang" .. tostring(best.kind) .. tostring(best.qid), ("%s: Reihenfolge haengt, nehme %s %s trotzdem (offen: %s)"):format(tostring(d.name), tostring(best.kind), tostring(best.qid), table.concat(miss, ", ")))
      end
    end
    done[best] = true
    table.insert(order, best)
    cur = best
    left = left - 1
  end

  -- Schritte bauen, gleiche Orte zusammenfassen
  local steps, t, prev = {}, 0, { c = pc, wx = pwx, wy = pwy }
  local last
  for _, n in ipairs(order) do
    -- anderer Kontinent: Schiff oder Zeppelin als eigener Schritt (wie in der Leveling Route), sonst zeigt
    -- der Pfeil ins Leere (Sim 17.2: Quests fuer Flammenschlund auf beiden Kontinenten)
    if prev.c and n.c and prev.c ~= n.c and ns.TravelBest and ns.TravelDesc then
      local a0, b0 = { cont = prev.c, wx = prev.wx, wy = prev.wy }, { cont = n.c, wx = n.wx, wy = n.wy }
      local okT, tt, from, to, l, side = pcall(ns.TravelBest, a0, b0, speed)
      if okT and tt and from and to and l then
        local kind, fromName, toName = ns.TravelDesc(l, side, from, to)
        table.insert(steps, { map = from.map, x = from.x, y = from.y, t = t, lvl = L, travel = true,
          acts = { { k = "R", link = l.id, li = l.idx, side = side, kind = kind, quest = toName, dest = toName, from = fromName,
            toMap = to.map, toX = to.x, toY = to.y, toCont = to.cont, cross = true } } })
        last = nil
      end
    end
    t = t + Dist(prev, n) / speed + n.dur
    local acts
    if n.kind == "D" then
      acts = n.acts or {}
    elseif n.kind == "O" then
      acts = { { k = "O", qid = n.qid, quest = n.quest, obj = n.obj, count = n.count } }
    else
      acts = { { k = n.kind, qid = n.qid, quest = n.quest, who = n.who } }
    end
    if #acts == 0 then
      -- 1.3zg (Pr 08:15 Lua Fehler MiniRoute 79): Eingang ohne Ziele (alles schon fertig) wird kein eigener Schritt
    elseif last and last.map == n.map and Dist(last, n) < 25 then
      for _, a in ipairs(acts) do table.insert(last.acts, a) end
    else
      last = { map = n.map, x = n.x, y = n.y, c = n.c, wx = n.wx, wy = n.wy, acts = {}, t = t, lvl = L, dungeon = (n.kind == "D") and d.name or nil }
      for _, a in ipairs(acts) do table.insert(last.acts, a) end
      table.insert(steps, last)
    end
    prev = n
  end
  for _, s in ipairs(steps) do s.c, s.wx, s.wy = nil, nil, nil end
  if ns.TestLog then
    local kc = {}
    for _, n in ipairs(order) do kc[n.kind] = (kc[n.kind] or 0) + 1 end
    DungLogOnce(d.name, "sum", ("%s: %d Schritte, Annehmen %d, Eingang %d, Ziele draussen %d, Abgaben %d (Knoten %d, in Reihenfolge %d)"):format(
      tostring(d.name), #steps, kc.A or 0, kc.D or 0, kc.O or 0, kc.T or 0, #nodes, #order))
  end
  return steps, { title = TR"Dungeon: " .. d.name, quests = count, sec = t, target = d.max }
end

-- Route als Text
function ns.DungeonRouteLines(steps)
  local out = {}
  for i, s in ipairs(steps) do
    local parts = {}
    for _, a in ipairs(s.acts) do
      if a.dungeon then table.insert(parts, TR"|cffff66ccIm Dungeon:|r " .. (a.quest or "?"))
      elseif a.k == "O" then table.insert(parts, ("|cffff66cc%s|r x%d"):format(a.obj or a.quest or "?", a.count or 1))
      elseif a.k == "A" then table.insert(parts, (TR"|cffff9030Annehmen|r %s"):format(a.quest or "?"))
      else table.insert(parts, (TR"|cff40ff90Abgeben|r %s"):format(a.quest or "?")) end
    end
    local where = s.dungeon and (TR"|cffffd100Eingang " .. s.dungeon .. "|r") or ns.ZoneName(s.map)
    table.insert(out, ("%d. %s  |cff9d9d9d(%s)|r"):format(i, table.concat(parts, ", "), where))
  end
  return out
end

-- gehoert die Quest zu einem Dungeon? (fuer den Knopf Dungeon Quests in der normalen Route)
-- Questie legt Dungeon Quests unter die Gebiets Nummer des Dungeons ab
function ns.IsDungeonQuest(qid)
  -- 17.9: "x and f()" gab nur qdb zurueck, zdb war immer nil und keine Quest galt als Dungeon Quest
  local qdb, zdb
  if ns.QDBAccess then qdb, zdb = ns.QDBAccess() end
  if not (qdb and zdb and zdb.private and type(zdb.private.dungeons) == "table") then return false end
  local ok, z = pcall(qdb.QueryQuestSingle, qid, "zoneOrSort")
  if not ok or type(z) ~= "number" or z <= 0 then return false end
  local e = zdb.private.dungeons[z]
  if e == nil then return false end
  if type(e) == "table" and NOT_DUNGEON[e[1]] then return false end
  return true
end
