-- /lib/ipc.lua
-- not used
local ipc_module = {}
local queues = {}
local queue_id_counter = 1

function ipc_module.create_queue()
    local queue_id = queue_id_counter
    queue_id_counter = queue_id_counter + 1
    queues[queue_id] = { messages = {} }
    return queue_id
end

function ipc_module.send_message(queue_id, message)
    local queue = queues[queue_id]
    if not queue then return false, "Invalid queue ID" end
    table.insert(queue.messages, message)
    return true
end

function ipc_module.receive_message(queue_id)
    local queue = queues[queue_id]
    if not queue then return nil, "Invalid queue ID" end
    if #queue.messages == 0 then return nil, "Queue empty" end
    return table.remove(queue.messages, 1), nil
end

return ipc_module