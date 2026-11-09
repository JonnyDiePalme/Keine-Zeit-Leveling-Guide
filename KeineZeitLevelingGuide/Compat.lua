local ADDON, ns = ...
-- 1.1 (S Log 06.11., Client 1.60.1 Build 70790): einige alte Spiel Funktionen (GetSpellInfo, GetItemInfo ...) gibt es im
-- Forever Client nur noch als Huelle, die beim Aufruf mit "attempt to call a nil value" abbricht. Darum ruft das Addon
-- solche Funktionen nur noch ueber ns.Api auf: zuerst die neue Schnittstelle (C_Spell, C_Item, C_Container), dann die alte,
-- jeder Aufruf mit pcall. Fehlt beides oder geht beides schief, kommt nil zurueck (wie bei einem noch unbekannten Item).
-- Rueckgabe immer in der alten Form, damit der restliche Code gleich bleibt.
-- Ausserdem: geschuetzte Werte ("secret values", zb Laufgeschwindigkeit) darf Addon Code weder vergleichen noch rechnen.
-- ns.Api.Num(v) gibt eine normale Zahl oder nil. Und ns.Api.Prot merkt sich die letzte geschuetzte Aktion, damit eine
-- Blizzard Meldung "UNKNOWN()" der richtigen Funktion zugeordnet werden kann.

local A = {}
ns.Api = A

-- 1.3zl (S 14:07 und 14:12, K 14:09 DRINGEND): "Attempt to register unknown event TRADE_SKILL_UPDATE" (Berufe.lua) und
-- "LEARNED_SPELL_IN_TAB" (Group.lua) beim Laden. Der Forever Client kennt nicht jedes Event. Darum registriert das ganze
-- Addon Events nur noch ueber ns.RegEv bzw ns.RegUEv: zuerst C_EventUtils.IsEventValid (falls vorhanden), dann mit pcall.
-- Unbekannte Events werden still ausgelassen und in ns.badEvents gemerkt (Test Log EVENT beim ersten Mal)
ns.badEvents = {}
local function BadEv(ev)
  if ns.badEvents[ev] then return end
  ns.badEvents[ev] = true
  if C_Timer and C_Timer.After then
    C_Timer.After(6, function() if ns.TestLog then ns.TestLog("EVENT", "unbekannt im Client, ausgelassen: " .. tostring(ev)) end end)
  end
end
local function EvValid(ev)
  if type(ev) ~= "string" then return false end
  local U = C_EventUtils
  if U and U.IsEventValid then
    local ok, v = pcall(U.IsEventValid, ev)
    if ok and v == false then return false end
  end
  return true
end
function ns.RegEv(f, ev, ...)
  if not (f and f.RegisterEvent) then return false end
  if not EvValid(ev) then BadEv(ev); return false end
  local ok = pcall(f.RegisterEvent, f, ev, ...)
  if not ok then BadEv(ev) end
  return ok
end
function ns.RegUEv(f, ev, ...)
  if not (f and f.RegisterUnitEvent) then return false end
  if not EvValid(ev) then BadEv(ev); return false end
  local ok = pcall(f.RegisterUnitEvent, f, ev, ...)
  if not ok then BadEv(ev) end
  return ok
end
local G = _G
local pcall, type, select = pcall, type, select

-- geschuetzter Wert? (gibt es erst in neuen Clients)
local function Secret(v)
  local f = G.issecretvalue
  if f and v ~= nil then
    local ok, r = pcall(f, v)
    return ok and r and true or false
  end
  return false
end
A.Secret = Secret
-- normale Zahl oder nil (nie ein geschuetzter Wert)
function A.Num(v)
  if type(v) ~= "number" or Secret(v) then return nil end
  return v
end
-- normaler Wert (Zahl, Text, Wahrheit) oder nil
function A.Plain(v)
  if v == nil or Secret(v) then return nil end
  return v
end

