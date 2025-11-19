return {
  ["/boot/kernel.lua"] = { uid = 0, gid = 0, mode = 400 },
  ["/all_code.txt"] = { uid = 1000, gid = 0, mode = 777 },
  ["/etc/perms.lua"] = { uid = 0, gid = 0, mode = 600 },
  ["/dev/tty"]     = { uid=0, gid=0, mode=666 }, -- rw-rw-rw- (everyone needs tty)
  ["/dev/ringlog"] = { uid=0, gid=0, mode=644 }, -- r--r--r-- (read only for users)
  ["/dev/gpu0"]    = { uid=0, gid=0, mode=660 }, -- rw-rw---- (system only)
  ["/etc/passwd.lua"] = { uid = 0, gid = 0, mode = 600 },
  
}