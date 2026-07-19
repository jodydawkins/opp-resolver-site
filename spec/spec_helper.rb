ENV["RACK_ENV"] = "test"

require "rack/test"
require "rspec"
require "opp"
require_relative "../app"

module OppSpecHelpers
  def signed_registration(pair: OPP::KeyPair.generate, overrides: {})
    document = {
      "type" => "open-presence-directory-registration",
      "version" => "0.2",
      "subject" => OPP::Subject.derive(pair.public_key),
      "public_key" => pair.public_key,
      "document_url" => "https://presence.example/opp.json",
      "sequence" => 0,
      "issued_at" => "2026-07-18T12:00:00Z"
    }.merge(overrides)

    OPP::Signature.sign(document, private_key: pair.private_key)
  end

  def signed_presence(pair: OPP::KeyPair.generate, overrides: {})
    document = {
      "type" => "open-presence",
      "version" => "0.1",
      "issued_at" => "2026-07-18T11:00:00Z",
      "expires_at" => "2026-07-19T11:00:00Z",
      "services" => [
        { "type" => "profile", "url" => "https://example.com/profile" }
      ]
    }.merge(overrides)

    OPP::Presence.sign(document, private_key: pair.private_key)
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.include OppSpecHelpers
end
