# FLARE-10K documentation
I will quickly run through all the features of my language.

## Overview
FLARE-10K is a compiled low-lever system programming language, currently compiling into assembler for the ISA for my CPU. Though IR is pretty general, and theoretically backend for other architectures can be implemented.

## Variables
FLARE-10K currently provides 7 primitive types:

u32, u16, u8
i32, i16, i8
bool

### Declarations
Variables are declared as follows:

```
```
<type> <name> = <value> ;
```
```


>_ for example:

u32 example = 512;

>_ Variables can also be declared but unitilized:

i16 uninit;

>_Unitilized value is NULL which is just 0.
```
```

### Pinning
Variables can be specifically pinned to a particular register, using **#r(x/y/z)NS** notation where N is 0-31 and S is sub-specifier it must be in the register of the exact size as variable. For example:
```
```
#rx1 i32 variable = -1024;
```
```
No matter what allocator does that variable will be stored in rx1, it is made for easier inline interactions and to pin important variables to the registers. 

### Arrays 
There are Arrays in FLARE-10K, nothing special about them, declared as follows, 
```
```
u32 arr[4] = {0, 1, 2, 3};

>_ It can also be left undeclared such as

u32 arr[4] = {};
```
```

### Global definitions
Global variables are declared as follows:
```
```
#def u32 EXAMPLE = 12;

>_ They can be pinned as well

#def #rx0 PINNED = 12;
```
```
```
```

### Casting 
Casting work similar to rust:
<variable> as <type>
For example 
example as i16
Lower bits will be used when shrinking, zero extended when cast to unsiged, sign extended when casting to signed

## Operations 
FLARE-10K has every operation you expect from a language from bitwises to arithmetic, however it currently lacks division and modulo division, because I haven't it implemented in my CPU. 

## Data structures
Struct is declared using keyword "arch" and works just as any other struct
```
```
arch Example {
    u8 a;
    u8 b;
    bool is_true;
}
>_ It can be accessed using standard anotation: 
Example.a = 8;
```
```

### Regarch
Similar to pinning variables structs can also be pinned to the register, they must be 4 bytes though. It is declared using keyword "regarch", example as follows
```
```
regarch RGBA {
    u8 r;
    u8 g;
    u8 b;
    u8 a;
}
```
```
It is made for having fast access to a important structs. It can also be pinned to specific register 
```
#rx1 RGBA;
```
```
```

## Functions
Functions are declared such:
```
```
func <name> (<args>) => <return type> <return variable> {}
>_ For example: 
func example (i8: a, i8: b) => bool is_equal{}
```

```
Functions can obviously be void, in that case omit "=> (everything after)" {}

### Return variable
You might have noticed return variable, it is an optional function variable that is declared directly in function signature.
It is declared with value NULL and can be pinned. It is used just like a regular variable in a function. If function doesn't have explicit return, but has a return variable, last value of return variable will automatically get returned. Although function doesn't necessary needs to return return variable, it might still explicitly return anything of return type.

### Arguments and returns
Arguments and returns can be Structs, pointers, references etc

## Memory operations
Since FLARE-10K is a low-level language memory access is important.

### Dereferencing
Dereferencing is very easy in FLARE-10K you just put any u32 value/variable in square brackets and memory location in that address will be accessed, for example. 
```
```
[0xFFFFFFFF] = 512;
>_The value in memory location 0xFFFFFFF will be rewritten to 512;
>_It can also be a variable
[var] = 1024;
>_Or a pointer
[ptr] = 2048;
```
```

### Referencing
Reference is, as usual, retrieved using "&", same with pointer "*"

## Control flow 

### If
Rather simple, no multi-check such as && or || though can be resolved using nested ifs(might need to add it later)
Used as follows:
```
```
if [true == true] {}
```
```
Supports <, >, ==

### For
For statement is properly implemented, so its not just a sugar, and used similar to C:
```
```
for [int i = 0; i < limit; i = i + 1] {}
```
```

### While
Similar to C again:
```
```
while [a < b] {}
```
```
```
```

## Inline assembly
Inline assembly is very flexible in FLARE-10K, it is used as 
```
```
inline [
    XOR rx0, rx0
    AND rx0, rx0
outline];
```
```

There can be any assembly code, importantly including labels, which is useful for, for example interrupt tables
start file with table
```
```
inline [
    #ORG 64
    ~MemFaultJmp
        JMP !MemFaultHandle
outline];

```

>_ Then somewhere in the file just do
inline [
    ~MemFaultHandle
outline];

func handle_memfault() {
    >_ Handle memfault
}
```
```

## That's it!

