local sys = require("syscall")
local ring = syscall("process_get_ring")

if ring == 2.5 or ring == 0 then
  sys.write("Rebooting...\n")
  sys.reboot()
else
  sys.write("reboot: Permission denied (must be root)\n")
end
