local ADDON, ns = ...
local TR = ns.TR

-- Quest Mobs hervorheben: Symbol mit Fortschritt ueber der Namensplakette,
-- und alleine automatisch ein Totenkopf auf das Ziel.

local marks = {}
-- 20.1b (FEH 13:27, Sascha: Markieren geht in 20.0 Era nicht): Zaehler fuer die Zeile MARKE im Test Log. Der Code hier
-- ist seit 19.33 gleich, darum zeigt die Zeile, woran es im Spiel liegt (Schalter, Plaketten, Questie Mobs, Blizzard)
local diag = { mob = 0, giver = 0, raid = 0, raidErr = nil, giverName = nil }

-- Fortschritt der Aufgabe, z.B. "1/7"
local function Count(info)
  local q = ns.logProgress and ns.logProgress[info.qid]
  if not q then return "" end
  for _, o in ipairs(q.objs) do
    if o.text and info.obj and o.text:find(info.obj, 1, true) then
      local a, b = o.text:match("(%d+)%s*/%s*(%d+)")
      if a then return a .. "/" .. b end
    end
  end
  return ""
end

-- 20.2 (P11, Sascha: Markieren geht nur manchmal): Erkennung zuerst ueber die NPC Nummer aus der GUID (wie Questie), der
-- Name nur als Rueckfall. Namen koennen im Kampf geheim sein (1.15.9) oder anders geschrieben als bei Questie.
-- Was lesbar war, merkt sich die Plakette (beim naechsten Mal geht es auch, wenn der Wert gerade geheim ist)
local function NpcOf(unit)
  local okG, g = pcall(UnitGUID, unit)
  g = okG and ns.Plain(g) or nil
  if type(g) ~= "string" then return nil end
  local t, _, _, _, _, id = strsplit("-", g)
  if t == "Creature" or t == "Vehicle" then return tonumber(id) end
end
local plateNpc, plateName = {}, {}
local function Ident(unit)
  local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit and C_NamePlate.GetNamePlateForUnit(unit)
  local id = NpcOf(unit)
  local okN, n = pcall(UnitName, unit)
  local name = okN and ns.Plain(n) or nil
  if plate then
    if id then plateNpc[plate] = id else id = plateNpc[plate] end
    if name then plateName[plate] = name else name = plateName[plate] end
  end
  return id, name
end
local function Info(unit)
  if not (ns.db and ns.db.markMobs ~= false and (ns.objMobs or ns.objMobIds)) then return end
  local okD, dead = pcall(UnitIsDead, unit)
  if okD and ns.Plain(dead) then return end
  local okP, pl = pcall(UnitIsPlayer, unit)
  if okP and ns.Plain(pl) then return end
  local id, name = Ident(unit)
  return (id and ns.objMobIds and ns.objMobIds[id]) or (name and ns.objMobs and ns.objMobs[name])
end

-- Marker NICHT an die Namensplakette haengen (die gehoert Blizzard, das fuehrt auf Forever zu "UNKNOWN" Blockaden).
-- Eigene Frames an UIParent, die jedes Bild der Plakette hinterher geschoben werden.
local follow = {}
local mover = CreateFrame("Frame", nil, UIParent)
mover:SetScript("OnUpdate", function()
  local us = UIParent:GetEffectiveScale()
  for m in pairs(follow) do
    -- versteckte Marker nicht jedes Bild nachfuehren (spart Zeit und Muell)
    if not m:IsShown() then
      -- nichts
    else
    local plate = m.plate
    local ok, x, y = false, nil, nil
    if plate then
      local okV, vis = pcall(plate.IsVisible, plate)
      if okV and ns.Plain(vis) == true then ok, x, y = pcall(plate.GetCenter, plate) end
    end
    x, y = ns.Plain(x), ns.Plain(y)
    if ok and type(x) == "number" and type(y) == "number" then
      local okS, ps = pcall(plate.GetEffectiveScale, plate)
      ps = okS and ns.Plain(ps) or us
      local okH, h = pcall(plate.GetHeight, plate)
      h = okH and ns.Plain(h) or 20
      m:ClearAllPoints()
      m:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", x * ps / us, (y + h / 2) * ps / us + (m.dy or 2))
      m:SetAlpha(1)
    else
      m:SetAlpha(0)
    end
    end
  end
end)
local function Follow(m, plate, dy)
  m.plate, m.dy = plate, dy
  follow[m] = true
