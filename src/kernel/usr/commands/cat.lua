-- cat - concatenate file(s) to standard output
local fs = require("filesystem")
local tArgs = env.ARGS

if not tArgs or #tArgs == 0 then
  print("Usage: cat <filename>")
  return
end

for _, sPath in ipairs(tArgs) do
  if sPath:sub(1,1) ~= "/" then
    sPath = (env.PWD or "/") .. sPath
  end
  -- Убираем двойные слеши
  sPath = sPath:gsub("//", "/")

  local hFile = fs.open(sPath, "r")
  if hFile then
    -- Читаем целиком
    local sData = fs.read(hFile, math.huge)
    if sData then
      io.write(sData)
    end
    fs.close(hFile)
  else
    print("cat: " .. sPath .. ": No such file or directory")
  end
end