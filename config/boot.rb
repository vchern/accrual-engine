require 'bundler/setup'
Bundler.require(:default, ENV.fetch('APP_ENV', 'development').to_sym)

require 'dotenv/load' if %w[development test].include?(ENV.fetch('APP_ENV', 'development'))

ROOT = File.expand_path('..', __dir__).freeze
APP_ENV = ENV.fetch('APP_ENV', 'development').freeze

require_relative 'database'

# Autoload application code (Zeitwerk would be cleaner; for a take-home, explicit requires)
Dir[File.join(ROOT, 'lib', '**', '*.rb')].sort.each { |f| require f }
