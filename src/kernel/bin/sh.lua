--
-- /bin/sh.lua
-- Advanced Shell
--

local oFs = require("filesystem")
local oSys = require("syscall")

local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")
local hStderr = hStdout

if not hStdin then syscall("kernel_panic", "SH: No TTY") end

local ENV = env or {}
ENV.PWD = ENV.PWD or "/"
ENV.PATH = ENV.PATH or "/usr/commands"
ENV.USER = ENV.USER or "user"

local function parseLine(line)
  local args = {}
  local current = ""
  local inQuote = false
  
  for i = 1, #line do
    local c = line:sub(i,i)
    if c == '"' then
      inQuote = not inQuote
    elseif c == ' ' and not inQuote then
      if #current > 0 then table.insert(args, current); current = "" end
    elseif c == "\n" then
      -- ignore newline at end
    else
      current = current .. c
    end
  end
  if #current > 0 then table.insert(args, current) end
  return args
end

local function getPrompt()
  local r = syscall("process_get_ring")
  local char = (r == 2.5) and "#" or "$"
  local path = ENV.PWD
  if ENV.HOME and path:sub(1, #ENV.HOME) == ENV.HOME then
     path = "~" .. path:sub(#ENV.HOME + 1)
  end
  return string.format("\n\27[32m%s@%s\27[37m:\27[34m%s\27[37m%s ", ENV.USER, ENV.HOSTNAME or "box", path, char)
end


local function findExecutable(cmd)
  if cmd:sub(1,1) == "/" or cmd:sub(1,2) == "./" then
     local path = cmd
     if path:sub(1,2) == "./" then path = ENV.PWD .. path:sub(2) end
     if oFs.open(path, "r") then oFs.close({fd=0}); return path end -- hacky check exists
     return nil
  end

  for path in string.gmatch(ENV.PATH, "[^:]+") do
     local full = path .. "/" .. cmd .. ".lua"
     local h = oFs.open(full, "r")
     if h then
        oFs.close(h)
        return full
     end
  end
  return nil
end

local builtins = {}

function builtins.cd(args)
   local newDir = args[1] or ENV.HOME
   if newDir == ".." then
      ENV.PWD = ENV.PWD:match("(.*/)[^/]+/?$") or "/"
      if ENV.PWD:sub(#ENV.PWD) == "/" and #ENV.PWD > 1 then 
         ENV.PWD = ENV.PWD:sub(1, -2) 
      end
      return true
   end
   
   if newDir:sub(1,1) ~= "/" then newDir = ENV.PWD .. (ENV.PWD == "/" and "" or "/") .. newDir end
   
   local list = oFs.list(newDir)
   if list then
      ENV.PWD = newDir
   else
      oFs.write(hStderr, "cd: " .. newDir .. ": No such directory\n")
   end
   return true
end

function builtins.exit() return false end
function builtins.pwd() oFs.write(hStdout, ENV.PWD .. "\n"); return true end
function builtins.export(args)
   if args[1] then
      local k, v = args[1]:match("([^=]+)=(.*)")
      if k then ENV[k] = v end
   end
   return true
end

-- Main Loop
while true do
  oFs.write(hStdout, getPrompt())
  local line = oFs.read(hStdin)
  
  if not line then break end -- EOF
  
  local args = parseLine(line)
  if #args > 0 then
    local cmd = args[1]
    table.remove(args, 1)
    
    if builtins[cmd] then
       if not builtins[cmd](args) then break end
    else
       local execPath = findExecutable(cmd)
       if execPath then
          local ring = syscall("process_get_ring")
          local pid, err = syscall("process_spawn", execPath, ring, {
             ARGS = args,
             PWD = ENV.PWD,
             PATH = ENV.PATH,
             USER = ENV.USER,
             HOME = ENV.HOME
          })
          if pid then
             syscall("process_wait", pid)
          else
             oFs.write(hStderr, "sh: " .. err .. "\n")
          end
       else
          oFs.write(hStderr, "sh: " .. cmd .. ": command not found\n")
       end
    end
  end
end

oFs.close(hStdin)
oFs.close(hStdout)