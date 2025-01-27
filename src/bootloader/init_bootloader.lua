do
  local bootfs_present = 0
  local fs_list = component.list("filesystem")
  if fs_list then for _, __ in fs_list do bootfs_present = bootfs_present + 1 end end
  if bootfs_present <= 1 then error("No bootable filesystem found.") end
end
if component.list("internet")() == nil then error("No interned card.") end

local installation

do
  local component_invoke = component.invoke
  local function eeprom_invoke(address, method, ...)
    local success, result = pcall(component_invoke, address, method, ...)
    if not success then return nil, result end
    return result
  end
  local eeprom = component.list("eeprom")()
  computer.getBootAddress = function() return eeprom_invoke(eeprom, "getData") end
  computer.setBootAddress = function(address) return eeprom_invoke(eeprom, "setData", address) end

  local gpu
  do
    local screen = next(component.list("screen") or {})
    local gpu_addr = next(component.list("gpu") or {})
    if gpu_addr and screen then gpu = component.proxy(gpu_addr)
        local success, result = pcall(eeprom_invoke, gpu_addr, "bind", screen)
        if not success then error("GPU bind fail: " .. tostring(result)) end else error("Nor GPU/screen found.") end
  end

  local cursor = {1, 1}
  local function status(text)
    gpu.set(cursor[1], cursor[2], text)
    cursor[2] = cursor[2] + 1
  end

  local function clean_up_fs(fs_proxy, file_path)
    if not fs_proxy or type(fs_proxy.list) ~= "function" then error("Invalid fs proxy or 'list' method not found.") end
    if not file_path:match(".*/$") then file_path = file_path .. "/" end
    local success, files = pcall(fs_proxy.list, file_path)
    if not success or not files then error("Failed to list files in path: " .. file_path) end
    for _, file in pairs(files) do local full_path = file_path .. file
      if fs_proxy.isDirectory(full_path) then clean_up_fs(fs_proxy, full_path .. "/") end fs_proxy.remove(full_path)
    end
  end
end


  local function download_installation(fs_boot_addr)
    local internet = component.list("internet")()
    local gh_install_addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/installation.lua"
    local inet_success, inet_handle = eeprom_invoke(internet, "request", gh_install_addr)
    if not inet_success then error("Failed to request /installation.lua: " .. inet_handle) end

    local file_success, file_handle = eeprom_invoke(fs_boot_addr, "open", "/installation.lua", "w")
    if not file_success then error("Failed to open /installation.lua: " .. file_handle) end
    while true do
      local chunk = inet_handle.read()
      if not chunk then break end
      file_handle.write(chunk)
    end 
    file_handle:close()
  end

  local function try_load_from(fs_boot_addr)
    local handle, reason = eeprom_invoke(fs_boot_addr, "open", "/installation.lua")
    if not handle then return nil, reason end
    local buffer = ""
    repeat
      local data, reason = eeprom_invoke(fs_boot_addr, "read", handle, math.maxinteger or math.huge)
      if not data and reason then return nil, reason end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invoke(fs_boot_addr, "close", handle)
    return load(buffer, "=installation")
  end

  local fs_boot_addr = computer.getBootAddress()
  if not fs_boot_addr or type(fs_boot_addr) ~= "string" then 
    error("No valid boot address found. Got: " .. tostring(fs_boot_addr))
  end

  status("Received boot address: " .. tostring(fs_boot_addr))
  clean_up_fs(fs_boot_addr, "/") 
  status("Filesystem cleaned.")
  download_installation(fs_boot_addr)
  status("/installation.lua downloaded.")
  local reason
  installation, reason = try_load_from(fs_boot_addr)
  if not installation then error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0) end
  status("Installation function is loaded.")
end
return installation()