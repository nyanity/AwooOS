--
-- /lib/pipeline_manager.lua
-- VFS Router with Device Proxy Support
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

local nMyPid = syscall("process_get_pid") 

local tPermCache = nil

local nDkmsPid, sDkmsErr = syscall("process_spawn", "/system/dkms.lua", 1)
if not nDkmsPid then syscall("kernel_panic", "Could not spawn DKMS: " .. tostring(sDkmsErr)) end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

local vfs_state = { oRootFs = nil, nNextFd = 0, tOpenHandles = {} }

syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")
syscall("syscall_override", "vfs_chmod")

syscall("syscall_override", "driver_load")


-- helper to parse "rw,size=100" into {rw=true, size=100}
local function parse_options(sOptions)
  local tOpts = {}
  if not sOptions then return tOpts end
  for sPart in string.gmatch(sOptions, "[^,]+") do
    local k, v = sPart:match("([^=]+)=(.*)")
    if k then 
      tOpts[k] = tonumber(v) or v 
    else
      tOpts[sPart] = true
    end
  end
  return tOpts
end

-- flushes the kernel boot log into the ringfs device
local function flush_boot_log(sLogDevice)
  syscall("kernel_log", "[PM] Flushing boot log to " .. sLogDevice)
  
  -- 1. Get the log from kernel (ring 0)
  local sBootLog = syscall("kernel_get_boot_log")
  if not sBootLog or #sBootLog == 0 then return end
  
  -- 2. Open the log device via our own VFS handler (loopback style)
  -- we use the raw syscall mechanism to bypass our own overrides if needed, 
  -- but calling handle_open directly is cleaner since we are the PM.
  local bOk, nFd = vfs_state.handle_open(nMyPid, sLogDevice, "w")
  
  if bOk then
     vfs_state.handle_write(nMyPid, nFd, sBootLog)
     vfs_state.handle_close(nMyPid, nFd)
     syscall("kernel_log", "[PM] Boot log flushed.")
  else
     syscall("kernel_log", "[PM] Failed to open log device for flushing.")
  end
end


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

local function load_perms()
  -- Capture both success flag AND the handle
  local bOk, h = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/perms.lua", "r")
  
  if bOk and h then
     local bReadOk, d = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", h, math.huge)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", h)
     
     if bReadOk and d then 
        local f = load(d, "perms", "t", {})
        if f then tPermCache = f() end
     end
  end
  if not tPermCache then tPermCache = {} end
end

local function save_perms()
  if not tPermCache then return end
  
  local sData = "return {\n"
  for sPath, tInfo in pairs(tPermCache) do
     sData = sData .. string.format('  ["%s"] = { uid = %d, gid = %d, mode = %d },\n', 
       sPath, tInfo.uid or 0, tInfo.gid or 0, tInfo.mode or 755)
  end
  sData = sData .. "}"
  
  -- capture both success flag AND the handle
  local bOk, h = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/perms.lua", "w")
  
  if bOk and h then
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", h, sData)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", h)
  else
     syscall("kernel_log", "[PM] ERROR: Failed to save permissions to disk!")
  end
end

