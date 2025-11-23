--
-- /system/dkms.lua
-- Dynamic Kernel Module System (Buffered & Enforcing)
--

local syscall = syscall
local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oSec = require("dkms_sec")
local oDispatcher = require("driverdispatch")

syscall("kernel_log", "[DKMS] Ring 1 Driver Manager starting.")

local g_tDriverRegistry = {}
local g_tDeviceTree = {}
local g_tSymbolicLinks = {}
local g_tPendingIrps = {}
local g_tSignalQueue = {}

local g_tDeviceTypeCounters = {}

-- Watchdog tracking: [sDriverPath] = { nLastPid, tLastConfig }
local g_tDriverWatchdog = {} 

-- ====================================

-- Syscall Overrides
syscall("syscall_override", "dkms_create_device")
syscall("syscall_override", "dkms_create_symlink")
syscall("syscall_override", "dkms_delete_device")
syscall("syscall_override", "dkms_delete_symlink")
syscall("syscall_override", "dkms_complete_irp")
syscall("syscall_override", "dkms_register_interrupt")

syscall("syscall_override", "dkms_get_next_index") 
syscall("syscall_override", "KeRaiseIrql")
syscall("syscall_override", "KeLowerIrql")

-- new toys for the filter boys
syscall("syscall_override", "dkms_attach_device")
syscall("syscall_override", "dkms_call_driver")

local tSyscallHandlers = {}

-- [[ IRQL MANAGEMENT ]] --
-- simulating interrupt levels. because we are serious about this.

function tSyscallHandlers.KeRaiseIrql(nCallerPid, nNewIrql)
  -- find the driver object
  local pObj = nil
  for _, d in pairs(g_tDriverRegistry) do 
     if d.nDriverPid == nCallerPid then pObj = d; break end 
  end
  
  if not pObj then return nil end -- who are you?
  
  local nOldIrql = pObj.nCurrentIrql or tDKStructs.PASSIVE_LEVEL
  
  -- can't verify strict ordering without real cpu control, but we track it
  pObj.nCurrentIrql = nNewIrql
  return nOldIrql
end

function tSyscallHandlers.KeLowerIrql(nCallerPid, nNewIrql)
  local pObj = nil
  for _, d in pairs(g_tDriverRegistry) do 
     if d.nDriverPid == nCallerPid then pObj = d; break end 
  end
  if pObj then pObj.nCurrentIrql = nNewIrql end
  return true
end

-- [[ STANDARD DKMS SYSCALLS ]] --

