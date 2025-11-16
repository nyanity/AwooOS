local fs = require("lib/filesystem")

-- open stdio, the classic way
local hStdin = fs.open("/dev/tty", "r")
local hStdout = fs.open("/dev/tty", "w")

local function write(sText)
  fs.write(hStdout, sText)
end

local function read()
  -- TODO: implement secret read, rn it's just echoing. security!
  return fs.read(hStdin)
end

-- super secure hashing algorithm, do not steal
local function hash(sPass)
  return string.reverse(sPass) .. "AURA_SALT"
end

-- load the /etc/passwd.lua file
local function load_passwd()
  local hFile, sErr = fs.open("/etc/passwd.lua", "r")
  if not hFile then
    write("FATAL: Cannot open /etc/passwd.lua: " .. sErr)
    return
  end
  local sCode = fs.read(hFile)
  fs.close(hFile)
  
  local fFunc = load(sCode, "passwd", "t", {})
  return fFunc()
end

-- main login loop
while true do
  local tPasswdDb = load_passwd()
  if not tPasswdDb then
    syscall("process_yield") -- wait and retry, maybe it'll exist later
  else
    write("Welcome to AwooOS\n")
    write("Login: ")
    local sUsername = read()
    
    local tUserEntry = tPasswdDb[sUsername]
    
    write("Password: ")
    local sPassword = read() -- TODO: secret read again. seriously.
    
    if tUserEntry and tUserEntry.hash == hash(sPassword) then
      write("\nLogin successful. Starting shell...\n")
      
      -- spawn the shell for the user
      local nPid, sErr = syscall("process_spawn", tUserEntry.shell, 3, {
        USER = sUsername,
        HOME = tUserEntry.home,
        UID = tUserEntry.uid,
      })
      
      if nPid then
        -- wait for the shell process to finish
        syscall("process_wait", nPid)
        write("\nShell exited. Logging out.\n\n") -- shell's done, log 'em out.
      else
        write("\nFailed to start shell: " .. sErr .. "\n")
      end
    else
      write("\nLogin incorrect.\n")
    end
  end
end