--
-- /lib/pipeline_manager.lua
-- VFS Router with Device Proxy Support
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

local nMyPid = syscall("process_get_pid") -- own pid

local nDkmsPid, sDkmsErr = syscall("process_spawn", "/system/dkms.lua", 1)
if not nDkmsPid then syscall("kernel_panic", "Could not spawn DKMS: " .. tostring(sDkmsErr)) end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

local vfs_state = { oRootFs = nil, nNextFd = 1, tOpenHandles = {} }

syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")


local function wait_for_dkms()
  while true do
    local bOk, nSender, sSig, p1, p2, p3, p4, p5 = syscall("signal_pull")
    
    if bOk then
        if sSig == "syscall_return" and nSender == nDkmsPid then
           return p1, p2 -- Status, Information

        elseif sSig == "os_event" then
           syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
        end
    end
  end
end

function vfs_state.handle_open(nSenderPid, sPath, sMode)
  if string.sub(sPath, 1, 5) == "/dev/" then
    -- proxying
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    
    if sPath == "/dev/tty" then pIrp.sDeviceName = "\\Device\\TTY0" 
    elseif sPath == "/dev/gpu0" then pIrp.sDeviceName = "\\Device\\Gpu0"
    else pIrp.sDeviceName = "\\Device" .. sPath:sub(5):gsub("/", "\\") end

    -- sender - WE (PM), so that the answer comes to us
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sMode = sMode
    
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    
    -- status
    local nStatus, vInfo = wait_for_dkms()
    
    if nStatus == 0 then -- STATUS_SUCCESS
       local nFd = vfs_state.nNextFd
       vfs_state.nNextFd = vfs_state.nNextFd + 1
       -- remember that this FD is associated with a device
       vfs_state.tOpenHandles[nFd] = { 
         type = "device", 
         devname = pIrp.sDeviceName 
       }
       return true, nFd
    else
       return nil, "Device Open Failed: " .. tostring(nStatus)
    end
  end
  
  local bOk, hHandle, sReason = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", sPath, sMode)
  if not hHandle then return nil, sReason end
  
  local nFd = vfs_state.nNextFd
  vfs_state.nNextFd = vfs_state.nNextFd + 1
  vfs_state.tOpenHandles[nFd] = { type = "file", handle = hHandle }
  
  return true, nFd
end

function vfs_state.handle_write(nSenderPid, nFd, sData)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  
  if tHandle.type == "file" then
    return syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", tHandle.handle, sData)
    
  elseif tHandle.type == "device" then
    -- proxying into device
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_WRITE)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sData = sData
    
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then return true, vInfo else return nil, "Write Error" end
  end
end

function vfs_state.handle_read(nSenderPid, nFd, nCount)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  
  if tHandle.type == "file" then
    local res1, res2 = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", tHandle.handle, nCount)
    if type(res2) == "boolean" then res2 = nil end
    return res1, res2
    
  elseif tHandle.type == "device" then
    -- proxying read form device
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_READ)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    
    -- reading a TTY is asynchronous by nature (we wait for keystrokes).
    -- but here we're waiting for the IRP to complete. DKMS won't respond until the TTY presses Enter
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then return true, vInfo else return nil, "Read Error" end
  end
end

function vfs_state.handle_close(nSenderPid, nFd)
    local tHandle = vfs_state.tOpenHandles[nFd]
    if not tHandle then return nil end
    
    if tHandle.type == "file" then
        syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", tHandle.handle)
    elseif tHandle.type == "device" then
        -- send IRP_MJ_CLOSE
        local tDKStructs = require("shared_structs")
        local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CLOSE)
        pIrp.sDeviceName = tHandle.devname
        pIrp.nSenderPid = nMyPid
        syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
        wait_for_dkms()
    end
    
    vfs_state.tOpenHandles[nFd] = nil
    return true
end


local function get_gpu_proxy()
  local bOk, tList = syscall("raw_component_list", "gpu")
  if not bOk or not tList then return nil end
  for sAddr in pairs(tList) do
    return syscall("raw_component_proxy", sAddr)
  end
end

local function get_screen_addr()
  local bOk, tList = syscall("raw_component_list", "screen")
  if not bOk or not tList then return nil end
  for sAddr in pairs(tList) do return sAddr end
end

