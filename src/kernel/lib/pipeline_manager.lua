--
-- /lib/pipeline_manager.lua
-- ring 1's big boss. manages drivers and the vfs. the kernel's trusted lieutenant.
--

local syscall = syscall -- The raw syscall function

-- announce our presence to the kernel
syscall("kernel_register_pipeline")
syscall("kernel_log", "[Ring 1] Pipeline Manager started.")

-- module-level state tables
local vfs_state = {
  tMounts = {},
  oRootFs = nil,
  nNextFd = 1,
  tOpenHandles = {}, -- [pid][fd] = { vfs_node, oc_handle, path, mode }
}

local driverpid = {
  nTTY = nil,
  nGPU = nil,
  nLog = nil,
}

-------------------------------------------------
-- VFS Implementation
-------------------------------------------------

-- where should this file path go? let's find out.
function vfs_state.find_mount(sPath)
  -- TODO: implement proper mount point resolution
  -- for now, all paths go to rootfs. keep it simple, stupid.
  return vfs_state.tMounts["/"]
end

-- knock knock. who's there? it's a process wanting a file.
function vfs_state.syscall_open(nSenderPid, sPath, sMode)
  syscall("kernel_log", "[Ring 1] VFS_OPEN: " .. sPath)
  
  -- Special device files
  if sPath == "/dev/tty" then
    -- This is a "virtual" file that talks to the TTY driver.
    local nFd = vfs_state.nNextFd; vfs_state.nNextFd = vfs_state.nNextFd + 1
    if not vfs_state.tOpenHandles[nSenderPid] then vfs_state.tOpenHandles[nSenderPid] = {} end
    vfs_state.tOpenHandles[nSenderPid][nFd] = {
      type = "tty",
      path = sPath,
      mode = sMode,
    }
    return nFd
  end

  -- TODO: check for other mounts (logfs, etc)
  
  -- default to rootfs for normal files
  local tMount = vfs_state.find_mount(sPath)
  if not tMount then
    return nil, "No filesystem for path"
  end
  
  local oProxy = tMount.proxy
  local bOk, hHandle, sReason = syscall("raw_component_invoke", oProxy.address, "open", sPath, sMode)
  if not (bOk and hHandle) then
    return nil, sReason or "Invocation failed"
  end
  
  local nFd = vfs_state.nNextFd; vfs_state.nNextFd = vfs_state.nNextFd + 1
  if not vfs_state.tOpenHandles[nSenderPid] then vfs_state.tOpenHandles[nSenderPid] = {} end
  vfs_state.tOpenHandles[nSenderPid][nFd] = {
    type = "file",
    path = sPath,
    mode = sMode,
    oc_handle = hHandle,
    proxy = oProxy,
  }
  return nFd
end

-- the process is thirsty for data.
function vfs_state.syscall_read(nSenderPid, nFd, nCount)
  local hHandle = vfs_state.tOpenHandles[nSenderPid] and vfs_state.tOpenHandles[nSenderPid][nFd]
  if not hHandle then return nil, "Invalid file descriptor" end
  
  if hHandle.type == "tty" then
    -- reading from the tty is async. we ask the driver and wait for a reply.
    syscall("signal_send", driverpid.nTTY, "tty_read", nSenderPid)
    return "async_wait"
    
  elseif hHandle.type == "file" then
    local bSyscallOk, bPcallOk, valDataOrErr = syscall("raw_component_invoke", hHandle.proxy.address, "read", hHandle.oc_handle, nCount or math.huge)
    if bSyscallOk and bPcallOk then
      return valDataOrErr
    else
      return nil, valDataOrErr
    end
  end
end

function vfs_state.syscall_write(nSenderPid, nFd, sData)
  syscall("kernel_log", string.format("[PM VFS_WRITE] Received from PID %s for FD %s. Data: '%s'", tostring(nSenderPid), tostring(nFd), tostring(sData)))

  local hHandle = vfs_state.tOpenHandles[nSenderPid] and vfs_state.tOpenHandles[nSenderPid][nFd]
  if not hHandle then return nil, "Invalid file descriptor" end

  if hHandle.type == "tty" then
    syscall("signal_send", driverpid.nTTY, "tty_write", nSenderPid, sData)
    return true -- TTY write is fire-and-forget from our perspective.
    
  elseif hHandle.type == "file" then
    local bOk, sReason = syscall("raw_component_invoke", hHandle.proxy.address, "write", hHandle.oc_handle, sData)
    if not bOk then return nil, sReason end
    return true
  end
