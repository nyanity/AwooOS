-- AwooOS Password File
-- Hashes are simple: string.reverse(pass) .. "AURA_SALT"
return {
  root = {
    uid = 0,
    home = "/root",
    shell = "/bin/sh.lua",
    hash = "toorAURA_SALT" -- hash("root")
  },
  guest = {
    uid = 1000,
    home = "/home/guest",
    shell = "/bin/sh.lua",
    hash = "tseugAURA_SALT" -- hash("guest")
  }
}