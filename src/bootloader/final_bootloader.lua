  local boot
  do
    local component_invoke = component.invoke
    local function eeprom_invoke(address, method, ...) -- wrapper for pcall
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
  
    do -- bind gpu to screen
      local screen = component.list("screen")()
      local gpu = component.list("gpu")()
      if gpu and screen then eeprom_invoke(gpu, "bind", screen)
      else error() -- no error message because there is no gpu of screen lol
      end
    end
  
    local cursor = {1, 1}
    local function status(text) -- status message
      gpu.set(cursor[1], cursor[2], text)
      cursor[2] = cursor[2] + 1
    end
  
    local function try_load_from(fs_boot_address)
      local handle, reason = eeprom_invoke(fs_boot_address, "open", "/boot/boot.lua")
      if not handle then
        return nil, reason
      end
      local buffer = ""
      repeat
        local data, reason = eeprom_invoke(fs_boot_address, "read", handle, math.maxinteger or math.huge)
        if not data and reason then
          return nil, reason
        end
        buffer = buffer .. (data or "")
      until not data
      eeprom_invoke(fs_boot_address, "close", handle)
      return load(buffer, "=boot")
    end
  
    local fs_boot_address = computer.getBootAddress()
    if not fs_boot_address then error("No boot address found.") end
    status("Recived boot address: " .. fs_boot_address)
  
    local reason
    boot, reason = try_load_from(fs_boot_address)
    if not boot
    then
      error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
    end
    status("Installation function is loaded.")
  end
  return boot()