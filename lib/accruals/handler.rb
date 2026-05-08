module Accruals
  # Base class every accrual handler inherits from. To add a new handler:
  #   1. Subclass `Accruals::Handler`
  #   2. Implement `.handler_name` and `#call` (return Array<DraftAccrual>)
  #   3. Register: `Accruals::Engine.register(YourHandler)`
  class Handler
    def self.handler_name
      raise NotImplementedError, "#{self} must define `.handler_name`"
    end

    def initialize(close_run)
      @close_run = close_run
    end

    # Returns Array<Accruals::DraftAccrual>. The engine handles persistence
    # and idempotency — handlers are pure compute.
    def call
      raise NotImplementedError, "#{self.class} must implement `#call`"
    end

    private

    attr_reader :close_run
  end
end
