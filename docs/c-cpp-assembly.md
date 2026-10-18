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
