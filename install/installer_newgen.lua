--
local oComponent = require("component")
local oEvent = require("event")
local oTerm = require("term")
local oFs = require("filesystem")
local oOs = require("os") 
local oKeyboard = require("keyboard")
local oComputer = require("computer")
local oUnicode = require("unicode")
local oGpu = oComponent.gpu
local oInternet = oComponent.internet

local DEBUG_MODE = true

if not oInternet and not DEBUG_MODE then
  error("This installer requires an Internet Card.")
  return
end

local g_sBaseGitApiUrl = "https://api.github.com/repos/nyanity/AxisOS"
local g_sKernelPath = "/src/kernel/"
local g_sBiosPath = "/src/bios/"

local g_tFilesToDownload = {}

-- Git Branch Management
local g_tAvalailableBranches = { 
    sCurrentBranch = "main", 
    tAllBranches = { },
    bFetched = false 
}

--------------------------------------------------------------------------------
-- Github API Functions
--------------------------------------------------------------------------------

local function fFetchBranches(bForceRefresh)
    -- If it has already been downloaded and we are not asking for a forced update -> exit
    if g_tAvalailableBranches.bFetched and not bForceRefresh then
        return true
    end

    local w, h = oGpu.getResolution()
    oGpu.fill(1, h, w, 1, " ")
    
    --
    if DEBUG_MODE then
        oGpu.set(1, h, "Status: [DEBUG] Generating fake branches...")
        oOs.sleep(0.5) -- Network delay simulation
        
        g_tAvalailableBranches.tAllBranches = { "main" }
        -- Generate 1 to 4 additional branches
        local nCount = math.random(1, 4)
        for i = 1, nCount do
            local sRandomName = string.format("feat-%d-update", math.random(100, 999))
            table.insert(g_tAvalailableBranches.tAllBranches, sRandomName)
        end
        
        g_tAvalailableBranches.bFetched = true
        oGpu.fill(1, h, w, 1, " ")
        return true
    end
    --

    local sUrl = g_sBaseGitApiUrl .. "/branches"
    local tHeaders = { ["User-Agent"] = "AxisInstallScript" }

    oGpu.set(1, h, "Status: Fetching branches from GitHub...")

    local hHandle, sError = oInternet.request(sUrl, nil, tHeaders)
    if not hHandle then
        oGpu.set(1, h, "Error: " .. tostring(sError))
        oOs.sleep(2)
        return false
    end

    local sResponse = ""
    repeat
        local sChunk = hHandle.read(math.huge)
        if sChunk then sResponse = sResponse .. sChunk end
    until not sChunk
    hHandle.close()

    g_tAvalailableBranches.tAllBranches = {}
    for sBranchName in sResponse:gmatch('"name"%s*:%s*"(.-)"') do
        table.insert(g_tAvalailableBranches.tAllBranches, sBranchName)
    end

    g_tAvalailableBranches.bFetched = true
    oGpu.fill(1, h, w, 1, " ")
    return true
end

local function fFetchRecursive(sPath)
    local sCleanPath = sPath
    if sCleanPath:sub(1,1) == "/" then sCleanPath = sCleanPath:sub(2) end

    local sUrl = g_sBaseGitApiUrl .. "/contents/" .. sCleanPath .. "?ref=" .. g_tAvalailableBranches.sCurrentBranch
    local tHeaders = { ["User-Agent"] = "AxisOS-Installer" }

    local w, h = oGpu.getResolution()
    oGpu.fill(1, h, w, 1, " ")
    oGpu.set(1, h, "Scanning: " .. sCleanPath)

    local hHandle = oInternet.request(sUrl, nil, tHeaders)
    oOs.sleep(0.5)

    if not hHandle then return end

    local sResponse = ""
    repeat
        local sChunk = hHandle.read(math.huge)
        if sChunk then sResponse = sResponse .. sChunk end
    until not sChunk
    hHandle.close()
    
    for sJsonObj in sResponse:gmatch("{(.-)}") do
        local sType = sJsonObj:match('"type"%s*:%s*"(.-)"')
        local sFilePath = sJsonObj:match('"path"%s*:%s*"(.-)"')

        if sType and sFilePath then
            if sType == "file" then
                table.insert(g_tFilesToDownload, sFilePath)
            elseif sType == "dir" then
                fFetchRecursive(sFilePath)
            end
        end
    end
end

