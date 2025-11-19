--
-- /system/lib/dk/shared_structs.lua
-- the blueprints for our driver model.
-- these are the lego bricks that every driver is built from.
--

local oDK = {}

-- IRP Major Function Codes
-- basically, "what kind of job is this?"
oDK.IRP_MJ_CREATE = 0x00
oDK.IRP_MJ_CLOSE = 0x02
oDK.IRP_MJ_READ = 0x03
oDK.IRP_MJ_WRITE = 0x04
oDK.IRP_MJ_DEVICE_CONTROL = 0x0E

-- Driver Types
oDK.DRIVER_TYPE_KMD = "KernelModeDriver"    -- Ring 0-2, full power, god mode enabled
oDK.DRIVER_TYPE_UMD = "UserModeDriver"      -- Ring 3, sandboxed, playing with plastic toys
oDK.DRIVER_TYPE_CMD = "ComponentModeDriver" -- Ring 2, strict hardware binding. no address? no entry.

oDK.IRP_FLAG_NO_REPLY = 0x10

-- The DRIVER_OBJECT
-- this is the driver's soul. it represents the loaded driver image.
function oDK.fNewDriverObject()
  return {
    sDriverPath = nil,         -- path to the driver file
    nDriverPid = nil,          -- the PID of the process running the driver code
    pDeviceObject = nil,       -- linked list of devices this driver owns
    fDriverUnload = nil,       -- the function to call when unloading
    tDispatch = {},            -- the table of IRP handlers (e.g., [IRP_MJ_READ] = fMyReadFunc)
    tDriverInfo = {},          -- a copy of the driver's static info table
  }
end

-- The DEVICE_OBJECT
-- this represents a thing the driver controls. a virtual tty, a gpu, a file system...
function oDK.fNewDeviceObject()
  return {
    pDriverObject = nil,       -- back-pointer to the driver that owns this
    pNextDevice = nil,         -- for the linked list of devices
    sDeviceName = nil,         -- e.g., "\\Device\\Serial0"
    pDeviceExtension = {},     -- a scratchpad for the driver to store its own state
    nFlags = 0,
  }
end

-- The IRP (I/O Request Packet)
-- a little packet of work. a "please do this" note passed to the driver.
function oDK.fNewIrp(nMajorFunction)
  return {
    nMajorFunction = nMajorFunction,
    pDeviceObject = nil,
    tParameters = {},          -- arguments for the operation (e.g., buffer for read, data for write)
    tIoStatus = {
      nStatus = 0,             -- will be filled with a STATUS_ code
      vInformation = nil,      -- return value (e.g., bytes read)
    },
    nSenderPid = nil,          -- who originally sent this request?
    nFlags = 0
  }
end

return oDK