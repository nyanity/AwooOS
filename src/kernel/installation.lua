local status = function(...) end
local cursor_y = 1
do
  local gpu = component.list("gpu")()
  if cpcall(gpu, "getScreen") ~= nil
  then
    status = function(text)
      cpcall(gpu, "set", 1, cursor_y, text)
      cursor_y = cursor_y + 1
    end
  end
end

local err = nil

local bt_addr = computer.getBootAddress()
err = get_last_error()
if err then error("/installation.lua: No boot address found: " .. err) end
status("Get boot address: " .. bt_addr)

local directories = {"/boot", "/bin", "/dev", "/etc", "/home", "/lib", "/mnt", "/tmp", "/usr", "proc/", "proc/core"}
for _, directory in ipairs(directories) do
  cpcall(bt_addr, "makeDirectory", directory)
  err = get_last_error()
  if err then error("/installation.lua: Failed to create directory '" .. directory .. "': " .. err) end
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

local internet = component.list("internet")()

for path, url in pairs(os_files) do
  local request = cpcall(internet, "request", url .. path)
  err = get_last_error()
  if err then error("Failed to request " .. url .. ": " .. err) end

  if path == "final_bootloader.lua"
  then
    local final_data = ""
    while true do
      local chunk = request.read()
      if not chunk then break end
      final_data = final_data .. chunk
    end

    status("Downloaded final bootloader")

    local eeprom = component.list("eeprom")()
    cpcall(eeprom, "set", final_data)
    err = get_last_error()
    if err then error("Failed to set final bootloader into eeprom: " .. err) end

    status("Wrote final bootloader into EEPROM")

    computer.setBootAddress(bt_addr)
  else
    local handle= cpcall(bt_addr, "open", path, "w")
    err = get_last_error()
    if err then error("Failed to open '" .. path .. "' for writing: " .. err) end

    status("Opened '" .. path .. "' for writing")

    while true do
      local chunk = request.read()
      if not chunk then break end
      cpcall(bt_addr, "write", handle, chunk)
      err = get_last_error()
      if err then error("Failed to write to '" .. path .. "': " .. err) end
    end

    status("Wrote to '" .. path .. "'")

    cpcall(bt_addr, "close", handle)
    err = get_last_error()
    if err then error("Failed to close to '" .. path .. "': " .. err) end
  end
end

cpcall(bt_addr, "remove", "/installation.lua")
err = get_last_error()
if err then error("Failed to remove /installation.lua: " .. err) end

status("Installation completed")
