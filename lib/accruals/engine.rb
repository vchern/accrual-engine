require 'bigdecimal'

module Accruals
  # Orchestrates a close run. For each registered handler, computes drafts,
  # upserts them by idempotency_key, regenerates journal entries (accrual
  # dated period_end + reversal dated next business day), and writes audit
  # events. Re-running the same close is a no-op for unchanged amounts.
  #
  # To register a handler: `Accruals::Engine.register(YourHandler)`.
  class Engine
    HANDLERS = []

    def self.register(handler_class)
      HANDLERS << handler_class unless HANDLERS.include?(handler_class)
      handler_class
    end

    def initialize(close_run)
      @close_run = close_run
    end

    def run!
      mark_started
      DB.transaction do
        HANDLERS.each { |klass| process_handler(klass) }
        regenerate_journal_entries
        mark_completed
      end
      audit(:run_completed,
            accruals: Accrual.where(close_run_id: @close_run.id).count,
            journal_entries: JournalEntry.where(close_run_id: @close_run.id).count)
      narrate_flagged_accruals
      @close_run.refresh
    rescue StandardError => e
      mark_failed(e)
      raise
    end

    private

    def process_handler(handler_class)
      handler = handler_class.new(@close_run)
      drafts  = handler.call
      drafts.each { |d| upsert_accrual(d) }
      audit(:handler_completed, handler: handler_class.handler_name, count: drafts.size)
    end

    def upsert_accrual(draft)
      attrs = draft.to_accrual_attrs.merge(close_run_id: @close_run.id)

      existing = Accrual.where(idempotency_key: draft.idempotency_key).first
      if existing
        prev_amount = existing.amount_usd
        existing.update(attrs)
        if prev_amount != existing.amount_usd
          audit(:accrual_amount_changed,
                accrual_id: existing.id,
                key:        draft.idempotency_key,
                previous:   prev_amount.to_s('F'),
                current:    existing.amount_usd.to_s('F'))
        end
        replace_sources(existing, draft.sources || [])
        existing
      else
        accrual = Accrual.create(attrs)
        replace_sources(accrual, draft.sources || [])
        accrual
      end
    end

    def replace_sources(accrual, sources)
      AccrualSource.where(accrual_id: accrual.id).delete
      sources.each do |s|
        AccrualSource.create(
          accrual_id:  accrual.id,
          source_type: s.fetch(:source_type),
          source_id:   s.fetch(:source_id)
        )
      end
    end

    def regenerate_journal_entries
      stale_je_ids = JournalEntry.where(close_run_id: @close_run.id).select_map(:id)
      unless stale_je_ids.empty?
        JournalLine.where(journal_entry_id: stale_je_ids).delete
        JournalEntry.where(id: stale_je_ids).delete
      end
      generate_accrual_entries
      generate_reversing_entries
    end

    def generate_accrual_entries
      Accrual.where(close_run_id: @close_run.id).each do |acc|
        je = JournalEntry.create(
          close_run_id: @close_run.id,
          accrual_id:   acc.id,
          entry_type:   'accrual',
          entry_date:   @close_run.period_end
        )
        memo = "#{acc.handler_name} #{acc.idempotency_key}"
        JournalLine.create(
          journal_entry_id:  je.id,
          gl_account_id:     acc.gl_debit_account_id,
          debit_amount_usd:  acc.amount_usd,
          credit_amount_usd: BigDecimal('0'),
          memo:              memo
        )
        JournalLine.create(
          journal_entry_id:  je.id,
          gl_account_id:     acc.gl_credit_account_id,
          debit_amount_usd:  BigDecimal('0'),
          credit_amount_usd: acc.amount_usd,
          memo:              memo
        )
      end
    end

    def generate_reversing_entries
      reversal_date = BusinessCalendar.next_business_day(@close_run.period_end)
      JournalEntry.where(close_run_id: @close_run.id, entry_type: 'accrual').each do |je|
        rev = JournalEntry.create(
          close_run_id: @close_run.id,
          accrual_id:   je.accrual_id,
          entry_type:   'reversal',
          entry_date:   reversal_date,
          reverses_id:  je.id
        )
        je.journal_lines.each do |line|
          JournalLine.create(
            journal_entry_id:  rev.id,
            gl_account_id:     line.gl_account_id,
            debit_amount_usd:  line.credit_amount_usd,
            credit_amount_usd: line.debit_amount_usd,
            memo:              "Reversal of JE-#{je.id}"
          )
        end
      end
    end

    def mark_started
      @close_run.update(status: 'running', started_at: Time.now.utc)
      audit :run_started, period_end: @close_run.period_end.to_s
    end

    def mark_completed
      @close_run.update(status: 'completed', completed_at: Time.now.utc)
    end

    def mark_failed(error)
      @close_run.update(status: 'failed')
      audit :run_failed, error: error.message, backtrace: Array(error.backtrace).first(5)
    end

    # Best-effort: ask the LLM narrator for a Controller-grade summary of
    # each newly-flagged accrual. Run *outside* the engine transaction so
    # an LLM error never rolls back the close. Skip if no API key.
    def narrate_flagged_accruals
      flagged = Accrual.where(
        close_run_id:     @close_run.id,
        status:           'flagged',
        review_narration: nil
      ).all
      return if flagged.empty?

      narrator = Accruals::ReviewNarrator.new
      flagged.each do |accrual|
        result = narrator.narrate(accrual)
        next if result.nil?

        if result.error
          audit(:review_narration_failed, accrual_id: accrual.id, error: result.error)
        else
          accrual.update(
            review_narration:       result.text,
            review_narration_at:    Time.now.utc,
            review_narration_model: result.model
          )
          audit(:review_narration_added, accrual_id: accrual.id, model: result.model)
        end
      end
    end

    def audit(action, payload = {})
      ev = AuditEvent.new(
        close_run_id: @close_run.id,
        action:       action.to_s,
        actor:        'engine',
        created_at:   Time.now.utc
      )
      ev.payload_data = payload
      ev.save
    end
  end
end
