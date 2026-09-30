# Подписанный AAB для RuStore

[← Оглавление](README.md)

Для публикации используется постоянный upload-ключ. Локальные файлы находятся в `android/signing/` и `android/key.properties`; оба пути исключены из Git. Скопируйте каталог с ключом и паролями в защищённое хранилище. Без этого ключа следующую версию приложения может быть невозможно установить как обновление.

Приватный ключ, отправленный в чат или опубликованный в другом месте, следует считать раскрытым. Отзовите его в кабинете RuStore и создайте новый токен. Токен API RuStore не является Android keystore и не используется для подписи AAB.

## Локальная сборка

После создания ключа и `android/key.properties` выполните:

```sh
flutter build appbundle --release
```

Готовый файл: `build/app/outputs/bundle/release/app-release.aab`. Проверьте отпечатки сертификата из `android/signing/tamtoot-upload-fingerprints.txt`, затем загрузите AAB в кабинет RuStore.

## Секреты GitHub Actions

Откройте репозиторий GitHub: **Settings → Secrets and variables → Actions → New repository secret**. Создайте четыре секрета:

| Секрет | Значение |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | содержимое keystore в Base64 одной строкой |
| `ANDROID_KEYSTORE_PASSWORD` | пароль хранилища |
| `ANDROID_KEY_ALIAS` | псевдоним ключа, по умолчанию `tamtoot` |
| `ANDROID_KEY_PASSWORD` | пароль ключа |

На macOS строку Base64 можно получить без создания публичного файла:

```sh
base64 < android/signing/tamtoot-upload.jks | tr -d '\n'
```

На Linux:

```sh
base64 -w 0 android/signing/tamtoot-upload.jks
```

В GitHub откройте **Actions → Build signed Android AAB → Run workflow**. После завершения скачайте артефакт **tamtoot-android-aab**. Workflow временно восстанавливает ключ на runner, собирает release AAB и не добавляет ключ или пароли в репозиторий.

Для будущей автоматической отправки в RuStore сохраните новый приватный токен отдельным секретом GitHub, например `RUSTORE_PRIVATE_KEY`. Не помещайте его в YAML, исходный код, `.tamtoot` или историю Git.
