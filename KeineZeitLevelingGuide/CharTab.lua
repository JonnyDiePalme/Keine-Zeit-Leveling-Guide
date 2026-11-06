local ADDON, ns = ...
local TR = ns.TR
local UnitLevel = function(u) return ns.UnitLevel(u) end

-- Eigene Seite im Charakterfenster, mit Button unter den Seitensymbolen rechts.
-- Mit ElvUI bekommt alles den ElvUI Look. Blizzard Fenster werden nicht veraendert.

local E, S
local tab, page, content, scroll, textFS, funcFrame
local routeScroll, routeContent, routeFS
local navButtons = {}
local view = "overview"
local hookedTabs = {}

------------------------------------------------------------
-- Look (Theme.lua): Classic UI oder ElvUI
------------------------------------------------------------
local T = ns.T
local function InitElv() end

-- classic: "window", "panel", "button", "thin"; kind: ElvUI Template (wird von T.Skin selbst gewaehlt)
local function Template(f, kind, classic)
  local k = classic or "inset"
  if k == "panel" or k == "button" then k = "inset" end
  T.Skin(f, k)
end

local function SkinScroll(sf) T.SkinScroll(sf) end
local function SkinEdit(eb) T.SkinEdit(eb) end

------------------------------------------------------------
-- Seitensymbole rechts am Charakterfenster finden
------------------------------------------------------------
local function FindSideTabs()
  local cf = CharacterFrame
  -- Forever: die Seitensymbole stehen in CharacterFrame.ModeTabs.Tabs
  local mt = cf and type(cf.ModeTabs) == "table" and cf.ModeTabs.Tabs
  if type(mt) == "table" then
    local list = {}
    for _, t in pairs(mt) do
      if type(t) == "table" and t.IsShown and t:IsShown() then table.insert(list, t) end
    end
    if #list > 0 then
      table.sort(list, function(a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
      return list
    end
  end
  local right = cf and cf:GetRight()
  if not right then return {} end
  local list = {}
  local function Scan(parent, depth)
    for _, c in ipairs({ parent:GetChildren() }) do
      if type(c) == "table" and c.IsShown and c ~= tab and c ~= page and c:IsShown() then
        local t = c:GetObjectType()
        local l, w, h = c:GetLeft(), c:GetWidth(), c:GetHeight()
        if (t == "Button" or t == "CheckButton") and l and l >= right - 6 and w > 18 and w < 70 and h > 18 and h < 70 then
          table.insert(list, c)
        elseif depth < 1 then
          Scan(c, depth + 1)
        end
      end
    end
  end
  Scan(cf, 0)
  -- nur die Symbole, die sauber untereinander in einer Spalte stehen
  local cols = {}
  for _, c in ipairs(list) do
    local k = math.floor((c:GetLeft() or 0) / 4 + 0.5)
    cols[k] = cols[k] or {}
    table.insert(cols[k], c)
  end
  local best = {}
  for _, c in pairs(cols) do if #c > #best then best = c end end
  table.sort(best, function(a, b) return (a:GetTop() or 0) > (b:GetTop() or 0) end)
  return best
end

local function PlaceTab()
  local tabs = FindSideTabs()
  tab:ClearAllPoints()
  local last = tabs[#tabs]
  if last then
    -- typischen Abstand zwischen den Symbolen nehmen
    local gaps = {}
    for i = 2, #tabs do
      local g = (tabs[i - 1]:GetBottom() or 0) - (tabs[i]:GetTop() or 0)
      if g >= 0 and g < 40 then table.insert(gaps, g) end
    end
    table.sort(gaps)
    local gap = gaps[math.max(1, math.floor(#gaps / 2 + 0.5))] or 4
    tab:SetSize(last:GetWidth(), last:GetHeight())
    tab:SetPoint("TOP", last, "BOTTOM", 0, -gap)
    -- Classic: Rahmen der anderen Seitensymbole uebernehmen, damit unser Knopf gleich aussieht
    if not T.IsElv() and not tab.cloned then
      tab.cloned = true
      local any = false
      for _, r in ipairs({ last:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" then
          local layer = r:GetDrawLayer()
          if layer == "OVERLAY" or layer == "BORDER" or layer == "HIGHLIGHT" then
            local tx = r:GetTexture()
            if tx then
              local c = tab:CreateTexture(nil, layer)
              c:SetTexture(tx)
              local ok, a1, a2, a3, a4 = pcall(r.GetTexCoord, r)
              if ok and a1 then c:SetTexCoord(r:GetTexCoord()) end
              if r.GetBlendMode then c:SetBlendMode(r:GetBlendMode()) end
              local cr, cg, cb, ca = r:GetVertexColor()
              c:SetVertexColor(cr or 1, cg or 1, cb or 1, ca or 1)
              -- gleiche Lage wie beim Vorbild
              local w, h = r:GetSize()
              local lw, lh = last:GetSize()
              c:SetSize(w, h)
              local cx, cy = r:GetCenter()
              local lx, ly = last:GetCenter()
              if cx and lx then c:SetPoint("CENTER", tab, "CENTER", cx - lx, cy - ly) else c:SetAllPoints(tab) end
              any = true
            end
          end
        end
      end
      if any and tab.SetBackdrop then pcall(tab.SetBackdrop, tab, nil) end
    end
    -- oeffnet ein anderes Symbol seine Seite, macht unsere Platz
    for _, t in ipairs(tabs) do
      if not hookedTabs[t] then
        hookedTabs[t] = true
        local target = t.frameName and _G[t.frameName]
        if type(target) == "table" and target.HookScript then
          target:HookScript("OnShow", function() if page then page:Hide() end end)
        end
        for _, ev in ipairs({ "OnClick", "OnMouseUp" }) do
          if t.HasScript and t:HasScript(ev) then
            t:HookScript(ev, function() if page then page:Hide() end end)
            break
          end
        end
      end
    end
  else
    tab:SetSize(36, 36)
    tab:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", 4, -260)
  end
end

------------------------------------------------------------
-- Farben und Bausteine
------------------------------------------------------------
local ACCENT = { 1, 0.82, 0 }
local ACC_HEX = "ffd100"
local GOLD_HEX = "ffd100"
local GREY_HEX = "9d9d9d"
local function UpdateAccent() ACCENT = T.AccT(); ACC_HEX = T.AccHex() end

local function BarTexture() return T.BarTexture() end
local function Section(title) return T.Section(title) end

-- Aktions Knopf (Classic rot, ElvUI flach)
local function FlatButton(parent, text, w, h, primary) return T.Button(parent, text, w, h, primary) end
-- Listen Zeile (Classic wie im Questlog, ElvUI flach)
local function RowButton(parent, text, w, h)
  local b = T.Row(parent, w, h)
  b:SetText(text or "")
  return b
end

local function MakeBar(parent) return T.Bar(parent, 14) end
local function MakeTile(parent) return T.Tile(parent) end

-- einfaches Balkendiagramm
local function MakeChart(parent, title)
  local c = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  Template(c, "Transparent")
  c.title = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  c.title:SetPoint("TOPLEFT", 8, -6)
  c.title:SetText(Section(title))
  c.info = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  c.info:SetPoint("TOPRIGHT", -8, -6)
  c.area = CreateFrame("Frame", nil, c)
  c.area:SetPoint("TOPLEFT", 8, -22)
  c.area:SetPoint("BOTTOMRIGHT", -8, 16)
  local base = c.area:CreateTexture(nil, "ARTWORK")
  base:SetPoint("BOTTOMLEFT")
  base:SetPoint("BOTTOMRIGHT")
  base:SetHeight(1)
  base:SetColorTexture(1, 1, 1, 0.2)
  -- Hilfslinie bei der Haelfte
  local mid = c.area:CreateTexture(nil, "BACKGROUND")
  mid:SetPoint("LEFT", c.area, "LEFT")
  mid:SetPoint("RIGHT", c.area, "RIGHT")
  mid:SetHeight(1)
  mid:SetColorTexture(1, 1, 1, 0.06)
  c.mid = mid
  c.empty = c.area:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  c.empty:SetPoint("CENTER")
  c.bars, c.labels = {}, {}
  -- values: Zahlen, labels: Text unter den Balken (optional), hi: Index hervorheben
  function c.Set(values, labels, hi, col, emptyText)
    local n = #values
    for _, b in ipairs(c.bars) do b:Hide() end
    for _, l in ipairs(c.labels) do l:Hide() end
    local w, h = c.area:GetWidth(), c.area:GetHeight()
    if not w or w <= 0 or not h or h <= 0 then return end
    c.mid:ClearAllPoints()
    c.mid:SetPoint("LEFT", c.area, "BOTTOMLEFT", 0, h / 2)
    c.mid:SetPoint("RIGHT", c.area, "BOTTOMRIGHT", 0, h / 2)
    local mx = 0
    for _, v in ipairs(values) do if v > mx then mx = v end end
    if n == 0 or mx <= 0 then
      c.empty:SetText(emptyText or TR"noch keine Daten")
      c.empty:Show()
      return mx
    end
    c.empty:Hide()
    local gap = n > 20 and 1 or 3
    local bw = math.max(1, (w - gap * (n - 1)) / n)
    local step = math.max(1, math.ceil(n / math.max(1, math.floor(w / 22))))
    for i, v in ipairs(values) do
      local b = c.bars[i]
      if not b then
        b = c.area:CreateTexture(nil, "ARTWORK")
        c.bars[i] = b
      end
      b:ClearAllPoints()
      b:SetPoint("BOTTOMLEFT", c.area, "BOTTOMLEFT", (i - 1) * (bw + gap), 0)
      b:SetSize(bw, math.max(1, v / mx * h))
      if i == hi then
        b:SetColorTexture(1, 0.82, 0, 0.95)
      else
        b:SetColorTexture(col[1], col[2], col[3], 0.85)
      end
      b:Show()
      if labels and labels[i] and (i - 1) % step == 0 then
        local l = c.labels[i]
        if not l then
          l = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
          c.labels[i] = l
        end
        l:ClearAllPoints()
        l:SetPoint("TOP", b, "BOTTOM", 0, -2)
        l:SetText(labels[i])
        l:Show()
      end
    end
    return mx
  end
  return c
end

------------------------------------------------------------
-- Inhalte
------------------------------------------------------------
-- Zeilen, die schon oben in Kacheln oder Kopf stehen, nicht doppelt zeigen
local SKIP = { "^Speed ", "^XP/Std", "^Nächstes Level", "^Quests: ", "^Level %d+ in ca" }
-- englischer Client: die Zeilen kommen uebersetzt, Muster aus den gleichen Vorlagen bauen
if ns.EN then
  local function FmtPat(f)
    local p = f:gsub("%%%%", "\001"):gsub("%%[%d%.%$]*[ds]", "\002")
    p = p:gsub("[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%0")
    return "^" .. p:gsub("\002", ".-"):gsub("\001", "%%%%")
  end
  for _, f in ipairs({ TR"Speed %d%%", TR"XP/Std %s  (Session %s)", TR"XP/Std: wird gemessen", TR"Nächstes Level in %s",
    TR"Quests: %d im Log, %s%d fertig zum Abgeben|r", TR"Level %d in ca %s" }) do
    table.insert(SKIP, FmtPat(f))
  end
end
local function Skip(l)
  for _, p in ipairs(SKIP) do if l:find(p) then return true end end
  return false
end

-- Reiter im Feld: Einsteiger hat 4, Experte 6, Lernen bekommt sie mit dem Level
local function TabOk(it)
  if not it.expert then return true end
  if ns.Expert() then return true end
  return ns.Learn() and it.lock and ns.Unlocked(it.lock)
end
local TAB_ITEMS = {
  { "overview", TR"Übersicht" }, { "route", TR"Route" }, { "weg", TR"Mein Weg" }, { "func", TR"Einstellungen" },
  { "perf", TR"Statistik", expert = true, lock = "perf" }, { "gold", TR"Gold", expert = true, lock = "gold" },
}

local function OverviewLines()
  local out = {}
  local i = ns.HudInfo and ns.HudInfo() or {}
  table.insert(out, Section(TR"Jetzt"))
  if i.warn then table.insert(out, "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14:14|t |cffff5050" .. i.warn .. "|r") end
  if i.name then
    local c = i.col or { 1, 1, 1 }
    table.insert(out, (TR"|cff%02x%02x%02x%s|r  %s"):format(math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255), i.kind or "", i.name))
    if i.dist then table.insert(out, (TR"|cff9d9d9d%d Yards, ca %s|r"):format(i.dist, i.time or "?")) end
  elseif i.finished then
    table.insert(out, TR"|cff40ff40Abschnitt fertig, Neu rechnen plant weiter.|r")
  else
    table.insert(out, TR"|cff9d9d9dNoch keine Route. Neu rechnen startet sie.|r")
  end
  for _, l in ipairs(i.objs or {}) do table.insert(out, "   " .. l) end
  if i.along and #i.along > 0 then
    table.insert(out, "|TInterface\\Icons\\Ability_DualWield:14:14|t |cffff9030Unterwegs mitnehmen:|r " .. table.concat(i.along, ", "))
  end
  -- Tipps: nur was gerade wirklich hilft
  local tips = {}
  local sh = ns.svcHint
  if sh and sh.text then table.insert(tips, "|cff4dccff>|r " .. sh.text) end
  local w = ns.levelWarn
  if w and w.lines and not w.ignored then table.insert(tips, "|cffff9030" .. (w.lines[1] or TR"Unterlevelt") .. "|r") end
  local qc = ns.questCheck
  if qc and qc.problems and qc.problems > 0 and qc.lines then table.insert(tips, "|cffff9030" .. (qc.lines[2] or qc.lines[1] or "") .. "|r") end
  local qmax = ns.LogMax and ns.LogMax() or 40
  local qlog = ns.QuestCounts and select(1, ns.QuestCounts()) or 0
  if qlog >= qmax - 3 then table.insert(tips, (TR"|cffff5050Questlog fast voll: %d von %d.|r Unter Meine Route, Tab Planen: Questlog aufräumen."):format(qlog, qmax)) end
  local cq = ns.classQuests
  if cq and #cq > 0 then
    local c = cq[1]
    table.insert(tips, (TR"|cffff80ffKlassenquest:|r %s bei %s, %s"):format(c.name, c.npc or "?", c.map and ns.ZoneName(c.map) or "?"))
  end
  if #tips > 0 then
    table.insert(out, "")
    table.insert(out, Section(TR"Tipps"))
    for _, t in ipairs(tips) do table.insert(out, t) end
  end
  local st, names
  if ns.NextUnlock then st, names = ns.NextUnlock() end
  if st and names then
    table.insert(out, "")
    table.insert(out, (TR"|cff9d9d9dAls Nächstes frei ab Level %d: %s|r"):format(st.lvl, names))
  end
  return out
end

-- welche Art Route gerade laeuft
local function RouteKind()
  local o = ns.db and ns.db.opt and ns.db.opt.opts
  if o and o.logOnly then return "log" end
  return ({ "all", "normal" })[ns.LevelStep and ns.LevelStep() or 2] or "normal"
end

local function RouteLines(s)
  local out = {}
  local opt = ns.db and ns.db.opt
  local fmt = s.fmt or tostring
  if ns.OptBusy and ns.OptBusy() then
    table.insert(out, TR"Rechnet gerade ...")
  elseif opt and opt.steps then
    table.insert(out, Section(TR"Diese Route"))
    table.insert(out, ("%s|r"):format("|cffffffff" .. (opt.title or TR"Normale Route")))
    table.insert(out, (TR"%d Schritte, geschätzt %s"):format(#opt.steps, fmt(opt.sec or 0)))
    table.insert(out, (TR"Level %d bis %.1f, Schritt %d von %d"):format(opt.from or 0, opt.to or 0, opt.idx or 1, #opt.steps))
  else
    table.insert(out, TR"Noch keine Route berechnet. Neu rechnen startet sie.")
  end
  table.insert(out, "")
  table.insert(out, Section(TR"Tempo"))
  for i = 1, #(ns.LEVEL_STEPS or {}) do table.insert(out, ns.TempoLine and ns.TempoLine(i) or "") end
  return out
end

local function WegLines()
  local out = {}
  local L = UnitLevel("player") or 1
  local st, names = ns.NextUnlock()
  if ns.Expert() then
    table.insert(out, TR"Im Modus Alles frei ist alles sofort da.")
  elseif st then
    table.insert(out, Section((TR"Als Nächstes, Level %d"):format(st.lvl)))
    table.insert(out, "|cffffffff" .. names .. "|r")
    table.insert(out, ns.UNLOCKS[st.items[1]].text)
    table.insert(out, (TR"|cff9d9d9dNoch %d Level.|r"):format(st.lvl - L))
  else
    table.insert(out, TR"Alles ist frei.")
  end
  table.insert(out, "")
  table.insert(out, Section(TR"Zuletzt frei geworden"))
  local list = {}
  for _, s in ipairs(ns.VisibleSteps()) do if s.lvl <= L and s.lvl > 1 then table.insert(list, 1, s) end end
  for i = 1, math.min(3, #list) do
    local s = list[i]
    local n = {}
    for _, k in ipairs(s.items) do table.insert(n, ns.UnlockName(k)) end
    table.insert(out, (TR"|cff40ff40Level %d|r  %s"):format(s.lvl, table.concat(n, ", ")))
  end
  if #list == 0 then table.insert(out, TR"|cff9d9d9dnoch nichts, ab Level 5 geht es los|r") end
  return out
end

local function GoldTabLines()
  if ns.Unlocked("gold") then return ns.GoldLines() end
  local L = UnitLevel("player") or 1
  return {
    Section(TR"Gold kommt ab Level 35"),
    TR"Dann siehst du hier Gold pro Stunde, die besten Grind Spots mit Auktionshaus Preisen und die Gold Quests.",
    TR"Bis dahin lohnt sich Leveln mehr.",
    "",
    (TR"|cff9d9d9dNoch %d Level.|r"):format(math.max(0, (ns.GOLD_LEVEL or 35) - L)),
  }
end

local function Run(cmd) SlashCmdList.TAURENROUTE(cmd) end

local header, zoneBar, xpBar, tiles, bodyFrame, charts
local toggles = {}
local tabBar, btnRow, routeModes, wegTop, funcGrid

local function UpdateHeader(s)
  header.sub:SetText((TR"%s   |cff%sLevel %d|r"):format(s.zone or "?", GOLD_HEX, s.level or 0))
  header.chip.Set()
  if s.total and s.total > 0 then
    zoneBar:SetValue(s.done / s.total)
    zoneBar.text:SetText(s.zone or TR"Zone")
    zoneBar.right:SetText((TR"Route %d Prozent"):format(math.floor(s.done / s.total * 100)))
  else
    zoneBar:SetValue(0)
    zoneBar.text:SetText(s.zone or TR"Zone")
    zoneBar.right:SetText(TR"keine Route")
  end
  if s.xpFrac then
    xpBar:SetValue(s.xpFrac)
    xpBar.text:SetText((TR"Level %d  %d%%"):format(s.level, math.floor(s.xpFrac * 100)))
    xpBar.right:SetText(s.nextLevel and (TR"noch %s"):format(s.nextLevelText or s.fmt(s.nextLevel)) or "")
  else
    xpBar.text:SetText((TR"Level %d"):format(s.level or 0))
    xpBar.right:SetText("")
  end
end

local function UpdateTiles(s)
  local v = tiles
  v[1].value:SetText(s.xph and s.xph > 0 and s.num(s.xph) or TR"|cff9d9d9dnoch offen|r")
  v[1].label:SetText(TR"XP pro Stunde")
  local nl = s.nextLevel and (s.nextLevelText or s.fmt(s.nextLevel)):gsub(" Min", ""):gsub(" Std", " h")
  if nl and ns.EN then nl = nl:gsub(" min$", "") end -- englisch kommt " min" klein
  v[2].value:SetText(nl or TR"|cff9d9d9dnoch offen|r")
  v[2].label:SetText(TR"bis Level " .. ((s.level or 0) + 1))
  v[3].value:SetText(("%d / %d"):format(s.qLog or 0, ns.LogMax and ns.LogMax() or 40))
  v[3].label:SetText(TR"Questlog")
  v[4].value:SetText(tostring(s.qDone or 0))
  v[4].label:SetText(TR"fertig zum Abgeben")
end

local function TabAllowed(v)
  for _, it in ipairs(TAB_ITEMS) do
    if it[1] == v then return TabOk(it) end
  end
  return false
end

local function Refresh()
  if not page or not page:IsShown() then return end
  local s = ns.Stats and ns.Stats() or {}
  view = "overview"
  UpdateHeader(s)
  tabBar.Select(view)
  -- Reiter, die eine kurze Erklaerung brauchen
  if ns.CoachLater then
    if view == "route" then
      ns.CoachLater("char_route", function() return {
        { target = routeModes, side = "BOTTOM", title = TR"Tempo", text = TR"Alles: jede machbare Quest. Normal: gute Quests. Questlog Route: nur was schon im Log ist. Leuchtend ist die aktive." },
      } end, 0.4)
    elseif view == "func" then
      ns.CoachLater("char_func", function() return {
        { target = funcGrid.cards and funcGrid.cards[1], side = "BOTTOM", title = TR"Einstellungen", text = TR"Die wichtigsten Knöpfe zum Starten. Gestrichelte kommen erst später und zeigen ihr Level. Alle Einstellungen unten im grossen Fenster." },
      } end, 0.4)
    end
  end
  -- rechts immer die Route
  local steps = ns.RouteSteps(20)
  if steps[1] and (steps.zoneHead == 1 or steps[1]:find("Punkt %d+ von %d+")) then table.remove(steps, 1) end
  routeFS:SetText(table.concat(steps, "\n"))
  routeContent:SetHeight(routeFS:GetStringHeight() + 20)
  page.routeSub:SetText(s.total and (TR"Schritt %d von %d"):format(s.idx, s.total) or "")

  tiles.frame:SetShown(view == "overview")
  charts.frame:SetShown(view == "perf")
  routeModes:SetShown(view == "route")
  wegTop:SetShown(view == "weg")
  funcGrid:SetShown(view == "func")
  scroll:SetShown(view ~= "func")

  -- Knoepfe unten je nach Reiter
  if view == "overview" then
    -- Planen erst, wenn der Reiter frei ist (Geführt ab Level 13)
    local l = { { TR"Neu rechnen", function() if ns.CalcHold and ns.CalcHold() then ns.CalcGo() elseif ns.AutoOpt then ns.AutoOpt("hand") end end } }
    if ns.Unlocked("plan") then l[#l + 1] = { TR"Planen", function() if ns.ShowBig then ns.ShowBig("plan") end end } end
    l[#l + 1] = { TR"Feierabend", function() if ns.EndSession then ns.EndSession() end end, "sleep" }
    btnRow.Set(l)
  elseif view == "route" then
    btnRow.Set({ { TR"Neu rechnen", function() if ns.CalcHold and ns.CalcHold() then ns.CalcGo() elseif ns.AutoOpt then ns.AutoOpt("hand") end end },
      { TR"Schritt überspringen", function() if ns.OptSkip then ns.OptSkip() end end },
      { TR"Quest auslassen", function() Run("auslassen") end } })
  elseif view == "weg" then
    btnRow.Set({ { TR"Mein Weg im grossen Fenster", function() if ns.ShowBig then ns.ShowBig("weg") end end } })
  elseif view == "perf" then
    btnRow.Set({ { TR"Statistik im grossen Fenster", function() if ns.ShowBig then ns.ShowBig("perf") end end } })
  elseif view == "gold" and ns.Unlocked("gold") then
    btnRow.Set({ { TR"Gold: Mobs", function() if ns.ShowBig then ns.ShowBig("farm") end end },
      { TR"Gold: Quests", function() if ns.ShowBig then ns.ShowBig("gold") end end } })
  elseif view == "func" then
    local l = { { TR"Alle Einstellungen", function() if ns.ShowBig then ns.ShowBig("set") end end } }
    if ns.Unlocked("plan") then l[#l + 1] = { TR"Planen", function() if ns.ShowBig then ns.ShowBig("plan") end end } end
    btnRow.Set(l)
  else
    btnRow.Set({})
  end

  if view == "func" then
    for _, c in ipairs(funcGrid.cards) do c.Update() end
    return
  end

  scroll:ClearAllPoints()
  if view == "overview" then
    UpdateTiles(s)
    scroll:SetPoint("TOPLEFT", tiles.frame, "BOTTOMLEFT", 0, -8)
  elseif view == "perf" then
    local g = ns.PerfGraph and ns.PerfGraph() or { rates = {}, levels = {} }
    local labels = {}
    for i = 1, #g.rates do
      local ago = (#g.rates - i) * 2
      labels[i] = (ago % 10 == 0) and (ago == 0 and TR"jetzt" or ("-" .. ago)) or nil
    end
    local mx = charts.rate.Set(g.rates, labels, #g.rates, ACCENT, TR"Daten kommen nach 2 Minuten")
    charts.rate.info:SetText(mx and mx > 0 and (TR"max %s XP/Std"):format(g.num(mx)) or "")
    local vals, lab, hi = {}, {}, nil
    for i, e in ipairs(g.levels) do
      vals[i] = e.t
      lab[i] = tostring(e.lv)
      if e.cur then hi = i end
    end
    local mx2 = charts.lvl.Set(vals, lab, hi, { 0.58, 0.35, 0.85 }, TR"noch keine Daten")
    charts.lvl.info:SetText(mx2 and mx2 > 0 and (TR"längstes: %s"):format(g.fmt(mx2)) or "")
    scroll:SetPoint("TOPLEFT", charts.frame, "BOTTOMLEFT", 0, -8)
  elseif view == "route" then
    routeModes.Update()
    scroll:SetPoint("TOPLEFT", routeModes, "BOTTOMLEFT", 0, -8)
  elseif view == "weg" then
    wegTop.Update()
    scroll:SetPoint("TOPLEFT", wegTop, "BOTTOMLEFT", 0, -8)
  else
    scroll:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 8, -8)
  end
  if btnRow.n > 0 then
    scroll:SetPoint("BOTTOMRIGHT", btnRow, "TOPRIGHT", -18, 6)
  else
    scroll:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", -26, 8)
  end
  local lines
  if view == "overview" then lines = OverviewLines()
  elseif view == "perf" then lines = ns.PerfLines()
  elseif view == "gold" then lines = GoldTabLines()
  elseif view == "route" then lines = RouteLines(s)
  elseif view == "weg" then lines = WegLines()
  else lines = {} end
  textFS:SetText(table.concat(lines, "\n"))
  content:SetHeight(textFS:GetStringHeight() + 20)
end
ns.RefreshCharTab = Refresh
function ns.SetCharView(v) view = v; Refresh() end


-- Funktionen: Schalter mit An/Aus Anzeige und Aktions Knoepfe
-- Einsteiger: nur diese Fragen (alles andere bleibt auf dem Standard)
local EASY_TOGGLES = {
  [TR"Grinden?"] = true, [TR"Dungeon Quests einplanen?"] = true, [TR"Eskorten einplanen?"] = true, [TR"Kontinent wechseln?"] = true,
  [TR"Bibliotheksbücher am Weg mitnehmen?"] = true, [TR"Mini Fenster mit Gruppen Ansicht?"] = true,
  [TR"Farmberufe Routen?"] = true, [TR"Elitegebiete beim Farmen meiden?"] = true, [TR"Gefährliche Orte beim Farmen meiden?"] = true,
  [TR"Hinweise zu neuen Funktionen?"] = true, [TR"Mini Fenster zeigen?"] = true, [TR"Mini Fenster klein?"] = true,
  [TR"Route an?"] = true, [TR"Pfeil zeigen?"] = true, [TR"Route auf der Weltkarte?"] = true, [TR"Route auf der Minimap?"] = true,
  [TR"Quests automatisch annehmen und abgeben?"] = true, [TR"Quest Mobs markieren?"] = true, [TR"Questgeber markieren?"] = true,
  [TR"Tipps zu Lehrer, Händler, Ruhestein?"] = true, [TR"Knöpfe für Quest Items?"] = true, [TR"Belohnung vorschlagen?"] = true,
  [TR"Fortschritt der Gruppe zeigen?"] = true, [TR"Quests automatisch teilen?"] = true, [TR"Elite Quests in der Gruppe?"] = true,
}
local EASY_HIDE_HEAD = ns.TRKeys{ Questlog = true, [TR"Reisen"] = true, Gold = true }
-- Modus Geführt: nur diese Themen und Fragen, der Rest hinter dem Knopf "Alle Einstellungen" (nie gesperrt)
ns.EASY_SET_CATS = ns.TRKeys{ Tempo = true, Allgemein = true, [TR"Route und Karte"] = true, Quests = true, Gruppe = true, Farmen = true }

local function BuildFunctions(parent, sfName, only, easyOnly)
  -- eigener Scrollbereich, falls das Fenster klein ist
  local sf = CreateFrame("ScrollFrame", sfName or "TaurenRouteFuncScroll", parent, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -2)
  sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -24, 2)
  SkinScroll(sf)
  local f = CreateFrame("Frame", nil, sf)
  f:SetSize(400, 400)
  sf:SetScrollChild(f)
  -- Breite immer wie das Fenster, Scrollbalken nur, wenn der Inhalt nicht passt (dann wird es auch nicht schmaler)
  local bar = sf.ScrollBar or (sf:GetName() and _G[sf:GetName() .. "ScrollBar"])
  sf.scrollBarHideable = true
  local fitting = false
  local function Fit()
    if fitting then return end
    fitting = true
    local need = (f:GetHeight() or 0) > (sf:GetHeight() or 0) + 4
    if bar then bar:SetShown(need) end
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -2)
    sf:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", need and -24 or -4, 2)
    local w = sf:GetWidth()
    if w and w > 0 then f:SetWidth(w) end
    if not need and sf.SetVerticalScroll then sf:SetVerticalScroll(0) end
    fitting = false
  end
  sf.Fit = Fit
  sf:SetScript("OnSizeChanged", function() Fit() end)
  sf:HookScript("OnShow", function() Fit(); if C_Timer then C_Timer.After(0, Fit) end end)
  local PAD, ROW, GAP = 10, 22, 4
  local y = -PAD
  local function W() return (f:GetWidth() > 0 and f:GetWidth() or 420) end

  f.heads = {}
  f.sf = sf
  sf.child = f
  -- only: nur ein Abschnitt, eine Spalte (Journal Stil)
  local cur
  local function Want()
    if easyOnly and EASY_HIDE_HEAD[cur] then return false end
    if not only then return true end
    if type(only) == "table" then return only[cur] and true or false end
    return cur == only
  end
  local function Header(text)
    cur = text
    if not Want() then return nil, nil end
    f.heads[text] = -y
    -- Ueberschrift steht im Journal Stil gross oben; bei zusammengelegten Themen die Unterueberschrift zeigen
    if only and type(only) ~= "table" then return nil, nil end
    local t = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
    t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    t:SetText(Section(text))
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 15)
    line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y - 15)
    line:SetHeight(1)
    line:SetColorTexture(1, 1, 1, 0.12)
    y = y - 22
    return t, line
  end

  -- Schalter in zwei Spalten, als Frage mit Ja und Nein wie bei Einsteiger
  local col = 0
  local ROWH = 30
  local function Toggle(text, get, fn, help)
    if not Want() then return nil end
    if easyOnly and not EASY_TOGGLES[text] then return nil end
    local r = T.YesNo(f, text, function() return get() and true or false end, function(v)
      if (get() and true or false) ~= v then fn() end
      Refresh()
    end, help)
    r:SetHeight(only and 38 or ROWH)
    if only then
      r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
      r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
      table.insert(toggles, r)
      y = y - 38 - GAP
      return r
    end
    if col == 0 then
      r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
      r:SetPoint("TOPRIGHT", f, "TOP", -12, y)
    else
      r:SetPoint("TOPLEFT", f, "TOP", 12, y)
      r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    end
    table.insert(toggles, r)
    col = col + 1
    if col > 1 then col = 0; y = y - ROWH - GAP end
    return r
  end
  local function EndRow() if col ~= 0 then col = 0; y = y - ROWH - GAP end end

  -- Knoepfe nebeneinander (nur noch fuer Modus, Einrichtung und Look)
  local function Actions(list)
    if not Want() then return end
    EndRow()
    local n = #list
    local holder = CreateFrame("Frame", nil, f)
    holder:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
    holder:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    holder:SetHeight(22)
    local btns = {}
    for i, a in ipairs(list) do
      local b = FlatButton(holder, a[1], 100, 22)
      b:SetScript("OnClick", function() a[2](); Refresh() end)
      btns[i] = b
    end
    local function Lay()
      local w = holder:GetWidth()
      if not w or w <= 0 then return end
      local bw = (w - (n - 1) * GAP) / n
      for i, b in ipairs(btns) do
        b:ClearAllPoints()
        b:SetWidth(bw)
        b:SetPoint("LEFT", holder, "LEFT", (i - 1) * (bw + GAP), 0)
      end
    end
    holder:SetScript("OnSizeChanged", Lay)
    Lay()
    y = y - 22 - GAP - 6
    return holder
  end

  local db = ns.db
  local function Requiz() db.learnedRev = (db.learnedRev or 0) + 1; if ns.QuestieFull then ns.QuestieFull(); ns.QuestieScan() end end
  -- Schieberegler Zeile (Prozent), ueber die ganze Breite
  local function ValRow(lo2, hi2, get, set, fmt, title, tip)
    local r = CreateFrame("Frame", nil, f)
    r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y); r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    r:SetHeight(24)
    local lb = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    lb:SetPoint("LEFT", 0, 0)
    local s2 = T.ValueSlider(r, lo2, hi2, 0.1, get, set)
    s2:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    s2:SetWidth(220)
    s2.OnChanged = function() lb:SetText(fmt:format(math.floor((get() or 1) * 100 + 0.5))) end
    s2:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(title)
      GameTooltip:AddLine(tip, 1, 1, 1, true)
      GameTooltip:Show()
    end)
    s2:SetScript("OnLeave", function() GameTooltip:Hide() end)
    s2.Update()
    y = y - 24 - GAP - 6
  end
  local function NumBox(label, x, get)
    local t = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + x, y - 4)
    t:SetText(label)
    local e = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    e:SetSize(34, 20)
    e:SetPoint("LEFT", t, "RIGHT", 10, 0)
    e:SetAutoFocus(false); e:SetNumeric(true); e:SetMaxLetters(2)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    SkinEdit(e)
    e.label = t
    e.Fill = function() e:SetText(tostring(get())) end
    e.Fill()
    return e
  end
  Header(TR"Allgemein und Mini Fenster")
  Actions({ { TR"Modus wechseln", function()
      local nx = ns.Expert() and "guided" or "free"
      ns.SetMode(nx); ns.Print(TR"Modus: " .. ns.ModeName(nx)) end },
    { TR"Einrichtung nochmal", function() if ns.ShowSetup then ns.ShowSetup() end end },
    { TR"Look wechseln", function() if ns.CycleLook then ns.CycleLook() end end } })
  Toggle(TR"Hinweise zu neuen Funktionen?", function() return db.unlockHints ~= false end, function() db.unlockHints = (db.unlockHints == false) end,
    TR"Neue Funktion frei: ein kleines Fenster erklärt sie.")
  Toggle(TR"Mini Fenster klein?", function() return db.hudSize == "small" end, function()
    db.hudSize = (db.hudSize == "small") and "normal" or "small"; if ns.ApplyHudSize then ns.ApplyHudSize() end end,
    TR"Klein: Zone, Ziel, Weg und drei Knöpfe. Gross: dazu Danach, Mitnehmen, Gruppe, XP Balken und Tempo.")
  Toggle(TR"Mini Fenster mit Gruppen Ansicht?", function() return db.hudGroup ~= false end, function()
    db.hudGroup = not (db.hudGroup ~= false); if ns.HudGroupUpdate then ns.HudGroupUpdate() end end,
    TR"In der Gruppe eine Zeile pro Mitspieler unter dem Mini Fenster, mit seinem Schritt. Klick auf einen Namen: hinlaufen und helfen.")
  Toggle(TR"Händler Knopf im Mini Fenster?", function() return db.hudVendor ~= false end, function()
    db.hudVendor = (db.hudVendor == false); if ns.RefreshHud then ns.RefreshHud() end end)
  Toggle(TR"Feierabend Knopf im Mini Fenster?", function() return db.hudSleep ~= false end, function()
    db.hudSleep = (db.hudSleep == false); if ns.RefreshHud then ns.RefreshHud() end end)
  Toggle(TR"Hinweise als Fenster über dem Mini Fenster?", function() return db.noticeWin ~= false end, function()
    db.noticeWin = (db.noticeWin == false); if ns.NoticeUpdate then ns.NoticeUpdate() end; if ns.RefreshHud then ns.RefreshHud() end end,
    TR"Ja: jeder Hinweis als eigene Karte mit X und Gehe zu. Nein: nur der wichtigste im Mini Fenster.")
  -- 18.2: auch hier, nicht nur in der Einrichtung (Sascha testet beide Modi)
  Toggle(TR"Älterer oder schwacher PC?", function() return db.slowPC and true or false end, function() db.slowPC = (not db.slowPC) or nil end,
    TR"Ja: die Route rechnet langsamer, dafür ruckelt nichts. Bei Ruckeln bremst Keine Zeit Leveling Guide auch von selbst.")
  -- 20.3c (S 01:57, f70, Na Flugmeister Auto Flug): Standard an
  Toggle(TR"Automatisch fliegen?", function() return db.autoFly ~= false end, function() db.autoFly = (db.autoFly == false) end,
    TR"Ja: Öffnest du beim Flugmeister die Flugkarte und der Wegweiser hat dort einen Flug als nächsten Schritt, fliegt er selbst los. Shift beim Öffnen: kein Auto Flug.")
  -- 20.3d (S f72 A, Na Nachtrag 06:50/09:15): Portale der Gruppe, Standard an
  Toggle(TR"Portale der Gruppe nutzen?", function() return db.partyPorts ~= false end, function() db.partyPorts = (db.partyPorts == false) end,
    TR"Ja: Mitspieler mit dem Addon teilen ihre Portale. Ist ein Magier mit Portal in der Nähe, plant das Navi es als Abkürzung. Dein Addon schickt ihnen dafür auch deine Portale.")
  -- 1.0 (K 23:17): Test Log ist Standard aus, hier ein und aus (nur mit dem Log Addon)
  if ns.TestLogAvailable and ns.TestLogAvailable() and ns.TestLogCmd then
    Toggle(TR"Test Log schreiben (für Fehler Meldungen)?", function() return ns.TestLogActive() end, function()
      ns.TestLogCmd(ns.TestLogActive() and "aus" or "an"); if ns.RefreshBig then ns.RefreshBig() end end,
      TR"Ja: das Addon schreibt mit, was es tut, damit Fehler gefunden werden. Standard aus. Mehr in der Hilfe unter Log und Fehler melden.")
  end
  -- nur wenn das Test Log gerade schreibt
  if ns.TestLogActive and ns.TestLogActive() then
    Toggle(TR"Test Notiz neben dem Mini Fenster?", function() return db.testerBox ~= false end, function()
      db.testerBox = (db.testerBox == false); if ns.TesterBoxUpdate then ns.TesterBoxUpdate() end end,
      TR"Kleiner Kasten mit Fehler melden und Verbesserung. Was du eintippst, landet im Test Log.")
  end
  -- Groesse vom Mini Fenster (in allen Modi)
  if Want() then
    EndRow()
    ValRow(ns.HUD_MIN or 0.7, ns.HUD_MAX or 2, function() return db.hudScale or 1 end,
      function(v) if ns.SetHudScale then ns.SetHudScale(v) end end,
      TR"Skalierung vom Mini Fenster: %d%%", TR"Skalierung vom Mini Fenster", TR"Macht das ganze Mini Fenster grösser oder kleiner, mit Schrift, Knöpfen und Hinweisen.")
    -- 19.32 (Saschas Runde 1 Punkt 5): wie viele nächste Schritte das grosse Mini Fenster zeigt (1, 3, 5 oder 8)
    local t = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 4)
    local btn = FlatButton(f, TR"mehr", 70, 20)
    btn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 8, y)
    local NEXT = { [1] = 3, [3] = 5, [5] = 8, [8] = 1 }
    local function Fill()
      local n = ns.HudSteps and ns.HudSteps() or 1
      t:SetText((TR"Mini Fenster zeigt %d nächste Schritte"):format(n))
      btn:SetText(n >= 8 and TR"weniger" or TR"mehr")
    end
    btn:SetScript("OnClick", function()
      db.hudSteps = NEXT[ns.HudSteps and ns.HudSteps() or 1] or 3
      Fill()
      if ns.RefreshHud then pcall(ns.RefreshHud) end
    end)
    btn:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Nächste Schritte im Mini Fenster")
      GameTooltip:AddLine(TR"1, 3, 5 oder 8 Zeilen unter dem jetzigen Schritt. Nur im grossen Mini Fenster.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f:HookScript("OnShow", Fill)
    Fill()
    y = y - 22 - GAP
  end
  EndRow()

  Header(TR"Tempo")
  if Want() then
    EndRow()
    -- Regler mit 2 Stufen, Prozent zu Normal
    local sl = T.StepSlider(f)
    sl:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, y - 4); sl:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 4, y - 4)
    sl:SetHeight(112)
    table.insert(toggles, sl)
    y = y - 112 - 16
  end
  -- alles, was bestimmt, welche Quests die Route nimmt (gleiche Fragen wie in der Einrichtung)
  for _, q in ipairs(ns.QuestRowDefs and ns.QuestRowDefs() or {}) do
    local r = Toggle(q.text, q.get, function() q.set(not q.get()) end, q.tip)
    if r and q.active then r.active = q.active; r.Update(); table.insert(ns.questRowUpd, r.Update) end
  end
  EndRow()
  -- Buecher: Umweg pro Buch in Yards (Standard 600)
  if Want() then
  local ebBook = NumBox(TR"Umweg pro Buch in Yards (Standard 600)", 0, function() return ns.BookYards and ns.BookYards() or 600 end)
  ebBook:SetMaxLetters(4); ebBook:SetWidth(48)
  local saveB = FlatButton(f, TR"Übernehmen", 100, 22)
  saveB:SetPoint("LEFT", ebBook, "RIGHT", 10, 0)
  local stdB = FlatButton(f, TR"Standard", 80, 22)
  stdB:SetPoint("LEFT", saveB, "RIGHT", 6, 0)
  local function SaveBook()
    ebBook:ClearFocus()
    if ns.SetBookYards then ns.SetBookYards(ebBook:GetText()) end
    ebBook.Fill()
  end
  saveB:SetScript("OnClick", SaveBook)
  ebBook:SetScript("OnEnterPressed", SaveBook)
  stdB:SetScript("OnClick", function() if ns.SetBookYards then ns.SetBookYards(600) end; ebBook.Fill() end)
  sf:HookScript("OnShow", function() ebBook.Fill() end)
  y = y - 22 - GAP - 6
  end
  Header(TR"Route und Karte")
  Toggle(TR"Route an?", function() return db.show end, function() Run(db.show and "aus" or "an") end, TR"Aus: kein Pfeil Ziel und keine Linie mehr, bis du sie wieder einschaltest.")
  Toggle(TR"Pfeil zeigen?", function() return TaurenRouteArrow and TaurenRouteArrow:IsShown() end, function() ns.ToggleArrow() end)
  -- Groesse vom Pfeil (in allen Modi): Schieberegler, nur der Pfeil selbst wird groesser
  if Want() then
    EndRow()
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y); row:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    row:SetHeight(24)
    local lab = row:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    lab:SetPoint("LEFT", 0, 0)
    local lo, hi = ns.ARROW_MIN or 0.5, ns.ARROW_MAX or 3
    local sl = T.ValueSlider(row, lo, hi, 0.1,
      function() return db.arrowScale or 1 end,
      function(v) if ns.SetArrowScale then ns.SetArrowScale(v) end end)
    sl:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    sl:SetWidth(220)
    sl.OnChanged = function() lab:SetText((TR"Grösse vom Pfeil: %d%%"):format(math.floor((db.arrowScale or 1) * 100 + 0.5))) end
    sl:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Grösse vom Pfeil")
      GameTooltip:AddLine(TR"Nur der Pfeil wird grösser oder kleiner, der Text bleibt gleich.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    sl:SetScript("OnLeave", function() GameTooltip:Hide() end)
    sl.Update()
    y = y - 24 - GAP - 6
    -- Schrift unter dem Pfeil: eigener Regler
    ValRow(ns.ARROW_TEXT_MIN or 0.8, ns.ARROW_TEXT_MAX or 2, function() return db.arrowText or 1 end,
      function(v) if ns.SetArrowTextScale then ns.SetArrowTextScale(v) end end,
      TR"Schrift unter dem Pfeil: %d%%", TR"Schrift unter dem Pfeil", TR"Nur der Text unter dem Pfeil wird grösser oder kleiner.")
  end
  -- 20.2b (P12): Schrift aller Fenster des Addons (gross, Mini Fenster, Einrichtung, Hilfe, Tooltips mit eigenen Zeilen)
  if Want() then
    EndRow()
    ValRow(0.8, 1.5, function() return (ns.FontScale and ns.FontScale()) or 1 end,
      function(v) if ns.SetFontScale then ns.SetFontScale(v) end end,
      TR"Schriftgrösse: %d%%", TR"Schriftgrösse", TR"Alle Texte von Keine Zeit Leveling Guide grösser oder kleiner (80 bis 150 %), zb wenn man schlecht sieht. Das grosse Fenster kannst du zusätzlich unten rechts am Griff grösser ziehen.")
  end
  Toggle(TR"Route auf der Weltkarte?", function() return db.mapShow ~= false end, function()
    db.mapShow = (db.mapShow == false); if ns.Draw then ns.Draw() end; if ns.MapButtonText then ns.MapButtonText() end end)
  Toggle(TR"Route auf der Minimap?", function() return db.miniShow end, function()
    db.miniShow = not db.miniShow; if ns.MapButtonText then ns.MapButtonText() end end)
  -- 20.3k (S Test 20.3g Punkt 24): nur zeigen, wenn OpenMap da ist
  local omOk = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("OpenMap") or (IsAddOnLoaded and IsAddOnLoaded("OpenMap"))
  if omOk then
    Toggle(TR"OpenMap als Karte nutzen?", function() return ns.OpenMapActive and ns.OpenMapActive() end, function() ns.SwitchMap() end, TR"Nur wenn OpenMap installiert ist.")
  end
  -- 20.3m+ (S Punkt 27)
  Toggle(TR"Gefahren auf der Karte?", function() return db.showDanger ~= false end, function()
    db.showDanger = (db.showDanger == false); if ns.Draw then ns.Draw() end end,
    TR"Von dir gesetzte Gefahren (Alt+Klick), starke Mobs und Elite für dein Level. Gelernte Sturz Stellen nutzt die Route, zeigt sie aber nicht.")
  Toggle(TR"Grind Spots auf der Karte?", function() return db.showGrind end, function()
    db.showGrind = not db.showGrind; if ns.Draw then ns.Draw() end end, TR"Grün passt, gelb geht, rot zu stark, grau zu tief.")
  EndRow()

  Header(TR"Reisen")
  Toggle(TR"Flüge einplanen?", function() return db.useFlights ~= false end, function() db.useFlights = (db.useFlights == false) end,
    TR"Fliegen statt laufen, wenn es Zeit spart.")
  -- 19.32 (Navi Chat, Pruefer A2): Teleport im Navi, nur fuer Magier sichtbar
  if UnitClass and select(2, UnitClass("player")) == "MAGE" then
    Toggle(TR"Navi: Teleport benutzen?", function() return db.naviPorts ~= false end, function() db.naviPorts = (db.naviPorts == false) end,
      TR"Magier: das Navi teleportiert dich in eine Hauptstadt, wenn es mindestens 1:30 Min spart (braucht eine Rune der Teleportation).")
  end
  Toggle(TR"Taschen einplanen?", function() return db.bagPlan ~= false end, function() db.bagPlan = (db.bagPlan == false) end,
    TR"Volle Taschen und kaputte Rüstung: der Weg geht über einen Händler.")
  Toggle(TR"Reittier Tempo einrechnen?", function() return not db.noMountPlan end, function() db.noMountPlan = not db.noMountPlan end)
  Toggle(TR"Wege um Berge?", function() return db.walkPaths ~= false end, function()
    db.walkPaths = (db.walkPaths == false); if ns.Draw then ns.Draw() end end, TR"Pfeil und Karte folgen bekannten Wegen statt quer über den Berg.")
  -- 19.0 (Sascha): sicherer Weg fuer den Pfeil, wenn er hoechstens 20 % laenger ist
  Toggle(TR"Pfeil: sicherer Weg?", function() return db.arrowSafe ~= false end, function()
    db.arrowSafe = (db.arrowSafe == false); if ns.Karte then ns.Karte.ResetRoutes() end end,
    TR"Der Pfeil geht um Mobs herum, die für dich nicht grau sind, wenn der Weg höchstens 20 % länger ist.")
  -- 19.27 (Sascha Teil 1 Punkt 5): Sprungstellen bergab (Werkzeug k4), Standard an
  Toggle(TR"Pfeil: runter springen?", function() return db.arrowJump ~= false end, function()
    db.arrowJump = (db.arrowJump == false); if ns.Karte then ns.Karte.ResetRoutes() end end,
    TR"Der Pfeil springt Kanten bis 20 m runter (etwas Fallschaden). Mit wenig Leben nur kleine Sprünge, unter 30 % und auf Hardcore keine.")
  Toggle(TR"Warnung bei starken Patrouillen?", function() return db.patrolWarn ~= false end, function()
    db.patrolWarn = (db.patrolWarn == false); if ns.Draw then ns.Draw() end end,
    TR"Herumlaufende Elite oder viel stärkere Mobs: ihr Weg ist rot auf der Karte, nah dran kommt eine Warnung.")
  Toggle(TR"Wege teilen?", function() return db.shareWays ~= false end, function() ns.ToggleShareWays() end,
    TR"Deine gelaufenen Wege gehen frühestens nach 45 Minuten an andere Spieler mit dem Addon, ihre kommen zu dir. Aus: nichts senden, nichts empfangen.")
  EndRow()

  Header(TR"Quests")
  Toggle(TR"Quests automatisch annehmen und abgeben?", function() return db.autoQuest end, function() ns.ToggleAutoQuest() end, TR"Mit Shift gedrückt passiert es nicht.")
  Toggle(TR"Auto Quest auch für Quests, die nicht in der Route sind?", function() return db.autoQuestAll end, function() db.autoQuestAll = not db.autoQuestAll end,
    TR"Nein (Standard): nur Quests aus deiner Route und Klassenquests. Ja: jede passende Quest.")
  Toggle(TR"Quest Mobs markieren?", function() return db.markMobs ~= false end, function() ns.ToggleMarkMobs() end)
  Toggle(TR"Questgeber markieren?", function() return db.markGiver ~= false end, function() ns.ToggleMarkGiver() end)
  -- 1.1 (P41): Kartenpunkt aufs Ziel, von weitem und durch Waende sichtbar
  Toggle(TR"Kartenpunkt aufs Ziel (von weitem sichtbar)?", function() return db.worldPin == true end, function() if ns.ToggleWorldPin then ns.ToggleWorldPin() end end)
  -- 1.1 (P48): Plaketten weiter sichtbar nur auf Wunsch (setzt eine Spiel Einstellung, nie im Kampf)
  Toggle(TR"Namensplaketten weiter sichtbar (41 Yards)?", function() return db.markFar == true end, function()
    db.markFar = not (db.markFar == true)
    if not db.markFar and db.oldCVars and db.oldCVars.nameplateMaxDistance ~= nil and not (InCombatLockdown and InCombatLockdown()) then
      ns.Api.Prot("SetCVar", SetCVar, "nameplateMaxDistance", db.oldCVars.nameplateMaxDistance)
      db.oldCVars.nameplateMaxDistance = nil
    elseif db.markFar and ns.EnsureFriendlyPlates then ns.EnsureFriendlyPlates() end
  end)
  -- 1.1 (P51): Groesse der Symbole ueber Questgebern und Mobs (Standard 2.5 fach, gross 3.5 fach)
  Toggle(TR"Symbole über NPCs extra gross?", function() return (tonumber(db.markScale) or ns.MARK_SCALE_STD or 2.5) > (ns.MARK_SCALE_STD or 2.5) end, function()
    local std = ns.MARK_SCALE_STD or 2.5
    if (tonumber(db.markScale) or std) > std then db.markScale = nil else db.markScale = ns.MARK_SCALE_BIG end
    if ns.MarkRescale then ns.MarkRescale() end
  end)
  -- 20.2 (P11): Raid Symbole sind nur noch ein Zusatz zu den eigenen Markern (Blizzard kann sie sperren)
  Toggle(TR"Dazu Raid Symbole setzen (Totenkopf, Stern)?", function() return db.raidIcons ~= false end, function() db.raidIcons = (db.raidIcons == false) end,
    TR"Nur allein und ausserhalb vom Kampf. Die eigenen Marker über Quest Mobs und Questgeber kommen immer, auch ohne Raid Symbole.")
  Toggle(TR"Glitzern bei Items, Kräutern, Erz?", function() return db.sparkle end, function() ns.ToggleSparkle() end)
  Toggle(TR"Tipps zu Lehrer, Händler, Ruhestein?", function() return db.svcHints ~= false end, function() ns.ToggleSvcHints() end)
  Toggle(TR"Fenster mit neuen Zaubern alle 2 Level?", function() return db.trainerPopup ~= false end, function() db.trainerPopup = (db.trainerPopup == false) end,
    TR"Bei jedem geraden Level, wenn beim Lehrer etwas wartet: ein Fenster mit Lehrer, Ort und Zaubern.")
  Toggle(TR"Knöpfe für Quest Items?", function() return db.questItems end, function() ns.ToggleQuestItems() end)
  Toggle(TR"Questitems in Taschen markieren?", function() return db.markBags ~= false end, function()
    db.markBags = (db.markBags == false); if ns.MarkBags then ns.MarkBags() end end)
  Toggle(TR"Questitems schützen?", function() return db.protectItems ~= false end, function() db.protectItems = (db.protectItems == false) end,
    TR"Quest Items werden nicht verkauft oder weggeworfen.")
  Toggle(TR"Belohnung vorschlagen?", function() return db.gearHints ~= false end, function() db.gearHints = (db.gearHints == false) end,
    TR"Bei der Abgabe wird die Belohnung markiert, die für dich am besten ist.")
  Toggle(TR"Feiertag Quests einplanen?", function() return db.eventQuests end, function() db.eventQuests = not db.eventQuests; if ns.AutoOptSoon then ns.AutoOptSoon() end end,
    TR"Quests von Festen wie Schlotternächte. Nein: die Route lässt sie weg, auch wenn das Fest läuft.")
  Toggle(TR"Einkaufsliste in Städten?", function() return db.shopHint ~= false end, function() db.shopHint = (db.shopHint == false) end)
  Toggle(TR"Hinweis zur Waffenfertigkeit?", function() return db.weaponHint ~= false end, function() db.weaponHint = (db.weaponHint == false) end)
  EndRow()

  Header(TR"Gruppe")
  Toggle(TR"Fortschritt der Gruppe zeigen?", function() return db.groupSync ~= false end, function() ns.ToggleGroupSync() end)
  Toggle(TR"Quests automatisch teilen?", function() return db.autoShare ~= false end, function() ns.ToggleAutoShare() end)
  -- Elite an oder aus: Route neu rechnen, sonst bleiben die alten Elite Quests im Plan
  Toggle(TR"Elite Quests in der Gruppe?", function() return db.eliteGroup ~= false end, function() db.eliteGroup = (db.eliteGroup == false); Requiz(); if ns.AutoOptSoon then ns.AutoOptSoon() end end)
  Toggle(TR"Elite Quests auch allein?", function() return db.eliteSolo end, function() db.eliteSolo = not db.eliteSolo; Requiz(); if ns.AutoOptSoon then ns.AutoOptSoon() end end)
  -- 19.32 (Sascha 23:35): Elite allein erst ab N Level unter dir, N lernt pro Charakter mit (Start 2)
  Toggle(TR"Elite Grenze lernt mit?", function() return db.eliteLearn ~= false end, function() db.eliteLearn = (db.eliteLearn == false) end,
    TR"Stirbst du oft, kommen Elite Gegner allein erst später. Lange ohne Tod wieder früher, bis 1 Level Abstand.")
  EndRow()
  if Want() and not easyOnly and ns.EliteGapStep then
    local t = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    t:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 4)
    local function Fill() t:SetText(ns.EliteGapText and ns.EliteGapText() or "") end
    local minus = FlatButton(f, TR"früher", 70, 20)
    local plus = FlatButton(f, TR"später", 70, 20)
    minus:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 76, y)
    plus:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
    minus:SetScript("OnClick", function() ns.EliteGapStep(-1); Fill() end)
    plus:SetScript("OnClick", function() ns.EliteGapStep(1); Fill() end)
    t:SetPoint("RIGHT", minus, "LEFT", -8, 0)
    t:SetJustifyH("LEFT")
    f:HookScript("OnShow", Fill)
    Fill()
    y = y - 22 - GAP
  end

  -- Questlog Groesse und Warnung
  Header(TR"Questlog")
  if Want() then
  local ebMax = NumBox(TR"Plätze im Log", 0, function() return ns.LogMax() end)
  local ebWarn = NumBox(TR"Warnung ab", 150, function() return ns.LogWarn() end)
  local save = FlatButton(f, TR"Übernehmen", 100, 22)
  save:SetPoint("LEFT", ebWarn, "RIGHT", 10, 0)
  local function SaveLog()
    ebMax:ClearFocus(); ebWarn:ClearFocus()
    local m, w = tonumber(ebMax:GetText()), tonumber(ebWarn:GetText())
    local old = ns.LogMax()
    if m and m >= 10 and m <= 50 then db.logMax = m end
    if w and w >= 1 then db.logWarn = math.min(w, ns.LogMax()) else db.logWarn = nil end
    ebMax.Fill(); ebWarn.Fill()
    ns.Print((TR"Questlog: %d Plätze, Warnung ab %d Quests."):format(ns.LogMax(), ns.LogWarn()))
    -- 20.2 (Sascha 18:57: Klicks buendeln): Regler ziehen = eine Rechnung danach
    if old ~= ns.LogMax() and ns.AutoOptSoon then ns.AutoOptSoon() end
  end
  save:SetScript("OnClick", SaveLog)
  ebMax:SetScript("OnEnterPressed", SaveLog); ebWarn:SetScript("OnEnterPressed", SaveLog)
  sf:HookScript("OnShow", function() ebMax.Fill(); ebWarn.Fill() end)
  y = y - 22 - GAP - 6
  end

  -- 20.4b: Farmen Schalter nur mit dem Farming Zusatz Addon
  if ns.FarmAddonLoaded and ns.FarmAddonLoaded() then
  Header(TR"Farmen")
  Toggle(TR"Farmberufe Routen?", function() return ns.db.profOn ~= false end, function()
    ns.db.profOn = (ns.db.profOn == false); if ns.BigRelayNav then ns.BigRelayNav() end end,
    TR"Ja: unten in der Seitenleiste kommt Farmen dazu, mit Berufe und Gold (Kräuter, Erz, Leder und mehr).")
  end
  Toggle(TR"Elitegebiete beim Farmen meiden?", function() return ns.ProfPlanSettings().avoidElite end, function()
    local s = ns.ProfPlanSettings(); s.avoidElite = not s.avoidElite end)
  Toggle(TR"Gefährliche Orte beim Farmen meiden?", function() return ns.ProfPlanSettings().avoidDanger end, function()
    local s = ns.ProfPlanSettings(); s.avoidDanger = not s.avoidDanger end,
    TR"Gefährlich heisst: Mobs deutlich über deinem Level.")
  EndRow()

  Header(TR"Gold")
  Toggle(TR"Gold Quests an?", function() return db.goldMode end, function() ns.ToggleGold() end, TR"Im Modus Geführt ab Level 35, im Modus Alles frei sofort.")
  Toggle(TR"Preise aus dem Auktionshaus nutzen?", function() return db.farmAH ~= false end, function() db.farmAH = (db.farmAH == false) end, TR"Mit TSM oder Auktionator.")
  EndRow()

  local levelW = {}
  y = y - 8
  local hint = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  if only then hint:Hide() end
  hint:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
  hint:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
  hint:SetJustifyH("LEFT")
  hint:SetText(TR"Auf der Karte: Alt+Klick Gefahr markieren oder löschen")
  f:SetHeight(-y + (only and 12 or 40))
  Fit()

  sf.levelW = levelW
  return sf
end

------------------------------------------------------------
-- Aufbau
------------------------------------------------------------
local function Build()
  if tab or not CharacterFrame then return end
  UpdateAccent()

  -- Symbol rechts unten am Charakterfenster, unter den anderen Seitensymbolen, mit dem Logo
  tab = CreateFrame("Button", "TaurenRouteCharTab", CharacterFrame, BackdropTemplateMixin and "BackdropTemplate" or nil)
  tab:SetSize(36, 36)
  Template(tab, nil, "button")
  local logo = T.Logo(tab, 30)
  logo:SetPoint("CENTER")
  local hl = tab:CreateTexture(nil, "HIGHLIGHT")
  hl:SetPoint("TOPLEFT", 2, -2); hl:SetPoint("BOTTOMRIGHT", -2, 2)
  hl:SetColorTexture(1, 1, 1, 0.2)
  tab:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(TR"Keine Zeit Leveling Guide")
    GameTooltip:AddLine(TR"Klick: Upgrades aus Quests für deine Ausrüstung", 1, 1, 1)
    GameTooltip:Show()
  end)
  tab:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Seite im Charakterfenster: links Inhalt, rechts Route
  page = CreateFrame("Frame", "TaurenRouteCharPage", CharacterFrame)
  page:SetPoint("TOPLEFT", CharacterFrame, "TOPLEFT", 2, -24)
  page:SetPoint("BOTTOMRIGHT", CharacterFrame, "BOTTOMRIGHT", -2, 2)
  page:Hide()
  local function TT(x) return type(x) == "table" and x or nil end
  local leftHost = TT(CharacterFrame.LeftPaneHost)
  local rightHost = TT(CharacterFrame.RightPaneHost)

  local leftBg, rightBg
  local ORDER = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP" }
  local function Raise()
    local base = CharacterFrame:GetFrameStrata() or "MEDIUM"
    local idx = 3
    for i, n in ipairs(ORDER) do if n == base then idx = i end end
    page:SetFrameStrata(ORDER[math.min(idx + 1, 5)])
    page:SetFrameLevel(10)
    if leftBg then leftBg:SetFrameLevel(11) end
    if rightBg then rightBg:SetFrameLevel(11) end
  end
  Raise()

  leftBg = CreateFrame("Frame", nil, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
  if leftHost then
    leftBg:SetAllPoints(leftHost)
  else
    leftBg:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
    leftBg:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
    leftBg:SetWidth(440)
  end
  leftBg:EnableMouse(true)
  Template(leftBg, nil, "window")
  if T.IsElv() and leftBg.SetBackdropColor then leftBg:SetBackdropColor(0.08, 0.08, 0.08, 0.97) end
  local left = CreateFrame("Frame", nil, leftBg)
  local inset = T.IsElv() and 10 or 14
  left:SetPoint("TOPLEFT", leftBg, "TOPLEFT", inset, -inset)
  left:SetPoint("BOTTOMRIGHT", leftBg, "BOTTOMRIGHT", -inset, inset)

  -- Kopf: Logo, Name, Modus, Zone und Level, Knoepfe
  header = CreateFrame("Frame", nil, left)
  header:SetPoint("TOPLEFT")
  header:SetPoint("TOPRIGHT")
  header:SetHeight(36)
  local hlogo = T.Logo(header, 32)
  hlogo:SetPoint("LEFT")
  local title = header:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
  title:SetPoint("TOPLEFT", hlogo, "TOPRIGHT", 8, -1)
  title:SetText(T.IsElv() and TR"Keine Zeit Leveling Guide" or TR"Keine Zeit Leveling Guide")
  if T.IsElv() then title:SetTextColor(1, 1, 1) end
  header.chip = T.Chip(header)
  header.chip:SetPoint("LEFT", title, "RIGHT", 8, 0)
  header.sub = header:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  header.sub:SetPoint("BOTTOMLEFT", hlogo, "BOTTOMRIGHT", 8, 1)
  local full = FlatButton(header, TR"Vollbild", 76, 20)
  full:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0)
  full:SetScript("OnClick", function() if ns.ToggleBig then ns.ToggleBig() end end)
  local ver = header:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  ver:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
  local v = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)
  -- 19.30: Code Version und Daten Stand getrennt (zb "v19.30, Daten 57"), Daten koennen ohne Code neu kommen
  local ki = ns.Karte and ns.Karte.Info and ns.Karte.Info()
  local st = type(ki) == "table" and ki.stand
  -- 19.32: dazu der Stand der Daten Korrektur vom Daten Chat (zb "Korrektur Daten 1"), wenn die Datei da ist
  local dk = ns.DKInfo and ns.DKInfo()
  local dks = dk and dk.short and ((dk.quests or 0) + (dk.items or 0)) > 0 and (TR", Korrektur %s"):format((dk.short:gsub("^Daten%s+", ""))) or ""
  ver:SetText("v" .. ((v and v(ADDON, "Version")) or "?") .. (st and (TR", Daten %s"):format(tostring(st)) or "") .. dks)

  -- Balken: Zone und Level
  zoneBar = MakeBar(left)
  zoneBar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -8)
  zoneBar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -8)
  zoneBar:SetStatusBarColor(ACCENT[1] * 0.75, ACCENT[2] * 0.75, ACCENT[3] * 0.75, 0.85)
  xpBar = MakeBar(left)
  xpBar:SetPoint("TOPLEFT", zoneBar, "BOTTOMLEFT", 0, -4)
  xpBar:SetPoint("TOPRIGHT", zoneBar, "BOTTOMRIGHT", 0, -4)
  xpBar:SetStatusBarColor(0.58, 0.0, 0.55, 0.85)

  -- Reiter
  tabBar = T.Tabs(left, TAB_ITEMS, function(k) view = k; Refresh() end)
  tabBar:SetPoint("TOPLEFT", xpBar, "BOTTOMLEFT", 0, -8)
  tabBar:SetPoint("TOPRIGHT", xpBar, "BOTTOMRIGHT", 0, -8)
  local function LayTabs()
    for i, it in ipairs(TAB_ITEMS) do tabBar.btns[i]:SetShown(TabOk(it)) end
    tabBar.Lay()
  end
  LayTabs()
  page.LayTabs = LayTabs
  -- erstes Mal offen: Knoepfe kurz erklaeren
  page:HookScript("OnShow", function()
    if not ns.CoachLater then return end
    ns.CoachLater("char", function()
      return {
        { target = header.chip, side = "BOTTOM", title = TR"Tempo und Modus", text = TR"Hier wählst du Tempo und Modus. Maus auf einen Eintrag erklärt ihn." },
        { target = tiles and tiles.frame, side = "BOTTOM", title = TR"Auf einen Blick", text = TR"Tempo, Zeit bis zum nächsten Level, Questlog und was fertig zum Abgeben ist. Darunter was jetzt dran ist, Questziele und Tipps." },
        { target = full, side = "BOTTOM", title = TR"Vollbild", text = TR"Alles andere ist im grossen Fenster: Meine Route, Mein Weg, Dungeons, Ausrüstung, Einstellungen und Hilfe." },
      }
    end)
  end)

  bodyFrame = CreateFrame("Frame", nil, left)
  -- keine Reiter mehr: nur das Wichtigste, alles andere im Vollbild
  tabBar:Hide()
  bodyFrame:SetPoint("TOPLEFT", xpBar, "BOTTOMLEFT", 0, -10)
  bodyFrame:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, 0)

  -- Kacheln (Uebersicht)
  tiles = {}
  tiles.frame = CreateFrame("Frame", nil, bodyFrame)
  tiles.frame:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 0, 0)
  tiles.frame:SetPoint("TOPRIGHT", bodyFrame, "TOPRIGHT", 0, 0)
  tiles.frame:SetHeight(50)
  for i = 1, 4 do tiles[i] = MakeTile(tiles.frame) end
  local function LayTiles()
    local w = tiles.frame:GetWidth()
    if not w or w <= 0 then return end
    local gap = 6
    local tw = (w - gap * 3) / 4
    for i = 1, 4 do
      tiles[i]:ClearAllPoints()
      tiles[i]:SetSize(tw, 50)
      tiles[i]:SetPoint("LEFT", tiles.frame, "LEFT", (i - 1) * (tw + gap), 0)
    end
  end
  tiles.frame:SetScript("OnSizeChanged", LayTiles)
  LayTiles()

  -- Diagramme (Performance)
  charts = {}
  charts.frame = CreateFrame("Frame", nil, bodyFrame)
  charts.frame:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 0, 0)
  charts.frame:SetPoint("TOPRIGHT", bodyFrame, "TOPRIGHT", 0, 0)
  charts.frame:SetHeight(194)
  charts.rate = MakeChart(charts.frame, TR"XP pro Stunde, letzte Stunde")
  charts.rate:SetPoint("TOPLEFT")
  charts.rate:SetPoint("TOPRIGHT")
  charts.rate:SetHeight(94)
  charts.lvl = MakeChart(charts.frame, TR"Zeit pro Level")
  charts.lvl:SetPoint("TOPLEFT", charts.rate, "BOTTOMLEFT", 0, -6)
  charts.lvl:SetPoint("TOPRIGHT", charts.rate, "BOTTOMRIGHT", 0, -6)
  charts.lvl:SetHeight(94)
  charts.frame:Hide()

  -- Route: Art der Route waehlen
  routeModes = CreateFrame("Frame", nil, bodyFrame)
  routeModes:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 0, 0)
  routeModes:SetPoint("TOPRIGHT", bodyFrame, "TOPRIGHT", 0, 0)
  routeModes:SetHeight(24)
  do
    local MODES = {
      { "all", TR"Alles", nil, function() if ns.SetLevelStep then ns.SetLevelStep(1) end end },
      { "normal", TR"Normal", nil, function() if ns.SetLevelStep then ns.SetLevelStep(2) end end },
      { "log", TR"Questlog Route", "questlog", function() if ns.TourQuestLog then ns.TourQuestLog() end end },
    }
    routeModes.btns = {}
    for i, m in ipairs(MODES) do
      local b = FlatButton(routeModes, m[2], 100, 22)
      b:SetScript("OnClick", function() m[4](); C_Timer.After(0.5, Refresh) end)
      b.key, b.lock = m[1], m[3]
      routeModes.btns[i] = b
    end
    routeModes:SetScript("OnSizeChanged", function(self, w)
      local gap = 4
      local nb = math.max(1, #self.btns)
      local bw = ((w or 400) - gap * (nb - 1)) / nb
      for i, b in ipairs(self.btns) do
        b:ClearAllPoints(); b:SetWidth(bw)
        b:SetPoint("LEFT", self, "LEFT", (i - 1) * (bw + gap), 0)
      end
    end)
    function routeModes.Update()
      local cur = RouteKind()
      for _, b in ipairs(routeModes.btns) do
        T.Lock(b, b.lock and ns.LockText(b.lock) or nil)
        local on = (b.key == cur)
        if T.IsElv() then
          if b.SetBackdropBorderColor then
            if on then b:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1) else b:SetBackdropBorderColor(0, 0, 0, 1) end
          end
        else
          if on then b:LockHighlight() else b:UnlockHighlight() end
        end
        if b.fs and b:IsEnabled() then
          if on then b.fs:SetTextColor(1, 1, 1) elseif T.IsElv() then b.fs:SetTextColor(0.75, 0.75, 0.75) else b.fs:SetTextColor(1, 0.82, 0) end
        end
      end
    end
  end
  routeModes:Hide()

  -- Mein Weg: Fortschritt der Freischaltungen
  wegTop = CreateFrame("Frame", nil, bodyFrame)
  wegTop:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 0, 0)
  wegTop:SetPoint("TOPRIGHT", bodyFrame, "TOPRIGHT", 0, 0)
  wegTop:SetHeight(30)
  wegTop.bar = MakeBar(wegTop)
  wegTop.bar:SetPoint("TOPLEFT", 0, -4); wegTop.bar:SetPoint("TOPRIGHT", 0, -4)
  wegTop.bar:SetStatusBarColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
  function wegTop.Update()
    local n, tot = ns.UnlockProgress()
    local L = UnitLevel("player") or 1
    wegTop.bar:SetValue(math.min(1, (L - 1) / 59))
    wegTop.bar.text:SetText(TR"Dein Weg bis 60")
    wegTop.bar.right:SetText((TR"%d von %d frei"):format(n, tot))
  end
  wegTop:Hide()

  -- Funktionen: Knoepfe als Karten, gesperrte zeigen ihr Level
  funcGrid = CreateFrame("Frame", nil, bodyFrame)
  funcGrid:SetPoint("TOPLEFT", bodyFrame, "TOPLEFT", 0, 0)
  funcGrid:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", 0, 34)
  funcGrid.cards = {}
  do
    local FUNCS = {
      { TR"Neu rechnen", TR"Route", nil, function() if ns.AutoOpt then ns.AutoOpt("hand") end end },
      { TR"Einkaufsliste", TR"für Quests", "shop", function() if ns.ShowShopping then ns.ShowShopping() end end },
      { TR"Questlog Route", TR"nur Log", "questlog", function() if ns.TourQuestLog then ns.TourQuestLog() end end },
      { TR"Feierabend", TR"Gasthaus", "sleep", function() if ns.EndSession then ns.EndSession() end end },
      { TR"Händler", TR"verkaufen", "vendor", function() if ns.FindVendor then ns.FindVendor() end end },
      { TR"Bücher Route", TR"Auswahl", "books", function() if ns.TourBooks then ns.TourBooks(true) end end },
      { TR"Flugpunkte Tour", TR"fehlende", "flights", function() if ns.TourFlights then ns.TourFlights() end end },
      { TR"Entdecken Tour", TR"Gebiete", "explore", function() if ns.TourExplore then ns.TourExplore() end end },
      { TR"Ausrüstung", TR"Quests", "gear", function() if ns.ShowBig then ns.ShowBig("gear") end end },
      { TR"Stunden Budget", TR"Zeit", "budget", function() if ns.ShowBudget then ns.ShowBudget() end end },
      { TR"Tempo", TR"Regler", nil, function()
        -- der Reiter Planen kommt bei Geführt erst ab Level 13, vorher steht der Regler in den Einstellungen (Tempo)
        if not ns.ShowBig then return end
        if ns.Unlocked("plan") then ns.ShowBig("plan"); return end
        ns.ShowBig("set")
        local pg = ns.BigJPage and ns.BigJPage("set")
        if pg and pg.Pick then pg.Pick(TR"Tempo") end
      end },
      { TR"Gold", TR"Mobs", "farm", function() if ns.ShowBig then ns.ShowBig("farm") end end },
    }
    for i, fx in ipairs(FUNCS) do
      local c = T.Card(funcGrid, 200, 34)
      c.title:ClearAllPoints(); c.title:SetPoint("LEFT", 10, 0); c.title:SetPoint("RIGHT", -70, 0)
      c.sub:ClearAllPoints(); c.sub:SetPoint("RIGHT", -10, 0); c.sub:SetJustifyH("RIGHT")
      c.state:Hide()
      c:SetScript("OnClick", function() if ns.Unlocked(fx[3] or "") then fx[4](); Refresh() end end)
      function c.Update()
        local lt = fx[3] and ns.LockText(fx[3])
        c.Set(fx[1], lt and (TR"ab " .. ns.UnlockLevel(fx[3])) or fx[2], "", lt and "lock" or "inset")
      end
      funcGrid.cards[i] = c
    end
    funcGrid:SetScript("OnSizeChanged", function(self, w)
      local gap = 6
      local cw = ((w or 400) - gap) / 2
      for i, c in ipairs(self.cards) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        c:ClearAllPoints(); c:SetSize(cw, 34)
        c:SetPoint("TOPLEFT", self, "TOPLEFT", col * (cw + gap), -row * 40)
      end
    end)
  end
  funcGrid:Hide()

  -- Knoepfe unten (je Reiter andere)
  btnRow = CreateFrame("Frame", nil, bodyFrame)
  btnRow:SetPoint("BOTTOMLEFT", bodyFrame, "BOTTOMLEFT", 0, 0)
  btnRow:SetPoint("BOTTOMRIGHT", bodyFrame, "BOTTOMRIGHT", 0, 0)
  btnRow:SetHeight(26)
  btnRow.btns, btnRow.n = {}, 0
  for i = 1, 3 do btnRow.btns[i] = FlatButton(btnRow, "", 100, 24) end
  function btnRow.Set(list)
    local key = ""
    for _, b in ipairs(list) do key = key .. b[1] end
    btnRow.n = #list
    local w = btnRow:GetWidth()
    if not w or w <= 0 then w = 400 end
    local gap = 6
    local bw = #list > 0 and (w - gap * (#list - 1)) / #list or w
    for i, b in ipairs(btnRow.btns) do
      local e = list[i]
      if e then
        if btnRow.key ~= key then
          b:SetText(e[1])
          b:ClearAllPoints(); b:SetWidth(bw)
          b:SetPoint("LEFT", btnRow, "LEFT", (i - 1) * (bw + gap), 0)
        end
        b:SetScript("OnClick", function() if not e[3] or ns.Unlocked(e[3]) then e[2](); Refresh() end end)
        T.Lock(b, e[3] and ns.LockText(e[3]) or nil)
        T.SetPrimary(b, i == 1)
        b:Show()
      else
        b:Hide()
      end
    end
    btnRow.key = key
    btnRow:SetShown(#list > 0)
  end
  btnRow:SetScript("OnSizeChanged", function() btnRow.key = nil end)

  scroll = CreateFrame("ScrollFrame", "TaurenRouteCharScroll", bodyFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", tiles.frame, "BOTTOMLEFT", 0, -8)
  scroll:SetPoint("BOTTOMRIGHT", btnRow, "TOPRIGHT", -18, 6)
  SkinScroll(scroll)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(10, 10)
  scroll:SetScrollChild(content)
  textFS = content:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  textFS:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
  textFS:SetJustifyH("LEFT")
  textFS:SetJustifyV("TOP")
  textFS:SetSpacing(4)
  scroll:SetScript("OnSizeChanged", function(self, w)
    if w and w > 0 then content:SetWidth(w); textFS:SetWidth(w - 4) end
  end)

  -- rechts: Route als Liste
  rightBg = CreateFrame("Frame", nil, page, BackdropTemplateMixin and "BackdropTemplate" or nil)
  if rightHost then
    rightBg:SetAllPoints(rightHost)
  else
    rightBg:SetPoint("TOPLEFT", leftBg, "TOPRIGHT", 0, 0)
    rightBg:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
  end
  rightBg:EnableMouse(true)
  Template(rightBg, nil, "window")
  if T.IsElv() and rightBg.SetBackdropColor then rightBg:SetBackdropColor(0.08, 0.08, 0.08, 0.97) end
  local right = CreateFrame("Frame", nil, rightBg, BackdropTemplateMixin and "BackdropTemplate" or nil)
  local ri = T.IsElv() and 6 or 12
  right:SetPoint("TOPLEFT", rightBg, "TOPLEFT", ri, -ri)
  right:SetPoint("BOTTOMRIGHT", rightBg, "BOTTOMRIGHT", -ri, ri)
  Template(right, "Transparent")
  local rtitle = right:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  rtitle:SetPoint("TOPLEFT", right, "TOPLEFT", 10, -9)
  rtitle:SetText(Section(TR"Route"))
  page.routeSub = right:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  page.routeSub:SetPoint("TOPRIGHT", right, "TOPRIGHT", -10, -10)
  local rline = right:CreateTexture(nil, "ARTWORK")
  rline:SetPoint("TOPLEFT", right, "TOPLEFT", 8, -26)
  rline:SetPoint("TOPRIGHT", right, "TOPRIGHT", -8, -26)
  rline:SetHeight(1)
  rline:SetColorTexture(1, 1, 1, 0.12)
  routeScroll = CreateFrame("ScrollFrame", "TaurenRouteRouteScroll", right, "UIPanelScrollFrameTemplate")
  routeScroll:SetPoint("TOPLEFT", right, "TOPLEFT", 8, -32)
  routeScroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -26, 8)
  SkinScroll(routeScroll)
  routeContent = CreateFrame("Frame", nil, routeScroll)
  routeContent:SetSize(10, 10)
  routeScroll:SetScrollChild(routeContent)
  routeFS = routeContent:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  routeFS:SetPoint("TOPLEFT", routeContent, "TOPLEFT", 0, 0)
  routeFS:SetJustifyH("LEFT")
  routeFS:SetJustifyV("TOP")
  routeFS:SetSpacing(3)
  routeScroll:SetScript("OnSizeChanged", function(self, w)
    if w and w > 0 then routeContent:SetWidth(w); routeFS:SetWidth(w - 4) end
  end)

  local function CheckRight()
    if rightHost then rightBg:SetShown(rightHost:IsShown() and (rightHost:GetWidth() or 0) > 40) end
  end
  page.CheckRight = CheckRight

  -- "Stufe X, Klasse" oben im Fenster ausblenden, wie es die anderen Seiten auch machen
  local hiddenFS = {}
  local function HideHeader()
    local cls = UnitClass("player")
    if type(cls) ~= "string" then return end
    local function Check(r)
      if type(r) ~= "table" or hiddenFS[r] or not r.GetObjectType then return end
      if r:GetObjectType() ~= "FontString" or not r:IsVisible() then return end
      local ok, t = pcall(r.GetText, r)
      if not ok or type(t) ~= "string" or (issecretvalue and issecretvalue(t)) then return end
      if t:find(cls, 1, true) then
        hiddenFS[r] = true
        r:SetAlpha(0)
      end
    end
    Check(_G.CharacterLevelText)
    local function Scan(fr, depth)
      if fr == page then return end
      for _, r in ipairs({ fr:GetRegions() }) do Check(r) end
      if depth < 3 then
        for _, c in ipairs({ fr:GetChildren() }) do
          if c ~= page and c ~= tab then Scan(c, depth + 1) end
        end
      end
    end
    Scan(CharacterFrame, 0)
  end
  local function ShowHeader()
    for r in pairs(hiddenFS) do r:SetAlpha(1) end
    wipe(hiddenFS)
  end
  page:SetScript("OnShow", function()
    Raise(); CheckRight(); HideHeader(); LayTabs()
    Refresh()
  end)
  page:SetScript("OnHide", ShowHeader)
  if TT(CharacterFrame.RightPaneToggleButton) then
    CharacterFrame.RightPaneToggleButton:HookScript("OnClick", function() C_Timer.After(0, CheckRight) end)
  end

  -- Klick: schmale Leiste mit Upgrades aus Quests (das alte grosse Feld gibt es nicht mehr)
  tab:SetScript("OnClick", function()
    page:Hide()
    if ns.ToggleUpgradeStrip then ns.ToggleUpgradeStrip() end
  end)

  CharacterFrame:HookScript("OnShow", function()
    C_Timer.After(0, PlaceTab)
    if ns.openPageOnShow then
      ns.openPageOnShow = false
      C_Timer.After(0, function() if ns.ToggleUpgradeStrip then ns.ToggleUpgradeStrip() end end)
    end
  end)
  CharacterFrame:HookScript("OnHide", function() page:Hide() end)
  if CharacterFrame:IsShown() then PlaceTab() end

  ns.Ticker(1, Refresh)
end


------------------------------------------------------------
-- Grosses Fenster (Vollbild) mit Seiten und Statistiken
------------------------------------------------------------
local big
local bigView = nil
-- welche Seite im grossen Fenster offen ist (fuer das Test Log)
function ns.BigViewName() return bigView end
local dungFilledAt
local dungFilled = {}
local detailFilledAt
local repFilled, farmFilled, gearFilled

local function ScrollText(parent, name, font)
  local sf = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
  SkinScroll(sf)
  local c = CreateFrame("Frame", nil, sf)
  c:SetSize(10, 10)
  sf:SetScrollChild(c)
  local fs = c:CreateFontString(nil, "OVERLAY", font or ns.FontName("GameFontHighlight"))
  fs:SetPoint("TOPLEFT")
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  fs:SetSpacing(4)
  sf:SetScript("OnSizeChanged", function(_, w) if w and w > 0 then c:SetWidth(w); fs:SetWidth(w - 4) end end)
  function sf.Set(lines)
    fs:SetText(type(lines) == "table" and table.concat(lines, "\n") or (lines or ""))
    c:SetHeight(fs:GetStringHeight() + 20)
  end
  return sf
end

-- Lange Liste (ganzer Plan, ueber 1000 Zeilen): nur die sichtbaren Zeilen gibt es als Knopf,
-- beim Scrollen werden sie neu gefuellt. fill(row, data) setzt den Inhalt.
local function VList(parent, rowH, fill, onClick)
  local box = T.Panel(parent, "inset")
  local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -24, 4)
  SkinScroll(sf)
  local c = CreateFrame("Frame", nil, sf)
  c:SetSize(300, 10)
  sf:SetScrollChild(c)
  box.rows, box.data = {}, {}
  local r1, g1, b1 = T.Acc()
  local function Row(i)
    local r = box.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, c)
    r:SetHeight(rowH)
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(); r.bg:SetColorTexture(1, 1, 1, 0.05)
    r.sel = r:CreateTexture(nil, "BACKGROUND", nil, 1); r.sel:SetAllPoints(); r.sel:SetColorTexture(r1, g1, b1, 0.18)
    r.bar = r:CreateTexture(nil, "ARTWORK"); r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(3); r.bar:SetColorTexture(r1, g1, b1, 1)
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.06)
    r.num = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); r.num:SetPoint("LEFT", 4, 0); r.num:SetWidth(34); r.num:SetJustifyH("RIGHT")
    r.dot = r:CreateTexture(nil, "ARTWORK"); r.dot:SetSize(7, 7); r.dot:SetPoint("LEFT", 44, 0); r.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    r.right = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); r.right:SetPoint("RIGHT", -6, 0); r.right:SetJustifyH("RIGHT")
    r.t = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall")); r.t:SetPoint("LEFT", 58, 0); r.t:SetPoint("RIGHT", r.right, "LEFT", -8, 0)
    r.t:SetJustifyH("LEFT"); r.t:SetWordWrap(false)
    -- 19.31 (Saschas Runde: Texte auf Route abgeschnitten): ist der Text zu lang, zeigt die Maus ihn ganz
    r.t.fwTip = true
    r:SetScript("OnEnter", function(self)
      if not (self.t.IsTruncated and self.t:IsTruncated()) then return end
      ns.TipOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(self.t:GetText() or "", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self) if onClick and self.data then onClick(self.data) end end)
    box.rows[i] = r
    return r
  end
  local function Render()
    local off = sf:GetVerticalScroll() or 0
    local h = sf:GetHeight() or 300
    local first = math.max(1, math.floor(off / rowH) + 1)
    local n = math.ceil(h / rowH) + 2
    for i = 1, n do
      local di = first + i - 1
      local d = box.data[di]
      local r = Row(i)
      if d then
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(di - 1) * rowH)
        r:SetPoint("RIGHT", c, "RIGHT", 0, 0)
        r.data = d
        fill(r, d)
        r:Show()
      else
        r:Hide(); r.data = nil
      end
    end
    for i = n + 1, #box.rows do box.rows[i]:Hide(); box.rows[i].data = nil end
  end
  box.Render = Render
  sf:HookScript("OnVerticalScroll", Render)
  sf:HookScript("OnSizeChanged", function(_, w) if w and w > 0 then c:SetWidth(w) end; Render() end)
  function box.Set(list)
    box.data = list or {}
    c:SetHeight(math.max(10, #box.data * rowH))
    Render()
  end
  function box.ScrollTo(i)
    local h = sf:GetHeight() or 300
    local maxs = math.max(0, #box.data * rowH - h)
    sf:SetVerticalScroll(math.max(0, math.min(maxs, (i - 4) * rowH)))
    Render()
  end
  box.sf = sf
  return box
end

local function Box(parent, title)
  local b = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  Template(b, "Transparent")
  if title then
    b.title = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
    b.title:SetPoint("TOPLEFT", 8, -6)
    b.title:SetText(Section(title))
  end
  return b
end

-- Liste mit waagrechten Balken: Name, Balken, Wert
local function HBars(parent, rows)
  local f = CreateFrame("Frame", nil, parent)
  f.rows = {}
  for i = 1, rows do
    local r = {}
    r.label = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    r.label:SetPoint("TOPLEFT", 0, -(i - 1) * 18)
    r.label:SetWidth(130)
    r.label:SetJustifyH("LEFT")
    r.label:SetWordWrap(false)
    r.bar = f:CreateTexture(nil, "ARTWORK")
    r.bar:SetPoint("TOPLEFT", 134, -(i - 1) * 18 - 2)
    r.bar:SetHeight(11)
    r.val = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    r.val:SetPoint("TOPRIGHT", 0, -(i - 1) * 18)
    f.rows[i] = r
  end
  function f.Set(list, col)
    local mx = 0
    for _, e in ipairs(list) do if e.v > mx then mx = e.v end end
    local w = math.max(10, (f:GetWidth() or 300) - 134 - 90)
    for i, r in ipairs(f.rows) do
      local e = list[i]
      if e and mx > 0 then
        r.label:SetText(e.name); r.label:Show()
        r.bar:SetWidth(math.max(1, e.v / mx * w))
        local c = e.col or col
        r.bar:SetColorTexture(c[1], c[2], c[3], 0.85); r.bar:Show()
        r.val:SetText(e.text or ""); r.val:Show()
      else
        r.label:Hide(); r.bar:Hide(); r.val:Hide()
      end
    end
  end
  return f
end

-- ein Balken mit Anteilen (z.B. XP Quellen) und Legende
local function StackBar(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(40)
  f.segs, f.leg = {}, {}
  for i = 1, 6 do
    f.segs[i] = f:CreateTexture(nil, "ARTWORK")
    f.segs[i]:SetHeight(16)
    f.leg[i] = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
  end
  function f.Set(parts)
    local total = 0
    for _, p in ipairs(parts) do total = total + p.v end
    local w = f:GetWidth() or 300
    local x = 0
    local lx = 0
    for i = 1, 6 do
      local p = parts[i]
      local s, l = f.segs[i], f.leg[i]
      if p and total > 0 and p.v > 0 then
        local sw = p.v / total * w
        s:ClearAllPoints(); s:SetPoint("TOPLEFT", f, "TOPLEFT", x, 0); s:SetWidth(math.max(1, sw))
        s:SetColorTexture(p.col[1], p.col[2], p.col[3], 0.9); s:Show()
        x = x + sw
        l:ClearAllPoints(); l:SetPoint("TOPLEFT", f, "TOPLEFT", lx, -22)
        l:SetText((TR"|cff%02x%02x%02x%s|r %d%%"):format(math.floor(p.col[1] * 255), math.floor(p.col[2] * 255), math.floor(p.col[3] * 255), p.name, math.floor(p.v / total * 100 + 0.5)))
        l:Show()
        lx = lx + l:GetStringWidth() + 18
      else
        s:Hide(); l:Hide()
      end
    end
    if total <= 0 then
      f.leg[1]:ClearAllPoints(); f.leg[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -4)
      f.leg[1]:SetText(TR"|cff9d9d9dnoch keine Daten|r"); f.leg[1]:Show()
    end
  end
  return f
end

local function BuildBig()
  if big then return end
  UpdateAccent()
  big = CreateFrame("Frame", "TaurenRouteBig", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  -- immer gleich gross gebaut (alle Seiten passen rein), bei kleinem Bildschirm oder grossem UI Scale als Ganzes kleiner
  local BIG_W, BIG_H = 1150, 720
  big:SetSize(BIG_W, BIG_H)
  -- 20.2b (P15, Sascha 14:16): eigener Faktor 70 bis 160 % je Charakter (Griff unten rechts), mal dem Grund Massstab,
  -- der das Fenster in den Bildschirm passt. Alles waechst gleichmaessig, das Layout bleibt
  local BIG_MIN, BIG_MAX = 0.7, 1.6
  local function UserF() return math.max(BIG_MIN, math.min(BIG_MAX, tonumber(ns.db and ns.db.bigScale) or 1)) end
  local function FitBig()
    local sw, sh = UIParent:GetWidth() or 1366, UIParent:GetHeight() or 768
    local base = math.max(0.5, math.min(1, sh * 0.92 / BIG_H, sw * 0.96 / BIG_W))
    local maxFit = math.min(sh * 0.98 / BIG_H, sw * 0.98 / BIG_W)
    big:SetScale(math.max(0.35, math.min(base * UserF(), maxFit)))
  end
  big.FitBig = FitBig
  FitBig()
  big:RegisterEvent("UI_SCALE_CHANGED")
  big:RegisterEvent("DISPLAY_SIZE_CHANGED")
  big:SetScript("OnEvent", function() FitBig() end)
  big:SetPoint("CENTER")
  big:SetFrameStrata("DIALOG")
  big:SetMovable(true)
  big:EnableMouse(true)
  big:RegisterForDrag("LeftButton")
  big:SetScript("OnDragStart", big.StartMoving)
  big:SetScript("OnDragStop", big.StopMovingOrSizing)
  big:SetClampedToScreen(true)
  Template(big, nil, "window")
  if ns.CloseOnEscape then ns.CloseOnEscape(big) end
  -- 20.3j (S Test 20.3g Punkt 12): Weltkarte (M) liegt ueber dem grossen Fenster. Solange die Karte offen ist, geht das
  -- Fenster eine Ebene tiefer, danach wieder zurueck. Nur Ebene (Strata), nichts an der Karte selbst (kein Taint)
  if WorldMapFrame and WorldMapFrame.HookScript then
    local function Low() if big:IsShown() then big:SetFrameStrata("MEDIUM") end end
    pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnShow", Low)
    pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnHide", function() big:SetFrameStrata("DIALOG") end)
    big:HookScript("OnShow", function() if WorldMapFrame:IsShown() then big:SetFrameStrata("MEDIUM") else big:SetFrameStrata("DIALOG") end end)
  end
  big:Hide()
  -- 20.2b (P15): Griff unten rechts, ziehen = ganzes Fenster groesser oder kleiner, Doppelklick = 100 %.
  -- Die linke obere Ecke bleibt, wo sie ist. Eigene Punkte statt Blizzard Grafik
  do
    local grip = CreateFrame("Button", nil, big)
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel(big:GetFrameLevel() + 50)
    local r, g, b = T.Acc()
    for i = 1, 3 do
      for j = 1, i do
        local d = grip:CreateTexture(nil, "OVERLAY")
        d:SetSize(3, 3)
        d:SetColorTexture(r, g, b, 0.9)
        d:SetPoint("BOTTOMRIGHT", -(j - 1) * 5 - 2, (i - j) * 5 + 2)
      end
    end
    local function Keep(newF)
      local l, t, s0 = big:GetLeft(), big:GetTop(), big:GetScale()
      if ns.db then ns.db.bigScale = math.max(BIG_MIN, math.min(BIG_MAX, newF)) end
      FitBig()
      local s1 = big:GetScale()
      if l and t and s1 > 0 then
        big:ClearAllPoints()
        big:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l * s0 / s1, t * s0 / s1)
      end
    end
    local drag
    grip:SetScript("OnMouseDown", function()
      local cx = GetCursorPosition()
      drag = { cx = cx, f = UserF(), w = (big:GetWidth() or BIG_W) * big:GetEffectiveScale() }
      grip:SetScript("OnUpdate", function()
        if not drag then return end
        local x = GetCursorPosition()
        if drag.w > 0 then Keep(drag.f * (1 + (x - drag.cx) / drag.w)) end
      end)
    end)
    grip:SetScript("OnMouseUp", function() drag = nil; grip:SetScript("OnUpdate", nil) end)
    grip:SetScript("OnDoubleClick", function() Keep(1) end)
    grip:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOPLEFT")
      GameTooltip:AddLine(TR"Fenster grösser oder kleiner", 1, 1, 1)
      GameTooltip:AddLine((TR"Ziehen ändert die Grösse (70 bis 160 %%, jetzt %d %%). Doppelklick: zurück auf 100 %%."):format(math.floor(UserF() * 100 + 0.5)), 1, 0.82, 0, true)
      GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  local PAD = T.IsElv() and 12 or 16

  -- ElvUI: Fenster fast deckend wie im Konzept, nicht durchsichtig
  if T.IsElv() and big.SetBackdropColor then big:SetBackdropColor(0.08, 0.08, 0.08, 0.97) end
  local IN = T.IsElv() and 1 or 6

  -- Kopfleiste: Logo, Name, Modus Schild, rechts Charakter und Level
  local head = T.HeadStrip(big, 58, IN)
  local logo = T.Logo(head, 38)
  logo:SetPoint("LEFT", 14, 0)
  local title = head:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
  title:SetPoint("LEFT", logo, "RIGHT", 12, 0)
  title:SetText(TR"Keine Zeit Leveling Guide")
  if T.IsElv() then title:SetTextColor(1, 1, 1) end
  big.chip = T.Chip(head)
  big.chip:SetPoint("LEFT", title, "RIGHT", 14, 0)
  big.mode = big.chip.text
  big.sub = head:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
  big.sub:SetPoint("RIGHT", head, "RIGHT", -74, 0)
  big.sub:SetTextColor(0.75, 0.72, 0.62)
  local close = CreateFrame("Button", nil, head, "UIPanelCloseButton")
  close:SetPoint("RIGHT", -6, 0)
  close:SetScript("OnClick", function() big:Hide() end)
  T.SkinClose(close)
  -- ? : kurzer Rundgang nur fuer diese Seite
  big.help = T.Button(head, "?", 24, 22)
  big.help:SetPoint("RIGHT", close, "LEFT", -6, 0)
  big.help:SetScript("OnClick", function() if ns.TourPage then ns.TourPage(bigView) end end)
  big.help:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(TR"Diese Seite erklären")
    GameTooltip:AddLine(TR"Erklärt diese Seite Schritt für Schritt. Den ganzen Rundgang gibt es auf der Übersicht.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  big.help:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Balken gibt es im Vollbild nicht mehr (stehen in den Kacheln), bleiben versteckt fuer alte Aufrufe
  big.zbar = MakeBar(big); big.zbar:Hide()
  big.xbar = MakeBar(big); big.xbar:Hide()

  -- Navigation links als Seitenleiste: Einsteiger kurz, Experte in Gruppen
  local nav = T.SideStrip(big, 196)
  nav:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
  nav:SetPoint("BOTTOMLEFT", big, "BOTTOMLEFT", IN, IN)
  big.nav = {}
  big.navHeads = {}
  -- Seitenleiste mit 12 Seiten (gleich in beiden Modi, Geführt zeigt nur, was schon frei ist):
  -- Start, Route, Ziele, Sonstiges, dann unter einer Trennlinie Farmen (nur mit Farmberufe Routen auf Ja)
  local NAV = {
    { "#", TR"Start" }, { "overview", TR"Übersicht" }, { "weg", TR"Mein Weg" }, { "perf", TR"Statistik", "perf" },
    { "#", TR"Route" }, { "opt", TR"Meine Route" },
    { "#", TR"Ziele" }, { "dungeons", TR"Dungeons", "dungeons" }, { "gear", TR"Ausrüstung", "gear" }, { "rep", TR"Ruf", "rep" }, { "books", TR"Bücher", "books" },
    { "#", TR"Sonstiges" }, { "set", TR"Einstellungen" }, { "help", TR"Hilfe" },
    { "-" },
    { "#", TR"Farmen" }, { "berufe", TR"Berufe", "berufe" }, { "gold", TR"Gold", "farm" },
  }
  ns.BIG_NAV = NAV
  local function NavButton(key, text)
    local b = big.nav[key]
    if not b then
      b = RowButton(nav, text, 180, 28)
      b:SetScript("OnClick", function()
        -- nochmal auf Dungeons, Raids oder Schlachtfelder: zurück zur Übersicht
        local p = big.pages[key]
        if bigView == key and p and p.mode == "detail" and p.Back then p.Back() end
        -- Gold: zuerst der Reiter Mobs
        bigView = (key == "gold") and "farm" or key; ns.RefreshBig()
      end)
      big.nav[key] = b
    end
    b:SetText(text)
    return b
  end
  big.navLine = nav:CreateTexture(nil, "ARTWORK")
  big.navLine:SetHeight(1)
  big.navLine:SetColorTexture(1, 0.82, 0, 0.45)
  local function LayNav()
    for _, b in pairs(big.nav) do b:Hide() end
    for _, h in ipairs(big.navHeads) do h:Hide() end
    big.navLine:Hide()
    local farmOn = ns.FarmOn and ns.FarmOn() -- 20.4b: braucht das Farming Zusatz Addon
    local list = {}
    for _, it in ipairs(NAV) do
      local k = it[1]
      if k == "#" or k == "-" then table.insert(list, it)
      elseif (k ~= "berufe" and k ~= "gold") or farmOn then
        -- Geführt: nur Seiten, die schon frei sind (das Fenster waechst mit dem Level)
        if not it[3] or ns.Unlocked(it[3]) then table.insert(list, it) end
      end
    end
    -- leere Gruppen weglassen (Titel ohne Eintrag darunter), Trennlinie nur mit Farmen darunter
    local out = {}
    for i, it in ipairs(list) do
      local nx = list[i + 1]
      if it[1] == "#" then
        if nx and nx[1] ~= "#" and nx[1] ~= "-" then table.insert(out, it) end
      elseif it[1] == "-" then
        if nx and nx[1] == "#" and list[i + 2] and list[i + 2][1] ~= "#" and list[i + 2][1] ~= "-" then table.insert(out, it) end
      else table.insert(out, it) end
    end
    list = out
    local ny, hi = 12, 0
    for _, it in ipairs(list) do
      if it[1] == "#" then
        hi = hi + 1
        local h = big.navHeads[hi]
        if not h then h = nav:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")); big.navHeads[hi] = h end
        h:ClearAllPoints()
        h:SetPoint("TOPLEFT", 12, -ny - (ny > 12 and 6 or 0))
        h:SetText(T.IsElv() and it[2]:upper() or it[2])
        h:Show()
        ny = ny + (ny > 12 and 22 or 16)
      elseif it[1] == "-" then
        -- klare Trennlinie vor Farmen
        big.navLine:ClearAllPoints()
        big.navLine:SetPoint("TOPLEFT", nav, "TOPLEFT", 10, -ny - 8)
        big.navLine:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -10, -ny - 8)
        big.navLine:Show()
        ny = ny + 12
      else
        local b = NavButton(it[1], it[2])
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 8, -ny)
        b:SetHeight(26)
        b:Show()
        ny = ny + 29
      end
    end
  end
  big.LayNav = LayNav
  ns.BigRelayNav = function() LayNav(); if big:IsShown() then ns.RefreshBig() end end
  LayNav()

  -- Inhalt
  local body = CreateFrame("Frame", nil, big)
  big.body = body
  body:SetPoint("TOPLEFT", nav, "TOPRIGHT", 18, -16)
  body:SetPoint("BOTTOMRIGHT", big, "BOTTOMRIGHT", -PAD - 4, PAD + 2)
  big.pages = {}
  local function Page(key)
    local pg = CreateFrame("Frame", nil, body)
    pg:SetAllPoints(body)
    pg:Hide()
    big.pages[key] = pg
    return pg
  end

  -- gesperrte Seite: Erklaerung, ab wann sie kommt
  do
    local lk = CreateFrame("Frame", nil, body)
    lk:SetAllPoints(body)
    lk:Hide()
    local card = T.Panel(lk, "lock")
    card:SetSize(460, 200)
    card:SetPoint("CENTER", 0, 40)
    card.t = card:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    card.t:SetPoint("TOP", 0, -28)
    card.b = card:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    card.b:SetPoint("TOP", card.t, "BOTTOM", 0, -14)
    card.b:SetWidth(400); card.b:SetSpacing(3)
    card.n = card:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    card.n:SetPoint("BOTTOM", 0, 18)
    function lk.Set(key)
      local u = ns.UNLOCKS[key] or {}
      card.t:SetText((TR"%s kommt ab Level %d"):format(u.name or TR"Das", ns.UnlockLevel(key)))
      card.b:SetText(u.text or "")
      local L = UnitLevel("player") or 1
      card.n:SetText((TR"Noch %d Level. Im Modus Alles frei ist alles sofort da."):format(math.max(0, ns.UnlockLevel(key) - L)))
    end
    big.lockPage = lk
  end


  -- Mein Weg: alle Stufen bis 60
  do
    local pg = Page("weg")
    pg.h = pg:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    pg.h:SetPoint("TOPLEFT", 0, -2)
    pg.h:SetText(TR"Dein Weg bis Level 60")
    if T.IsElv() then pg.h:SetTextColor(1, 1, 1) end
    pg.s = pg:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    pg.s:SetPoint("TOPLEFT", pg.h, "BOTTOMLEFT", 0, -6)
    pg.s:SetText(TR"Mit jedem Abschnitt kommt etwas Neues dazu. Klick auf eine Stufe für die Erklärung.")
    pg.bar = MakeBar(pg)
    pg.bar:SetPoint("TOPLEFT", 0, -62); pg.bar:SetPoint("TOPRIGHT", 0, -62)
    pg.bar:SetStatusBarColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
    pg.cards = {}
    -- Bild pro Stufe: kleines Symbol, das zeigt was kommt (nicht immer die Funktion selbst)
    local WEG_ICON = {
      [1] = "INV_Misc_Map_01", [4] = "INV_Banner_02", [6] = "INV_Misc_Bag_10", [8] = "INV_Misc_Coin_02",
      [10] = "INV_Sword_04", [12] = "INV_Misc_Book_09", [13] = "INV_Scroll_03", [14] = "INV_Misc_Rune_01",
      [15] = "INV_Misc_Key_03", [17] = "INV_Misc_PocketWatch_01", [20] = "INV_BannerPVP_01", [22] = "INV_Misc_Spyglass_03",
      [25] = "Spell_Holy_BorrowedTime", [28] = "INV_Scroll_05", [30] = "INV_Misc_Bone_HumanSkull_01", [34] = "INV_Misc_Note_01",
      [35] = "INV_Misc_Coin_01", [38] = "INV_Misc_Gear_01", [40] = "Ability_Mount_RidingHorse", [60] = "INV_Misc_Head_Dragon_01",
    }
    -- Hintergrund: ein Panorama ueber alle Karten (eigenes Bild, sonst das Banner vom Bergpfad)
    local PANO = "fw_weg_pano"
    pg.WEG_ICON = WEG_ICON
    -- Platz im Symbol Atlas (8 pro Reihe) je Stufe
    pg.WEG_ATLAS = { [1] = 0, [4] = 1, [6] = 2, [8] = 3, [10] = 4, [12] = 5, [13] = 6, [14] = 7, [15] = 8, [17] = 9,
      [20] = 10, [22] = 11, [25] = 12, [28] = 13, [30] = 14, [34] = 15, [35] = 16, [36] = 16, [38] = 17, [40] = 18, [60] = 19 }
    -- Symbol nach der ersten Funktion der Stufe (Einsteiger hat andere Stufen als Lernen)
    pg.KEY_ATLAS = { overviewE = 12, groupsE = 10 }
    for _, st in ipairs(ns.UNLOCK_STEPS) do
      for _, k in ipairs(st.items) do if pg.KEY_ATLAS[k] == nil then pg.KEY_ATLAS[k] = pg.WEG_ATLAS[st.lvl] end end
    end
    -- Weg Linie hinter den Karten (sichtbar in den Luecken) und Pfeile in den Luecken: zeigt die Reihenfolge
    pg.lines, pg.chev = {}, {}
    pg.over = CreateFrame("Frame", nil, pg)
    pg.over:SetAllPoints(pg)
    pg.over:SetFrameLevel(pg:GetFrameLevel() + 20)
    local function Line(k)
      local t = pg.lines[k]
      if not t then t = pg:CreateTexture(nil, "BACKGROUND", nil, 2); t:SetColorTexture(1, 0.82, 0, 0.75); pg.lines[k] = t end
      return t
    end
    local function Chev(k)
      local f = pg.chev[k]
      if not f then f = pg.over:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge")); f:SetTextColor(1, 0.82, 0); pg.chev[k] = f end
      return f
    end
    pg.Line, pg.Chev = Line, Chev
    -- Klick: freie Karte springt zur Funktion (bei mehreren Funktionen kurz wählen), gesperrte zeigt ab wann und was
    local function CardClick(self)
      local st = self.st
      if not st then return end
      -- gesperrt (Geführt): kein Klick und kein Hinweis Fenster, das kommt erst beim Erreichen. Maus drauf zeigt, was kommt
      if not ns.Unlocked(st.items[1]) then return end
      if #st.items == 1 then if ns.JumpTo then ns.JumpTo(st.items[1]) end; return end
      local list = { { head = true, text = (TR"Level %d"):format(st.lvl) } }
      for _, k in ipairs(st.items) do
        table.insert(list, { text = ns.UnlockName(k), tip = ns.UNLOCKS[k] and ns.UNLOCKS[k].text, fn = function() if ns.JumpTo then ns.JumpTo(k) end end })
      end
      T.ShowMenu(self, list)
    end
    for i = 1, #ns.UNLOCK_STEPS do
      local b = T.Card(pg, 200, 84)
      b:SetScript("OnClick", CardClick)
      b:SetScript("OnEnter", function(self)
        local st = self.st
        if not st then return end
        ns.TipOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine((TR"Level %d"):format(st.lvl))
        for _, k in ipairs(st.items) do
          GameTooltip:AddLine(ns.UnlockName(k), 1, 0.82, 0)
          if ns.UNLOCKS[k] and ns.UNLOCKS[k].text then GameTooltip:AddLine(ns.UNLOCKS[k].text, 1, 1, 1, true) end
        end
        GameTooltip:AddLine(ns.Unlocked(st.items[1]) and TR"Klick: zur Funktion" or (TR"Kommt ab Level %d."):format(st.lvl), 0.5, 0.8, 1)
        GameTooltip:Show()
      end)
      b:SetScript("OnLeave", function() GameTooltip:Hide() end)
      b.pano = b:CreateTexture(nil, "ARTWORK", nil, 0)
      b.pano:SetPoint("TOPLEFT", 2, -2); b.pano:SetPoint("BOTTOMRIGHT", -2, 2)
      b.pano:SetTexture(ns.APATH .. "Media\\" .. PANO)
      b.shade = b:CreateTexture(nil, "ARTWORK", nil, 1)
      b.shade:SetAllPoints(b.pano)
      b.shade:SetColorTexture(0, 0, 0, 0.35)
      b.icon = b:CreateTexture(nil, "ARTWORK", nil, 3)
      b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      b.iconBg = b:CreateTexture(nil, "ARTWORK", nil, 2)
      if T.IsElv() then
        -- ElvUI: eckig mit feinem Rand
        b.icon:SetSize(36, 36); b.icon:SetPoint("BOTTOMRIGHT", -8, 8)
        b.iconBg:SetPoint("TOPLEFT", b.icon, -1, 1); b.iconBg:SetPoint("BOTTOMRIGHT", b.icon, 1, -1)
        b.iconBg:SetColorTexture(0, 0, 0, 1)
      else
        -- Classic: rundes Medaillon mit Goldring wie im Dungeon Journal
        local M = ns.APATH .. "Media\\"
        b.icon:SetSize(40, 40); b.icon:SetPoint("BOTTOMRIGHT", -8, 8)
        -- keine Maske: die Medaillons im Atlas sind schon rund (Maske plus SetTexCoord geht nicht zusammen)
        b.iconBg:SetSize(40, 40); b.iconBg:SetPoint("CENTER", b.icon)
        b.iconBg:SetTexture(M .. "fw_ring"); b.iconBg:SetDrawLayer("ARTWORK", 4)
      end
      pg.cards[i] = b
    end
    pg.foot = pg:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisable"))
    pg.foot:SetPoint("BOTTOMLEFT", 0, 0)
    function pg.Layout()
      local w = pg:GetWidth() or 800
      if w < 50 then w = 800 end
      local j = ns.db ~= nil -- es gibt nur noch den Journal Stil
      pg.h:SetShown(not j); pg.s:SetShown(not j)
      local barY = j and -2 or -62
      pg.bar:ClearAllPoints()
      pg.bar:SetPoint("TOPLEFT", 0, barY); pg.bar:SetPoint("TOPRIGHT", 0, barY)
      local top, ch, gap, vgap = barY - 26, j and 100 or 84, 20, 18
      local cw = (w - gap * 4) / 5
      local n = 0
      for _, b in ipairs(pg.cards) do if b:IsShown() then n = n + 1 end end
      local rows = math.max(1, math.ceil(n / 5))
      -- kleines Fenster (grosser UI Scale, kleiner Bildschirm): Karten niedriger, damit alle Reihen ins Fenster passen
      local avail = (pg:GetHeight() or 0) - ((pg.foot and pg.foot:IsShown() and (pg.foot:GetText() or "") ~= "") and 16 or 0)
      if avail > 100 and -top + rows * ch + (rows - 1) * vgap > avail then
        vgap = 10
        ch = math.max(64, math.floor((avail + top - (rows - 1) * vgap) / rows))
      end
      local isz = math.max(24, math.min(40, ch - 44))
      local W, H = w, rows * ch + (rows - 1) * vgap
      -- Das Bild hat 4 Baender, eins pro Reihe. Der Weg schlaengelt sich: Reihe 2 und 4 laufen von rechts nach links.
      local u0, us, v0, vs = 0, 1, 0, math.min(1, rows / 4)
      -- Bild (1024x512) nicht verzerren, wenn die Karten niedriger sind: oben/unten oder seitlich weniger nehmen
      local A, G = 2, W / math.max(1, H)
      if A / vs < G then vs = A / G else us = math.min(1, G * vs / A) end
      -- letzte Reihe nicht voll: ihre Karten werden breiter, damit keine Luecke bleibt
      local lastN = n - (rows - 1) * 5
      for i, b in ipairs(pg.cards) do
        local row = math.floor((i - 1) / 5)
        local per = (row == rows - 1 and lastN > 0) and lastN or 5
        local cwr = (per == 5) and cw or (w - gap * (per - 1)) / per
        local k = (i - 1) % 5
        local col = (row % 2 == 0) and k or (per - 1 - k)
        local x, y = col * (cwr + gap), row * (ch + vgap)
        local cw = cwr
        b:ClearAllPoints(); b:SetSize(cw, ch)
        b:SetPoint("TOPLEFT", pg, "TOPLEFT", x, top - y)
        if b.icon then b.icon:SetSize(T.IsElv() and isz - 4 or isz, T.IsElv() and isz - 4 or isz) end
        if b.iconBg and not T.IsElv() then b.iconBg:SetSize(isz, isz) end
        b.pano:SetTexCoord(u0 + us * (x + 2) / W, u0 + us * (x + cw - 2) / W, v0 + vs * (y + 2) / H, v0 + vs * (y + ch - 2) / H)
        b.cx, b.cy, b.row, b.cwr = x + cw / 2, top - y - ch / 2, row, cw
      end
      -- Weg Linie: von Karte zu Karte in der Reihenfolge (Schlange), Pfeile in den Luecken
      for _, t in ipairs(pg.lines) do t:Hide() end
      for _, c in ipairs(pg.chev) do c:Hide() end
      local li = 0
      local prev
      for _, b in ipairs(pg.cards) do
        if b:IsShown() then
          if prev then
            li = li + 1
            local t = pg.Line(li)
            local c = pg.Chev(li)
            t:ClearAllPoints()
            c:ClearAllPoints()
            if prev.row == b.row then
              -- waagrecht, Pfeil in der Luecke zwischen den Karten
              local x0, x1 = math.min(prev.cx, b.cx), math.max(prev.cx, b.cx)
              t:SetPoint("TOPLEFT", pg, "TOPLEFT", x0, b.cy + 1); t:SetSize(x1 - x0, 3)
              local gx = (prev.cx < b.cx) and (prev.cx + prev.cwr / 2 + gap / 2) or (prev.cx - prev.cwr / 2 - gap / 2)
              c:SetPoint("CENTER", pg, "TOPLEFT", gx, b.cy)
              c:SetText(prev.cx < b.cx and ">" or "<")
            else
              -- senkrecht am Ende der Reihe nach unten
              local x = b.cx
              t:SetPoint("TOPLEFT", pg, "TOPLEFT", x - 1, prev.cy); t:SetSize(3, prev.cy - b.cy)
              c:SetPoint("CENTER", pg, "TOPLEFT", x, (prev.cy + b.cy) / 2)
              c:SetText("v")
            end
            t:Show(); c:Show()
          end
          prev = b
        end
      end
      -- 17.4: kleine Figur vom Charakter laeuft den Weg entlang (WegFigur.lua)
      if ns.WegFigurLayout then
        local okF, eF = pcall(ns.WegFigurLayout, pg)
        if not okF and ns.TestLog then ns.TestLog("FEHLER", "Mein Weg Figur: " .. tostring(eF)) end
      end
    end
    pg:SetScript("OnSizeChanged", function() pg.Layout() end)
    function pg.Fill()
      local L = UnitLevel("player") or 1
      local n, tot = ns.UnlockProgress()
      pg.bar:SetValue(math.min(1, (L - 1) / 59))
      pg.bar.text:SetText((TR"Level %d"):format(L))
      -- 20.4a4 (K 21:00): bei Alles frei zaehlt der Kopf die erreichten Stufen (vorher immer alle frei)
      if ns.Expert() then
        n = 0
        for _, st in ipairs(ns.VisibleSteps()) do if st.lvl <= L then n = n + 1 end end
        pg.bar.right:SetText((TR"%d von %d Stufen erreicht"):format(n, tot))
      else
        pg.bar.right:SetText((TR"%d von %d Stufen frei"):format(n, tot))
      end
      local nextDone = false
      local steps = ns.VisibleSteps()
      for i, b in ipairs(pg.cards) do
        local st = steps[i]
        b.st = st
        b:SetShown(st ~= nil)
        if st then pcall(function()
          local names = {}
          for _, k in ipairs(st.items) do table.insert(names, ns.UnlockName(k)) end
          local free = ns.Unlocked(st.items[1])
          local kind, state = "inset", TR"frei"
          if not free and not nextDone then kind, state, nextDone = "sel", TR"als Nächstes", true
          elseif not free then kind, state = "lock", TR"gesperrt" end
          b.Set((TR"Level %d"):format(st.lvl), table.concat(names, "\n"), state, kind)
          -- eigene Symbole aus Figma (Classic: Medaillon, ElvUI: flache Kachel), sonst WoW Icon
          local ai = pg.KEY_ATLAS[st.items[1]] or pg.WEG_ATLAS[st.lvl]
          if ai then
            b.icon:SetTexture(ns.APATH .. "Media\\" .. (T.IsElv() and "fw_weg_icons_elv" or "fw_weg_icons"))
            local c, r = ai % 8, math.floor(ai / 8)
            b.icon:SetTexCoord(c / 8, (c + 1) / 8, r / 4, (r + 1) / 4)
            b.iconBg:Hide()
          else
            local ic = pg.WEG_ICON[st.lvl]
            b.icon:SetTexture("Interface\\Icons\\" .. (ic or "INV_Misc_QuestionMark"))
            b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            b.iconBg:Show()
          end
          -- 20.4a4 (K 21:00, S 20:58): Karten ueber deinem Level grau, auch bei Alles frei (Klick geht weiter)
          local lock = kind == "lock" or st.lvl > L
          b.pano:SetDesaturated(lock); b.icon:SetDesaturated(lock); b.iconBg:SetDesaturated(lock)
          b.pano:SetVertexColor(lock and 0.45 or 1, lock and 0.45 or 1, lock and 0.45 or 1)
          b.icon:SetVertexColor(lock and 0.5 or 1, lock and 0.5 or 1, lock and 0.5 or 1)
          b.shade:SetColorTexture(0, 0, 0, lock and 0.55 or (kind == "sel" and 0.2 or 0.35))
        end) end
      end
      pg.Layout()
      pg.foot:SetText(ns.Expert() and TR"Alles frei: alle Funktionen sind da. Klick auf eine Karte springt zur Funktion."
        or TR"Geführt: mit jeder Stufe kommt etwas dazu. Klick auf eine freie Karte öffnet die Funktion, Maus auf eine gesperrte zeigt, was kommt.")
    end
  end




  -- Dungeons, Schlachtfelder und Raids wie im Dungeon Journal:
  -- Übersicht mit grossen Bildkarten, Klick öffnet die Seite mit Bild oben, Reitern Quests, Route und Info
  local function DungeonPage(key, title, ListFn)
    local pg = Page(key)
    pg.sort, pg.mode, pg.tab = "level", "gallery", "quests"
    local sel, qsel -- gewaehlter Eintrag und gewaehlte Quest
    local isPvp, isRaid = key == "pvp", key == "raids"
    local SUB = isPvp and TR"Wähle ein Schlachtfeld: Quests, Kampfmeister und Route."
      or (isRaid and TR"Wähle einen Raid: Quests, Vorquests und Eingang.") or TR"Wähle einen Dungeon: Quests, Vorquests und die beste Route dahin."

    ------------------------------------------------ Übersicht
    local gal = CreateFrame("Frame", nil, pg)
    gal:SetAllPoints()
    pg.gal = gal
    local gh = gal:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    gh:SetPoint("TOPLEFT", 0, -2); gh:SetText(title)
    if T.IsElv() then gh:SetTextColor(1, 1, 1) end
    local gs = gal:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    gs:SetPoint("TOPLEFT", gh, "BOTTOMLEFT", 0, -6); gs:SetText(SUB)
    pg.text = { Set = function(lines) gs:SetText(type(lines) == "table" and (lines[1] or "") or (lines or SUB)) end }
    -- Sortieren als Reiter (aktiver hell mit goldener Linie)
    local FILTER = { { "level", TR"Level" }, { "mine", TR"Mein Level" }, { "name", TR"Name" } }
    pg.sortTabs = T.TabBar(gal, 24)
    pg.sortTabs:SetPoint("TOPRIGHT", 0, -2); pg.sortTabs:SetWidth(300)
    pg.sortTabs.onPick = function(k) pg.sort = k; pg.Fill() end
    pg.sortTabs.Set(FILTER, pg.sort or "level")
    pg.fbtn = pg.sortTabs.btns
    local sf = CreateFrame("ScrollFrame", "TaurenRoute" .. key .. "Gallery", gal, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 0, -56); sf:SetPoint("BOTTOMRIGHT", -24, 0)
    SkinScroll(sf)
    local grid = CreateFrame("Frame", nil, sf)
    grid:SetSize(600, 10)
    sf:SetScrollChild(grid)
    pg.cards = {}

    local function Card(i)
      local c = pg.cards[i]
      if c then return c end
      c = CreateFrame("Button", nil, grid, BackdropTemplateMixin and "BackdropTemplate" or nil)
      T.Skin(c, "inset")
      c.art = c:CreateTexture(nil, "ARTWORK", nil, 1)
      c.art:SetPoint("TOPLEFT", 3, -3); c.art:SetPoint("BOTTOMRIGHT", -3, 3)
      c.top = c:CreateTexture(nil, "ARTWORK", nil, 2)
      c.top:SetPoint("TOPLEFT", 3, -3); c.top:SetPoint("TOPRIGHT", -3, -3); c.top:SetHeight(50)
      c.top:SetColorTexture(0, 0, 0, 0.55)
      c.bot = c:CreateTexture(nil, "ARTWORK", nil, 2)
      c.bot:SetPoint("BOTTOMLEFT", 3, 3); c.bot:SetPoint("BOTTOMRIGHT", -3, 3); c.bot:SetHeight(30)
      c.bot:SetColorTexture(0, 0, 0, 0.6)
      c.icon = c:CreateTexture(nil, "ARTWORK", nil, 3)
      c.icon:SetSize(54, 54); c.icon:SetPoint("CENTER", 0, -4); c.icon:SetAlpha(0.8)
      c.line = c:CreateTexture(nil, "ARTWORK", nil, 3)
      c.line:SetPoint("TOPLEFT", 3, -3); c.line:SetPoint("TOPRIGHT", -3, -3); c.line:SetHeight(1)
      c.line:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.6)
      local hl = c:CreateTexture(nil, "HIGHLIGHT")
      hl:SetPoint("TOPLEFT", 3, -3); hl:SetPoint("BOTTOMRIGHT", -3, 3); hl:SetColorTexture(1, 1, 1, 0.08)
      c.name = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
      c.name:SetPoint("TOPLEFT", 12, -9); c.name:SetPoint("RIGHT", -70, 0); c.name:SetJustifyH("LEFT"); c.name:SetWordWrap(false)
      if T.IsElv() then c.name:SetTextColor(1, 1, 1) end
      c.meta = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      c.meta:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
      c.badge = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
      c.badge:SetPoint("TOPRIGHT", -10, -11)
      c.zone = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      c.zone:SetPoint("BOTTOMLEFT", 12, 11)
      c.count = c:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
      c.count:SetPoint("BOTTOMRIGHT", -12, 10)
      c.tick = c:CreateTexture(nil, "OVERLAY")
      c.tick:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
      c.tick:SetSize(18, 18); c.tick:SetPoint("RIGHT", c.count, "LEFT", -4, 0)
      c:SetScript("OnClick", function(self) if self.d then pg.Open(self.d) end end)
      pg.cards[i] = c
      return c
    end

    ------------------------------------------------ Seite eines Eintrags
    local det = CreateFrame("Frame", nil, pg)
    det:SetAllPoints(); det:Hide()
    pg.det = det
    local ban = CreateFrame("Frame", nil, det, BackdropTemplateMixin and "BackdropTemplate" or nil)
    ban:SetPoint("TOPLEFT"); ban:SetPoint("TOPRIGHT"); ban:SetHeight(132)
    T.Skin(ban, "inset")
    pg.banArt = ban:CreateTexture(nil, "ARTWORK", nil, 1)
    pg.banArt:SetPoint("TOPLEFT", 3, -3); pg.banArt:SetPoint("BOTTOMRIGHT", -3, 3)
    local shade = ban:CreateTexture(nil, "ARTWORK", nil, 2)
    shade:SetPoint("TOPLEFT", 3, -3); shade:SetPoint("BOTTOMRIGHT", -3, 3); shade:SetColorTexture(0, 0, 0, 0.45)
    local back = FlatButton(ban, TR"< Zurück", 90, 22)
    back:SetPoint("TOPLEFT", 10, -10)
    back:SetScript("OnClick", function() pg.Back() end)
    pg.banName = ban:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalHuge"))
    pg.banName:SetPoint("BOTTOMLEFT", 14, 36)
    if T.IsElv() then pg.banName:SetTextColor(1, 1, 1) end
    pg.banSub = ban:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    pg.banSub:SetPoint("TOPLEFT", pg.banName, "BOTTOMLEFT", 0, -6)
    local follow = FlatButton(ban, TR"Route folgen", 150, 26, true)
    follow:SetPoint("TOPRIGHT", -10, -10)
    local toEntry = FlatButton(ban, isPvp and TR"Pfeil zum Kampfmeister" or TR"Pfeil zum Eingang", 150, 24)
    toEntry:SetPoint("TOPRIGHT", follow, "BOTTOMRIGHT", 0, -4)
    local split = FlatButton(ban, TR"In Gruppe aufteilen", 150, 24)
    split:SetPoint("TOPRIGHT", toEntry, "BOTTOMRIGHT", 0, -4)
    split:SetShown(not isPvp)
    split:SetScript("OnClick", function() if sel and ns.PartySplit then ns.PartySplit(sel) end end)
    follow:SetScript("OnClick", function()
      local d = sel
      if not d then return end
      local steps, info = ns.DungeonRoute(d)
      if steps then info.dungeonRoute = true; ns.OptLoad(steps, info); ns.db.opt.dungeonRoute = true; ns.db.opt.dungeonName = d.name else ns.Print(TR"Keine Route: " .. tostring(info)) end
    end)
    toEntry:SetScript("OnClick", function()
      local d = sel
      if d and d.entrance then
        -- 20.3j (Na, test_203g Punkt 6): Navi mit Weg (Flug, Schiff), Leveling Route bleibt
        local nm = TR"Eingang " .. d.name
        if ns.ZielNavi then ns.ZielNavi(d.entrance[1], d.entrance[2], d.entrance[3], nm, "dungeon")
        else ns.serviceTarget = { map = d.entrance[1], x = d.entrance[2], y = d.entrance[3], name = nm, kind = "dungeon" }; if ns.Draw then ns.Draw() end end
        ns.Print(TR"Pfeil zeigt zum Eingang: " .. d.name)
      end
    end)
    pg.follow, pg.toEntry = follow, toEntry
    -- Reiter unter dem Bild
    local TABS = { { "quests", TR"Quests" }, { "route", TR"Route" }, { "info", "Info" } }
    pg.tabs = {}
    for i, tb in ipairs(TABS) do
      local b = FlatButton(det, tb[2], 110, 24)
      b:SetPoint("TOPLEFT", ban, "BOTTOMLEFT", (i - 1) * 114, -8)
      b:SetScript("OnClick", function() pg.tab = tb[1]; pg.ShowTab() end)
      b.key = tb[1]
      pg.tabs[i] = b
    end
    pg.sum = det:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    pg.sum:SetPoint("LEFT", pg.tabs[#pg.tabs], "RIGHT", 14, 0)
    pg.sum:SetPoint("RIGHT", det, "RIGHT", -6, 0)
    pg.sum:SetJustifyH("RIGHT")
    -- Quests: links Liste, rechts die gewählte Quest
    local ql = Box(det)
    ql:SetPoint("TOPLEFT", ban, "BOTTOMLEFT", 0, -40); ql:SetPoint("BOTTOMLEFT"); ql:SetWidth(360)
    local qsf = CreateFrame("ScrollFrame", "TaurenRoute" .. key .. "QList", ql, "UIPanelScrollFrameTemplate")
    qsf:SetPoint("TOPLEFT", 4, -4); qsf:SetPoint("BOTTOMRIGHT", -26, 4)
    SkinScroll(qsf)
    local qchild = CreateFrame("Frame", nil, qsf)
    qchild:SetSize(326, 10)
    qsf:SetScrollChild(qchild)
    pg.qrows = {}
    local qheads = {} -- Ueberschriften im Quest Verzeichnis (Zugang, Weitere Quests)
    local qr = Box(det)
    qr:SetPoint("TOPLEFT", ql, "TOPRIGHT", 8, 0); qr:SetPoint("BOTTOMRIGHT")
    pg.qName = qr:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    pg.qName:SetPoint("TOPLEFT", 12, -12); pg.qName:SetPoint("RIGHT", -150, 0); pg.qName:SetJustifyH("LEFT")
    pg.qText = ScrollText(qr, "TaurenRoute" .. key .. "QText", ns.FontName("GameFontHighlight"))
    pg.qText:SetPoint("TOPLEFT", 10, -42); pg.qText:SetPoint("BOTTOMRIGHT", -26, 8)
    local toGiver = FlatButton(qr, TR"Pfeil zum Geber", 130, 22)
    toGiver:SetPoint("TOPRIGHT", -8, -10)
    toGiver:SetScript("OnClick", function()
      local q = qsel
      if q and q.gm then
        if ns.ZielNavi then ns.ZielNavi(q.gm, q.gx, q.gy, q.giver or q.name, "quest")
        else ns.serviceTarget = { map = q.gm, x = q.gx, y = q.gy, name = q.giver or q.name, kind = "quest" }; if ns.Draw then ns.Draw() end end
        ns.Print(TR"Pfeil zeigt zu " .. (q.giver or "?") .. TR" für " .. q.name)
      end
    end)
    pg.toGiver = toGiver
    -- Route und Info: Text über die ganze Breite
    local wide = Box(det)
    wide:SetPoint("TOPLEFT", ban, "BOTTOMLEFT", 0, -40); wide:SetPoint("BOTTOMRIGHT")
    pg.wideText = ScrollText(wide, "TaurenRoute" .. key .. "Wide", ns.FontName("GameFontHighlightSmall"))
    pg.wideText:SetPoint("TOPLEFT", 10, -8); pg.wideText:SetPoint("BOTTOMRIGHT", -26, 8)
    pg.ql, pg.qr, pg.wide = ql, qr, wide

    local ICON = {
      done = "Interface\\RaidFrame\\ReadyCheck-Ready", ready = "Interface\\GossipFrame\\ActiveQuestIcon",
      log = "Interface\\GossipFrame\\IncompleteQuestIcon", open = "Interface\\GossipFrame\\AvailableQuestIcon",
      level = "Interface\\RaidFrame\\ReadyCheck-NotReady", rep = "Interface\\RaidFrame\\ReadyCheck-NotReady", pre = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    }
    local function Mark(b, on)
      if T.IsElv() then
        if b.SetBackdropBorderColor then if on then b:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 1) else b:SetBackdropBorderColor(0, 0, 0, 1) end end
      else
        if on then b:LockHighlight() else b:UnlockHighlight() end
      end
    end

    function pg.ShowQuest(qid)
      local q = ns.DungeonQuestInfo and ns.DungeonQuestInfo(qid) or { name = tostring(qid) }
      qsel = q
      pg.qName:SetText(q.name)
      local L = UnitLevel("player")
      local lines = {}
      table.insert(lines, (TR"Level %d, annehmbar ab %d   %s"):format(q.level or 0, q.req or 0, q.stText or ""))
      -- 17.9: "x and f()" gibt nur den ersten Wert von f zurueck, an war immer nil (Fehler bei Zugangs Quests, Chaos Test)
      local ai, an
      if sel and ns.AttuneIndex then ai, an = ns.AttuneIndex(sel, qid) end
      if ai then
        local a = ns.ATTUNE[sel.key]
        table.insert(lines, (TR"|cffff9a30Zugang %s: Teil %d von %d|r"):format(a.what, ai, an))
        if ai == 1 and a.note then table.insert(lines, "|cff9d9d9d" .. a.note .. "|r") end
      end
      table.insert(lines, "")
      table.insert(lines, Section(TR"Annehmen"))
      table.insert(lines, ("%s%s"):format(q.giver or "?", q.giverZone and ("  |cff9d9d9d" .. q.giverZone .. "|r") or ""))
      table.insert(lines, Section(TR"Abgeben"))
      table.insert(lines, ("%s%s"):format(q.ender or "?", q.enderZone and ("  |cff9d9d9d" .. q.enderZone .. "|r") or ""))
      if q.text then
        table.insert(lines, ""); table.insert(lines, Section(TR"Aufgabe")); table.insert(lines, q.text)
      end
      if q.chain and #q.chain > 1 then
        table.insert(lines, ""); table.insert(lines, Section(TR"Kette"))
        for i, c in ipairs(q.chain) do
          local col = (c.st == "done") and "|cff6d6d6d" or ((c.id == qid) and "|cffffd100" or "|cffffffff")
          table.insert(lines, ("%s%d  %s|r%s"):format(col, i, c.name, c.st == "done" and TR"  |cff6d6d6derledigt|r" or ""))
        end
      end
      pg.qText.Set(lines)
      pg.toGiver:SetShown(q.gm ~= nil and q.st ~= "done")
      for _, r in ipairs(pg.qrows) do if r.SetSelected then r.SetSelected(r.qid == qid) end end
    end

    function pg.ShowTab()
      for _, b in ipairs(pg.tabs) do Mark(b, b.key == pg.tab) end
      local d = sel
      if not d then return end
      local qt = pg.tab == "quests"
      ql:SetShown(qt); qr:SetShown(qt); wide:SetShown(not qt)
      if qt then
        local shown, i, first = {}, 0, nil
        local y, hn = 0, 0
        -- Ueberschrift im Quest Verzeichnis (Zugang oder Weitere Quests)
        local function Head(text, sub, withBtn)
          hn = hn + 1
          local h = qheads[hn]
          if not h then
            h = CreateFrame("Frame", nil, qchild)
            h:SetSize(324, 40)
            h.ic = h:CreateTexture(nil, "ARTWORK")
            h.ic:SetSize(22, 22); h.ic:SetPoint("TOPLEFT", 4, -4)
            h.fs = h:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
            h.fs:SetPoint("TOPLEFT", 32, -4); h.fs:SetPoint("RIGHT", -96, 0); h.fs:SetJustifyH("LEFT"); h.fs:SetWordWrap(false)
            h.sub = h:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
            h.sub:SetPoint("TOPLEFT", h.fs, "BOTTOMLEFT", 0, -3); h.sub:SetPoint("RIGHT", -96, 0); h.sub:SetJustifyH("LEFT"); h.sub:SetWordWrap(false)
            h.line = h:CreateTexture(nil, "ARTWORK")
            h.line:SetPoint("BOTTOMLEFT", 2, 2); h.line:SetPoint("BOTTOMRIGHT", -2, 2); h.line:SetHeight(1)
            h.btn = FlatButton(h, TR"Zugang folgen", 104, 22)
            h.btn:SetPoint("TOPRIGHT", -2, -6)
            h.btn:SetScript("OnClick", function()
              local steps, info, later = ns.AttuneRoute(sel)
              if steps then
                info.dungeonRoute = true; ns.OptLoad(steps, info); ns.db.opt.dungeonRoute = true
                if later then ns.Print((TR"Der Rest der Reihe geht ab Level %d weiter."):format(later)) end
              else ns.Print(TR"Zugang: " .. tostring(info)) end
            end)
            qheads[hn] = h
          end
          h.fs:SetText(text); h.sub:SetText(sub or "")
          h.ic:SetTexture(withBtn and "Interface\\Icons\\INV_Misc_Key_03" or "Interface\\GossipFrame\\AvailableQuestIcon")
          h.line:SetColorTexture(1, 0.6, 0.15, withBtn and 0.7 or 0.25)
          h.btn:SetShown(withBtn and true or false)
          h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, -y); h:Show()
          y = y + 44
          return h
        end
        local function Row(qid, inChain, num)
          i = i + 1
          local r = pg.qrows[i]
          if not r then
            r = RowButton(qchild, "", 324, 30)
            r.ic = r:CreateTexture(nil, "ARTWORK")
            r.ic:SetSize(18, 18); r.ic:SetPoint("LEFT", 6, 0)
            r.fs:ClearAllPoints(); r.fs:SetPoint("LEFT", 30, 0); r.fs:SetPoint("RIGHT", -6, 0)
            -- Zugang: warmer Hintergrund und Balken links, damit die Reihe klar zusammengehoert
            r.tint = r:CreateTexture(nil, "BACKGROUND", nil, 1)
            r.tint:SetPoint("TOPLEFT", 1, -1); r.tint:SetPoint("BOTTOMRIGHT", -1, 1)
            r.tint:SetColorTexture(1, 0.6, 0.15, 0.10)
            r.bar = r:CreateTexture(nil, "ARTWORK")
            r.bar:SetPoint("TOPLEFT", 1, -1); r.bar:SetPoint("BOTTOMLEFT", 1, 1); r.bar:SetWidth(3)
            r.bar:SetColorTexture(1, 0.6, 0.15, 0.9)
            pg.qrows[i] = r
          end
          local st = ns.QuestStatus(qid)
          local okL, lv = pcall(ns.QuestReqLevel or function() end, qid)
          r.qid = qid
          r.ic:SetTexture(ICON[st] or ICON.open)
          r.tint:SetShown(inChain and true or false); r.bar:SetShown(inChain and true or false)
          local nm = (ns.QuestName and ns.QuestName(qid)) or (TR"Quest " .. qid)
          local pre = inChain and ("|cffff9a30%d.|r "):format(num) or ""
          r:SetText(("%s%s[%d]|r %s"):format(pre, st == "done" and "|cff6d6d6d" or "|cffffd100", okL and lv or 0, st == "done" and ("|cff6d6d6d" .. nm .. "|r") or nm))
          r:ClearAllPoints(); r:SetPoint("TOPLEFT", 0, -y)
          r:SetScript("OnClick", function() pg.ShowQuest(qid) end)
          r:Show()
          y = y + 32
          if not first and st ~= "done" then first = qid end
        end
        local chain = ns.AttuneChain and ns.AttuneChain(d)
        if chain then
          local done, total, nextQ, a = ns.AttuneProgress(d)
          local sub
          if done >= total then sub = TR"|cff40ff40Fertig, du hast den Zugang.|r"
          else
            local nm = nextQ and ns.QuestName and ns.QuestName(nextQ)
            sub = (TR"%d von %d erledigt%s"):format(done, total, nm and (TR"   |cff9d9d9dweiter: " .. nm .. "|r") or "")
          end
          Head((TR"Zugang: %s%s"):format(a.what, a.need and "" or TR"  |cff9d9d9d(Abkürzung)|r"), sub, done < total)
          for n, qid in ipairs(chain) do shown[qid] = true; Row(qid, true, n) end
          -- auf der Seite zuerst die naechste Quest der Reihe zeigen
          if nextQ and not (qsel and shown[qsel.id]) then first = nextQ end
          local rest = false
          for _, qid in ipairs(d.quests) do if not shown[qid] then rest = true; break end end
          if rest then y = y + 6; Head(TR"Weitere Quests", nil, false) end
        end
        for _, qid in ipairs(d.quests) do
          if not shown[qid] then
            shown[qid] = true
            Row(qid, false)
          end
        end
        for k = i + 1, #pg.qrows do pg.qrows[k]:Hide() end
        for k = hn + 1, #qheads do qheads[k]:Hide() end
        qchild:SetHeight(y + 8)
        if i == 0 then
          pg.qName:SetText(TR"Keine Quests"); pg.qText.Set({ TR"Für deine Fraktion, Klasse oder dein Volk gibt es hier keine Quests." }); pg.toGiver:Hide()
        else
          pg.ShowQuest(qsel and shown[qsel.id] and qsel.id or first or (chain and chain[1]) or d.quests[1])
        end
      elseif pg.tab == "route" then
        local lines = {}
        -- 17.9: "x and f()" schneidet auf einen Wert ab, ainfo und later waren immer nil
        local asteps, ainfo, later
        if ns.AttuneRoute then asteps, ainfo, later = ns.AttuneRoute(d) end
        if asteps then
          table.insert(lines, Section(TR"Zugang: Reihe in der richtigen Reihenfolge (Knopf Zugang folgen bei den Quests)"))
          for _, l in ipairs(ns.DungeonRouteLines(asteps)) do table.insert(lines, l) end
          if later then table.insert(lines, (TR"|cff9d9d9dDer Rest der Reihe geht ab Level %d weiter.|r"):format(later)) end
          table.insert(lines, "")
        elseif ns.ATTUNE and ns.ATTUNE[d.key] and ainfo and ainfo ~= TR"schon alles erledigt" and ainfo ~= TR"keine Questreihe" then
          table.insert(lines, TR"|cffff9a30Zugang:|r " .. tostring(ainfo)); table.insert(lines, "")
        end
        local steps = ns.DungeonRoute(d)
        if steps then
          table.insert(lines, Section(TR"Beste Route: erst alles holen, dann rein, danach abgeben"))
          for _, l in ipairs(ns.DungeonRouteLines(steps)) do table.insert(lines, l) end
        else
          table.insert(lines, TR"|cff9d9d9dKeine offenen Quests hierfür, also keine Route nötig.|r")
        end
        pg.wideText.Set(lines)
      else
        pg.wideText.Set(ns.DungeonLines(d))
      end
    end

    function pg.Back() pg.mode = "gallery"; sel = nil; qsel = nil; pg.Fill() end
    function pg.Open(d)
      sel, qsel, pg.mode = d, nil, "detail"
      pg.Fill()
      if ns.CoachLater then
        ns.CoachLater("journal_page", function()
          return {
            { target = pg.tabs[1], side = "BOTTOM", title = TR"Reiter", text = TR"Quests: alle Quests mit Kette. Route: der beste Weg, erst alles holen, dann rein. Info: was dir noch fehlt." },
            { target = follow, side = "LEFT", title = TR"Route folgen", text = TR"Der Pfeil führt dich zu allen Questgebern, mit Vorquests, danach zum Eingang." },
            { target = split, side = "LEFT", title = TR"In Gruppe aufteilen", text = TR"Jeder in der Gruppe holt einen Teil der Quests, danach teilt ihr sie. Spart viel Laufen." .. TR" Aufteilen kann nur der Gruppenleiter." },
          }
        end, 0.5)
      end
    end

    function pg.Fill()
      local L = UnitLevel("player")
      gal:SetShown(pg.mode == "gallery"); det:SetShown(pg.mode == "detail")
      if pg.mode == "detail" and sel then
        local d = sel
        ns.SetDungeonArt(pg.banArt, d, 0.62)
        pg.banName:SetText(d.name)
        local zone = d.entrance and ns.ZoneName(d.entrance[1]) or ""
        pg.banSub:SetText((TR"Level %d bis %d%s"):format(d.min, d.max, zone ~= "" and ("   |cff9d9d9d" .. zone .. "|r") or ""))
        local done, total, open, need = ns.DungeonCounts(d)
        if total == 0 then pg.sum:SetText(TR"Keine Quests für dich")
        elseif open == 0 then pg.sum:SetText(TR"|cff40ff40Alle " .. total .. TR" Quests erledigt|r")
        elseif L >= need then pg.sum:SetText((TR"|cff40ff40%d offene Quests, alle annehmbar|r   %d von %d erledigt"):format(open, done, total))
        else pg.sum:SetText((TR"|cffff5050%d offene Quests, alle annehmbar ab Level %d|r   %d von %d erledigt"):format(open, need, done, total)) end
        toEntry:SetEnabled(d.entrance ~= nil)
        pg.ShowTab()
        return
      end
      pg.sortTabs.Set(FILTER, pg.sort or "level")
      pg.sortTabs:SetWidth(math.max(200, pg.sortTabs.width or 300))
      local rows, fin = {}, {}
      for _, d in ipairs(ListFn() or {}) do
        local done, total, open, need = ns.DungeonCounts(d)
        local r = { d = d, done = done, total = total, open = open, need = need, fin = total > 0 and open == 0 }
        local relevant = L >= d.min - 3 and L <= d.max + 2
        -- Dungeons und Raids ohne eine Quest fuer dich (zb andere Fraktion) fallen weg, Schlachtfelder bleiben
        local hide = total == 0 and key ~= "pvp"
        if not hide and (pg.sort ~= "mine" or relevant) then table.insert(r.fin and fin or rows, r) end
      end
      local function By(a, b)
        if pg.sort == "name" then return a.d.name < b.d.name end
        if a.d.min ~= b.d.min then return a.d.min < b.d.min end
        return a.d.name < b.d.name
      end
      table.sort(rows, By); table.sort(fin, By)
      for _, r in ipairs(fin) do table.insert(rows, r) end
      -- Raster: 3 Spalten wenn Platz, sonst 2
      local w = sf:GetWidth() or 0
      if w <= 0 then w = 900 end
      local cols = w > 860 and 3 or 2
      local gap = 12
      local cw = math.floor((w - (cols - 1) * gap) / cols)
      local ch = 126
      grid:SetWidth(w)
      local faction = UnitFactionGroup and UnitFactionGroup("player") or "Horde"
      local ficon = faction == "Alliance" and "Interface\\TargetingFrame\\UI-PVP-Alliance" or "Interface\\TargetingFrame\\UI-PVP-Horde"
      for i, r in ipairs(rows) do
        local c, d = Card(i), r.d
        c.d = d
        c:SetSize(cw, ch)
        c:ClearAllPoints()
        c:SetPoint("TOPLEFT", grid, "TOPLEFT", ((i - 1) % cols) * (cw + gap), -math.floor((i - 1) / cols) * (ch + gap))
        local hasArt = ns.SetDungeonArt(c.art, d)
        c.icon:SetShown(not hasArt)
        if not hasArt then ns.SetDungeonIcon(c.icon, d) end
        c.name:SetText(d.name)
        -- zu langer Name (Forever Dungeons): "(Forever)" kommt dann in die Level Zeile
        local fTag = ""
        if (c.name:GetStringWidth() or 0) > cw - 82 then
          local short = d.name:gsub("%s*%(Forever%)%s*$", "")
          if short ~= d.name then c.name:SetText(short); fTag = "   |cff7fd1b9Forever|r" end
        end
        local lc = (L < d.min - 2) and "|cffff5050" or ((L > d.max) and "|cff9d9d9d" or "|cff40ff40")
        local ztxt = ""
        local zd, zt = nil, nil
        if ns.AttuneProgress then zd, zt = ns.AttuneProgress(d) end
        if zd and zt and zt > 0 then
          ztxt = zd >= zt and TR"   |cff40ff40Zugang ok|r" or (TR"   |cffff9a30Zugang %d/%d|r"):format(zd, zt)
        end
        c.meta:SetText((TR"%sLevel %d bis %d|r%s"):format(lc, d.min, d.max, ztxt) .. fTag)
        c.zone:SetText(d.entrance and ns.ZoneName(d.entrance[1]) or "")
        if r.total == 0 then
          c.count:SetText(TR"|cff9d9d9dkeine Quests|r")
        else
          c.count:SetText((TR"|T%s:18:18:0:0:64:64:0:40:0:40|t %s Quests"):format(ficon,
            r.done > 0 and (r.done .. "/" .. r.total) or tostring(r.total)))
        end
        c.tick:SetShown(r.fin)
        local tooHigh = L < d.min - 2
        c.art:SetDesaturated(r.fin or tooHigh)
        c.art:SetAlpha((r.fin or tooHigh) and 0.55 or 1)
        if r.fin then c.badge:SetText(TR"|cff40ff40erledigt|r")
        elseif L >= d.min - 1 and L <= d.max then c.badge:SetText(T.C(TR"passt zu dir"))
        elseif tooHigh then c.badge:SetText((TR"|cffff5050ab Level %d|r"):format(d.min))
        else c.badge:SetText("") end
        c:Show()
      end
      for i = #rows + 1, #pg.cards do pg.cards[i]:Hide() end
      grid:SetHeight(math.ceil(#rows / cols) * (ch + gap) + 4)
      gs:SetText(#rows == 0 and (pg.sort == "mine" and TR"Für dein Level passt hier gerade nichts. Filter Level zeigt alle." or TR"Nichts gefunden.") or SUB)
    end
    sf:SetScript("OnSizeChanged", function() if pg:IsShown() and pg.mode == "gallery" then pg.Fill() end end)
  end
  DungeonPage("dungeons", TR"Dungeons", function() return ns.dungeons end)
  DungeonPage("pvp", TR"Schlachtfelder", function() return ns.battlegrounds end)
  DungeonPage("raids", TR"Raids", function() return ns.raids end)


  -- Weg zu 60: alle Schritte vom ganzen Plan (klickbar), Zeit pro Level und Zone mit plus/minus Verlauf
  do
    local pg = Page("route")
    local KCOL = { A = { 1, 0.56, 0.19 }, T = { 0.25, 1, 0.56 }, O = { 1, 0.4, 0.8 }, G = { 1, 0.31, 0.31 }, V = { 1, 0.82, 0 },
      R = { 0.4, 0.8, 1 }, H = { 0.69, 0.88, 1 }, B = { 0.69, 0.88, 1 }, F = { 0.4, 1, 0.4 }, K = { 0.75, 0.5, 1 }, E = { 1, 1, 0.4 }, L = { 0.69, 0.88, 1 } }
    local function Plain2(t) return (tostring(t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    local left = Box(pg, TR"Alle Schritte bis Level 60")
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMRIGHT", pg, "BOTTOMRIGHT", -350, 0)
    local function Fill(r, d)
      if d.head then
        r.bg:Show(); r.num:SetText(""); r.dot:Hide()
        r.t:SetFontObject(ns.FontName("GameFontNormal"))
        r.t:SetText(d.text)
        local c = d.dim and 0.6 or 1
        r.t:SetTextColor(1 * c, 0.82 * c, 0)
        r.right:SetText(d.right or "")
        r.sel:Hide(); r.bar:Hide()
        return
      end
      r.bg:Hide(); r.dot:Show()
      r.t:SetFontObject(ns.FontName("GameFontHighlightSmall"))
      r.num:SetText(d.num)
      local a1 = d.st.acts and d.st.acts[1]
      local col = KCOL[a1 and a1.k or ""] or { 0.7, 0.7, 0.7 }
      r.dot:SetVertexColor(col[1], col[2], col[3], d.done and 0.4 or 1)
      if not d.txt then
        local ok, t = pcall(ns.OptStepText, d.st); d.txt = ok and t or "?"
        -- 20.4a5 Verlauf nach Max Level: Datum vor der Quest ("05.11.26 Quest XY gemacht")
        if d.pre then d.txt = d.pre .. "  " .. d.txt end
      end
      if d.done then r.t:SetText(Plain2(d.txt)); r.t:SetTextColor(0.5, 0.5, 0.5)
      else r.t:SetText(d.txt); r.t:SetTextColor(1, 1, 1) end
      r.right:SetText(("%s  L%.1f"):format(d.zone or "", d.st.L or d.st.lvl or 0))
      if not d.zone then d.zone = ns.ZoneName and ns.ZoneName(d.st.map) or ""; r.right:SetText(("%s  L%.1f"):format(d.zone, d.st.L or d.st.lvl or 0)) end
      local sel = pg.sel and pg.sel[1] == d.sec and pg.sel[2] == d.i
      r.sel:SetShown(sel or d.cur); r.bar:SetShown(d.cur)
    end
    pg.sel = false
    -- 20.4a5 Verlauf: Klick auf einen fertigen Level oder Monat klappt auf/zu und zeigt rechts die Zusammenfassung
    pg.vl = VList(left, 20, Fill, function(d)
      if d.head and d.fold then
        if ns.WayToggle then ns.WayToggle(d.fold) end
        pg.headSel = d.fold; pg.sel = false; ns.RefreshBig()
      elseif not d.head then pg.sel = { d.sec, d.i }; pg.headSel = nil; ns.RefreshBig() end
    end)
    pg.vl:SetPoint("TOPLEFT", 6, -22); pg.vl:SetPoint("BOTTOMRIGHT", -6, 6)
    -- rechts: gewaehlter Schritt, Zeit pro Zone
    -- Zeit pro Zone steht jetzt in der Statistik, der Platz gehoert dem gewaehlten Schritt
    local right = Box(pg, TR"Gewählter Schritt")
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0); right:SetPoint("BOTTOMRIGHT")
    pg.dt = right:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    pg.dt:SetPoint("TOPLEFT", 10, -26); pg.dt:SetPoint("RIGHT", right, "RIGHT", -10, 0)
    pg.dt:SetJustifyH("LEFT"); pg.dt:SetJustifyV("TOP"); pg.dt:SetSpacing(3)
    pg.go = FlatButton(right, TR"Pfeil hierhin", 150, 24, true)
    pg.go:SetPoint("BOTTOMLEFT", 10, 10)
    pg.go:SetScript("OnClick", function() if pg.sel and ns.PlanJump then ns.PlanJump(pg.sel[1], pg.sel[2]); ns.RefreshBig() end end)
    pg.back = FlatButton(right, TR"Zum jetzigen Schritt", 160, 24)
    pg.back:SetPoint("LEFT", pg.go, "RIGHT", 8, 0)
    -- alles neu wie bei einem neuen Charakter (Plan, Verlauf, Zeiten)
    pg.reset = FlatButton(right, TR"Plan bis 60 komplett neu", 318, 22)
    pg.reset:SetPoint("BOTTOMLEFT", pg.go, "TOPLEFT", 0, 6)
    pg.reset:SetScript("OnClick", function()
      local function Go() if ns.PlanResetAll then ns.PlanResetAll(); pg.sel = false; pg.scrollCur = true; ns.RefreshBig() end end
      if ns.Confirm then
        ns.Confirm(TR"Den ganzen Weg zu 60 komplett neu berechnen? Verlauf und Zeiten werden gelöscht, wie bei einem neuen Charakter.", TR"Komplett neu", Go, TR"Abbrechen")
      else Go() end
    end)
    pg.reset:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(TR"Plan bis 60 komplett neu")
      GameTooltip:AddLine(TR"Löscht Plan, Verlauf und Zeiten und rechnet alles neu, wie bei einem neuen Charakter. Für normale Änderungen reicht Abschnitt neu rechnen.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    pg.reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pg.back:SetScript("OnClick", function()
      pg.sel = false
      local o = ns.db and ns.db.opt
      if o and (o.pin or o.backSec) and ns.OptUnpin then ns.OptUnpin() end
      pg.scrollCur = true
      ns.RefreshBig()
    end)
    pg.scrollCur = true
  end

  -- Performance: zwei Diagramme, XP pro Stunde je Zone, Text
  do
    local pg = Page("perf")
    -- Kacheln: Tempo dieser Session
    pg.tiles = {}
    for i = 1, 6 do pg.tiles[i] = MakeTile(pg) end
    pg:SetScript("OnSizeChanged", function(self, w)
      local gap = 8
      local tw = (w - gap * 5) / 6
      for i = 1, 6 do
        pg.tiles[i]:ClearAllPoints()
        pg.tiles[i]:SetSize(tw, 54)
        pg.tiles[i]:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (tw + gap), 0)
      end
    end)
    pg.rate = MakeChart(pg, TR"XP pro Stunde, letzte Stunde")
    pg.rate:SetPoint("TOPLEFT", 0, -62); pg.rate:SetPoint("TOPRIGHT", pg, "TOP", -4, -62); pg.rate:SetHeight(160)
    pg.lvl = MakeChart(pg, TR"Zeit pro Level")
    pg.lvl:SetPoint("TOPLEFT", pg, "TOP", 4, -62); pg.lvl:SetPoint("TOPRIGHT", 0, -62); pg.lvl:SetHeight(160)
    local det = FlatButton(pg, TR"Detailliert: Level und Zonen", 200, 20)
    det:SetPoint("TOPRIGHT", 0, -232)
    det:SetFrameLevel(pg:GetFrameLevel() + 10)
    det:SetScript("OnClick", function() bigView = "detail"; ns.RefreshBig() end)
    local sb = Box(pg, TR"Wofür geht die Zeit drauf (diese Session)")
    sb:SetPoint("TOPLEFT", 0, -230); sb:SetPoint("TOPRIGHT", 0, -230); sb:SetHeight(64)
    pg.split = StackBar(sb)
    pg.split:SetPoint("TOPLEFT", 8, -24); pg.split:SetPoint("TOPRIGHT", -8, -24)
    local zb = Box(pg, TR"XP pro Stunde je Zone")
    zb:SetPoint("TOPLEFT", 0, -302); zb:SetPoint("BOTTOMRIGHT", pg, "BOTTOM", -4, 0)
    pg.zones = HBars(zb, 10)
    pg.zones:SetPoint("TOPLEFT", 8, -24); pg.zones:SetPoint("BOTTOMRIGHT", -8, 8)
    local tb = Box(pg, TR"Details")
    tb:SetPoint("TOPLEFT", pg, "TOP", 4, -302); tb:SetPoint("BOTTOMRIGHT")
    pg.text = ScrollText(tb, "TaurenRouteBigPerf", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", 8, -24); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
  end

  -- Statistik, Gold und Ruf (Knopf oben rechts in der Reiter Leiste)
  do
    local pg = Page("statgold")
    local bx = Box(pg, TR"Gold")
    bx:SetAllPoints(pg)
    pg.text = ScrollText(bx, "TaurenRouteBigStatGold", ns.FontName("GameFontHighlight"))
    pg.text:SetPoint("TOPLEFT", 8, -24); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
  end

  -- Statistik
  do
    local pg = Page("stats")
    pg.tiles = {}
    for i = 1, 6 do pg.tiles[i] = MakeTile(pg) end
    pg:SetScript("OnSizeChanged", function(self, w)
      local gap = 8
      local tw = (w - gap * 5) / 6
      for i = 1, 6 do
        pg.tiles[i]:ClearAllPoints()
        pg.tiles[i]:SetSize(tw, 54)
        pg.tiles[i]:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (tw + gap), 0)
      end
    end)
    local sb = Box(pg, TR"Woher kommen deine XP")
    sb:SetPoint("TOPLEFT", 0, -62); sb:SetPoint("TOPRIGHT", 0, -62); sb:SetHeight(72)
    pg.src = StackBar(sb)
    pg.src:SetPoint("TOPLEFT", 8, -24); pg.src:SetPoint("TOPRIGHT", -8, -24)
    pg.curve = MakeChart(pg, TR"Spielzeit bis zu jedem Level (aufsummiert)")
    pg.curve:SetPoint("TOPLEFT", 0, -142); pg.curve:SetPoint("TOPRIGHT", pg, "TOP", -4, -142); pg.curve:SetHeight(190)
    local fb = Box(pg, TR"Prognose")
    fb:SetPoint("TOPLEFT", pg, "TOP", 4, -142); fb:SetPoint("TOPRIGHT", 0, -142); fb:SetHeight(190)
    pg.fc = ScrollText(fb, "TaurenRouteBigForecast")
    pg.fc:SetPoint("TOPLEFT", 8, -24); pg.fc:SetPoint("BOTTOMRIGHT", -26, 8)
    local zb = Box(pg, TR"Zeit je Zone")
    zb:SetPoint("TOPLEFT", 0, -340); zb:SetPoint("BOTTOMRIGHT")
    pg.ztime = HBars(zb, 12)
    pg.ztime:SetPoint("TOPLEFT", 8, -24); pg.ztime:SetPoint("BOTTOMRIGHT", -8, 8)
  end

  -- Berufe und Gold Berufe: Inhalt im Journal Stil (JPage), hier nur der Platz
  Page("berufe")

  -- Gold
  do
    local pg = Page("gold")
    local b = Box(pg, TR"Gold Quests")
    b:SetAllPoints(pg)
    -- Knoepfe: Route rechnen und ein Ziel nach Zeit oder Gold
    local acts = {
      { TR"Route rechnen", function() if not ns.db.goldMode and ns.ToggleGold then ns.ToggleGold() elseif ns.BuildGoldRoute then ns.BuildGoldRoute(true) end end },
      { TR"1 Std", function() ns.SetGoldTarget("time", 3600) end },
      { TR"2 Std", function() ns.SetGoldTarget("time", 7200) end },
      { TR"90 Gold", function() ns.SetGoldTarget("gold", 900000) end },
      { TR"500 Gold", function() ns.SetGoldTarget("gold", 5000000) end },
      { TR"Kein Ziel", function() ns.SetGoldTarget(nil) end },
      { TR"Route aus", function() if ns.db.goldMode and ns.ToggleGold then ns.ToggleGold() end end },
    }
    local prev
    for i, a in ipairs(acts) do
      local btn = FlatButton(b, a[1], i == 1 and 110 or 76, 22, i == 1)
      if prev then btn:SetPoint("LEFT", prev, "RIGHT", 4, 0) else btn:SetPoint("TOPLEFT", 8, -24) end
      btn:SetScript("OnClick", function() a[2](); if ns.RefreshBig then ns.RefreshBig() end end)
      prev = btn
    end
    pg.text = ScrollText(b, "TaurenRouteBigGold")
    pg.text:SetPoint("TOPLEFT", 8, -54); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
  end

  -- Gold Mobs: links Spots, rechts Details und Start
  -- 20.3 (P16 und P2b, Sascha: Gold Reiter wie Berufe): links die Mob Arten (eine Zeile je Haupt Mob, kein Mob doppelt),
  -- rechts die Gebiete mit diesem Mob als Tabelle (Gebiet, Level, Stellen, Anreise, Gold/Std). Ein Gebiet anhaken, darunter
  -- die Details, dann Farmen starten. Ohne Wahl nimmt es das Gebiet mit dem meisten Gold pro Stunde. Allgemein, keine Mob Liste.
  do
    local pg = Page("farm")
    local farmSel, curMob
    local groups = {}
    -- 20.4b2 (K 20:05 c, S 19:56): oben die Top 10 ueber alle Zonen, per Auswahl je Zone die besten 10 bis 20.
    -- Gleiche Gegner Art (gleicher Name, verschiedene NPC Nummern) ist eine Zeile
    local FARM_TOP_N, FARM_ZONE_N = 10, 20
    local zoneFilter = "top"
    local lb = Box(pg, TR"Mobs für dein Level")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(300)
    local zbtn = FlatButton(lb, TR"Top 10, alle Zonen", 266, 22)
    zbtn:SetPoint("TOPLEFT", 6, -24)
    pg.zbtn = zbtn
    local sf = CreateFrame("ScrollFrame", "TaurenRouteFarmList", lb, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -50); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    SkinScroll(sf)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(260, 10)
    sf:SetScrollChild(child)
    pg.btns = {}
    local rb = Box(pg)
    rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT")
    local stop = FlatButton(rb, TR"Stop", 70, 24)
    stop:SetPoint("TOPRIGHT", -8, -8)
    stop:SetScript("OnClick", function() if ns.FarmStop then ns.FarmStop() end; pg.ShowSel() end)
    local go = FlatButton(rb, TR"Farmen starten", 120, 24, true)
    go:SetPoint("RIGHT", stop, "LEFT", -6, 0)
    go:SetScript("OnClick", function() if farmSel and ns.FarmStart then ns.FarmStart(farmSel); pg.ShowSel() end end)
    pg.goBtn = go
    local scan = FlatButton(rb, TR"Neu suchen", 100, 24)
    scan:SetPoint("RIGHT", go, "LEFT", -6, 0)
    scan:SetScript("OnClick", function()
      pg.text.Set({ TR"Suche Spots ..." })
      if ns.FarmSpots then ns.FarmSpots(function() farmSel = nil; curMob = nil; pg.Fill() end) end
    end)
    pg.title = rb:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalLarge"))
    pg.title:SetPoint("TOPLEFT", 10, -12); pg.title:SetPoint("RIGHT", scan, "LEFT", -8, 0)
    pg.title:SetJustifyH("LEFT"); pg.title:SetWordWrap(false)
    pg.sub = rb:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    pg.sub:SetPoint("TOPLEFT", 10, -38); pg.sub:SetPoint("RIGHT", rb, "RIGHT", -10, 0); pg.sub:SetJustifyH("LEFT")
    -- Tabelle der Gebiete
    local HEADS = { TR"Gebiet", TR"Level", TR"Stellen", TR"Anreise", TR"Gold/Std" }
    local COLX = { 30, 0.42, 0.56, 0.68, 0.82 }
    local tbl = CreateFrame("Frame", nil, rb)
    tbl:SetPoint("TOPLEFT", 6, -72); tbl:SetPoint("RIGHT", rb, "RIGHT", -10, 0); tbl:SetHeight(6 * 24)
    local function ColX(i)
      local wd = tbl:GetWidth() or 400
      if wd < 50 then wd = 400 end
      local v = COLX[i]
      return v < 1 and math.floor(wd * v) or v
    end
    pg.cols = {}
    for i = 1, 5 do pg.cols[i] = rb:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall")) end
    pg.rrows = {}
    local function RRow(i)
      local r = pg.rrows[i]
      if r then return r end
      r = CreateFrame("Button", nil, tbl)
      r:SetHeight(22)
      r.cb = T.CheckButton(r); r.cb:SetSize(20, 20); r.cb:SetPoint("LEFT", 2, 0)
      r.c = {}
      for k = 1, 5 do
        r.c[k] = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
        r.c[k]:SetWordWrap(false); r.c[k]:SetJustifyH("LEFT")
      end
      local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
      r.line = r:CreateTexture(nil, "ARTWORK"); r.line:SetPoint("BOTTOMLEFT"); r.line:SetPoint("BOTTOMRIGHT"); r.line:SetHeight(1); r.line:SetColorTexture(1, 1, 1, 0.05)
      pg.rrows[i] = r
      return r
    end
    pg.more = rb:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
    pg.more:SetPoint("TOPLEFT", tbl, "BOTTOMLEFT", 4, -2)
    pg.text = ScrollText(rb, "TaurenRouteFarmText", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", tbl, "BOTTOMLEFT", 2, -18); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    pg.text.Set({ TR"Spots werden gesucht ..." })

    -- Mob Arten aus den Spots: eine Gruppe je Haupt Mob, Gebiete nach Gold pro Stunde
    local function Groups(list)
      local out, by = {}, {}
      for _, s in ipairs(list) do
        local m = s.mobs and s.mobs[1]
        -- 20.4b2: gleiche Art = gleicher Name (zb mehrere Praeriewolf Nummern)
        local key = (m and m.name and ("n:" .. m.name)) or (m and m.id) or ("?" .. tostring(s.map))
        local g = by[key]
        if not g then
          g = { key = key, name = (m and m.name) or TR"Mobs", spots = {}, best = 0, learned = 0 }
          by[key] = g
          table.insert(out, g)
        end
        table.insert(g.spots, s)
        if (s.gph or 0) > g.best then g.best = s.gph or 0 end
        if (s.learned or 0) > g.learned then g.learned = s.learned or 0 end
      end
      for _, g in ipairs(out) do table.sort(g.spots, function(a, b) return (a.gph or 0) > (b.gph or 0) end) end
      table.sort(out, function(a, b) return a.best > b.best end)
      return out
    end
    local function CurGroup()
      for _, g in ipairs(groups) do if g.key == curMob then return g end end
    end

    function pg.FillRight()
      local g = CurGroup()
      for _, r in ipairs(pg.rrows) do r:Hide() end
      for k = 1, 5 do
        local c = pg.cols[k]
        c:ClearAllPoints()
        if g then c:SetPoint("TOPLEFT", tbl, "TOPLEFT", ColX(k), 16); c:SetText(HEADS[k]); c:Show() else c:Hide() end
      end
      if not g then
        pg.title:SetText(""); pg.sub:SetText(""); pg.more:SetText("")
        return
      end
      pg.title:SetText(g.name)
      local others = {}
      local first = g.spots[1]
      for i, m in ipairs(first and first.mobs or {}) do
        if i > 1 and i <= 4 then table.insert(others, m.name) end
      end
      pg.sub:SetText(#others > 0 and (TR"Dazu in der Runde: %s"):format(table.concat(others, ", "))
        or TR"Ein Gebiet anhaken, dann Farmen starten. Ohne Haken nimmt es das mit dem meisten Gold.")
      local xs = { ColX(1), ColX(2), ColX(3), ColX(4), ColX(5) }
      local shown = math.min(#g.spots, 6)
      for i = 1, shown do
        local s = g.spots[i]
        local r = RRow(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", tbl, "TOPLEFT", 0, -(i - 1) * 24); r:SetPoint("RIGHT", tbl, "RIGHT", 0, 0)
        for k = 1, 5 do
          local x, nx = xs[k], xs[k + 1]
          r.c[k]:ClearAllPoints(); r.c[k]:SetPoint("LEFT", r, "LEFT", x, 0)
          if nx then r.c[k]:SetWidth(math.max(20, nx - x - 6)) else r.c[k]:SetPoint("RIGHT", r, "RIGHT", -4, 0) end
        end
        r.cb:SetChecked(farmSel == s)
        local function Pick() farmSel = s; pg.ShowSel(); pg.FillRight() end
        r.cb:SetScript("OnClick", Pick)
        r:SetScript("OnClick", Pick)
        r.c[1]:SetText(ns.ZoneName and ns.ZoneName(s.map) or "?")
        r.c[2]:SetText((TR"%d bis %d"):format(s.lo or 0, s.hi or 0))
        r.c[3]:SetText(tostring(s.pts and #s.pts or 1))
        r.c[4]:SetText(s.travel and (TR"%d Min"):format(math.floor(s.travel / 60 + 0.5)) or TR"|cff9d9d9dweit|r")
        r.c[5]:SetText("|cff40ff40" .. ns.Money(s.gph or 0) .. "|r")
        r:Show()
      end
      pg.more:SetText(#g.spots > shown and (TR"und %d weitere Gebiete mit weniger Gold"):format(#g.spots - shown) or "")
    end

    function pg.ShowSel()
      local lines = {}
      for _, l in ipairs(ns.FarmSessionLines and ns.FarmSessionLines() or {}) do table.insert(lines, l) end
      if farmSel then
        for _, l in ipairs(ns.FarmSpotLines(farmSel)) do table.insert(lines, l) end
      else
        table.insert(lines, TR"Links einen Mob anklicken, rechts ein Gebiet wählen. Oben stehen die mit dem meisten Gold pro Stunde.")
        table.insert(lines, "")
        table.insert(lines, TR"|cff9d9d9dGesucht werden normale Mobs, die du solo schaffst: bis 1 Level über dir und höchstens 8 darunter.|r")
        table.insert(lines, TR"|cff9d9d9dKills pro Stunde kommen aus deiner gemessenen Zeit pro Kill, dem Laufweg zwischen den Mobs und den Respawns.|r")
        table.insert(lines, TR"|cff9d9d9dDer Wert pro Kill wird aus deiner Beute gelernt (Geld und Items), Items mit Auktionator Preisen.|r")
      end
      pg.text.Set(lines)
      if farmSel then pg.goBtn:Enable() else pg.goBtn:Disable() end
    end

    function pg.Fill()
      local all = ns.farmSpots or {}
      -- 20.4b2: Ansicht Top 10 oder eine Zone
      local list = all
      if zoneFilter ~= "top" then
        list = {}
        for _, sp in ipairs(all) do if sp.map == zoneFilter then list[#list + 1] = sp end end
        if #list == 0 then zoneFilter = "top"; list = all end
      end
      groups = Groups(list)
      local cap = (zoneFilter == "top") and FARM_TOP_N or FARM_ZONE_N
      while #groups > cap do table.remove(groups) end
      zbtn:SetText(zoneFilter == "top" and TR"Top 10, alle Zonen" or ((TR"Zone: %s"):format(ns.ZoneName and ns.ZoneName(zoneFilter) or "?")))
      zbtn:SetScript("OnClick", function(self)
        -- Zonen mit Spots, die beste zuerst
        local best, order = {}, {}
        for _, sp in ipairs(all) do
          if not best[sp.map] then order[#order + 1] = sp.map; best[sp.map] = 0 end
          if (sp.gph or 0) > best[sp.map] then best[sp.map] = sp.gph or 0 end
        end
        table.sort(order, function(a, b) return best[a] > best[b] end)
        local menu = { { head = true, text = TR"Ansicht" },
          { text = TR"Top 10, alle Zonen", fn = function() zoneFilter = "top"; curMob = nil; pg.Fill() end } }
        for _, m in ipairs(order) do
          menu[#menu + 1] = { text = (ns.ZoneName and ns.ZoneName(m) or "?") .. "  |cff40ff40" .. ns.Money(best[m]) .. "|r",
            fn = function() zoneFilter = m; curMob = nil; pg.Fill() end }
        end
        if T.ShowMenu then T.ShowMenu(self, menu) end
      end)
      -- Auswahl halten, wenn es den Mob und die Stelle noch gibt, sonst der beste Mob und sein bestes Gebiet
      local g = CurGroup()
      if not g then g = groups[1]; curMob = g and g.key end
      if g then
        local still = false
        for _, s in ipairs(g.spots) do if s == farmSel then still = true end end
        if not still then farmSel = g.spots[1] end
      else
        farmSel = nil
      end
      for i, gr in ipairs(groups) do
        local b = pg.btns[i]
        if not b then
          b = RowButton(child, "", 266, 22)
          b:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
          b.fs:ClearAllPoints(); b.fs:SetPoint("LEFT", 6, 0); b.fs:SetPoint("RIGHT", -4, 0); b.fs:SetJustifyH("LEFT"); b.fs:SetWordWrap(false)
          pg.btns[i] = b
        end
        local mark = gr.learned >= 0.7 and "|cff40ff40" or (gr.learned >= 0.2 and "|cffffd100" or "|cffff9030")
        local nz = #gr.spots
        b:SetText(("%s%s|r  %s%s|r%s"):format(mark, ns.Money(gr.best), curMob == gr.key and "|cffffd100" or "|cffffffff", gr.name,
          nz > 1 and ("  |cff9d9d9d" .. (TR"%d Gebiete"):format(nz) .. "|r") or ("  |cff9d9d9d" .. (ns.ZoneName and ns.ZoneName(gr.spots[1].map) or "?") .. "|r")))
        -- 20.3y (S Test 17:05: Farm 23 Texte abgeschnitten): passend kuerzen (Zone faellt zuerst weg)
        if ns.FitText and b.fs then ns.FitText(b.fs, b.fs:GetText() or "") end
        b:SetScript("OnClick", function() curMob = gr.key; farmSel = gr.spots[1]; pg.Fill() end)
        b:Show()
      end
      for i = #groups + 1, #pg.btns do pg.btns[i]:Hide() end
      child:SetHeight(#groups * 24 + 10)
      pg.FillRight()
      if #list == 0 and not (ns.FarmBusy and ns.FarmBusy()) then
        pg.text.Set({ TR"Keine Spots gefunden. Questie Daten noch nicht fertig? Dann gleich Neu suchen." })
        pg.goBtn:Disable()
      else
        pg.ShowSel()
      end
    end
    tbl:SetScript("OnSizeChanged", function() if pg:IsShown() and pg.FillRight then pg.FillRight() end end)
  end

  -- Bibliotheksbuecher: links Liste mit Haken, rechts Ort und Hinweis
  do
    local pg = Page("books")
    local bookSel
    local lb = Box(pg, TR"Bibliotheksbücher")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(360)
    local sf = CreateFrame("ScrollFrame", "TaurenRouteBookList", lb, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -24); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    SkinScroll(sf)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(320, 10)
    sf:SetScrollChild(child)
    pg.rows = {}
    local rb = Box(pg)
    rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT")
    local tour = FlatButton(rb, TR"Bücher Route", 110, 24, true)
    tour:SetPoint("TOPRIGHT", -8, -8)
    tour:SetScript("OnClick", function() if ns.TourBooks then ns.TourBooks(false) end end)
    pg.tourBtn = tour
    local prio = FlatButton(rb, "", 170, 24)
    prio:SetPoint("TOPRIGHT", tour, "BOTTOMRIGHT", 0, -4)
    local function PrioText() prio:SetText(TR"Umweg: " .. (ns.BookPrio and ns.BookPrio().text or "?")) end
    prio:SetScript("OnClick", function() if ns.BookPrioToggle then ns.BookPrioToggle() end; PrioText(); pg.Fill() end)
    pg.prioBtn = prio
    PrioText()
    local go = FlatButton(rb, TR"Pfeil hin", 90, 24)
    go:SetPoint("RIGHT", tour, "LEFT", -6, 0)
    go:SetScript("OnClick", function()
      if bookSel then
        local nm = TR"Buch: " .. bookSel.name
        if ns.ZielNavi then ns.ZielNavi(bookSel.map, bookSel.x, bookSel.y, nm, "book")
        else ns.serviceTarget = { map = bookSel.map, x = bookSel.x, y = bookSel.y, name = nm, kind = "book" }; if ns.Draw then ns.Draw() end end
      end
    end)
    local turn = FlatButton(rb, TR"Abgeben", 80, 24)
    pg.turnBtn = turn
    turn:SetPoint("RIGHT", go, "LEFT", -6, 0)
    turn:SetScript("OnClick", function()
      local t = ns.BOOK_TURNIN[UnitFactionGroup("player")]
      if t then
        if ns.ZielNavi then ns.ZielNavi(t.map, t.x, t.y, t.name, "book")
        else ns.serviceTarget = { map = t.map, x = t.x, y = t.y, name = t.name, kind = "book" }; if ns.Draw then ns.Draw() end end
      end
    end)
    pg.text = ScrollText(rb, "TaurenRouteBookText", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", 8, -70); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    function pg.Fill()
      local L = UnitLevel("player")
      local side = UnitFactionGroup("player")
      local list = {}
      for _, b in ipairs(ns.BOOKS or {}) do table.insert(list, b) end
      table.sort(list, function(a, b)
        local da, dbb = ns.BookDone(a.id), ns.BookDone(b.id)
        if da ~= dbb then return not da end
        return (a.tier or 1) < (b.tier or 1)
      end)
      for i, b in ipairs(list) do
        local r = pg.rows[i]
        if not r then
          r = {}
          r.b = RowButton(child, "", 318, 22)
          r.b:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
          r.b.fs:ClearAllPoints(); r.b.fs:SetPoint("LEFT", 6, 0); r.b.fs:SetPoint("RIGHT", -4, 0); r.b.fs:SetJustifyH("LEFT")
          pg.rows[i] = r
        end
        local done = ns.BookDone(b.id)
        local col = done and "|cff40ff40" or ((b.side and b.side ~= side) and "|cff7d7d7d" or (b.dungeon and "|cffff5050" or ((b.tier or 1) > L and "|cffff9030" or "|cffffffff")))
        r.b:SetText(("%s%s%s|r  |cff9d9d9d%s|r"):format(bookSel == b and "|cffffd100" or col, done and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12:12|t " or "", b.name, ns.ZoneName and ns.ZoneName(b.map) or "?"))
        -- 20.2 (Log 14:36: Bücher 10 Texte abgeschnitten): lange Buchnamen und Zonen passend kuerzen
        if ns.FitText and r.b.fs then ns.FitText(r.b.fs, r.b.fs:GetText() or "") end
        r.b:SetScript("OnClick", function() bookSel = b; pg.Fill() end)
        r.b:Show()
      end
      child:SetHeight(#list * 24 + 10)
      PrioText()
      pg.text.Set(ns.BookLines(bookSel))
    end
  end

  -- Ausruestung: links Quests mit Haken, rechts Belohnungen mit Tooltip
  do
    local pg = Page("gear")
    local gearSel
    local gearSort, gearSlot = "level", nil
    local lb = Box(pg, TR"Quests mit besserer Ausrüstung")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(330)
    -- Filter: sortieren nach Level oder groesstem Upgrade, und nur ein Platz (Kopf, Beine ...)
    -- Sortieren als Reiter (Level, Upgrade), daneben die Auswahl vom Platz
    local GSORT = { { "level", TR"Level" }, { "pct", TR"Upgrade" } }
    local sortTabs = T.TabBar(lb, 22)
    sortTabs:SetPoint("TOPLEFT", 8, -20); sortTabs:SetWidth(170)
    local sortL = sortTabs
    local slotB = FlatButton(lb, TR"Platz: alle", 130, 20)
    slotB:SetPoint("LEFT", sortTabs, "RIGHT", 6, 0)
    pg.sortBtn, pg.slotBtn = sortTabs, slotB
    local GROUP = { Einhand = TR"Waffen", Zweihand = TR"Waffen", Waffenhand = TR"Waffen", Wurfwaffe = TR"Distanz", Schild = TR"Schildhand" }
    local SLOTS = { TR"Kopf", TR"Hals", TR"Schulter", TR"Rücken", TR"Brust", TR"Handgelenke", TR"Hände", TR"Taille", TR"Beine", TR"Füsse", TR"Finger", TR"Schmuck", TR"Waffen", TR"Schildhand", TR"Distanz" }
    local function SlotOf(it) local n = ns.SlotName(it.loc); return GROUP[n] or n end
    local function MarkSort()
      sortTabs.Set(GSORT, gearSort or "level")
      sortTabs:SetWidth(math.max(120, sortTabs.width or 170))
      slotB:SetText(TR"Platz: " .. (gearSlot or TR"alle"))
    end
    sortTabs.onPick = function(k) gearSort = k; pg.Fill() end
    slotB:SetScript("OnClick", function(self)
      -- nur Plaetze anbieten, fuer die es Quests gibt
      local have = {}
      for _, q in ipairs(ns.gearQuests or {}) do for _, it in ipairs(q.items or {}) do have[SlotOf(it)] = (have[SlotOf(it)] or 0) + 1 end end
      local list = { { text = TR"Alle Plätze", checked = gearSlot == nil, fn = function() gearSlot = nil; pg.Fill() end } }
      for _, n in ipairs(SLOTS) do
        if have[n] then
          table.insert(list, { text = ("%s  (%d)"):format(n, have[n]), checked = gearSlot == n, fn = function() gearSlot = n; pg.Fill() end })
        end
      end
      T.ShowMenu(self, list)
    end)
    local sf = CreateFrame("ScrollFrame", "TaurenRouteGearList", lb, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -48); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    SkinScroll(sf)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(290, 10)
    sf:SetScrollChild(child)
    pg.rows = {}
    local rb = Box(pg)
    rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT")
    local route = FlatButton(rb, TR"Route berechnen", 120, 24, true)
    route:SetPoint("TOPRIGHT", -8, -8)
    pg.routeBtn = route
    route:SetScript("OnClick", function() if ns.GearRoute then ns.GearRoute() end end)
    local scan = FlatButton(rb, TR"Neu suchen", 90, 24)
    scan:SetPoint("RIGHT", route, "LEFT", -6, 0)
    local none = FlatButton(rb, TR"Alle aus", 70, 24)
    none:SetPoint("RIGHT", scan, "LEFT", -6, 0)
    local all = FlatButton(rb, TR"Alle an", 70, 24)
    all:SetPoint("RIGHT", none, "LEFT", -6, 0)
    -- Belohnungen als Zeilen mit Symbol, Maus drueber zeigt den Tooltip mit Vergleich
    pg.items = {}
    for k = 1, 6 do
      local r = CreateFrame("Button", nil, rb)
      r:SetSize(400, 30)
      r:SetPoint("TOPLEFT", rb, "TOPLEFT", 10, -42 - (k - 1) * 34)
      r.icon = r:CreateTexture(nil, "ARTWORK")
      r.icon:SetSize(28, 28); r.icon:SetPoint("LEFT", 0, 0)
      r.text = r:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
      r.text:SetPoint("LEFT", r.icon, "RIGHT", 8, 0); r.text:SetPoint("RIGHT", r, "RIGHT", 0, 0)
      r.text:SetJustifyH("LEFT")
      r:SetScript("OnEnter", function(self)
        if not self.link then return end
        ns.TipOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        if GameTooltip_ShowCompareItem then pcall(GameTooltip_ShowCompareItem, GameTooltip) end
        GameTooltip:Show()
      end)
      r:SetScript("OnLeave", function() GameTooltip:Hide(); if ShoppingTooltip1 then ShoppingTooltip1:Hide() end if ShoppingTooltip2 then ShoppingTooltip2:Hide() end end)
      r:SetScript("OnClick", function(self) if self.link and IsModifiedClick and IsModifiedClick() and HandleModifiedItemClick then HandleModifiedItemClick(self.link) end end)
      r:Hide()
      pg.items[k] = r
    end
    pg.text = ScrollText(rb, "TaurenRouteGearText", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", 8, -42 - 6 * 34 - 6); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    pg.text.Set({ TR"Quests werden gesucht ..." })
    function pg.ShowSel()
      local q = gearSel
      for k, r in ipairs(pg.items) do
        local it = q and q.items[k]
        if it then
          r.link = it.link
          r.icon:SetTexture((ns.Api.GetItemIcon and ns.Api.GetItemIcon(it.id)) or select(10, ns.Api.GetItemInfo(it.id)))
          local cur = it.slot and GetInventoryItemLink and GetInventoryItemLink("player", it.slot)
          local pct = (it.empty and TR"|cff40ff40leerer Platz|r") or (it.pct and (TR"|cff40ff40ca +%d%%|r"):format(math.floor(it.pct + 0.5))) or TR"|cff40ff40neu|r"
          r.text:SetText((TR"%s  %s  |cff9d9d9d%s, statt %s|r"):format(it.link, pct, ns.SlotName(it.loc), cur or TR"nichts"))
          r:Show()
        else
          r.link = nil
          r:Hide()
        end
      end
      if q then
        pg.text.Set(ns.GearLines(q))
      else
        pg.text.Set({ TR"Links eine Quest anklicken, rechts siehst du die Belohnung. Maus drauf zeigt den Vergleich mit deinem Teil.",
          TR"Haken weg nimmt die Quest aus der Route. Route berechnen plant alle Quests mit Haken, mit Vorquests.",
          "", TR"|cff9d9d9dGewertet wird mit den Werten für deine Klasse, Rüstungstyp und Waffen die du tragen kannst.|r",
          TR"|cff9d9d9dDie Prozent sind ungefähr: wie viel besser das Teil nach dieser Wertung ist als dein jetziges. Neu heisst, auf dem Platz hast du noch nichts.|r",
          TR"|cff9d9d9dGrün: jetzt annehmbar. Orange: in ein paar Levels. Rot: Dungeon Quest (Seite Dungeons).|r" })
      end
    end
    function pg.Fill()
      MarkSort()
      local list = {}
      for _, q in ipairs(ns.gearQuests or {}) do
        local ok = not gearSlot
        if gearSlot then for _, it in ipairs(q.items or {}) do if SlotOf(it) == gearSlot then ok = true end end end
        if ok then table.insert(list, q) end
      end
      -- Upgrade: neu (leerer Platz) zuerst, dann die groessten Prozent
      local function Up(q)
        if gearSlot then
          local best
          for _, it in ipairs(q.items or {}) do if SlotOf(it) == gearSlot then local v = it.pct or 1000; if not best or v > best then best = v end end end
          return best or 0
        end
        return q.pct or 1000
      end
      if gearSort == "pct" then
        table.sort(list, function(a, b) local x, y = Up(a), Up(b); if x ~= y then return x > y end; return a.rl < b.rl end)
      else
        table.sort(list, function(a, b) if a.rl ~= b.rl then return a.rl < b.rl end; return Up(a) > Up(b) end)
      end
      local L = UnitLevel("player")
      for i, q in ipairs(list) do
        local r = pg.rows[i]
        if not r then
          r = {}
          r.cb = T.CheckButton(child)
          r.cb:SetSize(22, 22)
          r.cb:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
          r.b = RowButton(child, "", 264, 22)
          r.b:SetPoint("LEFT", r.cb, "RIGHT", 2, 0)
          r.b.fs:ClearAllPoints(); r.b.fs:SetPoint("LEFT", 6, 0); r.b.fs:SetPoint("RIGHT", -4, 0); r.b.fs:SetJustifyH("LEFT")
          -- 19.31 (Saschas Runde: Text abgeschnitten): zu lang, dann ganz im Tooltip
          r.b.fs.fwTip = true
          r.b:HookScript("OnEnter", function(self)
            if not (self.fs.IsTruncated and self.fs:IsTruncated()) then return end
            ns.TipOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.fs:GetText() or "", 1, 1, 1, true)
            GameTooltip:Show()
          end)
          r.b:HookScript("OnLeave", function() GameTooltip:Hide() end)
          pg.rows[i] = r
        end
        local col = q.dungeon and "|cffff5050" or (q.rl > L and "|cffff9030" or "|cff40ff40")
        r.cb:SetChecked(not ns.GearSkipped(q.id))
        r.cb:SetScript("OnClick", function() ns.GearToggle(q.id); pg.Fill() end)
        r.b:SetText(("%s%d|r %s%s|r |cff40ff40%s|r%s"):format(col, q.rl, gearSel == q and "|cffffd100" or "|cffffffff", q.name,
          q.pct and ("+" .. math.floor(q.pct + 0.5) .. "%") or TR"neu",
          #(q.pre or {}) > 0 and (" |cffff9030+" .. #q.pre .. TR" Vorquest|r") or ""))
        r.b:SetScript("OnClick", function() gearSel = q; pg.ShowSel(); pg.Fill() end)
        r.cb:Show(); r.b:Show()
      end
      for i = #list + 1, #pg.rows do pg.rows[i].cb:Hide(); pg.rows[i].b:Hide() end
      child:SetHeight(#list * 24 + 10)
      if #list == 0 and not (ns.GearBusy and ns.GearBusy()) then
        for _, r in ipairs(pg.items) do r:Hide() end
        pg.text.Set({ gearSlot and (TR"Für " .. gearSlot .. TR" gibt es gerade keine Quest mit besserer Belohnung. Platz: alle zeigt wieder alles.")
          or TR"Keine Quests mit besserer Ausrüstung gefunden. Neu suchen, wenn Questie fertig geladen hat." })
      else
        pg.ShowSel()
      end
    end
    scan:SetScript("OnClick", function()
      pg.text.Set({ TR"Suche Quests ..." })
      if ns.GearScan then ns.GearScan(function() gearSel = nil; pg.Fill() end) end
    end)
    all:SetScript("OnClick", function() if ns.GearPickAll then ns.GearPickAll(true) end; pg.Fill() end)
    none:SetScript("OnClick", function() if ns.GearPickAll then ns.GearPickAll(false) end; pg.Fill() end)
  end

  -- Ruf: links Fraktionen, rechts Infos und Route
  do
    local pg = Page("rep")
    local lb = Box(pg, TR"Fraktionen")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(260)
    -- Sortieren: nach Ruf (hoechster Stand oben) oder nach Name
    pg.sort = "rep"
    pg.sortTabs = T.TabBar(lb, 22)
    pg.sortTabs:SetPoint("TOPLEFT", 8, -22); pg.sortTabs:SetPoint("RIGHT", lb, "RIGHT", -8, 0)
    pg.sortTabs.onPick = function(k) pg.sort = k; pg.Fill() end
    local sf = CreateFrame("ScrollFrame", "TaurenRouteRepList", lb, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -48); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    SkinScroll(sf)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(220, 10)
    sf:SetScrollChild(child)
    pg.btns = {}
    local rb = Box(pg)
    rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT")
    local stopM = FlatButton(rb, TR"Stop", 60, 24)
    stopM:SetPoint("TOPRIGHT", -8, -8)
    stopM:SetScript("OnClick", function() if ns.RepMobStop then ns.RepMobStop() end end)
    local mobs = FlatButton(rb, TR"Mobs farmen", 110, 24)
    mobs:SetPoint("RIGHT", stopM, "LEFT", -6, 0)
    mobs:SetScript("OnClick", function() if pg.sel and ns.RepMobFarm then ns.RepMobFarm(pg.sel) end end)
    pg.mobsBtn = mobs
    local farm = FlatButton(rb, TR"Quests farmen", 120, 24, true)
    farm:SetPoint("RIGHT", mobs, "LEFT", -6, 0)
    farm:SetScript("OnClick", function() if pg.sel and ns.RepFarm then ns.RepFarm(pg.sel) end end)
    pg.farmBtn = farm
    -- Ziel fuer die gewaehlte Fraktion (Klick: naechste Stufe)
    local goal = FlatButton(rb, TR"Ziel: Ehrfürchtig", 150, 24)
    goal:SetPoint("TOPLEFT", 8, -8)
    goal:SetScript("OnClick", function()
      if type(pg.sel) ~= "table" then return end
      local g = ns.RepGoal(pg.sel.id) + 1
      if g > 8 then g = 4 end
      ns.SetRepGoal(pg.sel.id, g)
      pg.text.Set(ns.FactionLines(pg.sel)); pg.Fill()
    end)
    pg.goalBtn = goal
    -- alle Fraktionen zeigen (sonst nur die, bei denen es noch was zu holen gibt)
    local allB = FlatButton(lb, TR"Alle zeigen", 80, 20)
    allB:SetPoint("TOPRIGHT", -8, 4)
    allB:SetScript("OnClick", function() pg.all = not pg.all; pg.Fill() end)
    pg.allBtn = allB
    pg.text = ScrollText(rb, "TaurenRouteRepText", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", 8, -40); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    pg.text.Set({ TR"Fraktionen werden geladen ..." })
    function pg.Fill()
      pg.sortTabs.Set({ { "rep", TR"Nach Ruf" }, { "name", TR"Nach Name" } }, pg.sort, true)
      local rows, fin = {}, {}
      for _, f in ipairs(ns.factions or {}) do
        if pg.all or (ns.FactionRelevant and ns.FactionRelevant(f)) then
          table.insert((ns.FactionDone and ns.FactionDone(f)) and fin or rows, f)
        end
      end
      pg.allBtn:SetText(pg.all and TR"Nur offene" or TR"Alle zeigen")
      pg.goalBtn:SetText(type(pg.sel) == "table" and (TR"Ziel: " .. (ns.REPNAME and ns.REPNAME[ns.RepGoal(pg.sel.id)] or "?")) or TR"Ziel: Fraktion wählen")
      -- Stand und Fortschritt fuer die Sortierung
      local function Rank(f)
        local info = ns.FactionInfo and ns.FactionInfo(f.id)
        if not info then return 0 end
        local span = (info.max or 1) - (info.min or 0)
        local frac = span > 0 and ((info.value or 0) - (info.min or 0)) / span or 0
        return (info.standing or 0) + frac
      end
      local function By(a, b)
        if pg.sort == "name" then return (a.name or "") < (b.name or "") end
        local ra, rb2 = Rank(a), Rank(b)
        if ra ~= rb2 then return ra > rb2 end
        return (a.name or "") < (b.name or "")
      end
      table.sort(rows, By); table.sort(fin, By)
      local nOpen = #rows
      for _, f in ipairs(fin) do table.insert(rows, f) end
      for i, f in ipairs(rows) do
        local b = pg.btns[i]
        if not b then
          b = RowButton(child, "", 216, 22)
          b.fs:ClearAllPoints(); b.fs:SetPoint("LEFT", 6, 0)
          pg.btns[i] = b
        end
        b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
        b:Show()
        local info = ns.FactionInfo and ns.FactionInfo(f.id)
        if i > nOpen then
          b:SetText((TR"|cff40ff40%s%s  %s, fertig|r"):format(pg.sel == f and "> " or "", f.name, info and info.standingName or "?"))
        else
          b:SetText(("%s%s|r  |cff9d9d9d%s, %d%s|r"):format(pg.sel == f and "|cffffd100" or "|cffffffff", f.name,
            info and info.standingName or TR"unbekannt", f.now, f.kill and TR", Mobs" or ""))
        end
        b:SetScript("OnClick", function() pg.sel = f; pg.text.Set(ns.FactionLines(f)); pg.Fill() end)
        b:Show()
      end
      for k = #rows + 1, #pg.btns do pg.btns[k]:Hide() end
      child:SetHeight(#rows * 24 + 10)
      if not pg.sel then pg.text.Set({ TR"Links eine Fraktion anklicken. Die Zahl hinten sind die Quests mit Ruf, die du jetzt annehmen kannst." }) end
    end
  end

  -- Details: links Gesamt, Level und Zonen, rechts alles aufgeschluesselt
  do
    local pg = Page("detail")
    local lb = Box(pg, TR"Auswahl")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(230)
    local sf = CreateFrame("ScrollFrame", "TaurenRouteDetailList", lb, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -24); sf:SetPoint("BOTTOMRIGHT", -26, 6)
    SkinScroll(sf)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(190, 10)
    sf:SetScrollChild(child)
    pg.btns = {}
    local rb = Box(pg)
    rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT")
    pg.text = ScrollText(rb, "TaurenRouteDetailText", ns.FontName("GameFontHighlightSmall"))
    pg.text:SetPoint("TOPLEFT", 8, -10); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    pg.sel = { kind = "all" }
    function pg.Entry(sel)
      local p = ns.PerfData and ns.PerfData()
      if not p then return nil, "?" end
      if sel.kind == "all" then return p, TR"Gesamt mit diesem Charakter" end
      if sel.kind == "lvl" then return p.lvl and p.lvl[sel.id], TR"Level " .. sel.id end
      return p.zones and p.zones[sel.id], ns.ZoneName(sel.id)
    end
    function pg.Fill()
      local p = ns.PerfData and ns.PerfData()
      if not p then return end
      local list = { { kind = "all", text = TR"|cffffd100Gesamt|r" }, { head = TR"Level" } }
      local L = UnitLevel("player")
      for lv = L, 1, -1 do
        local e = p.lvl and p.lvl[lv]
        if e and (e.t or 0) > 0 then table.insert(list, { kind = "lvl", id = lv, text = (TR"Level %d  |cff9d9d9d%s|r"):format(lv, ns.Clock(e.t)) }) end
      end
      table.insert(list, { head = TR"Zonen" })
      for _, id in ipairs(p.order or {}) do
        local z = p.zones[id]
        if z and (z.t or 0) > 30 then table.insert(list, { kind = "zone", id = id, text = ("%s  |cff9d9d9d%s|r"):format(ns.ZoneName(id), ns.Clock(z.t)) }) end
      end
      for i, it in ipairs(list) do
        local b = pg.btns[i]
        if not b then
          b = RowButton(child, "", 186, 20)
          b:SetPoint("TOPLEFT", 0, -(i - 1) * 22)
          b.fs:ClearAllPoints(); b.fs:SetPoint("LEFT", 6, 0)
          pg.btns[i] = b
        end
        if it.head then
          b:SetText(TR"|cff" .. ACC_HEX .. it.head .. "|r")
          b:SetScript("OnClick", nil)
        else
          local on = pg.sel.kind == it.kind and pg.sel.id == it.id
          b:SetText((on and "> " or "") .. it.text)
          b:SetScript("OnClick", function() pg.sel = { kind = it.kind, id = it.id }; detailFilledAt = GetTime(); pg.Fill() end)
        end
        b:Show()
      end
      for i = #list + 1, #pg.btns do pg.btns[i]:Hide() end
      child:SetHeight(#list * 22 + 10)
      local e, title = pg.Entry(pg.sel)
      pg.text.Set(ns.DetailLines and ns.DetailLines(e, title) or {})
    end
  end

  -- Hilfe
  do
    local pg = Page("help")
    -- links die Themen, rechts der Text
    local lb = Box(pg, TR"Themen")
    lb:SetPoint("TOPLEFT"); lb:SetPoint("BOTTOMLEFT"); lb:SetWidth(210)
    pg.cat = "start"
    pg.catBtns = {}
    -- 20.4b: Thema Farmen nur mit dem Farming Zusatz Addon
    local cats = {}
    for _, c in ipairs(ns.HELP_CATS or {}) do
      if c.key ~= "farm" or (ns.FarmOn and ns.FarmOn()) then cats[#cats + 1] = c end
    end
    for i, c in ipairs(cats) do
      local r = T.Row(lb, 194, 24)
      r:SetPoint("TOPLEFT", 8, -24 - (i - 1) * 26)
      r:SetText(c.title)
      r:SetScript("OnClick", function() pg.cat = c.key; pg.filled = nil; ns.RefreshBig() end)
      r.key = c.key
      pg.catBtns[i] = r
    end
    local b = Box(pg, TR"Hilfe")
    b:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); b:SetPoint("BOTTOMRIGHT")
    pg.box = b
    pg.text = ScrollText(b, "TaurenRouteBigHelp")
    pg.text:SetPoint("TOPLEFT", 8, -28); pg.text:SetPoint("BOTTOMRIGHT", -26, 8)
    function pg.Pick(key) pg.cat = key or "start"; pg.filled = nil end
    local again = FlatButton(b, TR"Einrichtung nochmal", 190, 22)
    again:SetPoint("TOPRIGHT", -8, -2)
    again:SetScript("OnClick", function() if ns.ShowSetup then ns.ShowSetup() end end)
    -- alle kurzen Erklaerungen (Knoepfe beim ersten Oeffnen) wieder einschalten und gleich hier zeigen
    local coach = FlatButton(b, TR"Erklärungen nochmal zeigen", 210, 22)
    coach:SetPoint("RIGHT", again, "LEFT", -6, 0)
    coach:SetScript("OnClick", function()
      if ns.CoachReset then ns.CoachReset() end
      if ns.BigCoach then ns.BigCoach() end
    end)
    coach:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_BOTTOM")
      GameTooltip:AddLine(TR"Erklärungen nochmal zeigen")
      GameTooltip:AddLine(TR"Schaltet die kurzen Erklärungen wieder ein. Sie kommen beim nächsten Öffnen jedes Fensters.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    coach:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end


  ns.Ticker(1, function() if big:IsShown() then ns.RefreshBig("tick") end end)
end

-- Erklaerung pro Seite, nur wo der Text allein nicht reicht
local PAGE_COACH = {
  weg = function(pg) return {
    { target = pg.cards and pg.cards[1], title = TR"Stufen", text = TR"Jede Karte ist eine Stufe. Gelb ist die nächste. Klick auf eine Karte erklärt, was dort neu kommt." },
  } end,
  books = function(pg) return {
    { target = pg.prioBtn, side = "BOTTOM", title = TR"Umweg", text = TR"Wie weit die normale Route für ein Buch vom Weg abgeht. Klick wechselt die Einstellung." },
    { target = pg.tourBtn, side = "BOTTOM", title = TR"Route Auswahl", text = TR"Eine eigene Runde nur zu den Büchern mit Haken, unabhängig von der Leveling Route." },
    { target = pg.turnBtn, side = "BOTTOM", title = TR"Abgeben", text = TR"Pfeil zur nächsten Stelle, wo du die gesammelten Bücher abgeben kannst." },
  } end,
  rep = function(pg) return {
    { target = pg.mobsBtn, side = "BOTTOM", title = TR"Mobs farmen", text = TR"Pfeil zu Mobs, die Ruf für die gewählte Fraktion geben. Stop beendet es." },
    { target = pg.farmBtn, side = "BOTTOM", title = TR"Quests farmen", text = TR"Route über alle Quests mit Ruf für diese Fraktion, auch in anderen Zonen." },
  } end,
  farm = function(pg) return {
    { target = pg.goBtn, side = "BOTTOM", title = TR"Farmen starten", text = TR"Links einen Mob wählen, rechts ein Gebiet anhaken, dann führt der Pfeil im Kreis über die Mobs. Gold pro Stunde mit Preisen aus dem Auktionshaus." },
  } end,
  detail = function(pg) return {
    { target = pg.btns and pg.btns[1], title = TR"Details", text = TR"Links einen Abschnitt oder eine Zone wählen, rechts siehst du Zeiten, Quests und XP dazu." },
  } end,
}

local JournalShow -- Journal Stil, unten in dieser Datei
-- auto == "tick": der Sekunden Takt (schwere Seiten nur alle paar Sekunden neu), sonst sofort (Klick)
function ns.RefreshBig(auto)
  if not (big and big:IsShown()) then return end
  local s = ns.Stats and ns.Stats() or {}
  big.sub:SetText((TR"%s, %s, Level %d"):format(UnitName("player") or "", s.zone or "?", s.level or 0))
  if s.total and s.total > 0 then
    big.zbar:SetValue(s.done / s.total); big.zbar.text:SetText(TR"Zone"); big.zbar.right:SetText((TR"Punkt %d von %d"):format(s.idx, s.total))
  else
    big.zbar:SetValue(0); big.zbar.text:SetText(TR"Zone"); big.zbar.right:SetText(TR"keine Route")
  end
  if s.xpFrac then
    big.xbar:SetValue(s.xpFrac)
    big.xbar.text:SetText((TR"Level %d  %d%%"):format(s.level, math.floor(s.xpFrac * 100)))
    big.xbar.right:SetText(s.nextLevel and (s.levelAfterTurnIn and (TR"Level %d nach Abgabe"):format(s.level + 1) or (TR"Level %d in %s"):format(s.level + 1, s.nextLevelText or s.fmt(s.nextLevel))) or "")
  end
  -- alte Seiten Namen auf die neue Seitenleiste
  local ALIAS = { start = "overview", actions = "opt", func = "set", settings = "set", goldprof = "berufe" }
  bigView = ALIAS[bigView] or bigView
  local JOK = { overview = true, opt = true, plan = true, set = true, berufe = true }
  if not big.pages[bigView] and not JOK[bigView] then bigView = "overview" end
  -- Farmen aus (Farmberufe Routen auf Nein): Berufe und Gold gibt es nicht
  if not (ns.FarmOn and ns.FarmOn()) and (bigView == "berufe" or bigView == "farm" or bigView == "gold") then bigView = "overview" end
  big.chip.Set()
  local navKey = (bigView == "detail" or bigView == "stats" or bigView == "statgold") and "perf"
    or ((bigView == "raids" or bigView == "pvp") and "dungeons")
    or ((bigView == "route" or bigView == "plan") and "opt")
    or ((bigView == "farm" or bigView == "gold") and "gold") or bigView
  for k, b in pairs(big.nav) do b.SetSelected(k == navKey) end
  -- gesperrte Seiten (Modus Geführt): Erklaerung statt Seite
  local LOCKS = { gear = "gear", books = "books", dungeons = "dungeons", raids = "raids", pvp = "pvp", farm = "farm", gold = "gold", rep = "rep", berufe = "berufe",
    perf = "perf", detail = "stats", stats = "stats" }
  local lockKey = LOCKS[bigView]
  if lockKey and not ns.Unlocked(lockKey) then
    for _, p in pairs(big.pages) do p:Hide() end
    if JournalShow then JournalShow(nil) end
    big.lockPage.Set(lockKey)
    big.lockPage:Show()
    return
  end
  big.lockPage:Hide()
  -- Journal Stil: eigene Seiten fuer Start, Meine Route und Einstellungen
  if JournalShow and JournalShow(bigView, s, auto) then return end
  for k, pg in pairs(big.pages) do pg:SetShown(k == bigView) end
  local pg = big.pages[bigView]
  if PAGE_COACH[bigView] and ns.CoachLater and pg then
    local key = bigView
    ns.CoachLater("page_" .. key, function() return PAGE_COACH[key](pg) end, 0.6)
  end
  local bs = ns.BigStats and ns.BigStats() or {}
  local num, fmt = bs.num or tostring, bs.fmt or tostring

  if bigView == "weg" then
    -- Mein Weg aendert sich nur mit Level oder Modus: im Takt nur alle 5 Sekunden
    if not (auto == "tick" and bigView == "weg" and GetTime() - (pg.lastFill or 0) < 5) then
      pg.lastFill = GetTime()
      pg.Fill(s)
    end
  elseif bigView == "dungeons" or bigView == "pvp" or bigView == "raids" then
    if ns.CoachLater and pg.mode == "gallery" then
      ns.CoachLater("journal", function()
        return {
          { target = pg.fbtn and pg.fbtn[1], side = "BOTTOM", title = TR"Sortieren", text = TR"Level: nach Level. Mein Level: nur was jetzt zu dir passt. Name: alphabetisch." },
          { target = pg.cards and pg.cards[1], title = TR"Karten", text = TR"Jede Karte ist ein Dungeon, Raid oder Schlachtfeld. Unten rechts: wie viele Quests es gibt und wie viele du schon hast. Klick öffnet die Seite mit Quests, Route und Info." },
        }
      end, 0.8)
    end
    if not ns.dungeons and ns.dungWarned then
      -- Questie ohne Dungeon Liste (alt oder kaputt): klar sagen statt ewig "wird geladen"
      pg.text.Set({ TR"Questie hat keine Dungeon Liste. Questie und QuestieDB aktualisieren, dann /reload." })
    elseif not ns.dungeons then
      pg.text.Set({ bigView == "pvp" and TR"Schlachtfelder werden geladen ..." or (bigView == "raids" and TR"Raids werden geladen ..." or TR"Dungeons werden geladen ...") })
      if ns.BuildDungeonIndex then ns.BuildDungeonIndex(function()
        if not pg.Fill then return end
        local ok, err = pcall(pg.Fill)
        if not ok and ns.TestLog then ns.TestLog("FEHLER", "Dungeon Seite: " .. tostring(err)) end
      end) end
    elseif GetTime() - (dungFilled[bigView] or -100) > 5 then
      dungFilled[bigView] = GetTime()
      local ok, err = pcall(pg.Fill)
      if not ok and ns.TestLog then ns.TestLog("FEHLER", "Dungeon Seite: " .. tostring(err)) end
    end
  elseif bigView == "route" then
    local rows = ns.PlanRows and ns.PlanRows() or {}
    if pg.rowsRef ~= rows then
      pg.rowsRef = rows
      pg.vl.Set(rows)
    else
      pg.vl.Render()
    end
    -- beim Oeffnen (und mit "Zum jetzigen Schritt") zum aktuellen Schritt scrollen
    local curRow
    for ri, r in ipairs(rows) do if r.cur then curRow = ri; break end end
    if pg.scrollCur then
      pg.scrollCur = false
      if curRow then pg.vl.ScrollTo(curRow) end
    end
    -- gewaehlter Schritt (sonst der aktuelle)
    local selRow
    for _, r in ipairs(rows) do
      if not r.head and ((pg.sel and r.sec == pg.sel[1] and r.i == pg.sel[2]) or (not pg.sel and r.cur)) then selRow = r; break end
    end
    local lines = {}
    local db = ns.db
    local pl = db.plan60
    if not (pl and pl.secs and #pl.secs > 0) then
      -- 20.3j (S Test 20.3g Punkt 5): auf Level 60 gibt es keinen Plan bis 60, nicht "wird berechnet" zeigen
      local atMax = (UnitLevel("player") or 0) >= ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60)
      lines[1] = atMax and TR"Level 60 erreicht: die Route plant jetzt alle restlichen Quests (wie Tempo Alles). Dazu im Mini Fenster Menü unter Ziel wählen: Ausrüstung, Ruf, Dungeons, Gold."
        or (ns.CalcHold and ns.CalcHold()) and TR"Die Route ist noch nicht berechnet. Unten im Mini Fenster oder unter Meine Route auf Berechnen drücken."
        or TR"Der Plan bis Level 60 wird gerade berechnet ..."
    elseif pg.headSel and not pg.sel then
      -- 20.4a5: Zusammenfassung vom gewaehlten fertigen Level oder Monat
      local hr
      for _, r in ipairs(rows) do if r.head and r.fold == pg.headSel then hr = r; break end end
      if hr then
        lines[#lines + 1] = (hr.text or ""):gsub("^[%+%-] ", "")
        if hr.t0 and date then lines[#lines + 1] = (TR"|cff9d9d9dBegonnen:|r %s"):format(date("%d.%m.%y %H:%M", hr.t0)) end
        if hr.t1 and date then lines[#lines + 1] = (TR"|cff9d9d9dFertig:|r %s"):format(date("%d.%m.%y %H:%M", hr.t1)) end
        if hr.dur and hr.dur > 0 and ns.PlanClock then lines[#lines + 1] = (TR"|cff9d9d9dGespielt:|r %s"):format(ns.PlanClock(hr.dur)) end
        if hr.sum and hr.sum ~= "" then lines[#lines + 1] = hr.sum end
        if hr.right and not hr.t0 then lines[#lines + 1] = hr.right end
        lines[#lines + 1] = hr.open and TR"|cff6d6d6dKlick auf den Kopf klappt wieder zu.|r" or TR"|cff6d6d6dKlick auf den Kopf zeigt die einzelnen Schritte.|r"
      end
    elseif selRow then
      local st = selRow.st
      local ok, txt = pcall(ns.OptStepText, st)
      lines[#lines + 1] = ok and txt or "?"
      if selRow.past then
        lines[#lines + 1] = (TR"|cff9d9d9d%s, erledigt auf Level %.1f|r"):format(ns.ZoneName and ns.ZoneName(st.map) or "?", st.L or st.lvl or 0)
      else
        if type(selRow.sec) == "number" then
          lines[#lines + 1] = (TR"|cff9d9d9d%s, Level ca %.1f, Abschnitt %d von %d, Schritt %d|r"):format(ns.ZoneName and ns.ZoneName(st.map) or "?", st.lvl or 0, selRow.sec, #pl.secs, selRow.i)
        else
          lines[#lines + 1] = (TR"|cff9d9d9d%s, Level ca %.1f, laufende Route, Schritt %d|r"):format(ns.ZoneName and ns.ZoneName(st.map) or "?", st.lvl or 0, selRow.i)
        end
      end
      -- warum steigt man hier auf: XP dieses Schritts (Quest Belohnung, Mobs beim Ziel, Grinden)
      local xq, xk, xg = st.xq or 0, st.xk or 0, st.xg or 0
      if xq + xk + xg > 0 then
        -- kurz und gerundet: "Mob Kills ca 750 XP", bei mehreren Teilen die Summe dazu
        local function R(v) if v < 100 then return math.floor(v / 10 + 0.5) * 10 end return math.floor(v / 50 + 0.5) * 50 end
        local parts = {}
        if xk > 0 then parts[#parts + 1] = (TR"Mob Kills ca %d XP"):format(R(xk)) end
        if xq > 0 then parts[#parts + 1] = (TR"Quests ca %d XP"):format(R(xq)) end
        if xg > 0 then parts[#parts + 1] = (TR"Grinden ca %d XP"):format(R(xg)) end
        local txt = table.concat(parts, ", ")
        if #parts > 1 then txt = txt .. (TR", zusammen ca %d XP"):format(R(xq + xk + xg)) end
        lines[#lines + 1] = "|cffffd100" .. txt .. "|r"
      end
      if selRow.done then lines[#lines + 1] = TR"|cff6d6d6dSchon hinter dir. Pfeil hierhin zeigt nochmal dorthin.|r"
      elseif selRow.cur then lines[#lines + 1] = TR"|cff40ff40Das ist dein jetziger Schritt.|r" end
    end
    pg.dt:SetText(table.concat(lines, "\n"))
    pg.go:SetEnabled(selRow ~= nil and not selRow.cur)
  elseif bigView == "perf" then
    local g = ns.PerfGraph and ns.PerfGraph() or { rates = {}, levels = {} }
    local labels = {}
    for i = 1, #g.rates do
      local ago = (#g.rates - i) * 2
      labels[i] = (ago % 10 == 0) and (ago == 0 and TR"jetzt" or ("-" .. ago)) or nil
    end
    local mx = pg.rate.Set(g.rates, labels, #g.rates, ACCENT, TR"Daten kommen nach 2 Minuten")
    pg.rate.info:SetText(mx and mx > 0 and (TR"max %s XP/Std"):format(num(mx)) or "")
    local vals, lab, hi = {}, {}, nil
    for i, e in ipairs(g.levels) do vals[i] = e.t; lab[i] = tostring(e.lv); if e.cur then hi = i end end
    local mx2 = pg.lvl.Set(vals, lab, hi, { 0.58, 0.35, 0.85 })
    pg.lvl.info:SetText(mx2 and mx2 > 0 and (TR"längstes: %s"):format(fmt(mx2)) or "")
    local list = {}
    for _, z in ipairs(bs.zones or {}) do
      table.insert(list, { name = z.name, v = z.rate, text = num(z.rate) .. TR" XP/Std" })
    end
    table.sort(list, function(a, b) return a.v > b.v end)
    pg.zones.Set(list, ACCENT)
    -- Kacheln und Zeitverteilung
    local pt = ns.PerfTiles and ns.PerfTiles() or {}
    local tl = pg.tiles
    local function T(i, v, l) tl[i].value:SetText(v); tl[i].label:SetText(l) end
    -- noch nichts gemessen: kurzer Satz statt Punkte
    local OPEN = TR"|cff9d9d9dnoch offen|r"
    T(1, pt.xph and num(pt.xph) or OPEN, pt.xph and TR"XP pro Stunde jetzt" or TR"XP pro Stunde, wird gerade gemessen")
    T(2, pt.kph and tostring(math.floor(pt.kph)) or OPEN, pt.kph and TR"Kills pro Stunde" or TR"Kills pro Stunde, noch zu wenig Kills")
    if pt.fight then
      T(3, math.floor(pt.fight + pt.down + 0.5) .. " s", (TR"Pro Kill: %d s Kampf, %d s Pause"):format(math.floor(pt.fight + 0.5), math.floor(pt.down + 0.5)))
    else
      T(3, pt.secPerKill and (math.floor(pt.secPerKill) .. " s") or OPEN, TR"Pro Kill (geschätzt, misst ab 5 Kills)")
    end
    T(4, pt.qph and ("%.1f"):format(pt.qph) or OPEN, pt.qph and TR"Quests pro Stunde" or TR"Quests pro Stunde, noch keine Quest abgegeben")
    T(5, ("%d%%"):format(math.floor(pt.restedPct or 0)), (TR"Ausgeruht, %s XP"):format(num(pt.rested or 0)))
    if pt.optPlan then
      local d = pt.optReal - pt.optPlan
      T(6, (d > 0 and "|cffff5050+" or "|cff40ff40-") .. fmt(math.abs(d)) .. "|r", TR"Route gegen Plan")
    else
      T(6, tostring(pt.deaths or 0), TR"Tode diese Session")
    end
    local sp = pt.split or {}
    pg.split.Set({
      { name = TR"Kampf", v = sp.fight or 0, col = { 0.9, 0.25, 0.25 } },
      { name = TR"Laufen", v = sp.walk or 0, col = { 0.3, 0.75, 1 } },
      { name = TR"Fliegen", v = sp.fly or 0, col = { 0.4, 0.9, 0.5 } },
      { name = TR"Tot", v = sp.dead or 0, col = { 0.55, 0.55, 0.55 } },
      { name = TR"Stillstand", v = sp.idle or 0, col = { 1, 0.8, 0.2 } },
    })
    local lines = ns.PerfLines()
    local tips = ns.StatTips and ns.StatTips() or {}
    local bl = ns.BestLine and ns.BestLine() or ""
    local head = {}
    if bl ~= "" then table.insert(head, bl) end
    for _, t in ipairs(tips) do table.insert(head, TR"|cff7fd1b9Tipp:|r " .. t) end
    if #head > 0 then table.insert(head, ""); for _, l in ipairs(lines) do table.insert(head, l) end; lines = head end
    -- ohne Daten: ein Satz statt leerer Kacheln
    if not pt.xph and not pt.kph then
      for _, t in ipairs(tl) do t.value:SetText(""); t.label:SetText("") end
      tl[1].value:SetText("..."); tl[1].label:SetText(TR"Spiel ein paar Minuten, dann kommen hier die Zahlen")
    end
    -- Tipps aus der Zeitverteilung
    local tot = (sp.fight or 0) + (sp.walk or 0) + (sp.fly or 0) + (sp.dead or 0) + (sp.idle or 0)
    if tot > 600 then
      table.insert(lines, "")
      table.insert(lines, TR"|cffffd100Tipps|r")
      if (sp.idle or 0) / tot > 0.25 then table.insert(lines, TR"   Viel Stillstand: Essen und Trinken beim Laufen planen, Quests vorher lesen.") end
      if (sp.dead or 0) / tot > 0.05 then table.insert(lines, TR"   Viele Tode: Mobs eher 1 bis 2 Level unter dir, Elite Gebiete meiden.") end
      if (sp.walk or 0) / tot > 0.5 then table.insert(lines, TR"   Viel Laufen: mit Grinden an spart die Route weite Wege.") end
      if (sp.fight or 0) / tot > 0.6 then table.insert(lines, TR"   Viel Kampf: Quests mitnehmen lohnt sich, Grinden allein ist langsamer.") end
    end
    -- Zeit pro Zone (frueher im Zonenplan): wie lange du dort warst und wie lange der Plan dort noch rechnet
    local zr = ns.PlanZoneRows and ns.PlanZoneRows() or {}
    if #zr > 0 then
      table.insert(lines, "")
      table.insert(lines, TR"|cffffd100Zeit pro Zone|r  |cff9d9d9dwie lange du dort warst und wie lange der Plan dort noch rechnet|r")
      for _, z in ipairs(zr) do
        table.insert(lines, ("   " .. (z.fin and "|cffb0b0b0%s|r  %s" or "|cffffd100%s|r  %s")):format(z.name, z.text))
      end
    end
    pg.text.Set(lines)
  elseif bigView == "statgold" then
    pg.text.Set(ns.GoldRepLines and ns.GoldRepLines() or {})
  elseif bigView == "stats" then
    local c = bs.cnt or {}
    local t = pg.tiles
    local function T(i, v, l) t[i].value:SetText(v); t[i].label:SetText(l) end
    T(1, tostring(c.kill or 0), "Kills")
    T(2, tostring(c.quest or 0), TR"Quests abgegeben")
    T(3, tostring(c.death or 0), TR"Tode")
    T(4, tostring(c.explore or 0), TR"Gebiete entdeckt")
    T(5, ns.Money and ns.Money(c.gold or 0) or tostring(c.gold or 0), TR"Gold aus Quests")
    T(6, num(bs.totalXP or 0), TR"XP gesamt (erfasst)")
    local src = bs.src or {}
    local other = math.max(0, (bs.totalXP or 0) - (src.quest or 0) - (src.kill or 0) - (src.explore or 0))
    pg.src.Set({
      { name = TR"Quests", v = src.quest or 0, col = { 1, 0.6, 0.1 } },
      { name = "Kills", v = src.kill or 0, col = { 0.9, 0.25, 0.25 } },
      { name = TR"Entdecken", v = src.explore or 0, col = { 1, 0.85, 0.2 } },
      { name = TR"Sonstiges", v = other, col = { 0.5, 0.5, 0.5 } },
    })
    local vals, lab = {}, {}
    for i, e in ipairs(bs.levels or {}) do vals[i] = e.sum / 3600; lab[i] = tostring(e.lv) end
    local mx = pg.curve.Set(vals, lab, #vals, { 0.58, 0.35, 0.85 })
    pg.curve.info:SetText(mx and mx > 0 and (TR"%.1f Std gesamt"):format(mx) or "")
    local fc = {}
    table.insert(fc, (TR"Erfasste Spielzeit: |cffffffff%s|r"):format(fmt(bs.totalTime or 0)))
    table.insert(fc, (TR"Schnitt: |cffffffff%s XP pro Stunde|r"):format(num(bs.rate or 0)))
    table.insert(fc, (TR"Bis Level 60 fehlen: |cffffffff%s XP|r"):format(num(bs.xpTo60 or 0)))
    if bs.eta60 then
      table.insert(fc, (TR"Bei diesem Tempo: |cff40ff40ca %s|r"):format(fmt(bs.eta60)))
      table.insert(fc, (TR"Bei 4 Std pro Tag: |cff40ff40ca %d Tage|r"):format(math.ceil(bs.eta60 / 3600 / 4)))
    else
      table.insert(fc, TR"|cff9d9d9dPrognose kommt nach ein paar Minuten Spielen|r")
    end
    local kills = c.kill or 0
    if kills > 0 then table.insert(fc, (TR"XP pro Kill im Schnitt: |cffffffff%s|r"):format(num((src.kill or 0) / kills))) end
    if (c.quest or 0) > 0 then table.insert(fc, (TR"XP pro Quest im Schnitt: |cffffffff%s|r"):format(num((src.quest or 0) / c.quest))) end
    pg.fc.Set(fc)
    local zl = {}
    for _, z in ipairs(bs.zones or {}) do
      table.insert(zl, { name = z.name, v = z.t, text = fmt(z.t) .. (TR"  Lvl %d-%d"):format(z.from or 0, z.to or 0) })
    end
    pg.ztime.Set(zl, { 0.4, 0.6, 1 })
  elseif bigView == "gold" then
    pg.text.Set(ns.GoldLines())
  elseif bigView == "rep" then
    if not ns.factions then
      if ns.BuildFactionIndex then ns.BuildFactionIndex(function() if pg.Fill then pg.Fill() end end) end
    elseif GetTime() - (repFilled or -100) > 5 then
      repFilled = GetTime()
      pg.Fill()
    end
  elseif bigView == "books" then
    if pg.Fill and not (auto == "tick" and GetTime() - (pg.lastFill or 0) < 3) then pg.lastFill = GetTime(); pg.Fill() end
  elseif bigView == "gear" then
    if ns.CoachLater then
      ns.CoachLater("gear", function()
        return {
          { target = pg.sortBtn, side = "BOTTOM", title = TR"Sortieren", text = TR"Level: nach dem Level, ab dem du die Quest annehmen kannst. Upgrade: das grösste Upgrade zuerst." },
          { target = pg.slotBtn, side = "BOTTOM", title = TR"Platz", text = TR"Nur Quests mit Belohnung für einen Platz zeigen, zum Beispiel Kopf oder Beine." },
          { target = pg.routeBtn, side = "BOTTOM", title = TR"Route berechnen", text = TR"Plant alle Quests mit Haken, Vorquests inklusive. Haken weg nimmt eine Quest raus." },
        }
      end, 0.6)
    end
    -- echtes Level, so wie die Suche selbst rechnet (sonst sucht es mit Test Level jede Sekunde neu)
    local L = _G.UnitLevel("player")
    local fresh = ns.gearScanAt and GetTime() - ns.gearScanAt < 20
    if (not ns.gearQuests or ns.gearLvl ~= L) and not fresh and not (ns.GearBusy and ns.GearBusy()) then
      ns.gearScanAt = GetTime()
      pg.text.Set({ TR"Suche Quests mit besserer Ausrüstung ..." })
      if ns.GearScan then ns.GearScan(function() if pg.Fill then pg.Fill() end end) end
    elseif ns.gearQuests and GetTime() - (gearFilled or -100) > 5 then
      gearFilled = GetTime()
      pg.Fill()
    end
  elseif bigView == "farm" then
    local L = _G.UnitLevel("player")
    local fresh = ns.farmScanAt and GetTime() - ns.farmScanAt < 20
    if (not ns.farmSpots or ns.farmSpotsLvl ~= L) and not fresh and not (ns.FarmBusy and ns.FarmBusy()) then
      ns.farmScanAt = GetTime()
      pg.text.Set({ TR"Suche Spots für dein Level ..." })
      if ns.FarmSpots then ns.FarmSpots(function() if pg.Fill then pg.Fill() end end) end
    elseif ns.farmSpots and GetTime() - (farmFilled or -100) > 3 then
      farmFilled = GetTime()
      pg.Fill()
    end
  elseif bigView == "detail" then
    if not detailFilledAt or GetTime() - detailFilledAt > 5 then detailFilledAt = GetTime(); pg.Fill() end
  elseif bigView == "help" then
    if not pg.filled and ns.HelpLines then
      pg.text.Set(ns.HelpLines(pg.cat)); pg.filled = true
      for _, r in ipairs(pg.catBtns or {}) do if r.SetSelected then r.SetSelected(r.key == pg.cat) end end
      for _, c in ipairs(ns.HELP_CATS or {}) do
        if c.key == pg.cat and pg.box and pg.box.title then pg.box.title:SetText(Section(c.title)) end
      end
      if pg.text.SetVerticalScroll then pg.text:SetVerticalScroll(0) end
    end

  end
end

function ns.SetBigView(v) bigView = v; ns.RefreshBig() end
function ns.BigView() return bigView end
local function BigCoach()
  if not ns.CoachLater or not big then return end
  ns.CoachLater("big", function()
    local nav = big.nav or {}
    return {
      { target = big.chip, side = "BOTTOM", title = TR"Tempo und Modus", text = TR"Klick: Tempo und Modus wählen. Maus auf einen Eintrag erklärt ihn." },
      { target = nav.start or nav.overview, title = TR"Seiten", text = TR"Links alle Seiten. Im Modus Geführt kommen mit dem Level neue dazu, jede mit kurzer Erklärung." },
      { target = nav.opt, title = TR"Meine Route", text = TR"Alle Schritte der Route und darüber alles zum Planen: neu rechnen, Touren, Stunden Budget, Feierabend." },
      { target = nav.weg, title = TR"Mein Weg", text = TR"Welche Funktion ab welchem Level kommt. Klick auf eine Stufe erklärt sie." },
      { target = nav.settings or nav.func, title = TR"Einstellungen", text = TR"Alles als Fragen mit Ja und Nein. Maus auf die Frage erklärt, was passiert." },
      { target = nav.help, title = TR"Hilfe", text = TR"Alles nachlesen. Dort kannst du auch alle Erklärungen wie diese hier wieder einschalten." },
    }
  end)
end
ns.BigCoach = BigCoach

-- Startseite des grossen Fensters: Übersicht, solange sie noch nicht frei ist Start
local function HomeView() return "overview" end
function ns.ShowBig(v)
  BuildBig()
  bigView = v or HomeView()
  if big.LayNav then big.LayNav() end
  big:Show()
  ns.RefreshBig()
  BigCoach()
end

function ns.ToggleBig()
  BuildBig()
  if big:IsShown() then big:Hide() else bigView = HomeView(); if big.LayNav then big.LayNav() end; big:Show(); ns.RefreshBig(); BigCoach() end
end

-- Modus gewechselt: Menue und Reiter neu ordnen
function ns.OnModeChanged()
  if ns.UpgradeStripRefresh then ns.UpgradeStripRefresh() end
  if big and big.LayNav then
    big.LayNav()

    ns.RefreshBig()
  end
  if page and page.LayTabs then page.LayTabs(); Refresh() end
  if ns.RefreshHud then ns.RefreshHud() end
  if ns.MapButtonText then ns.MapButtonText() end
end

-- Look wechseln: Automatisch, Classic UI, ElvUI (gilt nach /reload)
function ns.CycleLook()
  local db = ns.db
  if not db then return end
  -- zwischen den beiden Looks wechseln, ausgehend von dem, was gerade zu sehen ist
  local nextLook = T.IsElv() and "classic" or "elvui"
  if nextLook == "elvui" and not T.ElvLoaded() then
    ns.Print(TR"ElvUI ist nicht installiert oder nicht an, darum gibt es nur den Classic Look.")
    return
  end
  local name = nextLook == "elvui" and "ElvUI" or "Classic"
  -- erst nach Ja umstellen: Abbrechen laesst alles, wie es ist
  ns.Confirm((TR"Look auf %s wechseln?\n\nAlle Fenster von Keine Zeit Leveling Guide bekommen andere Farben, Rahmen und Knöpfe. Dafür lädt die Oberfläche neu, das dauert ein paar Sekunden.\n\nAbbrechen: es bleibt wie es ist."):format(name),
    TR"UI neu laden", function()
      db.look = nextLook
      ReloadUI()
    end, TR"Abbrechen")
end

function ns.OpenCharPage()
  if not page then return false end
  if CharacterFrame:IsShown() then
    if ns.ToggleUpgradeStrip then ns.ToggleUpgradeStrip() end
  else
    -- Forever: ein Addon darf das Charakterfenster nicht selbst oeffnen
    ns.openPageOnShow = true
    ns.Print(TR"Drücke C, dann gehen die Upgrades aus Quests direkt auf")
  end
  return true
end

function ns.InitCharTab()
  if CharacterFrame then
    Build()
  else
    -- Charakterfenster wird spaeter geladen
    local f = CreateFrame("Frame")
    f:RegisterEvent("ADDON_LOADED")
    f:SetScript("OnEvent", function(self)
      if CharacterFrame then Build(); self:UnregisterAllEvents() end
    end)
  end
end

-- fuer Tests und andere Teile: Seite im grossen Fenster holen
function ns.BigPage(k) return big and big.pages and big.pages[k] end
function ns.BigChip() return big and big.chip end
-- Erklaerungen einer Seite (fuer den Rundgang)
function ns.PageCoachSteps(key)
  local f = PAGE_COACH[key]
  local pg = big and big.pages and big.pages[key]
  if not (f and pg) then return nil end
  local ok, list = pcall(f, pg)
  return ok and list or nil
end
function ns.BigNavButton(k) return big and big.nav and big.nav[k] end

------------------------------------------------------------
-- Journal Stil (Einstellung "Neuer Fenster Stil"): Start, Meine Route und Einstellungen
-- mit grossen Bildern wie im Dungeon Journal. Der alte Stil bleibt unveraendert daneben.
------------------------------------------------------------
local jpages = {}
-- die gerade sichtbare Seite (Journal Seite oder alte Seite), sonst der Inhalt vom Fenster
function ns.BigBody()
  if not big then return nil end
  for _, p in pairs(jpages) do if p:IsShown() then return p end end
  local p = big.pages and bigView and big.pages[bigView]
  if p and p:IsShown() then return p end
  return big.body
end
function ns.BigJPage(k) return jpages[k] end
local JMAP = { start = "start", overview = "start", opt = "opt", plan = "opt", settings = "set", func = "set", set = "set", berufe = "berufe" }

local function JText(parent, font, r, g, b)
  local t = parent:CreateFontString(nil, "OVERLAY", font or ns.FontName("GameFontHighlight"))
  t:SetJustifyH("LEFT")
  if r then t:SetTextColor(r, g, b) end
  return t
end
local function JHead(parent, text)
  local t = JText(parent, ns.FontName("GameFontNormal"))
  t:SetText(T.IsElv() and text:upper() or text)
  if T.IsElv() then t:SetTextColor(0.66, 0.66, 0.66) end
  return t
end
local function Plain(x) return (tostring(x or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("\n.*", "")) end
local function PlayerMapPos()
  local m = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local pos = m and C_Map.GetPlayerMapPosition(m, "player")
  local x, y
  if pos then x, y = pos:GetXY() end
  return m, x, y
end
-- Bild aus dem Spiel (Ladebildschirm) auf eine Bildkarte, sonst das Symbol
local function JArt(card, key, icon)
  card.art.Clear()
  local ok, has = pcall(ns.SetDungeonArt or function() return false end, card.art.single, { key = key })
  if ok and has then card.art.single:Show(); return true end
  if icon then card.art.SetIcon(icon) end
  return false
end
-- eigene Bilder (Media\fw_*.tga): Karten 256x512, Banner 1024x256
local MEDIA = ns.APATH .. "Media\\"
local IMG_ASPECT = { fw_beruf_kraeuter = 4, fw_beruf_bergbau = 4, fw_beruf_kuerschner = 4, fw_beruf_stoff = 4, fw_beruf_kochen = 4, fw_beruf_angeln = 4, fw_leveln = 0.5, fw_ausruestung = 0.5, fw_buecher = 0.5, fw_dungeons = 0.5, fw_banner_zone = 4, fw_banner_route = 4, fw_banner_ruf = 4, fw_banner_weg = 4, fw_banner_gold = 4, fw_banner_stats = 4 }
local function JImg(target, name)
  local art = target.art or target
  local ok = art.SetFile(MEDIA .. name, IMG_ASPECT[name] or 1)
  -- eigene Bilder sind schon dunkel gemalt: weniger abdunkeln als die helle Pergamentkarte
  if ok and target.tint then target.tint:SetColorTexture(0, 0, 0, T.IsElv() and 0.22 or 0.08) end
  return ok
end
local function ContKey()
  local m = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  local info = m and C_Map.GetMapInfo(m)
  local guard = 0
  while info and info.mapType and info.mapType > 2 and info.parentMapID and guard < 8 do
    info = C_Map.GetMapInfo(info.parentMapID); guard = guard + 1
  end
  if info and info.mapID == 1414 then return "Kalimdor" end
  return TR"Eastern Kingdoms"
end
local KCOL = { P = { 0.4, 1, 0.6 }, A = { 1, 0.56, 0.19 }, O = { 1, 0.4, 0.8 }, T = { 0.25, 1, 0.56 }, G = { 1, 0.31, 0.31 }, V = { 0.9, 0.76, 0.36 },
  R = { 0.4, 0.8, 1 }, F = { 0.4, 1, 0.4 }, E = { 1, 1, 0.4 }, K = { 0.75, 0.5, 1 }, L = { 0.69, 0.88, 1 }, B = { 0.69, 0.88, 1 }, H = { 0.69, 0.88, 1 } }
local KNAME = { P = TR"Farmen", A = TR"Annehmen", O = TR"Questziel", T = TR"Abgeben", G = TR"Grinden", V = TR"Händler", R = TR"Reise", F = TR"Flugpunkt", E = TR"Entdecken", K = TR"Buch", L = TR"Gasthaus", B = TR"Ruhestein", H = TR"Ruhestein" }

-- Zahlenleiste: 4 Werte nebeneinander, mit feinen Trennlinien
local function JStats(parent, n)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(44)
  f.cells = {}
  for i = 1, n do
    local c = CreateFrame("Frame", nil, f)
    c.v = JText(c, ns.FontName("GameFontHighlightLarge")); c.v:SetPoint("TOPLEFT", 14, -2)
    c.l = JText(c, ns.FontName("GameFontDisableSmall")); c.l:SetPoint("TOPLEFT", c.v, "BOTTOMLEFT", 0, -3)
    if i > 1 then
      c.sep = c:CreateTexture(nil, "ARTWORK"); c.sep:SetColorTexture(1, 1, 1, 0.12)
      c.sep:SetPoint("TOPLEFT", 0, 0); c.sep:SetPoint("BOTTOMLEFT", 0, 2); c.sep:SetWidth(1)
    end
    f.cells[i] = c
  end
  f:SetScript("OnSizeChanged", function(self, w)
    local cw = (w or 600) / n
    for i, c in ipairs(self.cells) do c:ClearAllPoints(); c:SetSize(cw, 44); c:SetPoint("TOPLEFT", (i - 1) * cw, 0) end
  end)
  function f.Set(i, v, l) f.cells[i].v:SetText(v or ""); f.cells[i].l:SetText(l or "") end
  return f
end

-- Level Balken: lila, heller Teil = mit den fertigen Quests
local function JXPBar(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetHeight(8)
  f.bg = f:CreateTexture(nil, "BACKGROUND"); f.bg:SetAllPoints(); f.bg:SetColorTexture(1, 1, 1, 0.08)
  f.pend = f:CreateTexture(nil, "ARTWORK", nil, 1); f.pend:SetPoint("TOPLEFT"); f.pend:SetPoint("BOTTOMLEFT"); f.pend:SetColorTexture(0.85, 0.66, 0.9, 0.45)
  f.fill = f:CreateTexture(nil, "ARTWORK", nil, 2); f.fill:SetPoint("TOPLEFT"); f.fill:SetPoint("BOTTOMLEFT"); f.fill:SetColorTexture(0.54, 0.29, 0.82, 1)
  function f.Set(a, b)
    local w = f:GetWidth() or 0
    f.fill:SetWidth(math.max(1, w * math.min(1, a or 0)))
    f.pend:SetWidth(math.max(1, w * math.min(1, math.max(a or 0, b or 0))))
  end
  return f
end

-- Einfache Liste mit Zeilen zum Anklicken (Punkt in Farbe, Nummer, Text)
-- 17.9: nur die sichtbaren Zeilen werden gebaut und gefuellt (vorher eine Zeile pro Schritt, bei 2500 Schritten
-- ueber 20000 Fenster Teile, die WoW nie mehr frei gibt, und bei jedem Neuzeichnen alle Texte neu).
-- Ein Eintrag hat idx, num, col, dim und text oder st (dann macht textOf den Text erst, wenn die Zeile sichtbar ist).
local function JList(parent, rowH, onClick, textOf)
  local box = T.Panel(parent, "inset")
  local sf = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 4, -4); sf:SetPoint("BOTTOMRIGHT", -24, 4)
  SkinScroll(sf)
  local c = CreateFrame("Frame", nil, sf)
  c:SetSize(300, 10)
  sf:SetScrollChild(c)
  box.rows, box.data = {}, {}
  local r1, g1, b1 = T.Acc()
  local function Row(i)
    local r = box.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, c)
    r:SetHeight(rowH)
    r.sel = r:CreateTexture(nil, "BACKGROUND"); r.sel:SetAllPoints(); r.sel:SetColorTexture(r1, g1, b1, 0.16)
    r.bar = r:CreateTexture(nil, "ARTWORK"); r.bar:SetPoint("TOPLEFT"); r.bar:SetPoint("BOTTOMLEFT"); r.bar:SetWidth(3); r.bar:SetColorTexture(r1, g1, b1, 1)
    r.line = r:CreateTexture(nil, "ARTWORK"); r.line:SetPoint("BOTTOMLEFT"); r.line:SetPoint("BOTTOMRIGHT"); r.line:SetHeight(1); r.line:SetColorTexture(1, 1, 1, 0.06)
    local hl = r:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    r.num = JText(r, ns.FontName("GameFontDisableSmall")); r.num:SetPoint("LEFT", 6, 0); r.num:SetWidth(28); r.num:SetJustifyH("RIGHT")
    r.dot = r:CreateTexture(nil, "ARTWORK"); r.dot:SetSize(8, 8); r.dot:SetPoint("LEFT", 40, 0); r.dot:SetTexture("Interface\\Buttons\\WHITE8X8")
    -- lange Ziele (zwei Mobs, Item mit Mob) gehen auf zwei Zeilen, die Zeile ist hoch genug
    r.t = JText(r, ns.FontName("GameFontHighlight")); r.t:SetPoint("LEFT", 56, 0); r.t:SetPoint("RIGHT", -8, 0)
    r.t:SetWordWrap(rowH >= 30); r.t:SetMaxLines(rowH >= 30 and 2 or 1)
    r:SetScript("OnClick", function(self) if onClick and self.idx then onClick(self.idx) end end)
    -- abgeschnittener Text: ganz im Tooltip
    r:SetScript("OnEnter", function(self)
      if self.t.IsTruncated and self.t:IsTruncated() then
        ns.TipOwner(self, "ANCHOR_RIGHT"); GameTooltip:AddLine(self.t:GetText() or "", 1, 1, 1, true); GameTooltip:Show()
      end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    box.rows[i] = r
    return r
  end
  local function Render()
    local off = sf:GetVerticalScroll() or 0
    local h = sf:GetHeight() or 300
    if h < rowH then h = 300 end
    local first = math.max(1, math.floor(off / rowH) + 1)
    local n = math.min(60, math.ceil(h / rowH) + 2)
    local sel = box.selIdx
    for i = 1, n do
      local di = first + i - 1
      local it = box.data[di]
      local r = Row(i)
      if it then
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -(di - 1) * rowH)
        r:SetPoint("RIGHT", c, "RIGHT", 0, 0)
        r.idx = it.idx or di
        r.num:SetText(it.num or "")
        local col = it.col or { 0.7, 0.7, 0.7 }
        r.dot:SetVertexColor(col[1], col[2], col[3])
        local tx = it.text
        if not tx and textOf then tx = textOf(it); it.text = tx end
        r.t:SetText(tx or "")
        local tc = it.dim and 0.55 or 1
        r.t:SetTextColor(tc, tc, tc)
        r.sel:SetShown(r.idx == sel); r.bar:SetShown(r.idx == sel)
        r:Show()
      else
        r:Hide(); r.idx = nil
      end
    end
    for i = n + 1, #box.rows do box.rows[i]:Hide(); box.rows[i].idx = nil end
  end
  box.Render = Render
  sf:HookScript("OnVerticalScroll", Render)
  sf:HookScript("OnSizeChanged", function(_, w) if w and w > 0 then c:SetWidth(w) end; Render() end)
  function box.Set(list, sel)
    box.data = list or {}
    box.selIdx = sel
    c:SetHeight(math.max(10, #box.data * rowH))
    Render()
  end
  -- Zeile i oben ins Bild holen (mit zwei Zeilen davor)
  function box.ScrollTo(i)
    local h = sf:GetHeight() or 300
    local maxs = math.max(0, #box.data * rowH - h)
    if sf.UpdateScrollChildRect then sf:UpdateScrollChildRect() end
    sf:SetVerticalScroll(math.max(0, math.min(maxs, ((i or 1) - 3) * rowH)))
    Render()
  end
  box.sf = sf
  return box
end


------------------------------------------------------------
-- Berufe: Banner mit Knoepfen, Berufe Reihe, links Sachen mit Haken, rechts Gebiete und Rezepte
------------------------------------------------------------
local profPlanWin
-- Einstellungen fuer Route planen, fehlende Werte einzeln mit Standard fuellen
local PROF_PLAN_STD = { mode = "time", amount = 20, minutes = 30, avoidElite = true, avoidDanger = true, fishMode = "open" }
function ns.ProfPlanSettings()
  local db = ns.db
  db.profPlan = db.profPlan or {}
  for k, v in pairs(PROF_PLAN_STD) do if db.profPlan[k] == nil then db.profPlan[k] = v end end
  return db.profPlan
end
local ProfPlanSettings = ns.ProfPlanSettings

-- Fenster Route planen
local function ShowProfPlan()
  local set = ProfPlanSettings()
  if not profPlanWin then
    local w = T.Window("ForeverWegweiserProfPlan", 480, 510, TR"Route planen")
    profPlanWin = w
    local top = w.top or 40
    local function Head(text, anchor, y)
      local h = w:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
      if anchor then h:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -12) else h:SetPoint("TOPLEFT", 20, -top - 8) end
      h:SetText(Section(text))
      return h
    end
    local h1 = Head(TR"Gewählt")
    w.sel = w:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    w.sel:SetPoint("TOPLEFT", h1, "BOTTOMLEFT", 0, -4); w.sel:SetPoint("RIGHT", w, "RIGHT", -20, 0)
    w.sel:SetJustifyH("LEFT"); w.sel:SetSpacing(2)
    w.zones = w:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    w.zones:SetPoint("TOPLEFT", w.sel, "BOTTOMLEFT", 0, -4); w.zones:SetPoint("RIGHT", w, "RIGHT", -20, 0)
    w.zones:SetJustifyH("LEFT")
    local h2 = Head(TR"Ziel", w.zones, -12)
    w.bCount = T.Button(w, TR"Menge", 80, 22)
    w.bCount:SetPoint("TOPLEFT", h2, "BOTTOMLEFT", 0, -6)
    w.bTime = T.Button(w, TR"Zeit", 80, 22)
    w.bTime:SetPoint("LEFT", w.bCount, "RIGHT", 4, 0)
    w.bLoop = T.Button(w, TR"Endlos", 80, 22)
    w.bLoop:SetPoint("LEFT", w.bTime, "RIGHT", 4, 0)
    w.num = CreateFrame("EditBox", nil, w, "InputBoxTemplate")
    w.num:SetSize(50, 20); w.num:SetPoint("LEFT", w.bLoop, "RIGHT", 18, 0)
    w.num:SetAutoFocus(false); w.num:SetNumeric(true); w.num:SetMaxLetters(4)
    w.unit = w:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightSmall"))
    w.unit:SetPoint("LEFT", w.num, "RIGHT", 6, 0)
    -- Angeln: Open World oder Schwaerme
    w.fishHead = Head(TR"Angeln", w.bCount, -14)
    w.bOpen = T.Button(w, TR"Open World", 110, 22)
    w.bOpen:SetPoint("TOPLEFT", w.fishHead, "BOTTOMLEFT", 0, -6)
    w.bSchool = T.Button(w, TR"Schwärme", 110, 22)
    w.bSchool:SetPoint("LEFT", w.bOpen, "RIGHT", 4, 0)
    w.yElite = T.YesNo(w, TR"Elitegebiete meiden?", function() return ProfPlanSettings().avoidElite end,
      function(v) ProfPlanSettings().avoidElite = v; w.Recalc() end, TR"Ja: Stellen bei Elite Mobs lässt die Route weg.")
    w.yDanger = T.YesNo(w, TR"Gefährliche Orte meiden?", function() return ProfPlanSettings().avoidDanger end,
      function(v) ProfPlanSettings().avoidDanger = v; w.Recalc() end,
      TR"Gefährlich heisst: Mobs deutlich über deinem Level. Nein: die Stellen bleiben drin, du bekommst dort einen Hinweis.")
    w.info = w:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    w.info:SetJustifyH("LEFT"); w.info:SetSpacing(3)
    w.cancel = T.Button(w, TR"Abbrechen", 110, 24)
    w.cancel:SetPoint("BOTTOMLEFT", 20, 18)
    w.cancel:SetScript("OnClick", function() w:Hide() end)
    w.go = T.Button(w, TR"Route starten", 150, 26, true)
    w.go:SetPoint("BOTTOMRIGHT", -20, 18)
    -- andere Zone (die naechstbeste) und die ganze Runde auf der Karte zeigen
    w.alt = T.Button(w, TR"Andere Zone", 110, 22)
    w.alt:SetPoint("BOTTOMLEFT", w.cancel, "TOPLEFT", 0, 8)
    w.map = T.Button(w, TR"Auf der Karte", 110, 22)
    w.map:SetPoint("LEFT", w.alt, "RIGHT", 4, 0)
    w.alt:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(TR"Andere Zone")
      GameTooltip:AddLine(TR"Rechnet die Runde in der nächstbesten Zone. Nach der letzten geht es wieder bei der besten los.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    w.alt:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w.map:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP"); GameTooltip:AddLine(TR"Auf der Karte")
      GameTooltip:AddLine(TR"Zeigt die ganze Runde auf der Weltkarte, bevor du startest.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    w.map:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w:HookScript("OnHide", function() if ns.profPreview then ns.profPreview = nil; if ns.Draw then ns.Draw() end end end)
    local function Mark(b, on)
      T.SetState(b, on and "sel" or "inset")
      if on then b:LockHighlight() else b:UnlockHighlight() end
    end
    function w.Lay()
      local s = ProfPlanSettings()
      local hasFish = ns.Berufe and #ns.Berufe.Selected().fish > 0
      Mark(w.bCount, s.mode == "count"); Mark(w.bTime, s.mode ~= "count" and s.mode ~= "loop"); Mark(w.bLoop, s.mode == "loop")
      w.num:SetText(tostring(s.mode == "count" and (s.amount or 20) or (s.minutes or 30)))
      w.num:SetShown(s.mode ~= "loop")
      w.unit:SetText(s.mode == "count" and TR"Stück zusammen" or (s.mode == "loop" and TR"Runde im Kreis, bis du aufhörst" or TR"Minuten"))
      w.unit:ClearAllPoints()
      if s.mode == "loop" then w.unit:SetPoint("LEFT", w.bLoop, "RIGHT", 18, 0) else w.unit:SetPoint("LEFT", w.num, "RIGHT", 6, 0) end
      w.fishHead:SetShown(hasFish); w.bOpen:SetShown(hasFish); w.bSchool:SetShown(hasFish)
      Mark(w.bOpen, s.fishMode ~= "school"); Mark(w.bSchool, s.fishMode == "school")
      local anchor = hasFish and w.bOpen or w.bCount
      w.yElite:ClearAllPoints(); w.yElite:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -14); w.yElite:SetPoint("RIGHT", w, "RIGHT", -20, 0)
      w.yDanger:ClearAllPoints(); w.yDanger:SetPoint("TOPLEFT", w.yElite, "BOTTOMLEFT", 0, -4); w.yDanger:SetPoint("RIGHT", w, "RIGHT", -20, 0)
      w.info:ClearAllPoints(); w.info:SetPoint("TOPLEFT", w.yDanger, "BOTTOMLEFT", 0, -14); w.info:SetPoint("RIGHT", w, "RIGHT", -20, 0)
      w.yElite.Update(); w.yDanger.Update()
    end
    local pending
    function w.Recalc()
      w.Lay()
      w.res = nil
      w.info:SetText(TR"|cff9d9d9dRechnet ...|r")
      w.go:Disable()
      if pending then return end
      pending = true
      C_Timer.After(0.3, function()
        pending = false
        local s = ProfPlanSettings()
        ns.ProfPlan({ mode = s.mode, amount = s.amount, minutes = s.minutes, avoidElite = s.avoidElite, avoidDanger = s.avoidDanger, fishMode = s.fishMode, skip = w.skip }, function(res)
          w.res = res
          w.alt:SetEnabled(res and res.alts and #res.alts > 1 or (w.skip and next(w.skip)) and true or false)
          w.map:SetEnabled(res and #res.steps > 0 and true or false)
          if ns.profPreview and res and #res.steps > 0 then ns.profPreview = { steps = res.steps, idx = 1, loop = true }; if ns.Draw then ns.Draw() end end
          local lines = {}
          if res and #res.steps > 0 then
            local zn = {}
            for _, m in ipairs(res.zones or {}) do table.insert(zn, ns.ZoneName and ns.ZoneName(m) or "?") end
            table.insert(lines, (TR"Schätzung: ca |cffffffff%d Min|r, ca |cffffffff%d Stück|r, %d %s (%s)"):format(math.floor((res.min or 0) + 0.5),
              res.items or 0, #zn, #zn == 1 and TR"Gebiet" or TR"Gebiete", table.concat(zn, ", ")))
            if res.endless then
              table.insert(lines, (TR"Eine Runde über %d Stellen, sie läuft im Kreis, bis du aufhörst"):format(#res.steps))
            elseif res.loops then table.insert(lines, (TR"%d Runden über %d Stellen"):format(res.loops, math.floor(#res.steps / math.max(1, res.loops)))) end
            if res.alts and #res.alts > 1 then
              local an = {}
              for i2, a in ipairs(res.alts) do if i2 > 1 and i2 <= 4 then an[#an + 1] = (ns.ZoneName and ns.ZoneName(a.map) or "?") .. (" (%d/Std)"):format(math.floor(a.perHour or 0)) end end
              table.insert(lines, TR"|cff9d9d9dAndere gute Zonen: " .. table.concat(an, ", ") .. "|r")
            end
            w.go:Enable()
            if w.startAfter and w:IsShown() then
              w.startAfter = nil
              C_Timer.After(0, function() if w.res == res and w:IsShown() then ns.ProfStart(res); w:Hide(); if big then big:Hide() end end end)
            end
          else
            w.startAfter = nil
            table.insert(lines, TR"|cffff9030Keine Route möglich.|r")
          end
          for _, m in ipairs(res and res.missing or {}) do table.insert(lines, "|cffff9030" .. m .. "|r") end
          table.insert(lines, s.mode == "loop" and TR"|cff9d9d9dDie Runde läuft im Kreis, bis du im Menü Neu rechnen drückst (zurück zum Leveln).|r" or TR"|cff9d9d9dDie Route ist fertig, wenn das Ziel erreicht ist.|r")
          w.info:SetText(table.concat(lines, "\n"))
        end)
      end)
    end
    w.bCount:SetScript("OnClick", function() ProfPlanSettings().mode = "count"; w.Recalc() end)
    w.bTime:SetScript("OnClick", function() ProfPlanSettings().mode = "time"; w.Recalc() end)
    w.bLoop:SetScript("OnClick", function() ProfPlanSettings().mode = "loop"; w.Recalc() end)
    w.alt:SetScript("OnClick", function()
      local res = w.res
      local cur = res and res.zones and res.zones[1]
      w.skip = w.skip or {}
      if cur then w.skip[cur] = true end
      -- alle durch: wieder bei der besten anfangen
      local left = false
      for _, a in ipairs(res and res.alts or {}) do if not w.skip[a.map] then left = true end end
      if not left then w.skip = {} end
      w.Recalc()
    end)
    w.map:SetScript("OnClick", function()
      local res = w.res
      if not (res and #res.steps > 0) then return end
      ns.profPreview = { steps = res.steps, idx = 1, loop = true }
      local m = res.zones and res.zones[1] or res.steps[1].map
      if WorldMapFrame and not WorldMapFrame:IsShown() and ToggleWorldMap then ToggleWorldMap() end
      if WorldMapFrame and WorldMapFrame.SetMapID and m then WorldMapFrame:SetMapID(m) end
      if ns.Draw then ns.Draw() end
    end)
    w.bOpen:SetScript("OnClick", function() ProfPlanSettings().fishMode = "open"; w.Recalc() end)
    w.bSchool:SetScript("OnClick", function() ProfPlanSettings().fishMode = "school"; w.Recalc() end)
    w.num:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    w.num:SetScript("OnEditFocusLost", function(self)
      local v = tonumber(self:GetText())
      local s = ProfPlanSettings()
      if v and v > 0 then if s.mode == "count" then s.amount = v else s.minutes = v end end
      -- Fokus weg, weil du auf Route starten klickst: nach dem Rechnen gleich starten
      if w.go.IsMouseOver and w.go:IsMouseOver() then w.startAfter = true end
      w.Recalc()
    end)
    w.go:SetScript("OnClick", function()
      -- Zahl getippt, aber noch nicht uebernommen: zuerst neu rechnen
      local v = tonumber(w.num:GetText())
      local s = ProfPlanSettings()
      local cur = s.mode == "count" and s.amount or s.minutes
      if v and v > 0 and v ~= cur then
        if s.mode == "count" then s.amount = v else s.minutes = v end
        -- erst mit der neuen Zahl rechnen, dann gleich starten (vorher musste man ein zweites Mal klicken)
        w.startAfter = true
        w.num:ClearFocus(); w.Recalc()
        return
      end
      if w.res and #w.res.steps > 0 then ns.ProfStart(w.res); w:Hide(); if big then big:Hide() end end
    end)
  end
  local w = profPlanWin
  local sel = ns.Berufe.Selected()
  local names = {}
  for _, it in ipairs(sel.all) do table.insert(names, ns.ProfItemName(it)) end
  w.sel:SetText(#names > 0 and table.concat(names, ", ") or TR"Noch nichts angehakt.")
  local zn = {}
  for m in pairs(ns.ProfSel().zones) do table.insert(zn, ns.ZoneName and ns.ZoneName(m) or "?") end
  w.zones:SetText(TR"Gebiete: " .. (#zn > 0 and table.concat(zn, ", ") or TR"automatisch, Keine Zeit Leveling Guide sucht die besten"))
  w.skip = nil
  w:Show()
  w:Raise()
  w.Recalc()
end
ns.ShowProfPlan = ShowProfPlan

local STATUS_TXT = { ok = TR"|cff40ff40ok|r", danger = TR"|cffff9030gefährlich|r", elite = TR"|cffff5050Elite nah|r", enemy = TR"|cffff5050feindlich|r" }

-- 20.4b2 (K 20:05 a, S 19:52): Berufe Zonen. Nur EINE Zone waehlbar. Bei mehreren Sachen nur Zonen, in denen alle
-- vorkommen; Sachen ohne gemeinsame Zone sind grau. Zone waehlen bei laufender Berufe Route rechnet die Runde dort neu.
local function ProfCommonZones()
  local sel = ns.ProfSel()
  local common, nItems, missing = nil, 0, false
  for id in pairs(sel.items) do
    nItems = nItems + 1
    local list = ns.ProfAreasCached and ns.ProfAreasCached(id)
    if not list then missing = true
    else
      local here = {}
      for _, a in ipairs(list) do here[a.map] = true end
      if not common then common = here
      else for m in pairs(common) do if not here[m] then common[m] = nil end end end
    end
  end
  return common, nItems, missing
end
-- hat die Sache eine Zone mit allen anderen gewaehlten gemeinsam? (nil = weiss noch nicht)
local function ProfItemShares(id)
  local sel = ns.ProfSel()
  local mine = ns.ProfAreasCached and ns.ProfAreasCached(id)
  if not mine then return nil end
  for oid in pairs(sel.items) do
    if oid ~= id then
      local other = ns.ProfAreasCached and ns.ProfAreasCached(oid)
      if not other then return nil end
      local set = {}
      for _, a in ipairs(other) do set[a.map] = true end
      local any = false
      for _, a in ipairs(mine) do if set[a.map] then any = true; break end end
      if not any then return false end
    end
  end
  return true
end
-- laufende Berufe Route in der gewaehlten Zone neu rechnen (Einstellungen wie beim letzten Planen)
local function ProfReplanZone()
  local o = ns.db and ns.db.opt
  if not (o and o.prof and ns.ProfPlan and ns.ProfStart) then return end
  local s = ns.ProfPlanSettings and ns.ProfPlanSettings() or {}
  ns.ProfPlan({ mode = s.mode, amount = s.amount, minutes = s.minutes, avoidElite = s.avoidElite, avoidDanger = s.avoidDanger, fishMode = s.fishMode }, function(res)
    if res and res.steps and #res.steps > 0 then
      C_Timer.After(0, function() ns.ProfStart(res) end)
      if ns.TestLog then ns.TestLog("BERUFE", "Zone gewechselt bei laufender Route: Runde neu gerechnet") end
    else
      ns.Print(TR"In dieser Zone geht die Runde nicht, die alte Route bleibt.")
    end
  end)
end

local function BuildBerufe(pg)
  local curProf = "herb"
  local curItem
  local tab = "areas"
  local recFilter = "all"
  pg.hero = T.Hero(pg, 112)
  pg.hero:SetPoint("TOPLEFT"); pg.hero:SetPoint("TOPRIGHT")
  pg.plan = T.Button(pg.hero.top, TR"Route planen", 150, 26, true)
  pg.plan:SetPoint("TOPRIGHT", pg.hero.top, "TOPRIGHT", -14, -14)
  pg.reset = T.Button(pg.hero.top, TR"Zurücksetzen", 110, 26)
  pg.reset:SetPoint("RIGHT", pg.plan, "LEFT", -6, 0)
  pg.plan:SetScript("OnClick", function()
    if ns.ProfSelCount() == 0 then ns.Print(TR"Erst links etwas anhaken."); return end
    ShowProfPlan()
  end)
  pg.reset:SetScript("OnClick", function() ns.ProfReset(); pg.hint:SetText(""); pg.Fill() end)
  pg.reset:SetScript("OnEnter", function(self)
    ns.TipOwner(self, "ANCHOR_BOTTOM"); GameTooltip:AddLine(TR"Zurücksetzen")
    GameTooltip:AddLine(TR"Nimmt alle Haken weg: Sachen in allen Berufen und gewählte Gebiete.", 1, 1, 1, true); GameTooltip:Show()
  end)
  pg.reset:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Berufe als Reiter (aktiver hell mit goldener Linie), alle gleich breit
  local row = T.TabBar(pg, 28)
  row:SetPoint("TOPLEFT", pg.hero, "BOTTOMLEFT", 0, -8); row:SetPoint("TOPRIGHT", pg.hero, "BOTTOMRIGHT", 0, -8)
  row.onPick = function(k) curProf = k; curItem = nil; pg.hint:SetText(""); pg.Fill() end
  pg.profTabs = row
  row:SetScript("OnSizeChanged", function() if pg:IsShown() and pg.Fill then pg.Fill() end end)

  -- links: Sachen mit Haken
  local lb = T.Panel(pg, "inset")
  lb:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -8); lb:SetPoint("BOTTOMLEFT", pg, "BOTTOMLEFT", 0, 0); lb:SetWidth(300)
  pg.lhead = JText(lb, ns.FontName("GameFontNormal")); pg.lhead:SetPoint("TOPLEFT", 10, -8)
  pg.hint = JText(lb, ns.FontName("GameFontNormalSmall"), 1, 0.55, 0.2)
  pg.hint:SetPoint("BOTTOMLEFT", 10, 8); pg.hint:SetPoint("RIGHT", lb, "RIGHT", -10, 0); pg.hint:SetJustifyH("LEFT")
  local sf = CreateFrame("ScrollFrame", nil, lb, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 6, -28); sf:SetPoint("BOTTOMRIGHT", -26, 26)
  SkinScroll(sf)
  local child = CreateFrame("Frame", nil, sf)
  child:SetSize(260, 10)
  sf:SetScrollChild(child)
  pg.rows = {}

  -- rechts: Reiter Gebiete und Rezepte
  local rb = T.Panel(pg, "inset")
  rb:SetPoint("TOPLEFT", lb, "TOPRIGHT", 8, 0); rb:SetPoint("BOTTOMRIGHT", pg, "BOTTOMRIGHT", 0, 0)
  -- Reiter Gebiete und Rezepte, bei Rezepte rechts der Filter Alle oder Kann ich (auch als Reiter)
  pg.rTabs = T.TabBar(rb, 24)
  pg.rTabs:SetPoint("TOPLEFT", 8, -6); pg.rTabs:SetWidth(220)
  pg.rTabs.onPick = function(k) tab = k; pg.FillRight() end
  pg.fTabs = T.TabBar(rb, 24)
  pg.fTabs:SetPoint("TOPRIGHT", -8, -6); pg.fTabs:SetWidth(180)
  pg.fTabs.onPick = function(k) recFilter = k; pg.FillRight() end
  pg.title = JText(rb, ns.FontName("GameFontNormalLarge")); pg.title:SetPoint("TOPLEFT", 10, -38)
  if T.IsElv() then pg.title:SetTextColor(1, 1, 1) end
  pg.sub = JText(rb, ns.FontName("GameFontDisableSmall")); pg.sub:SetPoint("TOPLEFT", pg.title, "BOTTOMLEFT", 0, -3)
  pg.sub:SetPoint("RIGHT", rb, "RIGHT", -10, 0); pg.sub:SetJustifyH("LEFT")
  -- Kopfzeile der Tabelle
  pg.cols = {}
  for i = 1, 5 do
    local fs = JText(rb, ns.FontName("GameFontDisableSmall"))
    pg.cols[i] = fs
  end
  local rsf = CreateFrame("ScrollFrame", nil, rb, "UIPanelScrollFrameTemplate")
  rsf:SetPoint("TOPLEFT", 6, -96); rsf:SetPoint("BOTTOMRIGHT", -26, 40)
  SkinScroll(rsf)
  local rc = CreateFrame("Frame", nil, rsf)
  rc:SetSize(400, 10)
  rsf:SetScrollChild(rc)
  rsf:SetScript("OnSizeChanged", function(_, wd) if wd and wd > 0 then rc:SetWidth(wd) end end)
  pg.rrows = {}
  pg.best = T.Button(rb, TR"Pfeil zum besten Gebiet", 180, 24)
  pg.best:SetPoint("BOTTOMLEFT", 10, 8)
  pg.best:SetScript("OnClick", function() if curItem then ns.ProfArrowBest(curItem) end end)
  pg.note = JText(rb, ns.FontName("GameFontDisableSmall"))
  pg.note:SetPoint("LEFT", pg.best, "RIGHT", 10, 0); pg.note:SetPoint("RIGHT", rb, "RIGHT", -10, 0); pg.note:SetJustifyH("LEFT")

  local COLX = { 30, 0.44, 0.58, 0.70, 0.84 }
  local function ColX(i)
    local wd = rc:GetWidth() or 400
    if wd < 50 then wd = 400 end
    local v = COLX[i]
    return v < 1 and math.floor(wd * v) or v
  end
  local function RRow(i)
    local r = pg.rrows[i]
    if r then return r end
    r = CreateFrame("Frame", nil, rc)
    r:SetHeight(22)
    r.cb = T.CheckButton(r); r.cb:SetSize(20, 20); r.cb:SetPoint("LEFT", 2, 0)
    r.c = {}
    for k = 1, 5 do
      r.c[k] = JText(r, ns.FontName("GameFontHighlightSmall"))
      r.c[k]:SetWordWrap(false); r.c[k]:SetJustifyH("LEFT")
    end
    r.line = r:CreateTexture(nil, "ARTWORK"); r.line:SetPoint("BOTTOMLEFT"); r.line:SetPoint("BOTTOMRIGHT"); r.line:SetHeight(1); r.line:SetColorTexture(1, 1, 1, 0.05)
    pg.rrows[i] = r
    return r
  end
  local function PlaceCols(r, xs, cb)
    for k = 1, 5 do
      local x = xs[k]
      r.c[k]:ClearAllPoints()
      if x then
        r.c[k]:SetPoint("LEFT", r, "LEFT", x, 0)
        local nx = xs[k + 1]
        if nx then r.c[k]:SetWidth(math.max(20, nx - x - 6)) else r.c[k]:SetPoint("RIGHT", r, "RIGHT", -4, 0) end
        r.c[k]:Show()
      else
        r.c[k]:Hide()
      end
    end
    r.cb:SetShown(cb and true or false)
  end

  function pg.FillRight()
    pg.rTabs.Set({ { "areas", TR"Gebiete" }, { "rec", TR"Rezepte" } }, tab)
    pg.fTabs.Set({ { "all", TR"Alle" }, { "mine", TR"Kann ich" } }, recFilter)
    pg.fTabs:SetShown(tab == "rec")
    pg.best:SetShown(tab == "areas")
    local it = curItem and ns.ProfItem(curItem)
    for _, r in ipairs(pg.rrows) do r:Hide() end
    if not it then
      pg.title:SetText(""); pg.sub:SetText(TR"Links eine Sache anklicken.")
      for _, c in ipairs(pg.cols) do c:SetText("") end
      pg.note:SetText("")
      return
    end
    pg.title:SetText(ns.ProfItemName(it))
    local heads, xs
    if tab == "areas" then
      local zsel = ns.ProfSel().zones
      local nz = 0
      for _ in pairs(zsel) do nz = nz + 1 end
      pg.sub:SetText(nz > 0 and (TR"Route bleibt in %d %s mit Haken."):format(nz, nz == 1 and TR"Gebiet" or TR"Gebieten")
        or TR"Nichts angehakt: Keine Zeit Leveling Guide sucht die besten Gebiete selber.")
      local fish = it.prof == "fish"
      heads = { TR"Gebiet", TR"Level", fish and TR"Stellen" or TR"Stellen", "Status", TR"Gold/Std" }
      xs = { ColX(1), ColX(2), ColX(3), ColX(4), ColX(5) }
      -- Gold pro Stunde je Gebiet (Schaetzwert mit Preisen aus dem Auktionshaus, sonst Haendler Preis)
      local gold = {}
      if ns.profGold then
        for _, e in ipairs(ns.profGold) do
          local k = tostring(e.id) .. ":" .. tostring(e.map)
          if not gold[k] or (e.gph or 0) > gold[k] then gold[k] = e.gph or 0 end
        end
      elseif ns.ProfGoldList and not pg.goldBusy then
        pg.goldBusy = true
        ns.ProfGoldList(function() pg.goldBusy = false; if pg:IsShown() and tab == "areas" then pg.FillRight() end end)
      end
      pg.gold = gold
      -- erst den Cache, sonst rechnen lassen (Rueckruf spaeter, nie direkt, sonst ruft es sich selber auf)
      local list = ns.ProfAreasCached(curItem)
      if not list and pg.areaBusy ~= curItem then
        pg.areaBusy = curItem
        local want = curItem
        list = ns.ProfAreas(curItem, function()
          C_Timer.After(0, function()
            if pg.areaBusy == want then pg.areaBusy = nil end
            if pg:IsShown() and tab == "areas" and curItem == want then pg.FillRight() end
          end)
        end)
      end
      if not list then
        pg.note:SetText(TR"Gebiete werden gesucht ...")
        list = {}
      else
        local src = ns.AHSources and ns.AHSources() or {}
        pg.note:SetText(TR"(G) heisst: von dir gelernt.  " .. (#src > 0 and (TR"Gold/Std mit Preisen von %s, Schätzwert."):format(table.concat(src, ", "))
          or TR"Gold/Std nur mit Händler Preisen (kein Auktionshaus Addon), darum zu tief."))
      end
      -- 20.4b2: mehrere Sachen gewaehlt: nur Zonen, in denen alle vorkommen
      local common, nSel = ProfCommonZones()
      if common and nSel > 1 then
        local f = {}
        for _, a in ipairs(list) do if common[a.map] then f[#f + 1] = a end end
        if #f < #list then pg.note:SetText((pg.note:GetText() or "") .. "  " .. TR"Nur Gebiete, in denen alle gewählten Sachen vorkommen.") end
        list = f
      end
      for i, a in ipairs(list) do
        local r = RRow(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", rc, "TOPLEFT", 0, -(i - 1) * 24); r:SetPoint("RIGHT", rc, "RIGHT", 0, 0)
        PlaceCols(r, xs, true)
        r.cb:SetChecked(zsel[a.map] and true or false)
        r.cb:SetScript("OnClick", function(self)
          -- 20.4b2: nur eine Zone (die andere fliegt raus)
          local on = self:GetChecked()
          for m in pairs(zsel) do zsel[m] = nil end
          if on then zsel[a.map] = true end
          pg.FillRight()
          if on then ProfReplanZone() end
        end)
        r.c[1]:SetText((ns.ZoneName and ns.ZoneName(a.map) or "?") .. (a.learned and " |cff7fd1b9(G)|r" or ""))
        r.c[2]:SetText(a.lo and (TR"%d bis %d"):format(a.lo, a.hi or a.lo) or "?")
        if fish then
          r.c[3]:SetText(("%d%s"):format(a.n or 0, a.need and (TR" |cff9d9d9d(Skill " .. a.need .. ")|r") or ""))
        else
          r.c[3]:SetText(tostring(a.n or 0))
        end
        r.c[4]:SetText(STATUS_TXT[a.status] or a.status or "")
        local gph = gold[tostring(curItem) .. ":" .. tostring(a.map)]
        r.c[5]:SetText(gph and gph > 0 and ("|cff40ff40" .. (ns.Money and ns.Money(gph) or tostring(gph)) .. "|r") or (ns.profGold and "|cff9d9d9d-|r" or "..."))
        r:Show()
      end
      rc:SetHeight(math.max(10, #list * 24))
    else
      heads = { TR"Rezept", TR"Beruf", "Skill", TR"Menge", TR"Wer" }
      xs = { 4, math.floor((rc:GetWidth() > 50 and rc:GetWidth() or 400) * 0.42), math.floor((rc:GetWidth() > 50 and rc:GetWidth() or 400) * 0.62),
        math.floor((rc:GetWidth() > 50 and rc:GetWidth() or 400) * 0.72), math.floor((rc:GetWidth() > 50 and rc:GetWidth() or 400) * 0.82) }
      pg.sub:SetText(ns.HasAtlasLoot() and TR"Alle Rezepte, die das brauchen (AtlasLoot)" or TR"Ohne AtlasLoot siehst du nur die Rezepte, die du schon gelernt hast.")
      ns.ProfRecipeIndex(function() if pg:IsShown() and tab == "rec" and not pg.recFilled then pg.recFilled = true; pg.FillRight() end end)
      local list = {}
      for _, e in ipairs(ns.ProfRecipes(curItem)) do
        if recFilter == "all" or e.known then table.insert(list, e) end
      end
      for i, e in ipairs(list) do
        local r = RRow(i)
        r:ClearAllPoints(); r:SetPoint("TOPLEFT", rc, "TOPLEFT", 0, -(i - 1) * 24); r:SetPoint("RIGHT", rc, "RIGHT", 0, 0)
        PlaceCols(r, xs, false)
        r.c[1]:SetText(e.name .. (e.learned and " |cff7fd1b9(G)|r" or ""))
        r.c[2]:SetText(e.prof or "?")
        r.c[3]:SetText(tostring(e.skill or 0))
        r.c[4]:SetText(tostring(e.count or 1))
        r.c[5]:SetText(#e.who > 0 and table.concat(e.who, ", ") or TR"|cff9d9d9dkeiner|r")
        r:Show()
      end
      rc:SetHeight(math.max(10, #list * 24))
      -- 19.31 (Saschas Runde: Kochen und Angeln, Rezepte leer): klar sagen warum, und es ins Test Log schreiben
      local note = TR"Wer: welcher deiner Charaktere das Rezept kann"
      if #list == 0 then
        local al, nIdx = ns.HasAtlasLoot(), 0
        for _ in pairs(ns.ProfRecipeIndexNow and ns.ProfRecipeIndexNow() or {}) do nIdx = nIdx + 1 end
        if not al then
          note = TR"Keine Rezepte bekannt. Ohne AtlasLoot kennt Keine Zeit Leveling Guide nur Rezepte, die du gelernt hast: öffne einmal dein Berufsfenster (zb Kochen), dann merkt es sich die Rezepte."
        elseif nIdx == 0 then
          note = TR"AtlasLoot ist an, aber seine Berufe Daten sind noch nicht geladen. Öffne einmal das AtlasLoot Fenster oder dein Berufsfenster, dann nochmal schauen."
        else
          note = TR"Für dieses Teil kennen AtlasLoot und deine Berufsfenster kein Rezept."
        end
        if ns.TestLog and pg.recLogged ~= curItem then
          pg.recLogged = curItem
          ns.TestLog("BERUFE", ("Rezepte leer: Teil %s, Beruf %s, AtlasLoot %s, Rezept Index %d Zutaten, Filter %s"):format(tostring(curItem), tostring(curProf), al and "an" or "aus", nIdx, tostring(recFilter)))
        end
      end
      pg.note:SetText(note)
    end
    for k = 1, 5 do
      local c = pg.cols[k]
      c:ClearAllPoints()
      if heads[k] and xs[k] then c:SetPoint("TOPLEFT", rb, "TOPLEFT", 6 + xs[k], -78); c:SetText(heads[k]); c:Show() else c:Hide() end
    end
  end

  function pg.Fill()
    local p = ns.PROF[curProf]
    local sel = ns.ProfSel()
    -- Banner
    if pg.hero.img ~= p.banner then pg.hero.img = p.banner; JImg(pg.hero, p.banner) end
    pg.hero.title:SetText(p.name)
    local r, mx = ns.ProfSkill(curProf)
    if p.free and curProf == "cloth" then
      pg.hero.sub:SetText(r and (TR"Schneiderei %d von %d, Stoff farmen geht ohne Skill"):format(r, mx) or TR"Stoff farmen geht ohne Skill")
    elseif p.free then
      pg.hero.sub:SetText(r and (TR"Skill %d von %d, Zutaten farmen geht ohne Skill"):format(r, mx) or TR"Zutaten farmen geht ohne Skill")
    else
      pg.hero.sub:SetText(r and (TR"Skill %d von %d"):format(r, mx) or TR"Noch nicht gelernt")
    end
    local n = ns.ProfSelCount()
    pg.plan:SetText((TR"Route planen (%d)"):format(n))
    if n > 0 then pg.plan:Enable(); pg.reset:Enable() else pg.plan:Disable() end
    local nz = 0
    for _ in pairs(sel.zones) do nz = nz + 1 end
    if n > 0 or nz > 0 then pg.reset:Enable() else pg.reset:Disable() end
    -- Berufe Reiter: Symbol, Skill, wie viele Sachen in der Route
    local defs = {}
    for _, pp in ipairs(ns.PROFS) do
      local sk = ns.ProfSkill(pp.key)
      local c = ns.ProfSelCount(pp.key)
      defs[#defs + 1] = { pp.key, ("|T%s:16:16:0:0|t %s%s%s"):format(pp.icon, pp.short, sk and (" " .. sk) or "", c > 0 and (" (" .. c .. ")") or "") }
    end
    pg.profTabs.Set(defs, curProf, true)
    -- Liste links
    pg.lhead:SetText(curProf == "fish" and (TR"Fische für deinen Skill") or (p.short .. TR": was du farmen willst"))
    local items = ns.ProfItems(curProf)
    if not curItem then
      for _, it in ipairs(items) do if sel.items[it.id] then curItem = it.id; break end end
      if not curItem then for _, it in ipairs(items) do if ns.ProfCan(it) then curItem = it.id end end end
      curItem = curItem or (items[1] and items[1].id)
    end
    for i, it in ipairs(items) do
      local rw = pg.rows[i]
      if not rw then
        rw = CreateFrame("Button", nil, child)
        rw:SetHeight(24)
        rw.cb = T.CheckButton(rw); rw.cb:SetSize(20, 20); rw.cb:SetPoint("LEFT", 0, 0)
        rw.ic = rw:CreateTexture(nil, "ARTWORK"); rw.ic:SetSize(18, 18); rw.ic:SetPoint("LEFT", rw.cb, "RIGHT", 2, 0)
        rw.t = JText(rw, ns.FontName("GameFontHighlightSmall")); rw.t:SetPoint("LEFT", rw.ic, "RIGHT", 6, 0); rw.t:SetPoint("RIGHT", rw, "RIGHT", -44, 0)
        rw.t:SetJustifyH("LEFT"); rw.t:SetWordWrap(false)
        rw.s = JText(rw, ns.FontName("GameFontDisableSmall")); rw.s:SetPoint("RIGHT", -4, 0)
        rw.sel = rw:CreateTexture(nil, "BACKGROUND"); rw.sel:SetAllPoints()
        local ar, ag, ab = T.Acc(); rw.sel:SetColorTexture(ar, ag, ab, 0.16)
        local hl = rw:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
        pg.rows[i] = rw
      end
      rw:ClearAllPoints(); rw:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * 25); rw:SetPoint("RIGHT", child, "RIGHT", 0, 0)
      local can, miss, none = ns.ProfCan(it)
      rw.cb:SetChecked(sel.items[it.id] and true or false)
      rw.cb:SetScript("OnClick", function(self)
        local ok, msg = ns.ProfToggleItem(it.id)
        if ok == false then self:SetChecked(false); pg.hint:SetText(msg or "") else pg.hint:SetText("") end
        curItem = it.id
        pg.Fill()
      end)
      rw:SetScript("OnClick", function() curItem = it.id; pg.Fill() end)
      rw.ic:SetTexture(ns.ProfItemIcon(it.id))
      rw.ic:SetDesaturated(not can)
      -- 20.4b2: Sache ohne gemeinsame Zone mit den anderen gewaehlten: grau, Tooltip sagt warum
      local shares = ns.ProfSelCount() > 0 and not sel.items[it.id] and ProfItemShares(it.id)
      rw.noShare = shares == false
      local col = (can and not rw.noShare) and "|cffffffff" or "|cff7d7d7d"
      rw.t:SetText(col .. ns.ProfItemName(it) .. "|r")
      -- 20.3y (S Test 17:01: 2 Fischnamen abgeschnitten): lange Namen passend kuerzen, ganz im Tooltip
      if ns.FitText then ns.FitText(rw.t, rw.t:GetText() or "") end
      if it.lo and it.prof == "skin" then
        rw.s:SetText((TR"Lvl %d-%d"):format(it.lo, it.hi))
      elseif (it.skill or 0) > 0 then
        rw.s:SetText(can and tostring(it.skill) or ("|cffff9030" .. it.skill .. "|r"))
      else
        rw.s:SetText(it.lo and (TR"Lvl %d-%d"):format(it.lo, it.hi) or "")
      end
      rw.sel:SetShown(curItem == it.id)
      rw:SetScript("OnEnter", function(self)
        ns.TipOwner(self, "ANCHOR_RIGHT")
        if GameTooltip.SetItemByID then pcall(GameTooltip.SetItemByID, GameTooltip, it.id) else GameTooltip:AddLine(ns.ProfItemName(it)) end
        if not can then GameTooltip:AddLine(none and (TR"Noch nicht gelernt: " .. p.name) or (TR"Dir fehlen noch " .. miss .. TR" Skillpunkte."), 1, 0.55, 0.2, true) end
        if self.noShare then GameTooltip:AddLine(TR"Kommt in keinem Gebiet zusammen mit den anderen gewählten Sachen vor.", 1, 0.55, 0.2, true) end
        GameTooltip:Show()
      end)
      rw:SetScript("OnLeave", function() GameTooltip:Hide() end)
      rw:Show()
    end
    for i = #items + 1, #pg.rows do pg.rows[i]:Hide() end
    child:SetHeight(#items * 25 + 6)
    pg.FillRight()
  end
  sf:SetScript("OnSizeChanged", function(_, wd) if wd and wd > 0 then child:SetWidth(wd) end end)
  rsf:HookScript("OnSizeChanged", function() if pg:IsShown() then pg.FillRight() end end)
end

local function JPage(key)
  if jpages[key] then return jpages[key] end
  local pg = CreateFrame("Frame", nil, big.body)
  pg:SetAllPoints(big.body)
  pg:Hide()
  jpages[key] = pg
  if key == "berufe" then BuildBerufe(pg); return pg end

  if key == "start" then
    -------------------------------------------- Startseite
    pg.hero = T.Hero(pg, 176)
    pg.hero:SetPoint("TOPLEFT"); pg.hero:SetPoint("TOPRIGHT")
    -- (Knoepfe Karte und Weiter raus: gibt es schon im Mini Fenster)
    -- 19.32 (Saschas Runde 2 Punkt 14): Startgebiet wählen gut sichtbar oben auf der Startseite, in jedem Modus, bis Level 12
    pg.startArea = pg.hero.Button(TR"Startgebiet wählen", false, function() if ns.ChooseStartArea then ns.ChooseStartArea() end end)
    -- Pause: alles anhalten, nochmal klicken macht weiter
    pg.pause = pg.hero.Button(TR"Pause", false, function()
      if ns.SetPaused then ns.SetPaused(not ns.db.paused) end
      ns.RefreshBig()
    end)
    -- Rundgang durch alle Seiten (merkt sich, wo du aufgehoert hast)
    pg.tour = pg.hero.Button(TR"Rundgang starten", false, function() if ns.TourStart then ns.TourStart() end end)
    pg.stats = JStats(pg, 4)
    pg.stats:SetPoint("TOPLEFT", pg.hero, "BOTTOMLEFT", 0, -12); pg.stats:SetPoint("TOPRIGHT", pg.hero, "BOTTOMRIGHT", 0, -12)
    pg.xp = JXPBar(pg)
    pg.xp:SetPoint("TOPLEFT", pg.stats, "BOTTOMLEFT", 0, -6); pg.xp:SetPoint("TOPRIGHT", pg.stats, "BOTTOMRIGHT", 0, -6)
    -- Einsteiger ab 20 (Übersicht): ein Bestwert und ein Tipp unter dem XP Balken
    pg.tip = JText(pg, ns.FontName("GameFontHighlightSmall"))
    pg.tip:SetPoint("TOPLEFT", pg.xp, "BOTTOMLEFT", 0, -8); pg.tip:SetPoint("RIGHT", pg, "RIGHT", 0, 0)
    pg.tip:SetJustifyH("LEFT")
    pg.gh = JHead(pg, TR"Ziele")
    pg.gh:SetPoint("TOPLEFT", pg.xp, "BOTTOMLEFT", 0, -14)
    pg.next = JText(pg, ns.FontName("GameFontDisableSmall"))
    pg.next:SetPoint("BOTTOMRIGHT", pg.gh, "BOTTOMRIGHT", 0, 0)
    pg.next:SetPoint("RIGHT", pg, "RIGHT", 0, 0); pg.next:SetJustifyH("RIGHT")
    local GOALS = {
      { TR"Leveln", nil, function() bigView = "opt"; ns.RefreshBig() end },
      { TR"Ausrüstung", "gear", function() bigView = "gear"; ns.RefreshBig() end },
      { TR"Bücher", "books", function() bigView = "books"; ns.RefreshBig() end },
      { TR"Dungeons", "dungeons", function() bigView = "dungeons"; ns.RefreshBig() end },
    }
    pg.cards = {}
    for i, g in ipairs(GOALS) do
      local b = T.ArtCard(pg, 200, 150)
      b.def = g
      b:SetScript("OnClick", function() if not g[2] or ns.Unlocked(g[2]) then g[3]() end end)
      pg.cards[i] = b
    end
    pg:SetScript("OnSizeChanged", function(self, w, h)
      local gap = 12
      local cw = ((w or 800) - gap * 3) / 4
      local top = 176 + 12 + 44 + 6 + 8 + 14 + 22 + (self.tipOn and 20 or 0)
      local ch = math.max(110, (h or 600) - top)
      for i, b in ipairs(self.cards) do
        b:ClearAllPoints(); b:SetSize(cw, ch)
        b:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (cw + gap), -top)
      end
    end)
    function pg.Fill(s)
      if pg.tour and ns.TourLabel then pg.tour:SetText(ns.TourLabel()) end
      if pg.startArea then pg.startArea:SetShown((UnitLevel("player") or 1) <= 12 and ns.ChooseStartArea ~= nil) end
      local i = ns.HudInfo and ns.HudInfo() or {}
      local m, _, py = PlayerMapPos()
      -- Bild passend zur Landschaft der Zone
      if pg.hero.biomeMap ~= m then
        pg.hero.biomeMap = m
        if T.BiomeArt(pg.hero.art, m) then pg.hero.tint:SetColorTexture(0, 0, 0, T.IsElv() and 0.3 or 0.18)
        elseif not JImg(pg.hero, "fw_banner_zone") then pg.hero.art.SetMap(m, py) end
      end
      local objs = {}
      for _, o in ipairs(i.objs or {}) do table.insert(objs, Plain(o)) end
      local title = Plain(i.name or (i.finished and TR"Abschnitt fertig" or TR"Noch keine Route"))
      -- Stand des Ziels, auf das der Schritt gerade zeigt (nicht das erste Ziel der Quest)
      local ca = ns.OptCurrentAct and ns.OptCurrentAct()
      local prog = ca and ca.k == "O" and ns.OptCountText and ns.OptCountText(ca)
      if not prog or prog == "" or not prog:find("/") then prog = objs[1] and objs[1]:match("(%d+/%d+)%s*$") end
      -- 20.1 (Log 12:08: Text abgeschnitten): lange Schritte (Farmen mit vielen Mobs) passend kuerzen
      if ns.FitText then ns.FitText(pg.hero.title, title, prog and ("   " .. prog) or "") else pg.hero.title:SetText(title .. (prog and ("   " .. prog) or "")) end
      local sub = {}
      if i.dist then table.insert(sub, (TR"%d Yards"):format(math.floor(i.dist))) end
      if i.along and #i.along > 0 then table.insert(sub, TR"unterwegs: " .. Plain(i.along[1])) end
      if #sub == 0 and objs[2] then table.insert(sub, objs[2]) end
      pg.hero.sub:SetText(table.concat(sub, ",  "))
      local acc = { T.Acc() }
      local paused = ns.db and ns.db.paused
      local plbl = paused and TR"Weitermachen" or TR"Pause"
      -- Symbol als eigene Textur, beides genau in der Mitte (im Text sass das Symbol schief)
      if T.IconLabel then T.IconLabel(pg.pause, plbl, 16) else pg.pause:SetText(plbl) end
      if paused then
        pg.hero.Pills({ { TR"Pausiert", { 0.75, 0.75, 0.75 } }, { TR"Nichts wird gerechnet" } })
      else
        pg.hero.Pills({ { TR"Jetzt", acc }, { ("%s%s"):format(s.zone or "?", i.idx and i.total and (TR", Schritt %d von %d"):format(i.idx, i.total) or "") } })
      end
      local num, fmt = s.num or tostring, s.fmt or tostring
      -- noch nichts gemessen: ein kurzer Satz statt Punkte
      pg.stats.Set(1, (s.xph and s.xph > 0) and num(s.xph) or TR"|cff9d9d9dnoch offen|r", (s.xph and s.xph > 0) and TR"XP pro Stunde" or TR"XP pro Stunde, wird gerade gemessen")
      pg.stats.Set(2, s.nextLevel and (s.nextLevelText or fmt(s.nextLevel)) or TR"|cff9d9d9dnoch offen|r", TR"bis Level " .. ((s.level or 0) + 1))
      pg.stats.Set(3, ("%d / %d"):format(s.qLog or 0, ns.LogMax and ns.LogMax() or 20), TR"Questlog")
      pg.stats.Set(4, tostring(s.qDone or 0), TR"fertig zum Abgeben")
      local pf = s.pendFrac and ((s.pendLevel or 0) > (s.level or 0) and 1 or s.pendFrac) or 0
      pg.xp.Set(s.xpFrac or 0, pf)
      local stn, names
      if ns.NextUnlock then stn, names = ns.NextUnlock() end
      pg.next:SetText(stn and names and (TR"Als Nächstes ab Level %d: %s"):format(stn.lvl, names) or "")
      -- Bestwert und Tipp: Einsteiger mit Übersicht (Lernen und Experte haben dafür die Statistik)
      local tipOn = false
      if ns.Mode() == "guided" then
        local parts = {}
        local bl = ns.BestLine and ns.BestLine() or ""
        if bl ~= "" then parts[#parts + 1] = bl end
        local tips = ns.StatTips and ns.StatTips() or {}
        if tips[1] then parts[#parts + 1] = TR"|cff7fd1b9Tipp:|r " .. tips[1] end
        if #parts > 0 then tipOn = true; pg.tip:SetText(table.concat(parts, "     ")) end
      end
      pg.tip:SetShown(tipOn)
      if tipOn ~= pg.tipOn then
        pg.tipOn = tipOn
        pg.gh:ClearAllPoints(); pg.gh:SetPoint("TOPLEFT", pg.xp, "BOTTOMLEFT", 0, tipOn and -34 or -14)
        local sc = pg:GetScript("OnSizeChanged")
        if sc and pg:GetWidth() then pcall(sc, pg, pg:GetWidth(), pg:GetHeight()) end
      end
      -- Karten
      local opt = ns.db and ns.db.opt
      local L = UnitLevel("player") or 1
      local c1 = pg.cards[1]
      if not JImg(c1, "fw_leveln") and not JArt(c1, ContKey()) then c1.art.SetMap(m, py) end
      -- Etikett: läuft, Tour läuft (eine Tour oder Farm Route ist gerade aktiv), Pause oder noch keine Route
      local cur = ns.ProfileCur and ns.ProfileCur() or "level"
      local lb, lc = TR"läuft", { 0.25, 1, 0.25 }
      if paused then lb, lc = TR"Pause", { 0.75, 0.75, 0.75 }
      elseif not (opt and opt.steps and #opt.steps > 0) then lb, lc = TR"keine Route", { 1, 0.6, 0.2 }
      elseif cur == "extra" then lb, lc = TR"Tour läuft", { 0.4, 0.8, 1 } end
      local lsub = TR"Noch keine Route. Im Menü auf Neu rechnen."
      if opt and opt.steps and #opt.steps > 0 then
        lsub = cur == "extra" and (TR"Gerade: %s. Die Leveling Route wartet."):format(Plain(opt.title or TR"Tour"))
          or (TR"%d Schritte bis Level %d"):format(#opt.steps, opt.target or L + 1)
      end
      c1.Set(TR"Leveln", lsub, lb, lc)
      if c1.sub and ns.FitText then ns.FitText(c1.sub, lsub) end
      local function Lk(c, key, title, sub, badge, icon)
        local ok = ns.Unlocked(key)
        if not (icon.img and JImg(c, icon.img)) then JArt(c, icon.art, icon.ic) end
        c.Set(title, ok and sub or ns.UNLOCKS and ns.UNLOCKS[key] and ns.UNLOCKS[key].name or sub,
          ok and badge or (TR"ab Level " .. (ns.UnlockLevel and ns.UnlockLevel(key) or "?")), ok and nil or { 1, 0.35, 0.35 }, not ok)
      end
      -- Etiketten zeigen eine Info statt nochmal den Titel
      local ng = ns.gearQuests and #ns.gearQuests or nil
      local gb = ng and (ng == 1 and TR"1 Upgrade" or (TR"%d Upgrades"):format(ng)) or TR"wird gesucht"
      if ng == 0 then gb = TR"keine Upgrades" end
      Lk(pg.cards[2], "gear", TR"Ausrüstung", ng and (TR"%d Quests mit Upgrades"):format(ng) or TR"Quests mit besserer Ausrüstung", gb, { img = "fw_ausruestung", art = TR"Blackrock Depths", ic = "Interface\\Icons\\INV_Chest_Chain_05" })
      local nb = ns.BookNearCount and ns.BookNearCount() or 0
      local bd, bt = 0, 0
      if ns.BookCount then bd, bt = ns.BookCount() end
      Lk(pg.cards[3], "books", TR"Bücher", (TR"%d von %d gesammelt"):format(bd or 0, bt or 0), nb > 0 and (TR"%d in der Nähe"):format(nb) or TR"keins in der Nähe", { img = "fw_buecher", art = "Scholomance", ic = "Interface\\Icons\\INV_Misc_Book_09" })
      -- Dungeon: Bild vom passenden Dungeon, wenn bekannt
      local c4 = pg.cards[4]
      local fk = (UnitFactionGroup and UnitFactionGroup("player") == "Alliance") and TR"The Deadmines" or TR"Ragefire Chasm"
      local best
      for _, d in ipairs(ns.dungeons or {}) do
        if not d.raid and not d.pvp and (d.max or 0) >= L and (not best or (d.min or 0) < (best.min or 0)) and not (ns.DungeonHidden and ns.DungeonHidden(d)) then best = d end
      end
      local db4 = TR"wird geladen"
      if best then
        local dl = (best.min or 0) - L
        db4 = dl <= 0 and TR"passt jetzt" or (dl == 1 and TR"in 1 Level" or (TR"in %d Level"):format(dl))
      elseif ns.dungeons then db4 = TR"keiner passt" end
      Lk(c4, "dungeons", TR"Dungeons", TR"Quests und Route zum Eingang", db4, { img = "fw_dungeons", art = fk, ic = "Interface\\Icons\\INV_Misc_Key_03" })
      if best and ns.Unlocked("dungeons") then c4.sub:SetText((TR"%s, Level %d bis %d"):format(best.name or best.key or "?", best.min or 0, best.max or 0)) end
    end

  elseif key == "opt" then
    -------------------------------------------- Meine Route: Schritte und Planen
    pg.tab = "steps"
    pg.hero = T.Hero(pg, 124)
    pg.hero:SetPoint("TOPLEFT"); pg.hero:SetPoint("TOPRIGHT")
    -- Abschnitt neu rechnen: nur der laufende Abschnitt ab deinem Standort (der Plan bis 60 bleibt).
    -- Ganz neu (Plan, Verlauf, Zeiten) ist im Zonenplan: "Plan bis 60 komplett neu"
    pg.hero.Button(TR"Abschnitt neu rechnen", true, function() if ns.AutoOpt then ns.AutoOpt("hand") end; ns.RefreshBig() end)
    -- Reiter Schritte, Zonenplan, Planen kommen von der Seiten Leiste darueber (JournalShow), hier nur der Inhalt
    pg.tabTop = CreateFrame("Frame", nil, pg)
    pg.tabTop:SetPoint("TOPLEFT", pg.hero, "BOTTOMLEFT", 0, -10); pg.tabTop:SetPoint("TOPRIGHT", pg.hero, "BOTTOMRIGHT", 0, -10)
    pg.tabTop:SetHeight(26)
    pg.where = JText(pg, ns.FontName("GameFontDisable"))
    pg.where:SetPoint("RIGHT", pg, "RIGHT", 0, 0); pg.where:SetPoint("TOP", pg.tabTop, "TOP", 0, -6); pg.where:SetJustifyH("RIGHT")
    -- Schritte
    local steps = CreateFrame("Frame", nil, pg)
    steps:SetPoint("TOPLEFT", pg.tabTop, "BOTTOMLEFT", 0, -10); steps:SetPoint("BOTTOMRIGHT")
    pg.steps = steps
    pg.list = JList(steps, 34, function(idx) pg.sel = idx; ns.RefreshBig() end, function(it) return Plain(ns.OptStepText and ns.OptStepText(it.st) or "?") end)
    pg.list:SetPoint("TOPLEFT"); pg.list:SetPoint("BOTTOMLEFT"); pg.list:SetWidth(390)
    local det = CreateFrame("Frame", nil, steps)
    det:SetPoint("TOPLEFT", pg.list, "TOPRIGHT", 14, 0); det:SetPoint("BOTTOMRIGHT")
    pg.dh = T.Hero(det, 112)
    pg.dh:SetPoint("TOPLEFT"); pg.dh:SetPoint("TOPRIGHT")
    pg.dh.title:SetPoint("RIGHT", -70, 0); pg.dh.sub:SetPoint("RIGHT", -70, 0)
    pg.dprog = pg.dh.top:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlightHuge"))
    pg.dprog:SetPoint("BOTTOMRIGHT", -14, 14)
    pg.dtext = JText(det, ns.FontName("GameFontHighlight"))
    pg.dtext:SetPoint("TOPLEFT", pg.dh, "BOTTOMLEFT", 4, -12); pg.dtext:SetPoint("RIGHT", det, "RIGHT", -4, 0)
    pg.dtext:SetJustifyV("TOP"); pg.dtext:SetSpacing(5)
    local bw = {}
    local function DB(text, fn) local b = FlatButton(det, text, 120, 28); b:SetScript("OnClick", function() fn(); ns.RefreshBig() end); table.insert(bw, b); return b end
    DB(TR"Pfeil hierhin", function() local o = ns.db.opt; if o and pg.sel then if pg.sel < (o.idx or 1) then o.pinTop = math.max(o.pinTop or 0, o.idx or 1); o.pin, o.pinAt = true, time and time() or 0 end; o.idx = pg.sel; if ns.Draw then ns.Draw() end end end)
    DB(TR"Überspringen", function() if ns.OptSkip then ns.OptSkip() end end)
    DB(TR"Quest auslassen", function() Run("auslassen") end)
    det:SetScript("OnSizeChanged", function(self, w)
      local gw = ((w or 400) - 16) / 3
      for i, b in ipairs(bw) do b:ClearAllPoints(); b:SetWidth(gw); b:SetPoint("BOTTOMLEFT", (i - 1) * (gw + 8), 0) end
    end)
    -- Planen: Tempo Regler (3 Stufen mit Prozent), darunter Touren und Zeit als Knoepfe
    local plan = CreateFrame("Frame", nil, pg)
    plan:SetPoint("TOPLEFT", pg.tabTop, "BOTTOMLEFT", 0, -10); plan:SetPoint("BOTTOMRIGHT")
    pg.plan = plan
    pg.sl = T.StepSlider(plan)
    pg.sl:SetPoint("TOPLEFT", 4, 0); pg.sl:SetPoint("TOPRIGHT", -4, 0)
    local ph2 = JHead(plan, TR"Touren und Zeit"); ph2:SetPoint("TOPLEFT", 0, -150)
    pg.ph2 = ph2
    local TOURS = {
      { TR"Questlog Route", TR"nur die Quests in deinem Log", "questlog", function() ns.TourQuestLog() end, "Scholomance", "fw_buecher" },
      { TR"Stunden Budget", TR"Zeit eingeben, endet im Gasthaus", "budget", function() ns.ShowBudget() end, TR"Dire Maul", "fw_banner_zone" },
      { TR"Flugpunkte Tour", TR"fehlende Flugpunkte auf einer Runde", "flights", function() ns.TourFlights() end, "#cont", "fw_banner_route" },
      { TR"Entdecken Tour", TR"Gebiete aufdecken, XP pro Gebiet", "explore", function() ns.TourExplore() end, "Uldaman", "fw_leveln" },
      { TR"Feierabend", TR"Weg zum Gasthaus, Quests am Weg", "sleep", function() ns.EndSession() end, TR"Shadowfang Keep", "fw_leveln" },
      -- 20.3z (K 17:12, P13): auf Max Level alle offenen Quests nachholen
      { TR"Nach 60: alle offenen Quests", TR"nachquesten, alles was noch geht", nil, function() if ns.RestQuestsRoute then ns.RestQuestsRoute() end end, "Scholomance", "fw_leveln",
        rel = function() return (UnitLevel("player") or 1) >= ((GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60) end },
      { TR"Questlog aufräumen", TR"graue und zu weite Quests los", nil, function() ns.ShowLogCleanup() end, "Scholomance", "fw_buecher" },
      { TR"Startgebiet wählen", TR"woanders anfangen, zb mit Freunden", nil, function() if ns.ChooseStartArea then ns.ChooseStartArea() end end, "#cont", "fw_banner_zone", rel = function() return (UnitLevel("player") or 1) <= 12 end },
      { TR"Route exportieren und laden", TR"Klick: Route teilen, Rechtsklick: eine laden", nil, function(btn) if btn == "RightButton" or not (ns.db and ns.db.opt and ns.db.opt.steps) then ns.ShowImport() else ns.ShowExport() end end, "Gnomeregan", "fw_banner_route", rel = function() return ns.Unlocked("export") end },
    }
    pg.tours = {}
    for i, k in ipairs(TOURS) do
      local b = T.ArtCard(plan, 200, 110)
      b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
      b:SetScript("OnClick", function(_, btn) if not k[3] or ns.Unlocked(k[3]) then k[4](btn); ns.RefreshBig() end end)
      b.def = k
      pg.tours[i] = b
    end
    function pg.LayTours()
      local w, h = plan:GetWidth() or 800, plan:GetHeight() or 400
      local gap = 10
      local vis = {}
      for _, b in ipairs(pg.tours) do
        local ok = not b.def.rel or b.def.rel()
        b:SetShown(ok and true or false)
        if ok then vis[#vis + 1] = b end
      end
      local cols = 4
      local tw = (w - gap * (cols - 1)) / cols
      local rows = math.max(1, math.ceil(#vis / cols))
      local th = math.max(70, math.min(120, (h - 172 - gap * (rows - 1)) / rows))
      for i, b in ipairs(vis) do
        local c, r = (i - 1) % cols, math.floor((i - 1) / cols)
        b:ClearAllPoints(); b:SetSize(tw, th); b:SetPoint("TOPLEFT", plan, "TOPLEFT", c * (tw + gap), -172 - r * (th + gap))
      end
    end
    plan:SetScript("OnSizeChanged", function() pg.LayTours() end)
    function pg.Fill(s)
      local opt = ns.db and ns.db.opt
      local m, _, py = PlayerMapPos()
      if not JImg(pg.hero, "fw_banner_route") then pg.hero.art.SetMap(m, py) end
      if ns.OptBusy and ns.OptBusy() then
        pg.hero.title:SetText(TR"Rechnet gerade ..."); pg.hero.sub:SetText("")
      elseif opt and opt.steps then
        pg.hero.title:SetText(opt.title or TR"Normale Route")
        if (opt.sec or 0) >= 30 then
          pg.hero.sub:SetText((TR"%d Schritte, ca %s, Level %d bis %.1f"):format(#opt.steps, (s.fmt or tostring)(opt.sec or 0), opt.from or 0, opt.to or 0))
        else
          -- Farm Route oder Tour ohne geschaetzte Zeit
          pg.hero.sub:SetText((TR"%d Schritte, Level %d"):format(#opt.steps, math.floor(opt.from or UnitLevel("player") or 0)))
        end
      else
        pg.hero.title:SetText(TR"Noch keine Route"); pg.hero.sub:SetText(TR"Neu rechnen startet sie.")
      end
      pg.hero.Pills({ { (ns.ProfileOf and ns.ProfileOf(opt) == "extra") and TR"Tour" or TR"Leveling Route", { T.Acc() } } })
      pg.steps:SetShown(pg.tab == "steps"); pg.plan:SetShown(pg.tab == "plan")
      local cur = opt and math.min(opt.idx or 1, #(opt.steps or {})) or 0
      pg.where:SetText(opt and opt.steps and #opt.steps > 0 and pg.tab == "steps" and (TR"Schritt %d von %d"):format(cur, #opt.steps) or "")
      if pg.tab ~= "steps" and pg.tab ~= "plan" then return end
      if pg.tab == "plan" then
        pg.sl.Update()
        pg.LayTours()
        for _, b in ipairs(pg.tours) do
          local k = b.def
          if not b.artSet then b.artSet = true; if not (k[6] and JImg(b, k[6])) then JArt(b, k[5] == "#cont" and ContKey() or k[5], "Interface\\Icons\\INV_Misc_Map_01") end end
          local ok = not k[3] or ns.Unlocked(k[3])
          b.Set(k[1], k[2], ok and "" or (TR"ab Level " .. (ns.UnlockLevel and ns.UnlockLevel(k[3]) or "?")), { 1, 0.35, 0.35 }, not ok)
        end
        return
      end
      -- Liste der Schritte
      -- Text erst fuer die sichtbaren Zeilen (JList textOf), die Liste selbst ist nur Nummer, Farbe und Schritt
      -- 1.0 (K 22:57 Punkt 1, S Bild): Reiter Schritte zeigt nur die Schritte der aktuellen Zone (Zone vom jetzigen Schritt),
      -- alle Schritte stehen im Reiter Zonenplan
      local list = {}
      local function ZoneOf(m) return m and ((ns.cityParent and ns.cityParent[m]) or m) or nil end
      local curSt = opt and opt.steps and opt.steps[cur]
      local curZone = curSt and ZoneOf(curSt.map)
      local curPos = 1
      for idx, st in ipairs(opt and opt.steps or {}) do
        if not curZone or idx == cur or ZoneOf(st.map) == curZone then
          local a = st.acts and st.acts[1] or {}
          list[#list + 1] = { idx = idx, num = tostring(idx), col = KCOL[a.k] or { 0.7, 0.7, 0.7 }, st = st, dim = idx < cur }
          if idx == cur then curPos = #list end
        end
      end
      if curZone and ns.ZoneName then
        pg.where:SetText((TR"Schritt %d von %d, hier in %s: %d"):format(cur, #opt.steps, ns.ZoneName(curZone) or "?", #list))
      end
      local jump = false
      if not pg.sel or pg.lastCur ~= cur or pg.lastOpt ~= opt then pg.sel = cur; pg.lastCur = cur; pg.lastOpt = opt; jump = true end
      pg.list.Set(list, pg.sel)
      -- neuer aktueller Schritt: Liste dort hin, sonst bleibt sie, wo der Spieler hin gescrollt hat
      if jump then pg.list.ScrollTo(curPos) end
      -- Details zum gewaehlten Schritt
      local st = opt and opt.steps and opt.steps[pg.sel]
      if not st then
        pg.dh.title:SetText(""); pg.dh.sub:SetText(""); pg.dprog:SetText(""); pg.dtext:SetText(""); pg.dh.Pills({})
        return
      end
      if pg.dh.biomeMap ~= st.map then
        pg.dh.biomeMap = st.map
        if T.BiomeArt(pg.dh.art, st.map) then pg.dh.tint:SetColorTexture(0, 0, 0, T.IsElv() and 0.3 or 0.18)
        elseif not JImg(pg.dh, "fw_banner_zone") then pg.dh.art.SetMap(st.map, st.y) end
      end
      local a = st.acts[1] or {}
      local c = KCOL[a.k] or { 1, 1, 1 }
      pg.dh.Pills({ { KNAME[a.k] or TR"Schritt", c } })
      pg.dh.title:SetText(Plain(a.obj or a.who or a.quest or "?"))
      local zone = st.map and ns.ZoneName and ns.ZoneName(st.map) or ""
      pg.dh.sub:SetText(zone)
      local lp = a.qid and ns.logProgress and ns.logProgress[a.qid]
      local pr = ""
      for _, o in ipairs(lp and lp.objs or {}) do if a.obj and o.text and o.text:find(a.obj, 1, true) then pr = o.text:match("(%d+/%d+)") or "" end end
      pg.dprog:SetText(pr)
      local L = {}
      local function Line(h, t) table.insert(L, (T.IsElv() and "|cffa8a8a8" or "|cffffd100") .. h .. "|r   " .. t) end
      local qs = {}
      for _, x in ipairs(st.acts) do if x.quest and not qs[x.quest] then qs[x.quest] = true; table.insert(qs, (KNAME[x.k] or "") .. ": " .. Plain(x.quest)) end end
      Line(TR"Was", table.concat(qs, ",  "))
      if a.who then Line(TR"Wer", Plain(a.who)) end
      local m2, px, py2 = PlayerMapPos()
      if m2 and px and st.map and ns.WorldDist then
        local d = ns.WorldDist({ m2, px, py2 }, { st.map, st.x, st.y })
        if d then Line(TR"Weg", (TR"%d Yards"):format(math.floor(d))) end
      end
      local nx = opt.steps[pg.sel + 1]
      if nx then Line(TR"Danach", Plain(ns.OptStepText(nx))) end
      pg.dtext:SetText(table.concat(L, "\n"))
    end

  elseif key == "set" then
    -------------------------------------------- Einstellungen: links Themen als Bildkarten, rechts nur die Fragen dieses Themas
    local CATS = {
      { TR"Tempo", TR"Tempo", "Stratholme", TR"Welche Quests die Route nimmt: Tempo, Grinden, Dungeon Quests, Eskorten, Kontinent, Bücher", "fw_leveln" },
      { TR"Allgemein", TR"Allgemein und Mini Fenster", "Scholomance", TR"Modus, Mini Fenster und Hinweise", "fw_buecher" },
      { TR"Route und Karte", TR"Route und Karte", "#cont", TR"Was auf Karte und Minimap steht", "fw_banner_route" },
      { TR"Reisen", TR"Reisen", TR"Razorfen Kraul", TR"Wie die Route dich von A nach B bringt", "fw_leveln" },
      { TR"Quests", ns.TRKeys{ Quests = true, Questlog = true }, "Stratholme", TR"Annehmen, markieren, Belohnungen und wie voll das Questlog werden darf", "fw_ausruestung" },
      { TR"Gruppe", TR"Gruppe", TR"Blackrock Spire", TR"Zusammen spielen und teilen", "fw_dungeons" },
      { TR"Farmen", TR"Farmen", TR"Blackrock Depths", TR"Farmberufe: Kräuter, Erz, Leder, Stoff, Fleisch und Fische", "fw_beruf_kraeuter" },
      { TR"Gold", TR"Gold", TR"Blackrock Depths", TR"Gold Quests und Preise (ab 35, bei Alles frei sofort)", "fw_ausruestung" },
    }
    pg.cats = {}
    for i, c in ipairs(CATS) do
      local b = T.ArtCard(pg, 210, 54)
      b.Set(c[1], "")
      b.title:ClearAllPoints(); b.title:SetPoint("LEFT", 12, 0); b.title:SetPoint("RIGHT", -10, 0)
      b:SetPoint("TOPLEFT", 0, -(i - 1) * 60)
      b.def = c
      b:SetScript("OnClick", function() pg.cur = i; ns.RefreshBig() end)
      pg.cats[i] = b
    end
    local box = T.Panel(pg, "inset")
    box:SetPoint("TOPLEFT", 222, 0); box:SetPoint("BOTTOMRIGHT")
    pg.ht = JText(box, ns.FontName("GameFontNormalHuge")); pg.ht:SetPoint("TOPLEFT", 18, -14)
    if T.IsElv() then pg.ht:SetTextColor(1, 1, 1) end
    pg.hs = JText(box, ns.FontName("GameFontDisable")); pg.hs:SetPoint("TOPLEFT", pg.ht, "BOTTOMLEFT", 0, -4)
    local holder = CreateFrame("Frame", nil, box)
    holder:SetPoint("TOPLEFT", 8, -64); holder:SetPoint("BOTTOMRIGHT", -4, 6)
    pg.secs = {}
    pg.cur = 1
    -- Modus Geführt: nur die wichtigsten Themen und Fragen, darunter der Knopf "Alle Einstellungen" (nie gesperrt)
    pg.allBtn = FlatButton(pg, TR"Alle Einstellungen", 210, 26)
    pg.allBtn:SetScript("OnClick", function() ns.db.allSettings = not ns.db.allSettings; ns.RefreshBig() end)
    pg.allBtn:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(self:GetText())
      GameTooltip:AddLine(TR"Im Modus Geführt siehst du erst die wichtigsten Fragen. Hier kommen alle dazu.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    pg.allBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    function pg.Pick(name)
      for i, c in ipairs(CATS) do if c[1] == name then pg.cur = i end end
      ns.RefreshBig()
    end
    function pg.Fill()
      local easy = not ns.UseFunc()
      local vis = {}
      for i, b in ipairs(pg.cats) do
        local show = not easy or ns.EASY_SET_CATS[b.def[1]]
        b:SetShown(show and true or false)
        if show then vis[#vis + 1] = i; b:ClearAllPoints(); b:SetPoint("TOPLEFT", 0, -(#vis - 1) * 60) end
      end
      pg.allBtn:SetShown(not ns.Expert())
      pg.allBtn:SetText(ns.db.allSettings and TR"Nur die wichtigsten" or TR"Alle Einstellungen")
      pg.allBtn:ClearAllPoints(); pg.allBtn:SetPoint("TOPLEFT", pg, "TOPLEFT", 0, -#vis * 60 - 4)
      if easy and not ns.EASY_SET_CATS[CATS[pg.cur][1]] then pg.cur = vis[1] or 1 end
      for i, b in ipairs(pg.cats) do
        if not b.artSet then b.artSet = true; if not (b.def[5] and JImg(b, b.def[5])) then JArt(b, b.def[3] == "#cont" and ContKey() or b.def[3], "Interface\\Icons\\INV_Misc_Gear_01") end end
        b.badge:SetText(""); b.badgeBg:Hide()
        T.SetState(b, i == pg.cur and "sel" or "inset")
        b.art:SetAlpha(i == pg.cur and 1 or 0.6)
        if i == pg.cur then b.title:SetTextColor(T.Acc()) elseif T.IsElv() then b.title:SetTextColor(1, 1, 1) else b.title:SetTextColor(1, 0.82, 0) end
      end
      local c = CATS[pg.cur]
      pg.ht:SetText(c[1]); pg.hs:SetText(c[4])
      -- jeder Abschnitt einmal gebaut, nur der gewaehlte sichtbar
      local sk = (easy and "e" or "a") .. (ns.Mode() or "a") .. pg.cur
      if not pg.secs[sk] then
        local fr = CreateFrame("Frame", nil, holder); fr:SetAllPoints(holder)
        local t0 = #toggles
        local sf = BuildFunctions(fr, "TaurenRouteJournalSec" .. sk, c[2], easy)
        fr.sf = sf
        -- 17.9: die Schalter dieses Abschnitts merken, nur die sichtbaren werden nachgefuehrt (vorher alle von allen Kopien)
        fr.tg = {}
        for i = t0 + 1, #toggles do fr.tg[#fr.tg + 1] = toggles[i] end
        pg.secs[sk] = fr
      end
      for i, fr in pairs(pg.secs) do fr:SetShown(i == sk) end
      for _, tg in ipairs(pg.secs[sk].tg or toggles) do if tg.Update then tg.Update() end end
    end
  end
  return pg
end

-- alle anderen Seiten: Bildbanner oben, die bisherige Seite darunter
local JHERO = {
  weg = { TR"Mein Weg", TR"Was du schon kannst und was als Nächstes frei wird", "fw_banner_weg" },
  gear = { TR"Ausrüstung", TR"Quests mit Belohnungen, die besser sind als dein Zeug", "fw_ausruestung" },
  books = { TR"Bücher", TR"Bibliotheksbücher sammeln und abgeben", "fw_buecher" },
  rep = { TR"Ruf", TR"Quests und Mobs für deine Fraktionen", "fw_banner_ruf" },
  farm = { TR"Gold Mobs", TR"Die besten Spots für dein Level", "fw_banner_gold" },
  gold = { TR"Gold Quests", TR"Quests und Spots, die am meisten Gold bringen", "fw_banner_gold" },
  perf = { TR"Statistik", TR"Jetzt: Tempo, Kills und wo Zeit verloren geht", "fw_banner_stats" },
  detail = { TR"Statistik", TR"Pro Level: Zeiten pro Abschnitt und Zone", "fw_banner_stats" },
  stats = { TR"Statistik", TR"Gesamt: dein Weg in Zahlen", "fw_banner_stats" },
  statgold = { TR"Statistik", TR"Gold pro Stunde und nach Quelle", "fw_banner_gold" },
  help = { TR"Hilfe", TR"Was welche Funktion macht", "fw_banner_stats" },
  route = { TR"Weg zu 60", TR"Alle Schritte bis Level 60, Zeit pro Level und Zone", "fw_banner_route" },
}
local JH = 112
local jhero, shifted, statTabs = nil, {}, nil
local function Unshift()
  for p in pairs(shifted) do p:ClearAllPoints(); p:SetAllPoints(big.body) end
  shifted = {}
end

-- schwere Seiten: im Sekunden Takt nur so oft neu fuellen (Klicks fuellen sofort)
local JTHROTTLE = { berufe = 5, goldprof = 5, opt = 3 }
-- Seiten mit Reitern: Statistik, Dungeons, Gold und Meine Route. Gesperrte Reiter (Modus Geführt) fehlen noch.
local GROUPS = {
  stat = { { "perf", TR"Jetzt" }, { "detail", TR"Pro Level", lock = "stats" }, { "stats", TR"Gesamt", lock = "stats" }, extra = true },
  grp = { { "dungeons", TR"Dungeons" }, { "raids", TR"Raids", lock = "raids" }, { "pvp", TR"Schlachtfelder", lock = "pvp" } },
  gold = { { "farm", TR"Mobs" }, { "gold", TR"Quests" } },
  route = { { "opt", TR"Schritte" }, { "route", TR"Zonenplan" }, { "plan", TR"Planen", lock = "plan" } },
}
local OF = { perf = "stat", detail = "stat", stats = "stat", statgold = "stat", dungeons = "grp", raids = "grp", pvp = "grp",
  farm = "gold", gold = "gold", opt = "route", route = "route", plan = "route" }
local tabBar, goldBtn
JournalShow = function(view, s, auto)
  local journal = view and ns.db and true -- nur noch Journal Stil
  local grpKey = view and OF[view]
  local routeGrp = grpKey == "route"
  -- Banner fuer die uebrigen Seiten (Meine Route hat ihr eigenes oben)
  local h = journal and JHERO[view] and big.pages[view] and not routeGrp
  Unshift()
  if jhero then jhero:SetShown(h and true or false) end
  if h then
    if not jhero then
      jhero = T.Hero(big.body, JH)
      jhero:SetPoint("TOPLEFT"); jhero:SetPoint("TOPRIGHT")
    end
    jhero:Show()
    local d = JHERO[view]
    jhero.title:SetText(d[1]); jhero.sub:SetText(d[2])
    jhero.Pills({})
    if jhero.img ~= d[3] then jhero.img = d[3]; JImg(jhero, d[3]) end
    local p = big.pages[view]
    p:ClearAllPoints()
    p:SetPoint("TOPLEFT", big.body, "TOPLEFT", 0, -(JH + 12))
    p:SetPoint("BOTTOMRIGHT", big.body, "BOTTOMRIGHT", 0, 0)
    shifted[p] = true
  end
  if not tabBar then
    tabBar = T.TabBar(big.body, 26)
    tabBar.onPick = function(k) bigView = k; ns.RefreshBig() end
    goldBtn = T.Button(tabBar, TR"Gold", 130, 22)
    goldBtn:SetPoint("RIGHT", 0, 2)
    goldBtn:SetScript("OnClick", function() bigView = (bigView == "statgold") and "perf" or "statgold"; ns.RefreshBig() end)
  end
  local isTab = grpKey and (big.pages[view] or routeGrp)
  tabBar:SetShown(isTab and true or false)
  local top = 0
  if isTab then
    local defs = GROUPS[grpKey]
    top = routeGrp and (124 + 10) or (h and (JH + 12) or 0)
    tabBar:ClearAllPoints()
    tabBar:SetPoint("TOPLEFT", big.body, "TOPLEFT", 0, -top); tabBar:SetPoint("TOPRIGHT", big.body, "TOPRIGHT", 0, -top)
    local list = {}
    for _, d in ipairs(defs) do
      if not (d.lock and not ns.Unlocked(d.lock)) then list[#list + 1] = { d[1], d[2] } end
    end
    tabBar.Set(list, view == "statgold" and "perf" or view)
    goldBtn:SetText(view == "statgold" and TR"Zurück zu Leveln" or TR"Gold")
    goldBtn:SetShown(defs.extra and (ns.Unlocked("gold") or ns.Unlocked("rep")) and true or false)
    local p = big.pages[view]
    if p and not routeGrp or (routeGrp and view == "route" and p) then
      p:ClearAllPoints()
      p:SetPoint("TOPLEFT", big.body, "TOPLEFT", 0, -(top + 34))
      p:SetPoint("BOTTOMRIGHT", big.body, "BOTTOMRIGHT", 0, 0)
      shifted[p] = true
    end
  end
  local key = journal and (routeGrp and "opt" or JMAP[view])
  local pg = key and JPage(key)
  for _, p in pairs(jpages) do if p ~= pg then p:Hide() end end
  if not pg then return false end
  if key == "opt" then pg.tab = (view == "plan" and "plan") or (view == "route" and "zones") or "steps" end
  -- Zonenplan: oben das Banner von Meine Route, darunter die alte Seite (wird von RefreshBig gefuellt)
  local zones = routeGrp and view == "route"
  if not zones then for _, p in pairs(big.pages) do p:Hide() end end
  local was = pg:IsShown()
  pg:Show()
  local throttled = auto == "tick" and was and JTHROTTLE[key] and GetTime() - (pg.lastFill or 0) < JTHROTTLE[key]
  if not throttled then
    pg.lastFill = GetTime()
    local ok, err = pcall(pg.Fill, s or {})
    if not ok then
      -- jeder neue Fehler ins Test Log, im Chat nur der erste
      if ns.TestLog and pg.lastErr ~= tostring(err) then pg.lastErr = tostring(err); ns.TestLog("FEHLER", "Seite " .. tostring(key) .. ": " .. tostring(err)) end
      if not pg.errShown then pg.errShown = true; ns.Print(TR"Seite Fehler (bitte im Test Log melden): " .. tostring(err)) end
    end
  end
  if zones then return false end
  return true
end

-- 20.1 (Log 12:08, Seite Uebersicht: 2 Texte abgeschnitten): Text so weit kuerzen, dass er passt (an Komma oder
-- Wortgrenze, dann "..."). tail bleibt immer ganz stehen (zb "3/10")
function ns.FitText(fs, text, tail)
  if not (fs and text) then return end
  tail = tail or ""
  fs:SetText(text .. tail)
  if not fs.IsTruncated then return end
  -- noch ohne Breite (Fenster gerade gebaut): nicht kuerzen, sonst bliebe nur ein Stummel
  local okW, w = pcall(fs.GetWidth, fs)
  if not (okW and type(w) == "number" and w > 30) then return end
  local n = 0
  while n < 40 do
    local ok, tr = pcall(fs.IsTruncated, fs)
    if not (ok and tr) then return end
    n = n + 1
    local cut = text:match("^(.*)[,%s][^,%s]*$")
    if not cut or #cut < 8 then return end
    text = cut:gsub("[,%s]+$", "")
    fs:SetText(text .. "..." .. tail)
  end
end
