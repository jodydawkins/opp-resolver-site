# OPP Resolver Website Design

## Purpose

Build a small Sinatra application that demonstrates the complete Open Presence Protocol trust chain:

```text
requested subject -> directory registration -> Presence Document -> verified services
```

The application is a resolver and sample OPP consumer. It does not provide search, profiles, content hosting, registration publishing, persistence, accounts, or new protocol behavior.

## Runtime and dependencies

- Ruby 3.2 or newer.
- Sinatra and ERB for the web application.
- `opp` 0.1.x for subject derivation, signature verification, JSON parsing, and Presence Document verification.
- Ruby standard-library networking through `Net::HTTP`.
- RSpec and Rack::Test for automated tests.
- No database or client-side application framework.

The default directory is `https://directory.openpresenceprotocol.org`. `OPP_DIRECTORY_URL` may override it for development and deployment. The default example subject is `key:sha256:r04mk-KJfvTnlnVSTUpnT283CGbHSWJkFMevj-G72Ts`.

## Application surface

`GET /` renders a form with the example subject prefilled. `POST /resolve` accepts a single exact subject and renders either the complete resolution result or a specific failure state. A shareable result route is not included in the initial release.

The submitted value is stripped of surrounding whitespace and must match the exact OPP subject form `key:sha256:` followed by 43 unpadded Base64url characters. The normalized subject is percent-encoded as one directory path segment before requesting `GET /:subject`.

## Components and boundaries

### Sinatra application

The Sinatra layer owns configuration, parameter handling, HTTP status selection, and ERB rendering. It does not perform protocol verification or network access directly. It constructs a resolver from the configured directory URL and renders the resolver's structured result.

### Resolver

`Resolver` coordinates the trust flow:

1. Validate and normalize the requested subject.
2. Fetch the registration from the configured directory using an encoded path segment.
3. Parse the response with `OPP::JSON.parse`.
4. Verify the registration with `RegistrationVerifier` and the requested subject.
5. Fetch the independently hosted Presence Document from the verified `document_url`.
6. Parse and verify it with `OPP::Presence.verify`.
7. Require the Presence Document subject to equal the requested subject.
8. Return verified services and inspection data only after the entire chain succeeds.

The resolver maps internal exceptions and verification results into explicit application error codes and safe visitor-facing messages. Raw exception details, resolved addresses, and internal network information are never exposed.

### Registration verifier

`RegistrationVerifier` validates Directory Registration 0.2 without adding directory persistence or sequence-comparison behavior. It requires exactly the protocol rules relevant to a resolver:

- All required members exist: `type`, `version`, `subject`, `public_key`, `document_url`, `sequence`, `issued_at`, and `signature`.
- `type` equals `open-presence-directory-registration`.
- `version` equals `0.2`.
- String-typed fields and signature structure have the expected types.
- `sequence` is an integer greater than or equal to zero.
- `issued_at` is a real RFC 3339 UTC timestamp with a `Z` suffix.
- `document_url` is an absolute credential-free HTTPS URL.
- The registration subject equals the requested subject.
- `OPP::Subject.verify!` confirms that the subject derives from `public_key`.
- `OPP::Signature.verify!` confirms the registration signature.

Unknown registration members remain in the signed object and are accepted. This preserves extension compatibility and ensures their values remain authenticated by the generic OPP signature verification.

### Safe HTTP client

`SafeHttpClient` handles both directory and Presence Document GET requests, with stricter destination validation for the untrusted Presence Document URL. It:

- Accepts only absolute HTTPS URLs without embedded credentials.
- Resolves the hostname before connecting and rejects loopback, private, link-local, multicast, unspecified, reserved, and other non-public IP addresses for Presence Document destinations.
- Pins a validated resolved address for the connection while retaining the original hostname for the HTTP `Host` header and TLS hostname verification.
- Uses finite connection and read timeouts.
- Streams response bodies and aborts when the configured byte limit is exceeded, including when `Content-Length` already exceeds the limit.
- Requires a JSON media type (`application/json` or a `+json` subtype).
- Does not follow redirects.
- Converts DNS, TLS, timeout, connection, media-type, and size failures into stable client error categories.

The configured directory is operator-controlled and is required to be an absolute HTTPS base URL. Directory requests still use timeouts, response limits, JSON media-type checks, and no redirects. Private-address rejection is reserved for the directory-provided document destination so local test and development directories remain possible.

## Result and error model

A successful result contains the normalized subject, directory URL, verified registration, verified Presence Document, services, and pretty-printed raw JSON. A failed result contains a stable error code, a safe message, and any verification errors suitable for display. It never marks later trust stages as successful after an earlier failure.

Failures distinguish at least:

- Invalid subject.
- Registration not found.
- Directory unavailable, malformed response, invalid media type, timeout, or oversized response.
- Invalid registration schema, version, signature, derived subject, requested-subject match, timestamp, sequence, or document URL.
- Unsafe, unavailable, malformed, invalid-media-type, timed-out, or oversized Presence Document response.
- Invalid Presence Document signature or schema, structured OPP verification errors, subject mismatch, and expiration.

Directory `404` maps to registration-not-found. Other non-success statuses map to directory-unavailable without exposing the upstream body. Presence Document non-success statuses map to document-unavailable.

## Presentation

The page uses server-rendered semantic HTML with a compact, readable stylesheet. The result is divided into Resolution, Directory Registration, Presence Document, Services, and Raw Documents sections. Verification states use text labels in addition to color.

Services render as links only after complete verification. Unknown service types are displayed normally. Raw registration and Presence Document JSON are HTML-escaped inside collapsed `<details>` elements and never inserted as markup.

## Testing

All behavior is developed test-first. Tests inject fake HTTP behavior and do not contact the public directory or public Presence Documents.

Coverage includes:

- Home page, default example, form submission, safe HTML rendering, and escaped raw JSON.
- Subject validation, normalization, and exact path percent-encoding.
- Successful end-to-end resolution and service rendering.
- Registration schema, version, public key, derived subject, requested-subject equality, signature, sequence, timestamp, and URL validation.
- Directory 404, status failures, malformed JSON, timeouts, and connection failures.
- Presence verification success, structured errors, invalid signature, expiration, and subject mismatch.
- HTTPS and credential requirements, redirect rejection, public-address enforcement, response-size limits, JSON media types, and timeouts.

The final verification runs the complete RSpec suite and starts the Rack application far enough to prove configuration and boot succeed under Ruby 3.2 or newer.

## Documentation

The README documents prerequisites, Bundler setup, local Rack startup, `OPP_DIRECTORY_URL`, the default example subject, project structure, security boundaries, and the distinction between directory discovery and Presence Document authority.

## Acceptance

The implementation is accepted when a visitor can submit the example or another exact OPP subject, see each trust stage, inspect escaped source documents, and view service links only after registration and Presence verification succeed. Every specified failure is presented distinctly without leaking internal network details, and the full automated suite passes without live network dependencies.
