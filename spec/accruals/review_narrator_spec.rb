require 'spec_helper'

RSpec.describe Accruals::ReviewNarrator do
  let(:close_run) { create_close_run }
  let(:flagged_accrual) do
    seed_minimal_gl_accounts
    Accrual.create(
      close_run_id:         close_run.id,
      handler_name:         'ar_usage',
      idempotency_key:      'ar_usage|2026-03-31|TEST',
      entity_kind:          'ar',
      status:               'flagged',
      flagged_reason:       '2026-03-30 GPU-H100-HR qty=25.0 (median 10.5, z=6.1)',
      memo:                 'AR usage accrual for TEST',
      amount_usd:           BigDecimal('202.50'),
      amount_billing_ccy:   BigDecimal('202.50'),
      billing_currency:     'USD',
      fx_rate:              BigDecimal('1'),
      fx_rate_date:         Date.new(2026, 3, 31),
      gl_debit_account_id:  GlAccount.where(account_code: '1310').first.id,
      gl_credit_account_id: GlAccount.where(account_code: '4010').first.id
    )
  end

  it 'returns nil when API key is missing' do
    expect(described_class.new(api_key: nil).narrate(flagged_accrual)).to be_nil
    expect(described_class.new(api_key: '').narrate(flagged_accrual)).to be_nil
    expect(described_class.new(api_key: '   ').narrate(flagged_accrual)).to be_nil
  end

  it 'returns nil for non-flagged accruals' do
    flagged_accrual.update(status: 'posted')
    narrator = described_class.new(api_key: 'fake', transport: ->(_) { 'should not be called' })
    expect(narrator.narrate(flagged_accrual)).to be_nil
  end

  it 'returns Result.text on transport success' do
    transport = ->(_prompt) { 'Verify with the customer that the Mar 30 spike was real workload.' }
    result = described_class.new(api_key: 'fake', transport: transport).narrate(flagged_accrual)
    expect(result.text).to include('Verify')
    expect(result.model).to eq(Accruals::ReviewNarrator::DEFAULT_MODEL)
    expect(result.error).to be_nil
  end

  it 'passes the structured signal into the prompt' do
    captured = nil
    transport = ->(prompt) { captured = prompt; 'narration' }
    described_class.new(api_key: 'fake', transport: transport).narrate(flagged_accrual)

    expect(captured).to include('2026-03-30')
    expect(captured).to include('z=6.1')
    expect(captured).to include('202.50')
    expect(captured).to include('Do NOT compute or invent amounts')
  end

  it 'captures Result.error on transport failure (best-effort, no raise)' do
    transport = ->(_) { raise 'rate limited' }
    result = described_class.new(api_key: 'fake', transport: transport).narrate(flagged_accrual)
    expect(result.error).to eq('rate limited')
    expect(result.text).to be_nil
  end
end
