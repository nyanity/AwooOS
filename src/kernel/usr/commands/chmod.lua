-- chmod - change file mode bits
local fs = require("filesystem")
local tArgs = env.ARGS

if not tArgs or #tArgs < 2 then
  print("Usage: chmod <mode> <file>")
  print("Example: chmod 755 /bin/sh.lua")
  return
end

local sModeStr = tArgs[1]
local sPath = tArgs[2]

-- resolve path
if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. sPath end
sPath = sPath:gsub("//", "/")

-- convert "755" (string) to 755 (number)
-- we treat it as decimal here because our DB stores it as decimal representation of octal
-- (it's weird but easier than bitwise math in lua 5.2 without libs)
local nMode = tonumber(sModeStr)

if not nMode then
  print("chmod: invalid mode: " .. sModeStr)
  return
end

local bOk, sErr = fs.chmod(sPath, nMode)

if bOk then
  -- silent success is the unix way
else
  print("chmod: " .. tostring(sErr))
end