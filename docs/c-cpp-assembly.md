# Editing C, C++ and assembly in Tamtoot

The bundled language packages provide syntax coloring, comment toggling, bracket
and quote pairing, and starter file templates. C and C++ also include code
templates such as `main`, `for`, `if`, `struct`, and C++ `class`/`template`.

## File recognition

- C: `.c` and preprocessed `.i` files.
- C++: `.cpp`, `.cc`, `.cxx`, `.c++`, `.hpp`, `.hh`, `.hxx`, `.h++`, `.ipp`, `.tpp`
  and `.inl`, plus uppercase `.C` and preprocessed `.ii` / `.I`. Lowercase `.c`
  and `.i` select C. Ambiguous `.h` files use C++ coloring, which includes the C keywords
  and types provided by these packages.
- Intel/NASM/MASM-style assembly: `.asm` and `.inc`.
- GNU/AT&T x86 assembly: `.s` and `.S`.
- ARM: `.arm`, `.armasm`, or a compound name such as `startup.arm.s`.
- AArch64: `.aarch64`, `.arm64`, `startup.aarch64.s`, or `startup.arm64.s`.
  Compound assembly filenames also accept uppercase `.S`.

Choose the filename for the intended dialect. A generic `.s` file defaults to
GNU x86/AT&T; CPU architecture is not inferred from a build system or file contents.
Windows, macOS and Linux paths use the same language selection rules.

## What is highlighted

C/C++ coloring covers preprocessing, types, keywords, function-like names,
strings, character literals, numbers and block comments. C++ raw strings track
their custom closing delimiter across lines. Templates and modern language
keywords are colored lexically; this is not compiler-backed type resolution.

Assembly coloring recognizes labels, directives, instruction positions,
registers, numbers and strings. x86 registers include general-purpose, x87,
SIMD/vector, mask and tile register names; ARM and AArch64 packages provide
architecture-specific register names. Command-position coloring handles
mnemonics and macro invocations without relying on an exhaustive instruction
list. A colored mnemonic is not confirmation that an instruction exists or is
available on the selected CPU.

