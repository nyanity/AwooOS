--
-- /system/lib/dk/kmd_api.lua
--

local fSyscall = syscall
local tStatus = require("errcheck")
local oKMD = require("common_api") 

local function CallDkms(sName, ...)
  local bOk, val1, val2 = fSyscall(sName, ...)
  return val1, val2
end

function oKMD.DkCreateDevice(pDriverObject, sDeviceName)
  oKMD.DkPrint("DkCreateDevice: " .. sDeviceName)
  
  -- Removed pDriverObject.nDriverPid.
  -- DKMS will automatically determine the caller's PID.
  local pDeviceObject, nStatus = CallDkms("dkms_create_device", sDeviceName)
  
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
    -- direct syscall, returns data immediately
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

function oKMD.DkCreateComponentDevice(pDriverObject, sDeviceTypeName)
  -- 1. Verify we are actually a component driver
  local sAddress = env.address
  if not sAddress then
    oKMD.DkPrint("DkCreateComponentDevice: No address in env! Are you a CMD?")
    return tStatus.STATUS_INVALID_PARAMETER
  end
  
  -- 2. Get the next available index from DKMS
  local nIndex, _ = CallDkms("dkms_get_next_index", sDeviceTypeName)
  if not nIndex then nIndex = 0 end -- fallback, shouldn't happen
  
  -- 3. Format the names
  -- short address is first 6 chars. enough to be unique-ish.
  local sShortAddr = string.sub(sAddress, 1, 6)
  
  -- Internal Kernel Name: \Device\iter_a1b2c3
  -- We don't strictly need the index here if address is unique, but let's keep it clean.
  local sInternalName = string.format("\\Device\\%s_%s", sDeviceTypeName, sShortAddr)
  
  -- User-facing Symlink: /dev/iter_a1b2c3_0
  local sSymlinkName = string.format("/dev/%s_%s_%d", sDeviceTypeName, sShortAddr, nIndex)
  
  oKMD.DkPrint("Auto-creating CMD Device: " .. sSymlinkName)
  
  -- 4. Create the Device Object
  local nStatus, pDeviceObject = oKMD.DkCreateDevice(pDriverObject, sInternalName)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    return nStatus, nil
  end
  
  -- 5. Create the Symlink
  nStatus = oKMD.DkCreateSymbolicLink(sSymlinkName, sInternalName)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkDeleteDevice(pDeviceObject)
    return nStatus, nil
  end
  
  -- Store the auto-generated names in the extension so we can delete them later easily
  pDeviceObject.pDeviceExtension.sAutoSymlink = sSymlinkName
  
  return tStatus.STATUS_SUCCESS, pDeviceObject
end

return oKMD