
---

# AwooOS System Call Interface Specification

## 1. Introduction and Core Philosophy

The System Call, or "syscall," serves as the canonical, mandatory, and sole interface between user-space processes (Rings 1-3) and the AwooOS kernel (Ring 0). This interface is the fundamental mechanism for requesting privileged operations, such as hardware interaction, process management, or inter-process communication (IPC). The entire security and stability model of the operating system is predicated on the strict enforcement of this boundary.

All interactions are funneled through a single, globally available function, `syscall()`, which acts as a gateway to the kernel's dispatcher. The dispatcher is responsible for identifying the calling process, validating its privileges, and routing its request to the appropriate kernel subsystem or registered Ring 1 service. This design intentionally abstracts the kernel's internal complexity from user-space applications, presenting a stable and well-defined API while allowing the underlying kernel implementation to evolve.

The architecture borrows principles from both monolithic and microkernel designs. While core scheduling and process management reside within the kernel monolith, complex services like the Virtual File System (VFS) or the Dynamic Kernel Module System (DKMS) are implemented as Ring 1 processes. The syscall interface facilitates this hybrid model through a mechanism known as "syscall overriding," allowing these privileged services to intercept and handle specific syscalls, effectively extending the kernel's functionality from user-space.

## 2. The Syscall Dispatch Mechanism

Every invocation of `syscall(name, ...)` from any process triggers a sequence of operations within the `kernel.syscall_dispatch` function. This sequence is critical to the integrity of the system.

Upon invocation, the dispatcher first identifies the execution context. It retrieves the coroutine of the currently running code via `coroutine.running()` and uses the kernel's internal `tPidMap` table to resolve this coroutine to a Process ID (PID). This PID is the immutable identity of the caller for the duration of the syscall. If the coroutine is not tracked by the kernel, this indicates a severe integrity violation, and the system will immediately trigger a kernel panic.

With the caller's PID and its associated privilege Ring established, the dispatcher proceeds to the request routing phase. The first check is against the `tSyscallOverrides` table. This table maps syscall names to the PID of a Ring 1 service that has registered to handle that specific call. If an entry exists for the requested syscall, the dispatcher does not execute any kernel code directly. Instead, it marshals the syscall name and its arguments into an IPC signal and sends it to the registered handler process. The original calling process is then put into a `sleeping` state, pending a response from the handler. The handler service is now fully responsible for processing the request and, crucially, for waking the original caller with the appropriate return values. This mechanism is the foundation of the microkernel-like services in AwooOS.

If no override is registered for the syscall, the dispatcher proceeds with the standard kernel path. It consults the main `tSyscallTable` to find the handler function associated with the syscall name. A critical security check is then performed: the caller's Ring level is validated against the `allowed_rings` array defined for that syscall. Any attempt by a process to invoke a syscall from a privilege level not explicitly permitted in this array constitutes a Ring violation. Such violations are considered fatal for the offending process; it is immediately terminated, and the syscall fails.

Assuming the Ring check passes, the kernel invokes the handler function within a protected call (`pcall`). This ensures that an error within the syscall's implementation itself does not crash the entire kernel. The PID of the caller is always passed as the first argument to the handler function, providing it with the necessary context to perform its operations. The return values from the handler function are then transparently passed back to the original caller, completing the syscall lifecycle.

## 3. Defining a New System Call

Adding a new system call to the AwooOS kernel is a straightforward process that involves defining a handler function and registering it in the `kernel.tSyscallTable`.

A system call registration is a table with two required keys:
*   `func`: The Lua function that will be executed when the syscall is invoked. This function will always receive the caller's PID as its first argument, followed by any arguments passed by the user-space process.
*   `allowed_rings`: A table (array) of numbers representing the Ring levels that are permitted to invoke this syscall.

Consider a hypothetical syscall, `kernel_get_version`, which returns the kernel's version string. Its implementation and registration would appear as follows:

```lua
-- Within kernel.lua, in the syscall definitions section

-- 1. Define the handler function.
-- The function's name is arbitrary, but a descriptive convention is recommended.
local function syscall_get_kernel_version(nCallingPid)
  -- This syscall is simple and doesn't use the nCallingPid,
  -- but the parameter must be present to accept the dispatcher's argument.
  
  -- The version is hardcoded for this example.
  local KERNEL_VERSION = "AwooOS v0.21B25YM11"
  
  -- Syscall handlers should return values that will be passed
  -- back to the user-space caller.
  return KERNEL_VERSION
end

-- 2. Register the syscall in the main table.
kernel.tSyscallTable["kernel_get_version"] = {
  func = syscall_get_kernel_version,
  
  -- We allow any process, regardless of privilege, to query the version.
  allowed_rings = {0, 1, 2, 2.5, 3} 
}
```

