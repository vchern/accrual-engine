require 'spec_helper'

RSpec.describe Seeder do
  it 'seeds the anchor + synthetic history into a clean DB' do
    described_class.run!(log: ->(_) {})

    aggregate_failures do
      expect(Customer.count).to eq(3)
      expect(Customer.where(status: 'churned').map(:customer_id)).to eq(['CUS-1003'])

      expect(Sku.count).to eq(3)
      expect(Vendor.count).to eq(1)
      expect(GlAccount.count).to eq(4)

      expect(PurchaseOrder.count).to eq(1)
      expect(PoLine.count).to eq(1)
      expect(GoodsReceipt.count).to eq(1)
      expect(VendorInvoice.count).to eq(0)

      expect(ChargebeeInvoice.count).to eq(3)

      anchor = UsageEvent.where(Sequel.~(Sequel.like(:event_id, 'evt_synth_%')))
      synth  = UsageEvent.where(Sequel.like(:event_id, 'evt_synth_%'))
      expect(anchor.count).to eq(10)    # 3 on Mar 28 + 7 across Mar 29-31
      expect(synth.count).to eq(90)     # 30 days × 3 customers (synth window ends pre-churn)

      expect(FxRate.where(from_ccy: 'EUR', to_ccy: 'USD').count).to eq(31)
      # Canonical has no JPY/GBP/SGD customers, so no rates seeded for those.
      expect(FxRate.where(from_ccy: %w[JPY GBP SGD]).count).to eq(0)
      expect(FxRate.count).to eq(31)

      cobra = Customer.where(customer_id: 'CUS-1003').first
      expect(cobra.churned?).to be true
      expect(cobra.churned_at).to be_a(Time)
    end
  end
end
