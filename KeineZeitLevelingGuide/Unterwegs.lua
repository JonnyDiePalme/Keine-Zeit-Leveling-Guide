local ADDON, ns = ...
local TR = ns.TR

-- 1.3.1a (P119, S 18:28 "kann das navi auch merken wenn man auf dem flug ist? oder allgemein die berechnungen?"):
-- eine Stelle fuer "unterwegs" (Flug, Schiff oder Zeppelin, Tiefenbahn, Ladebildschirm). Solange gilt:
--   kein HAENGT Zaehler (DebugLog), keine LIVE Ausloeser (Arrow), kein "vom Weg abgekommen" (Navi), kein automatisches
--   Neu rechnen (AutoOpt, PlanSectionLive, Quest ausserhalb der Route). Von Hand (Klick Neu rechnen) geht weiter.
--   Was verschoben wurde, holt ns.UwLater nach der Ankunft nach (UW.LATER_S).
-- Kurz nach dem Start (UW.PRE_S) und beim Flug nochmal kurz vor der Landung (UW.PRE_AGAIN_S) wird der Weg ab dem
-- Landepunkt vorgerechnet (Stadt Netz, Zonen Graph, Weg Cache), damit bei der Ankunft Schritt und Pfeil gleich stehen.
-- Mini Fenster: "Flug nach X, noch m:ss" und der Schritt nach der Landung (ns.UwHud). Log UNTERWEGS Start und Ende.
ns.UW = {
  TICK_S = 1,         -- so oft pruefen
  END_CALM_S = 2,     -- so lange nicht mehr unterwegs = angekommen (Schiff Erkennung flackert am Steg)
  LOAD_AFTER_S = 3,   -- nach einem Ladebildschirm noch so lange als unterwegs zaehlen (Position kommt erst)
  PRE_S = 4,          -- so lange nach dem Start den Weg ab dem Landepunkt vorrechnen
  PRE_AGAIN_S = 8,    -- Flug: so viele Sekunden vor der Landung nochmal (der Weg Cache gilt nur 20 s)
  LATER_S = 2,        -- so lange nach der Ankunft das Verschobene nachholen
  HAND_S = 1,         -- ein Klick gilt so lange als "von Hand"
  NAME_MAX = 30,      -- Mini Fenster: Text nach der Landung hoechstens so lang
  -- 1.3zs (Pr 20:17, Quest 604): diese Anlaesse rechnen sofort, auch kurz nach der Ankunft (der Ort ist schon das Ziel,
  -- "Gegner am Ziel zu hoch" muss vor dem Annehmen neu rechnen, sonst nimmt man die Quest am Steg noch an)
  NO_HOLD = { gegner = true, level = true },
}
local UW = ns.UW
local st = { on = nil, kinds = {}, t0 = 0, offAt = nil, paused = {}, later = {}, laterOrder = {}, pre = nil, preAgain = nil,
  loading = false, loadEnd = -1e9, handAt = -1e9 }

local function Now() return GetTime and GetTime() or 0 end
local function Log(txt) if ns.TestLog then ns.TestLog("UNTERWEGS", txt) end end

-- was gerade los ist: "laden", "flug", "tiefenbahn", "schiff" oder nil
function ns.Unterwegs()
  if st.loading or Now() - st.loadEnd < UW.LOAD_AFTER_S then return "laden" end
  if ns.InFlight and ns.InFlight() then return "flug" end
  if UnitOnTaxi and ns.Api and ns.Api.U(UnitOnTaxi, "player") then return "flug" end   -- 1.3zzc: auch ohne ns.InFlight
  if ns.InTram and ns.InTram() then return "tiefenbahn" end
  -- 1.3zs (Pr 20:17, Quest 604 rot seit 1.3zq): Schiff nur, wenn die Route oder das Navi gerade eine Fahrt hat. Sonst schlug
  -- die Schnell Erkennung auch beim Laufen an, und Rechnen und Pruefungen blieben liegen
  if ns.WalkOnBoat and ns.WalkOnBoat() and (not ns.WaitsForRide or ns.WaitsForRide()) then return "schiff" end
  return nil
