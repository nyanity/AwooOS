local sha256 = load_file("/lib/sha256.lua", _G, nil, true)
local syscall_aliases = _G.syscall_aliases

local suMain = function()
  (shellState.isSu == true) and error("Already in su mode.")

  -- check pipe for permission
  local perm = syscall_aliases.pipe_read("permcheck")
  (perm == "allow_su") or error("Permission to su denied by pipe.")

  syscall_aliases.gset(1, shellState.currentY, "Password: ")
  local passwdInput = shellReadLine(true)
  
  local f = filesystem.open("/etc/passwd", "r")
  f or error("No /etc/passwd found, cannot authenticate.")
  local storedHash = f:read(math.huge) or ""
  f:close()

  (storedHash ~= "") or error("No password is set. Use 'passwd' to set one.")

  local inputHash = sha256(passwdInput)
  (inputHash == storedHash) or error("Invalid password.")

  shellState.isSu = true
  syscall_aliases.gset(1, shellState.currentY+1, "Switched to superuser.")
end

return suMain
