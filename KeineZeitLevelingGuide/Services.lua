local ADDON, ns = ...
local TR = ns.TR

-- Daten aus Questie: Lehrer, Gastwirte, Haendler, Reparatur, Flugmeister,
-- Mob Level und Elite (Grind Spots, Gefahren) und Laufwege von NPCs.

local QDB, ZDB
local band = bit and bit.band
local areaUi = {}
local F = {}

ns.svc = {}          -- [uiMap] = { { x, y, name, sub, flags, id, city = uiMap }, ... } freundliche Service NPCs
ns.hostileIds = {}   -- [uiMap] = { npcId, ... } feindliche Mobs (meiste Spawns in dieser Zone)
ns.svcReady = false

local function N(id, k)
  local ok, v = pcall(QDB.QueryNPCSingle, id, k)
  if ok then return v end
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

local function Faction()
  return (UnitFactionGroup("player") == "Alliance") and "A" or "H"
end

------------------------------------------------------------
-- Index aufbauen (einmal nach dem Einloggen, in Haeppchen)
------------------------------------------------------------
local function AddSvc(ui, e)
  ns.svc[ui] = ns.svc[ui] or {}
  table.insert(ns.svc[ui], e)
end

local building
local function BuildIndex()
  if building or ns.svcReady then return end
  if not ns.QDBAccess then return end
  QDB, ZDB = ns.QDBAccess()
  if not QDB then C_Timer.After(5, BuildIndex); return end
  local lib = LibQuestieDB
  local ids = lib and lib.Npc and lib.Npc.GetAllIds and lib.Npc.GetAllIds()
  -- Questie DB noch nicht fertig: spaeter nochmal (sonst wird svcReady nie wahr), hoechstens 5 Minuten lang
  if type(ids) ~= "table" or #ids == 0 then
    ns.svcTries = (ns.svcTries or 0) + 1
    if ns.svcTries <= 60 then C_Timer.After(5, BuildIndex) end
    return
  end
  local fl = (lib.Enum and lib.Enum.npcFlags) or {}
  F.vendor, F.repair, F.fly, F.trainer, F.inn = fl.VENDOR or 0, fl.REPAIR or 0, fl.FLIGHT_MASTER or 0, fl.TRAINER or 0, fl.INNKEEPER or 0
  local want = F.vendor + F.repair + F.fly + F.trainer + F.inn
  if not band or want == 0 then return end
  building = true
  local fac = Faction()
  local i = 0
  -- Haefen ohne bekannte Position: Hafenmeister und Zeppelinmeister suchen
  local needDock = ns.TravelNeedDocks and ns.TravelNeedDocks()
  local function Step()
    local n = 0
    while i < #ids and n < 400 do
      i = i + 1
      n = n + 1
      local id = ids[i]
      local fr = N(id, "friendlyToFaction")
      if needDock and type(fr) == "string" then
        local z = N(id, "zoneID")
        local zu = z and Ui(z)
        if zu and needDock[zu] then
          local nm, sb = N(id, "name") or "", N(id, "subName") or ""
          local txt = nm .. " " .. sb
          if txt:find("[Dd]ock") or txt:find("[Zz]eppelin") or txt:find("[Hh]afen") or (ns.EN and txt:find("[Hh]arbor")) or txt:find("[Ss]kycutter") then
            for area, coords in pairs(N(id, "spawns") or {}) do
              local c = type(coords) == "table" and coords[1]
              if Ui(area) == zu and type(c) == "table" and c[1] and c[1] > 0 then
                ns.dockNpcs[zu] = ns.dockNpcs[zu] or {}
                table.insert(ns.dockNpcs[zu], { c[1] / 100, c[2] / 100, nm })
                break
              end
            end
          end
        end
      end
      if type(fr) == "string" and fr:find(fac, 1, true) then
        local flags = N(id, "npcFlags") or 0
        if band(flags, want) ~= 0 then
          local sp = N(id, "spawns")
          local name, sub = N(id, "name"), N(id, "subName")
          for area, coords in pairs(type(sp) == "table" and sp or {}) do
            local ui = Ui(area)
            local c = type(coords) == "table" and coords[1]
            if ui and type(c) == "table" and c[1] and c[1] > 0 then
              local x, y = c[1] / 100, c[2] / 100
              AddSvc(ui, { x, y, name or "NPC", sub, flags, id })
              local parent = ns.cityParent and ns.cityParent[ui]
              if parent and ns.ToMap then
                local px, py = ns.ToMap(ui, x, y, parent)
                if px then AddSvc(parent, { px, py, name or "NPC", sub, flags, id, city = ui }) end
              end
            end
          end
        end
      -- feindliche Mobs: keine Wachen und Buerger der anderen Fraktion (freundlich zu A oder H), die toetet man nicht zum Farmen
      elseif not (type(fr) == "string" and (fr:find("A", 1, true) or fr:find("H", 1, true))) then
        local z = N(id, "zoneID")
        local ui = z and Ui(z)
        -- ohne Fraktion in den Daten (neue Forever NPCs): Gastwirte, Händler, Lehrer und NPCs mit Titel
        -- ("Innkeeper", "Weapons Quartermaster") sind keine Mobs zum Farmen
        local sv = band(N(id, "npcFlags") or 0, want) ~= 0
        local sub = N(id, "subName")
        if sv or (type(sub) == "string" and sub ~= "") then ui = nil end
        -- 19.33c (Rauchtest 19.33b, Turm von Althalaxx 1140, Level 123): NPCs, die laut Daten Korrektur nie ein Gegner
        -- sind (npc kein_gegner), zaehlen auch nicht fuer "Gegner am Ort" (Raster in Optimizer.lua AreaGrid und im Sim)
        if ui and ns.DKNoFoe and ns.DKNoFoe(nil, id) then ui = nil end
        -- dito Platzhalter Level (Forever und SoD Bosse mit Level 9999, zb Larsera, Shredder 9000): kein Mob draussen
        -- ist ueber 63, solche Eintraege verzerren sonst das Gegner Level am Ort und die Grind Spots
        if ui and (tonumber(N(id, "maxLevel")) or 0) > 63 then ui = nil end
        if ui then
          ns.hostileIds[ui] = ns.hostileIds[ui] or {}
          table.insert(ns.hostileIds[ui], id)
        end
      end
    end
    if i < #ids then C_Timer.After(0, Step); return end
    building = false
    ns.svcReady = true
    if ns.TravelResetCache then ns.TravelResetCache() end
    -- Questie hat jetzt alle gelesenen NPCs im Speicher: wieder freigeben
    if lib and lib.InvalidateCache then pcall(lib.InvalidateCache, "Npc") end
    if ns.db then ns.db.learnedRev = (ns.db.learnedRev or 0) + 1 end
    if ns.Draw then ns.Draw() end
  end
  Step()
end
ns.BuildSvcIndex = BuildIndex

------------------------------------------------------------
-- Grind Spots und Elite Gebiete aus den echten Mob Daten
------------------------------------------------------------
local grindCache, eliteCache = {}, {}
local CELL = 0.05

