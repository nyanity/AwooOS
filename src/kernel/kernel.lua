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

local g_nCurrentPid = 0 -- tracks the currently executing process. super important for context.
local g_nDebugY = 2 -- global var for screen line tracking. super primitive.
local g_bLogToScreen = true

local g_oGpu = nil
local g_nWidth, g_nHeight = 80, 25 -- Default values
local g_nCurrentLine = 0
local tBootArgs = boot_args or {} 

-- Color constants for the logger
local C_WHITE  = 0xFFFFFF
local C_GRAY   = 0xAAAAAA
local C_GREEN  = 0x55FF55
local C_RED    = 0xFF5555
local C_YELLOW = 0xFFFF55
local C_CYAN   = 0x55FFFF
local C_BLUE   = 0x5555FF

-- Log level definitions
local tLogLevels = {
  ok    = { text = "[  OK  ]", color = C_GREEN },
  fail  = { text = "[ FAIL ]", color = C_RED },
  info  = { text = "[ INFO ]", color = C_CYAN },
  warn  = { text = "[ WARN ]", color = C_YELLOW },
  dev   = { text = "[ DEV  ]", color = C_BLUE },
  none  = { text = "         ", color = C_WHITE }, -- For multi-line messages
}

local tLogLevelsPriority = {
  debug = 0,
  info = 1,
  warn = 2,
  fail = 3,
  none = 4
}

local sCurrentLogLevel = string.lower(tBootArgs.loglevel or "info")
local nMinPriority = tLogLevelsPriority[sCurrentLogLevel] or 1

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

local function __logger_init()
  local sGpuAddr, sScreenAddr
  for sAddr in raw_component.list("gpu") do sGpuAddr = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddr = sAddr; break end

  if sGpuAddr and sScreenAddr then
    g_oGpu = raw_component.proxy(sGpuAddr)
    pcall(g_oGpu.bind, sScreenAddr)
    g_nWidth, g_nHeight = g_oGpu.getResolution()
    g_oGpu.fill(1, 1, g_nWidth, g_nHeight, " ")
    g_nCurrentLine = 0
  end
end