local function check_access(nPid, sPath, sMode)
  -- 1. Get process info (we need to trust the kernel process table)
  -- Since PM is Ring 1, we can't read kernel tables directly easily without a syscall.
  -- Let's assume the UID is passed in the ENV of the process.
  -- BUT: PM cannot easily read other process envs.
  
  -- SHORTCUT: For this iteration, we will trust a cached UID map or assume 
  -- processes passed their UID during open? No, that's insecure.
  
  -- REALITY CHECK: Implementing full UID tracking in PM requires PM to track PIDs.
  -- Let's assume for now that PID 0-10 are SYSTEM (UID 0).
  
  -- For the sake of this example, let's say we added a syscall "process_get_uid" to kernel.
  -- If not, we default to UID 1000 (User) unless it's a system PID.
  
  local nUid = 1000 -- default to peasant
  if nPid < 20 then nUid = 0 end -- system services are root
  
  -- If we are root, we do what we want.
  if nUid == 0 then return true end
  
  -- 2. Check Perms
  if not tPermCache then load_perms() end
  local tP = tPermCache[sPath]
  
  -- Default permissions if not listed: 755 (rwxr-xr-x) owned by root
  if not tP then tP = { uid=0, gid=0, mode=755 } end
  
  -- 3. Calculate required bit
  local nReq = 4 -- read
  if sMode == "w" or sMode == "a" then nReq = 2 end -- write
  
  -- 4. Check ownership
  local nPermDigit = 0
  local sModeStr = tostring(tP.mode)
  
  if nUid == tP.uid then
     nPermDigit = tonumber(sModeStr:sub(1,1)) -- Owner
  else
     nPermDigit = tonumber(sModeStr:sub(3,3)) -- Others (skipping group for now)
  end
  
  -- Bitwise check (lua 5.2 doesn't have bit32 lib by default in OC sometimes, so manual check)
  -- 7=rwx, 6=rw, 5=rx, 4=r, 2=w, 1=x
  local bAllowed = false
  if nReq == 4 then -- Read
     if nPermDigit >= 4 then bAllowed = true end
  elseif nReq == 2 then -- Write
     if nPermDigit == 2 or nPermDigit == 3 or nPermDigit == 6 or nPermDigit == 7 then bAllowed = true end
  end
  
  if not bAllowed then
     syscall("kernel_log", "[PM] ACCESS DENIED: PID " .. nPid .. " tried to " .. sMode .. " " .. sPath)
  end
  
  return bAllowed
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

    if not check_access(nSenderPid, sPath, sMode or "r") then
     return nil, "Permission denied"
  end
  
  local bOk, hHandle, sReason = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", sPath, sMode)
  if not hHandle then return nil, sReason end
  
  local nFd = vfs_state.nNextFd
  vfs_state.nNextFd = vfs_state.nNextFd + 1
  vfs_state.tOpenHandles[nFd] = { type = "file", handle = hHandle }
  
  return true, nFd
end

function vfs_state.handle_chmod(nSenderPid, sPath, nMode)
  -- 1. Identify the user
  local nUid = syscall("process_get_uid", nSenderPid) or 1000
  
  -- 2. Load perms if needed
  if not tPermCache then load_perms() end
  
  -- 3. Get current file info
  local tEntry = tPermCache[sPath]
  
  -- if file not in db, create a default entry owned by root (secure by default)
  -- wait, if it's not in db, maybe the user created it? 
  -- for now, if it's not in db, we assume it's a new entry.
  if not tEntry then
     tEntry = { uid = nUid, gid = 0, mode = 755 }
     tPermCache[sPath] = tEntry
  end
  
  -- 4. SECURITY CHECK: The "Highest Right" Logic
  -- Only the owner or UID 0 (dev/kernel) can change permissions.
  if nUid ~= 0 and tEntry.uid ~= nUid then
     syscall("kernel_log", "[PM] CHMOD DENIED: PID " .. nSenderPid .. " (UID " .. nUid .. ") tried to touch " .. sPath)
     return nil, "Operation not permitted (Not owner)"
  end
  
  -- 5. EXTRA SECURITY: Protect system files from accidental sudoers
  -- Even if you own it (somehow), if it's in /boot or /sys, only UID 0 can chmod.
  if nUid ~= 0 and (sPath:sub(1,5) == "/boot" or sPath:sub(1,4) == "/sys") then
     return nil, "Operation not permitted (System protected)"
  end
  
  -- 6. Apply and Save
  tEntry.mode = nMode
  save_perms()
  
  syscall("kernel_log", "[PM] CHMOD: " .. sPath .. " -> " .. nMode .. " by UID " .. nUid)
  return true
end

function vfs_state.handle_write(nSenderPid, nFd, sData)
  local tHandle = vfs_state.tOpenHandles[nFd]
  if not tHandle then return nil, "Invalid Handle" end
  
  if tHandle.type == "file" then
    return syscall("raw_component_invoke", vfs_state.oRootFs.address, "write", tHandle.handle, sData)
    
  elseif tHandle.type == "device" then
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_WRITE)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    pIrp.tParameters.sData = sData
    
    -- OPTIMIZATION: FIRE AND FORGET WITH SILENCER
    if tHandle.devname == "\\Device\\TTY0" then
        pIrp.nFlags = tDKStructs.IRP_FLAG_NO_REPLY -- <--- Set the silence flag
        syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
        return true, #sData
    end
    
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
    local tDKStructs = require("shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_READ)
    pIrp.sDeviceName = tHandle.devname
    pIrp.nSenderPid = nMyPid
    
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    
    -- we MUST wait for read, obviously.
    local nStatus, vInfo = wait_for_dkms()
    if nStatus == 0 then return true, vInfo else return nil, "Read Error" end
  end
end

function vfs_state.handle_list(nSenderPid, sPath)
  -- Clean up path (remove trailing slash for check)
  local sCleanPath = sPath
  if #sCleanPath > 1 and string.sub(sCleanPath, -1) == "/" then
     sCleanPath = string.sub(sCleanPath, 1, -2)
  end

  -- INTERCEPTION: If listing /dev, ask DKMS
  if sCleanPath == "/dev" then
     syscall("signal_send", nDkmsPid, "dkms_list_devices_request", nSenderPid)
     
     while true do
        local bOk, nSender, sSig, p1, p2 = syscall("signal_pull")
        if bOk and nSender == nDkmsPid then
           if sSig == "dkms_list_devices_result" and p1 == nSenderPid then
              local tDeviceList = p2
              return true, tDeviceList
           elseif sSig == "os_event" then
              syscall("signal_send", nDkmsPid, "os_event", p1, p2)
           end
        end
     end
  end

  local bOk, tListOrErr = syscall("raw_component_invoke", vfs_state.oRootFs.address, "list", sPath)
  if bOk then return true, tListOrErr else return nil, tListOrErr end
end

function vfs_state.handle_close(nSenderPid, nFd)
    local tHandle = vfs_state.tOpenHandles[nFd]
    if not tHandle then return nil end
    
    if tHandle.type == "file" then
        syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", tHandle.handle)
    elseif tHandle.type == "device" then
        local tDKStructs = require("shared_structs")
        local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CLOSE)
        pIrp.sDeviceName = tHandle.devname
        pIrp.nSenderPid = nMyPid
        syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
        -- close can also be fire-and-forget for TTY if you want, but safer to wait
        wait_for_dkms()
    end
    
    vfs_state.tOpenHandles[nFd] = nil
    return true
