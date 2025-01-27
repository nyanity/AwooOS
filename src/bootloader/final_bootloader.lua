local boot
do
  local component_invoke = component.invoke
  local function eeprom_invoke(address, method, ...)
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
  
  do
    local screen = component.list("screen")()
    local gpu = component.list("gpu")()
    if gpu and screen then eeprom_invoke(gpu, "bind", screen)
    else error()
    end
  end
  
  local function try_load_from(fs_boot_address)
    local reason, handle = eeprom_invoke(fs_boot_address, "open", "/boot/boot.lua")
    if not reason then
      return nil, reason
    end
    local buffer = ""
    repeat
      local reason, data = eeprom_invoke(fs_boot_address, "read", handle, math.maxinteger or math.huge)
      if not reason then
        return nil, reason
      end
      buffer = buffer .. (data or "")
    until not data
    eeprom_invoke(fs_boot_address, "close", handle)
    return load(buffer, "=boot")
  end
  
  -- get boot address
  local sucess, bt_addr = computer.getBootAddress()
  if not sucess then error("No boot address found: " .. bt_addr) end
  
  local reason
  boot, reason = try_load_from(bt_addr)
  if not boot
  then
    error("no bootable medium found" .. (reason and (": " .. tostring(reason)) or ""), 0)
  end
end
return boot()