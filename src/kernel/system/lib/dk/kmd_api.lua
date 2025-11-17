--
-- /system/lib/dk/kmd_api.lua
-- the keys to the kingdom. this is the api for kernel mode drivers.
-- with great power comes great responsibility to not panic the kernel.
--

local fSyscall = syscall
local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oKMD = require("common_api") -- inherit common functions

-- DkCreateDevice
-- "i am a driver, and i declare this new device exists. respect my authority."
function oKMD.DkCreateDevice(pDriverObject, sDeviceName)
  oKMD.DkPrint("DkCreateDevice called for '" .. sDeviceName .. "'")
  local bOk, pDeviceObject, nStatus = fSyscall("dkms_create_device", pDriverObject.nDriverPid, sDeviceName)
  if bOk and pDeviceObject then
    return tStatus.STATUS_SUCCESS, pDeviceObject
  else
    return nStatus or tStatus.STATUS_UNSUCCESSFUL, nil
  end
end

-- DkCreateSymbolicLink
-- gives a device a friendly name in the filesystem, like /dev/tty
function oKMD.DkCreateSymbolicLink(sLinkName, sDeviceName)
  oKMD.DkPrint("DkCreateSymbolicLink: '" .. sLinkName .. "' -> '" .. sDeviceName .. "'")
  local bOk, nStatus = fSyscall("dkms_create_symlink", sLinkName, sDeviceName)
  return nStatus
end

-- DkDeleteDevice
-- "this device's watch has ended."
function oKMD.DkDeleteDevice(pDeviceObject)
  oKMD.DkPrint("DkDeleteDevice called for '" .. pDeviceObject.sDeviceName .. "'")
  local bOk, nStatus = fSyscall("dkms_delete_device", pDeviceObject.sDeviceName)
  return nStatus
end

-- DkDeleteSymbolicLink
-- removes the friendly name from the filesystem.
function oKMD.DkDeleteSymbolicLink(sLinkName)
  oKMD.DkPrint("DkDeleteSymbolicLink: '" .. sLinkName .. "'")
  local bOk, nStatus = fSyscall("dkms_delete_symlink", sLinkName)
  return nStatus
end

-- DkCompleteRequest
-- "i'm done with this job. here's the result."
function oKMD.DkCompleteRequest(pIrp, nStatus, vInformation)
  pIrp.tIoStatus.nStatus = nStatus
  pIrp.tIoStatus.vInformation = vInformation
  -- this syscall tells the I/O manager (DKMS) that the IRP is finished
  -- and the original caller can be woken up.
  fSyscall("dkms_complete_irp", pIrp)
end

-- DkGetHardwareProxy
-- the raw, unfiltered connection to a component. use with caution.
function oKMD.DkGetHardwareProxy(sAddress)
    local bOk, oProxyOrErr = fSyscall("raw_component_proxy", sAddress)
    if bOk then
        return tStatus.STATUS_SUCCESS, oProxyOrErr
    else
        return tStatus.STATUS_NO_SUCH_DEVICE, oProxyOrErr
    end
end

-- DkRegisterInterrupt
-- allows a driver to listen for hardware events (like key_down)
function oKMD.DkRegisterInterrupt(sEventName)
    local bOk, nStatus = fSyscall("dkms_register_interrupt", sEventName)
    return nStatus
end

return oKMD