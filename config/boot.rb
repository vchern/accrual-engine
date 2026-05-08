require 'bundler/setup'
Bundler.require(:default, ENV.fetch('APP_ENV', 'development').to_sym)

require 'dotenv/load' if %w[development test].include?(ENV.fetch('APP_ENV', 'development'))

ROOT = File.expand_path('..', __dir__).freeze
APP_ENV = ENV.fetch('APP_ENV', 'development').freeze

require_relative 'database'

# Application code (models, engine) is required *after* the DB schema exists.
# See lib/models.rb and lib/accruals.rb. Boot only sets up the DB connection.