Once registered, any process running in a permitted ring can invoke this new functionality:

```lua
-- In a user-space application (e.g., Ring 3)
local version = syscall("kernel_get_version")
print("Running on kernel version: " .. version)
```

The handler function must be carefully designed to be robust and secure, as it executes with the full authority of the kernel. It must validate all incoming parameters and handle potential error conditions gracefully.

## 4. System Call Catalogue

---

# **Kernel Management Syscalls**

These syscalls provide interfaces for core kernel operations and are typically restricted to highly privileged processes.

#### `kernel_panic`
**Synopsis:** Triggers an immediate, unrecoverable kernel panic, halting the system.
*   **Signature:** `syscall("kernel_panic", reason)`
*   **Parameters:**
    *   `reason` (string): A message describing the reason for the panic. This message will be displayed on the Kernel Panic screen.
*   **Return Values:** This function does not return. The system is halted.
*   **Allowed Rings:** `{0}`
*   **Description:** This is the most destructive syscall and is reserved for Ring 0 code to use when a catastrophic, unrecoverable error is detected. It immediately stops the scheduler, dumps system state to the screen, and enters an infinite loop.

#### `kernel_yield`
**Synopsis:** Yields the process's current timeslice to the scheduler.
*   **Signature:** `syscall("kernel_yield")`
*   **Parameters:** None.
*   **Return Values:** None.
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** A cooperative multitasking primitive. This call signals to the kernel that the current process has finished its work for the current timeslice and can be temporarily suspended, allowing other `ready` processes to run. This is functionally equivalent to `coroutine.yield()`.

#### `kernel_host_yield`
**Synopsis:** Yields control not just to the scheduler, but to the host operating system (OpenOS).
*   **Signature:** `syscall("kernel_host_yield")`
*   **Parameters:** None.
*   **Return Values:**
    *   `success` (boolean): Always `true`.
*   **Allowed Rings:** `{0, 1}`
*   **Description:** This is a low-level call that forces the entire AwooOS virtual machine to yield execution for a minimal duration (`computer.pullSignal(0)`). It is used by the kernel's main loop to wait for external hardware events without busy-waiting, thereby reducing CPU load on the host machine.

#### `kernel_register_pipeline`
**Synopsis:** Registers the calling process as the master Ring 1 Pipeline Manager.
*   **Signature:** `syscall("kernel_register_pipeline")`
*   **Parameters:** None.
*   **Return Values:** None.
*   **Allowed Rings:** `{0, 1}`
*   **Description:** This syscall must be called by the initial Ring 1 process during boot. It stores the caller's PID in the kernel's `nPipelinePid` variable. The kernel uses this PID to forward all raw hardware events (e.g., `component_added`, `key_down`) for processing. Only one Pipeline Manager can be registered.

#### `kernel_log`
**Synopsis:** Writes a message to the primary kernel boot log.
*   **Signature:** `syscall("kernel_log", message)`
*   **Parameters:**
    *   `message` (string): The text to be logged.
*   **Return Values:**
    *   `success` (boolean): Always `true`.
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** Provides a privileged logging mechanism. Messages are printed to the screen using the kernel's `kprint` function. This allows Ring 1 services and Ring 2 drivers to output diagnostic information during the boot process before a full TTY driver and userspace logging daemon are available.

#### `kernel_get_boot_log`
**Synopsis:** Retrieves the entire contents of the boot log and clears it.
*   **Signature:** `syscall("kernel_get_boot_log")`
*   **Parameters:** None.
*   **Return Values:**
    *   `log_contents` (string): A single string containing all messages logged since boot, separated by newlines.
*   **Allowed Rings:** `{1, 2}`
*   **Description:** This syscall is intended to be used once by a TTY or logging driver during its initialization. It retrieves the history of all `kprint` messages generated during early boot, allowing them to be displayed on the primary console. The internal boot log buffer is cleared after this call to free memory.

#### `syscall_override`
**Synopsis:** Registers the calling process to intercept and handle a specific syscall.
*   **Signature:** `syscall("syscall_override", syscall_name)`
*   **Parameters:**
    *   `syscall_name` (string): The name of the syscall to intercept (e.g., `"vfs_open"`).
