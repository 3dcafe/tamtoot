# Внешние форматы · schema v1

Версионируемые JSON-контракты Tamtoot несут `schemaVersion: 1`. Центральный `decodeVersioned` проверяет JSON object и поддерживаемую версию для основных IDE-форматов; специализированные loaders профилей и Kanban выполняют такую же проверку самостоятельно. Loader валидирует обязательную семантику и создаёт нормализованную доменную модель. Неизвестные необязательные поля игнорируются там, где это разрешает конкретный loader. Неподдерживаемая версия возвращает понятную ошибку вместо падения.

Исключение — `.tamtoot/mcp.json`: он следует внешней форме `mcpServers` и сейчас не содержит Tamtoot `schemaVersion`. Ответы model APIs, MCP JSON-RPC и hook JSON являются транспортными сообщениями, а не сохраняемыми схемами Tamtoot.

v1 — первая опубликованная схема. Схемы v0 не было: данные без версии и `schemaVersion: 0` отвергаются. Сейчас нормализация v1 тестирует defaults; фиктивная миграция не добавлена. При введении v2 нужно добавить DTO v1, переход v1→v2 и fixtures migration tests, сохранив единый version-aware loader.

| Контракт | Обязательные поля кроме schemaVersion | Optional / defaults |
|---|---|---|
| Language manifest | id, name, packageVersion, extensions: string[] | filenames/adapters/brackets/autoClosingPairs=[]; comments/indentation/icons={} |
| Syntax | rules: [{pattern, scope}] или region rules | Пустой список разрешён; приоритет правил по порядку при одинаковом начале совпадения |
| Snippets | — | snippets={} |
| Theme | id, name, packageVersion, dark, colors | fontFamily=monospace, iconTheme=material |
| Keybindings | bindings: [{key, command}] | Неуказанные сочетания берутся из default preset |
| Layout | root | hidden=[]; layoutId метаданные |
| Settings | — | user={}, workspace={}, effective через defaults |
| Session | documents: [{name,text}] | uri/savedText=null, recentWorkspaces=[], activeIndex — последний документ при отсутствии |
| Installed package | manifest, syntax (JSON strings) | snippets=null |
| Package index | ids: string[] | — |
| Model profile | id, name, provider, model, systemPrompt, userTemplate, parameters | apiFormat=chat-completions для старого v1; endpoint="" |
| Agent Kanban | cards: object[] | Пустая доска разрешена; поля карточки имеют безопасные defaults |
| HTTP request | version, name, method, url | headers/query/attachments=[]; body=none; auth=inherit |
| HTTP environment | version, variables | auth=none |

`schemaVersion` — формат, `packageVersion` — релиз конкретного пакета, `apiVersion` — совместимость executable API. Это независимые числа/версии.

## Language package