local jobs = {}
local queue, running = {}, false
local mergedCache = {}
local RunNext
local function Finish(ui, cells)
  local function Top(t)
    local best, bn
    for k, v in pairs(t) do if not bn or v > bn then best, bn = k, v end end
    return best or TR"Mobs"
  end
  -- Nummer vom haeufigsten Mob (fuer Anvisieren und geladene Routen in einer anderen Sprache)
  local function TopId(cl) local n = Top(cl.names); return cl.ids and cl.ids[n] end
  local spots, elites = {}, {}
  for _, cl in pairs(cells) do
    if cl.n >= 8 and cl.hi - cl.lo <= 6 then
      table.insert(spots, { cl.sx / cl.n, cl.sy / cl.n, Top(cl.names), cl.lo, cl.hi, n = cl.n, auto = true, mob = TopId(cl) })
    end
    if cl.e >= 4 then
      table.insert(elites, { cl.ex / cl.e, cl.ey / cl.e, 0.045, (TR"Elite: %s (Lvl %d bis %d)"):format(Top(cl.enames), cl.elo, cl.ehi), mob = true, elite = true, lo = cl.elo, hi = cl.ehi })
    end
  end
  table.sort(spots, function(a, b) return a.n > b.n end)
  -- nicht zu viele, und nicht doppelt nebeneinander
  local out = {}
  for _, s in ipairs(spots) do
    local dup = false
    for _, o in ipairs(out) do
      if math.sqrt((o[1] - s[1]) ^ 2 + (o[2] - s[2]) ^ 2) < 0.07 and math.abs(o[4] - s[4]) <= 2 then dup = true; break end
    end
    if not dup then table.insert(out, s) end
    if #out >= 12 then break end
  end
  table.sort(out, function(a, b) return a[4] < b[4] end)
  grindCache[ui], eliteCache[ui] = out, elites
  jobs[ui] = nil
  mergedCache[ui] = nil
  running = false
  C_Timer.After(0.2, function() if RunNext then RunNext() end end)
  -- Route und Karte mit den neuen Daten neu aufbauen, aber nur fuer die Zone, in der du bist (oder die die Karte zeigt).
  -- Fremde Zonen (zb fuer Berufe ausgewertet) sollen nicht jedes Mal alles neu bauen.
  local pm = ns.PlayerMap and ns.PlayerMap()
  local shown = WorldMapFrame and WorldMapFrame:IsShown() and WorldMapFrame:GetMapID()
  if ui == pm or ui == shown then
    if ns.db then ns.db.learnedRev = (ns.db.learnedRev or 0) + 1 end
    if ns.Draw then ns.Draw() end
  end
end


-- Auswerten in kleinen Haeppchen (40 Mobs pro Frame), immer nur eine Zone gleichzeitig
local function Start(ui)
  running = true
  local list = ns.hostileIds[ui] or {}
  local cells = {}
  local i = 0
  local function Step()
    local n = 0
    while i < #list and n < 40 do
      i = i + 1
      n = n + 1
      local id = list[i]
      local minL, maxL = N(id, "minLevel") or 0, N(id, "maxLevel") or 0
      if maxL >= 2 then
        local rank = N(id, "rank") or 0
        local elite = (rank == 1 or rank == 2 or rank == 3) -- Elite, seltene Elite, Boss
        local name = N(id, "name") or "?"
        local sp = N(id, "spawns")
        for area, coords in pairs(type(sp) == "table" and sp or {}) do
          if Ui(area) == ui and type(coords) == "table" then
            for k, c in ipairs(coords) do
              if k > 80 then break end
              if type(c) == "table" and c[1] and c[1] > 0 then
                local x, y = c[1] / 100, c[2] / 100
                local key = math.floor(x / CELL) .. ":" .. math.floor(y / CELL)
                local cl = cells[key]
                if not cl then
                  cl = { n = 0, e = 0, sx = 0, sy = 0, ex = 0, ey = 0, lo = 99, hi = 0, elo = 99, ehi = 0, names = {}, enames = {}, ids = {} }
                  cells[key] = cl
                end
                if elite then
                  cl.e = cl.e + 1; cl.ex = cl.ex + x; cl.ey = cl.ey + y
                  cl.elo = math.min(cl.elo, minL); cl.ehi = math.max(cl.ehi, maxL)
                  cl.enames[name] = (cl.enames[name] or 0) + 1
                elseif rank == 0 then
                  cl.n = cl.n + 1; cl.sx = cl.sx + x; cl.sy = cl.sy + y
                  cl.lo = math.min(cl.lo, minL); cl.hi = math.max(cl.hi, maxL)
                  cl.names[name] = (cl.names[name] or 0) + 1
                  cl.ids[name] = cl.ids[name] or id
                end
              end
            end
          end
        end
      end
    end
    if i < #list then C_Timer.After(0, Step); return end
    Finish(ui, cells)
  end
  Step()
end

RunNext = function()
  if running then return end
  local ui = table.remove(queue, 1)
  if ui then Start(ui) end
end

local function Analyze(ui)
  if grindCache[ui] or jobs[ui] then return end
  if not (ns.svcReady and QDB) then return end
  jobs[ui] = true
  -- aktuelle Zone zuerst
  if ui == (ns.PlayerMap and ns.PlayerMap()) then table.insert(queue, 1, ui) else table.insert(queue, ui) end
  RunNext()
end

-- Grind Spots einer Zone: von Hand eingetragene plus die aus den Mob Daten
function ns.GrindList(ui)
  local hand = ns.grind[ui] or {}
  if not ui then return hand end
  if mergedCache[ui] then return mergedCache[ui] end
  Analyze(ui)
  local auto = grindCache[ui]
  if not auto or #auto == 0 then return hand end
  local out = {}
  for _, g in ipairs(hand) do table.insert(out, g) end
  for _, a in ipairs(auto) do
    local near = false
    for _, g in ipairs(hand) do
      if math.sqrt((g[1] - a[1]) ^ 2 + (g[2] - a[2]) ^ 2) < 0.08 then near = true; break end
    end
    if not near then table.insert(out, a) end
  end
  mergedCache[ui] = out
  return out
end

-- Elite Gebiete, die fuer dein Level noch gefaehrlich sind
function ns.EliteAreas(ui)
  if not ui then return {} end
  Analyze(ui)
  local L = UnitLevel("player")
  local out = {}
  for _, e in ipairs(eliteCache[ui] or {}) do
    if e.hi >= L - 2 then table.insert(out, e) end
  end
  return out
end

