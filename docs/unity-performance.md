# Unity syntax regression tests and local benchmark

Measured 19 October 2026 on the local macOS development host using Flutter's
VM test runner (JIT), not a release build. Each input repeats a representative
source line 5,000 times; these are synthetic editor-core workloads, not real
Unity project build times or screen frame times. The benchmark warms tokenization
with 200 lines and reports the median of five trials.

| Language | First parse, 5,000 lines | Cached viewport, 100 × 60 lines | 100 last-line invalidations |
| --- | ---: | ---: | ---: |
| C# | 459.7 ms | 0.109 ms | 8.93 ms |
| ShaderLab/HLSL | 618.4 ms | 0.057 ms | 12.13 ms |
| Unity YAML | 158.1 ms | 0.057 ms | 3.07 ms |
| JSON | 107.5 ms | 0.056 ms | 2.16 ms |
| C++ | 588.7 ms | 0.064 ms | 11.64 ms |
| AArch64 | 538.6 ms | 0.058 ms | 10.81 ms |

The last-line scenario advances the revision and invalidates the same line on
each iteration, keeping its text constant to isolate cache/tokenization cost.
The cached viewport measures token retrieval only: no layout, painting, disk I/O,
Unity Editor or GPU execution. Host load, JIT compilation and source composition
change timings; there is no before/after speedup claim or fixed CI timing limit.

The initial scan into a distant line remains synchronous and scans its prefix.
This can delay first navigation in large files; it is not eliminated by the warm
cache. Early-file edits also invalidate and rescan the following suffix when
requested. The measurements do not imply every edit touches only one line.

Deterministic regression tests cover C#, shaders, YAML, JSON, C++, ARM, AArch64
and linker scripts. They compare cached output with full tokenization after
region changes, restored contents, inserted/deleted lines and empty documents.
They also assert zero buffer reads for an unchanged cached line and exactly one
read for a last-line edit in a 10,000-line file. Shader tests include incomplete
strings, multiline comment recovery and a 20,000-character near-match.

Run correctness checks:

```sh
flutter test --no-pub test/unity_syntax_regression_test.dart test/unity_language_test.dart test/editor_performance_test.dart
```

Run the optional benchmark separately:

```sh
flutter test --no-pub test/unity_syntax_benchmark_test.dart --reporter expanded
```

Exclude diagnostic benchmarks from a regular suite with
`flutter test --no-pub --exclude-tags benchmark`.
