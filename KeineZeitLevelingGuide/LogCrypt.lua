-- Test Log verschluesseln (17.2): nur wer den geheimen Schluessel hat, kann das Log lesen, und jede
-- veraenderte, geloeschte oder eingefuegte Zeile faellt bei der Auswertung auf.
-- Pro Sitzung ein zufaelliger Schluessel K (16 Byte). K wird mit dem oeffentlichen RSA Schluessel (2048 Bit)
-- verschluesselt gespeichert, die Zeilen mit RC4 (die ersten 3072 Byte verworfen), dazu pro Zeile eine
-- Pruefzahl (Polynom mod 67108859 mit geheimem Punkt aus K) und die Pruefzahl der Zeile davor (Kette).
-- Der geheime Schluessel liegt nie im Addon. Auswertung: fw_log_auswerten.py mit schluessel_privat.txt.
-- Grenze: wer den Addon Code selber umschreibt, kann alles. Gegen Aendern der Datei hilft es.
local ADDON, ns = ...
local floor, char, byte = math.floor, string.char, string.byte

local PUB_N = "9aa8164c61f19dab183e4388325befd9448340b8b61b5b0af5834fc61839be27d6d1fd166794beeda4544e8473685bc94309c7fefd9dc0ee03d4e1e9665f5d99c1b23fa4d48cfde21a1330bc700345aa419e30d91ee4df3bc5ecddeb7ef1a2c06f0f973c23f6b6414fb815dce93ba89d3a92d41ec6c1027bb48287cbc9992e314f4d1fea8df7b2dfddf55f8fa501c2f3d2ca9d4dc1d52b1ab6552d8f9d3b6b589851c0d4cd88a8983b30a53ae92d55c0ee083a74b6b92ce0f85c228ae82e9bd34d97a3af9c05a67e75016ea537400b35017783bc399e1f3fd5f40e3dab55fc825da3d87b1e3fba5f4e653fb1d23ebcaa3b05dd79171e4479a0fe476d3339328d"
local PUB_R2 = "7aa315dde4027770ef5db2f754b97df4529e69b4fd8cc8afe9f09948f43eb5f40c4855359f0b83118c9a89760d25097faadef8e6df9727aa343f3d68d799c4e658a5ba795fd3d6440353c3f4f5723f114d6a67628837eb33ca3a6be92d842df9ddeb83a71bf291affaa77ee5d26bff0e996942daf7b0a537d0eeec96b14f0fe39420e0fd94420a5cd4c79851a4dfd64385398e74d19bcce03d14c656e562287bc488b0e23e99df51e021f59774f57eeb0c3a2d248a0b4a1b01116c49e269020168b04523ea7f72907c8462cde70f79eb97a7e350d9935ee904da841ed451fae2e770bf9f6422c56b482bb82b6d7032af9a4e3a970a1bc1996220b2f196721c1f"
local N0INV = 12394427
local S = 86
local KID = "3339328d"
local B = 16777216 -- 2^24 pro Stelle
local P = 67108859 -- Primzahl fuer die Pruefzahl (unter 2^26, Produkte bleiben genau)

------------------------------------------------------------ grosse Zahlen (24 Bit Stellen, klein zuerst)
local function Limbs(hex)
  local t, k, i = {}, 1, #hex
  while i >= 1 do
    local j = math.max(1, i - 5)
    t[k] = tonumber(hex:sub(j, i), 16)
    k, i = k + 1, j - 1
  end
  for x = k, S do t[x] = 0 end
  return t
