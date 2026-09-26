# Tablet/Desktop IDE --- Architecture & Codex Master Prompt

**Version:** 0.1.0\
**Status:** Initial architecture / MVP specification\
**Target:** Flutter, cross-platform-first; Android tablets and
desktop-style Android environments are primary initial use cases.

------------------------------------------------------------------------

## 1. Product vision

Build a free, extensible IDE in Flutter with a desktop-class workspace
inspired by the **interaction model of Microsoft Visual Studio (not
Visual Studio Code)**, while using an original visual identity and
implementation.

The IDE must work well with: - touch; - mouse; - keyboard; - mixed
input; - external displays; - resizable windows; - future Flutter
targets beyond Android.

Do **not** model the architecture around a hard-coded
`InputModeService`. Input is capability/event driven. Widgets and
commands respond to pointer type, keyboard events, hover availability,
gestures, window metrics, and platform capabilities as needed.

The project must be designed as an IDE platform rather than a
single-purpose code editor.

------------------------------------------------------------------------

## 2. Core architecture

``` text
                         Flutter UI
                              │
                         Riverpod
                              │
              ┌───────────────┴───────────────┐
              │                               │
       Workspace / Docking              Command System
              │                               │
              └───────────────┬───────────────┘
                              │
                    Application Services
                              │
       ┌──────────┬───────────┼───────────┬──────────┐
       ↓          ↓           ↓           ↓          ↓
   Workspace   FileSystem    LSP       Terminal     SCM/Git
       │          │           │           │          │
       └──────────┴───────────┼───────────┴──────────┘
                              │
                        Extension Host
                              │
                          Plugin API
                              │
       ┌──────────┬───────────┼───────────┬──────────┐
       ↓          ↓           ↓           ↓          ↓
   Languages    Themes     Commands    Keymaps     UI Panels
                              │
                        Platform Layer
                              │
                    Dart / FFI / Native
```

Riverpod is an application/UI state-management mechanism, **not the
domain architecture**. Core services must not depend on Flutter widgets
and must not expose internal Riverpod providers as the public plugin
API.

------------------------------------------------------------------------

## 3. Mandatory architectural rules

1.  Do not put application logic in widgets.
2.  Do not build the editor around Flutter `TextField`/`TextFormField`.
3.  Do not couple Editor Core to C#, Dart, LSP, Android, or Riverpod.
4.  Do not let plugins access internal providers directly.
5.  UI actions must invoke commands instead of directly calling
    unrelated services.
6.  Persisted layouts and external package formats must be versioned.
7.  Platform-specific code must sit behind abstractions.
8.  Prefer small cohesive modules over a giant `main.dart` or god
    services.
9.  Avoid speculative abstractions with no foreseeable consumer.
10. Every public extension contract must be documented and versionable.
11. Visual Studio is a UX reference only. Do not copy Microsoft
    branding, assets, icons, or proprietary source/design resources.
12. The architecture must remain compilable for future Flutter desktop
    targets.

------------------------------------------------------------------------

## 4. Custom editor --- written from scratch

Create our own Flutter editor widget and editor engine.

``` text
EditorController
      │
      ├── DocumentModel
      ├── CursorManager
      ├── SelectionManager
      ├── UndoRedoManager
      ├── DecorationManager
      ├── FoldingModel
      └── EditorViewport
               │
               ↓
            Renderer
```

### Required editor concepts

-   text document independent from UI;
-   document version/revision;
-   efficient edits;
-   line/offset conversion;
-   cursor;
-   multiple cursors architecture, even if MVP initially exposes one;
-   selections;
-   undo/redo transactions;
-   scrolling;
-   line numbers;
-   current-line indication;
-   tab size;
-   spaces/tabs configuration;
-   read-only mode;
-   decorations;
-   diagnostics decoration hooks;
-   folding model hooks;
-   bracket matching hooks;
-   syntax token rendering;
-   configurable font and font size;
-   keyboard navigation;
-   mouse selection;
-   touch selection;
-   context menu hooks;
-   command integration.

### Performance

Never render the complete document merely because it exists.

The editor must use viewport virtualization:

``` text
Large Document
      ↓
EditorViewport
      ↓
Visible range + small overscan
      ↓
Render only required lines
```

Design for large files from the beginning.

Do not prematurely implement an extremely complex rope/piece-table
unless benchmarks justify it, but isolate the text-storage
implementation behind an interface so it can later be replaced without
rewriting the editor.

Example:

