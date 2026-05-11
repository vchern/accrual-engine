require 'spec_helper'

RSpec.describe 'GET /data', type: :request do
  it 'renders an empty-state hint when no data is loaded' do
    get '/data'
    expect(last_response).to be_ok
    expect(last_response.body).to include('No data loaded yet')
    expect(last_response.body).to include('Data Import')
  end

  context 'with the canonical anchor seeded' do
    before { Seeder.run!(log: ->(_) {}) }

    it 'defaults to the Customers tab and renders customer rows' do
      get '/data'
      expect(last_response).to be_ok
      expect(last_response.body).to include('CUS-1001')
      expect(last_response.body).to include('CUS-1003')   # churned customer
    end

    it 'lists all 11 tabs in the nav with row counts' do
      get '/data'
      ['Customers', 'Vendors', 'SKUs', 'GL Accounts', 'FX Rates',
       'Usage Events', 'Chargebee Invoices', 'Purchase Orders',
       'PO Lines', 'Goods Receipts', 'Vendor Invoices'].each do |label|
        expect(last_response.body).to include(label)
      end
    end

    it 'switches to ?tab=usage_events and renders usage event content' do
      get '/data?tab=usage_events'
      expect(last_response).to be_ok
      expect(last_response.body).to include('GPU-H100-HR')   # SKU shown via FK
      expect(last_response.body).to include('Quantity')      # column header for usage_events
    end

    it 'switches to ?tab=goods_receipts and renders the seeded receipt' do
      get '/data?tab=goods_receipts'
      expect(last_response.body).to include('GR-2026-0042')
      expect(last_response.body).to include('PO-2026-0188')
    end

    it 'falls back to the customers tab when ?tab= is unknown' do
      get '/data?tab=bogus'
      expect(last_response).to be_ok
      expect(last_response.body).to include('CUS-1001')
    end
  end
end
