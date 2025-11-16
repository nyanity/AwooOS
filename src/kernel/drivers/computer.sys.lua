local k_syscall = syscall
local my_pid = k_syscall("process_get_pid")

k_syscall("signal_send", 2, "driver_ready", my_pid)

while true do
  local ok, sig_name, sender_pid, command = k_syscall("signal_pull")
  
  if ok then
    if sig_name == "computer_control" then
      if command == "reboot" then
        k_syscall("computer_reboot")
      elseif command == "shutdown" then
        k_syscall("computer_shutdown")
      end
    end
  end
end