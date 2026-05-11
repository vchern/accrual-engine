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

    # If a narration call failed within this window, skip retrying for the
    # same accrual on the next engine.run!. Prevents repeated 'Run engine'
    # clicks from hammering an already-rate-limited Gemini endpoint.
    NARRATION_RETRY_COOLDOWN_SECONDS = 600   # 10 minutes

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
      dispatch_llm_tasks
      @close_run.refresh
    rescue StandardError => e
      mark_failed(e)
      raise
    end

    # Public so review routes (approve/reject) can refresh the consolidated
    # JEs after a status change without re-running every handler.
    def regenerate_journal_entries
      stale_je_ids = JournalEntry.where(close_run_id: @close_run.id).select_map(:id)
      unless stale_je_ids.empty?
        JournalLine.where(journal_entry_id: stale_je_ids).delete
        JournalEntry.where(id: stale_je_ids).delete
      end
      generate_consolidated_entries
    end

    private

    # In production the Gemini calls (N flagged-accrual narrations + 1 close
    # summary, each ~1-3s) run on a background thread so the HTTP response
    # returns immediately. Tests run synchronously: each spec wraps in a
    # Sequel transaction with rollback, and a separate thread would have its
    # own DB connection that bypasses the rollback (and wouldn't see the
    # in-progress data either).
    def dispatch_llm_tasks
      if ENV['APP_ENV'] == 'test'
        run_llm_tasks
      else
        Thread.new do
          run_llm_tasks
        rescue StandardError => e
          warn "[engine] LLM background thread crashed: #{e.class} #{e.message}"
        end
      end
    end

    def run_llm_tasks
      narrate_flagged_accruals
      summarize_close
    end

    def process_handler(handler_class)
      handler = handler_class.new(@close_run)
      drafts  = handler.call
      drafts.each { |d| upsert_accrual(d) }
      audit(:handler_completed, handler: handler_class.handler_name, count: drafts.size)
    end

    def upsert_accrual(draft)
      attrs = draft.to_accrual_attrs.merge(close_run_id: @close_run.id)

      existing    = Accrual.where(idempotency_key: draft.idempotency_key).first
      prev_status = existing&.status

      if existing
        prev_amount = existing.amount_usd

        # Preserve human review decisions across engine re-runs. The amount
        # may still update from new source data; an `accrual_amount_changed`
        # audit event surfaces the delta so a Controller can re-review.
        if %w[approved rejected].include?(existing.status)
          attrs.delete(:status)
        end

        existing.update(attrs)
        if prev_amount != existing.amount_usd
          audit(:accrual_amount_changed,
                accrual_id: existing.id,
                key:        draft.idempotency_key,
                previous:   prev_amount.to_s('F'),
                current:    existing.amount_usd.to_s('F'))
        end
        replace_sources(existing, draft.sources || [])
        accrual = existing
      else
        accrual = Accrual.create(attrs)
        replace_sources(accrual, draft.sources || [])
      end

      if accrual.status == 'blocked' && prev_status != 'blocked'
        audit(:accrual_blocked,
              accrual_id: accrual.id,
              key:        draft.idempotency_key,
              reason:     draft.flagged_reason)
      end

      accrual
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

    # Consolidated journal entries: one accrual JE for the entire close +
    # one paired reversal JE. Each accrual contributes 2 lines (DR + CR)
    # to the accrual JE and 2 mirror lines to the reversal. Per-accrual
    # source-trace lives on `journal_lines.accrual_id`. Matches how a
    # controller would post a single month-end JE to NetSuite.
    def generate_consolidated_entries
      # Only `posted` and `approved` accruals contribute lines. Flagged
      # (awaiting review), rejected, and blocked accruals stay off the JE
      # until/unless their status changes.
      accruals = Accrual.where(close_run_id: @close_run.id, status: %w[posted approved])
                        .order(:id).all
      return if accruals.empty?

      accrual_je = JournalEntry.create(
        close_run_id: @close_run.id,
        entry_type:   'accrual',
        entry_date:   @close_run.period_end
      )

      accruals.each do |acc|
        memo = "#{acc.handler_name} #{acc.idempotency_key}"
        JournalLine.create(
          journal_entry_id:  accrual_je.id,
          accrual_id:        acc.id,
          gl_account_id:     acc.gl_debit_account_id,
          debit_amount_usd:  acc.amount_usd,
          credit_amount_usd: BigDecimal('0'),
          memo:              memo
        )
        JournalLine.create(
          journal_entry_id:  accrual_je.id,
          accrual_id:        acc.id,
          gl_account_id:     acc.gl_credit_account_id,
          debit_amount_usd:  BigDecimal('0'),
          credit_amount_usd: acc.amount_usd,
          memo:              memo
        )
      end

      reversal_je = JournalEntry.create(
        close_run_id: @close_run.id,
        entry_type:   'reversal',
        entry_date:   BusinessCalendar.next_business_day(@close_run.period_end),
        reverses_id:  accrual_je.id
      )

      accrual_je.journal_lines.each do |line|
        JournalLine.create(
          journal_entry_id:  reversal_je.id,
          accrual_id:        line.accrual_id,
          gl_account_id:     line.gl_account_id,
          debit_amount_usd:  line.credit_amount_usd,
          credit_amount_usd: line.debit_amount_usd,
          memo:              "Reversal of JE-#{accrual_je.id}"
        )
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
    # an LLM error never rolls back the close. Skips accruals that failed
    # within NARRATION_RETRY_COOLDOWN_SECONDS to protect the API quota.
    def narrate_flagged_accruals
      flagged = Accrual.where(
        close_run_id:     @close_run.id,
        status:           'flagged',
        review_narration: nil
      ).all
      return if flagged.empty?

      if ENV['GEMINI_API_KEY'].to_s.strip.empty?
        audit(:review_narration_skipped,
              reason: 'GEMINI_API_KEY not set in environment',
              flagged_accrual_count: flagged.size)
        return
      end

      cooldown_floor = Time.now.utc - NARRATION_RETRY_COOLDOWN_SECONDS
      recently_failed_ids = AuditEvent
        .where(action: 'review_narration_failed', accrual_id: flagged.map(&:id))
        .where(Sequel[:created_at] > cooldown_floor)
        .select_map(:accrual_id)

      to_narrate = flagged.reject { |a| recently_failed_ids.include?(a.id) }
      if to_narrate.empty?
        audit(:review_narration_cooldown,
              flagged_accrual_count:    flagged.size,
              cooldown_seconds:         NARRATION_RETRY_COOLDOWN_SECONDS,
              skipped_accrual_ids:      recently_failed_ids)
        return
      end

      narrator = Accruals::ReviewNarrator.new
      to_narrate.each do |accrual|
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

    # Best-effort: ask the LLM for a Controller-grade close summary. Run
    # *outside* the engine transaction (same rationale as narration) so an
    # LLM error never rolls back the close. Skips re-summarization if a
    # summary already exists; audits skipped/failed cases for visibility.
    def summarize_close
      return if @close_run.summary && !@close_run.summary.to_s.empty?

      if ENV['GEMINI_API_KEY'].to_s.strip.empty?
        audit(:close_summary_skipped, reason: 'GEMINI_API_KEY not set in environment')
        return
      end

      result = Accruals::CloseSummarizer.summarize(@close_run)
      return if result.nil?

      if result.error
        audit(:close_summary_failed, error: result.error)
      else
        @close_run.update(
          summary:       result.text,
          summary_at:    Time.now.utc,
          summary_model: result.model
        )
        audit(:close_summary_added, model: result.model)
      end
    end

    def audit(action, payload = {})
      ev = AuditEvent.new(
        close_run_id: @close_run.id,
        accrual_id:   payload[:accrual_id],
        action:       action.to_s,
        actor:        'engine',
        created_at:   Time.now.utc
      )
      ev.payload_data = payload
      ev.save
    end
  end
end
