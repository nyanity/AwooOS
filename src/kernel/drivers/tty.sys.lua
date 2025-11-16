local k_syscall = syscall
local gpu_address = env.gpu
local screen_address = env.screen
local my_pid
local ok_pid, pid_val = k_syscall("process_get_pid")
if ok_pid then my_pid = pid_val else my_pid = "UNKNOWN" end

if not gpu_address or not screen_address then
  k_syscall("kernel_panic", "TTY Driver started without GPU or Screen address.")
end

local tty = {}

local ok_gpu, gpu_p, err_gpu = k_syscall("raw_component_proxy", gpu_address)
if not ok_gpu then k_syscall("kernel_panic", "TTY driver failed to get GPU proxy: " .. tostring(err_gpu)) end
tty.gpu = gpu_p

local ok_screen, screen_p, err_screen = k_syscall("raw_component_proxy", screen_address)
if not ok_screen then k_syscall("kernel_panic", "TTY driver failed to get Screen proxy: " .. tostring(err_screen)) end
tty.screen = screen_p

k_syscall("kernel_log", string.format("[TTY PID %s] Proxies acquired. Sending 'driver_ready' NOW.", tostring(my_pid)))
k_syscall("signal_send", 2, "driver_ready", my_pid) 

tty.gpu.bind(screen_address)
tty.width, tty.height = tty.gpu.getResolution()
tty.gpu.fill(1, 1, tty.width, tty.height, " ")
tty.gpu.setForeground(0xEEEEEE)
tty.gpu.setBackground(0x000000)
tty.cursor_x = 1
tty.cursor_y = 1

function tty.scroll()
  tty.gpu.copy(1, 2, tty.width, tty.height - 1, 0, -1)
  tty.gpu.fill(1, tty.height, tty.width, 1, " ")
  tty.cursor_y = tty.height
end

function tty.write(text)
  for char in string.gmatch(text, ".") do
    if char == "\n" then
      tty.cursor_x = 1
      tty.cursor_y = tty.cursor_y + 1
    else
      tty.gpu.set(tty.cursor_x, tty.cursor_y, char)
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

local ok, boot_log = k_syscall("kernel_get_boot_log")
if ok and boot_log then
  tty.write(boot_log .. "\n")
end
tty.write("[Ring 2] TTY Driver initialized.\n")
k_syscall("kernel_log", "[TTY] Screen initialized. Entering main loop.")

while true do
  local syscall_ok, signal_ok, pm_pid, sig_name, p1, p2 = k_syscall("signal_pull")
  if syscall_ok and signal_ok then
    if sig_name == "tty_write" then
      tty.write(tostring(p2))
    elseif sig_name == "tty_read" then
      local original_sender_pid = p1
      local line = ""
      -- tty.screen.setCursorBlink(true)
      
      while true do
        local key_syscall_ok, key_signal_ok, key_sender, key_sig, event, addr, char, code = k_syscall("signal_pull")
        if key_syscall_ok and key_signal_ok and key_sig == "os_event" and event == "key_down" then
          if code == 28 then -- Enter
            -- tty.screen.setCursorBlink(false)
            tty.write("\n")
            k_syscall("signal_send", original_sender_pid, "syscall_return", true, line)
            break
          elseif code == 14 then -- Backspace
            if #line > 0 then
              line = string.sub(line, 1, -2)
              tty.cursor_x = tty.cursor_x - 1
              if tty.cursor_x < 1 then tty.cursor_x = 1 end
              tty.gpu.set(tty.cursor_x, tty.cursor_y, " ")
            end
          else
            if char and #char > 0 then
              line = line .. char
              tty.write(char)
            end
          end
        end
      end
    end
  end
end