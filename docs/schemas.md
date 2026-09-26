# Внешние форматы · schema v1

Все JSON-контракты несут `schemaVersion: 1`. Центральный `decodeVersioned` проверяет JSON object и поддерживаемую версию; loader валидирует обязательную семантику и создаёт нормализованную доменную модель. Неизвестные необязательные поля игнорируются. Неподдерживаемая версия возвращает `SchemaException`; bootstrap/command boundary показывает понятное сообщение вместо падения.

v1 — первая опубликованная схема. Схемы v0 не было: данные без версии и `schemaVersion: 0` отвергаются. Сейчас нормализация v1 тестирует defaults; фиктивная миграция не добавлена. При введении v2 нужно добавить DTO v1, переход v1→v2 и fixtures migration tests, сохранив единый version-aware loader.

| Контракт | Обязательные поля кроме schemaVersion | Optional / defaults |
|---|---|---|
| Language manifest | id, name, packageVersion, extensions: string[] | filenames/adapters/brackets/autoClosingPairs=[]; comments/indentation/icons={} |
| Syntax | rules: [{pattern, scope}] | Пустой список разрешён; приоритет правил по порядку при одинаковом начале совпадения |
| Snippets | — | snippets={} |
| Theme | id, name, packageVersion, dark, colors | fontFamily=monospace, iconTheme=material |
| Keybindings | bindings: [{key, command}] | Неуказанные сочетания берутся из default preset |
| Layout | root | hidden=[]; layoutId метаданные |
| Settings | — | user={}, workspace={}, effective через defaults |
| Session | documents: [{name,text}] | uri/savedText=null, recentWorkspaces=[], activeIndex — последний документ при отсутствии |
| Installed package | manifest, syntax (JSON strings) | snippets=null |
| Package index | ids: string[] | — |

`schemaVersion` — формат, `packageVersion` — релиз конкретного пакета, `apiVersion` — совместимость executable API. Это независимые числа/версии.

## Language package

См. реальные fixtures `assets/languages/dart/` и `assets/languages/csharp/`. В v1 синтаксис — regex rules для одной строки; scope выбирает цвет темы. Пакет не выполняет код. Неизвестный scope получает foreground. Индентация, комментарии, скобки, пары автозакрытия, snippets, icons и adapters доступны нормализованной модели как данные; автоматическое применение всех подсказок не заявляется.

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

## Persistence

Ключи SharedPreferences имеют префикс `tamtoot.`: settings, layout, keybindings, session, language.index, language.<id>. Данные локальны. Сессия содержит текст открытых документов; это восстанавливаемые черновики, а не замена файловой системы проекта. Можно очистить данные приложения стандартными средствами ОС/браузера.
