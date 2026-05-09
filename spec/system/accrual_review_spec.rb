require 'spec_helper'

RSpec.describe 'POST /closes/:id/accruals/:aid/review', type: :request do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts
    flagged_handler = fake_handler_class(
      status:          'flagged',
      flagged_reason:  '2026-03-30 GPU-H100-HR qty=25.0 (median 10.5, z=6.1)',
      idempotency_key: 'fake|2026-03-31|FLAG'
    )
    stub_const('Accruals::Engine::HANDLERS', [flagged_handler])
    Accruals::Engine.new(close_run).run!
  end

  let(:flagged_accrual) { Accrual.where(status: 'flagged').first }

  it 'flagged accrual is excluded from the JE before review' do
    expect(JournalLine.where(accrual_id: flagged_accrual.id).count).to eq(0)
  end

  describe 'approve' do
    it 'flips status to approved and lands the accrual on the JE' do
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'approved'
      expect(last_response.status).to eq(302)

      flagged_accrual.refresh
      expect(flagged_accrual.status).to eq('approved')
      # 2 lines on the accrual JE + 2 mirror lines on the reversal JE
      expect(JournalLine.where(accrual_id: flagged_accrual.id).count).to eq(4)
    end

    it 'audits the transition with prev->current status' do
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'approved'
      ev = AuditEvent.where(action: 'accrual_approved', accrual_id: flagged_accrual.id).first
      expect(ev).not_to be_nil
      expect(ev.payload_data).to include('previous_status' => 'flagged', 'current_status' => 'approved')
    end
  end

  describe 'reject' do
    it 'flips status to rejected and keeps the accrual off the JE' do
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'rejected'
      expect(last_response.status).to eq(302)

      flagged_accrual.refresh
      expect(flagged_accrual.status).to eq('rejected')
      expect(JournalLine.where(accrual_id: flagged_accrual.id).count).to eq(0)
    end
  end

  describe 'reset' do
    it 'returns approved to flagged and removes from JE' do
      flagged_accrual.update(status: 'approved')
      Accruals::Engine.new(close_run).regenerate_journal_entries
      expect(JournalLine.where(accrual_id: flagged_accrual.id).count).to eq(4)

      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'reset'
      expect(last_response.status).to eq(302)

      flagged_accrual.refresh
      expect(flagged_accrual.status).to eq('flagged')
      expect(JournalLine.where(accrual_id: flagged_accrual.id).count).to eq(0)
    end
  end

  describe 'guards' do
    it 'rejects approve when accrual is not flagged' do
      flagged_accrual.update(status: 'approved')
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'approved'
      expect(last_response.status).to eq(422)
    end

    it 'rejects reset when accrual is still flagged' do
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'reset'
      expect(last_response.status).to eq(422)
    end

    it '400 on unknown decision' do
      post "/closes/#{close_run.id}/accruals/#{flagged_accrual.id}/review", decision: 'maybe'
      expect(last_response.status).to eq(400)
    end
  end

  describe 'engine re-run preserves human decisions' do
    it 'approved status survives a fresh engine run' do
      flagged_accrual.update(status: 'approved')
      Accruals::Engine.new(close_run).run!
      expect(flagged_accrual.refresh.status).to eq('approved')
    end

    it 'rejected status survives too' do
      flagged_accrual.update(status: 'rejected')
      Accruals::Engine.new(close_run).run!
      expect(flagged_accrual.refresh.status).to eq('rejected')
    end
  end
end
