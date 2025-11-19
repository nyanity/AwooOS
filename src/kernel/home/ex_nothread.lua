--
-- /home/ex_nothread.lua
-- The sad, lonely, single-threaded life.
--

local sys = require("syscall")
local computer = require("computer")

local function heavy_task(sName, nTime)
  print(string.format("[%s] Starting task (Duration: %ds)...", sName, nTime))
  local nDead = computer.uptime() + nTime
  
  -- simulate work
  while computer.uptime() < nDead do
     -- blocking the whole system effectively if we didn't yield
     -- but even with yield, we do this sequentially
     sys.wait(0) 
  end
  
  print(string.format("[%s] Done!", sName))
end

print("--- Single Threaded Demo ---")
local nStart = computer.uptime()

-- Task 1
heavy_task("Downloader", 2)

-- Task 2 (Starts only after Task 1 finishes)
heavy_task("Renderer", 2)

local nTotal = computer.uptime() - nStart
print(string.format("Total time: %.2f seconds", nTotal))