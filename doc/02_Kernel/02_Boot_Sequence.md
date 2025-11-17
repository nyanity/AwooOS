# 2.2. The Boot Sequence

The process of starting AwooOS involves a multi-stage sequence, beginning with the BIOS and culminating in the execution of the first user-space process.

## Stage 1: BIOS Execution (`eeprom.lua`)

1.  **Power-On Self-Test (POST)**: The BIOS initializes, beeps, and attempts to locate and bind a primary GPU and screen.
2.  **Boot Medium Discovery**: It iterates through all attached filesystem components, searching for a file named `/kernel.lua`.
3.  **Kernel Loading**: Upon finding a valid kernel file, the BIOS reads its entire contents into memory.
4.  **Environment Preparation**: A minimal execution environment is prepared for the kernel, injecting raw proxies for `component` and `computer`, and the address of the boot filesystem.
5.  **Handoff**: The BIOS executes the loaded kernel code within a protected call (`pcall`) and ceases its own operations.

## Stage 2: Kernel Initialization (`kernel.lua`)

1.  **Early Logging**: The kernel initializes its primitive `kprint` logger.
2.  **Root FS Mount**: The kernel reads `/etc/fstab.lua` from the boot device to identify and mount the root filesystem.
3.  **PID 0 Creation**: The kernel registers itself as the first process, PID 0.
4.  **Ring 1 Service Launch**: The kernel uses `create_process` to start the primary Ring 1 service, the Pipeline Manager (`/lib/pipeline_manager.lua`).
5.  **Scheduler Handoff**: The kernel enters its main scheduler loop, effectively completing the boot process. The system is now considered "running".

