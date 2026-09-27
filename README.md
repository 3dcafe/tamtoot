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
- A command registry, editable keybindings, font settings, tab preferences, and read-only mode.

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

The original development SDK is located at `/Users/latin/Documents/Flutter/3_44_1`; despite the directory name, that installation reports Flutter 3.44.0.

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
- **Tools → Settings**: theme, font, size, tabs, read-only mode, and keybindings.
- **Tools → Language packages**: install versioned `language.json`, `syntax.json`, and optional `snippets.json` without rebuilding the IDE.

Drag panel dividers to resize. Click folders to expand or collapse them, and files to open them. Tap in the editor to position the cursor; long-press and drag to select text. Ordinary touch dragging scrolls the document.

Common shortcuts: `Ctrl/⌘+S` saves, `Ctrl/⌘+Z` undoes, `Ctrl/⌘+Shift+Z` redoes, `Ctrl/⌘+F` finds, and `Ctrl/⌘+Shift+P` opens commands.

On startup, Tamtoot reopens the most recent project in history. If there is no project or its folder is unavailable, the project tree stays empty; no demo tabs are created. Existing user drafts are still recovered. Unmodified demo tabs from older installations are removed automatically, while edited drafts and real files are preserved.

The application saves session data after a 450 ms idle period and when it moves into the background. Theme changes are persisted immediately. Session recovery is separate from saving the actual file. Force-quitting during a pending write may lose the latest unsaved changes.

## Language highlighting

Bundled language packages are versioned independently (currently 0.2.0). File extensions are matched without case sensitivity:

| Language | Extensions | Highlighting |
| --- | --- | --- |
| HTML | `.html`, `.htm` | Tags, attributes, quoted values, entities, doctype, multiline comments and CDATA |
| JavaScript | `.js`, `.mjs`, `.cjs` | Module/async keywords, built-ins, calls, operators, numeric literals including BigInt, strings, multiline templates and comments |
| Dart | `.dart` | Expanded keywords and built-in types, annotations, calls, hexadecimal/exponent numbers, raw/triple-quoted strings and nested block comments |
| C# | `.cs` | Contextual keywords, attributes, directives, escaped identifiers, numeric suffixes, verbatim/interpolated/raw strings and block comments |

Multiline states remain correct when scrolling into the middle of a document. Editing a preceding delimiter invalidates the cached suffix. Existing single-line regex language packages remain supported.

This is syntax coloring, not semantic analysis. Interpolated expressions inside strings/templates use the string color; JavaScript regular-expression detection is heuristic. Embedded JavaScript/CSS in HTML, JSX/TypeScript, completion, live preview and code execution are not implemented by these packages. Snippet definitions are supplied as package data; an interactive snippet insertion UI remains future work.

## Commit and push from the IDE

Open a cloned project and select the **Git** tab beside **Solution** in the sidebar. The same controls are available through **Git → Commit and push…** and the command palette.

1. Use the checkboxes to select the files to include, including additions or deletions. Selected unsaved editor changes are saved before committing. Files not selected remain outside the commit.
2. Enter your author name, author email and commit message, then click **Commit selected**. Author details are stored in that repository's Git configuration.
3. Enter your HTTPS username and access token (or password accepted by your host), then click **Push commits**. This sends local commits to `origin` on the current branch. Credentials stay in memory while that Git view is open (switching sidebar tabs keeps the view open); they are never saved in settings or repository files.

Commit and push are separate operations: a failed push leaves the local commit available for retry. The Git view shows progress and errors; Explorer indicators refresh after successful operations. Push verifies the remote's unpack/ref status, refuses non-fast-forward updates and sets the current branch's upstream after success. No new dependencies or system Git executable are required by the application.

File selection is whole-file staging for one commit, not a persistent staging UI. The client maintains a standard Git v2 index and refuses to overwrite existing staging from another client. Advanced indexes, merge conflicts, detached HEAD commits, symlink/submodule edits, hooks, signing and packed object databases are not supported. `.tamtoot` metadata is excluded. Full `.gitignore` semantics are still not implemented: review new files explicitly before selecting them. Web push additionally depends on the remote host allowing browser requests (CORS).

