-- 19.4 (Wunsch Sascha: die Karten gehoeren ins Addon, kein eigenes Addon mehr): Gelaende aus der Gelaende Pruefung
-- liegt unveraendert in Karte\Era und Karte\Forever (Kopf.lua und Zonen\Z<uiMap>.lua, wie das Werkzeug sie baut).
-- Die toc laedt beide; die Dateien schreiben in die globalen FWW_AUTO_KARTE_RAW / FWW_AUTO_KARTE_INFO. Hier wird vor
-- jedem Teil eine frische Tabelle hingelegt, nach dem Teil nimmt Laden_Mitte / Laden_Ende den Teil vom eigenen Client
-- nach ns.KARTE_RAW und wirft den anderen weg. Am Ende ist alles Globale wieder wie vorher (ein altes Daten Addon
-- stoert so nicht). Kosten: beide Teile einmal lesen (etwa 0.2 s beim Einloggen), der falsche wird gleich frei.
local ADDON, ns = ...
-- 1.2e (P47): nur Forever, kein Era Teil mehr
ns.KARTE_CLIENT = "forever"
ns.KARTE_SAVE = { raw = FWW_AUTO_KARTE_RAW, tab = FWW_AUTO_KARTE, info = FWW_AUTO_KARTE_INFO, f = FWW_AutoKarte, fr = FWW_AutoKarteFrei,
  taxi = FWW_AUTO_TAXI, aus = FWW_AUTO_AUSLOESER, fh = FWW_AUTO_FRIEDHOF, srv = FWW_AUTO_SERVER, srvi = FWW_AUTO_SERVER_INFO, zb = FWW_AUTO_ZAUBER }
FWW_AUTO_KARTE_RAW, FWW_AUTO_KARTE, FWW_AUTO_KARTE_INFO = {}, {}, nil
-- 19.21: Flugdaten, Ausloeser (Dungeon Eingaenge) und Friedhoefe (Werkzeug Stand 49), je Client in Flug/Ausloeser/Friedhof.lua
FWW_AUTO_TAXI, FWW_AUTO_AUSLOESER, FWW_AUTO_FRIEDHOF = nil, nil, nil
-- 19.31: Server Daten 1.12 (Werkzeug Stand 58, Karte\Server.lua, gleich fuer beide Clients): Quest XP und Geld
FWW_AUTO_SERVER, FWW_AUTO_SERVER_INFO = nil, nil
-- 19.31: Zauber fuers Reisetempo und XP Buffs (Werkzeug Stand 60, Karte\Zauber.lua, gleich fuer beide Clients)
FWW_AUTO_ZAUBER = nil