*   **Return Values:**
    *   `success` (boolean): Always `true`.
*   **Allowed Rings:** `{1}`
*   **Description:** A powerful mechanism central to the AwooOS microkernel architecture. A Ring 1 process can use this to become the designated handler for a syscall. Subsequently, any process attempting to call `syscall_name` will have its request redirected to the handler process via an IPC signal. See section 2 for a detailed description of the dispatch flow.

---

### **Process Management Syscalls**

This group of syscalls provides the necessary primitives for creating and managing processes.

#### `process_spawn`
**Synopsis:** Creates and starts a new process from an executable file.
*   **Signature:** `syscall("process_spawn", path, ring, pass_env)`
*   **Parameters:**
    *   `path` (string): The absolute path to the Lua source file to be executed.
    *   `ring` (number): The privilege Ring the new process will run in.
    *   `pass_env` (table, optional): A table that will be made available to the new process in its global `env` variable.
*   **Return Values:**
    *   On success: `new_pid` (number), `nil`
    *   On failure: `nil`, `error_message` (string)
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** This is the fundamental function for process creation. The kernel reads the file at `path`, creates a new sandboxed environment for it, assigns it a new PID, and adds it to the scheduler's `ready` queue. A critical security check is performed: a process can only spawn new processes at its own Ring level or a numerically higher (less privileged) Ring. For example, a Ring 1 process can spawn a Ring 1, 2, or 3 process, but a Ring 3 process can only spawn another Ring 3 process.

#### `process_yield`
**Synopsis:** Cooperatively yields the processor.
*   **Signature:** `syscall("process_yield")`
*   **Parameters:** None.
*   **Return Values:**
    *   `success` (boolean): Always `true`.
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** This is an alias for `kernel_yield`. It moves the current process from the `running` state to the `ready` state, allowing the scheduler to run other processes.

#### `process_wait`
**Synopsis:** Pauses the current process until a target process terminates.
*   **Signature:** `syscall("process_wait", target_pid)`
*   **Parameters:**
    *   `target_pid` (number): The PID of the process to wait for.
*   **Return Values:**
    *   On success: `true`, `nil`
    *   On failure: `nil`, `error_message` (string, e.g., "Invalid PID")
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** Puts the calling process into a `sleeping` state. The kernel will automatically move it back to the `ready` state once the process identified by `target_pid` enters the `dead` state. If the target process is already dead when this call is made, it returns immediately.

#### `process_get_pid`
**Synopsis:** Returns the Process ID of the calling process.
*   **Signature:** `syscall("process_get_pid")`
*   **Parameters:** None.
*   **Return Values:**
    *   `pid` (number): The PID of the current process.
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** A simple utility for a process to learn its own identity within the system.

#### `process_get_ring`
**Synopsis:** Returns the Ring level of the calling process.
*   **Signature:** `syscall("process_get_ring")`
*   **Parameters:** None.
*   **Return Values:**
    *   `ring` (number): The Ring level of the current process.
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** Allows a process to determine its own privilege level.

---

### **Raw Component Syscalls**

These syscalls provide direct, low-level access to OpenComputers components. Access is highly restricted for security reasons.

#### `raw_component_list`
**Synopsis:** Lists all available hardware components attached to the machine.
*   **Signature:** `syscall("raw_component_list", filter)`
*   **Parameters:**
    *   `filter` (string, optional): A component type to filter by (e.g., `"gpu"`).
*   **Return Values:**
    *   On success: `true`, `component_table` (table) where keys are addresses and values are component types.
    *   On failure: `false`, `error_message` (string)
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** Provides a mechanism for privileged processes (like the Pipeline Manager or drivers) to discover hardware. Ring 3 processes are forbidden from using this call to prevent them from mapping the system's hardware layout.

#### `raw_component_invoke`
**Synopsis:** Invokes a method directly on a hardware component.
*   **Signature:** `syscall("raw_component_invoke", address, method, ...)`
*   **Parameters:**
    *   `address` (string): The UUID address of the component.
    *   `method` (string): The name of the method to call.
    *   `...`: Any additional arguments to pass to the component method.
*   **Return Values:**
    *   The first return value is a boolean indicating the success of the `pcall` used to invoke the method. Subsequent values are the returns from the component method itself or an error message.
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** This is the primary mechanism for direct hardware interaction. It is restricted to privileged processes to ensure that all hardware access is mediated by a driver that can enforce policy and prevent misuse.

