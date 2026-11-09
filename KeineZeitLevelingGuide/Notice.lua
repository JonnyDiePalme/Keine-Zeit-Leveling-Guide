local ADDON, ns = ...
local TR = ns.TR

-- Hinweis Fenster ueber dem Mini Fenster: jeder Hinweis und jede Warnung als eigene kleine Karte,
-- mit X zum Wegklicken und, wo es das gibt, einem Knopf (Gehe zu, Öffnen, Überspringen ...).
-- Wichtigstes direkt am Mini Fenster. Im Kampf nur Warnungen.

local W = 256
local COL = {
  patrol = { 1, 0.3, 0.25 }, missed = { 1, 0.3, 0.25 }, level = { 1, 0.55, 0.1 }, skip = { 1, 0.55, 0.1 },
  unlock = { 1, 0.82, 0 }, target = { 0.3, 0.8, 1 }, trainer = { 0.3, 0.8, 1 }, vendor = { 0.3, 0.8, 1 },
  repair = { 0.3, 0.8, 1 }, fly = { 0.4, 1, 0.4 }, inn = { 0.4, 1, 0.6 }, hearth = { 0.4, 1, 0.6 },
  log = { 0.75, 0.75, 0.75 }, books = { 0.8, 0.6, 1 }, dq = { 0.8, 0.6, 1 }, group = { 0.3, 1, 0.6 }, recalc = { 1, 0.55, 0.1 }, calc = { 1, 0.55, 0.1 },
}
local gone = {} -- in dieser Sitzung weggeklickt (Warnungen, Ueberspringen)
-- 1.2l (P75, S 17:47: x an "Reserve Quest ... kann abgebrochen werden" schloss die Karte nicht, nur "Hinweis fuer 15 Min
-- ausgeblendet"): jede Hinweis Karte mit x ist nach dem Klick sofort weg, HINT_GONE_S lang (Art und Text), egal ob der
-- Hinweis selbst seine Ruhe kennt
local HINT_GONE_S = 900
local hintGone = {}
local function HintKey(h) return tostring(h.kind) .. ":" .. tostring(h.key or h.text) end

function ns.NoticeOn()
  local db = ns.db
  return db ~= nil and db.noticeWin ~= false
end

local function Redraw()
  if ns.Draw then ns.Draw() end
  if ns.RefreshHud then ns.RefreshHud() end
  if ns.NoticeUpdate then ns.NoticeUpdate() end
end

-- Zaubernamen fuer den Lehrer Hinweis (Tooltip)
local function SpellNames(max)
  local L = UnitLevel("player") or 1
  local list = ns.TrainerSpells and ns.TrainerSpells(L) or {}
  local out = {}
  for i = #list, 1, -1 do
    local nm = ns.Api.GetSpellInfo and ns.Api.GetSpellInfo(list[i].id)
    if nm and #out < max then table.insert(out, nm) end
  end
  if #list > max then table.insert(out, (TR"... und %d mehr"):format(#list - max)) end
  return out
end

-- Alle Karten, wichtigste zuerst
function ns.NoticeList()
  local out = {}
  local db = ns.db
  if not db then return out end
  local combat = InCombatLockdown and InCombatLockdown()
  local function Add(n) if not (n.key and gone[n.key]) then table.insert(out, n) end end
  -- Hinweise: Gruppe, Ruhestein, Taschen, Reparieren, Lehrer, Questlog, Buecher, Dungeon, Flugpunkt, Gasthaus
  local function AddHints()
    local now = GetTime()
    for _, h in ipairs((ns.HintListShown and ns.HintListShown()) or (ns.HintList and ns.HintList()) or {}) do
      local hk = HintKey(h)
      if hintGone[hk] and now >= hintGone[hk] then hintGone[hk] = nil end
      if not hintGone[hk] then
      local n = { kind = h.kind, text = h.text, tip = h.tip, h = h }
      local svc = h.kind == "vendor" or h.kind == "repair" or h.kind == "trainer"
      if h.go then n.go = h.go elseif h.onClick then n.go = TR"Öffnen" elseif h.target then n.go = TR"Gehe zu" end
      if h.kind == "trainer" then
        local names = SpellNames(10)
        if #names > 0 then n.tip = table.concat(names, "\n") end
      end
      -- Haendler und Lehrer kommen als Schritt in die Route (wie im Menue), sonst zeigt nur der Pfeil hin
      n.onGo = function()
        if svc and db.optMode and ns.OptInsertService then ns.OptInsertService(h.kind == "trainer" and "trainer" or "vendor")
        elseif ns.HintClick then ns.HintClick(h) end
        Redraw()
      end
      n.onX = function()
        hintGone[hk] = GetTime() + HINT_GONE_S
        if ns.HintDismiss then ns.HintDismiss(h) end
      end
      Add(n)
      end
    end
  end

  -- Warnung: starke Patrouille in der Naehe (90 Sekunden)
  local lw = ns.Ways and ns.Ways.lastWarn
  -- 1.1 (P61): im Flug keine Patrouillen Karte, auch keine von vor dem Abflug
  if lw and GetTime() - lw.t < 90 and not (ns.InFlight and ns.InFlight()) then
    Add({ kind = "patrol", text = lw.text, key = "pat" .. tostring(lw.id) .. ":" .. math.floor(lw.t),
      tip = TR"Ihr Weg ist rot auf der Karte. Abschalten unter Einstellungen, Reisen." })
  end
  -- im Kampf: nur die Hinweise (Taschen leeren, Lehrer ...), die bleiben stehen
  if combat then AddHints(); return out end

  -- vergessene Quests beim Questgeber (Zonen Route)
  local ms = ns.missed
  if ms then
    Add({ kind = "missed",
      text = (TR"Bei %s noch nicht %s: %s"):format(ms.name or "?", ms.turnin and (ns.EN and "turned in" or "abgegeben") or (ns.EN and "accepted" or "angenommen"), table.concat(ms.names or {}, ", ")),
      go = TR"Gehe zu", tip = TR"X: diese Quests auslassen",
      onGo = function()
        local e = ms.entry
        ns.serviceTarget = { map = ms.map, x = e and e[1] or nil, y = e and e[2] or nil, name = ms.name, kind = "missed" }
        if not ns.serviceTarget.x then ns.serviceTarget = nil end
        Redraw()
      end,
      onX = function() if SlashCmdList and SlashCmdList.TAURENROUTE then SlashCmdList.TAURENROUTE("auslassen") end end })
  end
  -- unterlevelt (Zonen Route)
  local lv = ns.levelWarn
  if lv and not lv.ignored then
    Add({ kind = "level", text = (TR"Unterlevelt, Ziel Level %d"):format(lv.need or 0),
      tip = TR"X: Warnung ignorieren", onX = function() if ns.IgnoreWarn then ns.IgnoreWarn() end end })
  end
  -- Pfeil zeigt gerade nicht auf die Route
  local st = ns.serviceTarget
  if st then
    Add({ kind = "target", text = TR"Pfeil zeigt zu: " .. tostring(st.name or "?"), go = TR"Route", noX = true,
      tip = TR"Knopf: Pfeil wieder auf die Route",
      onGo = function() ns.serviceTarget = nil; Redraw() end })
  end
  -- naechster Punkt zu hoch (Zonen Route)
  if not db.optMode and ns.SkipSuggestion then
    local ok, sk = pcall(ns.SkipSuggestion)
    if ok and sk then
      Add({ kind = "skip", key = "skip" .. tostring(sk.zone or sk.count),
        text = sk.zone and TR"Zu hoch: weiter nach " .. ns.ZoneName(sk.zone) or (TR"Zu hoch: %d Punkte überspringen"):format(sk.count or 0),
        tip = sk.text, go = TR"Springen", onGo = function() if ns.DoSkip then ns.DoSkip() end; Redraw() end })
    end
  end
  -- 20.2 (P11, K 14:53): Blizzard hat die Raid Symbole gesperrt, sichtbar sagen (die eigenen Marker laufen weiter)
  if db.forbidden and db.forbidden.SetRaidTarget and db.raidIcons == false then
    Add({ kind = "level", key = "raidblock", text = TR"Raid Symbole beim Markieren von Blizzard gesperrt",
      tip = TR"Die eigenen Marker über Quest Mobs und Questgeber laufen weiter. Die Raid Symbole sind aus, wieder an unter Einstellungen, Quests." })
  end
  -- neue Funktion frei
  local pend = ns.unlockPending and ns.unlockPending[1]
  if pend and ns.UnlockName then
    Add({ kind = "unlock", text = (TR"Neu: %s"):format(ns.UnlockName(pend)), go = TR"Zeigen",
      tip = TR"Knopf: kurze Erklärung. X: ohne Erklärung weg.",
      onGo = function() if ns.TakePendingUnlock then ns.TakePendingUnlock() end; Redraw() end,
      onX = function() if ns.unlockPending then table.remove(ns.unlockPending, 1) end end })
  end
  AddHints()
  return out
end

------------------------------------------------------------
-- Fenster
------------------------------------------------------------
local frame

local function Tip(self)
  local n = self.n
  if not n then return end
  ns.TipOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine(n.text, 1, 1, 1, true)
  if n.tip and n.tip ~= "" then GameTooltip:AddLine(n.tip, 0.8, 0.8, 0.8, true) end
  GameTooltip:Show()
end

local function Card0(i)
  local c = frame.cards[i]
  if c then return c end
  local T = ns.T
  c = CreateFrame("Button", nil, frame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  c:SetWidth(W)
  if T then T.Skin(c, "tooltip") end
  c.bar = c:CreateTexture(nil, "ARTWORK")
  c.bar:SetPoint("TOPLEFT", 4, -4)
  c.bar:SetPoint("BOTTOMLEFT", 4, 4)
  c.bar:SetWidth(3)
  c.text = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  c.text:SetPoint("LEFT", 12, 0)
  c.text:SetJustifyH("LEFT"); c.text:SetJustifyV("MIDDLE")
  c.text:SetWordWrap(true)
  if c.text.SetMaxLines then c.text:SetMaxLines(3) end
  c.text:SetSpacing(1)
  local hl = c:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3)
  hl:SetColorTexture(1, 1, 1, 0.06)
  -- X
  c.x = CreateFrame("Button", nil, c)
  c.x.card = c
  c.x:SetSize(16, 16)
  c.x:SetPoint("RIGHT", c, "RIGHT", -5, 0)
  local xt = c.x:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  xt:SetPoint("CENTER", 0, 1)
  xt:SetText("x")
  xt:SetTextColor(0.75, 0.75, 0.75)
  local xhl = c.x:CreateTexture(nil, "HIGHLIGHT")
  xhl:SetAllPoints()
  xhl:SetColorTexture(1, 0.3, 0.3, 0.3)
  c.x:SetScript("OnClick", function(self)
    local n = self.card.n
    if not n then return end
    if n.key then gone[n.key] = true end
    if n.onX then n.onX() end
    Redraw()
  end)
  c.x:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(TR"Wegklicken")
    local n = self.card.n
    if n and n.kind == "trainer" then GameTooltip:AddLine(TR"Lehrer: bis zum nächsten Level. Sonst: eine Weile Ruhe.", 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  c.x:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Knopf
  c.go = T and T.Button(c, "", 58, 18) or CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
  c.go.card = c
  c.go:SetSize(58, 18)
  c.go:SetPoint("RIGHT", c.x, "LEFT", -3, 0)
  c.go:SetScript("OnClick", function(self)
    local n = self.card.n
    if n and n.onGo then n.onGo() end
  end)
  c.go:SetScript("OnEnter", function(self) Tip(self.card) end)
  c.go:SetScript("OnLeave", function() GameTooltip:Hide() end)
  c:SetScript("OnClick", function(self) local n = self.n; if n and n.onGo then n.onGo() end end)
  c:SetScript("OnEnter", Tip)
  c:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.cards[i] = c
  return c
end
-- 20.3k: Hinweis Karten wie das Mini Fenster mit ungeskalierten Schriften (der Rahmen folgt der Mini Fenster Groesse)
local function Card(i) return ns.WithPlainFont(Card0, i) end

local function Update()
  local db = ns.db
  if not db then return end
  local hud = _G.TaurenRouteHUD
  if not frame then
    if not hud then return end
    frame = CreateFrame("Frame", "ForeverWegweiserNotice", UIParent)
    frame:SetAllPoints(hud)
    frame:SetFrameStrata("MEDIUM")
    frame.cards = {}
  end
  local on = ns.NoticeOn() and hud and hud:IsShown() and not db.paused
  if hud then frame:SetScale(hud:GetScale() or 1) end
  local list = on and ns.NoticeList() or {}
  local small = (db.hudSize or "normal") == "small"
  local max = small and 2 or 4
  -- oben genug Platz? sonst unter das Mini Fenster (und unter das Menue)
  local top = hud and hud:GetTop()
  local sh = UIParent:GetTop() or 768
  local below = false
  local n = math.min(#list, max)
  local total = 0
  for i = 1, n do
    local c = Card(i)
    local e = list[i]
    c.n = e
    local col = COL[e.kind] or { 0.6, 0.6, 0.6 }
    c.bar:SetColorTexture(col[1], col[2], col[3], 1)
    c.go:SetShown(e.go ~= nil)
    if e.go then c.go:SetText(e.go) end
    c.x:SetShown(not e.noX)
    local right = 5 + (e.noX and 0 or 19) + (e.go and 61 or 0)
    c.text:SetWidth(W - 12 - right - 4)
    c.text:SetText(e.text or "")
    local h = math.max(24, math.floor((c.text:GetStringHeight() or 12) + 12))
    c:SetHeight(h)
    total = total + h + 2
  end
  if top and (top + total) * (hud:GetScale() or 1) > sh - 4 then below = true end
  local prev
  for i = 1, n do
    local c = frame.cards[i]
    c:ClearAllPoints()
    if below then
      local anchor = prev or ((hud.ext and hud.ext:IsShown()) and hud.ext or hud)
      c:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    else
      c:SetPoint("BOTTOM", prev or hud, "TOP", 0, 2)
    end
    c:Show()
    prev = c
  end
  for i = n + 1, #frame.cards do frame.cards[i]:Hide(); frame.cards[i].n = nil end
  frame:SetShown(n > 0)
end
ns.NoticeUpdate = Update

local ev = CreateFrame("Frame")
ns.RegEv(ev, "PLAYER_LOGIN")
ns.RegEv(ev, "PLAYER_REGEN_DISABLED")
ns.RegEv(ev, "PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event)
  if event == "PLAYER_LOGIN" then
    C_Timer.After(2, function() ns.Ticker(1, Update) end)
    return
  end
  -- Kampf an oder aus: gleich umschalten (im Kampf nur Warnungen)
  C_Timer.After(0, Update)
end)
