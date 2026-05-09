require 'spec_helper'

RSpec.describe 'End-to-end close against the Helix anchor' do
  let(:close_run) { create_close_run }

  before { Seeder.run!(log: ->(_) {}) }

  it 'AR=$362.50, AP=$100,000.00 → close total $100,362.50' do
    Accruals::Engine.new(close_run).run!

    ar = Accrual.where(close_run_id: close_run.id, entity_kind: 'ar')
                .map(:amount_usd).reduce(BigDecimal('0'), :+)
    ap = Accrual.where(close_run_id: close_run.id, entity_kind: 'ap')
                .map(:amount_usd).reduce(BigDecimal('0'), :+)

    expect(ar).to eq(BigDecimal('362.50'))
    expect(ap).to eq(BigDecimal('100000.00'))
    expect(ar + ap).to eq(BigDecimal('100362.50'))
  end

  it 'flags CUS-1001 for the Mar 30 anomaly but accrues the actual quantity' do
    Accruals::Engine.new(close_run).run!

    acc = Accrual.where(idempotency_key: 'ar_usage|2026-03-31|CUS-1001').first
    expect(acc.status).to eq('flagged')
    expect(acc.flagged_reason).to include('2026-03-30')
    expect(acc.amount_usd).to eq(BigDecimal('202.50'))
  end

  it 'persists FX detail for the EUR-billed customer' do
    Accruals::Engine.new(close_run).run!

    acc = Accrual.where(idempotency_key: 'ar_usage|2026-03-31|CUS-1002').first
    expect(acc.amount_usd).to eq(BigDecimal('60.00'))
    expect(acc.billing_currency).to eq('EUR')
    expect(acc.fx_rate).to eq(BigDecimal('1.08'))
    expect(acc.amount_billing_ccy).to eq(BigDecimal('55.5556'))
  end

  it 'generates one consolidated accrual JE + one reversal JE; reversal dated 2026-04-01' do
    Accruals::Engine.new(close_run).run!

    accrual_count = Accrual.where(close_run_id: close_run.id).count
    expect(JournalEntry.where(close_run_id: close_run.id, entry_type: 'accrual').count).to eq(1)
    expect(JournalEntry.where(close_run_id: close_run.id, entry_type: 'reversal').count).to eq(1)
    # Each accrual contributes 2 lines to each of the 2 JEs.
    expect(JournalLine.count).to eq(accrual_count * 4)
    expect(JournalEntry.where(close_run_id: close_run.id, entry_type: 'reversal').map(:entry_date).uniq)
      .to eq([Date.new(2026, 4, 1)])
  end

  it 're-running the same close is idempotent' do
    Accruals::Engine.new(close_run).run!
    first_ids   = Accrual.where(close_run_id: close_run.id).map(:id).sort
    first_total = Accrual.where(close_run_id: close_run.id).map(:amount_usd).reduce(BigDecimal('0'), :+)

    Accruals::Engine.new(close_run).run!
    second_ids   = Accrual.where(close_run_id: close_run.id).map(:id).sort
    second_total = Accrual.where(close_run_id: close_run.id).map(:amount_usd).reduce(BigDecimal('0'), :+)

    expect(second_ids).to eq(first_ids)
    expect(second_total).to eq(first_total)
  end

  it 'a different period_end is calendar-month-bounded' do
    Accruals::Engine.new(close_run).run!  # Mar 31 close

    apr_close = CloseRun.create(
      period_start: Date.new(2026, 4, 1),
      period_end:   Date.new(2026, 4, 30),
      status:       'pending'
    )
    Accruals::Engine.new(apr_close).run!

    # AR window is Apr 1..Apr 30 — no events in April, so no AR accruals.
    expect(Accrual.where(close_run_id: apr_close.id, entity_kind: 'ar').count).to eq(0)

    # AP receipt is still uninvoiced → re-accrued under a period-scoped key.
    ap = Accrual.where(close_run_id: apr_close.id, entity_kind: 'ap').first
    expect(ap.amount_usd).to eq(BigDecimal('100000.00'))
    expect(ap.idempotency_key).to start_with('ap_gr_not_invoiced|2026-04-30|')

    # March's AP accrual is preserved (different idempotency key per period).
    expect(Accrual.where(close_run_id: close_run.id, entity_kind: 'ap').count).to eq(1)
  end

  it 'CSV export covers every line and balances DR/CR' do
    Accruals::Engine.new(close_run).run!
    csv_text = Accruals::JournalCsvExporter.call(close_run)
    rows = CSV.parse(csv_text, headers: true)

    debit_total  = rows.map { |r| BigDecimal(r['debit_usd']) }.reduce(:+)
    credit_total = rows.map { |r| BigDecimal(r['credit_usd']) }.reduce(:+)
    expect(debit_total).to eq(credit_total)
    expect(rows.map { |r| r['handler'] }.uniq.sort).to eq(%w[ap_gr_not_invoiced ar_usage])
  end
end
