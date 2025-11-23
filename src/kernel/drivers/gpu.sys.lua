--
-- /drivers/gpu.sys.lua
-- the gpu driver, remade for the new world order.
-- it's still a middleman, but now it's a middleman with a fancy suit and a proper job title.
-- it exposes the gpu component as a standard system device.
--

-- our driver development kit. don't leave home without it.
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

-- static info for DKMS. this is our driver's resume.
g_tDriverInfo = {
  sDriverName = "AxisGPU",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 150, -- important, but less so than the initial TTY
  sVersion = "1.0.0",
}

-- module-level state. we only manage one device, so this is fine.
local g_pDeviceObject = nil

-------------------------------------------------
-- IRP HANDLERS
-- the functions that do the actual work when someone talks to our device.
-------------------------------------------------

-- called on fs.open("/dev/gpu0")
-- lets an application get a handle to us.
local function fGpuDispatchCreate(pDeviceObject, pIrp)
  oKMD.DkPrint("GPU: IRP_MJ_CREATE received. Granting handle.")
  -- nothing to do here but say "ok".
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- called on fs.close(handle)
local function fGpuDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("GPU: IRP_MJ_CLOSE received. Releasing handle.")
  -- again, nothing to clean up per-handle.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- this is the main one. it's the "do stuff" command.
-- replaces the old custom 'gpu_invoke' signal.
local function fGpuDispatchDeviceControl(pDeviceObject, pIrp)
  local tParams = pIrp.tParameters
  local sMethod = tParams.sMethod
  local tArgs = tParams.tArgs
  
  if not sMethod or type(tArgs) ~= "table" then
    oKMD.DkPrint("GPU: Invalid parameters for DEVICE_CONTROL.")
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
    return
  end
  
  oKMD.DkPrint("GPU: DEVICE_CONTROL for method '" .. sMethod .. "'")
  
  -- get our hardware proxy from the scratchpad we saved it in
  local oProxy = pDeviceObject.pDeviceExtension.oGpuProxy
  if not oProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
    return
  end
  
  -- the actual hardware call. wrap it in a pcall because who knows what the user sent us.
  local bIsOk, ... = pcall(oProxy[sMethod], table.unpack(tArgs))
  
  if bIsOk then
    -- success! pack the return values and complete the request.
    local tReturnValues = {...}
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, tReturnValues)
  else
    -- the component call failed. report the error.
    local sErrorMsg = ...
    oKMD.DkPrint("GPU: Hardware invocation failed: " .. tostring(sErrorMsg))
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErrorMsg)
  end
end


-------------------------------------------------
-- DRIVER ENTRY & EXIT
-- the birth and death of our driver.
-------------------------------------------------

-- DKMS calls this function after it creates our process. this is where we set everything up.
function DriverEntry(pDriverObject)
  oKMD.DkPrint("AxisGPU DriverEntry starting.")
  
  -- 1. Set up our IRP dispatch table. this tells DKMS which functions to call for which actions.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fGpuDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fGpuDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fGpuDispatchDeviceControl
  
  -- 2. Create our device object. this is our representation in the kernel's device tree.
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Gpu0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("GPU: Failed to create device object! Status: " .. nStatus)
    return nStatus
  end
  g_pDeviceObject = pDeviceObj
  
  -- 3. Create a symbolic link. this gives our device a friendly name in the VFS.
  nStatus = oKMD.DkCreateSymbolicLink("/dev/gpu0", "\\Device\\Gpu0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("GPU: Failed to create symbolic link!")
    oKMD.DkDeleteDevice(pDeviceObj) -- cleanup what we already created
    return nStatus
  end
  
  -- 4. Initialize hardware and store state in the device extension.
  local sMyAddress = env.address
  if not sMyAddress then
    oKMD.DkPrint("GPU: No component address passed in environment!")
    return tStatus.STATUS_INVALID_PARAMETER
  end
  
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sMyAddress)
  if nProxyStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("GPU: Failed to get hardware proxy!")
    return nProxyStatus
  end
  
  -- the device extension is our private scratchpad for this device instance.
  g_pDeviceObject.pDeviceExtension.oGpuProxy = oProxy
  
  oKMD.DkPrint("AxisGPU DriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

-- DKMS calls this when it's time to unload the driver.
function DriverUnload(pDriverObject)
  oKMD.DkPrint("AxisGPU DriverUnload starting.")
  
  -- cleanup in reverse order of creation.
  oKMD.DkDeleteSymbolicLink("/dev/gpu0")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  
  oKMD.DkPrint("AxisGPU DriverUnload completed.")
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-- the driver process just sits here, waiting for instructions from the kernel/dkms.
-------------------------------------------------
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  
  if bOk then
    if sSignalName == "driver_init" then
      -- DKMS is telling us to initialize.
      local pDriverObject = p1
      pDriverObject.fDriverUnload = DriverUnload -- register our unload function
      local nStatus = DriverEntry(pDriverObject)
      
      -- report back with status AND the modified driver object.
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
      
    elseif sSignalName == "irp_dispatch" then
      -- DKMS has a job for us.
      local pIrp = p1
      local fHandler = p2 -- DKMS tells us which of our functions to run
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end