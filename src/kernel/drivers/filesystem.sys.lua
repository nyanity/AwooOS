local k_syscall = syscall
local ok, my_pid = k_syscall("process_get_pid")
if not ok then my_pid = "UNKNOWN" end

-- ...

k_syscall("signal_send", 2, "driver_ready", my_pid)

while true do
  local ok, sig = k_syscall("signal_pull")
  -- Just idle.
end