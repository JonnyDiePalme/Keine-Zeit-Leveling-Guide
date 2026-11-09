local ADDON, ns = ...
local TR = ns.TR

-- Gold Mobs: Mobs in deinem Level suchen, die viel Gold pro Stunde bringen.
-- Wert pro Kill: aus deiner eigenen Beute gelernt (Geld plus Items, Items mit Auktionator
-- Preisen oder Haendler Preis), sonst geschaetzt nach Mob Level.
-- Kills pro Stunde: deine gemessene Zeit pro Kill plus Laufweg, begrenzt durch die Respawns.

local CELL = 0.035       -- Rastergroesse auf der Zonenkarte
local RESPAWN = 330      -- Sekunden bis ein Mob wieder da ist (Classic draussen ca 5 bis 6 Min)
local LOOT_SEC = 2       -- Pluendern pro Kill
-- 1.3zi (Pr 09:05 farm_v13zh: Schaetzung 1,4 bis 3,8 mal zu hoch, vor allem Kills je Std): Korrektur Faktor auf die Kills je
-- Std. Start EST_F, danach aus deinen eigenen Messungen gelernt (db.farmCal, ab CAL_MIN_S Farmzeit und CAL_MIN_KILLS)
local FCAL = { EST_F = 0.6, MIN = 0.25, MAX = 1.5, CAL_MIN_S = 600, CAL_MIN_KILLS = 10 }
local function FarmCal()
  local c = ns.db and tonumber(ns.db.farmCal)
  return c or FCAL.EST_F
end
local CALLER = "ForeverWegweiser"

local function Plain(v) if ns.Plain then return ns.Plain(v) end return v end
local function DB()
  local db = ns.db
  if not db then return end
  db.loot = db.loot or {}
  return db
end

------------------------------------------------------------
-- Item Werte
------------------------------------------------------------
local valCache = {}
-- AH Preise aus dem Addon, das du hast: TSM, Auctionator, Auctioneer, Aux, OribosExchange
local SOURCES = {
  { name = "TSM", ok = function() return TSM_API and TSM_API.GetCustomPriceValue end,
    -- 20.3 (P2d, Sascha: Wolfsfleisch Preis unplausibel): Server Markt und Region Mittel, der tiefere zählt (Ausreisser
    -- bei wenig Angeboten), erst ohne beide der kleinste Sofortkauf. Jeder Preis einzeln geschützt.
    get = function(id)
      local function P(k) local ok, v = pcall(TSM_API.GetCustomPriceValue, k, "i:" .. id); v = ok and tonumber(v); return v and v > 0 and v or nil end
      local m, r = P("DBMarket"), P("DBRegionMarketAvg")
      if m and r then return math.min(m, r) end
      return m or r or P("DBMinBuyout")
    end },
  { name = "Auctionator", ok = function() return Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemID end,
    get = function(id) return Auctionator.API.v1.GetAuctionPriceByItemID(CALLER, id) end },
  { name = "Auctioneer", ok = function() return AucAdvanced and AucAdvanced.API and AucAdvanced.API.GetMarketValue end,
    get = function(id, link) return link and AucAdvanced.API.GetMarketValue(link) end },
  { name = "Aux", ok = function() return aux and aux.history and aux.history.value end,
    get = function(id) return aux.history.value(id .. ":0") end },
  { name = "OribosExchange", ok = function() return OEMarketInfo end,
    get = function(id) local t = {}; OEMarketInfo(id, t); return t.market or t.region end },
}

-- Liste der gefundenen Preis Addons
function ns.AHSources()
  local out = {}
  for _, s in ipairs(SOURCES) do local ok, v = pcall(s.ok); if ok and v then table.insert(out, s.name) end end
  return out
end
function ns.HasAuctionator() return #ns.AHSources() > 0 end

-- AH Preis in Kupfer: Mittelwert aller Addons, die einen Preis kennen
function ns.AHPrice(id, link)
  local sum, n, names = 0, 0, {}
  for _, s in ipairs(SOURCES) do
    local okA, avail = pcall(s.ok)
    if okA and avail then
      local ok, v = pcall(s.get, id, link)
      v = ok and tonumber(v)
      if v and v > 0 then sum = sum + v; n = n + 1; table.insert(names, s.name) end
    end
  end
  if n == 0 then return nil end
  return math.floor(sum / n), table.concat(names, "+")
end

-- Wert in Kupfer und woher ("AH" oder "Händler")
function ns.ItemValue(id)
  if not id then return 0 end
  local c = valCache[id]
  if c and GetTime() - c.t < 120 then return c.v, c.src end
  local _, link, quality, _, _, _, _, _, _, _, sell = ns.Api.GetItemInfo(id)
  if quality == nil then
    -- noch nicht im Cache: beim Spiel anfragen, kommt beim naechsten Mal
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    ns.itemInfoMissing = (ns.itemInfoMissing or 0) + 1
    return 0
  end
  sell = Plain(sell) or 0
  local v, src = sell, TR"Händler"
  local db = ns.db
  if quality >= 1 and not (db and db.farmAH == false) then
    local ah, who = ns.AHPrice(id, link)
    -- 5 Prozent Gebuehr beim Verkauf im AH
    if ah and ah * 0.95 > v then v, src = math.floor(ah * 0.95), TR"AH " .. (who or "") end
  end
  valCache[id] = { v = v, src = src, t = GetTime() }
  return v, src
end

