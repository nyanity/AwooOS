local fs = {}

fs.open = function(path, mode)
  local syscall_ok, vfs_ok, fd_or_err = syscall("vfs_open", path, mode or "r")
  
  if syscall_ok and vfs_ok then
    return { fd = fd_or_err }
  else
    return nil, fd_or_err
  end
end

fs.read = function(handle, count)
  if not handle or not handle.fd then return nil, "Invalid handle" end
  local syscall_ok, vfs_ok, data_or_err = syscall("vfs_read", handle.fd, count or math.huge)

  if syscall_ok and vfs_ok then
    return data_or_err
  else
    return nil, data_or_err
  end
end

fs.write = function(handle, data)
  if not handle or not handle.fd then return nil, "Invalid handle" end
  return syscall("vfs_write", handle.fd, data)
end

fs.close = function(handle)
  if not handle or not handle.fd then return nil, "Invalid handle" end
  
  return syscall("vfs_close", handle.fd)
end

fs.list = function(path)
  local syscall_ok, vfs_ok, list_or_err = syscall("vfs_list", path)
  
  if syscall_ok and vfs_ok then
    return list_or_err
  else
    return nil, list_or_err
  end
end

return fs