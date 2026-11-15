local ADDON, ns = ...
local TR = ns.TR

-- Geld nach Quelle: Quests, Beute, Verkaeufe, Fluege, Reparatur, Lehrer, Einkaeufe ...
-- Pro Level, pro Zone und gesamt. Die Quelle ergibt sich aus dem, was gerade offen ist.

local last
local open = {}        -- merchant, taxi, trainer, loot, mail, auction, trade
local recent = {}      -- kurz nach einem Ereignis: [quelle] = Zeit
local repairing = false

ns.MONEY_NAMES = {
  quest = TR"Quest Belohnungen", loot = TR"Beute von Mobs", sell = TR"Verkauf beim Händler",
  flight = TR"Flüge", repair = TR"Reparatur", train = TR"Lehrer", buy = TR"Einkäufe beim Händler",
  mail = TR"Post", auction = TR"Auktionshaus", trade = TR"Handel", other = TR"Sonstiges",
}

local function Source(diff)
  local now = GetTime()
  local function Recent(k, s) return recent[k] and now - recent[k] < (s or 2) end
  -- nur Geld rein ist Quest Belohnung (Quests, die Gold kosten, sind eine Ausgabe)
  if Recent("quest") and diff > 0 then return "quest" end
  if open.taxi or Recent("taxi", 3) then if diff < 0 then return "flight" end end
  if open.trainer then if diff < 0 then return "train" end end
  if open.merchant then
    if diff > 0 then return "sell" end
    if repairing or Recent("repair") then return "repair" end
    return "buy"
  end
  if open.loot or Recent("loot") then return "loot" end
  if open.mail then return "mail" end
  if open.auction then return "auction" end
  if open.trade then return "trade" end
  return "other"
end

local function OnMoney()
  if not (ns.db and ns.StatBump) then return end
  local m = ns.Plain and ns.Plain(GetMoney()) or nil
  if not m then return end
  if not last then last = m; return end
  local diff = m - last
  last = m
  if diff == 0 then return end
  local src = Source(diff)
  if diff > 0 then ns.StatBump("moneyIn", src, diff) else ns.StatBump("moneyOut", src, -diff) end
  if src == "flight" then ns.StatBump("cnt", "flight") end
  if src == "repair" then ns.StatBump("cnt", "repair") end
end

if hooksecurefunc then
  pcall(hooksecurefunc, "RepairAllItems", function() recent.repair = GetTime() end)
end

local f = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_MONEY", "MERCHANT_SHOW", "MERCHANT_CLOSED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED",
  "TRAINER_SHOW", "TRAINER_CLOSED", "LOOT_OPENED", "LOOT_CLOSED", "MAIL_SHOW", "MAIL_CLOSED", "AUCTION_HOUSE_SHOW",
  "AUCTION_HOUSE_CLOSED", "TRADE_SHOW", "TRADE_CLOSED", "QUEST_TURNED_IN", "QUEST_COMPLETE", "CHAT_MSG_MONEY" }) do
  pcall(f.RegisterEvent, f, e)
end
f:SetScript("OnEvent", function(_, e)
  local now = GetTime()
  if e == "PLAYER_LOGIN" then last = ns.Plain and ns.Plain(GetMoney()) or nil
  elseif e == "PLAYER_MONEY" then OnMoney()
  elseif e == "MERCHANT_SHOW" then open.merchant = true
  elseif e == "MERCHANT_CLOSED" then open.merchant = false
  elseif e == "TAXIMAP_OPENED" then open.taxi = true
  elseif e == "TAXIMAP_CLOSED" then open.taxi = false; recent.taxi = now
  elseif e == "TRAINER_SHOW" then open.trainer = true
  elseif e == "TRAINER_CLOSED" then open.trainer = false
  elseif e == "LOOT_OPENED" then open.loot = true
  elseif e == "LOOT_CLOSED" then open.loot = false; recent.loot = now
  elseif e == "CHAT_MSG_MONEY" then recent.loot = now
  elseif e == "MAIL_SHOW" then open.mail = true
  elseif e == "MAIL_CLOSED" then open.mail = false
  elseif e == "AUCTION_HOUSE_SHOW" then open.auction = true
  elseif e == "AUCTION_HOUSE_CLOSED" then open.auction = false
  elseif e == "TRADE_SHOW" then open.trade = true
  elseif e == "TRADE_CLOSED" then open.trade = false
  elseif e == "QUEST_TURNED_IN" or e == "QUEST_COMPLETE" then recent.quest = now
  end
end)

