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
- Targeted tests cover request shapes, response parsing, streaming, credential redaction, cancellation, Ollama discovery, approvals, YOLO execution with uncommitted changes, command safety, premature-completion protection, hooks, HTTP/SSE/STDIO MCP, Kanban persistence and real temporary Git worktrees.
- `flutter analyze`: no issues. Full suite: **114 tests passed**. Debug Android APK, macOS app and web builds compile successfully.

## HTTP Requests — 2026-09-29

- Added a Requests sidebar and Tools command with project-scoped CRUD, nested folders, explicit save state, Markdown attachments, environments and individual/batch execution.
- Shared requests and `.tamtoot/environment.json` participate in the built-in Git status/commit flow; `.tamtoot/environment.local.json` and other private metadata remain excluded.
- Verified disk persistence in a temporary project, path containment, schema rejection, variable precedence, inherited bearer authorization, JSON/query/header resolution, sequential stop-on-error, parallel ordering, empty batches and Git visibility rules.
- `flutter analyze`: no issues. Full suite: **123 tests passed**. No dependencies added.
- Additional regression coverage verifies the five-request concurrency ceiling,
  form encoding, authorization precedence, streamed response limits, malformed-file
  isolation, move conflict rollback and symlink containment.

## Git Pull / Sync — 2026-09-29

- Added **Pull changes** beside Push in the Git panel, using the existing Smart HTTP client and the same in-memory credentials.
- Pull accepts only a clean work tree, performs a fast-forward, updates the Git index, removes upstream deletions and reloads open project documents and Solution.
- Added regression tests for fast-forward content, additions, deletions, index and remote-tracking updates, dirty-tree rejection without network access, and the clean local-ahead case.
- `flutter analyze`: no issues. Full suite: **125 tests passed**. No dependencies added.

## Friendly local model setup — 2026-09-29

- Added guided presets for Ollama, LM Studio, LocalAI, OpenAI and Anthropic with automatic endpoints and API formats.
- Moved provider IDs, endpoint URLs, compatibility formats and raw JSON parameters into an optional Advanced section; new profile IDs are generated from display names.
- Added a connection and compatibility check that discovers Ollama or OpenAI-compatible models, verifies the selected model and recognizes authenticated APIs without storing credentials.
- Added mocked compatibility tests for Ollama and OpenAI-style model discovery. `flutter analyze`: no issues. Full suite: **126 tests passed**.

## Cached project completion — 2026-09-29

- Added dot-triggered method completion for Dart, C# and JavaScript, including signatures, declaring types and documentation extracted from adjacent line or block comments.
- The project index refreshes asynchronously, hashes files to parse only changes, includes unsaved editor contents and stores its private cache under `.tamtoot/cache/`.
- Added tests for C# and Dart parsing, documentation, type-based ordering, incremental refresh and unsaved source completion. Full suite: **129 tests passed**. No dependencies added.

## Focused Git panel — 2026-09-30

- Removed product branding from the top menu and reduced the Git sidebar to changed files, diffs and the commit message.
- Added compact Pull, Push, Sync and local history controls. Remote URL, author identity and in-memory HTTPS credentials now live behind the Git settings gear.
- Pull writes its progress and each added, modified or deleted file to Output. History and pull-detail regression tests bring the full suite to **133 passing tests**; the analyzer is clean.

## Editor input and local completion — 2026-09-30

- Kept the platform text-input connection attached while switching document tabs, so ordinary typing continues to work alongside hardware-key commands such as Enter.
- Completion now includes active-document variables and parameters plus project methods, fields, properties and constants. Value symbols insert without call parentheses; methods retain callable insertion and parameter placement.
- The private completion cache was versioned to `.tamtoot/cache/completions-v2.json`. No dependencies were added.
- Added regression coverage for IME input after a tab switch, Windows physical-character input while completion is open, and Dart local/member discovery. `flutter analyze`: no issues. Full suite: **136 tests passed**.

## Agent enhanced privacy — 2026-10-09

- A remembered Agent toggle omits the automatic project index, custom/project
  instructions, retained memory and seeded compiler-error excerpts.
- A private run reads one file excerpt at a time (40 source lines, approximately
  2000 characters). Searches disclose locations instead of matching source text.
