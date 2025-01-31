if component.list("ocelot")() ~= nil then
  _G.log = component.proxy(component.list("ocelot")()).log
end

if component.list("gpu")() ~= nil then
  _G.gpu = component.proxy(component.list("gpu")())
end
if component.list("keyboard") ~= nil then
  _G.keyboard = component.proxy(component.list("keyboard")())
end

-- ======================================================================================
-- ======================================================================================
-- ======================================================================================
_G.bootlog = ""
local BOOT_START_TIME = computer.uptime()
local MAX_BOOT_TIME = 20
local last_watchdog_reset = BOOT_START_TIME
local watchdog_enabled = true
local watchdog_timeout = 10

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
-----------------------------
_G.klog = function(...)
  local args = { ... }
  local log_message = ""

  for i, v in ipairs(args) do
    if type(v) == "table" then
      log_message = log_message .. table_to_string(v)
    else
      log_message = log_message .. tostring(v)
    end
    if i < #args then
      log_message = log_message .. " " -- Add space between arguments
    end
  end

  local timestamp = string.format("%.2f", computer.uptime() - BOOT_START_TIME)
  log_message = "[" .. timestamp .. "] " .. log_message
  _G.bootlog = _G.bootlog .. log_message
  if log then
    log(log_message)
  end
  kprint(log_message)
end

_G.reset_watchdog = function()
  last_watchdog_reset = computer.uptime()
  klog("Watchdog timer reset")
end

_G.check_watchdog = function()
  if watchdog_enabled and (computer.uptime() - last_watchdog_reset > watchdog_timeout) then
    klog("Watchdog timeout! Rebooting...")
    _G.filesystem.open(log_file, "a"):write("Watchdog timeout! Rebooting...\n"):close()
    computer.shutdown(true)
  end
end

_G.table_to_string = function(tbl, indent)
  if type(tbl) ~= "table" then return tostring(tbl) end

  indent = indent or 0 local result = {}

  for key, value in pairs(tbl) do local key_str = string.format("%s[%s]", string.rep(" ", indent), tostring(key))
    if type(value) == "table" then table.insert(result, key_str .. ":") table.insert(result, table_to_string(value, indent + 2))
    else table.insert(result, string.format("%s = %s", key_str, tostring(value))) end
  end
  return table.concat(result, "\n")
end


_G.print_table = function(name, tbl)
  klog(tostring(name) .. ":") if type(tbl) ~= "table" then klog("  " .. tostring(tbl)) return end local formatted_table = table_to_string(tbl) for line in formatted_table:gmatch("[^\r\n]+") do  klog("  " .. line)  end
end


-- ======================================================================================
-- ======================================================================================
-- ======================================================================================

_G._OSVERSION = "AwooOS A0.16b-290125"


_G.load_file = function(path, env, fs, is_require)
  if fs == nil then
    fs = computer.getBootAddress()
  end
  assert(fs, "No filesystem found to load " .. tostring(path))
  klog("load_file: loading file: " .. tostring(fs) .. ":" .. path)

  local handle, openErr = component.invoke(fs, "open", path, "r")
  if not handle then
    klog("load_file: Error opening file - ", openErr) -- Log the error
    return nil, ("Could not open " .. path .. ": " .. tostring(openErr))
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

  klog("load_file: File read successfully, attempting to load as function")
  local fn, loadErr = load(data, "=@:"..path, "t", env or _G)
  if not fn then
    klog("load_file: Error loading data as function - ", loadErr) -- Log the error
    error("Error loading file "..path..": "..tostring(loadErr))
  end

  klog("load_file: File loaded as function successfully")
  if is_require == true then
    local result = fn()
    klog("load_file: Function called for is_require, result:", result)
    return result
  end

  return fn
end

_G.krequire = function(path, env, fs)
  return _G.load_file(path, env, fs, true)
end

_G.os.sleep = function(time, push_back_signals)
  if push_back_signals == nil then push_back_signals = false end
  local start = computer.uptime()
  while computer.uptime() < start + time
  do
    computer.pushSignal("sleep")
    local signal_pack = table.pack(computer.pullSignal())
    if signal_pack[1] ~= "sleep" and push_back_signals then
      computer.pushSignal(table.unpack(signal_pack)) -- Signals that appeared during sleep need to be push back into the queue
    end
  end
end

-- ring environments
local Ring0 = {} -- kernel
local Ring1 = {} -- syscalls/Pipes
local Ring2 = {} -- superuser
local Ring3 = {} -- user

local syscalls = {}
Ring1.syscalls = syscalls

local syscalls_aliases = {}
Ring1.syscalls_aliases = syscalls_aliases

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
_G.kprint("Booting " .. _OSVERSION)
_G.filesystem = _G.krequire("/lib/filesystem.lua", _G)
if _G.filesystem ~= nil then klog("filesystem loaded") end
_G.require    = _G.krequire("/lib/require.lua", _G)
if _G.require ~= nil then klog("require loaded") end

local usermode_env = { print = _G.kprint, require = _G.require, load_file = function(path) return _G.load_file(path, Ring2) end, gpu = _G.gpu, filesystem = _G.filesystem, test_klog = function() klog("This is a test from Ring3") end }

setmetatable(Ring3, { __index = Ring2 })
setmetatable(Ring2, { __index = Ring1 })
setmetatable(Ring1, { __index = Ring0 })
setmetatable(Ring0, { __index = function(t, k) return _G[k] end })

load_file("/proc/core/kernel.lua", Ring0)().init(Ring0, Ring1, Ring2, Ring3)
klog("kernel loaded: /proc/core/kernel.lua")
print_table("Ring1", Ring1)
_G.os.sleep(0)

local usermode_process = coroutine.create(function()
    -- load usermode
    klog("boot.lua: Before load_file for usermode.lua")

    klog("boot.lua: Contents of Ring3:")
    for k, v in pairs(Ring3) do
      klog("  ", k, "=", v)
    end

    load_file("/proc/core/usermode.lua", Ring3)()
    klog("boot.lua: After load_file for usermode.lua")
  end)
local ok, err = coroutine.resume(usermode_process)
klog("boot.lua: coroutine.resume result - ok:", ok, "err:", err)

while true do
  _G.os.sleep(1)
end