local ADDON, ns = ...
local TR = ns.TR

-- Benutzbare Quest Items als klickbare Knoepfe unter dem Pfeil.
-- Sichere Knoepfe von Blizzard: umbauen nur ausserhalb vom Kampf.

local MAX = 4
local bar, buttons = nil, {}
local pending = false

local function ItemID(link)
  return link and tonumber(link:match("item:(%d+)"))
end

local function Cooldown(btn)
  if not btn.itemID then return end
  local start, dur, enable
  if C_Container and C_Container.GetItemCooldown then
    start, dur, enable = C_Container.GetItemCooldown(btn.itemID)
  elseif ns.Api.GetItemCooldown then
    start, dur, enable = ns.Api.GetItemCooldown(btn.itemID)
  end
  if start and dur and CooldownFrame_Set then CooldownFrame_Set(btn.cd, start, dur, enable) end
end
local function SpellCooldown(btn)
  if not (btn.spellID and ns.Api.GetSpellCooldown) then return end
  local start, dur, enable = ns.Api.GetSpellCooldown(btn.spellID)
  if start and dur and CooldownFrame_Set then CooldownFrame_Set(btn.cd, start, dur, enable) end
end

local function Count(id)
  if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id) end
  if ns.Api.GetItemCount then return ns.Api.GetItemCount(id) end
  return 0
end

