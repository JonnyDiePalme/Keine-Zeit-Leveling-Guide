local ADDON, ns = ...
local TR = ns.TR

-- Beim Start pruefen, ob die Addons da sind, die Keine Zeit Leveling Guide nutzt.
-- Fehlt eins, steht im Chat, welche Funktionen dann fehlen. Fehlt Questie, kommt zusaetzlich ein Fenster.

local DEPS = {
  { name = "Questie", need = true, what = TR"Questgeber, Abgaben, Questziele, die Route, Touren, Dungeons, Lehrer und Flugpunkte" },
  { name = "QuestieDB", need = true, what = TR"alle Quest Daten, Questie hat ohne QuestieDB nichts", check = function() return LibQuestieDB ~= nil end },
  { name = "NauticusClassicResurrected", what = TR"die genauen Abfahrtszeiten von Schiff und Zeppelin, es wird mit mittlerer Wartezeit gerechnet" },
  { name = "GatherMate2", what = TR"die Stellen von Kräutern, Erz und Fischschwärmen von GatherMate2. Keine Zeit Leveling Guide nimmt dann die eingebauten Gebietslisten und lernt selber",
    check = function() return ns.HasGatherMate and ns.HasGatherMate() end, only = function() return ns.FarmOn and ns.FarmOn() and ns.Unlocked and ns.Unlocked("berufe") end },
  { name = "AtlasLoot", what = TR"die Rezepte mit Zutaten auf der Seite Berufe. Du siehst nur die Rezepte, die du schon gelernt hast",
    check = function() return ns.HasAtlasLoot and ns.HasAtlasLoot() end, only = function() return ns.FarmOn and ns.FarmOn() and ns.Unlocked and ns.Unlocked("berufe") end },
}

local function Info(name)
  local get = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not get then return "unknown" end
  local ok, n, _, _, loadable, reason = pcall(get, name)
  if not ok or not n then return "missing" end
  if loaded and loaded(name) then return "ok" end
  if reason == "MISSING" then return "missing" end
  if reason == "DISABLED" or reason == "DEMAND_LOADED" then return "disabled" end
  if loadable == false then return "disabled" end
  return "notloaded"
end

function ns.CheckDeps(silent)
  local out = {}
  for _, d in ipairs(DEPS) do
    if not d.only or d.only() then
      local st = Info(d.name)
      if d.check then
        -- Daten da? Dann passt es, egal wie das Addon heisst
        if d.check() then st = "ok" elseif st == "ok" then st = "nodata" end
      end
      if st ~= "ok" and st ~= "unknown" then
        table.insert(out, { dep = d, state = st })
      end
    end
  end
  if not silent then
    for _, e in ipairs(out) do
      local how = ({ missing = TR"fehlt", disabled = TR"ist deaktiviert", notloaded = TR"ist nicht geladen", nodata = TR"hat keine Daten geladen" })[e.state] or TR"fehlt"
      local col = e.dep.need and "|cffff5050" or "|cffffd100"
      ns.Print((TR"%s%s %s,|r dann fehlen: %s"):format(col, e.dep.name, how, e.dep.what))
    end
    local hard
    for _, e in ipairs(out) do if e.dep.need then hard = e end end
    if hard and ns.Confirm then
      ns.Confirm(TR"Keine Zeit Leveling Guide: " .. hard.dep.name .. (hard.state == "disabled" and TR" ist deaktiviert." or TR" fehlt.")
        .. TR"\n\nOhne Questie läuft nur die einfache Route. Questie und QuestieDB im Addon Menü einschalten oder installieren.", "OK")
    end
  end
  ns.depProblems = out
  return out
end

