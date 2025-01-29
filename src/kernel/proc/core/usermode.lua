gpu.fill(1,1,160,50," ")

local shell_path = "/bin/shell.lua"
klog("usermode.lua: attempting to load shell from " .. shell_path)

local shell_func, load_err = load_file(shell_path)

if shell_func then
    klog("usermode.lua: shell loaded successfully")

    -- create a coroutine from shellMain
    local shell_co = coroutine.create(shell_func)

    klog("usermode.lua: shell coroutine created, starting main loop")

    -- resume the coroutine once to start it
    local ok, err = coroutine.resume(shell_co)
    if not ok then
        klog("usermode.lua: Error resuming shell coroutine:", err)
        gpu.set(1, 5, "Error in shell_co: " .. tostring(err))
    else
        while coroutine.status(shell_co) ~= "dead" do
            klog("usermode.lua: shell status:", coroutine.status(shell_co))
            os.sleep(0.1)  -- small delay to prevent busy-waiting
        end
    end

    klog("Usermode done.")
else
    klog("usermode.lua: Error loading shell:", load_err)
    gpu.set(1, 4, "Error loading shell: " .. tostring(load_err))
end