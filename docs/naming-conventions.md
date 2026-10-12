# Project naming conventions · 0.1.6

Open a project, then choose **Settings → Project naming**. Select a language and configure types/classes, functions/methods, variables/fields, properties and constants independently. Available styles: camelCase, PascalCase, snake_case, UPPER_SNAKE_CASE, two combined styles and No check. The switch disables all naming advice for this project; Reset this language to defaults removes that language's overrides.

Profiles are stored in the app's local settings under `projectNaming`, keyed by project root URI. They survive reopening and do not affect other projects or create repository files. Standalone documents are not checked until a project is open.

| Language | Types | Functions/methods | Variables/fields | Properties | Constants |
| --- | --- | --- | --- | --- | --- |
| Dart / Flutter | PascalCase | camelCase | camelCase | camelCase | camelCase |
| C# | PascalCase | PascalCase | camelCase | PascalCase | PascalCase |
| Python | PascalCase | snake_case | snake_case | snake_case | UPPER_SNAKE_CASE |
| Java | PascalCase | camelCase | camelCase | camelCase | UPPER_SNAKE_CASE |
| Kotlin | PascalCase | camelCase | camelCase | camelCase | UPPER_SNAKE_CASE |
| PHP | PascalCase | camelCase | camelCase | camelCase | UPPER_SNAKE_CASE |
| JavaScript / TypeScript | PascalCase | camelCase or PascalCase | camelCase | camelCase | camelCase or UPPER_SNAKE_CASE |

These are practical presets, not mandatory compiler rules. Dart presets follow [Effective Dart](https://dart.dev/effective-dart/style), C# presets follow [Microsoft naming conventions](https://learn.microsoft.com/en-us/dotnet/csharp/fundamentals/coding-style/identifier-names), Python presets follow [PEP 8](https://peps.python.org/pep-0008/), and Kotlin presets follow its [coding conventions](https://kotlinlang.org/docs/coding-conventions.html). Java uses the [JLS naming conventions](https://docs.oracle.com/en/java/javase/26/docs/specs/jls/jls-6.html). PHP class/method/constant presets follow [PSR-1](https://www.php-fig.org/psr/psr-1/); variable/property styles are editor defaults, which PSR-1 does not prescribe. JavaScript/TypeScript allow both ordinary camelCase functions and PascalCase component functions, and distinguish naming styles without attempting to prove whether a `const` value is semantically constant; see the [JavaScript style guide](https://google.github.io/styleguide/jsguide.html).

Nonconforming recognized declarations get a green underline. Compiler/error decorations retain their error color. Place the caret in an underlined name and open its context menu to see the expected style. Nothing is renamed automatically.

Checks are lexical and advisory. They cover supported declaration forms rather than all parameters, destructuring, multiline declarations or semantic property/constant distinctions. Comments, strings, explicit overrides, Python magic names and non-ASCII names are excluded. Private prefixes such as `_`, `$`, C# `@` and private static `s_`/`t_` are allowed. Java checks static-final fields as constants; Kotlin checks `const val`; Python recognizes uppercase assignments as constants. C# public/protected fields use the property preset. Other languages and markup are not checked.

Analysis is debounced by 180 ms and reuses unchanged tokenization/declaration states. Cursor motion and scrolling do not reparse the file. Theme-aware green advice is drawn independently of compiler diagnostics, with a binary search for visible-line decorations. No additional libraries or SDK processes are required.
