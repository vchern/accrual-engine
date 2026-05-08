module Accruals
  # The contract between handlers and the engine. Handlers return one of these
  # per logical accrual; the engine handles persistence, idempotency, journal
  # entries, and reversals.
  DraftAccrual = Struct.new(
    :idempotency_key,
    :handler_name,
    :entity_kind,            # 'ar' | 'ap'
    :status,                 # 'posted' | 'flagged' | 'blocked'
    :memo,
    :amount_usd,             # BigDecimal
    :amount_billing_ccy,     # BigDecimal
    :billing_currency,       # ISO 4217
    :fx_rate,                # BigDecimal
    :fx_rate_date,           # Date
    :gl_debit_account_id,
    :gl_credit_account_id,
    :flagged_reason,
    :sources,                # Array<{source_type:, source_id:}>
    keyword_init: true
  ) do
    def to_accrual_attrs
      to_h.reject { |k, _| k == :sources }
    end
  end
end
