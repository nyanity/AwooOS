-- /lib/sha256.lua

local bit_band = bit32 and bit32.band or error("bit32 not found")
local bit_bnot = bit32.bnot
local bit_bor  = bit32.bor
local bit_bxor = bit32.bxor
local bit_lshift = bit32.lshift
local bit_rshift = bit32.rshift
local bit_rrotate = function(x, n)
  return bit_bor(bit_rshift(x, n), bit_lshift(x, 32 - n))
end

local k = {
  0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,
  0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,
  0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,
  0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,
  0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,
  0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,
  0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,
  0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,
  0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,
  0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,
  0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,
  0xD192E819,0xD6990624,0xF40E3585,0x106AA070,
  0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,
  0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,
  0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,
  0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2
}

local function sha256(msg)
  local msgLen = #msg * 8
  msg = msg .. "\128" .. string.rep("\0", 63 - ((#msg + 8) % 64))
  msg = msg .. string.pack(">I8", msgLen)

  local h = {
    0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,
    0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19
  }

  for i = 1, #msg, 64 do
    local w = {}
    for j = 0, 15 do
      w[j] = string.unpack(">I4", msg, i + j*4)
    end
    for j = 16, 63 do
      local s0 = bit_bxor(bit_rrotate(w[j-15],7), bit_rrotate(w[j-15],18), bit_rshift(w[j-15],3))
      local s1 = bit_bxor(bit_rrotate(w[j-2],17), bit_rrotate(w[j-2],19), bit_rshift(w[j-2],10))
      w[j] = (w[j-16] + s0 + w[j-7] + s1) & 0xffffffff
    end

    local a,b,c,d,e,f,g,hv = h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8]

    for j = 0, 63 do
      local S1 = bit_bxor(bit_rrotate(e,6), bit_rrotate(e,11), bit_rrotate(e,25))
      local ch = bit_bxor(bit_band(e,f), bit_band(bit_bnot(e),g))
      local temp1 = (hv + S1 + ch + k[j+1] + w[j]) & 0xffffffff
      local S0 = bit_bxor(bit_rrotate(a,2), bit_rrotate(a,13), bit_rrotate(a,22))
      local maj = bit_bxor(bit_band(a,b), bit_band(a,c), bit_band(b,c))
      local temp2 = (S0 + maj) & 0xffffffff

      hv = g
      g = f
      f = e
      e = (d + temp1) & 0xffffffff
      d = c
      c = b
      b = a
      a = (temp1 + temp2) & 0xffffffff
    end

    h[1] = (h[1] + a) & 0xffffffff
    h[2] = (h[2] + b) & 0xffffffff
    h[3] = (h[3] + c) & 0xffffffff
    h[4] = (h[4] + d) & 0xffffffff
    h[5] = (h[5] + e) & 0xffffffff
    h[6] = (h[6] + f) & 0xffffffff
    h[7] = (h[7] + g) & 0xffffffff
    h[8] = (h[8] + hv) & 0xffffffff
  end

  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
    h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8])
end

return sha256
