require 'spec_helper'
require 'csv'

RSpec.describe Accruals::JournalCsvExporter do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts
    stub_const('Accruals::Engine::HANDLERS', [fake_handler_class(amount_usd: BigDecimal('100.00'))])
    Accruals::Engine.new(close_run).run!
  end

  it 'emits a header row + one row per journal line' do
    rows = CSV.parse(described_class.call(close_run))
    expect(rows.size).to eq(5)        # header + 4 lines (2 accrual + 2 reversal)
    expect(rows.first).to eq(described_class::HEADERS)
  end

  it 'covers both accrual and reversal entries' do
    rows = CSV.parse(described_class.call(close_run), headers: true)
    expect(rows.map { |r| r['entry_type'] }.uniq).to contain_exactly('accrual', 'reversal')
  end

  it 'formats decimals to 2dp and balances DR/CR across all lines' do
    rows = CSV.parse(described_class.call(close_run), headers: true)
    debits  = rows.map { |r| BigDecimal(r['debit_usd']) }.reduce(:+)
    credits = rows.map { |r| BigDecimal(r['credit_usd']) }.reduce(:+)
    expect(debits).to eq(credits)
    expect(rows.first['debit_usd']).to match(/\A\d+\.\d{2}\z/)
  end
end
