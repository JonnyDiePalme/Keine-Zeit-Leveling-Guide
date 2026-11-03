local ADDON, ns = ...
local TR = ns.TR

-- Hilfe (Seite "Hilfe" im grossen Fenster): links die Themen, rechts der Text.
-- Jede Zeile ist ein Absatz, die Seite bricht selbst um.

local H = "|cffffd100"   -- Ueberschrift
local K = "|cff7fd1b9"   -- Knopf / Begriff (wird auf die Farbe vom Look gesetzt)
local G = "|cff9d9d9d"   -- grau

local function k(t) return K .. t .. "|r" end
-- Knopf mit seinem Symbol davor (dieselben Symbole wie im Mini Fenster, passend zum Look), ohne Symbol nur der Name
local function ki(t)
  local ic = ns.T and ns.T.HudIcon and ns.T.HudIcon(t, 16)
  return (ic and (ic .. " ") or "") .. k(t)
end

local CATS = {}
local function Cat(key, title, lines) CATS[#CATS + 1] = { key = key, title = title, lines = lines } end

Cat("start", TR"Erste Schritte", function()
  return {
    H .. TR"So geht es los|r",
    TR"1. " .. k(TR"Questie") .. TR" und " .. k(TR"QuestieDB") .. TR" müssen an sein. Fehlt etwas, sagt dir Keine Zeit Leveling Guide beim Einloggen Bescheid.",
    TR"2. Beim ersten Start kommt die " .. k(TR"Einrichtung") .. TR": Tempo, allein oder Gruppe, Modus und Grösse vom Mini Fenster. Nochmal machen: oben rechts " .. k(TR"Einrichtung nochmal") .. TR" oder " .. k(TR"/klg einrichten") .. ".",
    TR"3. Die Route rechnet sich von selbst, sobald Questie bereit ist. Sie geht bis Level 60, als " .. k(TR"Route mit Abschnitten") .. TR" von ein paar Leveln.",
    TR"4. Dann einfach dem " .. k(TR"Pfeil") .. TR" folgen. Das " .. k(TR"Mini Fenster") .. TR" sagt dir, was zu tun ist.",
    TR"5. " .. k(TR"Rundgang starten") .. TR" auf der Übersicht zeigt alle Seiten Schritt für Schritt und merkt sich, wo du aufgehört hast. Das " .. k("?") .. TR" oben rechts im grossen Fenster erklärt nur die Seite, die gerade offen ist.",
    "",
    H .. TR"Wo du was findest|r",
    TR"Das grosse Fenster öffnest du mit " .. k(TR"/klg") .. TR", mit dem Reiter im Charakterfenster (Taste C) oder im Menü vom Mini Fenster mit " .. k(TR"Grosses Fenster") .. ".",
    TR"Links ist die Seitenleiste: " .. k(TR"Übersicht") .. ", " .. k(TR"Mein Weg") .. ", " .. k(TR"Statistik") .. ", " .. k(TR"Meine Route") .. TR", die Ziele (" .. k(TR"Dungeons") .. ", " .. k(TR"Ausrüstung") .. ", " .. k(TR"Ruf") .. ", " .. k(TR"Bücher") .. "), " .. k(TR"Einstellungen") .. TR" und " .. k(TR"Hilfe") .. ".",
    TR"Ganz unten, mit einem Strich abgetrennt, steht " .. k(TR"Farmen") .. TR" (Berufe und Gold). Das siehst du nur, wenn in den Einstellungen " .. k(TR"Farmberufe Routen") .. TR" auf Ja ist.",
    "",
    H .. TR"Geführt und Alles frei|r",
    k(TR"Geführt") .. TR"  Am Anfang siehst du nur das Wichtigste. Mit dem Level kommen neue Funktionen dazu, jede mit einer kurzen Erklärung, und das Fenster wächst mit. " .. k(TR"Mein Weg") .. TR" zeigt, was wann kommt." .. TR" Mit 60 ist alles da, fast wie bei Alles frei. Die Route rechnet in beiden Modi gleich.",
    k(TR"Alles frei") .. TR"  Alles ist sofort da, auch Route exportieren und laden.",
    TR"Gesperrt ist nie etwas wirklich: Einstellungen kannst du immer ändern. Bei Geführt zeigt die Seite Einstellungen die wichtigsten, mit " .. k(TR"Alle Einstellungen") .. TR" siehst du alle.",
    TR"Wechseln: auf den Knopf oben im Fenster (Tempo und Modus), in den Einstellungen oder mit " .. k(TR"/klg gefuehrt") .. TR" und " .. k(TR"/klg experte") .. ".",
    "",
    H .. TR"Was kommt wann (Geführt)|r",
    "@UNLOCKS@",
    "",
    G .. TR"Beim ersten Öffnen erklärt jedes Fenster kurz seine Knöpfe. Wieder einschalten: oben rechts auf dieser Seite " .. TR"Erklärungen nochmal zeigen" .. TR" oder /klg erklaerungen.|r",
  }
end)

Cat("arrow", TR"Pfeil und Mini Fenster", function()
  local out = {
    H .. TR"Der Pfeil|r",
    TR"Der Pfeil zeigt immer zum nächsten Schritt. Grün geradeaus, gelb seitlich, rot hinter dir. Darunter steht kurz, was zu tun ist, wie weit und wie lange ungefähr.",
    TR"Das Symbol links vom Pfeil anklicken visiert den NPC oder Mob an. Zeigt der Pfeil auf einen Händler, Lehrer oder Wirt, ist es dieser. Als Geist zeigt der Pfeil zur Leiche.",
    TR"Grösse vom Pfeil: Einstellungen, Route und Karte (50 bis 300 Prozent). Rechtsklick auf den Text sperrt den Pfeil oder gibt ihn frei, frei kannst du ihn ziehen.",
    "",
    H .. TR"Das Mini Fenster|r",
    TR"Es gibt zwei Grössen: " .. k(TR"Klein") .. TR" (Ziel, Weg und die Knöpfe) und " .. k(TR"Gross") .. TR" (dazu Tipps, Gruppe, XP Balken und Tempo). Umstellen in den Einstellungen. Ziehen verschiebt, Rechtsklick sperrt.",
    TR"Oben steht die Zone und der Schritt in dieser Zone, zum Beispiel " .. k(TR"Wald von Elwynn, Schritt 12 von 57") .. TR", darunter " .. k(TR"danach Westfall") .. TR". Der Balken darunter zeigt, wie weit du in der Zone bist.",
    TR"Unten steht zum Beispiel " .. k(TR"1 Quest fertig zum Abgeben") .. TR". Maus drauf erklärt jede Zeile.",
    TR"Unten sind drei Knöpfe: " .. ki(TR"Zurück") .. TR" (Schritt davor nochmal), " .. ki(TR"Weiter") .. TR" (nächster Schritt) und " .. ki(TR"Menü") .. ".",
    "",
    H .. TR"Das Menü|r",
    TR"Das Menü hat drei Bereiche:",
    k(TR"Route") .. TR"  " .. ki(TR"Neu rechnen") .. TR" rechnet den Abschnitt ab hier neu. Läuft eine Tour oder Farm Route, wechselst du hier zwischen ihr und der " .. k(TR"Leveling Route") .. TR". " .. k(TR"Farmen stoppen") .. TR" steht nur da, solange eine Farm Route läuft.",
    k(TR"Unterwegs") .. TR"  " .. ki(TR"Händler") .. TR" (Pfeil zum nächsten Händler), " .. ki(TR"Feierabend") .. TR" (Pfeil zum nächsten Gasthaus, mit Abgaben auf dem Weg), " .. ki(TR"Einkaufsliste") .. TR" (Quest Items zum Kaufen) und " .. ki(TR"Ziel wählen") .. TR" (Leveln, Dungeons, Ausrüstung, Bücher oder Ruf).",
    k(TR"Fenster") .. TR"  " .. ki(TR"Grosses Fenster") .. TR" öffnet das grosse Fenster, " .. ki(TR"Gruppen Ansicht") .. TR" schaltet die Zeilen der Mitspieler unter dem Mini Fenster an oder aus.",
    TR"Einen Schritt auslassen: einfach " .. k(TR"Weiter") .. TR" drücken.",
    TR"Ausgelassene Quests plant die Route erst 3 Level später wieder ein. Aus Versehen? " .. k(TR"Zurück") .. TR" auf den Schritt holt ihn wieder.",
    "",
    H .. TR"Der farbige Streifen|r",
    TR"Links im Mini Fenster ist ein farbiger Streifen. Die Farbe sagt, was der jetzige Schritt ist:",
  }
  for _, c in ipairs(ns.KIND_COLORS or {}) do
    local r, g, b = c[1][1], c[1][2], c[1][3]
    out[#out + 1] = ("   |TInterface\\Buttons\\WHITE8X8:12:6:0:0:8:8:0:8:0:8:%d:%d:%d|t  %s"):format(r * 255, g * 255, b * 255, c[2])
  end
  out[#out + 1] = TR"Die gleichen Farben haben auch die Linie und die Punkte auf der Karte."
  out[#out + 1] = ""
  out[#out + 1] = H .. TR"Hinweise|r"
  out[#out + 1] = TR"Über dem Mini Fenster steht jeder Hinweis als eigene Karte. X klickt sie weg, " .. k(TR"Gehe zu") .. TR" schickt dich hin. Kommt eine neue Funktion dazu, steht dort " .. k(TR"Neu: ...") .. TR", Klick zeigt die Erklärung."
  out[#out + 1] = ""
  out[#out + 1] = H .. TR"Karte und Minimap|r"
  out[#out + 1] = TR"Die Karte zeigt die nächsten Schritte als Linie mit Nummern. Rechts an der Karte ist eine schmale Leiste mit Symbolen (Route, Minimap Linie, Bücher, Gold, OpenMap). Maus drauf erklärt sie, leuchtend heisst an."
  out[#out + 1] = TR"Die Minimap zeigt die nächsten Schritte als Linie und Questgeber als Kreise."
  out[#out + 1] = ""
  out[#out + 1] = H .. TR"Navi|r"
  out[#out + 1] = TR"Knopf Navi an der Karte, dann Klick auf dein Ziel. Das Navi sucht den schnellsten Weg: laufen oder reiten mit deinem Tempo, Flugpunkte die du kennst, Schiff und Zeppelin (mit Nauticus die echte Abfahrt) und den Ruhestein, wenn er bereit ist. Im Chat stehen die Abschnitte mit Zeit, auf der Karte die Strecke, der Pfeil führt Abschnitt für Abschnitt."
  out[#out + 1] = TR"Laufen ist in Wegpunkte entlang der Wege geteilt: Wegpunkt 1, Wegpunkt 2, dann Flugmeister oder Zeppelin. Das Mini Fenster zeigt den Navi Schritt wie einen Routen Schritt."
  out[#out + 1] = TR"Das Navi ist ein eigenes Profil wie die Tour: im Mini Fenster Menü unter Route wechselst du zwischen Leveling Route und Navi, das Navi bleibt dabei gemerkt (auch nach Neuladen). Navi beenden wirft es weg. Am Ziel geht es von selbst zurück zur Route."
  out[#out + 1] = k(TR"Flugzeiten") .. TR"  Jeder Flug wird gemessen und gemerkt, Navi und Route rechnen dann mit der echten Zeit. Mit " .. k(TR"Wege teilen") .. TR" gehen deine Flugzeiten auch an andere Spieler und ihre zu dir. " .. k(TR"/klg fluege") .. TR" zeigt, wie viele es sind."
  out[#out + 1] = ""
  out[#out + 1] = H .. TR"Wege um Berge|r"
  out[#out + 1] = TR"Die Gelände Karte (im Addon, Ordner Karte) kennt Berge, Wasser, Klippen, Wege und die Übergänge zwischen den Zonen. Damit rechnet die Route die echten Laufwege, und der Pfeil führt Stück für Stück um das Gelände, auch über mehrere Zonen. Dazu lernt Keine Zeit Leveling Guide, wo du schon gelaufen bist: dort ist nie ein Berg. " .. k(TR"/klg karte") .. TR" zeigt den Stand."
  out[#out + 1] = TR"Einen Berg sperrst du selbst mit " .. k(TR"Alt+Klick") .. TR" auf der Karte, eine grosse Gefahr mit " .. k(TR"Alt+Strg+Klick") .. "."
  out[#out + 1] = k(TR"Wege teilen") .. TR"  Wo du gelaufen bist, geht frühestens nach 45 Minuten an andere Spieler mit Keine Zeit Leveling Guide. Eine Stelle gilt erst als frei, wenn viele Spieler an verschiedenen Tagen dort laufen. Einen Berg setzen andere nie. " .. k(TR"/klg wege") .. TR" zeigt den Stand."
  return out
end)

Cat("route", TR"Route und Tempo", function()
  return {
    H .. TR"Die Route|r",
    TR"Keine Zeit Leveling Guide rechnet eine " .. k(TR"Route mit Abschnitten") .. TR" bis Level 60. Jeder Abschnitt geht ein paar Level, mit Laufwegen, Ketten, Ruf, Questlog Plätzen, Klassenquests und Lehrern. Zonenwechsel kosten extra, darum macht die Route erst eine Zone fertig.",
    TR"Die Seite " .. k(TR"Meine Route") .. TR" hat drei Reiter: " .. k(TR"Schritte") .. TR" (alle Schritte vom Abschnitt), " .. k(TR"Zonenplan") .. TR" (Level und Zonen bis 60) und " .. k(TR"Planen") .. ".",
    "",
    H .. TR"Tempo|r",
    TR"Ein Regler mit zwei Stufen und ein paar Fragen mit Ja und Nein. Alles davon steht in den Einstellungen im Bereich " .. k(TR"Tempo") .. ".",
    k(TR"Alles") .. TR"  alle machbaren Quests, auch solche, die kaum noch XP geben. Zonen werden fertig gemacht, bevor es weiter geht. Nach Level 60 geht die Route weiter, bis alle Quests fertig sind.",
    k(TR"Normal") .. TR"  gute Quests in sinnvoller Reihenfolge. Das ist der Standard.",
    k(TR"Grinden an") .. TR"  Grinden ist eine Option: die Route nimmt Grind Schritte, wo Grinden bei dir schneller ist als eine Quest. Bei schnellen Kill Zeiten kommen öfter Grind Schritte. Bei Alles nur, wenn es im Level sonst keine Quests gibt.",
    k(TR"Grinden aus") .. TR"  keine Grind Schritte, nur Quests. Nur wenn es in deinem Level gar keine Quest mehr gibt, kommt kurz der Hinweis Level fehlt.",
    k(TR"Dungeon Quests einplanen") .. TR"  Ja: Quests für Dungeons werden mit einem kleinen Umweg angenommen, damit du sie dabei hast. Nein: nur die Vorquests, wenn sie sich lohnen, die Quest für den Dungeon wird nicht angenommen." .. TR" Standard ist Ja, der Modus ändert daran nichts.",
    k(TR"Eskorten einplanen") .. TR"  Nein: Eskort Quests kommen nicht in die Route.",
    k(TR"Kontinent wechseln") .. TR"  Nein: die Route bleibt auf deinem Kontinent, solange es dort genug Quests gibt.",
    k(TR"Bibliotheksbücher am Weg mitnehmen") .. TR"  Ja: ein Buch kommt in die Route, wenn es nur einen kleinen Umweg kostet. Wie gross der Umweg sein darf, stellst du gleich darunter ein.",
    TR"Bei jeder Stufe steht, wie viel schneller oder langsamer sie für dich ist als Normal, zum Beispiel " .. k(TR"20% langsamer") .. TR". Die Zahl kommt aus deinen gemessenen Zeiten (Lauftempo, Kampf, Pausen). Am Anfang steht " .. k(TR"geschätzt") .. TR", bis genug gemessen ist.",
    TR"Ein Grind Block ist nie länger als " .. k("@GRIND@") .. TR". Danach geht es mit Quests weiter oder der nächste Block kommt an einem anderen Ort.",
    "",
    H .. TR"Neu rechnen|r",
    TR"Die Route rechnet sich nur von selbst neu, wenn du einen ganzen Level voraus oder hinten bist, wenn eine Tour fertig ist oder wenn du eine Einstellung änderst.",
    TR"Nach einem Grind Schritt: braucht die nächste Quest noch ein höheres Level, wird nur dieser Abschnitt neu gerechnet, höchstens alle 15 Minuten und höchstens zweimal pro Abschnitt.",
    TR"Bist du weit weg von der Route (oder stirbst weit weg), zeigt der Pfeil zurück zur Route und ein Hinweis fragt " .. k(TR"Neu rechnen?") .. TR". Du kannst ihn wegklicken.",
    TR"Kleine Abweichungen (eine Quest anders gemacht, ein Schritt schon erledigt): der Pfeil springt zum nächsten passenden Schritt.",
    TR"Von Hand: Menü, " .. k(TR"Neu rechnen") .. TR". Das rechnet nur den Abschnitt ab hier neu, der Plan bis 60 bleibt.",
    TR"Im Zonenplan gibt es dazu " .. k(TR"Plan bis 60 komplett neu") .. TR": das rechnet alle Zonen und Level bis 60 von vorne. Das brauchst du nur, wenn der Plan gar nicht mehr passt.",
    "",
    H .. TR"Planen|r",
    TR"Den Reiter " .. k(TR"Planen") .. TR" gibt es bei Geführt ab Level 13 (steht auch in " .. k(TR"Mein Weg") .. TR"), bei Alles frei sofort. Dort sind der Tempo Regler und die Touren:",
    k(TR"Questlog Route") .. TR"  alle Quests aus deinem Log anhaken, dann Route berechnen.",
    ki(TR"Stunden Budget") .. TR"  Stunden und Minuten oder eine Uhrzeit: die Route passt in die Zeit und endet in einem Gasthaus.",
    k(TR"Flugpunkte Tour") .. TR"  kürzeste Tour zu allen fehlenden Flugpunkten.",
    k(TR"Entdecken Tour") .. TR"  kürzeste Tour zu allen noch nicht entdeckten Gebieten.",
    ki(TR"Feierabend") .. TR" und " .. k(TR"Questlog aufräumen") .. TR" (Quests, die sich kaum lohnen, mit Knopf zum Abbrechen).",
    k(TR"Route exportieren und laden") .. TR"  bei Alles frei sofort, bei Geführt ab Level 25. Eine geladene Route zeigt Namen in deiner Sprache.",
    "",
    H .. TR"Leveling Route und Tour|r",
    TR"Die " .. k(TR"Leveling Route") .. TR" gibt es immer, bis Level 60. Startest du eine Tour oder eine Farm Route, kommt eine zweite Route dazu. Im Menü vom Mini Fenster wechselst du zwischen beiden.",
    TR"Die Leveling Route merkt sich, wo du warst. Quests und Level, die du in der Tour machst, zählen trotzdem. Ist die Tour fertig, verschwindet sie und es geht mit der Leveling Route weiter.",
  }
end)

Cat("goals", TR"Ziele", function()
  return {
    H .. TR"Übersicht|r",
    TR"Die Übersicht zeigt deine Ziele als Karten. Auf jeder Karte steht kurz der Stand, zum Beispiel " .. k(TR"Leveln: läuft") .. ", " .. k(TR"Ausrüstung: 2 Upgrades") .. ", " .. k(TR"Bücher: 3 in der Nähe") .. TR" oder " .. k(TR"Dungeons: in 2 Level") .. ".",
    "",
    H .. TR"Mein Weg|r",
    TR"Alle Stufen bis 60 als Karten, mit einer Linie verbunden. Klick auf eine freie Karte springt zur Funktion. Eine gesperrte Karte kannst du nicht anklicken, Maus drauf zeigt, ab welchem Level sie kommt. Die Erklärung kommt, sobald du das Level erreichst.",
    TR"Dein Charakter läuft als kleine Figur den Weg entlang bis zu deinem Level, mit der Ausrüstung, die du trägst. Alle 5 Level merkt sich das Addon, was du anhast. " .. k(TR"Rückblick") .. TR" auf der Karte Level 60 lässt ihn den ganzen Weg nochmal ablaufen, mit der Ausrüstung von damals.",
    "",
    H .. TR"Statistik|r",
    TR"Deine gemessenen Zeiten: XP pro Stunde, Kampf, Laufen, Pausen und " .. k(TR"Zeit pro Zone") .. TR" (geplant gegen echt).",
    "",
    H .. (ns.T and ns.T.HudIcon and ns.T.HudIcon(TR"Dungeons", 18) or "") .. " " .. TR"Dungeons|r",
    TR"Drei Reiter: " .. k(TR"Dungeons") .. ", " .. k(TR"Raids") .. TR" und " .. k(TR"Schlachtfelder") .. TR". Dungeons ohne Quests für dich sind ausgeblendet.",
    TR"Ein Dungeon zeigt, ob du alle Quests annehmen kannst, welcher Ruf und welche Vorquests noch fehlen, und alle Quests mit Ketten.",
    k(TR"Route folgen") .. TR"  Vorquests, Annehmen, Dungeon, Abgeben.  " .. k(TR"Pfeil zum Eingang") .. TR".  " .. k(TR"In Gruppe aufteilen") .. TR"  jeder holt einen Teil der Quests.",
    "",
    H .. (ns.T and ns.T.HudIcon and ns.T.HudIcon(TR"Ausrüstung", 18) or "") .. " " .. TR"Ausrüstung|r",
    TR"Quests, deren Belohnung für dich besser ist als dein Teil. Gewertet nach den Werten für deine Klasse, Rüstungstyp und Waffen. Sortieren nach Level oder nach Verbesserung.",
    k(TR"Route berechnen") .. TR"  plant alle mit Haken, offene Vorquests kommen automatisch mit.",
    "",
    H .. (ns.T and ns.T.HudIcon and ns.T.HudIcon(TR"Ruf", 18) or "") .. " " .. TR"Ruf|r",
    TR"Alle Fraktionen mit Quests, die Ruf geben. " .. k(TR"Quests farmen") .. TR" plant die schnellste Route nur für diese Fraktion. Fraktionen mit Ruf für Mobs stehen mit " .. k(TR"Mobs") .. TR" in der Liste, " .. k(TR"Mobs farmen") .. TR" schickt dich hin.",
    "",
    H .. (ns.T and ns.T.HudIcon and ns.T.HudIcon(TR"Bücher", 18) or "") .. " " .. TR"Bücher|r",
    TR"Die Bibliotheksbücher von Forever: Liste mit Haken, Ort und Abgabe. " .. k(TR"Bücher Route") .. TR" ist die kürzeste Runde zu den angehakten.",
    TR"Ein Buch ist auf der normalen Route einen kleinen Umweg wert (Standard 600 Yards, einstellbar unter Einstellungen, Tempo).",
  }
end)

Cat("farm", TR"Farmen", function()
  return {
    G .. TR"Farmen steht unten in der Seitenleiste, wenn in den Einstellungen Farmberufe Routen auf Ja ist.|r",
    "",
    H .. TR"Berufe|r",
    TR"Kräuter, Erz, Leder, Stoff, Fleisch und Fische farmen. Oben den Beruf wählen, links die Sachen anhaken. Nur was du mit deinem Skill kannst, ist wählbar.",
    TR"Rechts zwei Reiter: " .. k(TR"Gebiete") .. TR" (Level, Stellen, Status und " .. k(TR"Gold/Std") .. TR") und " .. k(TR"Rezepte") .. TR" (mit AtlasLoot, welcher deiner Charaktere es kann).",
    TR"Gold/Std ist ein Schätzwert mit Preisen aus dem Auktionshaus (TSM, Auctionator, Auctioneer, Aux oder OribosExchange). Ohne Auktionshaus Addon zählt der Händler Preis, dann ist der Wert zu tief.",
    k(TR"Route planen") .. TR"  Ziel nach Menge oder Zeit, Elitegebiete meiden, mehrere Berufe gemischt. Angeln: Open World oder Schwärme (braucht GatherMate2).",
    "",
    H .. TR"Gold|r",
    TR"Zwei Reiter: " .. k(TR"Mobs") .. TR" und " .. k(TR"Quests") .. ".",
    k(TR"Mobs") .. TR"  Spots mit normalen Mobs, die du allein schaffst, sortiert nach Gold pro Stunde. Der Wert pro Kill wird aus deiner Beute gelernt. " .. k(TR"Farmen starten") .. TR" schickt dich hin, " .. k(TR"Stop") .. TR" zeigt die Bilanz.",
    k(TR"Quests") .. TR"  Quests mit viel Gold, mit Ziel nach Zeit oder Gold.",
  }
end)

Cat("group", TR"Gruppe", function()
  return {
    H .. TR"Mit anderen spielen|r",
    TR"Haben andere in der Gruppe Keine Zeit Leveling Guide, siehst du im Mini Fenster ihren Stand bei gemeinsamen Quests. An einer Abgabe steht, auf wen du noch warten musst.",
    TR"Die " .. k(TR"Gruppen Ansicht") .. TR" unter dem Mini Fenster zeigt pro Mitglied eine Zeile, bei welchem Schritt es ist. Standard ist an, aus im Menü vom Mini Fenster oder in den Einstellungen.",
    TR"Quests werden automatisch mit Mitspielern geteilt, die Keine Zeit Leveling Guide haben, die Quest noch nicht haben und in Reichweite sind.",
    TR"Elite und Gruppenquests kommen in der Gruppe automatisch in die Route.",
    "",
    H .. TR"Gruppen Route|r",
    TR"Der Gruppenleiter rechnet für alle. Alle anderen sehen seine Schritte und springen mit ihm weiter. Was du nicht machen kannst, steht als 'hilf mit' da.",
    TR"Meldet sich der Leiter nicht mehr, läuft wieder deine eigene Route.",
    TR"Nur der Gruppenleiter kann eine Gruppen Route schicken.",
  }
end)

Cat("set", TR"Einstellungen", function()
  return {
    H .. TR"So sind die Einstellungen aufgebaut|r",
    TR"Alle Einstellungen sind Fragen mit Ja und Nein, nach Thema sortiert. Maus auf die Frage erklärt sie.",
    TR"Bei Geführt siehst du die wichtigsten. " .. k(TR"Alle Einstellungen") .. TR" zeigt alle, " .. k(TR"Nur die wichtigsten") .. TR" wieder die kurze Liste.",
    "",
    H .. TR"Die wichtigsten|r",
    k(TR"Tempo") .. TR"  Alles oder Normal, dazu was die Route mitnimmt: Grinden, Dungeon Quests, Eskorten, Kontinent wechseln und Bücher mit Umweg.",
    k(TR"Modus") .. TR"  Geführt oder Alles frei.",
    k(TR"Mini Fenster") .. TR"  Klein oder Gross.",
    k(TR"Auto Quest") .. TR"  nimmt Quests aus deiner Route und Klassenquests selbst an und gibt sie ab.",
    k(TR"Reisen") .. TR"  Flüge, Ruhestein, Taschen (Händler einplanen), Reittier, Wege teilen.",
    k(TR"Farmberufe Routen") .. TR"  zeigt Farmen in der Seitenleiste.",
    k(TR"Look") .. TR"  mit ElvUI der ElvUI Look, sonst Classic wie die Blizzard Fenster. Gilt nach /reload.",
    "",
    G .. TR"Änderst du eine Einstellung, die die Route betrifft, rechnet sie sich neu.|r",
  }
end)

Cat("cmds", TR"Befehle", function()
  local t = {
    H .. TR"Befehle im Chat|r",
    G .. TR"Fast alles geht über die Knöpfe im Mini Fenster und im grossen Fenster. Die Befehle hier sind für Makros oder wenn ein Fenster weg ist.|r",
    "",
    k(TR"/klg") .. TR"  öffnet das grosse Fenster.",
    k(TR"/klg hilfe") .. TR"  diese Anleitung.",
    k(TR"/klg an") .. TR" und " .. k(TR"/klg aus") .. TR"  Route zeigen oder verstecken.",
    k(TR"/klg pause") .. TR"  alles anhalten oder weiter.",
    k(TR"/klg einrichten") .. TR"  Einrichtung nochmal.",
    k(TR"/klg gefahr") .. TR"  Gefahr hier markieren.  " .. k(TR"/klg gefahrweg") .. TR"  wieder löschen. Geht auch mit Alt+Klick auf der Karte.",
  }
  -- 20.4a4 (K 21:02, S 21:01): alles zum Log steht im eigenen Abschnitt "Log und Fehler melden"
  t[#t + 1] = k(TR"/klg log start") .. TR"  Log für Fehler Meldungen, mehr dazu im Abschnitt Log und Fehler melden."
  t[#t + 1] = ""
  t[#t + 1] = G .. TR"Die alten Befehle gehen weiter, stehen aber nicht mehr hier, weil es dafür Knöpfe gibt.|r"
  return t
end)

-- 20.4a4 (K 21:02, S 21:01): alles zum Log an einer Stelle. Datei Namen kommen vom Ordner Namen des Addons
-- (Entwicklung ForeverWegweiser, Release KeineZeitLevelingGuide), nicht fest im Text
Cat("log", TR"Log und Fehler melden", function()
  local logAddon = ADDON .. "_Log"
  local t = {
    H .. TR"Wofür ist das Log?|r",
    TR"Läuft etwas falsch (Pfeil, Route, Fenster), schreibt das Log mit, was das Addon gerade tut. Mit der Log Datei kann der Fehler gefunden werden. Es läuft nur, wenn du es einschaltest.",
    "",
    H .. TR"Was brauche ich dafür?|r",
    (TR"Das Addon %s muss im AddOns Ordner sein und im Charakter Menü bei AddOns an. Ohne es gibt es kein Log, der Rest läuft normal."):format(logAddon),
    "",
    H .. TR"Wie schalte ich das Log ein und aus?|r",
    k(TR"/klg log start") .. TR"  schaltet das Log ein und öffnet den Kasten Test Notiz. Solange es läuft, wird mitgeschrieben.",
    k(TR"/klg log stop") .. TR"  schaltet es aus. Was schon drin ist, bleibt.",
    "",
    H .. TR"Wie sage ich, was passiert ist?|r",
    TR"Im Kasten Test Notiz kurz eintragen, was komisch war (Fehler oder Idee). Oder im Chat:",
    k(TR"/klg testlog notiz TEXT") .. TR"  schreibt deine Notiz mit dem Stand vom Addon ins Log, zum Beispiel: hier lief er in den Berg.",
    "",
    H .. TR"Wo liegt die Datei und welche schicke ich?|r",
    (TR"Eine Log Datei pro Konto (alle Charaktere und Server zusammen): WTF\\Account\\<Konto>\\SavedVariables\\%s.lua. Schick genau diese Datei mit deiner Notiz. Nicht %s.lua, das sind nur deine Einstellungen."):format(logAddon, ADDON),
    "",
    H .. TR"Wann ist alles drin?|r",
    TR"Das Spiel schreibt die Datei erst beim Ausloggen oder nach /reload. Also erst ausloggen oder /reload, dann die Datei schicken.",
  }
  return t
end)

Cat("faq", TR"Häufige Fragen", function()
  return {
    H .. TR"Der Pfeil zeigt quer über einen Berg.|r",
    TR"Ist die Gelände Karte geladen (" .. "/klg karte" .. TR")? Ohne sie kennt Keine Zeit Leveling Guide nur die Wege, die du gelaufen bist. Lauf einmal den richtigen Weg, dann lernt er ihn. Oder setze mit Alt+Klick auf der Karte eine Gefahr.",
    "",
    H .. TR"Die Route will, dass ich grinde.|r",
    TR"Mit Grinden an kommen Grind Schritte, wo Grinden bei dir schneller ist als eine Quest, bei schnellen Kill Zeiten öfter. Ein Grind Block ist kurz (höchstens " .. "@GRIND@" .. TR"). Willst du nur Quests: beim Tempo Grinden aus. Dungeons gehen auch: bist du danach voraus, fällt der Grind Schritt weg.",
    "",
    H .. TR"Ich habe etwas anderes gemacht als die Route.|r",
    TR"Kein Problem. Kleine Abweichungen merkt die Route selbst und springt zum nächsten passenden Schritt. Bist du einen ganzen Level weiter oder hinten, rechnet sie sich neu.",
    "",
    H .. TR"Warum ist eine Funktion gesperrt?|r",
    TR"Bei Geführt kommen Funktionen mit dem Level. Mein Weg zeigt, wann. Im Modus Alles frei ist alles sofort da.",
    "",
    H .. TR"Wie genau sind die Zeiten?|r",
    TR"Am Anfang sind es Schätzwerte. Je länger du spielst, desto genauer, weil Keine Zeit Leveling Guide dein Lauftempo, dein Reittier, die Kampfzeit pro Mob und deine Pausen misst.",
    "",
    H .. TR"Die Route rechnet nicht oder ist leer.|r",
    TR"Prüfe, ob Questie und QuestieDB an sind. Nach dem Einloggen braucht Questie ein paar Sekunden. Menü, Neu rechnen versucht es nochmal.",
    "",
    H .. TR"Ich habe auch RestedXP, Zygor oder TomTom an.|r",
    TR"Das geht, aber zwei Leveling Guides zeigen zwei Pfeile und verschiedene Routen. Keine Zeit Leveling Guide sagt einmal Bescheid und läuft normal weiter. Am einfachsten ist ein Guide zur Zeit.",
    "",
    H .. TR"Ich habe einen Fehler gefunden.|r",
    TR"Alles dazu steht im Abschnitt Log und Fehler melden.",
  }
end)

ns.HELP_CATS = CATS

local function Grind()
  local m = ns.GRIND_BLOCK_MIN or 15
  return (TR"%d Minuten"):format(m)
end

-- Text einer Kategorie, Farben folgen dem Look, "Was kommt wann" kommt aus den Freischaltungen
function ns.HelpLines(key)
  local acc = ns.T and ns.T.AccHex() or "7fd1b9"
  local cat = CATS[1]
  for _, c in ipairs(CATS) do if c.key == key then cat = c end end
  local out = {}
  for _, l in ipairs(cat.lines()) do
    if l == "@UNLOCKS@" then
      for _, st in ipairs(ns.UNLOCK_STEPS or {}) do
        local n = {}
        for _, kk in ipairs(st.items) do n[#n + 1] = ns.UnlockName and ns.UnlockName(kk) or kk end
        out[#out + 1] = (TR"|cff%sLevel %d|r  %s"):format(acc, st.lvl, table.concat(n, ", "))
      end
    else
      l = l:gsub("@GRIND@", Grind())
      out[#out + 1] = (l:gsub("|cff7fd1b9", "|cff" .. acc))
    end
  end
  return out
end
