    
local k_syscall = syscall
local my_address = env.address
-- Получаем свой PID, чтобы правильно отправлять сигналы
local my_pid = k_syscall("process_get_pid")

-- Отправляем сигнал о готовности, включая свой PID
k_syscall("signal_send", 2, "driver_ready", my_pid)

while true do
  -- Правильный способ получить переменное число возвращаемых значений - упаковать их в таблицу
  local returns = table.pack(k_syscall("signal_pull"))
  local ok = returns[1]
  local sig_name = returns[2]
  
  if ok and sig_name == "gpu_invoke" then
    local sender_pid = returns[3]
    local method = returns[4]
    
    -- Правильно извлекаем все остальные аргументы для вызова метода компонента
    local ok_invoke, ret1, ret2 = k_syscall("raw_component_invoke", my_address, method, table.unpack(returns, 5, returns.n))
    
    k_syscall("signal_send", sender_pid, "gpu_return", ok_invoke, ret1, ret2)
  end
end

  