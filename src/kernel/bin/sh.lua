--
-- /bin/sh.lua
-- the shell. where the user gets to break things.
--

local oFs = require("lib/filesystem")
local oSys = require("lib/syscall")

-- standard file descriptors
local hStdin = { fd = 0 }
local hStdout = { fd = 1 }
local hStderr = { fd = 2 }

-- shell state
local sCurrentPath = env.HOME or "/"

-- making it look pretty. the '#' for root is a classic.
local function fGetPrompt()
  local bIsOk, nRing = oSys.call("process_get_ring")
  local sUser = env.USER or "user"
  local sChar = (nRing == 2.5) and "#" or "$"
  return sUser .. "@auraos:" .. sCurrentPath .. " " .. sChar .. " " -- yes, it say aura. i want so
end

-- chop chop chop.
local function fSplitCommand(sLine)
  local tArgs = {}
  for sArg in string.gmatch(sLine, "[^%s]+") do
    table.insert(tArgs, sArg)
  end
  return tArgs
end

-- Built-in commands
local tBuiltins = {}

-- let's go on an adventure.
function tBuiltins.cd(tArgs)
  local sPath = tArgs[1] or env.HOME
  -- TODO: Path resolution (.., ., ~)
  local bIsOk, tList = oFs.list(sPath)
  if bIsOk and tList then -- Check if dir exists
    sCurrentPath = sPath
  else
    oFs.write(hStderr, "cd: No such directory: " .. sPath .. "\n")
  end
  return true
end

-- see ya!
function tBuiltins.exit()
  return false -- Signal to exit loop
end

-- main shell loop
-- read, parse, execute, repeat. the circle of life.
while true do
  oFs.write(hStdout, fGetPrompt())
  local bIsOk, sLine = oFs.read(hStdin)
  
  if sLine then
    local tArgs = fSplitCommand(sLine)
    local sCmd = table.remove(tArgs, 1)
    
    if sCmd then
      local fBuiltin = tBuiltins[sCmd]
      if fBuiltin then
        if not fBuiltin(tArgs) then
          break -- exit
        end
      else
        -- Not a builtin, try to execute from the filesystem
        local sCmdPath = "/usr/commands/" .. sCmd .. ".lua"
        
        -- Check if file exists
        local hFile, sErr = oFs.open(sCmdPath, "r")
        if hFile then
          oFs.close(hFile)
          local bRingOk, nRing = oSys.call("process_get_ring")
          local bSpawnOk, nPid, sSpawnErr = oSys.call("process_spawn", sCmdPath, nRing, {
            PATH = sCurrentPath,
            USER_ENV = env,
            ARGS = tArgs,
          })
          if nPid then
            oSys.call("process_wait", nPid)
          else
            oFs.write(hStderr, "exec failed: " .. sSpawnErr .. "\n")
          end
        else
          oFs.write(hStderr, "command not found: " .. sCmd .. "\n")
        end
      end
    end
  else
    -- EOF (e.g., Ctrl+D, if TTY supported it)
    break
  end
end