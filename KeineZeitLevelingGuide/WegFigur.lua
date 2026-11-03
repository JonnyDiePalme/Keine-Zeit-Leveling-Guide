-- Mein Weg: kleine Figur vom eigenen Charakter, die den Weg bis 60 entlang laeuft (17.4, Wunsch Sascha).
-- Das 3D Modell zeichnet WoW selbst (wie im Charakterfenster), mit der Ausruestung, die man gerade traegt.
-- Alle 5 Level merkt sich das Addon die Ausruestung (pro Charakter, db.wegGear). Der Knopf Rueckblick auf der
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

local function Snap(L)
  local db = ns.db
  if not db then return end
  L = tonumber(L) or UnitLevel("player")
  if not L or L < 5 or L % 5 ~= 0 then return end
  local g = GearNow()
  if not g then return end
  if type(db.wegGear) ~= "table" then db.wegGear = {} end
  db.wegGear[L] = g
end
ns.WegGearSnap = Snap

-- Ausruestung fuer Level L: der Stand bei der 5er Stufe darunter, fehlt der, die naechste hoehere.
-- Nichts gemerkt bis zum jetzigen Level: nil, dann zeigt die Figur, was du jetzt traegst.
local function GearFor(L)
  local g = ns.db and ns.db.wegGear
  if type(g) ~= "table" then return nil end
  local cur = UnitLevel("player") or 60
  local b = math.max(5, math.floor(L / 5) * 5)
  while b <= cur and b <= 60 do
    if type(g[b]) == "table" then return g[b], b end
    b = b + 5
  end
  return nil
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LEVEL_UP")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, e, a1)
  if e == "PLAYER_LEVEL_UP" then
    -- beim Event ist UnitLevel manchmal noch das alte Level
    pcall(Snap, a1)
  elseif e == "PLAYER_EQUIPMENT_CHANGED" then
    pcall(Snap)
  else
    -- beim Einloggen: auf einer 5er Stufe und noch nichts gemerkt
    local L = UnitLevel("player")
    local g = ns.db and ns.db.wegGear
    if L and L % 5 == 0 and not (type(g) == "table" and g[L]) then pcall(Snap, L) end
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

local function SetGear(g)
  local key = g and tostring(g) or "jetzt"
  if key == gearKey then return end
  gearKey, wantGear = key, g
  Call("SetUnit", "player")
  Refresh()
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

local function Place()
  if not (fig and path and cur) then return end
  local x, y, dx, dy = PointAt(cur)
  local h = math.max(28, math.floor((path.ch or 80) * FIG_H))
  fig:SetSize(h * 0.75, h)
  fig:ClearAllPoints()
  -- das Modell hat unter den Fuessen etwas Luft: ein Stueck tiefer setzen
  fig:SetPoint("BOTTOM", pgRef, "TOPLEFT", x, y - h * 0.06)
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
  if replay then replay = false; SetGear(nil) end
  if ns.db then ns.db.wegSeen = LOf(cur) end
  if fig then fig:SetScript("OnUpdate", nil) end
end

local function OnUpdate(_, el)
  if not (path and cur and target) then return end
  AnimPace(el)
  el = math.min(el or 0, 0.1)
  local d = target - cur
  local stepLen = SPEED * Tempo() * el
  if math.abs(d) <= stepLen then
    cur = target
    Place()
    Arrive()
    return
  end
  cur = cur + (d > 0 and stepLen or -stepLen)
  local dx, dy = Place()
  if d < 0 then dx, dy = -(dx or 0), -(dy or 0) end
  SetAnim(ANIM_WALK)
  if dx and math.abs(dx) > math.abs(dy or 0) then SetFace(dx > 0 and SIDE or -SIDE) else SetFace(0) end
  -- Rueckblick: alle 5 Level die Ausruestung von damals
  if replay then SetGear(GearFor(LOf(cur))) end
end

local function Walk()
  if not (fig and path) then return end
  if not cur then cur = SOf((ns.db and tonumber(ns.db.wegSeen)) or 1) end
  target = SOf(LevelNow())
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
    if replay then replay = false; cur = target; SetGear(nil) end
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
      SetGear(GearFor(1))
      Walk()
    end)
    r:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Rückblick")
      GameTooltip:AddLine(TR"Dein Charakter läuft den ganzen Weg nochmal ab, in der Ausrüstung von damals (alle 5 Level).", 1, 1, 1, true)
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
  if path and keepL then cur = SOf(keepL) end
  if path and keepT then target = SOf(keepT) end
  local last
  for _, b in ipairs(pg.cards or {}) do if b:IsShown() and b.st then last = b end end
  ReplayButton(pg, last)
  if not path then if fig then fig:Hide() end return end
  if not MakeFig(pg) then return end
  fig:SetFrameLevel((pg:GetFrameLevel() or 1) + 4)
  fig:SetShown(pg:IsShown())
  if pg:IsVisible() then Walk() end
end
