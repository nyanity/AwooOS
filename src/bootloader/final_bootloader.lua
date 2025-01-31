_G.last_error = { error_msg = nil }
_G.cpcall = function(address, method, ...) -- component proctected call
  local err = _G.last_error
  local result = table.pack(pcall(component.invoke, address, method, ...))
  if not result[1] then
    err.error_msg = result[2]
    return nil
  else
    err.error_msg = nil
    return table.unpack(result, 2, result.n)
  end
end
_G.fpcall = function(func, ...) -- function protected call
  local err = _G.last_error
  local result = table.pack(pcall(func, ...))
  if not result[1] then
    err.error_msg = result[2]
    return nil
  else
    err.error_msg = nil
    return table.unpack(result, 2, result.n)
  end
end
_G.get_last_error = function() -- get last error
  return _G.last_error.error_msg
end

local eeprom = component.list("eeprom")()
computer.getBootAddress = function()
  return cpcall(eeprom, "getData")
end
computer.setBootAddress = function(address)
  cpcall(eeprom, "setData", address)
end

do -- trying to bind gpu to screen if available gpu and screen
  local screen = component.list("screen")()
  local gpu = component.list("gpu")()
  if gpu and screen then cpcall(gpu, "bind", screen) end
  local err = get_last_error()
  if err then error("Failed to bind gpu to screen: " .. err) end
end

local function load_from(fs_addr)
  local handle = cpcall(fs_addr, "open", "/boot/boot.lua")
  if not handle then return nil end

  local buffer = ""
  repeat
    local data = cpcall(fs_addr, "read", handle, math.maxinteger or math.huge)
    if not data and get_last_error() then return nil end
    buffer = buffer .. (data or "")
  until not data
  cpcall(fs_addr, "close", handle)
  return load(buffer, "=installation")
end

local err = nil

local bt_addr = computer.getBootAddress()
err = get_last_error()
if err then error("No boot address found: " .. err) end

local boot = load_from(bt_addr)
err = get_last_error()
if err then error("Failed to load from boot address: " .. err) end

return boot()