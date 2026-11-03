-- Forever Wegweiser Test Log: nur der Speicher (eigene Datei SavedVariables\ForeverWegweiser_Log.lua).
-- Was hinein kommt, schreibt Forever Wegweiser (DebugLog.lua), verschluesselt und anonym.
-- Ohne dieses Addon schreibt Forever Wegweiser kein Log.
local ADDON = ...
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
  if name ~= ADDON then return end
  if type(ForeverWegweiserTestLog) ~= "table" then ForeverWegweiserTestLog = {} end
  f:UnregisterEvent("ADDON_LOADED")
end)