------------------------------------------------------------
-- Laufwege: NPCs, die herumlaufen
------------------------------------------------------------
local wpCache = {}
function ns.Waypoints(npcId, ui)
  if not (npcId and ui and QDB) then return nil end
  local key = npcId .. ":" .. ui
  if wpCache[key] ~= nil then return wpCache[key] or nil end
  local wp = N(npcId, "waypoints")
  local paths = {}
  for area, list in pairs(type(wp) == "table" and wp or {}) do
    if Ui(area) == ui and type(list) == "table" then
      for _, path in ipairs(list) do
        local pts = {}
        for _, c in ipairs(type(path) == "table" and path or {}) do
          if type(c) == "table" and c[1] and c[1] > 0 then table.insert(pts, { c[1] / 100, c[2] / 100 }) end
        end
        if #pts >= 2 then table.insert(paths, pts) end
      end
    end
  end
  wpCache[key] = (#paths > 0) and paths or false
  return wpCache[key] or nil
end

-- naechster Punkt auf einem Laufweg
function ns.NearestOnPaths(paths, x, y)
  local best, bd
  for _, path in ipairs(paths or {}) do
    for _, p in ipairs(path) do
      local d = (p[1] - x) ^ 2 + (p[2] - y) ^ 2
      if not bd or d < bd then best, bd = p, d end
    end
  end
  return best
end

------------------------------------------------------------
-- Service NPCs suchen
------------------------------------------------------------
local function IsKind(e, kind, forCls)
  local f = e[5] or 0
  if not F[kind == "fly" and "fly" or kind] and kind ~= "trainer" then return false end
  if kind == "vendor" then return band(f, F.vendor) ~= 0
  elseif kind == "repair" then return band(f, F.repair) ~= 0
  elseif kind == "fly" then return band(f, F.fly) ~= 0
  elseif kind == "inn" then return band(f, F.inn) ~= 0
  elseif kind == "trainer" then
    if band(f, F.trainer) == 0 then return false end
    -- Klassenname maennlich (UnitClass gibt bei Frauen "Kriegerin"), und englisch (Questie Daten oft englisch)
    local _, file = UnitClass("player")
    local own = not forCls or forCls == file
    file = forCls or file
    local sub = type(e[4]) == "string" and e[4]:lower() or ""
    if sub == "" or not file then return false end
    local names = { file:lower() }
    local m = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]
    local w = LOCALIZED_CLASS_NAMES_FEMALE and LOCALIZED_CLASS_NAMES_FEMALE[file]
    if m then names[#names + 1] = m:lower() end
    if w then names[#names + 1] = w:lower() end
    local cls = own and UnitClass("player")
    if type(cls) == "string" then names[#names + 1] = cls:lower() end
    for _, n in ipairs(names) do if sub:find(n, 1, true) then return true end end
    return false
  end
  return false
end

-- naechster passender NPC; sucht in der Zone und (fuer Lehrer) in allen Zonen der Route
local wideCache = {}
local EMPTY = {}
function ns.NearestSvc(kind, mapID, px, py, wide)
  if not (ns.svcReady and mapID) then return end
  -- weite Suche ist teuer: 20 Sekunden merken
  if wide then
    local c = wideCache[kind]
    if c and c.map == mapID and GetTime() - c.t < 20 then return c.best, c.d end
  end
  local maps = { mapID }
  if wide then
    for _, id in ipairs(ns.zoneOrder or {}) do if id ~= mapID then table.insert(maps, id) end end
  end
  -- ohne neue Tabellen pro Eintrag (weite Suche geht ueber tausende Eintraege)
  local pc, pwx, pwy = ns.MapWorld(mapID, px, py)
  if not pc then return end
  local best, bd, bui
  for _, ui in ipairs(maps) do
    for _, e in ipairs(ns.svc[ui] or EMPTY) do
      if IsKind(e, kind) then
        local c, wx, wy = ns.MapWorld(ui, e[1], e[2])
        if c == pc then
          local d = math.sqrt((wx - pwx) ^ 2 + (wy - pwy) ^ 2)
          if not bd or d < bd then best, bd, bui = e, d, ui end
        end
      end
    end
  end
  if best then best = { map = bui, x = best[1], y = best[2], name = best[3], sub = best[4], id = best[6], city = best.city } end
  if wide then wideCache[kind] = { map = mapID, t = GetTime(), best = best, d = bd } end
  return best, bd
end

-- Flugmeister einer Zone, die du noch nicht kennst
function ns.FlightMasters(ui)
  local out = {}
  if not ns.svcReady then return out end
  local known = (ns.db and ns.db.knownFP) or {}
  for _, e in ipairs(ns.svc[ui] or {}) do
    if IsKind(e, "fly") and not known[e[6]] and not e.city then table.insert(out, e) end
  end
  return out
end

-- bekannte Flugmeister (fuer Fluege in der Planung)
function ns.KnownFlightMasters()
  local out = {}
  if not ns.svcReady then return out end
  local known = (ns.db and ns.db.knownFP) or {}
  for ui, list in pairs(ns.svc) do
    for _, e in ipairs(list) do
      if IsKind(e, "fly") and known[e[6]] and not e.city then table.insert(out, { map = ui, x = e[1], y = e[2], name = e[3], id = e[6] }) end
    end
  end
  return out
end

-- alle Flugmeister nach NPC Nummer (17.4: gemessene und geteilte Flugzeiten pruefen)
local fmById, fmSrc
function ns.FlightMasterById(id)
  if not (ns.svcReady and id) then return nil end
  if not fmById or fmSrc ~= ns.svc then
    fmById, fmSrc = {}, ns.svc
    for ui, list in pairs(ns.svc) do
      for _, e in ipairs(list) do
        if e[6] and not e.city and not fmById[e[6]] and IsKind(e, "fly") then fmById[e[6]] = { map = ui, x = e[1], y = e[2], name = e[3], id = e[6] } end
      end
    end
  end
  return fmById[id]
end

-- alle Haendler (fuer Taschen leeren in der Planung)
function ns.Vendors()
  local out = {}
  if not ns.svcReady then return out end
  for ui, list in pairs(ns.svc) do
    for _, e in ipairs(list) do
      if IsKind(e, "vendor") and not e.city then table.insert(out, { map = ui, x = e[1], y = e[2], name = e[3], id = e[6] }) end
    end
  end
  return out
end

-- alle Lehrer deiner Klasse (fuer die Route: bis Level 10 immer zum Lehrer), cls: andere Klasse (Gruppe)
function ns.Trainers(cls)
  local out = {}
  if not ns.svcReady then return out end
  for ui, list in pairs(ns.svc) do
    for _, e in ipairs(list) do
      if IsKind(e, "trainer", cls) then table.insert(out, { map = ui, x = e[1], y = e[2], name = e[3], id = e[6], city = e.city }) end
    end
  end
  return out
end

-- alle Gastwirte (fuer Ruhestein Planung)
function ns.Inns()
  local out = {}
  if not ns.svcReady then return out end
  for ui, list in pairs(ns.svc) do
    for _, e in ipairs(list) do
      if IsKind(e, "inn") and not e.city then table.insert(out, { map = ui, x = e[1], y = e[2], name = e[3], id = e[6] }) end
    end
  end
  return out
end

function ns.FPKnownNear(ui, x, y)
  local known = (ns.db and ns.db.knownFP) or {}
  for _, e in ipairs(ns.svc[ui] or {}) do
    if IsKind(e, "fly") and known[e[6]] and math.sqrt((e[1] - x) ^ 2 + (e[2] - y) ^ 2) < 0.03 then return true end
  end
  return false
end

------------------------------------------------------------
-- Hinweise: Reparieren, Taschen voll, Lehrer, Ruhestein, Flugpunkt
------------------------------------------------------------
local function Durability()
  local lo
  if not GetInventoryItemDurability then return end
  for slot = 1, 18 do
    local ok, cur, max = pcall(GetInventoryItemDurability, slot)
    if ok and cur and max and max > 0 then
      local p = cur / max
      if not lo or p < lo then lo = p end
    end
  end
  return lo
end

local function FreeSlots()
  local free = 0
  for bag = 0, 4 do
    local f, typ
    if C_Container and C_Container.GetContainerNumFreeSlots then f, typ = C_Container.GetContainerNumFreeSlots(bag)
    elseif GetContainerNumFreeSlots then f, typ = GetContainerNumFreeSlots(bag) end
    -- nur normale Taschen (Koecher, Munition und Seelensplitter Taschen zaehlen nicht)
    typ = ns.Plain and ns.Plain(typ) or typ
    if typ == nil or typ == 0 then free = free + (ns.Plain and ns.Plain(f) or f or 0) end
  end
  return free
end

local function Snoozed(kind)
  local s = ns.db and ns.db.svcSnooze
  return s and s[kind] and time() < s[kind]
end

-- alle Service Hinweise, wichtigster zuerst
local lastVendor
local function Hints()
  local out = {}
  local db = ns.db
  if not (db and db.svcHints ~= false and ns.svcReady) then return out end
  local mapID = ns.PlayerMap()
  local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return out end
  local px, py = pos:GetXY()
  local L = UnitLevel("player")
  local function Add(h) table.insert(out, h) end
  local trainerDone = false

  local dur = Durability()
  if dur and dur <= 0.25 and not Snoozed("repair") then
    local t = ns.NearestSvc("repair", mapID, px, py, true)
    if t then Add({ kind = "repair", target = t, text = (TR"Rüstung %d%%: reparieren bei %s"):format(math.floor(dur * 100), t.name) }) end
  end
  if FreeSlots() <= 1 and not Snoozed("vendor") then
    local t, d = ns.NearestSvc("vendor", mapID, px, py, false)
    -- 19.31 (Saschas Log: "Taschen voll" 5 Mal in einer Minute, abwechselnd Duokna und Zlagk): der einmal gezeigte
    -- Haendler bleibt, solange er nicht klar weiter weg ist als der naechste
    local lv = lastVendor
    if t and lv and (lv.t.name ~= t.name or lv.t.x ~= t.x) and lv.map == mapID and GetTime() - lv.at < 300 and ns.WorldDist then
      local dl = ns.WorldDist({ mapID, px, py }, { lv.t.map or mapID, lv.t.x, lv.t.y })
      if dl and d and dl <= d * 1.3 + 50 then t = lv.t end
    end
    if t then
      lastVendor = { t = t, map = mapID, at = GetTime() }
      Add({ kind = "vendor", target = t, text = (TR"Taschen voll: verkaufen bei %s"):format(t.name) })
    end
  end
  -- Lehrer: seit ein paar Leveln nicht mehr dort und gerade in der Naehe
  db.trainedAt = db.trainedAt or 0
  if L >= 6 and L - db.trainedAt >= 4 and not Snoozed("trainerNear") then
    local t, d = ns.NearestSvc("trainer", mapID, px, py, false)
    if t and d and d < 500 then
      Add({ kind = "trainer", near = true, target = t, text = (TR"Lehrer %s ist gleich da, seit Level %d nicht mehr gelernt"):format(t.name, db.trainedAt) })
      trainerDone = true
    end
  end
  -- Lehrer: es wartet etwas (aus den Zauber Daten), sonst wie frueher bei geraden Leveln
  local waiting = ns.TrainerSpells and #ns.TrainerSpells(L) or nil
  if not trainerDone and ((waiting and waiting > 0) or (not waiting and L >= 4 and L % 2 == 0)) and db.trainedAt < L and (db.trainerSkip or 0) < L then
    local t, d = ns.NearestSvc("trainer", mapID, px, py, true)
    if t then
      local where = t.city and (TR" in " .. ns.ZoneName(t.city)) or (t.map ~= mapID and (TR" in " .. ns.ZoneName(t.map)) or "")
      local what = (waiting and waiting > 0) and (waiting == 1 and TR"1 neuen Zauber lernen" or (waiting .. TR" neue Zauber lernen")) or TR"Neue Zauber lernen"
      Add({ kind = "trainer", target = t, waiting = waiting, text = (TR"%s bei Lehrer %s%s"):format(what, t.name, where) })
    end
  end
  -- Flugpunkt in der Naehe noch nicht geholt.
  -- 19.32 (Navi Chat Vorschlag): ab Level 30 nur, wenn das Addon schon einen Flugpunkt kennt (sonst kennt es deine
  -- Flugpunkte einfach noch nicht, dann kommt statt dessen der Hinweis "Flugkarte einmal oeffnen")
  local nFP = 0
  for _ in pairs(db.knownFP or {}) do nFP = nFP + 1 end
  local flyOk = not (L >= 30 and nFP == 0)
  for _, e in ipairs((Snoozed("fly") or not flyOk) and {} or ns.FlightMasters(mapID)) do
    local d = ns.WorldDist({ mapID, px, py }, { mapID, e[1], e[2] })
    if d and d < 400 then
      Add({ kind = "fly", target = { map = mapID, x = e[1], y = e[2], name = e[3], id = e[6] }, text = (TR"Flugpunkt holen: %s"):format(e[3]) })
      break
    end
  end
  -- 19.32 (Navi Chat): Level 10 und mehr, Fluege an, aber kein Flugpunkt bekannt: einmal die Flugkarte oeffnen.
  -- Ziel ist der naechste Flugmeister auf dieser Karte (Klick: Pfeil dorthin), wegklickbar wie die anderen
  if ns.NaviFlugHinweisNoetig and ns.NAVI_FLUG_HINWEIS and not Snoozed("flymap") and ns.NaviFlugHinweisNoetig() then
    local best, bd
    for _, e in ipairs(ns.FlightMasters(mapID) or {}) do
      local d = ns.WorldDist({ mapID, px, py }, { mapID, e[1], e[2] })
      if d and (not bd or d < bd) then best, bd = e, d end
    end
    if best then
      Add({ kind = "flymap", target = { map = mapID, x = best[1], y = best[2], name = best[3], id = best[6] }, text = ns.NAVI_FLUG_HINWEIS })
    end
  end
  -- Ruhestein: laut Plan bleibst du hier noch, gebunden bist du woanders
  local cur = ns.PlanNow and ns.PlanNow(L)
  -- nicht im Startgebiet (bis Level 5): binden erst im naechsten Ort
  if L >= 6 and cur and cur[1] == mapID and cur[3] - L >= 2 and db.bindZone ~= mapID and not Snoozed("inn") then
    local t = ns.NearestSvc("inn", mapID, px, py, false)
    -- pro Gasthaus hoechstens zweimal anzeigen, nicht immer wieder
    if t then
      db.innHinted = db.innHinted or {}
      local key = tostring(t.name or "?")
      if ns.innHintFor ~= key then
        if (db.innHinted[key] or 0) >= 2 then t = nil
        else db.innHinted[key] = (db.innHinted[key] or 0) + 1; ns.innHintFor = key end
      end
    end
    if t then
      local nm = tostring(t.name or "?")
      -- Questie Name hat den Titel oft schon drin (deutsch oder englisch)
      -- Name hat den Titel schon drin (Gastwirt, Innkeeper, Aubergiste ...): so lassen, sonst davor setzen
      local titled = false
      for _, w in ipairs({ "^Gastwirt", "^Innkeeper", "^Aubergiste", "^Taberner", "^Posader", "^Locandier", "^Estalajade" }) do if nm:find(w) then titled = true; break end end
      local who = titled and nm or (TR"Gastwirt " .. nm)
      Add({ kind = "inn", target = t, text = (TR"Ruhestein beim %s setzen"):format(who) })
    end
  end
  return out
end
local function Hint()
  local l = Hints()
  ns.svcHints = l
  return l[1]
end

ns.svcHint = nil
local function Tick()
  ns.svcHint = Hint()
  local inn = false
  for _, h in ipairs(ns.svcHints or {}) do if h.kind == "inn" then inn = true end end
  if not inn then ns.innHintFor = nil end
  -- Ziel erreicht?
  local t = ns.serviceTarget
  if t then
    local mapID = ns.PlayerMap()
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then
      local px, py = pos:GetXY()
      local d = ns.WorldDist({ mapID, px, py }, { t.map, t.x, t.y })
      -- Navi (17.4) schaltet selbst zum naechsten Abschnitt
      if d and d < 12 and t.kind ~= "missed" and t.kind ~= "navi" then ns.serviceTarget = nil end
    end
  end
end

function ns.ToggleServiceTarget()
  if ns.serviceTarget then
    ns.serviceTarget = nil
  elseif ns.svcHint then
    ns.serviceTarget = ns.svcHint.target
    ns.serviceTarget.kind = ns.svcHint.kind
    ns.Print(TR"Pfeil zeigt jetzt zu: " .. ns.svcHint.text)
  end
  if ns.Draw then ns.Draw() end
end

-- Haendler in der Naehe suchen (Knopf im HUD). Nochmal klicken: Pfeil wieder auf die Route.
function ns.FindVendor()
  if ns.serviceTarget and ns.serviceTarget.kind == "vendor" then
    ns.serviceTarget = nil
    ns.Print(TR"Pfeil wieder auf der Route")
    if ns.Draw then ns.Draw() end
    return
  end
  if not ns.svcReady then ns.Print(TR"Händler werden noch eingelesen, gleich nochmal versuchen."); return end
  local map = ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  -- Haendler mit Reparatur bevorzugen, wenn er nicht viel weiter weg ist
  local v, dv = ns.NearestSvc("vendor", map, px, py, true)
  local r, dr = ns.NearestSvc("repair", map, px, py, true)
  local best, d = v, dv
  if r and (not dv or dr <= dv * 1.3) then best, d = r, dr end
  if not best then ns.Print(TR"Kein Händler in der Nähe gefunden"); return end
  ns.serviceTarget = { map = best.map, x = best.x, y = best.y, name = best.name, kind = "vendor" }
  ns.Print((TR"Pfeil zeigt zum Händler %s%s, ca %d Yards"):format(best.name or "?", best.sub and (" <" .. best.sub .. ">") or "", math.floor(d or 0)))
  if ns.Draw then ns.Draw() end
end

-- Feierabend: naechstes Gasthaus zum Ausloggen, Abgaben auf dem Weg, Ruhestein wenn das schneller ist
function ns.EndSession()
  if ns.serviceTarget and ns.serviceTarget.kind == "inn" then
    ns.serviceTarget = nil
    ns.Print(TR"Feierabend abgebrochen, Pfeil wieder auf der Route")
    if ns.Draw then ns.Draw() end
    return
  end
  if not ns.svcReady then ns.Print(TR"Gastwirte werden noch eingelesen, gleich nochmal versuchen."); return end
  local map = ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local inn, d = ns.NearestSvc("inn", map, px, py, true)
  if not inn then ns.Print(TR"Kein Gasthaus gefunden"); return end
  local me = { map, px, py }
  local tgt = { inn.map, inn.x, inn.y }
  -- fertige Quests, deren Abgabe kaum Umweg ist
  local on = {}
  for ui, list in pairs(ns.qEnds or {}) do
    for _, e in ipairs(list) do
      local a = ns.WorldDist(me, { ui, e[1], e[2] })
      local b = ns.WorldDist({ ui, e[1], e[2] }, tgt)
      if a and b and d and a + b - d < 300 then
        for _, q in ipairs(e.quests or {}) do table.insert(on, q.name) end
      end
    end
  end
  ns.serviceTarget = { map = inn.map, x = inn.x, y = inn.y, name = TR"Gasthaus: " .. (inn.name or "?"), kind = "inn" }
  ns.Print((TR"Feierabend: Gasthaus bei %s, ca %d Yards. Dort ausloggen, dann sammelst du Ruhebonus."):format(inn.name or "?", math.floor(d or 0)))
  if #on > 0 then ns.Print(TR"Auf dem Weg noch abgeben: " .. table.concat(on, ", ")) end
  -- Forever (17.5): der Schlafsack zaehlt auch als Ruhezone, Ausloggen darin geht ueberall
  if ns.HasSleepingBag and ns.HasSleepingBag() then
    local cd = (C_Container and C_Container.GetItemCooldown) or GetItemCooldown
    local st, dur = 0, 0
    if cd then st, dur = cd(211527) end
    local left = (st and dur and dur > 1.5) and (st + dur - GetTime()) or 0
    if left > 0 then
      ns.Print((TR"Du kannst dich auch in den Schlafsack legen und darin ausloggen (wieder bereit in %s)."):format(ns.Clock and ns.Clock(left) or math.floor(left) .. "s"))
    else
      ns.Print(TR"Du kannst dich auch gleich hier in den Schlafsack legen und darin ausloggen, das zählt auch als Ruhezone.")
    end
    if ns.TestLog then ns.TestLog("FEIERABEND", ("Schlafsack als Möglichkeit genannt (bereit %s)"):format(left > 0 and "nein" or "ja")) end
  end
  local bi = ns.db and ns.db.bindInn
  local ready = GetItemCooldown and select(2, GetItemCooldown(6948)) == 0 and (not GetItemCount or GetItemCount(6948) > 0)
  if bi and ready and d and d > 600 then
    ns.Print((TR"Schneller: Ruhestein benutzen, du bist in %s gebunden."):format(ns.ZoneName(bi[1])))
  end
  if ns.Draw then ns.Draw() end
end

-- Hinweis auslassen: Lehrer bis zum naechsten Level, sonst 15 Minuten Ruhe
function ns.DismissSvcHint(h)
  h = h or ns.svcHint
  if not h then return end
  local db = ns.db
  if h.kind == "trainer" and (h.near or (h.text and h.text:find("gleich da"))) then
    db.svcSnooze = db.svcSnooze or {}
    db.svcSnooze.trainerNear = time() + 1800
    ns.Print(TR"Lehrer Hinweis für 30 Minuten aus")
  elseif h.kind == "trainer" then
    db.trainerSkip = UnitLevel("player")
    ns.Print(TR"Lehrer ausgelassen, nächster Hinweis beim nächsten geraden Level")
  else
    db.svcSnooze = db.svcSnooze or {}
    db.svcSnooze[h.kind] = time() + 900
    ns.Print(TR"Hinweis für 15 Minuten ausgeblendet")
  end
  if ns.serviceTarget and ns.serviceTarget.kind == h.kind then ns.serviceTarget = nil end
  ns.svcHint = Hint()
end

function ns.ToggleSvcHints()
  ns.db.svcHints = (ns.db.svcHints == false)
  ns.Print(ns.db.svcHints and TR"Hinweise für Lehrer, Händler, Reparatur, Flugpunkt und Ruhestein an" or TR"Service Hinweise aus")
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
-- Zauber, die beim Lehrer warten (bis Level L), mit Daten aus TrainerData.lua
local function Known(id) return (IsPlayerSpell and IsPlayerSpell(id)) or (IsSpellKnown and IsSpellKnown(id)) end
function ns.TrainerSpells(L, onlyLevel)
  local _, cls = UnitClass("player")
  local data = ns.TRAINER_SPELLS and ns.TRAINER_SPELLS[cls or ""]
  if not data then return {} end
  L = L or UnitLevel("player") or 1
  local _, _, race = UnitRace("player")
  local fac = UnitFactionGroup("player")
  local out, pend = {}, {}
  for l = onlyLevel and L or 1, L do
    for _, e in ipairs(data[l] or {}) do
      local id = e[1]
      local ok = not Known(id)
      if ok and e.t and not Known(e.t) then ok = false end
      if ok and e.race and e.race ~= race then ok = false end
      if ok and e.races then
        local hit = false
        for _, r in ipairs(e.races) do if r == race then hit = true end end
        ok = hit
      end
      if ok and e.fac and e.fac ~= fac then ok = false end
      local up = false
      if ok and e.r then
        local need = e.r[1]
        local n1, n2 = GetSpellInfo(id), GetSpellInfo(need)
        up = n1 ~= nil and n1 == n2
        -- braucht einen Zauber, den du nicht hast und der auch nicht beim Lehrer wartet (Form, Talent): weglassen
        if not Known(need) and not pend[need] then ok = false end
      end
      if ok then
        pend[id] = true
        table.insert(out, { id = id, lvl = l, up = up })
      end
    end
  end
  return out
end

-- Fenster: Icons der Zauber, neue Raenge mit gruenem Pfeil, Knopf "Lehrer finden"
local tp
local function FindTrainer()
  local map = ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local t, d = ns.NearestSvc("trainer", map, px, py, true)
  if not t then ns.Print(TR"Kein Lehrer gefunden"); return end
  ns.serviceTarget = { map = t.map, x = t.x, y = t.y, name = TR"Lehrer: " .. (t.name or "?"), kind = "trainer" }
  ns.Print((TR"Pfeil zeigt zum Lehrer %s, ca %d Yards"):format(t.name or "?", math.floor(d or 0)))
  if ns.Draw then ns.Draw() end
end
ns.FindTrainer = FindTrainer

-- Alle 2 Level (wenn etwas wartet): Fenster mit Lehrer, Ort und den Zaubern mit Namen.
-- force: auch an ungeraden Leveln und ohne die Einstellung (zum Testen oder von Hand)
local function SpellRank(id)
  if GetSpellSubtext then
    local ok, r = pcall(GetSpellSubtext, id)
    if ok and type(r) == "string" and r ~= "" then return r end
  end
  local _, r = GetSpellInfo(id)
  if type(r) == "string" and r ~= "" then return r end
end
function ns.TrainerPopup(L, force)
  local db = ns.db
  if not db then return end
  L = L or UnitLevel("player") or 1
  if not force and (db.trainerPopup == false or L % 2 ~= 0) then return end
  if InCombatLockdown and InCombatLockdown() then C_Timer.After(5, function() ns.TrainerPopup(L, force) end); return end
  local list = ns.TrainerSpells(L)
  if #list == 0 then return end
  local T = ns.T
  if not tp then
    tp = CreateFrame("Frame", "ForeverWegweiserTrainer", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tp:SetPoint("TOP", UIParent, "TOP", 0, -160)
    tp:SetFrameStrata("FULLSCREEN_DIALOG")
    tp:SetClampedToScreen(true)
    tp:EnableMouse(true)
    tp:SetMovable(true)
    tp:RegisterForDrag("LeftButton")
    tp:SetScript("OnDragStart", tp.StartMoving)
    tp:SetScript("OnDragStop", tp.StopMovingOrSizing)
    if T then T.Skin(tp, "window") end
    tp.title = tp:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    tp.title:SetPoint("TOP", 0, -16)
    tp.sub = tp:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    tp.sub:SetPoint("TOP", tp.title, "BOTTOM", 0, -6)
    tp.sub:SetWidth(360)
    tp.close = CreateFrame("Button", nil, tp, "UIPanelCloseButton")
    tp.close:SetPoint("TOPRIGHT", -4, -4)
    if T and T.SkinClose then pcall(T.SkinClose, tp.close) end
    tp.rows = {}
    tp.go = T and T.Button(tp, TR"Zum Lehrer", 130, 24, true) or CreateFrame("Button", nil, tp, "UIPanelButtonTemplate")
    tp.go:SetSize(130, 24); tp.go:SetText(TR"Zum Lehrer")
    tp.go:SetPoint("BOTTOMRIGHT", tp, "BOTTOM", -6, 14)
    tp.go:SetScript("OnClick", function()
      tp:Hide()
      if ns.db and ns.db.optMode and ns.OptInsertService then ns.OptInsertService("trainer") else FindTrainer() end
    end)
    tp.go:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Lehrer kommt als Schritt in deine Route, danach geht es weiter.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    tp.go:SetScript("OnLeave", function() GameTooltip:Hide() end)
    tp.no = T and T.Button(tp, TR"Später", 130, 24) or CreateFrame("Button", nil, tp, "UIPanelButtonTemplate")
    tp.no:SetSize(130, 24); tp.no:SetText(TR"Später")
    tp.no:SetPoint("BOTTOMLEFT", tp, "BOTTOM", 6, 14)
    tp.no:SetScript("OnClick", function() tp:Hide() end)
    tp.more = tp:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  end
  -- Lehrer und Ort
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  local t, d
  if pos then local px, py = pos:GetXY(); t, d = ns.NearestSvc("trainer", map, px, py, true) end
  if t then
    local where = t.city and ns.ZoneName(t.city) or ns.ZoneName(t.map)
    tp.sub:SetText((TR"Lehrer %s in %s, ca %d Yards"):format(t.name or "?", where or "?", math.floor(d or 0)))
  else
    tp.sub:SetText(TR"Lehrer deiner Klasse in der nächsten Stadt")
  end
  -- Zauber: Icon, Name, Rang. Die neusten zuerst, zwei Spalten ab 9
  local ROWH, MAXR = 22, 20
  local n = math.min(#list, MAXR)
  local cols = n > 8 and 2 or 1
  local colW = 200
  local perCol = math.ceil(n / cols)
  for i = 1, n do
    local e = list[#list - i + 1]
    local r = tp.rows[i]
    if not r then
      r = CreateFrame("Button", nil, tp)
      r:SetSize(colW, ROWH - 2)
      r.icon = r:CreateTexture(nil, "ARTWORK")
      r.icon:SetSize(ROWH - 2, ROWH - 2); r.icon:SetPoint("LEFT", 0, 0); r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      r.up = r:CreateTexture(nil, "OVERLAY")
      r.up:SetSize(12, 12); r.up:SetPoint("BOTTOMRIGHT", r.icon, "BOTTOMRIGHT", 3, -3)
      r.up:SetTexture("Interface\\Buttons\\Arrow-Up-Up"); r.up:SetVertexColor(0.3, 1, 0.3)
      r.name = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
      r.name:SetPoint("RIGHT", r, "RIGHT", 0, 0)
      r.name:SetJustifyH("LEFT")
      r:SetScript("OnEnter", function(self)
        ns.TipOwner(self, "ANCHOR_RIGHT")
        if self.id and GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(self.id) end
        GameTooltip:AddLine(self.isUp and TR"Neuer Rang" or TR"Neuer Zauber", 0.3, 1, 0.3)
        GameTooltip:Show()
      end)
      r:SetScript("OnLeave", function() GameTooltip:Hide() end)
      tp.rows[i] = r
    end
    r.id, r.isUp = e.id, e.up
    r.icon:SetTexture(GetSpellTexture and GetSpellTexture(e.id) or "Interface\\Icons\\INV_Misc_QuestionMark")
    r.up:SetShown(e.up and true or false)
    local nm = GetSpellInfo and GetSpellInfo(e.id) or ("#" .. e.id)
    local rk = SpellRank(e.id)
    r.name:SetText(nm .. (rk and (" |cff9d9d9d" .. rk .. "|r") or "") .. (e.lvl < L - 1 and (" |cffff9030(" .. (TR"seit Level %d"):format(e.lvl) .. ")|r") or ""))
    local c, row = math.floor((i - 1) / perCol), (i - 1) % perCol
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", tp, "TOP", -(cols * colW + (cols - 1) * 16) / 2 + c * (colW + 16), -64 - row * ROWH)
    r:Show()
  end
  for i = n + 1, #tp.rows do tp.rows[i]:Hide() end
  tp.more:ClearAllPoints()
  tp.more:SetPoint("TOP", tp, "TOP", 0, -64 - perCol * ROWH - 2)
  tp.more:SetText(#list > MAXR and (TR"... und %d mehr"):format(#list - MAXR) or "")
  local nNew, nUp = 0, 0
  for _, e in ipairs(list) do if e.up then nUp = nUp + 1 else nNew = nNew + 1 end end
  tp.title:SetText((TR"Level %d: %d neue Zauber, %d neue Ränge"):format(L, nNew, nUp))
  tp:SetSize(math.max(400, cols * colW + (cols - 1) * 16 + 40), 64 + perCol * ROWH + (#list > MAXR and 16 or 0) + 56)
  tp:Show()
end

-- Ruhestein am Anfang: ein neuer Charakter ist am Startpunkt im Startgebiet gebunden (dort, wo er zum ersten Mal steht).
-- So kann die Route den ersten Ruhestein schon auf Level 3 bis 6 einplanen, zB zurueck ins Startgebiet zum Abgeben.
-- Startpunkte aus den Questie Daten (neben dem ersten Questgeber). Volk ohne Eintrag (Forever): beim ersten Einloggen gelernt.
local START_BIND = {
  Orc = { 1411, 0.433, 0.688 }, Troll = { 1411, 0.433, 0.688 },
  Tauren = { 1412, 0.448, 0.774 },
  Scourge = { 1420, 0.302, 0.716 }, Undead = { 1420, 0.302, 0.716 },
  Human = { 1429, 0.482, 0.426 },
  Dwarf = { 1426, 0.299, 0.712 }, Gnome = { 1426, 0.299, 0.712 },
  NightElf = { 1438, 0.587, 0.443 },
}
for _, b in pairs(START_BIND) do if ns.EraXY then b[2], b[3] = ns.EraXY(b[1], b[2], b[3]) end end
ns.START_BIND = START_BIND
local function HomeName() return GetBindLocation and GetBindLocation() or nil end

-- Startgebiet wechseln: Plan neu ab hier, der Weg dorthin kommt als Schritte (Reise, Zeppelin ...)
function ns.SetStartArea(key)
  local db = ns.db
  if not db or not key then return end
  local own = ns.OwnStartKey and ns.OwnStartKey()
  db.startPlan = (key ~= own) and key or nil
  db.startAsked = db.startAsked or {}
  db.startAsked[key] = true
  if ns.SetupRace then ns.SetupRace() end
  local name = key
  for _, a in ipairs(ns.StartAreas and ns.StartAreas() or {}) do if a.key == key then name = a.name end end
  ns.Print((TR"Startgebiet: %s. Die Route rechnet neu und führt dich dorthin."):format(name))
  -- bis der Plan fertig ist: Pfeil schon mal zum Startpunkt
  local sb = START_BIND[key]
  if sb and ns.PlayerMap and ns.PlayerMap() ~= sb[1] then
    ns.serviceTarget = { map = sb[1], x = sb[2], y = sb[3], name = (TR"Startgebiet: %s"):format(name), kind = "start" }
    if ns.Draw then ns.Draw() end
  end
  if ns.CalcGo then ns.CalcGo(TR"Startgebiet gewechselt") end
  -- 19.32: Einrichtung zeigt das neue Startgebiet gleich an
  if ns.OnStartAreaChanged then pcall(ns.OnStartAreaChanged) end
end

-- in welchem Startgebiet stehst du (nur der Kern um den Startpunkt, ganze Insel bei Zephras)? Schluessel oder nil
function ns.StartAreaAt(map, x, y)
  if not (map and x) then return end
  for _, a in ipairs(ns.StartAreas and ns.StartAreas() or {}) do
    local sb = START_BIND[a.key]
    if sb then
      if sb[1] == map and ns.WorldDist and (ns.WorldDist({ map, x, y }, sb) or 9999) < 450 then return a.key end
    elseif a.zone == map then
      return a.key
    end
  end
end

-- Auswahl Fenster: alle Startgebiete deiner Fraktion, deins ist markiert
local chooser
function ns.ChooseStartArea()
  local list = ns.StartAreas and ns.StartAreas() or {}
  if #list == 0 then return end
  if not chooser then
    local f = CreateFrame("Frame", "ForeverWegweiserStartArea", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(340, 120)
    f:SetPoint("TOP", UIParent, "TOP", 0, -160)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(true)
    if ns.T then ns.T.Skin(f, "window") elseif ns.Skin then ns.Skin(f, "window") end
    f.text = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    f.text:SetPoint("TOPLEFT", 16, -16); f.text:SetPoint("TOPRIGHT", -16, -16)
    f.text:SetJustifyH("CENTER")
    f.btns = {}
    f.close = ns.T and ns.T.Button(f, TR"Abbrechen", 140, 22) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.close:SetSize(140, 22); f.close:SetText(TR"Abbrechen")
    f.close:SetScript("OnClick", function() f:Hide() end)
    if ns.escFrames then table.insert(ns.escFrames, f) end
    chooser = f
  end
  local f = chooser
  f.text:SetText(TR"Wo willst du starten? Die Route führt dich dorthin und bleibt dort bis etwa Level 10 bis 12.")
  local cur = ns.CurStartKey and ns.CurStartKey()
  local own = ns.OwnStartKey and ns.OwnStartKey()
  local y = -26 - f.text:GetStringHeight() - 8
  for i, a in ipairs(list) do
    local b = f.btns[i]
    if not b then
      b = ns.T and ns.T.Button(f, "", 300, 24) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      b:SetSize(300, 24)
      f.btns[i] = b
    end
    local tag = (a.key == cur) and TR"  (jetzt)" or ((a.key == own) and TR"  (dein Volk)" or "")
    b:SetText(a.name .. tag)
    b:ClearAllPoints(); b:SetPoint("TOP", f, "TOP", 0, y)
    b:SetScript("OnClick", function() f:Hide(); if a.key ~= cur then ns.SetStartArea(a.key) end end)
    b:Show()
    y = y - 28
  end
  for i = #list + 1, #f.btns do f.btns[i]:Hide() end
  f.close:ClearAllPoints(); f.close:SetPoint("TOP", f, "TOP", 0, y - 6)
  f:SetHeight(-y + 40)
  f:Show()
end

-- Frage "Hier starten?": unter Level 10 eine Minute im Kern eines fremden Startgebiets (einmal pro Gebiet)
do
  local seenKey, seenAt = nil, 0
  function ns.StartAreaCheck()
      local db = ns.db
      if not db or not db.setupDone or db.paused or (InCombatLockdown and InCombatLockdown()) then return end
      if (UnitLevel("player") or 1) > 10 then return end
      local map = ns.PlayerMap and ns.PlayerMap()
      local pos = map and C_Map.GetPlayerMapPosition(map, "player")
      if not pos then return end
      local x, y = pos:GetXY()
      local key = ns.StartAreaAt(map, x, y)
      if not key or key == ns.CurStartKey() then seenKey = nil; return end
      db.startAsked = db.startAsked or {}
      if db.startAsked[key] then return end
      if seenKey ~= key then seenKey, seenAt = key, GetTime(); return end
      if GetTime() - seenAt < 60 then return end
      db.startAsked[key] = true
      local name = key
      for _, a in ipairs(ns.StartAreas()) do if a.key == key then name = a.name end end
      ns.Confirm((TR"Du bist im Startgebiet %s.\nHier starten?\n\nJa: die Route bleibt hier bis etwa Level 10 bis 12 und rechnet ab jetzt mit diesem Startgebiet. Nein: alles bleibt, wie es ist."):format(name),
        TR"Hier starten", function() ns.SetStartArea(key) end, TR"Nein")
  end
  ns.Ticker(10, function() ns.StartAreaCheck() end)
end
function ns.StartBindCheck()
  local db = ns.db
  if not db or db.bindInn or not UnitLevel then return end
  local L = UnitLevel("player") or 1
  if L > 10 then return end
  local _, race = UnitRace("player")
  db.startBindNames = db.startBindNames or {}
  local home = HomeName()
  local xp = (ns.Plain and ns.Plain(UnitXP("player"))) or UnitXP("player") or 0
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  -- ganz neu (Level 1, noch keine XP): du stehst am Startpunkt, dort ist der Ruhestein gebunden
  if L == 1 and (tonumber(xp) or 0) == 0 and pos then
    local x, y = pos:GetXY()
    db.bindInn, db.bindZone, db.bindStart = { map, x, y }, map, true
    if race and home then db.startBindNames[race] = home end
    return
  end
  -- sonst der bekannte Startpunkt vom Volk, aber nur wenn der Ruhestein noch dort ist
  -- (gleicher Name wie bei einem neuen Charakter, oder ohne Namen bis Level 5: vorher bindet kaum jemand woanders)
  local sb = race and START_BIND[race]
  local known = race and db.startBindNames[race]
  if sb and ((known and home == known) or (not known and L <= 5)) then
    db.bindInn, db.bindZone, db.bindStart = { sb[1], sb[2], sb[3] }, sb[1], true
  end
end
-- nach dem Ruhestein (oder Astralen Rueckruf): da wo du ankommst, ist der Bindepunkt. Genauer als jede Schaetzung
do
  local hf = CreateFrame("Frame")
  hf:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  hf:RegisterEvent("PLAYER_ENTERING_WORLD")
  local castAt, castPos = -999, nil
  local function Here()
    local map = ns.PlayerMap and ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not x or (x == 0 and y == 0) then return end
    return map, x, y
  end
  local function Learn()
    local db = ns.db
    if not db then return end
    local map, x, y = Here()
    if not map then return end
    -- 18.0: noch am gleichen Fleck wie beim Zaubern: noch nicht angekommen (Ladebild, Verzoegerung). Nicht als Gasthaus merken,
    -- spaeter nochmal schauen (Sim Teil D: sonst galt der Dungeon Eingang als Gasthaus)
    local cp = castPos
    if cp and cp[1] == map and math.abs(cp[2] - x) < 0.004 and math.abs(cp[3] - y) < 0.004 then return false end
    castPos = nil
    local old = db.bindInn
    db.bindInn, db.bindZone = { map, x, y }, map
    if not (old and old[1] == map and math.abs(old[2] - x) < 0.01 and math.abs(old[3] - y) < 0.01) then db.bindStart = nil end
    -- 19.33c (absprache hearth_bind, Navi Befund): nur EIN Lernen pro Zauber. Sonst lernte jedes Neuladen, Schiff oder
    -- Zeppelin in den 90 s danach die Stelle dort als Ruhestein Ort
    castAt = -999
  end
  hf:SetScript("OnEvent", function(_, e, unit, _, spellID)
    if e == "UNIT_SPELLCAST_SUCCEEDED" then
      if unit == "player" and (spellID == 8690 or spellID == 556) then
        castAt = GetTime()
        local m, cx, cy = Here()
        castPos = m and { m, cx, cy } or nil
        C_Timer.After(2, function()
          if GetTime() - castAt < 10 and Learn() == false then
            C_Timer.After(6, function() if GetTime() - castAt < 20 then Learn() end end)
          end
        end)
      end
    elseif e == "PLAYER_ENTERING_WORLD" then
      -- anderer Kontinent: erst nach dem Ladebildschirm
      if GetTime() - castAt < 90 then C_Timer.After(1, Learn) end
      C_Timer.After(3, function() if ns.StartBindCheck then pcall(ns.StartBindCheck) end end)
    end
  end)
end

-- 19.32 (Saschas Frage 02:24, Freigabe 02:35): erster Start des Addons auf einem Charakter, der schon gespielt hat.
-- Erledigte Quests, Quests im Log und Berufe liest die Route ohnehin aus dem Spiel und von Questie. Neu hier:
-- Ruhestein Ort aus dem Namen des Bindeorts (GetBindLocation) und den Gasthaeusern, Lehrer Stand auf das jetzige Level
-- (wer schon Level 30 ist, hat vorher normal gelernt) und eine Log Zeile ERSTER START.
-- Charaktere, die das Addon schon kennen (Route oder Fahrplan da), bekommen nur das Merkmal, keine Aenderung.
-- 19.33 (Navi Stand 6b, BASIS.txt): EIN Ruhestein Rater fuer den ersten Start und das Navi, ns.RateBind in NaviFlug.lua
-- (Datei vom Navi Chat). Hier nur noch der Aufruf. Rueckgabe { map, x, y }, wie ("Hauptstadt", "Gastwirt", "hier", "Zone"),
-- nil, "noidx" solange der Gastwirt Index leer ist, sonst nil. Der erste Start nimmt alle Regeln, das Navi strict.
local function InnByBindName(home)
  if ns.RateBind then return ns.RateBind(home) end
end
function ns.GuessBindInn(home, strict)
  home = home or HomeName()
  if ns.RateBind then return ns.RateBind(home, strict) end
end

local function FirstStart(tries, known)
  local db = ns.db
  if not db or db.firstStartDone then return end
  -- Questie und die Service Liste zuerst fertig (hoechstens 60 s warten)
  if (not (ns.QDBAccess and ns.QDBAccess()) or not ns.svcReady) and tries < 12 then
    C_Timer.After(5, function() FirstStart(tries + 1, known) end)
    return
  end
  db.firstStartDone = true
  if known then return end
  local L = UnitLevel and UnitLevel("player") or 1
  local home = HomeName()
  local bindWas = db.bindInn and "bekannt" or nil
  if not db.bindInn then
    local b, how = ns.GuessBindInn(home)
    if b then db.bindInn, db.bindZone, db.bindStart = b, b[1], nil; bindWas = how end
  end
  local nDone = 0
  local c = Questie and Questie.db and Questie.db.char and Questie.db.char.complete
  if type(c) == "table" then for _ in pairs(c) do nDone = nDone + 1 end end
  local nLog = 0
  if ns.ReadLog then pcall(ns.ReadLog) end
  for _ in pairs(ns.logProgress or {}) do nLog = nLog + 1 end
  local nFP = 0
  for _ in pairs(db.knownFP or {}) do nFP = nFP + 1 end
  if ns.TestLog then
    ns.TestLog("START", ("ERSTER START: %d erledigte Quests, %d im Log, %d Flugpunkte, Ruhestein %s (%s), Lehrer Stand Level %d, Level %d"):format(
      nDone, nLog, nFP, tostring(home or "?"), bindWas or "Ort unbekannt", db.trainedAt or 0, L))
  end
end
ns.FirstStart = FirstStart -- fuer Tests (Sim, Trockenlauf)
do
  local ff = CreateFrame("Frame")
  ff:RegisterEvent("PLAYER_ENTERING_WORLD")
  ff:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    local db = ns.db
    if not db or db.firstStartDone then return end
    -- vor der ersten Route: kennt das Addon den Charakter schon? Lehrer Stand gleich setzen, die Route rechnet bald
    -- 19.33: auch bekannt, wenn das Addon den Charakter schon gemerkt hat (db.lastChar, db.chars) oder Flugpunkte kennt
    local known = (db.opt or db.plan60 or db.setupDone or ns.charSeenBefore or (type(db.knownFP) == "table" and next(db.knownFP))) and true or false
    local L = UnitLevel and UnitLevel("player") or 1
    if not known and L > 5 and (db.trainedAt or 0) < L then db.trainedAt = L end
    C_Timer.After(4, function() FirstStart(0, known) end)
  end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("TRAINER_SHOW")
ev:RegisterEvent("MERCHANT_SHOW")
ev:RegisterEvent("TAXIMAP_OPENED")
ev:RegisterEvent("HEARTHSTONE_BOUND")
ev:RegisterEvent("GOSSIP_SHOW")
ev:RegisterEvent("CONFIRM_BINDER")
-- Soll beim Gastwirt gleich gebunden werden? Route Schritt "binden" oder der Ruhestein Hinweis ist da
function ns.WantBind()
  local a = ns.db and ns.db.optMode and ns.OptCurrentAct and ns.OptCurrentAct()
  if a and a.k == "B" then return true end
  local h = ns.svcHint
  return (h and h.kind == "inn") and true or false
end
ev:SetScript("OnEvent", function(_, event, ...)
  local db = ns.db
  if event == "PLAYER_LOGIN" then
    C_Timer.After(10, BuildIndex)
    ns.Ticker(2, Tick)
    return
  end
  if not db then return end
  if event == "PLAYER_LEVEL_UP" then
    local L = ...
    L = tonumber(L)
    if L and L >= 2 then C_Timer.After(3, function() ns.TrainerPopup(L) end) end
    return
  end
  local mapID = ns.PlayerMap()
  if event == "TRAINER_SHOW" then
    db.trainedAt = UnitLevel("player")
    ns.lastTrainerAt = time()
    if ns.serviceTarget and ns.serviceTarget.kind == "trainer" then ns.serviceTarget = nil end
  elseif event == "MERCHANT_SHOW" then
    if ns.serviceTarget and (ns.serviceTarget.kind == "vendor" or ns.serviceTarget.kind == "repair") then ns.serviceTarget = nil end
  elseif event == "TAXIMAP_OPENED" then
    -- Flugmeister in der Naehe gilt jetzt als bekannt
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos and ns.svcReady then
      local px, py = pos:GetXY()
      db.knownFP = db.knownFP or {}
      local maps = { mapID }
      for city, parent in pairs(ns.cityParent or {}) do if city == mapID then table.insert(maps, parent) end end
      for _, ui in ipairs(maps) do
        for _, e in ipairs(ns.svc[ui] or {}) do
          if IsKind(e, "fly") then
            local d = ns.WorldDist({ mapID, px, py }, { ui, e[1], e[2] })
            if d and d < 40 then db.knownFP[e[6]] = true end
          end
        end
      end
      -- alle bekannten Flugpunkte des Kontinents aus der Flugkarte lesen
      pcall(function()
        if not (NumTaxiNodes and TaxiNodeGetType and TaxiNodePosition) then return end
        local cm = mapID
        for _ = 1, 6 do
          local info = cm and C_Map.GetMapInfo(cm)
          if not info or info.mapType == 2 or not info.parentMapID then break end
          cm = info.parentMapID
        end
        local nodes = {}
        for i = 1, NumTaxiNodes() do
          local typ = TaxiNodeGetType(i)
          if typ == "REACHABLE" or typ == "CURRENT" then
            local x, y = TaxiNodePosition(i)
            local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, cm, CreateVector2D(x, y))
            if ok and w then table.insert(nodes, { c, w:GetXY() }) end
          end
        end
        for ui, list in pairs(ns.svc) do
          for _, e in ipairs(list) do
            if IsKind(e, "fly") and not e.city then
              local ok, c, w = pcall(C_Map.GetWorldPosFromMapPos, ui, CreateVector2D(e[1], e[2]))
              if ok and w then
                local wx, wy = w:GetXY()
                for _, nd in ipairs(nodes) do
                  if nd[1] == c and math.sqrt((nd[2] - wx) ^ 2 + (nd[3] - wy) ^ 2) < 250 then db.knownFP[e[6]] = true; break end
                end
              end
            end
          end
        end
      end)
      db.knownFPRev = (db.knownFPRev or 0) + 1
      db.learnedRev = (db.learnedRev or 0) + 1
    end
    if ns.serviceTarget and ns.serviceTarget.kind == "fly" then ns.serviceTarget = nil end
  elseif event == "GOSSIP_SHOW" then
    -- Ruhestein binden: Route will es jetzt (Schritt "binden") oder der Hinweis dazu steht gerade da
    if ns.WantBind and ns.WantBind() then
      local picked = false
      if C_GossipInfo and C_GossipInfo.GetOptions and C_GossipInfo.SelectOption then
        for _, o in ipairs(C_GossipInfo.GetOptions() or {}) do
          local t = tostring(o.name or ""):lower()
          -- nur die Gastwirt Option ("... zu Eurem Zuhause"), nicht jede Zeile mit "heim" (Geheimnis, Heimat ...)
          -- Art "binder" oder Symbol vom Gastwirt (jede Spielsprache), sonst der Text auf Deutsch, Englisch, Franzoesisch, Spanisch
          if o.type == "binder" or o.icon == 132052 or t:find("zuhause", 1, true) or t:find("your home", 1, true)
            or t:find("foyer", 1, true) or t:find("hogar", 1, true) then
            pcall(C_GossipInfo.SelectOption, o.gossipOptionID); picked = true; break
          end
        end
      end
      if not picked and GetGossipOptions and SelectGossipOption then
        local g = { GetGossipOptions() }
        for k = 1, #g, 2 do
          if g[k + 1] == "binder" then pcall(SelectGossipOption, (k + 1) / 2); break end
        end
      end
    end
    return
  elseif event == "CONFIRM_BINDER" then
    if ns.WantBind and ns.WantBind() then
      local ok = pcall(ConfirmBinder)
      if ok and StaticPopup_Hide then StaticPopup_Hide("CONFIRM_BINDER") end
    end
    return
  elseif event == "HEARTHSTONE_BOUND" then
    db.bindZone = mapID
    db.bindStart = nil
    -- Position merken, dort steht der Wirt
    local pos = mapID and C_Map.GetPlayerMapPosition(mapID, "player")
    if pos then local x, y = pos:GetXY(); db.bindInn = { mapID, x, y } end
    if ns.serviceTarget and ns.serviceTarget.kind == "inn" then ns.serviceTarget = nil end
  end
  ns.svcHint = Hint()
end)
