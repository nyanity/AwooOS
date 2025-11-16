local k_syscall = syscall -- The raw syscall function

k_syscall("kernel_register_pipeline")
k_syscall("kernel_log", "[Ring 1] Pipeline Manager started.")

local vfs = {
  mounts = {},
  root_fs = nil,
  next_fd = 1,
  open_handles = {}, -- [pid][fd] = { vfs_node, oc_handle, path, mode }
}

local drivers = {
  tty_pid = nil,
  gpu_pid = nil,
  log_pid = nil,
}

-------------------------------------------------
-- VFS Implementation
-------------------------------------------------

function vfs.find_mount(path)
  -- TODO: Implement proper mount point resolution
  -- For now, all paths go to rootfs
  return vfs.mounts["/"]
end

function vfs.syscall_open(sender_pid, path, mode)
  k_syscall("kernel_log", "[Ring 1] VFS_OPEN: " .. path)
  
  local mount = vfs.find_mount(path)
  if not mount then
    return nil, "No filesystem for path"
  end
  
  -- Special device files
  if path == "/dev/tty" then
    -- This is a "virtual" file.
    local fd = vfs.next_fd; vfs.next_fd = vfs.next_fd + 1
    if not vfs.open_handles[sender_pid] then vfs.open_handles[sender_pid] = {} end
    vfs.open_handles[sender_pid][fd] = {
      type = "tty",
      path = path,
      mode = mode,
    }
    return fd
  end

  -- TODO: Check for other mounts (logfs, etc)
  
  -- Default to rootfs
  local proxy = mount.proxy
  local handle, reason = k_syscall("raw_component_invoke", proxy.address, "open", path, mode)
  if not handle then
    return nil, reason
  end
  
  local fd = vfs.next_fd; vfs.next_fd = vfs.next_fd + 1
  if not vfs.open_handles[sender_pid] then vfs.open_handles[sender_pid] = {} end
  vfs.open_handles[sender_pid][fd] = {
    type = "file",
    path = path,
    mode = mode,
    oc_handle = handle,
    proxy = proxy,
  }
  return fd
end

function vfs.syscall_read(sender_pid, fd, count)
  local handle = vfs.open_handles[sender_pid] and vfs.open_handles[sender_pid][fd]
  if not handle then return nil, "Invalid file descriptor" end
  
  if handle.type == "tty" then
    -- TTY read. Send IPC to TTY driver and wait.
    k_syscall("signal_send", drivers.tty_pid, "tty_read", sender_pid, count)
    -- This process will now sleep, waiting for the TTY driver
    -- to send a "syscall_return" signal.
    return k_syscall("signal_pull")
    
  elseif handle.type == "file" then
    local ok, data, reason = k_syscall("raw_component_invoke", handle.proxy.address, "read", handle.oc_handle, count)
    if not ok then return nil, data end -- data is error
    return data
  end
end

function vfs.syscall_write(sender_pid, fd, data)
  local handle = vfs.open_handles[sender_pid] and vfs.open_handles[sender_pid][fd]
  if not handle then return nil, "Invalid file descriptor" end

  if handle.type == "tty" then
    k_syscall("signal_send", drivers.tty_pid, "tty_write", sender_pid, data)
    return true -- TTY write is async
    
  elseif handle.type == "file" then
    local ok, reason = k_syscall("raw_component_invoke", handle.proxy.address, "write", handle.oc_handle, data)
    if not ok then return nil, reason end
    return true
  end
end

function vfs.syscall_close(sender_pid, fd)
  local handle = vfs.open_handles[sender_pid] and vfs.open_handles[sender_pid][fd]
  if not handle then return nil, "Invalid file descriptor" end
  
  vfs.open_handles[sender_pid][fd] = nil -- Free the FD
  
  if handle.type == "file" then
    k_syscall("raw_component_invoke", handle.proxy.address, "close", handle.oc_handle)
  end
  return true
end

function vfs.syscall_list(sender_pid, path)
    local mount = vfs.find_mount(path)
    if not mount then return nil, "No filesystem for path" end
    local ok, list, reason = k_syscall("raw_component_invoke", mount.proxy.address, "list", path)
    if not ok then return nil, list end
    return list
end

-- Override the VFS syscalls
k_syscall("syscall_override", "vfs_open")
k_syscall("syscall_override", "vfs_read")
k_syscall("syscall_override", "vfs_write")
k_syscall("syscall_override", "vfs_close")
k_syscall("syscall_override", "vfs_list")

-------------------------------------------------
-- Driver Loading
-------------------------------------------------
local function load_driver(component_type, address)
  local driver_path = "/drivers/" .. component_type .. ".sys.lua"
  
  -- We must use the Ring 0 VFS, as our own VFS isn't fully up.
  -- This is a bit of a hack.
  -- Let's just spawn the process. The kernel's loader will find the file.
  
  k_syscall("kernel_log", "[Ring 1] Loading driver " .. driver_path .. " for " .. address)
  
  local ok, pid, err = k_syscall("process_spawn", driver_path, 2, {
    address = address
  })
  
  if not pid then
    k_syscall("kernel_log", "[Ring 1] FAILED to load driver: " .. err)
    return
  end
  
  k_syscall("kernel_log", "[Ring 1] Driver " .. component_type .. " spawned as PID " .. pid)
  
  -- store special drivers
  if component_type == "tty" then
    drivers.tty_pid = pid
  elseif component_type == "gpu" then
    drivers.gpu_pid = pid
  end
  
  -- register this driver with the kernel
  k_syscall("kernel_register_driver", component_type, pid)
  k_syscall("kernel_map_component", address, pid)