local function wait_with_throbber(sMessage, nSeconds)
  local oGpu = get_gpu_proxy()
  local sScreen = get_screen_addr()
  
  local nWidth, nHeight = 80, 25
  if oGpu and sScreen then 
     oGpu.bind(sScreen) 
     nWidth, nHeight = oGpu.getResolution()
  end

  local nStartTime = computer.uptime()
  local nDeadline = nStartTime + nSeconds
  
  local sPattern = " * * * "
  local nFrame = 0
  local nThrobberWidth = 12 -- (  * * *   )
  
  syscall("kernel_log", "[PM] " .. sMessage)
  
  while computer.uptime() < nDeadline do
    if oGpu then
       local nPos = math.floor(nFrame / 1.5) % (nThrobberWidth * 2 - 2)
       if nPos >= nThrobberWidth then nPos = (nThrobberWidth * 2 - 2) - nPos end
       
       local sLine = "("
       for i = 0, nThrobberWidth - 1 do
          if i >= nPos and i < nPos + 3 then
             sLine = sLine .. "*"
          else
             sLine = sLine .. " "
          end
       end
       sLine = sLine .. ")"
       local sFullMsg = string.format("%s %s", sLine, "Driver loading...")
       oGpu.set(1, nHeight, sFullMsg .. string.rep(" ", nWidth - #sFullMsg))
       
       nFrame = nFrame + 1
    end
    
    syscall("process_yield")
  end
  
  if oGpu then oGpu.fill(1, nHeight, nWidth, 1, " ") end
end

local function __scandrvload()
  syscall("kernel_log", "[PM] Loading TTY Driver explicitly...")
  raw_computer.beep(600, 0.01)
  syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/tty.sys.lua")
  raw_computer.beep(600, 0.01)
  
  local deadline = computer.uptime() + 2.0
  while computer.uptime() < deadline do syscall("process_yield") end

  syscall("kernel_log", "[PM] Scanning components...")
  raw_computer.beep(600, 0.01)

  local sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
  if not oRootProxy then syscall("kernel_panic", "Pipeline could not get root FS info.") end
  vfs_state.oRootFs = oRootProxy
  
  local bListOk, tCompList = syscall("raw_component_list")
  if not bListOk then return end
  
  for sAddr, sCtype in pairs(tCompList) do
    if sCtype ~= "screen" and sCtype ~= "gpu" and sCtype ~= "keyboard" then
        syscall("kernel_log", "[PM] Loading driver for " .. sCtype)
        syscall("signal_send", nDkmsPid, "load_driver_for_component", sCtype, sAddr)
    end
  end
end

__scandrvload()

wait_with_throbber("Waiting for system stabilization...", 3.0)

syscall("kernel_log", "[PM] Silence on deck. Handing off to userspace.")
raw_computer.beep(600, 0.01)
syscall("kernel_set_log_mode", false)

syscall("kernel_log", "[PM] Spawning /bin/init.lua...")
local nInitPid, sInitErr = syscall("process_spawn", "/bin/init.lua", 3)

if not nInitPid then syscall("kernel_log", "[PM] FAILED TO SPAWN INIT: " .. tostring(sInitErr))
else syscall("kernel_log", "[PM] Init spawned as PID " .. tostring(nInitPid)) end
raw_computer.beep(600, 0.01)

while true do
  local bOk, nSender, sSignal, p1, p2, p3, p4, p5 = syscall("signal_pull")
  
  if bOk then
    if sSignal == "syscall" then
      local tData = p1 -- data table for syscall first
      local sName = tData.name
      local tArgs = tData.args
      local nCaller = tData.sender_pid
      local result1, result2
      
      if sName == "vfs_open" then result1, result2 = vfs_state.handle_open(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_write" then result1, result2 = vfs_state.handle_write(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_read" then result1, result2 = vfs_state.handle_read(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_close" then result1, result2 = vfs_state.handle_close(nCaller, tArgs[1])
      elseif sName == "vfs_list" then
         result1, result2 = syscall("raw_component_invoke", vfs_state.oRootFs.address, "list", tArgs[1])
      end
      
      if result1 ~= "async_wait" then
         syscall("signal_send", nCaller, "syscall_return", result1, result2)
      end

    -- 2. НОВОЕ: Пересылка событий оборудования в DKMS
    elseif sSignal == "os_event" then
       -- p1=eventName, p2=addr, p3=char, p4=code ...
       -- Просто пересылаем как есть диспетчеру драйверов
       syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
    end
  end
end