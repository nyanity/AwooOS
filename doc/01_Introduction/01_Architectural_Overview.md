## The Layered Model

AwooOS is structured in a series of layers, each with a distinct set of responsibilities and privileges, enforced by the Ring Model.

- **Ring 0: The Kernel (`kernel.lua`)**: The core of the operating system. It is responsible for fundamental operations: process scheduling, memory management (conceptual), syscall dispatching, and the initial handling of hardware events. It is the most privileged component and serves as the ultimate authority.

- **Ring 1: System Services (`pipeline_manager.lua`, `dkms.lua`)**: Privileged user-space processes that manage core OS subsystems. The Dynamic Kernel Module System (DKMS) is the canonical example, acting as the I/O Manager. These services extend the kernel's functionality by overriding syscalls and communicating directly with drivers.

- **Ring 2: Kernel-Mode Drivers (`*.sys.lua`)**: Isolated processes that have direct access to hardware components. They are responsible for abstracting hardware details and presenting devices through a standardized I/O interface (IRPs).

- **Ring 2.5: User-Mode Driver Hosts (`driverhost.lua`)**: A specialized privilege level for processes that host and supervise less-trusted User-Mode Drivers.

- **Ring 3: Applications and User-Mode Drivers (`init.lua`, `sh.lua`, `*.umd.lua`)**: The least privileged layer. All applications, shells, and standard libraries run here. Access to system resources is strictly mediated through the syscall interface.

## Component Diagram

(A high-level block diagram illustrating the interaction between the Kernel, DKMS, Drivers, and User Applications would be placed here.)