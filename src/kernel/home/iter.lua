--
-- /lib/iter.lua
-- User-space library for controlling the ITER Fusion Reactor.
-- This is the safe, friendly remote control. The driver is the guy in the
-- blast suit flipping the actual switches.
--

local oFs = require("filesystem")
if not oFs then error("Filesystem library not available!") end

local oIterApi = {}

-- The reactor device path in the VFS.
local sDevicePath = "/dev/fusion0"

--[[
  Connects to the ITER driver.
  @return table A handle to the reactor, or nil and an error message.
]]
function oIterApi.open()
  local hDevice, sErr = oFs.open(sDevicePath, "r") -- mode doesn't matter much here
  if not hDevice then
    return nil, "Failed to open ITER device: " .. tostring(sErr)
  end
  
  local tReactorHandle = {
    _handle = hDevice,
  }
  
  -- This is the magic function that sends a command to the driver.
  -- It uses a hypothetical fs.deviceControl, which would map to IRP_MJ_DEVICE_CONTROL.
  -- Your VFS would need to implement this.
  function tReactorHandle:invoke(sMethod, ...)
    if not self._handle then return nil, "Handle is closed" end
    -- The fs.deviceControl function is the user-space bridge to the driver's
    -- fDispatchDeviceControl handler.
    local bOk, tResult, sError = oFs.deviceControl(self._handle, sMethod, {...})
    if bOk then
      return table.unpack(tResult or {})
    else
      return nil, sError
    end
  end
  
  -- Close the connection to the driver.
  function tReactorHandle:close()
    if self._handle then
      oFs.close(self._handle)
      self._handle = nil
    end
  end
  
  -- Helper methods that map directly to the component's API.
  function tReactorHandle:getEnergy() return self:invoke("getEnergyInfo") end
  function tReactorHandle:isActive() return self:invoke("isActive") end
  function tReactorHandle:setActive(bState) return self:invoke("setActive", bState) end
  function tReactorHandle:getFluids() return self:invoke("getFluid") end
  function tReactorHandle:getPlasmaTemp() return self:invoke("getPlasmaTemp") end
  function tReactorHandle:getMaxTemp() return self:invoke("getMaxTemp") end
  function tReactorHandle:getBlanketDamage() return self:invoke("getBlanketDamage") end
  
  setmetatable(tReactorHandle, { __gc = function(self) self:close() end })
  
  return tReactorHandle
end

return oIterApi