-- TipMaus (19.32, Navi Chat, Saschas Log 30.10. 00:47 "Tooltip nicht bei der Maus", ElvUI, UI Scale 0.70, 2560x1440,
-- Saschas Wunsch 02:12: Tooltips IMMER bei der Maus):
-- Alle 50 Tooltips hingen am Rand des Rahmens (ANCHOR_TOPLEFT, ANCHOR_RIGHT ...). Bei grossen Rahmen (Ja Nein Zeilen in
-- Einstellungen und Einrichtung, Mini Fenster, XP Balken) kam der Tooltip weit weg von der Maus. ElvUI kann das nicht
-- abfangen, weil das Addon den Anker selbst setzt.
-- ns.TipOwner(owner, anchor, ox, oy) ersetzt GameTooltip:SetOwner(owner, anchor, ox, oy): der Tooltip kommt rechts neben
-- die Maus (ANCHOR_CURSOR_RIGHT) und folgt ihr, solange sie auf dem Rahmen bleibt. Kennt der Client diesen Anker nicht,
-- ANCHOR_CURSOR (gibt es ueberall). anchor, ox, oy werden nur noch gebraucht, wenn beides scheitert.
local ADDON, ns = ...

local ok_right -- nil = noch nicht probiert, true / false nach dem ersten Versuch

function ns.TipOwner(owner, anchor, ox, oy, tt)
  tt = tt or GameTooltip
  if not tt then return end
  if ok_right ~= false then
    local ok = pcall(tt.SetOwner, tt, owner, "ANCHOR_CURSOR_RIGHT", 16, 0)
    if ok then ok_right = true; return end
    ok_right = false
  end
  if pcall(tt.SetOwner, tt, owner, "ANCHOR_CURSOR") then return end
  tt:SetOwner(owner, anchor or "ANCHOR_RIGHT", ox, oy)
end
