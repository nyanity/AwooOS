local fs = require("filesystem")

local hLog = fs.open("/dev/ringlog", "r")
if not hLog then
  print("Error: Could not open /dev/ringlog")
  return
end

local sData = fs.read(hLog, math.huge)
fs.close(hLog)

if sData then
  print(sData)
else
  print("Log is empty.")
end