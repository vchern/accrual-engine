require 'spec_helper'

RSpec.describe 'POST /closes/reset', type: :request do
  before { Seeder.run!(log: ->(_) {}) }

  it 'clears engine tables but preserves reference and transaction data' do
    post '/closes', period_end: '2026-03-31'
    follow_redirect!

    expect(CloseRun.count).to eq(1)
    expect(Accrual.count).to be > 0
    expect(JournalEntry.count).to be > 0
    expect(JournalLine.count).to be > 0

    customer_count   = Customer.count
    sku_count        = Sku.count
    usage_count      = UsageEvent.count
    po_count         = PurchaseOrder.count
    gr_count         = GoodsReceipt.count
    gl_count         = GlAccount.count

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

    # Reference / transaction data preserved
    expect(Customer.count).to       eq(customer_count)
    expect(Sku.count).to            eq(sku_count)
    expect(UsageEvent.count).to     eq(usage_count)
    expect(PurchaseOrder.count).to  eq(po_count)
    expect(GoodsReceipt.count).to   eq(gr_count)
    expect(GlAccount.count).to      eq(gl_count)
  end
end