function tSyscallHandlers.dkms_create_device(nCallerPid, sDeviceName)
  local pDriverObject
  for _, pObj in pairs(g_tDriverRegistry) do
    if pObj.nDriverPid == nCallerPid then pDriverObject = pObj; break end
  end
  if not pDriverObject then return nil, tStatus.STATUS_ACCESS_DENIED end
  if g_tDeviceTree[sDeviceName] then return nil, tStatus.STATUS_DEVICE_ALREADY_EXISTS end
  local pDeviceObject = tDKStructs.fNewDeviceObject()
  pDeviceObject.pDriverObject = pDriverObject
  pDeviceObject.sDeviceName = sDeviceName
  pDeviceObject.pNextDevice = pDriverObject.pDeviceObject
  pDriverObject.pDeviceObject = pDeviceObject
  g_tDeviceTree[sDeviceName] = pDeviceObject
  syscall("kernel_log", "[DKMS] Device '" .. sDeviceName .. "' created.")
  return pDeviceObject, tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_create_symlink(nCallerPid, sLinkName, sDeviceName)
  if not g_tDeviceTree[sDeviceName] then return tStatus.STATUS_NO_SUCH_DEVICE end
  g_tSymbolicLinks[sLinkName] = sDeviceName
  syscall("kernel_log", "[DKMS] Symlink '" .. sLinkName .. "' -> '" .. sDeviceName .. "' created.")
  return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_device(nCallerPid, sDeviceName)
    local pDeviceObject = g_tDeviceTree[sDeviceName]
    if not pDeviceObject then return tStatus.STATUS_NO_SUCH_DEVICE end
    g_tDeviceTree[sDeviceName] = nil
    pDeviceObject.pDriverObject.pDeviceObject = nil 
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_symlink(nCallerPid, sLinkName)
    g_tSymbolicLinks[sLinkName] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_complete_irp(nCallerPid, pIrp, nStatusOverride)
    if not pIrp then return tStatus.STATUS_INVALID_PARAMETER end
    if nStatusOverride then pIrp.tIoStatus.nStatus = nStatusOverride end

    if pIrp.nMajorFunction == 0x00 then -- IRP_MJ_CREATE
       local pDev = g_tDeviceTree[pIrp.sDeviceName]
       if pDev and pDev.pDriverObject then
          pIrp.tIoStatus.vInformation = pDev.pDriverObject.nDriverPid
       end
    end
    
    local bNoReply = false
    if pIrp.nFlags and type(pIrp.nFlags) == "number" then
       local nFlagVal = tDKStructs.IRP_FLAG_NO_REPLY
       local nRem = pIrp.nFlags % (nFlagVal * 2)
       if nRem >= nFlagVal then bNoReply = true end
    end
    
    if not bNoReply then
       syscall("signal_send", pIrp.nSenderPid, "syscall_return", pIrp.tIoStatus.nStatus, pIrp.tIoStatus.vInformation)
    end
    
    g_tPendingIrps[pIrp.nSenderPid] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_register_interrupt(nCallerPid, sEventName)
    syscall("kernel_log", "[DKMS] PID " .. nCallerPid .. " registered for interrupt '" .. sEventName .. "'")
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_get_next_index(nCallerPid, sDeviceType)
    if not sDeviceType then return nil, tStatus.STATUS_INVALID_PARAMETER end
    
    if not g_tDeviceTypeCounters[sDeviceType] then
        g_tDeviceTypeCounters[sDeviceType] = 0
    end
    
    local nIndex = g_tDeviceTypeCounters[sDeviceType]
    g_tDeviceTypeCounters[sDeviceType] = nIndex + 1
    
    return nIndex, tStatus.STATUS_SUCCESS
end

-- attaches a device to another. transparently redirects traffic.
function tSyscallHandlers.dkms_attach_device(nCallerPid, sSourceDeviceName, sTargetDeviceName)
    local pSourceDev = g_tDeviceTree[sSourceDeviceName]
    local pTargetDev = g_tDeviceTree[sTargetDeviceName]
    
    if not pSourceDev or not pTargetDev then return nil, tStatus.STATUS_NO_SUCH_DEVICE end
    
    -- check permissions? nah, we trust drivers loaded by root.
    
    -- climb to the top of the stack.
    -- if 3 drivers attach to the same device, we want to be at the very top.
    local pTopDev = pTargetDev
    while pTopDev.pAttachedDevice do
        pTopDev = pTopDev.pAttachedDevice
    end
    
    -- link 'em up
    pTopDev.pAttachedDevice = pSourceDev
    
    syscall("kernel_log", "[DKMS] Attached " .. sSourceDeviceName .. " to stack of " .. sTargetDeviceName)
    
    -- return the device we just attached to (so the filter knows where to send IRPs next)
    return pTopDev, tStatus.STATUS_SUCCESS
end

-- manually calls a driver's entry point. used for io_call_driver.
function tSyscallHandlers.dkms_call_driver(nCallerPid, sTargetDeviceName, pIrp)
    local pDev = g_tDeviceTree[sTargetDeviceName]
    if not pDev then return nil, tStatus.STATUS_NO_SUCH_DEVICE end
    
    -- use existing dispatch logic
    local nStatus = oDispatcher.DispatchIrp(pIrp, g_tDeviceTree, sTargetDeviceName) -- passing explicit name to avoid recursion lookup
    return nStatus, tStatus.STATUS_SUCCESS
end


