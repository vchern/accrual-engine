# Loads the accrual engine and its handlers. Require AFTER models.
require_relative 'accruals/handler'
require_relative 'accruals/engine'
# Handlers land in phase 4:
# require_relative 'accruals/handlers/ar_usage'
# require_relative 'accruals/handlers/ap_goods_receipt_not_invoiced'
