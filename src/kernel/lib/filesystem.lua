--
-- /lib/filesystem.lua
-- a friendly wrapper around the vfs syscalls. makes file stuff less scary.
--

local oFsLib = {}

oFsLib.open = function(sPath, sMode)
  local bSyscallOk, bVfsOk, valResult = syscall("vfs_open", sPath, sMode or "r")
  
  if bSyscallOk and bVfsOk then
    -- wrap the numeric file descriptor in a handle table
    return { fd = valResult }
  else
    return nil, valResult
  end
end

oFsLib.read = function(hHandle, nCount)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  local bSyscallOk, bVfsOk, valResult = syscall("vfs_read", hHandle.fd, nCount or math.huge)

  if bSyscallOk and bVfsOk then
    return valResult
  else
    return nil, valResult
  end
end

oFsLib.write = function(hHandle, sData)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  return syscall("vfs_write", hHandle.fd, sData)
end

oFsLib.close = function(hHandle)
  if not hHandle or not hHandle.fd then return nil, "Invalid handle" end
  
  return syscall("vfs_close", hHandle.fd)
end

oFsLib.list = function(sPath)
  local bSyscallOk, bVfsOk, valResult = syscall("vfs_list", sPath)
  
  if bSyscallOk and bVfsOk then
    return valResult
  else
    return nil, valResult
  end
end

return oFsLib