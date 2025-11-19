--
-- /drivers/ntm_fusion.sys.lua
-- Driver for the HBM's Nuclear Tech Mod ITER Fusion Reactor.
-- Its job is to tame the artificial sun and prevent it from disassembling itself
-- and the surrounding landscape. No pressure.
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AwooITER",
  sDriverType = tDKStructs.DRIVER_TYPE_CMD,
  nLoadPriority = 300,
  sVersion = "1.0.0-rc1",
  
  sSupportedComponent = "ntm_fusion" 
}

local g_pDeviceObject = nil

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

local function fIterDispatchCreate(pDeviceObject, pIrp)
  -- oKMD.DkPrint("ITER: Connection established.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fIterDispatchClose(pDeviceObject, pIrp)
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fIterDispatchDeviceControl(pDeviceObject, pIrp)
  local tParams = pIrp.tParameters
  local sMethod = tParams.sMethod
  local tArgs = tParams.tArgs or {}
  
  if not sMethod then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
    return
  end
  
  local oProxy = pDeviceObject.pDeviceExtension.oIterProxy
  if not oProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
    return
  end
  
  local bIsOk, ... = pcall(oProxy[sMethod], table.unpack(tArgs))
  
  if bIsOk then
    local tReturnValues = {...}
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, tReturnValues)
  else
    local sErrorMsg = ...
    oKMD.DkPrint("ITER: Hardware invocation failed for '" .. sMethod .. "': " .. tostring(sErrorMsg))
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErrorMsg)
  end
end


-------------------------------------------------
-- DRIVER ENTRY
-------------------------------------------------

function DriverEntry(pDriverObject)
  oKMD.DkPrint("AwooITER: Initializing Component Mode Driver.")
  
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fIterDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fIterDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fIterDispatchDeviceControl
  
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\FusionReactor0")
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  g_pDeviceObject = pDeviceObj
  
  local nStatus, pDeviceObj = oKMD.DkCreateComponentDevice(pDriverObject, "iter")

  if nStatus ~= tStatus.STATUS_SUCCESS then 
    oKMD.DkPrint("ITER: Failed to create auto-device.")
    return nStatus 
  end
  g_pDeviceObject = pDeviceObj
  
  -- The address is GUARANTEED by DKMS because we are a CMD.
  local sMyAddress = env.address
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sMyAddress)
  
  if nProxyStatus ~= tStatus.STATUS_SUCCESS then
    return nProxyStatus
  end
  
  g_pDeviceObject.pDeviceExtension.oIterProxy = oProxy
  
  oKMD.DkPrint("AwooITER: Online.")
  raw_computer.pullSignal(3)
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  -- Cleanup using the stored name
  if g_pDeviceObject and g_pDeviceObject.pDeviceExtension.sAutoSymlink then
     oKMD.DkDeleteSymbolicLink(g_pDeviceObject.pDeviceExtension.sAutoSymlink)
  end
  oKMD.DkDeleteDevice(g_pDeviceObject)
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN LOOP
-------------------------------------------------
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      pDriverObject.fDriverUnload = DriverUnload
      local nStatus = DriverEntry(pDriverObject)
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end