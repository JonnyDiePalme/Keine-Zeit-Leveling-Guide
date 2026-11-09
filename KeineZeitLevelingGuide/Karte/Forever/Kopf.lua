-- Gelaende aus den Spieldaten fuer Forever Wegweiser (Forever, Build WOW-70862patch1.60.1_Retail, Werkzeug Stand 170, 2026-11-08 07:25)
-- Aufbau pro Zone: siehe Kopf von Karte_Forever.lua im Werkzeug Ordner Karte
FWW_AUTO_KARTE = FWW_AUTO_KARTE or {}
FWW_AUTO_KARTE_RAW = FWW_AUTO_KARTE_RAW or {}
-- Zone als Tabelle holen (wird beim ersten Mal aus dem Text gebaut), nil wenn es die Zone nicht gibt
function FWW_AutoKarte(ui)
  local z = FWW_AUTO_KARTE[ui]
  if z == nil then
    local raw = FWW_AUTO_KARTE_RAW[ui]
    z = false
    if raw then
      local fn = loadstring("return " .. raw)
      if fn then local ok, t = pcall(fn); if ok and type(t) == "table" then z = t end end
    end
    FWW_AUTO_KARTE[ui] = z
  end
  return z or nil
end
-- Zone wieder freigeben (Text bleibt, Tabelle kann der Speicher wieder wegraeumen)
function FWW_AutoKarteFrei(ui) FWW_AUTO_KARTE[ui] = nil end
FWW_AUTO_KARTE_INFO = { format = 2, client = "forever", build = "WOW-70862patch1.60.1_Retail", stand = "170", erstellt = "2026-11-08" }