#### `raw_component_proxy`
**Synopsis:** Creates a proxy object for a hardware component.
*   **Signature:** `syscall("raw_component_proxy", address)`
*   **Parameters:**
    *   `address` (string): The UUID address of the component.
*   **Return Values:**
    *   On success: `proxy_object` (table), `nil`
    *   On failure: `nil`, `error_message` (string)
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** Returns a standard OpenComputers component proxy table. This is functionally similar to `raw_component.proxy` but is exposed as a syscall to enforce Ring-based security. Drivers use this to get a handle to the specific hardware they are intended to manage.

---

### **Inter-Process Communication (IPC) Syscalls**

These syscalls facilitate communication between processes.

#### `signal_send`
**Synopsis:** Sends an asynchronous signal (message) to another process.
*   **Signature:** `syscall("signal_send", target_pid, ...)`
*   **Parameters:**
    *   `target_pid` (number): The PID of the recipient process.
    *   `...`: The signal payload, consisting of one or more values of any type.
*   **Return Values:**
    *   On success: `true`, `nil`
    *   On failure: `nil`, `error_message` (string, e.g., "Invalid PID")
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** The primary IPC mechanism in AwooOS. If the target process is currently sleeping and waiting for a signal, it is immediately woken up, and the signal payload is returned from its `signal_pull` call. Otherwise, the signal is enqueued in the target process's signal queue for later retrieval.

#### `signal_pull`
**Synopsis:** Waits for and retrieves the next signal from the process's queue.
*   **Signature:** `syscall("signal_pull", timeout)`
*   **Parameters:**
    *   `timeout` (number, optional): Not currently implemented. The call will block indefinitely.
*   **Return Values:**
    *   `true`, `sender_pid` (number), `...` (the signal payload).
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** If a signal is already waiting in the process's queue, it is dequeued and its payload is returned immediately. If the queue is empty, the process is put into a `sleeping` state until a signal is received via `signal_send`. This is a blocking operation.

---

### **Virtual File System (VFS) Syscalls**

These are the primitive, boot-time VFS syscalls. They typically operate directly on the root filesystem found by the BIOS. It is expected that a Ring 1 VFS service will override these syscalls to provide a more advanced, mountpoint-aware implementation.

#### `vfs_read_file`
**Synopsis:** Reads the entire contents of a file into memory.
*   **Signature:** `syscall("vfs_read_file", path)`
*   **Parameters:**
    *   `path` (string): The absolute path to the file.
*   **Return Values:**
    *   On success: `file_contents` (string), `nil`
    *   On failure: `nil`, `error_message` (string)
*   **Allowed Rings:** `{0, 1, 2}`
*   **Description:** A privileged, high-level read operation used during boot to load critical system files like the Pipeline Manager and drivers. It is not intended for general-purpose file I/O.

#### `vfs_open`, `vfs_read`, `vfs_write`, `vfs_close`, `vfs_list`
**Synopsis:** Standard file I/O operations.
*   **Signatures:**
    *   `syscall("vfs_open", path, mode)`
    *   `syscall("vfs_read", handle, count)`
    *   `syscall("vfs_write", handle, data)`
    *   `syscall("vfs_close", handle)`
    *   `syscall("vfs_list", path)`
*   **Allowed Rings:** `{0, 1, 2, 2.5, 3}`
*   **Description:** These functions provide a basic, handle-based file I/O API. In the pristine kernel, they are simple wrappers around the methods of the root filesystem component. A full VFS service in Ring 1 is expected to override these to manage file descriptors, permissions, mount points, and routing I/O to device drivers for special files (e.g., `/dev/tty`).

---

### **Computer Control Syscalls**

These syscalls control the power state of the machine.

#### `computer_shutdown`
**Synopsis:** Shuts down the computer.
*   **Signature:** `syscall("computer_shutdown")`
*   **Parameters:** None.
*   **Return Values:** Does not return.
*   **Allowed Rings:** `{0, 1, 2, 2.5}`
*   **Description:** Halts the machine. Standard users (Ring 3) are not permitted to shut down the system.

#### `computer_reboot`
**Synopsis:** Reboots the computer.
*   **Signature:** `syscall("computer_reboot")`
*   **Parameters:** None.
*   **Return Values:** Does not return.
*   **Allowed Rings:** `{0, 1, 2, 2.5}`
*   **Description:** Reboots the machine. Standard users (Ring 3) are not permitted to reboot the system.