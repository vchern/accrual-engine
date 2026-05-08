require 'spec_helper'

RSpec.describe Accruals::Handlers::ArUsage do
  let(:close_run) { create_close_run }

  before { Seeder.run!(log: ->(_) {}) }

  it 'produces one accrual per customer with usage in the unbilled window' do
    drafts = described_class.new(close_run).call
    expect(drafts.size).to eq(3)
    expect(drafts.map(&:idempotency_key).sort).to eq([
      'ar_usage|2026-03-31|CUS-1001',
      'ar_usage|2026-03-31|CUS-1002',
      'ar_usage|2026-03-31|CUS-1003'
    ])
  end

  it 'CUS-1001: 45h × $4.50 = $202.50, flagged for the Mar 30 spike' do
    drafts = described_class.new(close_run).call
    cus_1001 = drafts.find { |d| d.idempotency_key.include?('CUS-1001') }
    expect(cus_1001.amount_usd).to eq(BigDecimal('202.50'))
    expect(cus_1001.status).to eq('flagged')
    expect(cus_1001.flagged_reason).to include('2026-03-30')
    expect(cus_1001.flagged_reason).to include('GPU-H100-HR')
  end

  it 'CUS-1002 (EUR): $60.00 USD, fx=1.08, billing_ccy ≈ €55.5556' do
    drafts = described_class.new(close_run).call
    cus_1002 = drafts.find { |d| d.idempotency_key.include?('CUS-1002') }
    expect(cus_1002.amount_usd).to eq(BigDecimal('60.00'))
    expect(cus_1002.billing_currency).to eq('EUR')
    expect(cus_1002.fx_rate).to eq(BigDecimal('1.08'))
    expect(cus_1002.amount_billing_ccy).to eq(BigDecimal('55.5556'))
    expect(cus_1002.status).to eq('posted')
  end

  it 'CUS-1003 (churned EOD Mar 29): single-day accrual = $100' do
    drafts = described_class.new(close_run).call
    cus_1003 = drafts.find { |d| d.idempotency_key.include?('CUS-1003') }
    expect(cus_1003.amount_usd).to eq(BigDecimal('100.00'))
    expect(cus_1003.sources.size).to eq(1)
  end

  it 'AR total across all 3 customers = $362.50 (matches the brief target)' do
    drafts = described_class.new(close_run).call
    total = drafts.map(&:amount_usd).reduce(BigDecimal('0'), :+)
    expect(total).to eq(BigDecimal('362.50'))
  end

  it 'each draft links its underlying UsageEvent rows as sources' do
    drafts = described_class.new(close_run).call
    cus_1001 = drafts.find { |d| d.idempotency_key.include?('CUS-1001') }
    expect(cus_1001.sources.size).to eq(3)
    expect(cus_1001.sources.first[:source_type]).to eq('UsageEvent')
  end
end
