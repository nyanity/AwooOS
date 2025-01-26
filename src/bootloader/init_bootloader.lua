do -- in release delete this... maybe
  local debug = component.list("debug")()
  if debug 
  then
    success, users = pcall(component.invoke, debug, "getPlayers")
    if not success then error("Failed to get players: " .. users) end
    for _, username in pairs(users)
    do
      if username == "Archevod" then error("Archevod detected. Aborting.") end
    end
  end
end

if #component.list("filesystem") == 0 then error("There is no any bootable filesystem in computer.") end
if component.list("internet")() == nil then error("There is no internet card in computer.") end

local installation
do
  local component_invoke = component.invoke
  local function eeprom_invoke(address, method, ...) -- wrapper for pcall
    local success, result = pcall(component_invoke, address, method, ...)
    if not success then return nil, result
    else return success, result
    end
  end

  local eeprom = component.list("eeprom")()
  computer.getBootAddress = function()
    return eeprom_invoke(eeprom, "getData")
  end
  computer.setBootAddress = function(address)
    return eeprom_invoke(eeprom, "setData", address)
  end

  do -- bind gpu to screen
    local screen = component.list("screen")()
    local gpu = component.list("gpu")()
    if gpu and screen then eeprom_invoke(gpu, "bind", screen)
    else error() -- no error message because there is no gpu of screen lol
    end
  end

  local cursor = {1, 1}
  local function status(text) -- status message
    gpu.set(cursor[1], cursor[2], text)
    cursor[2] = cursor[2] + 1
  end

  local function clean_up_fs(fs_boot_address, file_path) -- rm /* -rf be like:
    local fs_proxy = component.proxy(fs_boot_address)
    if not fs_proxy then error("Failed to proxy boot address.") end
    for file in fs_proxy.list("/")
    do
      file_path = fs_proxy.concat(file_path, file)
      if fs_proxy.isDirectory(file_path) then clean_up_fs(fs_proxy, file_path) fs_proxy.remove(file_path)
      else fs_proxy.remove(file_path) end
    end
  end

  local function download_installation(fs_boot_address)
    local internet = component.list("internet")()
    local github_installation_address = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/installation.lua" -- change this to the github address
    local internet_success, internet_handle = eeprom_invoke(internet, "request", github_installation_address)
    if not internet_success then error("Failed to request /installation.lua file from github: " .. internet_handle) end

    local file_success, file_handle = eeprom_invoke(fs_boot_address, "open", "/installation.lua", "w")
    if not file_success then error("Failed to open /installation.lua file: " .. file_handle) end
    for chunk in internet_handle do file_handle:write(chunk) end 
    file_handle:close()
  end

  local function try_load_from(fs_boot_address)
    local handle, reason = eeprom_invoke(fs_boot_address, "open", "/installation.lua")
    if not handle then
      return nil, reason
    end
    local buffer = ""
    repeat
      local data, reason = eeprom_invoke(fs_boot_address, "read", handle, math.maxinteger or math.huge)
      if not data and reason then
        return nil, reason
      end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invoke(fs_boot_address, "close", handle)
    return load(buffer, "=installation")
  end

  local fs_boot_address = computer.getBootAddress()
  if not fs_boot_address then error("No boot address found.") end
  status("Recived boot address: " .. fs_boot_address)

  clean_up_fs(fs_boot_address, "/") 
  status("Filesystem is cleaned.")
  download_installation(fs_boot_address)
  status("/installation.lua is downloaded.")
  local reason
  installation, reason = try_load_from(fs_boot_address)
  if not installation
  then
    error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
  end
  status("Installation function is loaded.")
end
return installation()