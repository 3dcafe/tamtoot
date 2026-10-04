# Публикация Google Play из GitHub Actions

Workflow `.github/workflows/publish-google-play.yml` запускается вручную: Actions → Publish Google Play production → Run workflow. Он собирает подписанный AAB и отправляет релиз сразу в production с `status: completed`, без внутреннего тестирования. Push сам публикацию не запускает. Локально ничего собирать не нужно.

## Secrets

GitHub → Settings → Secrets and variables → Actions → New repository secret:

| Имя | Значение |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 содержимого keystore с upload key, принятым Google Play для этого приложения |
| `ANDROID_KEYSTORE_PASSWORD` | Пароль keystore |
| `ANDROID_KEY_ALIAS` | Alias upload key внутри keystore |
| `ANDROID_KEY_PASSWORD` | Пароль этого ключа |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | Полное содержимое JSON-ключа сервисного аккаунта, без Base64 |

Первые четыре secrets совпадают с используемыми в существующей сборке AAB: если там нужный Google Play upload key, повторно добавлять их не требуется. На macOS Base64 можно скопировать в буфер командой `base64 -i /absolute/path/to/upload-keystore.jks | tr -d '\n' | pbcopy`. Ключи не добавляются в репозиторий.

## Доступ Google

В Google Cloud включите Google Play Android Developer API, создайте сервисный аккаунт и его JSON-ключ. Email из `client_email` пригласите в Play Console → Users and permissions, предоставьте доступ к Tamtoot и разрешение выпуска в production. JSON вставьте в соответствующий secret. Package name workflow: `dev.tamtoot.tamtoot`; он должен совпадать с уже опубликованным приложением.

Версия берётся из `pubspec.yaml`. Число после `+` должно быть больше всех ранее загруженных versionCode. При запуске можно указать `version_code`, чтобы переопределить это число только для сборки CI. Автоматический счётчик workflow не используется, чтобы не конфликтовать с прежними ручными публикациями.

Google может отправить обновление на проверку. `completed` обозначает полный rollout после допуска к публикации, а не обход проверки. Если в Play Console включена Managed publishing, одобренные изменения могут ожидать ручной публикации. Отдельные состояния аккаунта/приложения могут требовать действий в консоли; workflow не меняет настройки аккаунта.

AAB сохраняется в artifacts как `tamtoot-google-play-aab` на 14 дней, даже если последующая отправка в Google завершится ошибкой. Workflow не запускает отдельные анализаторы или тесты.

Источники: [Google Play API setup](https://developers.google.com/android-publisher/getting_started), [upload-google-play action](https://github.com/r0adkll/upload-google-play).
