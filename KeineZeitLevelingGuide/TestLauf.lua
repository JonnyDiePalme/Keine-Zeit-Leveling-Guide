local ADDON, ns = ...
local TR = ns.TR

-- 1.4h (P188, S 11:20 bis 11:49): Test im echten Spiel. Das Zusatz Addon ForeverWegweiser_Test bringt nur den Schalter
-- (Tabelle KZLG_TEST) und das Testpaket (KZLG_TESTPAKET, Datei KZLG_Testpaket.lua, die S in den _Test Ordner legt).
-- Hier laeuft der Test: Minimap Menue "Test starten", nur ausser Kampf, Ergebnis ins Test Log (spiel_wache holt es).
-- Teile (je nach Paket, Standard alle): fenster (alle Seiten des grossen Fensters oeffnen, Frame Baum, Speicher, FPS),
-- navi (Navi nur rechnen, nicht laufen, Zeile NAVITEST je Ziel), daten (naechste 50 Schritte pruefen), events (Event
-- Liste des Clients). 1.4zf (P199): mit dem Schalter Bild bei Meldung je Navi Ziel die Karte mit Weg und ein Bild.
-- 1.4zp (P201): mit dem Schalter auch je Fenster ein Bild und die Karte (Kontinent, Zonen) mit dem Weg; Teil extras
-- (Suche aktiv halten, Pause, Mein Weg, Ausruestung, Teilen, Kanal); M40: Takt Zeit und Rahmen je Seite.
ns.TL = { STEP_S = 0.6, TREE_MAX = 400, TEXT_MAX = 40, DATEN_N = 50, EVENTS_PER_LINE = 60 }
local TL = ns.TL
local running = false

function ns.TestAvailable() return type(_G.KZLG_TEST) == "table" end

