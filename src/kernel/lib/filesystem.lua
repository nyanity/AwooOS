return {
    open = function(path, mode)
        local f = {}
        local pos = 1
        local data = filesystem[path] or ""
      
        if mode == "r" then
            function f:read(n)
                local read_data = string.sub(data, pos, pos + (n or 1) - 1)
                pos = pos + (n or 1)
                if pos > string.len(data) + 1 then
                  pos = string.len(data) + 1
                end
                return read_data
            end
      
        elseif mode == "w" then
            function f:write(...)
                local args = {...}
                for i,v in ipairs(args) do
                    data = data .. tostring(v)
                end
                filesystem[path] = data
            end
      
        elseif mode == "a" then
            pos = string.len(data) + 1
            function f:write(...)
                local args = {...}
                for i,v in ipairs(args) do
                    data = data .. tostring(v)
                end
                filesystem[path] = data
            end
        else
            error("Invalid file mode")
        end
        function f:seek(whence, offset)
          if whence == "set" then
            pos = (offset or 0) + 1
          elseif whence == "cur" then
            pos = pos + (offset or 0)          
          elseif whence == "end" then
            pos = string.len(data) + (offset or 0) + 1
          end
          if pos < 1 then
            pos = 1
          elseif pos > string.len(data) + 1 then
            pos = string.len(data) + 1
          end
        
          return pos - 1
        end
        function f:close()
          f = nil
        end
      
        return f
    end,
    list = function(path)
      local results = {}
      for k, _ in pairs(filesystem) do
        if string.sub(k, 1, string.len(path)) == path then
          table.insert(results, string.sub(k, string.len(path) + 1))
        end
      end
      return results
    end
  }