# Архитектура v0.1

## Поток выполнения

`main → bootstrap → IdeSession → ProviderScope → TamtootApp → IdeShell`.

Flutter UI наблюдает `IdeSession.changes` через Riverpod. Команды и доменные модели не импортируют Flutter или Riverpod. UI маршрутизирует действия в `CommandRegistry`, ошибки попадают в Output / Problems / status. Асинхронные операции используют Future, каталог читается потоком без синхронного обхода всего дерева.

## Модули

| Модуль | Ответственность |
|---|---|
| `lib/editor/buffer` | Replaceable TextBuffer, UTF-16 coordinates, line index |
| `lib/editor/document` | Selection list, edits, atomic history, find/replace, read-only, decorations/folding/bracket hooks |
| `lib/editor/viewport` | Visible line range + overscan |
| `lib/editor/rendering` | Canvas painter, token spans, selection/caret, tab expansion |
| `lib/editor/input` | Flutter KeyEvent → normalized chord |
| `lib/editor/widgets` | Focus, IME client, pointer/gesture adaptation, scroll controllers |
| `lib/core/commands` | Commands, enablement/visibility, configurable keybindings |
| `lib/core/persistence` | Version gate and validation errors |
| `lib/core/settings` | defaults → user → workspace layers |
| `lib/core/themes` | Independent theme model, token colors and metadata |
| `lib/core/filesystem` | URI-based file provider, dialogs, persistence contracts |
| `lib/core/extensions` | Public v1 extension/provider boundaries |
| `lib/core/agents` | Model profiles and API clients, agent loop, hooks, MCP, Kanban and worktree boundaries |
| `lib/core/git` | Pure-Dart repository storage, status, diff, commit and Smart HTTP transport |
| `lib/workspace/layout` | Split/Tab/Panel/Document nodes; recovery for obsolete panels |
| `lib/workspace/documents` | Open documents, saved baselines, safe async save snapshot |
| `lib/languages` | Manifest normalization, registry, tokenization, persistent package installation |
| `lib/platform` | Conditional dart:io adapters, file_selector, SharedPreferences, Android channel |
| `lib/app` | Bootstrap, application orchestration, command registration, Riverpod integration |
| `lib/features` | Shell, data-driven dock renderer, dialogs and tool windows |

## Принятые решения

1. Редактор не использует TextField/TextFormField. TextField допустим только для полей поиска/настроек/пакетов. Текст документа рисует собственный CustomPainter; TextInputClient обслуживает IME.
2. Нет глобального InputMode. Реакция определяется фактическим pointer kind, клавишами, фокусом и событиями жестов.
3. Буфер заменяемый. Индекс строк и двоичный поиск дают быстрые чтения; rope не вводится без измерений.
4. Видимые строки и overscan обрабатываются отдельно от полного документа. Нет ListView из всех строк и построения TextSpan всего файла.
5. DockLayout — данные. Flutter DockView рекурсивно интерпретирует дерево; начальная раскладка задаётся один раз в модели.
6. Riverpod — адаптер состояния UI. Плагинам не экспортируются providers.
7. Доменные модели редактора, docking, команды, схемы, tokenization и цикл агента написаны в проекте. Внешние пакеты ограничены UI/state-адаптерами, системными диалогами и хранилищем, HTTP, криптографией, архивами и web interop; агентная подсистема не добавляет отдельный agent SDK.
8. Состояние сохраняется последовательно через очередь, чтобы старый snapshot не перезаписал новый. Ошибки persistence видимы пользователю. При async save изменения, сделанные во время записи, остаются dirty.
9. Android export отделён MethodChannel-адаптером; запись SAF происходит вне main thread. Полные SAF folder sessions не имитируются.
10. Executable extension API только описывает границы. Без host/sandbox динамическая загрузка произвольного plugin-кода не рекламируется как готовая функция. Отдельно реализованные agent commands и hooks являются внутренними ограниченными адаптерами и не превращают extension API в готовый host.
11. ModelProfile отделяет редактируемый prompt от транспорта. ModelClient строит запрос для Responses, Chat Completions, Anthropic или Ollama, ограничивает ответ и не сохраняет API key.
12. AgentTaskEngine — последовательный bounded loop. Модель предлагает JSON action, а host повторно проверяет путь, approval, тип команды и лимиты. Normal mode требует подтверждения изменяющих действий; YOLO снимает approvals только после clean-Git проверки, но не отключает ограничения.
13. `.tamtoot` — локальная workspace-область для profiles, instructions, hooks, MCP, Kanban и worktrees. Встроенный Git UI исключает её. Это соглашение приложения, а не security boundary для внешних Git-клиентов.
14. MCP — клиент инструментов агента, а не executable plugin host. Поддержаны JSON-RPC initialization, tools/list и tools/call через STDIO или Streamable HTTP/SSE.

## Поток агентной задачи

`Agent dialog / ide-agent → ModelProfile → TaskStart/UserPromptSubmit hooks → ModelClient → validated action → approval or YOLO policy → file/command/MCP adapter → PreToolUse/PostToolUse hooks → next model iteration → finish`.

После первой записи файла `finish` разрешается только после успешной команды, распознанной как test/analyze/check. Stop отменяет активный HTTP client и завершает текущие process/hook. Все file actions используют относительные пути внутри workspace; `.git` и `.tamtoot` через них недоступны. Command runner не вызывает shell и отдельно блокирует опасные executable и destructive Git forms. Это защитные ограничения приложения, а не полноценная OS sandbox.

## Дальнейшие изменения

- Обоснованный профилированием piece-table/rope без изменения controller/renderer.
- Виртуализация горизонтальных сегментов очень длинных строк и IME delta-window.
- Semantic token layers и embedded-language tokenization поверх существующего stateful lexical tokenizer.
- Dock DnD, перемещение по сторонам и независимые document groups.
- Android SAF tree provider, desktop security bookmarks, iOS export.
- LanguageServiceProvider → LSP adapter; diagnostics публикуются с revision guard.
- Extension host с lifecycle, scoped capabilities, teardown и ограничениями каждой платформы.
- Автоматический Kanban scheduler, запуск agent per card, inline review, auto-commit/push/PR и persistent Agent Teams.
- Global hooks, TaskResume, durable run logs и измеряемый prompt cache.
