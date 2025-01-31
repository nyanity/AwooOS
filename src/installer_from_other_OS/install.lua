do
  local supportedOS, found = {"OpenOS"}, false
  for _, os in ipairs(supportedOS) do if string.find(_G._OSVERSION, os) ~= nil then found = true break end end
  if not found
  then
    print("The AwooOS installer doesn't support this OS.")
    print("Supported OS: " .. table.concat(supportedOS, ", "))
    return
  end
end

local component = require("component")
local computer = require("computer")
local internet = require("internet")

-- init bootloader table
local init_btldr = {
  addr = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/dev/src/bootloader/init_bootloader.lua",
  data = ""
}

print("This script will install AwooOS onto the current computer.")
print("It will overwrite the EEPROM and remove all files from the current filesystem.")
io.write("Do you want to continue? [y/N] ")
while true
do
  local answer = io.read()
  if answer:lower() == "n" then return end
  if answer:lower() == "y" then break end
end

print("Choose the filesystem to install AwooOS:")
local fs = {__size = 0}
for address, _ in component.list("filesystem") do
  table.insert(fs, address)
  fs.__size = fs.__size + 1
end

for i, address in ipairs(fs) do
  print(i .. ": " .. address)
end

while true
do
  io.write("Type the index: ")
  local answer = tonumber(io.read())
  if answer and answer > 0 and answer <= fs.__size then fs = fs[answer] break end
end
print("Selected filesystem: " .. fs)

print("Writing init bootloader to EEPROM...")
-- download init bootloader
local success, internet_handle = pcall(internet.request, init_btldr.addr)
if not success then
  print("Failed to request init bootloader from github: " .. tostring(internet_handle))
  return
end

-- write init bootloader to EEPROM
for chunk in internet_handle do init_btldr.data = init_btldr.data .. chunk end
local success, err = pcall(component.eeprom.set, init_btldr.data)
if not success then
  print("Failed to write EEPROM: " .. tostring(err))
  return
end
print("Init bootloader written to EEPROM.")

local label = "AwooOS"
component.eeprom.setLabel(label)
print("EEPROM label set to: " .. label)

print("Setting current filesystem as default boot address...")
computer.setBootAddress(fs)

print("Init bootloader is downloaded and written!")
print("Reboot to launch installation of AwooOS. The system will now reboot.")
os.sleep(2)
computer.shutdown(true)