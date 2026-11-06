local ADDON, ns = ...
local TR = ns.TR

-- Ein Hinweis im Mini Fenster, immer nur der wichtigste:
-- 1 Gruppe (Abstecher)  2 Ruhestein aufheben  3 Taschen oder Reparieren  4 Lehrer
-- 5 Questlog aufraeumen  6 Buecher abgeben  6c Schlafsack bereit  7 Rest (Flugpunkt, Ruhestein setzen)
-- Im Kampf wird nichts gezeigt.

local BOOK_TIERS = {
  { n = 10, lvl = 1, item = TR"Halskette (Scholarly Pendant oder Erudite's Amulet)" },
  { n = 20, lvl = 20, item = TR"Ring (Field Researcher's Loop oder Philanthropist's Ring)" },
  { n = 25, lvl = 30, item = TR"Bogen, Schild oder Nebenhand (Truthseeker's Bow, Crest of Elucidation, Researcher's Night Light)" },
}

local function LogCount()
  if not GetNumQuestLogEntries then return 0 end
  local _, n = GetNumQuestLogEntries()
  return type(n) == "number" and n or 0
end

local function HearthSoon()
  local db = ns.db
  local opt = db and db.optMode and db.opt
  if not (opt and opt.steps) then return nil end
  local i0 = opt.idx or 1
  for i = i0 + 1, math.min(#opt.steps, i0 + 4) do
    for _, a in ipairs(opt.steps[i].acts or {}) do
      if a.k == "H" then return a end
    end
  end
end

local function BookHint()
  local db = ns.db
  if not (db and ns.BookCount and ns.BOOK_TURNIN and ns.Unlocked and ns.Unlocked("books")) then return nil end
  local n = ns.BookCount()
  local L = UnitLevel("player") or 1
  db.bookTierDone = db.bookTierDone or {}
  for _, t in ipairs(BOOK_TIERS) do
    if n >= t.n and L >= t.lvl and not db.bookTierDone[t.n] then
      local ti = ns.BOOK_TURNIN[UnitFactionGroup("player")]
      if ti then return t, ti end
    end
  end
end

local logCache = { t = 0 }
-- Alle Hinweise in der Reihenfolge der Wichtigkeit (fuer das Hinweis Fenster)
-- Hinweis "Neu rechnen?": statt von selbst neu zu rechnen (weit weg, Tod weit weg, anderer Kontinent,
-- viele fremde Quests im Log). Der Pfeil fuehrt weiter zur Route. Wegklicken oder zurueck zur Route
-- (in der Naehe vom Schritt) laesst ihn verschwinden.
local ask
function ns.RecalcAsk(reason, text)
  local db = ns.db
  if not db then return end
  local o = db.opt
  local st = o and o.steps and o.steps[o.idx or 1]
  if ask and ask.reason == reason then return end
  ask = { reason = reason, text = text, at = GetTime and GetTime() or 0, idx = o and o.idx, opt = o, map = st and st.map, x = st and st.x, y = st and st.y }
  ns.Print(text .. TR" Der Pfeil führt dich zurück zur Route. Im Mini Fenster kannst du neu rechnen lassen.")
  if ns.TestLog then ns.TestLog("RECHNEN", "Hinweis Neu rechnen? (" .. tostring(reason) .. ")") end
  if ns.NoticeUpdate then pcall(ns.NoticeUpdate) end
  if ns.RefreshHud then pcall(ns.RefreshHud) end
end
function ns.RecalcAskClear() ask = nil; if ns.NoticeUpdate then pcall(ns.NoticeUpdate) end end
function ns.RecalcAskActive() return ask end
local function AskStillValid()
  if not ask then return false end
  local db = ns.db
  local o = db and db.opt
  -- Route inzwischen anders (neu gerechnet, Profil gewechselt) oder Schritt geschafft: weg
  if not o or o ~= ask.opt or (o.idx or 1) ~= ask.idx then ask = nil; return false end
  -- wieder nah am Schritt: weg
  local map = ns.PlayerMap and ns.PlayerMap()
  local pos = map and C_Map.GetPlayerMapPosition(map, "player")
  if pos and ask.map and ns.WorldDist then
    local px, py = pos:GetXY()
    local d = ns.WorldDist({ map, px, py }, { ask.map, ask.x, ask.y })
    if d and d < 400 then ask = nil; return false end
  end
  return true
end

function ns.HintList()
  local out = {}
  local db = ns.db
  if not db then return out end
  if AskStillValid() then
    table.insert(out, { kind = "recalc", key = "recalc_" .. tostring(ask.at), text = ask.text .. TR" Neu rechnen?", go = TR"Neu rechnen",
      tip = TR"Klick: ab hier neu rechnen. X: nein, der Pfeil führt zurück zur Route.",
      onClick = function()
        local r = ask and ask.reason
        ask = nil
        if ns.TestLog then ns.TestLog("RECHNEN", "Hinweis Neu rechnen angenommen (" .. tostring(r) .. ")") end
        if ns.AutoOpt then ns.AutoOpt(true) end
      end })
  end
  -- auch im Kampf (Wunsch aus dem Test: Taschen leeren und Klassenlehrer sollen nicht verschwinden)
  local function Add(h) if h then table.insert(out, h) end end
  -- 0 Route noch nicht berechnet (Einrichtung mit "Später"): erst auf Knopfdruck
  if ns.CalcHold and ns.CalcHold() and db.setupDone and not ns.setupOpen then
    Add({ kind = "calc", text = TR"Route noch nicht berechnet", go = TR"Berechnen",
      tip = TR"Klick: jetzt berechnen. Das Spiel kann kurz ruckeln, das hört von selbst auf.",
      onClick = function() if ns.CalcGo then ns.CalcGo() end end })
  end
  -- 20.3z (K 17:12, P13): auf Max Level ohne laufende Route ein Link zu "Nach 60: alle offenen Quests"
  do
    local o = db.opt
    local running = o and o.steps and (o.idx or 1) <= #o.steps
    local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    if not running and (UnitLevel("player") or 1) >= maxL and not ns.navi and not (ns.OptBusy and ns.OptBusy()) then
      Add({ kind = "rest60", key = "rest60", text = TR"Max Level: alle offenen Quests nachholen?", go = TR"Los",
        tip = TR"Klick: Route mit allen Quests, die du noch machen kannst (wie Planen, Nach 60). X: ausblenden.",
        onClick = function() if ns.RestQuestsRoute then ns.RestQuestsRoute() end end })
    end
  end
  -- 1 Gruppe
  if ns.GroupHint then Add(ns.GroupHint()) end
  -- 2 Ruhestein fuer einen Schritt gleich aufheben
  local h = not (db.svcSnooze and db.svcSnooze.hearthSave and time() < db.svcSnooze.hearthSave) and HearthSoon()
  if h then
    local ready = true
    if not h.recall and ns.Api.GetItemCooldown then local _, dur = ns.Api.GetItemCooldown(6948); ready = not dur or dur == 0 end
    if ready then
      -- 19.31 (Sascha: "aufheben" las sich wie "jetzt benutzen", er hat ihn zu frueh benutzt)
      Add({ kind = "hearth", text = (TR"%s noch nicht benutzen, kommt gleich dran"):format(h.recall and TR"Astraler Rückruf" or TR"Ruhestein"),
        tip = TR"Die Route braucht ihn in ein paar Schritten, dann kommt beim Pfeil ein Knopf. Vorher nicht benutzen, sonst ist er nicht bereit." })
    end
  end
  -- 3 und 4: Taschen, Reparieren, Lehrer (aus den Service Hinweisen)
  local svc = ns.svcHints or (ns.svcHint and { ns.svcHint }) or {}
  local rest = {}
  for _, sh in ipairs(svc) do
    if sh.kind == "vendor" or sh.kind == "repair" or sh.kind == "trainer" then Add(sh) else table.insert(rest, sh) end
  end
  -- 5 Questlog: ab 20 Quests, oder kurz nachdem die Spielweise geaendert wurde
  local recent = db.stepChanged and time() - db.stepChanged < 180
  if (LogCount() >= 20 or recent) and ns.LogCleanup and not (db.svcSnooze and db.svcSnooze.log and time() < db.svcSnooze.log) then
    -- geht ueber den ganzen Fahrplan: hoechstens alle 5 Sekunden neu
    local now = GetTime()
    if not logCache.v or now - logCache.t > 5 then logCache.v, logCache.t = ns.LogCleanup(), now end
    local list = logCache.v
    if #list > 0 then
      local names = {}
      for i, q in ipairs(list) do if i <= 8 then table.insert(names, q.title) end end
      Add({ kind = "log", text = (TR"%d Quests im Log lohnen sich nicht. Klick: aufräumen"):format(#list),
        tip = table.concat(names, "\n") .. (#list > 8 and (TR"\n... und %d mehr"):format(#list - 8) or ""),
        onClick = function() if ns.ShowLogCleanup then ns.ShowLogCleanup() end end })
    end
  end
  -- 6 Buecher abgeben
  local t, ti = BookHint()
  if t then
    Add({ kind = "books", text = (TR"%d Bücher dabei, Belohnung wartet bei %s"):format(t.n, (ti.name or "?"):match("^[^(]+") or "?"),
      tip = TR"Zur Auswahl: " .. t.item .. TR"\nKlick: Pfeil dorthin.",
      target = { map = ti.map, x = ti.x, y = ti.y, name = TR"Bücher abgeben: " .. (ti.name or "?"), kind = "books" }, tier = t.n })
  end
  -- 6b Dungeon Quests dabei: "Fuer Kloster hast du 4 von 6 Quests"
  if ns.dungeons and ns.QuestStatus and not (db.svcSnooze and db.svcSnooze.dq and time() < db.svcSnooze.dq) then
    local L = UnitLevel("player") or 1
    local best
    for _, d in ipairs(ns.dungeons) do
      if d.min and d.max and L >= d.min - 2 and L <= d.max then
        local have, open = 0, 0
        for _, qid in ipairs(d.quests or {}) do
          local st = ns.QuestStatus(qid)
          if st == "log" then have = have + 1; open = open + 1 elseif st ~= "done" then open = open + 1 end
        end
        if have >= 2 and (not best or have > best.have) then best = { d = d, have = have, open = open } end
      end
    end
    if best then
      Add({ kind = "dq", text = (TR"Für %s hast du %d von %d Quests"):format(best.d.name or "?", best.have, best.open),
        tip = TR"Klick: Dungeon Seite mit den fehlenden Quests und dem Weg zum Eingang.",
        onClick = function() if ns.ShowBig then ns.ShowBig("dungeons") end; local pg = ns.BigPage and ns.BigPage("dungeons"); if pg and pg.Open then pg.Open(best.d) end end })
    end
  end
  -- 6c Schlafsack (Forever, 17.5): Buff abgelaufen und Schlafsack wieder bereit. Nicht im Kampf, nicht auf Level 60.
  -- Am besten beim naechsten Essen oder Trinken hinlegen, dann kostet das Liegen keine Zeit.
  local maxL = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
  if (UnitLevel("player") or 1) < maxL and not (UnitAffectingCombat and ns.Api.U(UnitAffectingCombat, "player"))
    and not (UnitOnTaxi and ns.Api.U(UnitOnTaxi, "player"))
    and not (db.svcSnooze and db.svcSnooze.bag and time() < db.svcSnooze.bag)
    and ns.SleepingBagReady and ns.SleepingBagReady() then
    Add({ kind = "bag", text = TR"Schlafsack bereit: beim nächsten Essen oder Trinken hinlegen",
      tip = TR"3 Minuten liegen gibt bis +3 % XP. Essen und Trinken geht dabei weiter, kostet also keine Zeit. X: eine Stunde Ruhe.",
      onClick = function() ns.Print(TR"Schlafsack aus der Tasche benutzen und 3 Minuten liegen bleiben (1 Stapel pro Minute).") end })
  end
  -- 7 Rest (Flugpunkt, Ruhestein setzen)
  for _, sh in ipairs(rest) do Add(sh) end
  return out
end

-- nur der wichtigste
function ns.TopHint()
  return ns.HintList()[1]
end

-- Klick auf den Hinweis
function ns.HintClick(h)
  if not h then return end
  if h.onClick then h.onClick(); return end
  if h.target then
    local kind = h.target.kind or h.kind
    if ns.serviceTarget and ns.serviceTarget.kind == kind then ns.serviceTarget = nil
    else
      local t = {}
      for k2, v in pairs(h.target) do t[k2] = v end
      t.kind = kind
      ns.serviceTarget = t
      ns.Print(TR"Pfeil zeigt jetzt zu: " .. (t.name or "?"))
    end
    if ns.Draw then ns.Draw() end
    return
  end
  if ns.ToggleServiceTarget then ns.ToggleServiceTarget() end
end

-- X am Hinweis
function ns.HintDismiss(h)
  local db = ns.db
  if not (h and db) then return end
  db.svcSnooze = db.svcSnooze or {}
  if h.kind == "recalc" then ask = nil; if ns.TestLog then ns.TestLog("RECHNEN", "Hinweis Neu rechnen weggeklickt") end
  elseif h.kind == "group" then if ns.GroupHintDismiss then ns.GroupHintDismiss(h) end
  elseif h.kind == "log" then db.svcSnooze.log = time() + 1800; db.stepChanged = nil
  elseif h.kind == "books" then db.bookTierDone = db.bookTierDone or {}; db.bookTierDone[h.tier] = true
  elseif h.kind == "hearth" then db.svcSnooze.hearthSave = time() + 900
  elseif h.kind == "dq" then db.svcSnooze.dq = time() + 3600
  elseif h.kind == "bag" then db.svcSnooze.bag = time() + 3600
  elseif ns.DismissSvcHint then ns.DismissSvcHint(h) end
end

-- Buecher erst bei der echten Abgabe zaehlen: eine Quest abgegeben, waehrend du beim Bibliothekar stehst
do
  local bf = CreateFrame("Frame")
  bf:RegisterEvent("QUEST_TURNED_IN")
  bf:SetScript("OnEvent", function(_, _, qid, xp)
    local db = ns.db
    if not (db and ns.BOOK_TURNIN and ns.WorldDist and ns.PlayerMap) then return end
    local ti = ns.BOOK_TURNIN[UnitFactionGroup("player")]
    local map = ns.PlayerMap()
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not (ti and pos) then return end
    local px, py = pos:GetXY()
    local d = ns.WorldDist({ map, px, py }, { ti.map, ti.x, ti.y })
    if not (d and d < 40) then return end
    db.bookMeasure = nil -- alte Messung (vor 12.5) weg
    local have = ns.BookCount and ns.BookCount() or 0
    local turned = db.booksTurned or 0
    if have > turned then
      turned = turned + 1
      db.booksTurned = turned
      -- XP pro Buch aus der Abgabe selbst
      xp = ns.Plain and ns.Plain(xp) or xp
      if type(xp) == "number" and xp > 0 then db.bookXP = db.bookXP and math.floor(db.bookXP * 0.5 + xp * 0.5) or xp end
    end
    -- Belohnungsstufe gilt erst als abgeholt, wenn so viele Buecher wirklich abgegeben sind
    db.bookTierDone = db.bookTierDone or {}
    for _, t in ipairs(BOOK_TIERS) do
      if turned >= t.n then db.bookTierDone[t.n] = true end
    end
    if turned >= have and ns.serviceTarget and ns.serviceTarget.kind == "books" then ns.serviceTarget = nil end
    if ns.RefreshHud then ns.RefreshHud() end
  end)
end
