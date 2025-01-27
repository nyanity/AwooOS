local ocelot
if component.list("ocelot")() ~= nil then ocelot = component.proxy(component.list("ocelot")()) end
local log = ocelot.log
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
        log("Created directory: " .. directory)
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
        log("Requested " .. address .. " from github")

        if path == "final_bootloader"
        then
            log("Setting final bootloader in eeprom")
            local final_btldr_data = ""
            while true
            do
                local chunk = request.read()
                if not chunk then break end
                final_btldr_data = final_btldr_data .. chunk
            end
            log("Final bootloader is downloaded")
            log(final_btldr_data)
            local success, set = pinvoke(component.list("eeprom")(), "set", final_btldr_data)
            if not success then error("Failed to write EEPROM: " .. set) end
            computer.setBootAddress(bt_addr)
            log("Final bootloader is written to EEPROM")

            

            break
        end

        local success, handle = pinvoke(bt_addr, "open", path, "w")
        if not success then error("Failed to open " .. path .. " file: " .. file_handle) end
        log("Opened " .. path .. " file")

        while true
        do
          local chunk = request.read()
          if not chunk then break end
          local success, wrt = pinvoke(bt_addr, "write", handle, chunk)
          if not success then error("Failed to write to /installation.lua file: " .. wrt) end
        end
        log("Writed OS file: " .. path)
        local sucess, cls = pinvoke(bt_addr, "close", handle)
        if not sucess then error("Failed to close /installation.lua file: " .. cls) end
        log("Closed " .. path .. " file")
    end

    computer.stop()
end