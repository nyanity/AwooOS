if component.list("ocelot")() ~= nil then
  _G.log = component.proxy(component.list("ocelot")()).log
end
_G.gpu = component.proxy(component.list("gpu")())
_G.keyboard = component.proxy(component.list("keyboard")())

_G.kprint_y = 0
_G.kprint = function(text)
  local pointer = 0
  local text_table = {}
  if pointer < #text then
    table.insert(text_table, string.sub(text, pointer, pointer + 160))
    pointer = pointer + 160
  end
  local y_offset = 0
  for i, v in ipairs(text_table) do
    gpu.set(1, i + _G.kprint_y, v)
    y_offset = i
  end
  _G.kprint_y = _G.kprint_y + y_offset
end

_G._OSVERSION = "AwooOS 0.1"

_G.load_file = function(path, env, fs, is_require)
  if fs == nil then
    fs = computer.getBootAddress()
  end
  assert(fs, "No filesystem found to load " .. tostring(path))

  local handle, openErr = component.invoke(fs, "open", path, "r")
  if not handle then
    error("Could not open " .. path .. ": " .. tostring(openErr))
  end
  local data = ""
  while true do
      local chunk = component.invoke(fs, "read", handle, math.huge)
    if not chunk then
      break
    end
    data = data .. chunk
  end
  component.invoke(fs, "close", handle)

  local fn, loadErr = load(data, "="..path, "t", env)
  if not fn then
    error("Error loading file " .. path .. ": " .. tostring(loadErr))
  end

  if is_require == true then
    return fn()
  end
  return fn
end
_G.krequire = function(path, env, fs)
  return _G.load_file(path, env, fs, true)
end

_G.os.sleep = function(time)
  local start = computer.uptime()
  while computer.uptime() < start + time do end
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

gpu.setResolution(160, 50)
gpu.fill(1, 1, 160, 50, " ")
_G.kprint("AwooOS 0.1 booting...")

_G.filesystem = _G.krequire("/lib/filesystem.lua", _G)
if _G.filesystem ~= nil then _G.kprint("Filesystem loaded.") end
_G.require    = _G.krequire("/lib/require.lua", _G)
if _G.require ~= nil then _G.kprint("Require loaded.") end

local usermode_env = { print = _G.kprint, require = _G.require, load_file = function(path) return _G.load_file(path, Ring2) end, gpu = _G.gpu, filesystem = _G.filesystem }

setmetatable(Ring3, { __index  = Ring2})
setmetatable(Ring2, { __index = Ring1 })
setmetatable(Ring1, { __index = Ring0 })
setmetatable(Ring0, { __index = function(t, k) return _G[k] end })

load_file("/boot/kernel.lua", Ring0)().init(Ring0, Ring1, Ring2, Ring3)
_G.kprint("Kernel loaded.")
_G.os.sleep(3)

local usermode_process = coroutine.create(function()
    -- load usermode
    load_file("/boot/usermode.lua", Ring3)()
  end)
coroutine.resume(usermode_process)

local update_rate = 0.3
local last_update = computer.uptime()
while true do
  while computer.uptime() < last_update + update_rate do end
  last_update = computer.uptime()
  computer.pullSignal()
end