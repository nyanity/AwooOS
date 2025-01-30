klog("usermode.lua: Starting execution")
gpu.fill(1,1,160,50," ")

local shell_path = "/bin/shell.lua"
klog("usermode.lua: attempting to load shell from " .. shell_path)

local shell_func, load_err = load_file(shell_path)

if shell_func then
    klog("usermode.lua: shell loaded successfully")
    -- create a coroutine from shellMain
    klog("usermode.lua: Creating shell coroutine")
    local shell_co = coroutine.create(shell_func)
    klog("usermode.lua: Shell coroutine created, status:", coroutine.status(shell_co))
    klog("usermode.lua: Value of shell_func:", shell_func)  -- Add this line

    klog("usermode.lua: Resuming shell coroutine for the first time")
    gpu.fill(1,1,160,50, " ") -- clear the screen from kprint messages
    local ok, err = coroutine.resume(shell_co)
    klog("usermode.lua: Shell coroutine resumed, ok:", ok, "err:", err)

    if not ok then
        klog("usermode.lua: Error resuming shell coroutine:", err)
        gpu.set(1, 5, "Error in shell_co: " .. tostring(err))
    else
        klog("usermode.lua: Shell coroutine resumed, ok:", ok, "err:", err)
        klog("usermode.lua: About to enter while loop, status:", coroutine.status(shell_co))
        
        while coroutine.status(shell_co) ~= "dead" do
            coroutine.resume(shell_co)
            klog("usermode.lua: shell status:", coroutine.status(shell_co))
            os.sleep(0.1)  -- small delay to prevent busy-waiting
        end
    end

    klog("Usermode done.")
else
    klog("usermode.lua: Error loading shell:", load_err)
    gpu.set(1, 4, "Error loading shell: " .. tostring(load_err))
end