------------------------------------------------------------
-- Texte fuer die Detail Seite
------------------------------------------------------------
local function Clock(t) return ns.Clock and ns.Clock(t or 0) or tostring(t) end
local function Num(n) n = math.floor(n or 0); local s = tostring(n):reverse():gsub("(%d%d%d)", "%1'"):reverse(); return (s:gsub("^'", "")) end
local function Money(c) return ns.Money and ns.Money(c or 0) or tostring(c) end

-- e: Eintrag (Level, Zone oder gesamt) mit t, xp, cnt, src, split, moneyIn, moneyOut
-- 1.4n (P161 soll2): zweite Rueckgabe mk fuer die Statistik Seite, damit dort kleine Diagramme neben den Abschnitten
-- und das Gold in Spalten stehen. mk.src/cnt/split = Zeile der Ueberschrift mit Teilen {name, v, col},
-- mk.gold = { line = erste Zeile, rows = { {v, name, plus} } } (die Gold Zeilen sind dann Platzhalter)
ns.DETAIL_COL = {
  quest = { 1, 0.6, 0.1 }, kill = { 0.9, 0.25, 0.25 }, explore = { 0.4, 0.7, 1 },
  death = { 0.55, 0.55, 0.55 }, flight = { 0.4, 0.9, 0.5 }, repair = { 0.8, 0.6, 0.3 },
  fight = { 0.9, 0.25, 0.25 }, walk = { 0.3, 0.75, 1 }, fly = { 0.4, 0.9, 0.5 }, dead = { 0.55, 0.55, 0.55 }, idle = { 1, 0.8, 0.2 },
}
function ns.DetailLines(e, title)
  local out = { "|cffffd100" .. title .. "|r", "" }
  local mk = {}
  if not e then table.insert(out, TR"Noch keine Daten."); return out, mk end
  local C = ns.DETAIL_COL
  local t = e.t or e.total or 0
  local c = e.cnt or {}
  table.insert(out, TR"|cffffd100Zeit und XP|r")
  local src = e.src or {}
  local sum = (src.quest or 0) + (src.kill or 0) + (src.explore or 0)
  if sum > 0 then
    mk.src = { line = #out, parts = { { name = TR"Quests", v = src.quest or 0, col = C.quest }, { name = TR"Kills", v = src.kill or 0, col = C.kill }, { name = TR"Entdecken", v = src.explore or 0, col = C.explore } } }
  end
  table.insert(out, (TR"   Spielzeit: %s"):format(Clock(t)))
  table.insert(out, (TR"   XP: %s, also %s pro Stunde"):format(Num(e.xp), t > 60 and Num((e.xp or 0) / t * 3600) or "?"))
  if sum > 0 then
    table.insert(out, (TR"   Woher: Quests %d%%, Kills %d%%, Entdecken %d%%"):format(
      math.floor((src.quest or 0) / sum * 100 + 0.5), math.floor((src.kill or 0) / sum * 100 + 0.5), math.floor((src.explore or 0) / sum * 100 + 0.5)))
  end
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Zähler|r")
  local cs = (c.kill or 0) + (c.quest or 0) + (c.death or 0) + (c.explore or 0) + (c.flight or 0) + (c.repair or 0)
  if cs > 0 then
    mk.cnt = { line = #out, parts = { { name = TR"Kills", v = c.kill or 0, col = C.kill }, { name = TR"Quests", v = c.quest or 0, col = C.quest }, { name = TR"Tode", v = c.death or 0, col = C.death },
      { name = TR"Entdeckt", v = c.explore or 0, col = C.explore }, { name = TR"Flüge", v = c.flight or 0, col = C.flight }, { name = TR"Reparaturen", v = c.repair or 0, col = C.repair } } }
  end
  table.insert(out, (TR"   Kills %d, Quests %d, Tode %d, Entdeckt %d, Flüge %d, Reparaturen %d"):format(
    c.kill or 0, c.quest or 0, c.death or 0, c.explore or 0, c.flight or 0, c.repair or 0))
  if t > 300 then
    table.insert(out, (TR"   Pro Stunde: %.0f Kills, %.1f Quests"):format((c.kill or 0) / t * 3600, (c.quest or 0) / t * 3600))
  end
  local sp = e.split or {}
  local st = (sp.fight or 0) + (sp.walk or 0) + (sp.fly or 0) + (sp.dead or 0) + (sp.idle or 0)
  if st > 0 then
    table.insert(out, "")
    table.insert(out, TR"|cffffd100Wofür die Zeit drauf ging|r")
    mk.split = { line = #out, parts = { { name = TR"Kampf", v = sp.fight or 0, col = C.fight }, { name = TR"Laufen", v = sp.walk or 0, col = C.walk }, { name = TR"Fliegen", v = sp.fly or 0, col = C.fly },
      { name = TR"Tot", v = sp.dead or 0, col = C.dead }, { name = TR"Stillstand", v = sp.idle or 0, col = C.idle } } }
    local function P(k) return math.floor((sp[k] or 0) / st * 100 + 0.5) end
    table.insert(out, (TR"   Kampf %d%%, Laufen %d%%, Fliegen %d%%, Tot %d%%, Stillstand %d%%"):format(P("fight"), P("walk"), P("fly"), P("dead"), P("idle")))
    table.insert(out, "")   -- Platz fuer die Legende des kleinen Diagramms
  end
  table.insert(out, "")
  table.insert(out, TR"|cffffd100Gold|r")
  local inn, outt = e.moneyIn or {}, e.moneyOut or {}
  local tin, tout = 0, 0
  local rows = {}
  local order = { "quest", "loot", "sell", "mail", "auction", "trade", "other" }
  for _, k in ipairs(order) do
    if (inn[k] or 0) > 0 then rows[#rows + 1] = { v = inn[k], name = ns.MONEY_NAMES[k], plus = true }; tin = tin + inn[k] end
  end
  for _, k in ipairs({ "flight", "repair", "train", "buy", "mail", "auction", "trade", "other" }) do
    if (outt[k] or 0) > 0 then rows[#rows + 1] = { v = outt[k], name = ns.MONEY_NAMES[k] }; tout = tout + outt[k] end
  end
  if tin == 0 and tout == 0 then table.insert(out, TR"   noch nichts erfasst")
  else
    -- Platzhalter: der Text steht als Zeile da (fuer Tests und ohne Fenster), die Seite legt die Spalten darueber
    mk.gold = { line = #out + 1, rows = rows }
    for _, r in ipairs(rows) do
      table.insert(out, r.plus and ("   |cff40ff40+ %s|r  %s"):format(Money(r.v), r.name) or ("   |cffff5050- %s|r  %s"):format(Money(r.v), r.name))
    end
  end
  local net = tin - tout
  table.insert(out, (TR"   Saldo: %s%s|r%s"):format(net >= 0 and "|cff40ff40+" or "|cffff5050-", Money(math.abs(net)),
    t > 300 and ("  (" .. Money(math.abs(net) / t * 3600) .. TR" pro Stunde)") or ""))
  return out, mk
end
