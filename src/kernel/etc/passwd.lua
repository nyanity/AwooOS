-- AwooOS Password File
return {
  root = {
    uid = 0,
    home = "/root",
    shell = "/bin/sh.lua",
    hash = "toorAURA_SALT",
    ring = 3 -- root is still user-mode usually
  },
  guest = {
    uid = 1000,
    home = "/home/guest",
    shell = "/bin/sh.lua",
    hash = "tseugAURA_SALT",
    ring = 3
  },
  dev = {
    uid = 0, -- effectively root
    home = "/",
    shell = "/bin/sh.lua",
    hash = "vedAURA_SALT", -- pass: dev
    ring = 0 -- UNLIMITED POWER
  }
}