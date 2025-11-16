-- AwooOS Password File
-- Hashes are simple: string.reverse(pass) .. "AURA_SALT"
return {
  root = { hash = "toorAURA_SALT", uid = 0, gid = 0, shell = "/bin/sh.lua", home = "/home/root", },
  user = { hash = "resuAURA_SALT", uid = 1000, gid = 1000, shell = "/bin/sh.lua", home = "/home/user", },
}
