-- cock-- kernel.lua

local component = component
local computer = computer

local gpu = component.list("gpu")()
gpu = component.proxy(gpu)

local keyboard = component.list("keyboard")()
keyboard = component.proxy(keyboard)

local function init(Ring0, Ring1, Ring2, Ring3)
  -- make the kernel table available in all rings
  _G.kernel = Ring0
  _G.syscall = Ring1.syscalls
  _G.pipes = Ring1.pipes

  -- syscall 0x80: write to screen
  Ring1.syscalls[0x80] = function(x, y, text)
    gpu.set(x, y, text)
  end
  
  -- syscall 0x81: get screen resolution
  Ring1.syscalls[0x81] = function()
    return gpu.getResolution()
  end

  -- syscall 0x82: get keyboard input
  Ring1.syscalls[0x82] = function()
    while true do
      local _, _, address, _, key, char = computer.pullSignal(0.1)
      if address == keyboard.address then
        return key, char
      end
    end
  end

  -- syscall 0x83: clear Screen
  Ring1.syscalls[0x83] = function()
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
  end

  --syscall 0x84: set resolution
  Ring1.syscalls[0x84] = function(w, h)
    return gpu.setResolution(w, h)
  end
  
  -- syscall 0x85: pipe creation
  Ring1.syscalls[0x85] = function(name)
    return pipes.create(name)
  end
  
  -- syscall 0x86: pipe write
  Ring1.syscalls[0x86] = function(name, data)
    return pipes.write(name, data)
  end
  
  -- syscall 0x87: pipe read
  Ring1.syscalls[0x87] = function(name)
    return pipes.read(name)
  end

  -- example "driver" for keyboard input
  local function handleKeyboardInput()
    while true do
      local signal, address, key, char = computer.pullSignal()
      if signal == "key_down" and address == keyboard then
          -- send key press to a pipe or handle it directly in kernel mode
          -- for simplicity, let's send it to a pipe named "keyboard_input"
          pipes.write("keyboard_input", char)
      end
    end
  end

  -- create the keyboard input pipe
  pipes.create("keyboard_input")

  -- start keyboard "driver" as a kernel process
  local keyboard_driver_co = coroutine.create(handleKeyboardInput)
  coroutine.resume(keyboard_driver_co)

  -- load and run superuser shell
  local su_co = coroutine.create(function()
    local su_shell = [[
        local password = "awoo"
        local function authenticate(entered_password)
          return entered_password == password
        end

        local function set_password(new_password)
          password = new_password
        end

        local function execute_command(command)
          if command == "help" then
            return "Available commands: help, exit, set_password <new_password>, user_shell"
          elseif command == "exit" then
            return coroutine.yield()
          elseif string.sub(command, 1, 13) == "set_password " then
            local new_password = string.sub(command, 14)
            set_password(new_password)
            return "Password updated."
          elseif command == "user_shell" then
            local shell_path = "/usr/shell.lua"
            if filesystem[shell_path] then
                local shell_func, err = load(filesystem[shell_path], shell_path, "t", Ring3)
                if shell_func then
                    local shell_co = coroutine.create(shell_func)
                    coroutine.resume(shell_co)
                    while coroutine.status(shell_co) ~= "dead" do
                        computer.pullSignal(0.1)
                    end
                else
                    return "Error loading shell: " .. err
                end
            else
                return "Shell not found at " .. shell_path
            end
          else
            return "Invalid command"
          end
        end
        
        filesystem["/usr/su.lua"] = ""
        local su_file = filesystem.open("/usr/su.lua", "w")
        su_file:write("local args = {...}\n")
        su_file:write("local command = table.concat(args,\" \")\n")
        su_file:write("local output = kernel.execute_command(command)\n")
        su_file:write("syscall[0x80](1, 1, output .. \"          \")\n")
        su_file:close()

        local function execute_kernel_command(...)
          local args = {...}
          local command = table.concat(args,\" \")
          local output = execute_command(command)
          return output
        end
        
        Ring0.execute_command = execute_kernel_command

        local function run()
          syscall[0x80](1, 1, "Superuser Mode (Ring 2) - Enter password: ")
          local entered_password = ""
          local x = 42
          while true do
            local key, char = syscall[0x82]()
            if key == 28 then -- Enter key
              break
            elseif key == 14 then -- Backspace key
                entered_password = string.sub(entered_password, 1, -2)
                x = x - 1
                syscall[0x80](x, 1, "  ")
            elseif char then
                entered_password = entered_password .. char
                syscall[0x80](x, 1, "*")
                x = x + 1
            end
            computer.pullSignal(0.1)
          end
          syscall[0x80](1, 1, string.rep(" ", 160))

          if authenticate(entered_password) then
            syscall[0x80](1, 1, "Authentication successful.")
            syscall[0x80](1, 2, "Type 'help' for a list of commands.")
            local y = 3
            while true do
              syscall[0x80](1, y, "> ")
              local command = ""
              local x = 3
              while true do
                local key, char = syscall[0x82]()
                if key == 28 then -- Enter key
                  break
                elseif key == 14 then -- Backspace key
                    command = string.sub(command, 1, -2)
                    x = x - 1
                    syscall[0x80](x, y, "  ")
                elseif char then
                    command = command .. char
                    syscall[0x80](x, y, char)
                    x = x + 1
                end
                computer.pullSignal(0.1)
              end

              if command == "exit" then
                break
              end

              local output = execute_command(command)
              y = y + 1
              syscall[0x80](1, y, output)
              y = y + 1
              if y > 48 then
                computer.pullSignal()
                syscall[0x83]()
                y = 1
              end
            end
          else
            syscall[0x80](1, 1, "Authentication failed.")
          end
        end

        return run
    ]]
    local su_func, err = load(su_shell, "su_shell", "t", Ring2)
    if su_func then
      su_func()()
      while coroutine.status(su_co) ~= "dead" do
          computer.pullSignal(0.1)
      end
    else
      error("Error loading SU shell: " .. err)
    end
  end)
  
    filesystem["/usr/shell.lua"] = [[
        local function execute_command(command)
            local command_path = "/usr/" .. command .. ".lua"
            if filesystem[command_path] then
                local command_func, err = load(filesystem[command_path], command_path, "t", Ring3)
                if command_func then
                    local command_co = coroutine.create(command_func)
                    coroutine.resume(command_co)
                    while coroutine.status(command_co) ~= "dead" do
                        computer.pullSignal(0.1)
                    end
                else
                    return "Error loading command: " .. err
                end
            else
                return "Command not found: " .. command
            end
        end
        
        local function run()
            syscall[0x80](1, 2, "User Mode (Ring 3)")
            local y = 3
            while true do
                syscall[0x80](1, y, "$ ")
                local command = ""
                local x = 3
                while true do
                    local key, char = syscall[0x82]()
                    if key == 28 then -- Enter key
                        break
                    elseif key == 14 then -- Backspace key
                        command = string.sub(command, 1, -2)
                        x = x - 1
                        syscall[0x80](x, y, "  ")
                    elseif char then
                        command = command .. char
                        syscall[0x80](x, y, char)
                        x = x + 1
                    end
                    computer.pullSignal(0.1)
                end

                if command == "exit" then
                    break
                elseif command == "su" then
                    coroutine.resume(su_co)
                    while coroutine.status(su_co) ~= "dead" do
                        computer.pullSignal(0.1)
                    end
                else
                    local output = execute_command(command)
                    y = y + 1
                    syscall[0x80](1, y, output)
                end
                y = y + 1
                if y > 48 then
                  computer.pullSignal()
                  syscall[0x83]()
                  y = 1
                end
            end
        end

        return run
    ]]

  filesystem["/usr/help.lua"] = [[
    local w, h = syscall[0x81]()
    local centerX = math.floor(w / 2)
    local centerY = math.floor(h / 2)
    
    local helpText = {
        "Available commands:",
        "help - display this help message",
        "echo <text> - display text on screen",
        "clear - clear the screen",
        "su - switch to superuser mode",
        "exit - exit the current shell",
        "version - display the OS version"
    }
    
    local startY = centerY - math.floor(#helpText / 2)
    for i, line in ipairs(helpText) do
        local startX = centerX - math.floor(string.len(line) / 2)
        syscall[0x80](startX, startY + i - 1, line)
    end
  ]]

  filesystem["/usr/echo.lua"] = [[
    local function echo(...)
        local args = {...}
        local output = table.concat(args, " ")
        local w, h = syscall[0x81]()
        local y = 1
        while true do
          if y > h then
            computer.pullSignal()
            syscall[0x83]()
            y = 1
          end
          local tmp, num = string.gsub(output, "[^\n]+", "")
          if num == 0 then
            syscall[0x80](1, y, output)
            return
          else
            local line = string.sub(output, 1, string.find(output, "\n") - 1)
            syscall[0x80](1, y, line)
            y = y + 1
            output = string.sub(output, string.find(output, "\n") + 1)
          end
        end
    end
    
    echo(...)
  ]]

  filesystem["/usr/clear.lua"] = [[
    syscall[0x83]()
  ]]

  filesystem["/usr/version.lua"] = [[
    local os_version = _G._OSVERSION
    syscall[0x80](1, 1, "OS Version: " .. os_version)
  ]]
end

return {
  init = init
}