## Compare and discard changes

Click a filename in the Git changes list to compare **HEAD → current content**, including unsaved editor changes. Added and removed lines have separate colors and line numbers. Right-click a file in Solution or Git (long-press on touch devices) for **Compare with HEAD** and **Discard changes…**.

Discard requires confirmation. It restores a tracked file to its last committed contents, including deleted files, and reloads its open editor. For an untracked file, the confirmation explicitly offers deletion. Cancel preserves everything. A stale review, changed HEAD or existing external staging prevents restoration.

Text comparison supports UTF-8 files up to a combined 2 MiB preview limit. Binary files show an explanatory message; large changed text spans use a bounded replacement view. Line endings are normalized only for display; restoration uses the original committed bytes.

## Model profiles and prompts

Open a project, then go to **Tools → Settings → Model profiles and prompts**.
Create a profile with a stable ID, display name, provider ID and model ID. Each
profile has an editable system prompt, user prompt template and JSON object of
API parameters. **Reset prompts** restores the built-in templates; **Save profile**
persists edits. Profiles can be selected, edited and deleted independently.

- Profiles: `.tamtoot/agents/models/<profile-id>.json` (schema version 1).
- Shared instructions: `.tamtoot/agents/instructions.md`, saved separately and
  appended to every profile's system prompt.
- Template variables: `{{task}}`, `{{file_path}}`, `{{file}}`, `{{selection}}`.
  Preview uses the task entered in the dialog and the active editor, including
  unsaved content. Substitution happens once; file contents are not reinterpreted
  as templates.

**Preview prompts** displays the resolved, provider-neutral configuration locally.
This release does **not** send model API requests or run agents. Provider adapters,
model-specific parameter validation and secure credential storage are not yet
implemented. Do not put credentials in prompts or parameters; common credential
and request-structure parameter names are rejected. No API-key field is exposed.

The profiles belong to the open workspace and are reloaded from disk when the
editor opens. External changes are detected before saving or deleting. The current
Git UI still excludes `.tamtoot` entirely, so these settings remain local when
committing through Tamtoot. Existing browser folder stores support profile files;
actual browser permission behavior requires a writable folder grant.

## Current limitations

This is an actively developed foundation, not a production compiler/debugger environment. Full LSP integration, PTY terminals, debugging, executable third-party extension hosting, advanced docking/drag-and-drop, and independent split editor groups are still future work. Placeholder panels identify unavailable providers explicitly.

The editor virtualizes visible lines with overscan. Storage currently uses an indexed string with O(n) edits. IME and session persistence still transfer the full document. Syntax highlighting is lexical, with cached continuation states for multiline comments and strings. Folding, diagnostics, snippets and multiple cursors have extension/model boundaries, while their complete UI is not implemented.

Platform file access differs: desktop supports local files/folders; Android uses system document selection and SAF export; Web file/folder capabilities depend on browser support and permission; the iOS export provider remains incomplete. macOS may require reopening a sandbox-protected folder after restart because security-scoped bookmarks are not implemented.

The existing Git client has limitations around staging, ignore rules, packed/shallow histories and repository layouts. Unsupported Git reads are reported in Explorer; ordinary file browsing remains available.

## Architecture and documentation

The editor, command system, layout model, schemas and language definitions are independent of Flutter widgets and Riverpod. Riverpod connects application state to the UI. Platform access is behind providers; plugins do not receive internal state providers.

- [Original specification](docs/specification.md)
- [Requirements matrix](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Versioned formats](docs/schemas.md)
- [Public extension API](docs/extension-api.md)
- [Foundation verification](docs/verification.md)

Some development documentation is currently in Russian.

## Third-party notices

JetBrains Mono is bundled under the [SIL Open Font License](assets/fonts/OFL.txt), from the official JetBrains/JetBrainsMono repository. UI icons are Material Icons supplied with Flutter. Microsoft branding and assets are not used. A separate license for this repository's original source has not yet been selected.
