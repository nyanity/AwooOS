--
-- /lib/errcheck.lua
-- the big book of everything that can go wrong.
-- if you see one of these, something probably blew up.
--

local g_tErrorCodes = {
  -- Success Codes
  STATUS_SUCCESS = 0,
  STATUS_PENDING = 1, -- for async operations like tty read

  -- Information Codes (100-199)
  
  -- Warning Codes (200-299)

  -- Error Codes (300+)
  STATUS_UNSUCCESSFUL = 300,
  STATUS_NOT_IMPLEMENTED = 301,
  
  -- Driver-specific errors
  STATUS_INVALID_DRIVER_OBJECT = 400,
  STATUS_INVALID_DRIVER_ENTRY = 401,
  STATUS_INVALID_DRIVER_INFO = 402,
  STATUS_DRIVER_VALIDATION_FAILED = 403,
  STATUS_DRIVER_INIT_FAILED = 404,
  STATUS_NO_SUCH_DEVICE = 405,
  STATUS_DEVICE_ALREADY_EXISTS = 406,
  STATUS_INVALID_DRIVER_TYPE = 407,
  STATUS_DRIVER_UNLOAD_FAILED = 408,
  
  -- Access and Security errors
  STATUS_ACCESS_DENIED = 500,
  STATUS_PRIVILEGE_NOT_HELD = 501,

  -- VFS/IO errors
  STATUS_INVALID_HANDLE = 600,
  STATUS_INVALID_PARAMETER = 601,
  STATUS_END_OF_FILE = 602,
  STATUS_NO_SUCH_FILE = 603,
  STATUS_DEVICE_BUSY = 604,
}

local g_tErrorStrings = {
  [0] = "STATUS_SUCCESS: The operation completed successfully.",
  [1] = "STATUS_PENDING: The operation is in progress and will complete later.",
  [300] = "STATUS_UNSUCCESSFUL: The operation failed.",
  [301] = "STATUS_NOT_IMPLEMENTED: The requested feature is not implemented.",
  [400] = "STATUS_INVALID_DRIVER_OBJECT: The driver object structure is malformed.",
  [401] = "STATUS_INVALID_DRIVER_ENTRY: The driver does not export a valid DriverEntry or UMDriverEntry function.",
  [402] = "STATUS_INVALID_DRIVER_INFO: The driver's g_tDriverInfo table is missing or malformed.",
  [403] = "STATUS_DRIVER_VALIDATION_FAILED: The driver file failed static validation.",
  [404] = "STATUS_DRIVER_INIT_FAILED: The driver's Entry function returned an error status.",
  [405] = "STATUS_NO_SUCH_DEVICE: The specified device does not exist.",
  [406] = "STATUS_DEVICE_ALREADY_EXISTS: An attempt was made to create a device that already exists.",
  [407] = "STATUS_INVALID_DRIVER_TYPE: The driver type specified in g_tDriverInfo is not valid.",
  [408] = "STATUS_DRIVER_UNLOAD_FAILED: The driver's Unload function returned an error.",
  [500] = "STATUS_ACCESS_DENIED: You do not have permission to perform this action.",
  [501] = "STATUS_PRIVILEGE_NOT_HELD: The operation requires a higher ring level.",
  [600] = "STATUS_INVALID_HANDLE: The provided file handle is not valid.",
  [601] = "STATUS_INVALID_PARAMETER: A parameter provided to a function was not valid.",
  [602] = "STATUS_END_OF_FILE: Reached the end of the file.",
  [603] = "STATUS_NO_SUCH_FILE: The file or directory does not exist.",
  [604] = "STATUS_DEVICE_BUSY: The device is currently busy with another request.",
}

local oErrCheck = {}

-- copy all codes into the exported table
for sName, nCode in pairs(g_tErrorCodes) do
  oErrCheck[sName] = nCode
end

-- function to get a human-readable string from a status code
function oErrCheck.fGetErrorString(nStatusCode)
  return g_tErrorStrings[nStatusCode] or "Unknown or unspecified error code: " .. tostring(nStatusCode)
end

return oErrCheck