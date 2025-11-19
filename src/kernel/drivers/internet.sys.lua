--
-- /drivers/internet.sys.lua
-- the gateway to the outside world.
-- handles http requests via standard i/o.
-- usage: open -> write(url) -> read(response) -> close
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AwooNet",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 250,
  sVersion = "1.0.0"
}

local g_pDeviceObject = nil
local g_oNetProxy = nil

-- table to track open handles and their internet request objects
-- [pIrp.nSenderPid .. "_" .. handle_id] = request_object
local g_tRequestMap = {}

-------------------------------------------------
-- IRP HANDLERS
-------------------------------------------------

local function fNetDispatchCreate(pDeviceObject, pIrp)
  -- just saying hello. actual connection happens on write.
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fNetDispatchClose(pDeviceObject, pIrp)
  -- clean up the request object if it exists
  -- we rely on the fact that PM sends us unique handles or we map by PID
  -- for simplicity in this stub, we just assume one active request per PID per open
  local sKey = tostring(pIrp.nSenderPid)
  if g_tRequestMap[sKey] then
     pcall(g_tRequestMap[sKey].close)
     g_tRequestMap[sKey] = nil
  end
  oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS)
end

local function fNetDispatchWrite(pDeviceObject, pIrp)
  local sUrl = pIrp.tParameters.sData
  if not sUrl or not g_oNetProxy then
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_PARAMETER)
     return
  end
  
  -- remove newline if present
  sUrl = sUrl:gsub("\n", "")
  
  -- start the request
  -- we use the raw component proxy directly
  local bOk, oHandle = pcall(g_oNetProxy.request, sUrl)
  
  if bOk and oHandle then
     -- store handle for subsequent reads
     g_tRequestMap[tostring(pIrp.nSenderPid)] = oHandle
     
     -- wait for connection to be established (optional, but polite)
     local bFinished = false
     while not bFinished do
        local bSuccess, sErr = oHandle.finishConnect()
        if bSuccess then bFinished = true end
        -- if sErr then... handle error? nah, we ball.
        if not bSuccess and sErr then 
            oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, sErr)
            return
        end
        if not bFinished then syscall("process_wait", 0) end -- yield
     end
     
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, #sUrl)
  else
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_UNSUCCESSFUL, "Request failed")
  end
end

local function fNetDispatchRead(pDeviceObject, pIrp)
  local oHandle = g_tRequestMap[tostring(pIrp.nSenderPid)]
  if not oHandle then
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_INVALID_HANDLE)
     return
  end
  
  -- read a chunk. 
  -- note: in a real os, this should be async/non-blocking.
  -- here we block the driver process, but since we yield in the loop, it's okay-ish.
  local sData = oHandle.read(math.huge) 
  
  if sData then
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_SUCCESS, sData)
  else
     -- nil means EOF
     oKMD.DkCompleteRequest(pIrp, tStatus.STATUS_END_OF_FILE)
  end
end

-------------------------------------------------
-- ENTRY
-------------------------------------------------

function DriverEntry(pDriverObject)
  oKMD.DkPrint("AwooNet: Initializing...")
  
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CREATE] = fNetDispatchCreate
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fNetDispatchClose
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_WRITE] = fNetDispatchWrite
  pDriverObject.tDispatch[tDKStructs.IRP_MJ_READ] = fNetDispatchRead
  
  local nStatus, pDeviceObj = oKMD.DkCreateDevice(pDriverObject, "\\Device\\Net0")
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  g_pDeviceObject = pDeviceObj
  
  -- find hardware
  local nProxyStatus, oProxy = oKMD.DkGetHardwareProxy(nil) -- nil finds first available? no, need scan.
  
  -- manual scan via syscall because DkGetHardwareProxy expects address
  local bOk, tList = syscall("raw_component_list", "internet")
  if bOk and tList then
     for sAddr in pairs(tList) do
        local _, p = oKMD.DkGetHardwareProxy(sAddr)
        g_oNetProxy = p
        break
     end
  end
  
  if not g_oNetProxy then
     oKMD.DkPrint("AwooNet: No internet card found. I am useless.")
     return tStatus.STATUS_NO_SUCH_DEVICE
  end
  
  oKMD.DkCreateSymbolicLink("/dev/net", "\\Device\\Net0")
  oKMD.DkPrint("AwooNet: Online at /dev/net")
  
  return tStatus.STATUS_SUCCESS
end

function DriverUnload(pDriverObject)
  oKMD.DkDeleteSymbolicLink("/dev/net")
  oKMD.DkDeleteDevice(g_pDeviceObject)
  return tStatus.STATUS_SUCCESS
end

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