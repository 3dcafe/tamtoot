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

В GitHub откройте **Actions → Build signed Android AAB** или **Build Android APK → Run workflow**. После завершения скачайте артефакт. Оба workflow временно восстанавливают ключ на runner, собирают release-сборку и не добавляют ключ или пароли в репозиторий. Подписанный APK можно ставить поверх предыдущей установки с тем же upload-ключом.

Приватный API-ключ RuStore храните только в GitHub Secrets под именем `RUSTORE_PRIVATE_KEY`. Не помещайте его в YAML, исходный код, `.tamtoot` или историю Git.

## Автоматическая загрузка в RuStore

Workflow **Build and upload AAB to RuStore** собирает подписанный AAB, получает временный токен RuStore, создаёт черновик версии и сразу загружает в него файл. При запуске можно дополнительно отправить черновик на модерацию. Режим `MANUAL` оставляет публикацию после модерации под вашим контролем, а `INSTANTLY` публикует одобренную версию автоматически.

Добавьте ещё три GitHub Secrets:

| Секрет | Значение |
| --- | --- |
| `RUSTORE_KEY_ID` | ID нового API-ключа из RuStore Консоли |
| `RUSTORE_PRIVATE_KEY` | новый приватный ключ RuStore в Base64 |
| `RUSTORE_DEVELOPER_EMAIL` | контактный email разработчика для черновика |

При создании API-ключа разрешите этому ключу доступ к приложению `dev.tamtoot.tamtoot` и методам создания версии, загрузки AAB и отправки версии на модерацию. Сначала вручную добавьте приложение и опубликуйте хотя бы одну активную версию: API RuStore не создаёт первую активную публикацию. Перед первой API-загрузкой AAB также добавьте в RuStore Консоль сертификат ключа загрузки из `android/signing/tamtoot-upload-certificate.pem` и настройте подпись AAB.

После настройки откройте **Actions → Build and upload AAB to RuStore → Run workflow**. Укажите уникальный увеличивающийся `version_code` либо оставьте поле пустым, чтобы использовать номер запуска GitHub. Заполните «Что нового», выберите режим публикации и решите, отправлять ли сборку на модерацию сразу. Даже после успешной загрузки AAB сохраняется отдельным GitHub-артефактом на 14 дней.

Workflow следует официальной последовательности RuStore: [получение временного токена](https://www.rustore.ru/help/work-with-rustore-api/api-authorization-token), [создание черновика](https://www.rustore.ru/help/work-with-rustore-api/api-upload-publication-app/create-draft-version), [загрузка AAB](https://www.rustore.ru/help/work-with-rustore-api/api-upload-publication-app/apk-file-upload/file-upload-aab) и, если включена опция, [отправка на модерацию](https://www.rustore.ru/help/work-with-rustore-api/api-upload-publication-app/send-draft-app-for-moderation).
