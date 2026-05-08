require 'spec_helper'

RSpec.describe 'Narration status surfacing on the UI', type: :request do
  let(:close_run) { create_close_run }

  before do
    seed_minimal_gl_accounts

    flagged_handler = fake_handler_class(
      status:          'flagged',
      flagged_reason:  '2026-03-30 GPU-H100-HR qty=25.0 (median 10.5, z=6.1)',
      idempotency_key: 'fake|2026-03-31|FLAG'
    )
    stub_const('Accruals::Engine::HANDLERS', [flagged_handler])
  end

  it 'shows a "skipped" note on the show page when no GEMINI_API_KEY is set' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return(nil)

    Accruals::Engine.new(close_run).run!

    get "/closes/#{close_run.id}"
    expect(last_response.body).to match(/AI review note.*skipped/m)
    expect(last_response.body).to include('GEMINI_API_KEY not set')
  end

  it 'shows a "failed" note on the show page when Gemini errors' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return('fake-key')
    failing_transport = ->(_) { raise 'Gemini 429: quota exceeded' }
    narrator = Accruals::ReviewNarrator.new(api_key: 'fake-key', transport: failing_transport)
    allow(Accruals::ReviewNarrator).to receive(:new).and_return(narrator)

    Accruals::Engine.new(close_run).run!

    get "/closes/#{close_run.id}"
    expect(last_response.body).to match(/AI review note.*failed/m)
    expect(last_response.body).to include('quota exceeded')
  end

  it 'shows the narration text when Gemini succeeds' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('GEMINI_API_KEY').and_return('fake-key')
    happy_transport = ->(_) { 'Verify with the customer that the Mar 30 spike was real workload.' }
    narrator = Accruals::ReviewNarrator.new(api_key: 'fake-key', transport: happy_transport)
    allow(Accruals::ReviewNarrator).to receive(:new).and_return(narrator)

    Accruals::Engine.new(close_run).run!

    get "/closes/#{close_run.id}"
    expect(last_response.body).to include('AI review note')
    expect(last_response.body).to include('Verify with the customer')
  end
end