- Run-local host aliases are applied at the common model-send boundary, including
  recovery requests, string parameter values and text attachments. Decoded tool
  actions restore aliases locally, preserving actual addresses in edits.
- Hooks/MCP are disabled, binary attachments are rejected before requests, and
  private runs leave project memory untouched. Requested text/code is still sent;
  this is limited host masking, not general secret detection or anonymization.
- Mocked HTTP tests verify minimal first requests, omitted unrelated Markdown,
  bounded batch reads, masked payloads and preserved real hosts after editing.
  Unit checks include Unicode/punycode hosts, URL credentials, idempotence,
  run-local aliases and attachment handling. A widget check covers the toggle.
- Full suite: **346 passed, 1 skipped**. Analyzer: **No issues found**.

## Git status cache and mutation notifications — 2026-10-09

- Git tab reopening and app resume reuse a shared workspace status cache; the
  unconditional 30-second polling timer is removed.
- Saved document changes and successful agent writes add paths to a pending set.
  A 600 ms debounce batches updates; a mutation revision forces a follow-up scan
  when another change happens during an active scan. Concurrent callers share
  the same refresh future.
- Unsaved editor changes update the cached Git list without scanning the disk.
  Manual Refresh is available in the embedded Git panel. Project opening and
  Git operations still refresh status; external edits require manual refresh.
- Regression checks cover clean tab reopening, forced refresh, idle periods,
  saved versus unsaved edits and mutations during a scan.
- Full suite: **340 passed, 1 skipped**. Analyzer: **No issues found**.

## Stable background Git refresh — 2026-09-30

- Periodic Git polling now publishes a session update only when status entries, unpublished paths or the status note actually change.
- The embedded Git panel filters unrelated session events and refreshes changed data in the background without inserting a progress bar or shifting its contents.
- Regression tests cover unchanged polls, real status changes, unrelated Output events and a pending background refresh. Full suite: **138 tests passed**; analyzer clean.

## Device files, request results and editor interaction — 2026-09-30

- Added Android system-document opening with persistent read/write access, so Save updates the selected document instead of exporting another copy.
- Output now timestamps entries, supports whole-log selection and has a Clear action. HTTP results record duration and open in a full Body/Headers viewer with formatted JSON.
- Request folders persist through commit-ready `.keep` files, and requests can be duplicated from their context menu.
- Double-click word selection, class/method folding and Tab completion are covered alongside storage, timing and unchanged Git-refresh regression tests. `flutter analyze`: no issues. Full suite: **141 tests passed**. No dependencies were added.

## RuStore delivery workflow — 2026-09-30

- Added a manual GitHub workflow that validates the source, builds a versioned signed AAB, retains it as an artifact, authorizes through the official RuStore JWE flow, creates a version draft and uploads the bundle.
- Moderation submission is an explicit workflow input. Manual and automatic-after-approval publication modes are supported; secrets and temporary tokens are never committed.
- YAML and every embedded Bash script were parsed locally. Application tests remain unchanged at **141 passing tests**.

## Custom model endpoints — 2026-10-01

- Custom compatible profiles accept a base URL, `/v1/models`, or a full Chat Completions request endpoint.
- Model discovery accepts both OpenAI `data` arrays and compatible `models` arrays and shows the normalized request URL.
- `https://domain/v1/chat/completions` was checked with the advertised GGUF model and returned `TAMTOOT_OK` without an API key.
- A headless Agent run using the saved `/v1/models` profile completed its structured action loop in one iteration with `TAMTOOT_AGENT_OK`.
- Headless mode now cancels its SIGINT subscription after completion so the process exits instead of remaining open.
- Automated coverage verifies URL normalization, discovery and the complete compatible request/response cycle.


## SSH profiles and keys — 2026-10-05

- Settings → SSH connections: global profile CRUD, bounded OpenSSH Ed25519 import,
  explicit native-secret persistence and a session-only fallback; no new dependencies.
- Secrets use own MethodChannel adapters: Apple Keychain, Android Keystore/AES-GCM,
  Windows Credential Manager. Linux explicitly uses session storage only.
- Added 14 domain/channel/widget tests covering malformed keys, secret isolation,
  persistence rollback, interrupted imports, deferred deletion, unavailable storage,
  profile CRUD and key import at phone width.
- Final full suite: **238 passed, 1 skipped**. Dart analyzer: no issues.
- Final macOS debug build and Android debug APK build: successful. Android build used
  Gradle offline mode after cancelling an earlier stalled online build.
