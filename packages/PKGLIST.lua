-- Axis OS Package Manifest
return {
    { 
        name = "Drivers", 
        items = {
            { name = "s.txt", path = "packages/drivers/s.txt", type = "file" },
            { name = "Experimental", type = "tree", items = {
                { name = "s.txt", path = "packages/drivers/experimental/s.txt", type = "file" },
                { name = "s.txt", path = "packages/drivers/experimental/s.txt", type = "file" }
            }},
        }
    },
    { 
        name = "Executable", 
        items = {
            { name = "s.txt", path = "packages/executable/s.txt", type = "file" },
            { name = "Utils", type = "tree", items = {
                 { name = "s.txt", path = "packages/executable/experimental/s.txt", type = "file" }
            }}
        }
    },
    { name = "Modules", items = {} },
    { name = "Multilib", items = {} }
}