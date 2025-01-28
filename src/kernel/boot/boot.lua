_G.component = component
_G.computer = computer

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
        assert(func, "Error loading module '" .. path .. "': " .. tostring(err))
        return func()
    end
  else
    error("Module not found: " .. path)
  end
end


local function loadFromDisk(path, env)
    local fsAddress
        repeat
            fsAddress = component.list("filesystem")()
        if not fsAddress then
            computer.pullSignal(0.5)  -- or 0.5
        end
    until fsAddress
    assert(fsAddress, "No filesystem component found!")
  
    local fs = component.proxy(fsAddress)
    local handle, err = fs.open(path, "r")
    if not handle then
        error("Failed to open file '" .. path .. "': " .. tostring(err))
    end
  
    local data = ""
    while true do
        local chunk = fs.read(handle, math.huge)
        if not chunk then
            break
        end
        data = data .. chunk
    end
    fs.close(handle)
  
    return load(data, "=" .. path, "t", env)
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

setmetatable(Ring3, { __index = _G })
setmetatable(Ring2, { __index = Ring1 }) 
setmetatable(Ring0, { __index = function(t, k) return _G[k] end })

local function loadFileFromDisk(path, env)
    -- find the first filesystem component (thanks gpt for useless code. i'll hold it here :))
    local fsAddress = component.list("filesystem")()
    assert(fsAddress, "No filesystem found to load " .. tostring(path))
  
    local handle, openErr = component.invoke(fsAddress, "open", path, "r")
    if not handle then
      error("Could not open " .. path .. ": " .. tostring(openErr))
    end
  
    local data = ""
    while true do
      local chunk = component.invoke(fsAddress, "read", handle, math.huge)
      if not chunk then
        break
      end
      data = data .. chunk
    end
  
    component.invoke(fsAddress, "close", handle)
  
    -- 'load' the Lua chunk in the given 'env' (environment/table).
    local fn, loadErr = load(data, "="..path, "t", env)
    if not fn then
      error("Error loading file " .. path .. ": " .. tostring(loadErr))
    end
  
    return fn  -- return the loaded chunk (function)
end
  

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

local chunk = loadFileFromDisk("/kernel.lua", Ring0)
local kernelModule = chunk()
kernelModule.init(Ring0, Ring1, Ring2, Ring3)

local firstProcess = coroutine.create(function()
    -- load usermode
    local usermodeModule = loadFileFromDisk("/usermode.lua", Ring3)
    usermodeModule()  -- run it
  end)
coroutine.resume(firstProcess)

while true do
  local sig = {computer.pullSignal(0.1)}
end