- iOS Swift typecheck for arm64 simulator: successful; fixed the pre-existing preview
  factory codec optionality. Full iOS build was interrupted and remains unverified.
- Windows/Linux builds and real-device native secret CRUD were not verified.
- Scope and platform details: [SSH stage 1](ssh-stage-1.ru.md). SSH connections,
  cryptographic key validation, encrypted-key import and key generation are later work.

## Native SSH stage 2 — 2026-10-05

- Implemented TCP, bounded packet framing, Curve25519/Ed25519 server verification,
  AES-256-CTR with HMAC-SHA-256 EtM, strict KEX, sequence reset, rekey and cancellation.
  Uses own C++ primitives through standard Dart FFI and OS randomness; no dependencies added.
- Added explicit TOFU, SHA-256 fingerprints, normalized endpoint trust, multiple
  saved keys, changed-key decisions and trusted-key removal in SSH settings.
- Fixed rekey handling for in-flight application/control messages, initial-only
  strict KEX markers, reentrant completion, banner boundary and TCP cancellation races.
  Automatic rekey starts only after the upper authentication protocol reports success.
- Full suite: **256 passed, 1 skipped**. After the final authentication/rekey hook,
  all **18 SSH stage 2 tests** passed again. Analyzer: **No issues found**.
- Real isolated OpenSSH verified initial encryption, four client rekeys, preservation
  of an in-flight host-key announcement, 40 KiB on an open echo channel and
  server-initiated rekey. Negative cases: altered server signature, unsupported cipher,
  changed host key and cancellation with a late trust confirmation.
- Native published vectors, invalid packet/MAC cases, fragmented/coalesced TCP,
  cancellation races and trust dialogs at 430px passed.
- AddressSanitizer/UndefinedBehaviorSanitizer: 100 native random X25519 exchanges,
  AES partial blocks and SHA boundary lengths; no errors. Reproducible harness:
  `native/ssh/ssh_crypto_sanitizer_test.cpp`.
- macOS debug, Android debug APK and full iOS Simulator debug builds: successful.
  Android APK contains the own native module for arm64-v8a, armeabi-v7a and x86_64.
  SSH FFI exports were checked in the macOS/iOS app binaries.
- Windows/Linux builds and physical-device runtime checks remain unverified here.
  The own cryptographic implementation has not received an independent audit.
- Application sign-in, command execution, terminal and SFTP remain for subsequent
  stages. Test-only signing uses a public RFC fixture and is not production auth.
- Scope, algorithms, limits and reproduction: [SSH stage 2](ssh-stage-2.ru.md).

## Native SSH stage 3 — 2026-10-05

- Implemented password, Ed25519, RSA SHA-2 and keyboard-interactive authentication,
  including partial success, bounded attempts, server banners and verified PK_OK.
- Added OpenSSH private-key parsing/unlock for none or AES-256-CTR + bcrypt;
  own native Ed25519/RSA signing and bcrypt_pbkdf. No dependencies added.
  Expensive native operations run through standard Dart isolates; active signers
  defer disposal until their worker finishes.
- Implemented session/exec, separate stdout/stderr, exit status/signal, stdin flow
  control, EOF, channel cancellation, command timeouts and output limits.
  Added profile sign-in prompts and command UI; no automatic command replay.
- Full suite: **283 passed, 1 skipped**. Analyzer: **No issues found**.
- Real isolated OpenSSH: Ed25519/RSA plaintext/encrypted keys, RSA 3072/4096,
  lcm private exponent validation, second command, stdout/stderr/exit code 7,
  512 KiB stdin during rekey, incorrect key/passphrase, attempt/output limits
  and command timeout. Actual password/keyboard-interactive login is covered
  by protocol simulation, not by changing an operating-system account.
- UI trust → password → command and cancellation verified at 430px.
  Published Ed25519 and bcrypt vectors and disposal during signing passed.
- ASan/UBSan harness passed: stage 2 primitives plus native Ed25519 signing,
  invalid seed/public rejection and bcrypt_pbkdf vector. RSA sanitizer coverage
  is not claimed. Native source also compiled with C++11 and strict warnings.
- macOS debug, Android debug APK and iOS Simulator debug builds passed.
  Fixed C++11 aggregate initialization compatibility for the iOS compiler.
