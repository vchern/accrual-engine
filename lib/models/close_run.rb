class CloseRun < Sequel::Model
  one_to_many :accruals
  one_to_many :journal_entries
  one_to_many :audit_events

  STATUSES = %w[pending running completed failed].freeze

  # The window of dates between the most-recent invoice end + 1 and period_end.
  # For the anchor: most recent invoice covered up to 2026-03-28 → window is Mar 29-31.
  def unbilled_window
    last_invoice_end = ChargebeeInvoice.max(:period_end)
    start_date = last_invoice_end ? Date.parse(last_invoice_end.to_s) + 1 : period_start
    (start_date..period_end)
  end

  def total_amount_usd
    accruals.sum { |a| a.amount_usd } || BigDecimal('0')
  end
end
