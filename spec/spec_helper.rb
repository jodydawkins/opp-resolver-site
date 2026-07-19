ENV["RACK_ENV"] = "test"

require "rack/test"
require "rspec"
require_relative "../app"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
