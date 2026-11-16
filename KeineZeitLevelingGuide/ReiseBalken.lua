local ADDON, ns = ...
local TR = ns.TR

-- 1.4a (P151 Pfeil Punkt 3, P150 Mini Fenster Punkt 4 und 5, S 11.11.): Reise Balken.
-- Flugzeit und Abfahrt (Zeppelin, Schiff, Tiefenbahn) als Balken mit dem Text im Balken. Immer sichtbar, auch in der Pause:
--   Mini Fenster an: im Mini Fenster ueber dem Level Balken (1.4zh, S 13:38). Sonst Pfeil an: unter dem Text vom Pfeil.
--   Beides aus: allein (verschiebbar).
-- Flug oben, die naechste Abfahrt darunter (zb Flug nach Orgrimmar, danach Zeppelin nach Unterstadt).
-- 1.4zu (M43): der Flug Balken hat seinen eigenen Kasten am Pfeil (auch in der Pause und mit Pfeil aus), im Mini Fenster
-- stehen nur noch Abfahrt und Fahrt (Zeppelin, Schiff, Tiefenbahn).
-- Abfahrt nur, wenn sie in den naechsten 3 Schritten kommt und du in hoechstens 15 Min dort bist (Navi.lua ns.DepartBar).
-- Puffer = Abfahrt minus deine Ankunft. Zwischen minus und plus RB.KNAPP_S oder darunter: Balken rot.
ns.RB = { W = 170, H = 14, GAP = 3, KNAPP_S = 30, TICK_S = 0.5, NAME_MAX = 22, NAME_PUF = 16, STEG_YD = 600 }
-- 1.5a (M66, S 17:46): Abfahrten am Steg oder Turm schon ab 600 yd (vorher 200), auch in der Pause. Nur hier einstellen
local RB = ns.RB
ns.ReiseBalkenOn = true