end

function vfs_state.syscall_close(nSenderPid, nFd)
  local hHandle = vfs_state.tOpenHandles[nSenderPid] and vfs_state.tOpenHandles[nSenderPid][nFd]
  if not hHandle then return nil, "Invalid file descriptor" end
  
  vfs_state.tOpenHandles[nSenderPid][nFd] = nil -- Free the FD
  
  if hHandle.type == "file" then
    syscall("raw_component_invoke", hHandle.proxy.address, "close", hHandle.oc_handle)
  end
  return true
end

function vfs_state.syscall_list(nSenderPid, sPath)
    local tMount = vfs_state.find_mount(sPath)
    if not tMount then return nil, "No filesystem for path" end
    local bOk, tList, sReason = syscall("raw_component_invoke", tMount.proxy.address, "list", sPath)
    if not bOk then return nil, tList end
    return tList
end

-- override the VFS syscalls. we're in charge of these now. sorry, kernel.
syscall("syscall_override", "vfs_open")
syscall("syscall_override", "vfs_read")
syscall("syscall_override", "vfs_write")
syscall("syscall_override", "vfs_close")
syscall("syscall_override", "vfs_list")

-------------------------------------------------
-- Driver Loading
-------------------------------------------------

-- hey you, new component. you need a driver. let's find one.
local function load_driver(sComponentType, sAddress)
  local sDriverPath = "/drivers/" .. sComponentType .. ".sys.lua"
  
  -- we must use the Ring 0 VFS, as our own VFS isn't fully up.
  -- this is a bit of a hack.
  -- let's just spawn the process. the kernel's loader will find the file.
  
  syscall("kernel_log", "[Ring 1] Loading driver " .. sDriverPath .. " for " .. sAddress)
  
  local bIsOk, nPid, sErr = syscall("process_spawn", sDriverPath, 2, {
    address = sAddress
  })
  
  if not nPid then
    syscall("kernel_log", "[Ring 1] FAILED to load driver: " .. sErr)
    return
  end
  
  syscall("kernel_log", "[Ring 1] Driver " .. sComponentType .. " spawned as PID " .. nPid)
  
  -- store special drivers
  if sComponentType == "tty" then
    driverpid.nTTY = nPid
  elseif sComponentType == "gpu" then
    driverpid.nGPU = nPid
  end
  
  -- register this driver with the kernel
  syscall("kernel_register_driver", sComponentType, nPid)
  syscall("kernel_map_component", sAddress, nPid)
end

-- time to see what hardware we've got to work with.
local function __scandrvload()
  syscall("kernel_log", "[Ring 1] Scanning for components...")
  
  -- receive information about the root file system from the kernel
  local bIsOk, sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
  if not bIsOk then
    syscall("kernel_panic", "Pipeline could not get root FS info from kernel: " .. tostring(sRootUuid))
    return
  end
  
  syscall("kernel_log", "[Ring 1] Got root FS: " .. sRootUuid)
  
  -- registering the root mount point in the VFS manager
  vfs_state.tMounts["/"] = {
    type = "rootfs",
    proxy = oRootProxy,
  }

  -- scan for all components
  local bListOk, tComponentList = syscall("raw_component_list")
  if not bListOk then
    syscall("kernel_log", "[Ring 1] Failed to list components: " .. tComponentList)
    return
  end
  
  local sGpuAddress, sScreenAddress
  for sAddr, sCtype in pairs(tComponentList) do
    if sCtype == "gpu" and not sGpuAddress then
      sGpuAddress = sAddr
    elseif sCtype == "screen" and not sScreenAddress then
      sScreenAddress = sAddr
    end
  end

  -- if there is a screen and gpu then run tty
  if sGpuAddress and sScreenAddress then
    syscall("kernel_log", "[Ring 1] Found screen and GPU. Loading TTY driver.")
    local bSpawnOk, nPid, sErr = syscall("process_spawn", "/drivers/tty.sys.lua", 2, {
      gpu = sGpuAddress,
      screen = sScreenAddress
    })
    if nPid then
      driverpid.nTTY = nPid
      syscall("kernel_log", "[Ring 1] TTY driver spawned as PID " .. nPid .. ". Stored in driverpid.nTTY.")
    else
      syscall("kernel_log", "[Ring 1] FAILED to load TTY driver: " .. sErr)
    end
  end
  
  -- load drivers for everything else
  for sAddr, sCtype in pairs(tComponentList) do
    -- skipping already satisfied types
    if sCtype ~= "gpu" and sCtype ~= "screen" and sCtype ~= "tty" then
      load_driver(sCtype, sAddr)
    end
  end
  
  syscall("kernel_log", "[Ring 1] Driver loading initiated.")
