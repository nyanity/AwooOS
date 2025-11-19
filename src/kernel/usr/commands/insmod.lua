-- /bin/insmod.lua
local tArgs = env.ARGS
if not tArgs or #tArgs < 1 then
  print("Usage: insmod <path>")
  return
end

local sPath = tArgs[1]
if sPath:sub(1,1) ~= "/" then sPath = (env.PWD or "/") .. "/" .. sPath end
sPath = sPath:gsub("//", "/")

-- call syscall
local bOk, sResult = syscall("driver_load", sPath)

if bOk then
  -- sResult contains the nice string from PM
  print("\27[32m" .. tostring(sResult) .. "\27[37m")
else
  print("\27[31mError:\27[37m " .. tostring(sResult))
end