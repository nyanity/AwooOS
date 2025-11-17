--
-- /drivers/ntm_fusion.sys.lua
-- Driver for the HBM's Nuclear Tech Mod ITER Fusion Reactor.
-- Its job is to tame the artificial sun and prevent it from disassembling itself
-- and the surrounding landscape. No pressure.
--

-- The standard toolkit for any self-respecting kernel mode driver.
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

-- This is our driver's resume, handed to DKMS upon inspection.
-- We're important, but not "boot-critical", so our priority is moderate.
g_tDriverInfo = {
  sDriverName = "AwooITER",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 300, -- Load after essential things like TTY and GPU.
  sVersion = "1.0.0-rc1",
}

-- Module-level state. We only expect to manage one of these beasts per driver instance.
local g_pDeviceObject = nil

-------------------------------------------------
-- IRP HANDLERS
-- These are the functions that do the actual work. When the I/O Manager (DKMS)
-- gets a request for our device, it calls one of these.
-------------------------------------------------

-- Called on fs.open("/dev/iter0")
-- Basically, the user is asking for a handle to talk to us. We say yes.
local function fIterDispatchCreate(pDeviceObject, pIrp)
  oKMD.DkPrint("ITER: IRP_MJ_CREATE received. Connection to plasma chamber established.")
  -- We don't need to track individual handles for this simple device, so just approve.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- Called on fs.close(handle)
-- The user is done talking to us.
local function fIterDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("ITER: IRP_MJ_CLOSE received. Disconnecting from control systems.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- This is the main one. It's the "do stuff" command.
-- All custom logic (get status, flip switches) goes through here.
local function fIterDispatchDeviceControl(pDeviceObject, pIrp)
  local tParams = pIrp.tParameters
  local sMethod = tParams.sMethod
  local tArgs = tParams.tArgs or {}
  
  if not sMethod then
    oKMD.DkPrint("ITER: Invalid parameters for DEVICE_CONTROL. No method specified.")
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
    return
  end
  
  -- Grab our hardware proxy from the little pocket dimension we stored it in.
  local oProxy = pDeviceObject.pDeviceExtension.oIterProxy
  if not oProxy then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_NOT_READY)
    return
  end
  
  -- The actual hardware call. We wrap it in a pcall because we don't trust
  -- the hardware (or the user's arguments) not to explode.
  local bIsOk, ... = pcall(oProxy[sMethod], table.unpack(tArgs))
  
  if bIsOk then
    -- Success! Pack the return values and complete the request.
    local tReturnValues = {...}
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, tReturnValues)
  else
    -- The component call failed. This is bad, but not panic-worthy. Report it.
    local sErrorMsg = ...
    oKMD.DkPrint("ITER: Hardware invocation failed for '" .. sMethod .. "': " .. tostring(sErrorMsg))
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErrorMsg)
  end
end


-------------------------------------------------
-- DRIVER ENTRY & EXIT
-- The birth and death of our driver process.
-------------------------------------------------

-- DKMS calls this function after it creates our process. This is where we set everything up.
function DriverEntry(pDriverObject)
  oKMD.DkPrint("AwooITER DriverEntry starting. Calibrating magnetic confinement fields.")
  
  -- 1. Set up our IRP dispatch table. This tells DKMS which functions to call for which actions.
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fIterDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fIterDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_DEVICE_CONTROL] = fIterDispatchDeviceControl
  
  -- 2. Create our device object. This is our representation in the kernel's device tree.
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\FusionReactor0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("ITER: Failed to create device object! Status: " .. nStatus)
    return nStatus
  end
  g_pDeviceObject = pDeviceObj
  
  -- 3. Create a symbolic link. This gives our device a friendly name in the VFS.
  nStatus = oKMD.DkCreateSymbolicLink("/dev/iter0", "\\Device\\FusionReactor0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("ITER: Failed to create symbolic link!")
    oKMD.DkDeleteDevice(pDeviceObj) -- cleanup what we already created
    return nStatus
  end
  
  -- 4. Get a proxy to the actual hardware. The address was passed to us by the Pipeline Manager.
  local sMyAddress = env.address
  if not sMyAddress then
    oKMD.DkPrint("ITER: No component address passed in environment! Cannot find reactor!")
    return tStatus.STATUS_INVALID_PARAMETER
  end
  
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sMyAddress)
  if nProxyStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("ITER: Failed to get hardware proxy! Control link failed.")
    return nProxyStatus
  end
  
  -- The device extension is our private scratchpad for this device instance.
  -- We'll store the proxy here so our IRP handlers can find it.
  g_pDeviceObject.pDeviceExtension.oIterProxy = oProxy
  
  oKMD.DkPrint("AwooITER DriverEntry completed. Reactor control systems are online.")
  return tStatus.STATUS_SUCCESS
end

-- DKMS calls this when it's time to unload the driver.
function DriverUnload(pDriverObject)
  oKMD.DkPrint("AwooITER DriverUnload starting. Performing safe shutdown sequence.")
  
  -- Cleanup in reverse order of creation. It's only polite.
  oKMD.DkDeleteSymbolicLink("/dev/iter0")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  
  oKMD.DkPrint("AwooITER DriverUnload completed. Magnetic fields are spun down.")
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-- The driver process just sits here, waiting for instructions from DKMS.
-- It's a lonely life, but a stable one.
-------------------------------------------------
while true do
  local bOk, nSenderPid, sSignalName, p1, p2 = syscall("signal_pull")
  
  if bOk then
    if sSignalName == "driver_init" then
      -- DKMS is telling us to initialize.
      local pDriverObject = p1
      pDriverObject.fDriverUnload = DriverUnload -- register our unload function
      local nStatus = DriverEntry(pDriverObject)
      
      -- Report back to DKMS with our status and the fully configured driver object.
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
      
    elseif sSignalName == "irp_dispatch" then
      -- DKMS has a job for us.
      local pIrp = p1
      local fHandler = p2 -- DKMS is kind enough to tell us which of our functions to run.
      fHandler(g_pDeviceObject, pIrp)
    end
  end
end