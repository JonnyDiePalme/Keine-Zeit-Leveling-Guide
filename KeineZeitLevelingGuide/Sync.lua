local ADDON, ns = ...
local TR = ns.TR

-- Wege teilen: Felder, durch die du gelaufen bist, gehen an andere Spieler mit Keine Zeit Leveling Guide (und umgekehrt).
-- Wie Nauticus: ein versteckter Chat Kanal, gesendet wird nur bei einem Klick oder Tastendruck (das verlangt das Spiel),
-- dazu Gilde und Gruppe als Addon Nachricht. Kann der Kanal auf diesem Server nicht gelesen werden ("geheime" Werte),
-- geht es nur noch ueber Gilde und Gruppe, mit einem einmaligen Hinweis.
-- Geteilt wird nur, was du selbst gelaufen bist, fruehestens nach 45 Minuten, gemischt und nie die aktuelle Position.
-- Gemalte Berge, Wege und Wasser werden nie geteilt.
-- Jede Nachricht: Kennung und Version, Zone, Abschnitte (zusammenhaengende Wege), Pruefsumme.

local W = ns.Ways
local CHAN = "FWWege1"
local CHANL = CHAN:lower()
local PREFIX = "FWWege"
local TAG = "FW1"
-- 17.4: gemessene Flugzeiten (Flights.lua), eigene Kennung und eigener Praefix: aeltere Versionen sehen sie nicht
local FTAG, FPREFIX = "FWF", "FWFlug"
local floor = math.floor
local EMPTY = {}
local CA, CD = W.CA, W.CD
-- klein und oefter (alle 3 Minuten hoechstens 30 Felder in 2 Meldungen): keine Ruckler beim Packen
local MAXCELLS, MAXMSG, MSGCELLS, BODY = 30, 2, 120, 255 - 3 - 2 - 2
local PRIVACY = 2700      -- 45 Minuten
local RESHARE = 7         -- dasselbe Feld in derselben Richtung hoechstens alle 7 Tage nochmal

local S = { recv = 0, sent = 0, gsent = 0, senders = {}, nsenders = 0, bad = 0, dropped = 0, secret = 0, readable = 0, echo = 0, packets = 0, cells = 0 }
ns.SyncStats = S
local chanState = "off"   -- off, join, ok, secret (nicht lesbar), broken (geht nicht)
local joinedAt
local sendsNoEcho = 0
local cq, gq = {}, {}     -- Warteschlangen: Kanal (nur bei Klick oder Taste) und Gilde/Gruppe
local lastChan = 0

local function Secret(v) return v ~= nil and issecretvalue and issecretvalue(v) or false end
local me
local function Realm() return (GetNormalizedRealmName and GetNormalizedRealmName()) or "" end
local function Me()
  if not me then
    local n = UnitName("player")
    if n then me = n .. "-" .. Realm() end
  end
  return me
end
local function Norm(s)
  if type(s) ~= "string" or Secret(s) or s == "" then return nil end
  if not s:find("-", 1, true) then s = s .. "-" .. Realm() end
  return s
end
local function Enabled() local db = ns.db; return db and db.shareWays ~= false end
ns.ShareWaysOn = Enabled

-- Name zu einer Zahl (gut gestreut, auch bei aehnlichen Namen; alles exakt unter 2^53)
local function Hash(s)
  local h = 0
  for i = 1, #s do h = (h * 131 + s:byte(i)) % 4294967291 end
  return h
end
local function Chk(s)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % 7744 end
  return h
end
local function Two(v) return string.char(CA[floor(v / 88)], CA[v % 88]) end
local function Shuffle(t) for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end end

