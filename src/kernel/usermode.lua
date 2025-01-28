-- usermode.lua

local gpuAddress = component.list("gpu")()
local gpu = component.proxy(gpuAddress)

gpu.set(1, 3, "Hello from usermode.lua!")

local shell_path = "/usr/shell.lua"
if filesystem[shell_path] then
  local shell_func, err = load(filesystem[shell_path], shell_path, "t", Ring3)
  if not shell_func then
    gpu.set(1, 4, "Error loading shell: " .. tostring(err))
    return
  end
  local shell_co = coroutine.create(shell_func)
  local ok, er = coroutine.resume(shell_co)
  if not ok then
    gpu.set(1, 5, "Error in shell_co: " .. tostring(er))
  end
  while coroutine.status(shell_co) ~= "dead" do
    computer.pullSignal(0.1)
  end
else
  gpu.set(1, 4, "Shell not found at " .. tostring(shell_path))
end

gpu.set(1, 6, "Usermode done.")
