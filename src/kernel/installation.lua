do
    local component_invoke = component.invoke
    local function pinvoke(address, method, ...) -- protected compnent.invoke
      local success, result = pcall(component_invoke, address, method, ...)
      if not success then return nil, result
      else return success, result
      end
    end

    local sucess, bt_addr = computer.getBootAddress()
    if not sucess then error("No boot address found: " .. bt_addr) end

    local directories = {"/boot", "/bin", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr"}
    for _, directory in ipairs(directories)
    do
        local success, mkdir = pinvoke(bt_addr, "makeDirectory", directory)
        if not success then error("Failed to create directory: " .. directory .. ": " .. mkdir) end
    end

    local os_files = {
        ["final_bootloader"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/bootloader/final_bootloader.lua",
        ["/boot/boot.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/boot/boot.lua"
    }
    local internet = component.list("internet")()

    for path, address in pairs(os_files)
    do
        local success, request = pinvoke(internet, "request", address)
        if not success then error("Failed to request " .. address .. " from github: " .. request) end

        if path == "final_bootloader"
        then
            local final_btldr_data = ""
            while true
            do
                local chunk = request.read()
                if not chunk then break end
                final_btldr_data = final_btldr_data .. chunk
            end

            local success, set = pinvoke(component.list("eeprom")(), "set", final_btldr_data)
            if not success then error("Failed to write EEPROM: " .. set) end
            computer.setBootAddress(bt_addr)
        else
            local success, handle = pinvoke(bt_addr, "open", path, "w")
            if not success then error("Failed to open " .. path .. " file: " .. file_handle) end

            while true
            do
                local chunk = request.read()
                if not chunk then break end
                local success, wrt = pinvoke(bt_addr, "write", handle, chunk)
                if not success then error("Failed to write to /installation.lua file: " .. wrt) end
            end

            local sucess, cls = pinvoke(bt_addr, "close", handle)
            if not sucess then error("Failed to close /installation.lua file: " .. cls) end
        end
    end

    pinvoke(bt_addr, "remove", "/installation.lua")
end