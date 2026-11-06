local ADDON, ns = ...
local TR = ns.TR

-- Verkaufen ab Gold farmen (Level 35): im Tooltip steht, ob AH oder Haendler,
-- beim Haendler ein Knopf "Haendler Kram verkaufen" (nur graue Items).

local function Worth(id, link)
  local vendor = select(11, ns.Api.GetItemInfo(link or id)) or 0
  local ah = ns.AHPrice and ns.AHPrice(id, link)
  -- AH lohnt, wenn nach 5% Gebuehr klar mehr als beim Haendler (und mindestens 20 Silber mehr)
  if ah and ah * 0.95 > vendor * 1.5 and ah * 0.95 - vendor > 2000 then return "ah", ah, vendor end
  return "vendor", ah, vendor
end
ns.SellWorth = Worth

local function Active() return ns.db and ns.Unlocked and ns.Unlocked("gold") end

-- Tooltip Zeile
local function OnItem(tt)
  if not Active() then return end
  local _, link = tt:GetItem()
  if not link then return end
  local id = tonumber(link:match("item:(%d+)"))
  if not id then return end
  local _, _, quality, _, _, _, _, _, _, _, sell = ns.Api.GetItemInfo(link)
  if not sell or sell <= 0 then return end
  local w, ah = Worth(id, link)
  if w == "ah" then
    tt:AddLine((TR"|cff7fd1b9Keine Zeit Leveling Guide:|r lieber ins AH, ca %s"):format(ns.Money(ah)), 1, 1, 1)
  elseif quality == 0 then
    -- "beim Händler verkaufen" nur bei Grauem, weisse und bessere Sachen entscheidest du selbst (17.3)
    tt:AddLine(TR"|cff7fd1b9Keine Zeit Leveling Guide:|r beim Händler verkaufen", 1, 1, 1)
  else
    return
  end
  tt:Show()
end
if GameTooltip and GameTooltip.HookScript then
  pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", OnItem)
end

-- Ist das Item gebunden? (dann geht es nicht ins AH)
local function Bound(bag, slot)
  if C_Item and C_Item.IsBound and ItemLocation and ItemLocation.CreateFromBagAndSlot then
    local ok, v = pcall(function() return C_Item.IsBound(ItemLocation:CreateFromBagAndSlot(bag, slot)) end)
    if ok then return v end
  end
  return nil
end

local function Info(bag, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local i = C_Container.GetContainerItemInfo(bag, slot)
    if i then return i.hyperlink, i.quality, i.itemID end
    return
  end
  if ns.Api.GetContainerItemInfo then
    local _, _, _, q, _, _, link, _, _, id = ns.Api.GetContainerItemInfo(bag, slot)
    return link, q, id
  end
end

-- was kommt weg: nur graue Items, Questitems nie
local function JunkList()
  local out = {}
  local nslots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
  for bag = 0, 4 do
    for slot = 1, (nslots and nslots(bag) or 0) do
      local link, q, id = Info(bag, slot)
      if link and id then
        local _, _, _, _, _, class, _, _, equipLoc, _, sell, classID = ns.Api.GetItemInfo(link)
        -- Quest Items an der Klasse 12 erkennen (der Text "Quest" ist je nach Sprache anders)
        local quest = (ns.neededItems and ns.neededItems[id]) or classID == 12 or class == "Quest" or class == "Quest Item" or class == "Quest Items"
        if sell and sell > 0 and not quest then
          -- nur Graues (Ausruestung entscheidest du selbst)
          if q == 0 then
            table.insert(out, { bag = bag, slot = slot, link = link, sell = sell })
          end
        end
      end
    end
  end
  return out
end

function ns.SellJunk()
  local list = JunkList()
  if #list == 0 then ns.Print(TR"Nichts zu verkaufen."); return end
  local total = 0
  local use = (C_Container and C_Container.UseContainerItem) or UseContainerItem
  for i, e in ipairs(list) do
    C_Timer.After(0.15 * (i - 1), function()
      if not (MerchantFrame and MerchantFrame:IsShown()) then return end
      -- liegt noch dasselbe Teil auf dem Platz? (Doppelklick, Kauf in der Zwischenzeit)
      local now = Info(e.bag, e.slot)
      if now == e.link then ns.Api.Prot("UseContainerItem", use, e.bag, e.slot) end
    end)
    total = total + e.sell
  end
  ns.Print((TR"Verkauft: %d Sachen für ca %s."):format(#list, ns.Money(total)))
end

-- Knopf am Haendler Fenster
local btn
local mf = CreateFrame("Frame")
mf:RegisterEvent("MERCHANT_SHOW")
mf:SetScript("OnEvent", function()
  if not (Active() and MerchantFrame) then if btn then btn:Hide() end; return end
  if not btn then
    btn = (ns.T and ns.T.Button(MerchantFrame, TR"Händler Kram verkaufen", 170, 22)) or CreateFrame("Button", nil, MerchantFrame, "UIPanelButtonTemplate")
    btn:SetSize(170, 22)
    btn:SetText(TR"Händler Kram verkaufen")
    btn:SetPoint("TOPRIGHT", MerchantFrame, "TOPRIGHT", -50, -40)
    btn:SetScript("OnClick", ns.SellJunk)
    btn:SetScript("OnEnter", function(self)
      ns.TipOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(TR"Händler Kram verkaufen")
      GameTooltip:AddLine(TR"Verkauft nur graue Items. Ausrüstung und Quest Items nie.", 1, 1, 1, true)
      GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  end
  btn:Show()
end)