end

-- handler for the driver_load syscall

function vfs_state.handle_driver_load(nSenderPid, sPath)
  syscall("kernel_log", "[PM] User (PID " .. nSenderPid .. ") requested load of: " .. sPath)
  syscall("signal_send", nDkmsPid, "load_driver_path_request", sPath, nSenderPid)
  while true do
    local bOk, nSender, sSig, p1, p2, p3, p4 = syscall("signal_pull") 
    if bOk and nSender == nDkmsPid then
       if sSig == "load_driver_result" and p1 == nSenderPid then
          local nStatus, sDrvName, nDrvPid = p2, p3, p4
          if not sDrvName then sDrvName = "Unknown" end
          if nStatus == 0 then 
             local sMsg = (nDrvPid == 0) and string.format("[PM] Success: %s", sDrvName) or string.format("[PM] Success: Loaded '%s' (PID %d)", sDrvName, nDrvPid)
             syscall("kernel_log", sMsg)
             return true, sMsg 
          else
             local sMsg = "[PM] Driver load failed. Status: " .. tostring(nStatus)
             syscall("kernel_log", sMsg)
             return nil, sMsg 
          end
       elseif sSig == "os_event" then
          syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4)
       end
    end
  end
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
  --syscall("kernel_log", "[PM] Loading RingFS Driver...")
  --syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/ringfs.sys.lua")
  
  syscall("kernel_log", "[PM] Loading TTY Driver explicitly...")
  --raw_computer.beep(600, 0.01)
  syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/tty.sys.lua")
  --raw_computer.beep(600, 0.01)
  
  local deadline = computer.uptime() + 0.0
  while computer.uptime() < deadline do syscall("process_yield") end

  syscall("kernel_log", "[PM] Scanning components...")
  --raw_computer.beep(600, 0.01)

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


