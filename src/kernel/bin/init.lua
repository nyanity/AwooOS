--
-- /bin/init.lua
-- the first userspace process. pid 1's big day.
-- its job is to get a user logged in and start their shell.
--

local oFs = require("filesystem")

-- open stdio, the classic way
local hStdin = oFs.open("/dev/tty", "r")
local hStdout = oFs.open("/dev/tty", "w")

-- a simple wrapper to make sure we're writing to the right place.
local function fWrite(sText)
  oFs.write(hStdout, sText)
end

fWrite("[INIT] hStdout created. FD is: " .. tostring(hStdout and hStdout.fd) .. "\n")

-- reads a line from stdin.
local function fRead()
  -- TODO: implement secret read, rn it's just echoing. security!
  return oFs.read(hStdin)
end

-- super secure hashing algorithm, do not steal
-- top secret government-grade encryption. totally unbreakable.
local function fHash(sPassword)
  return string.reverse(sPassword) .. "AURA_SALT"
end

-- load the /etc/passwd.lua file
-- let's see who's on the guest list.
local function fLoadPasswd()
  local hPasswdFile, sErr = oFs.open("/etc/passwd.lua", "r")
  if not hPasswdFile then
    fWrite("FATAL: Cannot open /etc/passwd.lua: " .. sErr .. "\n")
    return nil
  end
  local sFileContent = oFs.read(hPasswdFile)
  oFs.close(hPasswdFile)
  
  if not sFileContent or sFileContent == "" then
    return {}
  end
  
  local fLoadedFunc, sLoadErr = load(sFileContent, "passwd", "t", {})
  if not fLoadedFunc then
      fWrite("FATAL: Syntax error in /etc/passwd.lua: " .. tostring(sLoadErr) .. "\n")
      return nil
  end

  return fLoadedFunc()
end

-- main login loop
-- the eternal login prompt. the gatekeeper.
while true do
  local tPasswordDb = fLoadPasswd()
  if not tPasswordDb then
    syscall("process_yield") -- wait and retry, maybe it'll exist later
  else
    fWrite("\f") 
    fWrite("Welcome to AwooOS\n")
    fWrite("Login: ")
    local sUsername = fRead()
    
    local tUserEntry = tPasswordDb[sUsername]
    
    fWrite("Password: ")
    local sPassword = fRead() -- TODO: secret read again. seriously.
    
    if tUserEntry and tUserEntry.hash == fHash(sPassword) then
      fWrite("\nLogin successful. Starting shell...\n")
      
      -- spawn the shell for the user
      local nNewPid, sErr = syscall("process_spawn", tUserEntry.shell, 3, {
        USER = sUsername,
        HOME = tUserEntry.home,
        UID = tUserEntry.uid,
      })
      
      if nNewPid then
        -- wait for the shell process to finish
        syscall("process_wait", nNewPid)
        fWrite("\nShell exited. Logging out.\n\n") -- shell's done, log 'em out.
      else
        fWrite("\nFailed to start shell: " .. sErr .. "\n")
      end
    else
      fWrite("\nLogin incorrect.\n")
    end
  end
end