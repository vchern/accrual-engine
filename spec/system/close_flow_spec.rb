require 'spec_helper'
require 'csv'

RSpec.describe 'Close-run UI flow', type: :request do
  before { Seeder.run!(log: ->(_) {}) }

  it 'walks through index → run engine → drill through → CSV download' do
    # 1. Empty index
    get '/closes'
    expect(last_response).to be_ok
    expect(last_response.body).to include('No closes yet')
    expect(last_response.body).to include('Run engine')

    # 2. Run a close via POST
    post '/closes', period_end: '2026-03-31'
    expect(last_response.status).to eq(302)
    follow_redirect!
    expect(last_response).to be_ok

    # 3. Show page renders the totals + flagged badge
    expect(last_response.body).to include('$100,362.50')   # total accrual
    expect(last_response.body).to include('$202.50')       # CUS-1001 in flagged list
    expect(last_response.body).to include('Flagged')       # overview banner heading

    # 4. Index now lists this close with the totals
    get '/closes'
    expect(last_response.body).to include('$100,362.50')
    expect(last_response.body).to include('completed')

    close_run_id = CloseRun.last.id

    # 5. Accruals tab + flagged filter
    get "/closes/#{close_run_id}?tab=accruals&filter=flagged"
    expect(last_response.body).to include('CUS-1001')
    expect(last_response.body).not_to include('CUS-1002')
    expect(last_response.body).not_to include('CUS-1003')

    # 6. Journal-entries tab
    get "/closes/#{close_run_id}?tab=journal"
    expect(last_response.body).to include('Accrued Revenue')
    expect(last_response.body).to include('reversal')

    # 7. Drill-through to a single accrual
    accrual = Accrual.where(idempotency_key: 'ar_usage|2026-03-31|CUS-1001').first
    get "/closes/#{close_run_id}/accruals/#{accrual.id}"
    expect(last_response).to be_ok
    expect(last_response.body).to include('UsageEvent')
    expect(last_response.body).to include('Source records')

    # 8. CSV export
    get "/closes/#{close_run_id}/journal_entries.csv"
    expect(last_response).to be_ok
    expect(last_response.headers['Content-Type']).to include('text/csv')
    expect(last_response.headers['Content-Disposition']).to include('journal_entries_2026-03-31.csv')
    rows = CSV.parse(last_response.body, headers: true)
    expect(rows.map { |r| r['handler'] }.uniq.sort).to eq(%w[ap_gr_not_invoiced ar_usage])
    debit_total  = rows.map { |r| BigDecimal(r['debit_usd']) }.reduce(:+)
    credit_total = rows.map { |r| BigDecimal(r['credit_usd']) }.reduce(:+)
    expect(debit_total).to eq(credit_total)
  end

  it 'POST /closes is idempotent — re-running the same period reuses the close run' do
    post '/closes', period_end: '2026-03-31'
    follow_redirect!
    first_id = CloseRun.where(period_end: Date.new(2026, 3, 31)).first.id

    post '/closes', period_end: '2026-03-31'
    follow_redirect!
    expect(CloseRun.where(period_end: Date.new(2026, 3, 31)).count).to eq(1)
    expect(CloseRun.where(period_end: Date.new(2026, 3, 31)).first.id).to eq(first_id)
    expect(Accrual.count).to eq(4)
  end

  it 'returns 404 for unknown close run / accrual' do
    get '/closes/9999'
    expect(last_response.status).to eq(404)

    post '/closes', period_end: '2026-03-31'
    follow_redirect!
    close_id = CloseRun.last.id
    get "/closes/#{close_id}/accruals/9999"
    expect(last_response.status).to eq(404)
  end
end
