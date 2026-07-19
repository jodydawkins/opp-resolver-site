# frozen_string_literal: true

require "sinatra/base"
require_relative "lib/opp_resolver/result"
require_relative "lib/opp_resolver/resolver"

module OppResolver
  class App < Sinatra::Base
    DEFAULT_DIRECTORY_URL = "https://directory.openpresenceprotocol.org"
    EXAMPLE_SUBJECT = "key:sha256:r04mk-KJfvTnlnVSTUpnT283CGbHSWJkFMevj-G72Ts"

    def self.default_resolver_factory
      -> do
        Resolver.new(
          directory_url: ENV.fetch("OPP_DIRECTORY_URL", DEFAULT_DIRECTORY_URL)
        )
      end
    end

    set :resolver_factory, default_resolver_factory

    helpers do
      def h(value)
        Rack::Utils.escape_html(value.to_s)
      end
    end

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
