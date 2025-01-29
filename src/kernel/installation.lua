do
  local component_invoke = component.invoke

  local function pinvoke(address, method, ...)
    local ok, result = pcall(component_invoke, address, method, ...)
    if not ok then
      return nil, result
    end
    return result
  end

  local bt_addr, err = computer.getBootAddress()
  if not bt_addr then
      error("No boot address found: " .. tostring(err))
  end

  local directories = {"/boot", "/bin", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr", "proc/", "proc/core"}
  for _, directory in ipairs(directories) do
    local ok, err = pinvoke(bt_addr, "makeDirectory", directory)
    if not ok then
      error("Failed to create directory '" .. directory .. "': " .. tostring(err))
    end
  end

  local os_files = {
    ["final_bootloader"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/bootloader/",

    ["/boot/boot.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",
    ["/boot/boot_reserved.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",

    ["/bin/shell.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",
    ["/bin/su_shell_reversed.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",

    ["lib/filesystem.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",
    ["lib/require.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",

    ["proc/core/kernel.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",
    ["proc/core/usermode.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",

    ["usr/help.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/",
  }

  local internet = component.list("internet")()
  if not internet then
    error("No internet card found, cannot download files.")
  end

  for path, url in pairs(os_files) do
    local request, err = pinvoke(internet, "request", url .. path)
    if not request then
      error("Failed to request " .. url .. ": " .. tostring(err))
    end

    if path == "final_bootloader" then
      local final_data = ""
      while true do
        local chunk = request.read()
        if not chunk then break end
        final_data = final_data .. chunk
      end

      local eeprom = component.list("eeprom")()
      if not eeprom then
        error("No EEPROM found to write final bootloader!")
      end

      local set, err = pinvoke(eeprom, "set", final_data)
      if not set then
          error("Failed to write EEPROM: " .. tostring(err))
      end

      computer.setBootAddress(bt_addr)
    else
      local handle, err = pinvoke(bt_addr, "open", path, "w")
      if not handle then
          error("Failed to open '" .. path .. "' for writing: " .. tostring(err))
      end

      while true do
        local chunk = handle.read()
        if not chunk then break end
        local write, err = pinvoke(bt_addr, "write", handle, chunk)
        if not write then
          error("Failed to write to '" .. path .. "': " .. tostring(err))
        end
      end

      local close, err = pinvoke(bt_addr, "close", handle)
      if not close then
          error("Failed to close '" .. path .. "': " .. tostring(err))
      end
    end
  end

  local remove, err = pinvoke(bt_addr, "remove", "/installation.lua")
  if not remove then
      error("Failed to remove /installation.lua: " .. tostring(err))
  end
end
