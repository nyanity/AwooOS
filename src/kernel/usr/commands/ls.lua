-- ls - list directory
local fs = require("filesystem")
local sDir = ((env.ARGS and env.ARGS[1]) or env.PWD or "/")

local hStdout = { fd = 1 }

local tList, sErr = fs.list(sDir)

if not tList or type(tList) ~= "table" then
  fs.write(hStdout, "ls: cannot access '" .. sDir .. "': " .. tostring(sErr or "No such file") .. "\n")
  return
end

table.sort(tList)

for _, sFile in ipairs(tList) do
  fs.write(hStdout, sFile .. "\t") 
end
fs.write(hStdout, "\n")