local component = component
local computer = computer
local gpu = gpu
local keyboard = keyboard

local function init(Ring0, Ring1, Ring2, Ring3)
  klog("init(): kernel loaded")
  klog("init(): got into boot script")
  klog("init(): keyboard address = " .. tostring(_G.keyboard.address))
  
  _G.kernel = Ring0
  _G.syscall = Ring1.syscalls
  _G.pipes = Ring1.pipes
  --print_table(Ring1.pipes)

  computer.beep(1000, 0.2)
  Ring1.syscalls[0x80] = function(x, y, text)
    gpu.set(x,y,text)
  end

  Ring1.syscalls[0x81] = function()
    return gpu.getResolution()
  end

  Ring1.syscalls[0x82] = function()
    while true do
      local evt, addr, char, code = computer.pullSignal()
      if evt == "key_down" then
          return code, char
      end
    end
  end

  Ring1.syscalls[0x83] = function()
    local w, h = gpu.getResolution()
    gpu.fill(1, 1, w, h, " ")
  end

  Ring1.syscalls[0x84] = function(w, h)
    return gpu.setResolution(w, h)
  end

  Ring1.syscalls[0x85] = function(name)
    return pipes.create(name)
  end

  Ring1.syscalls[0x86] = function(name, data)
    return pipes.write(name, data)
  end

  Ring1.syscalls[0x87] = function(name)
    return pipes.read(name)
  end
  
  --[[local su_co = coroutine.create(function()
    local su_func, err = load_file("/bin/su_shell.lua", Ring2)
    if not su_func then
      error("Error loading SU shell: " .. tostring(err))
    end

    su_func()()
    while coroutine.status(su_co) ~= "dead" do
    end
  end)]]
  
end

return {
  init = init
}
