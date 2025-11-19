--
-- /home/ex_thread.lua
-- The glorious multithreaded future.
--

local thread = require("thread")
local sys = require("syscall")
local computer = require("computer")

local function heavy_task(sName, nTime)
  print(string.format("\27[32m[%s]\27[37m Starting task...", sName))
  
  local nDead = computer.uptime() + nTime
  while computer.uptime() < nDead do
     sys.wait(0) -- yield to let other threads run
  end
  
  print(string.format("\27[32m[%s]\27[37m Done!", sName))
end

print("--- Multi Threaded Demo ---")
local nStart = computer.uptime()

-- Create threads
-- Note: We wrap arguments in a closure because thread.create takes 1 func
local t1 = thread.create(function() heavy_task("Downloader", 2) end)
local t2 = thread.create(function() heavy_task("Renderer", 2) end)

if t1 and t2 then
  print("Threads spawned. Waiting for completion...")
  
  -- Wait for both to finish
  t1:join()
  t2:join()
else
  print("Failed to spawn threads!")
end

local nTotal = computer.uptime() - nStart
print(string.format("Total time: %.2f seconds", nTotal))