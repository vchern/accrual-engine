ENV['APP_ENV'] = 'test'

require_relative '../config/boot'
require_relative '../app'
require 'rspec'
require 'rack/test'

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.mock_with :rspec do |c|
    c.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Wrap every example in a Sequel transaction so DB state is isolated.
  config.around(:each) do |example|
    DB.transaction(rollback: :always, auto_savepoint: true) { example.run }
  end
end

module RackHelpers
  include Rack::Test::Methods
  def app
    Lambda::App
  end
end

RSpec.configure { |c| c.include RackHelpers, type: :request }
