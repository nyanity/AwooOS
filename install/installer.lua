--
-- installer.lua
-- AxisOS Installer // Arch-itect Edition v2.6
-- "I use AxisOS, by the way."
--

local component = require("component")
local event = require("event")
local term = require("term")
local fs = require("filesystem")
local computer = require("computer")
local unicode = require("unicode")
local gpu = component.gpu
local internet = component.internet

-- [[ 0. CONFIGURATION & CONSTANTS ]] --

local DEBUG_MODE = false 
local REPO_OWNER = "nyanity"
local REPO_NAME = "AxisOS"
local REPO_BRANCH = "main"

-- Point API directly to packages folder
local API_BASE = string.format("https://api.github.com/repos/%s/%s/contents/src/packages", REPO_OWNER, REPO_NAME)
local RAW_BASE = string.format("https://raw.githubusercontent.com/%s/%s/%s", REPO_OWNER, REPO_NAME, REPO_BRANCH)

-- Colors (Theme: Deep Space / Nord)
local C_BG       = 0x1E1E2E 
local C_PANEL    = 0x252535 
local C_TEXT     = 0xCDD6F4 
local C_ACCENT   = 0x89B4FA 
local C_ACCENT_T = 0x1E1E2E 
local C_DIM      = 0x6C7086 
local C_SUCCESS  = 0xA6E3A1 
local C_WARN     = 0xF9E2AF 
local C_ERR      = 0xF38BA8 
local C_HEADER   = 0x11111B 

-- Box Drawing
local B = { H="─", V="│", TL="┌", TR="┐", BL="└", BR="┘", VL="┤", VR="├", TT="┬", TB="┴", X="┼", D="═" }

-- [[ 1. UTILITIES ]] --

if not internet and not DEBUG_MODE then error("Internet Card required.") end

local function parse_json_list(sJson)
    -- CRITICAL FIX: Remove newlines so pattern matching works across lines
    sJson = sJson:gsub("[\r\n]", " ")
    
    local tList = {}
    for sItem in sJson:gmatch("{.-}") do
        local sName = sItem:match('"name"%s*:%s*"(.-)"')
        local sType = sItem:match('"type"%s*:%s*"(.-)"')
        
        -- Grab any file, allowing for .lua, .c.lua, etc.
        if sName and sType == "file" then 
            table.insert(tList, sName) 
        end
    end
    return tList
end

local function http_get(sUrl)
    if DEBUG_MODE then return "[]" end
    local h, err = internet.request(sUrl, nil, {["User-Agent"]="AxisInstaller/2.6"})
    if not h then return nil, err end
    local buf = ""
    for chunk in h do buf = buf .. chunk end
    return buf
end

local function format_size(n)
    if not n then return "0B" end
    if n >= 10^9 then return string.format("%.1fG", n/10^9)
    elseif n >= 10^6 then return string.format("%.1fM", n/10^6)
    elseif n >= 10^3 then return string.format("%.1fK", n/10^3)
    else return string.format("%dB", n) end
end

local function minify_code(code)
    code = code:gsub("%-%-%[%[.-%]%]", "")
    code = code:gsub("%-%-[^\n]*", "")
    local lines = {}
    for line in code:gmatch("[^\r\n]+") do
        local trim = line:match("^%s*(.-)%s*$")
        if #trim > 0 then table.insert(lines, trim) end
    end
    return table.concat(lines, "\n")
end

-- [[ 2. UI FRAMEWORK ]] --

local W, H = gpu.getResolution()

local function clear()
    gpu.setBackground(C_BG); gpu.setForeground(C_TEXT); gpu.fill(1, 1, W, H, " ")
end

local function center_text(y, text, color)
    gpu.setForeground(color or C_TEXT)
    gpu.set(math.floor((W - unicode.len(text))/2), y, text)
end

local function draw_box(x, y, w, h, title, color_border, bg_override)
    gpu.setBackground(bg_override or C_BG)
    gpu.setForeground(color_border or C_DIM)
    local t_str = title and (" " .. title .. " ") or ""
    gpu.set(x, y, B.TL .. B.H .. t_str .. string.rep(B.H, w - unicode.len(t_str) - 4) .. B.TR)
    for i=1, h-2 do
        gpu.set(x, y+i, B.V); gpu.set(x+w-1, y+i, B.V)
    end
    gpu.set(x, y+h-1, B.BL .. string.rep(B.H, w-2) .. B.BR)
    gpu.setForeground(C_TEXT)
