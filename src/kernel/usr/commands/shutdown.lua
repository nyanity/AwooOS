-- shutdown - halt the system
local sys = require("syscall")
print("System going down NOW!")
sys.shutdown()