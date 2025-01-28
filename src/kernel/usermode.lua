-- usermode.lua
gpu.set(1, 2, "Hello from usermode!")

local shell_path = "/usr/shell.lua"
if filesystem[shell_path] then
    local shell_func, err = load(filesystem[shell_path], shell_path, "t", Ring3)
    if shell_func then
        local shell_co = coroutine.create(shell_func)
        coroutine.resume(shell_co)
        while coroutine.status(shell_co) ~= "dead" do
            computer.pullSignal(0.1)
        end
    else
        syscall[0x80](1, 1, "Error loading shell: " .. err)
    end
else
    syscall[0x80](1, 1, "Shell not found at " .. shell_path)
end