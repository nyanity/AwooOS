local fs = require("lib/filesystem")
local sys = require("lib/syscall")

local stdin = { fd = 0 }
local stdout = { fd = 1 }
local stderr = { fd = 2 }

local current_path = env.HOME or "/"

local function get_prompt()
  local ring = syscall("process_get_ring")
  local user = env.USER or "user"
  local char = (ring == 2.5) and "#" or "$"
  return user .. "@auraos:" .. current_path .. " " .. char .. " "
end

local function split_cmd(line)
  local args = {}
  for arg in string.gmatch(line, "[^%s]+") do
    table.insert(args, arg)
  end
  return args
end

-- Built-in commands
local builtins = {}

function builtins.cd(args)
  local path = args[1] or env.HOME
  -- TODO: Path resolution (.., ., ~)
  if fs.list(path) then -- Check if dir exists
    current_path = path
  else
    fs.write(stderr, "cd: No such directory: " .. path .. "\n")
  end
  return true
end

function builtins.exit()
  return false -- Signal to exit loop
end

while true do
  fs.write(stdout, get_prompt())
  local line = fs.read(stdin)
  
  if line then
    local args = split_cmd(line)
    local cmd = table.remove(args, 1)
    
    if cmd then
      local builtin = builtins[cmd]
      if builtin then
        if not builtin(args) then
          break -- exit
        end
      else
        -- Not a builtin, try to execute
        local cmd_path = "/usr/commands/" .. cmd .. ".lua"
        
        -- Check if file exists
        local f, err = fs.open(cmd_path, "r")
        if f then
          fs.close(f)
          local ring = syscall("process_get_ring")
          local pid, err = syscall("process_spawn", cmd_path, ring, {
            PATH = current_path,
            USER_ENV = env,
            ARGS = args,
          })
          if pid then
            syscall("process_wait", pid)
          else
            fs.write(stderr, "exec failed: " .. err .. "\n")
          end
        else
          fs.write(stderr, "command not found: " .. cmd .. "\n")
        end
      end
    end
  else
    -- EOF (e.g., Ctrl+D, if TTY supported it)
    break
  end
end
