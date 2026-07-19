# OPP Resolver

OPP Resolver is a small Sinatra application that demonstrates the complete Open Presence Protocol resolution flow:

```text
subject -> directory registration -> Presence Document -> verified services
```

It lets a visitor resolve an exact cryptographic subject without installing a CLI. The result makes every trust boundary visible: a directory discovers a signed registration, but the independently hosted and signed Presence Document remains authoritative.

## Requirements

- Ruby 3.2 or newer
- Bundler

The application currently pins `opp` 0.1.0 to a reviewed commit in `jodydawkins/opp-ruby` because that version has not yet been published to RubyGems. `Gemfile.lock` records the exact commit and every transitive dependency.

## Setup

Install dependencies:

```bash
bundle install
```

Start the Rack application:

```bash
bundle exec rackup
```

Then open [http://localhost:9292](http://localhost:9292). The home page is prefilled with this real example subject:

```text
key:sha256:r04mk-KJfvTnlnVSTUpnT283CGbHSWJkFMevj-G72Ts
```

Run the test suite:

```bash
bundle exec rspec
```

Tests use injected HTTP fakes and never contact the public directory or public Presence Documents.

## Configuration

Production uses the public reference directory by default:

```text
https://directory.openpresenceprotocol.org
```

Set `OPP_DIRECTORY_URL` to use another credential-free HTTPS directory base URL:

```bash
OPP_DIRECTORY_URL=https://directory.example bundle exec rackup
```

No database, secrets, accounts, or persistent application state are required.

## Trust flow

For each submitted exact subject, the resolver:

1. Trims surrounding whitespace and validates the `key:sha256:` subject syntax.
2. Percent-encodes the complete subject as one directory path segment.
3. Requests the current Directory Registration with `GET /:subject`.
4. Parses and validates Directory Registration 0.2.
5. Confirms that the registration subject equals the requested subject and derives from its public key.
6. Verifies the complete registration with `OPP::Signature.verify!`.
7. Retrieves the independently hosted Presence Document from the verified `document_url`.
8. Verifies it with `OPP::Presence.verify`, including schema, timestamps, subject derivation, and signature.
9. Requires the Presence Document subject to equal the original requested subject.
10. Displays services only after every preceding check succeeds.

The directory is a discovery service. It does not host profiles, define services, or become the authority for presence data.

## Directory Registration checks

`OppResolver::RegistrationVerifier` enforces the resolver-relevant Directory Registration 0.2 rules:

- all required members and expected field types;
- the registration type and supported version;
- non-negative integer sequence values;
- real RFC 3339 UTC `issued_at` timestamps;
- absolute credential-free HTTPS document URLs;
- requested-subject equality;
- public-key validity and derived-subject equality; and
- Ed25519 signature structure and cryptographic verification.

Unknown registration members remain in the signed object and are accepted. Sequence persistence and replay comparisons belong to the directory server, not this resolver.

## Safe document retrieval

`OppResolver::SafeHttpClient` treats the directory-provided Presence Document URL as untrusted input. It:

- permits only absolute credential-free HTTPS URLs;
- resolves and rejects loopback, private, link-local, multicast, reserved, documentation, and otherwise non-public destinations;
- rejects a hostname if any DNS answer is unsafe;
- pins the validated address while retaining the original host for HTTP and TLS verification;
- uses finite connection and read timeouts;
- streams into a fixed response-size limit;
- accepts successful JSON media types only; and
- never follows redirects.

Network, DNS, TLS, and timeout details are converted into stable visitor-facing failures rather than exposed in responses.

The directory URL is operator-controlled, so directory requests may target a local HTTPS service during development. They still receive timeouts, response limits, JSON checks, and redirect rejection.

## Project structure

```text
app.rb                              Sinatra routes and dependency wiring
config.ru                           Rack entry point
lib/opp_resolver/result.rb          Immutable result contract
lib/opp_resolver/resolver.rb        Resolution orchestration
lib/opp_resolver/registration_verifier.rb
                                    Directory Registration 0.2 verification
lib/opp_resolver/safe_http_client.rb
                                    Bounded HTTPS retrieval and SSRF defenses
views/                              Server-rendered ERB pages
public/styles.css                   Responsive protocol-inspector presentation
spec/                               Network-independent RSpec suite
```

## Non-goals

The initial resolver does not provide alias lookup, search, profiles, aggregation, saved history, accounts, registration editing, federation, a database, or client-side protocol verification.

## License

Apache-2.0. See [LICENSE](LICENSE).