end


local function scan_and_load_drivers()
  k_syscall("kernel_log", "[Ring 1] Scanning for components...")
  
  -- receive information about the root file system from the kernel
  local ok, root_uuid, root_proxy = k_syscall("kernel_get_root_fs")
  if not ok then
    k_syscall("kernel_panic", "Pipeline could not get root FS info from kernel: " .. tostring(root_uuid))
    return
  end
  
  k_syscall("kernel_log", "[Ring 1] Got root FS: " .. root_uuid)
  
  -- registering the root mount point in the VFS manager
  vfs.mounts["/"] = {
    type = "rootfs",
    proxy = root_proxy,
  }

  -- scan
  local ok, comp_list = k_syscall("raw_component_list")
  if not ok then
    k_syscall("kernel_log", "[Ring 1] Failed to list components: " .. comp_list)
    return
  end
  
  local sGpuAddress, sScreenAddress
  for addr, ctype in pairs(comp_list) do
    if ctype == "gpu" and not sGpuAddress then
      sGpuAddress = addr
    elseif ctype == "screen" and not sScreenAddress then
      sScreenAddress = addr
    end
  end

  -- if there is a screen and gpu then run tty
  if sGpuAddress and sScreenAddress then
    k_syscall("kernel_log", "[Ring 1] Found screen and GPU. Loading TTY driver.")
    local ok, pid, err = k_syscall("process_spawn", "/drivers/tty.sys.lua", 2, {
      gpu = sGpuAddress,
      screen = sScreenAddress
    })
    if pid then
      drivers.tty_pid = pid
      k_syscall("kernel_log", "[Ring 1] Driver tty spawned as PID " .. pid)
    else
      k_syscall("kernel_log", "[Ring 1] FAILED to load TTY driver: " .. err)
    end
  end
  
  -- driver loiad
  for addr, ctype in pairs(comp_list) do
    -- skipping already satisfied tyupes
    if ctype ~= "gpu" and ctype ~= "screen" and ctype ~= "tty" then
      load_driver(ctype, addr)
    end
  end
  
  k_syscall("kernel_log", "[Ring 1] Driver loading initiated.")
end

scan_and_load_drivers()

-- are we ready or not
local state = {
  tty_ready = false,
  init_spawned = false,
}

-- a message indicating that we're entering the main loop.
print("[Ring 1] Entering main pipeline event loop...")

-------------------------------------------------
-- Main Pipeline Event Loop
-------------------------------------------------
while true do
  k_syscall("kernel_log", "[PM] Looping, now waiting for signal...")
  local ok, sender_pid, sig_name, p1, p2, p3, p4 = k_syscall("signal_pull")
  
  if ok then
    k_syscall("kernel_log", string.format("[PM] Woke up! Received signal. Sender: %s, Name: %s", tostring(sender_pid), tostring(sig_name)))
    if sig_name == "syscall" then
      -- Это перехваченный системный вызов
      local data = p1
      local syscall_name = data.name
      local args = data.args
      local sender_pid = data.sender_pid
      
      local handler = vfs["syscall_" .. syscall_name]
      if handler then
          local response = {pcall(handler, sender_pid, table.unpack(args))}
          
          local ret_ok = table.remove(response, 1)
          if ret_ok then
            -- Syscall succeeded, return its results
            k_syscall("signal_send", sender_pid, "syscall_return", true, table.unpack(response))
          else
            -- Syscall failed, return the error
            k_syscall("signal_send", sender_pid, "syscall_return", false, response[1])
          end
      else
          -- Неизвестный VFS syscall
          k_syscall("signal_send", sender_pid, "syscall_return", false, "Unknown VFS syscall: " .. syscall_name)
      end
      
    elseif sig_name == "os_event" then
      -- Это сырое событие от ядра
      local event_name = p1
      if event_name == "component_added" then
        local addr = p2
        local ctype = p3
        print("[Ring 1] Component added: " .. ctype .. " at " .. addr)
        load_driver(ctype, addr)
      elseif event_name == "component_removed" then
        -- TODO: Unload driver
      end

    elseif sig_name == "driver_ready" then
        -- Драйвер сообщил о готовности!
        -- sender_pid уже содержит правильный PID
        if sender_pid == drivers.tty_pid then
            state.tty_ready = true
            -- Используем print, т.к. TTY еще не готов для VFS
            k_syscall("kernel_log", "[Ring 1] TTY driver is ready.")
            
            if not state.init_spawned then
                state.init_spawned = true
                k_syscall("kernel_log", "[Ring 1] Spawning Ring 3 init...")
                local ok_spawn, init_pid, err = k_syscall("process_spawn", "/bin/init.lua", 3)
                if not ok_spawn then
                  k_syscall("kernel_log", "[Ring 1] FATAL: Could not spawn /bin/init.lua: " .. err)
                  k_syscall("kernel_panic", "Init spawn failed: " .. tostring(err))
                end
            end
        end
    end
  end
end