require 'sequel'

DB_PATHS = {
  'development' => File.join(ROOT, 'db', 'development.sqlite3'),
  'test'        => File.join(ROOT, 'db', 'test.sqlite3'),
  'production'  => ENV.fetch('DATABASE_PATH', File.join(ROOT, 'db', 'production.sqlite3'))
}.freeze

DB = Sequel.sqlite(DB_PATHS.fetch(APP_ENV))
DB.extension :pagination

# Models load even before migrations have run (Rakefile path).
Sequel::Model.require_valid_table = false
Sequel::Model.plugin :timestamps, update_on_create: true