-- andere Addons, die auch eine Leveling Route oder einen Pfeil zeigen: einmal klar sagen (pro Addon nur einmal)
local OTHERS = {
  { names = { "RXPGuides" }, label = "RestedXP" },
  { names = { "ZygorGuidesViewerClassic", "ZygorGuidesViewer" }, label = "Zygor" },
  { names = { "TomTom" }, label = "TomTom", soft = true },
  { names = { "pfQuest" }, label = "pfQuest", soft = true },
}
function ns.CheckOthers()
  local db = ns.db
  if not db then return {} end
  local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  if not loaded then return {} end
  db.otherSaid = db.otherSaid or {}
  local found = {}
  for _, o in ipairs(OTHERS) do
    for _, n in ipairs(o.names) do
      local ok, on = pcall(loaded, n)
      if ok and on then
        found[#found + 1] = o.label
        if not db.otherSaid[o.label] then
          db.otherSaid[o.label] = true
          if o.soft then
            ns.Print((TR"|cffffd100%s ist auch an.|r Das ist ok. Setzt es eigene Wegpunkte, siehst du dort einen zweiten Pfeil. Der Pfeil vom Keine Zeit Leveling Guide zeigt immer auf die Route."):format(o.label))
          else
            ns.Print((TR"|cffffd100%s ist auch an.|r Zwei Leveling Guides gleichzeitig zeigen zwei Pfeile und verschiedene Routen. Tipp: einen davon ausschalten. Keine Zeit Leveling Guide läuft trotzdem normal weiter."):format(o.label))
          end
          if ns.TestLog then ns.TestLog("ADDON", "anderes Leveling Addon an: " .. o.label) end
        end
        break
      end
    end
  end
  -- 18.3 (Konflikt Pruefung): ein anderes Addon nimmt Quests auch automatisch an oder gibt ab. Zusammen klicken beide,
  -- im Zweifel waehlt das schnellere die Belohnung. Nur ein Hinweis, nichts wird abgeschaltet
  if db.autoQuest then
    local function On(n) local ok, on = pcall(loaded, n); return ok and on end
    local qp = _G.Questie and Questie.db and Questie.db.profile
    local AUTO = {
      { label = "Questie Auto Quest", on = function() return qp and (qp.autoaccept or qp.autocomplete) and true or false end },
      { label = "Leatrix Plus Auto Quest", on = function() return On("Leatrix_Plus") and _G.LeaPlusDB and LeaPlusDB.AutomateQuests == "On" end },
      { label = "AutoTurnIn", on = function() return On("AutoTurnIn") end },
    }
    for _, o in ipairs(AUTO) do
      local ok, on = pcall(o.on)
      if ok and on and not db.otherSaid[o.label] then
        db.otherSaid[o.label] = true
        ns.Print((TR"|cffffd100%s ist auch an.|r Zusammen mit Auto Quest vom Keine Zeit Leveling Guide klicken beide, und das schnellere wählt die Belohnung. Tipp: nur eins davon an lassen."):format(o.label))
        if ns.TestLog then ns.TestLog("ADDON", "anderes Auto Quest an: " .. o.label) end
      end
    end
  end
  ns.otherAddons = found
  return found
end

local f = CreateFrame("Frame")
ns.RegEv(f, "PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  C_Timer.After(6, function() ns.CheckDeps(); if ns.CheckOthers then pcall(ns.CheckOthers) end end)
end)

-- Hat Blizzard eine Aktion von uns blockiert? Im Chat genau sagen welche, und die Funktion dahinter abschalten
local NAMES = {
  QuestLogPushQuest = { TR"Quests automatisch teilen", "autoShare" },
  AbandonQuest = { TR"Questlog aufräumen (Abbrechen Knopf)" },
  SetAbandonQuest = { TR"Questlog aufräumen (Abbrechen Knopf)" },
  -- 20.2 (P11): gesperrt sind nur die Raid Symbole, die eigenen Marker laufen weiter
  SetRaidTarget = { TR"Raid Symbole beim Markieren", "raidIcons" },
  SetCVar = { TR"Namensplaketten oder Glitzern umschalten" },
  -- 1.1 (S Log 06.11., 126x "UNKNOWN()"): Namen kommen jetzt auch aus ns.Api.Prot / ns.Api.Mark (Compat.lua)
  TakeTaxiNode = { TR"Automatisch fliegen", "autoFly" },
  Zielknopf = { TR"Ziel Knopf am Pfeil", "targetBtn" },
  ["Questitem Knopf"] = { TR"Quest Item Knöpfe", "questItems" },
  ["C_GossipInfo.SelectOption"] = { TR"Ruhestein automatisch binden" },
  SelectGossipOption = { TR"Ruhestein automatisch binden" },
  UseContainerItem = { TR"Plunder verkaufen" },
  RegisterEvent = { TR"Kampflog Abfrage (alte Version, ist entfernt)" },
  -- Auto Quest: auf Forever darf das evtl. nur die Blizzard Oberflaeche
  AcceptQuest = { TR"Auto Quest", "autoQuest" },
  CompleteQuest = { TR"Auto Quest", "autoQuest" },
  GetQuestReward = { TR"Auto Quest", "autoQuest" },
  SelectActiveQuest = { TR"Auto Quest", "autoQuest" },
  SelectAvailableQuest = { TR"Auto Quest", "autoQuest" },
  SelectGossipActiveQuest = { TR"Auto Quest", "autoQuest" },
  SelectGossipAvailableQuest = { TR"Auto Quest", "autoQuest" },
  ["C_GossipInfo.SelectActiveQuest"] = { TR"Auto Quest", "autoQuest" },
  ["C_GossipInfo.SelectAvailableQuest"] = { TR"Auto Quest", "autoQuest" },
}
local said = {}
function ns.OnBlocked(ev, addon, func)
  local db = ns.db
  if not db then table.insert(ns.blockedQueue, { ev, addon, func }); return end
  func = tostring(func or "?")
  local short = func:gsub("%(%)$", ""):match("([%w_%.:]+)$") or func
  -- 1.1: Blizzard nennt die Funktion oft nur "UNKNOWN()". War gerade eben eine unserer geschuetzten Aktionen, ist sie es
  local guess = (short == "UNKNOWN" or short == "?") and ns.Api and ns.Api.LastProt and ns.Api.LastProt()
  if guess then short, func = guess, guess .. TR"() (vermutet)" end
  if ns.Api and ns.Api.ForbiddenVerReset then ns.Api.ForbiddenVerReset(db) end
  -- alles mitschreiben, auch fremde Addons (hilft beim Suchen)
  db.blockedLog = db.blockedLog or {}
  -- wobei es passiert ist, hilft bei "UNKNOWN"
  local ctx = {}
  local function S(fr) return type(fr) == "table" and fr.IsShown and fr:IsShown() end
  if InCombatLockdown and InCombatLockdown() then table.insert(ctx, TR"Kampf") end
  if S(GameMenuFrame) then table.insert(ctx, TR"Spielmenü") end
  if S(CharacterFrame) then table.insert(ctx, TR"Charakterfenster") end
  if S(WorldMapFrame) then table.insert(ctx, TR"Karte") end
  if S(QuestFrame) or S(GossipFrame) then table.insert(ctx, TR"NPC Gespräch") end
  if S(MerchantFrame) then table.insert(ctx, TR"Händler") end
  if S(LootFrame) then table.insert(ctx, TR"Beute") end
  if S(_G.TaurenRouteBig) then table.insert(ctx, TR"Vollbild") end
  if UnitIsDeadOrGhost and ns.Api.U(UnitIsDeadOrGhost, "player") then table.insert(ctx, TR"tot") end
  if UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player") then table.insert(ctx, TR"Flug") end
  local key = tostring(addon) .. ": " .. short .. (#ctx > 0 and (" [" .. table.concat(ctx, ", ") .. "]") or TR" [nichts offen]")
  db.blockedLog[key] = (db.blockedLog[key] or 0) + 1
  if addon ~= ADDON then return end
  local n = NAMES[short] or NAMES[short:match("([%w_]+)$") or ""]
  -- v11d (Pr P2): Vermutung (UNKNOWN im selben Bild) nur zaehlen, nichts abschalten
  if guess then
    db.forbiddenGuess = db.forbiddenGuess or {}
    db.forbiddenGuess[short] = (db.forbiddenGuess[short] or 0) + 1
    return
  end
  db.forbidden = db.forbidden or {}
  db.forbidden[short] = (db.forbidden[short] or 0) + 1
  if n and n[2] then db[n[2]] = false end
  if said[short] then return end
  said[short] = true
  ns.Print((TR"|cffff5050Blizzard hat eine Aktion blockiert:|r %s%s"):format(func,
    n and (" (" .. n[1] .. (n[2] and TR", ist jetzt ausgeschaltet. Unter Einstellungen kannst du es wieder einschalten." or "") .. ")") or ""))
end
-- was beim Laden passiert ist, nach dem Einloggen auswerten
local lf = CreateFrame("Frame")
ns.RegEv(lf, "PLAYER_LOGIN")
lf:SetScript("OnEvent", function()
  C_Timer.After(3, function()
    local q = ns.blockedQueue or {}
    ns.blockedQueue = {}
    for _, e in ipairs(q) do ns.OnBlocked(e[1], e[2], e[3]) end
  end)
end)
