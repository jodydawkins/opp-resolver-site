# OPP Resolver Website Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Sinatra website that safely resolves an exact OPP subject through a verified Directory Registration and verified Presence Document, then displays trusted service endpoints and inspection details.

**Architecture:** A thin Sinatra layer delegates resolution to `OppResolver::Resolver`. Registration rules live in `OppResolver::RegistrationVerifier`, while bounded network access lives in `OppResolver::SafeHttpClient`; each returns stable domain results or typed errors. ERB views render only the structured result, and services are exposed only after the complete trust chain succeeds.

**Tech Stack:** Ruby 3.2+, Sinatra 4, ERB, Rack, `opp` 0.1.x, Net::HTTP, RSpec 3.13, Rack::Test 2.

## Global Constraints

- Default directory: `https://directory.openpresenceprotocol.org`.
- Configurable directory environment variable: `OPP_DIRECTORY_URL`.
- Default example subject: `key:sha256:r04mk-KJfvTnlnVSTUpnT283CGbHSWJkFMevj-G72Ts`.
- Directory Registration version: `0.2`.
- Presence Documents and service URLs must be absolute credential-free HTTPS URLs.
- Presence Document requests must reject non-public destinations, redirects, oversized responses, non-JSON media types, and finite-timeout failures.
- Tests must not contact live directory or Presence Document services.
- No database, accounts, search, history, registration publishing, or JavaScript application framework.

---

## File structure

- `Gemfile`: runtime and test dependencies.
- `.ruby-version`: required Ruby major/minor baseline.
- `config.ru`: Rack entry point.
- `app.rb`: Sinatra routes, dependency construction, and HTTP rendering decisions.
- `lib/opp_resolver/result.rb`: immutable success/failure result contract used by resolver and views.
- `lib/opp_resolver/registration_verifier.rb`: Directory Registration 0.2 validation and cryptographic checks.
- `lib/opp_resolver/safe_http_client.rb`: bounded HTTPS GET behavior and SSRF destination checks.
- `lib/opp_resolver/resolver.rb`: subject validation, directory path construction, orchestration, and error mapping.
- `views/layout.erb`: shared page shell.
- `views/index.erb`: subject form and trust-flow explanation.
- `views/result.erb`: staged success/failure output, services, and raw JSON.
- `public/styles.css`: responsive presentation with text-visible verification states.
- `spec/spec_helper.rb`: RSpec configuration and deterministic OPP signing helpers.
- `spec/app_spec.rb`: route, rendering, and escaping behavior.
- `spec/registration_verifier_spec.rb`: registration validation contract.
- `spec/safe_http_client_spec.rb`: HTTP safety, limits, and error categorization.
- `spec/resolver_spec.rb`: orchestration, percent encoding, verification, and result mapping.
- `README.md`: setup, configuration, architecture, trust flow, and security notes.

---

### Task 1: Bootable Sinatra application and home page

**Files:**
- Create: `Gemfile`
- Create: `.ruby-version`
- Create: `config.ru`
- Create: `app.rb`
- Create: `views/layout.erb`
- Create: `views/index.erb`
- Create: `public/styles.css`
- Create: `spec/spec_helper.rb`
- Create: `spec/app_spec.rb`

**Interfaces:**
- Consumes: no application interfaces.
- Produces: `OppResolver::App`, `GET /`, `POST /resolve`, and `settings.resolver_factory` for test injection.

- [ ] **Step 1: Add dependency and test configuration files**

Create `Gemfile`:

```ruby
source "https://rubygems.org"

ruby ">= 3.2"

gem "opp", "~> 0.1.0"
gem "sinatra", "~> 4.1"

group :test do
  gem "rack-test", "~> 2.2"
  gem "rspec", "~> 3.13"
end
```

Create `.ruby-version` containing `3.2` and `config.ru`:

```ruby
require_relative "app"

run OppResolver::App
```

Create `spec/spec_helper.rb`:

```ruby
ENV["RACK_ENV"] = "test"

require "rack/test"
require "rspec"
require_relative "../app"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
```

- [ ] **Step 2: Write failing home-page and form-submission tests**

Create `spec/app_spec.rb` with tests asserting that `GET /` returns 200, contains `Resolve an OPP Subject`, and pre-fills the exact example subject. Add a fake resolver result and assert `POST /resolve` passes the submitted `subject` to a resolver created by `settings.resolver_factory`.

```ruby
RSpec.describe OppResolver::App do
  include Rack::Test::Methods

  let(:app) { described_class }

  it "renders the resolver form with the example subject" do
    get "/"

    expect(last_response).to be_ok
    expect(last_response.body).to include("Resolve an OPP Subject")
    expect(last_response.body).to include(OppResolver::App::EXAMPLE_SUBJECT)
  end

  it "submits the exact subject to the configured resolver" do
    resolver = instance_double("OppResolver::Resolver")
    allow(resolver).to receive(:resolve).with("key:sha256:test").and_return(
      OppResolver::Result.failure(:invalid_subject, "Enter a valid OPP subject.")
    )
    app.set :resolver_factory, -> { resolver }

    post "/resolve", subject: "key:sha256:test"

    expect(last_response.status).to eq(422)
    expect(last_response.body).to include("Enter a valid OPP subject.")
  ensure
    app.set :resolver_factory, app.default_resolver_factory
  end
end
```

- [ ] **Step 3: Run the focused test and verify RED**

Run: `bundle exec rspec spec/app_spec.rb`

Expected: FAIL because `OppResolver::App` and `OppResolver::Result` do not exist.

- [ ] **Step 4: Add the minimal Sinatra shell and views**

Implement `app.rb` with namespaced modular Sinatra, constants for the directory and example subject, a configurable resolver factory, `GET /`, and `POST /resolve`. Initially define the small result contract required by the test; Task 2 moves it to its dedicated file. Render a semantic layout and index form. Add a compact stylesheet with a centered content column, readable system font stack, responsive form, focus states, and reusable `.status`, `.card`, `.error`, and `.raw-document` classes.

```ruby
require "sinatra/base"

module OppResolver
  Result = Data.define(:ok?, :error_code, :message, :details) do
    def self.failure(code, message, details = {})
      new(false, code, message, details.freeze)
    end
  end

  class App < Sinatra::Base
    DEFAULT_DIRECTORY_URL = "https://directory.openpresenceprotocol.org"
    EXAMPLE_SUBJECT = "key:sha256:r04mk-KJfvTnlnVSTUpnT283CGbHSWJkFMevj-G72Ts"

    def self.default_resolver_factory
      -> { raise "resolver is not configured yet" }
    end

    set :resolver_factory, default_resolver_factory

    get "/" do
      erb :index
    end

    post "/resolve" do
      @result = settings.resolver_factory.call.resolve(params.fetch("subject", ""))
      status 422 unless @result.ok?
      erb :result
    end
  end
end
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run: `bundle exec rspec spec/app_spec.rb`

Expected: 2 examples, 0 failures.

- [ ] **Step 6: Commit the application shell**

```bash
git add Gemfile .ruby-version config.ru app.rb views public spec/spec_helper.rb spec/app_spec.rb
git commit -m "feat: add Sinatra resolver shell"
```

---

### Task 2: Stable resolver result contract

**Files:**
- Create: `lib/opp_resolver/result.rb`
- Modify: `app.rb`
- Modify: `spec/app_spec.rb`
- Create: `spec/result_spec.rb`

**Interfaces:**
- Consumes: Ruby `Data`.
- Produces: `OppResolver::Result.success(details)`, `.failure(code, message, details = {})`, `#ok?`, `#success?`, `#failure?`, `#error_code`, `#message`, and `#details`.

- [ ] **Step 1: Write failing result-contract tests**