local function fFetchFilesFromBranch()
    g_tFilesToDownload = {}
    
    local w, h = oGpu.getResolution()
    oGpu.fill(1, h, w, 1, " ")

    --
    if DEBUG_MODE then
        oGpu.set(1, h, "Status: [DEBUG] Simulating file scan...")
        oOs.sleep(0.8)
        
        local tPrefixes = { 
            g_sKernelPath:sub(2),
            g_sBiosPath:sub(2) 
        }
        
        local nFiles = math.random(3, 5)
        for i = 1, nFiles do
            local sPrefix = tPrefixes[math.random(1, #tPrefixes)]
            local sName = string.format("module_%d.lua", math.random(10, 99))
            table.insert(g_tFilesToDownload, sPrefix .. sName)
        end
        
        oGpu.fill(1, h, w, 1, " ")
        return true
    end
    --]]

    fFetchRecursive(g_sKernelPath)
    fFetchRecursive(g_sBiosPath)
    return true
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Constants & Visual Configuration
--------------------------------------------------------------------------------

-- Color Palette (0xRRGGBB)
local g_nColorBack = 0x000000           -- Main background (Black)
local g_nColorText = 0xFFFFFF           -- Main text (White)
local g_nColorHighlightBack = 0x0000AA  -- Selection background (Arch Blue)
local g_nColorHighlightText = 0xFFFFFF  -- Selection text (White)
local g_nColorDim = 0x999999            -- Dimmed/Inactive text

-- Screen padding
local g_nPadX = 2
local g_nPadY = 1

-- Unicode Box Drawing Characters (U+2500 range)
-- Used to draw continuous lines and tables without gaps.
local g_tBox = {
    H = "─", V = "│",
    TL = "┌", TR = "┐",
    BL = "└", BR = "┘",
    VL = "┤", VR = "├",
    TT = "┬", TB = "┴",
    X  = "┼"
}

-- Enum for Menu Item Types determines how the UI Engine handles interaction
local g_tTypes = {
    ITEM_TYPE_INPUT = 1,      -- Text input field
    ITEM_TYPE_CHECKBOX = 2,   -- Toggleable state [ ] / [*]
    ITEM_TYPE_SUBMENU = 3,    -- Opens a nested menu
    ITEM_TYPE_ACTION = 4,     -- Executes a function
    ITEM_TYPE_INFO = 5,       -- Non-interactive display
    ITEM_TYPE_SEPARATOR = 6   -- Visual spacer
}

-- Global Installation State (The "Model")
-- Stores all data selected by the user during the wizard.
local g_tInstallState = {
    sLanguage = "English (100%)",
    sHostname = "archlinux",
    sRootPass = "****",
    sProfile = "Minimal",
    tUsers = {}
}

--------------------------------------------------------------------------------
-- Core Logic & Helper Functions
--------------------------------------------------------------------------------

-- Converts raw bytes into human-readable strings (GiB, MiB, B)
local function fFormatSize(nBytes)
    if not nBytes then return "0 B" end
    if nBytes >= 1073741824 then
        return string.format("%.1f GiB", nBytes / 1073741824)
    elseif nBytes >= 1048576 then
        return string.format("%.1f MiB", nBytes / 1048576)
    else
        return string.format("%d B", nBytes)
    end
end

-- Factory function to create standardized menu items.
-- vName: Display name (string) or dynamic name generator (function).
-- sType: One of g_tTypes.
-- tProps: Optional table containing actions, states, or info text.
local function fCreateItem(vName, sType, tProps)
    tProps = tProps or {}
    local oItem = { 
        vName = vName, 
        sType = sType, 
        vInfo = tProps.vInfo,       -- Info text shown in right panel
        fDynamic = tProps.fDynamic, -- For dynamic list generation
        uState = tProps.uState or {}, 
        fAction = tProps.fAction    -- Function to run on Enter
    }

    -- Default handler for Checkboxes: Toggle boolean state
    if sType == g_tTypes.ITEM_TYPE_CHECKBOX then
        oItem.uState.bChecked = oItem.uState.bChecked or false
        oItem.fAction = function(oSelf) 
            oSelf.uState.bChecked = not oSelf.uState.bChecked 
        end
    elseif sType == g_tTypes.ITEM_TYPE_SEPARATOR then
        oItem.vName = " "
    end

    return oItem
end

--------------------------------------------------------------------------------
-- Disk Configuration Manager
--------------------------------------------------------------------------------