Dialects remain separate because punctuation has different meanings. For example,
ARM uses `#` for immediate values and GNU x86 uses it for comments; AArch64 uses
`//` comments and semicolons can separate statements. See the
[GNU ARM syntax notes](https://sourceware.org/binutils/docs/as/ARM_002dChars.html),
[GNU AArch64 syntax notes](https://sourceware.org/binutils/docs/as/AArch64_002dChars.html)
and [Intel architecture manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

## Scope and limitations

The packages do not include a C/C++ compiler, assembler, linker, debugger,
disassembler, instruction encoder, macro expander, or instruction/operand
validation. Project semantic completion, C/C++ build detection and automatic
architecture detection are not added. Preprocessor conditionals are not
evaluated; inactive branches are still colored. Dialect-specific constructs
outside the lexical rules may be colored imperfectly.

The assembly starter templates are Linux exit examples for the indicated
architecture and assembler syntax. They are not portable Windows/macOS programs
and are not executed by creating or opening a file.

## Bare-metal editing tools

GNU linker scripts (`.ld`, `.lds`) now have their own language package: section
names, layout commands, sizes, strings and multiline comments, plus an ELF32
x86 layout template and `keep` / `memory` snippets. Linker command semantics
follow the [GNU ld manual](https://sourceware.org/binutils/docs/ld/Scripts.html).

NASM supports macro parameters (`%1`, `%{1}`), invocation-local labels (`%%name`),
context-local references and location counters (`$`, `$$`). Snippets include
`nasm-macro`, `nasm-guard`, `nasm-section`, `nasm-struct`, and `nasm-align`.
See the [NASM macro documentation](https://www.nasm.us/doc/nasm05.html).

The **x86 BIOS boot sector** file template initializes segments and stack, prints
T, and halts. Assemble with `nasm -f bin boot.asm -o boot.bin`; test the binary
in an emulator. It is a standalone legacy BIOS demonstration, not a UEFI loader
and does not load the C++ template.

C++ adds GNU compiler extension coloring, digit separators and user-defined
numeric literals. Snippets `extern-c`, `packed`, `mmio`, `inb`, and `outb` help
with hardware interfaces. Port I/O and the kernel entry template target x86
GCC/Clang in privileged mode. The packed descriptor example is a 32-bit layout.
The kernel entry needs startup assembly to establish its execution mode and
stack and clear `.bss`. It deliberately uses no static constructors or runtime.

For a real kernel use a target cross compiler, assembler and linker externally
(e.g. i686-elf GCC and GNU ld for ELF32). Typical C++ options are
`-ffreestanding -fno-exceptions -fno-rtti -fno-stack-protector -fno-pie`;
link with your startup object and `-T kernel.ld -nostdlib -no-pie`.
Compiler runtime helpers may still require target `libgcc` and your own memory
functions. Adapt the layout to your boot protocol; the linker template contains
no Multiboot header. Compilation, bootability and hardware behavior are not
validated by syntax coloring. No bundled toolchain or automatic OS build is added.

## ARM bare-metal workflow

Create assembly files with `.arm.s` (32-bit ARM/Thumb) or `.aarch64.s` / `.arm64.s`
so the editor selects the intended architecture. Generic `.s` still defaults to x86.

- **Cortex-M3 startup** pairs with the **Cortex-M3 FLASH/RAM layout** linker
  template. It provides the initial stack and 16 core vector entries, copies
  `.data` from FLASH to RAM, clears `.bss`, then calls `kernel_main` with
  interrupts masked. Extend the vector table with your device IRQs and adapt
  FLASH/RAM addresses and sizes. It does not configure clocks, FPU or a C++ runtime.
- **AArch64 single-core startup** pairs with the **AArch64 RAM image layout**.
  Firmware must load the image into writable RAM at the selected addresses, enter
  AArch64 with the MMU off and provide a usable current-EL stack bank. Startup
  masks interrupts, establishes a 16-byte-aligned stack, clears `.bss`, and calls
  `kernel_main`. It does not change exception level, install vectors, configure
  caches/MMU, park secondary cores, or implement a board boot protocol.
- **Freestanding ARM/AArch64 C++ kernel entry** uses `wfi` instead of x86 `hlt`.
  It assumes the corresponding startup ran and has no runtime initialization.

Snippets in ARM: `arm-function` (Thumb), `arm-barrier` (ARMv7), `arm-primask`
(Cortex-M only), `arm-mmio`. In AArch64: `a64-function`, `a64-barrier`,
`a64-currentel`, `a64-vbar` (EL1 vector base; requires a real 2-KiB-aligned vector
 table), `a64-mmio`. C++ includes an `arm-barrier` GCC/Clang snippet. MMIO addresses
are examples to replace; `volatile` accesses alone do not establish device memory
attributes or replace the required ordering barriers.

The syntax packages color Cortex-M special registers and AArch64 system-register
spellings. This is lexical recognition, not validation of register availability
or access permissions. See Arm's [Cortex-M startup explanation](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/writing-your-own-startup-code-for-cortex-m)
and [AArch64 stack guidance](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/using-the-stack-in-aarch32-and-aarch64).

Use an external `arm-none-eabi` or `aarch64-none-elf` toolchain. For example,
compile Cortex-M3 assembly with `clang --target=arm-none-eabi -mcpu=cortex-m3 -c startup.arm.s`,
or AArch64 with `clang --target=aarch64-none-elf -c startup.aarch64.s`.
Compile C++ with the matching target plus `-ffreestanding -fno-exceptions -fno-rtti`
and link with the matching script and entry. Runtime helpers and memory functions
may need implementations. Assembly and C++ templates were compiled for their
respective targets; linker layouts and boot behavior require board-specific
validation. No QEMU, flashing utility, cross compiler or debugger is bundled.
