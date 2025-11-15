local sys = {}

sys.write = function(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = tostring(select(i, ...))
  end
  syscall("vfs_write", 1, table.concat(parts, "\t")) -- 1 = stdout
end

sys.read = function()
  local ok, data = syscall("vfs_read", 0) -- 0 = stdin
  return data
end

sys.spawn = function(path, env)
  return syscall("process_spawn", path, 3, env)
end

sys.wait = function(pid)
  return syscall("process_wait", pid)
end

sys.reboot = function()
  return syscall("computer_reboot")
end

sys.shutdown = function()
  return syscall("computer_shutdown")
end

return sys
