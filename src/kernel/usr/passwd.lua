-- /usr/passwd.lua
local syscalls_aliases = _G.syscalls_aliases

local sha256 = load_file("/lib/sha256.lua", _G, nil, true)
local passwdMain = function()
  local f = filesystem.open("/etc/passwd", "r")
  local oldHash = f and f:read(math.huge)
  f and f:close()

  (oldHash == nil or oldHash == "") and false or (function()
    syscalls_aliases.gset(1, shellState.currentY, "Old password: ")
    local oldInput = shellReadLine(true)
    (sha256(oldInput) == oldHash) or error("Old password is incorrect.")
  end)()

  local y1 = shellState.currentY + 1
  syscalls_aliases.gset(1, y1, "New password: ")
  local new1 = shellReadLine(true)
  local y2 = y1 + 1
  syscalls_aliases.gset(1, y2, "Confirm new password: ")
  local new2 = shellReadLine(true)
  (new1 == new2) or error("Passwords did not match.")

  local wf = filesystem.open("/etc/passwd","w")
  wf:write(sha256(new1))
  wf:close()

  syscalls_aliases.gset(1, y2+1, "Password updated successfully.")
end

return passwdMain
