--
-- /lib/pipeline_manager.lua
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

local nDkmsPid, sDkmsErr = syscall("process_spawn", "/system/dkms.lua", 1)
if not nDkmsPid then syscall("kernel_panic", "Could not spawn DKMS: " .. tostring(sDkmsErr)) end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

local vfs_state = { oRootFs = nil, nNextFd = 1, tOpenHandles = {} }

syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")

function vfs_state.handle_open(nSenderPid, sPath, sMode)
  if string.sub(sPath, 1, 5) == "/dev/" then
    syscall("kernel_log", "[PM-VFS] Path '" .. sPath .. "' is a device. Forwarding to DKMS.")
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    
    if sPath == "/dev/tty" then pIrp.sDeviceName = "\\Device\\TTY0" 
    elseif sPath == "/dev/gpu0" then pIrp.sDeviceName = "\\Device\\Gpu0"
    else pIrp.sDeviceName = "\\Device" .. sPath:sub(5):gsub("/", "\\") end

    pIrp.nSenderPid = nSenderPid
    pIrp.tParameters.sMode = sMode
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return "async_wait" 
  end
  
  local bOk, hHandle, sReason = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", sPath, sMode)
  if not hHandle then return nil, sReason end
  
  local nFd = vfs_state.nNextFd
  vfs_state.nNextFd = vfs_state.nNextFd + 1
  vfs_state.tOpenHandles[nFd] = { type = "file", handle = hHandle }
  return nFd
end

function vfs_state.handle_write(nSenderPid, nFd, sData)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  if tHandle.type == "file" then
    return syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", tHandle.handle, sData)
  else
    -- TODO: Device write
    return nil, "Device write not implemented in PM"
  end
end

local function __scandrvload()
  -- loading tty firest because it is not in component.list
  syscall("kernel_log", "[PM] Loading TTY Driver explicitly...")
  syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/tty.sys.lua")
  
  -- pause for init
  local deadline = computer.uptime() + 1.0
  while computer.uptime() < deadline do syscall("kernel_host_yield") end

  syscall("kernel_log", "[PM] Scanning for components...")
  local sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
  if not oRootProxy then syscall("kernel_panic", "Pipeline could not get root FS info.") end
  vfs_state.oRootFs = oRootProxy
  
  local bListOk, tCompList = syscall("raw_component_list")
  if not bListOk then return end
  
  for sAddr, sCtype in pairs(tCompList) do
    syscall("kernel_log", "[PM] Found '" .. sCtype .. "'. Loading driver.")
    syscall("signal_send", nDkmsPid, "load_driver_for_component", sCtype, sAddr)
  end
end

__scandrvload()
syscall("kernel_log", "[PM] Scan complete.")

local deadline = computer.uptime() + 2.0
while computer.uptime() < deadline do syscall("kernel_host_yield") end

syscall("kernel_log", "[PM] Spawning /bin/init.lua...")
local nInitPid, sInitErr = syscall("process_spawn", "/bin/init.lua", 3)
if not nInitPid then syscall("kernel_log", "[PM] FAILED TO SPAWN INIT: " .. tostring(sInitErr))
else syscall("kernel_log", "[PM] Init spawned as PID " .. tostring(nInitPid)) end

while true do
  local bOk, nSender, sSignal, tData = syscall("signal_pull")
  
  if bOk and sSignal == "syscall" then
    local sName = tData.name
    local tArgs = tData.args
    local nCaller = tData.sender_pid
    local result1, result2
    
    if sName == "vfs_open" then result1, result2 = vfs_state.handle_open(nCaller, tArgs[1], tArgs[2])
    elseif sName == "vfs_write" then
       if vfs_state.tOpenHandles[tArgs[1]] then result1, result2 = vfs_state.handle_write(nCaller, tArgs[1], tArgs[2])
       else result1, result2 = nil, "Bad FD" end
    elseif sName == "vfs_read" then
       local tHandle = vfs_state.tOpenHandles[tArgs[1]]
       if tHandle and tHandle.type == "file" then
         result1, result2 = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", tHandle.handle, tArgs[2])
       else result1, result2 = nil, "Bad FD" end
    elseif sName == "vfs_close" then
       local nFd = tArgs[1]
       if vfs_state.tOpenHandles[nFd] then
         syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", vfs_state.tOpenHandles[nFd].handle)
         vfs_state.tOpenHandles[nFd] = nil
         result1 = true
       end
    elseif sName == "vfs_list" then
       result1, result2 = syscall("raw_component_invoke", vfs_state.oRootFs.address, "list", tArgs[1])
    end
    
    if result1 ~= "async_wait" then
       syscall("signal_send", nCaller, "syscall_return", true, result1, result2)
    end
  end
end