```ruby
RSpec.describe OppResolver::Result do
  it "creates an immutable success result" do
    result = described_class.success(subject: "key:sha256:value")

    expect(result).to be_success
    expect(result.error_code).to be_nil
    expect(result.details).to eq(subject: "key:sha256:value")
    expect { result.details[:subject].replace("changed") }.to raise_error(FrozenError)
  end

  it "creates a typed failure result" do
    result = described_class.failure(:invalid_subject, "Enter a valid OPP subject.")

    expect(result).to be_failure
    expect(result.error_code).to eq(:invalid_subject)
    expect(result.message).to eq("Enter a valid OPP subject.")
  end
end
```

- [ ] **Step 2: Run and verify RED**

Run: `bundle exec rspec spec/result_spec.rb`

Expected: FAIL because the temporary result lacks the required success and predicate methods.

- [ ] **Step 3: Implement and require the dedicated result**

Move the result type into `lib/opp_resolver/result.rb`. Deep-freeze nested hashes, arrays, and strings at construction so templates cannot mutate verified data. Require it from `app.rb` and remove the temporary definition.

```ruby
module OppResolver
  Result = Data.define(:success?, :error_code, :message, :details) do
    def self.success(details)
      new(true, nil, nil, freeze_value(details))
    end

    def self.failure(code, message, details = {})
      new(false, code, message, freeze_value(details))
    end

    def failure? = !success?
    alias ok? success?

    def self.freeze_value(value)
      case value
      when Hash then value.to_h { |key, item| [key, freeze_value(item)] }.freeze
      when Array then value.map { |item| freeze_value(item) }.freeze
      when String then value.dup.freeze
      else value.freeze
      end
    end
    private_class_method :freeze_value
  end
end
```

- [ ] **Step 4: Run result and app tests and verify GREEN**

Run: `bundle exec rspec spec/result_spec.rb spec/app_spec.rb`

Expected: all examples pass.

- [ ] **Step 5: Commit the result contract**

```bash
git add app.rb lib/opp_resolver/result.rb spec/app_spec.rb spec/result_spec.rb
git commit -m "feat: add resolver result contract"
```

---

### Task 3: Directory Registration verifier

**Files:**
- Create: `lib/opp_resolver/registration_verifier.rb`
- Create: `spec/registration_verifier_spec.rb`
- Modify: `spec/spec_helper.rb`

**Interfaces:**
- Consumes: a parsed registration `Hash` and `expected_subject:` string.
- Produces: `RegistrationVerifier#verify!(registration, expected_subject:) -> Hash`.
- Raises: `RegistrationVerifier::Invalid` with stable `#code` and safe `#message`.

- [ ] **Step 1: Add deterministic signed-registration helpers**

In `spec/spec_helper.rb`, add a helper that generates an OPP key pair and signs a valid registration with version `0.2`, sequence `0`, a fixed UTC time, and `https://presence.example/opp.json`. Allow field overrides before signing.

```ruby
def signed_registration(pair: OPP::KeyPair.generate, **overrides)
  document = {
    "type" => "open-presence-directory-registration",
    "version" => "0.2",
    "subject" => OPP::Subject.derive(pair.public_key),
    "public_key" => pair.public_key,
    "document_url" => "https://presence.example/opp.json",
    "sequence" => 0,
    "issued_at" => "2026-07-18T12:00:00Z"
  }.merge(overrides.transform_keys(&:to_s))
  OPP::Signature.sign(document, private_key: pair.private_key)
end
```

- [ ] **Step 2: Write failing happy-path and schema tests**

Test a valid registration, missing fields, wrong type/version, incorrect field types, negative and non-integer sequence values, invalid calendar timestamps, non-UTC timestamps, HTTP/relative/credentialed URLs, malformed public keys, derived-subject mismatch, requested-subject mismatch, malformed signature objects, and cryptographically invalid signatures. Assert exact stable codes such as `:missing_field`, `:unsupported_version`, `:invalid_document_url`, `:subject_mismatch`, and `:invalid_signature`.

- [ ] **Step 3: Run and verify RED**

Run: `bundle exec rspec spec/registration_verifier_spec.rb`

