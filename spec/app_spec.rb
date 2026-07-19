require "spec_helper"

RSpec.describe OppResolver::App do
  include Rack::Test::Methods

  let(:app) { described_class }

  def post_with_result(result, subject: "key:sha256:requested")
    resolver = instance_double("OppResolver::Resolver", resolve: result)
    app.set :resolver_factory, -> { resolver }
    post "/resolve", subject:
  ensure
    app.set :resolver_factory, app.default_resolver_factory
  end

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

  it "builds the production resolver from the application configuration" do
    app.set :resolver_factory, app.default_resolver_factory

    expect(app.settings.resolver_factory).to be_a(OppResolver::Resolver)
  end

  it "renders every verified trust stage and unknown service types" do
    result = OppResolver::Result.success(
      subject: "key:sha256:requested",
      directory_url: "https://directory.example",
      registration_found: true,
      registration: {
        "subject" => "key:sha256:requested",
        "document_url" => "https://presence.example/opp.json",
        "sequence" => 7,
        "issued_at" => "2026-07-18T10:00:00Z"
      },
      presence: {
        "subject" => "key:sha256:requested",
        "issued_at" => "2026-07-18T11:00:00Z",
        "expires_at" => "2026-07-19T11:00:00Z"
      },
      services: [
        { "type" => "com.example.calendar", "url" => "https://example.com/calendar" }
      ],
      registration_json: "{\n  \"sequence\": 7\n}",
      presence_json: "{\n  \"services\": []\n}"
    )

    post_with_result(result)

    expect(last_response).to be_ok
    %w[Resolution Registration Presence Services].each do |heading|
      expect(last_response.body).to include(heading)
    end
    expect(last_response.body).to include("Raw documents")
    expect(last_response.body).to include("key:sha256:requested")
    expect(last_response.body).to include("https://directory.example")
    expect(last_response.body).to include("https://presence.example/opp.json")
    expect(last_response.body).to include("com.example.calendar")
    expect(last_response.body).to include('href="https://example.com/calendar"')
    expect(last_response.body.scan("<details").length).to eq(2)
  end

  it "escapes service values and raw documents" do
    result = OppResolver::Result.success(
      subject: "key:sha256:requested",
      directory_url: "https://directory.example",
      registration_found: true,
      registration: {
        "subject" => "key:sha256:requested",
        "document_url" => "https://presence.example/opp.json",
        "sequence" => 1,
        "issued_at" => "2026-07-18T10:00:00Z"
      },
      presence: {
        "subject" => "key:sha256:requested",
        "issued_at" => "2026-07-18T11:00:00Z"
      },
      services: [
        { "type" => "<script>alert(1)</script>", "url" => "https://example.com/?x=&quot;" }
      ],
      registration_json: "<script>registration()</script>",
      presence_json: "<img src=x onerror=presence()>"
    )

    post_with_result(result)

    expect(last_response.body).not_to include("<script>alert(1)</script>")
    expect(last_response.body).not_to include("<script>registration()</script>")
    expect(last_response.body).not_to include("<img src=x onerror=presence()>")
    expect(last_response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
    expect(last_response.body).to include("&lt;img src=x onerror=presence()&gt;")
  end

  it "renders structured failures without presenting services as trusted" do
    result = OppResolver::Result.failure(
      :invalid_presence,
      "Unsafe <failure> detail.",
      subject: "key:sha256:requested",
      directory_url: "https://directory.example",
      stage: :presence,
      verification_errors: [
        { code: "validation", path: "services[0].url", message: "URL <invalid>" }
      ]
    )

    post_with_result(result)

    expect(last_response.status).to eq(422)
    expect(last_response.body).to include("Resolution stopped")
    expect(last_response.body).to include("services[0].url")
    expect(last_response.body).to include("URL &lt;invalid&gt;")
    expect(last_response.body).not_to include("Unsafe <failure> detail.")
    expect(last_response.body).not_to include("Trusted services")
    expect(last_response.body).not_to include("service-card")
  end
end
