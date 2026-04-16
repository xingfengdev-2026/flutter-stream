# flutter-stream

Minimal compilable Flutter app used for CI build validation.

## Local build

```bash
flutter pub get
flutter test
flutter build apk --debug
```

## GitHub Actions

Workflow file: `.github/workflows/flutter-build.yml`

It runs on every `push` and `pull_request`, then executes:

1. `flutter pub get`
2. `flutter test`
3. `flutter build apk --debug`
