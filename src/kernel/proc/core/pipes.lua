local pipeModule = {}
local pipeStore = {}  -- holds all pipe objects { data="", read_waiting={}, write_waiting={} }

-- helper to resume the first coroutine in a queue.
local function resumeFirst(q)
  local co = table.remove(q, 1)
  if co then coroutine.resume(co) end
end

function pipeModule.createPipe(name)
  if pipeStore[name] then error("Pipe already exists: " .. name) end
  pipeStore[name] = { data = "", read_waiting = {}, write_waiting = {} }
end

function pipeModule.writePipe(name, data)
  local p = pipeStore[name] or error("Pipe not found: " .. name)
  p.data = p.data .. data

  -- wake up any readers if data became available
  while (#p.read_waiting > 0) and (#p.data > 0) do
    resumeFirst(p.read_waiting)
  end

  -- if we exceed some size limit, yield until the data is read
  if (#p.data > 255) then table.insert(p.write_waiting, coroutine.running()) coroutine.yield() end
end

function pipeModule.readPipe(name)
  local p = pipeStore[name] or error("Pipe not found: " .. name)

  -- if no data is available, wait
  if (#p.data == 0) then table.insert(p.read_waiting, coroutine.running()) coroutine.yield() end

  local d = p.data
  p.data = ""

  -- if any writers were blocked, resume one
  if (#p.write_waiting > 0) then resumeFirst(p.write_waiting) end

  return d
end

return pipeModule