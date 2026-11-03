-- Keine Zeit Leveling Guide: Farming (kurz "Keine Zeit Farming"), Zusatz Addon (20.4b, K 19:02, KORR 19:28)
-- Copyright (C) 2026 jonnydiepalme, GPLv3 oder spaeter (LICENSE.txt)
--
-- Ist dieses Addon an, zeigt der Keine Zeit Leveling Guide das Farmen: Seitenleiste Farmen (Berufe, Gold), Farm Kacheln,
-- Mini Fenster Eintraege, Hilfe und Tipps dazu. Fehlt es oder ist es aus, blendet das Hauptaddon das alles ohne
-- Fehlermeldung aus (ns.FarmOn im Hauptaddon fragt C_AddOns.IsAddOnLoaded("<Hauptordner>_Farming")).
-- Gespeicherte Farm Einstellungen bleiben im Hauptaddon (gleiche SavedVariables), beim Ein und Ausschalten geht nichts verloren.
-- Die Farm Logik (Berufe, Gold, Spots) laeuft fuer 20.4 noch im Hauptaddon mit dessen Navi, Pfeil, Wegnetz und Karte;
-- dieses Addon ist der Schalter dafuer. Spaeter koennen die Farm Dateien hierher wandern.
local ADDON = ...
KEINEZEIT_FARMING = { version = "1.0", addon = ADDON }
