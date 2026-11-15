-- Mein Weg: kleine Figur vom eigenen Charakter, die den Weg bis 60 entlang laeuft (17.4, Wunsch Sascha).
-- Das 3D Modell zeichnet WoW selbst (wie im Charakterfenster), mit der Ausruestung, die man gerade traegt.
-- Jedes Level (1.1, vorher alle 5) merkt sich das Addon die Ausruestung (pro Charakter, db.wegGear). Der Knopf Rueckblick auf der
-- Karte Level 60 laesst die Figur den Weg nochmal ablaufen, mit dem, was man damals anhatte.
local ADDON, ns = ...
local TR = ns.TR

local SPEED = 34                    -- Punkte pro Sekunde (17.5: 60 % langsamer als 17.4, Wunsch Sascha), ganzer Weg etwa 2.5 Minuten
local ANIM_RATE = 0.4               -- Laufanimation ebenso 60 % langsamer (Modell abwechselnd laufen lassen und anhalten)
local FIG_H = 0.45                  -- Hoehe der Figur in Kartenhoehen (etwas hoeher als die Symbole)
local FEET_F = 0.32                 -- Fuesse auf dieser Hoehe der Karte (von unten): Mitte der Symbole, wie Saschas lila Linie
local TURN_F = 0.22                 -- Bogen am Reihenende: so weit ueber die Kartenmitte nach aussen (in Kartenbreiten)
local TURN_R = 28                   -- Radius der Ecken im Bogen
local SIDE = math.pi / 2 - 0.35     -- seitlich laufen, leicht zum Betrachter gedreht
local FRONT = 0.35                  -- stehen: fast zum Betrachter
local ANIM_STAND, ANIM_WALK = 0, 4
-- 19.36 (Sascha f29 22:11): Tempo Knopf unter Rueckblick, normal oder x2 (db.wegTempo), nur die Figur, keine Route
local function Tempo() return (ns.db and ns.db.wegTempo == 2) and 2 or 1 end
-- sichtbare Teile (Hals, Ringe, Schmuck sieht man nicht, Fernkampf haengt sonst statt der Waffe in der Hand)
local SLOTS = { 1, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 19 }

------------------------------------------------------------
-- Ausruestung alle 5 Level merken
------------------------------------------------------------
local function GearNow()
  if not GetInventoryItemID then return nil end
  local t, n = {}, 0
  for _, s in ipairs(SLOTS) do
    local id = GetInventoryItemID("player", s)
    if type(id) == "number" and id > 0 then t[s] = id; n = n + 1 end
  end
  return n > 0 and t or nil
end

-- 1.1 (S Log L9.8 "Mein Weg: Ausruestung bei den Level Schritten speichern, der Avatar veraendert sich dann"): jetzt bei
-- jedem Level und jedem Wechsel der Ausruestung (Stand am Ende des Levels), nicht mehr nur alle 5 Level
local UPGRADE_STOP_S = 1.4          -- Figur bleibt bei einem Ausruestungs Wechsel so lange stehen
local function Snap(L)
  local db = ns.db
  if not db then return end
  L = tonumber(L) or UnitLevel("player")
  if not L or L < 1 then return end
  local g = GearNow()
  if not g then return end
  if type(db.wegGear) ~= "table" then db.wegGear = {} end
  db.wegGear[L] = g
  -- 1.4n (P162, S: "bei 60 einmal das Gear, was er auf 60 hatte, nicht das aktuelle"): nur der erste Stand auf Hoechststufe
  local maxL = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
  if L >= maxL and type(db.wegGearMax) ~= "table" then db.wegGearMax = g end
end
ns.WegGearSnap = Snap

-- Ausruestung fuer Level L: der Stand bei der 5er Stufe darunter, fehlt der, die naechste hoehere.
-- Nichts gemerkt bis zum jetzigen Level: nil, dann zeigt die Figur, was du jetzt traegst.
local function GearFor(L)
  local g = ns.db and ns.db.wegGear
  if type(g) ~= "table" then return nil end
  local cur = UnitLevel("player") or 60
  L = math.floor(L or cur)
  if L >= cur then return nil end
  -- 1.1: Stand vom hoechsten gemerkten Level bis L, sonst der naechste hoehere (bis zu deinem Level)
  local best, bl
  for lv, t in pairs(g) do
    if type(lv) == "number" and type(t) == "table" and lv <= L and (not bl or lv > bl) then best, bl = t, lv end
  end
  if best then return best, bl end
  for lv, t in pairs(g) do
    if type(lv) == "number" and type(t) == "table" and lv > L and lv <= cur and (not bl or lv < bl) then best, bl = t, lv end
  end
  return best, bl
