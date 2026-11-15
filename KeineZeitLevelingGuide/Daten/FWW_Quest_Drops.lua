-- FWW_Quest_Drops.lua (Pr 13.11. 03:40, M38, Co FRA 03:15): Drop Raten aus cMaNGOS classic-db fuer Ziel Items von Quests in Dungeon
-- Gebieten (ZoneOrSort = Dungeon), nur Gegner mit Spawns draussen (Karte 0/1). Format { [Item] = { [NPC] = Promille } }, Questdrop Werte
-- (negativ in cMaNGOS) als Betrag. Ergaenzt nur Fehlendes (Farm.lua). Forever kann abweichen. Nur Quest Gegenstaende (Klasse 12).
_G.FWW_QDROP_ZUSATZ = _G.FWW_QDROP_ZUSATZ or {}
local Z = _G.FWW_QDROP_ZUSATZ
Z[915] = Z[915] or { [594] = 800, [619] = 800, [824] = 800, [1727] = 800 }  -- Red Silk Bandana | Quest 214
Z[4635] = Z[4635] or { [2932] = 1000 }  -- Hammertoe\'s Amulet | Quest 722
Z[5334] = Z[5334] or { [3655] = 1000 }  -- 99-Year-Old Port | Quest 959
Z[5538] = Z[5538] or { [3984] = 1000 }  -- Vorrel\'s Wedding Ring | Quest 1051
Z[5805] = Z[5805] or { [4280] = 800, [4281] = 800, [4282] = 800, [4283] = 800 }  -- Heart of Zeal | Quest 1113
Z[5952] = Z[5952] or { [4788] = 800, [4789] = 800, [4802] = 800, [4803] = 800 }  -- Corrupted Brain Stem | Quest 1275
Z[6443] = Z[6443] or { [3630] = 800, [3631] = 800, [3632] = 800, [3633] = 800, [3634] = 800, [3641] = 800 }  -- Deviate Hide | Quest 1486
Z[7666] = Z[7666] or { [4844] = 80, [4845] = 80, [4846] = 80, [4851] = 80, [4856] = 80 }  -- Shattered Necklace | Quest 2198,2283
Z[8009] = Z[8009] or { [4844] = 400, [4845] = 400, [4846] = 400 }  -- Dentrium Power Stone | Quest 2418
Z[8052] = Z[8052] or { [4844] = 550, [4845] = 550, [4846] = 550 }  -- An\'Alleum Power Stone | Quest 2418
Z[9277] = Z[9277] or { [6231] = 1000 }  -- Techbot\'s Memory Core | Quest 2922
Z[9308] = Z[9308] or { [6208] = 250, [6209] = 250, [6210] = 250, [6213] = 250, [6391] = 250 }  -- Grime-Encrusted Object | Quest 2951,2953,4601,4602,4603,4604
Z[9309] = Z[9309] or { [6208] = 800, [6213] = 800, [6231] = 1000 }  -- Robo-mechanical Guts | Quest 2928
Z[11129] = Z[11129] or { [8281] = 1000, [9026] = 800 }  -- Essence of the Elements | Quest 7201
Z[11446] = Z[11446] or { [8917] = 250, [8924] = 250, [9026] = 250 }  -- A Crumpled Up Note | Quest 4264
Z[12219] = Z[12219] or { [9043] = 50, [9044] = 50, [9046] = 50 }  -- Unadorned Seal of Ascension | Quest 4742
Z[12562] = Z[12562] or { [335] = 1000 }  -- Important Blackrock Documents | Quest 4903
Z[17009] = Z[17009] or { [12865] = 1000 }  -- Ambassador Malcin\'s Head | Quest 6521
Z[17684] = Z[17684] or { [11688] = 800, [13718] = 800 }  -- Theradric Crystal Carving | Quest 7028
Z[17756] = Z[17756] or { [11777] = 800, [11778] = 800 }  -- Shadowshard Fragment | Quest 7068,7070
Z[21982] = Z[21982] or { [11440] = 100, [11442] = 100, [11443] = 100 }  -- Ogre Warbeads | Quest 8949