``` dart
abstract interface class TextBuffer {
  int get length;
  int get lineCount;

  String getText(TextRange range);
  String getLine(int line);
  TextPosition positionAt(int offset);
  int offsetAt(TextPosition position);

  TextChange applyEdit(TextEdit edit);
}
```

------------------------------------------------------------------------

## 5. Input architecture

Do not create a global enum such as:

``` dart
enum InputMode { touch, mouseKeyboard, hybrid }
```

as the central source of truth.

Instead, use Flutter's actual input model and capability-oriented
services where needed:

-   keyboard events;
-   pointer kind;
-   hover events;
-   mouse buttons;
-   scroll wheel/trackpad;
-   touch gestures;
-   long press;
-   drag;
-   window dimensions;
-   focus;
-   shortcuts/actions;
-   platform capabilities.

All input paths ultimately execute the same commands:

``` text
Keyboard ──────┐
Mouse ─────────┼──→ Keybinding / Gesture mapping
Touch ─────────┘                 │
                                 ↓
                          Command Registry
                                 │
                                 ↓
                           Editor / IDE Core
```

This keeps behavior consistent and makes the IDE portable.

------------------------------------------------------------------------

## 6. Workspace and docking

The IDE shell should be conceptually close to the desktop workspace
model of Visual Studio, **not VS Code**.

Default layout:

``` text
┌──────────────────────────────────────────────────────┐
│ Menu / Main Toolbar                                 │
├────────────┬─────────────────────────────────────────┤
│ Explorer / │ Document tabs                          │
│ Solution   ├─────────────────────────────────────────┤
│ Explorer   │                                         │
│            │              Editor                     │
│            │                                         │
├────────────┴─────────────────────────────────────────┤
│ Problems | Output | Terminal | Debug                │
├──────────────────────────────────────────────────────┤
│ Status Bar                                           │
└──────────────────────────────────────────────────────┘
```

The exact side used for individual tool windows may be changed by the
user.

### Docking requirements

Design a first-party docking/layout engine.

Panels must eventually support:

-   resize;
-   move;
-   left/right/top/bottom docking;
-   tab groups;
-   document groups;
-   split editor groups;
-   show/hide;
-   drag-and-drop;
-   restore default layout;
-   persistent layout;
-   plugin-contributed panels.

Represent layout as data rather than widget nesting hard-coded into the
application.

Example conceptual node model:

``` text
DockNode
 ├── SplitNode
 ├── TabNode
 ├── PanelNode
 └── DocumentNode
```

Persisted layout must contain a schema version.

Example:

``` json
{
  "schemaVersion": 1,
  "layoutId": "default",
  "root": {
    "type": "horizontalSplit",
    "children": []
  }
}
```

Unknown/obsolete panel IDs must not make startup fail. The loader should
recover gracefully.

------------------------------------------------------------------------

## 7. Command system

Commands are a core platform primitive.

Examples:

``` text
file.open
file.save
file.saveAll

editor.undo
editor.redo
editor.copy
editor.paste
editor.find
editor.replace
editor.splitRight
editor.splitDown

view.solutionExplorer
view.terminal
view.problems

terminal.create
terminal.kill

workspace.open

extensions.manage
```

Conceptual API:

``` dart
abstract interface class CommandRegistry {
  void register(CommandDescriptor command);
  Future<Object?> execute(String commandId, [Object? argument]);
  bool contains(String commandId);
}
```

Commands may have: - id; - title; - category; - handler; - enablement
predicate; - visibility predicate.

Menu items, toolbar buttons, context menus, shortcuts, touch actions,
and plugins should invoke commands.

------------------------------------------------------------------------

## 8. Keybinding system

Never hard-code `Ctrl+S => save()` inside UI code.

``` text
Key Event
   ↓
Keybinding Registry
   ↓
Command ID
   ↓
Command Registry
```

Keybindings must be configurable and support future presets such as:

-   IDE Default;
-   Visual Studio-like;
-   IntelliJ-like;
-   custom;
-   potentially Vim/Emacs extensions later.

Example external representation:

``` json
{
  "schemaVersion": 1,
  "bindings": [
    {
      "key": "ctrl+s",
      "command": "file.save"
    }
  ]
}
```

------------------------------------------------------------------------

## 9. Language system

The custom editor knows nothing about Dart or C#.

``` text
Custom Editor
      │
Language Registry
      │
 ┌────┴────┐
 ↓         ↓
Dart       C#
```

Initial reference languages: - Dart (`.dart`); - C# (`.cs`).

