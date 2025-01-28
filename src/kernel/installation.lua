do
    local component_invoke = component.invoke
  
    local function pinvoke(address, method, ...)
      local ok, result = pcall(component_invoke, address, method, ...)
      if not ok then
        return nil, result
      end
      return true, result
    end
  
    local success, bt_addr = computer.getBootAddress()
    if not success then
        error("No boot address found: " .. tostring(bt_addr))
    end
  
    local directories = {"/boot", "/bin", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr"}
    for _, directory in ipairs(directories) do
      local ok, err = pinvoke(bt_addr, "makeDirectory", directory)
      if not ok then
        error("Failed to create directory '" .. directory .. "': " .. tostring(err))
      end
    end
  
    local os_files = {
      ["final_bootloader"]      = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/bootloader/final_bootloader.lua",
      ["/boot/boot.lua"]        = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/boot/boot.lua",
      ["/kernel.lua"]           = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/kernel.lua",
      ["/usermode.lua"]         = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/kernel/usermode.lua",
      ["/lib/filesystem.lua"]   = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/library/lib/filesystem.lua",
      ["/lib/ipc.lua"]   = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/library/lib/ipc.lua",
      -- ["/lib/filesystem.lua"]   = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/kerneltest/src/library/lib/filesystem.lua",
    }
  
    local internet = component.list("internet")()
    if not internet then
      error("No internet card found, cannot download files.")
    end
  
    for path, url in pairs(os_files) do
      local ok_request, request_handle = pinvoke(internet, "request", url)
      if not ok_request or not request_handle then
        error("Failed to request " .. url .. ": " .. tostring(request_handle))
      end
  
      if path == "final_bootloader" then
        local final_data = ""
        while true do
          local chunk = request_handle.read()
          if not chunk then break end
          final_data = final_data .. chunk
        end
  
        local eeprom = component.list("eeprom")()
        if not eeprom then
          error("No EEPROM found to write final bootloader!")
        end
  
        local ok_set, err_set = pinvoke(eeprom, "set", final_data)
        if not ok_set then
            error("Failed to write EEPROM: " .. tostring(err_set))
        end
  
        computer.setBootAddress(bt_addr)
      else
        local ok_open, handle = pinvoke(bt_addr, "open", path, "w")
        if not ok_open or not handle then
            error("Failed to open '" .. path .. "' for writing: " .. tostring(handle))
        end
  
        while true do
          local chunk = request_handle.read()
          if not chunk then break end
          local ok_write, err_write = pinvoke(bt_addr, "write", handle, chunk)
          if not ok_write then
            error("Failed to write to '" .. path .. "': " .. tostring(err_write))
          end
        end
  
        local ok_close, err_close = pinvoke(bt_addr, "close", handle)
        if not ok_close then
            error("Failed to close '" .. path .. "': " .. tostring(err_close))
        end
      end
    end

    local ok_remove, err_remove = pinvoke(bt_addr, "remove", "/installation.lua")
    if not ok_remove then
        error("Failed to remove /installation.lua: " .. tostring(err_remove))
    end
end
  