local syscall = _G.syscall

local function main()
  syscall[0x83]()`
end

main()