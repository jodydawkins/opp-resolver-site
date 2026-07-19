# frozen_string_literal: true

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
      @result = settings.resolver_factory.resolve(params.fetch("subject", ""))
      status 422 unless @result.ok?
      erb :result
    end
  end
end
