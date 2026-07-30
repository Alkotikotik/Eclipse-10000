# FLARE-10K Documentation

I will quickly run through all the features of my language.

## Overview
FLARE-10K is a compiled, low-level systems programming language currently compiling into assembly for my custom CPU's ISA. Although the intermediate representation (IR) is fairly general, a backend for other architectures could theoretically be implemented.

## Variables
FLARE-10K currently provides 7 primitive types:

`u32`, `u16`, `u8`  
`i32`, `i16`, `i8`  
`bool`

### Declarations
Variables are declared as follows:

```c
<type> <name> = <value>;
```

For example:

```c
u32 example = 512;
```

Variables can also be declared uninitialized:

```c
i16 uninit;
```

An uninitialized value defaults to `NULL`, which is just `0`.

### Pinning
Variables can be explicitly pinned to a particular register using **#r(x/y/z)NS** notation, where `N` is `0-31` and `S` is the size sub-specifier. The variable must be placed in a register that matches its exact size. For example:

```c
#rx1 i32 variable = -1024;
```

Regardless of what the allocator does, that variable will be stored in `rx1`. This is designed for easier inline hardware interactions and for pinning important variables, requiring high speed access, directly to registers.

### Arrays
FLARE-10K features standard arrays, declared as follows:

```c
u32 arr[4] = {0, 1, 2, 3};
```

An array can also be left zero-initialized:

```c
u32 arr[4];
```

### Global Definitions
Global variables are declared as follows:

```c
#def u32 EXAMPLE = 12;
```

They can also be pinned:

```c
#def #rx0 PINNED = 12;
```

### Casting
Casting works similarly to Rust:

```c
<variable> as <type>
```

For example:

```c
example as i16
```

Lower bits are used when shrinking types. Values are zero-extended when cast to unsigned types, and sign-extended when cast to signed types.

## Operations
FLARE-10K supports standard operations ranging from bitwise to arithmetic. However, it currently lacks division and modulo division because they have not yet been implemented in the CPU.

## Data Structures
Structs are declared using the `arch` keyword and work like standard structures:

```c
arch Example {
    u8 a;
    u8 b;
    bool is_true;
}
```

Fields can be accessed using standard dot notation:

```c
Example.a = 8;
```

### Regarch
Similar to pinning variables, structs can also be pinned to a register, provided they are exactly 4 bytes in size. They are declared using the `regarch` keyword, as shown below:

```c
regarch RGBA {
    u8 r;
    u8 g;
    u8 b;
    u8 a;
}
```

This feature provides fast access to important structs. A `regarch` can also be pinned to a specific register:

```c
#rx1 RGBA color;
```

## Functions
Functions are declared as follows:

```c
func <name>(<args>) => <return type> <return variable> {}
```

For example:

```c
func example(i8: a, i8: b) => bool is_equal {}
```

Functions can obviously be `void`. In that case, omit the `=>` arrow and everything after it:

```c
func log_event(u32: code) {}
```

### Return Variable
You might have noticed the return variable in the signature. This is an optional function variable declared directly in the function signature.

It is initialized to `NULL` and can be pinned. If omitted, the function behaves like a standard function. It is used just like a regular variable within the body. If a function does not contain an explicit `return` statement but has a return variable, the last value stored in the return variable is automatically returned at the end of the function. Although a function does not strictly need to return the declared return variable, any explicit `return` statement works just fine, as long as its of a return type of a function.

### Arguments and Returns
Arguments and return types can be structs, pointers, references, etc.

## Memory Operations
Since FLARE-10K is a low-level language, direct memory access is very important, hence I tried making it easy to use.

### Dereferencing
Dereferencing is straightforward in FLARE-10K: place any `u32` value/variable inside square brackets to access that memory address. For example:

```c
[0xFFFFFFFF] = 512;
>_ The value at memory address 0xFFFFFFFF will be rewritten to 512
```

It can also take a variable:

```c
[var] = 1024;
```

Or a pointer:

```c
[ptr] = 2048;
```

### Referencing
References are retrieved using `&`, and pointers use `*`.

## Control Flow

### If
Conditionals are simple and use square brackets. Multi-condition checks using `&&` or `||` are not currently supported, though they can be resolved using nested `if` statements:

```c
if [true == true] {}
```

Supported relational operators are `<`, `>`, and `==`.

### For
The `for` statement is fully implemented (not just sugar) and uses syntax similar to C:

```c
for [int i = 0; i < limit; i = i + 1] {}
```

### While
Similar to C again:

```c
while [a < b] {}
```

## Inline Assembly
Inline assembly is very flexible in FLARE-10K and uses the following syntax:

```x86asm
inline [
    XOR rx0, rx0
    AND rx0, rx0
outline];
```

Any assembly code can be inserted, importantely, including labels, which is useful, for example for setting up interrupt tables: start a file with a vector table:

```x86asm
inline [
    #ORG 64
    ~MemFaultJmp
        JMP !MemFaultHandle
outline];
```

Then, elsewhere in the file, define the handler label:

```x86asm
inline [
    ~MemFaultHandle
outline];

func handle_memfault() {
    >_ Handle memfault
}
```

## That's it
Comments are ">_" btw, of course read the OS code to understand FLARE-10K better(not yet tho)