function kprint(sLevel, ...)
  local nMsgPriority = tLogLevelsPriority[sLevel] or 1
  if nMsgPriority < nMinPriority then return end 
  -- 1. Prepare the message
  local tMsgParts = {...}
  local sMessage = ""
  for i, v in ipairs(tMsgParts) do
    sMessage = sMessage .. tostring(v) .. (i < #tMsgParts and " " or "")
  end
  
  -- 2. Add to the internal boot log table
  local sFullLogMessage = string.format("[%s] %s", sLevel, sMessage)
  table.insert(kernel.tBootLog, sFullLogMessage)

  -- 3. If we don't have a GPU, we're done here.
  if not g_bLogToScreen then return end
  if not g_oGpu then return end

  -- 4. Handle scrolling
  if g_nCurrentLine >= g_nHeight then
    -- Copy everything from line 2 to the end, one line up.
    g_oGpu.copy(1, 2, g_nWidth, g_nHeight - 1, 0, -1)
    -- Clear the last line, which is now a duplicate of the second-to-last.
    g_oGpu.fill(1, g_nHeight, g_nWidth, 1, " ")
  else
    g_nCurrentLine = g_nCurrentLine + 1
  end
  
  -- 5. Print the formatted line to the screen
  local tLevelInfo = tLogLevels[sLevel] or tLogLevels.none
  local nPrintY = g_nCurrentLine
  local nPrintX = 1
  
  -- Timestamp
  g_oGpu.setForeground(C_GRAY)
  local sTimestamp = string.format("[%8.4f]", raw_computer.uptime())
  g_oGpu.set(nPrintX, nPrintY, sTimestamp)
  nPrintX = nPrintX + #sTimestamp + 1
  
  -- Log Level Tag
  g_oGpu.setForeground(tLevelInfo.color)
  g_oGpu.set(nPrintX, nPrintY, tLevelInfo.text)
  nPrintX = nPrintX + #tLevelInfo.text + 1

  -- Message
  g_oGpu.setForeground(C_WHITE)
  g_oGpu.set(nPrintX, nPrintY, sMessage)
end

-------------------------------------------------
-- KERNEL PANIC asdfghjkl
-------------------------------------------------

-- the 'everything is on fire' function.
function kernel.panic(sReason, coFaulting)
  -- the song of our people
  raw_computer.beep(1100, 1.3); raw_computer.pullSignal(0.1)

  local sGpuAddress, sScreenAddress
  for sAddr in raw_component.list("gpu") do sGpuAddress = sAddr; break end
  for sAddr in raw_component.list("screen") do sScreenAddress = sAddr; break end

  if not sGpuAddress or not sScreenAddress then
    -- if we can't even find a screen, we're truly lost. Loop forever.
    while true do raw_computer.pullSignal(1) end
  end

  local oGpu = raw_component.proxy(sGpuAddress)
  pcall(oGpu.bind, sScreenAddress)
  
  -- screen setup
  local nW, nH = oGpu.getResolution()
  pcall(oGpu.setBackground, 0x0000AA) -- Classic Blue
  pcall(oGpu.setForeground, 0xFFFFFF)
  pcall(oGpu.fill, 1, 1, nW, nH, " ")

  -- helper function for printing lines to avoid pcall spam
  local y = 1
  local function print_line(sText, sColor)
    if y > nH then return end
    pcall(oGpu.setForeground, sColor or 0xFFFFFF)
    pcall(oGpu.set, 2, y, tostring(sText or ""))
    y = y + 1
  end

  -- =================================================================
  -- HEADER
  -- =================================================================
  print_line(" ")
  print_line(":( A fatal error has occurred and AxisOS has been shut down.", 0xFFFFFF)
  print_line("   to prevent damage to your system.", 0xFFFFFF)
  y = y + 1
  print_line("[ KERNEL PANIC ]", 0xFF5555)
  y = y + 1
  print_line("Reason: " .. tostring(sReason or "No reason specified."), 0xFFFF55)
  y = y + 1

  -- =================================================================
  -- FAULTING CONTEXT
  -- =================================================================
  print_line("---[ Faulting Context ]---", 0x55FFFF)
  local nFaultingPid = coFaulting and kernel.tPidMap[coFaulting]
  if nFaultingPid then
    local p = kernel.tProcessTable[nFaultingPid]
    print_line(string.format("PID: %d   Parent: %d   Ring: %d   Status: %s",
               nFaultingPid, p.parent or -1, p.ring or -1, p.status or "UNKNOWN"), 0xFFFFFF)
    
    -- try to find the process path from the sandbox env
    local sPath = "N/A"
    if p.env and p.env.arg and type(p.env.arg) == "table" then
      sPath = p.env.arg[0] or "N/A"
    end
    print_line("Image Path: " .. sPath, 0xAAAAAA)
    y = y + 1
    
    print_line("Stack Trace:", 0x55FFFF)
    local sTraceback = debug.traceback(coFaulting)
    for line in sTraceback:gmatch("[^\r\n]+") do
      line = line:gsub("kernel.lua", "kernel")
      line = line:gsub("pipeline_manager.lua", "pm")
      line = line:gsub("dkms.lua", "dkms")
      print_line("  " .. line, 0xAAAAAA)
      if y > 22 then print_line("  ... (trace truncated)", 0xAAAAAA); break end
    end
  else
    print_line("Panic occurred outside of a managed process (e.g., during boot).", 0xFFFF55)
  end
  y = y + 1

  -- =================================================================
  -- SYSTEM STATE
  -- =================================================================
  print_line("---[ System State ]---", 0x55FFFF)
  print_line(string.format("Uptime: %.4f seconds", raw_computer.uptime()), 0xFFFFFF)
  print_line(string.format("Total Processes: %d", kernel.nNextPid - 1), 0xFFFFFF)
  y = y + 1

  print_line("Process Table (Top 10):", 0x55FFFF)
  print_line(string.format("%-5s %-7s %-12s %-6s %-s", "PID", "PARENT", "STATUS", "RING", "IMAGE"), 0xAAAAAA)
  local nCount = 0
  for pid, p in pairs(kernel.tProcessTable) do
    if nCount >= 10 then break end
    local sPath = "N/A"
    if p.env and p.env.arg and type(p.env.arg) == "table" then sPath = p.env.arg[0] or "N/A" end
    print_line(string.format("%-5d %-7d %-12s %-6d %-s",
               pid, p.parent or -1, p.status or "??", p.ring or "?", sPath), 0xFFFFFF)
    nCount = nCount + 1
  end
  y = y + 1

  -- =================================================================
  -- HARDWARE DUMP
  -- =================================================================
  print_line("---[ Component Dump ]---", 0x55FFFF)
  local tComponents = {}
  for addr, ctype in raw_component.list() do table.insert(tComponents, {addr=addr, ctype=ctype}) end
  
  for i, comp in ipairs(tComponents) do
    if y > nH - 2 then print_line("... (list truncated)", 0xAAAAAA); break end
    local sShortAddr = comp.addr:sub(1, 13)
    print_line(string.format("[%s...] %s", sShortAddr, comp.ctype), 0xFFFFFF)
  end

  -- =================================================================
  -- FOOTER
  -- =================================================================
  pcall(oGpu.setForeground, 0xFFFF55)
  pcall(oGpu.set, 2, nH, "System halted. Please power cycle the machine.")

  -- the long sleep
  while true do
    raw_computer.pullSignal(1)
  end
end

------------------------------------------------
-- BOOT MSG
------------------------------------------------

__logger_init()
kprint("info", "AxisOS Xen XKA v0.3 starting...")
kprint("info", "Copyright (C) 2025 AxisOS")
kprint("none", "")

------------------------------------------------
-- BOOT MSG
------------------------------------------------

-- ================================================================

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
  
  kprint("info", "Creating process " .. nPid .. " ('" .. sPath .. "') at Ring " .. nRing)
  
  local sCode, sErr = kernel.syscalls.vfs_read_file(0, sPath)
  if not sCode then
    kprint("fail", "Failed to create process: " .. sErr) -- well, that didn't work.
    return nil, sErr
  end
  
  local tEnv = kernel.create_sandbox(nPid, nRing)
  if tPassEnv then tEnv.env = tPassEnv end
  
  local fFunc, sLoadErr = load(sCode, "@" .. sPath, "t", tEnv)
  if not fFunc then
    -- oh great, a syntax error. classic.
    kprint("fail", "SYNTAX ERROR in " .. sPath .. ": " .. tostring(sLoadErr))
    return nil, sLoadErr
  end
  
  -- spin up the coroutine
  local coProcess = coroutine.create(function()
    -- this pcall is our last line of defense against rogue processes
    local bIsOk, sErr = pcall(fFunc)
    
    if not bIsOk then
      -- the process has crashed! reporting this via privileged kprint.
      kprint("fail", "!!! KERNEL ALERT: PROCESS " .. nPid .. " CRASHED !!!")
      kprint("fail", "Crash reason: " .. tostring(sErr))
    else
      -- im ok
      kprint("info", "Process " .. nPid .. " exited normally.")
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
    run_queue = {},
    uid = (tPassEnv and tPassEnv.UID) or 1000
  }
  kernel.tPidMap[coProcess] = nPid
  kernel.tRings[nPid] = nRing
  
  return nPid
end

function kernel.create_thread(fFunc, nParentPid)
  local nPid = kernel.nNextPid
  kernel.nNextPid = kernel.nNextPid + 1
  
  local tParentProcess = kernel.tProcessTable[nParentPid]
  if not tParentProcess then return nil, "Parent died" end
  
  kprint("dev", "Spawning thread " .. nPid .. " for parent " .. nParentPid)
  
  -- CRITICAL: We share the ENV. No new sandbox.
  -- Changes in global variables in the thread affect the parent.
  local tSharedEnv = tParentProcess.env
  
  local coThread = coroutine.create(function()
    local bOk, sErr = pcall(fFunc)
    if not bOk then
      kprint("fail", "Thread " .. nPid .. " crashed: " .. tostring(sErr))
    end
    kernel.tProcessTable[nPid].status = "dead"
  end)
  
  kernel.tProcessTable[nPid] = {
    co = coThread,
    status = "ready",
    ring = tParentProcess.ring, -- inherit ring
    parent = nParentPid,
    env = tSharedEnv, -- shared memory!
    fds = tParentProcess.fds, -- shared file descriptors! (advanced feature)
    wait_queue = {},
    run_queue = {},
    uid = tParentProcess.uid
  }
  
  kernel.tPidMap[coThread] = nPid
  kernel.tRings[nPid] = tParentProcess.ring
  
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
    kprint("fail", "Ring violation: PID " .. nPid .. " (Ring " .. nRing .. ") tried to call " .. sName)
    -- this is a big deal. terminate the process with prejudice.
    kernel.tProcessTable[nPid].status = "dead"
    return coroutine.yield() -- yeets the process out of existence
  end

  local tReturns = {pcall(tHandler.func, nPid, ...)}
  
  -- the first value is the success status of the pcall itself.
  local bIsOk = table.remove(tReturns, 1)
  
  if not bIsOk then
    -- the syscall function itself crashed. tReturns[1] is the error message.
    return nil, tReturns[1]
  end
  
  -- the syscall executed without crashing. tReturns now contains the actual
  -- return values from the handler function. we unpack them and return them directly.
  -- this makes the dispatcher transparent to the caller.
  return table.unpack(tReturns)

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
    kprint("info", tostring(sMessage))
    return true
  end,
  allowed_rings = {0, 1, 2, 3} -- let the kernel, pipeline manager, AND DRIVERS write to the log
}

