local ADDON, ns = ...
-- 20.3o (Da Pruefung Nr 2, Release Ordner KeineZeitLevelingGuide): Pfad zu den eigenen Bildern aus dem echten Ordner Namen
ns.ADDON = ADDON
ns.APATH = "Interface\\AddOns\\" .. tostring(ADDON or "ForeverWegweiser") .. "\\"

-- Sprache: automatisch die Sprache vom Spiel. Deutscher Client: alles wie geschrieben (Deutsch).
-- Jeder andere Client: Englisch. Die Texte im Code sind Deutsch und werden mit TR"..." uebersetzt.
local loc = (GetLocale and GetLocale()) or "deDE"
ns.LOCALE = loc
ns.EN = loc ~= "deDE"
ns.EN_T = {}
local EN_T = ns.EN_T
if ns.EN then
  ns.TR = function(s) return (s and EN_T[s]) or s end
else
  ns.TR = function(s) return s end
end
-- Text auf hoechstens n Bytes kuerzen, ohne ein Zeichen mit Umlaut (2 oder mehr Bytes) zu zerschneiden
function ns.U8Sub(s, n)
  if type(s) ~= "string" or #s <= n then return s end
  s = s:sub(1, n)
  -- angefangenes Zeichen am Ende weg: Startbyte ohne alle Folgebytes
  local tail = s:match("[\192-\255][\128-\191]*$")
  if tail then
    local b = tail:byte(1)
    local need = b >= 240 and 4 or b >= 224 and 3 or 2
    if #tail < need then s = s:sub(1, #s - #tail) end
  end
  return s
end
-- Tabellen, deren Schluessel Anzeige Namen sind: uebersetzte Schluessel dazu (nur auf Englisch noetig)
function ns.TRKeys(t)
  if ns.EN and type(t) == "table" then
    local add = {}
    for k, v in pairs(t) do if type(k) == "string" then local e = EN_T[k]; if e and t[e] == nil then add[e] = v end end end
    for k, v in pairs(add) do t[k] = v end
  end
  return t
end

-- 20.2b (P12, Sascha 13:26: Schriftgroesse fuer Leute, die schlecht sehen): eigene Schrift Objekte je Blizzard Vorlage
-- (FWW_GameFont...), alle Texte des Addons nutzen sie. Ein Faktor (Einstellungen, 80 bis 150 %) aendert alle auf einmal,
-- die Texte folgen von selbst. Die Kopie wird beim Betreten der Welt neu von der Vorlage genommen (ElvUI aendert Schriften)
local fontObjs = {}
function ns.FontScale() return math.max(0.8, math.min(1.5, tonumber(ns.db and ns.db.fontScale) or 1)) end
local function ApplyOne(o, k)
  pcall(o.f.CopyFontObject, o.f, o.src)
  local okF, font, size, flags = pcall(o.src.GetFont, o.src)
  if okF and font and size then pcall(o.f.SetFont, o.f, font, size * k, flags or "") end
end
-- 20.3k (S Test 20.3g Punkt 10, Mini Fenster bei Schrift 150 %): das Mini Fenster (und seine Hinweise, Gruppen Ansicht)
-- wird als Ganzes mit dem Schrift Faktor skaliert. Seine Texte nehmen darum ungeskalierte Kopien (FWWH_...), sonst waeren
-- sie doppelt gross und die Zeilen ueberlappen. ns.fontPlain ist nur waehrend dem Bauen dieser Fenster an
local plainObjs = {}
local function PlainName(base)
  local o = plainObjs[base]
  if not o then
    local src = _G[base]
    if not (src and CreateFont and src.GetFont) then return base end
    o = { f = CreateFont("FWWH_" .. base), src = src }
    plainObjs[base] = o
    ApplyOne(o, 1)
  end
  return "FWWH_" .. base
end
function ns.FontName(base)
  if ns.fontPlain then return PlainName(base) end
  local o = fontObjs[base]
  if not o then
    local src = _G[base]
    if not (src and CreateFont and src.GetFont) then return base end
    local f = CreateFont("FWW_" .. base)
    o = { f = f, src = src }
    fontObjs[base] = o
    ApplyOne(o, ns.FontScale())
  end
  return "FWW_" .. base
end
function ns.ApplyFontScale()
  local k = ns.FontScale()
  for _, o in pairs(fontObjs) do ApplyOne(o, k) end
  for _, o in pairs(plainObjs) do ApplyOne(o, 1) end
  if ns.HudRescale then pcall(ns.HudRescale) end
end
-- ein Fenster mit ungeskalierten Schriften bauen (siehe oben)
function ns.WithPlainFont(fn, ...)
  local was = ns.fontPlain
  ns.fontPlain = true
  local r = { pcall(fn, ...) }
  ns.fontPlain = was
  if not r[1] then error(r[2], 0) end
  return unpack(r, 2)
end
function ns.SetFontScale(v)
  if not ns.db then return end
  ns.db.fontScale = math.max(0.8, math.min(1.5, math.floor((tonumber(v) or 1) * 20 + 0.5) / 20))
  ns.ApplyFontScale()
  if ns.RefreshBig then pcall(ns.RefreshBig) end
  if ns.RefreshHud then pcall(ns.RefreshHud) end
end
do
  local ff = CreateFrame("Frame")
  ff:RegisterEvent("PLAYER_ENTERING_WORLD")
  ff:SetScript("OnEvent", function() ns.ApplyFontScale() end)
end