-- 1.1 (P57, K 14:33, Log: Core.lua:3028 "boolean test on local 'afk' (a secret boolean value)"): Spiel Abfragen, die auf
-- Forever geheime Werte liefern koennen (UnitIsAFK, UnitIsDead, UnitExists ...), nur so aufrufen. Geheim oder Fehler: nil
function A.U(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, v, w = pcall(f, ...)
  if not ok then return nil end
  if Secret(v) then v = nil end
  if Secret(w) then w = nil end
  return v, w
end

local function Second(ok, ...) if ok then return ... end end
local function Pick1(f2, x, ok, a, ...)
  if ok and a ~= nil then return a, ... end
  if type(f2) == "function" then return Second(pcall(f2, x)) end
end
local function Chain1(f1, f2, x)
  if type(f1) == "function" then return Pick1(f2, x, pcall(f1, x)) end
  if type(f2) == "function" then return Second(pcall(f2, x)) end
end
local function Pick2(f2, x, y, ok, a, ...)
  if ok and a ~= nil then return a, ... end
  if type(f2) == "function" then return Second(pcall(f2, x, y)) end
end
local function Chain2(f1, f2, x, y)
  if type(f1) == "function" then return Pick2(f2, x, y, pcall(f1, x, y)) end
  if type(f2) == "function" then return Second(pcall(f2, x, y)) end
end
local function CS(n) local t = G.C_Spell; return t and t[n] end
local function CI(n) local t = G.C_Item; return t and t[n] end
local function CC(n) local t = G.C_Container; return t and t[n] end

------------------------------------------------------------
-- Zauber
------------------------------------------------------------
-- name, rank, icon, castTime, minRange, maxRange, spellID
function A.GetSpellInfo(id)
  if id == nil then return nil end
  local f = CS("GetSpellInfo")
  if f then
    local ok, t = pcall(f, id)
    if ok and type(t) == "table" and t.name then
      local rank
      local fs = CS("GetSpellSubtext") or G.GetSpellSubtext
      if fs then local ok2, r = pcall(fs, id); if ok2 and type(r) == "string" and r ~= "" then rank = r end end
      return t.name, rank, t.iconID, t.castTime, t.minRange, t.maxRange, t.spellID or id
    end
  end
  return Second(pcall(G.GetSpellInfo, id))
end
function A.GetSpellTexture(id)
  if id == nil then return nil end
  return Chain1(CS("GetSpellTexture"), G.GetSpellTexture, id)
end
-- start, duration, enabled (geschuetzte Werte werden 0: gilt als bereit)
function A.GetSpellCooldown(id)
  if id == nil then return 0, 0, 0 end
  local f = CS("GetSpellCooldown")
  local st, dur, en
  if f then
    local ok, t = pcall(f, id)
    if ok and type(t) == "table" then st, dur, en = t.startTime, t.duration, t.isEnabled and 1 or 0 end
  end
  if st == nil and type(G.GetSpellCooldown) == "function" then
    local ok, a, b, c = pcall(G.GetSpellCooldown, id)
    if ok then st, dur, en = a, b, c end
  end
  return A.Num(st) or 0, A.Num(dur) or 0, en
end

------------------------------------------------------------
-- Items
------------------------------------------------------------
-- alte Form: name, link, quality, level, minLevel, type, subType, stackCount, equipLoc, texture, sellPrice, classID, subclassID ...
function A.GetItemInfo(item)
  if item == nil then return nil end
  return Chain1(CI("GetItemInfo"), G.GetItemInfo, item)
end
function A.GetItemStats(link)
  if link == nil then return nil end
  return Chain1(CI("GetItemStats"), G.GetItemStats, link)
end
function A.GetItemIcon(id)
  if id == nil then return nil end
  return Chain1(CI("GetItemIconByID"), G.GetItemIcon, id)
end
function A.GetItemSpell(item)
  if item == nil then return nil end
  return Chain1(CI("GetItemSpell"), G.GetItemSpell, item)
end
-- Anzahl (immer eine Zahl)
function A.GetItemCount(item, a, b, c)
  if item == nil then return 0 end
  local f = CI("GetItemCount")
  if f then local ok, n = pcall(f, item, a, b, c); if ok and type(n) == "number" then return n end end
  f = G.GetItemCount
  if type(f) == "function" then local ok, n = pcall(f, item, a, b, c); if ok and type(n) == "number" then return n end end
  return 0
end
-- start, duration, enable
function A.GetItemCooldown(id)
  if id == nil then return 0, 0, 0 end
  local st, dur, en
  local f = CC("GetItemCooldown")
  if f then local ok, a, b, c = pcall(f, id); if ok then st, dur, en = a, b, c end end
  if st == nil and type(G.GetItemCooldown) == "function" then
    local ok, a, b, c = pcall(G.GetItemCooldown, id)
    if ok then st, dur, en = a, b, c end
  end
  return A.Num(st) or 0, A.Num(dur) or 0, en
end

------------------------------------------------------------
-- Taschen
------------------------------------------------------------
-- alte Form: texture, count, locked, quality, readable, lootable, link, filtered, noValue, itemID, isBound
function A.GetContainerItemInfo(bag, slot)
  local f = CC("GetContainerItemInfo")
  if f then
    local ok, t = pcall(f, bag, slot)
    if ok and type(t) == "table" then
      return t.iconFileID, t.stackCount, t.isLocked, t.quality, t.isReadable, t.hasLoot, t.hyperlink, t.isFiltered,
        t.hasNoValue, t.itemID, t.isBound
    end
    if ok then return nil end
  end
  return Second(pcall(G.GetContainerItemInfo, bag, slot))
end
function A.GetContainerItemLink(bag, slot)
  return Chain2(CC("GetContainerItemLink"), G.GetContainerItemLink, bag, slot)
end

------------------------------------------------------------
-- Einheiten: nur normale Zahlen (geschuetzte Werte werden nil)
------------------------------------------------------------
function A.GetUnitSpeed(unit)
  local f = G.GetUnitSpeed
  if type(f) ~= "function" then return nil end
  local ok, cur, run, fly, swim = pcall(f, unit or "player")
  if not ok then return nil end
  return A.Num(cur), A.Num(run), A.Num(fly), A.Num(swim)
end
local function UnitNum(fname)
  return function(unit, ...)
    local f = G[fname]
    if type(f) ~= "function" then return nil end
    local ok, v = pcall(f, unit, ...)
    if not ok then return nil end
    return A.Num(v)
  end
end
A.UnitHealth = UnitNum("UnitHealth")
A.UnitHealthMax = UnitNum("UnitHealthMax")
A.UnitPower = UnitNum("UnitPower")
A.UnitPowerMax = UnitNum("UnitPowerMax")

------------------------------------------------------------
-- Geschuetzte Aktionen: letzte merken (fuer "UNKNOWN()" Meldungen von Blizzard)
------------------------------------------------------------
-- Blizzard meldet manche verbotenen Aufrufe nur als "UNKNOWN()". Jede Aktion, die Blizzard sperren kann, laeuft darum
-- ueber Prot(name, f, ...). Kommt die Meldung im selben Moment, weiss Deps.OnBlocked, welche Funktion es war, und kann
-- die Einstellung dahinter abschalten (Tabelle NAMES in Deps.lua). Ist die Funktion schon als gesperrt bekannt
-- (ns.db.forbidden), wird sie gar nicht mehr aufgerufen.
local PROT_WINDOW_S = 0.05  -- Meldung kommt im selben Bild wie die Aktion (GetTime ist pro Bild gleich)
-- v11d (Pr Code Pruefung P2): gesperrt erst ab PROT_BLOCK_HITS echten Meldungen mit Namen (Vermutungen zaehlen getrennt in
-- db.forbiddenGuess und sperren nie), und bei einer neuen Addon Version faengt die Zaehlung neu an
local PROT_BLOCK_HITS = 3
local lastProt, lastProtAt = nil, -1
local verNow
local function VerReset(db)
  if not verNow then
    local f = (G.C_AddOns and G.C_AddOns.GetAddOnMetadata) or G.GetAddOnMetadata
    local ok, v = pcall(f, ADDON, "Version")
    verNow = ok and v or "?"
  end
  if db.forbiddenVer ~= verNow then db.forbidden, db.forbiddenGuess, db.forbiddenVer = {}, {}, verNow end
end
A.ForbiddenVerReset = VerReset
function A.Prot(name, f, ...)
  if type(f) ~= "function" then return false end
  local db = ns.db
  if db then VerReset(db) end
  if db and db.forbidden and (tonumber(db.forbidden[name]) or 0) >= PROT_BLOCK_HITS then return false end
  lastProt, lastProtAt = name, (G.GetTime and G.GetTime()) or 0
  return pcall(f, ...)
end
-- nur merken (fuer Methoden an sicheren Knoepfen, die direkt aufgerufen werden)
function A.Mark(name)
  lastProt, lastProtAt = name, (G.GetTime and G.GetTime()) or 0
end
-- Name der letzten geschuetzten Aktion, wenn sie gerade eben war
function A.LastProt()
  local now = (G.GetTime and G.GetTime()) or 0
  if lastProt and now - lastProtAt <= PROT_WINDOW_S then return lastProt end
end
