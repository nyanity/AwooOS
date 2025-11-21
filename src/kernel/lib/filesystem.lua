--
-- /lib/filesystem.lua
-- user-mode fs wrapper.
-- now with aggressive buffering because donut.c was murdering the kernel with syscalls.
--

local oFsLib = {}
local tBuffers = {} 

local function fFlush(nFd)
  local sData = tBuffers[nFd]
  if sData and #sData > 0 then
    tBuffers[nFd] = "" -- wipe it before sending
    local bSys, bVfs, valResult = syscall("vfs_write", nFd, sData)
    return bSys and bVfs, valResult
  end
  return true
end

oFsLib.open = function(sPath, sMode)
  local bSys, bVfs, valResult = syscall("vfs_open", sPath, sMode or "r")
  if bSys and bVfs and type(valResult) == "number" then
    return { fd = valResult }
  else
    return nil, valResult
  end
end

oFsLib.read = function(hHandle, nCount)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  
  -- flush all buffers before reading. 
  -- otherwise prompts like "login: " sit in the buffer while we wait for input. awkward.
  for nBufFd, _ in pairs(tBuffers) do
     fFlush(nBufFd)
  end
  
  local bSys, bVfs, valResult = syscall("vfs_read", hHandle.fd, nCount or math.huge)
  return (bSys and bVfs) and valResult or nil, valResult
end

oFsLib.write = function(hHandle, sData)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  local nFd = hHandle.fd
  
  -- change: buffering everything now, not just stdout.
  -- we hoard chars like a dragon hoards gold until a newline appears.
  local sBuf = (tBuffers[nFd] or "") .. tostring(sData)
  tBuffers[nFd] = sBuf
  
  -- flush strategy:
  -- 1. if there's a newline (interactive stuff)
  -- 2. if the buffer is getting fat (> 2kb)
  if sBuf:find("[\n\r]") or #sBuf > 2048 then
     return fFlush(nFd)
  end
  return true
end

oFsLib.flush = function(hHandle)
  if hHandle and hHandle.fd then return fFlush(hHandle.fd) end
end

oFsLib.close = function(hHandle)
  if not hHandle or not hHandle.fd then return nil end
  
  -- flush the toilet before leaving
  fFlush(hHandle.fd)
  tBuffers[hHandle.fd] = nil
  
  local bSys, bVfs = syscall("vfs_close", hHandle.fd)
  return bSys and bVfs
end

oFsLib.list = function(sPath)
  local bSys, bVfs, valResult = syscall("vfs_list", sPath)
  return (bSys and bVfs and type(valResult) == "table") and valResult or nil, valResult
end

oFsLib.chmod = function(sPath, nMode)
  local bSys, bVfs, valResult = syscall("vfs_chmod", sPath, nMode)
  return bSys and bVfs, valResult
end

return oFsLib