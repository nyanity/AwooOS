local k_syscall = syscall
local gpu_address = env.gpu
local screen_address = env.screen
local my_pid = k_syscall("process_get_pid")

if not gpu_address or not screen_address then
  k_syscall("kernel_panic", "TTY Driver started without GPU or Screen address.")
end

local ok_gpu, proxy_gpu = k_syscall("raw_component_proxy", gpu_address)
if not ok_gpu or not proxy_gpu then k_syscall("kernel_panic", "TTY driver failed to get GPU proxy.") end

local ok_screen, proxy_screen = k_syscall("raw_component_proxy", screen_address)
if not ok_screen or not proxy_screen then k_syscall("kernel_panic", "TTY driver failed to get Screen proxy.") end

local tty = {}
k_syscall("raw_component_invoke", gpu_address, "bind", screen_address)
local syscall_ok, invoke_ok, w, h = k_syscall("raw_component_invoke", gpu_address, "getResolution")
if not (syscall_ok and invoke_ok) then
  k_syscall("kernel_panic", "TTY: Failed to get screen resolution.")
end
tty.width, tty.height = w, h
k_syscall("raw_component_invoke", gpu_address, "fill", 1, 1, tty.width, tty.height, " ")
k_syscall("raw_component_invoke", gpu_address, "setForeground", 0xEEEEEE)
k_syscall("raw_component_invoke", gpu_address, "setBackground", 0x000000)
tty.cursor_x = 1
tty.cursor_y = 1

function tty.scroll()
  local returns = {k_syscall("raw_component_invoke", gpu_address, "copy", 1, 2, tty.width, tty.height - 1, 0, -1)}
  if not (returns[1] and returns[2]) then
    k_syscall("kernel_log", "[TTY-ERROR] gpu.copy failed: " .. tostring(returns[3]))
  end
  
  returns = {k_syscall("raw_component_invoke", gpu_address, "fill", 1, tty.height, tty.width, 1, " ")}
  if not (returns[1] and returns[2]) then
    k_syscall("kernel_log", "[TTY-ERROR] gpu.fill failed: " .. tostring(returns[3]))
  end
  
  tty.cursor_y = tty.height
end

function tty.write(text)
  for char in string.gmatch(tostring(text), ".") do
    if char == "\n" then
      tty.cursor_x = 1
      tty.cursor_y = tty.cursor_y + 1
    else
      local returns = {k_syscall("raw_component_invoke", gpu_address, "set", tty.cursor_x, tty.cursor_y, tostring(char))}
      local ok_syscall = returns[1]
      local ok_invoke = returns[2]
      
      if not (ok_syscall and ok_invoke) then
        local err_msg = returns[3]
        k_syscall("kernel_log", "[TTY-ERROR] gpu.set failed: " .. tostring(err_msg))
      end
      
      tty.cursor_x = tty.cursor_x + 1
      if tty.cursor_x > tty.width then
        tty.cursor_x = 1
        tty.cursor_y = tty.cursor_y + 1
      end
    end
    if tty.cursor_y > tty.height then
      tty.scroll()
    end
  end
end

local state = {
  mode = "idle", -- "idle"/"reading"
  read_requester_pid = nil,
  line_buffer = ""
}

k_syscall("kernel_log", "[TTY PID " .. tostring(my_pid) .. "] Initialized. Sending 'driver_ready'.")
k_syscall("signal_send", 2, "driver_ready", tostring(my_pid)) 

while true do
  local syscall_ok, pull_ok, sender_pid, sig_name, p1, p2, p3, p4 = k_syscall("signal_pull")

  if pull_ok then
    k_syscall("kernel_log", string.format("[TTY-DEBUG] Pulled signal: '%s' from PID %s", tostring(sig_name), tostring(sender_pid)))
  end

  if syscall_ok and pull_ok then
    
    if sig_name == "tty_write" then
      local data = p2
      tty.write(tostring(data))
    
    elseif sig_name == "tty_read" then
      if state.mode == "idle" then
        state.mode = "reading"
        state.read_requester_pid = p1
        state.line_buffer = ""
      else
        k_syscall("signal_send", p1, "syscall_return", false, "TTY busy")
      end

    elseif sig_name == "os_event" then
      local event_name = p1
      if event_name == "key_down" and state.mode == "reading" then
        local char = p3
        local code = p4
        
        if code == 28 then -- Enter
          tty.write("\n")
          k_syscall("signal_send", state.read_requester_pid, "syscall_return", true, state.line_buffer)
          state.mode = "idle"
          state.read_requester_pid = nil
          
        elseif code == 14 then -- Backspace
          if #state.line_buffer > 0 then
            state.line_buffer = string.sub(state.line_buffer, 1, -2)
            tty.cursor_x = tty.cursor_x - 1
            if tty.cursor_x < 1 then tty.cursor_x = 1 end
            k_syscall("raw_component_invoke", gpu_address, "set", tty.cursor_x, tty.cursor_y, " ")
          end
        else
          if char and #char > 0 then
            state.line_buffer = state.line_buffer .. char
            tty.write(char)
          end
        end
      end
    end
  end
end