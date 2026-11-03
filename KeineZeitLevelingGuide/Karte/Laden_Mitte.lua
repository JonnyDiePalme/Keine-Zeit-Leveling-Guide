-- 19.4: nach dem Era Teil (siehe Laden_Vor.lua)
local ADDON, ns = ...
if ns.KARTE_CLIENT == "era" then ns.KARTE_RAW, ns.KARTE_INFO = FWW_AUTO_KARTE_RAW, FWW_AUTO_KARTE_INFO end
FWW_AUTO_KARTE_RAW, FWW_AUTO_KARTE, FWW_AUTO_KARTE_INFO = {}, {}, nil