------------------------------------------------------------
-- Startwerte aus cMaNGOS (BerufeData.lua): einmal beim ersten Gebrauch lesen
------------------------------------------------------------
local cmNpc, cmWith, cmQ, cmQOf
local function CMParse()
  if cmNpc then return end
  cmNpc, cmWith = {}, {}
  for rec in (ns.CM_NPC or ""):gmatch("[^;]+") do
    local id, m, v, rest = rec:match("^(%d+),(%d+),(%d+)(.*)$")
    id = tonumber(id)
    if id then
      local e = { m = tonumber(m), v = tonumber(v), c = {}, s = {} }
      for kind, item, n in rest:gmatch(",([cs])(%d+):(%d+)") do
        item = tonumber(item)
        e[kind][item] = tonumber(n) / 1000
        cmWith[item] = cmWith[item] or {}
        cmWith[item][id] = e[kind][item]
      end
      cmNpc[id] = e
    end
  end
  cmQ, cmQOf = {}, {}
  for rec in (ns.CM_QDROP or ""):gmatch("[^;]+") do
    local item, list = rec:match("^(%d+)=(.*)$")
    item = tonumber(item)
    if item then
      local t = {}
      for npc, n in list:gmatch("(%d+):(%d+)") do
        npc = tonumber(npc)
        t[npc] = tonumber(n) / 1000
        cmQOf[npc] = cmQOf[npc] or {}
        table.insert(cmQOf[npc], item)
      end
      cmQ[item] = t
    end
  end
end
-- { m = Kupfer, v = Beute Wert, c = { [Stoff] = Stueck }, s = { [Leder] = Stueck } } oder nil
function ns.CMNpc(id) CMParse(); return id and cmNpc[id] end
-- Mobs mit diesem Stoff oder Leder: { [npc] = Stueck pro Kill }
function ns.CMNpcsWith(item) CMParse(); return cmWith[item] end
-- Quest Item: { [npc] = Stueck pro Kill }
function ns.CMQuestDrop(item) CMParse(); return cmQ[item] end

-- Quest Item: wie viele Kills fuer ein Stueck? Startwert aus cMaNGOS (Mittel ueber die Mobs, die es droppen),
-- gemischt mit dem, was du auf Forever schon gesehen hast (nur Kills, waehrend du das Item gebraucht hast)
function ns.QuestDropKills(item, npcs, strict)
  CMParse()
  local t = cmQ[item]
  local sum, n = 0, 0
  if t then
    for _, npc in ipairs(npcs or {}) do if t[npc] then sum = sum + t[npc]; n = n + 1 end end
    if n == 0 and not strict then for _, p in pairs(t) do sum = sum + p; n = n + 1 end end
  end
  local p = n > 0 and sum / n or nil
  local db = ns.db
  local d = db and db.qdrop and db.qdrop[item]
  if d and (d.k or 0) >= 3 then
    -- gelernt: wie 4 Kills Startwert (oder 1.6 Kills pro Stueck ohne Daten) plus deine echten Kills
    local p0 = p or (1 / 1.6)
    p = ((d.n or 0) + 4 * p0) / ((d.k or 0) + 4)
  end
  if not p or p <= 0 then return nil end
  return math.max(1, math.min(12, 1 / p))
end

-- braucht ein offenes Questziel gerade dieses Item? (dann zaehlt der Kill als Versuch)
local function QuestWanted(item)
  local name = ns.Api.GetItemInfo and ns.Api.GetItemInfo(item)
  if not name then return false end
  for _, lp in pairs(ns.logProgress or {}) do
    if not lp.complete then
      for _, o in ipairs(lp.objs or {}) do
        if not o.done and type(o.text) == "string" and o.text:find(name, 1, true) then return true end
      end
    end
  end
  return false
end

------------------------------------------------------------
-- Beute lernen
------------------------------------------------------------
local looted = {}  -- [guid] = Zeit (schon gepluendert: zweites Mal ist Kuerschnern)
local win
local function NpcFromGUID(g)
  if type(g) ~= "string" then return end
  local t, _, _, _, _, id = strsplit("-", g)
  if t == "Creature" then return tonumber(id) end
end

local function NpcLevel(id)
  if not ns.QDBAccess then return end
  local QDB = ns.QDBAccess()
  if not (QDB and QDB.QueryNPCSingle) then return end
  local ok1, lo = pcall(QDB.QueryNPCSingle, id, "minLevel")
  local ok2, hi = pcall(QDB.QueryNPCSingle, id, "maxLevel")
  if ok1 and ok2 and lo and hi then return (lo + hi) / 2 end
end

local function Rec(npc)
  local db = DB()
  if not db then return end
  local r = db.loot[npc]
  if not r then
    r = { k = 0, kc = 0, c = 0, it = {}, sk = 0, si = {}, lv = NpcLevel(npc) }
    db.loot[npc] = r
  end
  return r
end

-- Was war das fuer eine Beute? Kuerschnern und Taschendiebstahl erkennt man am Zauber kurz davor
local SKIN_IDS = { [8613] = true, [8617] = true, [8618] = true, [10768] = true }
local PICK_IDS = { [921] = true }
local lastCast -- { kind = "skin" / "pick", t }
local lastCommit -- gerade verbucht: Geld, das kurz nach dem Schliessen noch kommt, gehoert dazu

