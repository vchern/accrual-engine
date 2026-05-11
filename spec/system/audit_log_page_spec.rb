require 'spec_helper'

RSpec.describe 'GET /audit', type: :request do
  it 'renders an empty-state hint when there are no events' do
    get '/audit'
    expect(last_response).to be_ok
    expect(last_response.body).to include('No audit events yet')
  end

  context 'after running and deleting closes' do
    before do
      Seeder.run!(log: ->(_) {})
      post '/closes', period_end: '2026-03-31'
      post '/closes', period_end: '2026-04-30'
    end

    it 'lists events from all closes, most-recent first' do
      get '/audit'
      expect(last_response).to be_ok
      expect(last_response.body).to include('run_started')
      expect(last_response.body).to include('run_completed')
      # Both periods appear since both ran
      expect(last_response.body).to include('2026-03-31')
      expect(last_response.body).to include('2026-04-30')
    end

    it 'surfaces close_deleted with the period snapshot after deletion' do
      target = CloseRun.where(period_end: Date.new(2026, 3, 31)).first
      post "/closes/#{target.id}/delete"

      get '/audit'
      expect(last_response.body).to include('close_deleted')
      expect(last_response.body).to include('(deleted)')
      expect(last_response.body).to include('2026-03-31')          # snapshotted period_end
      # Other close still has its row visible
      expect(last_response.body).to include('2026-04-30')
    end
  end
end