local box, bars, where = nil, {}, nil
-- 1.4zu (M43, S 22:58: "Flegen immer unterhalb vom Pfeil und das soll immer eingeblendet sein egal ob addon pausiert pfeil
-- ausgeblendet ist", im Mini Fenster nur die Zeppeline): eigener Kasten fuer den Flug Balken, immer an der Stelle vom Pfeil
local fbox, fbars = nil, {}
local totals = {}      -- Abfahrt: erste Wartezeit je Fahrt (Fortschritt des Balkens)
local lastLog
local onKeys = {}      -- 1.4f (Pr M2): welche Balken gerade an sind, fuer die Log Zeile "Balken an"
local rideOn, rideAt   -- 1.4zf (M28): Fahrt Abschnitt und Einsteige Zeit

local function Clock(s) return ns.Clock and ns.Clock(s) or tostring(math.floor(s or 0)) end
-- 1.4zh (M32, S 13:38: Text zu lang, endet mit "-0..."): im Balken nur m:ss (ohne "Min"), ab 1 Std h:mm
local function MS(s)
  s = math.max(0, math.floor(s or 0))
  if s >= 3600 then return ("%d:%02d h"):format(math.floor(s / 3600), math.floor((s % 3600) / 60)) end
  return ("%d:%02d"):format(math.floor(s / 60), s % 60)
end
-- "Zeppelin nach Grom'gol" -> "Zeppelin Grom'gol"
local function ShortName(t) return (tostring(t or ""):gsub(TR" nach ", " ", 1)) end
local function Short(t, n)
  t = tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  local c, out = 0, {}
  for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    c = c + 1
    if c > n then return table.concat(out) .. ".." end
    out[#out + 1] = ch
  end
  return t
end

local function MakeBar(i, parent, tbl)
  local b = CreateFrame("StatusBar", nil, parent or box)
  b:SetHeight(RB.H)
  b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(0, 0, 0, 0.55)
  b.txt = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  b.txt:SetPoint("LEFT", 4, 0)
  b.txt:SetPoint("RIGHT", -4, 0)
  b.txt:SetJustifyH("CENTER")
  b.txt:SetWordWrap(false)
  b:EnableMouse(true)
  b:SetScript("OnEnter", function(self)
    if not self.tip then return end
    ns.TipOwner(self, "ANCHOR_BOTTOM")
    for k, l in ipairs(self.tip) do
      if k == 1 then GameTooltip:AddLine(l) else GameTooltip:AddLine(l, 1, 1, 1, true) end
    end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local t = tbl or bars
  t[i] = b
  return b
end

-- Die Balken, die gerade gelten (Flug zuerst, dann die Abfahrt)
local function Lines()
  local out = {}
  local flying = ns.InFlight and ns.InFlight()
  if flying then
    local left, total, src
    if ns.FlightNow then
      local ok, l, t, s = pcall(ns.FlightNow)
      if ok and l and t and t > 0 then left, total, src = l, t, s end
    end
    local to = ns.FlightTo and ns.FlightTo()
    local fm = to and ns.FlightMasterById and ns.FlightMasterById(to)
    -- 1.4zzk (M43, S Abhak 01:45: bei Donnerfels stand nur "Tal"): fm.name ist der Flugmeister, nicht der Ort. Jetzt der Ort
    -- (Karte des Flugmeisters), der Flugmeister steht im Tip
    local mi = fm and fm.map and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(fm.map)
    local place = (mi and mi.name and mi.name ~= "" and mi.name) or (fm and fm.name)
    local name = place and Short(place, RB.NAME_MAX)
    if left then
      out[#out + 1] = { key = "flug", val = total - left, max = total, col = { 0.4, 0.8, 1 },
        text = name and (TR"Flug nach %s  %s"):format(name, MS(left)) or (TR"Flug  noch %s"):format(MS(left)),
        tip = { TR"Flug", (TR"Noch %s von %s"):format(Clock(left), Clock(total)),
          src == "geteilt" and TR"Flugzeit von anderen Spielern geteilt" or TR"Flugzeit selbst gemessen",
          place and fm and fm.name and fm.name ~= place and (TR"Ankunft: %s, bei %s"):format(place, fm.name) or nil } }
    else
      out[#out + 1] = { key = "flug", val = 0, max = 1, col = { 0.4, 0.8, 1 },
        text = name and (TR"Flug nach %s"):format(name) or TR"Im Flug",
        tip = { TR"Flug", TR"Die Flugzeit für diese Strecke ist noch nicht bekannt. Nach der Landung ist sie gemessen." } }
    end
  end
  -- 1.4zj (M35, S 14:43): im Flug oder in der Pause nur der Flug Balken, Abfahrt und Fahrt weg
  -- 1.5a (M66): in der Pause bleibt die Liste der Abfahrten am Steg (unten), nur Fahrt und Abfahrt der Route fallen weg
  if flying then return out end
  local paused = ns.db and ns.db.paused
  -- 1.4zf (M28, S Durchsicht 13:44: Zeppelin fehlt als Teilstrecke): auf Schiff oder Zeppelin ein Balken wie beim Flug,
  -- Fahrzeit aus Travel.lua (ns.TravelRide), Start beim Einsteigen (ns.WalkOnBoat)
  if not flying and not paused then
    local nv = ns.navi
    local lg = nv and not nv.hidden and nv.legs and nv.legs[nv.cur]
    local onBoat = ns.WalkOnBoat and ns.WalkOnBoat()
    if lg and lg.kind == "ride" and onBoat then
      if rideOn ~= lg then rideOn, rideAt = lg, GetTime() end
      local total = (lg.l and ns.TravelRide and ns.TravelRide(lg.l, lg.side)) or 120
      local left = math.max(0, total - (GetTime() - rideAt))
      local nm = Short(ShortName(lg.text or TR"Fahrt"), RB.NAME_MAX)
      out[#out + 1] = { key = "fahrt", val = total - left, max = math.max(1, total), col = { 0.9, 0.75, 0.3 },
        text = ("%s  %s"):format(nm, MS(left)), tip = { tostring(lg.text or TR"Fahrt"), (TR"Noch ca %s von %s"):format(Clock(left), Clock(total)) } }
    elseif not onBoat then
      rideOn, rideAt = nil, nil
    end
  end
  local d = not paused and ns.DepartBar and ns.DepartBar() or nil
  if d then
    local key = tostring(d.name)
    local tot = totals[key]
    -- neue Runde (Abfahrt ist vorbei, die naechste ist weiter weg): Fortschritt neu
    if not tot or d.leave > tot + 1 then tot = d.leave; totals[key] = tot end
    local col, extra = { 0.4, 1, 0.6 }, ""
    local tip = { tostring(d.name), (TR"Fährt in %s"):format(Clock(d.leave)) }
    if d.need then
      local buf = d.leave - d.need
      extra = "  " .. (buf >= 0 and "+" or "-") .. Clock(math.abs(buf))
      if buf <= RB.KNAPP_S then col = { 1, 0.25, 0.25 } end
      tip[#tip + 1] = (TR"Du bist in ca %s dort."):format(Clock(d.need))
      tip[#tip + 1] = buf >= 0 and (TR"Puffer %s"):format(Clock(buf)) or TR"Reicht knapp nicht, dann die nächste Abfahrt."
      tip[#tip + 1] = (TR"Rot: Puffer unter %d Sekunden"):format(RB.KNAPP_S)
    end
    -- 1.4zh (M32): Puffer nur im Tooltip und als Farbe, im Balken Name und Abfahrt
    -- 1.4zz (M47, S 04:31: "wenn es nicht reicht von der zeit oder doch sollte der puffer angezeigt werden"): Puffer kurz
    -- dahinter (+m:ss reicht, -m:ss reicht nicht), der Name dafuer etwas kuerzer
    local pf = ""
    if d.need then
      local buf = d.leave - d.need
      pf = "  " .. (buf >= 0 and "+" or "-") .. MS(math.abs(buf))
    end
    out[#out + 1] = { key = "abfahrt", val = tot - d.leave, max = math.max(1, tot), col = col,
      text = ("%s  %s%s"):format(Short(ShortName(d.name), d.need and RB.NAME_PUF or RB.NAME_MAX), MS(d.leave), pf), tip = tip }
  end
  -- 1.4zzd (M48, S 10:34: "wenn ich dem zeppelin punkt naeher komme ... sollten die abfahrten im minifenster aufgelistet werden"):
  -- naeher als RB.STEG_YD an einem Steg oder Turm: alle Abfahrten von dort untereinander (grau, nur zur Info). Die Fahrt der
  -- Route (Balken oben, mit Puffer) kommt nicht doppelt
  if ns.travelLinks and ns.TravelDeparts and ns.WorldDist and ns.PlayerMap and not (ns.WalkOnBoat and ns.WalkOnBoat()) then
    local pm = ns.PlayerMap()
    local pos = pm and C_Map.GetPlayerMapPosition(pm, "player")
    if pos then
      local px, py = pos:GetXY()
      local fac = UnitFactionGroup and UnitFactionGroup("player")
      local routeDest = d and tostring(d.name or "")
      local seen = {}
      for _, l in ipairs(ns.travelLinks) do
        if not l.faction or l.faction == fac then
          for _, sd in ipairs({ "a", "b" }) do
            local e, o = l[sd], l[sd == "a" and "b" or "a"]
            if e and e[2] and o then
              local dist = ns.WorldDist({ pm, px, py }, { e[1], e[2], e[3] })
              local key = tostring(l.id) .. sd
              if dist and dist < RB.STEG_YD and not seen[key] then
                seen[key] = true
                local keep = ns.lastNautRaw
                local ok, w = pcall(ns.TravelDeparts, l.id, sd, l.idx)
                ns.lastNautRaw = keep
                local dest = tostring(o[4] or "?")
                if ok and type(w) == "number" and not (routeDest and routeDest:find(dest, 1, true)) then
                  -- 1.5a (M67, S 18:15): auch hier ein Balken, der sich bis zur Abfahrt fuellt (wie die Abfahrt der Route, grau)
                  local tk = "steg:" .. key
                  local tot = totals[tk]
                  if not tot or w > tot + 1 then tot = math.max(1, w); totals[tk] = tot end
                  out[#out + 1] = { key = "steg", val = tot - w, max = tot, col = { 0.45, 0.45, 0.45 },
                    text = ("%s  %s"):format(Short(ShortName((TR"%s nach %s"):format(tostring(l.kind), dest)), RB.NAME_MAX), MS(w)),
                    tip = { (TR"%s nach %s"):format(tostring(l.kind), dest), (TR"Fährt in %s"):format(Clock(w)), TR"Nur zur Info, nicht in deiner Route" } }
                end
              end
            end
          end
        end
      end
    end
  end
  return out
end

local function Where()
  -- 1.4zh (M32, S 13:38: Zeppelin im Mini Fenster wie besprochen): Mini Fenster offen geht vor, sonst unter dem Pfeil
  local hud = _G.TaurenRouteHUD
  if hud and hud:IsShown() then return "hud", hud end
  local a = _G.TaurenRouteArrow
  if a and a:IsShown() and a.text and a.text:IsVisible() then return "pfeil", a end
  return "allein"
end

-- Mini Fenster fragt, wie viel Platz es ueber dem Level Balken lassen muss
local hudH = 0
function ns.ReiseBalkenHudH() return hudH end

local function Build()
  box = CreateFrame("Frame", "ForeverWegweiserReise", UIParent)
  box:SetSize(RB.W, RB.H)
  box:SetFrameStrata("MEDIUM")
  box:SetClampedToScreen(true)
  box:SetMovable(true)
  box:EnableMouse(false)
  box:RegisterForDrag("LeftButton")
  box:SetScript("OnDragStart", function(self) if where == "allein" then self:StartMoving() end end)
  box:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local a, _, b, x, y = self:GetPoint()
    if ns.db then ns.db.reisePos = { a, b, x, y } end
  end)
  box:Hide()
  fbox = CreateFrame("Frame", "ForeverWegweiserReiseFlug", UIParent)
  fbox:SetSize(RB.W, RB.H)
  fbox:SetFrameStrata("MEDIUM")
  fbox:SetClampedToScreen(true)
  fbox:Hide()
end
-- Flug Balken: unter dem Text vom Pfeil, ist der Pfeil aus (oder Pause), an der Stelle vom Pfeil
local function FlightBar(fl)
  if not fl then
    for _, b in ipairs(fbars) do b:Hide() end
    fbox:Hide()
    return "aus"
  end
  local b = fbars[1] or MakeBar(1, fbox, fbars)
  b:SetWidth(RB.W)
  b:ClearAllPoints()
  b:SetPoint("TOP", fbox, "TOP", 0, 0)
  b:SetMinMaxValues(0, fl.max)
  b:SetValue(math.max(0, math.min(fl.max, fl.val)))
  b:SetStatusBarColor(fl.col[1], fl.col[2], fl.col[3], 0.9)
  b.txt:SetText(fl.text)
  b.tip = fl.tip
  b:Show()
  fbox:SetSize(RB.W, RB.H)
  fbox:ClearAllPoints()
  local a = _G.TaurenRouteArrow
  local at
  if a and a:IsShown() and a.text and a.text:IsVisible() then
    fbox:SetScale(a:GetScale() or 1)
    fbox:SetPoint("TOP", a.text, "BOTTOM", 0, -3)
    at = "pfeil"
  elseif a and a:GetCenter() then
    fbox:SetScale(a:GetScale() or 1)
    fbox:SetPoint("CENTER", a, "CENTER", 0, 0)
    at = "pfeil platz"
  else
    fbox:SetScale(1)
    fbox:SetPoint("TOP", UIParent, "TOP", 0, -150)
    at = "oben"
  end
  fbox:Show()
  return at
end

local function Update()
  if not ns.db then return end
  if not box then Build() end
  local all = Lines()
  local list, fl = {}, nil
  for _, l in ipairs(all) do if l.key == "flug" then fl = l else list[#list + 1] = l end end
  local fat = FlightBar(fl)
  local w, anchor = Where()
  where = w
  -- Log: neue Balken oder andere Farbe
  if ns.TestLog then
    local sig = {}
    for _, l in ipairs(all) do sig[#sig + 1] = l.key .. ":" .. tostring(l.text):gsub("%d+:%d+", "") .. ":" .. (l.col[1] > 0.9 and "rot" or "ok") end
    local s = table.concat(sig, "|") .. "@" .. w .. (fl and ("/flug " .. fat) or "")
    if s ~= lastLog then lastLog = s; ns.TestLog("REISE", ("Balken %s: %s%s"):format(w, #sig > 0 and table.concat(sig, ", ") or "keine", fl and (", Flug bei " .. fat) or "")) end
  end
  -- 1.4f (Pr 11:05, M2 Test): beim Aufgehen eines Balkens eine eigene Zeile "Balken an flug|zeppelin|schiff|..."
  do
    local now = {}
    for _, l in ipairs(all) do
      local k = (l.key == "flug" or l.key == "fahrt") and l.key or (tostring(l.text):match("^(%S+)") or "abfahrt"):lower()
      now[k] = true
      if not onKeys[k] and ns.TestLog then ns.TestLog("REISE", ("Balken an %s (%s)"):format(k, k == "flug" and fat or w)) end
    end
    onKeys = now
  end
  local n = #list
  local width = RB.W
  if w == "hud" then width = math.max(80, (anchor:GetWidth() or 256) - 18) end
  for i = 1, n do
    local b = bars[i] or MakeBar(i)
    local l = list[i]
    b:SetWidth(width)
    b:ClearAllPoints()
    b:SetPoint("TOP", box, "TOP", 0, -(i - 1) * (RB.H + RB.GAP))
    b:SetMinMaxValues(0, l.max)
    b:SetValue(math.max(0, math.min(l.max, l.val)))
    b:SetStatusBarColor(l.col[1], l.col[2], l.col[3], 0.9)
    b.txt:SetText(l.text)
    b.tip = l.tip
    b:Show()
  end
  for i = n + 1, #bars do bars[i]:Hide() end
  local h = n > 0 and (n * RB.H + (n - 1) * RB.GAP) or 0
  local newHud = (w == "hud" and n > 0) and (h + 4) or 0
  if newHud ~= hudH then hudH = newHud; if ns.RefreshHud then pcall(ns.RefreshHud) end end
  if n == 0 then box:Hide(); return end
  box:SetSize(width, h)
  box:ClearAllPoints()
  box:EnableMouse(w == "allein")
  if w == "pfeil" then
    box:SetScale(anchor:GetScale() or 1)
    box:SetPoint("TOP", anchor.text, "BOTTOM", 0, -3)
  elseif w == "hud" then
    box:SetScale(anchor:GetScale() or 1)
    local xb = anchor.xbar
    if xb and xb:IsShown() then box:SetPoint("BOTTOM", xb, "TOP", 0, 4)
    else box:SetPoint("BOTTOM", anchor, "BOTTOM", 0, 34) end
  else
    box:SetScale(1)
    local p = ns.db.reisePos
    if p then box:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else box:SetPoint("TOP", UIParent, "TOP", 0, -180) end
  end
  box:Show()
end
ns.ReiseBalkenUpdate = Update

local ev = CreateFrame("Frame")
ns.RegEv(ev, "PLAYER_LOGIN")
ev:SetScript("OnEvent", function()
  -- 1.4zj (M35, S 14:43: Balken beim Pausieren eingefroren): laeuft auch in der Pause (der Ticker stand dort still)
  -- 1.5a (M65, S 17:44: in der Pause nur alle 5 s): keep = true, sonst drosselt der Ruhe Modus (ns.Idle, ns.LowPower) den
  -- Takt. Der Balken ist klein und zaehlt immer jede Sekunde weiter, der Rest vom Ruhe Modus bleibt
  C_Timer.After(2, function() ns.Ticker(RB.TICK_S, function() local ok, err = pcall(Update); if not ok and ns.TestLog then ns.TestLog("REISE", "Fehler " .. tostring(err)) end end, true, true) end)
end)
