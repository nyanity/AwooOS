--
-- /lib/dk/common.lua
-- the holy scripture for drivers.
-- contains all the shared constants, statuses, and types.
-- if you're writing a driver, you include this. no exceptions.
-- like ntstatus.h or errno.h, but for lua.
--

local oDkCommon = {}

--
-- NTSTATUS-like codes
--
oDkCommon.STATUS_SUCCESS = 0x00000000
oDkCommon.STATUS_FAILURE = 0xC0000001
oDkCommon.STATUS_INVALID_PARAMETER = 0xC000000D
oDkCommon.STATUS_DEVICE_NOT_FOUND = 0xC00000E1
oDkCommon.STATUS_INSUFFICIENT_RESOURCES = 0xC000009A
oDkCommon.STATUS_ACCESS_DENIED = 0xC0000022
oDkCommon.STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034
oDkCommon.STATUS_REJECTED = 0xFF000001 -- custom: driver structure invalid

--
-- Driver Types
-- defines the execution context and available APIs for a driver.
--
oDkCommon.DRIVER_TYPE = {
  KMD = 0, -- Kernel Mode Driver (Ring 2). has privileged access.
  UMD = 1, -- User Mode Driver (Ring 3). sandboxed, uses IPC to talk to KMDs.
  DKMS = 2, -- Dynamic Kernel Module Service (Ring 2). not tied to hardware, provides a service.
}

--
-- Driver Load Priority
-- determines the loading order. critical drivers go first.
--
oDkCommon.DRIVER_PRIORITY = {
  BOOT = 0, -- Filesystem, TTY, essential boot drivers.
  SYSTEM = 100, -- Core system devices (e.g., network cards).
  NORMAL = 200, -- Standard peripherals.
  OPTIONAL = 300, -- Non-essential stuff.
}

return oDkCommon