end

-- Gate fuer alle Stellen: true = unterwegs (bis zur Ankunft, mit UW.END_CALM_S), dann zaehlt "what" als pausiert
function ns.UwHold(what)
  if not st.on then return false end
  if what then st.paused[what] = (st.paused[what] or 0) + 1 end
  return true
end
-- nach der Ankunft nachholen (je key nur der letzte Wunsch)
function ns.UwLater(key, fn)
  if not st.later[key] then table.insert(st.laterOrder, key) end
  st.later[key] = fn
end
function ns.UwHand() st.handAt = Now() end
function ns.UwIsHand() return Now() - st.handAt < UW.HAND_S end

local function Kurz(t, n)
  t = tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  t = t:match("^[^\n]*") or t
  local c, out = 0, {}
  for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    c = c + 1
    if c > n then return table.concat(out) .. "..." end
    out[#out + 1] = ch
  end
  return t
end

local function FlightDest()
  local to = ns.FlightTo and ns.FlightTo()
  return to and ns.FlightMasterById and ns.FlightMasterById(to) or nil
end

-- Weg ab dem Landepunkt vorrechnen (nur Caches fuellen, nichts aendern)
local function Pre(why)
  local fm, fx, fy, tm, tx, ty, src
  local nv = ns.navi
  local lg = nv and not nv.hidden and nv.legs and nv.legs[nv.cur]
  if lg and lg.kind ~= "walk" and lg.to then
    local nx = nv.legs[nv.cur + 1]
    if nx and nx.to then fm, fx, fy, tm, tx, ty, src = lg.to.map, lg.to.x, lg.to.y, nx.to.map, nx.to.x, nx.to.y, "navi" end
  end
  if not fm then
    local e = FlightDest()
    if e and ns.ArrowTargetRaw then
      local ok, m, _, _, ax, ay = pcall(ns.ArrowTargetRaw)
      if ok and m and ax and ay then fm, fx, fy, tm, tx, ty, src = e.map, e.x, e.y, m, ax, ay, "route" end
    end
  end
  if not (fm and fx and fy and tm and tx and ty) then Log(("vorrechnen (%s): kein Landepunkt bekannt"):format(why)); return end
  local t0 = debugprofilestop and debugprofilestop() or 0
  local ok, err = pcall(function()
    if fm == tm then
      if ns.WalkNext then ns.WalkNext(fm, fx, fy, tx, ty) end
    elseif ns.XZoneNext then
      ns.XZoneNext(fm, fx, fy, tm, tx, ty)
    end
  end)
  local ms = (debugprofilestop and debugprofilestop() or 0) - t0
  Log(("vorrechnen (%s, %s): ab Karte %s %.3f,%.3f nach %s, %d ms%s"):format(why, src, tostring(fm), fx, fy, tostring(tm),
    math.floor(ms), ok and "" or (", Fehler " .. tostring(err))))
end

local function Start(k)
  st.on, st.kinds, st.t0, st.offAt, st.paused, st.pre, st.preAgain = k, { [k] = true }, Now(), nil, {}, nil, nil
  local e = k == "flug" and FlightDest() or nil
  Log(("Start %s%s"):format(k, e and (" nach " .. tostring(e.name)) or ""))
end

local function End()
  local kinds = {}
  for k in pairs(st.kinds) do kinds[#kinds + 1] = k end
  table.sort(kinds)
  local p = {}
  for w, n in pairs(st.paused) do p[#p + 1] = ("%s %d"):format(w, n) end
  table.sort(p)
  local later = {}
  for _, key in ipairs(st.laterOrder) do later[#later + 1] = key end
  Log(("Ende %s nach %s, pausiert: %s%s"):format(table.concat(kinds, "+"), ns.Clock and ns.Clock(Now() - st.t0) or "?",
    #p > 0 and table.concat(p, ", ") or "nichts", #later > 0 and (", nachholen: " .. table.concat(later, ", ")) or ""))
  st.on = nil
  local fns, order = st.later, st.laterOrder
  st.later, st.laterOrder = {}, {}
  if #order == 0 then return end
  C_Timer.After(UW.LATER_S, function()
    for _, key in ipairs(order) do
      if st.on then ns.UwLater(key, fns[key])   -- schon wieder unterwegs (Umsteigen): weiter warten
      else
        local ok, err = pcall(fns[key])
        if not ok then Log(("nachholen %s: Fehler %s"):format(key, tostring(err))) end
      end
    end
  end)
end

local function Tick()
  local k = ns.Unterwegs()
  local now = Now()
  if k then
    st.offAt = nil
    if not st.on then Start(k) else st.kinds[k] = true end
    if not st.pre and now - st.t0 >= UW.PRE_S and k ~= "laden" then st.pre = true; Pre("Start") end
    if k == "flug" and not st.preAgain and ns.FlightNow then
      local ok, left = pcall(ns.FlightNow)
      if ok and left and left <= UW.PRE_AGAIN_S then st.preAgain = true; Pre("vor Landung") end
    end
  elseif st.on then
    st.offAt = st.offAt or now
    if now - st.offAt >= UW.END_CALM_S then End() end
  end
end

do
  local f = CreateFrame("Frame")
  ns.RegEv(f, "LOADING_SCREEN_ENABLED")
  ns.RegEv(f, "LOADING_SCREEN_DISABLED")
  f:SetScript("OnEvent", function(_, ev)
    if ev == "LOADING_SCREEN_ENABLED" then st.loading = true
    else st.loading = false; st.loadEnd = Now() end
  end)
  local acc = 0
  f:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < UW.TICK_S then return end
    acc = 0
    local ok, err = pcall(Tick)
    if not ok then Log("Fehler " .. tostring(err)) end
  end)
end

-- Mini Fenster: im Flug "Flug nach X, noch m:ss", danach der Schritt nach der Landung. Navi Fahrt: Text der Fahrt
function ns.UwHud(i)
  if not (st.on and i) then return i end
  local nv = ns.navi
  local lg = nv and not nv.hidden and nv.legs and nv.legs[nv.cur]
  local line, after
  if st.on == "flug" or (ns.InFlight and ns.InFlight()) then
    local e = FlightDest()
    local name = (e and e.name) or (lg and lg.kind == "fly" and lg.to and lg.to.name) or nil
    local left
    if ns.FlightNow then local ok, l = pcall(ns.FlightNow); if ok then left = l end end
    if name and left then line = (TR"Flug nach %s, noch %s"):format(name, ns.Clock(left))
    elseif name then line = (TR"Flug nach %s"):format(name)
    elseif left then line = (TR"Im Flug, noch %s"):format(ns.Clock(left)) end
  elseif lg and lg.kind == "ride" and lg.text then
    line = Kurz(lg.text, UW.NAME_MAX * 2)
  end
  if not line then return i end
  -- Schritt nach der Landung: Navi naechster Abschnitt, Route der naechste Schritt, wenn der jetzige die Reise ist
  if i.navi and nv then
    local nx = nv.legs[nv.cur + 1]
    if nx and nx.text then after = Kurz(nx.text, UW.NAME_MAX) end
  else
    local o = ns.db and ns.db.opt
    local s = o and o.steps and o.steps[o.idx or 1]
    local ca = ns.OptCurrentAct and ns.OptCurrentAct()
    if s and ca and ca.k == "R" then
      local nx = o.steps[(o.idx or 1) + 1]
      if nx and ns.OptStepText then
        local ok, t = pcall(ns.OptStepText, nx)
        if ok and t then after = Kurz(t, UW.NAME_MAX) end
      end
    elseif i.name then
      after = Kurz(i.name, UW.NAME_MAX)
    end
  end
  i.objs = i.objs or {}
  if after then table.insert(i.objs, 1, "|cffbbbbbb" .. (TR"danach: %s"):format(after) .. "|r") end
  table.insert(i.objs, 1, "|cff66ccff" .. line .. "|r")
  i.kind, i.col = TR"Reise", { 0.4, 0.8, 1 }
  return i
end
