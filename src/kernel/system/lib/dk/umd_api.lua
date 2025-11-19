--
-- /system/lib/dk/umd_api.lua
-- the user-mode driver api. you live in a little box and you'll be happy about it.
-- no direct hardware access for you. talk to your host process.
--

local fSyscall = syscall
local tStatus = require("errcheck")
local oUMD = require("common_api") -- inherit common functions

-- for a UMD, all "privileged" operations are just signals to the UMDH process.

function oUMD.UmdCompleteRequest(pIrp, nStatus, vInformation)
  pIrp.tIoStatus.nStatus = nStatus
  pIrp.tIoStatus.vInformation = vInformation
  -- we can't call the kernel directly. we send a signal to our host,
  -- and the host will complete the request for us.
  fSyscall("signal_send", env.nHostPid, "umd_complete_irp", pIrp)
end

-- UMDs can't create devices or links. this is done by a higher-level manager.
-- these functions are intentionally left out. trying to call them would be an error.

return oUMD