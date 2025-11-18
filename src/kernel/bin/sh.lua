--
-- /bin/sh.lua
-- The Shell
--

local oFs = require("filesystem")
local oSys = require("syscall") 

local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")
local hStderr = hStdout 

if not hStdin or not hStdout then
    syscall("kernel_panic", "Shell failed to open /dev/tty")
end

-- shell state
local sCurrentPath = (env and env.HOME) or "/"

local function fTrim(s)
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function fGetPrompt()
  local nRing = syscall("process_get_ring")
  local sUser = (env and env.USER) or "user"
  local sChar = (nRing == 2.5) and "#" or "$"
  return sUser .. "@auraos:" .. sCurrentPath .. " " .. sChar .. " "
end

local function fSplitCommand(sLine)
  local tArgs = {}
  for sArg in string.gmatch(sLine, "[^%s]+") do
    table.insert(tArgs, sArg)
  end
  return tArgs
end

-- Built-in commands
local tBuiltins = {}

function tBuiltins.cd(tArgs)
  local sPath = tArgs[1] or (env and env.HOME) or "/"
  local tList = oFs.list(sPath)
  if tList then 
    sCurrentPath = sPath
  else
    oFs.write(hStderr, "cd: No such directory: " .. sPath .. "\n")
  end
  return true
end

function tBuiltins.exit()
  return false 
end

function tBuiltins.help()
    oFs.write(hStdout, "AuraOS Shell v0.1\nBuiltins: cd, exit, help\n")
    return true
end

-- main shell loop
while true do
  oFs.write(hStdout, fGetPrompt())
  
  local sLine = oFs.read(hStdin)
  
  if sLine then
    sLine = fTrim(sLine)
    
    if #sLine > 0 then
        local tArgs = fSplitCommand(sLine)
        local sCmd = table.remove(tArgs, 1)
        
        if sCmd then
          local fBuiltin = tBuiltins[sCmd]
          if fBuiltin then
            if not fBuiltin(tArgs) then
              break -- exit command called
            end
          else
            -- Try external command
            local sCmdPath = "/usr/commands/" .. sCmd .. ".lua"
            local hFile = oFs.open(sCmdPath, "r")
            if hFile then
              oFs.close(hFile)
              local nRing = syscall("process_get_ring")
              
              local nPid, sSpawnErr = syscall("process_spawn", sCmdPath, nRing, {
                PATH = sCurrentPath,
                USER_ENV = env,
                ARGS = tArgs,
              })
              
              if nPid then
                syscall("process_wait", nPid)
              else
                oFs.write(hStderr, "exec failed: " .. tostring(sSpawnErr) .. "\n")
              end
            else
              oFs.write(hStderr, "command not found: " .. sCmd .. "\n")
            end
          end
        end
    end
  else
    break
  end
end

oFs.close(hStdin)
oFs.close(hStdout)