if string.find(_G._OSVERSION, "OpenOS") == nil
then
  print("The AwooOS installer now only supports OpenOS. Install OpenOS to run the AwooOS installer.")
  return
end

local component = require("component")
local fs = require("filesystem")
local computer = require("computer")
local internet = require("internet")

local eeprom = component.eeprom

local init_bootloader_github_address = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/bootloader/init_bootloader.lua"

print("This script will install AwooOS onto the current computer.")
print("It will overwrite the EEPROM and remove all files from the current filesystem.")
io.write("Do you want to continue? [y/N] ")
while true
do
  local answer = io.read()
  if answer:lower() == "n" then return end
  if answer:lower() == "y" then break end
end

print("Writing init bootloader to EEPROM...")
local success, internet_handle = pcall(internet.request, init_bootloader_github_address)
if not success then
  print("Failed to request init bootloader from github: " .. tostring(internet_handle))
  return
end
local init_bootloader_data = ""
for chunk in internet_handle do init_bootloader_data = init_bootloader_data .. chunk end
local success, err = pcall(eeprom.set, init_bootloader_data)
if not success then
  print("Failed to write EEPROM: " .. tostring(err))
  return
end
print("Init bootloader written to EEPROM.")

local eepromLabel = "AwooOS"
eeprom.setLabel(eepromLabel)
print("EEPROM label set to: " .. eeprom.getLabel())

print("Setting current filesystem as default boot address...")
local currentFsAddress = fs.get("/").address
computer.setBootAddress(currentFsAddress)

print("Init bootloader is downloaded and written!")
print("Reboot to launch installation of AwooOS. The system will now reboot.")
os.sleep(2)
computer.shutdown(true)