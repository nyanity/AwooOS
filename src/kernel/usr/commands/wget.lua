--
-- wget - download files from the interwebs
-- now with 20% more progress bars
--

local fs = require("filesystem")
local tArgs = env.ARGS

if not tArgs or #tArgs < 1 then
  print("Usage: wget <url> [output_path]")
  return
end

local sUrl = tArgs[1]
local sOutPath = tArgs[2]

-- if no output path, infer from url
if not sOutPath then
  sOutPath = sUrl:match(".*/([^/]+)$") or "downloaded_file"
end
if sOutPath:sub(1,1) ~= "/" then sOutPath = (env.PWD or "/") .. sOutPath end

print("\27[36m::\27[37m Connecting to " .. sUrl .. "...")

local hNet = fs.open("/dev/net", "w") -- open for write to send url
if not hNet then
  print("\27[31mError:\27[37m Could not open /dev/net. Is the driver loaded?")
  return
end

-- send request
fs.write(hNet, sUrl)

-- close and reopen for read? 
-- actually, our driver keeps state by PID. 
-- but standard VFS usually separates read/write handles.
-- let's assume we can read from the same handle if we opened with rw, 
-- OR we close and reopen.
-- Given the driver implementation above, it maps by PID. 
-- So we can just close the write handle and open a read handle, 
-- OR (better) the driver should handle read on the same handle if opened "rw".
-- Let's try closing and re-opening in "r" mode to be safe with VFS logic.
fs.close(hNet)

local hNetRead = fs.open("/dev/net", "r")
if not hNetRead then
   print("\27[31mError:\27[37m Connection lost during handshake.")
   return
end

local hFile = fs.open(sOutPath, "w")
if not hFile then
  print("\27[31mError:\27[37m Cannot open output file: " .. sOutPath)
  fs.close(hNetRead)
  return
end

print("\27[36m::\27[37m Downloading...")

local nTotalBytes = 0
local sSpinners = {"|", "/", "-", "\\"}
local nSpinIdx = 1

while true do
  local sChunk = fs.read(hNetRead, 2048) -- read 2kb chunks
  if not sChunk or #sChunk == 0 then break end
  
  fs.write(hFile, sChunk)
  nTotalBytes = nTotalBytes + #sChunk
  
  -- draw fancy progress
  local sSizeStr = string.format("%.2f KB", nTotalBytes / 1024)
  io.write("\r\27[K\27[32m" .. sSpinners[nSpinIdx] .. "\27[37m Received: " .. sSizeStr)
  
  nSpinIdx = nSpinIdx + 1
  if nSpinIdx > 4 then nSpinIdx = 1 end
end

fs.close(hNetRead)
fs.close(hFile)

print("\n\27[32m[OK]\27[37m Saved to " .. sOutPath)