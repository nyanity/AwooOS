<p align="center"> AwooOS Logo Image Placeholder </p>

----------

 **AwooOS** - an *open-source*, *Linux-like*, *full-featured* operating system written in Lua for the [OpenComputers](https://github.com/MightyPirates/OpenComputers) mod.

# **The project includes several parts**:
*   **Kernel**: The most important and complex part of the project. It is the system itself.
*   **Installer**: An advanced installer that can be run on a variety of other operating systems, created by the OC community.
*   **Bios**: The start-up shaft of the entire system. It is written to your computer's EEPROM.
*   **Packages**: Official and verified packages that are downloaded via a separate package manager and are optional 

# Features
*   **Custom BIOS (EEPROM)**: Wrote our own BIOS, with extremely flexible and deep settings for launching the system kernel.
*   **Rings**: Protection rings model implemented. (*Kernel Mode, Pipes, Driver Mode, User Mode*)
*   **Driver Model**: Support for drivers in *kernel mode* (KMDF) and *user mode* (UMDF).
*   **Virtual Filesystem(VFS)**: An abstract layer for working with different file systems.
*   **Sandbox**: Allows processes to be run in a *sandbox* and *isolated* from each other.
*   **Multithreading**: The ability to launch *multiple threads* and perform work *in parallel.**
    * It works through coroutines, so it's not true multithreading, but it's only what we have.
*   **Linux-like user environment**: Environment, commands, shortcuts, and behaviour are the same as you remember. 
*   **Advanced and pretty GUI**: A *visually appealing* and *user-friendly* GUI that allows you to forget you are working in OpenComputers.

# Installation

*Check that your OC's computer has an Internet Card and that your environment has software that allows you to make internet requests*

## Installing from Github

*   **OpenOS**

```
wget https://raw.githubusercontent.com/nyanity/AwooOS/refs/heads/main/src/iso/installer.lua install.lua
install
```

## Installing via OC's Package Managers

*   **OPPM**

```
Soon™
```

# AwooOS Technical Documentation

## Table of Contents

### Part I: Core Concepts
*   **[1. Introduction](./doc/01_Introduction/01_Architectural_Overview.md)**
    *   [1.1. Architectural Overview](./doc/01_Introduction/01_Architectural_Overview.md)
    *   [1.2. Core Design Philosophies](./doc/01_Introduction/02_Core_Philosophies.md)

### Part II: The Kernel
*   **[2. The AwooOS Kernel](./doc/02_Kernel/01_Kernel_Architecture.md)**
    *   [2.1. Kernel Architecture](./doc/02_Kernel/01_Kernel_Architecture.md)
    *   [2.2. The Boot Sequence](./doc/02_Kernel/02_Boot_Sequence.md)
    *   [2.3. The Process Model and Lifecycle](./doc/02_Kernel/03_Process_Model.md)

### Part III: System Programming Interfaces
*   **[3. The System Call Interface](./doc/03_System_Calls/README.md)**
*   **[4. The AwooOS Driver Model (ADM)](./doc/04_Driver_Model_ADM/README.md)**
    *   [4.1. Kernel-Mode Driver Framework (KMDF) Reference](./doc/04_Driver_Model_ADM/01_KMDF_Reference.md)
    *   [4.2. User-Mode Driver Framework (UMDF) Reference](./doc/04_Driver_Model_ADM/02_UMDF_Reference.md)

### Part IV: Subsystems
*   **[5. The Virtual File System (VFS) and I/O Subsystem](./doc/05_VFS_and_IO/01_VFS_Architecture.md)**
    *   [5.1. VFS Architecture](./doc/05_VFS_and_IO/01_VFS_Architecture.md)
    *   [5.2. The I/O Request Flow](./doc/05_VFS_and_IO/02_IO_Request_Flow.md)

### Part V: The User Environment
*   **[6. User Space](./doc/06_User_Space/01_Init_Process.md)**
    *   [6.1. The `init` Process (PID 1)](./doc/06_User_Space/01_Init_Process.md)
    *   [6.2. Standard Libraries](./doc/06_User_Space/02_Standard_Libraries.md)
    *   [6.3. The Shell and Execution Environment](./doc/06_User_Space/03_Shell_and_Execution_Environment.md)

### Part VI: Security
*   **[7. The AwooOS Security Model](./doc/07_Security/01_Ring_Model.md)**
    *   [7.1. The Ring Model](./doc/07_Security/01_Ring_Model.md)
    *   [7.2. Process Sandboxing](./doc/07_Security/02_Process_Sandboxing.md)

  