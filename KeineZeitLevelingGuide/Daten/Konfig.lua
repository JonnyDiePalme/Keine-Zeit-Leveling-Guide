-- Konfig (20.3, Navi Chat): feste Werte an EINEM Ort, die Dateien nur lesen. Nicht im Spiel einstellbar.
-- WEG_FERN_YD: Ziel nicht erreichbar, naechster erreichbarer Punkt hoechstens so weit weg = Ausnahme (Pfeil fuehrt bis dorthin,
-- dann gerade aufs Ziel, Log WEG_NAH). Weiter weg = Fehler der Weg Rechnung (Log WEG_FERN). Start 50, Arrow kappt bei 80.
local _, ns = ...
ns.Konfig = ns.Konfig or {}
ns.Konfig.WEG_FERN_YD = 50
