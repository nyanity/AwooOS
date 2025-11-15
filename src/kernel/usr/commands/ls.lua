local fs = require("lib/filesystem")
local path = (env.ARGS and env.ARGS[1]) or env.PATH or "/"

local stdout = { fd = 1 }
local stderr = { fd = 2 }

local list, err = fs.list(path)
if not list then
  fs.write(stderr, "ls: cannot access " .. path .. ": " .. err .. "\n")
  return
end

local output = ""
for _, item in ipairs(list) do
  output = output .. item .. "\t"
end
fs.write(stdout, output .. "\n")
