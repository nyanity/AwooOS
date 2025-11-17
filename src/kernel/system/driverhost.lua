--
-- /system/driverhost.lua
-- user mode driver host.
-- this is a ring 2.5 process that loads a single ring 3 driver (UMD),
-- supervises it, and acts as a secure proxy for any privileged operations
-- it needs to perform. it's a sandbox within a sandbox.
--

local krnlstatus = require("errcheck")

-- environment from pipeline manager
local sDriverPath = env.driver_path
local tComponentInfo = env.component_info
local nPipelineManagerPid = env.pm_pid
local nMyPid = syscall("process_get_pid")

if not sDriverPath or not nPipelineManagerPid then
  syscall("kernel_log", "[DriverHost] FATAL: Missing env variables.")
  return
end

syscall("kernel_log", "[DriverHost] Hosting UMD: " .. sDriverPath)

-- 1. Spawn the Ring 3 driver process
local nDriverPid, sSpawnErr = syscall("process_spawn", sDriverPath, 3, {
  component_info = tComponentInfo,
  pm_pid = nPipelineManagerPid,
  host_pid = nMyPid, -- CRITICAL: the UMD needs to know who its host is.
})

if not nDriverPid then
  syscall("kernel_log", "[DriverHost] Failed to spawn Ring 3 process for UMD: " .. sSpawnErr)
  syscall("signal_send", nPipelineManagerPid, "driver_load_result", sDriverPath, krnlstatus.STATUS_INSUFFICIENT_RESOURCES)
  return
end

syscall("kernel_log", "[DriverHost] UMD " .. sDriverPath .. " spawned as PID " .. nDriverPid)

-- 2. Create the Driver Object and call UMDriverEntry
local bCreateOk, nStatus, oDriverObject = syscall("driver_create_object", sDriverPath, nDriverPid)
if not (bCreateOk and nStatus == krnlstatus.STATUS_SUCCESS) then
  syscall("kernel_log", "[DriverHost] Kernel failed to create driver object.")
  syscall("signal_send", nPipelineManagerPid, "driver_load_result", sDriverPath, nStatus)
  return
end

-- tell the UMD process to start its initialization.
syscall("signal_send", nDriverPid, "umd_initialize", oDriverObject)

-- 3. Main loop: process RPC requests from our hosted UMD
while true do
  local bSyscallOk, bPullOk, nSender, sSignalName, tRequest = syscall("signal_pull")
  if bSyscallOk and bPullOk then
    if sSignalName == "umd_request" and nSender == nDriverPid then
      -- it's a request from our child. process it.
      local sType = tRequest.type
      local tPayload = tRequest.payload
      local nStatus, tData = krnlstatus.STATUS_NOT_IMPLEMENTED, nil

      if sType == "create_device" then
        bSyscallOk, nStatus, tData = syscall("driver_create_device", tPayload.driver_object, tPayload.device_type, tPayload.device_name)
      elseif sType == "create_symlink" then
        bSyscallOk, nStatus = syscall("driver_create_symlink", tPayload.link_name, tPayload.device_name)
      elseif sType == "complete_init" then
        -- this is a notification, not a request/reply
        syscall("signal_send", nPipelineManagerPid, "driver_load_result", sDriverPath, tPayload.status)
        if tPayload.status ~= krnlstatus.STATUS_SUCCESS then break end -- init failed, shut down
        goto continue -- skip reply
      elseif sType == "complete_request" then
        -- forward the IRP completion to the IO manager
        local oIrp = tPayload.irp
        syscall("signal_send", oIrp.nIoManagerPid, "irp_complete", {
          requester_pid = oIrp.nOriginalRequesterPid,
          request_id = oIrp.nOriginalRequestId,
          status = tPayload.status,
          info = tPayload.info,
        })
        nStatus = krnlstatus.STATUS_SUCCESS
      end
      
      -- send the reply back to the UMD
      syscall("signal_send", nDriverPid, "umd_reply", { status = nStatus, data = tData })

    elseif sSignalName == "umd_unload_request" then
      syscall("kernel_log", "[DriverHost] Received unload request for " .. nDriverPid)
      syscall("signal_send", nDriverPid, "umd_unload")
      syscall("driver_delete_object", oDriverObject)
      break
    end
    ::continue::
  end
end

syscall("kernel_log", "[DriverHost] Shutting down for driver: " .. sDriverPath)