------------------------------------------------------------
-- Nachricht lesen und pruefen
------------------------------------------------------------
local function Parse(text)
  if type(text) ~= "string" or #text < 10 or #text > 255 or text:sub(1, 3) ~= TAG then return nil end
  local body = text:sub(1, -3)
  local c1, c2 = CD[text:byte(-2)], CD[text:byte(-1)]
  if not (c1 and c2) or c1 * 88 + c2 ~= Chk(body) then return nil end
  local z1, z2 = CD[text:byte(4)], CD[text:byte(5)]
  if not (z1 and z2) then return nil end
  local ui = z1 * 88 + z2
  local info = C_Map.GetMapInfo(ui)
  if not (info and info.mapType == Enum.UIMapType.Zone) then return nil end
  local cells = {}
  local p, e = 6, #body
  while p <= e do
    local seg, len = W.ReadSeg(body, p)
    if not seg then return nil end
    for _, c in ipairs(seg) do cells[#cells + 1] = c end
    if #cells > 130 then return nil end
    p = p + len
  end
  if #cells == 0 then return nil end
  return ui, cells
end
ns.SyncParse = Parse

------------------------------------------------------------
-- Annehmen: pro Absender begrenzt, doppelte (Kanal und Gilde) nur einmal
------------------------------------------------------------
local snd, muted, seen, nSeen = {}, {}, {}, 0
local function Sender(name)
  local s = snd[name]
  if not s then
    s = { m = {}, hT = GetTime(), hN = 0, zd = {}, day = W.Today(), total = 0, onBlock = 0, bad = 0 }
    snd[name] = s
    S.nsenders = S.nsenders + 1
  end
  return s
end
local function Allow(s, name, ui, n)
  local now = GetTime()
  local m = s.m
  m[#m + 1] = now
  while m[1] and now - m[1] > 600 do table.remove(m, 1) end
  -- mehr als 40 Nachrichten in 10 Minuten: fuer diese Sitzung stumm
  if #m > 40 then muted[name] = true; return 0 end
  if now - s.hT > 3600 then s.hT, s.hN = now, 0 end
  local today = W.Today()
  if s.day ~= today then s.day, s.zd = today, {} end
  -- hoechstens 600 Felder pro Stunde und 1500 pro Zone und Tag
  local allow = math.min(n, 600 - s.hN, 1500 - (s.zd[ui] or 0))
  if allow <= 0 then return 0 end
  s.hN = s.hN + allow
  s.zd[ui] = (s.zd[ui] or 0) + allow
  return allow
end

local function OnPayload(text, sender)
  if not Enabled() or type(text) ~= "string" then return end
  sender = Norm(sender)
  if not sender or sender == Me() then return end
  if muted[sender] then if ns.MsgReject then ns.MsgReject("Wege: Absender stumm") end return end
  local db = ns.db
  local ig = db.syncIgnore and db.syncIgnore[sender]
  if ig then
    if time() - ig < 30 * 86400 then return end
    db.syncIgnore[sender] = nil
  end
  local now = GetTime()
  local dk = sender .. "\1" .. text
  if seen[dk] and now - seen[dk] < 900 then return end
  seen[dk] = now
  nSeen = nSeen + 1
  local s = Sender(sender)
  local ui, cells = Parse(text)
  if not ui then
    S.bad = S.bad + 1
    s.bad = s.bad + 1
    if s.bad >= 5 then muted[sender] = true end
    return
  end
  local allow = Allow(s, sender, ui, #cells)
  if allow < #cells then S.dropped = S.dropped + (#cells - allow) end
  if allow <= 0 then return end
  local sbit = Hash(sender:lower()) % 31
  local KF = ns.Felder and ns.Felder(ui)
  local B = KF and KF.block or EMPTY
  for i = 1, allow do
    local c = cells[i]
    W.Add(ui, c[1], c[2], c[3], sbit)
    -- Sprung nach unten: im Feld davor geht es in Gegenrichtung nicht hoch
    if c[4] == 1 and c[2] and i > 1 then W.AddDrop(ui, cells[i - 1][1], (c[2] + 4) % 8, sbit) end
    s.total = s.total + 1
    if B[c[1]] then s.onBlock = s.onBlock + 1 end
  end
  S.recv = S.recv + 1
  S.cells = S.cells + allow
  S.senders[sender] = true
  -- laeuft fast nur durch Berge der Karte: wohl Unsinn, 30 Tage ignorieren
  if s.total >= 200 and s.onBlock / s.total > 0.5 then
    db.syncIgnore = db.syncIgnore or {}
    db.syncIgnore[sender] = time()
    muted[sender] = true
  end
end
ns.SyncReceive = OnPayload

------------------------------------------------------------
-- Senden
------------------------------------------------------------
local function ChanId()
  if not GetChannelName then return nil end
  local id = GetChannelName(CHAN)
  if type(id) == "number" and id > 0 then return id end
end
local function Locked()
  if InCombatLockdown and InCombatLockdown() then return true end
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    local ok, v = pcall(C_ChatInfo.InChatMessagingLockdown)
    if ok and v then return true end
  end
  return false
end

-- bei Klick in die Welt oder Tastendruck: hoechstens eine Nachricht, mindestens 3 Sekunden Abstand
local function HW()
  if #cq == 0 or chanState ~= "ok" or not Enabled() then return end
  local now = GetTime()
  if now - lastChan < 3 or Locked() then return end
  local id = ChanId()
  if not id then return end
  while cq[1] and now - cq[1].t > 300 do table.remove(cq, 1) end
  local m = table.remove(cq, 1)
  if not m then return end
  lastChan = now
  local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if not send then return end
  local ok = pcall(send, m.text, "CHANNEL", nil, id)
  if ok then S.sent = S.sent + 1; sendsNoEcho = sendsNoEcho + 1 end
end
ns.SyncHW = HW

-- Gilde und Gruppe: kein Klick noetig, langsam (das Spiel drosselt Addon Nachrichten)
local function GuildTick()
  if #gq == 0 then return end
  if not Enabled() then gq = {}; return end
  if Locked() then return end
  local now = GetTime()
  while gq[1] and now - gq[1].t > 600 do table.remove(gq, 1) end
  local m = table.remove(gq, 1)
  local send = C_ChatInfo and C_ChatInfo.SendAddonMessage
  if not (m and send) then return end
  local pfx = m.prefix or PREFIX
  if IsInGuild and IsInGuild() then
    if pcall(send, pfx, m.text, "GUILD") then S.gsent = S.gsent + 1 end
  end
  local grp = (IsInRaid and IsInRaid()) and "RAID" or ((IsInGroup and IsInGroup()) and "PARTY") or nil
  if grp then pcall(send, pfx, m.text, grp) end
end

-- neue Felder eines Abschnitts (in den letzten 7 Tagen noch nicht in dieser Richtung geteilt)
local function NewParts(z, cells, today)
  local db = ns.db
  db.sharedOut = db.sharedOut or {}
  local so = db.sharedOut[z]
  if not so then so = {}; db.sharedOut[z] = so end
  local subs, cur, prev, n = {}, nil, nil, 0
  for _, c in ipairs(cells) do
    local k, d, sw, dr = c[1], c[2], c[3], c[4] or 0
    local v = so[k] or 0
    local m = v % 1024
    local day = (v - m) / 1024
    if today - day >= RESHARE then m = 0 end
    -- Bits: 0..7 Richtung, 8 nur da gewesen, 9 Sprung
    local bit = (dr == 1 and d) and 9 or (d or 8)
    if not W.HasBit(m, bit) then
      local code = d and (d + 8 * sw + 16 * dr)
      if cur then
        cur.st[#cur.st + 1] = code
      elseif d and prev then
        -- neuer Teil ab dem vorigen Feld, damit die Richtung dieses Schritts mitkommt
        cur = { k0 = prev[1], sw0 = prev[3], st = { code } }
        subs[#subs + 1] = cur
      else
        cur = { k0 = k, sw0 = sw, st = {} }
        subs[#subs + 1] = cur
      end
      n = n + 1
      so[k] = today * 1024 + W.SetBit(m, bit)
    else
      cur = nil
    end
    prev = c
  end
  return subs, n
end

local function PackZone(z, subs)
  local msgs = {}
  local head = TAG .. Two(z)
  local body, cells, blen = {}, 0, 0
  local function Flush()
    if #body == 0 then return end
    local s = head .. table.concat(body)
    msgs[#msgs + 1] = s .. Two(Chk(s))
    body, cells, blen = {}, 0, 0
  end
  for _, sub in ipairs(subs) do
    local w = W.WireSeg(sub.k0, sub.sw0, sub.st)
    local nc = #sub.st + 1
    if blen + #w > BODY or cells + nc > MSGCELLS then Flush() end
    body[#body + 1] = w
    blen, cells = blen + #w, cells + nc
  end
  Flush()
  return msgs
end
ns.SyncPackZone = PackZone

-- ein Paket: hoechstens 150 neue Felder in hoechstens 8 Nachrichten, Abschnitte gemischt
function ns.SyncPacket(force)
  local db = ns.db
  if not (db and Enabled()) then return 0, 0 end
  local tr = db.trail
  if not tr or #tr == 0 then return 0, 0 end
  local now = time()
  local today = W.Today()
  local ready, keep = {}, {}
  for _, s in ipairs(tr) do
    if force or now - (s.t or 0) >= PRIVACY then ready[#ready + 1] = s else keep[#keep + 1] = s end
  end
  if #ready == 0 then return 0, 0 end
  Shuffle(ready)
  local byZone, total = {}, 0
  for _, s in ipairs(ready) do
    if total >= MAXCELLS then keep[#keep + 1] = s
    else
      local cells = type(s.s) == "string" and W.ReadSeg(s.s, 1)
      if cells and s.z then
        local subs, n = NewParts(s.z, cells, today)
        if n > 0 then
          local bz = byZone[s.z]
          if not bz then bz = {}; byZone[s.z] = bz end
          for _, sub in ipairs(subs) do bz[#bz + 1] = sub end
          total = total + n
        end
      end
    end
  end
  db.trail = keep
  local msgs = {}
  for z, subs in pairs(byZone) do
    Shuffle(subs)
    for _, m in ipairs(PackZone(z, subs)) do msgs[#msgs + 1] = m end
  end
  Shuffle(msgs)
  while #msgs > MAXMSG do table.remove(msgs) end
  local t = GetTime()
  for _, m in ipairs(msgs) do
    if chanState == "ok" or chanState == "join" then cq[#cq + 1] = { text = m, t = t } end
    gq[#gq + 1] = { text = m, t = t }
  end
  if #msgs > 0 then S.packets = S.packets + 1 end
  -- alte Eintraege der Doppelt Pruefung weg
  if nSeen > 500 then
    local n2 = 0
    for k, v in pairs(seen) do if GetTime() - v > 900 then seen[k] = nil else n2 = n2 + 1 end end
    nSeen = n2
  end
  return #msgs, total
end

------------------------------------------------------------
-- Der versteckte Kanal
------------------------------------------------------------
local function IsOurs(name)
  if type(name) ~= "string" or Secret(name) then return false end
  return name:lower():find(CHANL, 1, true) ~= nil
end
local function HideChan()
  for i = 1, (NUM_CHAT_WINDOWS or 10) do
    local f = _G["ChatFrame" .. i]
    if f and ChatFrame_RemoveChannel then pcall(ChatFrame_RemoveChannel, f, CHAN) end
  end
end
local function Build() local _, b = GetBuildInfo(); return tostring(b) end
local function Fallback(kind)
  if chanState == "secret" or chanState == "broken" then return end
  chanState = kind
  cq = {}
  if ChanId() and LeaveChannelByName then pcall(LeaveChannelByName, CHAN) end
  local db = ns.db
  db.syncNoChan = { build = Build(), t = time(), kind = kind }
  if not db.syncHint then
    db.syncHint = true
    ns.Print(TR"Wege teilen: Auf diesem Server kann Keine Zeit Leveling Guide den versteckten Kanal nicht nutzen. Wege gehen jetzt nur über Gilde und Gruppe.")
  end
end
local function Join()
  if not Enabled() then return end
  local db = ns.db
  local nc = db.syncNoChan
  if nc and nc.build == Build() and time() - (nc.t or 0) < 7 * 86400 then chanState = nc.kind or "secret"; return end
  if chanState == "secret" or chanState == "broken" then return end
  if ChanId() then chanState = "ok"; HideChan(); joinedAt = joinedAt or GetTime(); return end
  local join = JoinTemporaryChannel or JoinChannelByName
  if not join then chanState = "broken"; return end
  chanState = "join"
  joinedAt = GetTime()
  pcall(join, CHAN)
  C_Timer.After(3, function()
    if ChanId() then chanState = "ok"; HideChan()
    elseif chanState == "join" then chanState = "off" end
  end)
end
ns.SyncJoin = Join

-- nach 10 Minuten im Kanal: nichts lesbar und (geheime Werte oder das eigene Echo kommt nie) -> nur Gilde und Gruppe
local function CheckChan()
  if chanState ~= "ok" or not joinedAt then return end
  if GetTime() - joinedAt < 600 or S.readable > 0 then return end
  if S.secret > 0 then Fallback("secret") elseif sendsNoEcho >= 3 then Fallback("broken") end
end

function ns.ToggleShareWays()
  local db = ns.db
  db.shareWays = (db.shareWays == false)
  if db.shareWays == false then
    cq, gq = {}, {}
    db.trail = nil
    if W.EndSeg then W.EndSeg() end
    if ChanId() and LeaveChannelByName then pcall(LeaveChannelByName, CHAN) end
    chanState = "off"
    ns.Print(TR"Wege teilen aus: du sendest und empfängst keine Wege mehr.")
  else
    chanState = "off"
    Join()
    ns.Print(TR"Wege teilen an: deine Wege gehen frühestens nach 45 Minuten an andere, ihre kommen zu dir.")
  end
  ns.blockRev = (ns.blockRev or 0) + 1
  if ns.Draw then pcall(ns.Draw) end
end

function ns.SyncState() return chanState, #cq, #gq end

-- andere Daten ueber denselben Weg (17.4: Flugzeiten): Kanal bei Klick oder Taste, Gilde und Gruppe mit eigenem Praefix
function ns.SyncQueue(text, kind)
  if not Enabled() or type(text) ~= "string" then return end
  local t = GetTime()
  if chanState == "ok" or chanState == "join" then cq[#cq + 1] = { text = text, t = t } end
  gq[#gq + 1] = { text = text, t = t, prefix = kind == "flights" and FPREFIX or nil }
end

-- Flugzeiten empfangen: gleiche Sperren wie bei den Wegen (stumm, ignoriert, doppelt ueber Kanal und Gilde)
local function OnFlights(text, sender)
  if not Enabled() or not ns.FlightsReceive then return end
  sender = Norm(sender)
  if not sender or sender == Me() or muted[sender] then return end
  local db = ns.db
  local ig = db.syncIgnore and db.syncIgnore[sender]
  if ig and time() - ig < 30 * 86400 then return end
  local now = GetTime()
  local dk = sender .. "\1" .. text
  if seen[dk] and now - seen[dk] < 900 then return end
  seen[dk] = now
  nSeen = nSeen + 1
  local ok, took = pcall(ns.FlightsReceive, text, sender, Hash(sender:lower()))
  if ok and took then S.flights = (S.flights or 0) + took end
end
ns.SyncFlightsIn = OnFlights
-- fuer Tests
ns.SyncGuildTick, ns.SyncCheckChan = GuildTick, CheckChan
function ns.SyncQueues() return cq, gq end
function ns.SyncResetSession() snd, muted, seen, nSeen = {}, {}, {}, 0 end

-- /klg wege
function ns.SyncStatus()
  local db = ns.db
  local P = ns.Print
  P(TR"Wege teilen: " .. (Enabled() and TR"an" or TR"aus"))
  if not Enabled() then P("  " .. TR"Einschalten unter Einstellungen, Reisen: Wege teilen."); return end
  local st = ({ ok = TR"versteckter Kanal verbunden, dazu Gilde und Gruppe", join = TR"Kanal wird verbunden",
    secret = TR"Kanal auf diesem Server nicht lesbar, nur Gilde und Gruppe", broken = TR"Kanal geht hier nicht, nur Gilde und Gruppe",
    off = TR"Kanal noch nicht verbunden, Gilde und Gruppe gehen" })[chanState] or chanState
  P("  " .. st)
  P(("  " .. TR"Diese Sitzung: %d Nachrichten von %d Spielern (%d Felder), %d gesendet, %d warten"):format(
    S.recv, S.nsenders, S.cells, S.sent + S.gsent, #cq + #gq))
  local pm = ns.PlayerMap and ns.PlayerMap()
  local sum = W.Summary(pm)
  P(("  " .. TR"Gespeichert: %d Zonen, etwa %d Felder, %d KB"):format(sum.zones, sum.cells, floor(sum.bytes / 1024)))
  if sum.zone then
    local z = sum.zone
    P(("  " .. TR"Diese Zone: %d Felder, %d wohl frei, %d sehr zuverlässig, %d extrem zuverlässig, %d Berge unsicher, %d Berge frei"):format(
      z.cells, z.free, z.high, z.extreme, z.unsure, z.freed))
    if (z.cliffs or 0) > 0 then P(("  " .. TR"Klippen aus geteilten Sprüngen: %d Felder"):format(z.cliffs)) end
  end
  local wait = 0
  for _, s in ipairs(db.trail or EMPTY) do if time() - (s.t or 0) < PRIVACY then wait = wait + 1 end end
  P(("  " .. TR"Eigene Spur: %d Abschnitte, %d davon noch keine 45 Minuten alt"):format(#(db.trail or EMPTY), wait))
  local ml = db.mobLayer
  if W.MobBuilding() then P("  " .. TR"Mob Ebene: wird gerade berechnet")
  elseif ml then
    local n = 0
    for _ in pairs(ml.s or EMPTY) do n = n + 1 end
    P(("  " .. TR"Mob Ebene: fertig, %d Zonen"):format(n))
  else P("  " .. TR"Mob Ebene: wartet auf Questie") end
  local ign = 0
  for _ in pairs(db.syncIgnore or EMPTY) do ign = ign + 1 end
  if ign > 0 then P(("  " .. TR"Ignoriert: %d Spieler (liefen fast nur durch Berge)"):format(ign)) end
end

------------------------------------------------------------
-- Start
------------------------------------------------------------
local inited
local function SetupFilters()
  if not ChatFrame_AddMessageEventFilter then return end
  local function Filter(_, _, _, _, _, chanStr, _, _, _, _, chanBase)
    if IsOurs(chanBase) or IsOurs(chanStr) then return true end
    return false
  end
  for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
    pcall(ChatFrame_AddMessageEventFilter, ev, Filter)
  end
end
-- Tastatur: nur einschalten, wenn die Tasten sicher weitergehen (sonst koenntest du dich nicht mehr bewegen)
local kf
local function SetupKeys()
  if kf or not CreateFrame then return end
  if InCombatLockdown and InCombatLockdown() then return end
  kf = CreateFrame("Frame", nil, UIParent)
  if not (kf.SetPropagateKeyboardInput and kf.EnableKeyboard) then return end
  local ok = pcall(kf.SetPropagateKeyboardInput, kf, true)
  local prop = ok and kf.GetPropagateKeyboardInput and kf:GetPropagateKeyboardInput()
  if not prop then return end
  kf:SetScript("OnKeyDown", function() pcall(HW) end)
  pcall(kf.EnableKeyboard, kf, true)
end

local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_ENTERING_WORLD")
ef:RegisterEvent("CHAT_MSG_CHANNEL")
ef:RegisterEvent("CHAT_MSG_ADDON")
ef:RegisterEvent("PLAYER_REGEN_ENABLED")
ef:SetScript("OnEvent", function(_, ev, ...)
  if ev == "CHAT_MSG_CHANNEL" then
    if not Enabled() then return end
    local text, sender, _, chanStr, _, _, _, _, chanBase = ...
    if Secret(chanBase) or Secret(chanStr) then S.secret = S.secret + 1; return end
    if not (IsOurs(chanBase) or IsOurs(chanStr)) then return end
    if Secret(text) or Secret(sender) then S.secret = S.secret + 1; return end
    S.readable = S.readable + 1
    if type(text) ~= "string" then return end
    if text:sub(1, 3) == FTAG then
      if Norm(sender) == Me() then S.echo = S.echo + 1; sendsNoEcho = 0; return end
      ns.SyncFlightsIn(text, sender)
      return
    end
    if text:sub(1, 3) ~= TAG then return end
    if Norm(sender) == Me() then S.echo = S.echo + 1; sendsNoEcho = 0; return end
    OnPayload(text, sender)
  elseif ev == "CHAT_MSG_ADDON" then
    local prefix, text, _, sender = ...
    if Secret(prefix) or (prefix ~= PREFIX and prefix ~= FPREFIX) then return end
    if Secret(text) or Secret(sender) then return end
    if prefix == FPREFIX then ns.SyncFlightsIn(text, sender); return end
    OnPayload(text, sender)
  elseif ev == "PLAYER_REGEN_ENABLED" then
    if inited and not kf then SetupKeys() end
  elseif ev == "PLAYER_ENTERING_WORLD" then
    if inited then return end
    inited = true
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX); pcall(C_ChatInfo.RegisterAddonMessagePrefix, FPREFIX) end
    SetupFilters()
    SetupKeys()
    if WorldFrame and WorldFrame.HookScript then WorldFrame:HookScript("OnMouseDown", function() pcall(HW) end) end
    -- spaeter beitreten, damit Allgemein, Handel usw. ihre gewohnten Nummern behalten
    C_Timer.After(8, function() pcall(Join) end)
    C_Timer.After(60, function() pcall(ns.SyncPacket) end)
    ns.Ticker(180, function() pcall(ns.SyncPacket) end)
    ns.Ticker(2.5, function() pcall(GuildTick) end, true)
    ns.Ticker(60, function() pcall(CheckChan); if chanState == "off" and Enabled() then pcall(Join) end end)
  end
end)
