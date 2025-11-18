--
-- /drivers/tty.sys.lua
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AwooTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100,
  sVersion = "1.1.0",
}

local g_pDeviceObject = nil
local g_oGpuProxy = nil

-------------------------------------------------
-- INTERNAL HELPERS
-------------------------------------------------

local function writeToScreen(pDeviceObject, sData)
  local pExt = pDeviceObject.pDeviceExtension
  local sDataStr = tostring(sData)
  
  for i = 1, #sDataStr do
    local sChar = string.sub(sDataStr, i, i)
    local nByte = string.byte(sChar)
    
    if nByte == 10 then -- \n
      pExt.nCursorX = 1
      pExt.nCursorY = pExt.nCursorY + 1
    elseif nByte == 13 then -- \r
      pExt.nCursorX = 1
    elseif nByte == 8 then -- \b
      if pExt.nCursorX > 1 then
        pExt.nCursorX = pExt.nCursorX - 1
        g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, " ")
      elseif pExt.nCursorX == 1 and pExt.nCursorY > 1 then
         pExt.nCursorY = pExt.nCursorY - 1
         pExt.nCursorX = pExt.nWidth
      end
    elseif nByte == 12 then -- \f (Clear)
      g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
      pExt.nCursorX = 1
      pExt.nCursorY = 1
    else
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sChar)
      pExt.nCursorX = pExt.nCursorX + 1
      if pExt.nCursorX > pExt.nWidth then
        pExt.nCursorX = 1
        pExt.nCursorY = pExt.nCursorY + 1
      end
    end
    
    if pExt.nCursorY > pExt.nHeight then
      g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
      g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
      pExt.nCursorY = pExt.nHeight
    end
  end
end

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

local function fTtyDispatchCreate(pDeviceObject, pIrp)
  oKMD.DkPrint("TTY: IRP_MJ_CREATE received.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, 0) 
end

local function fTtyDispatchClose(pDeviceObject, pIrp)
  oKMD.DkPrint("TTY: IRP_MJ_CLOSE received.")
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fTtyDispatchWrite(pDeviceObject, pIrp)
  local sData = pIrp.tParameters.sData
  
  writeToScreen(pDeviceObject, sData)
  
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sData)
end

local function fTtyDispatchRead(pDeviceObject, pIrp)
  -- oKMD.DkPrint("TTY: Read Request.")
  local pExt = pDeviceObject.pDeviceExtension
  
  if pExt.pPendingReadIrp then
    oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_DEVICE_BUSY)
    return
  end
  
  pExt.pPendingReadIrp = pIrp
  pExt.sLineBuffer = ""
end

-------------------------------------------------
-- DRIVER ENTRY & EXIT
-------------------------------------------------

function DriverEntry(pDriverObject)
  oKMD.DkPrint("AwooTTY DriverEntry starting.")
  
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fTtyDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fTtyDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fTtyDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fTtyDispatchRead
  
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\TTY0")
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  g_pDeviceObject = pDeviceObj
  
  nStatus = oKMD.DkCreateSymbolicLink("/dev/tty", "\\Device\\TTY0")
  if nStatus ~= tStatus.STATUS_SUCCESS then
    oKMD.DkDeleteDevice(pDeviceObj)
    return nStatus
  end
  
  local sGpuAddress, sScreenAddress
  local bGpuOk, tGpuList = syscall("raw_component_list", "gpu")
  if bGpuOk and tGpuList then for sAddr in pairs(tGpuList) do sGpuAddress = sAddr; break end end

  local bScreenOk, tScreenList = syscall("raw_component_list", "screen")
  if bScreenOk and tScreenList then for sAddr in pairs(tScreenList) do sScreenAddress = sAddr; break end end
  
  if sGpuAddress then
      local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(sGpuAddress)
      if nProxyStatus ~= tStatus.STATUS_SUCCESS then return nProxyStatus end
      g_oGpuProxy = oProxy
      
      if sScreenAddress then
        g_oGpuProxy.bind(sScreenAddress)
        local w, h = g_oGpuProxy.getResolution()
        g_oGpuProxy.fill(1, 1, w, h, " ")
        
        local pExt = g_pDeviceObject.pDeviceExtension
        pExt.nWidth, pExt.nHeight = w, h
        pExt.nCursorX, pExt.nCursorY = 1, 1
        pExt.pPendingReadIrp = nil
        pExt.sLineBuffer = ""
      end
  end
  
  oKMD.DkRegisterInterrupt("key_down")
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  oKMD.DkDeleteSymbolicLink("/dev/tty")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  return tStatus.STATUS_SUCCESS
end

-------------------------------------------------
-- MAIN DRIVER LOOP
-------------------------------------------------
while true do
  local bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
  
  if bOk then
    if sSignalName == "driver_init" then
      local pDriverObject = p1
      local nStatus = DriverEntry(pDriverObject)
      syscall("signal_send", nSenderPid, "driver_init_complete", nStatus, pDriverObject)
      
    elseif sSignalName == "irp_dispatch" then
      local pIrp = p1
      local fHandler = p2
      if fHandler then fHandler(g_pDeviceObject, pIrp) end
      
    elseif sSignalName == "hardware_interrupt" and p1 == "key_down" then
      local pExt = g_pDeviceObject and g_pDeviceObject.pDeviceExtension
      if pExt and pExt.pPendingReadIrp then
        local sChar, nCode = p3, p4
        if nCode == 28 then -- Enter
          writeToScreen(g_pDeviceObject, "\n")
          oKMD.DkCompleteRequest(pExt.pPendingReadIrp, tStatus.STATUS_SUCCESS, pExt.sLineBuffer)
          pExt.pPendingReadIrp = nil
        elseif nCode == 14 then -- Backspace
          if #pExt.sLineBuffer > 0 then
            pExt.sLineBuffer = string.sub(pExt.sLineBuffer, 1, -2)
            writeToScreen(g_pDeviceObject, "\b \b")
          end
        else
          if nCode ~= 0 and sChar > 0 then 
             local sC = string.char(sChar)
             pExt.sLineBuffer = pExt.sLineBuffer .. sC
             writeToScreen(g_pDeviceObject, sC)
          end
        end
      end
    end
  end
end