local function inspect_driver(sDriverPath)
  local sCode, sErr = syscall("vfs_read_file", sDriverPath)
  if not sCode then return nil, tStatus.STATUS_NO_SUCH_FILE end
  
  local tTempEnv = { require = require }
  local fChunk, sLoadErr = load(sCode, "@" .. sDriverPath, "t", tTempEnv)
  if not fChunk then return nil, tStatus.STATUS_INVALID_DRIVER_OBJECT end
  
  pcall(fChunk)
  
  if type(tTempEnv.g_tDriverInfo) ~= "table" then
     return nil, tStatus.STATUS_INVALID_DRIVER_INFO
  end
  
  return tTempEnv.g_tDriverInfo
end

-- check if the driver object has the mandatory irql fields initialized
local function check_irql_compliance(pDriverObject)
  if type(pDriverObject.nCurrentIrql) ~= "number" then
     return false
  end
  -- ensure it starts at passive level
  if pDriverObject.nCurrentIrql ~= tDKStructs.PASSIVE_LEVEL then
     -- actually, maybe allow starting elsewhere, but let's strict it to 0 for init
     -- pDriverObject.nCurrentIrql = tDKStructs.PASSIVE_LEVEL
  end
  return true
end

-- this is split out so we can call it recursively for restarts
function perform_load_driver(sDriverPath, tDriverEnv, bIsRestart)
  if not bIsRestart then
      syscall("kernel_log", "[DKMS] Loading: " .. sDriverPath)
  else
      syscall("kernel_log", "[DKMS] RECOVERING DRIVER: " .. sDriverPath)
  end
  
  local sCode, sErr = syscall("vfs_read_file", sDriverPath)
  if not sCode then return tStatus.STATUS_NO_SUCH_FILE end
  
  local nStatus = oSec.fValidateDriverSignature(sCode)
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  
  local tTempEnv = { require = require }
  local fChunk, sLoadErr = load(sCode, "@" .. sDriverPath, "t", tTempEnv)
  if not fChunk then return tStatus.STATUS_INVALID_DRIVER_OBJECT end
  pcall(fChunk)
  
  local tDriverInfo = tTempEnv.g_tDriverInfo
  nStatus, sErr = oSec.fValidateDriverInfo(tDriverInfo)
  if nStatus ~= tStatus.STATUS_SUCCESS then return nStatus end
  
  if tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_CMD then
     if not tDriverEnv or not tDriverEnv.address then
        syscall("kernel_log", "[DKMS] SECURITY: Blocked CMD '" .. tDriverInfo.sDriverName .. "' - No Address.")
        return tStatus.STATUS_INVALID_PARAMETER
     end
  end
  
  local nRing = (tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_UMD) and 3 or 2
  local nPid, sSpawnErr = syscall("process_spawn", sDriverPath, nRing, tDriverEnv)
  if not nPid then return tStatus.STATUS_DRIVER_INIT_FAILED end
  
  local pDriverObject = tDKStructs.fNewDriverObject()
  pDriverObject.sDriverPath = sDriverPath
  pDriverObject.nDriverPid = nPid
  pDriverObject.tDriverInfo = tDriverInfo
  
  g_tDriverRegistry[sDriverPath] = pDriverObject
  
  -- Register for watchdog
  g_tDriverWatchdog[sDriverPath] = { 
      nPid = nPid, 
      tEnv = tDriverEnv, 
      sName = tDriverInfo.sDriverName 
  }
  
  syscall("signal_send", nPid, "driver_init", pDriverObject)
  
  while true do
      local bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
      if bOk then
          if sSignalName == "driver_init_complete" and nSenderPid == nPid then
              local nEntryStatus = p1
              local pInitializedDriverObject = p2
              
              -- !!! STRICT IRQL ENFORCEMENT !!!
              if nEntryStatus == tStatus.STATUS_SUCCESS and pInitializedDriverObject then
                  if not check_irql_compliance(pInitializedDriverObject) then
                      syscall("kernel_log", "[DKMS] FATAL: Driver '" .. tDriverInfo.sDriverName .. "' rejected.")
                      syscall("kernel_log", "[DKMS] REASON: IRQL NOT IMPLEMENTED. READ THE DOCS.")
                      syscall("process_kill", nPid)
                      g_tDriverRegistry[sDriverPath] = nil
                      g_tDriverWatchdog[sDriverPath] = nil
                      return tStatus.STATUS_DRIVER_NO_IRQL
                  end
              
                  syscall("kernel_log", "[DKMS] Loaded '" .. tDriverInfo.sDriverName .. "' (PID " .. nPid .. ") [IRQL " .. pInitializedDriverObject.nCurrentIrql .. "]")
                  g_tDriverRegistry[sDriverPath] = pInitializedDriverObject
                  return tStatus.STATUS_SUCCESS
              else
                  syscall("kernel_log", "[DKMS] Err: DriverEntry failed: " .. tostring(nEntryStatus))
                  g_tDriverRegistry[sDriverPath] = nil
                  g_tDriverWatchdog[sDriverPath] = nil -- don't restart failed inits
                  return nEntryStatus or tStatus.STATUS_DRIVER_INIT_FAILED
              end
              
          elseif sSignalName == "syscall" then
              local tData = p1
              local fHandler = tSyscallHandlers[tData.name]
              if fHandler then
                   local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
                   syscall("signal_send", tData.sender_pid, "syscall_return", ret1, ret2)
              end
          else
              table.insert(g_tSignalQueue, {nSenderPid, sSignalName, p1, p2, p3, p4})
          end
      end
  end
