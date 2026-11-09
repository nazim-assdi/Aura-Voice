# Security and responsible voice use

## Voice permission

Voice profiles and cloning features must be limited to a voice the account owner controls or a voice for which the account owner has explicit authorization from the voice owner. A checkbox alone is not sufficient proof for high-risk use cases.

Before voice enrollment or cloning is enabled, the implementation must include:

- Authenticated accounts and ownership checks.
- Clear, purpose-specific permission and consent records.
- A way for the voice owner to revoke permission and request deletion.
- Access controls, audit events, abuse reporting and rate limits.
- Provenance disclosure for generated or transformed speech.
- Retention limits and secure handling of source recordings.

Do not use Aura Voice AI to impersonate people, deceive listeners, commit fraud, evade identity checks, or create non-consensual synthetic speech.

## Data handling

- Do not commit private voice samples, generated user audio, model weights, API tokens or signing keys.
- Use TLS in production and restrict CORS to known client origins.
- Keep audio out of application logs.
- Document storage location, retention and deletion behavior before enabling uploads.
- Treat model providers as data processors and review their terms before sending user audio.

## Reporting

Do not publish exploitable details in a public issue. Contact the repository owner through GitHub's private vulnerability reporting feature when available.
