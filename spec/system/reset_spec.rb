require 'spec_helper'

RSpec.describe 'POST /closes/reset', type: :request do
  before { Seeder.run!(log: ->(_) {}) }

  it 'wipes ALL tables (engine state + imported reference + transaction data)' do
    post '/closes', period_end: '2026-03-31'
    follow_redirect!

    expect(CloseRun.count).to eq(1)
    expect(Accrual.count).to be > 0
    expect(JournalEntry.count).to be > 0
    expect(JournalLine.count).to be > 0
    expect(Customer.count).to be > 0
    expect(UsageEvent.count).to be > 0

    post '/closes/reset'
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')

    # Engine state gone
    expect(CloseRun.count).to       eq(0)
    expect(Accrual.count).to        eq(0)
    expect(AccrualSource.count).to  eq(0)
    expect(JournalEntry.count).to   eq(0)
    expect(JournalLine.count).to    eq(0)
    expect(AuditEvent.count).to     eq(0)

    # Imported data gone too
    expect(Customer.count).to         eq(0)
    expect(Sku.count).to              eq(0)
    expect(Vendor.count).to           eq(0)
    expect(GlAccount.count).to        eq(0)
    expect(FxRate.count).to           eq(0)
    expect(UsageEvent.count).to       eq(0)
    expect(ChargebeeInvoice.count).to eq(0)
    expect(PurchaseOrder.count).to    eq(0)
    expect(PoLine.count).to           eq(0)
    expect(GoodsReceipt.count).to     eq(0)
    expect(VendorInvoice.count).to    eq(0)
  end
end
