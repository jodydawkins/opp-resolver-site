require "spec_helper"
require "ipaddr"
require "net/http"
require_relative "../lib/opp_resolver/safe_http_client"

RSpec.describe OppResolver::SafeHttpClient do
  FakeResolver = Data.define(:answers, :error) do
    def resolve(_host)
      raise error if error

      answers
    end
  end

  class FakeTransport
    attr_reader :requests

    def initialize(status: 200, headers: { "content-type" => ["application/json"] }, chunks: ["{}"], error: nil)
      @status = status
      @headers = headers
      @chunks = chunks
      @error = error
      @requests = []
    end

    def get(**request)
      @requests << request
      raise @error if @error

      yield @status, @headers, @chunks.each
    end
  end

  let(:public_ip) { IPAddr.new("93.184.216.34") }
  let(:resolver) { FakeResolver.new([public_ip], nil) }
  let(:transport) { FakeTransport.new }
  let(:client) do
    described_class.new(
      resolver:,
      transport:,
      open_timeout: 1,
      read_timeout: 2,
      max_bytes: 12
    )
  end

  def expect_failure(code, url = "https://presence.example/opp.json", public_only: true, using: client)
    expect { using.get(url, public_only:) }
      .to raise_error(described_class::Failure) { |error| expect(error.code).to eq(code) }
  end

  it "returns a bounded JSON response and pins the validated address" do
    response = client.get("https://presence.example/opp.json", public_only: true)

    expect(response.status).to eq(200)
    expect(response.body).to eq("{}")
    expect(response.content_type).to eq("application/json")
    expect(transport.requests).to contain_exactly(
      uri: URI("https://presence.example/opp.json"),
      ipaddr: "93.184.216.34",
      open_timeout: 1,
      read_timeout: 2
    )
  end

  it "allows a trusted directory request without public-address resolution" do
    response = client.get("https://localhost:9292/key", public_only: false)

    expect(response.status).to eq(200)
    expect(transport.requests.first.fetch(:ipaddr)).to be_nil
  end

  it "accepts JSON structured-syntax media types and parameters" do
    transport = FakeTransport.new(headers: { "content-type" => ["Application/Problem+Json; charset=utf-8"] })
    client = described_class.new(resolver:, transport:, max_bytes: 12)

    expect(client.get("https://presence.example/opp.json", public_only: true).content_type)
      .to eq("application/problem+json")
  end

  it "rejects non-HTTPS, relative, credentialed, and hostless URLs" do
    [
      "http://presence.example/opp.json",
      "/opp.json",
      "https://user:secret@presence.example/opp.json",
      "https:///opp.json",
      "not a URL"
    ].each { |url| expect_failure(:invalid_url, url) }
  end

  it "rejects empty DNS results" do
    client = described_class.new(resolver: FakeResolver.new([], nil), transport:)

    expect_failure(:unsafe_address, using: client)
  end

  [
    "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.1.1",
    "172.16.0.1", "192.0.0.1", "192.0.2.1", "192.168.1.1", "198.18.0.1",
    "198.51.100.1", "203.0.113.1", "224.0.0.1", "240.0.0.1", "::", "::1",
    "::ffff:127.0.0.1", "64:ff9b::1", "100::1", "2001:db8::1", "fc00::1",
    "fe80::1", "ff00::1"
  ].each do |address|
    it "rejects unsafe address #{address}" do
      client = described_class.new(resolver: FakeResolver.new([IPAddr.new(address)], nil), transport:)

      expect_failure(:unsafe_address, using: client)
    end
  end

  it "rejects a hostname when any resolved address is unsafe" do
    mixed = FakeResolver.new([public_ip, IPAddr.new("127.0.0.1")], nil)
    client = described_class.new(resolver: mixed, transport:)

    expect_failure(:unsafe_address, using: client)
  end

  it "rejects redirects without making another request" do
    transport = FakeTransport.new(status: 302, headers: { "location" => ["https://other.example/"] }, chunks: [])
    client = described_class.new(resolver:, transport:)

    expect_failure(:redirect, using: client)
    expect(transport.requests.length).to eq(1)
  end

  it "returns non-redirect upstream status responses without exposing their bodies as JSON" do
    transport = FakeTransport.new(status: 404, headers: { "content-type" => ["text/html"] }, chunks: ["not found"])
    client = described_class.new(resolver:, transport:)

    response = client.get("https://presence.example/opp.json", public_only: true)
    expect(response.status).to eq(404)
    expect(response.body).to eq("not found")
  end

  it "rejects successful non-JSON responses" do
    transport = FakeTransport.new(headers: { "content-type" => ["text/html"] })
    client = described_class.new(resolver:, transport:)

    expect_failure(:invalid_content_type, using: client)
  end

  it "rejects a declared response larger than the byte limit" do
    transport = FakeTransport.new(headers: {
      "content-type" => ["application/json"],
      "content-length" => ["13"]
    }, chunks: [])
    client = described_class.new(resolver:, transport:, max_bytes: 12)

    expect_failure(:response_too_large, using: client)
  end

  it "rejects a streamed response larger than the byte limit" do
    transport = FakeTransport.new(chunks: ["123456", "789012", "3"])
    client = described_class.new(resolver:, transport:, max_bytes: 12)

    expect_failure(:response_too_large, using: client)
  end

  it "accepts a response exactly at the byte limit" do
    transport = FakeTransport.new(chunks: ["123456", "789012"])
    client = described_class.new(resolver:, transport:, max_bytes: 12)

    expect(client.get("https://presence.example/opp.json", public_only: true).body.bytesize).to eq(12)
  end

  it "maps DNS and connection failures without exposing their details" do
    dns_client = described_class.new(resolver: FakeResolver.new([], SocketError.new("secret DNS detail")), transport:)
    expect { dns_client.get("https://presence.example/opp.json", public_only: true) }
      .to raise_error(described_class::Failure, "The remote service is unavailable.") { |error| expect(error.code).to eq(:unavailable) }

    transport_client = described_class.new(resolver:, transport: FakeTransport.new(error: Errno::ECONNREFUSED.new("secret address")))
    expect { transport_client.get("https://presence.example/opp.json", public_only: true) }
      .to raise_error(described_class::Failure, "The remote service is unavailable.") { |error| expect(error.code).to eq(:unavailable) }
  end

  it "maps connection and read timeouts" do
    transport = FakeTransport.new(error: Net::ReadTimeout.new("secret timeout"))
    client = described_class.new(resolver:, transport:)

    expect_failure(:timeout, using: client)
  end
end
