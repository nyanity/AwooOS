--
-- dk/error_checker.lua
-- the bouncer at the driver club.
-- checks if a driver is properly dressed before letting it in.
--

local oDkCommon = require("dk/common")
local oErrorChecker = {}

-- validates the entire driver module table before we even think about running it.
function oErrorChecker.fValidateDriverObject(tDriverModule)
  if type(tDriverModule) ~= "table" then
    return false, "Driver file did not return a table."
  end

  -- 1. Check for DriverEntry
  if not tDriverModule.DriverEntry or type(tDriverModule.DriverEntry) ~= "function" then
    return false, "DriverEntry function not found or is not a function."
  end

  -- 2. Check for DriverExit
  if not tDriverModule.DriverExit or type(tDriverModule.DriverExit) ~= "function" then
    return false, "DriverExit function not found or is not a function."
  end

  -- 3. Check for DRIVER_PROPERTIES
  local tProps = tDriverModule.DRIVER_PROPERTIES
  if not tProps or type(tProps) ~= "table" then
    return false, "DRIVER_PROPERTIES table not found."
  end

  -- 4. Validate properties content
  if not tProps.sName or type(tProps.sName) ~= "string" then
    return false, "DRIVER_PROPERTIES.sName is missing or invalid."
  end

  if tProps.nType == nil or not (tProps.nType == oDkCommon.DRIVER_TYPE.KMD or tProps.nType == oDkCommon.DRIVER_TYPE.UMD or tProps.nType == oDkCommon.DRIVER_TYPE.DKMS) then
    return false, "DRIVER_PROPERTIES.nType is missing or invalid."
  end

  if tProps.nPriority == nil or type(tProps.nPriority) ~= "number" then
    return false, "DRIVER_PROPERTIES.nPriority is missing or invalid."
  end

  -- all checks passed. the driver looks legit.
  return true, "Validation successful."
end

return oErrorChecker