- Windows/Linux builds and physical-device runtime remain unverified.
  Own cryptography has not received an independent audit.
- Scope, limits and reproduction: [SSH stage 3](ssh-stage-3.ru.md).

## Native SSH stage 4 — 2026-10-08

- Added remote PTY (`pty-req` → `shell`) and bounded dimensions with debounced
  `window-change`. Uses the existing channel flow control and cancellation;
  interactive output streams without accumulating a lifetime transcript.
- Added an own Dart VT100/ANSI screen/parser and Flutter Canvas renderer: colors,
  cursor, margins/origin, insert/delete, scrollback, alternate screen and line
  drawing. Unicode 17 data tables cover wide/combining characters; tests cover
  fragmented UTF-8, Hangul, flags, emoji modifiers, ZWJ and VS16.
- Added desktop/mobile input, application cursor/keypad modes, selection/copy,
  bounded sanitized bracketed paste, keyboard toggle and accessible history.
  Remote OSC/DCS commands, including clipboard commands, are ignored.
- Android/iOS explicitly close SSH when the app becomes paused; returning from
  background displays a disconnect warning and never reopens or replays shell.
- Full suite: **320 passed, 1 skipped**. Final application-keypad change also
  passed all **3 terminal widget tests**. Analyzer: **No issues found**.
- Real isolated OpenSSH passed PTY TERM, stty dimensions before/after resize,
  Unicode input, Ctrl-C and exit; full-screen vi saved a temporary file after
  resize, and interactive macOS top accepted refresh, resize and quit.
- Protocol tests passed PTY/shell refusal, cancelled opening, transport loss,
  resizing and more than 2 MiB of streamed interactive output. Parser tests
  passed bounded adversarial CSI/OSC/UTF-8 and random input/resize sequences.
  Widget tests passed at 430px, with clipboard, control keys and lifecycle.
- macOS debug, Android offline debug APK and iOS Simulator debug builds passed.
  Windows/Linux builds and physical-device input/lifecycle remain unverified.
- No pubspec dependencies added. Own cryptography remains unaudited; full xterm
  emulation, full Unicode grapheme segmentation and transcript reflow are not
  claimed. Exact scope: [SSH stage 4](ssh-stage-4.ru.md).

## SSH/SFTP основной сценарий — 2026-10-08

- Completed SFTP v3 over the own SSH subsystem stream: negotiated extensions,
  bounded framing/IDs, directory listing, attributes, realpath/readlink, binary
  transfer/progress/cancel, mkdir, non-overwriting rename and confirmed deletion.
- Added remote text editing with full-content/metadata conflict checks, explicit
  reload/discard, exclusive temporary uploads, fsync when advertised, retained
  recovery copies, and safe failure when a competing destination appears.
  Existing-file replacement is deliberately not advertised as atomic or CAS.
- Native Android SAF and iOS UIDocumentPicker bridges support binary import/export
  up to 32 MiB with bounded stream reads. Desktop reuses the project's existing
  native file-selector adapter; no pubspec dependencies added.
- Full suite: **334 passed, 1 skipped**. Analyzer: **No issues found**.
- Real isolated OpenSSH verified a 170000-byte binary Unicode file through rekey,
  listing/stat/realpath, save/recovery, conflict, symlinks, rename/removal, cancellation
  and exec while the SFTP channel remains open. Existing native login/PTY/vi/top
  checks also passed in the full suite.
- Protocol tests: byte fragmentation, reversed response order, eight pending IDs,
  wrong version/size/ID, same-size/same-mtime content conflict, rename race,
  retention of a competing destination and original recovery copy, cancellation
  of a stalled source and inert late cancellation after success.
- Widget tests: 430px binary upload/export, deletion confirmation, remote editor,
  conflict rejection, confirmed reload and retained recovery copy. Test event-loop
  turns are allowed via runAsync for async stream completion.
- Final macOS debug, Android offline debug APK and iOS Simulator debug builds passed.
  Native picker/provider interaction on physical devices and Windows/Linux builds
  remain unverified; own cryptography still requires an independent audit.
- Stages 1–5 implement the primary client flow. Stage 6 features remain optional
  extensions. Scope, recovery procedure and limits: [SSH stage 5](ssh-stage-5.ru.md).
