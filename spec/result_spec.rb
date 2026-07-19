require "spec_helper"

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

  it "deep-freezes nested arrays and hashes" do
    result = described_class.success(services: [{ "type" => "profile" }])

    expect { result.details[:services] << {} }.to raise_error(FrozenError)
    expect { result.details[:services][0]["type"].replace("other") }.to raise_error(FrozenError)
  end
end
