# Соответствие ТЗ v0.1

Объём поставки — Milestone 1 (§19), с границами §20 и §25. Разделы будущих возможностей сохранены как требования последующих этапов, а не объявлены реализованными.

| № §19 | Требование | Реализация |
|---|---|---|
| 1 | Desktop-style IDE shell | IdeShell: меню/toolbar, Explorer, документы, tools, status |
| 2–3 | Оригинальные dark/light темы | Midnight Ink / Porcelain, theme packages, переключение и persistence |
| 4 | Menu/toolbar | File/Edit/View/Tools и command-backed actions |
| 5 | Solution Explorer | Открытые документы, desktop folder browsing, recent folders |
| 6 | Custom editor | CodeEditor + CustomPainter; без TextField документа |
| 7 | Document tabs | Несколько документов, активная вкладка, dirty marker, close confirmation |
| 8 | Problems/Output/Terminal placeholders | Действующие Output/ошибки приложения; явные placeholders провайдеров Terminal/Debug/diagnostics |
| 9 | Status bar | Сообщение, строка/колонка, язык, read-only |
| 10 | Resize | Горизонтальная и вертикальная границы, mouse/touch drag |
| 11 | Dock model | SplitNode/TabNode/PanelNode/DocumentNode, recursive renderer |
| 12 | Layout persistence | Versioned JSON, visibility/ratio/active tool; recovery неизвестных panel IDs |
| 13 | Command registry | Registration/execution/enablement/visibility/unregister; error boundary |
| 14 | Keybinding registry | Defaults ctrl/meta, JSON overrides, command resolution |
| 15 | Settings foundation | defaults/user/workspace, font/tab/readOnly/theme; durable storage |
| 16 | Language registry | Расширения/имена, package metadata, provider boundary |
| 17–18 | Dart/C# packages | language/syntax/snippets JSON, schemaVersion + packageVersion |
| 19 | Custom document rendering | Видимые строки + overscan, line numbers/current line, syntax tokens |
| 20 | Cursor/selection | UTF-16 offset, selection list, один UI cursor, selection painting |
| 21 | Keyboard editing | TextInputClient/IME, arrows/home/end, select, backspace/delete/enter/tab, commands |
| 22 | Mouse interaction | Click, drag selection, double-click word, context menu, wheel/scrollbars |
| 23 | Touch hooks | Tap caret, long-press word/drag selection, touch scroll, software keyboard |
| 24 | Package-driven highlighting | Regex SyntaxRule → tokens → theme scopes; editor не знает Dart/C# |
| 25 | Undo/redo | Batch transactions, selection restoration, redo invalidation, read-only guard |
| 26 | Save abstraction | DocumentService → FileSystemProvider / FileDialogs; native/SAF/download adapters |
| 27 | Core tests | Buffer/edits/history/commands/keybindings/packages/schema/layout/settings/session; widget tests |

## Другие обязательные архитектурные пункты

| Пункт ТЗ | Статус |
|---|---|
| Riverpod не является domain architecture | Core/editor models импортируют только Dart; ProviderScope в app |
| Нет InputModeService | Фактические события Flutter + platform capabilities |
| UI actions через commands | Меню, toolbar, editor input, gestures, dialogs и панели используют command IDs |
| Version-aware external formats | Центральный version gate, отдельная нормализация в loaders, schemas.md |
| Неизвестные схемы не роняют запуск | Errors routed to Output/Problems; defaults/recovery |
| Plugin API без providers | tamtoot_api.dart, PluginContext, API v1 documentation |
| Local filesystem за абстракцией | URI boundary, dart:io conditional import только platform |
| Efficient edits / replaceable storage | O(n) edits, indexed reads; TextBuffer replaceable; 100k-line viewport test |
| Multiple cursors architecture | Список selections и batch transactions; MVP UI один cursor |
| Decorations/diagnostics/folding/brackets | Domain records, painter decoration support, revision-aware provider seam, bounded bracket hook |
| Fonts/tab preferences | Настройки и persistence; bundled JetBrains Mono. Глобальный UI read-only удалён, чтобы открытые файлы проекта всегда оставались редактируемыми |
| Plugin-contributed panels | Публичный PanelRegistry/descriptor; executable-host ещё нет |
| Terminal/LSP/SCM/debug/process boundaries | Публичные capability interfaces; отдельно реализованы внутренние Git и bounded agent process adapters |
| Future desktop compilation | Scaffolds всех платформ, conditional IO; проверяемые сборки перечислены отдельно |

