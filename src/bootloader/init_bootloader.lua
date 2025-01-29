local installation
do
  local component_invoke = component.invoke
  local function eeprom_invoke(address, method, ...)
    local success, result = pcall(component_invoke, address, method, ...)
    if not success then return nil, result
    else return result
    end
  end

  local eeprom = component.list("eeprom")()
  computer.getBootAddress = function()
    return eeprom_invoke(eeprom, "getData")
  end
  computer.setBootAddress = function(address)
    return eeprom_invoke(eeprom, "setData", address)
  end

  do
    local screen = component.list("screen")()
    local gpu = component.list("gpu")()
    if gpu and screen then eeprom_invoke(gpu, "bind", screen)
    else error()
    end
  end

  local function __fsclean(bt_addr, file_path)
    local files, err = eeprom_invoke(bt_addr, "list", "/")
    if not files then error("Failed to get list in path: " .. file_path .. ": " .. err) end
    for _, path in ipairs(files)
    do
      local full_path = file_path .. path

      local is_directory, err = eeprom_invoke(bt_addr, "isDirectory", full_path)
      if not is_directory then error("Failed to get isDirectory in path:" .. full_path .. ": " .. err) end

      if is_directory then __fsclean(bt_addr, full_path) end

      local remove, err = eeprom_invoke(bt_addr, "remove", full_path)
      if not remove then error("Failed to remove file in path: " .. full_path .. ": " .. err) end
    end
  end

  local function try_load_from(fs_boot_address)
    local handle, err = eeprom_invoke(fs_boot_address, "open", "/installation.lua")
    if not handle then
      return nil, err
    end
    local buffer = ""
    repeat
      local data, err = eeprom_invoke(fs_boot_address, "read", handle, math.maxinteger or math.huge)
      if not err then
        return nil, err
      end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invoke(fs_boot_address, "close", handle)
    return load(buffer, "=installation")
  end

  -- get boot address
  local bt_addr, error = computer.getBootAddress()
  if not bt_addr then error("No boot address found: " .. bt_addr) end

  --clean up fs
  __fsclean(bt_addr, "/")

  -- download installation
  local internet = component.list("internet")()
  local instal_addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/installation.lua"
  local request, err = eeprom_invoke(internet, "request", instal_addr)
  if not request then error("Failed to request installation.lua from github: " .. err) end

  local handle, err = eeprom_invoke(bt_addr, "open", "/installation.lua", "w")
  if not handle then error("Failed to open /installation.lua file: " .. err) end

  local installation_data = ""
  while true
  do
    local chunk = request.read()
    if not chunk then break end
    installation_data = installation_data .. chunk
  end
  local write, err = eeprom_invoke(bt_addr, "write", handle, installation_data)
  if not write then error("Failed to write to /installation.lua file: " .. err) end
  local close, err = eeprom_invoke(bt_addr, "close", handle)
  if not close then error("Failed to close /installation.lua file: " .. err) end

  local reason
  installation, reason = try_load_from(bt_addr)
  if not installation
  then
    error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
  end
end
return installation()