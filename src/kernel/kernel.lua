--
-- /kernel.lua
-- the big kahuna. the heart of the machine.
-- don't touch this unless you know what you're doing. seriously.
--

-- module-level state. our single source of truth.
local kernel = {
  tProcessTable = {},     -- [nPid] = { co, sStatus, nRing, nParentPid, tEnv, tFds, ... }
  tPidMap = {},           -- [coCoroutine] = nPid
  tRings = {},            -- [nPid] = nRingLevel
  nNextPid = 1,           -- our little counter, goes up, never down.
  
  tSyscallTable = {},     -- [sName] = { fFunc, tAllowedRings }
  tSyscallOverrides = {}, -- [sName] = nHandlingPid // for when ring 1 gets uppity
  
  tEventQueue = {},       -- internal queue for OS signals (e.g. component_added). basically our gossip channel.
  
  -- VFS and Drivers
  tVfs = {
    tMounts = {},         -- [sPath] = { sType, oProxy, tOptions }
    oRootFs = nil,        -- the main FS proxy. don't lose this.
    sRootUuid = nil,      -- the address of the root fs. equally important.
  },
  
  tDriverRegistry = {}, -- [sComponentType] = { nDriverPid, ... } // who drives what and loaded drivers (by component type)
  tComponentDriverMap = {}, -- [sAddress] = nPid // mapped component addresses to their driver PIDs
  nPipelinePid = nil, -- the big boss of ring 1
  tBootLog = {}, -- before real logging is a thing
  tLoadedModules = {},
}

-- tracks the currently executing process. super important for context.
local g_nCurrentPid = 0
-- global var for screen line tracking. super primitive.
local g_nDebugY = 2 

-------------------------------------------------
-- EARLY BOOT & DEBUG FUNCTIONS
-------------------------------------------------

