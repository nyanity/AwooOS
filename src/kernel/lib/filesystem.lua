local function newFileObject(path, dataref)
  local pos = 1
  local obj = {}

  local function clampPosition()
    if pos < 1 then pos = 1 end
    if pos > #dataref + 1 then pos = #dataref + 1 end
  end

  obj.read = function(_)
    return nil -- default: no-op for write/append
  end
  obj.write = function(...)
    return nil -- default: no-op for read
  end

  obj.seek = function(whence, offset)
    offset = offset or 0
    local actions = {
      set = function()
        pos = offset + 1
      end,
      cur = function()
        pos = pos + offset
      end,
      ["end"] = function() -- 'end' fallback
        pos = #dataref + offset + 1
      end
    }
    if (actions[whence]) then actions[whence]() else actions["end"]() end
    clampPosition()
    return pos - 1
  end

  obj.close = function()
    obj = nil
  end

  return obj, function()
    return pos
  end
end

return {
  open = function(path, mode)
    local fdata = filesystem[path] or ""
    local fileObj, getPos = newFileObject(path, fdata)

    local function readMode()
      fileObj.read = function(_, n)
        local startPos = getPos()
        local r = string.sub(fdata, startPos, startPos + (n or 1) - 1)
        local nextPos = startPos + (n or 1)
        if nextPos > (#fdata + 1) then nextPos = #fdata + 1 end
        filesystem[path] = fdata -- ensure it’s updated
        fileObj.seek("set", nextPos - 1)
        return r
      end
    end

    local function writeMode(append)
      if append then fileObj.seek("end", 0) else fileObj.seek("set", 0) end
      fileObj.write = function(_, ...)
        local args = {...}
        local new_data = table.concat(args)
        if append then filesystem[path] = filesystem[path] .. new_data else filesystem[path] = new_data end
        fdata = filesystem[path]
      end
    end

    local modeMap = {
      r = readMode,
      w = function() writeMode(false) end,
      a = function() writeMode(true) end
    }

    -- no if-statement, just a table-lookup or error
    if modeMap[mode] then modeMap[mode]() else error("Invalid file mode: " .. tostring(mode)) end

    return fileObj
  end,

  list = function(path)
    local results = {}
    for k, _ in pairs(filesystem) do
      if string.sub(k, 1, #path) == path then table.insert(results, string.sub(k, #path + 1)) end
    end
    return results
  end
}