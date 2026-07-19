require "spec_helper"
require_relative "../lib/opp_resolver/registration_verifier"

RSpec.describe OppResolver::RegistrationVerifier do
  subject(:verifier) { described_class.new }

  let(:pair) { OPP::KeyPair.generate }
  let(:registration) { signed_registration(pair:) }
  let(:expected_subject) { registration.fetch("subject") }

  def expect_failure(code, document = registration, subject: expected_subject)
    expect { verifier.verify!(document, expected_subject: subject) }
      .to raise_error(described_class::Invalid) { |error| expect(error.code).to eq(code) }
  end

  it "returns a valid registration without removing unknown signed members" do
    document = signed_registration(pair:, overrides: { "extension" => { "enabled" => true } })

    expect(verifier.verify!(document, expected_subject: document.fetch("subject"))).to equal(document)
    expect(document.dig("extension", "enabled")).to be(true)
  end

  it "requires a JSON object" do
    expect_failure(:malformed_registration, [])
  end

  %w[type version subject public_key document_url sequence issued_at signature].each do |field|
    it "requires #{field}" do
      expect_failure(:missing_field, registration.reject { |key, _| key == field })
    end
  end

  it "requires the Directory Registration type" do
    expect_failure(:unsupported_type, signed_registration(pair:, overrides: { "type" => "open-presence" }))
  end

  it "requires Directory Registration version 0.2" do
    expect_failure(:unsupported_version, signed_registration(pair:, overrides: { "version" => "0.1" }))
  end

  %w[subject public_key document_url issued_at].each do |field|
    it "requires #{field} to be a string" do
      expect_failure(:invalid_field, signed_registration(pair:, overrides: { field => 7 }))
    end
  end

  it "requires a non-negative integer sequence" do
    expect_failure(:invalid_sequence, signed_registration(pair:, overrides: { "sequence" => -1 }))
    expect_failure(:invalid_sequence, signed_registration(pair:, overrides: { "sequence" => 1.0 }))
  end

  it "requires an RFC 3339 UTC issued_at timestamp" do
    expect_failure(:invalid_issued_at, signed_registration(pair:, overrides: { "issued_at" => "2026-07-18T12:00:00-07:00" }))
    expect_failure(:invalid_issued_at, signed_registration(pair:, overrides: { "issued_at" => "2026-02-30T12:00:00Z" }))
  end

  it "requires an absolute credential-free HTTPS document URL" do
    [
      "http://presence.example/opp.json",
      "/opp.json",
      "https://user:secret@presence.example/opp.json",
      "https:///opp.json",
      "not a URL"
    ].each do |value|
      expect_failure(:invalid_document_url, signed_registration(pair:, overrides: { "document_url" => value }))
    end
  end

  it "requires the registration subject to match the requested subject" do
    expect_failure(:requested_subject_mismatch, registration, subject: "key:sha256:#{'A' * 43}")
  end

  it "requires the subject to derive from the public key" do
    other_pair = OPP::KeyPair.generate
    document = signed_registration(pair:, overrides: { "subject" => OPP::Subject.derive(other_pair.public_key) })

    expect_failure(:subject_mismatch, document, subject: document.fetch("subject"))
  end

  it "requires a valid public key" do
    document = signed_registration(pair:, overrides: { "public_key" => "not-a-public-key" })

    expect_failure(:invalid_public_key, document)
  end

  it "requires a structured Ed25519 signature" do
    expect_failure(:invalid_signature, registration.merge("signature" => { "algorithm" => "rsa", "value" => "value" }))
    expect_failure(:invalid_signature, registration.merge("signature" => "value"))
  end

  it "requires a cryptographically valid signature" do
    value = registration.dig("signature", "value")
    changed = (value.start_with?("A") ? "B" : "A") + value[1..]
    document = registration.merge("signature" => registration.fetch("signature").merge("value" => changed))

    expect_failure(:invalid_signature, document)
  end
end
