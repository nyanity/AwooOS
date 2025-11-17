--
-- /system/driverdispatch.lua
-- the grand central station for all i/o.
-- this figures out which driver needs to handle a request and sends it on its way.
-- this is a library, not a process. it's required by dkms.
--

local tStatus = require("errcheck")
local oDispatch = {}

-- this is the main entry point for all i/o requests from the vfs.
function oDispatch.DispatchIrp(pIrp, g_tDeviceTree)
  local pDeviceObject = g_tDeviceTree[pIrp.sDeviceName]
  
  if not pDeviceObject then
    syscall("kernel_log", "[DD] Error: No device object for '" .. pIrp.sDeviceName .. "'")
    return tStatus.STATUS_NO_SUCH_DEVICE
  end
  
  local pDriverObject = pDeviceObject.pDriverObject
  if not pDriverObject then
    syscall("kernel_log", "[DD] Error: Device '" .. pIrp.sDeviceName .. "' has no driver object!")
    return tStatus.STATUS_INVALID_DRIVER_OBJECT
  end
  
  local fHandler = pDriverObject.tDispatch[pIrp.nMajorFunction]
  
  if not fHandler then
    -- if there's no specific handler, it's not implemented.
    syscall("kernel_log", "[DD] Driver '" .. pDriverObject.tDriverInfo.sDriverName .. "' does not implement handler for Major Function " .. pIrp.nMajorFunction)
    return tStatus.STATUS_NOT_IMPLEMENTED
  end
  
  -- ok, we found the driver and the right function to call.
  -- send a signal to the driver's process, telling it to execute the handler.
  syscall("kernel_log", "[DD] Dispatching IRP " .. pIrp.nMajorFunction .. " to PID " .. pDriverObject.nDriverPid)
  syscall("signal_send", pDriverObject.nDriverPid, "irp_dispatch", pIrp, fHandler)
  
  -- the operation is now in the hands of the driver. it will complete asynchronously.
  return tStatus.STATUS_PENDING
end

return oDispatch