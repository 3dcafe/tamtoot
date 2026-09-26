# Публичный API v1

Точка импорта: `package:tamtoot/tamtoot_api.dart`. Константа `ideApiVersion = 1`. Публичный barrel не экспортирует Flutter UI, Riverpod providers, PlatformFiles или IdeSession.

В v0.1 executable host **не подключён**. Ни декларация интерфейса, ни enum permissions не являются sandbox. Контракты предназначены для следующего этапа с доверенными compiled-in providers и последующим platform-aware host. Извне можно установить только декларативный языковой пакет.

## Контракты

| Контракт | Семантика / будущий lifecycle |
|---|---|
| IdePlugin | id/version/apiVersion; host проверяет версию до activate, вызывает deactivate перед выгрузкой |
| PluginContext | Только явно предоставленные capabilities, без UI state internals |
| CommandRegistry | Уникальные IDs; duplicate/unknown → ошибка, disabled → без выполнения; unregister нужен при deactivate |
| FileSystemProvider | URI вместо dart:io File; read/write/list асинхронны, canWrite указывает доступность записи |
| WorkspaceAccess | Корневой URI и поток его изменений |
| EditorAccess | Active controller и открытие URI; offsets UTF-16, half-open ranges |
| EditorController/TextBuffer | Редактирование через transactions; change stream; dispose освобождает поток; UI и язык независимы |
| LanguageRegistry | Определение языка по extension/filename; register заменяет определение с тем же ID |
| LanguageServiceProvider | capabilities: completion, diagnostics, hover, definition, references, rename, formatting, semanticTokens, codeActions; request(operation,uri,revision,parameters) возвращает provider result, transport/LSP снаружи |
| DiagnosticAccess | Publish заменяет набор владельца; host обязан игнорировать устаревший revision; clear освобождает владельца |
| SettingsService | defaults→user→workspace, validation известных editor keys |
| ThemeAccess | Регистрация domain IdeTheme; host отображает int ARGB через Flutter adapter |
| NotificationAccess | Текст сообщения и признак ошибки |
| PanelRegistry | ID/title/viewType; будущий presentation adapter сопоставляет viewType виджету; unregister при deactivate |
| TerminalService/Session | capability available; create, output stream, write, resize, close; отсутствующий provider должен явно отказывать |
| ProcessService | Executable, args, рабочий URI; реализация вне editor |
| ScmService | Изменённые URI workspace; реализация Git не включена |
| DebugService | Launch configuration URI / stop; протокол debugger не включён |

Permission-направления: filesystem.read/write, process.execute, network, terminal, scm. Будущий host выдаёт scoped implementations после проверки возможностей платформы. Сейчас нет обещания безопасной загрузки Dart-кода во время выполнения.

Изменение семантики контракта несовместимым образом требует новой apiVersion. packageVersion плагина может меняться независимо. Структурированные результаты language providers будут уточнены до включения executable host; Object? в v1 — намеренно transport-neutral seam, а не завершённый LSP SDK.