end

local function GetMark(plate)
  local m = marks[plate]
  if not m then
    m = CreateFrame("Frame", nil, UIParent)
    m:SetSize(24, 24)
    Follow(m, plate, 2)
    m:SetFrameStrata("HIGH")
    m.icon = m:CreateTexture(nil, "OVERLAY")
    m.icon:SetAllPoints()
    m.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    m.text = m:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
    m.text:SetPoint("LEFT", m, "RIGHT", 0, 0)
    m.text:SetTextColor(1, 0.82, 0)
    marks[plate] = m
  end
  return m
end

local function UpdatePlate(unit)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local info = Info(unit)
  if info then
    diag.mob = diag.mob + 1
    local m = GetMark(plate)
    m.text:SetText(Count(info))
    m:Show()
  elseif marks[plate] then
    marks[plate]:Hide()
  end
end

------------------------------------------------------------
-- Questgeber, zu dem das Addon gerade schickt, gross markieren
------------------------------------------------------------
local giverMarks = {}
local CIRCLE = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

-- Name und Art (turnin, quest, beides) des aktuellen Questgebers
local function CurrentGiver()
  if not ns.db or ns.db.markGiver == false then return end
  -- optimierte Route: nur der NPC vom aktuellen Schritt (Annehmen oder Abgeben), sonst keiner
  if ns.db.optMode then
    local opt = ns.db.opt
    local st = opt and opt.steps and opt.steps[opt.idx or 1]
    if not st then return end
    local acc, turn, who, npc
    for _, a in ipairs(st.acts or {}) do
      if (a.k == "A" or a.k == "T") and not (ns.OptActDone and ns.OptActDone(a)) then
        if a.k == "A" then acc = true else turn = true end
        who, npc = who or a.who, npc or a.npc
      end
    end
    if not who then return end
    local name = ns.NpcName and ns.NpcName(npc, who) or who
    return name, (acc and turn) and "both" or (turn and "turnin" or "quest"), tonumber(npc)
  end
  local mapID = ns.PlayerMap and ns.PlayerMap()
  if not mapID then return end
  local pos = C_Map.GetPlayerMapPosition(mapID, "player")
  if not pos then return end
  local px, py = pos:GetXY()
  local hub = ns.PendingHub and ns.PendingHub(mapID, px, py)
  local function Both(npc)
    local a, b
    for _, e in ipairs((ns.qEnds and ns.qEnds[mapID]) or {}) do if e.npc == npc then a = true end end
    for _, e in ipairs((ns.qStarts and ns.qStarts[mapID]) or {}) do if e.npc == npc then b = true end end
    return a and b
  end
  if hub and hub.hub and hub.hub.npc then
    return hub[3], Both(hub.hub.npc) and "both" or (hub.turnin and "turnin" or "quest")
  end
  local route = ns.GetRoute(mapID)
  local p = route and route[ns.db.progress[mapID] or 1]
  local t = p and p.tags
  if not t then return end
  local tu = type(t.turnin) == "table" and t.turnin
  local qu = type(t.quest) == "table" and t.quest.npc and t.quest
  if tu and qu then return tu[3], "both" end
  if tu then return tu[3], "turnin" end
  if qu then return qu[3], "quest" end
end
ns.CurrentGiver = CurrentGiver

