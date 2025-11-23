-- AxisOS File System Table
return {
  { uuid = "8d390d50-4bc9-4d6d-8f63-c9057f8d20ff", path = "/", mount = "/", type = "rootfs", options = "rw", },
  { uuid = "8d390d50-4bc9-4d6d-8f63-c9057f8d20ff", path = "/home", mount = "/home", type = "homefs", options = "rw,size=3000", },
  { uuid = "8d390d50-4bc9-4d6d-8f63-c9057f8d20ff", path = "/swapfile", mount = "none", type = "swap", options = "size=3000", },
  { uuid = "8d390d50-4bc9-4d6d-8f63-c9057f8d20ff", path = "/log", mount = "/var/log", type = "ringfs", options = "rw,size=3000", },
  { uuid = "virtual", path = "/dev/ringlog", mount = "/var/log/syslog", type = "ringfs", options = "rw,size=8192" },
}