Встроенные пакеты: `assets/languages/{dart,csharp,html,javascript}/`. Синтаксис поддерживает прежние `{pattern, scope}` и регионы `{begin, end, scope}`. Регион переносит состояние между строками; `escape` пропускает экранированные последовательности, `nested: true` учитывает вложенные начала (комментарии Dart), `endCapture` берёт буквальный закрывающий разделитель из группы begin (raw strings C#), `contentRules` задаёт вложенные правила (атрибуты и строки внутри HTML-тегов). Глубина правил ограничена 8; отсутствующие end, некорректные regex и группы отклоняются. Scope выбирает цвет темы. Пакет не выполняет код. Неизвестный scope получает foreground. Индентация, комментарии, скобки, пары автозакрытия, snippets, icons и adapters доступны нормализованной модели как данные; автоматическое применение всех подсказок не заявляется.

## Theme

`colors` содержит `#RRGGBB`. Обязательны shell, panel, editor, foreground, muted, border, accent, selection, currentLine. Default-пакеты также включают keyword/string/comment/number/type/error, semantic.type, terminal.background/terminal.foreground. Все цвета превращаются в ARGB int независимо от Flutter.

## Layout

Узлы имеют уникально задаваемый приложением `id`. Типы:

- `split`: axis=horizontal|vertical, ratio (нормализуется в 0.1–0.9), first, second.
- `tabs`: panels:string[], active; отсутствующий active заменяется первым известным panel.
- `panel`: panel id.
- `documents`: точка вставки document group.

Устаревшие/неизвестные панели отфильтровываются. Пустые ветки схлопываются; отсутствие области документов восстанавливает default. Неизвестный тип узла — неизвестная обязательная семантика, поэтому отклоняется. Глубина ограничена 32 для безопасного восстановления повреждённых данных.

## Keybindings

Порядок модификаторов: `ctrl+meta+alt+shift+key`. Регистр игнорируется. Примеры: ctrl+s, meta+shift+z, shift+arrow left. Реестр разрешает строку в command ID; обработчик клавиатуры не вызывает save напрямую. Ненайденная команда сообщается через command error boundary.

Theme is an IDE-wide user preference: its effective value comes from the user layer (or the default), not a workspace override. Other editor settings retain defaults → user → workspace precedence.

## Persistence

Ключи SharedPreferences имеют префикс `tamtoot.`: settings, layout, keybindings, session, language.index, language.<id>. Данные локальны. Сессия содержит текст открытых документов; это восстанавливаемые черновики, а не замена файловой системы проекта. Можно очистить данные приложения стандартными средствами ОС/браузера.

## Model profile v1

Путь: `.tamtoot/agents/models/<id>.json`. `id` состоит из lowercase ASCII letters, numbers, `_` и `-`, длина 1–64. Обязательные строки: `id`, `name`, `provider`, `model`, `systemPrompt`, `userTemplate`. `parameters` — JSON object. `apiFormat`: `ollama`, `chat-completions`, `responses` или `anthropic`. `endpoint` — HTTPS URL без credentials/query/fragment; HTTP разрешён для localhost и private IPv4.

Допустимые template variables: `task`, `file_path`, `file`, `selection`. Credentials и transport-owned keys в `parameters` запрещены рекурсивно. API key в JSON не хранится. Общие текстовые инструкции лежат отдельно в `.tamtoot/agents/instructions.md` и добавляются к system prompt во время запуска.

## Agent Kanban v1

Путь: `.tamtoot/agents/kanban.json`. Корень содержит `schemaVersion: 1` и `cards`. Поля карточки: `id`, `title`, `description`, `status`, `dependencies`, `profileId`, `worktree`, `lastOutput`, `autoCommit`, `autoPr`. Status: `todo`, `inProgress`, `review`, `done`. ID уникален и следует тем же ограничениям, что ID профиля. Dependency обязан ссылаться на другую существующую карточку; self-dependency запрещена. Поля `autoCommit` и `autoPr` сохранены для будущей автоматизации и сейчас не запускают действие.

## MCP configuration

Путь: `.tamtoot/mcp.json`. Корень: `{ "mcpServers": { "name": { ... } } }`. Server name: ASCII letters, numbers, `_`, `-`, длина 1–64. Transport `stdio` требует `command` и допускает string array `args`. Transport `streamableHttp` требует безопасный `url` и допускает string-to-string `headers`. Общие поля: `disabled` и `timeoutSeconds` в диапазоне 1–600. При отсутствии `type` он выводится из наличия `command`. Формат намеренно не объявлен Tamtoot schema v1.

## HTTP Requests v1

Общие запросы проекта хранятся в `.tamtoot/requests/**/*.json`. В отличие от
остальных локальных метаданных `.tamtoot`, эти файлы, соседняя Markdown-документация
и `.tamtoot/environment.json` отображаются в Git UI и предназначены для коммита.
Секреты хранятся только в `.tamtoot/environment.local.json`, который исключён из Git.

Корень запроса содержит `version: 1`, `name`, `method`, `url`, массивы `headers` и
`query`, объект `body`, объект `auth` и необязательный массив `attachments`. Method:
`GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`. Body type: `none`, `json`,
`text`, `form`. Auth mode: `inherit`, `none`, `bearer`. Каждый header/query имеет
`key`, `value`, `enabled`; Markdown attachment имеет `type: markdown` и относительный
`path` рядом с запросом. Пути с `..`, абсолютные пути и другие типы вложений запрещены.

Environment содержит `version: 1`, string-to-string `variables` и общий `auth` с
типом `none` или `bearer`. Для общего bearer рекомендуется `{{token}}`; фактическое
значение находится в локальных variables. При выполнении приоритет значений:
runtime → local secret → shared project. Шаблоны `{{name}}` разрешаются в URL,
параметрах, заголовках, body и bearer token; отсутствующая переменная завершает
конкретный запрос ошибкой до сетевой отправки.

## Hook response и CLI events

Hook может вернуть пустой stdout или object с `cancel: bool`, `errorMessage: string`, `contextModification: string`. Это одноразовый IPC-контракт, не persistence schema.

`ide-agent --json` пишет JSON Lines. Обычное событие содержит `type`, `text`, `ts` (Unix milliseconds) и необязательный `data`. Финальный result содержит `success`, `text`, `iterations`, `ts`. Формат предназначен для автоматизации текущей версии CLI; отдельный `schemaVersion` пока не зафиксирован.

## Workspace `.tamtoot`

Локальная структура и security-поведение подробно описаны в [agents.md](agents.md). Встроенный Git UI исключает локальные данные `.tamtoot`, но включает HTTP requests и общий request environment. Это не заменяет `.gitignore` для внешнего Git-клиента. Secrets нельзя добавлять в model profiles; MCP headers хранятся verbatim и требуют отдельной осторожности.
