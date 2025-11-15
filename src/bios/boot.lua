-- BIOS. Bare metal. No `require`, just raw power.
computer.beep(800, 0.1) -- boot beep.
local sGpuAddress
local sScreenAddress

-- find a screen, don't fly blind.
for sAddr in component.list("gpu") do sGpuAddress = sAddr; break end
for sAddr in component.list("screen") do sScreenAddress = sAddr; break end

local oGpu -- gpu proxy object
-- primitive print for boot screen.
local function print(nY, sText)
  if oGpu then
    oGpu.fill(1, nY, 160, 1, " ")
    oGpu.set(1, nY, tostring(sText or "nil"))
  end
end

-- clear screen.
local function cls()
  if oGpu then oGpu.fill(1, 1, 160, 50, " ") end
end

if sGpuAddress and sScreenAddress then
  oGpu = component.proxy(sGpuAddress)
  local bOk, sReason = pcall(oGpu.bind, sScreenAddress) -- pcall, screen might be weird.
  if not bOk then
    oGpu = nil -- no gpu for us. sad.
    computer.beep(500, 0.5)
  else
    cls()
    print(1, "AwooOS BIOS v0.2NV25RC00 (Bare-metal)")
    print(2, "Scanning for bootable drives...")
  end
else
  computer.beep(500, 0.5) -- beep of solitude.
end

local sBootFsAddress = nil
local sKernelCode = nil

-- hunt for a kernel.
for sAddr in component.list("filesystem") do
  if sBootFsAddress then break end -- already found one.
  local oFs = component.proxy(sAddr)
  if oFs.exists("/kernel.lua") then
    print(3, "Found kernel on " .. sAddr:sub(1, 13) .. "...")
    local hFile, sReason = oFs.open("/kernel.lua", "r")
    if hFile then
      local sBuffer = ""
      while true do
        local sChunk = oFs.read(hFile, math.huge) -- slurp the whole thing.
        if not sChunk then break end
        sBuffer = sBuffer .. sChunk
      end
      oFs.close(hFile)
      sKernelCode = sBuffer
      sBootFsAddress = sAddr
      print(4, "Kernel loaded (" .. #sKernelCode .. " bytes).")
    else
      print(4, "Kernel found, but can't open: " .. tostring(sReason)) -- cruel.
    end
  end
end

if sKernelCode then
  -- dreaded UTF-8 BOM. some editors love it. we don't. begone.
  local sBom = string.char(239, 187, 191)
  if sKernelCode:sub(1, 3) == sBom then
    sKernelCode = sKernelCode:sub(4) -- strip it
    print(4, "Kernel loaded (" .. #sKernelCode .. " bytes). BOM removed.")
  end

  local tKernelEnv = {}
  tKernelEnv.raw_component = component
  tKernelEnv.raw_computer = computer
  tKernelEnv.boot_fs_address = sBootFsAddress
  setmetatable(tKernelEnv, { __index = _G }) -- let kernel peek at _G. a little cheat.

  local fKernelFunc, sLoadErr = load(sKernelCode, "kernel.lua", "t", tKernelEnv)
  
  if fKernelFunc then
    print(5, "Executing kernel...")
    computer.beep(1200, 0.1)

    local bOk, sPanicErr = pcall(fKernelFunc) -- handoff. our last line of defense.
    
    if not bOk then
      cls()
      print(1, "KERNEL PANIC")
      print(3, "The kernel failed to initialize.")
      print(5, tostring(sPanicErr))
      computer.beep(400, 0.2)
      computer.shutdown()
    end
    -- a well-behaved kernel should never return. this is a clean halt.
    cls()
    print(1, "KERNEL HALTED")
    print(3, "Kernel returned control to BIOS. Shutting down.")
    computer.sleep(10)
    computer.shutdown()
  else
    cls()
    print(1, "BOOT FAILED")
    print(3, "Kernel file is corrupt.")
    print(5, tostring(sLoadErr))
    computer.beep(500, 1)
    computer.shutdown()
  end
else
  cls()
  print(1, "BOOT FAILED")
  print(3, "No bootable medium found.")
  computer.beep(600, 0.2)
  computer.shutdown()
end