end

local ev = CreateFrame("Frame")
ns.RegEv(ev, "PLAYER_LEVEL_UP")
ns.RegEv(ev, "PLAYER_EQUIPMENT_CHANGED")
ns.RegEv(ev, "PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, e, a1)
  if e == "PLAYER_LEVEL_UP" then
    -- beim Event ist UnitLevel manchmal noch das alte Level
    pcall(Snap, a1)
  elseif e == "PLAYER_EQUIPMENT_CHANGED" then
    pcall(Snap)
  else
    -- beim Einloggen: fuer dieses Level noch nichts gemerkt
    local L = UnitLevel("player")
    local g = ns.db and ns.db.wegGear
    if L and not (type(g) == "table" and g[L]) then pcall(Snap, L) end
  end
end)

-- 20.1 (P8, Sascha 12:18): Reittier der Figur in Mein Weg ganz raus (Erkennung, Merken, Modelle). Die Figur laeuft
-- immer zu Fuss. Das Reittier in der Route (Tempo ab 40, Karte Level 40) bleibt, das steht nicht hier.

------------------------------------------------------------
-- Weg aus den Karten: Linie auf Hoehe der Symbole, am Reihenende ein runder Bogen aussen herum (17.5)
------------------------------------------------------------
local path            -- { pts = { {x, y, s} }, anc = { {lvl, s} } }
local fig             -- das Modell
local cur, target     -- Position auf dem Weg (Strecke in Punkten)
local replay          -- Rueckblick laeuft
local anim, facing    -- was gerade gesetzt ist
local gearKey, wantGear
local pgRef
local dressFig        -- das Modell (DressUpModel, Ausruestung anprobierbar)

local function LevelNow()
  local L = UnitLevel("player") or 1
  local x, mx = UnitXP and UnitXP("player") or 0, UnitXPMax and UnitXPMax("player") or 0
  if L < 60 and mx and mx > 0 then L = L + math.min(0.99, x / mx) end
  return L
end

