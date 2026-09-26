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
7. Только три runtime-зависимости сверх Flutter: Riverpod (требование ТЗ), shared_preferences (платформенное хранилище), file_selector (системные диалоги). Редактор, docking, команды, схемы и tokenization написаны в проекте.
8. Состояние сохраняется последовательно через очередь, чтобы старый snapshot не перезаписал новый. Ошибки persistence видимы пользователю. При async save изменения, сделанные во время записи, остаются dirty.
9. Android export отделён MethodChannel-адаптером; запись SAF происходит вне main thread. Полные SAF folder sessions не имитируются.
10. Executable API только описывает границы. Без host/sandbox динамическая загрузка произвольного кода не рекламируется как готовая функция.

## Дальнейшие изменения

- Обоснованный профилированием piece-table/rope без изменения controller/renderer.
- Виртуализация горизонтальных сегментов очень длинных строк и IME delta-window.
- Stateful tokenizer для многострочных комментариев/строк.
- Dock DnD, перемещение по сторонам и независимые document groups.
- Android SAF tree provider, desktop security bookmarks, iOS export.
- LanguageServiceProvider → LSP adapter; diagnostics публикуются с revision guard.
- Extension host с lifecycle, scoped capabilities, teardown и ограничениями каждой платформы.