end
local function Hex(t)
  local parts = {}
  for k = S, 1, -1 do parts[#parts + 1] = ("%06x"):format(t[k] or 0) end
  local h = table.concat(parts):gsub("^0+", "")
  return ("0"):rep(512 - #h) .. h
end
local Nl, R2l
-- Montgomery: a * b / R mod n (R = B^S)
local function MonMul(a, b)
  local n = Nl
  local t = {}
  for x = 1, S + 2 do t[x] = 0 end
  for i = 1, S do
    local ai, C = a[i], 0
    for j = 1, S do
      local x = t[j] + ai * b[j] + C
      C = floor(x / B); t[j] = x - C * B
    end
    local x = t[S + 1] + C
    C = floor(x / B); t[S + 1] = x - C * B; t[S + 2] = C
    local m = (t[1] * N0INV) % B
    x = t[1] + m * n[1]; C = floor(x / B)
    for j = 2, S do
      x = t[j] + m * n[j] + C
      C = floor(x / B); t[j - 1] = x - C * B
    end
    x = t[S + 1] + C
    C = floor(x / B); t[S] = x - C * B
    t[S + 1] = t[S + 2] + C
  end
  -- t >= n: n abziehen
  local ge = t[S + 1] > 0
  if not ge then
    ge = true
    for k = S, 1, -1 do
      if t[k] ~= n[k] then ge = t[k] > n[k]; break end
    end
  end
  local r = {}
  if ge then
    local br = 0
    for k = 1, S do
      local x = t[k] - n[k] - br
      if x < 0 then x = x + B; br = 1 else br = 0 end
      r[k] = x
    end
  else
    for k = 1, S do r[k] = t[k] end
  end
  return r
end

------------------------------------------------------------ Bytes
local bx = bit and bit.bxor
local NIB
local function Xor(a, b)
  if bx then return bx(a, b) end
  if not NIB then
    NIB = {}
    for i = 0, 15 do
      NIB[i] = {}
      for j = 0, 15 do
        local r, p, x, y = 0, 1, i, j
        for _ = 1, 4 do
          if (x % 2) ~= (y % 2) then r = r + p end
          x, y, p = floor(x / 2), floor(y / 2), p * 2
        end
        NIB[i][j] = r
      end
    end
  end
  return NIB[a % 16][b % 16] + 16 * NIB[floor(a / 16)][floor(b / 16)]
end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64C = {}
for i = 1, 64 do B64C[i - 1] = B64:sub(i, i) end
local function Base64(t)
  local out, n = {}, #t
  for i = 1, n, 3 do
    local a, b, c = t[i], t[i + 1] or 0, t[i + 2] or 0
    local v = a * 65536 + b * 256 + c
    out[#out + 1] = B64C[floor(v / 262144)] .. B64C[floor(v / 4096) % 64]
      .. (i + 1 <= n and B64C[floor(v / 64) % 64] or "=") .. (i + 2 <= n and B64C[v % 64] or "=")
  end
  return table.concat(out)
end

------------------------------------------------------------ Zufall (das Spiel mischt math.random selber)
local function RandByte(nonzero)
  local v = (math.random(0, 255) + floor(((debugprofilestop and debugprofilestop()) or 0) * 997) + floor((GetTime() or 0) * 7919)) % 256
  if nonzero and v == 0 then v = math.random(1, 255) end
  return v
end

------------------------------------------------------------ RC4
local function KS(st)
  local s = st.s
  local i = (st.i + 1) % 256
  local j = (st.j + s[i]) % 256
  s[i], s[j] = s[j], s[i]
  st.i, st.j, st.off = i, j, st.off + 1
  return s[(s[i] + s[j]) % 256]
end

-- neue Sitzung: Schluessel ziehen, Strom bereit machen, RSA nebenbei (ein Stueck pro Bild, damit nichts ruckelt)
function ns.LogCryptNew()
  if not Nl then Nl, R2l = Limbs(PUB_N), Limbs(PUB_R2) end
  local K = {}
  for i = 1, 16 do K[i] = RandByte() end
  local st = { s = {}, i = 0, j = 0, off = 0, kid = KID, prev = 0 }
  local s = st.s
  for i = 0, 255 do s[i] = i end
  local j = 0
  for i = 0, 255 do
    j = (j + s[i] + K[i % 16 + 1]) % 256
    s[i], s[j] = s[j], s[i]
  end
  for _ = 1, 3072 do KS(st) end
  -- geheimer Punkt fuer die Pruefzahl aus dem Strom
  local r = 0
  for _ = 1, 4 do r = (r * 256 + KS(st)) % P end
  st.r = (r < 2) and (r + 2) or r
  st.off = 0
  -- K fuer den Schluessel Inhaber: 00 02 Zufall(237, ohne 0) 00 K
  local m = { 0, 2 }
  for _ = 1, 237 do m[#m + 1] = RandByte(true) end
  m[#m + 1] = 0
  for i = 1, 16 do m[#m + 1] = K[i] end
  local hex = {}
  for i = 1, 256 do hex[i] = ("%02x"):format(m[i]) end
  local ml = Limbs(table.concat(hex))
  -- m^65537 mod n: m*R, 16 mal quadrieren, mal m*R, aus der Montgomery Form
  local job = { step = 0 }
  st.job = job
  function job.Run(nsteps)
    for _ = 1, nsteps or 99 do
      if job.step == 0 then job.a = MonMul(ml, R2l); job.x = job.a
      elseif job.step <= 16 then job.x = MonMul(job.x, job.x)
      elseif job.step == 17 then job.x = MonMul(job.x, job.a)
      elseif job.step == 18 then
        local one = { 1 }
        for k = 2, S do one[k] = 0 end
        st.key = Hex(MonMul(job.x, one))
        st.job, ml, job.a, job.x = nil, nil, nil, nil
        return true
      end
      job.step = job.step + 1
    end
    return false
  end
  return st
end

-- eine Zeile verschliessen: "seq.off:base64". Inhalt: Pruefzahl davor (4 Byte), Text, Pruefzahl (4 Byte)
function ns.LogCryptSeal(st, seq, text)
  local r = st.r
  local body = {}
  local pv = st.prev
  body[1], body[2], body[3], body[4] = floor(pv / 16777216) % 256, floor(pv / 65536) % 256, floor(pv / 256) % 256, pv % 256
  local n = #text
  for i = 1, n do body[4 + i] = byte(text, i) end
  -- Pruefzahl ueber Nummer und Inhalt (Horner, mod P)
  local h = 0
  local sq = seq
  for _ = 1, 4 do h = ((h + (sq % 256) + 1) * r) % P; sq = floor(sq / 256) end
  for i = 1, #body do h = ((h + body[i] + 1) * r) % P end
  local k = #body
  body[k + 1], body[k + 2], body[k + 3], body[k + 4] = floor(h / 16777216) % 256, floor(h / 65536) % 256, floor(h / 256) % 256, h % 256
  st.prev = h
  local off = st.off
  for i = 1, #body do body[i] = Xor(body[i], KS(st)) end
  return seq .. "." .. off .. ":" .. Base64(body)
end
