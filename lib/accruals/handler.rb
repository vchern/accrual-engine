module Accruals
  # Base class every accrual handler inherits from. To add a new handler:
  #   1. Subclass `Accruals::Handler`
  #   2. Implement `.handler_name` and `#call`
  #   3. Register the class in `Accruals::Engine::HANDLERS`
  class Handler
    def self.handler_name
      raise NotImplementedError, "#{self} must define `.handler_name`"
    end

    def initialize(close_run)
      @close_run = close_run
    end

    # Returns an array of draft accrual hashes (not yet persisted).
    # Each draft must include :idempotency_key so the engine can upsert safely.
    def call
      raise NotImplementedError, "#{self.class} must implement `#call`"
    end

    private

    attr_reader :close_run
  end
end