local function GetGiverMark(plate)
  local m = giverMarks[plate]
  if m then return m end
  m = CreateFrame("Frame", nil, UIParent)
  m:SetSize(44, 44)
  Follow(m, plate, 6)
  m:SetFrameStrata("HIGH")
  m.glow = m:CreateTexture(nil, "BACKGROUND")
  m.glow:SetTexture(CIRCLE)
  m.glow:SetSize(44, 44)
  m.glow:SetPoint("CENTER")
  m.inner = m:CreateTexture(nil, "BORDER")
  m.inner:SetTexture(CIRCLE)
  m.inner:SetSize(34, 34)
  m.inner:SetPoint("CENTER")
  m.inner:SetVertexColor(0, 0, 0, 0.75)
  m.icon = m:CreateTexture(nil, "ARTWORK")
  m.icon:SetSize(26, 26)
  m.icon:SetPoint("CENTER")
  m.icon2 = m:CreateTexture(nil, "ARTWORK")
  m.icon2:SetSize(22, 22)
  m.icon2:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
  -- huepfender Pfeil nach unten
  m.arrow = m:CreateTexture(nil, "OVERLAY")
  m.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
  m.arrow:SetSize(28, 28)
  m.arrow:SetPoint("BOTTOM", m, "TOP", 0, 0)
  m.arrow:SetRotation(math.pi)
  m.arrow:SetVertexColor(0.2, 1, 0.4)
  if m.CreateAnimationGroup then
    local ag = m:CreateAnimationGroup()
    local up = ag:CreateAnimation("Translation")
    up:SetOffset(0, 8); up:SetDuration(0.45); up:SetOrder(1)
    local down = ag:CreateAnimation("Translation")
    down:SetOffset(0, -8); down:SetDuration(0.45); down:SetOrder(2)
    ag:SetLooping("REPEAT")
    m.anim = ag
  end
  giverMarks[plate] = m
  return m
end

local raidMarked -- Name, dem wir ein Symbol gegeben haben
local function MarkGiver(unit, kind)
  if ns.db and ns.db.raidIcons == false then return end
  if IsInGroup and IsInGroup() then return end
  if InCombatLockdown and InCombatLockdown() then return end
  local cur = GetRaidTargetIndex(unit)
  if issecretvalue and issecretvalue(cur) then return end
  local want = (kind == "both") and 1 or 4 -- Stern bei beidem, sonst gruenes Dreieck
  if cur ~= want then
    local ok, err = pcall(SetRaidTarget, unit, want)
    if ok then diag.raid = diag.raid + 1 else diag.raidErr = tostring(err) end
  end
  raidMarked = ns.Plain(UnitName(unit))
end

local function UpdateGiverPlate(unit, giverName, kind, giverNpc)
  local plate = C_NamePlate.GetNamePlateForUnit(unit)
  if not plate then return end
  local id, name = Ident(unit)
  local okP, pl = pcall(UnitIsPlayer, unit)
  local isGiver = (giverNpc and id == giverNpc) or (giverName and name == giverName)
  if okP and ns.Plain(pl) then isGiver = false end
  if isGiver then
    diag.giver = diag.giver + 1
    local m = GetGiverMark(plate)
    if kind == "both" then
      m.glow:SetVertexColor(1, 0.5, 0, 0.95)
      m.icon:SetTexture("Interface\\GossipFrame\\ActiveQuestIcon")
      m.icon:ClearAllPoints(); m.icon:SetPoint("CENTER", -7, 0)
      m.icon2:ClearAllPoints(); m.icon2:SetPoint("CENTER", 8, 0); m.icon2:Show()
    else
      local c = (kind == "turnin") and { 0.3, 1, 0.6 } or { 1, 0.5, 0 }
      m.glow:SetVertexColor(c[1], c[2], c[3], 0.95)
      m.icon:SetTexture(kind == "turnin" and "Interface\\GossipFrame\\ActiveQuestIcon" or "Interface\\GossipFrame\\AvailableQuestIcon")
      m.icon:ClearAllPoints(); m.icon:SetPoint("CENTER")
      m.icon2:Hide()
    end
    m:Show()
    if m.anim and not m.anim:IsPlaying() then m.anim:Play() end
    MarkGiver(unit, kind)
  elseif giverMarks[plate] then
    giverMarks[plate]:Hide()
    -- altes Symbol weg, wenn das nicht mehr das Ziel ist
    if raidMarked and name == raidMarked and not (InCombatLockdown and InCombatLockdown()) then
      local cur = GetRaidTargetIndex(unit)
      if not (issecretvalue and issecretvalue(cur)) and (cur == 1 or cur == 4) then pcall(SetRaidTarget, unit, 0) end
      raidMarked = nil
    end
  end
