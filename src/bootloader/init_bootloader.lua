do
  local isBootFS = 0
  local fs_list = component.list("filesystem")
  if fs_list then for _, __ in fs_list do isBootFS = isBootFS + 1 end end
  if isBootFS <= 1 then error("No bootable filesystem found.") end
end

if component.list("internet")() == nil then error("No internet card.") end

local installation

do
  local component_invoke = component.invoke
  local function eeprom_invk(address, method, ...)
    local success, result = pcall(component_invoke, address, method, ...)
    if not success then return nil, result end
    return result
  end

  local eeprom = component.list("eeprom")()
  computer.getBootAddress = function() return eeprom_invk(eeprom, "getData") end
  computer.setBootAddress = function(address) return eeprom_invk(eeprom, "setData", address) end

  local gpu
  do
    local screen = next(component.list("screen") or {})
    local gpu_addr = next(component.list("gpu") or {})
    if gpu_addr and screen then
      gpu = component.proxy(gpu_addr)
      local success, result = pcall(eeprom_invk, gpu_addr, "bind", screen)
      if not success then error("GPU bind fail: " .. tostring(result)) end
    else
      error("No GPU/screen found.")
    end
  end

  local cursor = {1, 1}
  local function status(text)
    gpu.set(cursor[1], cursor[2], text)
    cursor[2] = cursor[2] + 1
  end

  local function __fsclean(fs_proxy, file_path)
    if not fs_proxy or type(fs_proxy.list) ~= "function" then error("Invalid fs proxy.") end
    if not file_path:match(".*/$") then file_path = file_path .. "/" end
    local success, files = pcall(fs_proxy.list, file_path)
    if not success or not files then error("Failed to l_f in path: " .. file_path) end
    for _, file in pairs(files) do
      local full_path = file_path .. file
      if fs_proxy.isDirectory(full_path) then __fsclean(fs_proxy, full_path .. "/") end
      fs_proxy.remove(full_path)
    end
  end

  local function getInstaller(fs_boot_addr)
    local internet = component.list("internet")()
    local gh_install_addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/installation.lua"
    local inet_success, inet_handle = eeprom_invk(internet, "request", gh_install_addr)
    if not inet_success then error("request /installation.lua fail: " .. inet_handle) end

    local file_success, f_handle = eeprom_invk(fs_boot_addr, "open", "/installation.lua", "w")
    if not file_success then error("open /installation.lua fail: " .. f_handle) end
    while true do
      local chunk = inet_handle.read()
      if not chunk then break end
      f_handle.write(chunk)
    end
    f_handle:close()
  end

  local function __tryload(fs_boot_addr)
    local handle, reason = eeprom_invk(fs_boot_addr, "open", "/installation.lua")
    if not handle then return nil, reason end
    local buffer = ""
    repeat
      local data, reason = eeprom_invk(fs_boot_addr, "read", handle, math.maxinteger or math.huge)
      if not data and reason then return nil, reason end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invk(fs_boot_addr, "close", handle)
    return load(buffer, "=installation")
  end

  local fs_boot_addr = computer.getBootAddress()
  if not fs_boot_addr or type(fs_boot_addr) ~= "string" then error("No valid boot address found. Got: " .. tostring(fs_boot_addr)) end

  local fs_boot = component.proxy(fs_boot_addr)
  if not fs_boot then error("Failed to get fs proxy for address: " .. tostring(fs_boot_addr)) end

  status("boot address: " .. tostring(fs_boot_addr))
  __fsclean(fs_boot, "/")
  status("fs cleaned.")
  getInstaller(fs_boot)
  status("/installation.lua downloaded.")
  local reason
  installation, reason = __tryload(fs_boot)
  if not installation then error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0) end
  status("Installation loaded.")
end

return installation()