-- the emergency broadcast system. no syscalls, just raw power.
local function __gpu_dprint(sText)
  -- try to find a GPU and screen, brute-force style
  local sGpuAddr, sScreenAddr
  for sAddr in raw_component.list("gpu") do sGpuAddr = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddr = sAddr; break end

  if sGpuAddr and sScreenAddr then
    local oGpu = raw_component.proxy(sGpuAddr)
    -- try to bind (ignore errors if it's already bound, who cares)
    pcall(oGpu.bind, sScreenAddr)
    
    -- slap the sText onto the screen
    pcall(oGpu.fill, 1, g_nDebugY, 160, 1, " ")
    pcall(oGpu.set, 1, g_nDebugY, tostring(sText))
    
    -- move the cursor down
    g_nDebugY = g_nDebugY + 1
    if g_nDebugY > 40 then g_nDebugY = 2 end -- loop it around so we don't scroll off into the void
  end
end

-- the one true print function during boot.
local function kprint(sText)
  -- save to log (the usual)
  table.insert(kernel.tBootLog, sText)
  
  -- AND IMMEDIATELY blast it to the screen using the emergency method
  __gpu_dprint(sText)
end

-------------------------------------------------
-- KERNEL PANIC asdfghjkl
-------------------------------------------------

-- the 'everything is on fire' function.
function kernel.panic(sReason)
  -- the song of our people
  raw_computer.beep(400, 0.2)
  raw_computer.pullSignal(0.1)
  raw_computer.beep(400, 0.2)
  raw_computer.pullSignal(0.1)
  raw_computer.beep(400, 0.2)

  local sGpuAddress
  local sScreenAddress
  for sAddr in raw_component.list("gpu") do sGpuAddress = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddress = sAddr; break end

  if sGpuAddress and sScreenAddress then
    local oGpu = raw_component.proxy(sGpuAddress)

    local bIsOk, sBindErr = pcall(oGpu.bind, sScreenAddress)
    if bIsOk then
      pcall(oGpu.fill, 1, 1, 160, 50, " ")
      pcall(oGpu.setForeground, 0xFF5555)
      -- Hahaha! Scaredy cat... AHHHHHHHHHH
      -- https://www.youtube.com/watch?v=5vEwO-orfG8
      pcall(oGpu.set, 2, 2, "!! KERNEL PANIC !!")
      
      pcall(oGpu.setForeground, 0xFFFFFF)
      pcall(oGpu.set, 2, 4, "The kernel has encountered a fatal error and has been halted.")
      pcall(oGpu.set, 2, 6, "Reason: " .. tostring(sReason or "No reason specified."))
      
      pcall(oGpu.set, 2, 8, "---[ Boot Log ]---")
      for i, sMsg in ipairs(kernel.tBootLog or {}) do
        if i > 15 then
          pcall(oGpu.set, 2, 8 + i, "...")
          break
        end
        pcall(oGpu.set, 2, 8 + i, tostring(sMsg))
      end
    end
  end

  while true do
    raw_computer.pullSignal(1) -- the long sleep
  end
end

-------------------------------------------------
-- PRIMITIVE BOOTLOADER HELPERS
-------------------------------------------------

-- this is the filesystem we use before the real vfs is a thing.
local g_oPrimitiveFs = raw_component.proxy(boot_fs_address)

local function primitive_load(sPath)
  -- (this func is fine, but let's make it more robust... or at least pretend to)
  local hFile, sReason = g_oPrimitiveFs.open(sPath, "r")
  if not hFile then
    return nil, "primitive_load failed to open: " .. tostring(sReason or "Unknown error")
  end
  
  local sData = ""
  local sChunk
  repeat
    sChunk = g_oPrimitiveFs.read(hFile, math.huge)
    if sChunk then
      sData = sData .. sChunk
    end
  until not sChunk
  
  g_oPrimitiveFs.close(hFile)
  return sData
end

local function primitive_load_lua(sPath)
  local sCode, sErr = primitive_load(sPath)
  if not sCode then
    kernel.panic("CRITICAL: Failed to load " .. sPath .. ": " .. (sErr or "File not found"))
  end
  
  local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", {})
  if not fFunc then
    kernel.panic("CRITICAL: Failed to parse " .. sPath .. ": " .. sLoadErr)
  end
  
  return fFunc()
end

-------------------------------------------------
-- PROCESS & MODULE MANAGEMENT
-------------------------------------------------

function kernel.custom_require(sModulePath, nCallingPid)
  if kernel.tLoadedModules[sModulePath] then
    return kernel.tLoadedModules[sModulePath]
  end
  
  local tPathsToTry = {
    "/lib/" .. sModulePath .. ".lua",
    "/usr/lib/" .. sModulePath .. ".lua",
    -- for drivers and other sketchy stuff
    "/drivers/" .. sModulePath .. ".lua",
    "/drivers/" .. sModulePath .. ".sys.lua",
    "/system/" .. sModulePath .. ".lua",
    "/system/lib/dk/" .. sModulePath .. ".lua",
    "/sys/security/" .. sModulePath .. ".lua",
  }
  
  local sCode, sErr
  local sFoundPath
  for _, sPath in ipairs(tPathsToTry) do
    -- IMPORTANT: this has to use a VFS syscall, not the primitive loader! we're a real OS now, kinda.
    sCode, sErr = kernel.syscalls.vfs_read_file(nCallingPid, sPath)
    if sCode then
      sFoundPath = sPath
      break
    end
  end
  
  if not sCode then
    return nil, "Module not found: " .. sModulePath
  end
  
  -- grab the process's tEnv
  local tEnv = kernel.tProcessTable[nCallingPid].env
  local fFunc, sLoadErr = load(sCode, "@" .. sFoundPath, "t", tEnv)
  if not fFunc then
    return nil, "Failed to load module " .. sModulePath .. ": " .. sLoadErr
  end
  
  -- run the module's code. cross your fingers.
  local bIsOk, result = pcall(fFunc)
  if not bIsOk then
    return nil, "Failed to initialize module " .. sModulePath .. ": " .. result
  end
  
  kernel.tLoadedModules[sModulePath] = result
  return result
end

-- building the padded walls for our little processes.
function kernel.create_sandbox(nPid, nRing)
  local tEnv = {}
  
  -- safe globals. "safe".
  local tSafeGlobals = {
    "assert", "error", "ipairs", "next", "pairs", "pcall", "print",
    "select", "tonumber", "tostring", "type", "unpack", "_VERSION",
    "xpcall", "coroutine", "string", "table", "math", "os"
  }
  
  -- 'os' is mostly safe. os.exit() is a big no-no.
  local tSafeOs = {}
  for sKey, vValue in pairs(os) do
    if sKey ~= "exit" and sKey ~= "execute" and sKey ~= "remove" and sKey ~= "rename" then
      tSafeOs[sKey] = vValue
    end
  end
  
  -- build the sandbox
  local tSandbox = {
    -- Base functions
    assert = assert,
    error = error,
    ipairs = ipairs,
    next = next,
    pairs = pairs,
    pcall = pcall,
    select = select,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    unpack = unpack,
    _VERSION = _VERSION,
    xpcall = xpcall,
    
    -- Libraries
    coroutine = coroutine,
    string = string,
    table = table,
    math = math,
    os = tSafeOs,
    
    -- the ONE and ONLY way to talk to the OS. all hail the syscall.
    syscall = function(...)
      return kernel.syscall_dispatch(...)
    end,
    
    -- Custom require
    require = function(sModulePath)
      local mod, sErr = kernel.custom_require(sModulePath, nPid)
      if not mod then error(sErr, 2) end
      return mod
    end,
    
    -- 'print' has to be a syscall to the TTY driver. no direct access for you.
    print = function(...)
      local tParts = {}
      for i = 1, select("#", ...) do
        tParts[i] = tostring(select(i, ...))
      end
      -- Правильно: пишем в stdout (fd=1) через VFS
      kernel.syscall_dispatch("vfs_write", 1, table.concat(tParts, "\t") .. "\n")
    end,
  }
  
  -- ring 0 (kernel) gets the god-mode cheats
  if nRing == 0 then
    tSandbox.kernel = kernel
    tSandbox.raw_component = raw_component
    tSandbox.raw_computer = raw_computer
  end
  
  -- set the tEnv
  setmetatable(tSandbox, { __index = _G })
  -- CRITICAL: stop the sandbox from reaching the real _G
  -- we reset _G inside the sandbox to point to itself. inception.¹
  -- the ol' razzle dazzle. sandbox can't see the real world now.
  tSandbox._G = tSandbox
  
  return tSandbox
end
-- Yes, I know how that sounds.

-- birthing a new process. hope it's a good one.
function kernel.create_process(sPath, nRing, nParentPid, tPassEnv)
  local nPid = kernel.nNextPid
  kernel.nNextPid = kernel.nNextPid + 1
  
  kprint("Creating process " .. nPid .. " ('" .. sPath .. "') at Ring " .. nRing)
  
  local sCode, sErr = kernel.syscalls.vfs_read_file(0, sPath)
  if not sCode then
    kprint("Failed to create process: " .. sErr) -- well, that didn't work.
    return nil, sErr
  end
  
  local tEnv = kernel.create_sandbox(nPid, nRing)
  if tPassEnv then tEnv.env = tPassEnv end
  
  local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", tEnv)
  if not fFunc then
    -- oh great, a syntax error. classic.
    kprint("SYNTAX ERROR in " .. sPath .. ": " .. tostring(sLoadErr))
    return nil, sLoadErr
  end
  
  -- spin up the coroutine
  local coProcess = coroutine.create(function()
    -- this pcall is our last line of defense against rogue processes
    local bIsOk, sErr = pcall(fFunc)
    
    if not bIsOk then
      -- the process has crashed! reporting this via privileged kprint.
      kprint("!!! KERNEL ALERT: PROCESS " .. nPid .. " CRASHED !!!")
      kprint("Crash reason: " .. tostring(sErr))
    else
      -- im ok
      kprint("Process " .. nPid .. " exited normally.")
    end

    -- 'dead'
    kernel.tProcessTable[nPid].status = "dead"
  end)
  
  kernel.tProcessTable[nPid] = {
    co = coProcess,
    status = "ready", -- ready, running, sleeping, dead
    ring = nRing,
    parent = nParentPid,
    env = tEnv,
    fds = {}, -- tFds: file descriptors
    wait_queue = {}, -- tWaitQueue: other nPids waiting on this one
    run_queue = {}
  }
  kernel.tPidMap[coProcess] = nPid
  kernel.tRings[nPid] = nRing
  
  return nPid
end

-------------------------------------------------
-- SYSCALL DISPATCHER
-------------------------------------------------
kernel.syscalls = {} -- implementation functions

-- the grand central station of kernel requests.
function kernel.syscall_dispatch(sName, ...)
  local coCurrent = coroutine.running()
  local nPid = kernel.tPidMap[coCurrent]
  
  if not nPid then
    -- this is a coroutine not managed by us.
    -- this should literally never happen.
    kernel.panic("Untracked coroutine tried to syscall: " .. sName)
  end
  
  g_nCurrentPid = nPid
  local nRing = kernel.tRings[nPid]
  
  -- check for ring 1 overrides
  local nOverridePid = kernel.tSyscallOverrides[sName]
  if nOverridePid then
    -- this syscall is being handled by a ring 1 driver.
    -- so we send it an IPC message. like passing a hot potato.
    local tProcess = kernel.tProcessTable[nPid]
    tProcess.status = "sleeping"
    tProcess.wait_reason = "syscall"
    
    local bIsOk, sErr = pcall(kernel.syscalls.signal_send, 0, nOverridePid, "syscall", {
      name = sName,
      args = {...},
      sender_pid = nPid,
    })
    
    if not bIsOk then
      -- failed to send signal to the driver. oops.
      tProcess.status = "ready"
      return nil, "Syscall IPC failed: " .. sErr
    end
    
    -- yield this process. the ring 1 driver is now responsible for waking it up. not my problem anymore.
    return coroutine.yield()
  end
  
  -- no override, check the main kernel table
  local tHandler = kernel.tSyscallTable[sName]
  if not tHandler then
    return nil, "Unknown syscall: " .. sName
  end
  
  -- RING CHECK
  local bIsAllowed = false
  for _, nAllowedRing in ipairs(tHandler.allowed_rings) do
    if nRing == nAllowedRing then
      bIsAllowed = true
      break
    end
  end
  
  if not bIsAllowed then
    -- RING VIOLATION
    -- you shall not pass!
    kprint("Ring violation: PID " .. nPid .. " (Ring " .. nRing .. ") tried to call " .. sName)
    -- this is a big deal. terminate the process with prejudice.
    kernel.tProcessTable[nPid].status = "dead"
    return coroutine.yield() -- yeets the process out of existence
  end
  
  -- all checks passed. let's do this.
  -- the syscall func itself is responsible for not exploding.
  local bIsOk, valRet1, valRet2, valRet3, valRet4 = pcall(tHandler.func, nPid, ...)
  
  if not bIsOk then
    -- the syscall itself failed. great.
    return nil, valRet1 -- valRet1 is the sError message
  end
  
  return true, valRet1, valRet2, valRet3, valRet4
end

-------------------------------------------------
-- SYSCALL DEFINITIONS
-------------------------------------------------

-- Kernel (Ring 0) -- the god-tier calls
kernel.tSyscallTable["kernel_panic"] = {
  func = function(nPid, sReason) kernel.panic(sReason) end,
  allowed_rings = {0}
}

kernel.tSyscallTable["kernel_yield"] = {
    func = function() return coroutine.yield() end,
    allowed_rings = {0, 1, 2, 2.5, 3} -- 2.5? what is this, windows 98?
}

kernel.tSyscallTable["kernel_host_yield"] = {
  func = function()
    computer.pullSignal(0)
    return true
  end,
  allowed_rings = {0, 1} 
}

kernel.tSyscallTable["kernel_register_pipeline"] = {
  func = function(nPid) kernel.nPipelinePid = nPid end,
  allowed_rings = {0, 1}
}

kernel.tSyscallTable["kernel_register_driver"] = {
  func = function(nPid, sComponentType, nHandlerPid)
    if not kernel.tDriverRegistry[sComponentType] then
      kernel.tDriverRegistry[sComponentType] = {}
    end
    table.insert(kernel.tDriverRegistry[sComponentType], nHandlerPid)
  end,
  allowed_rings = {1} -- only pipeline can register drivers
}

kernel.tSyscallTable["kernel_map_component"] = {
  func = function(nPid, sAddress, nDriverPid)
    kernel.tComponentDriverMap[sAddress] = nDriverPid
  end,
  allowed_rings = {1}
}

kernel.tSyscallTable["kernel_get_root_fs"] = {
  func = function(nPid)
    -- just return the sUuid and oProxy the kernel found during boot
    if kernel.tVfs.sRootUuid and kernel.tVfs.oRootFs then
      return kernel.tVfs.sRootUuid, kernel.tVfs.oRootFs
    else
      return nil, "Root FS not mounted in kernel"
    end
  end,
  allowed_rings = {0, 1} -- allow the pipeline manager (ring 1) to ask for this info
}

kernel.tSyscallTable["kernel_log"] = {
  func = function(nPid, sMessage)
    kprint(tostring(sMessage))
    return true
  end,
  allowed_rings = {0, 1, 2} -- let the kernel, pipeline manager, AND DRIVERS write to the log
}

kernel.tSyscallTable["kernel_get_boot_log"] = {
  func = function(nPid)
    local sLog = table.concat(kernel.tBootLog, "\n")
    kernel.tBootLog = {} -- clear log after first read. can't have it hanging around.
    return sLog
  end,
  allowed_rings = {1, 2} -- for TTY driver
}
kernel.tSyscallTable["syscall_override"] = {
  func = function(nPid, sSyscallName)
    -- the calling process (nPid) now handles this syscall
    kernel.tSyscallOverrides[sSyscallName] = nPid
    return true
  end,
  allowed_rings = {1} -- only pipeline can override syscalls
}

-- Process Management -- herding cats
kernel.tSyscallTable["process_spawn"] = {
  func = function(nPid, sPath, nRing, tPassEnv)
    local nParentRing = kernel.tRings[nPid]
    -- a process can only spawn processes at its own ring or a HIGHER (less privileged) ring.
    if nRing < nParentRing then
      return nil, "Permission denied: cannot spawn higher-privilege process"
    end
    
    local nNewPid, sErr = kernel.create_process(sPath, nRing, nPid, tPassEnv)
    if not nNewPid then
      return nil, sErr
    end
    return nNewPid
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["process_yield"] = {
  func = function(nPid)
    kernel.tProcessTable[nPid].status = "ready"
    coroutine.yield()
    return true
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["process_wait"] = {
  func = function(nPid, nTargetPid)
    if not kernel.tProcessTable[nTargetPid] then
      return nil, "Invalid PID"
    end
    if kernel.tProcessTable[nTargetPid].status == "dead" then
      return true -- it's already dead, jim.
    end
    -- add self to target's wait queue
    table.insert(kernel.tProcessTable[nTargetPid].wait_queue, nPid)
    kernel.tProcessTable[nPid].status = "sleeping"
    kernel.tProcessTable[nPid].wait_reason = "wait_pid"
    return coroutine.yield()
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["process_elevate"] = {
  func = function(nPid, nNewRing)
    -- this is for 'su'. can only go from 3 to 2.5
    if kernel.tRings[nPid] == 3 and nNewRing == 2.5 then
      kernel.tRings[nPid] = 2.5
      kernel.tProcessTable[nPid].ring = 2.5
      -- re-create the sandbox with new privileges
      kernel.tProcessTable[nPid].env = kernel.create_sandbox(nPid, 2.5)
      return true
    end
    return nil, "Permission denied"
  end,
  allowed_rings = {3} -- only ring 3 can call this
}
kernel.tSyscallTable["process_get_ring"] = {
  func = function(nPid)
    return kernel.tRings[nPid]
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["process_get_pid"] = {
  func = function(nPid)
    return nPid -- just return it
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

-- Raw Component (Privileged) -- touching the hardware
kernel.tSyscallTable["raw_component_list"] = {
  func = function(nPid, sFilter)
    local tList = {}
    for sAddr, sCtype in raw_component.list(sFilter) do
      tList[sAddr] = sCtype
    end
    return tList
  end,
  allowed_rings = {0, 1, 2} -- ring 3 CANNOT see this. keep them out.
}
kernel.tSyscallTable["raw_component_invoke"] = {
  func = function(nPid, sAddress, sMethod, ...)
    local oProxy = raw_component.proxy(sAddress)
    if not oProxy then return nil, "Invalid component" end
    return pcall(oProxy[sMethod], ...)
  end,
  allowed_rings = {0, 1, 2} -- ring 3 CANNOT invoke directly.
}
kernel.tSyscallTable["raw_component_proxy"] = {
  func = function(nPid, sAddress)
    -- just create and return the oProxy.
    -- pcall just in case the sAddress is bogus.
    local bIsOk, oProxy = pcall(raw_component.proxy, sAddress)
    if bIsOk then
      return oProxy
    else
      return nil, "Invalid component address"
    end
  end,
  allowed_rings = {0, 1, 2} -- allow drivers (ring 2) to get proxies.
}

-- IPC -- passing notes in class
kernel.syscalls.signal_send = function(nPid, nTargetPid, ...)
  local tSignalArgs = {...}
  -- kprint(string.format("SIGNAL SEND: From PID %d to PID %d. Name: %s", nPid, nTargetPid, tostring(tSignalArgs[1])))

  local tTarget = kernel.tProcessTable[nTargetPid]
  if not tTarget then return nil, "Invalid PID" end
  
  local tSignal = {nPid, ...}
  
  if tTarget.status == "sleeping" and (tTarget.wait_reason == "signal" or tTarget.wait_reason == "syscall") then
    tTarget.status = "ready"
    if tTarget.wait_reason == "syscall" then
        tTarget.resume_args = {tSignal[3], table.unpack(tSignal, 4)}
    else
        tTarget.resume_args = tSignal
    end
  else
    if not tTarget.signal_queue then tTarget.signal_queue = {} end
    table.insert(tTarget.signal_queue, tSignal)
  end
  
  return true
end

kernel.tSyscallTable["signal_send"] = {
  func = kernel.syscalls.signal_send,
  allowed_rings = {0, 1, 2, 2.5, 3} -- anyone can send signals
}
kernel.tSyscallTable["signal_pull"] = {
  func = function(nPid, nTimeout)
    local tProcess = kernel.tProcessTable[nPid]
    if tProcess.signal_queue and #tProcess.signal_queue > 0 then
      return true, table.unpack(table.remove(tProcess.signal_queue, 1))
    end
    
    -- no signal waiting, sleep
    tProcess.status = "sleeping"
    tProcess.wait_reason = "signal"
    
    if nTimeout then
      -- this is complex, requires timer events.
      -- for now, we only support yield-until-signal. deal with it.
    end
    
    return coroutine.yield()
  end,
  allowed_rings = {0, 1, 2, 2.5, 3}
}

-- VFS (placeholders, will be overridden by ring 1's manager)
kernel.syscalls.vfs_read_file = function(nPid, sPath)
  -- this is the kernel-level VFS.
  -- it's only used for booting and by drivers.
  -- use the primitive loader directly. it's fine.
  return primitive_load(sPath)
end

kernel.tSyscallTable["vfs_open"]  = { func = function() end, allowed_rings = {1, 2, 2.5, 3} }
kernel.tSyscallTable["vfs_read"]  = { func = function() end, allowed_rings = {1, 2, 2.5, 3} }
kernel.tSyscallTable["vfs_write"] = { func = function() end, allowed_rings = {1, 2, 2.5, 3} }
kernel.tSyscallTable["vfs_close"] = { func = function() end, allowed_rings = {1, 2, 2.5, 3} }
kernel.tSyscallTable["vfs_list"]  = { func = function() end, allowed_rings = {1, 2, 2.5, 3} }

-- Computer -- the big red buttons
kernel.tSyscallTable["computer_shutdown"] = {
  func = function() raw_computer.shutdown() end,
  allowed_rings = {0, 1, 2, 2.5} -- user (3) cannot shutdown
}
kernel.tSyscallTable["computer_reboot"] = {
  func = function() raw_computer.shutdown(true) end,
  allowed_rings = {0, 1, 2, 2.5}
}

-------------------------------------------------
-- KERNEL INITIALIZATION
-------------------------------------------------
kprint("Initializing kernel...")

-- 1. Mount Root FS
kprint("Loading fstab...")
local tFstab = primitive_load_lua("/etc/fstab.lua")
if not tFstab then
  kernel.panic("Failed to load /etc/fstab.lua")
end

local tRootEntry = tFstab[1]
if tRootEntry.type ~= "rootfs" then
  kernel.panic("fstab[1] is not rootfs")
end
kernel.tVfs.sRootUuid = tRootEntry.uuid
kernel.tVfs.oRootFs = raw_component.proxy(tRootEntry.uuid)
kernel.tVfs.tMounts["/"] = {
  type = "rootfs",
  proxy = kernel.tVfs.oRootFs,
  options = tRootEntry.options,
}
kprint("Root filesystem mounted from " .. kernel.tVfs.sRootUuid)

-- 2. Create nPid 0 (Kernel Process)
-- this process "owns" the kernel and runs the main loop. it's us!
local nKernelPid = kernel.nNextPid
kernel.nNextPid = kernel.nNextPid + 1
local coKernel = coroutine.running()
local tKernelEnv = kernel.create_sandbox(nKernelPid, 0)
kernel.tProcessTable[nKernelPid] = {
  co = coKernel, status = "running", ring = 0,
  parent = 0, env = tKernelEnv, fds = {}
}
kernel.tPidMap[coKernel] = nKernelPid
kernel.tRings[nKernelPid] = 0
g_nCurrentPid = nKernelPid
-- set the kernel's _G to its own sandbox. more inception.
_G = tKernelEnv
kprint("Kernel process registered as PID " .. nKernelPid)

-- 3. Load Ring 1 Pipeline Manager
local nPipelinePid, sErr = kernel.create_process("/lib/pipeline_manager.lua", 1, nKernelPid)
if not nPipelinePid then
  kernel.panic("Failed to start Ring 1 Pipeline Manager: " .. sErr)
end
kernel.nPipelinePid = nPipelinePid
kprint("Ring 1 Pipeline Manager started as PID " .. nPipelinePid)

-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("Entering main event loop...")
-- and so our watch begins.

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")

while true do
  -- 1. Run all "ready" processes
  for nPid, tProcess in pairs(kernel.tProcessTable) do
    if tProcess.status == "ready" then
      g_nCurrentPid = nPid
      tProcess.status = "running"
      
      local tResumeParams = tProcess.resume_args
      tProcess.resume_args = nil
      
      local bIsOk, sErrOrSignalName
      if tResumeParams then
        --kprint(string.format("SCHEDULER: Resuming PID %d with signal args.", nPid))
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co, true, table.unpack(tResumeParams))
      else
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co)
      end
      
      g_nCurrentPid = nKernelPid 
      
      if not bIsOk then
        tProcess.status = "dead"
        kprint("!!! KERNEL ALERT: PROCESS " .. nPid .. " CRASHED !!!")
        kprint("Crash reason: " .. tostring(sErrOrSignalName))
      end
      
      if coroutine.status(tProcess.co) == "dead" then
        if tProcess.status ~= "dead" then
          kprint("Process " .. nPid .. " exited normally.")
          tProcess.status = "dead"
        end
      end
      
      if tProcess.status == "dead" then
        -- wake up any processes that were waiting for this one to die
        for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
          local tWaiter = kernel.tProcessTable[nWaiterPid]
          if tWaiter and tWaiter.status == "sleeping" and tWaiter.wait_reason == "wait_pid" then
            tWaiter.status = "ready"
            tWaiter.resume_args = {true}
          end
        end
      end
    end
  end
  
  -- 2. Pull external events
  -- we yield the *kernel* process itself to wait for events
  local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(0.1)
  
  if sEventName then
    -- this is a raw OS event.
    -- punt it over to the Pipeline Manager (ring 1) to deal with.
    pcall(kernel.syscalls.signal_send, nKernelPid, kernel.nPipelinePid, "os_event", sEventName, p1, p2, p3, p4, p5)
  end
  
  -- 3. Clean up dead processes
  -- TODO: actually do this sometime. memory leaks are a feature, right?
end