kernel.tSyscallTable["kernel_get_boot_log"] = {
  func = function(nPid)
    local sLog = table.concat(kernel.tBootLog, "\n")
    kernel.tBootLog = {} -- clear log after first read. can't have it hanging around.
    return sLog
  end,
  allowed_rings = {1, 2} -- for TTY driver
}

kernel.tSyscallTable["kernel_set_log_mode"] = {
  func = function(nPid, bEnable)
    g_bLogToScreen = bEnable
    return true
  end,
  allowed_rings = {0, 1}
}


kernel.tSyscallTable["driver_load"] = {
  func = function(nPid, sPath)
    -- placeholder. pipeline manager should override this.
    return nil, "Syscall not handled by PM"
  end,
  allowed_rings = {0, 1, 2, 2.5, 3} -- open the gates for ring 3
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

kernel.tSyscallTable["process_thread"] = {
  func = function(nPid, fFunc)
    if type(fFunc) ~= "function" then return nil, "Argument must be a function" end
    local nThreadPid, sErr = kernel.create_thread(fFunc, nPid)
    return nThreadPid, sErr
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

kernel.tSyscallTable["process_kill"] = {
  func = function(nPid, nTargetPid)
    local tTarget = kernel.tProcessTable[nTargetPid]
    if not tTarget then return nil, "No such process" end
    
    -- Security check: can only kill own children or if root (Ring 0/1)
    -- for simplicity in dev mode: allow all for now, or check rings.
    local nCallerRing = kernel.tRings[nPid]
    if nCallerRing > 1 and tTarget.parent ~= nPid then
       return nil, "Permission denied"
    end
    
    tTarget.status = "dead"
    kprint("info", "Process " .. nTargetPid .. " killed by " .. nPid)
    return true
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

kernel.tSyscallTable["process_get_uid"] = {
  func = function(nPid, nTargetPid)
    local tP = kernel.tProcessTable[nTargetPid or nPid]
    if tP then return tP.uid else return nil end
  end,
  allowed_rings = {0, 1} -- only PM needs to know this usually
}

-- Raw Component (Privileged) -- touching the hardware
kernel.tSyscallTable["raw_component_list"] = {
  func = function(nPid, sFilter)
    -- Use a pcall for maximum safety, in case raw_component.list ever fails.
    local bIsOk, tList = pcall(function()
        local tTempList = {}
        for sAddr, sCtype in raw_component.list(sFilter) do
          tTempList[sAddr] = sCtype
        end
        return tTempList
    end)

    if bIsOk then
        -- The operation succeeded. Return our standard API format: success, result.
        return true, tList
    else
        -- The operation failed. Return failure and the error message.
        return false, tList -- tList here is the error string from pcall
    end
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

kernel.tSyscallTable["vfs_read_file"] = {
    func = kernel.syscalls.vfs_read_file,
    allowed_rings = {0, 1, 2} -- Only privileged processes can use this raw read
}

kernel.tSyscallTable["vfs_open"]  = {
    func = function(nPid, sPath, sMode) return pcall(g_oPrimitiveFs.open, sPath, sMode) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_read"]  = {
    func = function(nPid, hHandle, nCount) return pcall(g_oPrimitiveFs.read, hHandle, nCount or math.huge) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_write"] = {
    func = function(nPid, hHandle, sData) return pcall(g_oPrimitiveFs.write, hHandle, sData) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}
kernel.tSyscallTable["vfs_close"] = {
    func = function(nPid, hHandle) return pcall(g_oPrimitiveFs.close, hHandle) end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

kernel.tSyscallTable["vfs_chmod"] = {
  func = function() return nil, "Not implemented in kernel" end,
  allowed_rings = {0, 1, 2, 2.5, 3} -- PM will override this
}

kernel.tSyscallTable["vfs_list"]  = {
    func = function(nPid, sPath)
        local bOk, tListOrErr = pcall(g_oPrimitiveFs.list, sPath)
        if bOk then
            return true, tListOrErr
        else
            -- pcall returns false and the error message
            return false, tListOrErr
        end
    end,
    allowed_rings = {0, 1, 2, 2.5, 3}
}

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
kprint("info", "Kernel entering initialization sequence (Ring 0).")
kprint("dev", "Initializing syscall dispatcher table...")

-- 1. Mount Root FS
kprint("info", "Reading fstab from /etc/fstab.lua...")
local tFstab = primitive_load_lua("/etc/fstab.lua")
if not tFstab then
    kprint("fail", "Failed to load /etc/fstab.lua")
  kernel.panic("fstab is missing or corrupt.")
end

local tRootEntry = tFstab[1]
if tRootEntry.type ~= "rootfs" then
  kprint("fail", "fstab[1] is not of type 'rootfs'.")
  kernel.panic("Invalid fstab configuration.")
end
kernel.tVfs.sRootUuid = tRootEntry.uuid
kernel.tVfs.oRootFs = raw_component.proxy(tRootEntry.uuid)
kernel.tVfs.tMounts["/"] = {
  type = "rootfs",
  proxy = kernel.tVfs.oRootFs,
  options = tRootEntry.options,
}
kprint("ok", "Mounted root filesystem on", kernel.tVfs.sRootUuid:sub(1,13).."...")

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
kprint("ok", "Kernel process registered as PID", nKernelPid)

-- 3. Load Ring 1 Pipeline Manager
kprint("info", "Starting Ring 1 services...")
local tPmEnv = {
   SAFE_MODE = (tBootArgs.safemode == "Enabled"),
   INIT_PATH = tBootArgs.init or "/bin/init.lua"
}

local nPipelinePid, sErr = kernel.create_process("/lib/pipeline_manager.lua", 1, nKernelPid, tPmEnv)

if not nPipelinePid then
  kprint("fail", "Failed to start Ring 1 Pipeline Manager:", sErr)
  kernel.panic("Critical service failure: pipeline_manager")
end
kernel.nPipelinePid = nPipelinePid
kprint("ok", "Ring 1 Pipeline Manager started as PID", nPipelinePid)

-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("info", "Handing off control to scheduler...")
kprint("ok", "Entering main event loop. Kernel is now running.")
kprint("none", "")
-- and so our watch begins.

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")


-------------------------------------------------
-- MAIN KERNEL EVENT LOOP
-------------------------------------------------
kprint("info", "Handing off control to scheduler...")
kprint("ok", "Entering main event loop. Kernel is now running.")
kprint("none", "")

table.insert(kernel.tProcessTable[nPipelinePid].run_queue, "start")

while true do
  local nWorkDone = 0 -- tracking if we actually did anything useful
  
  -- 1. Run all "ready" processes
  for nPid, tProcess in pairs(kernel.tProcessTable) do
    if tProcess.status == "ready" then
      nWorkDone = nWorkDone + 1 -- we are busy, no sleeping allowed
      g_nCurrentPid = nPid
      tProcess.status = "running"
      
      local tResumeParams = tProcess.resume_args
      tProcess.resume_args = nil
      
      local bIsOk, sErrOrSignalName
      if tResumeParams then
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co, true, table.unpack(tResumeParams))
      else
        bIsOk, sErrOrSignalName = coroutine.resume(tProcess.co)
      end
      
      g_nCurrentPid = nKernelPid 
      
      if not bIsOk then
        tProcess.status = "dead"
        kernel.panic(tostring(sErrOrSignalName), tProcess.co)
      end
      
      if coroutine.status(tProcess.co) == "dead" then
        if tProcess.status ~= "dead" then
          kprint("info", "Process " .. nPid .. " exited normally.")
          tProcess.status = "dead"
        end
      end
      
      -- wake up the stalkers waiting for this pid
      if tProcess.status == "dead" then
        for _, nWaiterPid in ipairs(tProcess.wait_queue or {}) do
          local tWaiter = kernel.tProcessTable[nWaiterPid]
          if tWaiter and tWaiter.status == "sleeping" and tWaiter.wait_reason == "wait_pid" then
            tWaiter.status = "ready"
            tWaiter.resume_args = {true}
            nWorkDone = nWorkDone + 1
          end
        end
      end
    end
  end
  
  -- 2. Pull external events
  -- change: optimization logic here.
  -- if we did work (nWorkDone > 0), yield instantly (0).
  -- if we are idle, sleep a tiny bit (0.05) to save ticks/energy/sanity.
  local nTimeout = (nWorkDone > 0) and 0 or 0.05
  local sEventName, p1, p2, p3, p4, p5 = computer.pullSignal(nTimeout)
  
  if sEventName then
    pcall(kernel.syscalls.signal_send, nKernelPid, kernel.nPipelinePid, "os_event", sEventName, p1, p2, p3, p4, p5)
  end
  
  -- 3. Clean up dead processes
  -- maybe later. garbage collection is hard.
end