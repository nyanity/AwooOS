local component = component
local computer = computer
local gpu = gpu
local keyboard = keyboard

local function init(Ring0, Ring1, Ring2, Ring3)
  klog("init(): kernel loaded")
  klog("init(): got into boot script")
  klog("init(): keyboard address = " .. tostring(_G.keyboard.address))

  _G.kernel           = Ring0
  _G.syscall          = Ring1.syscalls
  _G.syscalls_aliases = Ring1.syscalls_aliases

  local pipeModule = load_file("/proc/core/pipes.lua", Ring1)()
  Ring1.pipes = {
    create = pipeModule.createPipe,
    write  = pipeModule.writePipe,
    read   = pipeModule.readPipe
  }

  computer.beep(1000, 0.2)

  Ring1.syscalls[0x80] = function(x, y, text) gpu.set(x,y,text) end
  Ring1.syscalls_aliases.gset = Ring1.syscalls[0x80]

  Ring1.syscalls[0x81] = function() return gpu.getResolution() end
  Ring1.syscalls_aliases.getResolution = Ring1.syscalls[0x81]

  Ring1.syscalls[0x82] = function()
    while true do
      local evt, addr, char, code = computer.pullSignal()
      (evt == "key_down") and (function() return code, char end)()
    end
  end
  Ring1.syscalls_aliases.getKey = Ring1.syscalls[0x82]

  Ring1.syscalls[0x83] = function()
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
  end
  Ring1.syscalls_aliases.clear = Ring1.syscalls[0x83]

  Ring1.syscalls[0x84] = function(w, h) return gpu.setResolution(w, h) end
  Ring1.syscalls_aliases.setResolution = Ring1.syscalls[0x84]

  Ring1.syscalls[0x85] = function(name) return Ring1.pipes.create(name) end
  Ring1.syscalls_aliases.pipe_create = Ring1.syscalls[0x85]

  Ring1.syscalls[0x86] = function(name, data) return Ring1.pipes.write(name, data) end
  Ring1.syscalls_aliases.pipe_write = Ring1.syscalls[0x86]
  
  Ring1.syscalls[0x87] = function(name) return Ring1.pipes.read(name) end
  Ring1.syscalls_aliases.pipe_read = Ring1.syscalls[0x87]

end

return {
  init = init
}
