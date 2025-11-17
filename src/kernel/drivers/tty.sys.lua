--
-- /drivers/tty.sys.lua
-- the teletype driver. turns key presses into pixels and back again. it's basically magic.
--

local syscall = syscall

-- configuration from environment
local sGpuAddress = env.gpu
local sScreenAddress = env.screen
local bPidOk, nMyPid = syscall("process_get_pid")

if not sGpuAddress or not sScreenAddress then
  syscall("kernel_panic", "TTY Driver started without GPU or Screen address.")
end

-- get proxies for our hardware
local bIsGpuOk, oGpuProxy = syscall("raw_component_proxy", sGpuAddress)
if not bIsGpuOk or not oGpuProxy then syscall("kernel_panic", "TTY driver failed to get GPU proxy.") end

local bIsScreenOk, oScreenProxy = syscall("raw_component_proxy", sScreenAddress)
if not bIsScreenOk or not oScreenProxy then syscall("kernel_panic", "TTY driver failed to get Screen proxy.") end

-- our internal state for the screen buffer
local tTtyState = {}

-- initialization
syscall("raw_component_invoke", sGpuAddress, "bind", sScreenAddress)
local bSyscallOk, bInvokeOk, nWidth, nHeight = syscall("raw_component_invoke", sGpuAddress, "getResolution")
if not (bSyscallOk and bInvokeOk) then
  syscall("kernel_panic", "TTY: Failed to get screen resolution.")
end
tTtyState.nWidth, tTtyState.nHeight = nWidth, nHeight
syscall("raw_component_invoke", sGpuAddress, "fill", 1, 1, tTtyState.nWidth, tTtyState.nHeight, " ")
syscall("raw_component_invoke", sGpuAddress, "setForeground", 0xEEEEEE)
syscall("raw_component_invoke", sGpuAddress, "setBackground", 0x000000)
tTtyState.nCursorX = 1
tTtyState.nCursorY = 1

-- the screen is full, time to push everything up. gravity, but for text.
function tTtyState.scroll()
  local tReturns = {syscall("raw_component_invoke", sGpuAddress, "copy", 1, 2, tTtyState.nWidth, tTtyState.nHeight - 1, 0, -1)}
  if not (tReturns[1] and tReturns[2]) then
    syscall("kernel_log", "[TTY-ERROR] gpu.copy failed: " .. tostring(tReturns[3]))
  end
  
  tReturns = {syscall("raw_component_invoke", sGpuAddress, "fill", 1, tTtyState.nHeight, tTtyState.nWidth, 1, " ")}
  if not (tReturns[1] and tReturns[2]) then
    syscall("kernel_log", "[TTY-ERROR] gpu.fill failed: " .. tostring(tReturns[3]))
  end
  
  tTtyState.nCursorY = tTtyState.nHeight
end

-- painting characters onto the screen, one by one.
function tTtyState.write(sText)
  for sChar in string.gmatch(tostring(sText), ".") do
    if sChar == "\n" then
      tTtyState.nCursorX = 1
      tTtyState.nCursorY = tTtyState.nCursorY + 1
    else
      local tReturns = {syscall("raw_component_invoke", sGpuAddress, "set", tTtyState.nCursorX, tTtyState.nCursorY, tostring(sChar))}
      local bIsSyscallOk = tReturns[1]
      local bIsInvokeOk = tReturns[2]
      
      if not (bIsSyscallOk and bIsInvokeOk) then
        local sErrMsg = tReturns[3]
        syscall("kernel_log", "[TTY-ERROR] gpu.set failed: " .. tostring(sErrMsg))
      end
      
      tTtyState.nCursorX = tTtyState.nCursorX + 1
      if tTtyState.nCursorX > tTtyState.nWidth then
        tTtyState.nCursorX = 1
        tTtyState.nCursorY = tTtyState.nCursorY + 1
      end
    end
    if tTtyState.nCursorY > tTtyState.nHeight then
      tTtyState.scroll()
    end
  end
end

-- managing the read loop. are we waiting for input or just chilling?
local tReadState = {
  sMode = "idle", -- "idle"/"reading"
  nReadRequesterPid = nil,
  sLineBuffer = ""
}

syscall("kernel_log", "[TTY PID " .. tostring(nMyPid) .. "] Initialized. Sending 'driver_ready'.")
syscall("signal_send", 2, "driver_ready", tostring(nMyPid)) 

-- main driver loop. listening for whispers on the wind (or, you know, s i g n a l s).
while true do
  local bSyscallOk, bPullOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")

  if bPullOk then
    syscall("kernel_log", string.format("[TTY-DEBUG] Pulled signal: '%s' from PID %s", tostring(sSignalName), tostring(nSenderPid)))
  end

  if bSyscallOk and bPullOk then
    
    if sSignalName == "tty_write" then
      local sData = p2
      tTtyState.write(tostring(sData))
    
    elseif sSignalName == "tty_read" then
      if tReadState.sMode == "idle" then
        tReadState.sMode = "reading"
        tReadState.nReadRequesterPid = p1
        tReadState.sLineBuffer = ""
      else
        -- someone else is already trying to read. tell the new guy to wait.
        syscall("signal_send", p1, "syscall_return", false, "TTY busy")
      end

    elseif sSignalName == "os_event" then
      local sEventName = p1
      if sEventName == "key_down" and tReadState.sMode == "reading" then
        local sChar = p3
        local nCode = p4
        
        if nCode == 28 then -- Enter
          tTtyState.write("\n")
          syscall("signal_send", tReadState.nReadRequesterPid, "syscall_return", true, tReadState.sLineBuffer)
          tReadState.sMode = "idle"
          tReadState.nReadRequesterPid = nil
          
        elseif nCode == 14 then -- Backspace
          if #tReadState.sLineBuffer > 0 then
            tReadState.sLineBuffer = string.sub(tReadState.sLineBuffer, 1, -2)
            tTtyState.nCursorX = tTtyState.nCursorX - 1
            if tTtyState.nCursorX < 1 then tTtyState.nCursorX = 1 end
            syscall("raw_component_invoke", sGpuAddress, "set", tTtyState.nCursorX, tTtyState.nCursorY, " ")
          end
        else
          if sChar and #sChar > 0 then
            tReadState.sLineBuffer = tReadState.sLineBuffer .. sChar
            tTtyState.write(sChar)
          end
        end
      end
    end
  end
end