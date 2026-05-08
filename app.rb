require 'sinatra/base'
require 'sinatra/contrib'
require_relative 'lib/models'
require_relative 'lib/accruals'
require_relative 'lib/seeder'

module Lambda
  class App < Sinatra::Base
    set :root, ROOT
    set :views, File.join(ROOT, 'views')
    set :public_folder, File.join(ROOT, 'public')
    set :default_encoding, 'utf-8'

    configure :development do
      register Sinatra::Reloader
      also_reload File.join(ROOT, 'lib', '**', '*.rb')
    end

    helpers do
      def usd(amount)
        return '—' if amount.nil?
        "$#{format('%.2f', amount.to_d).reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
      end
    end

    get '/' do
      erb :home
    end

    get '/health' do
      content_type :json
      { status: 'ok', env: APP_ENV }.to_json
    end
  end
end
