-- Zauber fuers Reisetempo und XP Buffs fuer Forever Wegweiser, Werkzeug Stand 60, 2026-10-29 22:21
-- FWW_AUTO_ZAUBER.tempo = { { id, name, art, prozent, dauer, klassen, level, quelle }, ... }
--   art: lauf, reit (Reittier schneller), reittier (ist ein Reittier), schwimm. prozent = mehr Tempo.
--   dauer in Sekunden, -1 = bis man es ausmacht, -2 = unbekannt. klassen = Maske (1 Krieger, 2 Paladin, 4 Jaeger,
--   8 Schurke, 16 Priester, 64 Schamane, 128 Magier, 256 Hexenmeister, 1024 Druide), 0 = alle. level = ab Level.
--   Quelle vmangos112 (1.12 Server Daten). Reittier 60 und 100 Prozent allgemein mit id 0.
-- FWW_AUTO_ZAUBER.xp = { { id, name, prozent, dauer }, ... } aus dem Forever Client (Aura XP Prozent, Sleeping Bag).
FWW_AUTO_ZAUBER = FWW_AUTO_ZAUBER or {}
FWW_AUTO_ZAUBER.tempo = {
  { 5118, "Aspect of the Cheetah", "lauf", 30, -1, 4, 20, "vmangos112" },
  { 13159, "Aspect of the Pack", "lauf", 30, -1, 4, 40, "vmangos112" },
  { 1850, "Dash", "lauf", 50, 15, 1024, 26, "vmangos112" },
  { 9821, "Dash", "lauf", 60, 15, 1024, 46, "vmangos112" },
  { 2645, "Ghost Wolf", "lauf", 40, -1, 64, 20, "vmangos112" },
  { 26022, "Pursuit of Justice", "lauf", 4, -1, 2, 0, "vmangos112" },
  { 26023, "Pursuit of Justice", "lauf", 8, -1, 2, 0, "vmangos112" },
  { 2983, "Sprint", "lauf", 50, 15, 8, 10, "vmangos112" },
  { 8696, "Sprint", "lauf", 60, 15, 8, 34, "vmangos112" },
  { 11305, "Sprint", "lauf", 70, 15, 8, 58, "vmangos112" },
  { 5419, "Travel Form (Passive)", "lauf", 40, -1, 1024, 30, "vmangos112" },
  { 23214, "Summon Charger", "reittier", 100, -1, 2, 60, "vmangos112" },
  { 23161, "Summon Dreadsteed", "reittier", 100, -1, 256, 60, "vmangos112" },
  { 5784, "Summon Felsteed", "reittier", 60, -1, 256, 40, "vmangos112" },
  { 13819, "Summon Warhorse", "reittier", 60, -1, 2, 40, "vmangos112" },
  { 5421, "Aquatic Form (Passive)", "schwimm", 50, -1, 1024, 16, "vmangos112" },
  { 0, "Reittier (Reiten 75)", "reittier", 60, -1, 0, 40, "1.12" },
  { 0, "Episches Reittier (Reiten 150)", "reittier", 100, -1, 0, 60, "1.12" },
}
FWW_AUTO_ZAUBER.xp = {
  { 335924, "Winds of Wisdom", 1, -1 },
  { 429959, "Well-Rested", 1, 7200.0 },
  { 430496, "WoW Variety Show - The Winds of Inspiration!", 1, 300.0 },
  { 436412, "Discoverer's Delight", 1, -1 },
  { 1243969, "Well Fed XP Boost", 1, -1 },
}