Expected: FAIL because `OppResolver::RegistrationVerifier` does not exist.

- [ ] **Step 4: Implement minimal registration verification**

Implement constants for required fields, type, version, and UTC timestamp syntax. Validate schema before cryptography. Parse timestamps using `Time.iso8601`, URLs using `URI.parse`, public keys and subjects with the `opp` APIs, and signatures with `OPP::Signature.verify!`. Preserve unknown fields and return the original parsed hash on success.

```ruby
module OppResolver
  class RegistrationVerifier
    class Invalid < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super(message)
      end
    end

    REQUIRED_FIELDS = %w[type version subject public_key document_url sequence issued_at signature].freeze
    TYPE = "open-presence-directory-registration"
    VERSION = "0.2"
    UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

    def verify!(registration, expected_subject:)
      fail_with(:malformed_registration, "The Directory Registration must be a JSON object.") unless registration.is_a?(Hash)
      missing = REQUIRED_FIELDS.reject { |field| registration.key?(field) }
      fail_with(:missing_field, "The Directory Registration is missing #{missing.first}.") unless missing.empty?
      fail_with(:unsupported_type, "The Directory Registration type is unsupported.") unless registration["type"] == TYPE
      fail_with(:unsupported_version, "The Directory Registration version is unsupported.") unless registration["version"] == VERSION

      %w[subject public_key document_url issued_at].each do |field|
        fail_with(:invalid_field, "The Directory Registration #{field} must be a string.") unless registration[field].is_a?(String)
      end
      unless registration["sequence"].is_a?(Integer) && registration["sequence"] >= 0
        fail_with(:invalid_sequence, "The Directory Registration sequence must be a non-negative integer.")
      end
      validate_timestamp!(registration["issued_at"])
      validate_document_url!(registration["document_url"])
      fail_with(:subject_mismatch, "The Directory Registration belongs to a different subject.") unless registration["subject"] == expected_subject

      OPP::Subject.verify!(registration.fetch("subject"), public_key: registration.fetch("public_key"))
      OPP::Signature.verify!(registration, public_key: registration.fetch("public_key"))
      registration
    rescue OPP::InvalidSignatureError
      fail_with(:invalid_signature, "The Directory Registration signature is invalid.")
    rescue OPP::SubjectMismatchError, OPP::InvalidPublicKeyError
      fail_with(:subject_mismatch, "The Directory Registration subject does not match its public key.")
    end

    private

    def validate_timestamp!(value)
      fail_with(:invalid_issued_at, "The Directory Registration issued_at must be an RFC 3339 UTC timestamp.") unless UTC_TIMESTAMP.match?(value)
      Time.iso8601(value)
    rescue ArgumentError
      fail_with(:invalid_issued_at, "The Directory Registration issued_at must be an RFC 3339 UTC timestamp.")
    end

    def validate_document_url!(value)
      uri = URI.parse(value)
      valid = uri.is_a?(URI::HTTPS) && uri.absolute? && !uri.host.to_s.empty? && uri.user.nil? && uri.password.nil?
      fail_with(:invalid_document_url, "The Presence Document URL must be absolute, credential-free HTTPS.") unless valid
    rescue URI::InvalidURIError
      fail_with(:invalid_document_url, "The Presence Document URL must be absolute, credential-free HTTPS.")
    end

    def fail_with(code, message)
      raise Invalid.new(code, message)
    end
  end
end
```

- [ ] **Step 5: Run and verify GREEN**

Run: `bundle exec rspec spec/registration_verifier_spec.rb`

Expected: all registration examples pass.

- [ ] **Step 6: Commit the verifier**

```bash
git add lib/opp_resolver/registration_verifier.rb spec/spec_helper.rb spec/registration_verifier_spec.rb
git commit -m "feat: verify directory registrations"
```

---

### Task 4: Defensive HTTPS client

**Files:**
- Create: `lib/opp_resolver/safe_http_client.rb`
- Create: `spec/safe_http_client_spec.rb`