local function Log(cat, msg) if ns.TestLog then ns.TestLog(cat, msg) end end
-- 1.4zzf (P216, S 13:42): Fortschritt Balken oberhalb vom Mini Fenster (wo die Hinweise sind), nur solange ein Test laeuft.
-- Name vom Teil, "Schritt 12 von 80" und Balken; Karten Test "Zone 7 von 48, Ziel 15 von 23". Ende: kurz "Test fertig", dann weg.
-- Jede Zeile auch als TESTSCHRITT ins Log (hoechstens je Teil Wechsel), damit Pr den Stand sieht.
-- 1.4zzi (K 21:50, S 21:48): oben ein zweiter Balken "Gesamt x von y (ca n Min)" ueber alle Teile, darunter der Teil Balken
local Bar = { HOLD_S = 3, H = 48 }
ns.TestBarInfo = Bar
function Bar.Mark(jobs, name)
  jobs.marks = jobs.marks or {}
  jobs.marks[#jobs.marks + 1] = { at = #jobs + 1, name = name }
end
function Bar.Make()
  if Bar.f then return Bar.f end
  local f = CreateFrame("Frame", "ForeverWegweiserTestBalken", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(260, Bar.H)
  f:SetFrameStrata("MEDIUM")
  if ns.Skin then pcall(ns.Skin, f, "tooltip") end
  local function SB(y, r, g, b)
    local sb = CreateFrame("StatusBar", nil, f)
    sb:SetPoint("TOPLEFT", 5, y); sb:SetPoint("TOPRIGHT", -5, y); sb:SetHeight(6)
    sb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    sb:SetStatusBarColor(r, g, b)
    sb:SetMinMaxValues(0, 1)
    local bg = sb:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.5)
    return sb
  end
  local fn1 = ns.FontName and ns.FontName("GameFontNormalSmall") or "GameFontNormalSmall"
  local fn2 = ns.FontName and ns.FontName("GameFontHighlightSmall") or "GameFontHighlightSmall"
  f.gtitle = f:CreateFontString(nil, "OVERLAY", fn1)
  f.gtitle:SetPoint("TOPLEFT", 6, -3); f.gtitle:SetJustifyH("LEFT")
  f.gtext = f:CreateFontString(nil, "OVERLAY", fn2)
  f.gtext:SetPoint("TOPRIGHT", -6, -3); f.gtext:SetJustifyH("RIGHT")
  f.gsb = SB(-15, 0.95, 0.75, 0.3)
  f.title = f:CreateFontString(nil, "OVERLAY", fn1)
  f.title:SetPoint("TOPLEFT", 6, -24); f.title:SetJustifyH("LEFT")
  f.text = f:CreateFontString(nil, "OVERLAY", fn2)
  f.text:SetPoint("TOPRIGHT", -6, -24); f.text:SetJustifyH("RIGHT")
  f.sb = SB(-36, 0.5, 0.82, 0.73)
  f:Hide()
  Bar.f = f
  return f
end
function Bar.Show(title, text, frac, gtext, gfrac)
  local f = Bar.Make()
  local hud = _G.TaurenRouteHUD
  f:ClearAllPoints()
  if hud and hud:IsShown() then
    f:SetScale(hud:GetScale() or 1)
    f:SetWidth(hud:GetWidth() or 260)
    f:SetPoint("BOTTOM", hud, "TOP", 0, 2)
  else
    f:SetScale(1)
    f:SetPoint("TOP", UIParent, "TOP", 0, -120)
  end
  f.title:SetText(title or "")
  f.text:SetText(text or "")
  f.sb:SetValue(math.max(0, math.min(1, frac or 0)))
  f.gtitle:SetText(TR"Gesamt")
  f.gtext:SetText(gtext or "")
  f.gsb:SetValue(math.max(0, math.min(1, gfrac or frac or 0)))
  local was = f:IsShown()
  f:Show()
  if not was and ns.NoticeUpdate then pcall(ns.NoticeUpdate) end
end
function Bar.Step(jobs, i)
  local name, at, nxt = TR"Test", 1, #jobs + 1
  for k, m in ipairs(jobs.marks or {}) do
    if m.at <= i then
      name, at = m.name, m.at
      local m2 = jobs.marks[k + 1]
      nxt = m2 and m2.at or (#jobs + 1)
    end
  end
  local lbl = jobs.lbl and jobs.lbl[i]
  local text = lbl or (TR"Schritt %d von %d"):format(i - at + 1, math.max(1, nxt - at))
  -- Gesamt: alle geplanten Schritte (uebersprungene Teile stehen gar nicht in jobs)
  -- 1.4zzq (M57, S 13:06): Rest Zeit aus gelernten Dauern je Teil (Sekunden je Schritt, gemerkt in db.testDur), ohne
  -- gelernten Wert aus dem Schnitt dieses Laufs. Anzeige geglaettet, damit sie nicht springt.
  local now = GetTime()
  if i <= 1 or not jobs.t0 then jobs.t0 = now; jobs.dispRest, jobs.dispT = nil, nil end
  Bar.jobs = jobs
  if jobs.curTeil ~= name then
    Bar.Learn(jobs, i, now)
    jobs.curTeil, jobs.teilAt, jobs.teilT0 = name, i, now
  end
  local gt = (TR"%d von %d"):format(i, #jobs)
  local rest = Bar.Rest(jobs, i, now)
  if rest then
    if jobs.dispRest and jobs.dispT then
      local prev = math.max(0, jobs.dispRest - (now - jobs.dispT))
      rest = prev + (rest - prev) * Bar.SMOOTH
    end
    jobs.dispRest, jobs.dispT = rest, now
    gt = gt .. (rest >= 60 and (TR" (ca %d Min)"):format(math.floor(rest / 60 + 0.5)) or (TR" (ca %d s)"):format(math.floor(rest + 0.5)))
  end
  Bar.Show(name, text, (i - at + 1) / math.max(1, nxt - at), gt, i / math.max(1, #jobs))
  if Bar.lastName ~= name then
    Bar.lastName = name
    Log("TESTSCHRITT", ("teil=%s | schritt=%d | von=%d | gesamt=%d/%d"):format(tostring(name), i - at + 1, math.max(1, nxt - at), i, #jobs))
  end
end
Bar.SMOOTH = 0.25
-- Sekunden je Schritt fuer einen Teil: gelernt, sonst Schnitt dieses Laufs, sonst Takt
local function DurDB()
  local db = ns.db
  if not db then return nil end
  db.testDur = type(db.testDur) == "table" and db.testDur or {}
  return db.testDur
end
function Bar.PerStep(jobs, teil, i, now)
  local t = DurDB()
  local L = t and t[tostring(teil)]
  if type(L) == "table" and tonumber(L.p) then return L.p, true end
  if i and i > 3 and jobs.t0 then return (now - jobs.t0) / (i - 1), false end
  return TL.STEP_S, false
end
-- Rest: offene Schritte je Teil mal Sekunden je Schritt (laufender Teil ab Schritt i)
function Bar.Rest(jobs, i, now)
  local marks = jobs.marks
  if not marks or #marks == 0 then
    if i <= 3 then return nil end
    return (now - jobs.t0) / (i - 1) * (#jobs - i + 1)
  end
  local sum, learned = 0, false
  for k, m in ipairs(marks) do
    local stop = marks[k + 1] and marks[k + 1].at or (#jobs + 1)
    local from = math.max(m.at, i)
    if stop > from then
      local per, l = Bar.PerStep(jobs, m.name, i, now)
      if l then learned = true end
      sum = sum + per * (stop - from)
    end
  end
  if not learned and i <= 3 then return nil end
  return sum
end
-- Teil fertig: echte Dauer je Schritt merken (gleitend, neuer Lauf zaehlt 40 Prozent)
function Bar.Learn(jobs, i, now)
  local teil, at, t0 = jobs.curTeil, jobs.teilAt, jobs.teilT0
  if not (teil and at and t0) then return end
  local n = i - at
  if n < 1 then return end
  local per = (now - t0) / n
  local t = DurDB()
  if not t then return end
  local key = tostring(teil)
  local L = t[key]
  if type(L) == "table" and tonumber(L.p) then L.p = L.p * 0.6 + per * 0.4; L.n = (tonumber(L.n) or 1) + 1
  else t[key] = { p = per, n = 1 } end
  Log("TESTDAUER", ("teil=%s | schritte=%d | s_je_schritt=%.2f | gelernt=%.2f"):format(key, n, per, t[key].p))
end
function Bar.Done(msg)
  local f = Bar.f
  Bar.lastName = nil
  -- 1.4zzq (M57): letzten Teil nur bei normalem Ende lernen (Abbruch waere zu kurz)
  local jobs = Bar.jobs
  Bar.jobs = nil
  if jobs and not msg then Bar.Learn(jobs, #jobs + 1, GetTime()) end
  if jobs then jobs.curTeil = nil end
  if not f then return end
  Bar.Show(msg or TR"Test fertig", "", 1, "", 1)
  local tok = {}
  Bar.tok = tok
  C_Timer.After(Bar.HOLD_S, function()
    if Bar.tok ~= tok then return end
    f:Hide()
    if ns.NoticeUpdate then pcall(ns.NoticeUpdate) end
  end)
end
function ns.TestBarAnchor()
  local f = Bar.f
  return f and f:IsShown() and f or nil
end
local function Paket() return type(_G.KZLG_TESTPAKET) == "table" and _G.KZLG_TESTPAKET or {} end
local function Want(p, k) return p[k] ~= false end

local function Mem()
  if UpdateAddOnMemoryUsage then pcall(UpdateAddOnMemoryUsage) end
  local get = (C_AddOns and C_AddOns.GetAddOnMemoryUsage) or GetAddOnMemoryUsage
  local ok, kb = pcall(get, ADDON)
  return ok and kb or 0
end

-- Frame Baum: Name oder Art, Lage, Groesse, Text (gekuerzt), nur sichtbare
local function Tree(f, depth, out, path)
  if #out >= TL.TREE_MAX or not (f and f.IsVisible and f:IsVisible()) then return end
  local nm = (f.GetName and f:GetName()) or (f.GetObjectType and f:GetObjectType()) or "?"
  local l, b, w, h = f.GetRect and f:GetRect()
  local txt = ""
  if f.GetText then local ok, t = pcall(f.GetText, f); if ok and type(t) == "string" and t ~= "" then txt = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("\n", " ") end end
  if #txt > TL.TEXT_MAX then txt = txt:sub(1, TL.TEXT_MAX):gsub("[\192-\255][\128-\191]*$", "") .. ".." end
  out[#out + 1] = ("%s%s %d,%d %dx%d%s"):format(path, nm, math.floor(l or 0), math.floor(b or 0), math.floor(w or 0), math.floor(h or 0), txt ~= "" and (" '" .. txt .. "'") or "")
  if depth <= 0 then return end
  if f.GetRegions then
    for _, r in ipairs({ f:GetRegions() }) do
      if r.GetObjectType and r:GetObjectType() == "FontString" and r:IsVisible() then
        local ok, t = pcall(r.GetText, r)
        if ok and type(t) == "string" and t ~= "" and #out < TL.TREE_MAX then
          t = t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("\n", " ")
          if #t > TL.TEXT_MAX then t = t:sub(1, TL.TEXT_MAX):gsub("[\192-\255][\128-\191]*$", "") .. ".." end
          out[#out + 1] = path .. "  text '" .. t .. "'"
        end
      end
    end
  end
  if f.GetChildren then for _, c in ipairs({ f:GetChildren() }) do Tree(c, depth - 1, out, path .. "  ") end end
end

-- 1.4zp (M40, S 22:10: fps faellt mit jedem Fenster von 76 auf 35): alle Rahmen unter f zaehlen, auch versteckte. Waechst
-- die Zahl von Seite zu Seite, baut eine Seite bei jedem Fuellen neue Rahmen (dann ist das die Ursache)
local function Count(f, n)
  n = (n or 0) + 1
  if f and f.GetChildren then for _, c in ipairs({ f:GetChildren() }) do n = Count(c, n) end end
  return n
end
local function Now() return debugprofilestop and debugprofilestop() or 0 end
local function Shot(what) if ns.ShotOn and ns.ShotOn() and ns.TakeShot then ns.TakeShot(what, 0.15) end end
-- Kontinent einer Karte (Kartentyp 2), fuer die Bilder der Weltkarte
local function Continent(map)
  local n = 0
  while map and n < 8 do
    local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(map)
    if not mi then return nil end
    if mi.mapType == 2 then return map end
    map, n = mi.parentMapID, n + 1
  end
end
-- 1.4zu (P201, K 01:50: Kontinent Bild im kleinen Karten Fenster, Linie kaum zu sehen): fuer die Karten Bilder gross, danach
-- wieder wie vorher (nur wenn wir sie gross gemacht haben)
local mapMax
local function MapOpen(map, big)
  local W = WorldMapFrame
  if W and not W:IsShown() and ToggleWorldMap then ToggleWorldMap() end
  if big and W and W.IsMaximized and W.Maximize and not W:IsMaximized() then
    if pcall(W.Maximize, W) then mapMax = true end
  end
  if W and W.SetMapID then pcall(W.SetMapID, W, map) end
end
local function MapClose()
  local W = WorldMapFrame
  if mapMax and W and W.Minimize then pcall(W.Minimize, W) end
  mapMax = nil
  if W and W:IsShown() and ToggleWorldMap then ToggleWorldMap() end
end

local function Jobs(p)
  local jobs = {}
  local shots = ns.ShotOn and ns.ShotOn()
  -- Fenster: alle Seiten des grossen Fensters, dazu Mini Fenster und Pfeil
  Bar.Mark(jobs, "fenster")
  if Want(p, "fenster") then
    local bigPrev
    jobs[#jobs + 1] = function()
      local b = _G.TaurenRouteBig
      bigPrev = { shown = b and b:IsShown(), view = ns.BigView and ns.BigView() }
      Log("TEST", ("Fenster Start: %d fps, Speicher %d KB"):format(math.floor(GetFramerate() or 0), math.floor(Mem())))
    end
    -- 1.4zp (P201): dazu Start, Route, Berufe, Dungeons, Einstellungen
    for _, v in ipairs(p.seiten or { "overview", "opt", "route", "plan", "weg", "stats", "perf", "statgold", "gear", "books", "rep", "berufe", "dungeons", "raids", "pvp", "help", "detail", "farm", "gold", "set" }) do
      jobs[#jobs + 1] = function()
        local m0, t0 = Mem(), Now()
        local ok, err = pcall(ns.ShowBig, v)
        local ms = Now() - t0
        -- 1.4zp (M40): was kostet der Takt auf dieser Seite (RefreshBig jede Sekunde), und wie viele Rahmen gibt es jetzt
        local t1 = Now()
        for _ = 1, 5 do pcall(ns.RefreshBig, "tick") end
        local tick = (Now() - t1) / 5
        local out = {}
        if ok then Tree(_G.TaurenRouteBig, 6, out, "") end
        Log("TEST", ("Fenster %s: %s, %d ms, Speicher +%d KB, %d fps, %d Elemente, Takt %.1f ms, Rahmen %d, Seite %s"):format(v, ok and "ok" or ("Fehler " .. tostring(err)),
          math.floor(ms), math.floor(Mem() - m0), math.floor(GetFramerate() or 0), #out, tick, Count(_G.TaurenRouteBig), tostring(ns.BigView and ns.BigView())))
        if p.baum ~= false then for _, l in ipairs(out) do Log("TESTBAUM", v .. " | " .. l) end end
        Shot("Fenster " .. v)
      end
      -- 1.4zu (P201, K 01:50: Bilder in derselben Sekunde ueberschrieben sich): zwischen zwei Bildern mindestens 1.2 s
      if shots then jobs[#jobs + 1] = function() end end
    end
    -- 1.4zp (M40): Fenster zu, kurz warten, fps ohne Fenster (faellt es nicht zurueck, laeuft etwas weiter)
    jobs[#jobs + 1] = function() if _G.TaurenRouteBig then _G.TaurenRouteBig:Hide() end end
    jobs[#jobs + 1] = function()
      Log("TEST", ("Fenster zu: %d fps, Speicher %d KB, Rahmen %d"):format(math.floor(GetFramerate() or 0), math.floor(Mem()), Count(_G.TaurenRouteBig)))
      for _, nm in ipairs({ "TaurenRouteHUD", "TaurenRouteArrow", "ForeverWegweiserReise", "TaurenRouteQuestItemBar" }) do
        local out = {}
        Tree(_G[nm], 3, out, "")
        for _, l in ipairs(out) do Log("TESTBAUM", nm .. " | " .. l) end
      end
    end
    -- 1.4zt (M40): 5 s warten, dann fps und Speicher; dann einmal aufraeumen (collectgarbage) und nochmal. Faellt der Speicher
    -- stark und kommen die fps zurueck, war es Muell (Test selbst oder Seiten), sonst laeuft etwas weiter
    for _ = 1, 8 do jobs[#jobs + 1] = function() end end
    local gc0
    jobs[#jobs + 1] = function()
      gc0 = collectgarbage("count")
      Log("TEST", ("Fenster zu nach 5 s: %d fps, Addon %d KB, Lua gesamt %d KB"):format(math.floor(GetFramerate() or 0), math.floor(Mem()),
        math.floor(gc0)))
      collectgarbage("collect")
    end
    for _ = 1, 4 do jobs[#jobs + 1] = function() end end
    jobs[#jobs + 1] = function()
      local gc1 = collectgarbage("count")
      Log("TEST", ("Nach Aufraeumen: %d fps, Addon %d KB, Lua gesamt %d KB (frei %d KB)"):format(math.floor(GetFramerate() or 0), math.floor(Mem()),
        math.floor(gc1), math.floor((gc0 or gc1) - gc1)))
    end
    -- 1.4zp (P201): Mini Fenster mit Balken und Pfeil je ein Bild (der Pfeil kurz an, wenn er aus war)
    if shots then
      local arrowWas
      jobs[#jobs + 1] = function()
        local a = _G.TaurenRouteArrow
        arrowWas = a and a:IsShown()
        if a and not arrowWas and not (ns.db and ns.db.paused) then a:Show() end
        Shot("Mini Fenster und Pfeil mit Balken")
      end
      jobs[#jobs + 1] = function() end
      jobs[#jobs + 1] = function()
        local a = _G.TaurenRouteArrow
        if a and not arrowWas then a:Hide() end
        if _G.TaxiFrame and _G.TaxiFrame:IsShown() then Shot("Flugkarte") else Log("TEST", "Flugkarte: nur beim Flugmeister offen, kein Bild") end
      end
    end
    jobs[#jobs + 1] = function()
      if bigPrev and bigPrev.shown then pcall(ns.ShowBig, bigPrev.view) end
      bigPrev = nil
    end
  end
  -- 1.4zp (P201): ganzer Weg auf der Karte, Weltkarte je Kontinent und die Zonen der naechsten Schritte (mit Linie und Nummern)
  Bar.Mark(jobs, "karte")
  if shots and Want(p, "karte") then
    local o = ns.db and ns.db.opt
    local i0 = o and (o.idx or 1) or 1
    local zones, conts, seenZ, seenC = {}, {}, {}, {}
    for k = i0, math.min(#(o and o.steps or {}), i0 + (p.karte_n or 30) - 1) do
      local m = o.steps[k].map
      if m and not seenZ[m] and #zones < (p.zonen_max or 4) then seenZ[m] = true; zones[#zones + 1] = m end
      local c = m and Continent(m)
      if c and not seenC[c] then seenC[c] = true; conts[#conts + 1] = c end
    end
    local what = o and (o.dungeonRoute and ("Dungeon Tour " .. tostring(o.dungeonName)) or "Leveling Route") or "keine Route"
    Log("TEST", ("Karte: %s, Schritt %d, Kontinente %d, Zonen %d"):format(what, i0, #conts, #zones))
    local list = {}
    for _, c in ipairs(conts) do list[#list + 1] = { c, "Weltkarte Kontinent" } end
    for _, z in ipairs(zones) do list[#list + 1] = { z, "Zone" } end
    for _, e in ipairs(list) do
      jobs[#jobs + 1] = function()
        -- 1.4zv (P201): unsere Linie fuer das Bild dicker, nach dem Bild wieder normal
        ns.lineBoost = 2.5
        MapOpen(e[1], true)
        if ns.Draw then pcall(ns.Draw) end
      end
      jobs[#jobs + 1] = function()
        local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(e[1])
        Shot(("Karte %s %s %s (%s)"):format(e[2], tostring(e[1]), tostring(mi and mi.name or "?"), what))
      end
      jobs[#jobs + 1] = function() end
    end
    if #list > 0 then jobs[#jobs + 1] = function() ns.lineBoost = nil; MapClose() end end
  end
  -- 1.4zp (P201): weitere Teile, jeweils Zustand vorher und nachher ins Log, danach wie vorher
  Bar.Mark(jobs, "extras")
  if Want(p, "extras") then
    -- P200 Suche aktiv halten (1.4zs, K 00:55: wirklich pruefen): Haken kurz an, die Suche im Spiel aus, Pruefung
    -- ausloesen, nach CHECK_S schauen, ob sie wieder an ist. Danach Haken und Suche wie vorher
    local tp
    jobs[#jobs + 1] = function()
      -- 1.4zzb (K 05:18): auf dem Test Char (Paket mit profil) braucht dieser Teil den echten Char, darum nur melden
      if type(p.profil) == "table" then Log("TEST", "Suche aktiv halten: uebersprungen (Test Char)"); return end
      Log("TEST", ("Suche aktiv halten vorher: %s"):format(tostring(ns.ProfTrackState and ns.ProfTrackState() or "?")))
      -- 1.4zz (K 04:56): alle Eintraege der Minimap Suche, damit man sieht, wie Forever sie fuehrt
      for _, l in ipairs(ns.ProfTrackDump and ns.ProfTrackDump() or {}) do Log("TESTSUCHE", l) end
      if not (ns.ProfTrackRaw and ns.ProfTrackCheck and ns.db and ns.KEEP_TRACK) then return end
      -- 1.4zx (K 03:36): alles vorher merken (nur lesen), am Ende immer genau so zurueck
      tp = { hook = ns.db.keepTrack, was = {} }
      for k in pairs(ns.KEEP_TRACK.SPELL) do tp.was[k] = ns.ProfTrackRaw(k, nil) end
      local key
      for _, k in ipairs({ "mine", "herb" }) do if tp.was[k] ~= nil then key = k; break end end
      if not key then Log("TEST", "Suche aktiv halten: keine Suche in der Minimap Liste, Test geht nicht"); return end
      tp.key = key
      -- 1.4zze (K 13:25, Pr BER 13:10 P200 ROT: Test stellte die Mineraliensuche aus und bekam sie nicht wieder an): eine
      -- Zauber Suche laesst sich im Spiel nur aus, aber nicht wieder an schalten (SetTracking geht nur in eine Richtung, an
      -- braucht den Zauber per Klick). Der Test schaltet darum NICHTS mehr aus, er prueft nur den Stand und die Pruefung selbst
      ns.db.keepTrack = key
      pcall(ns.ProfTrackCheck, "Test")
    end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function()
      if tp then
        if tp.key then
          local on = ns.ProfTrackRaw(tp.key, nil)
          Log("TEST", ("Suche aktiv halten Test: %s vorher %s, nach der Pruefung %s (%s)"):format(tp.key, tp.was[tp.key] and "an" or "aus", on and "an" or "aus",
            (on == tp.was[tp.key] or on) and "ok" or "ROT"))
        end
        ns.db.keepTrack = tp.hook
        -- nur zurueck stellen, was sich wirklich geaendert hat; an geht nur per Klick, dann Hinweis im Chat
        for k, v in pairs(tp.was) do
          if v ~= nil and ns.ProfTrackRaw(k, nil) ~= v then
            ns.ProfTrackRaw(k, v)
            if v and not ns.ProfTrackRaw(k, nil) then ns.Print((TR"Test: %s ist aus, bitte selbst wieder anmachen (Symbol an der Minimap)."):format(k == "mine" and TR"Mineraliensuche" or TR"Kräutersuche")) end
          end
        end
        tp = nil
      end
      Log("TEST", ("Suche aktiv halten nachher (zurueck): %s"):format(tostring(ns.ProfTrackState and ns.ProfTrackState() or "?")))
    end
    -- Pause und Weitermachen: Knoepfe im Mini Fenster und die Balken
    local pausePrev
    jobs[#jobs + 1] = function()
      pausePrev = ns.db and ns.db.paused
      if ns.SetPaused then ns.SetPaused(not pausePrev) end
    end
    local function PauseLog(tag)
      local h = ns.hud or _G.TaurenRouteHUD
      local bb, bn = h and h.bBack, h and h.bNext
      local out = {}
      Tree(_G.ForeverWegweiserReise, 2, out, "")
      Log("TEST", ("Pause %s: pausiert %s, Zurueck %s, Weiter %s, Balken Zeilen %d"):format(tag, tostring(ns.db and ns.db.paused),
        tostring(bb and bb:IsShown()), tostring(bn and bn:IsShown()), #out))
      Shot("Mini Fenster " .. tag)
    end
    jobs[#jobs + 1] = function() PauseLog("umgestellt") end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function() if ns.SetPaused then ns.SetPaused(pausePrev) end end
    jobs[#jobs + 1] = function() PauseLog("zurueck") end
    -- Mein Weg: Figur steht still (zwei Messungen 2 s auseinander)
    local wegPrev, w1
    jobs[#jobs + 1] = function()
      local b = _G.TaurenRouteBig
      wegPrev = { shown = b and b:IsShown(), view = ns.BigView and ns.BigView() }
      pcall(ns.ShowBig, "weg")
    end
    jobs[#jobs + 1] = function() w1 = { ns.WegFigurPos and ns.WegFigurPos() } end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function()
      local w2 = { ns.WegFigurPos and ns.WegFigurPos() }
      local still = w1 and w1[1] == w2[1]
      Log("TEST", ("Mein Weg Figur: vorher %s, nachher %s, Ziel %s, %s"):format(tostring(w1 and w1[1]), tostring(w2[1]), tostring(w2[2]), still and "still" or "bewegt"))
      -- Ausruestung Liste
      pcall(ns.ShowBig, "gear")
    end
    jobs[#jobs + 1] = function() end
    jobs[#jobs + 1] = function()
      local n = 0
      for _ in pairs(ns.gearQuests or {}) do n = n + 1 end
      Log("TEST", ("Ausruestung Liste: %d Quests, Grund leer: %s"):format(n, tostring(ns.gearScanWhy or "-")))
      if wegPrev and wegPrev.shown then pcall(ns.ShowBig, wegPrev.view) elseif _G.TaurenRouteBig then _G.TaurenRouteBig:Hide() end
      -- Teilen und Kanal: 1.4zs (K 00:55, S war in einer Gruppe, der Test teilte wirklich): nie echt teilen, nur pruefen
      local grp = IsInGroup and IsInGroup()
      local reg = C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered and C_ChatInfo.IsAddonMessagePrefixRegistered("TaurenRt")
      Log("TEST", ("Teilen: Gruppe %s, Funktion %s, nur geprueft (Test teilt nie) | Kanal: Addon Kanal %s"):format(tostring(grp),
        ns.ShareRouteQuests and "da" or "fehlt", reg and "angemeldet" or "nicht angemeldet"))
      -- 1.4zzf (M49, M50, P211): die drei Teilen Knoepfe nur auf Dasein und grau/aktiv pruefen, nie klicken
      local function St(b)
        if not b then return "fehlt" end
        local en = b.IsEnabled and b:IsEnabled()
        local ok = (en and true or false) == (grp and true or false)
        return ("da %s%s"):format(en and "aktiv" or "grau", ok and "" or " FALSCH")
      end
      local menuB
      local hud = _G.TaurenRouteHUD
      for _, r in ipairs(hud and hud.ext and hud.ext.rows or {}) do
        if r.def and r.def[1] == TR"Mit Gruppe teilen" and not r.head then menuB = r end
      end
      local menuSt = menuB and (menuB.def.grey and ((menuB.def.grey() and "grau" or "aktiv") .. (((not menuB.def.grey()) == (grp and true or false)) and "" or " FALSCH")) or "ohne grau") or "fehlt"
      local pick = _G.TaurenRouteLogPick
      local pickPrev = pick and pick:IsShown()
      if ns.TourQuestLog and not pickPrev then pcall(ns.TourQuestLog) end
      pick = _G.TaurenRouteLogPick
      local pickSt = St(pick and pick.share)
      if pick and not pickPrev then pick:Hide() end
      Log("TEST", ("Teilen Knoepfe: Gruppe %s | Menue %s | Questlog Route %s | Dungeon %s (nur geprueft, nie geklickt)"):format(tostring(grp and true or false),
        menuSt, pick and pickSt or "Fenster nicht offen (Log leer?)", ns.dungeonShareBtn and St(ns.dungeonShareBtn) or "Seite noch nicht gebaut"))
    end
  end
  -- Navi: nur rechnen. Zeile wie Pr will: NAVITEST | nr | teile= | zeit= | punkte= | netz= | fehler=
  Bar.Mark(jobs, "navi")
  if Want(p, "navi") then
    local shotPrev
    for i, z in ipairs(p.navi or {}) do
      -- 1.4k: Ziel als Tabelle mit Namen ({ nr, name, map, x, y } Felder) oder als Liste { nr, name, map, x, y } (Pr Paket)
      z = { nr = z.nr or z[1], name = z.name or z[2], map = z.map or z[3], x = z.x or z[4], y = z.y or z[5] }
      jobs[#jobs + 1] = function()
        local nr = z.nr or i
        if not (z.map and z.x and z.y and ns.NaviPlan) then
          Log("NAVITEST", ("%s | teile= | zeit= | punkte= | netz= | fehler=kein Ziel (%s)"):format(tostring(nr), tostring(z.name))); return
        end
        local t0 = debugprofilestop and debugprofilestop() or 0
        local ok, nv = pcall(ns.NaviPlan, z.map, z.x, z.y, z.name)
        local ms = (debugprofilestop and debugprofilestop() or 0) - t0
        if not (ok and type(nv) == "table" and nv.legs) then
          Log("NAVITEST", ("%s | teile= | zeit= | punkte= | netz= | fehler=%s | ziel=%s | ms=%d"):format(tostring(nr), ok and "kein Weg" or tostring(nv), tostring(z.name), math.floor(ms))); return
        end
        local parts, sec, pts, net = {}, 0, 0, false
        local NAME = { walk = "Lauf", fly = "Flug", ride = "Fahrt", hearth = "Ruhestein", portal = "Teleport" }
        for _, lg in ipairs(nv.legs) do
          parts[#parts + 1] = NAME[lg.kind] or tostring(lg.kind)
          sec = sec + (lg.sec or 0)
          local n = lg.pc and lg.pc.pts and #lg.pc.pts or 0
          if n > 0 then net = true end
          pts = pts + math.max(1, n)
        end
        Log("NAVITEST", ("%s | teile=%s | zeit=%d | punkte=%d | netz=%s | fehler= | ziel=%s | ms=%d"):format(tostring(nr), table.concat(parts, ","),
          math.floor(sec), pts, net and "ja" or "luft", tostring(z.name), math.floor(ms)))
      end
      -- 1.4zf (P199): Navi starten, Karte vom Ziel mit Weg offen, Bild, dann wieder zu (nur mit Schalter Bild bei Meldung)
      if ns.ShotOn and ns.ShotOn() then
        jobs[#jobs + 1] = function()
          if not (z.map and z.x and z.y and ns.NaviTo) then return end
          shotPrev = shotPrev or { had = ns.navi ~= nil, dest = ns.navi and ns.navi.dest }
          ns.NaviTo(z.map, z.x, z.y, z.name)
          if WorldMapFrame and not WorldMapFrame:IsShown() and ToggleWorldMap then ToggleWorldMap() end
          if WorldMapFrame and WorldMapFrame.SetMapID then pcall(WorldMapFrame.SetMapID, WorldMapFrame, z.map) end
        end
        jobs[#jobs + 1] = function() ns.TakeShot(("Navi Test %s %s"):format(tostring(z.nr or i), tostring(z.name)), 0.1) end
        jobs[#jobs + 1] = function()
          if WorldMapFrame and WorldMapFrame:IsShown() and ToggleWorldMap then ToggleWorldMap() end
          if ns.NaviHide then ns.NaviHide(true) end
        end
      end
    end
    -- 1.4zf (P199): dein Navi von vorher wieder herstellen
    jobs[#jobs + 1] = function()
      if shotPrev and shotPrev.had and shotPrev.dest and ns.NaviTo then
        local d = shotPrev.dest
        pcall(ns.NaviTo, d.map, d.x, d.y, d.name)
      end
      shotPrev = nil
    end
  end
  -- Daten: 1.4zza (P209, S 05:19 Ja): alle Schritte der Route (vorher die naechsten 50), Paket daten_n begrenzt. Je Fund eine
  -- Zeile TESTDATEN "FUND art | Schritt | Quest | ...", am Ende Summe je Art. Prueft: Ort, Quest in Questie, Geber und Abgabe NPC
  -- mit Spawns, Vorquests in Questie, Ziel Gegner mit Spawns
  Bar.Mark(jobs, "daten")
  if Want(p, "daten") then
    jobs[#jobs + 1] = function()
      local o = ns.db and ns.db.opt
      local steps = o and o.steps or {}
      local i0 = o and (o.idx or 1) or 1
      local iN = math.min(#steps, i0 + (tonumber(p.daten_n) or 1000) - 1)
      local QDB = ns.QDBAccess and select(1, ns.QDBAccess())
      local function Q(id, k) if not (QDB and QDB.QueryQuestSingle) then return nil end local ok, v = pcall(QDB.QueryQuestSingle, id, k); return ok and v or nil end
      local function NSp(id)
        if not (QDB and QDB.QueryNPCSingle) then return true end
        local ok, v = pcall(QDB.QueryNPCSingle, id, "spawns")
        return ok and type(v) == "table" and next(v) ~= nil
      end
      local sum, n, seen = {}, 0, {}
      local function Fund(art, k, a, extra)
        sum[art] = (sum[art] or 0) + 1
        if sum[art] <= 40 then Log("TESTDATEN", ("FUND %s | Schritt %d | Quest %s %s%s"):format(art, k, tostring(a and a.qid or "-"), tostring(a and a.quest or ""), extra and (" | " .. extra) or "")) end
      end
      for k = i0, iN do
        local s = steps[k]
        n = n + 1
        if not (s.map and s.x and s.y) then Fund("ohne_ort", k, s.acts and s.acts[1]) end
        for _, a in ipairs(s.acts or {}) do
          local q = a.qid
          if q and QDB and not seen[a.k .. q] then
            seen[a.k .. q] = true
            if not Q(q, "name") then Fund("quest_fehlt", k, a)
            else
              if a.k == "A" then
                local sb = Q(q, "startedBy")
                local npc = type(sb) == "table" and type(sb[1]) == "table" and sb[1][1]
                local obj = type(sb) == "table" and type(sb[2]) == "table" and sb[2][1]
                if not (npc or obj) then Fund("geber_fehlt", k, a) elseif npc and not NSp(npc) then Fund("geber_ohne_spawn", k, a, "NPC " .. npc) end
                for _, pid in ipairs(type(Q(q, "preQuestGroup")) == "table" and Q(q, "preQuestGroup") or {}) do
                  if type(pid) == "number" and pid > 0 and not Q(pid, "name") then Fund("vorquest_fehlt", k, a, "Vorquest " .. pid) end
                end
              elseif a.k == "T" then
                local fb = Q(q, "finishedBy")
                local npc = type(fb) == "table" and type(fb[1]) == "table" and fb[1][1]
                local obj = type(fb) == "table" and type(fb[2]) == "table" and fb[2][1]
                if not (npc or obj) then Fund("abgabe_fehlt", k, a) elseif npc and not NSp(npc) then Fund("abgabe_ohne_spawn", k, a, "NPC " .. npc) end
              elseif a.k == "O" then
                for _, npc in ipairs(type(a.npcs) == "table" and a.npcs or {}) do
                  if type(npc) == "number" and not NSp(npc) then Fund("gegner_ohne_spawn", k, a, "NPC " .. npc) end
                end
              end
            end
          end
        end
      end
      local t = {}
      for art, c in pairs(sum) do t[#t + 1] = art .. " " .. c end
      table.sort(t)
      Log("TEST", ("Daten %d Schritte (ab %d): %s"):format(n, i0, #t > 0 and table.concat(t, ", ") or "keine Funde"))
    end
  end
  -- 1.4zze (P211): Funktionen einmal benutzen, danach wie vorher
  Bar.Mark(jobs, "funktionen")
  if Want(p, "funktionen") and ns.FunktionJobs then ns.FunktionJobs(p, jobs) end
  -- 1.4zzb (P206): Szenarien (nur rechnen, nichts Echtes aendern)
  Bar.Mark(jobs, "szenarien")
  if Want(p, "szenario") and type(p.szenarien) == "table" and ns.SzenarioJobs then
    if type(p.profil) == "table" then
      for _, sc in ipairs(p.szenarien) do if type(sc) == "table" and not sc.level then sc.level = p.profil.level end end
    end
    ns.SzenarioJobs(p.szenarien, jobs, p)
  end
  -- Events des Clients (ersetzt den blizzard_api Export, events_pruefen liest es)
  Bar.Mark(jobs, "events")
  if Want(p, "events") then
    jobs[#jobs + 1] = function()
      local okL = pcall(function()
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then load("Blizzard_APIDocumentationGenerated") end
      end)
      local list = {}
      local AD = _G.APIDocumentation
      if AD and type(AD.systems) == "table" then
        for _, sys in ipairs(AD.systems) do
          for _, e in ipairs(sys.Events or {}) do if e.LiteralName then list[#list + 1] = e.LiteralName end end
        end
      end
      table.sort(list)
      Log("TEST", ("Events: %d aus der API Doku%s"):format(#list, okL and "" or " (Doku nicht ladbar)"))
      for k = 1, #list, TL.EVENTS_PER_LINE do
        Log("EVENTS", table.concat(list, ",", k, math.min(#list, k + TL.EVENTS_PER_LINE - 1)))
      end
    end
  end
  return jobs
end

function ns.TestStart()
  if running then ns.Print(TR"Test läuft schon."); return end
  if InCombatLockdown and InCombatLockdown() then ns.Print(TR"Test nur ausserhalb vom Kampf."); return end
  if not (ns.TestLogActive and ns.TestLogActive()) then ns.Print(TR"Für den Test bitte zuerst das Log starten (Minimap Menü)."); return end
  local p = Paket()
  if ns.MigrationLine then pcall(ns.MigrationLine) end
  local jobs = Jobs(p)
  running = true
  Log("TEST", ("Start: Paket %s, %d Teile"):format(tostring(p.stand or "ohne"), #jobs))
  ns.Print((TR"Test läuft, %d Teile. Bitte nicht kämpfen."):format(#jobs))
  local i = 0
  local function Next()
    if InCombatLockdown and InCombatLockdown() then
      Log("TEST", ("Abbruch: Kampf nach %d von %d"):format(i, #jobs)); running = false; ns.lineBoost, ns.simKnownFP = nil, nil; if mapMax then MapClose() end; ns.Print(TR"Test abgebrochen (Kampf)."); Bar.Done(TR"Test abgebrochen (Kampf)"); return
    end
    i = i + 1
    local job = jobs[i]
    if not job then
      running = false
      ns.lineBoost, ns.simKnownFP = nil, nil
      Log("TEST", "Ende")
      ns.Print(TR"Test fertig, Ergebnis steht im Log.")
      Bar.Done()
      return
    end
    Bar.Step(jobs, i)
    local ok, err = pcall(job)
    if not ok then Log("TEST", ("Teil %d Fehler: %s"):format(i, tostring(err))) end
    -- 1.4zzb: Warte Teile, die nichts mehr zu tun haben, gleich ueberspringen
    C_Timer.After((ok and err == "skip") and 0 or TL.STEP_S, Next)
  end
  C_Timer.After(0.2, Next)
end

------------------------------------------------------------
-- 1.4zy (P203, S 03:11 und 03:14 Ja, K 03:16): Karten Test. Eigener Lauf (Minimap Menue "Karten Test"), nur ausser Kampf.
-- Zone fuer Zone aus KZLG_TESTPAKET.karte_navi = { zonen = { 1411, ... }, raster = 4, punkte = { [1418] = { {x, y, "Name"} } },
-- start = { [1418] = {x, y} }, max_ms = 300 }. Je Zone ein Raster Ziele (Rand 10 %) plus die festen Punkte, je Ziel nur
-- rechnen (ns.NaviPlan ab dem Start Punkt der Zone, ohne Laufen), Zeile KARTENTEST. Mit Bild bei Meldung je Zone ein Bild der
-- Zonen Karte mit dem Ziel mit dem groessten Umweg. Abbruch bei Kampf, der naechste Start macht ab dieser Zone weiter.
------------------------------------------------------------
local ktRunning = false
function ns.KartenTestStart(hier)
  if ktRunning or running then ns.Print(TR"Test läuft schon."); return end
  if InCombatLockdown and InCombatLockdown() then ns.Print(TR"Test nur ausserhalb vom Kampf."); return end
  if not (ns.TestLogActive and ns.TestLogActive()) then ns.Print(TR"Für den Test bitte zuerst das Log starten (Minimap Menü)."); return end
  -- 1.4zzh (P212 Punkt 2): hier = eigene Liste vom Knopf "Hier pruefen" (eine Zone, Start = du), ohne Fortsetzen
  local kn = hier or Paket().karte_navi
  if type(kn) ~= "table" or type(kn.zonen) ~= "table" or #kn.zonen == 0 then ns.Print(TR"Karten Test: im Testpaket fehlt karte_navi."); return end
  if not (ns.NaviPlan and ns.WorldDistXY) then return end
  local db = ns.db
  local from = 1
  local kt = db and db.kartenTest
  if not hier and type(kt) == "table" and kt.zi and kt.stand == Paket().stand and kt.zi <= #kn.zonen then from = kt.zi end
  -- 1.4zze (Pr INF 11:55): raster = 0 erlaubt (nur die festen Punkte)
  local n = math.max(0, math.min(8, tonumber(kn.raster) or 4))
  local maxMs = tonumber(kn.max_ms) or 300
  local shots = ns.ShotOn and ns.ShotOn()
  local prev = { had = ns.navi ~= nil, dest = ns.navi and ns.navi.dest }
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  local jobs = { lbl = {} }
  Bar.Mark(jobs, TR"Karten Test")
  for zi = from, #kn.zonen do
    local zone = kn.zonen[zi]
    local list = {}
    for i = 1, n do
      for j = 1, n do list[#list + 1] = { 0.1 + 0.8 * (i - 0.5) / n, 0.1 + 0.8 * (j - 0.5) / n, ("Raster %d,%d"):format(i, j) } end
    end
    for _, pt in ipairs(type(kn.punkte) == "table" and kn.punkte[zone] or {}) do
      if type(pt) == "table" and pt[1] and pt[2] then list[#list + 1] = { pt[1], pt[2], tostring(pt[3] or "Punkt") } end
    end
    -- 1.4zze (Pr INF 11:55): start[zone] darf eine Liste sein { {x, y, "Name"}, ... }, dann alle Ziele je Start
    local st = type(kn.start) == "table" and kn.start[zone] or nil
    local starts = (type(st) == "table" and type(st[1]) == "table") and st or { { st and st[1] or 0.5, st and st[2] or 0.5, "Start" } }
    local worst
    local sx0, sy0 = starts[1][1], starts[1][2]
    jobs[#jobs + 1] = function() worst = nil end
    for si, stt in ipairs(starts) do
    local sx, sy = stt[1] or 0.5, stt[2] or 0.5
    jobs[#jobs + 1] = function()
      if db and not hier then db.kartenTest = { zi = zi, stand = Paket().stand } end
      local mi = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(zone)
      Log("KARTENTEST", ("Zone %s %s: %d Ziele, Start %d %s %.3f,%.3f"):format(tostring(zone), tostring(mi and mi.name or "?"), #list, si, tostring(stt[3] or "Start"), sx, sy))
    end
    -- je Job 4 Ziele, damit kein Bild zu lange haengt
    for k0 = 1, #list, 4 do
      jobs.lbl[#jobs + 1] = (TR"Zone %d von %d, Ziel %d von %d"):format(zi, #kn.zonen, math.min(#list, k0 + 3), #list) .. (#starts > 1 and (" (" .. si .. "/" .. #starts .. ")") or "")
      jobs[#jobs + 1] = function()
        for k = k0, math.min(#list, k0 + 3) do
          local z = list[k]
          ns.naviFromTest = { zone, sx, sy }
          local t0 = debugprofilestop and debugprofilestop() or 0
          local ok, nv, why = pcall(ns.NaviPlan, zone, z[1], z[2], z[3])
          local ms = (debugprofilestop and debugprofilestop() or 0) - t0
          ns.naviFromTest = nil
          local luft = ns.WorldDistXY(zone, sx, sy, zone, z[1], z[2]) or 0
          local line
          if ok and type(nv) == "table" and nv.legs then
            local walk, teile, net, lastP = 0, {}, false, nil
            for _, lg in ipairs(nv.legs) do
              if not lg.wp then teile[#teile + 1] = lg.kind end
              if lg.kind == "walk" then walk = walk + (lg.sec or 0) * speed end
              if lg.pc and lg.pc.pts and #lg.pc.pts > 0 then lastP = lg.pc.pts[#lg.pc.pts]; if #lg.pc.pts > 2 then net = true end end
            end
            -- 1.4zza (Pr 05:30): rest = Abstand letzter Netz Punkt zum Ziel (ueber 60 yd: Ziel nur aufs Netz geschnappt)
            local rest = lastP and type(lastP[1]) == "number" and ns.WorldDistXY(lastP[1], lastP[2], lastP[3], zone, z[1], z[2]) or nil
            local um = luft > 1 and walk / luft or 1
            -- 1.4zzb (Pr 05:55): Umweg genau 1.20 ist der Luftlinie Ersatz (kein Netz Weg), ehrlich als luft melden
            if math.abs(um - 1.2) < 0.005 then net = false end
            if not worst or um > worst.um then worst = { um = um, z = z, k = k, sx = sx, sy = sy } end
            -- 1.4zzd (P212 Punkt 1, Ka FRA 10:30): ehrlich. geht=0 mit grund luft_ersatz (nur Luftlinie Ersatz), wasser/berg/kein_weg
            -- (Ziel selbst nicht erreichbar, Weg geht bis erreichbar_bis), ausser_zone (Abstand nicht rechenbar). Sonst geht=1
            -- 1.4zzf (Ka BER 13:30 Punkt 2, 135 "NAVI findet Weg nicht"): ist die gerade Linie im Raster frei, nimmt die
            -- Wegsuche bewusst kein Netz (K.PathPts "free"). Das ist kein Ersatz, sondern art=frei mit geht=1
            local frei = false
            if not net and ns.Karte and ns.Karte.PathPts then
              local okF, pF, whyF = pcall(ns.Karte.PathPts, zone, sx, sy, z[1], z[2])
              frei = okF and pF == nil and whyF == "free"
            end
            local grund
            if not luft or luft <= 0 then grund = "ausser_zone"
            elseif nv.reach then grund = (nv.reach.why == "wasser" and "wasser") or (nv.reach.why == "berg" and "berg") or "kein_weg"
            elseif not net and not frei then grund = "luft_ersatz" end
            line = ("zone=%s | nr=%d | ziel=%.3f,%.3f | name=%s | geht=%d | laenge=%d | luft=%d | umweg=%.2f | teile=%d | art=%s | zeit=%d | ms=%d | rest=%s%s%s%s"):format(tostring(zone), k, z[1], z[2], z[3],
              grund and 0 or 1, math.floor(walk), math.floor(luft or 0), um, #teile, net and "netz" or (frei and "frei" or "luft"), math.floor(nv.total or 0), math.floor(ms), rest and tostring(math.floor(rest)) or "-",
              nv.reach and (" | erreichbar_bis=" .. tostring(nv.reach.d)) or "", grund and (" | grund=" .. grund) or "", ms > maxMs and " | langsam" or "")
          else
            line = ("zone=%s | nr=%d | ziel=%.3f,%.3f | name=%s | geht=0 | grund=%s | luft=%d | ms=%d"):format(tostring(zone), k, z[1], z[2], z[3], ok and tostring(why or "kein Weg") or ("Fehler " .. tostring(nv)), math.floor(luft), math.floor(ms))
          end
          Log("KARTENTEST", line .. " | start=" .. (hier and "hier" or si))
        end
      end
    end
    end
    if shots then
      jobs[#jobs + 1] = function()
        if not (worst and ns.NaviTo) then return end
        ns.naviFromTest = { zone, worst.sx or sx0, worst.sy or sy0 }
        pcall(ns.NaviTo, zone, worst.z[1], worst.z[2], worst.z[3])
        ns.naviFromTest = nil
        ns.lineBoost = 2.5
        MapOpen(zone, true)
        if ns.Draw then pcall(ns.Draw) end
      end
      jobs[#jobs + 1] = function()
        if worst then Shot(("Karten Test Zone %s, Ziel %d groesster Umweg %.2f"):format(tostring(zone), worst.k, worst.um)) end
      end
      jobs[#jobs + 1] = function() end
      jobs[#jobs + 1] = function()
        ns.lineBoost = nil
        MapClose()
        if ns.NaviHide then pcall(ns.NaviHide, true) end
      end
    end
  end
  jobs[#jobs + 1] = function()
    if db and not hier then db.kartenTest = nil end
    if prev.had and prev.dest and ns.NaviTo then pcall(ns.NaviTo, prev.dest.map, prev.dest.x, prev.dest.y, prev.dest.name) end
  end
  ktRunning = true
  Log("TEST", ("Karten Test Start%s: Paket %s, Zonen %d bis %d, Raster %d, %d Teile"):format(hier and " (hier pruefen)" or "", tostring(Paket().stand or "ohne"), from, #kn.zonen, n, #jobs))
  ns.Print((TR"Karten Test läuft, %d Teile. Bitte nicht kämpfen."):format(#jobs))
  local i = 0
  local function Next()
    if InCombatLockdown and InCombatLockdown() then
      ns.naviFromTest, ns.lineBoost = nil, nil
      if mapMax then MapClose() end
      Log("TEST", ("Karten Test Abbruch: Kampf nach %d von %d, weiter ab Zone %s"):format(i, #jobs, tostring(db and db.kartenTest and db.kartenTest.zi or "?")))
      ktRunning = false
      ns.Print(TR"Karten Test abgebrochen (Kampf). Nochmal starten macht ab dieser Zone weiter.")
      Bar.Done(TR"Karten Test abgebrochen (Kampf)")
      return
    end
    i = i + 1
    local job = jobs[i]
    if not job then
      ktRunning = false
      Log("TEST", "Karten Test Ende")
      ns.Print(TR"Karten Test fertig, Ergebnis steht im Log.")
      Bar.Done()
      return
    end
    Bar.Step(jobs, i)
    local ok, err = pcall(job)
    if not ok then ns.naviFromTest = nil; Log("TEST", ("Karten Test Teil %d Fehler: %s"):format(i, tostring(err))) end
    -- 1.4zzl (M53, Pr BER 03:00: Karten Test +200 MB je 5 Min Muell vom Weg Rechnen): nach jedem Paket ein Stueck aufraeumen
    if TL.KT_GC_KB and TL.KT_GC_KB > 0 then collectgarbage("step", TL.KT_GC_KB) end
    C_Timer.After(TL.STEP_S, Next)
  end
  C_Timer.After(0.2, Next)
end

------------------------------------------------------------
-- 1.4zzh (P212 Punkt 2, Ka FRA 10:30): Knopf "Hier pruefen". Rechnet vom Standort zu Punkten im Umkreis (je 8 Richtungen
-- auf KT_HIER.RADII Yards) plus Punkte aus dem Testpaket (karte_navi.punkte) in der Naehe, gleiche KARTENTEST Zeilen mit
-- start=hier. Fuer Stellen, wo dir beim Spielen etwas komisch vorkommt. Nur ausser Kampf, Log muss laufen
ns.KT_HIER = { RADII = { 100, 300 }, NEAR = 400, MAX_PKT = 8 }
function ns.KartenTestHier()
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if not (pos and ns.WorldDistXY) then ns.Print(TR"Hier pruefen: keine Position."); return end
  local x, y = pos:GetXY()
  local ux = ns.WorldDistXY(map, x, y, map, x + 0.01, y) or 0
  local uy = ns.WorldDistXY(map, x, y, map, x, y + 0.01) or 0
  if ux <= 0 or uy <= 0 then ns.Print(TR"Hier pruefen: keine Position."); return end
  local list = {}
  for _, r in ipairs(ns.KT_HIER.RADII) do
    for k = 0, 7 do
      local a = k * math.pi / 4
      local tx, ty = x + math.cos(a) * r / ux * 0.01, y + math.sin(a) * r / uy * 0.01
      if tx > 0.01 and tx < 0.99 and ty > 0.01 and ty < 0.99 then list[#list + 1] = { tx, ty, ("Umkreis %d yd %d"):format(r, k + 1) } end
    end
  end
  local kn = Paket().karte_navi
  local n = 0
  for _, pt in ipairs(type(kn) == "table" and type(kn.punkte) == "table" and kn.punkte[map] or {}) do
    if n < ns.KT_HIER.MAX_PKT and type(pt) == "table" and pt[1] and pt[2] then
      local d = ns.WorldDistXY(map, x, y, map, pt[1], pt[2])
      if d and d <= ns.KT_HIER.NEAR then n = n + 1; list[#list + 1] = { pt[1], pt[2], tostring(pt[3] or "Punkt") } end
    end
  end
  ns.KartenTestStart({ zonen = { map }, raster = 0, punkte = { [map] = list }, start = { [map] = { { x, y, "hier" } } }, max_ms = kn and kn.max_ms })
end

-- 1.4zzb (P206, S 04:38/04:41 Ja, K 04:44 und 05:18): Szenario Test. Teil "szenarien" im Testpaket (Format Pr 05:55):
-- szenarien = { { name, level, map, x, y, ruhestein = {map,x,y}, log = { {qid, fertig = true} }, erledigt = {qid,...},
-- schritte = 30, ziel = Level } }. Das Addon spielt den Stand nur fuer die Planung vor (ns.Optimize mit opts.sim: eigenes
-- Level, Ort, Questlog, erledigte Quests, Ruhestein). Die echte Route, das Questlog und alles Gespeicherte bleiben
-- unberuehrt. Flugpunkte: die echten (eigene Liste fp kommt spaeter, das muesste db.knownFP umstellen). Zeilen SZENARIO.
-- Mit Bild bei Meldung: die geplante Route als Vorschau auf der grossen Karte (ns.profPreview), danach weg.
------------------------------------------------------------
ns.TL.SZEN_WAIT_S = 120
function ns.SzenarioJobs(list, jobs, pk)
  for si, sc in ipairs(list) do
    if type(sc) == "table" and sc.map and sc.x and sc.y and sc.level then
      local name = tostring(sc.name or ("Szenario " .. si))
      local res
      jobs[#jobs + 1] = function()
        res = { t0 = GetTime() }
        local done, log, prog = {}, {}, {}
        for _, q in ipairs(type(sc.erledigt) == "table" and sc.erledigt or {}) do if type(q) == "number" then done[q] = true end end
        for _, e in ipairs(type(sc.log) == "table" and sc.log or {}) do
          local q = type(e) == "table" and e[1] or e
          if type(q) == "number" then
            log[q] = true
            -- 1.4zzd (Pr WUNSCH 1): fertig = abgabebereit
            if type(e) == "table" and e.fertig == true then prog[q] = { complete = true, objs = {} } end
          end
        end
        -- 1.4zzd (P206 fp, K 11:00): eigene Flugpunkte nur fuer die Rechnung (ns.simKnownFP), db.knownFP bleibt unberuehrt
        local fpl = sc.fp == "profil" and pk and pk.profil_fp or (type(sc.fp) == "table" and sc.fp) or nil
        local nfp = "echt"
        if type(fpl) == "table" then
          local kf, c = {}, 0
          for _, npc in ipairs(fpl) do if type(npc) == "number" then kf[npc] = true; c = c + 1 end end
          ns.simKnownFP, ns.simFPRev = kf, (ns.simFPRev or 0) + 1
          nfp = tostring(c)
        end
        res.fp = nfp
        local L = tonumber(sc.level) or 1
        local sim = { L = L, xp = ns.xpTotal and ns.xpTotal[L] or 0, map = sc.map, x = sc.x, y = sc.y, done = done, log = log,
          trained = L, bind = type(sc.ruhestein) == "table" and sc.ruhestein or nil, prog = prog }
        Log("SZENARIO", ("%s | start | level=%d | ort=%s %.3f,%.3f | log=%d | fertig=%d | erledigt=%d | fp=%s"):format(name, L, tostring(sc.map), sc.x, sc.y,
          (function() local c = 0 for _ in pairs(log) do c = c + 1 end return c end)(), (function() local c = 0 for _ in pairs(prog) do c = c + 1 end return c end)(),
          #(sc.erledigt or {}), nfp))
        if not ns.Optimize then res.err = "kein ns.Optimize"; return end
        local ok, err = pcall(ns.Optimize, tonumber(sc.ziel) or (L + 3), function(opt) res.opt = opt or false end, { sim = sim })
        if not ok then res.err = tostring(err) end
      end
      -- warten, bis die Rechnung fertig ist (in Stuecken), hoechstens SZEN_WAIT_S
      local waitN = math.ceil(ns.TL.SZEN_WAIT_S / ns.TL.STEP_S)
      for _ = 1, waitN do
        jobs[#jobs + 1] = function() if res and (res.opt ~= nil or res.err) then return "skip" end end
      end
      jobs[#jobs + 1] = function()
        if not res then return end
        -- Flugpunkte wieder die echten (auch bei Fehler oder Zeit um)
        if ns.simKnownFP then ns.simKnownFP, ns.simFPRev = nil, (ns.simFPRev or 0) + 1 end
        local ms = math.floor((GetTime() - res.t0) * 1000)
        if res.err or res.opt == nil or res.opt == false then
          Log("SZENARIO", ("%s | nicht gerechnet | grund=%s | ms=%d"):format(name, tostring(res.err or (res.opt == false and "keine Route" or "Zeit um oder Route rechnet gerade")), ms))
          return
        end
        local opt = res.opt
        local reisen, nR, abg = {}, 0, {}
        local okL, errL = pcall(function()
        for i, st in ipairs(opt.steps or {}) do
          local a1 = st.acts and st.acts[1] or {}
          local qs = {}
          for _, a in ipairs(st.acts or {}) do
            -- 1.4zzl (K 03:05 Punkt 1, Pr BER 03:00: keine ende und abgabe Zeile mehr): Aktionen ohne k (zb Reise Teile)
            -- brachen hier ab, nach Schritt 30 ohne Log. Jetzt tostring, und ende/abgabe kommen auch nach einem Fehler
            if a.qid then qs[#qs + 1] = tostring(a.k or "?") .. tostring(a.qid) end
            -- 1.4zzd (Pr WUNSCH 5): je Quest der Schritt der Abgabe
            if a.k == "T" and a.qid and #abg < 60 then abg[#abg + 1] = a.qid .. "@" .. i end
            if a.k == "R" then nR = nR + 1; reisen[#reisen + 1] = tostring(a.link or a.kind or "reise") .. ">" .. tostring(a.dest or "?") end
          end
          if i <= (tonumber(sc.schritte) or 30) then
            Log("SZENARIO", ("%s | schritt=%d | art=%s | quest=%s | zone=%s | ort=%.3f,%.3f"):format(name, i, tostring(a1.k or "?"), table.concat(qs, ","),
              tostring(st.map), tonumber(st.x) or 0, tonumber(st.y) or 0))
          end
        end
        end)
        if not okL then Log("SZENARIO", ("%s | fehler | %s"):format(name, tostring(errL))) end
        Log("SZENARIO", ("%s | ende | schritte=%d | bis Level %.1f | reisen=%d %s | fp=%s | ms=%d"):format(name, #(opt.steps or {}), tonumber(opt.to) or 0, nR,
          table.concat(reisen, ","):sub(1, 300), tostring(res.fp), ms))
        Log("SZENARIO", ("%s | abgabe=%s"):format(name, #abg > 0 and table.concat(abg, ",") or "-"))
        res.ok = true
      end
      if ns.ShotOn and ns.ShotOn() then
        jobs[#jobs + 1] = function()
          if not (res and res.ok and res.opt) then return end
          ns.profPreview = res.opt
          ns.lineBoost = 2.5
          local s1 = res.opt.steps and res.opt.steps[1]
          MapOpen(s1 and s1.map or sc.map, true)
          if ns.Draw then pcall(ns.Draw) end
        end
        jobs[#jobs + 1] = function() if res and res.ok then Shot(("Szenario %s Route"):format(name)) end end
        jobs[#jobs + 1] = function() end
        jobs[#jobs + 1] = function()
          ns.profPreview, ns.lineBoost = nil, nil
          MapClose()
          if ns.Draw then pcall(ns.Draw) end
        end
      end
    end
  end
end

------------------------------------------------------------
-- 1.4zze (P211, S 10:34, K 11:00): Teil "funktionen" im normalen Test. Jede Funktion einmal benutzen und danach genau wie
-- vorher. Zeile "FUNKTION | name | ok/ROT/uebersprungen | was". Nicht dabei, weil es die Route neu rechnet oder Daten
-- speichert: Ueberspringen, Gefahr Stelle setzen, Farm Runde starten (die stehen als uebersprungen mit Grund im Log).
-- Englisch (fehlende Uebersetzungen) prueft Pr besser auf dem PC (alle TR Texte gegen Locale_enUS).
------------------------------------------------------------
local function F(name, st, txt) Log("FUNKTION", ("%s | %s | %s"):format(name, st, tostring(txt or ""))) end
function ns.FunktionJobs(p, jobs)
  local db = ns.db
  -- 1 Mini Fenster: Zurueck und Weiter (Weiter nach Zurueck blaettert nur vor, Ueberspringen aendert die Route)
  local o0
  jobs[#jobs + 1] = function()
    local o = db and db.opt
    if not (o and o.steps and #o.steps > 1 and ns.OptBack and ns.OptForward) then F("Knoepfe", "uebersprungen", "keine Route"); return end
    -- bei Schritt 1 ginge Zurueck in den Abschnitt davor (andere Route), das nicht im Test
    if (o.idx or 1) < 2 then F("Knoepfe", "uebersprungen", "Schritt 1, Zurueck ginge in den Abschnitt davor"); return end
    o0 = { idx = o.idx or 1, pin = o.pin, opt = o }
    pcall(ns.OptBack)
  end
  jobs[#jobs + 1] = function()
    if not o0 then return end
    local o = db.opt
    local back = o == o0.opt and (o.idx or 1)
    pcall(ns.OptForward)
    local fwd = db.opt == o0.opt and (db.opt.idx or 1)
    local okB = back and (back == o0.idx - 1 or (o0.idx == 1 and back == 1))
    local okF = fwd and fwd == o0.idx
    if db.opt == o0.opt then db.opt.idx, db.opt.pin = o0.idx, o0.pin end
    if ns.OptSync then pcall(ns.OptSync) end
    F("Knoepfe", (okB and okF) and "ok" or "ROT", ("Schritt %d, Zurueck %s, Weiter %s, wieder %d (Ueberspringen nicht im Test, aendert die Route)"):format(o0.idx, tostring(back), tostring(fwd), db.opt and db.opt.idx or 0))
    o0 = nil
  end
  -- 2 Einstellungen: Seite oeffnen, Haken zaehlen. Klicken nur mit Paket einstellungen_klick = true (manche rechnen die Route neu)
  jobs[#jobs + 1] = function()
    local b = _G.TaurenRouteBig
    local was = { shown = b and b:IsShown(), view = ns.BigView and ns.BigView() }
    if not pcall(ns.ShowBig, "set") then F("Einstellungen", "ROT", "Seite geht nicht auf"); return end
    local boxes = {}
    local function Walk(f)
      if not f then return end
      if f.GetObjectType and f:GetObjectType() == "CheckButton" and f:IsVisible() then boxes[#boxes + 1] = f end
      for _, c in ipairs({ f:GetChildren() }) do Walk(c) end
    end
    Walk(_G.TaurenRouteBig)
    local bad, n = 0, 0
    if p.einstellungen_klick then
      for _, cb in ipairs(boxes) do
        local v0 = cb:GetChecked() and true or false
        local ok1 = pcall(cb.Click, cb)
        local v1 = cb:GetChecked() and true or false
        local ok2 = pcall(cb.Click, cb)
        local v2 = cb:GetChecked() and true or false
        n = n + 1
        if not (ok1 and ok2 and v1 ~= v0 and v2 == v0) then bad = bad + 1 end
      end
    end
    F("Einstellungen", bad == 0 and "ok" or "ROT", ("%d Haken sichtbar%s"):format(#boxes, p.einstellungen_klick and (", %d geklickt hin und zurueck, %d falsch"):format(n, bad) or ", nicht geklickt (Paket einstellungen_klick = true)"))
    if was.shown then pcall(ns.ShowBig, was.view) elseif b then b:Hide() end
  end
  -- 3 Pfeil an/aus und Groesse
  jobs[#jobs + 1] = function()
    local a = _G.TaurenRouteArrow
    if not (a and ns.ToggleArrow and db) then F("Pfeil", "uebersprungen", "kein Pfeil"); return end
    local s0, v0, sc0 = a:IsShown(), db.arrow, db.arrowScale
    pcall(ns.ToggleArrow); local s1 = a:IsShown()
    pcall(ns.ToggleArrow); local s2 = a:IsShown()
    local okS = true
    if ns.SetArrowScale then
      pcall(ns.SetArrowScale, (sc0 or 1) + 0.2)
      okS = db.arrowScale ~= sc0
      pcall(ns.SetArrowScale, sc0 or 1)
      db.arrowScale = sc0
      if ns.ApplyArrowSize then pcall(ns.ApplyArrowSize) end
    end
    db.arrow = v0
    F("Pfeil", (s2 == s0 and okS and (s1 ~= s0 or db.paused)) and "ok" or "ROT", ("vorher %s, umgeschaltet %s, zurueck %s, Groesse %s, Groesse wieder %s"):format(tostring(s0), tostring(s1), tostring(s2), okS and "geht" or "geht nicht", tostring(db.arrowScale)))
  end
  -- 4 Questitem Leiste an/aus
  jobs[#jobs + 1] = function()
    if not (ns.ToggleQuestItems and db) then F("Questitems", "uebersprungen", "fehlt"); return end
    local v0 = db.questItems
    pcall(ns.ToggleQuestItems); local v1 = db.questItems
    pcall(ns.ToggleQuestItems); local v2 = db.questItems
    F("Questitems", (v1 ~= v0 and v2 == v0) and "ok" or "ROT", ("vorher %s, um %s, zurueck %s"):format(tostring(v0), tostring(v1), tostring(v2)))
  end
  -- 5 Service Ziele: naechster Lehrer, Haendler, Gastwirt, Reparatur, Flugmeister, Weg nur rechnen
  for _, kind in ipairs({ "trainer", "vendor", "inn", "repair", "fly" }) do
    jobs[#jobs + 1] = function()
      local pm = ns.PlayerMap and ns.PlayerMap()
      local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
      if not (pos and ns.NearestSvc and ns.NaviPlan) then F("Service " .. kind, "uebersprungen", "keine Position"); return end
      local px, py = pos:GetXY()
      local best, d = ns.NearestSvc(kind, pm, px, py, true)
      if not best then F("Service " .. kind, "uebersprungen", "keiner auf dem Kontinent bekannt"); return end
      local ok, nv, why = pcall(ns.NaviPlan, best.map, best.x, best.y, best.name)
      local good = ok and type(nv) == "table" and nv.legs
      F("Service " .. kind, good and "ok" or "ROT", ("%s, %d yd, %s"):format(tostring(best.name), math.floor(d or 0), good and ("Weg %d s, %d Teile"):format(math.floor(nv.total or 0), #nv.legs) or tostring(ok and why or nv)))
    end
  end
  -- 6 Dungeon Touren nur rechnen
  jobs[#jobs + 1] = function() if ns.BuildDungeonIndex then pcall(ns.BuildDungeonIndex, function() end) end end
  jobs[#jobs + 1] = function() end
  jobs[#jobs + 1] = function()
    local list = ns.dungeons
    if type(list) ~= "table" or not ns.DungeonRoute then F("Dungeon Touren", "uebersprungen", "Liste noch nicht da"); return end
    local okN, bad, out = 0, 0, {}
    for _, d in ipairs(list) do
      local t0 = debugprofilestop and debugprofilestop() or 0
      local ok, steps, info = pcall(ns.DungeonRoute, d)
      local ms = (debugprofilestop and debugprofilestop() or 0) - t0
      if ok and type(steps) == "table" then okN = okN + 1; out[#out + 1] = ("%s %d (%d ms)"):format(tostring(d.name), #steps, math.floor(ms))
      else bad = bad + 1; F("Dungeon Tour " .. tostring(d.name), "ROT", tostring(ok and info or steps)) end
    end
    F("Dungeon Touren", bad == 0 and "ok" or "ROT", ("%d gerechnet, %d Fehler | %s"):format(okN, bad, table.concat(out, ", "):sub(1, 500)))
  end
  -- 7 Zusatz Routen nur rechnen (wie Szenarien, ab deinem Stand): Gold und Questlog. Ruf braucht eine Fraktion, nicht im Test
  for _, z in ipairs({ { "Gold", { gold = true } }, { "Questlog", { logOnly = true } } }) do
    local res
    jobs[#jobs + 1] = function()
      local pm = ns.PlayerMap and ns.PlayerMap()
      local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
      if not (pos and ns.Optimize) then F("Route " .. z[1], "uebersprungen", "keine Position"); return end
      local px, py = pos:GetXY()
      local L = UnitLevel("player") or 1
      local log = {}
      for q in pairs(ns.logProgress or {}) do log[q] = true end
      res = { t0 = GetTime() }
      local opts = { sim = { L = L, xp = ns.xpTotal and ns.xpTotal[L] or 0, map = pm, x = px, y = py, done = {}, log = log, trained = L } }
      for k, v in pairs(z[2]) do opts[k] = v end
      local ok, err = pcall(ns.Optimize, L + 3, function(opt) res.opt = opt or false end, opts)
      if not ok then res.err = tostring(err) end
    end
    for _ = 1, math.ceil(60 / ns.TL.STEP_S) do jobs[#jobs + 1] = function() if res and (res.opt ~= nil or res.err) then return "skip" end end end
    jobs[#jobs + 1] = function()
      if not res then return end
      local o = res.opt
      F("Route " .. z[1], (type(o) == "table") and "ok" or "ROT", type(o) == "table" and ("%d Schritte, %d ms"):format(#(o.steps or {}), math.floor((GetTime() - res.t0) * 1000))
        or tostring(res.err or (o == false and "keine Route" or "Zeit um oder Route rechnet gerade")))
    end
  end
  jobs[#jobs + 1] = function() F("Ruf Route", "uebersprungen", "braucht eine Fraktion") end
  -- 8 Farm Stellen nur rechnen (Runde starten nicht, das speichert eine Sitzung)
  local farm
  jobs[#jobs + 1] = function()
    if not ns.FarmSpots then F("Farm", "uebersprungen", "fehlt"); return end
    farm = { t0 = GetTime() }
    local ok, err = pcall(ns.FarmSpots, function(list) farm.list = list or {} end)
    if not ok then farm.err = tostring(err) end
  end
  for _ = 1, math.ceil(30 / ns.TL.STEP_S) do jobs[#jobs + 1] = function() if farm and (farm.list or farm.err) then return "skip" end end end
  jobs[#jobs + 1] = function()
    if not farm then return end
    F("Farm", farm.list and "ok" or "ROT", farm.list and ("%d Stellen gerechnet (Runde nicht gestartet, das speichert eine Sitzung)"):format(#farm.list) or tostring(farm.err or "Zeit um"))
  end
  jobs[#jobs + 1] = function() F("Gefahr Stelle", "uebersprungen", "setzen rechnet die Route neu") end
  jobs[#jobs + 1] = function() F("Englisch", "uebersprungen", "prueft Pr auf dem PC (TR Texte gegen Locale_enUS)") end
end