end

-- run the hardware scan
__scandrvload()

-- state for the main loop
local tState = {
  bIsTtyReady = false,
  bIsInitSpawned = false,
}

-- a message indicating that we're entering the main loop.
print("[Ring 1] Entering main pipeline event loop...")

-------------------------------------------------
-- Main Pipeline Event Loop
-------------------------------------------------
-- juggling signals from drivers, syscalls from userspace, and os events. a day in the life.
while true do
  local bSyscallOk, bPullOk, nSenderPid, sSignalName, p1, p2, p3, p4 = syscall("signal_pull")
  
  if bSyscallOk and bPullOk then
    --syscall("kernel_log", string.format("[PM] Woke up! Received signal. Sender: %s, Name: %s", tostring(nSenderPid), tostring(sSignalName)))

    if sSignalName == "syscall" then
      local tData = p1
      local s_syscallname = tData.name
      local tArgs = tData.args
      local nOriginalSenderPid = tData.sender_pid
      
      local sShortName = string.sub(s_syscallname, 5) -- remove "vfs_"
      local fHandler = vfs_state["syscall_" .. sShortName]

      if fHandler then
          local tResponse = {pcall(fHandler, nOriginalSenderPid, table.unpack(tArgs))}
          local bIsReturnOk = table.remove(tResponse, 1)
          
          if tResponse[1] == "async_wait" then
            -- do nothing, the handler will send a signal later
          else
            if bIsReturnOk then
                syscall("signal_send", nOriginalSenderPid, "syscall_return", true, table.unpack(tResponse))
            else
                syscall("signal_send", nOriginalSenderPid, "syscall_return", false, tResponse[1])
            end
          end
      else
          syscall("signal_send", nOriginalSenderPid, "syscall_return", false, "Unknown VFS syscall: " .. s_syscallname)
      end
      
    elseif sSignalName == "os_event" then
      local sEventName = p1
      if sEventName == "component_added" then
        local sAddr = p2
        local sCtype = p3
        print("[Ring 1] Component added: " .. sCtype .. " at " .. sAddr)
        load_driver(sCtype, sAddr)
      elseif sEventName == "component_removed" then
        -- TODO: Unload driver. good luck with that.

      elseif sEventName == "key_down" then
        -- forward keyboard events to the TTY driver
        if driverpid.nTTY then
          syscall("signal_send", driverpid.nTTY, "os_event", sEventName, p2, p3, p4)
        end
      end

    elseif sSignalName == "driver_ready" then
        if nSenderPid == driverpid.nTTY then
            tState.bIsTtyReady = true
            syscall("kernel_log", "[Ring 1] TTY driver is ready. Spawning init...")
            
            if not tState.bIsInitSpawned then
                tState.bIsInitSpawned = true
                local bSpawnOk, nInitPid, sErr = syscall("process_spawn", "/bin/init.lua", 3)
                if not bSpawnOk then
                  syscall("kernel_log", "[Ring 1] FATAL: Could not spawn /bin/init.lua: " .. sErr)
                  syscall("kernel_panic", "Init spawn failed: " .. tostring(sErr))
                end
            end
        else
            syscall("kernel_log", string.format("[PM] Ignored 'driver_ready' from PID %s because driverpid.nTTY is %s", tostring(nSenderPid), tostring(driverpid.nTTY)))
        end
    end
  end
end