--
-- /drivers/tty.sys.lua
-- v4.3: Priority Shift
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AwooTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100,
  sVersion = "4.3.0",
}

local g_pDeviceObject = nil
local g_oGpuProxy = nil

local tAnsiColors = {
  [30] = 0x000000, [31] = 0xFF0000, [32] = 0x00FF00, [33] = 0xFFFF00,
  [34] = 0x0000FF, [35] = 0xFF00FF, [36] = 0x00FFFF, [37] = 0xFFFFFF,
  [90] = 0x555555,
}

local function scroll(pExt)
  if not g_oGpuProxy then return end
  g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
  g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
  pExt.nCursorY = pExt.nHeight
end

local function rawWrite(pExt, sText)
  if #sText == 0 then return end
  local nLen = #sText
  local nRemainingSpace = pExt.nWidth - pExt.nCursorX + 1
  
  if nLen <= nRemainingSpace then
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sText)
      pExt.nCursorX = pExt.nCursorX + nLen
      if pExt.nCursorX > pExt.nWidth then
         pExt.nCursorX = 1
         if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
      end
  else
      local sPart1 = string.sub(sText, 1, nRemainingSpace)
      local sPart2 = string.sub(sText, nRemainingSpace + 1)
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sPart1)
      pExt.nCursorX = 1
      if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
      rawWrite(pExt, sPart2)
  end
end

local function safeDraw(fFunc, ...)
    local bOk, sErr = pcall(fFunc, ...)
    -- ignore errors silently to prevent log spam loops
end

