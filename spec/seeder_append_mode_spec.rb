require 'spec_helper'

RSpec.describe Seeder, 'append mode' do
  let(:anchor_path) { File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx') }

  it 'second seed in append mode is a no-op for fully-overlapping data' do
    described_class.run!(path: anchor_path, log: ->(_) {})
    counts = {
      customers:        Customer.count,
      skus:             Sku.count,
      gl_accounts:      GlAccount.count,
      vendors:          Vendor.count,
      fx_rates:         FxRate.count,
      chargebee:        ChargebeeInvoice.count,
      purchase_orders:  PurchaseOrder.count,
      po_lines:         PoLine.count,
      goods_receipts:   GoodsReceipt.count,
      usage_events:     UsageEvent.count
    }

    expect {
      described_class.run!(path: anchor_path, log: ->(_) {}, mode: :append)
    }.not_to raise_error

    expect(Customer.count).to        eq(counts[:customers])
    expect(Sku.count).to             eq(counts[:skus])
    expect(GlAccount.count).to       eq(counts[:gl_accounts])
    expect(Vendor.count).to          eq(counts[:vendors])
    expect(FxRate.count).to          eq(counts[:fx_rates])
    expect(ChargebeeInvoice.count).to eq(counts[:chargebee])
    expect(PurchaseOrder.count).to   eq(counts[:purchase_orders])
    expect(PoLine.count).to          eq(counts[:po_lines])
    expect(GoodsReceipt.count).to    eq(counts[:goods_receipts])
    expect(UsageEvent.count).to      eq(counts[:usage_events])
  end

  it 'invalid mode falls back to :replace silently' do
    expect { described_class.run!(path: anchor_path, log: ->(_) {}, mode: :nonsense) }
      .not_to raise_error
    expect(Customer.count).to eq(3)
  end
end
