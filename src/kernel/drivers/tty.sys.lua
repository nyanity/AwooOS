--
-- /drivers/tty.sys.lua
-- the teletype driver, reborn under the new driver model.
-- event-driven, stateful, and much more robust.
--

-- these are our bibles. the driver kit.
local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

-- this is static information about our driver. DKMS reads this before loading us.
g_tDriverInfo = {
  sDriverName = "AwooTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100, -- pretty important, load it early
  sVersion = "1.0.0",
}

-- local state for our driver
local g_pDeviceObject = nil
local g_oGpuProxy = nil

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------
-- these functions are called by the dispatcher when an app tries to use our device.

-- called on fs.open("/dev/tty")
local function fTtyDispatchCreate(pDeviceObject, pIrp)
  oKMD.DkPrint("TTY: IRP_MJ_CREATE received.")
  -- we don't need to do much here, just succeed the request.
  -- a real driver might allocate a handle-specific structure here.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, { fd = 1 }) -- return a dummy fd info
end

-- called on fs.close(handle)
local function fTtyDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("TTY: IRP_MJ_CLOSE received.")
  -- nothing to clean up per-handle, so just succeed.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

-- called on fs.write(handle, data)
local function fTtyDispatchWrite(pDeviceObject, pIrp)
  local sData = pIrp.tParameters.sData
  oKMD.DkPrint("TTY: IRP_MJ_WRITE received with data: " .. sData)
  
  local pExt = pDeviceObject.pDeviceExtension
  
  for sChar in string.gmatch(tostring(sData), ".") do
    if sChar == "\n" then
      pExt.nCursorX = 1
      pExt.nCursorY = pExt.nCursorY + 1
    else
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sChar)
      pExt.nCursorX = pExt.nCursorX + 1
      if pExt.nCursorX > pExt.nWidth then
        pExt.nCursorX = 1
        pExt.nCursorY = pExt.nCursorY + 1
      end
    end
    if pExt.nCursorY > pExt.nHeight then
      -- scroll
      g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
      g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
      pExt.nCursorY = pExt.nHeight
    end
  end
  
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sData) -- return bytes written
end

-- called on fs.read(handle)
local function fTtyDispatchRead(pDeviceObject, pIrp)
  oKMD.DkPrint("TTY: IRP_MJ_READ received. Awaiting user input.")
  local pExt = pDeviceObject.pDeviceExtension
  
  -- if we're already waiting for a read, fail this new one.
  if pExt.pPendingReadIrp then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_BUSY)
    return
  end
  
  -- store the IRP. we will complete it later when the user presses Enter.
  pExt.pPendingReadIrp = pIrp
  pExt.sLineBuffer = ""
  
  -- we don't complete the request here. we return STATUS_PENDING implicitly.
end

-------------------------------------------------
-- DRIVER ENTRY & EXIT
-------------------------------------------------

-- this is our main entry point. DKMS tells us to run this after spawning us.
function DriverEntry(pDriverObject)
  oKMD.DkPrint("AwooTTY DriverEntry starting.")
  
  -- 1. Set up our IRP dispatch table
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fTtyDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fTtyDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fTtyDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fTtyDispatchRead
  
  -- 2. Create our device object
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\TTY0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("TTY: Failed to create device object!")
    return nStatus
  end
  g_pDeviceObject = pDeviceObj
  
  -- 3. Create a symbolic link so user apps can find us
  nStatus = oKMD.DkCreateSymbolicLink("/dev/tty", "\\Device\\TTY0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkPrint("TTY: Failed to create symbolic link!")
    oKMD.DkDeleteDevice(pDeviceObj) -- cleanup
    return nStatus
  end
  
  -- 4. Initialize the hardware and our device extension (state)
  local sGpuAddress, sScreenAddress -- find them
  for sAddr in syscall("raw_component_list", "gpu") do sGpuAddress = sAddr; break end
  for sAddr in syscall("raw_component_list", "screen") do sScreenAddress = sAddr; break end
  
  if not sGpuAddress or not sScreenAddress then
    oKMD.DkPrint("TTY: Could not find GPU or Screen component!")
    return tStatus.STATUS_NO_SUCH_DEVICE
  end
  
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sGpuAddress)
  if nProxyStatus ~= tStatus.STATUS_SUCCESS then return nProxyStatus end
  g_oGpuProxy = oProxy
  
  g_oGpuProxy.bind(sScreenAddress)
  local w, h = g_oGpuProxy.getResolution()
  g_oGpuProxy.fill(1, 1, w, h, " ")
  
  -- store state in the device extension
  local pExt = g_pDeviceObject.pDeviceExtension
  pExt.nWidth, pExt.nHeight = w, h
  pExt.nCursorX, pExt.nCursorY = 1, 1
  pExt.pPendingReadIrp = nil
  pExt.sLineBuffer = ""
  
  -- 5. Register for keyboard interrupts
  oKMD.DkRegisterInterrupt("key_down")
  
  oKMD.DkPrint("AwooTTY DriverEntry completed successfully.")
  return tStatus.STATUS_SUCCESS
end

-- called by DKMS when the driver is being unloaded.
function DriverUnload(pDriverObject)
  oKMD.DkPrint("AwooTTY DriverUnload starting.")
  
  -- cleanup in reverse order of creation
  oKMD.DkDeleteSymbolicLink("/dev/tty")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  
  -- hardware can be left as is.
  
  oKMD.DkPrint("AwooTTY DriverUnload completed.")
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
-- a driver process doesn't run freely. it just waits for signals from DKMS.
while true do
  local bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
  
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      -- DKMS is telling us to initialize. call our entry point.
      local nStatus = DriverEntry(pDriverObject)
      -- report back to DKMS
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus)
      
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      -- DKMS is telling us to handle an IRP.
      fHandler(g_pDeviceObject, pIrp)
      
    elseif sSignalName == "hardware_interrupt" and p1 == "key_down" then
      local pExt = g_pDeviceObject.pDeviceExtension
      if pExt.pPendingReadIrp then
        -- we have a pending read request! process the key press.
        local sChar, nCode = p3, p4
        if nCode == 28 then -- Enter
          fTtyDispatchWrite(g_pDeviceObject, {tParameters={sData="\n"}}) -- echo newline
          oKMD.DkCompleteRequest(pExt.pPendingReadIrp, tStatus.STATUS_SUCCESS, pExt.sLineBuffer)
          pExt.pPendingReadIrp = nil
        elseif nCode == 14 then -- Backspace
          if #pExt.sLineBuffer > 0 then
            pExt.sLineBuffer = string.sub(pExt.sLineBuffer, 1, -2)
            -- echo backspace
            fTtyDispatchWrite(g_pDeviceObject, {tParameters={sData="\b \b"}}) 
          end
        else
          if sChar and #sChar > 0 then
            pExt.sLineBuffer = pExt.sLineBuffer .. sChar
            fTtyDispatchWrite(g_pDeviceObject, {tParameters={sData=sChar}}) -- echo char
          end
        end
      end
    end
  end
end