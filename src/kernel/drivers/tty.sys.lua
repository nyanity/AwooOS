--
-- /drivers/tty.sys.lua
-- v3.1: Turbo & Stable
--

local tStatus = require("errcheck")
local oKMD = require("kmd_api")
local tDKStructs = require("shared_structs")

g_tDriverInfo = {
  sDriverName = "AwooTTY",
  sDriverType = tDKStructs.DRIVER_TYPE_KMD,
  nLoadPriority = 100,
  sVersion = "3.1.0",
}

local g_pDeviceObject = nil
local g_oGpuProxy = nil

local tAnsiColors = {
  [30] = 0x000000, [31] = 0xFF0000, [32] = 0x00FF00, [33] = 0xFFFF00,
  [34] = 0x0000FF, [35] = 0xFF00FF, [36] = 0x00FFFF, [37] = 0xFFFFFF,
}

local function scroll(pExt)
  if not g_oGpuProxy then return end
  g_oGpuProxy.copy(1, 2, pExt.nWidth, pExt.nHeight - 1, 0, -1)
  g_oGpuProxy.fill(1, pExt.nHeight, pExt.nWidth, 1, " ")
  pExt.nCursorY = pExt.nHeight
end

local function printChunk(pExt, sText)
  if #sText == 0 or not g_oGpuProxy then return end
  if not pExt.nWidth then return end

  local nRem = pExt.nWidth - pExt.nCursorX + 1
  
  if #sText <= nRem then
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sText)
      pExt.nCursorX = pExt.nCursorX + #sText
      if pExt.nCursorX > pExt.nWidth then
         pExt.nCursorX = 1
         pExt.nCursorY = pExt.nCursorY + 1
         if pExt.nCursorY > pExt.nHeight then scroll(pExt) end
      end
  else
      local sPart1 = string.sub(sText, 1, nRem)
      local sPart2 = string.sub(sText, nRem + 1)
      g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, sPart1)
      pExt.nCursorX = 1
      pExt.nCursorY = pExt.nCursorY + 1
      if pExt.nCursorY > pExt.nHeight then scroll(pExt) end
      printChunk(pExt, sPart2)
  end
end

local function writeToScreen(pDeviceObject, sData)
  if not g_oGpuProxy then return end
  local pExt = pDeviceObject.pDeviceExtension
  local sStr = tostring(sData)
  local nStart = 1
  local nLen = #sStr
  
  while nStart <= nLen do
      local nS, nE = string.find(sStr, "[%c\27]", nStart)
      
      if not nS then
          printChunk(pExt, string.sub(sStr, nStart))
          break
      end
      
      if nS > nStart then
          printChunk(pExt, string.sub(sStr, nStart, nS - 1))
      end
      
      local nByte = string.byte(sStr, nS)
      local nNextStart = nS + 1
      
      if nByte == 10 then -- \n
          pExt.nCursorX = 1
          pExt.nCursorY = pExt.nCursorY + 1
          if pExt.nCursorY > pExt.nHeight then scroll(pExt) end
          
      elseif nByte == 13 then -- \r
          pExt.nCursorX = 1
          
      elseif nByte == 12 then -- \f
          g_oGpuProxy.fill(1, 1, pExt.nWidth, pExt.nHeight, " ")
          pExt.nCursorX = 1
          pExt.nCursorY = 1
          
      elseif nByte == 8 then -- \b
          if pExt.nCursorX > 1 then
              pExt.nCursorX = pExt.nCursorX - 1
              g_oGpuProxy.set(pExt.nCursorX, pExt.nCursorY, " ")
          end
          
      elseif nByte == 27 then -- ANSI
          if string.sub(sStr, nS+1, nS+1) == "[" then
              local nEndAnsi = string.find(sStr, "m", nS)
              if nEndAnsi then
                  local sCode = string.sub(sStr, nS+2, nEndAnsi-1)
                  local nColor = tonumber(sCode)
                  if nColor and tAnsiColors[nColor] then
                      g_oGpuProxy.setForeground(tAnsiColors[nColor])
                  elseif sCode == "0" or sCode == "" then
                      g_oGpuProxy.setForeground(0xFFFFFF)
                  end
                  nNextStart = nEndAnsi + 1
              end
          end
      end
      
      nStart = nNextStart
  end
end

-------------------------------------------------
-- HANDLERS
-------------------------------------------------
local function fCreate(d, i) oKMD.DkCompleteRequest(i, 0, 0) end
local function fClose(d, i) oKMD.DkCompleteRequest(i, 0) end

local function fWrite(d, i)
  writeToScreen(d, i.tParameters.sData)
  oKMD.DkCompleteRequest(i, 0, #i.tParameters.sData)
end

local function fRead(d, i)
  local p = d.pDeviceExtension
  if p.pPendingReadIrp then oKMD.DkCompleteRequest(i, tStatus.STATUS_DEVICE_BUSY)
  else p.pPendingReadIrp = i; p.sLineBuffer = "" end
end

-------------------------------------------------
-- ENTRY
-------------------------------------------------
function DriverEntry(pObj)
  oKMD.DkPrint("AwooTTY v3.1")
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
  
  if gpu then
     local _, p = oKMD.DkGetHardwareProxy(gpu)
     g_oGpuProxy = p
     if scr and p then
         p.bind(scr)
         local w, h = p.getResolution()
         p.fill(1,1,w,h," ")
         dev.pDeviceExtension.nWidth = w
         dev.pDeviceExtension.nHeight = h
         dev.pDeviceExtension.nCursorX = 1
         dev.pDeviceExtension.nCursorY = 1
     end
  else
     oKMD.DkPrint("TTY Warning: No GPU found")
  end
  
  oKMD.DkRegisterInterrupt("key_down")
  return 0
end

function DriverUnload() return 0 end

-------------------------------------------------
-- LOOP
-------------------------------------------------
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
            if code == 28 then
                writeToScreen(g_pDeviceObject, "\n")
                oKMD.DkCompleteRequest(ext.pPendingReadIrp, 0, ext.sLineBuffer)
                ext.pPendingReadIrp = nil
            elseif code == 14 then
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