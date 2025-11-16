local oComponent = require("component")
local oEvent = require("event")
local oTerm = require("term")
local oFs = require("filesystem")
local oInternet = oComponent.internet
local oGpu = oComponent.gpu -- ADDED: gotta get the gpu component for pretty colors

-- CONFIG: where we get the good stuff.
-- all files are pulled from github. what could possibly go wrong?
local sBASE_URL = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/v0.2N25/src/kernel/"
local tFileList = {
  ["kernel.lua"] = sBASE_URL .. "kernel.lua",
  ["lib/pipeline_manager.lua"] = sBASE_URL .. "lib/pipeline_manager.lua",
  ["lib/ringfs_driver.lua"] = sBASE_URL .. "lib/ringfs_driver.lua",
  ["lib/swap_driver.lua"] = sBASE_URL .. "lib/swap_driver.lua",
  ["lib/filesystem.lua"] = sBASE_URL .. "lib/filesystem.lua",
  ["lib/syscall.lua"] = sBASE_URL .. "lib/syscall.lua",
  ["drivers/gpu.sys.lua"] = sBASE_URL .. "drivers/gpu.sys.lua",
  ["drivers/filesystem.sys.lua"] = sBASE_URL .. "drivers/filesystem.sys.lua",
  ["drivers/tty.sys.lua"] = sBASE_URL .. "drivers/tty.sys.lua",
  ["bin/init.lua"] = sBASE_URL .. "bin/init.lua",
  ["bin/sh.lua"] = sBASE_URL .. "bin/sh.lua",
  ["usr/commands/ls.lua"] = sBASE_URL .. "usr/commands/ls.lua",
  ["usr/commands/su.lua"] = sBASE_URL .. "usr/commands/su.lua",
  ["usr/commands/reboot.lua"] = sBASE_URL .. "usr/commands/reboot.lua",
}


-- TUI helper functions. because raw term calls are a pain.
local tui = {}

function tui.clear()
  oTerm.clear()
  oTerm.setCursor(1, 1)
end

function tui.writeAt(nX, nY, sText)
  oTerm.setCursor(nX, nY)
  oTerm.write(sText)
end

function tui.prompt(nX, nY, sPromptText)
  tui.writeAt(nX, nY, sPromptText)
  return oTerm.read()
end

function tui.drawBox(nX1, nY1, nX2, nY2, sTitle)
  local nW, nH = nX2 - nX1 + 1, nY2 - nY1 + 1
  tui.writeAt(nX1, nY1, "┌" .. string.rep("─", nW - 2) .. "┐")
  for nY = nY1 + 1, nY2 - 1 do
    tui.writeAt(nX1, nY, "│")
    tui.writeAt(nX2, nY, "│")
  end
  tui.writeAt(nX1, nY2, "└" .. string.rep("─", nW - 2) .. "┘")
  if sTitle then
    tui.writeAt(nX1 + 2, nY1, "[ " .. sTitle .. " ]")
  end
