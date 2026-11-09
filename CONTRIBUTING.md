# Contributing

Thanks for helping build Aura Voice AI.

## Development rules

- Keep the Flutter UI, API contracts and speech providers separated.
- Add HTTP features under `backend/app/api/v1/`; do not silently change existing response shapes.
- A speech provider must report an accurate readiness state and must never return placeholder audio as if it were generated.
- Add tests for every API behavior and document required environment variables.
- Review model licensing, deployment limits, language coverage and privacy implications before adding an engine.
- Do not commit model weights, private recordings, credentials or user-generated audio.

## Local checks

Backend:

```bash
cd backend
python -m pip install -r requirements-dev.txt
pytest
```

Flutter:

```bash
cd app
flutter pub get
dart format lib test
flutter analyze
flutter test
```

## Pull requests

Describe the user-facing change, platforms tested, model/provider added (if any), known limitations, and privacy/security impact.
