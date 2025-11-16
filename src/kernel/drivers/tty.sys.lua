local k_syscall = syscall
local gpu_address = env.gpu
local screen_address = env.screen

if not gpu_address or not screen_address then
  k_syscall("kernel_panic", "TTY Driver started without GPU or Screen address.")
end

local ok, gpu_proxy, err = k_syscall("raw_component_proxy", gpu_address)
if not ok then
  k_syscall("kernel_panic", "TTY driver failed to get GPU proxy: " .. tostring(err))
end

local ok, screen_proxy, err = k_syscall("raw_component_proxy", screen_address)
if not ok then
  k_syscall("kernel_panic", "TTY driver failed to get Screen proxy: " .. tostring(err))
end

local tty = {}
gpu_proxy.bind(screen_address)
tty.width, tty.height = gpu_proxy.getResolution()
gpu_proxy.fill(1, 1, tty.width, tty.height, " ")
gpu_proxy.setForeground(0xEEEEEE)
gpu_proxy.setBackground(0x000000)
tty.cursor_x = 1
tty.cursor_y = 1

function tty.scroll()
  gpu_proxy.copy(1, 2, tty.width, tty.height - 1, 0, -1)
  gpu_proxy.fill(1, tty.height, tty.width, 1, " ")
  tty.cursor_y = tty.height
end

function tty.write(text)
  for char in string.gmatch(text, ".") do
    if char == "\n" then
      tty.cursor_x = 1
      tty.cursor_y = tty.cursor_y + 1
    else
      gpu_proxy.set(tty.cursor_x, tty.cursor_y, char)
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
  -- empty here no1wspqmwifjwai
end

-- Read and print the kernel boot log
local ok, boot_log = k_syscall("kernel_get_boot_log")
if ok and boot_log then
  tty.write(boot_log .. "\n")
end

tty.write("[Ring 2] TTY Driver initialized.\n")
k_syscall("signal_send", 2, "driver_ready") 

-- Main driver loop
while true do
  -- unpacking the signal more efficiently
  local ok, sender_pid, sig_name, data = k_syscall("signal_pull")
  
  if ok then
    if sig_name == "tty_write" then
      tty.write(tostring(data))
    
    elseif sig_name == "tty_read" then
      local line = ""
      gpu_proxy.setCursorBlink(true)
      
      while true do
        -- here too
        local key_ok, key_sender, key_sig, event, addr, char, code = k_syscall("signal_pull")
        if key_ok and key_sig == "os_event" and event == "key_down" then
          if code == 28 then -- Enter
            gpu_proxy.setCursorBlink(false)
            tty.write("\n")
            -- answering someone who called 📞📞📞
            k_syscall("signal_send", sender_pid, "syscall_return", true, line)
            break
          elseif code == 14 then -- Backspace
            if #line > 0 then
              line = string.sub(line, 1, -2)
              tty.cursor_x = tty.cursor_x - 1
              if tty.cursor_x < 1 then tty.cursor_x = 1 end
              gpu_proxy.set(tty.cursor_x, tty.cursor_y, " ")
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