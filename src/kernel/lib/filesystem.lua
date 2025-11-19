--
-- /lib/filesystem.lua
--
local oFsLib = {}
local tBuffers = {} 

local function fFlush(nFd)
  local sData = tBuffers[nFd]
  if sData and #sData > 0 then
    tBuffers[nFd] = ""
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
  
  -- flush all buffers to ensure prompts are visible
  for nBufFd, _ in pairs(tBuffers) do
     fFlush(nBufFd)
  end
  
  -- Removed process_wait(0) - relying on explicit flush in init.lua now
  
  local bSys, bVfs, valResult = syscall("vfs_read", hHandle.fd, nCount or math.huge)
  return (bSys and bVfs) and valResult or nil, valResult
end

oFsLib.write = function(hHandle, sData)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  local nFd = hHandle.fd
  
  if nFd == 1 or nFd == 2 then
     local sBuf = (tBuffers[nFd] or "") .. tostring(sData)
     tBuffers[nFd] = sBuf
     if sBuf:find("[\n\r]") or #sBuf > 2048 then
        return fFlush(nFd)
     end
     return true
  else
     local bSys, bVfs, valResult = syscall("vfs_write", nFd, sData)
     return bSys and bVfs, valResult
  end
end

oFsLib.flush = function(hHandle)
  if hHandle and hHandle.fd then return fFlush(hHandle.fd) end
end

oFsLib.close = function(hHandle)
  if not hHandle or not hHandle.fd then return nil end
  fFlush(hHandle.fd)
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