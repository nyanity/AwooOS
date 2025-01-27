local fsCount=0
for a in pairs(component.list("filesystem") or {}) do fsCount=fsCount+1 end
if fsCount<=1 then error("no fs") end
if not component.list("internet")() then error("no inet") end

local eepromAddr=component.list("eeprom")()
local function e(a,...) local ok,res=pcall(component.invoke,eepromAddr,a,...) if not ok then return nil,res end return res end
computer.getBootAddress=function() return e("getData") end
computer.setBootAddress=function(a) return e("setData",a) end

local gpuAddr=next(component.list("gpu") or {})
local scrAddr=next(component.list("screen") or {})
if not gpuAddr or not scrAddr then error("no gpu") end
assert(pcall(component.invoke,gpuAddr,"bind",scrAddr))

local function clean(fs,p)
  if not fs or type(fs.list)~="function" then error("bad fs") end
  if p:sub(-1)~="/" then p=p.."/" end
  local f=fs.list(p) if not f then error("lf") end
  for i=1,#f do
    local fp=p..f[i]
    if fs.isDirectory(fp) then clean(fs,fp.."/") end
    fs.remove(fp)
  end
end

local function getInstaller(fs)
  local i=component.list("internet")()
  local h=e("request","https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/kernel/installation.lua")
  if not h then error("req") end
  local fh=fs.open("/installation.lua","w") if not fh then error("open") end
  while true do
    local c=h.read()
    if not c then break end
    fh.write(c)
  end
  fh.close()
end

local function tryLoad(fs)
  local h=fs.open("/installation.lua")
  if not h then return end
  local b=""
  while true do
    local d=fs.read(h,math.huge)
    if not d then break end
    b=b..d
  end
  fs.close(h)
  return load(b,"=install")
end

local ba=computer.getBootAddress()
if not ba then error("no boot addr") end
local fs=component.proxy(ba)
if not fs then error("fs?") end

clean(fs,"/")
getInstaller(fs)
local inst=tryLoad(fs)
if not inst then error("no load") end
return inst()
