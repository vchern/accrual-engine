require 'spec_helper'

RSpec.describe Accruals::CloseSummarizer do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts
    flagged_handler = fake_handler_class(
      status:          'flagged',
      flagged_reason:  '2026-03-30 GPU-H100-HR qty=25.0 (median 10.5, z=6.1)',
      idempotency_key: 'fake|2026-03-31|FLAG'
    )
    stub_const('Accruals::Engine::HANDLERS', [flagged_handler])
    Accruals::Engine.new(close_run).run!  # creates the accrual + JEs
  end

  it 'returns nil when API key is missing' do
    expect(described_class.new(api_key: nil).summarize(close_run)).to be_nil
    expect(described_class.new(api_key: '').summarize(close_run)).to be_nil
  end

  it 'returns Result.text on transport success' do
    captured = nil
    transport = ->(prompt) { captured = prompt; 'March close totaled $100.00 with one flagged accrual.' }
    result = described_class.new(api_key: 'fake', transport: transport).summarize(close_run)
    expect(result.text).to include('March close')
    expect(result.error).to be_nil

    # Prompt is grounded in actual close-run data
    expect(captured).to include(close_run.period_end.to_s)
    expect(captured).to include('Awaiting review (flagged): 1')
    expect(captured).to include('Do NOT compute or invent amounts')
  end

  it 'captures Result.error on transport failure (no raise)' do
    transport = ->(_) { raise 'rate limited' }
    result = described_class.new(api_key: 'fake', transport: transport).summarize(close_run)
    expect(result.error).to eq('rate limited')
    expect(result.text).to be_nil
  end
end

RSpec.describe 'Engine#summarize_close', type: :request do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts
    stub_const('Accruals::Engine::HANDLERS', [fake_handler_class])
  end

  it 'caches the summary on close_runs after a successful run' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return('fake-key')

    happy = Accruals::CloseSummarizer.new(api_key: 'fake-key', transport: ->(_) { 'Close summary text.' })
    allow(Accruals::CloseSummarizer).to receive(:new).and_return(happy)

    Accruals::Engine.new(close_run).run!

    expect(close_run.refresh.summary).to eq('Close summary text.')
    expect(close_run.summary_model).to eq(Accruals::CloseSummarizer::DEFAULT_MODEL)
  end

  it 'audits a skip when GEMINI_API_KEY is unset' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return(nil)

    Accruals::Engine.new(close_run).run!
    skip_event = AuditEvent.where(close_run_id: close_run.id, action: 'close_summary_skipped').first
    expect(skip_event).not_to be_nil
    expect(skip_event.payload_data).to include('reason' => /GEMINI_API_KEY not set/)
  end

  it 'does not re-summarize if a summary already exists' do
    close_run.update(summary: 'pre-existing summary', summary_model: 'gemini-2.5-flash-lite')
    transport_called = false
    expect(Accruals::CloseSummarizer).not_to receive(:summarize)

    Accruals::Engine.new(close_run).run!
    expect(close_run.refresh.summary).to eq('pre-existing summary')
  end
end
