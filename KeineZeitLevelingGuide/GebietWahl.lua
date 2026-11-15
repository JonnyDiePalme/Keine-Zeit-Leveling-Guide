local ADDON, ns = ...
local TR = ns.TR

-- 1.4g (P193, S 11.36): "Neu rechnen" von Hand fragt kurz, wo es losgehen soll. Oben "Schnellste Route" (vorgewaehlt,
-- Enter), darunter bis GW.MAX andere Gebiete fuer dein Level mit Level Bereich, ca XP pro Std (wenn gemessen) und Anreise.
-- Alles aus den Daten: ns.zones (Level Bereich je Zone, auch neue aus Questie), eigene Messung ns.PerfData. Nichts fest.
-- Klick auf ein Gebiet: Navi dorthin, beim Ankommen rechnet die Route ab dort neu, danach wieder ganz normal.
-- Nur beim Klick von Hand, nie beim automatischen Nachrechnen. Schalter db.askZone (Einstellungen) und Haken im Fenster.
ns.GW = { MAX = 4, UNDER = 1, OVER = 1, PATH = 1.2 }
local GW = ns.GW
local win

local function Clock(s) return ns.Clock and ns.Clock(s) or tostring(math.floor(s or 0)) end

local function Choices()
  local out = {}
  local L = UnitLevel("player") or 1
  local pm = ns.PlayerMap and ns.PlayerMap()
  local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
  local px, py
  if pos then px, py = pos:GetXY() end
  local cur = (ns.CurZone and ns.CurZone()) or pm
  if ns.cityParent and cur and ns.cityParent[cur] then cur = ns.cityParent[cur] end
  local perf
  if ns.PerfData then local ok, p = pcall(ns.PerfData); perf = ok and p and p.zones end
  local speed = (ns.PlanSpeed and ns.PlanSpeed()) or 7
  for id, z in pairs(ns.zones or {}) do
    if id ~= cur and z.min and z.max and L >= z.min - GW.UNDER and L <= z.max - GW.OVER then
      local d = (pm and px and ns.WorldDistXY) and ns.WorldDistXY(pm, px, py, id, 0.5, 0.5) or nil
      local sec = d and d * GW.PATH / speed or nil
      local zs = perf and perf[id]
      local xph = zs and type(zs.xp) == "number" and type(zs.t) == "number" and zs.t > 600 and math.floor(zs.xp * 3600 / zs.t) or nil
      out[#out + 1] = { id = id, name = ns.ZoneName and ns.ZoneName(id) or tostring(id), min = z.min, max = z.max, sec = sec, xph = xph }
    end
  end
  table.sort(out, function(a, b)
    if (a.sec ~= nil) ~= (b.sec ~= nil) then return a.sec ~= nil end
    if a.sec and b.sec and a.sec ~= b.sec then return a.sec < b.sec end
    return a.name < b.name
  end)
  while #out > GW.MAX do table.remove(out) end
  return out
end

local function Fastest()
  if win then win:Hide() end
  if ns.TestLog then ns.TestLog("KNOPF", "Gebiet waehlen: Schnellste Route") end
  if ns.AutoOpt then ns.AutoOpt("hand") end
end

local function GoZone(c)
  if win then win:Hide() end
  if ns.TestLog then ns.TestLog("KNOPF", ("Gebiet waehlen: %s (Karte %s)"):format(tostring(c.name), tostring(c.id))) end
  ns.db.gwZone = c.id
  if ns.ZielNavi then ns.ZielNavi(c.id, 0.5, 0.5, c.name, "gebiet") end
  ns.Print((TR"Navi nach %s. Dort rechnet die Route ab da neu."):format(c.name))
end

local function Build()
  local T = ns.T
  win = CreateFrame("Frame", "ForeverWegweiserGebietWahl", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  win:SetSize(300, 100)
  win:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  win:SetFrameStrata("DIALOG")
  win:SetClampedToScreen(true)
  win:EnableMouse(true)
  win:SetMovable(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", win.StopMovingOrSizing)
  if T then T.Skin(win, "window") end
  win.title = win:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  win.title:SetPoint("TOP", 0, -12)
  win.title:SetText(TR"Wo soll es losgehen?")
  win.close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  win.close:SetPoint("TOPRIGHT", -2, -2)
  if T and T.SkinClose then pcall(T.SkinClose, win.close) end
  win.fast = T and T.Button(win, TR"Schnellste Route", 270, 24, true) or CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  win.fast:SetSize(270, 24); win.fast:SetText(TR"Schnellste Route")
  win.fast:SetPoint("TOP", 0, -36)
  win.fast:SetScript("OnClick", Fastest)
  win.rows = {}
  win.ask = CreateFrame("CheckButton", nil, win, "UICheckButtonTemplate")
  win.ask:SetSize(22, 22)
  win.ask.txt = win:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  win.ask.txt:SetPoint("LEFT", win.ask, "RIGHT", 2, 0)
  win.ask.txt:SetText(TR"nicht mehr fragen")
  win.ask:SetScript("OnClick", function(self) ns.db.askZone = not self:GetChecked() end)
  -- Enter = Schnellste Route, Esc = zu. Tastatur nur solange das Fenster offen ist, andere Tasten gehen ans Spiel weiter
  win:EnableKeyboard(true)
  win:SetScript("OnKeyDown", function(self, key)
    local pass = not (key == "ENTER" or key == "ESCAPE")
    if self.SetPropagateKeyboardInput and not (InCombatLockdown and InCombatLockdown()) then pcall(self.SetPropagateKeyboardInput, self, pass) end
    if key == "ENTER" then Fastest() elseif key == "ESCAPE" then self:Hide() end
  end)
  win:Hide()
end

-- Menue "Neu rechnen" von Hand
function ns.NeuRechnenFrage()
  local db = ns.db
  if not db then return end
  local list = (db.askZone ~= false and not (InCombatLockdown and InCombatLockdown()) and db.optMode) and Choices() or {}
  if #list == 0 then return Fastest() end
  if not win then Build() end
  local T = ns.T
  for i, c in ipairs(list) do
    local r = win.rows[i]
    if not r then
      r = T and T.Button(win, "", 270, 22) or CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
      r:SetSize(270, 22)
      r:SetPoint("TOP", win.fast, "BOTTOM", 0, -6 - (i - 1) * 25)
      win.rows[i] = r
    end
    local info = {}
    info[#info + 1] = ("%d-%d"):format(c.min, c.max)
    if c.xph then info[#info + 1] = (TR"ca %s XP/Std"):format(ns.Num and ns.Num(c.xph) or tostring(c.xph)) end
    info[#info + 1] = c.sec and (TR"Anreise ca %s"):format(Clock(c.sec)) or TR"anderer Kontinent"
    r:SetText(("%s  |cff9d9d9d%s|r"):format(c.name, table.concat(info, ", ")))
    r:SetScript("OnClick", function() GoZone(c) end)
    r:Show()
  end
  for i = #list + 1, #win.rows do win.rows[i]:Hide() end
  win.ask:ClearAllPoints()
  win.ask:SetPoint("TOPLEFT", win.fast, "BOTTOMLEFT", 0, -10 - #list * 25)
  win.ask:SetChecked(false)
  win:SetHeight(36 + 24 + 10 + #list * 25 + 34)
  win:Show()
  if ns.TestLog then
    local t = {}
    for _, c in ipairs(list) do t[#t + 1] = c.name end
    ns.TestLog("FENSTER", "Gebiet waehlen: Schnellste Route, " .. table.concat(t, ", "))
  end
end

-- angekommen im gewaehlten Gebiet: einmal neu rechnen, dann wieder normal
local ev = CreateFrame("Frame")
ns.RegEv(ev, "ZONE_CHANGED_NEW_AREA")
ev:SetScript("OnEvent", function()
  C_Timer.After(2, function()
    local db = ns.db
    if not (db and db.gwZone) then return end
    local m = ns.PlayerMap and ns.PlayerMap()
    if ns.cityParent and m and ns.cityParent[m] then m = ns.cityParent[m] end
    if m == db.gwZone then
      db.gwZone = nil
      if ns.navi and ns.NaviStop then pcall(ns.NaviStop, TR"Angekommen, die Route rechnet ab hier.") end
      if ns.TestLog then ns.TestLog("ROUTE", "Gebiet waehlen: angekommen, rechne ab hier") end
      if ns.AutoOpt then ns.AutoOpt("hand") end
    end
  end)
end)
