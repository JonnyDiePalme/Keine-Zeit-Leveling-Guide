local ADDON, ns = ...
local TR = ns.TR

-- Route teilen: die optimierte Route (oder Tour) als Text exportieren und wieder laden.
-- Der Text enthaelt nur Daten (keinen Code), fremde Texte koennen also nichts ausfuehren.

local HEAD = "TaurenRoute1"        -- alte Texte (nur noch laden)
local HEAD2 = "ForeverWegweiser2"  -- sprachunabhaengig: Quests, NPCs, Items, Objekte und Karten als Nummern

local function Esc(v)
  return (tostring(v):gsub("[%%;&=\n|]", function(c) return ("%%%02X"):format(c:byte()) end))
end
local function Unesc(v)
  return (v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function EncVal(v)
  local t = type(v)
  if t == "number" then return "n" .. v end
  if t == "boolean" then return v and "b1" or "b0" end
  if t == "string" then return "s" .. Esc(v) end
  if t == "table" then
    -- nur Listen von Nummern (zb NPCs); alles andere bleibt weg
    local parts = {}
    for _, x in ipairs(v) do if type(x) == "number" then table.insert(parts, x) else return nil end end
    if #parts == 0 then return nil end
    return "l" .. table.concat(parts, ",")
  end
end
local function DecVal(s)
  local t, r = s:sub(1, 1), s:sub(2)
  if t == "n" then return tonumber(r) end
  if t == "b" then return r == "1" end
  if t == "s" then return Unesc(r) end
  if t == "l" then
    local out = {}
    for x in r:gmatch("[^,]+") do local n = tonumber(x); if n then table.insert(out, n) end end
    return out
  end
end

-- Felder, die mitgehen. Texte (Quest, NPC, Ziel, Ziel Ort) gehen als Rueckfall mit, beim Laden baut jeder Client
-- sie aus den Nummern in seiner Sprache neu (Questie und Spieldaten)
local KEEP = { "k", "qid", "quest", "who", "obj", "count", "npcs", "npc", "dungeon", "link", "li", "side", "kind", "dest", "from",
  "toMap", "toX", "toY", "toCont", "cross", "toLvl", "lo", "hi", "min", "imap", "ix", "iy", "name", "x", "y", "map",
  -- vorher gefehlt: Buch (sonst wird ein geladener Buch Schritt nie fertig), Lehrer (sonst "Taschen leeren beim Haendler")
  "book", "trainer", "tlvl", "cls", "forName", "recall", "hint", "dung", "grp", "item", "pre", "srcItem", "guess", "radius", "area",
  "buyAt", "books", "ot", "oi", "mob" }

-- Texte vom Addon (Schiff, Zeppelin, Lehrer ...): als deutscher Schluessel, beim Laden wieder uebersetzt
local rev
local function KeyOf(s)
  if type(s) ~= "string" or not ns.EN then return s end
  if not rev then
    rev = {}
    for k, v in pairs(ns.EN_T or {}) do if rev[v] == nil then rev[v] = k end end
  end
  return rev[s] or s
end

-- Questie Zugriff (nil, wenn Questie fehlt: dann bleiben die Texte aus dem Export)
local function DB()
  local QDB = ns.QDBAccess and ns.QDBAccess()
  return QDB
end
local function Get(fn, id, key)
  local QDB = DB()
  if not (QDB and QDB[fn] and id) then return nil end
  local ok, v = pcall(QDB[fn], id, key)
  if ok then return v end
end
local function QN(id) return Get("QueryQuestSingle", id, "name") end
local function NN(id) return Get("QueryNPCSingle", id, "name") end
local function ON(id) return Get("QueryObjectSingle", id, "name") end
local function IN(id) return Get("QueryItemSingle", id, "name") end
local function Base(t)
  if type(t) ~= "string" then return nil end
  local p = t:find(TR" (von ", 1, true)
  return p and t:sub(1, p - 1) or t
end

-- Ziel einer Quest als Nummer: Art (1 Mob, 2 Objekt, 3 Item, 5 Kill Credit) und Stelle in den Questie Zielen
local function ObjIndex(qid, obj)
  local want = Base(obj)
  local objs = want and Get("QueryQuestSingle", qid, "objectives")
  if type(objs) ~= "table" then return nil end
  for i, c in ipairs(objs[1] or {}) do if NN(c[1]) == want then return 1, i end end
  for i, c in ipairs(objs[2] or {}) do if ON(c[1]) == want or c[2] == want then return 2, i end end
  for i, c in ipairs(objs[3] or {}) do if IN(c[1]) == want then return 3, i end end
  for i, c in ipairs(objs[5] or {}) do if c[3] == want or (c[2] and NN(c[2]) == want) then return 5, i end end
end
local function ObjName(qid, ot, oi)
  local objs = Get("QueryQuestSingle", qid, "objectives")
  local c = type(objs) == "table" and objs[ot] and objs[ot][oi]
  if not c then return nil end
  if ot == 1 then return NN(c[1]) end
  if ot == 2 then return ON(c[1]) or c[2] end
  if ot == 3 then return IN(c[1]) end
  if ot == 5 then return c[3] or (c[2] and NN(c[2])) end
end

-- eine Aktion fuer den Export: Nummern dazu, Addon Texte als Schluessel
local function ExportAct(a)
  local e = {}
  for _, k in ipairs(KEEP) do e[k] = a[k] end
  if a.k == "O" and a.qid and a.obj and not a.item then
    local ot, oi = ObjIndex(a.qid, a.obj)
    if ot then e.ot, e.oi = ot, oi end
  end
  -- Texte vom Addon in Schritten ohne Quest (Startpunkt, Bindepunkt, Lehrer ...): als Schluessel
  if not (a.k == "A" or a.k == "O" or a.k == "T") then
    for _, f in ipairs({ "kind", "quest", "who", "dest", "from", "name" }) do e[f] = KeyOf(a[f]) end
  end
  return e
end

-- fremde Texte nur als Text zeigen: keine Bilder, Links oder Tasten Codes, nicht ueberlang (Farben bleiben)
local function Clean(v)
  if type(v) ~= "string" then return v end
  v = v:gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("|K.-|k", "")
  v = v:gsub("|([^cr|n])", "%1"):gsub("|c(%x%x%x%x%x%x%x%x)", "\1%1"):gsub("|c", ""):gsub("\1", "|c")
  if #v > 200 then v = ns.U8Sub(v, 200) end
  return v
end
ns.ShareClean = Clean

-- beim Laden: Namen in der eigenen Sprache aus den Nummern
local function LocalizeAct(a, sameLoc)
  if a.qid and a.qid > 0 and (a.k == "A" or a.k == "O" or a.k == "T") then
    a.quest = QN(a.qid) or a.quest
  end
  if (a.k == "A" or a.k == "T") and a.npc then a.who = NN(a.npc) or a.who end
  if a.k == "O" then
    if a.buyAt and a.npc then a.buyAt = NN(a.npc) or a.buyAt end
    local nm
    if a.item then
      nm = IN(a.item)
      -- Quell Item mit Herkunft ("Kette (von Ferocitas)")
      if nm and a.srcItem and type(a.npcs) == "table" and a.npcs[1] then
        local who = NN(a.npcs[1])
        if who then nm = nm .. TR" (von " .. who .. ")" end
      end
    elseif a.ot and a.oi then
      nm = ObjName(a.qid, a.ot, a.oi)
    elseif type(a.npcs) == "table" and #a.npcs == 1 then
      nm = NN(a.npcs[1])
    end
    if nm then a.obj = nm end
  end
  if not (a.k == "A" or a.k == "O" or a.k == "T") then
    for _, f in ipairs({ "kind", "quest", "who", "dest", "from", "name" }) do if type(a[f]) == "string" then a[f] = TR(a[f]) end end
  end
  -- Haendler, Gasthaus, Ruhestein, Lehrer: Name in deiner Sprache (auch "who", das nimmt der Ziel Knopf)
  if (a.k == "V" or a.k == "B" or a.k == "H" or a.k == "L") and a.npc then
    local nm = NN(a.npc)
    if nm then a.quest = nm; if a.who then a.who = nm end end
  end
  if a.k == "R" then
    if a.link and a.link ~= "fly" and ns.TravelText then
      local kind, from, to = ns.TravelText(a.link, a.side)
      if kind then a.kind, a.from, a.dest, a.quest = kind, from, to, to end
    elseif a.toMap and C_Map and C_Map.GetMapInfo and not sameLoc then
      local info = C_Map.GetMapInfo(a.toMap)
      if info and info.name then a.dest = a.dest or info.name end
    end
  end
  if a.k == "K" and a.book and ns.BOOKS then
    for _, b in ipairs(ns.BOOKS) do
      if b.id == a.book then a.quest, a.name, a.note = b.name, b.name, b.note; break end
    end
  end
  -- Mob Namen einer Grind Pause: mit Nummer in deiner Sprache, sonst bei anderer Sprache allgemein "Mobs"
  if a.k == "G" then
    local nm = a.mob and NN(a.mob)
    if nm then a.obj = nm elseif not sameLoc then a.obj = nil end
  end
  -- Flugmeister: Name aus der Nummer
  if a.k == "F" and a.npc then a.who = NN(a.npc) or a.who end
  for k, v in pairs(a) do if type(v) == "string" then a[k] = Clean(v) end end
  a.ot, a.oi = nil, nil
  return a
end

-- fuer die Gruppen Route: Schritt fuer den Versand (Nummern dazu, Addon Texte als Schluessel) und beim Empfang
-- Namen in der eigenen Sprache. Alle anderen Felder bleiben, wie sie sind.
function ns.WireOutAct(a)
  local e = {}
  for k, v in pairs(a) do e[k] = v end
  local x = ExportAct(a)
  e.ot, e.oi = x.ot, x.oi
  if not (a.k == "A" or a.k == "O" or a.k == "T") then
    for _, f in ipairs({ "kind", "quest", "who", "dest", "from", "name" }) do e[f] = x[f] end
  end
  return e
end
function ns.WireInAct(a, sameLoc)
  local ok = pcall(LocalizeAct, a, sameLoc)
  return a
end

function ns.ExportRoute()
  local opt = ns.db and ns.db.opt
  if not (opt and opt.steps and #opt.steps > 0) then return nil, TR"Keine Route zum Exportieren" end
  -- Farm Routen (Berufe, Gold Mobs, Ruf Mobs) haengen an deiner Sitzung, die lassen sich nicht teilen
  -- Merker der Farm Routen (in beiden Sprachen), aeltere Routen ohne Merker am Titel
  local t = (opt.title or ""):lower()
  if opt.prof or opt.farm or opt.repFarm or t:find("farmen", 1, true) or t:find("farm", 1, true) then
    return nil, TR"Farm Routen (Berufe, Gold Mobs, Ruf Mobs) lassen sich nicht teilen, nur Quest Routen."
  end
  local lines = { table.concat({ HEAD2, Esc(opt.title or TR"Leveling Route"), opt.target or 0, opt.quests or 0, math.floor(opt.sec or 0),
    Esc(ns.LOCALE or "deDE") }, ";") }
  for _, s in ipairs(opt.steps) do
    table.insert(lines, ("S;%d;%.4f;%.4f;%d;%.2f"):format(s.map or 0, s.x or 0, s.y or 0, math.floor(s.t or 0), s.lvl or 0))
    for _, a in ipairs(s.acts) do
      local ea = ExportAct(a)
      local kv = {}
      for _, k in ipairs(KEEP) do
        if ea[k] ~= nil then
          local e = EncVal(ea[k])
          if e then table.insert(kv, k .. "=" .. e) end
        end
      end
      table.insert(lines, "A;" .. table.concat(kv, "&"))
    end
  end
  return table.concat(lines, "\n")
end

-- 19.7 Teil X (Grenzen): eine echte Route hat einige hundert Schritte. Riesige oder kaputte Texte (Troll, Copy Fehler)
-- sollen das Spiel nicht lange anhalten: Text, Schritte und Aktionen begrenzt, Koordinaten nur auf der Karte (0 bis 1.2)
local IMP_TEXT, IMP_STEPS, IMP_ACTS = 2000000, 3000, 300
function ns.ImportRoute(text)
  if type(text) ~= "string" then return false, TR"kein Text" end
  if #text > IMP_TEXT then return false, TR"Der Text ist zu lang für eine Route" end
  local steps, cur, head = {}, nil, nil
  for line in text:gmatch("[^\r\n]+") do
    local tag = line:match("^(%w+)")
    if tag == HEAD or tag == HEAD2 then
      local p = {}
      for x in (line .. ";"):gmatch("(.-);") do table.insert(p, x) end
      head = { title = Unesc(p[2] or ""), target = tonumber(p[3]), quests = tonumber(p[4]), sec = tonumber(p[5]),
        loc = p[6] and Unesc(p[6]) or nil, v2 = tag == HEAD2 }
    elseif tag == "S" then
      local m, x, y, t, l = line:match("^S;(%d+);([%d%.]+);([%d%.]+);(%d+);([%d%.]+)")
      if not m then return false, TR"Schritt kaputt: " .. ns.U8Sub(line, 40) end
      if not (tonumber(x) and tonumber(y) and tonumber(x) <= 1.2 and tonumber(y) <= 1.2) then return false, TR"Schritt kaputt: " .. ns.U8Sub(line, 40) end
      if #steps >= IMP_STEPS then return false, (TR"Zu viele Schritte (höchstens %d)"):format(IMP_STEPS) end
      cur = { map = tonumber(m), x = tonumber(x), y = tonumber(y), t = tonumber(t), lvl = tonumber(l), acts = {} }
      table.insert(steps, cur)
    elseif tag == "A" and cur then
      local a = {}
      for kv in line:sub(3):gmatch("[^&]+") do
        local k, v = kv:match("^(%w+)=(.*)$")
        if k then a[k] = DecVal(v) end
      end
      if type(a.k) ~= "string" then return false, TR"Aktion ohne Art" end
      if #cur.acts >= IMP_ACTS then return false, TR"Schritt kaputt: " .. ns.U8Sub(line, 40) end
      -- Grind Pause: Ziel XP aus dem Ziel Level neu rechnen (XP sind pro Charakter verschieden)
      if a.k == "G" and a.toLvl and ns.xpTotal then
        local lv = math.floor(a.toLvl)
        local base, nxt = ns.xpTotal[lv] or 0, ns.xpTotal[lv + 1] or 0
        a.untilXP = base + (nxt - base) * (a.toLvl - lv)
      end
      table.insert(cur.acts, a)
    end
  end
  if not head then return false, TR"Das ist kein Keine Zeit Leveling Guide Text" end
  if #steps == 0 then return false, TR"Keine Schritte im Text" end
  -- Namen in deiner Sprache (auch alte Texte: Quests, NPCs und Items haben Nummern)
  local same = head.loc ~= nil and head.loc == ns.LOCALE
  for _, st in ipairs(steps) do
    for _, a in ipairs(st.acts) do pcall(LocalizeAct, a, same) end
  end
  -- Titel in der Sprache vom Exporteur: bei fremder Sprache ein eigener Titel
  local title = (same and head.title ~= "") and (head.title .. TR" (geladen)") or TR"Geladene Route"
  ns.OptLoad(steps, { title = title, target = head.target, quests = head.quests, sec = head.sec, loaded = true })
  return true, #steps
end

------------------------------------------------------------
-- Fenster zum Kopieren und Einfuegen
------------------------------------------------------------
local win
local function Window()
  if win then return win end
  local f = CreateFrame("Frame", "TaurenRouteShare", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(520, 340)
  f:SetPoint("CENTER")
  f:SetFrameStrata("FULLSCREEN")
  if ns.Skin then ns.Skin(f, "window") end
  f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f.title = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormal"))
  f.title:SetPoint("TOPLEFT", 12, -10)
  f.hint = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontDisableSmall"))
  f.hint:SetPoint("TOPLEFT", 12, -28); f.hint:SetPoint("RIGHT", -12, 0); f.hint:SetJustifyH("LEFT")
  local sf = CreateFrame("ScrollFrame", "TaurenRouteShareScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 12, -48); sf:SetPoint("BOTTOMRIGHT", -32, 44)
  local eb = CreateFrame("EditBox", nil, sf)
  eb:SetMultiLine(true); eb:SetAutoFocus(false); eb:SetFontObject("ChatFontSmall"); eb:SetWidth(460)
  eb:SetScript("OnEscapePressed", function() f:Hide() end)
  sf:SetScrollChild(eb)
  f.eb = eb
  local function Btn(text, x)
    local b = (ns.T and ns.T.Button(f) or CreateFrame("Button", nil, f, "UIPanelButtonTemplate"))
    b:SetSize(120, 24); b:SetPoint("BOTTOMRIGHT", x, 12); b:SetText(text)
    return b
  end
  f.close = Btn(TR"Schliessen", -12)
  f.close:SetScript("OnClick", function() f:Hide() end)
  f.load = Btn(TR"Laden", -138)
  f.load:SetScript("OnClick", function()
    local ok, info = ns.ImportRoute(eb:GetText())
    if ok then ns.Print((TR"Route geladen: %d Schritte. Der Pfeil folgt ihr jetzt."):format(info)); f:Hide()
    else ns.Print(TR"|cffff5050Laden ging nicht:|r " .. tostring(info)) end
  end)
  win = f
  return f
end

function ns.ShowExport()
  local text, err = ns.ExportRoute()
  if not text then ns.Print(err); return end
  local f = Window()
  f.title:SetText(TR"Route exportieren")
  f.hint:SetText(TR"Text ist markiert: mit Strg+C kopieren und z.B. in Discord einfügen.")
  f.load:Hide()
  f.eb:SetText(text)
  f:Show()
  f.eb:SetFocus(); f.eb:HighlightText()
end

function ns.ShowImport()
  local f = Window()
  f.title:SetText(TR"Route laden")
  f.hint:SetText(TR"Den Text einer exportierten Route hier einfügen (Strg+V) und Laden drücken.")
  f.load:Show()
  f.eb:SetText("")
  f:Show()
  f.eb:SetFocus()
end