local function ReadLoot()
  if win then return end
  if IsFishingLoot and IsFishingLoot() then return end
  if not GetNumLootItems then return end
  local mode = (lastCast and GetTime() - lastCast.t < 3) and lastCast.kind or "loot"
  lastCast = nil -- gilt nur fuer dieses eine Pluendern
  win = { money0 = Plain(GetMoney()) or 0, corpses = {}, n = 0, mode = mode }
  local num = Plain(GetNumLootItems()) or 0
  for slot = 1, num do
    local link = GetLootSlotLink and GetLootSlotLink(slot)
    local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    local _, _, qty = GetLootSlotInfo(slot)
    qty = Plain(qty) or 1
    local ok, src = pcall(function() return { GetLootSourceInfo(slot) } end)
    if ok and type(src) == "table" then
      for k = 1, #src, 2 do
        local g = src[k]
        local npc = NpcFromGUID(g)
        if npc then
          local c = win.corpses[g]
          if not c then
            -- skin: Kuerschnern, pick: Taschendiebstahl (lebender Mob), again: dieselbe Leiche nochmal (Taschen waren voll)
            c = { npc = npc, skin = mode == "skin", pick = mode == "pick", again = mode == "loot" and looted[g] ~= nil, items = {} }
            win.corpses[g] = c
            win.n = win.n + 1
          end
          if id then c.items[id] = (c.items[id] or 0) + (tonumber(Plain(src[k + 1])) or qty or 1) end
        end
      end
    end
  end
end

