require 'spec_helper'

RSpec.describe Accruals::Engine do
  let(:close_run) { create_close_run }

  before { seed_minimal_gl_accounts }

  context 'with no handlers registered' do
    before { stub_const('Accruals::Engine::HANDLERS', []) }

    it 'completes cleanly with zero accruals' do
      result = described_class.new(close_run).run!
      expect(result.status).to eq('completed')
      expect(Accrual.count).to eq(0)
      expect(JournalEntry.count).to eq(0)
    end

    it 'writes started + completed audit events' do
      described_class.new(close_run).run!
      actions = AuditEvent.where(close_run_id: close_run.id).map(:action)
      expect(actions).to include('run_started', 'run_completed')
    end

    it 'sets started_at and completed_at on the close run' do
      result = described_class.new(close_run).run!
      expect(result.started_at).not_to be_nil
      expect(result.completed_at).not_to be_nil
    end
  end

  context 'with a fake handler returning one draft' do
    let(:handler) { fake_handler_class(amount_usd: BigDecimal('123.45')) }

    before { stub_const('Accruals::Engine::HANDLERS', [handler]) }

    it 'persists one accrual and a paired journal + reversal entry' do
      described_class.new(close_run).run!

      expect(Accrual.count).to eq(1)
      expect(Accrual.first.amount_usd).to eq(BigDecimal('123.45'))

      jes = JournalEntry.where(close_run_id: close_run.id).all
      expect(jes.size).to eq(2)
      expect(jes.map(&:entry_type).sort).to eq(%w[accrual reversal])

      accrual_je  = jes.find { |je| je.entry_type == 'accrual' }
      reversal_je = jes.find { |je| je.entry_type == 'reversal' }

      expect(accrual_je.entry_date).to  eq(Date.new(2026, 3, 31))
      expect(reversal_je.entry_date).to eq(Date.new(2026, 4, 1))
      expect(reversal_je.reverses_id).to eq(accrual_je.id)
    end

    it 'creates 4 journal lines in balance' do
      described_class.new(close_run).run!
      lines = JournalLine.all
      expect(lines.size).to eq(4)
      total_debit  = lines.map(&:debit_amount_usd).reduce(BigDecimal('0'), :+)
      total_credit = lines.map(&:credit_amount_usd).reduce(BigDecimal('0'), :+)
      expect(total_debit).to eq(total_credit)
      expect(total_debit).to eq(BigDecimal('246.90'))  # 123.45 × 2 (accrual + reversal)
    end

    it 're-running with same drafts is idempotent (no duplicates)' do
      engine = described_class.new(close_run)
      engine.run!
      first_id = Accrual.first.id

      engine.run!
      expect(Accrual.count).to eq(1)
      expect(Accrual.first.id).to eq(first_id)
      # Journal entries are regenerated each run; count stays the same.
      expect(JournalEntry.where(close_run_id: close_run.id).count).to eq(2)
      expect(JournalLine.count).to eq(4)
    end

    it 'audits the handler completion and run completion' do
      described_class.new(close_run).run!
      actions = AuditEvent.where(close_run_id: close_run.id).map(:action)
      expect(actions).to include('run_started', 'handler_completed', 'run_completed')

      handler_event = AuditEvent.where(close_run_id: close_run.id, action: 'handler_completed').first
      expect(handler_event.payload_data).to include('handler' => 'fake', 'count' => 1)
    end

    it 'preserves source links across re-runs' do
      handler_with_sources = fake_handler_class(
        sources: [{ source_type: 'GlAccount', source_id: GlAccount.first.id }]
      )
      stub_const('Accruals::Engine::HANDLERS', [handler_with_sources])

      described_class.new(close_run).run!
      expect(AccrualSource.count).to eq(1)
      described_class.new(close_run).run!
      expect(AccrualSource.count).to eq(1)
    end
  end

  context 'when amount changes between runs' do
    it 'audits the change and updates in place' do
      first_handler  = fake_handler_class(amount_usd: BigDecimal('100.00'))
      stub_const('Accruals::Engine::HANDLERS', [first_handler])
      described_class.new(close_run).run!

      second_handler = fake_handler_class(amount_usd: BigDecimal('150.00'))
      stub_const('Accruals::Engine::HANDLERS', [second_handler])
      described_class.new(close_run).run!

      expect(Accrual.count).to eq(1)
      expect(Accrual.first.amount_usd).to eq(BigDecimal('150.00'))

      change_event = AuditEvent.where(action: 'accrual_amount_changed').first
      expect(change_event).not_to be_nil
      expect(change_event.payload_data).to include('previous' => '100.0', 'current' => '150.0')
    end
  end

  context 'when a handler emits a blocked draft' do
    let(:blocked_handler) do
      reason = 'PO-XYZ references unknown GL account 9999'
      Class.new(Accruals::Handler) do
        define_singleton_method(:handler_name) { 'blocked_fake' }
        define_method(:call) do
          [Accruals::DraftAccrual.new(
            idempotency_key:      'blocked_fake|2026-03-31|XYZ',
            handler_name:         'blocked_fake',
            entity_kind:          'ap',
            status:               'blocked',
            memo:                 'fake blocked draft',
            amount_usd:           BigDecimal('200.00'),
            amount_billing_ccy:   BigDecimal('200.00'),
            billing_currency:     'USD',
            fx_rate:              BigDecimal('1'),
            fx_rate_date:         @close_run.period_end,
            gl_debit_account_id:  nil,
            gl_credit_account_id: nil,
            flagged_reason:       reason,
            sources:              []
          )]
        end
      end
    end

    before { stub_const('Accruals::Engine::HANDLERS', [blocked_handler]) }

    it 'persists the accrual with status blocked and nil GL FKs' do
      described_class.new(close_run).run!
      a = Accrual.first
      expect(a.status).to eq('blocked')
      expect(a.gl_debit_account_id).to be_nil
      expect(a.gl_credit_account_id).to be_nil
      expect(a.flagged_reason).to include('9999')
    end

    it 'keeps blocked accruals OFF the consolidated journal entry' do
      described_class.new(close_run).run!
      expect(JournalEntry.where(close_run_id: close_run.id).count).to eq(0)
      expect(JournalLine.count).to eq(0)
    end

    it 'writes an accrual_blocked audit event with the reason' do
      described_class.new(close_run).run!
      ev = AuditEvent.where(action: 'accrual_blocked').first
      expect(ev).not_to be_nil
      expect(ev.payload_data['reason']).to include('9999')
    end

    it 'does not re-audit blocked on a second run with the same status' do
      described_class.new(close_run).run!
      described_class.new(close_run).run!
      expect(AuditEvent.where(action: 'accrual_blocked').count).to eq(1)
    end
  end
end
