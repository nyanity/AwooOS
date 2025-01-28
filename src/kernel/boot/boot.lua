local component = component
local computer = computer
local filesystem = require("filesystem")

local function readAll(path)
  local handle, reason = filesystem.open(path, "r")
  if not handle then
    error("Failed to open " .. path .. ": " .. tostring(reason))
  end
  local data = ""
  repeat
    local chunk = filesystem.read(handle, math.huge)
    if chunk then
      data = data .. chunk
    end
  until not chunk
  filesystem.close(handle)
  return data
end

do
  local gpu = component.list("gpu")()
  if gpu then
    gpu = component.proxy(gpu)
    gpu.setResolution(80, 25)
    gpu.fill(1, 1, 80, 25, " ")
    gpu.set(1, 1, "AwooOS is loading kernel...")
  end
end

local kernelCode = readAll("/kernel.lua") -- surely we don't have kernel rn; but whatever.
local kernelFunc, err = load(kernelCode, "=kernel", "t", _ENV)
if not kernelFunc then
  error("Error loading kernel: " .. tostring(err))
end

local ok, err2 = pcall(kernelFunc)
if not ok then
  error("Kernel crashed: " .. tostring(err2))
end

while true do
  computer.pullSignal()
end
