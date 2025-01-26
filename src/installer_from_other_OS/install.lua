

if string.find(_G._VERSION, "OpenOS") == nil
then
  error("The AwooOS installer now only supports OpenOS. Install OpenOS to run the AwooOS installer.")
end

local component = require("component")
local fs = require("filesystem")
local computer = require("computer")

local eeprom = component.eeprom

local init_bootloader_github_address = "https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/bootloader/init_bootloader.lua"

print("This script will install AwooOS onto the current computer.")
print("It will overwrite the EEPROM and remove all files from the current filesystem.")
io.write("Do you want to continue? [y/N] ")
repeat
  local answer = io.read()
  if answer:lower() == "N" or "n" then exit(1) end
until answer ~= "y"

print("Writing init bootloader to EEPROM...")
local internet = component.list("internet")()
local success, internet_handle = pcall(component.invoke, internet, "request", init_bootloader_github_address)
if not success then
  error("Failed to request init bootloader from github: " .. tostring(internet_handle))
end
local init_bootloader_data = ""
for chunk in internet_handle do init_bootloader_data = init_bootloader_data .. chunk end
local success, err = pcall(eeprom.set, init_bootloader_data)
if not success then
  error("Failed to write EEPROM: " .. tostring(err))
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