local function MakeButton(i)
  local b = CreateFrame("Button", "TaurenRouteQuestItem" .. i, bar, "SecureActionButtonTemplate")
  b:SetSize(32, 32)
  b:RegisterForClicks("AnyUp", "AnyDown")
  b:SetAttribute("type", "item")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints()
  b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.border = b:CreateTexture(nil, "BACKGROUND")
  b.border:SetPoint("TOPLEFT", -1, 1)
  b.border:SetPoint("BOTTOMRIGHT", 1, -1)
  b.border:SetColorTexture(0, 0, 0, 1)
  b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.count:SetPoint("BOTTOMRIGHT", -1, 1)
  -- 19.31 (Sascha: wann den Ruhestein benutzen?): beim Ruhestein steht darunter "jetzt klicken"
  b.lbl = b:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontNormalSmall"))
  b.lbl:SetPoint("TOP", b, "BOTTOM", 0, -2)
  b.cd = CreateFrame("Cooldown", nil, b, "CooldownFrameTemplate")
  b.cd:SetAllPoints()
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.25)
  b:SetScript("OnEnter", function(self)
    if not (self.link or self.spellID) then return end
    ns.TipOwner(self, "ANCHOR_RIGHT")
    if self.spellID and GameTooltip.SetSpellByID then GameTooltip:SetSpellByID(self.spellID)
    elseif self.link then GameTooltip:SetHyperlink(self.link) end
    if self.quest then GameTooltip:AddLine(self.hearth and self.quest or (TR"Für: " .. self.quest), 1, 0.82, 0) end
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  buttons[i] = b
  return b
end

-- Ruhestein oder Astraler Rueckruf: nur wenn die Route jetzt genau das will
local HEARTH, RECALL = 6948, 556
local function HearthWanted()
  -- 19.33 (Navi Chat 6e/6f, Saschas Ja f20): Ruhestein, Astraler Rueckruf oder Magier Teleport fuer das Navi zuerst.
  -- Die Navi keys heissen NH, NR, NP<Zauber>, die der Route H und R. nil, wenn das Navi gerade nichts will
  local n = ns.NaviHearthWanted and ns.NaviHearthWanted()
  if n then return n end
  local a = ns.db and ns.db.optMode and ns.OptCurrentAct and ns.OptCurrentAct()
  -- 20.3o (Log 20.3m M4, S 22:57 "Button fuer Teleport fehlt"): Reise Schritt Teleport (Magier, Travel.lua) als Knopf
  if a and a.k == "R" and a.link == "tele" and a.spell and ((IsPlayerSpell and IsPlayerSpell(a.spell)) or (IsSpellKnown and IsSpellKnown(a.spell))) then
    local icon = (ns.Api.GetSpellTexture and ns.Api.GetSpellTexture(a.spell)) or "Interface\\Icons\\Spell_Arcane_TeleportOrgrimmar"
    return { spell = a.spell, icon = icon, quest = TR"Teleport nach " .. tostring(a.dest or "?"), hearth = true, key = "P" .. a.spell }
  end
  if not (a and a.k == "H") then return nil end
  local where = TR"Zurück nach " .. tostring(a.quest or TR"Gasthaus")
  if a.recall and IsSpellKnown and IsSpellKnown(RECALL) then
    return { spell = RECALL, icon = "Interface\\Icons\\Spell_Nature_AstralRecall", quest = where, hearth = true, key = "R" }
  end
  if Count(HEARTH) > 0 then
    return { id = HEARTH, link = "item:" .. HEARTH, icon = (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(HEARTH)) or "Interface\\Icons\\INV_Misc_Rune_01",
      quest = where, hearth = true, key = "H" }
  end
end
ns.HearthWanted = HearthWanted

-- Items der Quests: zuerst aktuelle Zone, dann der Rest (davor der Ruhestein, wenn die Route ihn jetzt will)
local function Collect()
  local list = {}
  local h = HearthWanted()
  if h then table.insert(list, h) end
  local mapID = ns.PlayerMap()
  local zname = mapID and ns.ZoneName(mapID)
  local seen = {}
  -- feste Reihenfolge (nach Quest ID), sonst tauschen die Knoepfe beim Neuaufbau die Plaetze
  local qs = {}
  -- 1.1 (S Log L14.3 "Quest Items zum Benutzen nur zeigen, wenn die Quest gerade gemacht wird"): mit Route nur Quests aus
  -- dem aktuellen Schritt (und dem Buendel an derselben Stelle, Quest.lua StepWindowQuests). Ohne Route wie bisher alle
  local cur = ns.StepWindowQuests and ns.StepWindowQuests()
  for qid, q in pairs(ns.logProgress or {}) do
    if not cur or cur[qid] then qs[#qs + 1] = { qid, q } end
  end
  table.sort(qs, function(a, b) return a[1] < b[1] end)
  for pass = 1, 2 do
    for _, e in ipairs(qs) do
      local q = e[2]
      local here = (q.zone == zname)
      if q.itemLink and not q.complete and ((pass == 1) == here) then
        local id = ItemID(q.itemLink)
        if id and not seen[id] and Count(id) > 0 then
          seen[id] = true
          table.insert(list, { link = q.itemLink, icon = q.itemIcon, id = id, quest = q.title })
        end
      end
    end
  end
  return list
end

-- Leiste unter den Pfeil setzen, ohne sie daran zu haengen
local updSoon = false
local function Place()
  local a = _G.TaurenRouteArrow
  bar:ClearAllPoints()
  local x, y = a and a:GetCenter(), a and a:GetBottom()
  if x and y and a:IsShown() then
    -- Pfeil kann groesser oder kleiner sein: in die Masse vom UIParent umrechnen
    local k = a:GetEffectiveScale() / UIParent:GetEffectiveScale()
    bar:SetPoint("TOP", UIParent, "BOTTOMLEFT", x * k, y * k - 4)
  else
    bar:SetPoint("TOP", UIParent, "TOP", 0, -260)
  end
end

local function Update()
  if not bar then return end
  if InCombatLockdown() then pending = true; return end
  pending = false
  Place()
  local list = (ns.db and ns.db.questItems ~= false and not ns.db.paused) and Collect() or {}
  -- 19.31: der Ruhestein Knopf kommt auch, wenn die Quest Item Knoepfe aus sind (die Route braucht ihn jetzt)
  if #list == 0 and ns.db and not ns.db.paused then local h = HearthWanted(); if h then list[1] = h end end
  for i = 1, MAX do
    local it = list[i]
    local b = buttons[i] or MakeButton(i)
    ns.Api.Mark("Questitem Knopf")
    b:ClearAllPoints()
    b:SetPoint("LEFT", bar, "LEFT", (i - 1) * 36, 0)
    if it and it.spell then
      b:SetAttribute("type", "spell")
      b:SetAttribute("spell", it.spell)
      b:SetAttribute("item", nil)
      b.icon:SetTexture(it.icon)
      b.link, b.itemID, b.spellID, b.quest, b.hearth = nil, nil, it.spell, it.quest, true
      b.count:SetText("")
      b.lbl:SetText(TR"jetzt klicken")
      SpellCooldown(b)
      b:Show()
    elseif it then
      b:SetAttribute("type", "item")
      b:SetAttribute("spell", nil)
      b:SetAttribute("item", "item:" .. it.id)
      b.icon:SetTexture(it.icon or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(it.id)))
      b.link, b.itemID, b.spellID, b.quest, b.hearth = it.link, it.id, nil, it.quest, it.hearth
      local n = Count(it.id)
      b.count:SetText((n > 1 and not it.hearth) and n or "")
      b.lbl:SetText(it.hearth and TR"jetzt klicken" or "")
      Cooldown(b)
      b:Show()
    else
      b:SetAttribute("item", nil)
      b:SetAttribute("spell", nil)
      b.link, b.itemID, b.spellID, b.quest, b.hearth = nil, nil, nil, nil, nil
      b.lbl:SetText("")
      b:Hide()
    end
  end
  bar:SetWidth(math.max(1, math.min(#list, MAX) * 36))
end

function ns.InitQuestItems()
  if ns.db.questItems == nil then ns.db.questItems = true end
  bar = CreateFrame("Frame", "TaurenRouteQuestItemBar", UIParent)
  bar:SetSize(36, 32)
  ns.RefreshItemBar = function() C_Timer.After(0, Update) end
  local f = CreateFrame("Frame")
  ns.RegEv(f, "QUEST_LOG_UPDATE")
  ns.RegEv(f, "BAG_UPDATE_DELAYED")
  ns.RegEv(f, "ZONE_CHANGED_NEW_AREA")
  ns.RegEv(f, "PLAYER_REGEN_ENABLED")
  ns.RegEv(f, "BAG_UPDATE_COOLDOWN")
  ns.RegEv(f, "SPELL_UPDATE_COOLDOWN")
  f:SetScript("OnEvent", function(_, event)
    if event == "BAG_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" then
      for _, b in ipairs(buttons) do if b:IsShown() then Cooldown(b); SpellCooldown(b) end end
      return
    end
    if event == "PLAYER_REGEN_ENABLED" and not pending then return end
    -- viele Events hintereinander: nur einmal aufbauen
    if updSoon then return end
    updSoon = true
    C_Timer.After(0.3, function() updSoon = false; Update() end)
  end)
  C_Timer.After(3, Update)
  -- Ruhestein Knopf: auftauchen und verschwinden, sobald die Route ihn will oder nicht mehr
  local lastWant, lastStep
  ns.Ticker(1, function()
    local h = HearthWanted()
    local k = h and h.key or false
    -- 1.1: neuer Schritt, dann passen die Quest Items vielleicht nicht mehr
    local o = ns.db and ns.db.opt
    local st = o and o.steps and o.steps[o.idx or 1]
    if k ~= lastWant or st ~= lastStep then lastWant, lastStep = k, st; Update() end
  end)
end

function ns.ToggleQuestItems()
  ns.db.questItems = not ns.db.questItems
  ns.Print(ns.db.questItems and TR"Quest Item Knöpfe an" or TR"Quest Item Knöpfe aus")
  Update()
end
