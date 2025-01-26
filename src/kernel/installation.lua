do
    local component_invoke = component.invoke
    local bpcall = function(address, method, ...)
        local success, result = pcall(component_invoke, address, method, ...)
        if not success then return nil, result
        else return success, result
        end
    end

    local cursor = {1, 1}
    local function status(text) -- status message
      gpu.set(cursor[1], cursor[2], text)
      cursor[2] = cursor[2] + 1
    end

    local current_fs_address = computer.getBootAddress()

    local function make_fs_directories()
        local fs_proxy = component.proxy(current_fs_address)
        local directories = {"/boot", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr"}
        for _, directory in pairs(directories)
        do
            fs_proxy.makeDirectory(directory)
            status("Created directory: " .. directory)
        end
    end

    local function donwload_os_files()
        local github_os_file_addresses = {["path"] = "address"} -- example {["/bin/ls.lua"] = "https://raw.githubusercontent.com/ocawesome101/awoo_os/main/src/bin/ls.lua"}

        local fs_proxy = component.proxy(current_fs_address)
        local internet = component.list("internet")()

        for path, address in pairs(github_os_file_addresses)
        do
            local success, internet_handle = bpcall(internet, "request", address)
            if not success then
                success, internet_handle = bpcall(internet, "request", address) -- try again
                if not success then error("Failed to request " .. address .. " from github: " .. internet_handle) end
            end

            local success, file_handle = bpcall(fs_proxy, "open", path, "w")
            if not success then
                success, file_handle = bpcall(fs_proxy, "open", path, "w") -- try again
                if not success then error("Failed to open " .. path .. " file: " .. file_handle) end
            end

            for chunk in internet_handle do file_handle:write(chunk) end
            status("Writed OS file: " .. path)
            file_handle:close()
        end
    end

    local function download_final_bootloader_and_setup_up_system()
        local github_final_bootloader_address = "..."

        local fs_proxy = component.proxy(current_fs_address)
        local internet = component.list("internet")()

        local success, internet_handle = bpcall(internet, "request", github_final_bootloader_address)
        if not success then
            success, internet_handle = bpcall(internet, "request", github_final_bootloader_address) -- try again
            if not success then error("Failed to request " .. github_final_bootloader_address .. " from github: " .. internet_handle) end
        end

        local final_bootloader_data = {}
        for chunk in internet_handle do table.insert(final_bootloader_data, chunk) end
        status("Downloaded final bootloader")
        component.list("eeprom")().set(final_bootloader_data)
        component.setBootAddress(current_fs_address)
        status("Setted final bootloader in eeprom")

        fs_proxy.remove("/installation.lua")
        status("Removed /installation.lua")
    end

    make_fs_directories()
    donwload_os_files()
    download_final_bootloader_and_setup_up_system()
    status("Installation completed")

    status("Shutting down computer")
    computer.shutdown(true)
end