Their first implementation should prove that language support can be
externalized rather than embedded into Editor Core.

### Two extension levels

#### Level A --- declarative Language Package

A language can initially be added without rebuilding the IDE.

Example:

``` text
languages/
└── csharp/
    ├── language.json
    ├── syntax.json
    ├── snippets.json
    └── icons/
```

A package may describe: - language id; - display name; - extensions; -
filenames; - comments; - brackets; - auto-closing pairs; - indentation
hints; - syntax/tokenization rules; - snippets; - icon metadata; -
optional references to supported language-service adapters.

#### Level B --- executable Plugin / Provider

For advanced behavior:

-   completion;
-   diagnostics;
-   hover;
-   go to definition;
-   references;
-   rename;
-   formatting;
-   semantic tokens;
-   code actions;
-   LSP integration.

The executable plugin mechanism may be implemented after MVP, but its
public boundaries must be anticipated now.

------------------------------------------------------------------------

## 10. Versioned external JSON contracts

**Every external JSON format must carry a schema version from day one.**

Example:

``` json
{
  "schemaVersion": 1,
  "packageVersion": "0.1.0",
  "id": "csharp",
  "name": "C#",
  "extensions": [".cs"]
}
```

Distinguish:

-   `schemaVersion` --- version of the JSON structure understood by the
    IDE;
-   `packageVersion` --- version of the individual language/plugin/theme
    package;
-   `apiVersion` --- compatibility level of an executable extension with
    the IDE extension API, where applicable.

### Compatibility rules

1.  Never silently reinterpret an incompatible schema.
2.  Older supported schemas should be migrated/normalized into the
    current in-memory model.
3.  Unknown optional fields should normally be ignored.
4.  Missing optional fields use documented defaults.
5.  Unknown required semantics must produce a useful validation error.
6.  A newer unsupported `schemaVersion` must not crash the IDE.
7.  Keep parsing DTOs separate from normalized domain models.
8.  Add migration tests whenever a schema evolves.

Conceptual flow:

``` text
External JSON
     ↓
Version detection
     ↓
Schema-specific DTO
     ↓
Migration / normalization
     ↓
Current domain model
```

Do not spread `schemaVersion == ...` checks throughout application code.

------------------------------------------------------------------------

## 11. Plugin API

Plugins must depend on a stable public context, not implementation
details.

Conceptual interface:

``` dart
abstract interface class IdePlugin {
  String get id;
  String get version;
  int get apiVersion;

  Future<void> activate(PluginContext context);
  Future<void> deactivate();
}
```

Conceptual `PluginContext`:

``` text
PluginContext
 ├── commands
 ├── workspace
 ├── filesystem
 ├── editors
 ├── languages
 ├── diagnostics
 ├── settings
 ├── themes
 ├── notifications
 ├── terminals
 └── ui
```

Potential permissions:

``` text
filesystem.read
filesystem.write
process.execute
network
terminal
scm
```

Do not assume arbitrary dynamic Dart code can safely or portably be
loaded at runtime on every Flutter target. Keep declarative packages
separate from executable plugins and design the eventual extension host
around platform constraints.

------------------------------------------------------------------------

## 12. File system abstraction

Do not bind the workspace directly to `dart:io File`.

``` text
Workspace
   ↓
Virtual File System
   ↓
FileSystemProvider
```

Potential providers:

``` text
LocalFileSystem
AndroidDocumentProvider / SAF adapter
RemoteFileSystem
SSHFileSystem
PluginFileSystem
```

The first implementation may be limited, but Editor/Application layers
should depend on abstractions.

------------------------------------------------------------------------

## 13. Application services

Define explicit boundaries for services such as:

``` text
WorkspaceService
FileSystemService
DocumentService
EditorService
LanguageService
SettingsService
ThemeService
LayoutService
CommandService
KeybindingService
ExtensionService
```

Later:

``` text
LspService
TerminalService
ScmService
DebugService
ProcessService
```

Services should be testable without rendering the full Flutter
application where practical.

------------------------------------------------------------------------

## 14. LSP

LSP is not the editor.

Use a generic language-service boundary:

``` text
Editor
  ↓
LanguageService
  ├── completion
  ├── diagnostics
  ├── hover
  ├── definition
  ├── references
  ├── rename
  ├── formatting
  └── semantic tokens
          │
          ↓
       LSP Adapter
```

This allows both LSP-backed languages and native/plugin providers.

C# and Dart language packages in the first UI milestone do **not**
require full production LSP integration yet. Keep the integration points
ready.