**Interfaces:**
- Consumes: `SafeHttpClient#get(url, public_only:)` where `url` is a String or URI and `public_only` is boolean.
- Produces: `SafeHttpClient::Response` with `status`, `body`, and normalized `content_type`.
- Raises: `SafeHttpClient::Failure` with codes `:invalid_url`, `:unsafe_address`, `:timeout`, `:unavailable`, `:redirect`, `:response_too_large`, or `:invalid_content_type`.
- Constructor injection: `resolver:`, `transport:`, `open_timeout:`, `read_timeout:`, and `max_bytes:`.

- [ ] **Step 1: Write failing URL and address-safety tests**

Cover HTTP, relative URLs, embedded credentials, missing hosts, loopback IPv4/IPv6, RFC1918, link-local, multicast, unspecified and reserved addresses, mixed safe/unsafe DNS answers, and a public address. Use a fake resolver returning `IPAddr` values; no DNS calls are permitted.

- [ ] **Step 2: Run URL tests and verify RED**

Run: `bundle exec rspec spec/safe_http_client_spec.rb -e "URL" -e "address"`

Expected: FAIL because `OppResolver::SafeHttpClient` does not exist.

- [ ] **Step 3: Implement URL validation and public-address classification**

Use `URI`, `IPAddr`, and an explicit deny list covering `0.0.0.0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16`, `172.16/12`, `192.0.0.0/24`, `192.0.2/24`, `192.168/16`, `198.18/15`, `198.51.100/24`, `203.0.113/24`, `224/4`, `240/4`, `::/128`, `::1/128`, `::ffff:0:0/96`, `64:ff9b::/96`, `100::/64`, `2001:db8::/32`, `fc00::/7`, `fe80::/10`, and `ff00::/8`. Reject the destination when any returned address is denied; choose the first validated address otherwise.

- [ ] **Step 4: Write failing transport behavior tests**

Create a fake transport interface with `get(uri:, ipaddr:, open_timeout:, read_timeout:) { |chunk| ... }`. Test 200 JSON, `application/problem+json`, redirect rejection without a second request, JSON media-type parameters, non-JSON rejection, `Content-Length` preflight, streamed-size overflow, connection/read timeouts, DNS failures, TLS/socket failures, and a configured limit boundary.

- [ ] **Step 5: Run transport tests and verify RED**

Run: `bundle exec rspec spec/safe_http_client_spec.rb`

Expected: new transport examples fail because GET behavior is missing.

- [ ] **Step 6: Implement bounded Net::HTTP transport and error mapping**

Implement `NetHttpTransport` so `Net::HTTP#ipaddr=` pins the validated address while the URI hostname remains the TLS verification name. Set `use_ssl`, `VERIFY_PEER`, `open_timeout`, and `read_timeout`; send `Accept: application/json`; stream with `read_body`; reject redirects; and stop once bytes exceed `max_bytes`. Rescue only known DNS, timeout, TLS, and socket failures into stable codes.

- [ ] **Step 7: Run and verify GREEN**

Run: `bundle exec rspec spec/safe_http_client_spec.rb`

Expected: all safe-client examples pass without network access.

- [ ] **Step 8: Commit the safe client**

```bash
git add lib/opp_resolver/safe_http_client.rb spec/safe_http_client_spec.rb
git commit -m "feat: add defensive HTTPS client"
```

---

### Task 5: Resolution orchestration and trust-chain enforcement

**Files:**
- Create: `lib/opp_resolver/resolver.rb`
- Create: `spec/resolver_spec.rb`
- Modify: `app.rb`

**Interfaces:**
- Consumes: `Resolver.new(directory_url:, http_client:, registration_verifier:, clock:)` and `#resolve(raw_subject)`.
- Produces: `OppResolver::Result` with success detail keys `subject`, `directory_url`, `registration`, `presence`, `services`, `registration_json`, and `presence_json`.
- Uses: `SafeHttpClient#get(url, public_only:)` and `RegistrationVerifier#verify!(registration, expected_subject:)`.

