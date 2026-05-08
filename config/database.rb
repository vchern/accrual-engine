require 'sequel'

DB_PATHS = {
  'development' => File.join(ROOT, 'db', 'development.sqlite3'),
  'test'        => File.join(ROOT, 'db', 'test.sqlite3'),
  'production'  => ENV.fetch('DATABASE_PATH', File.join(ROOT, 'db', 'production.sqlite3'))
}.freeze

DB = Sequel.sqlite(DB_PATHS.fetch(APP_ENV))
DB.extension :pagination
