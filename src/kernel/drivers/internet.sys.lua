local k_syscall = syscall
local my_pid = k_syscall("process_get_pid")

k_syscall("signal_send", 2, "driver_ready", my_pid)

while true do
  k_syscall("signal_pull")
end