--
-- /system/lib/dk/kmd_api.lua
--

local fSyscall = syscall
local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oKMD = require("common_api") 

function oKMD.DkCreateDevice(pDriverObject, sDeviceName)
  oKMD.DkPrint("DkCreateDevice called for '" .. sDeviceName .. "'")
  -- accepting obj directyl
  local pDeviceObject, nStatus = fSyscall("dkms_create_device", pDriverObject.nDriverPid, sDeviceName)
  
  if pDeviceObject then
    return tStatus.STATUS_SUCCESS, pDeviceObject
  else
    return nStatus or tStatus.STATUS_UNSUCCESSFUL, nil
  end
end

function oKMD.DkCreateSymbolicLink(sLinkName, sDeviceName)
  oKMD.DkPrint("DkCreateSymbolicLink: '" .. sLinkName .. "' -> '" .. sDeviceName .. "'")
  -- accepting status only
  local nStatus = fSyscall("dkms_create_symlink", sLinkName, sDeviceName)
  return nStatus
end

function oKMD.DkDeleteDevice(pDeviceObject)
  if not pDeviceObject or type(pDeviceObject) ~= "table" then return tStatus.STATUS_INVALID_PARAMETER end
  oKMD.DkPrint("DkDeleteDevice called for '" .. pDeviceObject.sDeviceName .. "'")
  local nStatus = fSyscall("dkms_delete_device", pDeviceObject.sDeviceName)
  return nStatus
end

function oKMD.DkDeleteSymbolicLink(sLinkName)
  oKMD.DkPrint("DkDeleteSymbolicLink: '" .. sLinkName .. "'")
  local nStatus = fSyscall("dkms_delete_symlink", sLinkName)
  return nStatus
end

function oKMD.DkCompleteRequest(pIrp, nStatus, vInformation)
  pIrp.tIoStatus.nStatus = nStatus
  pIrp.tIoStatus.vInformation = vInformation
  fSyscall("dkms_complete_irp", pIrp)
end

function oKMD.DkGetHardwareProxy(sAddress)
    -- kernel.lua returns proxy or nil+err
    local oProxyOrErr, sErr = fSyscall("raw_component_proxy", sAddress)
    if oProxyOrErr then
        return tStatus.STATUS_SUCCESS, oProxyOrErr
    else
        return tStatus.STATUS_NO_SUCH_DEVICE, sErr
    end
end

function oKMD.DkRegisterInterrupt(sEventName)
    local nStatus = fSyscall("dkms_register_interrupt", sEventName)
    return nStatus
end

return oKMD