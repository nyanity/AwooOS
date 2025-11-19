-- ls - list directory (Pro Edition)
-- now with colors and -l support. fancy.

local fs = require("filesystem")
local tArgs = env.ARGS or {}

-- ANSI Colors
local C_RESET  = "\27[37m"
local C_DIR    = "\27[34m" -- Blue
local C_DEV    = "\27[33m" -- Yellow
local C_EXEC   = "\27[32m" -- Green
local C_FILE   = "\27[37m" -- White
local C_GRAY   = "\27[90m" -- Gray for metadata

-- Parse arguments
local bLongMode = false
local sPath = nil

for _, sArg in ipairs(tArgs) do
  if sArg == "-l" then
    bLongMode = true
  elseif not sPath then
    sPath = sArg
  end
end

local sPwd = env.PWD or "/"
local sTargetDir = sPath or sPwd

-- Resolve relative paths
if sTargetDir:sub(1,1) ~= "/" then
  sTargetDir = sPwd .. (sPwd == "/" and "" or "/") .. sTargetDir
end
-- Clean double slashes
sTargetDir = sTargetDir:gsub("//", "/")

-- Get file list
local tList, sErr = fs.list(sTargetDir)
if not tList or type(tList) ~= "table" then
  print("ls: cannot access '" .. sTargetDir .. "': " .. tostring(sErr or "No such file"))
  return
end

table.sort(tList)

-- Try to load permissions DB for -l mode
-- We might not have read access if we are guest, so pcall it.
local tPermsDb = {}
if bLongMode then
  local hPerms = fs.open("/etc/perms.lua", "r")
  if hPerms then
    local sData = fs.read(hPerms, math.huge)
    fs.close(hPerms)
    if sData then
       local f = load(sData, "perms", "t", {})
       if f then tPermsDb = f() end
    end
  end
end

-- Helper to format mode (755 -> rwxr-xr-x)
local function format_mode(nMode)
  if not nMode then return "rwxr-xr-x" end -- default
  local sM = string.format("%03d", nMode)
  local sRes = ""
  local tMaps = { [7]="rwx", [6]="rw-", [5]="r-x", [4]="r--", [0]="---" }
  for i=1, 3 do
    local c = tonumber(sM:sub(i,i))
    sRes = sRes .. (tMaps[c] or "???")
  end
  return sRes
end

-- Buffer for output
local tBuffer = {}

for _, sName in ipairs(tList) do
  local bIsDir = (sName:sub(-1) == "/")
  local sCleanName = bIsDir and sName:sub(1, -2) or sName
  local sFullPath = sTargetDir .. (sTargetDir == "/" and "" or "/") .. sCleanName
  
  -- Determine type and color
  local sColor = C_FILE
  local sTypeChar = "-"
  
  if bIsDir then
    sColor = C_DIR
    sTypeChar = "d"
  elseif sTargetDir:sub(1, 5) == "/dev/" then
    sColor = C_DEV -- Block device (yellow)
    sTypeChar = "c" -- char device technically
  elseif sName:sub(-4) == ".lua" then
    sColor = C_EXEC -- Executable script (green)
  end
  
  if bLongMode then
    -- Long format: drwxr-xr-x 0 root filename
    local tP = tPermsDb[sFullPath]
    local sModeStr = format_mode(tP and tP.mode)
    local nUid = tP and tP.uid or 0
    local sOwner = (nUid == 0) and "root" or tostring(nUid)
    
    -- Pad owner name
    if #sOwner < 5 then sOwner = sOwner .. string.rep(" ", 5 - #sOwner) end
    
    local sLine = string.format("%s%s%s %s %s%s%s", 
      C_GRAY, sTypeChar .. sModeStr, C_RESET,
      sOwner,
      sColor, sName, C_RESET
    )
    table.insert(tBuffer, sLine)
  else
    -- Short format: just colored names
    table.insert(tBuffer, sColor .. sName .. C_RESET)
  end
end

-- Print
if #tBuffer > 0 then
  local hStdout = {fd=1}
  fs.write(hStdout, table.concat(tBuffer, "\n") .. "\n")
end