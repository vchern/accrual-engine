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

RSpec.describe 'JournalCsvExporter source_refs against canonical anchor', type: :request do
  let(:close_run) { create_close_run }

  before { Seeder.run!(log: ->(_) {}) }

  it 'emits source_refs with natural ids from the XLSX (not internal PKs)' do
    Accruals::Engine.new(close_run).run!
    csv = Accruals::JournalCsvExporter.call(close_run)
    rows = CSV.parse(csv, headers: true)

    refs = rows.map { |r| r['source_refs'] }.reject(&:empty?).join(';')

    # AR accruals link UsageEvent rows by their natural event_id (e.g. evt_u0001)
    expect(refs).to match(/UsageEvent#evt_u\d+/)

    # AP accrual for the canonical receipt links GR-2026-0042 and PO-2026-0188/L1
    expect(refs).to include('GoodsReceipt#GR-2026-0042')
    expect(refs).to include('PoLine#PO-2026-0188/L1')

    # And not internal integer PKs
    expect(refs).not_to match(/UsageEvent#\d+\b/)
    expect(refs).not_to match(/GoodsReceipt#\d+\b/)
  end
end
