require 'spec_helper'

RSpec.describe Accruals::Handlers::ApGoodsReceiptNotInvoiced do
  let(:close_run) { create_close_run }

  before { Seeder.run!(log: ->(_) {}) }

  it 'accrues $100,000 for the partial Dell receipt (matches the brief target)' do
    drafts = described_class.new(close_run).call
    expect(drafts.size).to eq(1)
    expect(drafts.first.amount_usd).to eq(BigDecimal('100000.00'))
  end

  it 'codes DR 1480 / CR 2150 per the GL chart' do
    draft = described_class.new(close_run).call.first
    expect(GlAccount[draft.gl_debit_account_id].account_code).to eq('1480')
    expect(GlAccount[draft.gl_credit_account_id].account_code).to eq('2150')
  end

  it 'links GoodsReceipt and PoLine as audit sources' do
    draft = described_class.new(close_run).call.first
    types = draft.sources.map { |s| s[:source_type] }.sort
    expect(types).to eq(%w[GoodsReceipt PoLine])
  end

  it 'skips fully-invoiced receipts' do
    receipt = GoodsReceipt.first
    VendorInvoice.create(
      invoice_number:    'TEST-FULL',
      vendor_id:         receipt.vendor.id,
      purchase_order_id: receipt.purchase_order.id,
      invoice_date:      Date.new(2026, 3, 30),
      subtotal_usd:      receipt.value_usd,
      status:            'posted'
    )
    expect(described_class.new(close_run).call).to be_empty
  end

  it 'accrues only the uninvoiced remainder when partially invoiced' do
    receipt = GoodsReceipt.first
    VendorInvoice.create(
      invoice_number:    'TEST-PARTIAL',
      vendor_id:         receipt.vendor.id,
      purchase_order_id: receipt.purchase_order.id,
      invoice_date:      Date.new(2026, 3, 30),
      subtotal_usd:      BigDecimal('40000'),
      status:            'posted'
    )
    drafts = described_class.new(close_run).call
    expect(drafts.first.amount_usd).to eq(BigDecimal('60000'))
  end

  it 'emits a blocked draft (instead of raising) when the PO references an unknown GL code' do
    PurchaseOrder.first.update(gl_account_code: '9999-DOES-NOT-EXIST')

    drafts = described_class.new(close_run).call
    expect(drafts.size).to eq(1)

    blocked = drafts.first
    expect(blocked.status).to eq('blocked')
    expect(blocked.gl_debit_account_id).to be_nil
    expect(blocked.flagged_reason).to include('9999-DOES-NOT-EXIST')
    expect(blocked.amount_usd).to eq(BigDecimal('100000.00'))   # amount still computed
  end
end