end

-- wrapper for external calls
function load_driver(sDriverPath, tDriverEnv)
    return perform_load_driver(sDriverPath, tDriverEnv, false)
end

-- Watchdog cycle: Check if any driver PIDs are dead and restart them
local function watchdog_check()
    for sPath, tInfo in pairs(g_tDriverWatchdog) do
        -- we check if the PID is still valid/alive using process_get_ring which returns nil/false on dead pid
        local nRing = syscall("process_get_ring", tInfo.nPid)
        if not nRing then
            syscall("kernel_log", "[DKMS] WATCHDOG: Driver died! -> " .. tInfo.sName .. " (PID " .. tInfo.nPid .. ")")
            
            -- Cleanup old objects (simple iteration, potentially slow but robust)
            local tDeadDevices = {}
            for sDevName, pDev in pairs(g_tDeviceTree) do
                if pDev.pDriverObject and pDev.pDriverObject.sDriverPath == sPath then
                    table.insert(tDeadDevices, sDevName)
                end
            end
            for _, sDev in ipairs(tDeadDevices) do
                g_tDeviceTree[sDev] = nil
                -- also remove symlinks pointing to it
                for sLink, sTarget in pairs(g_tSymbolicLinks) do
                    if sTarget == sDev then g_tSymbolicLinks[sLink] = nil end
                end
            end
            
            -- Attempt resurrection
            perform_load_driver(sPath, tInfo.tEnv, true)
        end
    end
end


-- Main Loop
local nWatchdogTimer = computer.uptime()

while true do
  local nSenderPid, sSignalName, p1, p2, p3, p4
  
  -- Run watchdog every 5 seconds
  if computer.uptime() > nWatchdogTimer + 5 then
      watchdog_check()
      nWatchdogTimer = computer.uptime()
  end
  
  -- CHECKING SIGNAL BUFFER!!!!!!
  if #g_tSignalQueue > 0 then
      local tSig = table.remove(g_tSignalQueue, 1)
      nSenderPid = tSig[1]
      sSignalName = tSig[2]
      p1 = tSig[3]
      p2 = tSig[4]
      p3 = tSig[5]
      p4 = tSig[6]
  else
      -- if buffer empty then wait, but with a timeout for watchdog
      local bOk
      bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull", 0.5)
      if not bOk then goto continue end
  end
  
  if sSignalName == "syscall" then
      local tData = p1
      local fHandler = tSyscallHandlers[tData.name]
      if fHandler then
        local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
        syscall("signal_send", tData.sender_pid, "syscall_return", ret1, ret2)
      end
      
