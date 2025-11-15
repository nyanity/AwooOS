local raw_component = require("component")
local raw_computer = require("computer")

raw_computer.beep(800, 0.1)

-- Find the TTY and GPU to print status messages
local gpu_address
local tty_address

for addr, comp_type in raw_component.list("gpu") do
  gpu_address = addr
  break
end
for addr, comp_type in raw_component.list("screen") do
  tty_address = addr
  break
end

local gpu
local tty

local function print(text)
  if not text then text = "nil" end
  if tty and gpu then
    gpu.set(1, 1, tostring(text))
  end
end

local function cls()
  if tty and gpu then
    gpu.fill(1, 1, 160, 50, " ")
  end
end

if gpu_address and tty_address then
  gpu = raw_component.proxy(gpu_address)
  tty = raw_component.proxy(tty_address)
  pcall(gpu.bind, tty_address)
  cls()
  print("AwooOS BIOS v0.2NV25RC00")
  gpu.set(1, 2, "Scanning for bootable drives...")
else
  -- No screen, just beep and hope
  raw_computer.beep(500, 0.5)
end

local boot_fs_address = nil
local kernel_code = nil

for addr, comp_type in raw_component.list("filesystem") do
  if boot_fs_address then break end
  
  local fs = raw_component.proxy(addr)
  if fs.exists("/kernel.lua") then
    gpu.set(1, 3, "Found kernel on " .. addr)
    local f, reason = fs.open("/kernel.lua", "r")
    if f then
      local buffer = ""
      while true do
        local chunk, read_reason = fs.read(f, math.huge)
        if not chunk then
          break -- EOF or error
        end
        buffer = buffer .. chunk
      end
      fs.close(f)
      
      kernel_code = buffer
      boot_fs_address = addr
      gpu.set(1, 4, "Kernel loaded (" .. #kernel_code .. " bytes).")
    else
      gpu.set(1, 4, "Found kernel, but failed to open: " .. tostring(reason))
    end
  end
end

if kernel_code then
  -- We have a kernel. Load it into a function.
  -- We create a pristine environment for it.
  -- The kernel will be responsible for setting up its own globals.
  local kernel_env = {}
  
  -- Pass the raw APIs and boot address to the kernel's environment.
  kernel_env.raw_component = raw_component
  kernel_env.raw_computer = raw_computer
  kernel_env.boot_fs_address = boot_fs_address
  
  
  local kernel_func, load_err = load(kernel_code, "kernel", "t", kernel_env)
  
  if kernel_func then
    gpu.set(1, 5, "Executing kernel...")
    raw_computer.beep(1200, 0.1)
    
    -- This is the handoff. The kernel_func MUST NOT return.
    -- We pcall it so we can catch a top-level kernel panic.
    local ok, panic_err = pcall(kernel_func)
    
    if not ok then
      -- Kernel Panicked during init
      cls()
      print("KERNEL PANIC")
      gpu.set(1, 3, "The kernel failed to initialize.")
      gpu.set(1, 5, tostring(panic_err))
      raw_computer.beep(400, 0.2)
      raw_computer.beep(400, 0.2)
      raw_computer.beep(400, 0.2)
      -- Wait for 10s then shutdown
      raw_computer.sleep(10)
      raw_computer.shutdown()
    end
  else
    cls()
    print("BOOT FAILED")
    gpu.set(1, 3, "Kernel file is corrupt and failed to load.")
    gpu.set(1, 5, tostring(load_err))
    raw_computer.beep(500, 1)
    raw_computer.sleep(10)
    raw_computer.shutdown()
  end
else
  cls()
  print("BOOT FAILED")
  gpu.set(1, 3, "No bootable medium found.")
  gpu.set(1, 4, "Insert an AwooOS-formatted drive and reboot.")
  raw_computer.beep(600, 0.2)
  raw_computer.beep(500, 0.2)
  raw_computer.beep(400, 0.2)
  raw_computer.sleep(10)
  raw_computer.shutdown()
end