local ADDON, ns = ...
local TR = ns.TR

-- Aussehen: mit ElvUI der ElvUI Look, ohne ElvUI der klassische Blizzard Look
-- kind: "window" (grosse Fenster), "panel" (Kaesten, HUD), "button", "thin" (Balken)

local CLASSIC = {
  window = {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  },
  panel = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
  },
  button = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 10,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  },
  thin = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
  },
}

function ns.HasElv() return ElvUI ~= nil end

function ns.Skin(f, kind, alpha, elvKind)
  kind = kind or "panel"
  -- neuer Look (Theme.lua): Classic UI oder ElvUI, je nach Einstellung
  if ns.T then
    local map = { window = "window", panel = "tooltip", button = "inset", thin = "thin" }
    return ns.T.Skin(f, map[kind] or "inset", alpha)
  end
  if ElvUI and f.SetTemplate then
    local ek = elvKind or ((kind == "window" or kind == "panel") and "Transparent" or "Default")
    if pcall(f.SetTemplate, f, ek) then return "elv" end
  end
  if not f.SetBackdrop then return end
  f:SetBackdrop(CLASSIC[kind] or CLASSIC.panel)
  if kind == "window" then
    f:SetBackdropColor(1, 1, 1, alpha or 1)
    f:SetBackdropBorderColor(1, 1, 1, 1)
  elseif kind == "button" then
    f:SetBackdropColor(0.12, 0.08, 0.02, alpha or 0.95)
    f:SetBackdropBorderColor(0.85, 0.7, 0.25, 1) -- goldener Rand wie bei Blizzard Knoepfen
  elseif kind == "thin" then
    f:SetBackdropColor(0, 0, 0, alpha or 0.6)
    f:SetBackdropBorderColor(0, 0, 0, 1)
  else
    f:SetBackdropColor(0.04, 0.04, 0.06, alpha or 0.9)
    f:SetBackdropBorderColor(0.7, 0.7, 0.7, 1) -- grauer Rand wie bei Tooltips
  end
  return "classic"
end


------------------------------------------------------------
-- Eigene Rueckfrage statt StaticPopup (StaticPopup von Addons kann Blizzard Fenster "verseuchen",
-- dann blockiert Blizzard spaeter eigene Aktionen mit "UNKNOWN")
------------------------------------------------------------
local confirm
function ns.Confirm(text, yesText, onYes, noText)
  if not confirm then
    local f = CreateFrame("Frame", "ForeverWegweiserConfirm", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(380, 120)
    f:SetPoint("TOP", UIParent, "TOP", 0, -160)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(true)
    if ns.T then ns.T.Skin(f, "window") elseif ns.Skin then ns.Skin(f, "window") end
    f.text = f:CreateFontString(nil, "OVERLAY", ns.FontName("GameFontHighlight"))
    f.text:SetPoint("TOPLEFT", 18, -20); f.text:SetPoint("TOPRIGHT", -18, -20)
    f.text:SetJustifyH("CENTER")
    if ns.T then
      f.yes = ns.T.Button(f, "", 130, 24, true)
      f.no = ns.T.Button(f, "", 130, 24)
    else
      f.yes = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
      f.no = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    end
    f.yes:SetSize(130, 24); f.yes:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 14)
    f.no:SetSize(130, 24); f.no:SetPoint("BOTTOMLEFT", f, "BOTTOM", 6, 14)
    f.no:SetScript("OnClick", function() f:Hide() end)
    f:Hide()
    confirm = f
  end
  local f = confirm
  f.text:SetText(text)
  f:SetHeight(math.max(110, f.text:GetStringHeight() + 70))
  f.yes:SetText(yesText or "OK")
  f.yes:SetScript("OnClick", function() f:Hide(); if onYes then onYes() end end)
  if onYes then
    f.no:SetText(noText or TR"Abbrechen"); f.no:Show()
    f.yes:ClearAllPoints(); f.yes:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 14)
  else
    f.no:Hide()
    f.yes:ClearAllPoints(); f.yes:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
  end
  f:Show()
end

-- ESC: unsere Fenster schliessen, sobald das Spielmenue aufgeht (statt UISpecialFrames, das kann Blizzard blockieren lassen)
ns.escFrames = {}
function ns.CloseOnEscape(frame) table.insert(ns.escFrames, frame) end
do
  local hooked = false
  local function Hook()
    if hooked or not GameMenuFrame then return end
    hooked = true
    GameMenuFrame:HookScript("OnShow", function()
      for _, fr in ipairs(ns.escFrames) do if fr:IsShown() then fr:Hide() end end
    end)
  end
  local ef = CreateFrame("Frame")
  ef:RegisterEvent("PLAYER_ENTERING_WORLD")
  ef:SetScript("OnEvent", Hook)
end