-- Scans attached components for filesystems.
-- Filters out 'tmpfs' (RAM disks) to show only persistent storage.
local function fScanDisks()
    local tDisks = {}
    local nIndex = 97 -- ASCII 'a' => /dev/sda
    local sTmpAddr = oComputer.tmpAddress()
    
    for sAddr, sType in oComponent.list("filesystem") do
        local proxy = oComponent.proxy(sAddr)
        if proxy then
            local sLabel = proxy.getLabel() or "Generic Drive"
            
            -- Filter: Exclude system tmpfs and explicitly labeled tmpfs drives
            if sAddr ~= sTmpAddr and sLabel ~= "tmpfs" then
                local nTotal = proxy.spaceTotal()
                local bRo = proxy.isReadOnly()
                
                table.insert(tDisks, {
                    sModel = sLabel,
                    sPath = "/dev/sd" .. string.char(nIndex),
                    sType = "ocfs", -- Standard OpenComputers Filesystem
                    nSize = nTotal,
                    sSizeStr = fFormatSize(nTotal),
                    bRo = tostring(bRo),
                    sAddr = sAddr
                })
                nIndex = nIndex + 1
            end
        end
    end
    -- Sort by virtual path (/dev/sda, /dev/sdb...)
    table.sort(tDisks, function(a,b) return a.sPath < b.sPath end)
    return tDisks
end

