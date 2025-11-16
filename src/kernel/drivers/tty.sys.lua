
local k_syscall = syscall
local my_address = env.address
local gpu_address = nil

-- Получаем прокси для самого TTY
local ok, tty_proxy, err = k_syscall("raw_component_proxy", my_address)
if not ok then
  k_syscall("kernel_panic", "TTY driver failed to get its own proxy: " .. tostring(err))
end

-- Ищем и получаем прокси для GPU
local ok, list = k_syscall("raw_component_list", "gpu")
if ok then
  for addr, _ in pairs(list) do
    gpu_address = addr
    break
  end
end

if not gpu_address then
  k_syscall("kernel_panic", "TTY driver cannot find a GPU")
end

local ok, gpu_proxy, err = k_syscall("raw_component_proxy", gpu_address)
if not ok then
  k_syscall("kernel_panic", "TTY driver failed to get GPU proxy: " .. tostring(err))
end


-- Инициализация
local tty = {}
gpu_proxy.bind(my_address)
tty.width, tty.height = gpu_proxy.getResolution()
gpu_proxy.fill(1, 1, tty.width, tty.height, " ")
gpu_proxy.setForeground(0xEEEEEE)
gpu_proxy.setBackground(0x000000)
tty.cursor_x = 1
tty.cursor_y = 1

-- Теперь вместо gpu_proxy.call("method", ...) можно писать просто gpu_proxy.method(...)

function tty.scroll()
  gpu_proxy.copy(1, 2, tty.width, tty.height - 1, 0, -1)
  gpu_proxy.fill(1, tty.height, tty.width, 1, " ")
  tty.cursor_y = tty.height
end

function tty.scroll()
  gpu_proxy.call("copy", 1, 2, tty.width, tty.height - 1, 0, -1)
  gpu_proxy.call("fill", 1, tty.height, tty.width, 1, " ")
  tty.cursor_y = tty.height
end

function tty.write(text)
  for char in string.gmatch(text, ".") do
    if char == "\n" then
      tty.cursor_x = 1
      tty.cursor_y = tty.cursor_y + 1
    else
      gpu_proxy.call("set", tty.cursor_x, tty.cursor_y, char)
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
  gpu_proxy.call("setCursor", tty.cursor_x, tty.cursor_y)
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
  local ok, sig_name, sender_pid, data = k_syscall("signal_pull")
  
  if ok then
    if sig_name == "tty_write" then
      tty.write(tostring(data))
    
    elseif sig_name == "tty_read" then
      -- This is a blocking read. We need to handle 'key_down' events.
      local line = ""
      gpu_proxy.call("setCursorBlink", true)
      
      while true do
        local key_ok, key_sig, char, code, _, key_name = k_syscall("signal_pull")
        if key_ok and key_sig == "os_event" and char == "key_down" then
          if key_name == "enter" then
            gpu_proxy.call("setCursorBlink", false)
            tty.write("\n")
            -- Return to the *original* caller
            k_syscall("signal_send", sender_pid, "syscall_return", true, line)
            break -- Exit read loop
          elseif key_name == "back" then
            if #line > 0 then
              line = string.sub(line, 1, -2)
              tty.cursor_x = tty.cursor_x - 1
              if tty.cursor_x < 1 then
                -- This is a simple backspace, doesn't wrap lines.
                tty.cursor_x = 1 
              end
              gpu_proxy.call("set", tty.cursor_x, tty.cursor_y, " ")
              gpu_proxy.call("setCursor", tty.cursor_x, tty.cursor_y)
            end
          else
            if char then
              line = line .. char
              tty.write(char)
            end
          end
        end
      end
    end
  end
end
