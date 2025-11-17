--
-- /system/lib/dk/common_api.lua
-- functions for every driver, whether you're a god-tier kernel driver
-- or a humble user-mode peasant.
--

local fSyscall = syscall
local oDK = {}

-- the one true print function for drivers.
-- it's just a wrapper around the kernel log, but it feels more official.
function oDK.DkPrint(sMessage)
  fSyscall("kernel_log", "[DK] " .. tostring(sMessage))
end

return oDK