end

    
function tui.menu(nX, nY, tOptions, sTitle)
  local nW, nH = 0, #tOptions + 2
  for _, sOpt in ipairs(tOptions) do
    if #sOpt > nW then nW = #sOpt end
  end
  nW = nW + 4 -- some padding so it doesn't look cramped
  
  tui.drawBox(nX, nY, nX + nW - 1, nY + nH - 1, sTitle)
  
  local nSelected = 1
  local function redraw()
    for i, sOpt in ipairs(tOptions) do
      if i == nSelected then
        -- inverted colors for the selected item. classic.
        oGpu.setBackground(0xEEEEEE)
        oGpu.setForeground(0x000000)
      end
      tui.writeAt(nX + 2, nY + 1 + i - 1, string.format("%-".. (nW - 4) .."s", sOpt))
      oGpu.setBackground(0x000000)
      oGpu.setForeground(0xEEEEEE)
    end
  end
  
  redraw()
  
  while true do
    -- MODIFIED: grab the fourth value (nKeyCode), not the non-existent sixth (sName)
    local _, _, _, nKeyCode = oEvent.pull("key_down")
    
    -- key codes for up/down/enter. magic numbers!
    local KEY_UP = 200
    local KEY_DOWN = 208
    local KEY_ENTER = 28

    if nKeyCode == KEY_DOWN then -- MODIFIED: compare with the key code
      nSelected = math.min(#tOptions, nSelected + 1)
      redraw()
    elseif nKeyCode == KEY_UP then -- MODIFIED: compare with the key code
      nSelected = math.max(1, nSelected + 1)
      redraw()
    elseif nKeyCode == KEY_ENTER then -- MODIFIED: compare with the key code
      return nSelected, tOptions[nSelected]
    end
  end
end

-- http_get, our little internet fetcher.
local function http_get(sUrl)
  local hHandle, sReason = oInternet.request(sUrl)
  if not hHandle then
    return nil, "Request failed: " .. tostring(sReason)
  end
  local sData = ""
  while true do
    -- read the response in chunks until it's all gone.
    local sChunk, sReason = hHandle.read(math.huge)
    if not sChunk then
      if sReason then
        return nil, "Read failed: " .. tostring(sReason)
      else
        return sData
      end
    end
    sData = sData .. sChunk
  end
end

-- filesystem helpers. mkdir -p is a must.
local function mkdir_p(oProxy, sPath)
  local tParts = {}
  for sPart in string.gmatch(sPath, "([^/]+)") do
    table.insert(tParts, sPart)
  end
  
  local sCurrentPath = ""
  for _, sPart in ipairs(tParts) do
    sCurrentPath = sCurrentPath .. "/" .. sPart
    if not oProxy.exists(sCurrentPath) then
      oProxy.makeDirectory(sCurrentPath)
    end
  end
end

-- opens, writes, and closes a file. foolproof.
local function write_file(oProxy, sPath, sContent)
  local hFile, sReason = oProxy.open(sPath, "w")
  if not hFile then
    return nil, "Failed to open " .. sPath .. ": " .. tostring(sReason)
  end
  local bOk, sReason = oProxy.write(hFile, sContent)
  oProxy.close(hFile)
  if not bOk then
    return nil, "Failed to write to " .. sPath .. ": " .. tostring(sReason)
  end
  return true
end

-- Installer Logic. let's get this party started.
local function main()
  if not oInternet then
    print("This installer requires an 'internet' component. duh.")
    return
  end
  if not oGpu then -- ADDED: check for a gpu
    print("This installer requires a 'gpu' component for the fancy UI.")
    return
  end

  tui.clear()
  tui.writeAt(1, 1, "AwooOS Installer - Step 1: Download Files")
  tui.drawBox(1, 2, 70, 10)
  
  -- lua doesn't have a simple # for tables with string keys. sigh.
  local nFileCount = 0
  for _ in pairs(tFileList) do nFileCount = nFileCount + 1 end
  
  tui.writeAt(3, 3, "Preparing to download " .. nFileCount .. " files from Github...")
  local tOsFiles = {}
  local nY = 5
  for sFilepath, sUrl in pairs(tFileList) do
    tui.writeAt(3, nY, "Downloading " .. sFilepath .. "...")
    local sCode, sErr = http_get(sUrl)
    if not sCode then
      tui.writeAt(3, nY + 1, "ERROR: " .. sErr)
      return
    end
    tOsFiles[sFilepath] = sCode
    tui.writeAt(60, nY, "OK")
    nY = nY + 1
    -- redraw the box to clear the "OK" messages and loop the display. simple animation!
    if nY > 9 then nY = 4; tui.drawBox(1, 2, 70, 10) end
  end
  
  tui.writeAt(3, 9, "All files downloaded successfully.")
  tui.prompt(1, 11, "Press Enter to continue to Step 2 (Partitioning)...")

  -- Step 2: let's find a drive to ruin.
  tui.clear()
  tui.writeAt(1, 1, "AwooOS Installer - Step 2: Drive Selection")
  
  local tDrives = {}
  for sAddr, sCompType in oComponent.list("filesystem") do
    -- we only want drives we can actually write to.
    if not oComponent.proxy(sAddr).isReadOnly() then
      tDrives[#tDrives + 1] = {
        address = sAddr,
        label = oComponent.proxy(sAddr).getLabel() or sAddr
      }
    end
  end
  
  if #tDrives == 0 then
    tui.writeAt(1, 3, "No writable hard drives found.")
    tui.writeAt(1, 4, "Please install a hard drive and reboot.")
    return
  end

  local tOptions = {}
  for _, tDrive in ipairs(tDrives) do
    table.insert(tOptions, tDrive.label .. " (" .. string.sub(tDrive.address, 1, 13) .. "...)")
  end
  
  local nSel, _ = tui.menu(5, 3, tOptions, "Select Target Drive")
  local tTargetDrive = tDrives[nSel]
  local oTargetProxy = oComponent.proxy(tTargetDrive.address)
  
  tui.clear()
  tui.writeAt(1, 1, "AwooOS Installer - Step 2: Partition Sizing")
  tui.drawBox(1, 2, 60, 10, "Configure Virtual Partitions (in KB)")
  
  local nHomeSize = tui.prompt(3, 4, "Size for /home (e.g., 1024000 for 1GB): ")
  local nSwapSize = tui.prompt(3, 5, "Size for /swap (e.g., 512000 for 512MB): ")
  local nLogSize  = tui.prompt(3, 6, "Size for /log (e.g., 256000 for 256MB): ")
  
  nHomeSize = tonumber(nHomeSize) or 1024000
  nSwapSize = tonumber(nSwapSize) or 512000
  nLogSize  = tonumber(nLogSize)  or 256000
  
  tui.writeAt(1, 11, "Target: " .. tTargetDrive.label)
  tui.writeAt(1, 12, "UUID:   " .. tTargetDrive.address)
  tui.writeAt(1, 13, "Sizes:  Home="..nHomeSize.."KB, Swap="..nSwapSize.."KB, Log="..nLogSize.."KB")
  
  -- the point of no return. make sure they're REALLY sure.
  local sConfirm = tui.prompt(1, 15, "WARNING: This will format the drive. Continue? (yes/no): ")
  if not sConfirm or sConfirm:match("^%s*(.-)%s*$"):lower() ~= "yes" then
    tui.clear()
    tui.writeAt(1, 1, "Installation cancelled. Phew.")
    return
  end
  
  -- Step 3: the main event. writing files to the drive.
  tui.clear()
  tui.writeAt(1, 1, "AwooOS Installer - Step 3: Installing")
  tui.drawBox(1, 2, 70, 15)
  
  tui.writeAt(3, 3, "Formatting target drive...")
  -- this isn't a real format, just a "rm -rf /" on the key directories.
  local tOldDirs = {"/etc", "/bin", "/lib", "/usr", "/drivers", "/home", "/log", "/tmp", "/kernel.lua", "/swapfile"}
  for _, sDir in ipairs(tOldDirs) do
    if oTargetProxy.exists(sDir) then
      oTargetProxy.remove(sDir)
    end
  end
  
  tui.writeAt(3, 4, "Creating directory structure...")
  mkdir_p(oTargetProxy, "/etc"); mkdir_p(oTargetProxy, "/bin"); mkdir_p(oTargetProxy, "/lib")
  mkdir_p(oTargetProxy, "/usr/commands"); mkdir_p(oTargetProxy, "/usr/lib"); mkdir_p(oTargetProxy, "/drivers")
  mkdir_p(oTargetProxy, "/home"); mkdir_p(oTargetProxy, "/log"); mkdir_p(oTargetProxy, "/tmp")

  tui.writeAt(3, 5, "Writing OS files...")
  nY = 6
  for sFilepath, sContent in pairs(tOsFiles) do
    tui.writeAt(5, nY, "Writing " .. sFilepath .. "...")
    local bOk, sErr = write_file(oTargetProxy, "/" .. sFilepath, sContent)
    if not bOk then
      tui.writeAt(5, nY + 1, "ERROR: " .. sErr)
      return
    end
    nY = nY + 1
    if nY > 14 then nY = 6; tui.drawBox(1, 2, 70, 15) end -- clear box
  end

  tui.writeAt(3, 14, "All OS files written.")
  
  tui.writeAt(3, 16, "Creating /etc/fstab.lua...")
  -- the most sacred of all unix-like config files.
  local sFstabContent = string.format([[
-- AwooOS File System Table
return {
  { uuid = "%s", path = "/", mount = "/", type = "rootfs", options = "rw", },
  { uuid = "%s", path = "/home", mount = "/home", type = "homefs", options = "rw,size=%d", },
  { uuid = "%s", path = "/swapfile", mount = "none", type = "swap", options = "size=%d", },
  { uuid = "%s", path = "/log", mount = "/var/log", type = "ringfs", options = "rw,size=%d", },
}
]], tTargetDrive.address, tTargetDrive.address, nHomeSize, tTargetDrive.address, nSwapSize, tTargetDrive.address, nLogSize)
  
  write_file(oTargetProxy, "/etc/fstab.lua", sFstabContent)
  
  tui.writeAt(3, 17, "Creating /etc/passwd.lua...")
  -- next, the password file. with super secure hardcoded passwords.
  local sPasswdContent = [[
-- AwooOS Password File
-- Hashes are simple: string.reverse(pass) .. "AURA_SALT"
return {
  root = { hash = "toorAURA_SALT", uid = 0, gid = 0, shell = "/bin/sh.lua", home = "/home/root", },
  user = { hash = "resuAURA_SALT", uid = 1000, gid = 1000, shell = "/bin/sh.lua", home = "/home/user", },
}
]]
  write_file(oTargetProxy, "/etc/passwd.lua", sPasswdContent)
  
  tui.writeAt(3, 18, "Creating swap file...")
  local hSwapFile, sErr = oTargetProxy.open("/swapfile", "w")
  if hSwapFile then
    -- this is the OC way of making a large, sparse file. seek and poke.
    oTargetProxy.seek(hSwapFile, "set", nSwapSize * 1024)
    oTargetProxy.write(hSwapFile, "\0")
    oTargetProxy.close(hSwapFile)
  else
    tui.writeAt(3, 19, "Warning: Could not create swap file: " .. tostring(sErr))
  end
  
  tui.writeAt(1, 20, "--------------------------------------------------")
  tui.writeAt(1, 21, "AwooOS Installation Complete!")
  tui.writeAt(1, 22, "You may now remove the installer disk and reboot.")
end

main()