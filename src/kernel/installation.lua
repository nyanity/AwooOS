local component = component
local computer = computer
local filesystem = filesystem  -- Access the filesystem API (available at boot)

-- Enhanced status function with memory address and component type logging.
local status = function(...) end
local cursor_y = 1

do
  local gpu_list = component.list("gpu")
  local gpu_address = nil
  for address, component_type in gpu_list do
    if component_type == "gpu" then
      gpu_address = address
      break
    end
  end

  if gpu_address then
    local gpu = component.proxy(gpu_address)  -- Use proxy for direct component access.
    if cpcall(gpu, "getScreen") ~= nil then
      status = function(text)
        -- Example:  [0x00001234, gpu]: Setting text at (1, 1):  ...
        local log_msg = string.format("[%s, %s]: Setting text at (1, %d): %s", tostring(gpu), "gpu", cursor_y, text)
        cpcall(gpu, "set", 1, cursor_y, text)  -- We assume the first GPU. More robust handling possible.
        cursor_y = cursor_y + 1
        print(log_msg) --  ALSO print to console for full verbosity.
      end
    end
  else
      print("No GPU found. Status messages will be sent to standard output (print).")
      status = function (msg)
        print("[INSTALLER] " .. msg)
      end
  end
end


local err = nil

local bt_addr = computer.getBootAddress()
err = get_last_error()
if err then error("/installation.lua: No boot address found: " .. err) end
status(string.format("Boot address retrieved: %s", bt_addr))

local boot_fs = filesystem.proxy(bt_addr)  -- Get a filesystem proxy.

local directories = {"/boot", "/bin", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr", "proc/", "proc/core"}
for _, directory in ipairs(directories) do
  status(string.format("Creating directory: %s", directory))
  local ok, res = cpcall(boot_fs, "makeDirectory", directory)  -- Use the filesystem proxy.
  err = get_last_error()
  if not ok or err then error(string.format("/installation.lua: Failed to create directory '%s': %s", directory, err or res)) end
  status(string.format("Directory created: %s [Result: %s]", directory, tostring(ok)))  -- Log result.
end

local os_files = {
  ["final_bootloader.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/bootloader/",
  ["/boot/boot.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["/bin/shell.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["lib/filesystem.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["lib/require.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["lib/sha256.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["proc/core/kernel.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["proc/core/usermode.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["proc/core/pipes.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
  ["usr/help.lua"] = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/kernel/",
}

local internet_list = component.list("internet")
local internet_address = nil

for address, component_type in internet_list do
  if component_type == "internet" then
      internet_address = address
      break
  end
end

if not internet_address then
  error("No internet card found!")
end

local internet = component.proxy(internet_address)  -- Get a proxy for the internet card.

for path, url in pairs(os_files) do
  local full_url = url .. path
  status(string.format("Requesting file: %s from %s", path, full_url))
  local ok, request = cpcall(internet, "request", full_url)
  err = get_last_error()
  if not ok or err then error(string.format("Failed to request %s: %s", full_url, err or request)) end

  if path == "final_bootloader.lua" then
    local final_data = ""
    status("Downloading final bootloader...")
    while true do
      local chunk = request.read()
      if not chunk then break end
      final_data = final_data .. chunk
    end
    status("Downloaded final bootloader. Total size: " .. #final_data .. " bytes")

    local eeprom_list = component.list("eeprom")
    local eeprom_address = nil
      for address, comp_type in eeprom_list do
        if comp_type == "eeprom" then
          eeprom_address = address
          break
        end
      end

      if not eeprom_address then
        error("No EEPROM found!")
      end
    local eeprom = component.proxy(eeprom_address)
    status(string.format("Writing final bootloader to EEPROM [%s]...", eeprom_address))
    local ok, res = cpcall(eeprom, "set", final_data)
    err = get_last_error()
    if not ok or err then error(string.format("Failed to set final bootloader into EEPROM: %s", err or res)) end
    status("Wrote final bootloader into EEPROM.")

    computer.setBootAddress(bt_addr)
    status(string.format("Boot address set to: %s", bt_addr))
  else
    status(string.format("Opening file for writing: %s", path))
    local ok, handle = cpcall(boot_fs, "open", path, "w")  -- Open using the filesystem proxy.
    err = get_last_error()
    if not ok or err then error(string.format("Failed to open '%s' for writing: %s", path, err or handle)) end
    status(string.format("File opened.  Handle: %s", tostring(handle)))

    status(string.format("Downloading and writing: %s", path))
    local bytes_written = 0
    while true do
      local chunk = request.read()
      if not chunk then break end
      local ok, res = cpcall(boot_fs, "write", handle, chunk)
      err = get_last_error()
      if not ok or err then error(string.format("Failed to write to '%s': %s", path, err or res)) end
      bytes_written = bytes_written + #chunk
    end
    status(string.format("Downloaded and wrote %d bytes to '%s'", bytes_written, path))

    status(string.format("Closing file: %s", path))
    local ok, res = cpcall(boot_fs, "close", handle)
    err = get_last_error()
    if not ok or err then error(string.format("Failed to close '%s': %s", path, err or res)) end
      status("File closed")
  end
  if request.close then
    request.close()  -- Ensure request is closed (if it has a close method, as http requests do)
  end
end

status(string.format("Removing installation script: /installation.lua"))
local ok, res = cpcall(boot_fs, "remove", "/installation.lua")
err = get_last_error()
if not ok or err then error(string.format("Failed to remove /installation.lua: %s", err or res)) end
status("Installation script removed.")

status("Installation completed successfully.")