local function Commit()
  local w = win
  win = nil
  if not w then return end
  local delta = math.max(0, (Plain(GetMoney()) or w.money0) - w.money0)
  -- Geld gehoert zu den Leichen, die zum ersten Mal gepluendert werden (nicht Kuerschnern, nicht Taschendiebstahl)
  -- zweites Oeffnen mit Leder (Kuerschnern ohne erkannten Zauber): doch Kuerschnern
  for _, c in pairs(w.corpses) do
    if c.again then
      for id in pairs(c.items) do
        local it = ns.ProfItem and ns.ProfItem(id)
        if it and it.prof == "skin" then c.skin, c.again = true, false; break end
      end
    end
  end
  local normal = {}
  for _, c in pairs(w.corpses) do if not (c.skin or c.pick or c.again) then normal[#normal + 1] = c end end
  local share = #normal > 0 and delta / #normal or 0
  local now = GetTime()
  local sess = ns.farmSess
  local recs = {}
  for g, c in pairs(w.corpses) do
    local r = Rec(c.npc)
    if r then
      if c.skin then
        r.sk = r.sk + 1
        for id, q in pairs(c.items) do r.si[id] = (r.si[id] or 0) + q end
      elseif c.pick then
        -- Taschendiebstahl: zaehlt fuers Gold pro Stunde, aber nicht als Kill
      elseif c.again then
        -- zweites Oeffnen derselben Leiche: Items dazu, kein neuer Kill
        for id, q in pairs(c.items) do r.it[id] = (r.it[id] or 0) + q end
        r.c = r.c + share
      else
        r.k = r.k + 1
        r.c = r.c + share
        for id, q in pairs(c.items) do r.it[id] = (r.it[id] or 0) + q end
        looted[g] = now
        recs[#recs + 1] = r
        -- Quest Items dieses Mobs: Versuch zaehlen, solange ein Questziel sie braucht (Dropchance auf Forever)
        CMParse()
        local db = DB()
        for _, item in ipairs(cmQOf[c.npc] or {}) do
          if QuestWanted(item) or (c.items[item] or 0) > 0 then
            db.qdrop = db.qdrop or {}
            local d = db.qdrop[item] or { k = 0, n = 0 }
            d.k = d.k + 1
            d.n = d.n + (c.items[item] or 0)
            db.qdrop[item] = d
          end
        end
      end
      if sess then
        for id, q in pairs(c.items) do sess.items = sess.items + q * (ns.ItemValue(id) or 0) end
      end
    end
  end
  if sess then sess.copper = sess.copper + delta end
  lastCommit = { t = now, recs = recs, money = Plain(GetMoney()) or 0 }
  -- alte Eintraege wegwerfen
  for g, t in pairs(looted) do if now - t > 900 then looted[g] = nil end end
end

-- Geld, das erst kurz nach dem Schliessen ankommt, noch der gerade verbuchten Beute geben
local function LateMoney()
  local lc = lastCommit
  if win or not lc or GetTime() - lc.t > 0.8 then return end
  local m = Plain(GetMoney()) or lc.money
  local extra = m - lc.money
  lc.money = m
  if extra <= 0 then return end
  if #lc.recs > 0 then for _, r in ipairs(lc.recs) do r.c = r.c + extra / #lc.recs end end
  if ns.farmSess then ns.farmSess.copper = ns.farmSess.copper + extra end
end

-- Kills zaehlen ohne Kampflog (auf Forever fuer Addons gesperrt): dein Ziel stirbt und war deins
local counted = {}
local function CountTargetKill()
  if not (UnitExists and ns.Api.U(UnitExists, "target") and UnitIsDead and ns.Api.U(UnitIsDead, "target")) then return end
  if UnitIsPlayer and ns.Api.U(UnitIsPlayer, "target") then return end
  if UnitIsTapDenied and ns.Api.U(UnitIsTapDenied, "target") then return end
  local g = Plain(UnitGUID("target"))
  if type(g) ~= "string" or counted[g] then return end
  counted[g] = GetTime()
  local npc = NpcFromGUID(g)
  if npc and ns.OnKill then pcall(ns.OnKill, npc, Plain(UnitName("target"))) end
  local r = npc and Rec(npc)
  if r then
    r.kc = r.kc + 1
    if ns.farmSess then ns.farmSess.kills = ns.farmSess.kills + 1 end
  end
  local now = GetTime()
  for k, t in pairs(counted) do if now - t > 900 then counted[k] = nil end end
end

local lf = CreateFrame("Frame")
ns.RegEv(lf, "LOOT_READY")
ns.RegEv(lf, "LOOT_OPENED")
ns.RegEv(lf, "LOOT_CLOSED")
ns.RegEv(lf, "PLAYER_TARGET_CHANGED")
ns.RegEv(lf, "PLAYER_MONEY")
ns.RegEv(lf, "UNIT_SPELLCAST_SUCCEEDED")
if lf.RegisterUnitEvent then ns.RegUEv(lf, "UNIT_HEALTH", "target") else ns.RegEv(lf, "UNIT_HEALTH") end
lf:SetScript("OnEvent", function(_, e, unit, _, spellID)
  if e == "LOOT_READY" or e == "LOOT_OPENED" then
    pcall(ReadLoot)
  elseif e == "LOOT_CLOSED" then
    -- gleich verbuchen: die naechste Leiche darf sofort kommen
    pcall(Commit)
  elseif e == "PLAYER_MONEY" then
    pcall(LateMoney)
  elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
    if unit == "player" then
      spellID = Plain(spellID)
      if SKIN_IDS[spellID] then lastCast = { kind = "skin", t = GetTime() }
      elseif PICK_IDS[spellID] then lastCast = { kind = "pick", t = GetTime() } end
    end
  else
    pcall(CountTargetKill)
  end
end)

------------------------------------------------------------
-- Wert pro Kill
------------------------------------------------------------
local function Formula(m)
  -- grob Classic: Geld plus graue Items, Level 20 ca 3s, Level 40 ca 12s, Level 60 ca 26s
  return 1.1 * (math.max(1, m) ^ 1.9)
end

local function HasSkinning()
  if not GetNumSkillLines then return false end
  for i = 1, GetNumSkillLines() do
    local name = GetSkillLineInfo(i)
    if name == "Kürschnerei" or name == "Kürschnerei" or name == "Skinning" then return true end
  end
  return false
end

-- gelernter Wert eines Mobs (Kupfer pro Kill) und wie viele Kills dahinter stehen
local function Learned(r, skin)
  local kills = math.max(r.k or 0, r.kc or 0)
  if kills <= 0 then return nil, 0 end
  local v = r.c or 0
  for id, q in pairs(r.it or {}) do v = v + q * (ns.ItemValue(id) or 0) end
  if skin and (r.sk or 0) > 0 then
    local sv = 0
    for id, q in pairs(r.si or {}) do sv = sv + q * (ns.ItemValue(id) or 0) end
    v = v + sv -- Kuerschnern zaehlt zum Kill dazu
  end
  return v / kills, kills
end

-- Drop Tabelle aus QuestieDB (Wowhead Daten): [npc] = { { item, Prozent }, ... }
-- enthaelt Stoff, Leder, Fleisch und Co. mit echten Drop Chancen
local dropByNpc
local function DropTable()
  if dropByNpc ~= nil then return dropByNpc or nil end
  local lib = LibQuestieDB
  local mod = lib and lib.Support and lib.Support.Get and lib.Support.Get("QuestieClassicItemDrops")
  if not (mod and mod.wowheadData) and QuestieLoader and QuestieLoader.ImportModule then
    local ok, m = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieClassicItemDrops")
    if ok and type(m) == "table" and m.wowheadData then mod = m end
  end
  local data = mod and mod.wowheadData
  if not data then return nil end -- noch nicht geladen, spaeter nochmal
  dropByNpc = false
  local ld = loadstring or load
  if type(data) == "string" and ld then
    local fn = ld(data)
    local ok, t = pcall(fn or function() end)
    data = ok and t or nil
  end
  if type(data) ~= "table" then return nil end
  local by = {}
  for item, npcs in pairs(data) do
    if type(npcs) == "table" then
      for npc, pct in pairs(npcs) do
        if type(pct) == "number" and pct > 0 and pct < 100 then -- 100 Prozent sind Quest Items
          by[npc] = by[npc] or {}
          table.insert(by[npc], { item, pct })
        end
      end
    end
  end
  dropByNpc = by
  return by
end
ns.DropTable = DropTable

-- erwarteter Wert der bekannten Drops pro Kill
function ns.DropValue(npc)
  local t = DropTable()
  local list = t and t[npc]
  if not list then return 0, nil end
  local v, top, tv = 0, nil, 0
  for _, d in ipairs(list) do
    local iv = ns.ItemValue(d[1]) or 0
    local e = iv * d[2] / 100
    v = v + e
    if e > tv then top, tv = d, e end
  end
  return v, top
end

-- Schaetzung pro Level aus allen gelernten Mobs (+-2 Level), sonst Formel
local byLevel
local function BuildByLevel(skin)
  byLevel = {}
  local db = DB()
  for _, r in pairs(db and db.loot or {}) do
    local v, k = Learned(r, skin)
    if v and k >= 3 and r.lv then
      local b = math.floor(r.lv + 0.5)
      byLevel[b] = byLevel[b] or { s = 0, n = 0 }
      byLevel[b].s = byLevel[b].s + v; byLevel[b].n = byLevel[b].n + 1
    end
  end
end
local function Estimate(m)
  local s, n = 0, 0
  local b = math.floor(m + 0.5)
  for d = -2, 2 do local e = byLevel and byLevel[b + d]; if e then s = s + e.s; n = n + e.n end end
  if n >= 3 then return s / n, TR"ähnliche Mobs" end
  return Formula(m), TR"Formel"
end

-- 1.3zzd (P133): alle gelernten Mobs (id, Kupfer pro Kill ohne Kuerschnern, Kills) zum Teilen
function ns.NpcLearnedAll()
  local db = DB()
  local t = db and db.loot or {}
  local k
  return function()
    while true do
      local r
      k, r = next(t, k)
      if k == nil then return nil end
      local v, n = Learned(r, false)
      if v then return k, v, n end
    end
  end
end

-- Kupfer pro Kill, Gewicht 0 bis 1 wie sicher (1 = gelernt)
function ns.NpcValue(id, m, skin)
  local db = DB()
  local r = db and db.loot[id]
  local est, how = Estimate(m)
  -- Startwert aus cMaNGOS: Geld plus Beute beim Haendler (plus Leder beim Kuerschnern), genauer als die Formel
  local cm = ns.CMNpc(id)
  if cm then
    est, how = cm.m + cm.v, "cMaNGOS"
    if skin then for item, n in pairs(cm.s) do est = est + n * (ns.ItemValue(item) or 0) end end
  elseif how == TR"Formel" then est = est + (ns.DropValue(id)) end
  -- 1.3zzd (P133): ohne eigene Beute ein geteilter Wert anderer Spieler (Median), als Schaetzung (Gewicht 0)
  -- 1.3zzf (K 04:44): dazwischen die Startdaten gelernt: geteilt ab 2 Absendern, sonst gelernt, sonst geteilt von 1
  if not (r and math.max(r.k or 0, r.kc or 0) > 0) then
    local sv, sn = nil, 0
    if ns.SharedValue then sv, sn = ns.SharedValue("k", id) end
    local gv = ns.GelerntMob and ns.GelerntMob(id)
    local pick = (sv and (sn or 0) >= ns.GELERNT.MIN_SENDERS) and sv or gv or sv
    if pick then
      est = pick
      if skin and cm then for item, n in pairs(cm.s) do est = est + n * (ns.ItemValue(item) or 0) end end
    end
  end
  if r then
    local v, k = Learned(r, skin)
    if v then
      -- deine Beute auf Forever zaehlt mit jedem Kill mehr (ab 10 Kills nur noch sie)
      local w = math.min(1, k / (cm and 10 or 6))
      return w * v + (1 - w) * est, w, k
    end
  end
  return est, 0, 0
end

------------------------------------------------------------
-- Spots suchen
------------------------------------------------------------
local zoneSize = {}
local function ZoneYards(ui)
  local z = zoneSize[ui]
  if z then return z[1], z[2] end
  local w = ns.WorldDist and ns.WorldDist({ ui, 0, 0.5 }, { ui, 1, 0.5 })
  local h = ns.WorldDist and ns.WorldDist({ ui, 0.5, 0 }, { ui, 0.5, 1 })
  w, h = w or 3000, h or 2000
  zoneSize[ui] = { w, h }
  return w, h
end

local busy = false
function ns.FarmBusy() return busy end

-- 20.3y: Mob gibt es in Classic/Forever (Questie Daten enthalten auch Mobs aus spaeteren Erweiterungen und Events).
-- Ohne cMaNGOS Daten im Addon: alle wie bisher
local function KnownMob(id)
  if not id then return false end
  CMParse()
  if not next(cmNpc) then return true end
  if cmNpc[id] then return true end
  local dt = DropTable()
  if dt and dt[id] then return true end
  local db = DB()
  if db and db.loot and db.loot[id] then return true end
  return false
end
ns.FarmKnownMob = KnownMob

function ns.FarmSpots(done)
  if busy then return end
  if not ns.QDBAccess then return end
  local QDB, ZDB = ns.QDBAccess()
  if not (QDB and ZDB) then ns.Print(TR"Gold Mobs braucht Questie, die Daten sind noch nicht geladen."); return end
  if not ns.svcReady then
    if ns.farmWaiting then return end
    ns.farmWaiting = true
    if ns.BuildSvcIndex then ns.BuildSvcIndex() end
    ns.Print(TR"Gold Mobs: Mob Daten werden noch gelesen, die Suche startet gleich von selbst ...")
    local tries = 0
    local function Wait()
      tries = tries + 1
      if ns.svcReady then ns.farmWaiting = false; ns.FarmSpots(done)
      elseif tries < 24 then C_Timer.After(5, Wait)
      else ns.farmWaiting = false end
    end
    C_Timer.After(5, Wait)
    return
  end
  busy = true
  local db = ns.db
  local L = UnitLevel("player")
  local lo = L - (db.farmBelow or 8)
  local hi = L + (db.farmAbove or 1)
  local skin = HasSkinning()
  BuildByLevel(skin)
  local function N(id, k) local ok, v = pcall(QDB.QueryNPCSingle, id, k); if ok then return v end end
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
  -- Zonen mit passenden Mobs
  local zones = {}
  for ui, z in pairs(ns.zones or {}) do
    -- keine Zonen der anderen Fraktion (dort sind die Wachen und Questgeber feindlich)
    if z.max >= lo - 2 and z.min <= hi + 2 and not (ns.cityParent and ns.cityParent[ui]) and ns.hostileIds[ui]
      and not (ns.EnemyZone and ns.EnemyZone(ui)) then
      table.insert(zones, ui)
    end
  end
  local spots = {}
  local zi = 0
  local list, li, cells, ui
  local npcInfo = {}
  local function FinishZone()
    local zw, zh = ZoneYards(ui)
    local area = (3 * CELL * zw) * (3 * CELL * zh)
    for key, cl in pairs(cells) do
      local cx, cy = key:match("^(%-?%d+):(%-?%d+)$")
      cx, cy = tonumber(cx), tonumber(cy)
      local cnt, sx, sy, per = 0, 0, 0, {}
      for dx = -1, 1 do
        for dy = -1, 1 do
          local o = cells[(cx + dx) .. ":" .. (cy + dy)]
          if o then
            cnt = cnt + o.n; sx = sx + o.sx; sy = sy + o.sy
            for id, n in pairs(o.per) do per[id] = (per[id] or 0) + n end
          end
        end
      end
      if cnt >= 6 and cl.n >= 2 then
        local kt, val, wsum, mlo, mhi, xp = 0, 0, 0, 99, 0, 0
        for id, n in pairs(per) do
          local inf = npcInfo[id]
          local diff = inf.m - L
          kt = kt + n * (ns.KillSeconds and ns.KillSeconds(diff) or 25)
          local v, w = ns.NpcValue(id, inf.m, skin)
          inf.v, inf.w = v, w
          val = val + n * v
          wsum = wsum + n * w
          mlo = math.min(mlo, inf.lo); mhi = math.max(mhi, inf.hi)
        end
        kt, val = kt / cnt, val / cnt
        local spacing = math.sqrt(area / cnt)
        local walk = spacing * 0.6 / 7
        local own = 3600 / (kt + walk + LOOT_SEC)
        local cap = cnt * 3600 / RESPAWN
        local kph = math.min(own, cap) * FarmCal()
        local names = {}
        for id, n in pairs(per) do table.insert(names, { id = id, n = n, name = npcInfo[id].name }) end
        table.sort(names, function(a, b) return a.n > b.n end)
        table.insert(spots, { map = ui, x = sx / cnt, y = sy / cnt, n = cnt, lo = mlo, hi = mhi, kph = kph, capped = cap < own,
          gph = kph * val, val = val, learned = wsum / cnt, mobs = names, kt = kt })
      end
    end
  end
  local function NextZone()
    zi = zi + 1
    ui = zones[zi]
    if not ui then
      -- beste zuerst, keine zwei Spots direkt nebeneinander
      table.sort(spots, function(a, b) return a.gph > b.gph end)
      local out = {}
      -- 20.2 (P2, Sascha: Praeriewolf Mulgore 3x): Stellen in derselben Zone mit derselben Haupt Mob Art sind EINE
      -- Farm Runde (mehrere Punkte, im Kreis). Gewinn pro Stunde = Mittel der Stellen nach Spawn Zahl. Allgemein, keine Mob Liste.
      for _, s in ipairs(spots) do
        local main = s.mobs and s.mobs[1] and s.mobs[1].id
        local hit
        for _, o in ipairs(out) do
          if o.map == s.map and (math.sqrt((o.x - s.x) ^ 2 + (o.y - s.y) ^ 2) < 0.09 or (main and o.main == main)) then hit = o; break end
        end
        if hit then
          local close = false
          for _, p in ipairs(hit.pts) do if math.sqrt((p.x - s.x) ^ 2 + (p.y - s.y) ^ 2) < 0.04 then close = true end end
          if not close and #hit.pts < 8 then
            table.insert(hit.pts, { x = s.x, y = s.y, n = s.n })
            hit.gph = (hit.gph * hit.n + s.gph * s.n) / (hit.n + s.n)
            hit.n = hit.n + s.n
          end
        elseif #out < 40 then -- 20.3 (P16): mehr Stellen, damit ein Mob in mehreren Gebieten zur Wahl steht
          s.main = main
          s.pts = { { x = s.x, y = s.y, n = s.n } }
          table.insert(out, s)
        end
      end
      table.sort(out, function(a, b) return a.gph > b.gph end)
      -- Anreise
      local pm = ns.PlayerMap and ns.PlayerMap()
      local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
      if pos then
        local px, py = pos:GetXY()
        local sp = (ns.PlanSpeed and ns.PlanSpeed()) or 7
        for _, s in ipairs(out) do
          local d = ns.WorldDist and ns.WorldDist({ pm, px, py }, { s.map, s.x, s.y })
          s.dist = d
          s.travel = d and d / sp or nil
        end
      end
      ns.farmSpots = out
      ns.farmSpotsAt = GetTime()
      ns.farmSpotsLvl = L
      busy = false
      if done then done(out) end
      return
    end
    list, li, cells = ns.hostileIds[ui], 0, {}
    local SafeStep
    local function Step()
      local n = 0
      while li < #list and n < 40 do
        li = li + 1
        n = n + 1
        local id = list[li]
        local minL, maxL = N(id, "minLevel") or 0, N(id, "maxLevel") or 0
        local rank = N(id, "rank") or 0
        -- 20.3y (S Test 17:05, Gold Liste mit Firelands Drudge, New Avalon Citizen ...): nur Mobs, die es im Spiel gibt.
        -- Bekannt heisst: in den cMaNGOS Classic Daten, in der Classic Drop Tabelle oder schon selbst gelootet
        if rank == 0 and maxL >= 2 and minL >= lo and maxL <= hi and KnownMob(id) then
          local sp = N(id, "spawns")
          for areaId, coords in pairs(type(sp) == "table" and sp or {}) do
            if Ui(areaId) == ui and type(coords) == "table" then
              for k, c in ipairs(coords) do
                if k > 80 then break end
                if type(c) == "table" and c[1] and c[1] > 0 then
                  if not npcInfo[id] then npcInfo[id] = { name = N(id, "name") or "?", lo = minL, hi = maxL, m = (minL + maxL) / 2 } end
                  local x, y = c[1] / 100, c[2] / 100
                  local key = math.floor(x / CELL) .. ":" .. math.floor(y / CELL)
                  local cl = cells[key]
                  if not cl then cl = { n = 0, sx = 0, sy = 0, per = {} }; cells[key] = cl end
                  cl.n = cl.n + 1; cl.sx = cl.sx + x; cl.sy = cl.sy + y
                  cl.per[id] = (cl.per[id] or 0) + 1
                end
              end
            end
          end
        end
      end
      if li < #list then C_Timer.After(0, SafeStep); return end
      FinishZone()
      C_Timer.After(0, NextZone)
    end
    -- Fehler: Gold Mobs nicht bis zum Neuladen sperren
    SafeStep = function()
      local ok, err = pcall(Step)
      if not ok then
        busy = false
        if ns.TestLog then ns.TestLog("FEHLER", "Gold Mobs: " .. tostring(err)) end
      end
    end
    SafeStep()
  end
  NextZone()
end

------------------------------------------------------------
-- Farmen starten und messen
------------------------------------------------------------
function ns.FarmActive() return ns.farmSess ~= nil end

function ns.FarmStart(s)
  if not s then return end
  local names = {}
  for i, m in ipairs(s.mobs) do if i > 3 then break end table.insert(names, m.name) end
  local txt = table.concat(names, ", ")
  -- eine andere Farm Route lief noch (Ruf Mobs, Berufe): die ist damit beendet (sonst bleibt sie nach Stop uebrig, Sim 17.2)
  ns.repFarm = nil
  if ns.db then ns.db.profSess = nil end
  ns.farmSess = { t0 = GetTime(), copper = 0, items = 0, kills = 0, spot = s, est = s.gph, round = 1 }
  -- 20.2 (P2): Farm Runde ueber alle Stellen, naechste zuerst ab dir, am Ende wieder von vorne (Linie auf der Karte
  -- wie bei der Route). Je Stelle so lange, wie ihre Mobs zum Toeten brauchen (Spawns mal Kill Zeit, 45 s bis 5 Min)
  local pts = {}
  for _, p in ipairs(s.pts or { { x = s.x, y = s.y, n = s.n } }) do pts[#pts + 1] = p end
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm == s.map and C_Map.GetPlayerMapPosition(pm, "player")
  local cx, cy = s.x, s.y
  if pos then cx, cy = pos:GetXY() end
  local order = {}
  while #pts > 0 do
    local bi, bd
    for i, p in ipairs(pts) do
      local d = (p.x - cx) ^ 2 + (p.y - cy) ^ 2
      if not bd or d < bd then bi, bd = i, d end
    end
    local p = table.remove(pts, bi)
    order[#order + 1] = p
    cx, cy = p.x, p.y
  end
  local steps = {}
  for _, p in ipairs(order) do
    local dwell = math.max(45, math.min(300, (p.n or 6) * ((s.kt or 25) + LOOT_SEC)))
    steps[#steps + 1] = { map = s.map, x = p.x, y = p.y, t = 0, lvl = UnitLevel("player"),
      acts = { { k = "G", farm = true, obj = txt, lo = s.lo, hi = s.hi, gph = s.gph, dwell = #order > 1 and dwell or nil, r = 60 } } }
  end
  if ns.OptLoad then
    ns.OptLoad(steps, { title = TR"Gold farmen: " .. txt, target = UnitLevel("player"), farm = true, loop = #order > 1 or nil })
    ns.db.opt.farm = true
    ns.db.opt.loop = #order > 1 or nil
  end
  ns.Print((TR"Gold farmen: %s in %s, geschätzt %s pro Stunde. Stoppen mit dem Knopf Stop oder /klg farm stop."):format(
    txt, ns.ZoneName and ns.ZoneName(s.map) or "?", ns.Money(s.gph)))
end

function ns.FarmMeasured()
  local s = ns.farmSess
  if not s then return end
  local el = GetTime() - s.t0
  local total = s.copper + s.items
  return total, el, el > 60 and total / el * 3600 or nil
end

-- 20.2: Runde zu Ende, Farmen laeuft noch: wieder ab der ersten Stelle
function ns.FarmLoopAgain(opt)
  if not (ns.farmSess and opt and opt.farm and opt.loop and #(opt.steps or {}) > 0) then return false end
  for _, st in ipairs(opt.steps) do for _, a in ipairs(st.acts or {}) do a.arrive = nil end end
  opt.idx = 1
  ns.farmSess.round = (ns.farmSess.round or 1) + 1
  ns.Print((TR"Runde %d: wieder von vorne, die Mobs sind inzwischen nachgewachsen."):format(ns.farmSess.round))
  return true
end

function ns.FarmStop()
  local s = ns.farmSess
  if not s then return end
  local total, el, gph = ns.FarmMeasured()
  ns.farmSess = nil
  -- 1.3zi: Schaetzung an der Messung lernen (halber Schritt, begrenzt)
  if gph and s.est and s.est > 0 and el >= FCAL.CAL_MIN_S and (s.kills or 0) >= FCAL.CAL_MIN_KILLS and ns.db then
    local c0 = FarmCal()
    local c1 = math.max(FCAL.MIN, math.min(FCAL.MAX, c0 * math.sqrt(gph / s.est)))
    ns.db.farmCal = c1
    if ns.TestLog then ns.TestLog("FARM", ("Schaetzung gelernt: gemessen %d, geschaetzt %d je Std, Faktor %.2f auf %.2f"):format(math.floor(gph), math.floor(s.est), c0, c1)) end
  end
  ns.Print((TR"Farmen beendet: %s in %d Min (Geld %s, Items %s), %d Kills%s."):format(ns.Money(total), math.floor(el / 60 + 0.5),
    ns.Money(s.copper), ns.Money(s.items), s.kills, gph and (", " .. ns.Money(gph) .. TR" pro Stunde") or ""))
  local o = ns.db and ns.db.opt
  if o and o.farm then o.idx = #(o.steps or {}) + 1 end
  if ns.ProfileBackToLevel then ns.ProfileBackToLevel() elseif ns.AutoOpt then ns.AutoOpt(true) end
end

function ns.FarmHudLine()
  local s = ns.farmSess
  if not s then return end
  local total, el, gph = ns.FarmMeasured()
  if gph then
    return (TR"Farmen: %s pro Std gemessen (geschätzt %s), %s in %d Min"):format(ns.Money(gph), ns.Money(s.est or 0), ns.Money(total), math.floor(el / 60))
  end
  return (TR"Farmen: geschätzt %s pro Std, Messung läuft"):format(ns.Money(s.est or 0))
end

------------------------------------------------------------
-- Text fuer das grosse Fenster
------------------------------------------------------------
local function Pct(x) return math.floor(x * 100 + 0.5) .. "%" end

function ns.FarmSpotLines(s)
  local out = {}
  if not s then
    table.insert(out, TR"Links einen Spot anklicken.")
    return out
  end
  local zn = ns.ZoneName and ns.ZoneName(s.map) or "?"
  table.insert(out, ("|cffffd100%s|r  (%.0f, %.0f)"):format(zn, s.x * 100, s.y * 100))
  table.insert(out, (TR"Geschätzt: |cff40ff40%s pro Stunde|r"):format(ns.Money(s.gph)))
  table.insert(out, (TR"%d Kills pro Stunde, %s pro Kill, Zeit pro Kill ca %d Sek"):format(math.floor(s.kph + 0.5), ns.Money(s.val), math.floor(s.kt + 0.5)))
  if s.capped then table.insert(out, TR"|cffff9030Begrenzt durch Respawns: hier stehen wenige Mobs, du bist schneller als sie nachkommen.|r") end
  table.insert(out, (TR"Mobs Level %d bis %d, %d Spawns im Gebiet"):format(s.lo, s.hi, s.n))
  if s.travel then
    table.insert(out, (TR"Anreise: ca %d Min"):format(math.floor(s.travel / 60 + 0.5)))
  else
    table.insert(out, TR"|cff9d9d9dAnreise: anderer Kontinent|r")
  end
  local how = s.learned >= 0.7 and TR"|cff40ff40aus deiner Beute gelernt|r" or (s.learned >= 0.2 and TR"|cffffd100teils gelernt, teils geschätzt|r" or TR"|cffff9030geschätzt (noch keine Beute von diesen Mobs)|r")
  table.insert(out, TR"Wert: " .. how)
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Mobs|r")
  local db = ns.db
  local skin = HasSkinning()
  for i, m in ipairs(s.mobs) do
    if i > 6 then break end
    local r = db and db.loot and db.loot[m.id]
    local v, w, k = ns.NpcValue(m.id, (s.lo + s.hi) / 2, skin)
    table.insert(out, (TR"   %s  %d Spawns, %s pro Kill%s"):format(m.name, m.n, ns.Money(v), k > 0 and (" |cff9d9d9d(" .. k .. TR" Kills gelernt)|r") or ""))
    if r and k > 0 then
      local items = {}
      for id, q in pairs(r.it or {}) do
        local val, src = ns.ItemValue(id)
        table.insert(items, { id = id, rate = q / k, v = q * val / k, src = src })
      end
      table.sort(items, function(a, b) return a.v > b.v end)
      for j, it in ipairs(items) do
        if j > 3 or it.v <= 0 then break end
        local name = ns.Api.GetItemInfo(it.id) or (TR"Item " .. it.id)
        table.insert(out, (TR"      |cff9d9d9d%s %s, %s pro Kill (%s)|r"):format(name, Pct(math.min(it.rate, 9.99)), ns.Money(it.v), it.src or "?"))
      end
    end
  end
  table.insert(out, "")
  local src = ns.AHSources()
  if #src > 0 then
    table.insert(out, TR"|cff9d9d9dAH Preise von: " .. table.concat(src, ", ") .. TR" (Mittelwert, minus 5 Prozent Gebühr), sonst Händler Preis.|r")
  else
    table.insert(out, TR"|cff9d9d9dKein AH Addon gefunden, nur Händler Preise. Unterstützt: TSM, Auctionator, Auctioneer, Aux, OribosExchange.|r")
  end
  table.insert(out, TR"|cff9d9d9dNoch nicht gelernte Mobs: Geld nach Level plus Stoff, Leder und Co. aus der Questie Drop Tabelle.|r")
  table.insert(out, TR"|cff9d9d9dJe mehr du farmst, desto genauer: jeder Kill und jede Beute wird pro Mob gelernt.|r")
  return out
end

function ns.FarmSessionLines()
  local s = ns.farmSess
  if not s then return {} end
  local total, el, gph = ns.FarmMeasured()
  return {
    TR"|cffffd100Läuft gerade|r",
    (TR"Zeit: %d Min, Kills: %d"):format(math.floor(el / 60), s.kills),
    (TR"Geld: %s, Items: %s, zusammen %s"):format(ns.Money(s.copper), ns.Money(s.items), ns.Money(total)),
    gph and (TR"Gemessen: |cff40ff40%s pro Stunde|r (geschätzt %s)"):format(ns.Money(gph), ns.Money(s.est or 0)) or TR"Gemessen: nach einer Minute",
    "",
  }
end
