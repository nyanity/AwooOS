local component = component
local computer = computer

_G._VERSION = "AwooOS 0.1"

local gpu = component.list("gpu")()

do
    gpu = component.proxy(gpu)
    gpu.setResolution(160,50)
end

while true
do
    gpu.fill(1, 1, 160, 1, " ")
    gpu.set(1, 1, "AwooOS Running!" .. tostring(os.clock()))
    computer.pullSignal(0.5)
end