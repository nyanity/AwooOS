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
              while coroutine.status(shell_co) ~= "dead" do end
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
          if key == 28 then
            break
          elseif key == 14 then
            entered_password = string.sub(entered_password, 1, -2)
            x = x - 1
            syscall[0x80](x, 1, " ")
          else
            if c and c > 0 then
              entered_password = entered_password .. string.char(c)
              syscall[0x80](x, 1, "*")
              x = x + 1
            end
          end
        end
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
            end
            if command == "exit" then
              break
            end
            local output = execute_command(command)
            y = y + 1
            syscall[0x80](1, y, output)
            y = y + 1
            if y > 48 then
              syscall[0x83]()
              y = 3
            end
          end
        else
          syscall[0x80](1, 1, "Authentication failed.")
        end
      end
      return run