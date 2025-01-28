local component = component
local computer = computer

local gpuAddress = component.list("gpu")()
local gpu = component.proxy(gpuAddress)

local keyboardAddress = component.list("keyboard")()
local keyboard
if keyboardAddress then
  keyboard = component.proxy(keyboardAddress)
end

local function init(Ring0, Ring1, Ring2, Ring3)
  gpu.fill(1, 1, 160, 50, " ")
  gpu.set(1, 1, "Kernel loaded successfully!")
  gpu.set(1, 2, "Got into boot script")

  gpu.set(1, 5, "Keyboard address = " .. tostring(keyboardAddress))

  _G.kernel  = Ring0
  _G.syscall = Ring1.syscalls
  _G.pipes   = Ring1.pipes

  computer.beep(1000, 0.2)


  -- 0x80: write text on screen
  Ring1.syscalls[0x80] = function(x, y, text)
    gpu.set(x, y, text)
  end

  -- 0x81: get screen resolution
  Ring1.syscalls[0x81] = function()
    return gpu.getResolution()
  end

  -- 0x82: wait for key press, return (scanCode, char)
  Ring1.syscalls[0x82] = function()
    while true do
      local evt, addr, char, code = computer.pullSignal(0.5)
      if evt == "key_down" then
        if addr == keyboardAddress then
          return code, char
        end
      end
    end
  end

  -- 0x83: clear screen
  Ring1.syscalls[0x83] = function()
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
  end

  -- 0x84: set resolution
  Ring1.syscalls[0x84] = function(w, h)
    return gpu.setResolution(w, h)
  end

  -- 0x85: create pipe
  Ring1.syscalls[0x85] = function(name)
    return pipes.create(name)
  end

  -- 0x86: pipe write
  Ring1.syscalls[0x86] = function(name, data)
    return pipes.write(name, data)
  end

  -- 0x87: pipe read
  Ring1.syscalls[0x87] = function(name)
    return pipes.read(name)
  end

  local function handleKeyboardInput()
    while true do
      local evt, addr, char, code = computer.pullSignal()
      if evt == "key_down" and addr == keyboardAddress then
        local ch = ""
        if char and char > 0 then
          ch = string.char(char)
        end
        pipes.write("keyboard_input", ch)
      end
    end
  end

  Ring1.pipes.create("keyboard_input")

  local keyboard_driver_co = coroutine.create(handleKeyboardInput)
  coroutine.resume(keyboard_driver_co)

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
          return "Commands: help, exit, set_password <pw>, user_shell"
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
              local ok, er = coroutine.resume(shell_co)
              while coroutine.status(shell_co) ~= "dead" do
                computer.pullSignal(0.1)
              end
              if not ok then
                return "Error in user_shell: " .. tostring(er)
              end
            else
              return "Error loading shell: " .. tostring(err)
            end
          else
            return "Shell not found at " .. shell_path
          end
        else
          return "Invalid command: " .. tostring(command)
        end
      end

      filesystem["/usr/su.lua"] = ""

      -- Expose to kernel environment so kernel can see
      local function execute_kernel_command(command)
        return execute_command(command)
      end
      Ring0.execute_command = execute_kernel_command

      local function run()
        syscall[0x80](1, 1, "Superuser Mode (Ring 2) - Enter password: ")
        local entered_password = ""
        local x = 42
        while true do
          local key, c = syscall[0x82]()
          -- key=scancode, c=char code
          if key == 28 then
            -- Enter
            break
          elseif key == 14 then
            -- Backspace
            entered_password = string.sub(entered_password, 1, -2)
            x = x - 1
            syscall[0x80](x, 1, " ")
          else
            -- For normal keys, c != 0
            if c and c > 0 then
              entered_password = entered_password .. string.char(c)
              syscall[0x80](x, 1, "*")
              x = x + 1
            end
          end
          computer.pullSignal(0.1)
        end
        -- Clear that line
        syscall[0x80](1, 1, string.rep(" ", 160))

        if authenticate(entered_password) then
          syscall[0x80](1, 1, "Authentication successful.")
          syscall[0x80](1, 2, "Type 'help' for commands.")
          local y = 3
          while true do
            syscall[0x80](1, y, "> ")
            local command = ""
            local x = 3
            while true do
              local key, c = syscall[0x82]()
              if key == 28 then
                break
              elseif key == 14 then
                command = string.sub(command, 1, -2)
                x = x - 1
                syscall[0x80](x, y, " ")
              else
                if c and c > 0 then
                  command = command .. string.char(c)
                  syscall[0x80](x, y, string.char(c))
                  x = x + 1
                end
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
            -- Simple scroll
            if y > 48 then
              computer.pullSignal()
              syscall[0x83]()
              y = 3
            end
          end
        else
          syscall[0x80](1, 1, "Authentication failed.")
        end
      end

      return run
    ]]

    local su_func, err = load(su_shell, "su_shell", "t", Ring2)
    if not su_func then
      error("Error loading SU shell: " .. tostring(err))
    end

    -- Actually run it
    su_func()()
    while coroutine.status(su_co) ~= "dead" do
      computer.pullSignal(0.1)
    end
  end)

  ----------------------------------------------------------------
  -- Create basic user shell files
  ----------------------------------------------------------------
  filesystem["/usr/shell.lua"] = [[
    local function execute_command(command)
      local cmd_path = "/usr/" .. command .. ".lua"
      if filesystem[cmd_path] then
        local func, err = load(filesystem[cmd_path], cmd_path, "t", Ring3)
        if not func then
          return "Error loading " .. command .. ": " .. tostring(err)
        end
        local co = coroutine.create(func)
        local ok, er = coroutine.resume(co)
        while coroutine.status(co) ~= "dead" do
          computer.pullSignal(0.1)
        end
        if not ok then
          return "Error in " .. command .. ": " .. tostring(er)
        end
      else
        return "Command not found: " .. tostring(command)
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
          local key, c = syscall[0x82]()
          if key == 28 then
            -- Enter
            break
          elseif key == 14 then
            -- Backspace
            command = string.sub(command, 1, -2)
            x = x - 1
            syscall[0x80](x, y, " ")
          else
            if c and c > 0 then
              command = command .. string.char(c)
              syscall[0x80](x, y, string.char(c))
              x = x + 1
            end
          end
          computer.pullSignal(0.1)
        end

        if command == "exit" then
          break
        elseif command == "su" then
          local ok, er = coroutine.resume(su_co)
          if not ok then
            syscall[0x80](1, y, "Error running su_co: " .. tostring(er))
          end
          while coroutine.status(su_co) ~= "dead" do
            computer.pullSignal(0.1)
          end
        else
          local output = execute_command(command)
          y = y + 1
          if output and output ~= "" then
            syscall[0x80](1, y, output)
            y = y + 1
          end
          if y > 48 then
            computer.pullSignal()
            syscall[0x83]()
            y = 3
          end
        end
      end
    end

    return run
  ]]

  filesystem["/usr/help.lua"] = [[
    local w, h = syscall[0x81]()
    local centerX = math.floor(w / 2)
    local centerY = math.floor(h / 2)

    local lines = {
      "Available commands:",
      "help      - this help",
      "echo TEXT - print TEXT",
      "clear     - clear screen",
      "su        - switch to superuser",
      "exit      - exit shell",
      "version   - OS version"
    }
    local startY = centerY - math.floor(#lines / 2)
    for i, line in ipairs(lines) do
      local startX = centerX - math.floor(#line / 2)
      syscall[0x80](startX, startY + i - 1, line)
    end
  ]]

  filesystem["/usr/echo.lua"] = [[
    local args = {...}
    local text = table.concat(args, " ")
    syscall[0x80](1, 20, text)
  ]]

  filesystem["/usr/clear.lua"] = [[
    syscall[0x83]()
  ]]

  filesystem["/usr/version.lua"] = [[
    syscall[0x80](1, 1, "OS Version: " .. tostring(_OSVERSION))
  ]]

end

return {
  init = init
}
