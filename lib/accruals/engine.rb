module Accruals
  # Orchestrates a close run: invokes each registered handler, persists the
  # resulting accruals with idempotency, and generates paired reversing entries.
  class Engine
    HANDLERS = [
      # Accruals::Handlers::ArUsage,
      # Accruals::Handlers::ApGoodsReceiptNotInvoiced,
    ].freeze

    def initialize(close_run)
      @close_run = close_run
    end

    def run!
      # Implementation lands in phase 3.
      raise NotImplementedError
    end
  end
end
