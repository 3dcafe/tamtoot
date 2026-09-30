# Tamtoot

Tamtoot is a **free code and plain-text editor** and an extensible Flutter IDE for tablets and desktop windows. It includes an original editor engine, resizable tool panels, language packages, Git integration, and light and dark themes. Markdown (`.md`) files can be edited as plain text; a rendered Markdown preview is not implemented yet.

## Features

- A custom Canvas-based editor with syntax highlighting, selection, undo/redo, search and replace, keyboard shortcuts, mouse selection, and touch input.
- Multiple document tabs and recovery of unsaved documents between sessions.
- A project tree that expands directories **in place**. Opening a child folder keeps the project root and sibling folders visible. Directory contents load on demand.
- Subtle Explorer indicators, also aggregated onto parent folders:
  - `●` — unsaved editor changes;
  - `M` — changes relative to Git HEAD;
  - `?` — a new, untracked file;
  - `↑` — changes in commits not reachable from the locally known upstream.
- Git clone/fetch/pull/push and local repository operations through the existing pure-Dart Smart HTTP client.
- Versioned Dart, C#, HTML and JavaScript language packages and an interface for installing declarative language definitions.
- Midnight Ink and Porcelain themes. The active theme is saved immediately as an **IDE-wide preference**, including when selected in **Tools → Settings**.
- A command registry, editable keybindings, font settings, and tab preferences.

Git indicators refresh on project open, after saving, when the app resumes, every 30 seconds while a project is open, and through the Explorer refresh button. They never fetch or push automatically. The upstream information reflects the last clone/fetch/push: if there is no upstream or the current Git provider cannot read its history, Explorer shows a status note instead of guessing.

## Run locally

The project is tested with **Flutter 3.44.0 / Dart 3.12.0**. Add your Flutter SDK's `bin` directory to `PATH`, then run:

```sh
flutter pub get
flutter run -d macos
# Or use Chrome / a connected Android device:
flutter run -d chrome
flutter devices
flutter run -d <device-id>
```

