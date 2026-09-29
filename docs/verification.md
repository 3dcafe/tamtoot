# Проверка v0.1 · 26 сентября 2026

Окружение: macOS 26.6.2; Flutter 3.44.0 stable / Dart 3.12.0; Xcode 26.5; Android SDK 36. Путь к Flutter SDK намеренно не фиксируется: для сборки достаточно добавить `<flutter-sdk>/bin` в `PATH`.

## Автоматические проверки

- `dart format lib test` — выполнено.
- `flutter analyze` — **No issues found**.
- `flutter test --timeout 30s` — **34 tests passed**.
- `flutter build apk --debug` — успешно, `build/app/outputs/flutter-apk/app-debug.apk`.
- `flutter build macos --debug` — успешно, `build/macos/Build/Products/Debug/tamtoot.app`.
- `flutter build web` — успешно, `build/web`.

Покрытие: document edits, UTF-16 offset↔line/column, CRLF normalization, batch undo/redo, read-only, overlap rejection, surrogate deletion, find/replace, command duplicate/enablement/unknown errors, configurable keybindings, package parsing/tokenization/installation/restore, schema rejection/default normalization, theme parsing, settings layers, layout round-trip and obsolete panel recovery, 100k-line viewport calculation, draft/session restoration, cancel save, concurrent edit while saving, dirty baseline after undo.

Widget tests: shell rendering; dark/light switch; TextInputClient input; undo; panel drag resize; размеры 600×700, 768×1024 и 1920×1080; keyboard shortcut dispatch; touch long-press selection.

## Проверка платформ

Web-интерфейс открыт в браузере и визуально проверен. Проверка нативного macOS-окна через UI automation недоступна из-за отсутствия разрешений Computer Use; успешная сборка не выдается за проверку всех нативных жестов и IME. Android APK собран, но не запускался на реальном планшете/эмуляторе. Android SAF export требует проверки на устройстве. Windows/Linux/iOS scaffolds созданы, нативные сборки на этих ОС/устройствах не проверены.

## Особенности локального окружения

Первый macOS build выявил повреждённый кэш SDK: symlink FlutterMacOS указывал на отсутствующий бинарник. Штатный `flutter precache --macos --force` восстановил артефакты; повторная сборка прошла. Версия SDK не менялась.

`flutter doctor` сообщает об отсутствующем Android cmdline-tools и неизвестном статусе лицензий; установленного Gradle/SDK оказалось достаточно для debug APK. Лицензии автоматически не принимались. При последующем обновлении toolchain их следует проверить средствами Android Studio.

Предупреждение Xcode о Run Script без outputs относится к стандартной Flutter Assemble build phase. Web build может сообщать о необязательном CupertinoIcons font из Material defaults; приложение использует Material Icons и JetBrains Mono.

## Explorer / theme update

The project tree now loads and expands child folders in place, including nested browser workspace paths. Explorer displays independent unsaved/modified/untracked/unpublished indicators and aggregates them onto folders. Publication status compares commit reachability against the locally known upstream; missing or unsupported history is reported explicitly. Theme selection is saved immediately as a user-level IDE preference.

The expanded test suite passes **57 tests**, including folder collapse/reopen, stale asynchronous directory loads, access failures, nested Web paths, immediate theme restoration, combined Git indicators, reverted unpublished commits, branches behind upstream, and actual Explorer widget interactions.

## Commit and push UI — 2026-09-27

- Added Git → Commit and push with explicit whole-file selection, author identity, commit message, HTTPS credentials and separate commit/push actions.
- Selected unsaved buffers are saved first; failed saves prevent the commit. Credentials are confined to the dialog lifetime.
- Verified selected snapshots, deletion, excluded metadata, stale/detached HEAD rejection, rejected/incomplete push reports, and multi-commit pack contents.
- Verified the dialog at desktop and 430px widths, including retry after a save failure.
- The interoperability test uses isolated temporary repositories and native `git receive-pack` only as a test server. Native Git accepted the index, commits and multi-commit pushes; `git fsck --strict` passed. Existing external staging was preserved and rejected for modification.
- Full suite: 64 tests passed, followed by all 7 commit/push tests including the newly added save-failure case (65 tests total). `flutter analyze`: no issues. No dependencies added.
- Git implementation limits and instructions are documented in the English README. No production repository was changed by the application tests.


## Startup project restoration — 2026-09-27

- Startup reopens the first recent project and restores user tabs. An unavailable folder leaves no active project; it does not fall back to an older one.
- Demo creation was removed from the application. Exact unchanged legacy examples are migrated away without deleting edited drafts or real files. Example contents now exist only in test fixtures.
- Added tests for first launch, recent-project restore, missing-folder fallback, legacy migration and closed-tab persistence. Full suite: 70 tests passed; analyzer clean.

