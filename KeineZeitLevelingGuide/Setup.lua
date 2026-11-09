local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Einrichtung beim ersten Start: ein paar kurze Fragen (Tempo, allein oder Gruppe, Modus, Mini Fenster), dann "Fertig, so findest du alles".
-- Ersetzt das alte Willkommen Fenster. Nochmal aufrufen: Einstellungen, "Einrichtung nochmal machen".

local win
local step = 1
local choice = {}
local STEPS = 6

local function T() return ns.T end

local function Apply()
  local db = ns.db
  if not db then return end
  -- Ziel
  if not db.levelStep then db.goal = choice.goal or db.goal or "normal" end
  -- Ruhestein und Buecher: eigene Wahl, gilt egal was sonst gewaehlt ist
  db.useHearth = nil -- Ruhestein gehoert immer zur Planung
  db.profOn = choice.profOn ~= false
  if choice.sparkle ~= nil and (db.sparkle and true or false) ~= choice.sparkle and ns.ToggleSparkle then ns.ToggleSparkle() end
  -- allein oder Gruppe
  local wasElite = db.eliteSolo
  if choice.group == "group" then
    db.eliteSolo = true; db.groupSync = true; db.autoShare = true
  else
    db.eliteSolo = false
  end
  if wasElite ~= db.eliteSolo then
    db.learnedRev = (db.learnedRev or 0) + 1
    if ns.QuestieFull then pcall(ns.QuestieFull); if ns.QuestieScan then pcall(ns.QuestieScan) end end
  end
  -- Aussehen: gilt nach Neuladen
  local oldLook = db.look or "auto"
  local wantLook = choice.look
  if wantLook and wantLook ~= ((oldLook == "auto") and (T().ElvLoaded() and "elvui" or "classic") or oldLook) then
    db.look = wantLook
    ns.lookChanged = true
    C_Timer.After(0.5, function()
      if ns.Confirm then
        ns.Confirm(TR"Der neue Look braucht ein Neuladen der Oberfläche. Jetzt neu laden?", TR"Jetzt neu laden", function() ReloadUI() end, TR"Später")
      end
    end)
  elseif wantLook then
    db.look = wantLook
  end
  -- Modus und Mini Fenster (nur noch klein und gross, "normal" ist gross)
  ns.SetMode(choice.mode or "guided")
  db.hudSize = (choice.hud == "small") and "small" or "normal"
  db.hud = true
  if ns.ApplyHudSize then ns.ApplyHudSize() end
  db.setupDone = true
  db.welcomeDone = true
  -- Fahrplan 1 bis 60: nie von selbst, nur ueber den Knopf "Berechnen" (oder hier mit Ja)
  db.planOn = true
  local msg
  if ns.planBuilding then
    -- rechnet schon (Knopf gedrueckt): der laufende Fahrplan prueft am Ende die Einstellungen
  elseif db.plan60 and ns.PlanSig and db.plan60.sig == ns.PlanSig() then
    -- schon mit genau diesen Einstellungen gerechnet
  elseif db.plan60 then
    -- es gibt eine Route, die Wahl ist anders: fragen, sonst laeuft die alte weiter
    msg = TR"Du hast etwas geändert. Route neu berechnen? Das Spiel kann kurz ruckeln. Sonst läuft die alte Route weiter."
  else
    -- noch keine Route: erst mit Berechnen geht es los
    db.calcWait = true
    msg = TR"Die Route ist noch nicht berechnet. Jetzt berechnen? Das Spiel kann dabei kurz ruckeln."
  end
  if msg and ns.Confirm then
    C_Timer.After(0.3, function() ns.Confirm(msg, TR"Jetzt berechnen", function() if ns.CalcGo then ns.CalcGo(TR"Einrichtung") end end, TR"Später") end)
  end
end