local function writeToScreen(pDeviceObject, sData)
  if not g_oGpuProxy then return end
  local pExt = pDeviceObject.pDeviceExtension
  local sStr = tostring(sData)
  local nLen = #sStr
  local nIdx = 1
  
  while nIdx <= nLen do
      local nNextSpecial = string.find(sStr, "[%c\27]", nIdx)
      if not nNextSpecial then
          safeDraw(rawWrite, pExt, string.sub(sStr, nIdx))
          break
      end
      if nNextSpecial > nIdx then
          safeDraw(rawWrite, pExt, string.sub(sStr, nIdx, nNextSpecial - 1))
      end
      
      local nByte = string.byte(sStr, nNextSpecial)
      pcall(function()
          if nByte == 10 then -- \n
              pExt.nCursorX = 1
              if pExt.nCursorY < pExt.nHeight then pExt.nCursorY = pExt.nCursorY + 1 else scroll(pExt) end
          elseif nByte == 13 then -- \r
              pExt.nCursorX = 1
          elseif nByte == 8 then -- \b
              if pExt.nCursorX > 1 then
                  pExt.nCursorX = pExt.nCursorX - 1
                  g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, " ")
              end
          elseif nByte == 12 then -- \f
              g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
              pExt.nCursorX, pExt.nCursorY = 1, 1
          elseif nByte == 27 then -- ANSI escape code
              if string.sub(sStr, nNextSpecial + 1, nNextSpecial + 1) == "[" then
                  local sAnsiSeq = string.sub(sStr, nNextSpecial + 2, nNextSpecial + 3)

                  if sAnsiSeq:sub(1,1) == "H" then -- \27[H (Set cursor pos to 1,1)
                      pExt.nCursorX, pExt.nCursorY = 1, 1
                      nNextSpecial = nNextSpecial + 2
                  
                  elseif sAnsiSeq == "2J" then -- \27[2J (Clear Screen)
                      g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
                      pExt.nCursorX, pExt.nCursorY = 1, 1
                      nNextSpecial = nNextSpecial + 3 
                  
                  else -- Color codes
                      local nEndAnsi = string.find(sStr, "m", nNextSpecial)
                      if nEndAnsi then
                          local sCode = string.sub(sStr, nNextSpecial + 2, nEndAnsi - 1)
                          for sSubCode in string.gmatch(sCode, "[^;]+") do
                              local nColor = tonumber(sSubCode)
                              if nColor and tAnsiColors[nColor] then
                                  g_oGpuProxy.setForeground(tAnsiColors[nColor])
                              elseif sSubCode == "0" or sSubCode == "" then
                                  g_oGpuProxy.setForeground(0xFFFFFF)
                                  g_oGpuProxy.setBackground(0x000000)
                              end
                          end
                          nNextSpecial = nEndAnsi
                      end
                  end
              end
          end
      end)
      nIdx = nNextSpecial + 1
  end
end

local function fCreate(d, i) oKMD.DkCompleteRequest(i, 0, 0) end
local function fClose(d, i) oKMD.DkCompleteRequest(i, 0) end
local function fWrite(d, i)
  writeToScreen(d, i.tParameters.sData)
  oKMD.DkCompleteRequest(i, 0, #i.tParameters.sData)
end
local function fRead(d, i)
  local p = d.pDeviceExtension
  if p.pPendingReadIrp then 
     oKMD.DkCompleteRequest(i, tStatus.STATUS_DEVICE_BUSY)
  else 
     p.pPendingReadIrp = i
     p.sLineBuffer = "" 
  end
end

function DriverEntry(pObj)
  oKMD.DkPrint("AwooTTY v4.3 Loaded.")
  pObj.tDispatch[tDKStructs.IRP_MJ_CREATE] = fCreate
  pObj.tDispatch[tDKStructs.IRP_MJ_CLOSE] = fClose
  pObj.tDispatch[tDKStructs.IRP_MJ_WRITE] = fWrite
  pObj.tDispatch[tDKStructs.IRP_MJ_READ] = fRead
  
  local st, dev = oKMD.DkCreateDevice(pObj, "\\Device\\TTY0")
  if st ~= 0 then return st end
  g_pDeviceObject = dev
  oKMD.DkCreateSymbolicLink("/dev/tty", "\\Device\\TTY0")
  
  local gpu, scr
  local b, l
  b, l = syscall("raw_component_list", "gpu")
  if b and l then for k in pairs(l) do gpu=k break end end
  b, l = syscall("raw_component_list", "screen")
  if b and l then for k in pairs(l) do scr=k break end end
  
  dev.pDeviceExtension.nWidth = 80
  dev.pDeviceExtension.nHeight = 25
  dev.pDeviceExtension.nCursorX = 1
  dev.pDeviceExtension.nCursorY = 25
  
  if gpu then
     local _, p = oKMD.DkGetHardwareProxy(gpu)
     g_oGpuProxy = p
     if scr and p then
         p.bind(scr)
         local w, h = p.getResolution()
         p.setBackground(0x000000)
         p.setForeground(0xFFFFFF)
         if w and h then
             dev.pDeviceExtension.nWidth = w
             dev.pDeviceExtension.nHeight = h
             dev.pDeviceExtension.nCursorY = h
         end
     end
  end
  oKMD.DkRegisterInterrupt("key_down")
  return 0
end

function DriverUnload() return 0 end

while true do
  local b, pid, sig, p1, p2, p3, p4 = syscall("signal_pull")
  if b then
    if sig == "driver_init" then
        local s = DriverEntry(p1)
        syscall("signal_send", pid, "driver_init_complete", s, p1)
    elseif sig == "irp_dispatch" then
        if p2 then p2(g_pDeviceObject, p1) end
    elseif sig == "hardware_interrupt" and p1 == "key_down" then
        local ext = g_pDeviceObject and g_pDeviceObject.pDeviceExtension
        if ext and ext.pPendingReadIrp then
            local ch, code = p3, p4
            if code == 28 then -- Enter
                -- save the data we need
                local sResult = ext.sLineBuffer
                local pIrp = ext.pPendingReadIrp
                
                -- clear the state so we don't process double enters
                ext.pPendingReadIrp = nil
                
                -- tell the OS we are done. This unblocks init.lua immediately.
                oKMD.DkCompleteRequest(pIrp, 0, sResult)
                
                -- NOW try to draw the newline. If this lags/fails, the OS doesn't care.
                writeToScreen(g_pDeviceObject, "\n")
                
            elseif code == 14 then -- Backspace
                if #ext.sLineBuffer > 0 then
                    ext.sLineBuffer = ext.sLineBuffer:sub(1, -2)
                    writeToScreen(g_pDeviceObject, "\b")
                end
            elseif code ~= 0 and ch > 0 and ch < 256 then
                local s = string.char(ch)
                ext.sLineBuffer = ext.sLineBuffer .. s
                writeToScreen(g_pDeviceObject, s)
            end
        end
    end
  end
end