- [ ] **Step 1: Write failing subject and directory-request tests**

Assert trimming of surrounding whitespace, rejection of malformed prefixes/payloads/padding, and an exact directory URI whose path ends in `key%3Asha256%3A...`. Assert the trusted configured directory request uses `public_only: false`.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `bundle exec rspec spec/resolver_spec.rb -e "subject" -e "directory request"`

Expected: FAIL because `OppResolver::Resolver` does not exist.

- [ ] **Step 3: Implement subject handling and directory URI construction**

Use `\Akey:sha256:[A-Za-z0-9_-]{43}\z` and percent-encode the complete subject as one path segment. Parse the configured base once, require credential-free HTTPS, remove any trailing slash, and append `/#{encoded_subject}` without allowing query or fragment data from the subject.

- [ ] **Step 4: Write failing end-to-end resolver tests**

Using deterministic OPP key pairs and fake client responses, cover:

- Valid signed registration plus valid signed Presence Document.
- Directory 404 versus other statuses and all safe-client failures.
- Duplicate-member/malformed registration JSON.
- Every `RegistrationVerifier::Invalid` code.
- Document request with `public_only: true`.
- Malformed Presence JSON and structured `OPP::Presence.verify` failures.
- Invalid signature, expired Presence Document, and Presence subject mismatch.
- Unknown service types preserved on success.
- Services absent from every failure result.

- [ ] **Step 5: Run end-to-end tests and verify RED**

Run: `bundle exec rspec spec/resolver_spec.rb`

Expected: orchestration examples fail because only subject handling exists.

- [ ] **Step 6: Implement minimal orchestration and error mapping**

Parse both bodies with `OPP::JSON.parse`; use the injected clock as the `at:` value for `OPP::Presence.verify`. Convert each known failure into a specific safe message. On success, pretty-print both parsed hashes with `JSON.pretty_generate` and include services only from the verified Presence Document.

The core success path must be structurally equivalent to:

```ruby
registration_response = http_client.get(directory_uri(subject), public_only: false)
return registration_status_failure(registration_response) unless registration_response.status == 200

registration = OPP::JSON.parse(registration_response.body)
registration_verifier.verify!(registration, expected_subject: subject)

presence_response = http_client.get(registration.fetch("document_url"), public_only: true)
return presence_status_failure(presence_response) unless presence_response.status == 200

presence = OPP::JSON.parse(presence_response.body)
verification = OPP::Presence.verify(presence, at: clock.call)
return presence_verification_failure(verification, registration:, presence:) unless verification.valid?
return Result.failure(:presence_subject_mismatch, "The Presence Document belongs to a different subject.") unless presence["subject"] == subject

Result.success(
  subject:,
  directory_url:,
  registration:,
  presence:,
  services: presence.fetch("services"),
  registration_json: JSON.pretty_generate(registration),
  presence_json: JSON.pretty_generate(presence)
)
```

- [ ] **Step 7: Wire the production resolver factory**

Update `app.rb` to require all library files and construct `SafeHttpClient`, `RegistrationVerifier`, and `Resolver` with `ENV.fetch("OPP_DIRECTORY_URL", DEFAULT_DIRECTORY_URL)`. Keep `resolver_factory` injectable for Rack tests.

- [ ] **Step 8: Run and verify GREEN**

Run: `bundle exec rspec spec/resolver_spec.rb spec/app_spec.rb`

Expected: all resolver and route examples pass.

- [ ] **Step 9: Commit orchestration**

```bash
git add app.rb lib/opp_resolver/resolver.rb spec/resolver_spec.rb spec/app_spec.rb
git commit -m "feat: resolve and verify OPP subjects"
```

---

### Task 6: Trusted result presentation and safe error rendering

**Files:**
- Modify: `views/result.erb`
- Modify: `views/index.erb`
- Modify: `views/layout.erb`
- Modify: `public/styles.css`
- Modify: `spec/app_spec.rb`