elseif sSignalName == "vfs_io_request" then
      local pIrp = p1
      if pIrp and type(pIrp) == "table" then
          g_tPendingIrps[pIrp.nSenderPid] = pIrp
          
          -- use the root name initially, dispatcher will climb stack
          local nDispatchStatus = oDispatcher.DispatchIrp(pIrp, g_tDeviceTree)
          
          if pIrp.nMajorFunction == 0x00 then -- IRP_MJ_CREATE
             local pDevice = g_tDeviceTree[pIrp.sDeviceName]
             -- we might have climbed the stack, so grab the top one if possible,
             -- but here we just need the PID to return to the user (if it's a direct connection)
             -- logic: if it's attached, the filter now owns the connection?
             -- actually, for VFS, we just need status success.
             if pDevice and pDevice.pDriverObject then
                pIrp.tIoStatus.vInformation = pDevice.pDriverObject.nDriverPid
             end
          end

          if nDispatchStatus ~= tStatus.STATUS_PENDING then
            tSyscallHandlers.dkms_complete_irp(0, pIrp, nDispatchStatus)
          end
      end
  elseif sSignalName == "dkms_list_devices_request" then
      local nOriginalRequester = p1
      
      local tList = {}
      -- g_tSymbolicLinks keys are like "/dev/tty", "/dev/gpu0"
      for sLinkPath, sDeviceName in pairs(g_tSymbolicLinks) do
          -- we strip the "/dev/" prefix to get just the filename
          local sName = string.match(sLinkPath, "^/dev/(.+)$")
          if sName then
             table.insert(tList, sName)
          end
      end
      
      -- send the list back to PM
      syscall("signal_send", nSenderPid, "dkms_list_devices_result", nOriginalRequester, tList)

  elseif sSignalName == "load_driver_for_component" then
      local sComponentType = p1
      local sComponentAddress = p2
      local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"
      load_driver(sDriverPath, { address = sComponentAddress })

  elseif sSignalName == "load_driver_path" then
      local sPath = p1
      load_driver(sPath, {})
      
elseif sSignalName == "load_driver_path_request" then
      local sPath = p1
      local nOriginalRequester = p2
      
      local tInfo, nInspectErr = inspect_driver(sPath)
      
      if not tInfo then
          syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, nInspectErr or tStatus.STATUS_UNSUCCESSFUL, "Unknown", -1)
          goto continue
      end
      
      if tInfo.sDriverType == tDKStructs.DRIVER_TYPE_CMD and tInfo.sSupportedComponent then
          syscall("kernel_log", "[DKMS] Auto-discovery for type: " .. tInfo.sSupportedComponent)
          local bOk, tList = syscall("raw_component_list", tInfo.sSupportedComponent)
          local nLoadedCount = 0
          local nLastStatus = tStatus.STATUS_NO_SUCH_DEVICE
          
          if bOk and tList then
              for sAddr, _ in pairs(tList) do
                  local nSt = load_driver(sPath, { address = sAddr })
                  if nSt == tStatus.STATUS_SUCCESS then nLoadedCount = nLoadedCount + 1 end
                  nLastStatus = nSt
              end
          end
          
          if nLoadedCount > 0 then
             local sMsg = string.format("Auto-loaded %d instances of %s", nLoadedCount, tInfo.sDriverName)
             syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, tStatus.STATUS_SUCCESS, sMsg, 0)
          else
             syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, nLastStatus, tInfo.sDriverName, -1)
          end
          
      else
          local nStatus = load_driver(sPath, {})
          local pObj = g_tDriverRegistry[sPath]
          local sName = tInfo.sDriverName
          local nPid = pObj and pObj.nDriverPid or -1
          
          syscall("signal_send", nSenderPid, "load_driver_result", nOriginalRequester, nStatus, sName, nPid)
      end
      
      ::continue::

  elseif sSignalName == "os_event" and p1 == "key_down" then
      for _, pDriver in pairs(g_tDriverRegistry) do
          if pDriver.tDriverInfo.sDriverName == "AxisTTY" then
              syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "key_down", p2, p3, p4)
          end
      end
  end
  
  ::continue::
end