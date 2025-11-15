local oRawComponent = require("component")
local oRawComputer = require("computer")

oRawComputer.beep(800, 0.1) -- a little beep to say "i'm alive!"

-- try to find a screen so we're not booting blind.
local sGpuAddress
local sTtyAddress

for sAddr, sCompType in oRawComponent.list("gpu") do
  sGpuAddress = sAddr
  break
end
for sAddr, sCompType in oRawComponent.list("screen") do
  sTtyAddress = sAddr
  break
end

local oGpu
local oTty

-- a super primitive print function for BIOS messages.
local function print(sText)
  if not sText then sText = "nil" end -- because printing actual nil is a no-go.
  if oTty and oGpu then
    oGpu.set(1, 1, tostring(sText))
  end
end

-- clear screen.
local function cls()
  if oTty and oGpu then
    oGpu.fill(1, 1, 160, 50, " ")
  end
end

if sGpuAddress and sTtyAddress then
  oGpu = oRawComponent.proxy(sGpuAddress)
  oTty = oRawComponent.proxy(sTtyAddress)
  pcall(oGpu.bind, sTtyAddress)
  cls()
  print("AuraOS BIOS v0.1")
  oGpu.set(1, 2, "Scanning for bootable drives...")
else
  -- no screen? well, this is awkward. beep and hope for the best.
  oRawComputer.beep(500, 0.5)
end

local sBootFsAddress = nil
local sKernelCode = nil

-- let's go hunting for a bootable drive.
for sAddr, sCompType in oRawComponent.list("filesystem") do
  if sBootFsAddress then break end
  
  local oFs = oRawComponent.proxy(sAddr)
  if oFs.exists("/kernel.lua") then
    -- jackpot! found a kernel.
    oGpu.set(1, 3, "Found kernel on " .. sAddr)
    local hFile, sReason = oFs.open("/kernel.lua", "r")
    if hFile then
      local sBuffer = ""
      while true do
        -- slurp the whole file into a string. memory is cheap, right?
        local sChunk, sReadReason = oFs.read(hFile, math.huge)
        if not sChunk then
          break -- EOF or error
        end
        sBuffer = sBuffer .. sChunk
      end
      oFs.close(hFile)
      
      sKernelCode = sBuffer
      sBootFsAddress = sAddr
      oGpu.set(1, 4, "Kernel loaded (" .. #sKernelCode .. " bytes).")
    else
      -- the universe is cruel. the file is there but we can't open it.
      oGpu.set(1, 4, "Found kernel, but failed to open: " .. tostring(sReason))
    end
  end
end

if sKernelCode then
  -- we have a kernel! time to prep for launch.
  -- create a clean, pristine environment for the kernel. no pollution from us.
  local tKernelEnv = {}
  
  -- give the kernel the raw tools it needs to take over.
  tKernelEnv.raw_component = oRawComponent
  tKernelEnv.raw_computer = oRawComputer
  tKernelEnv.boot_fs_address = sBootFsAddress
  
  -- compile the kernel code string into a function.
  local fKernelFunc, sLoadErr = load(sKernelCode, "kernel", "t", tKernelEnv)
  
  if fKernelFunc then
    oGpu.set(1, 5, "Executing kernel...")
    oRawComputer.beep(1200, 0.1)
    
    -- this is the handoff. if this function ever returns, something is very wrong.
    -- wrap it in a pcall. our last line of defense against an immediate kernel crash.
    local bOk, sPanicErr = pcall(fKernelFunc)
    
    if not bOk then
      -- well, that was fast. the kernel died on takeoff.
      cls()
      print("KERNEL PANIC")
      oGpu.set(1, 3, "The kernel failed to initialize.")
      oGpu.set(1, 5, tostring(sPanicErr))
      oRawComputer.beep(400, 0.2); oRawComputer.beep(400, 0.2); oRawComputer.beep(400, 0.2)
      -- display the BSOD for 10 seconds, then pull the plug.
      oRawComputer.sleep(10)
      oRawComputer.shutdown()
    end
  else
    -- the kernel file is borked. can't even compile it.
    cls()
    print("BOOT FAILED")
    oGpu.set(1, 3, "Kernel file is corrupt and failed to load.")
    oGpu.set(1, 5, tostring(sLoadErr))
    oRawComputer.beep(500, 1)
    oRawComputer.sleep(10)
    oRawComputer.shutdown()
  end
else
  -- couldn't find a kernel anywhere. sad beep.
  cls()
  print("BOOT FAILED")
  oGpu.set(1, 3, "No bootable medium found.")
  oGpu.set(1, 4, "Insert an AuraOS-formatted drive and reboot.")
  oRawComputer.beep(600, 0.2); oRawComputer.beep(500, 0.2); oRawComputer.beep(400, 0.2)
  oRawComputer.sleep(10)
  oRawComputer.shutdown()
end