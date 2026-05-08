class CloseRun < Sequel::Model
  one_to_many :accruals
  one_to_many :journal_entries
  one_to_many :audit_events

  STATUSES = %w[pending running completed failed].freeze

  # Window of dates that should accrue at this close: from (last invoice
  # end + 1) OR the first day of period_end's calendar month — whichever
  # is later — through period_end. Calendar-month bound prevents an Apr 30
  # close from sweeping in already-handled March events when no April
  # invoices have been issued yet.
  def unbilled_window
    last_invoice_end  = ChargebeeInvoice.max(:period_end)
    earliest_unbilled = last_invoice_end ? Date.parse(last_invoice_end.to_s) + 1 : period_start
    month_start       = Date.new(period_end.year, period_end.month, 1)
    start_date        = [earliest_unbilled, month_start].max
    (start_date..period_end)
  end

  def total_amount_usd
    accruals.sum { |a| a.amount_usd } || BigDecimal('0')
  end
end