end

local function UpdateAll()
  if not C_NamePlate then return end
  local giverName, kind, giverNpc = CurrentGiver()
  for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
    local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
    if u then
      UpdatePlate(u)
      UpdateGiverPlate(u, giverName, kind, giverNpc)
    end
  end
  -- ohne Plakette: Ziel oder Maus drueber markieren
  for _, u in ipairs({ "target", "mouseover" }) do
    if giverName and UnitExists(u) and not UnitIsPlayer(u) then
      local id, name = Ident(u)
      if (giverNpc and id == giverNpc) or name == giverName then MarkGiver(u, kind) end
    end
  end
end

-- Nur die Plaketten fuer freundliche NPCs einschalten, sonst sieht man den Marker nicht.
-- Plaketten von anderen Spielern bleiben wie sie sind. Die alten Werte merken wir uns.
local platesPending
local function EnsureFriendlyPlates()
  if not ns.db or ns.db.markGiver == false then return end
  if not (GetCVar and SetCVar) then return end
  if InCombatLockdown and InCombatLockdown() then platesPending = "on"; return end
  -- aeltere Version hat auch die Spieler Plaketten eingeschaltet: das zuruecknehmen
  local old = ns.db.oldCVars
  if old and old.nameplateShowFriends ~= nil then
    pcall(SetCVar, "nameplateShowFriends", old.nameplateShowFriends)
    old.nameplateShowFriends = nil
  end
  local cv = "nameplateShowFriendlyNPCs"
  local ok, v = pcall(GetCVar, cv)
  if ok and v ~= nil and v ~= "1" then
    ns.db.oldCVars = ns.db.oldCVars or {}
    if ns.db.oldCVars[cv] == nil then ns.db.oldCVars[cv] = v end
    pcall(SetCVar, cv, "1")
    ns.Print(TR"Namensplaketten für freundliche NPCs eingeschaltet (Spieler bleiben wie sie sind), damit der Questgeber markiert werden kann. Ausschalten unter Einstellungen: Questgeber markieren.")
  end
end

local function RestorePlates()
  if not (ns.db and ns.db.oldCVars) then return end
  if InCombatLockdown and InCombatLockdown() then platesPending = "off"; return end
  for cv, v in pairs(ns.db.oldCVars) do pcall(SetCVar, cv, v) end
  ns.db.oldCVars = nil
end

function ns.ToggleMarkGiver()
  ns.db.markGiver = (ns.db.markGiver == false)
  if ns.db.markGiver then
    EnsureFriendlyPlates()
    ns.Print(TR"Questgeber wird markiert")
  else
    RestorePlates()
    for _, m in pairs(giverMarks) do m:Hide() end
    ns.Print(platesPending == "off" and TR"Questgeber wird nicht mehr markiert, Namensplaketten kommen nach dem Kampf zurück"
      or TR"Questgeber wird nicht mehr markiert, Namensplaketten wie vorher")
  end
  UpdateAll()
end

-- Totenkopf auf das Ziel, nur alleine
local function MarkTarget()
  if not (ns.db and ns.db.markMobs ~= false) or ns.db.raidIcons == false then return end
  if IsInGroup and IsInGroup() then return end
  if not UnitExists("target") or not Info("target") then return end
  local cur = GetRaidTargetIndex("target")
  if issecretvalue and issecretvalue(cur) then return end
  if cur == nil then
    local ok, err = pcall(SetRaidTarget, "target", 8)
    if ok then diag.raid = diag.raid + 1 else diag.raidErr = tostring(err) end
  end
end

