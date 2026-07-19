require "spec_helper"
require "json"
require_relative "../lib/opp_resolver/resolver"
require_relative "../lib/opp_resolver/registration_verifier"
require_relative "../lib/opp_resolver/safe_http_client"

RSpec.describe OppResolver::Resolver do
  class FakeHttpClient
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def get(url, public_only:)
      @requests << { url: url.to_s, public_only: }
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  let(:pair) { OPP::KeyPair.generate }
  let(:presence) { signed_presence(pair:) }
  let(:subject_value) { presence.fetch("subject") }
  let(:registration) do
    signed_registration(
      pair:,
      overrides: { "document_url" => "https://presence.example/opp.json" }
    )
  end
  let(:registration_response) do
    OppResolver::SafeHttpClient::Response.new(200, JSON.generate(registration), "application/json")
  end
  let(:presence_response) do
    OppResolver::SafeHttpClient::Response.new(200, JSON.generate(presence), "application/json")
  end
  let(:http_client) { FakeHttpClient.new(registration_response, presence_response) }
  let(:clock) { -> { Time.utc(2026, 7, 18, 12) } }
  let(:resolver) do
    described_class.new(
      directory_url: "https://directory.example/base/",
      http_client:,
      registration_verifier: OppResolver::RegistrationVerifier.new,
      clock:
    )
  end

  it "resolves and verifies the complete trust chain" do
    result = resolver.resolve(subject_value)

    expect(result).to be_success
    expect(result.details[:subject]).to eq(subject_value)
    expect(result.details[:registration]).to eq(registration)
    expect(result.details[:presence]).to eq(presence)
    expect(result.details[:services]).to eq(presence.fetch("services"))
    expect(result.details[:registration_json]).to include("\n")
    expect(result.details[:presence_json]).to include("\n")
    expect(http_client.requests).to eq([
      {
        url: "https://directory.example/base/key%3Asha256%3A#{subject_value.delete_prefix('key:sha256:')}",
        public_only: false
      },
      { url: "https://presence.example/opp.json", public_only: true }
    ])
  end

  it "normalizes surrounding whitespace before requesting the directory" do
    result = resolver.resolve(" \n#{subject_value}\t")

    expect(result).to be_success
    expect(result.details[:subject]).to eq(subject_value)
  end

  it "rejects malformed subjects without making a request" do
    [
      "", "key:sha256:", "KEY:sha256:#{'A' * 43}", "key:sha256:#{'A' * 42}",
      "key:sha256:#{'A' * 44}", "key:sha256:#{'A' * 42}=", "key:sha256:#{'!' * 43}"
    ].each do |value|
      result = resolver.resolve(value)
      expect(result.error_code).to eq(:invalid_subject)
      expect(result.details).not_to have_key(:services)
    end
    expect(http_client.requests).to be_empty
  end

  it "reports a missing registration for directory 404" do
    client = FakeHttpClient.new(OppResolver::SafeHttpClient::Response.new(404, "", nil))
    resolver = described_class.new(directory_url: "https://directory.example", http_client: client)

    expect(resolver.resolve(subject_value).error_code).to eq(:registration_not_found)
  end

  it "reports other directory statuses as unavailable" do
    client = FakeHttpClient.new(OppResolver::SafeHttpClient::Response.new(503, "", nil))
    resolver = described_class.new(directory_url: "https://directory.example", http_client: client)

    expect(resolver.resolve(subject_value).error_code).to eq(:directory_unavailable)
  end

  it "distinguishes directory network failures" do
    timeout = OppResolver::SafeHttpClient::Failure.new(:timeout, "internal timeout detail")
    unavailable = OppResolver::SafeHttpClient::Failure.new(:unavailable, "internal address detail")

    expect(described_class.new(directory_url: "https://directory.example", http_client: FakeHttpClient.new(timeout))
      .resolve(subject_value).error_code).to eq(:directory_timeout)
    result = described_class.new(directory_url: "https://directory.example", http_client: FakeHttpClient.new(unavailable))
      .resolve(subject_value)
    expect(result.error_code).to eq(:directory_unavailable)
    expect(result.message).not_to include("internal")
  end

  it "reports malformed and duplicate-member registration JSON" do
    ["not-json", '{"type":"one","type":"two"}'].each do |body|
      client = FakeHttpClient.new(OppResolver::SafeHttpClient::Response.new(200, body, "application/json"))
      result = described_class.new(directory_url: "https://directory.example", http_client: client).resolve(subject_value)

      expect(result.error_code).to eq(:malformed_registration)
    end
  end

  it "preserves specific registration verification failures" do
    invalid = registration.merge("sequence" => -1)
    client = FakeHttpClient.new(OppResolver::SafeHttpClient::Response.new(200, JSON.generate(invalid), "application/json"))
    result = described_class.new(directory_url: "https://directory.example", http_client: client).resolve(subject_value)

    expect(result.error_code).to eq(:invalid_sequence)
    expect(result.details).not_to have_key(:services)
  end

  it "reports an unavailable Presence Document" do
    client = FakeHttpClient.new(
      registration_response,
      OppResolver::SafeHttpClient::Response.new(503, "", nil)
    )
    result = described_class.new(directory_url: "https://directory.example", http_client: client).resolve(subject_value)

    expect(result.error_code).to eq(:presence_unavailable)
  end

  it "distinguishes unsafe and timed-out Presence Document requests" do
    [:unsafe_address, :timeout, :response_too_large, :invalid_content_type].each do |code|
      failure = OppResolver::SafeHttpClient::Failure.new(code, "internal detail")
      client = FakeHttpClient.new(registration_response, failure)
      result = described_class.new(directory_url: "https://directory.example", http_client: client).resolve(subject_value)

      expect(result.error_code).to eq("presence_#{code}".to_sym)
      expect(result.message).not_to include("internal")
    end
  end

  it "reports malformed Presence Document JSON" do
    client = FakeHttpClient.new(
      registration_response,
      OppResolver::SafeHttpClient::Response.new(200, "not-json", "application/json")
    )

    expect(described_class.new(directory_url: "https://directory.example", http_client: client)
      .resolve(subject_value).error_code).to eq(:malformed_presence)
  end

  it "preserves structured Presence verification errors" do
    changed = presence.merge("issued_at" => "not-a-time")
    client = FakeHttpClient.new(
      registration_response,
      OppResolver::SafeHttpClient::Response.new(200, JSON.generate(changed), "application/json")
    )
    result = described_class.new(directory_url: "https://directory.example", http_client: client, clock:).resolve(subject_value)

    expect(result.error_code).to eq(:invalid_presence)
    expect(result.details[:verification_errors]).to include(
      hash_including(code: "validation", path: "issued_at")
    )
    expect(result.details).not_to have_key(:services)
  end

  it "reports an invalid Presence signature" do
    changed = presence.merge("issued_at" => "2026-07-18T10:00:00Z")
    client = FakeHttpClient.new(registration_response, OppResolver::SafeHttpClient::Response.new(200, JSON.generate(changed), "application/json"))
    result = described_class.new(directory_url: "https://directory.example", http_client: client, clock:).resolve(subject_value)

    expect(result.error_code).to eq(:invalid_presence_signature)
  end

  it "reports an expired Presence Document" do
    expired = signed_presence(pair:, overrides: { "expires_at" => "2026-07-18T11:30:00Z" })
    client = FakeHttpClient.new(registration_response, OppResolver::SafeHttpClient::Response.new(200, JSON.generate(expired), "application/json"))
    result = described_class.new(directory_url: "https://directory.example", http_client: client, clock:).resolve(subject_value)

    expect(result.error_code).to eq(:expired_presence)
  end

  it "rejects a valid Presence Document for another subject" do
    other_presence = signed_presence
    client = FakeHttpClient.new(registration_response, OppResolver::SafeHttpClient::Response.new(200, JSON.generate(other_presence), "application/json"))
    result = described_class.new(directory_url: "https://directory.example", http_client: client, clock:).resolve(subject_value)

    expect(result.error_code).to eq(:presence_subject_mismatch)
    expect(result.details).not_to have_key(:services)
  end

  it "preserves unknown verified service types" do
    custom_presence = signed_presence(pair:, overrides: {
      "services" => [{ "type" => "com.example.calendar", "url" => "https://example.com/calendar" }]
    })
    client = FakeHttpClient.new(registration_response, OppResolver::SafeHttpClient::Response.new(200, JSON.generate(custom_presence), "application/json"))
    result = described_class.new(directory_url: "https://directory.example", http_client: client, clock:).resolve(subject_value)

    expect(result.details[:services].first.fetch("type")).to eq("com.example.calendar")
  end

  it "rejects an unsafe configured directory URL" do
    expect { described_class.new(directory_url: "http://directory.example", http_client:) }
      .to raise_error(ArgumentError, /directory URL/i)
  end
end
