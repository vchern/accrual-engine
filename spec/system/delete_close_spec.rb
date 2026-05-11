require 'spec_helper'

RSpec.describe 'POST /closes/:id/delete', type: :request do
  before { Seeder.run!(log: ->(_) {}) }

  it 'deletes one close and its children, leaves other closes alone' do
    post '/closes', period_end: '2026-03-31'
    post '/closes', period_end: '2026-04-30'

    target = CloseRun.where(period_end: Date.new(2026, 3, 31)).first
    other  = CloseRun.where(period_end: Date.new(2026, 4, 30)).first

    target_accrual_ids = Accrual.where(close_run_id: target.id).select_map(:id)
    target_je_ids      = JournalEntry.where(close_run_id: target.id).select_map(:id)
    other_accrual_count = Accrual.where(close_run_id: other.id).count

    post "/closes/#{target.id}/delete"
    expect(last_response.status).to eq(302)
    expect(last_response.headers['Location']).to end_with('/closes')

    expect(CloseRun[target.id]).to be_nil
    expect(Accrual.where(id: target_accrual_ids).count).to eq(0)
    expect(AccrualSource.where(accrual_id: target_accrual_ids).count).to eq(0)
    expect(JournalLine.where(journal_entry_id: target_je_ids).count).to eq(0)
    expect(JournalEntry.where(close_run_id: target.id).count).to eq(0)
    expect(AuditEvent.where(close_run_id: target.id).count).to eq(0)

    expect(CloseRun[other.id]).not_to be_nil
    expect(Accrual.where(close_run_id: other.id).count).to eq(other_accrual_count)
  end

  it 'preserves reference and transaction data' do
    post '/closes', period_end: '2026-03-31'
    close_run = CloseRun.first

    customer_count = Customer.count
    sku_count      = Sku.count
    usage_count    = UsageEvent.count

    post "/closes/#{close_run.id}/delete"

    expect(Customer.count).to   eq(customer_count)
    expect(Sku.count).to        eq(sku_count)
    expect(UsageEvent.count).to eq(usage_count)
  end

  it '404s on an unknown close id' do
    post '/closes/9999/delete'
    expect(last_response.status).to eq(404)
  end

  it 'writes a close_deleted audit event that survives the close deletion' do
    post '/closes', period_end: '2026-03-31'
    close_run = CloseRun.first
    accrual_count = Accrual.where(close_run_id: close_run.id).count

    post "/closes/#{close_run.id}/delete"

    deletion = AuditEvent.where(action: 'close_deleted').first
    expect(deletion).not_to be_nil
    expect(deletion.close_run_id).to be_nil  # detached, so survives the cascade
    expect(deletion.payload_data).to include(
      'deleted_close_run_id' => close_run.id,
      'period_end'           => '2026-03-31',
      'accrual_count'        => accrual_count
    )
    expect(deletion.payload_data['total_amount_usd']).to be_a(String)
  end
end