**Interfaces:**
- Consumes: the `OppResolver::Result` contract and its documented detail keys.
- Produces: accessible server-rendered HTML with staged trust details and escaped raw JSON.

- [ ] **Step 1: Write failing success-rendering tests**

Inject a successful result and assert separate headings for Resolution, Directory Registration, Presence Document, Services, and Raw Documents. Assert requested subject, directory, sequence, issued/expiration times, document URL, unknown service type, and linked service URL. Assert two collapsed `<details>` elements.

- [ ] **Step 2: Write failing trust and escaping tests**

Use hostile values containing `<script>`, quotes, and event-handler markup in subjects, service types, verification messages, and raw JSON. Assert escaped output and absence of executable markup. Inject failures at registration and Presence stages and assert no service links or trusted labels appear.

- [ ] **Step 3: Run rendering tests and verify RED**

Run: `bundle exec rspec spec/app_spec.rb`

Expected: FAIL because the result template does not yet render staged details.

- [ ] **Step 4: Implement staged templates and visual states**

Use ERB's escaped output form for every value. On success render all stages, linked service cards, and raw JSON in `<pre><code>`. On failure render requested-subject context when available, the safe message, and structured OPP errors as code/path/message rows; omit services and unverified raw data unless the resolver explicitly includes it for inspection with a visible `Unverified` label.

Use a quiet protocol-inspector visual direction: warm neutral background, dark ink, restrained green/red/amber verification chips, monospace for subjects and JSON, and a vertical trust-chain rhythm. Maintain visible keyboard focus, at least WCAG AA contrast, fluid wrapping for long subjects/URLs, and a single-column mobile layout.

- [ ] **Step 5: Run rendering tests and verify GREEN**

Run: `bundle exec rspec spec/app_spec.rb`

Expected: all route and escaping examples pass.

- [ ] **Step 6: Commit presentation**

```bash
git add views public/styles.css spec/app_spec.rb
git commit -m "feat: render OPP verification results"
```

---

### Task 7: Documentation and full acceptance verification

**Files:**
- Modify: `README.md`
- Modify: any implementation or spec file required by verification failures.

**Interfaces:**
- Consumes: completed application commands and configuration.
- Produces: reproducible setup and operations documentation.

- [ ] **Step 1: Replace the README with complete operating documentation**

Document Ruby 3.2+, `bundle install`, `bundle exec rackup`, the local URL, `bundle exec rspec`, `OPP_DIRECTORY_URL`, the default directory and example subject, project structure, the resolution sequence, why the directory is discovery rather than authority, verification gates, SSRF defenses, response limits/timeouts, and the no-live-network test policy.

- [ ] **Step 2: Install dependencies under Ruby 3.2+**

Run: `bundle install`

Expected: Bundler resolves Sinatra, `opp`, Rack::Test, and RSpec without version conflicts and writes `Gemfile.lock`.

- [ ] **Step 3: Run the complete automated suite**

Run: `bundle exec rspec`

Expected: all examples pass with 0 failures and no live network access.

- [ ] **Step 4: Run syntax checks**

Run: `find app.rb lib spec -name '*.rb' -print0 | xargs -0 -n1 ruby -c`

Expected: every file reports `Syntax OK`.

- [ ] **Step 5: Verify Rack boot**

Run: `bundle exec rackup --help`

Expected: exit 0, proving the Rack command and application dependencies load. Then run a bounded local boot check against `config.ru` and confirm the root page returns HTTP 200.

- [ ] **Step 6: Review acceptance criteria and repository diff**

Run: `git diff --check && git status --short && git diff --stat HEAD~1`

Expected: no whitespace errors; only issue #1 implementation, tests, lockfile, design, plan, and documentation are present.

- [ ] **Step 7: Commit documentation and final verification fixes**

```bash
git add README.md Gemfile.lock
git add app.rb config.ru lib views public spec Gemfile .ruby-version
git commit -m "docs: explain OPP resolver setup and trust flow"
```
