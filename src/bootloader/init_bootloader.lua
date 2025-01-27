<<<<<<< HEAD
do
  local is_there_bootable_fs = 0
  for _, __ in component.list("filesystem") do is_there_bootable_fs = is_there_bootable_fs + 1 end
  if is_there_bootable_fs <= 1 then error("There is no any bootable filesystem in computer.") end
end
if component.list("internet")() == nil then error("There is no internet card in computer.") end

=======
>>>>>>> 9f32c5c5bb3a6b4dc3b96995fcd9206bc02c1015
local installation
do
  local component_invoke = component.invoke
  local function eeprom_invoke(address, method, ...)
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

  do
    local screen = component.list("screen")()
    local gpu = component.list("gpu")()
    if gpu and screen then eeprom_invoke(gpu, "bind", screen)
    else error()
    end
  end

  local function __fsclean(bt_addr, file_path)
    local success, files = eeprom_invoke(bt_addr, "list", "/")
    if not success then error("Failed to get list in path: " .. file_path .. ": " .. files) end
    for _, path in ipairs(files)
    do
      local full_path = file_path .. path

      local success, is_directory = eeprom_invoke(bt_addr, "isDirectory", full_path)
      if not success then error("Failed to get isDirectory in path:" .. full_path .. ": " .. is_directory) end

      if is_directory then __fsclean(bt_addr, full_path) end

      local success, rm = eeprom_invoke(bt_addr, "remove", full_path)
      if not success then error("Failed to remove file in path: " .. full_path .. ": " .. rm) end
    end
  end

  local function try_load_from(fs_boot_address)
    local reason, handle = eeprom_invoke(fs_boot_address, "open", "/installation.lua")
    if not reason then
      return nil, reason
    end
    local buffer = ""
    repeat
      local reason, data = eeprom_invoke(fs_boot_address, "read", handle, math.maxinteger or math.huge)
      if not reason then
        return nil, reason
      end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invoke(fs_boot_address, "close", handle)
    return load(buffer, "=installation")
  end

  -- get boot address
  local sucess, bt_addr = computer.getBootAddress()
  if not sucess then error("No boot address found: " .. bt_addr) end

  --clean up fs
  __fsclean(bt_addr, "/")

  -- download installation
  local internet = component.list("internet")()
  local instal_addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/installation.lua"
  local success, request = eeprom_invoke(internet, "request", instal_addr)
  if not success then error("Failed to request installation.lua from github: " .. request) end

  local success, handle = eeprom_invoke(bt_addr, "open", "/installation.lua", "w")
  if not success then error("Failed to open /installation.lua file: " .. file) end

  while true
  do
    local chunk = request.read()
    if not chunk then break end
    local success, wrt = eeprom_invoke(bt_addr, "write", handle, chunk)
    if not success then error("Failed to write to /installation.lua file: " .. wrt) end
  end
  local sucess, cls = eeprom_invoke(bt_addr, "close", handle)
  if not sucess then error("Failed to close /installation.lua file: " .. cls) end

  local reason
  installation, reason = try_load_from(bt_addr)
  if not installation
  then
    error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
  end
end
return installation()