-- 20.1b: eine Zeile MARKE im Test Log (40 s nach dem Einloggen, dann alle 5 Minuten und wenn sich der Questgeber aendert)
local function MarkDiag(why)
  if not (ns.TestLog and ns.db) then return end
  local function CV(n) local ok, v = pcall(GetCVar, n); return ok and tostring(v) or "?" end
  local plates, fr, en = 0, 0, 0
  if C_NamePlate and C_NamePlate.GetNamePlates then
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
      plates = plates + 1
      local u = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      if u then
        local okF, f = pcall(UnitIsFriend, "player", u)
        if okF and ns.Plain(f) then fr = fr + 1 else en = en + 1 end
      end
    end
  end
  local nm = 0
  for _ in pairs(ns.objMobIds or ns.objMobs or {}) do nm = nm + 1 end
  local g, k = CurrentGiver()
  local blocked = ns.db.forbidden and ns.db.forbidden.SetRaidTarget
  ns.TestLog("MARKE", ("%s | Questgeber %s, Quest Mobs %s, Pause %s | Ziel Geber %s (%s) | Plaketten %d (freundlich %d, sonst %d), CVar freundl. NPC %s, Feinde %s | Questie Mobs %s | Treffer Geber %d, Mobs %d, Symbol gesetzt %d%s%s"):format(
    why, ns.db.markGiver == false and "aus" or "an", ns.db.markMobs == false and "aus" or "an", ns.db.paused and "ja" or "nein",
    tostring(g or "-"), tostring(k or "-"), plates, fr, en, CV("nameplateShowFriendlyNPCs"), CV("nameplateShowEnemies"),
    ns.objMobs and tostring(nm) or "nil", diag.giver, diag.mob, diag.raid,
    diag.raidErr and (", Fehler " .. diag.raidErr:sub(1, 80)) or "", blocked and (", Blizzard blockiert " .. blocked .. " mal") or ""))
  diag.giver, diag.mob, diag.raid, diag.raidErr = 0, 0, 0, nil
end
ns.MarkDiag = MarkDiag

local f = CreateFrame("Frame")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("QUEST_LOG_UPDATE")
local updSoon = false
f:SetScript("OnEvent", function(_, event, unit)
  -- Pause: keine Marker und Symbole setzen (Ausblenden beim Entfernen der Plakette geht weiter)
  if ns.db and ns.db.paused and event ~= "NAME_PLATE_UNIT_REMOVED" then return end
  if event == "NAME_PLATE_UNIT_ADDED" then
    -- 20.2: alte Werte der wiederverwendeten Plakette vergessen, Name und Nummer sind manchmal erst kurz danach lesbar
    local pl0 = C_NamePlate.GetNamePlateForUnit(unit)
    if pl0 then plateNpc[pl0], plateName[pl0] = nil, nil end
    UpdatePlate(unit)
    local g, k, gn = CurrentGiver()
    UpdateGiverPlate(unit, g, k, gn)
    C_Timer.After(0.3, function()
      if not UnitExists(unit) then return end
      UpdatePlate(unit)
      local g2, k2, gn2 = CurrentGiver()
      UpdateGiverPlate(unit, g2, k2, gn2)
    end)
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if plate and marks[plate] then marks[plate]:Hide() end
    if plate and giverMarks[plate] then giverMarks[plate]:Hide() end
    if plate then plateNpc[plate], plateName[plate] = nil, nil end
  elseif event == "PLAYER_TARGET_CHANGED" then
    MarkTarget()
  elseif not updSoon then
    -- QUEST_LOG_UPDATE kommt oft mehrmals hintereinander: einmal reicht
    updSoon = true
    C_Timer.After(0.5, function() updSoon = false; UpdateAll() end) -- Fortschritt hat sich geaendert
  end
end)

function ns.ToggleMarkMobs()
  ns.db.markMobs = (ns.db.markMobs == false)
  ns.Print(ns.db.markMobs and TR"Quest Mobs werden markiert" or TR"Quest Mobs werden nicht mehr markiert")
  UpdateAll()
end

