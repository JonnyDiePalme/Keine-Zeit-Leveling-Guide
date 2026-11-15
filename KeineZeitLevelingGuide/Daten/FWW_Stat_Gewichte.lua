-- Stat Gewichte je Klasse fuer die Ausruestungs Bewertung (P163), K 11.11.
-- Startwerte fuer Leveling (Classic Werte, Forever gleich), Ziel ca 80 Prozent Treffer. Keine Sonderfaelle im Code:
-- Co liest nur diese Tabelle. Einheit: Punkte pro 1 Stat. Waffe: dps = Punkte pro 1 Waffen DPS (nur Haupthand,
-- Nebenhand mit offhand Faktor). hit/crit = pro 1 Prozent. Spaeter kann das Addon die Werte aus eigenen Daten nachziehen.
-- Quelle: allgemeine Classic Leveling Prioritaeten (Krieger Waffe und Staerke, Schurke Waffe und Beweglichkeit,
-- Jaeger Fernwaffe und Beweglichkeit, Caster Intelligenz und Zaubermacht, Heiler Heilung und Willenskraft).
FWW_STAT_GEWICHTE = {
  version = 1,
  WARRIOR = { str = 1.0, agi = 0.6, sta = 0.5, ap = 0.5, crit = 12, hit = 14, armor = 0.02, dps = 14, offhand = 0.5, ranged_dps = 0.5, def = 0.3 },
  ROGUE   = { agi = 1.0, str = 0.55, sta = 0.4, ap = 0.5, crit = 12, hit = 15, armor = 0.01, dps = 13, offhand = 0.6 },
  HUNTER  = { agi = 1.0, int = 0.35, sta = 0.4, ap = 0.45, rap = 0.45, crit = 12, hit = 12, armor = 0.01, ranged_dps = 14, dps = 2, str = 0.05 },
  PALADIN = { str = 1.0, sta = 0.5, int = 0.5, spi = 0.2, agi = 0.4, ap = 0.5, crit = 10, hit = 10, armor = 0.02, dps = 13, sp = 0.4, heal = 0.3 },
  SHAMAN  = { str = 0.8, int = 0.7, sta = 0.5, agi = 0.4, spi = 0.3, ap = 0.4, crit = 9, hit = 9, sp = 0.6, heal = 0.3, armor = 0.01, dps = 11 },
  DRUID   = { str = 0.9, agi = 0.6, int = 0.6, sta = 0.5, spi = 0.4, ap = 0.45, crit = 9, sp = 0.6, heal = 0.4, armor = 0.02, dps = 1 },
  MAGE    = { int = 1.0, sp = 1.2, sta = 0.5, spi = 0.5, spell_crit = 10, spell_hit = 12, armor = 0.005, dps = 0 },
  WARLOCK = { int = 0.8, sp = 1.2, sta = 0.7, spi = 0.5, spell_crit = 8, spell_hit = 12, armor = 0.005, dps = 0 },
  PRIEST  = { int = 0.9, spi = 0.8, sp = 1.1, heal = 0.6, sta = 0.5, spell_crit = 8, spell_hit = 10, armor = 0.005, dps = 0 },
  -- Filter im Fenster Ausruestung (M15): S kann statt Klasse nach einem Stat sortieren
  filter = { staerke = "str", beweglichkeit = "agi", zaubermacht = "sp", heilung = "heal", ausdauer = "sta", intelligenz = "int", willenskraft = "spi" },
}
