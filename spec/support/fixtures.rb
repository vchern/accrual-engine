module Fixtures
  GL_ACCOUNTS = [
    %w[1310 Accrued\ Revenue Asset],
    %w[4010 Compute\ Services\ Revenue Revenue],
    %w[1480 Computer\ Equipment\ -\ GPU\ Servers Asset],
    %w[2150 Accrued\ Expenses\ -\ AP Liability]
  ].freeze

  def seed_minimal_gl_accounts
    [
      ['1310', 'Accrued Revenue', 'Asset'],
      ['4010', 'Compute Services Revenue', 'Revenue'],
      ['1480', 'Computer Equipment - GPU Servers', 'Asset'],
      ['2150', 'Accrued Expenses - AP', 'Liability']
    ].each do |code, name, type|
      GlAccount.create(account_code: code, name: name, account_type: type)
    end
  end

  def create_close_run(period_end: Date.new(2026, 3, 31), period_start: Date.new(2026, 3, 1))
    CloseRun.create(
      period_start: period_start,
      period_end:   period_end,
      status:       'pending'
    )
  end

  # Returns an anonymous Accruals::Handler subclass that emits a single
  # draft accrual using the given attributes (with sensible defaults).
  def fake_handler_class(handler_name: 'fake', amount_usd: BigDecimal('100.00'),
                        status: 'posted', flagged_reason: nil,
                        idempotency_key: 'fake|2026-03-31|X',
                        debit_code: '1310', credit_code: '4010', sources: [])
    name = handler_name
    args = {
      idempotency_key:    idempotency_key,
      handler_name:       handler_name,
      amount_usd:         amount_usd,
      amount_billing_ccy: amount_usd,
      billing_currency:   'USD',
      fx_rate:            BigDecimal('1'),
      status:             status,
      flagged_reason:     flagged_reason,
      debit_code:         debit_code,
      credit_code:        credit_code,
      sources:            sources
    }
    Class.new(Accruals::Handler) do
      define_singleton_method(:handler_name) { name }
      define_method(:call) do
        [Accruals::DraftAccrual.new(
          idempotency_key:      args[:idempotency_key],
          handler_name:         args[:handler_name],
          entity_kind:          'ar',
          status:               args[:status],
          memo:                 'fake test draft',
          amount_usd:           args[:amount_usd],
          amount_billing_ccy:   args[:amount_billing_ccy],
          billing_currency:     args[:billing_currency],
          fx_rate:              args[:fx_rate],
          fx_rate_date:         @close_run.period_end,
          gl_debit_account_id:  GlAccount.where(account_code: args[:debit_code]).first.id,
          gl_credit_account_id: GlAccount.where(account_code: args[:credit_code]).first.id,
          flagged_reason:       args[:flagged_reason],
          sources:              args[:sources]
        )]
      end
    end
  end
end
