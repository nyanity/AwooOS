--
-- /lib/pipeline_manager.lua
-- now just a bootstrapper. its job is to start the real managers,
-- set up the basic vfs, and then get out of the way.
--

local syscall = syscall

syscall("kernel_register_pipeline")
syscall("kernel_log", "[PM] Ring 1 Pipeline Manager started.")

-- spawn the real heroes
local bDkmsOk, nDkmsPid = syscall("process_spawn", "/system/dkms.lua", 1)
if not bDkmsOk then syscall("kernel_panic", "Could not spawn DKMS!") end
syscall("kernel_log", "[PM] DKMS process started as PID " .. tostring(nDkmsPid))

-- local bUmdhOk, nUmdhPid = syscall("process_spawn", "/system/umdh.lua", 3)
-- if not bUmdhOk then syscall("kernel_panic", "Could not spawn UMDH!") end
-- syscall("kernel_log", "[PM] UMDH process started as PID " .. nUmdhPid)

local vfs_state = {
  tMounts = {},
  oRootFs = nil,
  nNextFd = 1,
  tOpenHandles = {},
}

-- we still handle the vfs syscalls, but now we're just a router.
-- if it's a normal file, we handle it. if it's a device, we pass it to DKMS.
function vfs_state.syscall_open(nSenderPid, sPath, sMode)
  -- is this a device file? let's ask DKMS if it knows about this path.
  -- for now, we'll just check for /dev/
  if string.sub(sPath, 1, 5) == "/dev/" then
    syscall("kernel_log", "[PM-VFS] Path '" .. sPath .. "' is a device. Forwarding to DKMS.")
    local tDKStructs = require("/system/lib/dk/shared_structs")
    local pIrp = tDKStructs.fNewIrp(tDKStructs.IRP_MJ_CREATE)
    pIrp.sDeviceName = g_tSymbolicLinks[sPath] -- this is a problem, PM doesn't know this. HACK:
    pIrp.sDeviceName = "\\Device\\TTY0" -- we have to know the target device name. this is a flaw.
    pIrp.nSenderPid = nSenderPid
    pIrp.tParameters.sMode = sMode
    
    syscall("signal_send", nDkmsPid, "vfs_io_request", pIrp)
    return "async_wait" -- tell the kernel we're waiting
  end
  
  -- otherwise, it's a normal file on the root fs
  local bOk, hHandle, sReason = syscall("raw_component_invoke", vfs_state.oRootFs.address, "open", sPath, sMode)
  if not hHandle then return nil, sReason end
  
  local nFd = vfs_state.nNextFd; vfs_state.nNextFd = vfs_state.nNextFd + 1
  -- ... standard file handle creation ...
  return nFd
end

-- other vfs functions (read, write, etc.) would have similar logic:
-- check if handle is a device handle or file handle, then route accordingly.

-- this is now a huge simplification. we just tell DKMS to do the work.
local function __scandrvload()
  syscall("kernel_log", "[PM] Scanning for components...")
  
  local bOk, sRootUuid, oRootProxy = syscall("kernel_get_root_fs")
  if not bOk then syscall("kernel_panic", "Pipeline could not get root FS info from kernel.") end
  vfs_state.oRootFs = oRootProxy
  
  local bListOk, tCompList = syscall("raw_component_list")
  if not bListOk then return end
  
  for sAddr, sCtype in pairs(tCompList) do
    syscall("kernel_log", "[PM] Found component '" .. sCtype .. "'. Telling DKMS to load driver.")
    syscall("signal_send", nDkmsPid, "load_driver_for_component", sCtype, sAddr)
  end
end

__scandrvload()

syscall("kernel_log", "[PM] Initial scan complete. Handing off to DKMS. Idling.")

-- the pipeline manager's main job is done. it just sits here now.
while true do
  syscall("signal_pull")
end