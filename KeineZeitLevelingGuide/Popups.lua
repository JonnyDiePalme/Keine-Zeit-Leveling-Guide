local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Kleine Fenster (P1): Einkaufsliste, Questlog Warnung

------------------------------------------------------------
-- Einkaufsliste
------------------------------------------------------------
local shop
function ns.ShowShopping()
  local T = ns.T
  if not T then if ns.PrintShopping then ns.PrintShopping() end return end
  local list = ns.ShoppingList and ns.ShoppingList() or {}
  if not shop then
    shop = T.Popup("ForeverWegweiserShop", 380, TR"Einkaufsliste")
    shop.rows = {}
    shop.go = T.Button(shop, TR"Pfeil zum Händler", 160, 22)
    shop.go:SetPoint("BOTTOMLEFT", 14, 12)
    shop.go:SetScript("OnClick", function() if ns.FindVendor then ns.FindVendor() end end)
    shop.ok = T.Button(shop, TR"Erledigt", 120, 22, true)
    shop.ok:SetPoint("BOTTOMRIGHT", -14, 12)
    shop.ok:SetScript("OnClick", function() shop:Hide() end)
  end
  if #list == 0 then
    shop.body:SetText(TR"Nichts nötig. Alle Quest Sachen kommen von Mobs oder Objekten.")
  else
    shop.body:SetText(TR"Für deine Quests, beim nächsten Händler kaufen:")
  end
  for _, r in ipairs(shop.rows) do r:Hide() end
  local y = -62
  for i, e in ipairs(list) do
    if i > 10 then break end
    local r = shop.rows[i]
    if not r then
      r = CreateFrame("Frame", nil, shop)
      r:SetHeight(18)
      r.n = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
      r.n:SetPoint("LEFT", 0, 0); r.n:SetWidth(170); r.n:SetJustifyH("LEFT"); r.n:SetWordWrap(false)
      r.w = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
      r.w:SetPoint("LEFT", r.n, "RIGHT", 6, 0); r.w:SetPoint("RIGHT", r, "RIGHT", -40, 0); r.w:SetJustifyH("LEFT"); r.w:SetWordWrap(false)
      r.a = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
      r.a:SetPoint("RIGHT", 0, 0)
      shop.rows[i] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", shop, "TOPLEFT", 14, y)
    r:SetPoint("RIGHT", shop, "RIGHT", -14, 0)
    r.n:SetText(e.name or "?")
    r.w:SetText(("%s, %s"):format(e.quest or "", e.where or ""))
    r.a:SetText(e.need and tostring(math.max(0, e.need - (e.have or 0))) or "")
    r:Show()
    y = y - 20
  end
  shop:SetHeight(-y + 46)
  shop:Show()
end

------------------------------------------------------------
-- Questlog fast voll
------------------------------------------------------------
local warn, warned
local function QuestCount()
  if not GetNumQuestLogEntries then return 0 end
  local _, n = GetNumQuestLogEntries()
  n = ns.Plain and ns.Plain(n) or n
  return tonumber(n) or 0
end

local function ShowLogWarn(n)
  local T = ns.T
  if not T then return end
  if not warn then
    warn = T.Popup("ForeverWegweiserLogWarn", 360, TR"Questlog fast voll")
    warn.big = warn:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    warn.big:SetPoint("TOPLEFT", 14, -40)
    warn.big:SetTextColor(1, 0.6, 0.2)
    warn.body:ClearAllPoints()
    warn.body:SetPoint("TOPLEFT", warn.big, "BOTTOMLEFT", 0, -8)
    warn.body:SetPoint("RIGHT", warn, "RIGHT", -14, 0)
    warn.later = T.Button(warn, TR"Später", 120, 22)
    warn.later:SetPoint("BOTTOMLEFT", 14, 12)
    warn.later:SetScript("OnClick", function() warn:Hide() end)
    warn.fix = T.Button(warn, TR"Log aufräumen", 150, 22, true)
    warn.fix:SetPoint("BOTTOMRIGHT", -14, 12)
    warn.fix:SetScript("OnClick", function() warn:Hide(); if ns.ShowLogCleanup then ns.ShowLogCleanup() end end)
  end
  warn.big:SetText(("%d / %d"):format(n, ns.LogMax()))
  warn.body:SetText((TR"Warnung ab %d (einstellbar). Neue Quests kommen erst wieder, wenn Platz ist. Graue oder schwere Quests kannst du abbrechen."):format(ns.LogWarn()))
  warn:SetHeight((warn.body:GetStringHeight() or 30) + 120)
  warn:Show()
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("QUEST_ACCEPTED")
ev:RegisterEvent("QUEST_REMOVED")
ev:SetScript("OnEvent", function()
  if not ns.db or not ns.LogWarn then return end
  C_Timer.After(0.5, function()
    local n = QuestCount()
    if n >= ns.LogWarn() then
      if not warned then warned = true; ShowLogWarn(n) end
    elseif n < ns.LogWarn() - 1 then
      warned = false
    end
  end)
end)

