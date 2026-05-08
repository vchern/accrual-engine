require 'rake'

ENV['APP_ENV'] ||= 'development'

namespace :db do
  desc 'Run pending migrations'
  task :migrate do
    require_relative 'config/boot'
    require 'sequel/core'
    Sequel.extension :migration
    Sequel::Migrator.run(DB, File.join(ROOT, 'db', 'migrations'))
    puts "Migrated #{APP_ENV} database to latest version."
  end

  desc 'Roll back the most recent migration'
  task :rollback do
    require_relative 'config/boot'
    Sequel.extension :migration
    current = DB[:schema_migrations].max(:filename) rescue nil
    Sequel::Migrator.run(DB, File.join(ROOT, 'db', 'migrations'), target: 0, current: current)
    puts 'Rolled back.'
  end

  desc 'Drop, migrate, seed'
  task setup: %i[drop migrate seed]

  desc 'Drop the database'
  task :drop do
    require_relative 'config/boot'
    DB.disconnect
    path = DB_PATHS.fetch(APP_ENV)
    File.delete(path) if File.exist?(path)
    puts "Dropped #{path}."
  end

  desc 'Seed from the anchor XLSX + synthetic prior-period usage'
  task :seed do
    require_relative 'db/seeds'
  end
end

namespace :assets do
  TAILWIND_INPUT  = 'tailwind/input.css'.freeze
  TAILWIND_OUTPUT = 'public/application.css'.freeze
  TAILWIND_CONFIG = 'tailwind/tailwind.config.js'.freeze

  desc 'Compile Tailwind CSS once (minified)'
  task :tailwind do
    sh "bundle exec tailwindcss -i #{TAILWIND_INPUT} -o #{TAILWIND_OUTPUT} -c #{TAILWIND_CONFIG} --minify"
  end

  desc 'Watch Tailwind CSS in dev'
  task :watch do
    sh "bundle exec tailwindcss -i #{TAILWIND_INPUT} -o #{TAILWIND_OUTPUT} -c #{TAILWIND_CONFIG} --watch"
  end
end

desc 'Run the test suite'
task :spec do
  sh 'bundle exec rspec'
end

task default: :spec