------------------------------------------------------------------------

## 15. Terminal

Terminal is a service/panel, not a special-case widget tied to Android.

Conceptually:

``` text
Terminal UI
    ↓
Terminal Session API
    ↓
PTY / Process abstraction
    ↓
Platform implementation
```

Actual PTY/process execution can be implemented after the UI/editor
foundation.

------------------------------------------------------------------------

## 16. Themes

Support dark and light themes from the beginning.

Do not limit the theme model to Flutter `ThemeMode`.

Conceptually:

``` text
IdeTheme
 ├── shell colors
 ├── panel colors
 ├── editor colors
 ├── syntax colors
 ├── semantic token colors
 ├── terminal colors
 ├── borders
 ├── typography
 └── icon theme reference
```

Default themes should evoke a professional desktop IDE while retaining
an original identity.

Theme packages must also be versionable.

------------------------------------------------------------------------

## 17. Settings and persistence

Design settings in layers:

``` text
Defaults
   ↓
User settings
   ↓
Workspace settings
   ↓
Effective settings
```

Persist at least: - selected theme; - font settings; - editor
preferences; - keybindings; - workspace layout; - panel visibility; -
recent workspaces when appropriate.

Persisted data formats must be versioned where structural evolution is
expected.

------------------------------------------------------------------------

## 18. Proposed repository structure

``` text
lib/
├── app/
│   ├── app.dart
│   ├── bootstrap.dart
│   └── providers/
│
├── core/
│   ├── commands/
│   ├── keybindings/
│   ├── settings/
│   ├── themes/
│   ├── extensions/
│   ├── filesystem/
│   └── persistence/
│
├── editor/
│   ├── document/
│   ├── buffer/
│   ├── cursor/
│   ├── selection/
│   ├── history/
│   ├── decorations/
│   ├── viewport/
│   ├── rendering/
│   ├── input/
│   └── widgets/
│
├── workspace/
│   ├── docking/
│   ├── layout/
│   ├── documents/
│   └── panels/
│
├── languages/
│   ├── api/
│   ├── registry/
│   └── packages/
│
├── features/
│   ├── explorer/
│   ├── problems/
│   ├── output/
│   ├── terminal/
│   ├── extensions/
│   └── settings/
│
└── platform/
    ├── filesystem/
    ├── process/
    └── terminal/

assets/
├── languages/
│   ├── dart/
│   └── csharp/
└── themes/

test/
├── editor/
├── commands/
├── docking/
├── languages/
├── persistence/
└── schemas/
```

This is a starting structure, not a command to create empty folders
purely for appearance. Create modules as implementation requires them
while preserving these boundaries.

------------------------------------------------------------------------

## 19. First milestone --- IDE shell

The first milestone is **not** full compilation/debugging.

Deliver a runnable Flutter application containing:

1.  desktop-style IDE shell;
2.  original dark theme;
3.  original light theme;
4.  menu/toolbar area;
5.  Solution/Project Explorer panel;
6.  central custom editor area;
7.  document tabs;
8.  bottom panel with placeholder tabs:
    -   Problems;
    -   Output;
    -   Terminal;
9.  status bar;
10. resizable primary panel boundaries;
11. initial docking/layout data model;
12. layout persistence;
13. command registry;
14. keybinding registry;
15. settings foundation;
16. language registry;
17. versioned Dart language package;
18. versioned C# language package;
19. custom editor rendering a document;
20. cursor and basic selection;
21. keyboard text editing;
22. basic mouse interaction;
23. basic touch scrolling/selection hooks;
24. syntax highlighting driven through language-package data;
25. undo/redo;
26. save command abstraction;
27. tests for non-UI core logic.

The architecture should make future movable/dockable panels possible
even if the first commit implements only resizing and the initial
layout.

------------------------------------------------------------------------

## 20. Explicitly out of scope for the first milestone

Do not derail milestone 1 by fully implementing:

-   production C# compiler/runtime;
-   production Dart analyzer;
-   full LSP processes;
-   Android PTY;
-   debugger;
-   Git client;
-   SSH;
-   marketplace/backend;
-   arbitrary executable third-party plugins;
-   collaboration;
-   AI assistant;
-   pixel-perfect Visual Studio cloning.

Provide interfaces/hooks where justified, but avoid fake implementations
pretending these features are complete.

------------------------------------------------------------------------

## 21. Testing expectations

At minimum, unit-test:

