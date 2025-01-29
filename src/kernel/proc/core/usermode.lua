gpu.fill(1,1,160,50," ")
--kprint("Hello from usermode.lua!")

local shell_path = "/bin/shell.lua"

    local shell_func = load_file(shell_path)()
    if not shell_func then
        gpu.set(1, 4, "Error loading shell: " .. tostring(err))
        return
    end

    local shell_co = coroutine.create(shell_func)
    local ok, er = coroutine.resume(shell_co)
    if not ok then
        gpu.set(1, 5, "Error in shell_co: " .. tostring(er))
    end
    
    while coroutine.status(shell_co) ~= "dead" do  end

kprint("Usermode done.")
