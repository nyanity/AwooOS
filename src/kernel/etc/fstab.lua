-- AwooOS File System Table
return {
  {
    uuid = "f746c378-2f9b-4175-b3b0-8fd1e583627e",
    path = "/", -- Path on physical drive
    mount = "/", -- Mount point in VFS
    type = "rootfs",
    options = "rw",
  },
  {
    uuid = "f746c378-2f9b-4175-b3b0-8fd1e583627e",
    path = "/home",
    mount = "/home",
    type = "homefs",
    options = "rw,size=3000",
  },
  {
    uuid = "f746c378-2f9b-4175-b3b0-8fd1e583627e",
    path = "/swapfile",
    mount = "none",
    type = "swap",
    options = "size=4000",
  },
  {
    uuid = "f746c378-2f9b-4175-b3b0-8fd1e583627e",
    path = "/log",
    mount = "/var/log",
    type = "ringfs",
    options = "rw,size=4000",
  },
}
