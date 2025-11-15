local fs = require("lib/filesystem")

local stdin = { fd = 0 }
local stdout = { fd = 1 }

local function hash(pass)
  return string.reverse(pass) .. "AURA_SALT"
end

local function load_passwd()
  local f = fs.open("/etc/passwd.lua", "r")
  local code = fs.read(f)
  fs.close(f)
  return load(code, "passwd", "t", {})()
end

fs.write(stdout, "Password for root: ")
local pass = fs.read(stdin) -- TODO: secret read

local passwd_db = load_passwd()
local root_hash = passwd_db.root.hash

if hash(pass) == root_hash then
  local ok, err = syscall("process_elevate", 2.5)
  if ok then
    fs.write(stdout, "Elevated to Ring 2.5\n")
    -- We need to re-execute the shell to get the new sandbox
    local ring = syscall("process_get_ring")
    syscall("process_spawn", "/bin/sh.lua", ring, {
      USER = "root",
      HOME = "/home/root",
      UID = 0,
    })
    -- After this, the current 'su' process will exit,
    -- and the parent shell will wait for the *new* shell.
  else
    fs.write(stdout, "Elevation failed: " .. err .. "\n")
  end
else
  fs.write(stdout, "su: Authentication failure\n")
end