local function Build()
  local t = T()
  win = t.Window("ForeverWegweiserSetup", 760, 640, TR"Keine Zeit Leveling Guide einrichten")
  win.pages = {}
  local top = win.top or 40

  win.stepText = win:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  win.stepText:SetPoint("TOPLEFT", 22, -top - 2)

  local function Page()
    local p = CreateFrame("Frame", nil, win)
    p:SetPoint("TOPLEFT", 22, -top - 20)
    p:SetPoint("BOTTOMRIGHT", -22, 52)
    p:Hide()
    table.insert(win.pages, p)
    return p
  end
  local function H1(p, text)
    local h = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    h:SetPoint("TOPLEFT", 0, 0)
    h:SetText(text)
    if t.IsElv() then h:SetTextColor(1, 1, 1) end
    return h
  end
  local function Sub(p, text, anchor, y)
    local s = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -8)
    s:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    s:SetJustifyH("LEFT"); s:SetSpacing(3)
    s:SetText(text)
    return s
  end
  -- Auswahl Karten (eine ist gewaehlt)
  local function Choices(p, anchor, key, list, cols, h)
    local cards = {}
    local w = (716 - (cols - 1) * 10) / cols
    for i, c in ipairs(list) do
      local b = t.Card(p, w, h or 96)
      local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
      b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", col * (w + 10), -14 - row * ((h or 96) + 10))
      b.sub:SetPoint("RIGHT", -10, 0)
      b.val = c[1]
      b:SetScript("OnClick", function()
        choice[key] = c[1]
        for _, o in ipairs(cards) do o.Set(o.ttl, o.txt, o.st, choice[key] == o.val and "sel" or "inset") end
      end)
      b.ttl, b.txt, b.st = c[2], c[3], c[4]
      cards[i] = b
    end
    p:HookScript("OnShow", function()
      for _, o in ipairs(cards) do o.Set(o.ttl, o.txt, o.st, choice[key] == o.val and "sel" or "inset") end
    end)
    return cards
  end

  -- 1 Willkommen
  do
    local p = Page()
    local logo = t.Logo(p, 64)
    logo:SetPoint("TOPLEFT", 0, 0)
    local h = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    h:SetPoint("LEFT", logo, "RIGHT", 14, 6)
    h:SetText(TR"Willkommen beim Keine Zeit Leveling Guide")
    if t.IsElv() then h:SetTextColor(1, 1, 1) end
    local s = Sub(p, TR"Keine Zeit Leveling Guide zeigt dir immer, was als Nächstes kommt und wohin du läufst. Du musst nichts planen. Ein paar kurze Fragen, dann geht es los.", logo, -16)
    local items = {
      { TR"Ein Pfeil", TR"zeigt dir den Weg zum nächsten Questgeber oder Questziel." },
      { TR"Ein kleines Fenster", TR"sagt dir in Worten, was zu tun ist, zum Beispiel Wolfsfelle annehmen." },
      { TR"Neues mit der Zeit", TR"Mit dem Level kommen neue Funktionen dazu, jede kurz erklärt." },
    }
    -- nur zum Lesen: kein Klick, nichts wird eingeblendet (Maus drauf zeigt mehr)
    local acts = {
      { TR"Steht oben in der Mitte", nil,
        TR"Der Pfeil steht oben in der Mitte. Ziehen mit der Maus verschiebt ihn." },
      { TR"Ziel, Weg und XP auf einen Blick", nil,
        TR"Das Mini Fenster sagt dir, was zu tun ist. Ziehen verschiebt es, Rechtsklick sperrt es." },
      { TR"Maus drauf: was als Nächstes kommt", nil, nil },
    }
    for i, it in ipairs(items) do
      local c = t.Card(p, 232, 92)
      c:SetPoint("TOPLEFT", s, "BOTTOMLEFT", (i - 1) * 242, -18)
      c.Set(it[1], it[2], acts[i][1], "inset")
      c:SetScript("OnClick", nil)
      if c.RegisterForClicks then c:RegisterForClicks() end
      if c.hl then c.hl:SetAlpha(0) end
      c.state:SetTextColor(0.6, 0.6, 0.6)
      c:SetScript("OnEnter", function(self)
        ns.TipOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(it[1])
        if acts[i][3] then
          GameTooltip:AddLine(acts[i][3], 1, 1, 1, true)
        else
          local L = UnitLevel("player") or 1
          local shown = 0
          for _, st in ipairs(ns.VisibleSteps and ns.VisibleSteps() or {}) do
            if st.lvl > L and shown < 4 then
              local names = {}
              for _, k in ipairs(st.items) do table.insert(names, ns.UnlockName(k)) end
              GameTooltip:AddLine((TR"Level %d: %s"):format(st.lvl, table.concat(names, ", ")), 1, 1, 1, true)
              shown = shown + 1
            end
          end
          GameTooltip:AddLine(TR"Alle Stufen siehst du später unter Mein Weg.", 0.7, 0.7, 0.7, true)
        end
        GameTooltip:Show()
      end)
      c:SetScript("OnLeave", function() GameTooltip:Hide() end)
      if i == 1 then p.firstCard = c end
    end
    -- Aussehen gleich am Anfang waehlen
    local lh = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    lh:SetPoint("TOPLEFT", p.firstCard, "BOTTOMLEFT", 0, -22)
    lh:SetText(TR"Wie sollen die Fenster aussehen?")
    local elv = t.ElvLoaded()
    local lookCards = Choices(p, lh, "look", {
      { "classic", TR"Classic UI", TR"Wie die Blizzard Fenster: Gold Schrift, rote Knöpfe, Steinrahmen.", "" },
      { "elvui", "ElvUI", elv and TR"Flach und dunkel, in deiner ElvUI Farbe. Passt, wenn du ElvUI nutzt." or TR"ElvUI ist nicht aktiv. Erst ElvUI installieren, dann geht diese Wahl.", "" },
    }, 2, 70)
    local ln = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    ln:SetPoint("TOPLEFT", lookCards[1], "BOTTOMLEFT", 0, -8)
    ln:SetText(TR"Der neue Look gilt nach einem Neuladen. Ändern geht später unter Einstellungen.")
    -- 20.3z (S Wunsch 17:09, P14): Neuladen gleich bei der Wahl anbieten, nicht erst am Ende der Einrichtung
    for _, card in ipairs(lookCards) do
      card:HookScript("OnClick", function(self)
        local val = self.val
        if val == "elvui" and not elv then return end
        local shown = t.IsElv() and "elvui" or "classic"
        if val == shown or not ns.Confirm then return end
        ns.Confirm(TR"Der neue Look braucht ein Neuladen der Oberfläche. Jetzt neu laden? Die Einrichtung geht danach weiter.",
          TR"Jetzt neu laden", function() if ns.db then ns.db.look = val end; ReloadUI() end, TR"Später")
      end)
    end
    if not elv then
      lookCards[2]:HookScript("OnClick", function()
        choice.look = "classic"
        for _, o in ipairs(lookCards) do o.Set(o.ttl, o.txt, o.st, choice.look == o.val and "sel" or (o.val == "elvui" and "lock" or "inset")) end
      end)
      p:HookScript("OnShow", function() lookCards[2].Set(lookCards[2].ttl, lookCards[2].txt, "", "lock") end)
    end
  end

  -- 2 Tempo und was die Route mitnimmt
  do
    local p = Page()
    local h = H1(p, TR"Welches Tempo willst du?")
    local s = Sub(p, TR"Bei jeder Stufe steht, wie viel länger sie für dich dauert als Normal. Ändern geht jederzeit.", h)
    -- Regler mit 2 Stufen (Alles, Normal), Normal ist Standard
    local sl = T().StepSlider(p)
    sl:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 10, -16); sl:SetPoint("RIGHT", p, "RIGHT", -10, 0)
    sl:SetHeight(112)
    p:HookScript("OnShow", function() sl.Update() end)
    -- Was die Route mitnimmt: Ja oder Nein, Maus drauf erklaert kurz (gleiche Fragen wie in den Einstellungen, Tempo)
    local rows = {}
    local prev = sl
    for i, q in ipairs(ns.QuestRowDefs and ns.QuestRowDefs(true) or {}) do
      local y = t.YesNo(p, q.text, q.get, q.set, q.tip)
      if q.active then y.active = q.active; y.Update(); table.insert(ns.questRowUpd, y.Update) end
      y:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", i == 1 and -10 or 0, i == 1 and -12 or -2)
      y:SetPoint("RIGHT", p, "RIGHT", -10, 0); y:SetHeight(30)
      rows[i] = y
      prev = y
    end
    -- schwacher PC: langsamer rechnen, dafuer fluessig
    local pc = T().YesNo(p, TR"Älterer oder schwacher PC?", function() return ns.db.slowPC and true or false end, function(v)
      ns.db.slowPC = v or nil
    end, TR"Ja: die Route rechnet langsamer, dafür ruckelt nichts. Bei Ruckeln bremst Keine Zeit Leveling Guide auch von selbst.")
    pc:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2); pc:SetPoint("RIGHT", p, "RIGHT", -10, 0); pc:SetHeight(30)
    rows[#rows + 1] = pc
    p:HookScript("OnShow", function() for _, y in ipairs(rows) do if y.Update then y.Update() end end end)
    -- Route berechnen: nur auf Knopfdruck, Weiter geht erst danach
    local hint = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    hint:SetPoint("TOPLEFT", pc, "BOTTOMLEFT", 0, -12)
    hint:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    hint:SetJustifyH("LEFT"); hint:SetSpacing(2)
    hint:SetTextColor(1, 0.55, 0.1)
    hint:SetText(TR"Drück auf Route berechnen, dann kannst du gleich weitermachen. Bis die Route fertig ist, kann das Spiel kurz ruckeln.")
    local btn = T().Button(p, TR"Route berechnen", 190, 26, true)
    btn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -10)
    win.calcBtn = btn
    local st = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    st:SetPoint("LEFT", btn, "RIGHT", 12, 0)
    st:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    st:SetJustifyH("LEFT")
    win.calcStatus = st
    -- nur was der Knopf gestartet hat zaehlt als "rechnet" (die kurze Start Route beim Einloggen nicht)
    local function Busy() return win.calcPressed and ((ns.OptBusy and ns.OptBusy()) or ns.planBuilding) end
    local function SetSt(txt)
      if win.blinkAt and GetTime() - win.blinkAt < 3 then return end
      st:SetText(txt)
    end
    local function Upd()
      local db = ns.db or {}
      local wt = win.calcPressed and ns.PlanWaitText and ns.PlanWaitText()
      if wt then
        -- gedrueckt, aber noch nicht alles geladen: wartet und rechnet dann von selbst
        btn:SetText(TR"Wartet ..."); btn:Disable()
        SetSt(wt)
      elseif Busy() then
        btn:SetText(TR"Rechnet ..."); btn:Disable()
        SetSt(TR"Die Route wird gerechnet. Du kannst schon auf Weiter klicken.")
      elseif db.plan60 and ns.PlanSig and db.plan60.sig == ns.PlanSig() and (win.calcPressed or not win.fresh) then
        btn:SetText(TR"Neu berechnen"); btn:Enable()
        SetSt(TR"|cff40ff40Fertig berechnet.|r Änderst du oben etwas, nochmal berechnen.")
      else
        btn:SetText(TR"Route berechnen"); btn:Enable()
        SetSt((db.plan60 and not win.fresh) and TR"Deine Wahl hat sich geändert, die Route ist noch die alte." or TR"Noch nicht berechnet.")
      end
      if win.UpdNext then win.UpdNext() end
    end
    btn:SetScript("OnClick", function() win.calcPressed = true; win.blinkAt = nil; if ns.CalcGo then ns.CalcGo(TR"Einrichtung") end; Upd() end)
    local acc = 0
    p:HookScript("OnShow", Upd)
    p:HookScript("OnUpdate", function(_, e)
      acc = acc + (e or 0)
      if acc < 0.5 then return end
      acc = 0
      Upd()
    end)
  end

  -- 3 allein oder Gruppe
  do
    local p = Page()
    local h = H1(p, TR"Spielst du meistens allein oder in einer Gruppe?")
    local s = Sub(p, TR"Davon hängt ab, ob schwere Quests und das Teilen von Quests eingeplant werden.", h)
    local cards = Choices(p, s, "group", {
      { "solo", TR"Meistens allein", TR"Nur Quests, die du allein schaffst. Elite Quests werden ausgelassen.", "" },
      { "group", TR"Oft in einer Gruppe", TR"Elite Quests kommen dazu. Quests werden mit Mitspielern geteilt, die das Addon auch haben. Das Mini Fenster zeigt ihren Stand.", "" },
    }, 2, 120)
    local n = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    n:SetPoint("TOPLEFT", cards[1], "BOTTOMLEFT", 0, -14)
    n:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    n:SetJustifyH("LEFT")
    n:SetText(TR"In einer Gruppe gehen die Gruppen Hilfen sowieso von selbst an. Hier geht es nur darum, wie du meistens spielst.")

    -- eigene Wahl, unabhaengig von Spielweise und Modus
    local h2 = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    h2:SetPoint("TOPLEFT", n, "BOTTOMLEFT", 0, -26)
    h2:SetText(t.Section(TR"Was soll die Route sonst noch machen?"))
    local rows = {
      { TR"Glitzern bei Quest Items, Kräutern und Erz?", "sparkle", TR"Ja: Quest Gegenstände funkeln, Kräuter und Erz bekommen ein Symbol. Nein: wie im normalen Spiel.", true },
      { TR"Farmberufe Routen?", "profOn", TR"Ja: unten in der Seitenleiste kommt Farmen dazu, mit Berufe und Gold (Kräuter, Erz, Leder und mehr). Bei Geführt ab Level 10." },
    }
    -- 20.4b: Frage nach Farmen nur mit dem Farming Zusatz Addon
    if not (ns.FarmAddonLoaded and ns.FarmAddonLoaded()) then table.remove(rows, #rows) end
    local prev = h2
    p.yn = {}
    for i, r in ipairs(rows) do
      local y = t.YesNo(p, r[1], function()
        if r[4] then return choice[r[2]] == true or (choice[r[2]] == nil and ns.db and ns.db.sparkle) and true or false end
        return choice[r[2]] ~= false end, function(v) choice[r[2]] = v end, r[3])
      y:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, i == 1 and -10 or -6)
      y:SetPoint("RIGHT", p, "RIGHT", 0, 0)
      p.yn[i] = y
      prev = y
    end
    local n2 = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    n2:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -8)
    n2:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    n2:SetJustifyH("LEFT")
    n2:SetText(TR"Gilt für jedes Tempo und jeden Modus. Ändern geht später unter Einstellungen.")
    -- 19.32 (Saschas Runde 2 Punkt 14): Startgebiet gleich am Anfang (bis Level 12), zb um mit Freunden woanders anzufangen
    local sh = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    sh:SetPoint("TOPLEFT", n2, "BOTTOMLEFT", 0, -22)
    sh:SetText(t.Section(TR"Wo fängst du an?"))
    local sb = t.Button(p, TR"Startgebiet wählen", 220, 24)
    sb:SetPoint("TOPLEFT", sh, "BOTTOMLEFT", 0, -8)
    sb:SetScript("OnClick", function() if ns.ChooseStartArea then ns.ChooseStartArea() end end)
    local st = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    st:SetPoint("LEFT", sb, "RIGHT", 12, 0)
    st:SetPoint("RIGHT", p, "RIGHT", 0, 0)
    st:SetJustifyH("LEFT")
    local function StartFill()
      local show = (UnitLevel("player") or 1) <= 12 and ns.ChooseStartArea ~= nil and ns.StartAreas and #ns.StartAreas() > 0
      sh:SetShown(show and true or false); sb:SetShown(show and true or false); st:SetShown(show and true or false)
      if not show then return end
      local cur = ns.CurStartKey and ns.CurStartKey()
      local name
      for _, a in ipairs(ns.StartAreas()) do if a.key == cur then name = a.name end end
      st:SetText(name and (TR"Jetzt: %s. Woanders anfangen geht hier oder später im grossen Fenster."):format(name)
        or TR"Woanders anfangen geht hier oder später im grossen Fenster.")
    end
    p:HookScript("OnShow", function() for _, y in ipairs(p.yn) do y.Update() end; pcall(StartFill) end)
    if ns.OnStartAreaChanged == nil then ns.OnStartAreaChanged = function() pcall(StartFill) end end
  end

  -- 4 Geführt oder Experte, Mini Fenster klein oder gross, mit Vorschau die sich beim Umschalten aendert
  do
    local p = Page()
    local h = H1(p, TR"Wie viel willst du sehen?")
    local modeCards = Choices(p, h, "mode", {
      { "guided", TR"Geführt", TR"Am Anfang nur das Wichtigste. Mit dem Level kommen neue Seiten dazu, jede mit kurzer Erklärung.", TR"Neu bei Keine Zeit Leveling Guide" },
      { "free", TR"Alles frei", TR"Alles sofort da, alle Seiten und Einstellungen, auch Route exportieren und laden.", TR"Jederzeit wechselbar" },
    }, 2, 88)
    local h2 = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    h2:SetPoint("TOPLEFT", modeCards[1], "BOTTOMLEFT", 0, -12)
    h2:SetText(TR"Wie gross soll das Mini Fenster sein?")
    local hudCards = Choices(p, h2, "hud", {
      { "small", TR"Klein", TR"Pfeil plus Ziel, Weg und die drei Knöpfe", "" },
      { "normal", TR"Gross", TR"dazu Tipps, Gruppe, XP Balken und Tempo", "" },
    }, 2, 46)

    -- Vorschau links: so sieht das grosse Fenster aus
    local pvM = t.Panel(p, "inset")
    pvM:SetPoint("TOPLEFT", hudCards[1], "BOTTOMLEFT", 0, -26)
    pvM:SetSize(440, 214)
    local pvMt = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    pvMt:SetPoint("BOTTOMLEFT", pvM, "TOPLEFT", 2, 4)
    pvMt:SetText(TR"Vorschau, nur ein Bild: so sieht das grosse Fenster aus")
    local side = t.SideStrip(pvM, 130)
    side:SetPoint("TOPLEFT", 3, -3); side:SetPoint("BOTTOMLEFT", 3, 3)
    local ar, ag, ab = t.Acc()
    local elvLook = t.IsElv()
    -- Alles in der Vorschau ist nur Text, keine Knoepfe: die aktuelle Seite hat einen Strich in der Akzentfarbe
    local function Mark(parent, w, h)
      local bg = parent:CreateTexture(nil, "ARTWORK")
      bg:SetColorTexture(ar, ag, ab, 0.16); bg:SetSize(w, h)
      local bar = parent:CreateTexture(nil, "OVERLAY")
      bar:SetColorTexture(ar, ag, ab, 1); bar:SetSize(2, h)
      bar:SetPoint("LEFT", bg, "LEFT", 0, 0)
      return bg, bar
    end
    local navRows, navHeads = {}, {}
    for i = 1, 12 do
      local fs = side:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      fs:SetJustifyH("LEFT")
      navRows[i] = fs
      navHeads[i] = side:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    end
    local navSel, navBar = Mark(side, 120, 16)
    -- rechts wie die echten Einstellungen: Themen als Liste, daneben die Fragen mit ihrem Wert
    local body = CreateFrame("Frame", nil, pvM)
    body:SetPoint("TOPLEFT", side, "TOPRIGHT", 8, -2); body:SetPoint("BOTTOMRIGHT", -6, 6)
    local CATS_E = { TR"Tempo", TR"Allgemein", TR"Route und Karte", TR"Quests", TR"Gruppe" }
    local CATS_X = { TR"Tempo", TR"Allgemein", TR"Route und Karte", TR"Reisen", TR"Quests", TR"Gruppe", TR"Bücher", TR"Farmen" }
    local cats = {}
    for k = 1, 8 do
      local fs = body:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      fs:SetJustifyH("LEFT")
      fs:SetPoint("TOPLEFT", body, "TOPLEFT", 8, -5 - (k - 1) * 22)
      cats[k] = fs
    end
    local catSel = Mark(body, 90, 20)
    catSel:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    local qBox = t.Panel(body, "inset")
    qBox:SetPoint("TOPLEFT", 98, 0); qBox:SetPoint("BOTTOMRIGHT")
    local qt = qBox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge")); qt:SetPoint("TOPLEFT", 8, -6)
    if elvLook then qt:SetTextColor(1, 1, 1) end
    qt:SetText(TR"Tempo")
    local qs = qBox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); qs:SetPoint("TOPLEFT", qt, "BOTTOMLEFT", 0, -2)
    qs:SetText(TR"Wie viele Quests, wie schnell")
    local qrows = {}
    for k = 1, 4 do
      local q = qBox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      q:SetPoint("TOPLEFT", 8, -46 - (k - 1) * 24); q:SetJustifyH("LEFT")
      local v = qBox:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
      v:SetPoint("TOPRIGHT", qBox, "TOPRIGHT", -10, -46 - (k - 1) * 24)
      v:SetText(TR"Ja"); v:SetTextColor(ar, ag, ab)
      local ln = qBox:CreateTexture(nil, "ARTWORK")
      ln:SetColorTexture(1, 1, 1, 0.06); ln:SetHeight(1)
      ln:SetPoint("TOPLEFT", q, "BOTTOMLEFT", 0, -6); ln:SetPoint("RIGHT", qBox, "RIGHT", -8, 0)
      qrows[k] = { q = q, v = v, ln = ln }
    end
    local lnote = pvM:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    lnote:SetPoint("TOPLEFT", pvM, "BOTTOMLEFT", 2, -4); lnote:SetPoint("RIGHT", pvM, "RIGHT", 0, 0)
    lnote:SetJustifyH("LEFT")
    local function ShowModePreview()
      local expert = choice.mode == "free"
      local learn = false
      -- Themen und Fragen wie im echten Fenster
      local list = (expert or learn) and CATS_X or CATS_E
      for k, fs in ipairs(cats) do
        local d = list[k]
        fs:SetShown(d ~= nil)
        if d then
          fs:SetText(d)
          if k == 1 then fs:SetTextColor(1, 1, 1) else fs:SetTextColor(0.7, 0.7, 0.7) end
        end
      end
      local qs2 = (expert or learn) and { TR"Tempo", TR"Dungeon Quests", TR"Eskorten", TR"Kontinent wechseln" }
        or { TR"Tempo", TR"Dungeon Quests" }
      for k, r in ipairs(qrows) do
        local on = qs2[k] ~= nil
        r.q:SetShown(on); r.v:SetShown(on); r.ln:SetShown(on)
        if on then r.q:SetText(qs2[k]) end
      end
      lnote:SetText(expert and TR"Alles frei: alle Seiten und Einstellungen sofort."
        or (t.C(TR"Kommt dazu:") .. TR" Ausrüstung und Berufe 10, Bücher 12, Dungeons 15, Statistik 25, Ruf 30, Gold 35. Einstellungen: die wichtigsten, mit Knopf für alle."))
      for _, r in ipairs(navRows) do r:Hide() end
      for _, hd in ipairs(navHeads) do hd:Hide() end
      navSel:Hide(); navBar:Hide()
      local nav = expert
        and { "#Start", TR"Übersicht", TR"Mein Weg", TR"Statistik", "#Route", TR"Meine Route", "#Ziele", TR"Dungeons", TR"Ausrüstung", TR"Ruf", TR"Bücher", "#Sonstiges", TR"Einstellungen" }
        or { "#Start", TR"Übersicht", TR"Mein Weg", "#Route", TR"Meine Route", "#Sonstiges", TR"Einstellungen", TR"Hilfe" }
      local y, ri, hi = 6, 0, 0
      for _, it in ipairs(nav) do
        if it:sub(1, 1) == "#" then
          hi = hi + 1
          local hd = navHeads[hi]
          hd:ClearAllPoints(); hd:SetPoint("TOPLEFT", 8, -y - 2)
          local hn = TR(it:sub(2)) -- Ueberschrift ohne #, uebersetzt
          hd:SetText(elvLook and hn:upper() or hn); hd:Show()
          y = y + 13
        else
          ri = ri + 1
          local r = navRows[ri]
          if r then
            local sel = it == TR"Einstellungen"
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", 14, -y - 3)
            r:SetText(it)
            if sel then r:SetTextColor(1, 1, 1)
            elseif elvLook then r:SetTextColor(0.78, 0.78, 0.78)
            else r:SetTextColor(1, 0.82, 0) end
            if sel then
              navSel:ClearAllPoints(); navSel:SetPoint("TOPLEFT", side, "TOPLEFT", 5, -y)
              navSel:Show(); navBar:Show()
            end
            r:Show()
            y = y + ((expert or learn) and 14 or 22)
          end
        end
      end
    end

    -- Vorschau rechts: so sieht das Mini Fenster aus
    local pvH = CreateFrame("Frame", nil, p)
    pvH:SetPoint("TOPLEFT", pvM, "TOPRIGHT", 16, 0)
    pvH:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
    local pvHt = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    pvHt:SetPoint("BOTTOMLEFT", pvH, "TOPLEFT", 2, 4)
    pvHt:SetText(TR"Vorschau, nur ein Bild: Mini Fenster")
    local mh = CreateFrame("Frame", nil, pvH, t.BD)
    mh:SetPoint("TOPLEFT", 0, 0); mh:SetWidth(240)
    t.Skin(mh, t.IsElv() and "window" or "tooltip")
    local lg = t.Logo(mh, 14); lg:SetPoint("TOPLEFT", 10, -7)
    local mz = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall")); mz:SetPoint("LEFT", lg, "RIGHT", 5, 0); mz:SetText(TR"Mulgore, Schritt 3 von 24")
    local ms = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); ms:SetPoint("TOPLEFT", mz, "BOTTOMLEFT", 0, -1); ms:SetText(TR"danach Brachland")
    local stripe = mh:CreateTexture(nil, "ARTWORK"); stripe:SetColorTexture(1, 0.5, 0, 0.9); stripe:SetWidth(3)
    stripe:SetPoint("TOPLEFT", 4, -32); stripe:SetPoint("BOTTOMLEFT", 4, 34)
    local mk = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall")); mk:SetPoint("TOPLEFT", 10, -36); mk:SetText(TR"|cffff9a3cQUESTS ANNEHMEN|r")
    local mt = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight")); mt:SetPoint("TOPLEFT", 10, -50); mt:SetText(TR"Häuptling Bluthuf")
    local md = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); md:SetPoint("TOPRIGHT", -8, -36); md:SetText(TR"120 yd  0:40")
    local mn = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); mn:SetPoint("TOPLEFT", 10, -68); mn:SetText(TR"Danach: Abgeben bei Baine")
    local mhint = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall")); mhint:SetPoint("TOPLEFT", 10, -84); mhint:SetText(TR"|cff4dccff>|r 3 neue Zauber lernen")
    local mx = t.Bar(mh, 12); mx:SetPoint("BOTTOMLEFT", 10, 44); mx:SetPoint("BOTTOMRIGHT", -8, 44)
    mx:SetStatusBarColor(0.58, 0, 0.55, 0.9); mx:SetValue(0.58); mx.text:SetText(TR"Level 5  58%")
    -- die drei Knoepfe nur als Schrift (in der Vorschau kann man nichts klicken)
    local mbs = {}
    local sep = mh:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(1, 1, 1, 0.08); sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", 10, 30); sep:SetPoint("BOTTOMRIGHT", -8, 30)
    for i, n in ipairs({ TR"Zurück", TR"Weiter", TR"Menü" }) do
      local b = mh:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
      b:SetPoint("BOTTOM", mh, "BOTTOMLEFT", 8 + (i - 1) * 76 + 36, 13)
      b:SetText((t.HudIcon and t.HudIcon(n, 12) and (t.HudIcon(n, 12) .. " ") or "") .. n)
      mbs[i] = b
    end
    mbs[4] = sep
    local arrow = pvH:CreateTexture(nil, "ARTWORK")
    -- wie der echte Pfeil: Classic der goldene Pfeil, ElvUI der schlichte in der ElvUI Farbe
    if t.IsElv() then
      arrow:SetTexture("Interface\\Minimap\\MinimapArrow"); arrow:SetVertexColor(t.Acc())
    else
      arrow:SetTexture(ns.APATH .. "Media\\fw_arrow")
    end
    arrow:SetSize(64, 64); arrow:SetPoint("TOPLEFT", 80, -20)
    local arrowT = pvH:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    arrowT:SetPoint("TOP", arrow, "BOTTOM", 0, -4)
    arrowT:SetText(TR"Häuptling Bluthuf\n|cff9d9d9d120 yd|r")
    local note = pvH:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    note:SetPoint("BOTTOMLEFT", 0, 0); note:SetPoint("RIGHT", pvH, "RIGHT", 0, 0); note:SetJustifyH("LEFT")
    local function ShowHudPreview()
      local k = (choice.hud == "small") and "small" or "normal"
      mh:Show()
      local small = (k == "small")
      mx:SetShown(not small)
      for _, b in ipairs(mbs) do b:Show() end
      mn:SetShown(not small)
      mhint:SetShown(not small)
      mh:SetHeight(small and 104 or 160)
      -- der Pfeil ist bei allen drei dabei, nur das Fenster aendert sich
      arrow:ClearAllPoints(); arrowT:ClearAllPoints()
      -- Groesse wie beim echten Pfeil (Regler darunter), in der Vorschau hoechstens doppelt
      local as = math.max(0.5, math.min(2, (ns.db and ns.db.arrowScale) or 1))
      arrow:SetSize(34 * as, 34 * as); arrow:SetPoint("TOPLEFT", mh, "BOTTOMLEFT", 4, -6)
      arrowT:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
      arrowT:SetText(TR"Pfeil, separat verschiebbar")
      note:SetText(small and TR"Klein: Pfeil plus Fenster mit Ziel, Weg und den drei Knöpfen." or TR"Gross: dazu Tipps, Gruppe, XP Balken und Tempo.")
    end

    -- Groesse vom Pfeil gleich hier einstellen (gehoert zur Seite, nicht zur Vorschau, darum klickbar)
    local asl = t.ValueSlider(p, ns.ARROW_MIN or 0.5, ns.ARROW_MAX or 3, 0.1,
      function() return (ns.db and ns.db.arrowScale) or 1 end,
      function(v) if ns.SetArrowScale then ns.SetArrowScale(v) end; ShowHudPreview() end)
    asl:SetPoint("BOTTOMLEFT", pvH, "BOTTOMLEFT", 0, 26)
    asl:SetWidth(200)
    local alab = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    alab:SetPoint("BOTTOMLEFT", asl, "TOPLEFT", 0, 4)
    asl.OnChanged = function() alab:SetText((TR"Grösse vom Pfeil: %d%%"):format(math.floor(((ns.db and ns.db.arrowScale) or 1) * 100 + 0.5))) end
    asl.Update()

    -- Die Vorschau ist nur ein Bild: nichts darin reagiert auf die Maus (kein Leuchten, kein Klick)
    local function NoMouse(fr)
      if type(fr) ~= "table" then return end
      if fr.EnableMouse then fr:EnableMouse(false) end
      if fr.EnableMouseWheel then fr:EnableMouseWheel(false) end
      if fr.GetChildren then for _, ch in ipairs({ fr:GetChildren() }) do NoMouse(ch) end end
    end
    NoMouse(pvM); NoMouse(pvH)

    for _, c in ipairs(modeCards) do c:HookScript("OnClick", ShowModePreview) end
    for _, c in ipairs(hudCards) do c:HookScript("OnClick", ShowHudPreview) end
    p:HookScript("OnShow", function() ShowModePreview(); ShowHudPreview(); NoMouse(pvM); NoMouse(pvH) end)
  end

  -- 5 Addons: notwendige und optionale, aktive jeweils oben
  do
    local p = Page()
    local h = H1(p, TR"Hilfreiche Addons")
    local s = Sub(p, TR"Grün heisst: installiert und aktiv. Unter diesen Namen findest du sie auf CurseForge. Optionale Addons helfen, es geht aber auch ohne.", h)
    local function Loaded(name)
      local l = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
      return l and l(name) and true or false
    end
    local NEED = {
      { "Questie", TR"Kennt alle Quests, Mobs und Orte. Ohne Questie gibt es keine Route.", function() return QuestieLoader ~= nil end, img = nil,
        fx = TR"Alle Questgeber, Ziele und Abgaben auf der Karte. Keine Zeit Leveling Guide baut daraus die Route." },
      { "QuestieDB", TR"Die Quest Daten für Questie, ohne geht Questie nicht. Eigener Ordner neben Questie.", function() return LibQuestieDB ~= nil end, img = nil,
        fx = TR"Das grosse Buch mit allen Quests: Level, Vorquests, Belohnungen." },
    }
    local OPT = {
      { "NauticusClassicResurrected", TR"Abfahrtszeiten von Schiff und Zeppelin. Die Route wartet nicht unnötig am Steg.", function() return Loaded("NauticusClassicResurrected") end, img = 2,
        fx = TR"Die Route weiss, wann Schiff und Zeppelin fahren, und plant die Wartezeit ein." },
      { TR"Auktionshaus Addon", TR"Auctionator, TSM, Auctioneer, Aux oder OribosExchange. Damit kennen Gold und Berufe die Preise für Stoff, Kräuter und Leder.",
        function() local s = ns.AHSources and ns.AHSources() or {}; return #s > 0 or (ns.HasAuctionator and ns.HasAuctionator()) end, img = nil,
        fx = TR"Mit echten AH Preisen weiss Keine Zeit Leveling Guide, welche Beute sich lohnt und was du verkaufen sollst." },
      { "OpenMap", TR"Grosse Karte über mehrere Zonen. Die Route wird darauf ganz gezeichnet.", function() return OpenMapAPI ~= nil end, img = 5,
        fx = TR"Die ganze Route über mehrere Zonen auf einer grossen Karte." },
      { "GatherMate2", TR"Kennt Kräuter, Erz und Fischschwärme. Ohne nimmt Keine Zeit Leveling Guide eigene Listen und lernt beim Farmen dazu, kennt am Anfang aber weniger.",
        function() return ns.HasGatherMate and ns.HasGatherMate() end, file = "fw_gathermate",
        fx = TR"Die Karte voller Kräuter und Erz. Daraus plant die Seite Berufe ihre Runden. Mit GatherMate2_Data kommen alle bekannten Stellen dazu." },
      { "AtlasLootClassic", TR"Oder AtlasLoot Continued. Kennt alle Rezepte mit Zutaten. Ohne AtlasLoot siehst du nur die Rezepte, die du schon gelernt hast.", function() return ns.HasAtlasLoot and ns.HasAtlasLoot() end },
      { "ElvUI", TR"Mit ElvUI passen sich die Fenster an. Gibt es auf tukui.org, nicht auf CurseForge.", function() return t.ElvLoaded() end },
    }
    local function Head(text)
      local fs = p:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
      fs:SetText(t.Section(text))
      return fs
    end
    local function Row()
      local r = t.Panel(p, "inset")
      r:SetHeight(34)
      r.n = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
      r.n:SetPoint("LEFT", 10, 0); r.n:SetWidth(210); r.n:SetJustifyH("LEFT"); r.n:SetWordWrap(true)
      r.w = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.w:SetPoint("LEFT", 226, 0); r.w:SetPoint("RIGHT", r, "RIGHT", -112, 0)
      r.w:SetJustifyH("LEFT")
      r.s = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
      r.s:SetPoint("RIGHT", -10, 0)
      return r
    end
    -- Maus auf ein Addon: Bild, was es bringt
    local hov = CreateFrame("Frame", nil, p, t.BD)
    hov:SetSize(340, 210); hov:SetFrameStrata("TOOLTIP")
    t.Skin(hov, "tooltip")
    hov.img = hov:CreateTexture(nil, "ARTWORK")
    hov.img:SetPoint("TOPLEFT", 8, -8); hov.img:SetSize(324, 162)
    hov.img:SetTexture(ns.APATH .. "Media\\fw_addons")
    hov.txt = hov:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    hov.txt:SetPoint("TOPLEFT", hov.img, "BOTTOMLEFT", 0, -6); hov.txt:SetPoint("RIGHT", -8, 0); hov.txt:SetJustifyH("LEFT")
    hov:Hide()
    local function ShowHov(r, it)
      if not (it.img or it.file) then return end
      if it.file then
        hov.img:SetTexture(ns.APATH .. "Media\\" .. it.file)
        hov.img:SetTexCoord(0, 1, 0, 1)
      else
        hov.img:SetTexture(ns.APATH .. "Media\\fw_addons")
        local c, rr = it.img % 2, math.floor(it.img / 2)
        hov.img:SetTexCoord(c / 2, (c + 1) / 2, rr / 4, (rr + 1) / 4)
      end
      hov.txt:SetText(it.fx or it[2])
      hov:ClearAllPoints()
      -- 19.32 (UI Pruefer, Saschas Wunsch): der Bildkasten an der Maus statt fest am Rand der Zeile
      -- 20.1 (Log 12:13, 31 Fehler): "a and f()" gibt nur einen Wert zurueck, cy war immer nil
      local cx, cy
      if GetCursorPosition then cx, cy = GetCursorPosition() end
      local sc = hov:GetEffectiveScale()
      if cx and cy and sc and sc > 0 then hov:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", cx / sc + 18, cy / sc + 10)
      else hov:SetPoint("BOTTOMLEFT", r, "TOPLEFT", 220, 4) end
      hov:Show()
    end
    local hNeed, hOpt = Head(TR"Notwendige Addons"), Head(TR"Optionale Addons")
    local rows = {}
    for i = 1, #NEED + #OPT do rows[i] = Row() end
    p:HookScript("OnShow", function()
      local function Sorted(list)
        local on, off = {}, {}
        for _, it in ipairs(list) do table.insert(it[3]() and on or off, it) end
        for _, it in ipairs(off) do table.insert(on, it) end
        return on
      end
      local y = -10
      local ri = 0
      local function Place(head, list, need)
        head:ClearAllPoints(); head:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, y)
        y = y - 20
        for _, it in ipairs(Sorted(list)) do
          ri = ri + 1
          local r = rows[ri]
          r:ClearAllPoints()
          r:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, y); r:SetPoint("RIGHT", p, "RIGHT", 0, 0)
          r.n:SetText(it[1]); r.w:SetText(it[2])
          r:EnableMouse(true)
          r:SetScript("OnEnter", function(self) ShowHov(self, it) end)
          r:SetScript("OnLeave", function() hov:Hide() end)
          local ok = it[3]() and true or false
          if ok then r.s:SetText(need and TR"Nötig, aktiv" or TR"Aktiv"); r.s:SetTextColor(0.25, 1, 0.25); t.SetState(r, "inset")
          elseif need then r.s:SetText(TR"Fehlt, nötig"); r.s:SetTextColor(1, 0.3, 0.3); t.SetState(r, "inset")
          else r.s:SetText(TR"Fehlt, optional"); r.s:SetTextColor(1, 0.6, 0.2); t.SetState(r, "lock") end
          r.n:SetAlpha(ok and 1 or 0.75); r.w:SetAlpha(ok and 1 or 0.75)
          y = y - 38
        end
        y = y - 8
      end
      Place(hNeed, NEED, true)
      Place(hOpt, OPT, false)
    end)
  end

  -- 6 Fertig
  do
    local p = Page()
    local h = H1(p, TR"Fertig, so findest du alles")
    local items = {
      { TR"Knopf an der Minimap", TR"Klick öffnet ein Menü: grosses Fenster, Pfeil, Mini Fenster, Pause. Oder /klg." },
      { TR"Mini Fenster", TR"Sagt dir den nächsten Schritt. Mit der Maus ziehen zum Verschieben." },
      { TR"Pfeil", TR"Grün geradeaus, gelb seitlich, rot hinter dir. Darunter steht, was dort zu tun ist." },
      { TR"Im Chat: /klg", TR"/klg hilfe öffnet die Hilfe, /klg zeigt alle Befehle." },
    }
    for i, it in ipairs(items) do
      local c = t.Card(p, 353, 70)
      local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
      c:SetPoint("TOPLEFT", h, "BOTTOMLEFT", col * 363, -16 - row * 80)
      c:EnableMouse(false)
      c.Set(it[1], it[2], "", "inset")
    end
    p.next = t.Card(p, 716, 56)
    p.next:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -186)
    p.next:EnableMouse(false)
    -- 19.32 (Navi Chat): Hinweis Flugkarte, nur wenn das Addon noch keinen Flugpunkt kennt (ab Level 10)
    p.fly = t.Card(p, 716, 56)
    p.fly:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -252)
    p.fly:EnableMouse(false)
    p.fly:Hide()
    p:HookScript("OnShow", function()
      if ns.NaviFlugHinweisNoetig and ns.NAVI_FLUG_HINWEIS and ns.NaviFlugHinweisNoetig() then
        p.fly.Set(TR"Flugpunkte", ns.NAVI_FLUG_HINWEIS, "", "inset")
        p.fly:Show()
      else p.fly:Hide() end
    end)
    p:HookScript("OnShow", function()
      local st, names = ns.NextUnlock()
      if choice.mode == "free" then
        p.next.Set(TR"Alles frei: alles ist schon da", TR"Auch Dungeons, Ruf, Berufe, Gold und Route exportieren und laden gehen sofort.", "", "sel")
      elseif st then
        p.next.Set((TR"Als Nächstes, ab Level %d: %s"):format(st.lvl, names), TR"Du bekommst Bescheid, sobald es soweit ist, mit kurzer Erklärung.", "", "sel")
      else
        p.next.Set(TR"Alles ist frei", TR"Viel Spass auf Level 60.", "", "sel")
      end
    end)
  end

  -- Knoepfe unten
  win.later = t.Button(win, TR"Später einrichten", 150, 24)
  win.later:SetPoint("BOTTOMLEFT", 20, 18)
  win.back = t.Button(win, TR"Zurück", 110, 24)
  win.nextB = t.Button(win, TR"Weiter", 130, 24, true)
  win.nextB:SetPoint("BOTTOMRIGHT", -20, 18)
  win.back:SetPoint("RIGHT", win.nextB, "LEFT", -8, 0)
  win.again = t.Button(win, TR"Einrichtung nochmal machen", 200, 24)
  win.again:SetPoint("BOTTOMLEFT", 20, 18)

  -- Seite 2 (Tempo): Weiter erst, wenn die Route berechnet wird oder schon passt
  local function CanNext()
    if step ~= 2 then return true end
    local db = ns.db or {}
    if win.calcPressed then return true end
    return (not win.fresh and db.plan60 and ns.PlanSig and db.plan60.sig == ns.PlanSig()) and true or false
  end
  function win.UpdNext()
    local ok = CanNext()
    win.nextB:SetAlpha(ok and 1 or 0.45)
    if win.nextB.fs then if ok then win.nextB.fs:SetTextColor(1, 1, 1) else win.nextB.fs:SetTextColor(0.6, 0.6, 0.6) end end
  end
  -- Knopf blinken lassen: roter Rahmen, der dreimal aufleuchtet
  local function Blink(b)
    if not b then return end
    if not b.blink then
      local f = CreateFrame("Frame", nil, b)
      f:SetPoint("TOPLEFT", -4, 4); f:SetPoint("BOTTOMRIGHT", 4, -4)
      f:SetFrameLevel((b:GetFrameLevel() or 1) + 5)
      f.lines = {}
      for i, pt in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local tx = f:CreateTexture(nil, "OVERLAY")
        tx:SetColorTexture(1, 0.15, 0.1, 1)
        tx:SetPoint(pt[1]); tx:SetPoint(pt[2])
        if pt[3] then tx:SetHeight(3) else tx:SetWidth(3) end
        f.lines[i] = tx
      end
      f:Hide()
      b.blink = f
    end
    local f = b.blink
    local t0 = GetTime()
    f:Show()
    f:SetScript("OnUpdate", function(self)
      local e = GetTime() - t0
      if e > 2.1 then self:Hide(); self:SetScript("OnUpdate", nil); return end
      self:SetAlpha(0.25 + 0.75 * math.abs(math.sin(e * math.pi * 1.5)))
    end)
  end
  local function Show(n)
    step = math.max(1, math.min(STEPS, n))
    for i, p in ipairs(win.pages) do p:SetShown(i == step) end
    win.stepText:SetText(step < STEPS and (TR"Einrichtung, Schritt %d von %d"):format(step, STEPS - 1) or "")
    win.back:SetShown(step > 1 and step < STEPS)
    win.later:SetShown(step < STEPS)
    win.again:SetShown(step == STEPS)
    win.nextB:SetText(step == 1 and TR"Los gehts" or (step == STEPS - 1 and TR"Fertig" or (step == STEPS and TR"Los, Pfeil folgen" or TR"Weiter")))
    win.UpdNext()
  end
  win.Show2 = Show
  win.nextB:SetScript("OnClick", function()
    if not CanNext() then
      -- noch nicht berechnet: der Knopf Route berechnen blinkt und sagt warum
      Blink(win.calcBtn)
      win.blinkAt = GetTime()
      if win.calcStatus then win.calcStatus:SetText(TR"|cffff5050Zuerst Route berechnen drücken, dann geht es weiter.|r") end
      return
    end
    if step == STEPS - 1 then Apply() end
    if step == STEPS then
      win:Hide()
      -- 20.1b (P13, Sascha 13:28): nach Fertig einmal pro Charakter das grosse Fenster zeigen, mit dem Satz, wie man es
      -- spaeter oeffnet. Die Erklaerung zum Mini Fenster kommt, wenn das grosse Fenster zu ist
      local db = ns.db
      if db and not db.bigShownAuto and ns.ShowBig then
        db.bigShownAuto = true
        C_Timer.After(1, function()
          ns.ShowBig()
          if ns.Print then ns.Print(TR"Das ist das grosse Fenster. Später öffnest du es mit /klg, mit dem Knopf an der Minimap oder im Mini Fenster unter Menü, Grosses Fenster.") end
          local bf = _G.TaurenRouteBig
          if bf and bf.HookScript and not bf.fwSetupHook then
            bf.fwSetupHook = true
            bf:HookScript("OnHide", function()
              if ns.setupHudCoach then ns.setupHudCoach = nil; if ns.HudCoach then C_Timer.After(0.5, ns.HudCoach) end end
            end)
            ns.setupHudCoach = true
          elseif ns.HudCoach then
            C_Timer.After(1, ns.HudCoach)
          end
        end)
      elseif ns.HudCoach then
        C_Timer.After(1, ns.HudCoach)
      end
      return
    end
    Show(step + 1)
  end)
  win.back:SetScript("OnClick", function() Show(step - 1) end)
  win.later:SetScript("OnClick", function()
    if ns.db then ns.db.setupDone = true; ns.db.welcomeDone = true end
    win:Hide()
    if ns.Print then ns.Print(TR"Einrichtung später: im grossen Fenster unter Einstellungen, oder /klg einrichten") end
  end)
  win.again:SetScript("OnClick", function() Show(1) end)
  -- solange die Einrichtung offen ist, rechnet der Regler nicht von selbst (nur der Knopf)
  win:HookScript("OnShow", function() ns.setupOpen = true end)
  win:HookScript("OnHide", function()
    ns.setupOpen = false
    -- 19.31 (Tester Log: Einrichtung nach 2 s mit X zu, danach die ganze Sitzung keine Route): zu ohne fertig machen
    -- heisst wie "Später", die Route rechnet mit den Standard Einstellungen, ein Satz sagt, wo man es aendert
    local db = ns.db
    if db and not db.setupDone then
      db.setupDone = true; db.welcomeDone = true
      if ns.Print then ns.Print(TR"Einrichtung geschlossen: die Route nimmt die Standard Einstellungen. Ändern geht im grossen Fenster unter Einstellungen oder mit /klg einrichten.") end
      if ns.TestLog then ns.TestLog("FENSTER", "Einrichtung ohne Abschluss geschlossen, Route mit Standard Einstellungen") end
      if C_Timer and C_Timer.After then C_Timer.After(1, function() if ns.AutoOpt and not ns.setupOpen then ns.AutoOpt(true) end end) end
    elseif db and step < STEPS and db.plan60 and ns.PlanSig and db.plan60.sig ~= ns.PlanSig() and not ns.planBuilding and ns.Confirm then
      -- 20.1 (P7, Log 12:11 bis 12:14): Einrichtung mit X zu, Tempo oder Fragen geaendert: vorher lief einfach die alte
      -- Route weiter, ohne Hinweis. Jetzt die gleiche Frage wie bei Fertig
      if ns.TestLog then ns.TestLog("FENSTER", "Einrichtung mit Aenderung zu, Frage neu berechnen") end
      C_Timer.After(0.3, function()
        ns.Confirm(TR"Du hast in der Einrichtung etwas geändert. Route neu berechnen? Das Spiel kann kurz ruckeln. Sonst läuft die alte Route weiter.",
          TR"Jetzt berechnen", function() if ns.CalcGo then ns.CalcGo(TR"Einrichtung") end end, TR"Später")
      end)
    end
  end)