The project was verified with Flutter 3.44.0. The SDK may be installed anywhere;
add its `bin` directory to `PATH` instead of relying on a machine-specific path.

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release
flutter build macos --debug
flutter build web
```

## Android CI artifacts on GitVerse

[Build Android APK](.gitverse/workflows/build-apk.yml) runs automatically on pushes to `master`, on `v*` tags, and manually through **CI/CD → Build Android APK → Run workflow**.

The workflow installs Java, Android SDK and the pinned Flutter SDK, runs formatting checks, static analysis and tests, builds a release-mode APK, and uploads it as a downloadable artifact. Open a completed run and download **tamtoot-apk** from its artifacts section. Artifacts are retained for **14 days**. CI/CD must be enabled in the repository settings.

The workflow **does not publish to app stores or create store releases**. The current Android release configuration uses a debug signing key, so these are test/preview artifacts. Before distributing through stores, configure a persistent release signing key and the store-specific versioning/package requirements; ephemeral CI debug keys are not suitable for maintaining installed release updates. No signing credentials are committed to this repository.

The existing Windows workflows remain available separately.

## Everyday use

- **File**: new/open/save/save as/save all, open project, clone repository.
- **Edit**: undo/redo, clipboard, find and replace.
- **View**: show/hide panels, switch theme, reset layout, command palette.
- **Tools → Settings**: theme, font, size, tabs, and keybindings.
- **Tools → Install language package**: install versioned `language.json`, `syntax.json`, and optional `snippets.json` without rebuilding the IDE. The bundled languages and their extensions are documented below instead of being enumerated in the application UI.

Drag panel dividers to resize. Click folders to expand or collapse them, and files to open them. Tap in the editor to position the cursor; long-press and drag to select text. Ordinary touch dragging scrolls the document.

Common shortcuts: `Ctrl/⌘+S` saves, `Ctrl/⌘+Z` undoes, `Ctrl/⌘+Shift+Z` redoes, `Ctrl/⌘+F` finds, and `Ctrl/⌘+Shift+P` opens commands.

Programming ligatures are disabled in the editor and Git diff. Operators such
as `!=`, `==`, `=>`, `>=` and `<=` are always displayed as the characters stored
in the file instead of being merged into typographic symbols by the code font.

On startup, Tamtoot reopens the most recent project in history. If there is no project or its folder is unavailable, the project tree stays empty; no demo tabs are created. Existing user drafts are still recovered. Unmodified demo tabs from older installations are removed automatically, while edited drafts and real files are preserved.

Solution shows only the current project tree. Open documents remain in the central editor tabs, and recent folders are available through **File → Open project…** instead of occupying the project tree. Hover the folder icon above the tree to see the repository name, branch and location.

The application saves session data after a 450 ms idle period and when it moves into the background. Theme changes are persisted immediately. Session recovery is separate from saving the actual file. Force-quitting during a pending write may lose the latest unsaved changes.

## Language highlighting

Use **Edit → Find in project** or **Ctrl+Shift+F** (**⌘Shift+F** on macOS) to search the open project. Results show file paths, line numbers and text previews; tap a result to open and select the occurrence. Search supports case matching and uses unsaved contents of open files. It skips dependency/build folders and `.tamtoot`, ignores binary or oversized text (over two million characters), and caps results at 500. Unreadable entries are counted as skipped. Search starts after a short typing delay and cancels when the query changes or the dialog closes. No additional dependencies are required.

Bundled language packages are versioned independently (currently 0.2.0). File extensions are matched without case sensitivity:

| Language | Extensions | Highlighting |
| --- | --- | --- |
| HTML | `.html`, `.htm` | Tags, attributes, quoted values, entities, doctype, multiline comments and CDATA |
| JavaScript | `.js`, `.mjs`, `.cjs` | Module/async keywords, built-ins, calls, operators, numeric literals including BigInt, strings, multiline templates and comments |
| Dart | `.dart` | Expanded keywords and built-in types, annotations, calls, hexadecimal/exponent numbers, raw/triple-quoted strings and nested block comments |
| C# | `.cs` | Contextual keywords, attributes, directives, escaped identifiers, numeric suffixes, verbatim/interpolated/raw strings and block comments |

Multiline states remain correct when scrolling into the middle of a document. Editing a preceding delimiter invalidates the cached suffix. Existing single-line regex language packages remain supported.

This is syntax coloring, not semantic analysis. Interpolated expressions inside strings/templates use the string color; JavaScript regular-expression detection is heuristic. Embedded JavaScript/CSS in HTML, JSX/TypeScript, live preview and code execution are not implemented by these packages. Snippet definitions are supplied as package data; an interactive snippet insertion UI remains future work.

For Dart, C# and JavaScript files, typing an identifier or `.` after a variable opens lightweight project-aware suggestions. The list includes local variables, parameters, methods, fields, properties and constants. Each item shows its signature or type and the nearest preceding line or block comment, so API documentation remains visible while writing code. Tamtoot prioritizes members whose declaring type matches a local variable declaration or constructor expression. This index is lexical rather than a full compiler or LSP, so scope and type inference are intentionally limited.

The project index runs asynchronously and reparses only files whose SHA-1 content hash changed. Its local cache is stored in `.tamtoot/cache/completions-v2.json` and ignored by Git. Tamtoot checks for changes at most once every ten seconds when completion is requested, while the current unsaved document is indexed directly in memory without content hashing. Dependency and generated directories (`node_modules`, `build`, `.dart_tool`, `.git`, `obj`) are excluded from indexing. File enumeration still traverses the project, and eligible source files are read during a refresh to compare hashes; this is not a filesystem watcher.

## Commit and push from the IDE

Open a cloned project and select the **Git** tab beside **Solution** in the sidebar. The same controls are available through **Git → Commit and push…** and the command palette.

1. Use the checkboxes to select the files to include, including additions or deletions. Selected unsaved editor changes are saved before committing. Files not selected remain outside the commit.
2. Enter a commit message and click **Commit**. The main panel stays focused on changed files and their diffs.
3. Open the gear menu to configure the remote URL, author name, author email, HTTPS username and access token. The identity and remote are stored in the repository Git configuration. Credentials stay in memory while this Git view is open and are never written to settings or repository files.
4. Use the compact Pull, Push and Sync buttons at the top. The history button shows the latest local commits with their authors, dates and hashes.

Use **Pull** to fetch the current branch from `origin` and fast-forward the local project. Pull requires a clean working tree and no unsaved project editors, so it cannot overwrite local work. It refreshes open files and Solution after checkout, removes files deleted upstream and preserves a clean local branch that is already ahead. Start, completion, failure and every added, modified or deleted file are written to Output. Divergent histories are reported for manual resolution because the embedded client does not create merge commits.

The Git panel provides separate directional actions: **Pull changes** uses a download icon, **Push commits** uses an upload icon, and **Sync** uses a bidirectional icon. Sync performs the same safe pull first and pushes local commits only after pull succeeds.

Commit and push are separate operations: a failed push leaves the local commit available for retry. The Git view shows progress and errors; Explorer indicators refresh after successful operations. Push verifies the remote's unpack/ref status, refuses non-fast-forward updates and sets the current branch's upstream after success. No new dependencies or system Git executable are required by the application.

File selection is whole-file staging for one commit, not a persistent staging UI. The client maintains a standard Git v2 index and refuses to overwrite existing staging from another client. Advanced indexes, merge conflicts, detached HEAD commits, symlink/submodule edits, hooks, signing and packed object databases are not supported. Private `.tamtoot` metadata is excluded; shared HTTP requests and their project environment are visible to Git. Full `.gitignore` semantics are still not implemented: review new files explicitly before selecting them. Web push additionally depends on the remote host allowing browser requests (CORS).

## Compare and discard changes

Click a filename in the Git changes list to compare **HEAD → current content**, including unsaved editor changes. Added and removed lines have separate colors and line numbers. Right-click a file in Solution or Git (long-press on touch devices) for **Compare with HEAD** and **Discard changes…**.

Discard requires confirmation. It restores a tracked file to its last committed contents, including deleted files, and reloads its open editor. For an untracked file, the confirmation explicitly offers deletion. Cancel preserves everything. A stale review, changed HEAD or existing external staging prevents restoration.

Text comparison supports UTF-8 files up to a combined 2 MiB preview limit. Binary files show an explanatory message; large changed text spans use a bounded replacement view. Line endings are normalized only for display; restoration uses the original committed bytes.

## HTTP Requests

Open **Requests** beside Solution and Git, or choose **Tools → HTTP Requests…**. Requests can be organized in nested folders, edited, renamed, moved, deleted and run individually or as a selected batch. Batch execution can run sequentially or in parallel with a maximum of five concurrent requests, with an optional stop-on-error mode. Each result shows status, duration and a response preview.

Requests support GET, POST, PUT, PATCH, DELETE, HEAD and OPTIONS; query parameters and headers can be enabled independently. Bodies support JSON, text and URL-encoded forms. Project authorization can be inherited, disabled or overridden with a bearer token. `{{variable}}` placeholders are resolved in URLs, query parameters, headers, bodies and tokens. Runtime values override local secrets, which override shared project variables.

Project request files live under `.tamtoot/requests/**` and shared variables live in `.tamtoot/environment.json`. These files appear in Tamtoot's Git view so a team can commit and exchange them with the rest of the project. Secrets belong in `.tamtoot/environment.local.json`; this file is excluded from Tamtoot Git operations and from the repository `.gitignore`. If a literal project or request bearer token is entered, Tamtoot moves it into the local environment and stores only a `{{variable}}` reference in the shared file.

Request documentation is ordinary Markdown beside its request. Use **New Documentation** to create it or **Attach Markdown** to link an existing neighboring `.md` file. Request and environment files use version 1 JSON and reject unsupported versions or paths outside their project folders.

## Model profiles and prompts

Open a project, then go to **Tools → Settings → Model profiles and prompts**.
Create a profile with a display name and model name. Each profile has an editable
system prompt, user prompt template and optional JSON object of
API parameters. **Reset prompts** restores the built-in templates; **Save profile**
persists edits. Profiles can be selected, edited and deleted independently.

For a new profile, choose **Ollama**, **LM Studio**, **LocalAI**, **OpenAI** or
**Anthropic** from **Model server**. Tamtoot fills in the provider, API format and
standard endpoint automatically; the profile ID is generated from its display
name. URLs and provider details remain available under **Advanced connection
settings** for custom servers. **Check connection** verifies that the API is
reachable and compatible, loads its model list when supported, and confirms
whether the selected model is available. This check does not send a prompt.

- Profiles: `.tamtoot/agents/models/<profile-id>.json` (schema version 1).
- Shared instructions: `.tamtoot/agents/instructions.md`, saved separately and
  appended to every profile's system prompt.
- Template variables: `{{task}}`, `{{file_path}}`, `{{file}}`, `{{selection}}`.
  Preview uses the task entered in the dialog and the active editor, including
  unsaved content. Substitution happens once; file contents are not reinterpreted
  as templates.

**Preview prompts** displays the resolved request locally. **Run model…** sends it
through OpenAI Responses, OpenAI-compatible Chat Completions, Anthropic Messages,
or Ollama Chat. The API key is entered in the run window, stays in memory only,
and is cleared when the request finishes. Error messages redact the supplied key.
Common credential and request-structure parameter names are rejected in profiles.

For Ollama, press **Detect Ollama**. Tamtoot queries `/api/tags`, offers the models
reported by the server, reads context metadata from `/api/show`, and uses native
streaming `/api/chat`. The default address is `http://localhost:11434`; HTTP is
also accepted for private-network addresses, while public endpoints require HTTPS.

The profiles belong to the open workspace and are reloaded from disk when the
editor opens. External changes are detected before saving or deleting. The Git UI
excludes these agent settings, so they remain local when committing through
Tamtoot. Existing browser folder stores support profile files;
actual browser permission behavior requires a writable folder grant.

## Agent, YOLO and headless mode

Open **Tools → Agent…**, choose a saved model profile, enter a task and run it.
The agent has bounded tools to list/read/write project files, run a command without
a shell, and call connected MCP tools. File writes and commands require one-time
approval in normal mode. API keys remain in the open window only.

**YOLO Mode** auto-approves these actions after a visible first-use warning and a
clean-Git check. It has a 600-second default timeout, a configurable consecutive
mistake limit, an iteration limit, a live log and a **Stop** button. Dangerous
executables and destructive Git commands are blocked. If files changed, the agent
cannot finish until a test/analyze/check command succeeds.

For scripts and CI:

```sh
TAMTOOT_API_KEY=... dart run bin/ide_agent.dart -y --profile local-code "fix the tests"
cat README.md | dart run bin/ide_agent.dart --json "summarize"
```

The CLI reads profiles from the current repository, supports `--timeout` and
`--max-consecutive-mistakes`, emits line-delimited JSON with `--json`, accepts
piped input, handles Ctrl+C, and returns a nonzero status on failure. Compile
`bin/ide_agent.dart` with `dart compile exe` to install it as `ide-agent`.

## Hooks, MCP and Kanban

Executable project hooks live at `.tamtoot/hooks/<HookType>` and receive JSON on
stdin. Supported lifecycle names are `TaskStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, and `TaskCancel`. A JSON response may set `cancel`, `errorMessage`,
and `contextModification`. Hooks have a 10-second timeout and their state appears
in the Agent log.

Configure MCP under **Tools → Settings → MCP servers**. The project file
is `.tamtoot/mcp.json`; both STDIO servers and Streamable HTTP/SSE servers are
supported. The editor can test connections and list tools, and Agent can call
them with the same normal/YOLO approval rules. Header values are stored verbatim,
so do not commit long-lived secrets.

**Tools → Agent Kanban…** stores cards in `.tamtoot/agents/kanban.json` with Todo,
In Progress, Review and Done states. Cards can express dependencies. Starting a
ready desktop card creates an isolated `tamtoot/<card-id>` Git worktree under
`.tamtoot/worktrees/`; Tamtoot adds its metadata folder to the repository's local
Git exclude file.

## Current limitations

This is an actively developed foundation, not a production compiler/debugger environment. Full LSP integration, PTY terminals, debugging, executable third-party extension hosting, advanced docking/drag-and-drop, and independent split editor groups are still future work. Placeholder panels identify unavailable providers explicitly.

The editor virtualizes visible lines with overscan. Storage currently uses an indexed string with O(n) edits. IME and session persistence still transfer the full document. Syntax highlighting is lexical, with cached continuation states for multiline comments and strings. Folding, diagnostics, snippets and multiple cursors have extension/model boundaries, while their complete UI is not implemented.

Platform file access differs: desktop supports local files/folders; Android uses system document selection and SAF export; Web file/folder capabilities depend on browser support and permission; the iOS export provider remains incomplete. macOS may require reopening a sandbox-protected folder after restart because security-scoped bookmarks are not implemented.

The existing Git client has limitations around staging, ignore rules, packed/shallow histories and repository layouts. Unsupported Git reads are reported in Explorer; ordinary file browsing remains available. Kanban currently creates and tracks worktrees, but automated dependency scheduling, inline diff review, auto-commit/PR and persistent multi-agent teams remain future work.

## Architecture and documentation

The editor, command system, layout model, schemas and language definitions are independent of Flutter widgets and Riverpod. Riverpod connects application state to the UI. Platform access is behind providers; plugins do not receive internal state providers.

- [Original specification](docs/specification.md)
- [Requirements matrix](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Versioned formats](docs/schemas.md)
- [Models, Agent, hooks, MCP and Kanban](docs/agents.md)
- [Public extension API](docs/extension-api.md)
- [Foundation verification](docs/verification.md)

Some development documentation is currently in Russian.

## Third-party notices

JetBrains Mono is bundled under the [SIL Open Font License](assets/fonts/OFL.txt), from the official JetBrains/JetBrainsMono repository. UI icons are Material Icons supplied with Flutter. Microsoft branding and assets are not used. A separate license for this repository's original source has not yet been selected.