-- Renders the full-screen Disk Manager UI.
-- Displays a list of disks on top and partition details for the selected disk on bottom.
local function fRunDiskManager()
    local tDisks = fScanDisks()
    local nCursor = 1
    local nW, nH = oGpu.getResolution()

    -- Define table columns with fixed widths to prevent visual jitter
    local tCols = {
        { name = "Model",     width = 26 },
        { name = "Path",      width = 10 },
        { name = "Type",      width = 6 },
        { name = "Size",      width = 10 },
        { name = "Read only", width = 9 }
    }

    -- Helper: Draws a single row of the disk table with vertical separators
    local function fDrawRow(nY, tData, bIsHeader, bIsSelected)
        local nX = 1
        
        for i, col in ipairs(tCols) do
            local sText = tData[i] or ""
            local nWCol = col.width
            
            -- Handle text truncation or padding
            if oUnicode.len(sText) > nWCol then 
                sText = oUnicode.sub(sText, 1, nWCol)
            else
                sText = sText .. string.rep(" ", nWCol - oUnicode.len(sText))
            end

            -- Apply highlight colors if row is selected
            if bIsSelected and not bIsHeader then
                oGpu.setBackground(g_nColorHighlightBack)
                oGpu.setForeground(g_nColorHighlightText)
            else
                oGpu.setBackground(g_nColorBack)
                oGpu.setForeground(g_nColorText)
            end

            oGpu.set(nX, nY, " " .. sText .. " ")
            nX = nX + nWCol + 2 -- +2 accounts for padding spaces inside the cell

            -- Draw vertical separator line (unless it's the last column)
            if i < #tCols then
                oGpu.setBackground(g_nColorBack)
                oGpu.setForeground(g_nColorText)
                oGpu.set(nX - 1, nY, g_tBox.V)
            end
        end
    end

    -- Calculate total table width for horizontal lines
    local nTotalTableW = 0
    for _, c in ipairs(tCols) do nTotalTableW = nTotalTableW + c.width + 3 end 
    nTotalTableW = nTotalTableW - 1

    -- Disk Manager Main Loop
    while true do
        oGpu.setBackground(g_nColorBack)
        oGpu.setForeground(g_nColorText)
        oGpu.fill(1, 1, nW, nH, " ")
        oGpu.set(1, 1, "Press ? for help")

        -- 1. Draw Table Header
        local nHeadY = 3
        local tHeadData = {}
        for _, c in ipairs(tCols) do table.insert(tHeadData, c.name) end
        fDrawRow(nHeadY, tHeadData, true, false)

        -- 2. Draw Horizontal Divider (with crosses at intersections)
        local nDivY = 4
        local nX = 1
        for i, col in ipairs(tCols) do
            local nSegW = col.width + 2
            oGpu.set(nX, nDivY, string.rep(g_tBox.H, nSegW))
            nX = nX + nSegW
            if i < #tCols then
                oGpu.set(nX, nDivY, g_tBox.X) -- Draw '┼'
                nX = nX + 1
            end
        end

        -- 3. Draw Disk Rows
        local nTopStartY = 5
        local nListLimit = 5 -- Max disks to show before partition area
        
        for i, tDisk in ipairs(tDisks) do
            if i <= nListLimit then
                local sPrefix = "[ ]"
                if i == nCursor then sPrefix = "> [" end
                
                local tRowData = {
                    sPrefix .. " " .. tDisk.sModel,
                    tDisk.sPath,
                    tDisk.sType,
                    tDisk.sSizeStr,
                    tDisk.bRo
                }
                fDrawRow(nTopStartY + i - 1, tRowData, false, (i == nCursor))
            end
        end

        -- 4. Draw Partition Details Section
        local nMidY = nTopStartY + nListLimit + 1
        local sPartTitle = " Partitions "
        -- Continuous horizontal line with title embedded
        local sLine = g_tBox.H .. sPartTitle .. string.rep(g_tBox.H, nTotalTableW - #sPartTitle - 1)
        oGpu.set(1, nMidY, sLine)

        -- 5. Partition Table (Simulated for OpenComputers)
        -- OC filesystems are treated as single primary partitions
        local sPFmt = " %-10s %s %-8s %s %-10s %s %-12s %s %-10s %s %s"
        
        -- Partition Header
        local sPHeader = string.format(sPFmt, "Name", g_tBox.V, "Type", g_tBox.V, "Filesystem", g_tBox.V, "Path", g_tBox.V, "Size", g_tBox.V, "Flags")
        oGpu.set(1, nMidY + 1, sPHeader)
        oGpu.set(1, nMidY + 2, string.rep(g_tBox.H, oUnicode.len(sPHeader)))

        -- Partition Data (for selected disk)
        local tSel = tDisks[nCursor]
        if tSel then
            local sPRow = string.format(sPFmt, 
                "primary", g_tBox.V, "part", g_tBox.V, "ocfs", g_tBox.V, 
                tSel.sPath .. "1", g_tBox.V, tSel.sSizeStr, g_tBox.V, "BOOT")
            oGpu.set(1, nMidY + 3, sPRow)
        end

        -- Draw vertical border line on the right side for polish
        local nPWidth = oUnicode.len(sPHeader)
        for y = nMidY + 1, nMidY + 3 do
             oGpu.set(nPWidth + 1, y, g_tBox.V) 
        end

        -- Footer & Input Handling
        local sFooter = "Arrows: Navigate | Enter: Select | Esc: Back"
        oGpu.set(math.floor((nW - #sFooter)/2), nH, sFooter)

        local _, _, _, nCode = oEvent.pull("key_down")
        if nCode == 200 then -- Up
            if nCursor > 1 then nCursor = nCursor - 1 end
        elseif nCode == 208 then -- Down
            if nCursor < #tDisks then nCursor = nCursor + 1 end
        elseif nCode == 28 then -- Enter: Confirm Selection
            return "Manual: " .. (tDisks[nCursor] and tDisks[nCursor].sPath or "None")
        elseif nCode == 1 then -- Esc: Cancel
            return nil
        end
    end
end

--------------------------------------------------------------------------------
-- Input Components & Forms
--------------------------------------------------------------------------------

-- Draws a bordered box with a title on the top edge
local function fDrawBox(nX, nY, nW, nH, sTitle)
    local sHeader = g_tBox.TL .. g_tBox.H
    if sTitle then sHeader = sHeader .. " " .. sTitle .. " " end
    local nRem = math.max(0, nW - oUnicode.len(sHeader) - 1)
    sHeader = sHeader .. string.rep(g_tBox.H, nRem) .. g_tBox.TR
    oGpu.set(nX, nY, sHeader)
    for i = 1, nH - 2 do
        oGpu.set(nX, nY + i, g_tBox.V)
        oGpu.set(nX + nW - 1, nY + i, g_tBox.V)
    end
    oGpu.set(nX, nY + nH - 1, g_tBox.BL .. string.rep(g_tBox.H, nW - 2) .. g_tBox.BR)
end

-- Modal text input box with scrolling and password masking
local function fRunInputBox(sLabel, sCurrentValue, bIsPassword, nMaxLength)
    local nW, nH = oGpu.getResolution()
    local nBoxW = 60; local nBoxH = 3
    local nBoxX = math.floor((nW - nBoxW) / 2)
    local nBoxY = math.floor((nH - nBoxH) / 2)
    local sValue = sCurrentValue or ""
    if sValue == "****" then sValue = "" end -- Clear default placeholder on edit
    local nVisWidth = nBoxW - 4 

    while true do
        oGpu.setBackground(g_nColorBack); oGpu.setForeground(g_nColorText)
        oGpu.fill(nBoxX, nBoxY, nBoxW, nBoxH, " ")
        fDrawBox(nBoxX, nBoxY, nBoxW, nBoxH, sLabel)

        -- Handle display (Masking and Scrolling)
        local sDisplay = bIsPassword and string.rep("*", oUnicode.len(sValue)) or sValue
        if oUnicode.len(sDisplay) > nVisWidth then
            -- Scroll left if text exceeds width
            sDisplay = oUnicode.sub(sDisplay, oUnicode.len(sDisplay) - nVisWidth + 1)
        end
        oGpu.set(nBoxX + 2, nBoxY + 1, sDisplay .. "_")

        local _, _, nChar, nCode = oEvent.pull("key_down")
        if nCode == 28 then return sValue -- Enter
        elseif nCode == 1 then return nil -- Esc
        elseif nCode == 14 and oUnicode.len(sValue) > 0 then -- Backspace
            sValue = oUnicode.sub(sValue, 1, oUnicode.len(sValue) - 1)
        elseif nChar > 0 and not oKeyboard.isControl(nChar) and oUnicode.len(sValue) < nMaxLength then 
            sValue = sValue .. oUnicode.char(nChar) 
        end
    end
end

-- Modal User Creation Form (Username, Password, Sudo Toggle)
local function fRunUserForm()
    local sUser, sPass, bSudo = "", "", false
    local nFocus = 1 -- 1: User, 2: Pass, 3: Sudo Selection
    local nW, nH = oGpu.getResolution()

    while true do
        oGpu.setBackground(g_nColorBack); oGpu.setForeground(g_nColorText)
        oGpu.fill(1, 1, nW, nH, " ")
        local nCX, nCY = math.floor(nW / 2) - 20, math.floor(nH / 2) - 5

        -- Username Field
        oGpu.set(nCX, nCY, "Username: " .. sUser)
        if nFocus == 1 then oGpu.set(nCX + 10 + #sUser, nCY, "_") end

        -- Password Field
        local sPassMask = string.rep("*", #sPass)
        oGpu.set(nCX, nCY + 1, "Password: " .. sPassMask)
        if nFocus == 2 then oGpu.set(nCX + 10 + #sPassMask, nCY + 1, "_") end

        -- Sudo Selection
        oGpu.set(nCX, nCY + 3, "Should \"" .. (sUser=="" and "user" or sUser) .. "\" be a superuser (sudo)?")
        local sNo, sYes = " No ", " Yes "
        oGpu.set(nCX + 10, nCY + 5, sNo); oGpu.set(nCX + 25, nCY + 5, sYes)
        
        -- Highlight active sudo option
        if nFocus == 3 then
            oGpu.setBackground(g_nColorHighlightBack); oGpu.setForeground(g_nColorHighlightText)
            local nX = bSudo and (nCX + 25) or (nCX + 10)
            local sTxt = bSudo and (">" .. sYes) or (">" .. sNo)
            oGpu.set(nX, nCY + 5, sTxt)
        end

        oGpu.setBackground(g_nColorBack); oGpu.setForeground(g_nColorText)
        oGpu.set(math.floor((nW - 39)/2), nH - 1, "Enter: Confirm Field/Finish | Esc: Cancel")

        local _, _, nChar, nCode = oEvent.pull("key_down")
        if nCode == 1 then return nil
        elseif nCode == 28 then -- Enter traverses fields
            if nFocus < 3 then nFocus = nFocus + 1 else return { name = sUser, pass = sPass, sudo = bSudo } end
        elseif (nCode == 203 or nCode == 205) and nFocus == 3 then bSudo = not bSudo -- Left/Right toggle
        elseif nCode == 200 and nFocus > 1 then nFocus = nFocus - 1 -- Up
        elseif nCode == 208 and nFocus < 3 then nFocus = nFocus + 1 -- Down
        elseif nCode == 14 then -- Backspace
            if nFocus == 1 and #sUser > 0 then sUser = oUnicode.sub(sUser, 1, #sUser - 1) end
            if nFocus == 2 and #sPass > 0 then sPass = oUnicode.sub(sPass, 1, #sPass - 1) end
        elseif nChar > 0 and not oKeyboard.isControl(nChar) then
            if nFocus == 1 then sUser = sUser .. oUnicode.char(nChar) end
            if nFocus == 2 then sPass = sPass .. oUnicode.char(nChar) end
        end
    end
end

--------------------------------------------------------------------------------
-- Menu Definitions
--------------------------------------------------------------------------------

-- Dynamic generator for the User Accounts submenu.
-- Handles a temporary "Staging" list that is only committed on "Confirm".
local function fGenerateUserMenu()
    local tTempUsers = {}
    -- Copy existing users to staging
    for _, u in ipairs(g_tInstallState.tUsers) do table.insert(tTempUsers, u) end

    local function fInfo()
        if #tTempUsers == 0 then return "No users staged." end
        local s = "Staged Users (" .. #tTempUsers .. "):\n" .. string.rep(g_tBox.H, 13) .. "\n"
        for i, u in ipairs(tTempUsers) do
            s = s .. i .. ". " .. u.name .. " (sudo: " .. tostring(u.sudo) .. ")\n   Pass: [Hidden]\n" 
        end
        return s
    end

    return {
        fCreateItem("Add a user", g_tTypes.ITEM_TYPE_ACTION, { 
            fAction = function()
                local t = fRunUserForm()
                if t then table.insert(tTempUsers, t) end
            end, vInfo = fInfo 
        }),
        fCreateItem("Confirm and exit", g_tTypes.ITEM_TYPE_ACTION, { 
            fAction = function() g_tInstallState.tUsers = tTempUsers; return true end, vInfo = fInfo 
        }),
        fCreateItem("Cancel", g_tTypes.ITEM_TYPE_ACTION, { 
            fAction = function() return true end, vInfo = fInfo 
        })
    }
end

-- Main Menu Structure
local g_tMenu = {
    -- Language Selection
    fCreateItem(function() return "Archinstall language: " .. g_tInstallState.sLanguage end, g_tTypes.ITEM_TYPE_SUBMENU, {
        uState = {
            fCreateItem("English", g_tTypes.ITEM_TYPE_ACTION, { fAction = function() g_tInstallState.sLanguage="English (100%)"; return true end }),
            fCreateItem("Russian", g_tTypes.ITEM_TYPE_ACTION, { fAction = function() g_tInstallState.sLanguage="Russian (76%)"; return true end })
        },
        vInfo = "Sets the installer language"
    }),
    
    -- Mirrors
    fCreateItem("Mirrors", g_tTypes.ITEM_TYPE_SUBMENU, {
        uState = {
             fCreateItem("Worldwide", g_tTypes.ITEM_TYPE_CHECKBOX, {uState={bChecked=true}})
        },
        vInfo = "Select mirror regions"
    }),

    -- Disk Configuration
    fCreateItem("Disk configuration", g_tTypes.ITEM_TYPE_SUBMENU, {
        uState = {
            fCreateItem("Use a best-effort default partition layout", g_tTypes.ITEM_TYPE_ACTION, { fAction = function() return true end }),
            fCreateItem("Manual Partitioning", g_tTypes.ITEM_TYPE_ACTION, { 
                fAction = function() 
                    local sRes = fRunDiskManager() 
                    if sRes then return true end
                end 
            })
        },
        vInfo = "Select disk configuration method"
    }),

    -- System Settings
    fCreateItem("Swap", g_tTypes.ITEM_TYPE_ACTION, nil, "True"),
    fCreateItem("Bootloader", g_tTypes.ITEM_TYPE_SUBMENU, {}, "Systemd-boot"),
    fCreateItem("Unified kernel images", g_tTypes.ITEM_TYPE_CHECKBOX, {bChecked=false}),
    
    fCreateItem("Hostname", g_tTypes.ITEM_TYPE_ACTION, {
        fAction = function()
            local s = fRunInputBox("Hostname", g_tInstallState.sHostname, false, 64)
            if s then g_tInstallState.sHostname = s end
        end,
        vInfo = function() return g_tInstallState.sHostname .. "\n\nLimit: 64 chars" end
    }),

    fCreateItem("Root password", g_tTypes.ITEM_TYPE_ACTION, {
        fAction = function()
            local s = fRunInputBox("Password", g_tInstallState.sRootPass, true, 32)
            if s then g_tInstallState.sRootPass = s end
        end,
        vInfo = function()
            return (g_tInstallState.sRootPass == "****" and "**** (Default)" or (g_tInstallState.sRootPass == "" and "Not set" or "********")) .. "\n\nLimit: 32 chars"
        end
    }),

    fCreateItem("User account", g_tTypes.ITEM_TYPE_ACTION, {
        fAction = function() return fGenerateUserMenu() end,
        vInfo = function() return "Users to create: " .. #g_tInstallState.tUsers end
    }),

    -- Profile Selection
    fCreateItem("Profile", g_tTypes.ITEM_TYPE_SUBMENU, {
        uState = {
            fCreateItem("Desktop", g_tTypes.ITEM_TYPE_SUBMENU, { 
                uState = { fCreateItem("Gnome", g_tTypes.ITEM_TYPE_CHECKBOX, {}), fCreateItem("KDE", g_tTypes.ITEM_TYPE_CHECKBOX, {}) } 
            }),
            fCreateItem("Minimal", g_tTypes.ITEM_TYPE_CHECKBOX, {}),
            fCreateItem("Server", g_tTypes.ITEM_TYPE_CHECKBOX, {}),
            fCreateItem("Xorg", g_tTypes.ITEM_TYPE_CHECKBOX, {})
        },
        vInfo = "Select profile" 
    }),
    
    -- Misc Configuration
    fCreateItem("Kernels", g_tTypes.ITEM_TYPE_SUBMENU, {}, "linux"),
    fCreateItem("Network configuration", g_tTypes.ITEM_TYPE_SUBMENU, {}, "NetworkManager"),
    fCreateItem("Timezone", g_tTypes.ITEM_TYPE_SUBMENU, {}, "UTC"),
    fCreateItem("Automatic time sync (NTP)", g_tTypes.ITEM_TYPE_CHECKBOX, {bChecked=true}),
    
    -- Actions
    fCreateItem(nil, g_tTypes.ITEM_TYPE_SEPARATOR),
    fCreateItem("Install", g_tTypes.ITEM_TYPE_ACTION, { fAction = function() end }),
    fCreateItem("Abort", g_tTypes.ITEM_TYPE_ACTION, { fAction = function() oTerm.clear(); os.exit() end })
}

--------------------------------------------------------------------------------
-- UI Engine (Main Loop)
--------------------------------------------------------------------------------

-- Renders the current menu state to the screen.
-- Handles the "Split View" (Left: Menu, Right: Info) and drawing connectors.
local function fDrawUI(tMenu, nCursor, nScroll)
    local nW, nH = oGpu.getResolution()
    local nMinX, nMinY = 1 + g_nPadX, 1 + g_nPadY
    local nMaxX, nMaxY = nW - g_nPadX, nH - g_nPadY
    
    -- Calculate split position (approx 45% width)
    local nSplitAbs = nMinX + math.floor((nMaxX - nMinX + 1) * 0.45)

    -- Clear screen
    oGpu.setBackground(g_nColorBack); oGpu.setForeground(g_nColorText)
    oGpu.fill(1, 1, nW, nH, " ")
    oGpu.set(nMinX, nMinY, "Press ? for help")

    -- Draw Vertical Separator
    for y = nMinY + 3, nMaxY do oGpu.set(nSplitAbs, y, g_tBox.V) end
    
    -- Draw "Top Left" corner connector for the Info box
    oGpu.set(nSplitAbs, nMinY + 2, g_tBox.TL)
    
    -- Draw Info Header "─── Info ───" connected to the separator
    local sInfo = " Info "
    local nRW = nMaxX - (nSplitAbs + 1) + 1
    local nD = math.floor((nRW - #sInfo) / 2) - 1
    local sHead = g_tBox.H .. string.rep(g_tBox.H, nD) .. sInfo .. string.rep(g_tBox.H, nD)
    if #sHead < nRW then sHead = sHead .. g_tBox.H end
    oGpu.set(nSplitAbs + 1, nMinY + 2, sHead)

    -- Render Menu Items (Left Panel)
    local nListH = nMaxY - (nMinY + 2) + 1
    local nEnd = math.min(#tMenu, nScroll + nListH)
    
    for i = 1 + nScroll, nEnd do
        local tItem = tMenu[i]
        local nY = (nMinY + 2) + (i - 1 - nScroll)
        
        if tItem.sType ~= g_tTypes.ITEM_TYPE_SEPARATOR then
            local bSel = (i == nCursor)
            
            -- Highlight active row
            oGpu.setBackground(bSel and g_nColorHighlightBack or g_nColorBack)
            oGpu.setForeground(bSel and g_nColorHighlightText or g_nColorText)
            
            -- Resolve name (dynamic or static)
            local sName = type(tItem.vName) == "function" and tItem.vName() or tostring(tItem.vName or "")
            
            -- Decorate item (Prefix/Suffix)
            local sPre = bSel and "> " or "  "
            local sSuf = ""
            if tItem.sType == g_tTypes.ITEM_TYPE_CHECKBOX then
                sSuf = "[" .. (tItem.uState.bChecked and "*" or " ") .. "]"
                if not bSel then sPre = "  " end
            elseif tItem.sType == g_tTypes.ITEM_TYPE_SUBMENU then sSuf = "+" end
            
            -- Truncate and pad text to fit left panel
            local nWAvail = (nSplitAbs - 1) - nMinX
            local sLine = sPre .. oUnicode.sub(sName, 1, nWAvail - #sPre - #sSuf - 1)
            sLine = sLine .. string.rep(" ", math.max(0, nWAvail - #sLine - #sSuf)) .. sSuf
            oGpu.set(nMinX, nY, sLine)
        end
    end

    -- Render Info Panel (Right Panel)
    oGpu.setBackground(g_nColorBack); oGpu.setForeground(g_nColorText)
    local tSel = tMenu[nCursor]
    if tSel then
        local sTxt = type(tSel.vInfo) == "function" and tSel.vInfo() or tSel.vInfo
        if sTxt then
            local nIY = nMinY + 4
            for sL in string.gmatch(sTxt .. "\n", "([^\n]*)\n") do
                if nIY <= nMaxY then
                    oGpu.set(nSplitAbs + 2, nIY, oUnicode.sub(sL, 1, nRW))
                    nIY = nIY + 1
                end
            end
        end
    end
end

-- Main Application Loop
-- Handles navigation, submenus, and actions via a stack system.
local function fRunMenu()
    local tStack = {}
    local tCur, nCur, nScr = g_tMenu, 1, 0

    -- Helper to find next selectable item (skip separators)
    local function fNext(nD)
        local n = nCur
        repeat
            n = n + nD
            if n > #tCur then n = 1 elseif n < 1 then n = #tCur end
        until tCur[n].sType ~= g_tTypes.ITEM_TYPE_SEPARATOR
        return n
    end

    while true do
        fDrawUI(tCur, nCur, nScr)
        local _, _, nCh, nCo = oEvent.pull("key_down")
        local nListH = select(2, oGpu.getResolution()) - (g_nPadY * 2) - 2

        if nCo == 200 then -- Up
            nCur = fNext(-1)
            -- Adjust scroll if moving above visible area
            if nCur > #tCur - nListH and nCur == #tCur then nScr = math.max(0, #tCur - nListH) end
            if nCur <= nScr then nScr = nCur - 1 end
        elseif nCo == 208 then -- Down
            nCur = fNext(1)
            -- Adjust scroll if moving below visible area
            if nCur == 1 then nScr = 0 end
            if nCur > nScr + nListH then nScr = nCur - nListH end
        elseif nCo == 28 or nCh == 32 then -- Enter or Space
            local t = tCur[nCur]
            
            -- Handle Checkboxes (Toggle)
            if t.sType == g_tTypes.ITEM_TYPE_CHECKBOX and t.fAction then 
                t.fAction(t)
            
            -- Handle Submenus (Push to Stack)
            elseif t.sType == g_tTypes.ITEM_TYPE_SUBMENU and nCo == 28 then
                table.insert(tStack, { m = tCur, c = nCur, s = nScr })
                tCur = type(t.uState) == "table" and t.uState or {}
                nCur, nScr = 1, 0
            
            -- Handle Actions
            elseif t.sType == g_tTypes.ITEM_TYPE_ACTION and nCo == 28 and t.fAction then
                local res = t.fAction(t)
                -- If Action returns a table, treat it as a dynamic submenu
                if type(res) == "table" then
                    table.insert(tStack, { m = tCur, c = nCur, s = nScr })
                    tCur, nCur, nScr = res, 1, 0
                -- If Action returns true, go back one level
                elseif res == true and #tStack > 0 then
                    local p = table.remove(tStack)
                    tCur, nCur, nScr = p.m, p.c, p.s
                end
            end
        elseif nCo == 14 and #tStack > 0 then -- Backspace: Go Back
            local p = table.remove(tStack)
            tCur, nCur, nScr = p.m, p.c, p.s
        elseif nCo == 1 then -- Esc: Exit
            oTerm.clear(); return
        end
    end
end

-- Entry Point
oTerm.clear()
fRunMenu()