local k_syscall = syscall
local my_address = env.address

-- This driver is simple because the Pipeline (Ring 1)
-- is already doing raw_component_invoke on the FS.
-- If we wanted full VFS, the pipeline would send
-- IPC messages here instead.
-- For this design, this driver is mostly a stub.

k_syscall("signal_send", 2, "driver_ready", k_syscall("process_get_ring"))

while true do
  local ok, sig = k_syscall("signal_pull")
  -- Just idle.
end