-- 20.4a4 (K 21:00, S 20:58): die Figur bleibt auf der hoechsten erreichten Karte (Level <= dein Level). Vorher lief sie
-- zwischen zwei Karten anteilig weiter und stand mit Level 3 schon auf der Karte Level 4. Jetzt hoechstens dieser Teil
-- des Wegs zur naechsten Karte (bleibt in der eigenen Karte, auch bei Alles frei)
local WEG_HOLD_F = 0.3
local function SOf(L)
  local a = path and path.anc
  if not a or #a == 0 then return 0 end
  if L <= a[1].lvl then return a[1].s end
  for i = 2, #a do
    if L < a[i].lvl then
      local p = a[i - 1]
      return p.s + (a[i].s - p.s) * math.min(WEG_HOLD_F, (L - p.lvl) / math.max(0.01, a[i].lvl - p.lvl))
    end
  end
  return a[#a].s
end

local function LOf(s)
  local a = path and path.anc
  if not a or #a == 0 then return 1 end
  if s <= a[1].s then return a[1].lvl end
  for i = 2, #a do
    if s < a[i].s then
      local p = a[i - 1]
      return p.lvl + (a[i].lvl - p.lvl) * (s - p.s) / math.max(0.01, a[i].s - p.s)
    end
  end
  return a[#a].lvl
end

local function PointAt(s)
  local pts = path.pts
  for i = 2, #pts do
    local a, b = pts[i - 1], pts[i]
    if s <= b.s or i == #pts then
      local f = (b.s > a.s) and math.min(1, math.max(0, (s - a.s) / (b.s - a.s))) or 0
      return a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, b.x - a.x, b.y - a.y
    end
  end
  return pts[1].x, pts[1].y, 0, 0
end

local function BuildPath(pg)
  local cards = {}
  for _, b in ipairs(pg.cards or {}) do
    if b:IsShown() and b.st and b.cx and b.cy then cards[#cards + 1] = b end
  end
  if #cards < 2 then return nil end
  local pts, anc = {}, {}
  local function Add(x, y)
    local p = pts[#pts]
    local s = p and (p.s + math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)) or 0
    if not p or s > p.s + 0.01 then pts[#pts + 1] = { x = x, y = y, s = s } end
    return pts[#pts].s
  end
  local function FY(b) local h = b:GetHeight() or 80; return b.cy - h / 2 + h * FEET_F end
  local function Dir(b) return (b.row or 0) % 2 == 0 and 1 or -1 end
  local function Arc(cx, cy, r, dir, a0, a1)
    for k = 1, 6 do
      local a = a0 + (a1 - a0) * k / 6
      Add(cx + dir * r * math.cos(a), cy + r * math.sin(a))
    end
  end
  local first = cards[1]
  -- Start: im ersten Drittel der ersten Karte, Ende: im letzten Drittel der letzten (in Laufrichtung)
  anc[1] = { lvl = first.st.lvl, s = Add(first.cx - Dir(first) * (first.cwr or 200) * TURN_F, FY(first)) }
  for i = 2, #cards do
    local p, b = cards[i - 1], cards[i]
    if b.row ~= p.row then
      -- Reihenende (Saschas lila Linie): aussen an der letzten Karte vorbei, rund nach unten, rund in die neue Reihe
      local dir = Dir(p)
      local xt = p.cx + dir * (p.cwr or 200) * TURN_F
      local yA, yB = FY(p), FY(b)
      local r = math.min(TURN_R, math.abs(yA - yB) / 2, (p.cwr or 200) * TURN_F)
      local xc = xt - dir * r
      Add(xc, yA)
      Arc(xc, yA - r, r, dir, math.pi / 2, 0)
      Add(xt, yB + r)
      Arc(xc, yB + r, r, dir, 0, -math.pi / 2)
    end
    local x = b.cx
    if i == #cards then x = b.cx + Dir(b) * (b.cwr or 200) * TURN_F * 0.7 end
    anc[#anc + 1] = { lvl = b.st.lvl, s = Add(x, FY(b)) }
  end
  return { pts = pts, anc = anc, ch = first:GetHeight() or 80 }
end

------------------------------------------------------------
-- Figur
------------------------------------------------------------
local function Call(m, ...)
  if fig and fig[m] then return pcall(fig[m], fig, ...) end
end

local function DressNow()
  if not (fig and wantGear and fig.Undress and fig.TryOn) then return end
  pcall(fig.Undress, fig)
  for s, id in pairs(wantGear) do
    local hand = (s == 16 and "MAINHANDSLOT") or (s == 17 and "SECONDARYHANDSLOT") or nil
    if not pcall(fig.TryOn, fig, "item:" .. id, hand) then pcall(fig.TryOn, fig, "item:" .. id) end
  end
end

local function Refresh()
  -- nach jedem Neuladen vom Modell: Kamera, Animation, Blickrichtung und die gemerkte Ausruestung wieder setzen
  Call("SetPortraitZoom", 0)
  Call("SetCamDistanceScale", 1.15)
  Call("SetPosition", 0, 0, 0)
  if fig and fig.SetSheathed then pcall(fig.SetSheathed, fig, true) end
  if anim then Call("SetAnimation", anim) end
  if facing then Call("SetFacing", facing) end
  DressNow()
end

-- 1.4n (P162, S: "sehr ruckelig, da bei jedem Item Wechsel neu laedt"): das Modell nur beim ersten Mal laden (SetUnit),
-- danach nur aus und anziehen (Undress, TryOn bzw Dress), das laedt nichts neu
local function SetGear(g)
  local key = g and tostring(g) or "jetzt"
  if key == gearKey then return end
  local first = gearKey == nil
  gearKey, wantGear = key, g
  if first or not (fig and fig.Undress and fig.TryOn) then
    Call("SetUnit", "player")
    Refresh()
  elseif g then
    DressNow()
  elseif fig.Dress then
    Call("Dress")
  else
    Call("SetUnit", "player")
    Refresh()
  end
end

local function SetAnim(a)
  if a == anim then return end
  anim = a
  Call("SetAnimation", a)
end

local function SetFace(f)
  if facing and math.abs(f - facing) < 0.01 then return end
  facing = f
  Call("SetFacing", f)
end

-- 1.4n (P162): Stopps an jeder Karte, bei langen Abschnitten (mehr als FILL Level zwischen zwei Karten) alle FILL Level.
-- An jedem Stopp wird die Figur kurz groesser (POP), zieht die Ausruestung von damals an und laeuft dann weiter.
-- Ueber der Figur ein kleines Level Schild wie eine Namensplakette
local STOP = { FILL = 5, POP = 1.5, POP_IN = 0.25 }
local stops, lastStop, popScale, holdStart = nil, nil, 1, nil
local plate
local function BuildStops()
  stops = {}
  local a = path and path.anc or {}
  for i, p in ipairs(a) do
    stops[#stops + 1] = p.lvl
    local nx = a[i + 1]
    if nx and nx.lvl - p.lvl > STOP.FILL then
      local l = p.lvl - (p.lvl % STOP.FILL) + STOP.FILL
      while l < nx.lvl do stops[#stops + 1] = l; l = l + STOP.FILL end
    end
  end
end
local function StopAtOrBelow(L)
  local r
  for _, v in ipairs(stops or {}) do if v <= L + 0.001 then r = v end end
  return r
end
local function StopBetween(L0, L1)
  for _, v in ipairs(stops or {}) do
    if v > L0 + 0.001 and v <= L1 + 0.001 and (not lastStop or v > lastStop) then return v end
  end
end
-- Strecke zu Level L ohne das Halten in der eigenen Karte (Umkehrung von LOf)
local function SLin(L)
  local a = path and path.anc
  if not a or #a == 0 then return 0 end
  if L <= a[1].lvl then return a[1].s end
  for i = 2, #a do
    if L <= a[i].lvl then
      local p = a[i - 1]
      return p.s + (a[i].s - p.s) * (L - p.lvl) / math.max(0.01, a[i].lvl - p.lvl)
    end
  end
  return a[#a].s
end
-- Ausruestung an einem Stopp: Hoechststufe = der erste Stand dort, sonst der Stand vom Stopp (GearFor)
local function GearAt(L)
  local st = StopAtOrBelow(L) or L
  local a = path and path.anc
  local maxL = a and a[#a] and a[#a].lvl or 60
  if st >= maxL and ns.db and type(ns.db.wegGearMax) == "table" then return ns.db.wegGearMax, st end
  return GearFor(st)
end

local function Place()
  if not (fig and path and cur) then return end
  local x, y, dx, dy = PointAt(cur)
  local h = math.max(28, math.floor((path.ch or 80) * FIG_H * (popScale or 1)))
  fig:SetSize(h * 0.75, h)
  fig:ClearAllPoints()
  -- das Modell hat unter den Fuessen etwas Luft: ein Stueck tiefer setzen
  fig:SetPoint("BOTTOM", pgRef, "TOPLEFT", x, y - h * 0.06)
  if not plate then
    plate = CreateFrame("Frame", nil, fig)
    plate:SetSize(60, 14)
    plate:SetPoint("BOTTOM", fig, "TOP", 0, -2)
    plate.bg = plate:CreateTexture(nil, "BACKGROUND"); plate.bg:SetAllPoints(); plate.bg:SetColorTexture(0, 0, 0, 0.55)
    plate.fs = plate:CreateFontString(nil, "OVERLAY", ns.FontName and ns.FontName("GameFontHighlightSmall") or "GameFontHighlightSmall")
    plate.fs:SetPoint("CENTER")
  end
  local lv = math.floor(LOf(cur) + 0.001)
  if plate.lv ~= lv then
    plate.lv = lv
    plate.fs:SetText((TR"Level %d"):format(lv))
    plate:SetWidth((plate.fs:GetStringWidth() or 40) + 10)
  end
  return dx, dy
end

-- Laufanimation langsamer: das Modell laeuft nur in einem Teil der Bilder weiter (ANIM_RATE), sonst angehalten
local animAcc = 0
local function AnimPace(el)
  if not (fig and fig.SetPaused) then return end
  animAcc = animAcc + (el or 0) * math.min(1, ANIM_RATE * Tempo())
  if animAcc >= (el or 0) then animAcc = animAcc - (el or 0); Call("SetPaused", false)
  else Call("SetPaused", true) end
end

local function Arrive()
  Call("SetPaused", false)
  animAcc = 0
  SetAnim(ANIM_STAND)
  SetFace(FRONT)
  popScale, holdStart = 1, nil
  if replay then replay = false end
  -- am Ziel (dein Level): was du jetzt traegst, auf Hoechststufe der erste Stand dort
  local maxL = GetMaxPlayerLevel and GetMaxPlayerLevel() or 60
  local gm = ns.db and ns.db.wegGearMax
  SetGear(((UnitLevel("player") or 1) >= maxL and type(gm) == "table") and gm or nil)
  Place()
  if ns.db then ns.db.wegSeen = LOf(cur) end
  if fig then fig:SetScript("OnUpdate", nil) end
end

local holdUntil
local function PopTick(now)
  local dur = (holdUntil or now) - (holdStart or now)
  local t = now - (holdStart or now)
  local k = STOP.POP_IN / Tempo()
  local f
  if t < k then f = t / k elseif t > dur - k then f = math.max(0, (dur - t) / k) else f = 1 end
  popScale = 1 + (STOP.POP - 1) * f
  Place()
end
local function OnUpdate(_, el)
  if not (path and cur and target) then return end
  -- 1.4n: am Stopp stehen, kurz groesser werden, dann weiter
  if holdUntil then
    local now = GetTime()
    if now < holdUntil then PopTick(now); return end
    holdUntil, holdStart, popScale = nil, nil, 1
    Place()
  end
  AnimPace(el)
  el = math.min(el or 0, 0.1)
  local d = target - cur
  local stepLen = SPEED * Tempo() * el
  local nxt = (math.abs(d) <= stepLen) and target or (cur + (d > 0 and stepLen or -stepLen))
  if d > 0 then
    local st = StopBetween(LOf(cur), LOf(nxt))
    if st then
      lastStop = st
      cur = SLin(st)
      SetGear((GearAt(st)))
      holdStart = GetTime()
      holdUntil = holdStart + UPGRADE_STOP_S / Tempo()
      Call("SetPaused", false)
      SetAnim(ANIM_STAND)
      SetFace(FRONT)
      Place()
      if ns.TestLog then ns.TestLog("FENSTER", ("Mein Weg Stopp Level %d"):format(st)) end
      return
    end
  end
  if nxt == target then
    cur = target
    Place()
    Arrive()
    return
  end
  cur = nxt
  local dx, dy = Place()
  if d < 0 then dx, dy = -(dx or 0), -(dy or 0) end
  SetAnim(ANIM_WALK)
  if dx and math.abs(dx) > math.abs(dy or 0) then SetFace(dx > 0 and SIDE or -SIDE) else SetFace(0) end
end

local function Walk()
  if not (fig and path) then return end
  if not stops then BuildStops() end
  -- 1.4zl (M33): laeuft sie schon, nur das Ziel nachfuehren (vorher Neustart bei jedem Aufbau: Stopp abgebrochen,
  -- Ausruestung neu, Ruck)
  if cur and fig:GetScript("OnUpdate") then target = SOf(LevelNow()); return end
  holdUntil, holdStart, popScale = nil, nil, 1
  if not cur then cur = SLin((ns.db and tonumber(ns.db.wegSeen)) or 1) end
  target = SOf(LevelNow())
  -- Start: Ausruestung vom Stopp, auf dem die Figur steht, ohne Halt
  lastStop = StopAtOrBelow(LOf(cur))
  SetGear((GearAt(LOf(cur))))
  Place()
  if math.abs(target - cur) < 0.5 then cur = target; Place(); Arrive(); return end
  fig:SetScript("OnUpdate", OnUpdate)
end


local function MakeFig(pg)
  if dressFig then return fig end
  local ok, f = pcall(CreateFrame, "DressUpModel", nil, pg)
  if not ok or type(f) ~= "table" then ok, f = pcall(CreateFrame, "PlayerModel", nil, pg) end
  if not ok or type(f) ~= "table" then return nil end
  fig, dressFig = f, f
  f:EnableMouse(false)
  -- ueber den Karten, unter den Symbolen und den gelben Pfeilen
  f:SetFrameLevel((pg:GetFrameLevel() or 1) + 4)
  pcall(f.SetScript, f, "OnModelLoaded", function() if fig == dressFig then Refresh() end end)
  gearKey = nil
  SetGear(nil)
  pg:HookScript("OnShow", function()
    if not fig then return end
    -- 20.1 (P8): immer zu Fuss, Modell frisch vom Charakter
    if anim then Call("SetAnimation", anim) end
    gearKey = nil
    if not replay then SetGear(nil) end
    fig:Show()
    Walk()
  end)
  pg:HookScript("OnHide", function()
    if fig then fig:SetScript("OnUpdate", nil); Call("SetPaused", false) end
    if replay then replay = false; cur = target end
    holdUntil, holdStart, popScale = nil, nil, 1
    if ns.db and cur and path then ns.db.wegSeen = LOf(cur) end
  end)
  return f
end

-- Knopf Rueckblick auf der Karte Level 60
local function ReplayButton(pg, b)
  if not (b and b.st and b.st.lvl == 60) then
    if pg.wegReplay then pg.wegReplay:Hide() end
    if pg.wegTempo then pg.wegTempo:Hide() end
    return
  end
  local r = pg.wegReplay
  if not r then
    r = ns.T and ns.T.Button and ns.T.Button(b, TR"Rückblick", 92, 20) or CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    if not ns.T then r:SetSize(92, 20); r:SetText(TR"Rückblick") end
    r:SetScript("OnClick", function()
      if not (fig and path) then return end
      if pgRef then if anim then Call("SetAnimation", anim) end; fig:Show() end
      replay = true
      gearKey = nil
      cur = SOf(1)
      Walk()
    end)
    r:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Rückblick")
      GameTooltip:AddLine(TR"Dein Charakter läuft den ganzen Weg nochmal ab, in der Ausrüstung von damals (jedes Level).", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pg.wegReplay = r
  end
  r.card = b
  r:SetParent(b)
  r:ClearAllPoints()
  r:SetPoint("TOPRIGHT", b, "TOPRIGHT", -8, -8)
  r:SetFrameLevel(b:GetFrameLevel() + 8)
  r:Show()
  -- 19.36: Tempo Knopf direkt darunter, normal oder x2
  local s = pg.wegTempo
  if not s then
    s = ns.T and ns.T.Button and ns.T.Button(b, TR"Tempo: normal", 92, 20) or CreateFrame("Button", nil, b, "UIPanelButtonTemplate")
    if not ns.T then s:SetSize(92, 20) end
    local function Label() s:SetText(Tempo() == 2 and TR"Tempo: x2" or TR"Tempo: normal") end
    s.Label = Label
    s:SetScript("OnClick", function()
      if ns.db then ns.db.wegTempo = (Tempo() == 2) and 1 or 2 end
      Label()
    end)
    s:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Tempo der Figur")
      GameTooltip:AddLine(TR"Wie schnell deine Figur in Mein Weg läuft: normal oder doppelt so schnell. Nur die Anzeige, die Route bleibt gleich.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pg.wegTempo = s
  end
  s:SetParent(b)
  s:ClearAllPoints()
  s:SetPoint("TOPRIGHT", r, "BOTTOMRIGHT", 0, -4)
  s:SetFrameLevel(b:GetFrameLevel() + 8)
  if s.Label then s.Label() end
  s:Show()
end

-- aus CharTab (Mein Weg): nach jedem Layout und Fuellen
-- 1.4zm (M33 Test, Pr 18:48): Stelle der Figur (Strecke, Ziel, Level an der Stelle) und Neuaufbau fuer den Sim Waechter
function ns.WegFigurPos()
  if not (path and cur) then return nil end
  return cur, target, LOf(cur)
end
function ns.WegFigurRelayout() if pgRef and ns.WegFigurLayout then return ns.WegFigurLayout(pgRef) end end
function ns.WegFigurLayout(pg)
  pgRef = pg
  -- Symbole in einen eigenen Rahmen ueber der Figur: sie laeuft hinter ihnen durch
  for _, b in ipairs(pg.cards or {}) do
    if not b.iconF and b.icon then
      b.iconF = CreateFrame("Frame", nil, b)
      b.iconF:SetAllPoints(b)
      b.iconF:EnableMouse(false)
      b.icon:SetParent(b.iconF)
      if b.iconBg then b.iconBg:SetParent(b.iconF) end
    end
    if b.iconF then b.iconF:SetFrameLevel(b:GetFrameLevel() + 6) end
  end
  local w = pg:GetWidth() or 0
  -- Groesse geaendert: gleiche Stelle (Level) auf dem neuen Weg
  local keepL = (path and cur) and LOf(cur) or nil
  local keepT = (path and target) and LOf(target) or nil
  path = (w > 300) and BuildPath(pg) or nil
  stops = nil
  if path then BuildStops() end
  -- 1.4zl (M33, S 13:34 "springt oft hin und her"): Stelle mit der genauen Umkehrung (SLin) halten. Vorher SOf, das in
  -- der eigenen Karte auf 30 % staucht: bei jedem neuen Aufbau der Seite sprang die Figur ein Stueck zurueck
  if path and keepL then cur = SLin(keepL) end
  if path and keepT then target = SLin(keepT) end
  local last
  for _, b in ipairs(pg.cards or {}) do if b:IsShown() and b.st then last = b end end
  ReplayButton(pg, last)
  if not path then if fig then fig:Hide() end return end
  if not MakeFig(pg) then return end
  fig:SetFrameLevel((pg:GetFrameLevel() or 1) + 4)
  fig:SetShown(pg:IsShown())
  if pg:IsVisible() then Walk() end
end
