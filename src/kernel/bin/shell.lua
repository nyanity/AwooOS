local function execute_command(command)
  local cmd_path = "/usr/" .. command .. ".lua"
    local func, err = load_file(cmd_path)
    if not func then
      return "Error loading " .. command .. ": " .. tostring(err)
    end
    local co = coroutine.create(func)
    local ok, er = coroutine.resume(co)
    while coroutine.status(co) ~= "dead" do end
    if not ok then
      return "Error in " .. command .. ": " .. tostring(er)
    end
end
local function run()
  syscall[0x80](1, 2, "User Mode (Ring 3)")
  local y = 3
  while true do
    if y > 48 then
      syscall[0x83]()
      y = 3 
    end

    syscall[0x80](1, y, "$ ")
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
    elseif command == "su" then
      local ok, er = coroutine.resume(su_co)
      if not ok then
        syscall[0x80](1, y, "Error running su_co: " .. tostring(er))
      end
      while coroutine.status(su_co) ~= "dead" do end
    else
      local output = execute_command(command)
      y = y + 1
      if output and output ~= "" then
        syscall[0x80](1, y, output)
        y = y + 1
      end
    end
  end
end
return run