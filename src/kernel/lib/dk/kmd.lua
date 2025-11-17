--
-- dk/kmd.lua
-- the Kernel Mode Driver Kit. the keys to the kingdom.
-- this is the API for Ring 2 drivers. it's powerful and dangerous.
--

local oKmdApi = {}

-- Log a message to the kernel's boot/system log.
-- @param sMessage (string): The message to log.
function oKmdApi.fLog(sMessage)
  syscall("kernel_log", sMessage)
end

-- Get the PID of the current driver process.
-- @return (number): The process ID.
function oKmdApi.fGetPid()
  local bOk, nPid = syscall("process_get_pid")
  return nPid
end

-- Directly invoke a method on a hardware component.
-- This is the core of a KMD.
-- @param sAddress (string): The component's address.
-- @param sMethod (string): The method name to call.
-- @param ...: Arguments for the method.
-- @return (boolean, ...): pcall-style return: success flag, followed by results or error.
function oKmdApi.fInvokeRawComponent(sAddress, sMethod, ...)
  return syscall("raw_component_invoke", sAddress, sMethod, ...)
end

-- Get a raw proxy object for a component.
-- @param sAddress (string): The component's address.
-- @return (boolean, object/string): Success flag, and the proxy or an error message.
function oKmdApi.fGetRawProxy(sAddress)
    return syscall("raw_component_proxy", sAddress)
end

-- Send a signal to another process.
-- @param nTargetPid (number): The PID to send the signal to.
-- @param ...: The signal payload (name, args...).
-- @return (boolean, string): Success flag, and error message on failure.
function oKmdApi.fSendSignal(nTargetPid, ...)
    return syscall("signal_send", nTargetPid, ...)
end

-- Pull for a signal. This will yield the driver process.
-- @return (boolean, ...): pcall-style return: success, followed by signal payload.
function oKmdApi.fPullSignal()
    return syscall("signal_pull")
end

-- Yield the current process, giving CPU time back to the scheduler.
function oKmdApi.fYield()
    syscall("process_yield")
end

return oKmdApi