------------------------------------------------------------
-- Glitzern: Quest Gegenstaende funkeln wieder, Kraeuter und Erz bekommen ein Symbol
-- Das Spiel zeigt das Funkeln nur, wenn der Umriss Modus aus ist.
------------------------------------------------------------
local SPARKLE = {
  outlineModeShowLootEffectWhenDisabled = "1",
  graphicsOutlineMode = "0",
  raidGraphicsOutlineMode = "0",
  OutlineEngineMode = "0",
  SoftTargetInteract = "3",        -- naechstes Objekt (Kraut, Erz, Quest Ding) anvisieren
  SoftTargetInteractRange = "30",
  SoftTargetIconGameObject = "1",  -- Symbol ueber dem Objekt
}

local function ApplySparkle()
  if not (ns.db and ns.db.sparkle) or not (GetCVar and SetCVar) then return end
  if InCombatLockdown and InCombatLockdown() then
    ns.sparklePending = true
    return
  end
  ns.db.sparkleOld = ns.db.sparkleOld or {}
  for cv, v in pairs(SPARKLE) do
    local ok, cur = pcall(GetCVar, cv)
    if ok and cur ~= nil then
      if ns.db.sparkleOld[cv] == nil then ns.db.sparkleOld[cv] = cur end
      if cur ~= v then pcall(SetCVar, cv, v) end
    end
  end
end

local function RestoreSparkle()
  if not (ns.db and ns.db.sparkleOld) then return end
  if InCombatLockdown and InCombatLockdown() then return end
  for cv, v in pairs(ns.db.sparkleOld) do pcall(SetCVar, cv, v) end
  ns.db.sparkleOld = nil
end

function ns.ToggleSparkle()
  ns.db.sparkle = not ns.db.sparkle
  if ns.db.sparkle then
    ApplySparkle()
    ns.Print(TR"Glitzern an: Quest Gegenstände funkeln, Kräuter und Erz bekommen ein Symbol (Umriss beim Drüberfahren ist dafür aus)")
  else
    RestoreSparkle()
    ns.Print(TR"Glitzern aus, Grafik Einstellungen wie vorher")
  end
end

-- Grafik Vorlagen schalten den Umriss wieder an: danach neu setzen
local sp = CreateFrame("Frame")
sp:RegisterEvent("PLAYER_REGEN_ENABLED")
sp:RegisterEvent("CVAR_UPDATE")
sp:SetScript("OnEvent", function(_, event, name)
  if event == "PLAYER_REGEN_ENABLED" then
    if ns.sparklePending then ns.sparklePending = false; ApplySparkle() end
    if platesPending then
      local p = platesPending
      platesPending = nil
      if p == "on" then EnsureFriendlyPlates() else RestorePlates() end
    end
  elseif ns.db and ns.db.sparkle and (name == "graphicsOutlineMode" or name == "OutlineEngineMode" or name == "GRAPHICS_OUTLINE_MODE") then
    C_Timer.After(1, ApplySparkle)
  end
end)

function ns.InitHighlight()
  if ns.db.markGiver == nil then ns.db.markGiver = true end
  ns.Ticker(1, UpdateAll) -- Ziel und Quest Daten aendern sich
  -- 20.1b: Zeile MARKE im Test Log (keep: auch bei schwachem PC im Takt)
  C_Timer.After(40, function() pcall(MarkDiag, "Start") end)
  ns.Ticker(300, function() pcall(MarkDiag, "5 Min") end, true)
  ns.Ticker(5, function()
    local g = CurrentGiver()
    -- hoechstens 10 Zeilen pro Sitzung fuer neue Questgeber, sonst wird das Log zu voll
    if g ~= diag.giverName then
      diag.giverName = g
      if g and (diag.newN or 0) < 10 then diag.newN = (diag.newN or 0) + 1; pcall(MarkDiag, "neuer Questgeber") end
    end
  end, true)
  C_Timer.After(3, EnsureFriendlyPlates)
  C_Timer.After(2, ApplySparkle)
end
