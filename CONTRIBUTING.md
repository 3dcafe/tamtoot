# Contributing to Tamtoot

Thank you for your interest in Tamtoot.

Tamtoot is free and open. **Use it however you like** — copy, modify, study,
ship, fork. Authorship of the original work belongs to **Latin Nikolay**.

## Before you start

1. Read the [README](README.md) and Russian docs in [`docs/ru/`](docs/ru/README.md).
2. Follow the [Code of Conduct](CODE_OF_CONDUCT.md).
3. Keep changes focused: one problem or feature per pull request.

## Development setup

```sh
flutter pub get
flutter test
flutter run -d macos
```

Prefer the Flutter / Dart versions noted in the README.

## What makes a good contribution

- Bug fixes with a failing test when practical.
- Clear UX improvements that match existing Tamtoot patterns.
- Documentation in English and, when relevant, Russian under `docs/ru/`.
- Small diffs. Avoid drive-by refactors unrelated to the change.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Run tests that cover your change (`flutter test` or a focused file).
3. Open a pull request using the template.
4. Describe **why** the change is needed, not only what files moved.

Do not commit secrets, signing keys, API tokens, or personal credentials.

## Issues

- Use the bug or feature templates when possible.
- Include OS, Flutter version, and steps to reproduce for bugs.
- Search existing issues before opening a duplicate.

## License

By contributing, you agree that your contributions are licensed under the same
[MIT License](LICENSE) as the project, with copyright retained by contributors
for their own changes and original authorship of Tamtoot remaining with
Latin Nikolay.
