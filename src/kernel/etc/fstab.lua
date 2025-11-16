-- AwooOS File System Table
return {
  { uuid = "c7bd352c-57fc-4128-8630-7ea067954133", path = "/", mount = "/", type = "rootfs", options = "rw", },
  { uuid = "c7bd352c-57fc-4128-8630-7ea067954133", path = "/home", mount = "/home", type = "homefs", options = "rw,size=3000", },
  { uuid = "c7bd352c-57fc-4128-8630-7ea067954133", path = "/swapfile", mount = "none", type = "swap", options = "size=3000", },
  { uuid = "c7bd352c-57fc-4128-8630-7ea067954133", path = "/log", mount = "/var/log", type = "ringfs", options = "rw,size=3000", },
}
