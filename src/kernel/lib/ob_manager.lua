--
-- /sys/ob_manager.lua
-- Object Manager & Handle Table logic.
-- Fixed: Now supports legacy FD aliases (0, 1, 2) pointing to secure tokens.
--

local oOb = {}
local tProcessHandleTables = {} -- [pid] = { tHandles={}, tAliases={} }

-- generate a cryptographically secure* handle.
-- *not actually crypto secure, but good enough to stop script kiddies.
local function fGenerateHandleToken()
    local sPart1 = string.format("%x", math.random(0, 0xFFFFFF))
    local sPart2 = string.format("%x", math.floor(os.clock() * 10000))
    local sPart3 = string.format("%x", math.random(0, 0xFFFF))
    return "H-" .. sPart1 .. "-" .. sPart2 .. "-" .. sPart3
end

-- Initialize a handle table for a new process
function oOb.InitProcess(nPid)
    if not tProcessHandleTables[nPid] then
        tProcessHandleTables[nPid] = {
            tHandles = {},   -- Map: Token (String) -> ObjectHeader
            tAliases = {}    -- Map: Alias (Number) -> Token (String)
        }
    end
end

-- Clean up when a process dies
function oOb.DestroyProcess(nPid)
    tProcessHandleTables[nPid] = nil
end

-- Add an object to the process handle table and get a secure Handle back
function oOb.CreateHandle(nPid, tObjectHeader)
    oOb.InitProcess(nPid)
    local tTable = tProcessHandleTables[nPid]
    
    local sToken = fGenerateHandleToken()
    -- collision check because random is pseudo
    while tTable.tHandles[sToken] do sToken = fGenerateHandleToken() end
    
    tTable.tHandles[sToken] = tObjectHeader
    return sToken
end

-- Manually map a legacy FD (e.g. 1) to an existing Token
function oOb.SetHandleAlias(nPid, nAliasFd, sToken)
    oOb.InitProcess(nPid)
    local tTable = tProcessHandleTables[nPid]
    
    -- verify token exists first
    if tTable.tHandles[sToken] then
        tTable.tAliases[nAliasFd] = sToken
        return true
    end
    return false
end

-- Resolve a Handle (String Token OR Integer Alias) to an Object
function oOb.ReferenceObjectByHandle(nPid, vHandle)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return nil end
    
    local sRealToken = vHandle
    
    -- if user provided a number (e.g. 1 for stdout), look up the alias
    if type(vHandle) == "number" then
        sRealToken = tTable.tAliases[vHandle]
        if not sRealToken then return nil end -- alias not found
    end
    
    -- now look up the real object by token
    return tTable.tHandles[sRealToken]
end

-- Get the token string from an alias (helper for cloning)
function oOb.GetTokenByAlias(nPid, nAlias)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return nil end
    return tTable.tAliases[nAlias]
end

-- Close a handle
function oOb.CloseHandle(nPid, vHandle)
    local tTable = tProcessHandleTables[nPid]
    if not tTable then return false end
    
    -- if closing an alias (e.g. fs.close(1)), we just remove the alias?
    -- usually closing fd 1 closes the underlying resource too.
    
    local sRealToken = vHandle
    if type(vHandle) == "number" then
        sRealToken = tTable.tAliases[vHandle]
        tTable.tAliases[vHandle] = nil
    end
    
    if sRealToken and tTable.tHandles[sRealToken] then
        -- destroy object ref. 
        -- in a real OS we would decrement refcount, but here we kill it.
        tTable.tHandles[sRealToken] = nil 
        
        -- clean up any other aliases pointing to this dead token
        for k, v in pairs(tTable.tAliases) do
            if v == sRealToken then tTable.tAliases[k] = nil end
        end
        return true
    end
    return false
end

return oOb