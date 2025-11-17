--
-- /system/dkms.lua
-- Dynamic Kernel Module System
-- this is the big boss of drivers. it loads them, unloads them,
-- and routes all their mail (i/o requests).
--

local syscall = syscall
local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oSec = require("dkms_sec")
local oDispatcher = require("driverdispatch")

syscall("kernel_log", "[DKMS] Ring 1 Driver Manager starting.")

-- our global state. this is the single source of truth for all drivers.
local g_tDriverRegistry = {} -- [sDriverPath] = pDriverObject
local g_tDeviceTree = {}     -- [sDeviceName] = pDeviceObject
local g_tSymbolicLinks = {}  -- [sLinkName] = sDeviceName
local g_tPendingIrps = {}    -- [nSenderPid] = pIrp

-- register our special syscalls so drivers can talk to us.
syscall("syscall_override", "dkms_create_device")
syscall("syscall_override", "dkms_create_symlink")
syscall("syscall_override", "dkms_delete_device")
syscall("syscall_override", "dkms_delete_symlink")
syscall("syscall_override", "dkms_complete_irp")
syscall("syscall_override", "dkms_register_interrupt")

-- the actual implementation of the syscalls we just overrode.
local tSyscallHandlers = {}

function tSyscallHandlers.dkms_create_device(nCallerPid, sDeviceName)
  -- find the driver object associated with the calling PID
  local pDriverObject
  for _, pObj in pairs(g_tDriverRegistry) do
    if pObj.nDriverPid == nCallerPid then
      pDriverObject = pObj
      break
    end
  end
  
  if not pDriverObject then return nil, tStatus.STATUS_ACCESS_DENIED end
  if g_tDeviceTree[sDeviceName] then return nil, tStatus.STATUS_DEVICE_ALREADY_EXISTS end
  
  local pDeviceObject = tDKStructs.fNewDeviceObject()
  pDeviceObject.pDriverObject = pDriverObject
  pDeviceObject.sDeviceName = sDeviceName
  
  -- add to the driver's linked list of devices
  pDeviceObject.pNextDevice = pDriverObject.pDeviceObject
  pDriverObject.pDeviceObject = pDeviceObject
  
  -- add to the global device tree
  g_tDeviceTree[sDeviceName] = pDeviceObject
  
  syscall("kernel_log", "[DKMS] Device '" .. sDeviceName .. "' created by driver '" .. pDriverObject.tDriverInfo.sDriverName .. "'.")
  return pDeviceObject, tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_create_symlink(nCallerPid, sLinkName, sDeviceName)
  if not g_tDeviceTree[sDeviceName] then return tStatus.STATUS_NO_SUCH_DEVICE end
  g_tSymbolicLinks[sLinkName] = sDeviceName
  syscall("kernel_log", "[DKMS] Symbolic link '" .. sLinkName .. "' created for device '" .. sDeviceName .. "'.")
  return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_device(nCallerPid, sDeviceName)
    -- security check: does this device belong to the calling driver?
    -- (simplified for now)
    local pDeviceObject = g_tDeviceTree[sDeviceName]
    if not pDeviceObject then return tStatus.STATUS_NO_SUCH_DEVICE end
    
    -- remove from global tree
    g_tDeviceTree[sDeviceName] = nil
    
    -- remove from driver's list (complex, simplified here)
    pDeviceObject.pDriverObject.pDeviceObject = nil 
    
    syscall("kernel_log", "[DKMS] Device '" .. sDeviceName .. "' deleted.")
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_delete_symlink(nCallerPid, sLinkName)
    g_tSymbolicLinks[sLinkName] = nil
    syscall("kernel_log", "[DKMS] Symbolic link '" .. sLinkName .. "' deleted.")
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_complete_irp(nCallerPid, pIrp)
    local nOriginalSenderPid = pIrp.nSenderPid
    syscall("kernel_log", "[DKMS] IRP for PID " .. nOriginalSenderPid .. " completed with status " .. pIrp.tIoStatus.nStatus)
    -- wake up the original process that made the vfs call
    syscall("signal_send", nOriginalSenderPid, "syscall_return", true, pIrp.tIoStatus.nStatus, pIrp.tIoStatus.vInformation)
    g_tPendingIrps[nOriginalSenderPid] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_register_interrupt(nCallerPid, sEventName)
    -- for now, just log it. a real implementation would hook into the kernel's event queue.
    syscall("kernel_log", "[DKMS] PID " .. nCallerPid .. " registered for interrupt '" .. sEventName .. "'")
    -- associate this pid with this event
    -- (implementation detail omitted for brevity, but it's important)
    return tStatus.STATUS_SUCCESS
end


-- the main function for loading and initializing a driver. it's a big one.
function load_driver(sDriverPath, tDriverEnv)
  syscall("kernel_log", "[DKMS] Attempting to load driver: " .. sDriverPath)
  
  -- 1. Read the driver file using the kernel's primitive vfs
  local bOk, sCode, sErr = syscall("vfs_read_file", sDriverPath)
  if not bOk then
    syscall("kernel_log", "[DKMS] Error: Failed to read driver file " .. sDriverPath .. ": " .. tostring(sErr))
    return tStatus.STATUS_NO_SUCH_FILE
  end
  
  -- 2. Security validation
  local nStatus = oSec.fValidateDriverSignature(sCode)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    syscall("kernel_log", "[DKMS] Error: Driver " .. sDriverPath .. " failed signature validation.")
    return nStatus
  end
  
  -- 3. Load the code into a temporary environment to inspect it
  local tTempEnv = { require = require } -- give it a basic require
  local fChunk, sLoadErr = load(sCode, "@" .. sDriverPath, "t", tTempEnv)
  if not fChunk then
    syscall("kernel_log", "[DKMS] Error: Syntax error in driver " .. sDriverPath .. ": " .. sLoadErr)
    return tStatus.STATUS_INVALID_DRIVER_OBJECT
  end
  pcall(fChunk) -- run the code to populate tTempEnv
  
  -- 4. Validate the driver's info table
  local tDriverInfo = tTempEnv.g_tDriverInfo
  nStatus, sErr = oSec.fValidateDriverInfo(tDriverInfo)
  if nStatus ~= tStatus.STATUS_SUCCESS then
    syscall("kernel_log", "[DKMS] Error: Driver " .. sDriverPath .. " has invalid g_tDriverInfo: " .. sErr)
    return nStatus
  end
  
  -- 5. Check for the correct entry point
  local sEntryFuncName = (tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_KMD) and "DriverEntry" or "UMDriverEntry"
  if type(tTempEnv[sEntryFuncName]) ~= "function" then
    syscall("kernel_log", "[DKMS] Error: Driver " .. sDriverPath .. " is missing its entry point: " .. sEntryFuncName)
    return tStatus.STATUS_INVALID_DRIVER_ENTRY
  end
  
  -- 6. Spawn the driver process
  local nRing = (tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_KMD) and 2 or 3
  local bSpawnOk, nPid, sSpawnErr = syscall("process_spawn", sDriverPath, nRing, tDriverEnv)
  if not bSpawnOk then
    syscall("kernel_log", "[DKMS] Error: Failed to spawn process for driver " .. sDriverPath .. ": " .. sSpawnErr)
    return tStatus.STATUS_DRIVER_INIT_FAILED
  end
  
  -- 7. Create the DRIVER_OBJECT
  local pDriverObject = tDKStructs.fNewDriverObject()
  pDriverObject.sDriverPath = sDriverPath
  pDriverObject.nDriverPid = nPid
  pDriverObject.tDriverInfo = tDriverInfo
  
  -- 8. Send a signal to the new process to call its DriverEntry
  syscall("kernel_log", "[DKMS] Telling PID " .. nPid .. " to initialize...")
  syscall("signal_send", nPid, "driver_init", pDriverObject)
  
  -- 9. Wait for the driver to report back.
  -- a real system would have a timeout here.
  local bPullOk, nSenderPid, sSignalName, nEntryStatus, pInitializedDriverObject = syscall("signal_pull")
  if bPullOk and sSignalName == "driver_init_complete" and nSenderPid == nPid then
    if nEntryStatus == tStatus.STATUS_SUCCESS and pInitializedDriverObject then
      syscall("kernel_log", "[DKMS] Driver '" .. tDriverInfo.sDriverName .. "' loaded successfully as PID " .. nPid)
      -- CRITICAL: Use the returned, fully configured driver object.
      g_tDriverRegistry[sDriverPath] = pInitializedDriverObject
      return tStatus.STATUS_SUCCESS
    else
      syscall("kernel_log", "[DKMS] Error: DriverEntry for '" .. tDriverInfo.sDriverName .. "' failed with status " .. (nEntryStatus or "UNKNOWN"))
      -- TODO: kill the process nPid
      return nEntryStatus or tStatus.STATUS_DRIVER_INIT_FAILED
    end
  else
    syscall("kernel_log", "[DKMS] Error: Driver " .. nPid .. " failed to respond correctly to init signal.")
    return tStatus.STATUS_DRIVER_INIT_FAILED
  end
end

-- syscall("kernel_log", "[DKMS-DEBUG] Checking root directory contents...")
local bListOk, tFileList = syscall("vfs_list", "/")
if bListOk then
    for i, sFile in ipairs(tFileList) do
        -- syscall("kernel_log", "[DKMS-DEBUG] /" .. sFile)
    end
else
    -- syscall("kernel_log", "[DKMS-DEBUG] Failed to list root directory!")
end

-- syscall("kernel_log", "[DKMS-DEBUG] Checking /drivers/ directory contents...")
local bDrvListOk, tDrvFileList = syscall("vfs_list", "/drivers")
if bDrvListOk then
    for i, sFile in ipairs(tDrvFileList) do
        --syscall("kernel_log", "[DKMS-DEBUG] /drivers/" .. sFile)
    end
else
    --syscall("kernel_log", "[DKMS-DEBUG] Failed to list /drivers/ directory!")
end

-- main event loop
while true do
  local bSyscallOk, bPullOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
  
  if bSyscallOk and bPullOk then
    if sSignalName == "syscall" then
      -- this is one of our overridden syscalls
      local tData = p1
      local fHandler = tSyscallHandlers[tData.name]
      if fHandler then
        local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
        syscall("signal_send", tData.sender_pid, "syscall_return", true, ret1, ret2)
      end
      
    elseif sSignalName == "vfs_io_request" then
      -- this signal comes from the pipeline_manager when a user hits a device file
      local pIrp = p1
      g_tPendingIrps[pIrp.nSenderPid] = pIrp
      local nDispatchStatus = oDispatcher.DispatchIrp(pIrp, g_tDeviceTree)
      if nDispatchStatus ~= tStatus.STATUS_PENDING then
        -- the dispatch failed immediately, complete the IRP right now
        tSyscallHandlers.dkms_complete_irp(0, pIrp, nDispatchStatus)
      end

    elseif sSignalName == "load_driver_for_component" then
      local sComponentType = p1
      local sComponentAddress = p2
      -- find driver in /etc/drivers.lua or similar
      local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"
      load_driver(sDriverPath, { address = sComponentAddress })

    elseif sSignalName == "os_event" and p1 == "key_down" then
        -- This is a hardware interrupt. Find the driver that wants it.
        -- A real system would have a registry for this. We'll hardcode for TTY.
        for _, pDriver in pairs(g_tDriverRegistry) do
            if pDriver.tDriverInfo.sDriverName == "AwooTTY" then
                syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "key_down", p2, p3, p4)
            end
        end
    end
  end
end