## HTML / JavaScript and expanded syntax — 2026-09-27

- Bundled Dart, C#, HTML and JavaScript packages at 0.2.0; verified manifests, syntax and snippet assets load from the application bundle.
- Added lexical regions with continuation state, nested Dart comments, captured C# raw-string delimiters and nested HTML attribute-string rules. Existing pattern-only packages still load.
- Added per-editor syntax cache; tests cover viewport entry inside a multiline region, delimiter edits and language changes.
- Tested HTML quoted `>` / multiline attributes / plain text, JavaScript modules / BigInt / regex versus division / templates, Dart annotations / types / raw strings, and C# contextual keywords / attributes / directives / literal forms.
- Full suite: 81 tests passed. `flutter analyze`: no issues. New packages require no additional dependencies. Lexical limits are documented in README.

## Solution / Git sidebar and file changes — 2026-09-27

- Shortened the project tab to Solution and added an adjacent Git tab with the existing commit/push controls. Switching tabs preserves the form.
- Clicking a Git filename opens a HEAD comparison with unsaved editor content, line numbers and added/removed colors. Context menus in both tabs support comparison and confirmed discard; touch uses long-press.
- Restoration uses committed bytes, handles deleted and untracked files, reloads open editors and rejects stale reviews, changed HEAD, external staging and filesystem symlink paths.
- Added tests for modified/deleted/untracked/binary files, stale disk and editor snapshots, protected paths, bounded text diffs, cancel/confirm interactions and committing from the sidebar.
- `dart format lib test`: clean. `flutter analyze`: no issues. Full `flutter test` suite: **89 tests passed**. No dependencies added.

## Per-model prompt profiles — 2026-09-27

- Added Settings → Model profiles and prompts, with create/select/edit/delete, explicit saves, reset-to-default templates and local resolved-prompt preview.
- Versioned profiles live in `.tamtoot/agents/models/<id>.json`; shared instructions are saved separately in `.tamtoot/agents/instructions.md`.
- Tested template substitution without recursively interpreting source code, schema/path/parameter validation, native disk persistence, project isolation, stale-write rejection and symlink rejection.
- Widget test creates, previews and reopens a profile at 600px window width. Full suite: **93 tests passed**. Analyzer: no issues.
- No new dependencies. At this checkpoint the feature was configuration and preview only; model execution was added in the 2026-09-29 update below. Browser metadata listing supports explicit reads under `.tamtoot` while keeping metadata excluded from ordinary work-tree listings.

## Agent coding foundation — 2026-09-29

- Added model execution for Ollama Chat streaming, OpenAI Responses, compatible Chat Completions and Anthropic Messages. Ollama discovery covers `/api/tags` and `/api/show` context metadata.
- Added Tools → Agent with bounded file/command/MCP actions, per-action approval, YOLO clean-Git gate, timeout, mistake/iteration limits, emergency stop, JSON logs and a successful-test completion guard.
- Added `bin/ide_agent.dart` with `-y`, `--json`, piped input, profile/timeout/mistake options, Ctrl+C cancellation and meaningful exit codes.
- Added project hooks with cancel/context injection, 10-second timeout and lifecycle logging.
- Added Streamable HTTP/SSE and STDIO MCP configuration, discovery and tool calls, plus Settings UI.
- Added persistent Kanban columns, dependency validation and isolated desktop Git worktree creation.
- Targeted tests cover request shapes, response parsing, streaming, credential redaction, cancellation, Ollama discovery, approvals, YOLO clean-tree enforcement, command safety, premature-completion protection, hooks, HTTP/SSE/STDIO MCP, Kanban persistence and real temporary Git worktrees.
- `flutter analyze`: no issues. Full suite: **114 tests passed**. Debug Android APK, macOS app and web builds compile successfully.

## HTTP Requests — 2026-09-29

- Added a Requests sidebar and Tools command with project-scoped CRUD, nested folders, explicit save state, Markdown attachments, environments and individual/batch execution.
- Shared requests and `.tamtoot/environment.json` participate in the built-in Git status/commit flow; `.tamtoot/environment.local.json` and other private metadata remain excluded.
- Verified disk persistence in a temporary project, path containment, schema rejection, variable precedence, inherited bearer authorization, JSON/query/header resolution, sequential stop-on-error, parallel ordering, empty batches and Git visibility rules.
- `flutter analyze`: no issues. Full suite: **118 tests passed**. No dependencies added.