------------------------------------------------------------
-- Stunden Budget: Zeit eingeben oder bis zu einer Uhrzeit (Serverzeit)
------------------------------------------------------------
local budget
local function NumEdit(parent, w, maxLetters)
  local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  e:SetSize(w or 34, 20)
  e:SetAutoFocus(false); e:SetNumeric(true); e:SetMaxLetters(maxLetters or 2)
  e:SetJustifyH("CENTER")
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if ns.T then ns.T.SkinEdit(e) end
  return e
end

local function StartBudget(minutes)
  minutes = math.floor(minutes or 0)
  if minutes < 15 then ns.Print(TR"Mindestens 15 Minuten, sonst lohnt sich keine Route."); return false end
  if minutes > 12 * 60 then minutes = 12 * 60 end
  ns.Print((TR"Stunden Budget: %d:%02d Std. Die Route passt in die Zeit und endet im Gasthaus."):format(math.floor(minutes / 60), minutes % 60))
  if ns.TourBudget then ns.TourBudget(minutes / 60) end
  return true
end

function ns.ShowBudget()
  local T = ns.T
  if not T then return end
  if not budget then
    local f = T.Popup("ForeverWegweiserBudget", 360, TR"Stunden Budget")
    f.body:SetText(TR"Wie lange willst du spielen? Die Route passt in die Zeit und endet in einem Gasthaus.")
    -- Dauer
    local l1 = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    l1:SetPoint("TOPLEFT", 16, -82); l1:SetText(TR"Dauer")
    f.h = NumEdit(f, 34, 2); f.h:SetPoint("TOPLEFT", 110, -78)
    local lh = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall")); lh:SetPoint("LEFT", f.h, "RIGHT", 4, 0); lh:SetText(TR"Std")
    f.m = NumEdit(f, 34, 2); f.m:SetPoint("LEFT", lh, "RIGHT", 10, 0)
    local lm = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall")); lm:SetPoint("LEFT", f.m, "RIGHT", 4, 0); lm:SetText(TR"Min")
    f.go1 = T.Button(f, TR"Start", 80, 22, true); f.go1:SetPoint("TOPRIGHT", -14, -77)
    -- bis Uhrzeit
    local l2 = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    l2:SetPoint("TOPLEFT", 16, -118); l2:SetText(TR"oder bis Uhrzeit")
    f.uh = NumEdit(f, 34, 2); f.uh:SetPoint("TOPLEFT", 140, -114)
    local lc = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight")); lc:SetPoint("LEFT", f.uh, "RIGHT", 3, 0); lc:SetText(":")
    f.um = NumEdit(f, 34, 2); f.um:SetPoint("LEFT", lc, "RIGHT", 6, 0)
    f.go2 = T.Button(f, TR"Start", 80, 22, true); f.go2:SetPoint("TOPRIGHT", -14, -113)
    f.srv = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    f.srv:SetPoint("TOPLEFT", 16, -146); f.srv:SetPoint("RIGHT", f, "RIGHT", -14, 0); f.srv:SetJustifyH("LEFT")
    f:SetHeight(176)
    local function Go1()
      local m = (tonumber(f.h:GetText()) or 0) * 60 + (tonumber(f.m:GetText()) or 0)
      if StartBudget(m) then f:Hide() end
    end
    local function Go2()
      local th, tm = tonumber(f.uh:GetText()), tonumber(f.um:GetText()) or 0
      if not th or th > 23 or tm > 59 then ns.Print(TR"Uhrzeit bitte als Stunde und Minute eingeben, zum Beispiel 22 : 30."); return end
      local sh, sm = 0, 0
      if GetGameTime then sh, sm = GetGameTime() end
      local now = sh * 60 + sm
      local target = th * 60 + tm
      local diff = target - now
      if diff <= 0 then diff = diff + 24 * 60 end
      if StartBudget(diff) then f:Hide() end
    end
    f.go1:SetScript("OnClick", Go1); f.go2:SetScript("OnClick", Go2)
    f.h:SetScript("OnEnterPressed", Go1); f.m:SetScript("OnEnterPressed", Go1)
    f.uh:SetScript("OnEnterPressed", Go2); f.um:SetScript("OnEnterPressed", Go2)
    f:SetScript("OnUpdate", function(self, el)
      self.acc = (self.acc or 0) + el
      if self.acc < 1 then return end
      self.acc = 0
      local sh, sm = 0, 0
      if GetGameTime then sh, sm = GetGameTime() end
      self.srv:SetText((TR"Serverzeit jetzt: %02d:%02d. Die Uhrzeit oben gilt als Serverzeit."):format(sh or 0, sm or 0))
    end)
    budget = f
  end
  budget.h:SetText("1"); budget.m:SetText("0")
  budget.uh:SetText(""); budget.um:SetText("")
  budget:Show()
end
