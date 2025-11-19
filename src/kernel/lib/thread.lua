--
-- /lib/thread.lua
-- Multithreading library for AwooOS.
-- Because doing one thing at a time is boring.
--

local oSys = require("syscall")
local oThread = {}

-- creates a new thread from a function.
-- the thread shares global variables with the main process.
function oThread.create(fFunc)
  local nPid, sErr = syscall("process_thread", fFunc)
  
  if not nPid then
    return nil, sErr
  end
  
  local tThreadObj = {
    pid = nPid,
    
    -- wait for the thread to finish
    join = function(self)
      oSys.wait(self.pid)
    end,
    
    -- kill the thread immediately
    kill = function(self)
      -- we don't have a kill syscall yet, but let's pretend/plan for it
      -- or implement it via signal
      -- for now, we just wait. TODO: Add process_kill syscall.
      return false, "Not implemented"
    end,
    
    detach = function(self)
      -- just forget about it
    end
  }
  
  return tThreadObj
end

-- sleep the current thread (wrapper for yield)
function oThread.sleep(nSeconds)
  local nStart = os.clock() -- assuming os.clock maps to uptime
  -- actually, we don't have a sleep syscall with timer yet.
  -- we have to busy-wait yield.
  -- optimized kernel would have a timer event.
  local nDeadline = require("computer").uptime() + nSeconds
  while require("computer").uptime() < nDeadline do
     syscall("process_wait", 0) -- yield to scheduler
  end
end

return oThread