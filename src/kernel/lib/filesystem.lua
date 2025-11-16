local fs = {}

fs.open = function(path, mode)
  local ok, fd, err = syscall("vfs_open", path, mode or "r")
  if ok then
    return { fd = fd } -- Return a file handle object
  else
    return nil, err
  end
end

fs.read = function(handle, count)
  if not handle or not handle.fd then return nil, "Invalid handle" end
  local ok, data, err = syscall("vfs_read", handle.fd, count or math.huge)
  if ok then
    return data
  else
    return nil, err
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
  local ok, list, err = syscall("vfs_list", path)
  if ok then
    return list
  else
    return nil, err
  end
end

return fs
