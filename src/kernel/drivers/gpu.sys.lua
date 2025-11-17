--
-- /drivers/gpu.sys.lua
-- a simple proxy driver. it takes requests and just passes them on.
-- the middleman for the graphics card.
--
    
local syscall = syscall

-- driver's own identity
local sMyAddress = env.address
local bPidOk, nMyPid = syscall("process_get_pid")

-- let the pipeline manager know we're alive and kicking
syscall("signal_send", 2, "driver_ready", nMyPid)

-- the main event loop. just wait for work.
while true do
  local tReturnValues = {syscall("signal_pull")}
  local bIsOk = tReturnValues[1]
  local sSignalName = tReturnValues[3] -- signal pull returns true, sender, name, ...
  
  if bIsOk and sSignalName == "gpu_invoke" then
    local nSenderPid = tReturnValues[2]
    local sMethod = tReturnValues[4]
    
    -- do the actual hardware call
    local bInvokeOk, valRet1, valRet2 = syscall("raw_component_invoke", sMyAddress, sMethod, table.unpack(tReturnValues, 5, #tReturnValues))
    
    -- send the result back to whoever asked
    syscall("signal_send", nSenderPid, "gpu_return", bInvokeOk, valRet1, valRet2)
  end
end