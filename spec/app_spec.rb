require 'spec_helper'

RSpec.describe Lambda::App, type: :request do
  describe 'GET /health' do
    it 'returns ok' do
      get '/health'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('ok')
    end
  end

  describe 'GET /' do
    it 'renders the home page' do
      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('Period close')
    end
  end
end
