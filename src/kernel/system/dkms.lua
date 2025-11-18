--
-- /system/dkms.lua
-- Dynamic Kernel Module System (Buffered)
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
-- ====================================

-- Syscall Overrides
syscall("syscall_override", "dkms_create_device")
syscall("syscall_override", "dkms_create_symlink")
syscall("syscall_override", "dkms_delete_device")
syscall("syscall_override", "dkms_delete_symlink")
syscall("syscall_override", "dkms_complete_irp")
syscall("syscall_override", "dkms_register_interrupt")

local tSyscallHandlers = {}

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
    syscall("signal_send", pIrp.nSenderPid, "syscall_return", true, pIrp.tIoStatus.nStatus, pIrp.tIoStatus.vInformation)
    g_tPendingIrps[pIrp.nSenderPid] = nil
    return tStatus.STATUS_SUCCESS
end

function tSyscallHandlers.dkms_register_interrupt(nCallerPid, sEventName)
    syscall("kernel_log", "[DKMS] PID " .. nCallerPid .. " registered for interrupt '" .. sEventName .. "'")
    return tStatus.STATUS_SUCCESS
end

function load_driver(sDriverPath, tDriverEnv)
  syscall("kernel_log", "[DKMS] Loading: " .. sDriverPath)
  
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
  
  local nRing = (tDriverInfo.sDriverType == tDKStructs.DRIVER_TYPE_KMD) and 2 or 3
  local nPid, sSpawnErr = syscall("process_spawn", sDriverPath, nRing, tDriverEnv)
  if not nPid then return tStatus.STATUS_DRIVER_INIT_FAILED end
  
  local pDriverObject = tDKStructs.fNewDriverObject()
  pDriverObject.sDriverPath = sDriverPath
  pDriverObject.nDriverPid = nPid
  pDriverObject.tDriverInfo = tDriverInfo
  
  syscall("signal_send", nPid, "driver_init", pDriverObject)
  
  while true do
      local bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
      if bOk then
          -- if init finished exit
          if sSignalName == "driver_init_complete" and nSenderPid == nPid then
              local nEntryStatus = p1
              local pInitializedDriverObject = p2
              
              if nEntryStatus == tStatus.STATUS_SUCCESS and pInitializedDriverObject then
                  syscall("kernel_log", "[DKMS] Loaded '" .. tDriverInfo.sDriverName .. "' (PID " .. nPid .. ")")
                  g_tDriverRegistry[sDriverPath] = pInitializedDriverObject
                  return tStatus.STATUS_SUCCESS
              else
                  syscall("kernel_log", "[DKMS] Err: DriverEntry failed: " .. tostring(nEntryStatus))
                  return nEntryStatus or tStatus.STATUS_DRIVER_INIT_FAILED
              end
              
          -- death
          elseif sSignalName == "syscall" then
              local tData = p1
              local fHandler = tSyscallHandlers[tData.name]
              if fHandler then
                   -- calling 📞📞
                   local ret1, ret2 = fHandler(tData.sender_pid, table.unpack(tData.args))
                   -- hello wake up driver driver send us DriverEntry()
                   syscall("signal_send", tData.sender_pid, "syscall_return", ret1, ret2)
              end
              
          -- buffering
          else
              table.insert(g_tSignalQueue, {nSenderPid, sSignalName, p1, p2, p3, p4})
          end
      end
  end
end

-- Main Loop
while true do
  local nSenderPid, sSignalName, p1, p2, p3, p4
  
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
      -- if buffer empty then wait
      local bOk
      bOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
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
          local nDispatchStatus = oDispatcher.DispatchIrp(pIrp, g_tDeviceTree)
          if nDispatchStatus ~= tStatus.STATUS_PENDING then
            tSyscallHandlers.dkms_complete_irp(0, pIrp, nDispatchStatus)
          end
      end

  elseif sSignalName == "load_driver_for_component" then
      local sComponentType = p1
      local sComponentAddress = p2
      local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"
      load_driver(sDriverPath, { address = sComponentAddress })

  elseif sSignalName == "load_driver_path" then
      local sPath = p1
      load_driver(sPath, {})

  elseif sSignalName == "os_event" and p1 == "key_down" then
      for _, pDriver in pairs(g_tDriverRegistry) do
          if pDriver.tDriverInfo.sDriverName == "AwooTTY" then
              syscall("signal_send", pDriver.nDriverPid, "hardware_interrupt", "key_down", p2, p3, p4)
          end
      end
  end
  
  ::continue::
end