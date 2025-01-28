local component = component
local computer = computer

_G._OSVERSION = "AwooOS 0.1"

local gpu = component.list("gpu")()
gpu = component.proxy(gpu)
gpu.fill(1, 1, 160, 50, " ")
--gpu.setResolution(160,50)

-- simulated Filesystem
local filesystem = {}

local function customRequire(path, env)
  if filesystem[path] then
    local func, err = load(filesystem[path], path, "t", env)
    if func then
      return func()
    else
      error("Error loading module '" .. path .. "': " .. err)
    end
  else
    error("Module not found: " .. path)
  end
end

-- ring environments
local Ring0 = {} -- kernel
local Ring1 = {} -- syscalls/Pipes
local Ring2 = {} -- superuser
local Ring3 = {} -- user

local syscalls = {}
Ring1.syscalls = syscalls

local pipes = {}
Ring1.pipes = pipes

function pipes.create(name)
    if pipes[name] then
        error("Pipe already exists: " .. name)
    end
    pipes[name] = {
        data = "",
        read_waiting = {},
        write_waiting = {}
    }
end

function pipes.write(name, data)
    local pipe = pipes[name]
    if not pipe then
        error("Pipe not found: " .. name)
    end
    pipe.data = pipe.data .. data

    while #pipe.read_waiting > 0 and #pipe.data > 0 do
        local co = table.remove(pipe.read_waiting, 1)
        coroutine.resume(co)
    end

    if #pipe.data > 255 then
        table.insert(pipe.write_waiting, coroutine.running())
        return coroutine.yield()
    end
end

function pipes.read(name)
    local pipe = pipes[name]
    if not pipe then
        error("Pipe not found: " .. name)
    end

    if #pipe.data == 0 then
        table.insert(pipe.read_waiting, coroutine.running())
        coroutine.yield()  -- wait until data is available
    end

    local data = pipe.data
    pipe.data = ""

    if #pipe.write_waiting > 0 then
        local co = table.remove(pipe.write_waiting, 1)
        coroutine.resume(co)
    end
    
    return data
end

setmetatable(Ring3, { __index = function(t, k) error("Access denied: " .. k) end })
setmetatable(Ring2, { __index = Ring1 }) 
setmetatable(Ring0, { __index = function(t, k) return _G[k] end })

filesystem["/kernel.lua"] = [[

]]

filesystem["/usermode.lua"] = [[

]]

filesystem["/lib/require.lua"] = [[
  return function(path, env)
    return customRequire(path, env)
  end
]]

filesystem["/lib/filesystem.lua"] = [[
  return {
    open = function(path, mode)
        local f = {}
        local pos = 1
        local data = filesystem[path] or ""
      
        if mode == "r" then
            function f:read(n)
                local read_data = string.sub(data, pos, pos + (n or 1) - 1)
                pos = pos + (n or 1)
                if pos > string.len(data) + 1 then
                  pos = string.len(data) + 1
                end
                return read_data
            end
      
        elseif mode == "w" then
            function f:write(...)
                local args = {...}
                for i,v in ipairs(args) do
                    data = data .. tostring(v)
                end
                filesystem[path] = data
            end
      
        elseif mode == "a" then
            pos = string.len(data) + 1
            function f:write(...)
                local args = {...}
                for i,v in ipairs(args) do
                    data = data .. tostring(v)
                end
                filesystem[path] = data
            end
        else
            error("Invalid file mode")
        end
        function f:seek(whence, offset)
          if whence == "set" then
            pos = (offset or 0) + 1
          elseif whence == "cur" then
            pos = pos + (offset or 0)          
          elseif whence == "end" then
            pos = string.len(data) + (offset or 0) + 1
          end
          if pos < 1 then
            pos = 1
          elseif pos > string.len(data) + 1 then
            pos = string.len(data) + 1
          end
        
          return pos - 1
        end
        function f:close()
          f = nil
        end
      
        return f
    end,
    list = function(path)
      local results = {}
      for k, _ in pairs(filesystem) do
        if string.sub(k, 1, string.len(path)) == path then
          table.insert(results, string.sub(k, string.len(path) + 1))
        end
      end
      return results
    end
  }
]]

_G.filesystem = customRequire("/lib/filesystem.lua", _G)
_G.require    = customRequire("/lib/require.lua", _G)

local kernel_module = customRequire("/kernel.lua", Ring0)

kernel_module.init(Ring0, Ring1, Ring2, Ring3)

local firstProcess = coroutine.create(function()
  customRequire("/usermode.lua", Ring3)
end)
coroutine.resume(firstProcess)

while true do
  local sig = {computer.pullSignal(0.1)}
end