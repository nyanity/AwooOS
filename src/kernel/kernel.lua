local kernel = {
  tProcessTable = {}, -- [nPid] = { co, sStatus, nRing, nParentPid, tEnv, tFds, ... }
  tPidMap = {},       -- [coCoroutine] = nPid
  tRings = {},         -- [nPid] = nRingLevel
  nNextPid = 1,      -- our little counter, goes up, never down.
  
  tSyscallTable = {}, -- [sName] = { fFunc, tAllowedRings }
  tSyscallOverrides = {}, -- [sName] = nHandlingPid // for when ring 1 gets uppity
  
  tEventQueue = {},   -- internal queue for OS signals (e.g. component_added). basically our gossip channel.
  
  -- VFS and Drivers
  tVfs = {
    tMounts = {},      -- [sPath] = { sType, oProxy, tOptions }
    oRootFs = nil,    -- the main FS proxy. don't lose this.
    sRootUuid = nil,
  },
  
  -- Loaded drivers (by component type)
  tDriverRegistry = {}, -- [sComponentType] = { nDriverPid, ... } // who drives what
  -- Mapped component addresses to their driver PIDs
  tComponentDriverMap = {}, -- [sAddress] = nPid
  
  -- Ring 1 Pipeline Manager PID
  nPipelinePid = nil, -- the big boss of ring 1
  
  -- Log buffer for early boot messages
  tBootLog = {}, -- before real logging is a thing
}

local nCurrentPid = 0


-- kernel.lua

-- global var for screen line tracking. super primitive.
local nDebugY = 2 

