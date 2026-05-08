# Loads the accrual engine and its handlers. Require AFTER models.
require_relative 'accruals/draft_accrual'
require_relative 'accruals/business_calendar'
require_relative 'accruals/anomaly_detector'
require_relative 'accruals/handler'
require_relative 'accruals/engine'
require_relative 'accruals/journal_csv_exporter'
require_relative 'accruals/handlers/ar_usage'
require_relative 'accruals/handlers/ap_goods_receipt_not_invoiced'

Accruals::Engine.register(Accruals::Handlers::ArUsage)
Accruals::Engine.register(Accruals::Handlers::ApGoodsReceiptNotInvoiced)
