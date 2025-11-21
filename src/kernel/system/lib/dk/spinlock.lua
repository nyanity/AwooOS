-- /system/lib/dk/spinlock.lua
local tDKStructs = require("shared_structs")
local syscall = syscall

local SpinLock = {}

function SpinLock.KeInitializeSpinLock()
  return { bLocked = false }
end

function SpinLock.KeAcquireSpinLock(tLock)
  local nOldIrql = syscall("KeRaiseIrql", tDKStructs.DISPATCH_LEVEL)
  tLock.bLocked = true
  
  return nOldIrql
end

function SpinLock.KeReleaseSpinLock(tLock, nNewIrql)
  tLock.bLocked = false
  syscall("KeLowerIrql", nNewIrql)
end

return SpinLock