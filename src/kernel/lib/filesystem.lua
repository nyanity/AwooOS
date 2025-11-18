--
-- /lib/filesystem.lua
--

local oFsLib = {}

oFsLib.open = function(sPath, sMode)
  local bSys, bVfs, valResult = syscall("vfs_open", sPath, sMode or "r")
  
  if bSys and bVfs and type(valResult) == "number" then
    return { fd = valResult }
  else
    return nil, valResult -- valResult is the error text
  end
end

oFsLib.read = function(hHandle, nCount)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  local bSys, bVfs, valResult = syscall("vfs_read", hHandle.fd, nCount or math.huge)
  
  if bSys and bVfs then
    return valResult
  else
    return nil, valResult
  end
end

oFsLib.write = function(hHandle, sData)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  local bSys, bVfs, valResult = syscall("vfs_write", hHandle.fd, sData)
  return bSys and bVfs, valResult
end

oFsLib.close = function(hHandle)
  if not hHandle or not hHandle.fd then return nil end
  local bSys, bVfs = syscall("vfs_close", hHandle.fd)
  return bSys and bVfs
end

oFsLib.list = function(sPath)
  local bSys, bVfs, valResult = syscall("vfs_list", sPath)
  
  if bSys and bVfs and type(valResult) == "table" then
     return valResult
  else
     return nil, valResult
  end
end

oFsLib.chmod = function(sPath, nMode)
  -- nMode should be a number (e.g. 0x1ED for 755, but lua 5.2 uses decimal usually)
  -- we expect decimal representation of octal, e.g. 755 passed as 755 (integer)
  local bSys, bVfs, valResult = syscall("vfs_chmod", sPath, nMode)
  return bSys and bVfs, valResult
end

return oFsLib