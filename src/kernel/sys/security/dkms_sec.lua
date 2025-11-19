--
-- /sys/security/dkms_sec.lua
-- the bouncer at the club door for drivers.
-- checks if a driver looks legit before we even think about loading it.
--

local tStatus = require("errcheck")
local tDKStructs = require("shared_structs")
local oSec = {}

-- right now, our security is... trusting.
-- in the future, this could check signatures, hashes, or a list of trusted developers.
function oSec.fValidateDriverSignature(sDriverCode)
  -- for now, all drivers are trusted. what could go wrong?
  return tStatus.STATUS_SUCCESS
end

-- checks the g_tDriverInfo table for basic sanity.
function oSec.fValidateDriverInfo(tDriverInfo)
  if type(tDriverInfo) ~= "table" then
    return tStatus.STATUS_INVALID_DRIVER_INFO, "g_tDriverInfo is not a table"
  end
  if type(tDriverInfo.sDriverName) ~= "string" or #tDriverInfo.sDriverName == 0 then
    return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing or invalid sDriverName"
  end
  if type(tDriverInfo.sDriverType) ~= "string" then
    return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing sDriverType"
  end
  
  -- check against the holy trinity of driver types
  if tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_KMD and 
     tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_UMD and
     tDriverInfo.sDriverType ~= tDKStructs.DRIVER_TYPE_CMD then
    return tStatus.STATUS_INVALID_DRIVER_TYPE, "Unknown sDriverType: " .. tostring(tDriverInfo.sDriverType)
  end
  
  if type(tDriverInfo.nLoadPriority) ~= "number" then
    return tStatus.STATUS_INVALID_DRIVER_INFO, "Missing or invalid nLoadPriority"
  end
  
  return tStatus.STATUS_SUCCESS
end

return oSec