## Агентное ТЗ

| Возможность | Статус | Реализация / граница |
|---|---|---|
| Редактируемые prompts per model | Готово | Model profiles schema v1, общие instructions, preview и reset |
| OpenAI Responses / compatible Chat Completions / Anthropic | Готово | Отдельная сборка request/response, timeout, cancel, size limit, redaction |
| Ollama native integration | Готово | `/api/tags`, `/api/show`, streaming `/api/chat`, context metadata |
| Безопасное хранение API keys | Готово в заявленной модели | Ключ только в памяти dialog или `TAMTOOT_API_KEY`; persistence отсутствует |
| Agent file tools | Готово | list/read/write только внутри project; `.git`/`.tamtoot` закрыты; размеры ограничены |
| Agent commands | Готово на desktop | Direct process без shell, timeout/output limits, stop, dangerous command denylist |
| Normal approvals | Готово | One-time approval перед write/command/MCP call |
| YOLO Mode | Готово | First-use warning, clean Git, auto-approval; остальные ограничения остаются |
| Завершение после проверки | Готово | После write нужен successful test/analyze/check command |
| Headless `ide-agent` | Готово | `-y`, JSON Lines, stdin, timeout, mistake limit, profile, exit codes, Ctrl+C |
| Project hooks | Частично | 5 lifecycle hooks, cancel/context, timeout; global hooks и TaskResume отсутствуют |
| MCP STDIO + Streamable HTTP | Готово | initialize, tools/list, tools/call, SSE/JSON, session ID, test UI |
| MCP management UI | Частично | Raw JSON editor и connection test; отдельные add/restart controls отсутствуют |
| Kanban persistence/dependencies | Готово | 4 статуса, schema v1, dependency validation и ready state |
| Git worktree per card | Готово на desktop | `.tamtoot/worktrees/<id>`, branch `tamtoot/<id>` |
| Автоматический Kanban scheduler | Не реализовано | Карточки запускаются/двигаются вручную |
| Inline review и комментарии | Не реализовано | Остаётся будущим UI |
| Auto-commit/push/PR | Не реализовано | Поля зарезервированы, действие не выполняется |
| Persistent Agent Teams | Не реализовано | Нет ролей, shared task list и межагентных сообщений |
| Durable JSONL logs и prompt cache metrics | Не реализовано | Есть live/copyable events текущего запуска |

Полная пользовательская и конфигурационная документация находится в [agents.md](agents.md).

## Что специально оставлено на следующий этап

- Dock move / left-right-top-bottom DnD, editor splits и несколько независимых document groups.
- Stateful lexer, snippets insertion UI, auto-close/indent behavior, folding controls, полноценная accessibility semantics документа, полная grapheme navigation.
- Production analyzer/compiler/LSP, terminals/PTY, debugging/SSH, executable extension host, marketplace и collaboration.
- Agent scheduler, inline review, auto-commit/push/PR, global hooks, TaskResume и persistent Agent Teams.
- SAF tree, iOS export, sandbox bookmarks, remote filesystem.

Это границы текущей реализации, а не скрытые готовые функции. Нет тестов миграции несуществующей legacy-схемы; есть v1 normalization/defaults и rejection старой/будущей неподдерживаемой версии. Migration fixtures обязательны при первом изменении схемы.
