-- echo - display a line of text
local tArgs = env.ARGS or {}
print(table.concat(tArgs, " "))