local function direct_gpu_print(sText)
  -- try to find a GPU and screen, brute-force style
  local sGpuAddr, sScreenAddr
  for sAddr in raw_component.list("gpu") do sGpuAddr = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddr = sAddr; break end

  if sGpuAddr and sScreenAddr then
    local oGpu = raw_component.proxy(sGpuAddr)
    -- try to bind (ignore errors if it's already bound, who cares)
    pcall(oGpu.bind, sScreenAddr)
    
    -- slap the sText onto the screen
    pcall(oGpu.set, 1, nDebugY, tostring(sText))
    
    -- move the cursor down
    nDebugY = nDebugY + 1
    if nDebugY > 40 then nDebugY = 2 end -- loop it around so we don't scroll off into the void
  end
end

local function kprint(sText)
  -- save to log (the usual)
  table.insert(kernel.tBootLog, sText)
  
  -- AND IMMEDIATELY blast it to the screen using the emergency method
  direct_gpu_print(sText)
end


-------------------------------------------------
-- KERNEL PANIC asdfghjkl
-------------------------------------------------
function kernel.panic(sReason)
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

    local bOk, sBindErr = pcall(oGpu.bind, sScreenAddress)
    if bOk then

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

local oPrimitiveFs = raw_component.proxy(boot_fs_address)

local function primitive_load(sPath)
  -- (this func is fine, but let's make it more robust... or at least pretend to)
  local hFile, sReason = oPrimitiveFs.open(sPath, "r")
  if not hFile then
    return nil, "primitive_load failed to open: " .. tostring(sReason or "Unknown error")
  end
  
  local sData = ""
  local sChunk
  repeat
    sChunk = oPrimitiveFs.read(hFile, math.huge)
    if sChunk then
      sData = sData .. sChunk
    end
  until not sChunk
  
  oPrimitiveFs.close(hFile)
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

kernel.tLoadedModules = {}

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
  local bOk, result = pcall(fFunc)
  if not bOk then
    return nil, "Failed to initialize module " .. sModulePath .. ": " .. result
  end
  
  kernel.tLoadedModules[sModulePath] = result
  return result
end

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
  for k, v in pairs(os) do
    if k ~= "exit" and k ~= "execute" and k ~= "remove" and k ~= "rename" then
      tSafeOs[k] = v
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
      kernel.syscall_dispatch("tty_write", table.concat(tParts, "\t"))
    end
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
  tSandbox._G = tSandbox
  
  return tSandbox
end
-- Yes, I know how that sounds.

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
  local co = coroutine.create(function()
    -- this pcall is our last line of defense against rogue processes
    local bOk, sErr = pcall(fFunc)
    
    if not bOk then
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
    co = co,
    status = "ready", -- ready, running, sleeping, dead
    ring = nRing,
    parent = nParentPid,
    env = tEnv,
    fds = {}, -- tFds: file descriptors
    wait_queue = {}, -- tWaitQueue: other nPids waiting on this one
    run_queue = {}
  }
  kernel.tPidMap[co] = nPid
  kernel.tRings[nPid] = nRing
  
  return nPid
end

-------------------------------------------------
-- SYSCALL DISPATCHER
-------------------------------------------------
kernel.syscalls = {} -- implementation functions

function kernel.syscall_dispatch(sName, ...)
  local co = coroutine.running()
  local nPid = kernel.tPidMap[co]
  
  if not nPid then
    -- this is a coroutine not managed by us.
    -- this should literally never happen.
    kernel.panic("Untracked coroutine tried to syscall: " .. sName)
  end
  
  nCurrentPid = nPid
  local nRing = kernel.tRings[nPid]
  
  -- check for ring 1 overrides
  local nOverridePid = kernel.tSyscallOverrides[sName]
  if nOverridePid then
    -- this syscall is being handled by a ring 1 driver.
    -- so we send it an IPC message. like passing a hot potato.
    local tProcess = kernel.tProcessTable[nPid]
    tProcess.status = "sleeping"
    tProcess.wait_reason = "syscall"
    
    local bOk, sErr = pcall(kernel.syscalls.signal_send, 0, nOverridePid, "syscall", {
      name = sName,
      args = {...},
      sender_pid = nPid,
    })
    
    if not bOk then
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
  local bAllowed = false
  for _, nAllowedRing in ipairs(tHandler.allowed_rings) do
    if nRing == nAllowedRing then
      bAllowed = true
      break
    end
  end
  
  if not bAllowed then
    -- RING VIOLATION
    kprint("Ring violation: PID " .. nPid .. " (Ring " .. nRing .. ") tried to call " .. sName)
    -- this is a big deal. terminate the process with prejudice.
    kernel.tProcessTable[nPid].status = "dead"
    return coroutine.yield() -- yeets the process out of existence
  end
  
  -- all checks passed. let's do this.
  -- the syscall func itself is responsible for not exploding.
  local bOk, ret1, ret2, ret3, ret4 = pcall(tHandler.func, nPid, ...)
  
  if not bOk then
    -- the syscall itself failed. great.
    return nil, ret1 -- ret1 is the sError message
  end
  
  return true, ret1, ret2, ret3, ret4
end

-------------------------------------------------
-- SYSCALL DEFINITIONS
-------------------------------------------------

-- Kernel (Ring 0)
kernel.tSyscallTable["kernel_panic"] = {
  func = function(nPid, sReason) kernel.panic(sReason) end,
  allowed_rings = {0}
}
-- NEW SYSCALL
kernel.tSyscallTable["kernel_yield"] = {
    func = function() return coroutine.yield() end,
    allowed_rings = {0, 1, 2, 2.5, 3} -- 2.5? what is this, windows 98?
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
    -- we just use the existing kprint function. easy.
    kprint(tostring(sMessage))
    return true
  end,
  allowed_rings = {0, 1} -- let the kernel and pipeline manager write to the log
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

-- Process Management
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

-- Raw Component (Privileged)
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
    return pcall(oProxy[sMethod], oProxy, ...)
  end,
  allowed_rings = {0, 1, 2} -- ring 3 CANNOT invoke directly.
}
kernel.tSyscallTable["raw_component_proxy"] = {
  func = function(nPid, sAddress)
    -- just create and return the oProxy.
    -- pcall just in case the sAddress is bogus.
    local bOk, oProxy = pcall(raw_component.proxy, sAddress)
    if bOk then
      return oProxy
    else
      return nil, "Invalid component address"
    end
  end,
  allowed_rings = {0, 1, 2} -- allow drivers (ring 2) to get proxies.
}

-- Signal / IPC
kernel.syscalls.signal_send = function(nPid, nTargetPid, ...)
  local tTarget = kernel.tProcessTable[nTargetPid]
  if not tTarget then return nil, "Invalid PID" end
  
  -- right here, we add the sender's nPid as the first argument to the signal
  local tSignal = {nPid, ...}
  
  if tTarget.status == "sleeping" and tTarget.wait_reason == "signal" then
    -- process is waiting for a signal, resume it directly
    tTarget.status = "running"
    local bOk, ret1, ret2 = pcall(coroutine.resume, tTarget.co, true, table.unpack(tSignal))
    if not bOk then
      tTarget.status = "dead" -- crashed on resume
      kernel.panic("Signal resume crash: " .. ret1)
    end
    return true
  elseif tTarget.status == "sleeping" and tTarget.wait_reason == "syscall" then
    -- process is waiting for a syscall return
    -- the signal MUST be a syscall_return
    if tSignal[1] == "syscall_return" then
      tTarget.status = "running"
      local bOk, ret1, ret2 = pcall(coroutine.resume, tTarget.co, true, table.unpack(tSignal, 2))
      if not bOk then
        tTarget.status = "dead"
        kernel.panic("Syscall resume crash: " .. ret1)
      end
      return true
    else
      -- trying to send a normal signal to a process in a syscall.
      -- this is complex. for now, queue it?
      -- nah, let's just reject it.
      return nil, "Process is in syscall wait"
    end
  else
    -- process is running or ready, queue the signal
    if not tTarget.signal_queue then tTarget.signal_queue = {} end
    table.insert(tTarget.signal_queue, tSignal)
    return true
  end
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

-- Computer
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
local nKPid = kernel.nNextPid
kernel.nNextPid = kernel.nNextPid + 1
local kCo = coroutine.running()
local kEnv = kernel.create_sandbox(nKPid, 0)
kernel.tProcessTable[nKPid] = {
  co = kCo, status = "running", ring = 0,
  parent = 0, env = kEnv, fds = {}
}
kernel.tPidMap[kCo] = nKPid
kernel.tRings[nKPid] = 0
nCurrentPid = nKPid
-- set the kernel's _G to its own sandbox. more inception.
_G = kEnv
kprint("Kernel process registered as PID " .. nKPid)

-- 3. Load Ring 1 Pipeline Manager
local nPipelinePid, sErr = kernel.create_process("/lib/pipeline_manager.lua", 1, nKPid)
if not nPipelinePid then
  kernel.panic("Failed to start Ring 1 Pipeline Manager: " .. sErr)
end
kernel.nPipelinePid = nPipelinePid
kprint("Ring 1 Pipeline Manager started as PID " .. nPipelinePid)

-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("Entering main event loop...")

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")

while true do
  -- 1. Run all "ready" processes
  for nPid, tProcess in pairs(kernel.tProcessTable) do
    if tProcess.status == "ready" then
      nCurrentPid = nPid
      tProcess.status = "running"
      
      -- resume the coroutine. what could go wrong?
      local bOk, err_or_sig_name, sig_arg1, sig_arg2 = coroutine.resume(tProcess.co)
      
      nCurrentPid = nKPid 
      
      if not bOk then
        -- process crashed
        tProcess.status = "dead"
        -- tell the world about the crash
        kprint("CRASH PID " .. nPid .. ": " .. tostring(err_or_sig_name))
      end
      
      if coroutine.status(tProcess.co) == "dead" then
        tProcess.status = "dead"
      end
      
      if tProcess.status == "dead" then
        -- notify waiting processes that their wait is over
        for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
          local tWaiter = kernel.tProcessTable[nWaiterPid]
          if tWaiter and tWaiter.status == "sleeping" and tWaiter.wait_reason == "wait_pid" then
            tWaiter.status = "ready"
            -- TODO: send resume signal or something, idk
          end
        end
        -- TODO: clean up resources (fds, etc). later.
        -- for now, just mark as dead.
      end
    end
  end
  
  -- 2. Pull external events
  -- we yield the *kernel* process itself to wait for events
  local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(0.1)
  
  if sEventName then
    -- this is a raw OS event.
    -- punt it over to the Pipeline Manager (ring 1) to deal with.
    pcall(kernel.syscalls.signal_send, nKPid, kernel.nPipelinePid, "os_event", sEventName, p1, p2, p3, p4, p5)
  end
  
  -- 3. Clean up dead processes
  -- TODO: actually do this sometime
end