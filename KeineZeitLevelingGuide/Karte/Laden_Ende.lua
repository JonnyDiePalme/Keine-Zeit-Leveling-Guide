-- 19.4: nach dem Forever Teil (siehe Laden_Vor.lua). Alles Globale wieder wie vor dem Laden.
local ADDON, ns = ...
if ns.KARTE_CLIENT == "forever" then ns.KARTE_RAW, ns.KARTE_INFO = FWW_AUTO_KARTE_RAW, FWW_AUTO_KARTE_INFO end
-- 19.21: Flugdaten, Ausloeser und Friedhoefe vom eigenen Client nach ns (der andere Client wird frei)
do
  local cl = ns.KARTE_CLIENT or "forever"
  ns.TAXI = FWW_AUTO_TAXI and FWW_AUTO_TAXI[cl] or nil
  ns.AUSLOESER = FWW_AUTO_AUSLOESER and FWW_AUTO_AUSLOESER[cl] or nil
  ns.FRIEDHOF = FWW_AUTO_FRIEDHOF and FWW_AUTO_FRIEDHOF[cl] or nil
  -- 1.3zf (Ka Stand 170, K 07:48): Ersatz Punkte fuer Orte ohne Weg (Wasser: Ufer, ex = -1: unerreichbar)
  ns.ERSATZ = type(FWW_AUTO_ERSATZ) == "table" and FWW_AUTO_ERSATZ[cl] or nil
  -- 19.31: Daten in einem neueren Format, als der Code kennt: auch Flug, Ausloeser und Friedhof nicht nehmen
  local inf, K = ns.KARTE_INFO, ns.Karte
  local fm = type(inf) == "table" and tonumber(inf.format)
  if fm and K and K.FORMAT_MAX and fm > K.FORMAT_MAX then ns.TAXI, ns.AUSLOESER, ns.FRIEDHOF, ns.ERSATZ = nil, nil, nil, nil end
end
-- 19.31: Server Daten (Quest XP und Geld), nur wenn das Format bekannt ist
do
  local si = FWW_AUTO_SERVER_INFO
  local fm = type(si) == "table" and tonumber(si.format) or 1
  if type(FWW_AUTO_SERVER) == "table" and fm <= 1 then ns.SERVER, ns.SERVER_INFO = FWW_AUTO_SERVER, si end
  if type(FWW_AUTO_ZAUBER) == "table" then ns.ZAUBER = FWW_AUTO_ZAUBER end
end
-- 20.4a6 (Ge Stadt.lua Stand 164): Tore und Ziele innen kommen als Liste ohne Namen ({id, x, y, art, breite_yd, sicher},
-- innen {x, y, art, grund}). Na Path.lua liest die Namen (t.x, p.x). Hier einmal beide Formen bereitstellen, dann passt
-- jede Fassung (Ge darf auch mit Namen liefern, dann bleibt alles wie es ist)
do
  local A = FWW_AUTO_STADT
  local f = type(A) == "table" and A.forever
  local list = type(f) == "table" and f.staedte
  if type(list) == "table" then
    local TOR = { "id", "x", "y", "art", "breite_yd", "sicher" }
    local INNEN = { "x", "y", "art", "grund" }
    local function Name(t, keys)
      if type(t) ~= "table" or t[keys[1]] ~= nil then return end
      for i, k in ipairs(keys) do t[k] = t[i] end
    end
    for _, st in pairs(list) do
      if type(st) == "table" then
        for _, t in ipairs(type(st.tore) == "table" and st.tore or {}) do Name(t, TOR) end
        for _, p in ipairs(type(st.innen) == "table" and st.innen or {}) do Name(p, INNEN) end
      end
    end
  end
end
local S = ns.KARTE_SAVE or {}
ns.KARTE_SAVE = nil
FWW_AUTO_KARTE_RAW, FWW_AUTO_KARTE, FWW_AUTO_KARTE_INFO = S.raw, S.tab, S.info
FWW_AutoKarte, FWW_AutoKarteFrei = S.f, S.fr
FWW_AUTO_TAXI, FWW_AUTO_AUSLOESER, FWW_AUTO_FRIEDHOF = S.taxi, S.aus, S.fh
FWW_AUTO_ERSATZ = S.er
FWW_AUTO_SERVER, FWW_AUTO_SERVER_INFO = S.srv, S.srvi
FWW_AUTO_ZAUBER = S.zb
-- 19.31 (Editor Addon): FWW_EDITOR_API und die alten Namen FWW_AutoKarte, FWW_AutoKarteFrei, FWW_AUTO_KARTE_INFO zum Lesen (siehe Karte.lua)
if ns.Karte and ns.Karte.Schnittstelle then pcall(ns.Karte.Schnittstelle) end