-   document edits;
-   offset ↔ line/column conversion;
-   undo/redo;
-   command registration/execution;
-   keybinding resolution;
-   language package parsing;
-   schema-version handling;
-   schema migration/normalization;
-   unsupported future schema behavior;
-   layout serialization/deserialization;
-   graceful handling of missing panel IDs.

Add widget tests for critical editor and docking behavior as those
pieces are implemented.

------------------------------------------------------------------------

## 22. Codex implementation instructions

You are implementing this project as a senior Flutter/Dart engineer.

Before writing large amounts of code:

1.  inspect the existing repository;
2.  identify existing dependencies and constraints;
3.  write a short implementation plan;
4.  implement incrementally;
5.  run formatter/analyzer/tests after meaningful changes;
6.  fix regressions before proceeding.

### Engineering constraints

-   Use current stable Flutter/Dart APIs available in the project
    environment.
-   Use Riverpod for state orchestration, while keeping domain/core
    classes framework-independent where practical.
-   Prefer immutable state.
-   Prefer explicit interfaces at architectural boundaries.
-   Do not introduce code generation unless it clearly pays for itself.
-   Do not add a dependency for functionality that is central to this
    project's identity, especially the text editor and docking model,
    without first explaining why.
-   The editor widget/engine must be ours.
-   Keep dependencies minimal.
-   Avoid global mutable singletons.
-   Avoid platform checks scattered through UI code.
-   Avoid giant classes.
-   Avoid premature optimization, but preserve replaceable
    performance-sensitive boundaries.
-   Public extension APIs require documentation.
-   External JSON requires validation and version handling.
-   Do not silently swallow errors; route them through
    logging/diagnostics.
-   UI should remain responsive during expensive work.

### UX direction

The default shell should feel like a serious desktop IDE inspired by the
organization and density of Visual Studio 2020-era/modern Visual Studio,
**not Visual Studio Code**.

Required qualities: - professional; - compact with mouse/keyboard; -
still operable with touch; - resizable; - eventually
dockable/rearrangeable; - dark/light; - clear document/tool-window
distinction; - no Microsoft assets or branding.

Use larger invisible hit targets where useful for touch without
necessarily making the desktop UI visually oversized.

------------------------------------------------------------------------

## 23. Initial language package example

`language.json`:

``` json
{
  "schemaVersion": 1,
  "packageVersion": "0.1.0",
  "id": "csharp",
  "name": "C#",
  "extensions": [".cs"],
  "comments": {
    "line": "//",
    "block": {
      "open": "/*",
      "close": "*/"
    }
  },
  "brackets": [
    { "open": "{", "close": "}" },
    { "open": "[", "close": "]" },
    { "open": "(", "close": ")" }
  ],
  "autoClosingPairs": [
    { "open": "{", "close": "}" },
    { "open": "[", "close": "]" },
    { "open": "(", "close": ")" },
    { "open": "\"", "close": "\"" }
  ]
}
```

Create an equivalent Dart package.

Do not assume schema version 1 is permanent. Parsing must go through a
version-aware loader.

------------------------------------------------------------------------

## 24. Definition of done for v0.1 foundation

The foundation is successful when:

-   the app runs;
-   dark/light themes switch correctly;
-   the shell resembles a desktop IDE workflow without copying Visual
    Studio assets;
-   panels resize;
-   layout state can be serialized/restored;
-   multiple editor tabs can exist;
-   our custom editor can display/edit text;
-   basic keyboard, mouse, and touch interaction works;
-   undo/redo works;
-   commands and keybindings are decoupled from widgets;
-   `.dart` and `.cs` are recognized through external/versioned language
    definitions;
-   syntax highlighting is not hard-coded into the editor;
-   unsupported package schema versions fail gracefully;
-   core tests pass;
-   the codebase leaves clear seams for docking, plugins, LSP, terminal,
    SCM, and additional Flutter platforms.

------------------------------------------------------------------------

## 25. First task for Codex

Start with the repository inspection and then implement **Milestone 1 in
small, reviewable steps**.

Do not attempt the entire future IDE in one pass.

Suggested order:

1.  project/app bootstrap;
2.  theme system;
3.  command + keybinding foundation;
4.  workspace/layout domain model;
5.  IDE shell;
6.  resizable panels;
7.  document/text-buffer model;
8.  custom editor viewport and renderer;
9.  cursor/editing/selection;
10. undo/redo;
11. language-package schema + version-aware loader;
12. Dart/C# packages;
13. token rendering/highlighting;
14. persistence;
15. tests and cleanup.

After each major step, run analysis/tests and keep the project
executable.
