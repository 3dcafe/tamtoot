# Установка и первый запуск

[← Оглавление](README.md)

## Требования

Проект проверяется с Flutter 3.44.0 и Dart 3.12.0. Flutter SDK может находиться в любой директории: добавьте его каталог `bin` в `PATH`.

```sh
flutter pub get
flutter devices
flutter run -d <device-id>
```

Примеры целей:

```sh
flutter run -d windows
flutter run -d macos
flutter run -d chrome
```

Перед отправкой изменений используются следующие проверки:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --release
```

Сборки для конкретной настольной платформы создаются на этой платформе. Например, Windows-приложение собирается на Windows, а macOS-приложение — на macOS.

## Первый запуск

Откройте проект через **File → Open project…**. При следующих запусках Tamtoot пытается открыть последний проект из истории. Если каталог удалён или недоступен, IDE оставляет дерево проекта пустым и не создаёт демонстрационные вкладки.

Открытые документы и несохранённые черновики восстанавливаются отдельно от файлов на диске. Сохранение сессии выполняется после небольшой паузы и при уходе приложения в фон. Чтобы записать текущий документ в проект, используйте **File → Save** или `Ctrl/⌘+S`.

## Сборка APK в GitVerse

Workflow [Build Android APK](../../.gitverse/workflows/build-apk.yml) запускается при отправке в `master`, для тегов `v*` и вручную через **CI/CD → Build Android APK → Run workflow**.

Процесс устанавливает Java, Android SDK и закреплённую версию Flutter, затем проверяет форматирование, запускает анализатор и тесты, собирает release APK и публикует артефакт **tamtoot-apk**. Срок хранения артефакта — 14 дней.

Текущая Android-сборка подписывается отладочным ключом и предназначена для тестирования. Для публикации в магазине нужен постоянный release-ключ, корректные версия и идентификатор приложения. Секреты подписи не должны храниться в репозитории.

## Сборка Windows в GitHub Actions

Workflow `.github/workflows/build-windows.yml` использует Windows runner GitHub и собирает каталог `build/windows/x64/runner/Release/` в артефакт **tamtoot-windows** со сроком хранения 14 дней. Он доступен для ручного запуска через **Actions → Build Windows exe → Run workflow**.

При восстановлении workflow в пересозданном репозитории он один раз запускается от изменения самого файла workflow. Обычные изменения исходного кода не запускают Windows runner автоматически, чтобы не расходовать минуты сборки; для них используйте **Run workflow**.

GitVerse Cloud предоставляет только Linux runner и не может собирать Windows-приложение. Для Windows на GitVerse нужен собственный Windows runner; готовый сценарий находится в `.gitverse/workflows/build-windows.yml`.

## Сборка Android в GitHub Actions

Workflow `.github/workflows/build-android-apk.yml` создаёт артефакт **tamtoot-apk** и доступен через **Actions → Build Android APK → Run workflow**. После пересоздания репозитория изменение самого workflow запускает его один раз, чтобы GitHub снова зарегистрировал действие. Обычные изменения кода запускаются вручную.

## Основные сочетания клавиш

| Действие | Windows/Linux | macOS |
| --- | --- | --- |
| Сохранить | `Ctrl+S` | `⌘S` |
| Отменить | `Ctrl+Z` | `⌘Z` |
| Повторить | `Ctrl+Shift+Z` | `⌘Shift+Z` |
| Найти в документе | `Ctrl+F` | `⌘F` |
| Найти в проекте | `Ctrl+Shift+F` | `⌘Shift+F` |
| Палитра команд | `Ctrl+Shift+P` | `⌘Shift+P` |
