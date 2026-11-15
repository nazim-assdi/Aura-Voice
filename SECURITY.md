# Security and responsible voice use

Aura Voice AI handles account credentials, scripts, audio files and requests to third-party speech/LLM providers. Treat all of these as private data.

## Current controls in code

- Passwords are hashed with Argon2 via pwdlib; plaintext passwords are not stored.
- Access tokens are signed and short-lived. Refresh tokens are stored hashed in the database and rotated on refresh.
- Server-side sessions can be revoked individually or globally. Password change revokes other sessions; account deletion requires a password re-check.
- Browser sessions use HttpOnly cookies; production cookies are Secure and SameSite=None for the separately hosted browser studio, with an Origin allow-list for cookie-authenticated write requests.
- Authenticated routes enforce per-user and per-IP request limits where implemented. Daily TTS, transcription, translation and conversation quotas are reserved before paid provider calls.
- Project and audio asset reads/writes are scoped to the authenticated owner. Audio uploads have file-size and per-account storage caps.
- Cartesia and LLM provider keys are read only by the backend; ephemeral real-time tokens are short-lived.
- Generated speech/dubbing audio responses use private/no-store cache headers and nosniff content-type protection.

## Production prerequisites and gaps

- A durable production PostgreSQL database and a 32+ character JWT secret are mandatory. Without them, account endpoints remain locked. The current Render Postgres resource has not been provisioned because the account requires payment information; no paid database was created.
- Email verification, password reset/recovery and account email change are not implemented. Do not treat an email address as verified.
- Audio bytes are currently stored in Postgres, not private object storage. Enforce the current caps; add object storage, lifecycle/retention policy and backups before broad public use.
- Rate limits are database-backed and help control per-user/IP traffic, but they are not a replacement for WAF/bot controls, spend alerts, observability or provider-level limits. Review proxy IP handling before relying on per-IP limits at larger scale.
- Database schema is currently initialized with SQLAlchemy `create_all`; a versioned migration workflow (for example, Alembic) should be introduced before schema changes are promoted to a mature production deployment.
- Realtime STT/TTS uses an ephemeral provider token. Keep grants and lifetime minimal; do not log the token or audio content.
- LLM and speech providers receive the text/audio required to perform the requested operation. Review provider terms, data retention and regional controls before sending sensitive content.

## Voice permission

Voice profiles and cloning features must be limited to a voice the account owner controls or a voice for which the account owner has explicit authorization from the voice owner. A checkbox alone is not sufficient proof for high-risk use cases.

Before voice enrollment or cloning is enabled, implement:
- Authenticated accounts and ownership checks.
- Clear, purpose-specific consent and durable consent records.
- Revocation and deletion at the voice-profile and source-recording level.
- Access controls, audit events, abuse reporting and rate limits.
- Provenance disclosure for generated or transformed speech.
- Retention limits and secure handling of source recordings.

Do not use Aura Voice AI to impersonate people, deceive listeners, commit fraud, evade identity checks or create non-consensual synthetic speech.

## Data handling

- Do not commit private voice samples, generated user audio, API tokens, JWT secrets or signing keys.
- Use TLS in production and restrict CORS to trusted client origins.
- Keep scripts, voice samples and generated audio out of application logs.
- Define data retention and deletion behavior before enabling public uploads.
- Do not expose Cartesia or LLM keys in Flutter code, web assets, browser storage or public build variables.
- Test account deletion and backups against the configured production database before public launch.

## Reporting

Do not publish exploitable details in a public issue. Contact the repository owner through GitHub's private vulnerability reporting feature when available.
