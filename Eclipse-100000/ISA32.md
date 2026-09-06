# ISA for my architecture name
Full detailed and technical explanation is in paper

## Fragmented register
32, 32-bit rx register each one fragmented into 2 ry and hence 4 rz register, they are encoded as follows:

| Base register | Sub-specifier |
|---------------|---------------|
|    5 bits     |    3 bits     |

Where sub specifier is

| Bits    | Sub-reg |
| -------------- | --------------- |
| 000 | rx |
| 001, 010| ry0, ry1 |
| 011, 100, 101, 110 | rz0, rz1, rz2, rz3 |

Note that rx31 and rx30 are soft-reserved by the compiler - compiler uses them for storing temporary variables, or usually as 0-register.

Notice how with that pattern 32 combinations are unused:)

### Special registers
Currentely there are 3 special register: SP, LR and GP. SP is regular stack pointer, LR is link register that stores the address of the last CALL return address, hence non-leaf functions have to have prologue and epilogue saving that LR register. GP register(Global pointer) stores the initial value of the SP before program start, since global variable are stored right before the stack.

## Memory map
Note: Soon this will be deprecated and actual numbers would change in favor of 256MB RAM module instead of 64MB one
There are several special structures in the memory
VRAM - 0x04000000 - 0x04100000
The MMIO stores all the I/O data, such as last_key in, timer and I forgot what else
MMIO 0x04100008+
By default stack lives at 0x03FFFFF0 and grows downwards.

### Interrupt vectors
In case of interrupt PC jumps to one of those addresses, based on exact interrupt type
0x64 : Syscall
0x68 : Timer interrupt
0x6C : Key interrupt
0x70 : Memory Protection Fault
0x74 : Division by Zero