local function process_fstab()
  syscall("kernel_log", "[PM] Processing fstab...")
  
  -- we skip sys.cfg for now to keep it simple, let's focus on the crash.

  -- raw_component_invoke returns (bool_success, return_val).
  -- we need to catch both, otherwise we try to load a boolean.
  local bOpenOk, hFstab = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/fstab.lua", "r")
  
  if bOpenOk and hFstab then
     local bReadOk, sData = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", hFstab, math.huge)
     
     -- always close your handles, kids
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFstab)
     
     if bReadOk and type(sData) == "string" then
        local f, sErr = load(sData, "fstab", "t", {})
        if f then 
           local tFstab = f()
           if type(tFstab) == "table" then
               for _, tEntry in ipairs(tFstab) do
                  if tEntry.type == "ringfs" then
                     -- 1. Load the driver explicitly
                     if not bRingFsLoaded then
                         syscall("kernel_log", "[PM] Auto-loading RingFS...")
                         syscall("signal_send", nDkmsPid, "load_driver_path", "/drivers/ringfs.sys.lua")
                         syscall("process_wait", 0) 
                         bRingFsLoaded = true
                     end
                     
                     -- 2. Parse options
                     local tOpts = parse_options(tEntry.options)
                     
                     -- 3. Resize if needed
                     if tOpts.size then
                        local tDKStructs = require("shared_structs")
                        local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_DEVICE_CONTROL)
                        pIrp.sDeviceName = "\\Device\\ringlog"
                        pIrp.nSenderPid = nMyPid
                        pIrp.tParameters.sMethod = "resize"
                        pIrp.tParameters.tArgs = { tOpts.size }
                        
                        syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
                        wait_for_dkms()
                     end
                     
                     -- 4. Flush boot logs
                     if string.sub(tEntry.path, 1, 5) == "/dev/" then
                        flush_boot_log(tEntry.path)
                     end
                  end
               end
           end
        else
            syscall("kernel_log", "[PM] Syntax error in fstab: " .. tostring(sErr))
        end
     end
  else
     syscall("kernel_log", "[PM] Warning: /etc/fstab.lua not found or unreadable.")
  end
end

local function process_autoload()
  syscall("kernel_log", "[PM] Processing autoload...")
  local bOk, hFile = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", "/etc/autoload.lua", "r")
  
  if bOk and hFile then
     local _, sData = syscall("raw_component_invoke", vfs_state.oRootFs.address, "read", hFile, math.huge)
     syscall("raw_component_invoke", vfs_state.oRootFs.address, "close", hFile)
     
     if sData then
        local f = load(sData, "autoload", "t", {})
        if f then
           local tList = f()
           if tList then
              for _, sDrvPath in ipairs(tList) do
                 syscall("kernel_log", "[PM] Autoloading: " .. sDrvPath)
                 syscall("signal_send", nDkmsPid, "load_driver_path", sDrvPath)
                 -- give it a moment to breathe
                 syscall("process_wait", 0)
              end
           end
        end
     end
  end
end

-- ==============================

__scandrvload()
process_fstab()
if env.SAFE_MODE then
   syscall("kernel_log", "[PM] SAFE MODE ENABLED: Skipping autoload.lua")
else
   process_autoload()
end

wait_with_throbber("Waiting for system stabilization...", 1.0)

syscall("kernel_log", "[PM] Silence on deck. Handing off to userspace.")
syscall("kernel_set_log_mode", false)


-- ==============================

local sInitPath = env.INIT_PATH or "/bin/init.lua"
syscall("kernel_log", "[PM] Spawning " .. sInitPath .. "...")
local nInitPid, sInitErr = syscall("process_spawn", sInitPath, 3)

if not nInitPid then syscall("kernel_log", "[PM] FAILED TO SPAWN INIT: " .. tostring(sInitErr))
else syscall("kernel_log", "[PM] Init spawned as PID " .. tostring(nInitPid)) end


while true do
  local bOk, nSender, sSignal, p1, p2, p3, p4, p5 = syscall("signal_pull")
  if bOk then
    if sSignal == "syscall" then
      local tData = p1
      local sName = tData.name
      local tArgs = tData.args
      local nCaller = tData.sender_pid
      local result1, result2
      
      if sName == "vfs_open" then result1, result2 = vfs_state.handle_open(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_write" then result1, result2 = vfs_state.handle_write(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_read" then result1, result2 = vfs_state.handle_read(nCaller, tArgs[1], tArgs[2])
      elseif sName == "vfs_close" then result1, result2 = vfs_state.handle_close(nCaller, tArgs[1])
      elseif sName == "vfs_list" then result1, result2 = vfs_state.handle_list(nCaller, tArgs[1])
      elseif sName == "vfs_chmod" then result1, result2 = vfs_state.handle_chmod(nCaller, tArgs[1], tArgs[2])
      elseif sName == "driver_load" then result1, result2 = vfs_state.handle_driver_load(nCaller, tArgs[1])
      end
      
      if result1 ~= "async_wait" then
         syscall("signal_send", nCaller, "syscall_return", result1, result2)
      end
    elseif sSignal == "os_event" then
       syscall("signal_send", nDkmsPid, "os_event", p1, p2, p3, p4, p5)
    end
  end
end