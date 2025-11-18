--
-- /system/lib/dk/kmd_api.lua
--
local fSyscall = syscall
local tStatus = require("errcheck")
local oKMD = require("common_api") 

local function CallDkms(sName, ...)
  -- intercepted syscalls return: true (from the scheduler), result...
  local bOk, val1, val2 = fSyscall(sName, ...)
  return val1, val2
end

function oKMD.DkCreateDevice(pDriverObject, sDeviceName)
  oKMD.DkPrint("DkCreateDevice: " .. sDeviceName)
  -- wrapping
  local pDeviceObject, nStatus = CallDkms("dkms_create_device", pDriverObject.nDriverPid, sDeviceName)
  
  if pDeviceObject then
    return tStatus.STATUS_SUCCESS, pDeviceObject
  else
    return nStatus or tStatus.STATUS_UNSUCCESSFUL, nil
  end
end

function oKMD.DkCreateSymbolicLink(sLinkName, sDeviceName)
  oKMD.DkPrint("SymLink: " .. sLinkName .. " -> " .. sDeviceName)
  local nStatus = CallDkms("dkms_create_symlink", sLinkName, sDeviceName)
  return nStatus
end

function oKMD.DkDeleteDevice(pDeviceObject)
  if not pDeviceObject or type(pDeviceObject) ~= "table" then return tStatus.STATUS_INVALID_PARAMETER end
  local nStatus = CallDkms("dkms_delete_device", pDeviceObject.sDeviceName)
  return nStatus
end

function oKMD.DkDeleteSymbolicLink(sLinkName)
  local nStatus = CallDkms("dkms_delete_symlink", sLinkName)
  return nStatus
end

function oKMD.DkCompleteRequest(pIrp, nStatus, vInformation)
  pIrp.tIoStatus.nStatus = nStatus
  pIrp.tIoStatus.vInformation = vInformation
  fSyscall("dkms_complete_irp", pIrp)
end

function oKMD.DkGetHardwareProxy(sAddress)
    -- raw_component_proxy is a DIRECT syscall, it does NOT return an extra true
    local oProxyOrErr, sErr = fSyscall("raw_component_proxy", sAddress)
    if oProxyOrErr then
        return tStatus.STATUS_SUCCESS, oProxyOrErr
    else
        return tStatus.STATUS_NO_SUCH_DEVICE, sErr
    end
end

function oKMD.DkRegisterInterrupt(sEventName)
    local nStatus = CallDkms("dkms_register_interrupt", sEventName)
    return nStatus
end

return oKMD