    
local k_syscall = syscall
local my_address = env.address
local my_pid = k_syscall("process_get_pid")

k_syscall("signal_send", 2, "driver_ready", my_pid)

while true do
  local returns = table.pack(k_syscall("signal_pull"))
  local ok = returns[1]
  local sig_name = returns[2]
  
  if ok and sig_name == "gpu_invoke" then
    local sender_pid = returns[3]
    local method = returns[4]
    local ok_invoke, ret1, ret2 = k_syscall("raw_component_invoke", my_address, method, table.unpack(returns, 5, returns.n))
    
    k_syscall("signal_send", sender_pid, "gpu_return", ok_invoke, ret1, ret2)
  end
end

  