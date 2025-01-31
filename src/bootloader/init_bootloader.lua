_G.last_error = { error_msg = nil }
_G.cpcall = function(address, method, ...) -- component proctected call
  local err = _G.pcall_last_error
  local result = table.pack(pcall(component.invoke, address, method, ...))
  if not result[1] then
    err.error_msg = result[2]
    return nil
  else
    err.error_msg = nil
    return table.unpack(result, 2, result.n)
  end
end
_G.fpcall = function(function, ...) -- function protected call
  local err = _G.pcall_last_error
  local result = table.pack(pcall(function, ...))
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

local function fs_clean(bt_addr, file_path)
  local err = nil

  local files = cpcall(bt_addr, "list", "/")
  err = get_last_error()
  if err then error("Failed to get list in path: " .. file_path .. ": " .. err) end

  for _, path in ipairs(files)
  do
    local full_path = file_path .. path

    if path == "/old/" then goto continue end -- skip the old directory where files from /home/ on the old OC are stored

    local is_directory = cpcall(bt_addr, "isDirectory", full_path)
    err = get_last_error()
    if err then error("Failed to check if path is directory: " .. full_path .. ": " .. err) end

    if is_directory then fs_clean(bt_addr, full_path) end

    cpcall(bt_addr, "remove", full_path)
    err = get_last_error()
    if err then error("Failed to remove file: " .. full_path .. ": " .. err) end

    ::continue::
  end
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

-- get boot address
local bt_addr = computer.getBootAddress()
err = get_last_error()
if err then error("No boot address found: " .. err) end

--clean up fs
fs_clean(bt_addr, "/")

-- download installation
local internet = component.list("internet")()
local instal_addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/installation.lua"
local request = cpcall(internet, "request", instal_addr)
err = get_last_error()
if err then error("Failed to request installation.lua from github: " .. err) end

local handle = cpcall(bt_addr, "open", "/installation.lua", "w")
err = get_last_error()
if err then error("Failed to open /installation.lua file: " .. err) end

local installation_data = ""
while true
do
  local chunk = request.read()
  if not chunk then break end
  installation_data = installation_data .. chunk
end
local write = cpcall(bt_addr, "write", handle, installation_data)
err = get_last_error()
if err then error("Failed to write to /installation.lua file: " .. err) end

cpcall(bt_addr, "close", handle)
err = get_last_error()
if err then error("Failed to close /installation.lua file: " .. err) end

local installation = try_load_from(bt_addr)
err = get_last_error()
if err then error("Failed to load from boot address: " .. err) end

return installation()