require 'spec_helper'

RSpec.describe 'Accruals::Engine narration cooldown' do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts
    flagged_handler = fake_handler_class(
      status:          'flagged',
      flagged_reason:  '2026-03-30 GPU-H100-HR qty=25.0 (median 10.5, z=6.1)',
      idempotency_key: 'fake|2026-03-31|FLAG'
    )
    stub_const('Accruals::Engine::HANDLERS', [flagged_handler])

    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return('fake-key')
  end

  it 'skips accruals that failed narration within the cooldown window' do
    failing = Accruals::ReviewNarrator.new(api_key: 'fake-key', transport: ->(_) { raise 'rate-limited' })
    allow(Accruals::ReviewNarrator).to receive(:new).and_return(failing)

    Accruals::Engine.new(close_run).run!
    expect(AuditEvent.where(action: 'review_narration_failed').count).to eq(1)

    happy = Accruals::ReviewNarrator.new(api_key: 'fake-key', transport: ->(_) { 'should not be called' })
    allow(Accruals::ReviewNarrator).to receive(:new).and_return(happy)
    expect(happy).not_to receive(:narrate)

    Accruals::Engine.new(close_run).run!

    cooldown_events = AuditEvent.where(action: 'review_narration_cooldown')
    expect(cooldown_events.count).to eq(1)
    expect(cooldown_events.first.payload_data['cooldown_seconds'])
      .to eq(Accruals::Engine::NARRATION_RETRY_COOLDOWN_SECONDS)
  end

  it 'cooldown applies only to FAILED events, not skipped (config) events' do
    # If GEMINI_API_KEY was unset on a prior run (which writes 'skipped',
    # not 'failed'), the next run should still try — the cooldown is about
    # rate-limit protection, not config issues.
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return(nil)
    Accruals::Engine.new(close_run).run!
    expect(AuditEvent.where(action: 'review_narration_skipped').count).to eq(1)

    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return('fake-key')
    happy_text = 'Verify with the customer about the spike.'
    happy = Accruals::ReviewNarrator.new(api_key: 'fake-key', transport: ->(_) { happy_text })
    allow(Accruals::ReviewNarrator).to receive(:new).and_return(happy)

    Accruals::Engine.new(close_run).run!
    expect(Accrual.where(status: 'flagged').first.review_narration).to eq(happy_text)
  end
end
