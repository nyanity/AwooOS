--
-- dk/umd.lua
-- the User Mode Driver Kit. playing in the sandbox.
-- this is the restricted API for Ring 3 drivers.
-- no direct hardware access. all requests go through the system.
--

local oUmdApi = {}
local nMyPid = syscall("process_get_pid")

-- Log a message. This is a restricted, less privileged log.
-- @param sMessage (string): The message to log.
function oUmdApi.fLog(sMessage)
  -- UMDs can't use kernel_log. They have to print, which goes to the TTY.
  print("[UMD " .. tostring(nMyPid) .. "] " .. sMessage)
end

-- Send a request to a Kernel Mode Driver.
-- This is the primary way a UMD interacts with hardware.
-- @param nKmdPid (number): The PID of the target KMD.
-- @param tRequest (table): The request payload.
-- @return (boolean, string): Success flag of the send operation.
function oUmdApi.fSendRequest(nKmdPid, tRequest)
  return syscall("signal_send", nKmdPid, "umd_request", tRequest)
end

-- Pull for a signal/response.
-- @return (boolean, ...): pcall-style return: success, followed by signal payload.
function oUmdApi.fPullEvent()
    return syscall("signal_pull")
end

-- Yield the current process.
function oUmdApi.fYield()
    syscall("process_yield")
end

return oUmdApi