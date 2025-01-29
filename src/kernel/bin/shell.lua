-- /bin/shell.lua

shellState = {
  running   = true,
  isSu      = false,
  currentY  = 3,
  xStart    = 3
}

local function shellReadLine(passwordMode)
  local line = ""
  local x = shellState.xStart
  local capturing = true

  while capturing do
    local key, ch = syscall[0x82]()
    if (key == 14) then -- backspace
      if (#line > 0) then
        line = line:sub(1, -2)
        x = x - 1
        syscall[0x80](x, shellState.currentY, " ")
      end
    elseif (key == 28) then -- enter
      capturing = false
    elseif (ch and ch > 0) then
      line = line .. string.char(ch)
      if (passwordMode) then
        syscall[0x80](x, shellState.currentY, "*")
      else
        syscall[0x80](x, shellState.currentY, string.char(ch))
      end
      x = x + 1
    end
  end

  return line
end

_G.shellReadLine = shellReadLine 
_G.shellState    = shellState

local function externalCommand(cmd)
  local cmd_path = "/usr/" .. cmd .. ".lua"
  local func, err = load_file(cmd_path)
  if not func then error("Error loading " .. cmd .. ": " .. tostring(err)) end

  local co = coroutine.create(func)
  local ok, er = coroutine.resume(co)
  while coroutine.status(co) ~= "dead" do end
  if (not ok) then error("Error in " .. cmd .. ": " .. tostring(er)) end
end

local builtins = {}

builtins["exit"] = function()
  shellState.running = false
end

builtins["su"] = function()
  local suPath = "/usr/su.lua"
  local suFunc, err = load_file(suPath)
  if not suFunc then error("Error loading su: " .. tostring(err))
  local co = coroutine.create(suFunc)
  local ok, er = coroutine.resume(co)
  while coroutine.status(co) ~= "dead" do end
  if (not ok) then error("Error in su: " .. tostring(er)) end
end

builtins["passwd"] = function()
  local pwPath = "/usr/passwd.lua"
  local pwFunc, err = load_file(pwPath)
  if not pwFunc then error("Error loading passwd: " .. tostring(err)) end
  local co = coroutine.create(pwFunc)
  local ok, er = coroutine.resume(co)
  while coroutine.status(co) ~= "dead" do end
  if (not ok) then error("Error in passwd: " .. tostring(er)) end
end

local function dispatchCommand(cmd)
  if (builtins[cmd]) then builtins[cmd]() else externalCommand(cmd) end
end

local function shellMain()
  syscall[0x80](1,2,"User Mode Shell (Ring 3)")

  while shellState.running do
    if (shellState.currentY > 48) then
      syscall[0x83]()
      shellState.currentY = 3
    end

    syscall[0x80](1, shellState.currentY, (shellState.isSu and "# " or "$ "))
    local command = shellReadLine(false)
    shellState.currentY = shellState.currentY + 1

    if (#command ~= 0) then
      local success, err = pcall(function()
        dispatchCommand(command)
      end)
      if (not success) then
        syscall[0x80](1, shellState.currentY, "Error: " .. tostring(err))
        shellState.currentY = shellState.currentY + 1
      end
    end
  end
end
end
return shellMain