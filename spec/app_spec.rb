require "spec_helper"

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

  it "builds the production resolver from the application configuration" do
    app.set :resolver_factory, app.default_resolver_factory

    expect(app.settings.resolver_factory).to be_a(OppResolver::Resolver)
  end
end