end

local function draw_header(subtitle)
    gpu.setBackground(C_HEADER); gpu.setForeground(C_ACCENT)
    gpu.fill(1, 1, W, 1, " ")
    gpu.set(2, 1, "AxisOS Installer" .. (subtitle and (" :: " .. subtitle) or ""))
    local time = os.date("%H:%M"); gpu.set(W - #time - 1, 1, time)
    gpu.setBackground(C_BG)
end

local function status_bar(text)
    gpu.setBackground(C_PANEL); gpu.setForeground(C_TEXT)
    gpu.fill(1, H, W, 1, " ")
    gpu.set(2, H, text); gpu.setBackground(C_BG)
end

local function confirm_dialog(msg)
    local bw, bh = #msg + 8, 5
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, "CONFIRM", C_WARN)
    center_text(by+1, msg, C_TEXT)
    center_text(by+3, "[Y]es   [N]o", C_ACCENT)
    while true do
        local _, _, _, code = event.pull("key_down")
        if code == 21 then return true  -- Y
        elseif code == 49 then return false -- N
        end
    end
end

local function input_box(title, default, is_pass)
    local bw, bh = 50, 3
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, title, C_ACCENT)
    local val = default or ""
    while true do
        local view = is_pass and string.rep("*", #val) or val
        gpu.set(bx+2, by+1, view .. "_   ")
        local _, _, ch, code = event.pull("key_down")
        if code == 28 then return val -- Enter
        elseif code == 1 then return nil -- Esc
        elseif code == 14 then val = unicode.sub(val, 1, -2)
        elseif ch > 0 and not require("keyboard").isControl(ch) then val = val .. unicode.char(ch) end
    end
end

local function dropdown_menu(x, y, options)
    local w = 20
    for _, o in ipairs(options) do w = math.max(w, #o + 4) end
    local h = #options + 2
    if x + w > W then x = W - w - 1 end
    if y + h > H then y = H - h - 1 end

    local sel = 1
    while true do
        gpu.setBackground(C_PANEL)
        gpu.fill(x, y, w, h, " ")
        gpu.setForeground(C_ACCENT)
        gpu.set(x, y, B.TL .. string.rep(B.H, w-2) .. B.TR)
        for i=1, #options do
            gpu.set(x, y+i, B.V); gpu.set(x+w-1, y+i, B.V)
            if i == sel then
                gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T)
            else
                gpu.setBackground(C_PANEL); gpu.setForeground(C_TEXT)
            end
            local txt = options[i]
            gpu.set(x+1, y+i, " " .. txt .. string.rep(" ", w - #txt - 3))
        end
        gpu.setBackground(C_PANEL); gpu.setForeground(C_ACCENT)
        gpu.set(x, y+h-1, B.BL .. string.rep(B.H, w-2) .. B.BR)
        
        local _, _, _, code = event.pull("key_down")
        if code == 200 then sel = sel > 1 and sel - 1 or #options
        elseif code == 208 then sel = sel < #options and sel + 1 or 1
        elseif code == 28 then gpu.setBackground(C_BG); return options[sel] 
        elseif code == 1 then gpu.setBackground(C_BG); return nil end
    end
end

local function draw_prog(pct, msg)
    local bw = W - 20
    local bx, by = 10, math.floor(H/2)
    gpu.fill(bx, by-1, bw, 4, " ")
    gpu.setForeground(C_TEXT)
    gpu.set(bx, by-1, msg)
    gpu.setBackground(C_PANEL); gpu.fill(bx, by+1, bw, 1, " ")
    gpu.setBackground(C_ACCENT); gpu.fill(bx, by+1, math.floor(pct*bw), 1, " ")
    gpu.setBackground(C_BG)
end

-- [[ 3. STATE & LOGIC ]] --

local State = {
    Hostname = "abox",
    RootPass = "toor",
    Users = {},
    Mounts = {},
    Packages = {},
    RepoCache = {}
}

-- [[ 4. DASHBOARD WIDGETS ]] --

local function draw_dashboard()
    local col_w = 32
    local lx, ly = 3, 3
    
    gpu.setForeground(C_ACCENT)
    gpu.set(lx, ly+0, "   /\\   AxisOS")
    gpu.set(lx, ly+1, "  /  \\   v2.6")
    gpu.set(lx, ly+2, " ( /\\ )  Installer")
    gpu.set(lx, ly+3, "  \\__/")
    
    ly = ly + 5
    draw_box(lx, ly, col_w, 10, "DETECTED HARDWARE", C_DIM)
    
    local hw_y = ly + 1
    local function print_hw(label, val)
        gpu.set(lx+2, hw_y, label .. ":")
        gpu.set(lx+12, hw_y, val)
        hw_y = hw_y + 1
    end
    
    gpu.setForeground(C_TEXT)
    print_hw("CPU", component.isAvailable("cpu") and "Zilog Z80" or "Unknown")
    
    local total_ram = computer.totalMemory()
    local free_ram = computer.freeMemory()
    print_hw("Memory", format_size(total_ram))
    
    local gpu_comp = component.gpu
    local rw, rh = gpu_comp.getResolution()
    print_hw("Display", rw .. "x" .. rh)
    
    local eeprom_size = component.eeprom.getSize()
    print_hw("EEPROM", format_size(eeprom_size))
    print_hw("Network", internet and "Online" or "Offline")
    
    hw_y = hw_y + 1
    local bar_w = col_w - 4
    local used_pct = (total_ram - free_ram) / total_ram
    gpu.setBackground(C_DIM); gpu.fill(lx+2, hw_y, bar_w, 1, " ")
    gpu.setBackground(used_pct > 0.8 and C_ERR or C_ACCENT)
    gpu.fill(lx+2, hw_y, math.ceil(bar_w * used_pct), 1, " ")
    gpu.setBackground(C_BG)
    
    ly = ly + 11
    gpu.setForeground(C_DIM)
    gpu.set(lx, ly, "Navigation:")
    gpu.set(lx, ly+1, string.rep(B.H, 20))
    gpu.setForeground(C_TEXT)
    gpu.set(lx, ly+2, "\24 \25 Arrows : Move")
    gpu.set(lx, ly+3, "ENTER      : Select")
end

-- [[ 5. MODULE: PARTITION MANAGER (AxisParted) ]] --

local function scan_drives()
    local drives = {}
    local tmp = computer.tmpAddress()
    for addr in component.list("filesystem") do
        local p = component.proxy(addr)
        if addr ~= tmp and p.getLabel() ~= "tmpfs" then
            table.insert(drives, {
                uuid = addr,
                label = p.getLabel() or "UNLABELED",
                total_size = p.spaceTotal(),
                ro = p.isReadOnly()
            })
        end
    end
    table.insert(drives, { uuid = "virtual", label = "VIRTUAL (RAM/KERNEL)", total_size = 0, ro = false })
    return drives
end

local function size_selector(max_size, current_size)
    if max_size == 0 then return 0 end 
    local size = current_size or math.floor(max_size / 2)
    local bw, bh = 60, 6
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    
    while true do
        gpu.fill(bx, by, bw, bh, " ")
        draw_box(bx, by, bw, bh, "PARTITION SIZE", C_ACCENT)
        local pct = size / max_size
        local bar_w = bw - 4
        local fill = math.floor(pct * bar_w)
        gpu.set(bx+2, by+1, string.format("Size: %s / %s (%.1f%%)", format_size(size), format_size(max_size), pct*100))
        gpu.setBackground(C_DIM); gpu.fill(bx+2, by+3, bar_w, 1, " ")
        gpu.setBackground(C_ACCENT); gpu.fill(bx+2, by+3, fill, 1, " "); gpu.setBackground(C_BG)
        gpu.set(bx+2, by+5, "LEFT/RIGHT: Adjust | ENTER: Confirm")
        local _, _, _, code = event.pull("key_down")
        local step = math.floor(max_size / 100) 
        if code == 203 then size = math.max(1024, size - step) 
        elseif code == 205 then size = math.min(max_size, size + step) 
        elseif code == 28 then return size
        elseif code == 1 then return nil end
    end
end

local function auto_partition_drive(drive)
    local bw, bh = 40, 8
    local bx, by = math.floor((W-bw)/2), math.floor((H-bh)/2)
    
    gpu.fill(bx, by, bw, bh, " ")
    draw_box(bx, by, bw, bh, "AUTO PARTITIONING", C_ACCENT)
    gpu.set(bx+2, by+2, "Calculating optimal layout...")
    
    -- Remove existing mounts for this drive
    local new_mounts = {}
    for _, m in ipairs(State.Mounts) do
        if m.uuid ~= drive.uuid then table.insert(new_mounts, m) end
    end
    State.Mounts = new_mounts
    
    os.sleep(0.5)
    
    local total = drive.total_size
    local swap_sz = math.min(512 * 1024, math.floor(total * 0.1))
    local log_sz  = math.min(256 * 1024, math.floor(total * 0.05))
    local home_sz = math.min(1024 * 1024, math.floor(total * 0.3))
    
    if total < 1024 * 1024 then
         table.insert(State.Mounts, { uuid = drive.uuid, mount = "/", type = "rootfs", options = "rw", label = drive.label })
         gpu.set(bx+2, by+4, "Layout: Single Root Partition")
    else
         table.insert(State.Mounts, { uuid = drive.uuid, mount = "none", type = "swap", options = "size="..swap_sz, size_limit = swap_sz, label = drive.label })
         table.insert(State.Mounts, { uuid = drive.uuid, mount = "/var/log", type = "ringfs", options = "rw,size="..log_sz, size_limit = log_sz, label = drive.label })
         table.insert(State.Mounts, { uuid = drive.uuid, mount = "/home", type = "homefs", options = "rw,size="..home_sz, size_limit = home_sz, label = drive.label })
         table.insert(State.Mounts, { uuid = drive.uuid, mount = "/", type = "rootfs", options = "rw", label = drive.label })
         
         gpu.set(bx+2, by+4, "Layout: Root, Home, Swap, Log")
    end
    
    for i=1, 20 do
        local p = i/20
        gpu.setBackground(C_DIM); gpu.fill(bx+2, by+6, bw-4, 1, " ")
        gpu.setBackground(C_SUCCESS); gpu.fill(bx+2, by+6, math.ceil((bw-4)*p), 1, " ")
        gpu.setBackground(C_BG)
        os.sleep(0.05)
    end
    os.sleep(0.5)
end

local function manage_drive_partitions(drive)
    local selected = 1
    
    local function next_type(curr)
        if curr == "rootfs" then return "homefs"
        elseif curr == "homefs" then return "ringfs"
        elseif curr == "ringfs" then return "swap"
        else return "rootfs" end
    end

    while true do
        local drive_mounts = {}
        local used_space = 0
        for i, m in ipairs(State.Mounts) do
            if m.uuid == drive.uuid then 
                table.insert(drive_mounts, {data=m, idx=i}) 
                used_space = used_space + (m.size_limit or 0)
            end
        end
        local free_space = drive.total_size - used_space
        
        clear()
        draw_header("Editing: " .. drive.label)
        
        gpu.setForeground(C_ACCENT)
        gpu.set(2, 3, "DISK UUID: " .. drive.uuid:sub(1,8))
        gpu.set(2, 4, string.format("CAPACITY : %s Total | %s Free", format_size(drive.total_size), format_size(free_space)))
            
        gpu.setForeground(C_DIM)
        gpu.set(2, 6, " ID   MOUNT POINT     TYPE          OPTS")
        gpu.set(2, 7, string.rep(B.H, W-4))
        
        local row_y = 8
        for i, entry in ipairs(drive_mounts) do
            if i == selected then gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T)
            else gpu.setBackground(C_BG); gpu.setForeground(C_TEXT) end
            
            local m = entry.data
            local size_str = m.size_limit and ("sz="..format_size(m.size_limit)) or "FULL"
            local line = string.format(" %-4d %-15s %-13s %-20s", i, m.mount, "<"..m.type..">", size_str)
            gpu.set(2, row_y, line .. string.rep(" ", W - #line - 2))
            row_y = row_y + 1
        end
        gpu.setBackground(C_BG)
        
        gpu.setForeground(C_ACCENT)
        gpu.set(2, row_y + 2, "[A]dd   [D]el   [T]oggle Type   [W]ipe & Auto   [B]ack")
        status_bar("A: Add | D: Del | T: Type | W: Auto-Partition (Lazy Mode)")
        
        local _, _, _, code = event.pull("key_down")
        if code == 200 and selected > 1 then selected = selected - 1 
        elseif code == 208 and selected < #drive_mounts then selected = selected + 1 
        elseif code == 30 then -- A (Add)
            if drive.uuid ~= "virtual" and free_space < 1024 then
                status_bar("No space left on device!")
                os.sleep(1)
            else
                local suggestions = {"/", "/home", "/boot", "/var", "/var/log", "swap", "Custom..."}
                local mp = dropdown_menu(10, row_y + 3, suggestions)
                
                if mp == "Custom..." then mp = input_box("Custom Mount Point", "/") end
                
                if mp then
                    local size = 0
                    if drive.uuid ~= "virtual" then size = size_selector(free_space, free_space) end
                    if size then
                        local ftype = "rootfs"
                        if mp:find("log") then ftype = "ringfs"
                        elseif mp:find("swap") then ftype = "swap"; mp = "none"
                        elseif mp:find("home") then ftype = "homefs" end
                        
                        local opts = "rw"
                        if size > 0 then opts = opts .. ",size="..size end
                        table.insert(State.Mounts, {
                            uuid = drive.uuid, mount = mp, type = ftype,
                            options = opts, size_limit = size, label = drive.label
                        })
                    end
                end
            end
        elseif code == 32 then -- D (Delete)
            if #drive_mounts > 0 then
                table.remove(State.Mounts, drive_mounts[selected].idx)
                if selected > 1 then selected = selected - 1 end
            end
        elseif code == 20 then -- T (Toggle Type)
            if #drive_mounts > 0 then
                local m = State.Mounts[drive_mounts[selected].idx]
                m.type = next_type(m.type)
            end
        elseif code == 17 then -- W (Wipe/Auto)
            if drive.uuid ~= "virtual" then
                if confirm_dialog("Wipe & Auto-Partition?") then
                    auto_partition_drive(drive)
                end
            end
        elseif code == 48 then return end
    end
end

local function run_partition_manager()
    local drives = scan_drives()
    local sel = 1
    while true do
        clear()
        draw_header("Disk Selection")
        center_text(3, ":: PHYSICAL STORAGE DEVICES ::", C_ACCENT)
        
        local ty = 5
        gpu.setForeground(C_DIM)
        gpu.set(2, ty, "DEVICE LABEL          UUID (SHORT)    CAPACITY   SLICES")
        gpu.set(2, ty+1, string.rep(B.H, W-4))
        ty = ty + 2
        
        for i, drv in ipairs(drives) do
            if i == sel then gpu.setBackground(C_ACCENT); gpu.setForeground(C_ACCENT_T) 
            else gpu.setForeground(C_TEXT) end
            local parts = 0
            for _, m in ipairs(State.Mounts) do if m.uuid == drv.uuid then parts = parts + 1 end end
            local line = string.format(" %-20s  %-14s  %-10s %-4d", 
                drv.label:sub(1,20), drv.uuid:sub(1,8).."...", format_size(drv.total_size), parts)
            gpu.set(2, ty, line .. string.rep(" ", W - #line - 2))
            gpu.setBackground(C_BG)
            ty = ty + 1
        end
        
        status_bar("ENTER: Select | B: Back")
        local _, _, _, code = event.pull("key_down")
        if code == 200 and sel > 1 then sel = sel - 1
        elseif code == 208 and sel < #drives then sel = sel + 1
        elseif code == 28 then manage_drive_partitions(drives[sel])
        elseif code == 48 then if confirm_dialog("Return to menu?") then return end end
    end
end

-- [[ 6. MODULE: PACKAGE SELECTOR ]] --

local PkgCategories = {
    { name = "Drivers",    path = "drivers",    type = "sys.lua" },
    { name = "Executable", path = "executable", type = "lua" },
    { name = "Modules",    path = "modules",    type = "lua" },
    { name = "Multilib",   path = "multilib",   type = "lua" }
}

local function run_package_selector()
    if #State.RepoCache == 0 then
        local bx, by = math.floor(W/2)-20, math.floor(H/2)-2
        gpu.fill(bx, by, 40, 5, " "); draw_box(bx, by, 40, 5, "SYNCING REPOS", C_ACCENT)
        for i, cat in ipairs(PkgCategories) do
            gpu.set(bx+2, by+2, "Fetching " .. cat.name .. "...")
            local raw = http_get(string.format("%s/%s?ref=%s", API_BASE, cat.path, REPO_BRANCH))
            if raw then
                local list = parse_json_list(raw)
                local items = {}
                for _, f in ipairs(list) do 
                    table.insert(items, {
                        name=f, 
                        path="src/packages/"..cat.path.."/"..f, 
                        selected=false, 
                        cat=cat.name
                    }) 
                end
                table.insert(State.RepoCache, {name=cat.name, items=items})
            end
            os.sleep(0.1)
        end
    end
    
    local cat_idx, file_idx, active_pane = 1, 1, 1
    while true do
        clear()
        draw_header("Pacstrap // Select Packages")
        
        local pane_w = math.floor((W - 4) / 2)
        local pane_h = H - 6
        
        draw_box(2, 3, pane_w, pane_h + 2, "REPOSITORIES", active_pane==1 and C_ACCENT or C_DIM)
        for i, cat in ipairs(State.RepoCache) do
            if i == cat_idx then gpu.setBackground(active_pane==1 and C_ACCENT or C_PANEL); gpu.setForeground(C_ACCENT_T)
            else gpu.setForeground(C_TEXT) end
            gpu.set(3, 4+i, " " .. cat.name .. string.rep(" ", pane_w - #cat.name - 3))
            gpu.setBackground(C_BG)
        end
        
        draw_box(2 + pane_w, 3, pane_w, pane_h + 2, "PACKAGES", active_pane==2 and C_ACCENT or C_DIM)
        local files = State.RepoCache[cat_idx].items
        local limit = pane_h
        local offset = 0
        if file_idx > limit then offset = file_idx - limit end
        for i=1, limit do
            local idx = i + offset
            if idx > #files then break end
            local f = files[idx]
            if idx == file_idx then gpu.setBackground(active_pane==2 and C_ACCENT or C_PANEL); gpu.setForeground(C_ACCENT_T)
            else gpu.setForeground(C_TEXT) end
            local mark = f.selected and "[*]" or "[ ]"
            local txt = string.format(" %s %s", mark, f.name)
            gpu.set(3 + pane_w, 4+i, txt .. string.rep(" ", pane_w - #txt - 2))
            gpu.setBackground(C_BG)
        end
        
        status_bar("TAB: Switch | SPACE: Toggle | S: Save | B: Back")
        local _, _, _, code = event.pull("key_down")
        if code == 15 then active_pane = (active_pane == 1) and 2 or 1 
        elseif code == 200 then 
            if active_pane == 1 then if cat_idx > 1 then cat_idx=cat_idx-1; file_idx=1 end
            else if file_idx > 1 then file_idx=file_idx-1 end end
        elseif code == 208 then 
            if active_pane == 1 then if cat_idx < #State.RepoCache then cat_idx=cat_idx+1; file_idx=1 end
            else if file_idx < #files then file_idx=file_idx+1 end end
        elseif code == 57 and active_pane == 2 then files[file_idx].selected = not files[file_idx].selected
        elseif code == 31 then 
            State.Packages = {}
            for _, cat in ipairs(State.RepoCache) do
                for _, f in ipairs(cat.items) do if f.selected then table.insert(State.Packages, f) end end
            end
            return
        elseif code == 48 then return end
    end
end

-- [[ 7. INSTALLATION ]] --

local function install_os()
    local root_uuid = nil
    for _, m in ipairs(State.Mounts) do if m.mount == "/" then root_uuid = m.uuid end end
    if not root_uuid then status_bar("Error: No Root Partition!"); os.sleep(2); return end
    
    clear(); draw_header("Installing AxisOS")
    draw_prog(0.05, "Formatting Root...")
    
    -- 0. Set Label
    local proxy = component.proxy(root_uuid)
    proxy.setLabel("AxisOS")
    
    for _, f in ipairs(proxy.list("/")) do proxy.remove(f) end
    
    local dirs = {"/boot", "/bin", "/lib", "/etc", "/home", "/drivers", "/system", "/sys", "/usr", "/var/log", "/usr/commands", "/system/lib/dk", "/sys/security"}
    for _, d in ipairs(dirs) do proxy.makeDirectory(d) end
    
    local manifest = {
        { s="/kernel/kernel.lua", d="/boot/kernel.lua" },
        { s="/kernel/bin/init.lua", d="/bin/init.lua" },
        { s="/kernel/bin/sh.lua", d="/bin/sh.lua" },
        { s="/kernel/lib/errcheck.lua", d="/lib/errcheck.lua" },
        { s="/kernel/lib/filesystem.lua", d="/lib/filesystem.lua" },
        { s="/kernel/lib/pipeline_manager.lua", d="/lib/pipeline_manager.lua" },
        { s="/kernel/lib/syscall.lua", d="/lib/syscall.lua" },
        { s="/kernel/system/dkms.lua", d="/system/dkms.lua" },
        { s="/kernel/system/driverdispatch.lua", d="/system/driverdispatch.lua" },
        { s="/kernel/system/lib/dk/shared_structs.lua", d="/system/lib/dk/shared_structs.lua" },
        { s="/kernel/system/lib/dk/kmd_api.lua", d="/system/lib/dk/kmd_api.lua" },
        { s="/kernel/system/lib/dk/common_api.lua", d="/system/lib/dk/common_api.lua" },
        { s="/kernel/sys/security/dkms_sec.lua", d="/sys/security/dkms_sec.lua" },
        { s="/kernel/drivers/tty.sys.lua", d="/drivers/tty.sys.lua" },
        { s="/kernel/drivers/gpu.sys.lua", d="/drivers/gpu.sys.lua" },
        { s="/kernel/drivers/keyboard.sys.lua", d="/drivers/keyboard.sys.lua" },
        { s="/kernel/drivers/ringfs.sys.lua", d="/drivers/ringfs.sys.lua" },
        { s="/kernel/usr/commands/ls.lua", d="/usr/commands/ls.lua" }
    }
    
    local total = #manifest + #State.Packages + 8
    local done = 0
    local function dl(url, dest)
        done = done + 1
        draw_prog(done/total, "Downloading " .. dest)
        local d = http_get(url)
        if d then local h = proxy.open(dest, "w"); proxy.write(h, d); proxy.close(h) end
    end
    
    -- 1. Core System
    for _, f in ipairs(manifest) do dl(RAW_BASE .. "/src" .. f.s, f.d) end
    
    -- 2. Packages
    for _, p in ipairs(State.Packages) do
        local pre = "/usr/misc"
        if p.cat == "Drivers" then pre = "/drivers"
        elseif p.cat == "Executable" then pre = "/usr/commands"
        elseif p.cat == "Modules" then pre = "/lib"
        elseif p.cat == "Multilib" then pre = "/usr/lib" end
        dl(RAW_BASE .. "/" .. p.path, pre .. "/" .. p.name)
    end
    
    -- 3. Configuration Generation
    draw_prog(0.9, "Generating Configs...")
    
    local fstab = "-- AxisOS File System Table\nreturn {\n"
    for _, m in ipairs(State.Mounts) do
        if m.uuid ~= "virtual" then
            local pth = "/dev/disk_" .. m.uuid:sub(1,4)
            local mnt = (m.type == "swap") and "none" or m.mount
            fstab = fstab .. string.format('  { uuid="%s", path="%s", mount="%s", type="%s", options="%s" },\n',
                m.uuid, pth, mnt, m.type, m.options)
        end
    end
    -- Always add system log
    fstab = fstab .. '  { uuid="virtual", path="/dev/ringlog", mount="/var/log/syslog", type="ringfs", options="rw,size=8192" },\n'
    fstab = fstab .. "}"
    
    local h = proxy.open("/etc/fstab.lua", "w"); proxy.write(h, fstab); proxy.close(h)
    
    local passwd = "return {\n"
    passwd = passwd .. string.format('  root={uid=0, home="/root", shell="/bin/sh.lua", hash="%sAURA_SALT", ring=3},\n', string.reverse(State.RootPass))
    for _, u in ipairs(State.Users) do
        passwd = passwd .. string.format('  ["%s"]={uid=%d, home="/home/%s", shell="/bin/sh.lua", hash="%sAURA_SALT", ring=%d},\n',
             u.name, u.sudo and 0 or 1000, u.name, string.reverse(u.pass), u.sudo and 0 or 3)
    end
    passwd = passwd .. "}"
    h = proxy.open("/etc/passwd.lua", "w"); proxy.write(h, passwd); proxy.close(h)
    h = proxy.open("/etc/hostname", "w"); proxy.write(h, State.Hostname); proxy.close(h)
    
    -- 4. EEPROM / BIOS Flashing
    draw_prog(0.95, "Flashing BIOS (boot.lua)...")
    if component.isAvailable("eeprom") then
        local bios_url = RAW_BASE .. "/src/bios/boot.lua"
        local bios_code = http_get(bios_url)
        
        if bios_code then
            local min_bios = minify_code(bios_code)
            component.eeprom.set(min_bios)
            component.eeprom.setLabel("AxisBIOS v6")
            component.eeprom.setData(root_uuid)
            computer.setBootAddress(root_uuid)
        else
            status_bar("Failed to download BIOS! Continuing with current EEPROM...")
            os.sleep(2)
        end
    end
    
    draw_prog(1.0, "Installation Complete. Rebooting..."); os.sleep(2); computer.shutdown(true)
end

-- [[ 8. MAIN MENU ]] --

local function main_menu()
    local menu_state = 1
    
    while true do
        clear()
        draw_header()
        draw_dashboard()
        
        local mx, my = 38, 3
        local mw = W - mx - 2
        local mh = H - 5
        
        draw_box(mx, my, mw, mh, " CONFIGURATION ", C_ACCENT)
        
        local root_dev = "Not Selected"
        for _, m in ipairs(State.Mounts) do if m.mount == "/" then root_dev = m.uuid:sub(1,8).."..." end end
        
        local items = {
            { txt="Disk Configuration", val="[ "..root_dev.." ]", fn=run_partition_manager },
            { txt="Packages",           val="[ "..#State.Packages.." Selected ]", fn=run_package_selector },
            { txt="Hostname",           val="[ "..State.Hostname.." ]", fn=function() State.Hostname = input_box("Hostname", State.Hostname) or State.Hostname end },
            { txt="Root Password",      val="[ "..(State.RootPass == "toor" and "Default" or "*****").." ]", fn=function() State.RootPass = input_box("Root Password", State.RootPass, true) or State.RootPass end },
            { txt="User Accounts",      val="[ "..#State.Users.." Created ]", fn=function() 
                 local u = input_box("Username", "")
                 if u then table.insert(State.Users, {name=u, pass=input_box("Password", "", true), sudo=false}) end
            end },
            { txt="------------------", val="", fn=nil },
            { txt="Install AxisOS",     val=">>>", fn=install_os },
            { txt="Abort",              val="", fn=function() if confirm_dialog("Quit?") then os.exit() end end }
        }
        
        local iy = my + 2
        for i, item in ipairs(items) do
            if item.fn then
                if i == menu_state then 
                    gpu.setForeground(C_ACCENT)
                    gpu.set(mx+2, iy, "> " .. item.txt)
                else
                    gpu.setForeground(C_TEXT)
                    gpu.set(mx+2, iy, "  " .. item.txt)
                end
                if item.val ~= "" then
                    gpu.setForeground(i == menu_state and C_ACCENT or C_DIM)
                    gpu.set(mx + mw - #item.val - 2, iy, item.val)
                end
            else
                gpu.setForeground(C_DIM)
                gpu.set(mx+2, iy, string.rep(B.H, mw-4))
            end
            iy = iy + 1
        end
        
        local _, _, _, code = event.pull("key_down")
        if code == 200 then 
            repeat menu_state = menu_state - 1 
                if menu_state < 1 then menu_state = #items end 
            until items[menu_state].fn
        elseif code == 208 then
            repeat menu_state = menu_state + 1 
                if menu_state > #items then menu_state = 1 end 
            until items[menu_state].fn
        elseif code == 28 then
            if items[menu_state].fn then items[menu_state].fn() end
        elseif code == 16 then
            if confirm_dialog("Quit?") then os.exit() end
        end
    end
end

gpu.setResolution(W, H)
main_menu()