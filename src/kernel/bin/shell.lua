-- /bin/shell.lua
klog("shell.lua: Starting shell.lua")
shellState = {
  running   = true,
  isSu      = false,
  currentY  = 3,
  xStart    = 3
}

klog("shell.lua: Defined shellState")

local function shellReadLine(passwordMode)
  klog("shellReadLine: Entering function")
  local line = ""
  local x = shellState.xStart
  local capturing = true

  while capturing do
    local key, ch = syscall[0x82]()
    if (key == 14) then if (#line > 0) then line = line:sub(1, -2) x = x - 1 syscall[0x80](x, shellState.currentY, " ") end
    elseif (key == 28) then capturing = false
    elseif (ch and ch > 0) then
      line = line .. string.char(ch)
      if (passwordMode) then syscall[0x80](x, shellState.currentY, "*") else syscall[0x80](x, shellState.currentY, string.char(ch)) end x = x + 1
    end
  end

  klog("shellReadLine: Exiting function, line:", line)
  return line
end

klog("shell.lua: Defined shellReadLine")

_G.shellReadLine = shellReadLine 
_G.shellState    = shellState

klog("shell.lua: Assigned shellReadLine and shellState to _G")

local function externalCommand(cmd)
  klog("externalCommand: Entering function, cmd:", cmd)
  local cmd_path = "/usr/" .. cmd .. ".lua"
  klog("externalCommand: loading file from path: ", cmd_path)
  local func, err = load_file(cmd_path)
  if not func then error("Error loading " .. cmd .. ": " .. tostring(err)) end

  klog("externalCommand: Creating coroutine")
  local co = coroutine.create(func)
  klog("externalCommand: Resuming coroutine")
  local ok, er = coroutine.resume(co)
  klog("externalCommand: Coroutine resume finished, ok:", ok, "er:", er)
  while coroutine.status(co) ~= "dead" do 
    klog("externalCommand: Waiting for coroutine to die, status:", coroutine.status(co))
  end
  if (not ok) then error("Error in " .. cmd .. ": " .. tostring(er)) end
  klog("externalCommand: Exiting function")
end

klog("shell.lua: Defined externalCommand")

local builtins = {}

klog("shell.lua: Defined builtins table")

builtins["exit"] = function()
  klog("builtins.exit: Called")
  shellState.running = false
end

klog("shell.lua: Defined builtins.exit")

builtins["su"] = function()
  klog("builtins.su: Called")
  local suPath = "/usr/su.lua"
  klog("builtins.su: suPath =", suPath)

  local suFunc, err = load_file(suPath)
  klog("builtins.su: load_file result - suFunc:", suFunc, "err:", err)

  if not suFunc then error("Error loading su: " .. tostring(err)) end

  local co = coroutine.create(suFunc)
  klog("builtins.su: Coroutine created, status:", coroutine.status(co))

  local ok, er = coroutine.resume(co)
  klog("builtins.su: Coroutine resumed, ok:", ok, "er:", er)

  while coroutine.status(co) ~= "dead" do 
    klog("builtins.su: Waiting for coroutine to die, status:", coroutine.status(co))
  end

  if not ok then error("Error in su: " .. tostring(er)) end
end

klog("shell.lua: Defined builtins.su")

builtins["passwd"] = function()
  klog("builtins.passwd: Called")
  local pwPath = "/usr/passwd.lua"
  local pwFunc, err = load_file(pwPath)
  if not pwFunc then error("Error loading passwd: " .. tostring(err)) end
  local co = coroutine.create(pwFunc)
  local ok, er = coroutine.resume(co)
  while coroutine.status(co) ~= "dead" do end
  if not ok then error("Error in passwd: " .. tostring(er)) end
end

klog("shell.lua: Defined builtins.passwd")

local function dispatchCommand(cmd)
  klog("dispatchCommand: Entering function, cmd:", cmd)
  if builtins[cmd] then 
    klog("dispatchCommand: calling function from builtins table")
    builtins[cmd]() 
  else 
    klog("dispatchCommand: calling external command")
    externalCommand(cmd) 
  end
  klog("dispatchCommand: Exiting function")
end

klog("shell.lua: Defined dispatchCommand")

local function shellMain()
      klog("shellMain: Entering shellMain")
      klog("shellMain: shellState.running =", shellState.running)

      syscall[0x80](1,2,"User Mode Shell (Ring 3)")

      klog("shellMain: Starting main loop")
     while shellState.running do
        klog("shellMain: Top of loop, shellState.running =", shellState.running)
        if shellState.currentY > 48 then
          syscall[0x83]()
          shellState.currentY = 3
        end

        syscall[0x80](1, shellState.currentY, (shellState.isSu and "# " or "$ "))
        local command = shellReadLine(false)
        klog("shellMain: Read command:", command)
        shellState.currentY = shellState.currentY + 1

        if #command ~= 0 then
          klog("shellMain: Calling dispatchCommand")
          local success, err = pcall(function()
              dispatchCommand(command)
          end)
          klog("shellMain: dispatchCommand returned, success:", success)
          if not success then
              klog("shellMain: Error in dispatchCommand:", err)
              syscall[0x80](1, shellState.currentY, "Error: " .. tostring(err))
              shellState.currentY = shellState.currentY + 1
          end
        else
            klog("shellMain: Empty command entered")
        end

        klog("shellMain: Yielding")
        coroutine.yield()
        klog("shellMain: Resumed after yield") 
      end
      
      klog("shellMain: Exiting main loop, shellState.running =", shellState.running)
      return shellMain
end

shellMain()