end

function ns.ShowSetup()
  if not ns.T then return end
  if not win then Build() end
  local db = ns.db or {}
  choice = {
    goal = db.goal or "normal",
    group = db.eliteSolo and "group" or "solo",
    mode = ns.Mode and ns.Mode() or "guided",
    hud = (db.hudSize == "small" or db.hudSize == "arrow") and "small" or "normal",
    hearth = db.useHearth ~= false,
    look = (db.look == "classic" or db.look == "elvui") and db.look or (T().ElvLoaded() and "elvui" or "classic"),
    books = db.books ~= false,
    profOn = db.profOn ~= false,
  }
  -- jedes Öffnen fängt neu an: Route berechnen muss wieder gedrückt werden.
  -- Erste Einrichtung: eine schon passende Route vom Einloggen zählt nicht, nur der Knopf.
  win.calcPressed, win.blinkAt = nil, nil
  win.fresh = not db.setupDone
  win.Show2(1)
  ns.setupOpen = true
  win:Show()
end
-- alter Name, falls noch irgendwo aufgerufen
ns.ShowWelcome = ns.ShowSetup

local ev = CreateFrame("Frame")
ns.RegEv(ev, "PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
  C_Timer.After(9, function()
    if ns.db and not ns.db.setupDone then ns.ShowSetup() end
  end)
end)
