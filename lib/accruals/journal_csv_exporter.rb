require 'csv'

module Accruals
  # Exports journal entries for a close run as a NetSuite-friendly CSV. One
  # row per journal line, with the source-trace refs (e.g. "UsageEvent#42")
  # joined by ';' so an auditor can drill back to the underlying records.
  class JournalCsvExporter
    HEADERS = %w[
      journal_entry_id
      entry_type
      entry_date
      account_code
      account_name
      debit_usd
      credit_usd
      memo
      close_run_id
      accrual_id
      handler
      source_refs
    ].freeze

    def self.call(close_run)
      new(close_run).call
    end

    def initialize(close_run)
      @close_run = close_run
    end

    def call
      CSV.generate do |csv|
        csv << HEADERS
        each_row { |row| csv << row }
      end
    end

    private

    def each_row
      JournalEntry
        .where(close_run_id: @close_run.id)
        .order(:entry_date, :id)
        .each do |je|
          je.journal_lines.sort_by(&:id).each do |line|
            accrual = line.accrual
            source_refs = if accrual
                            accrual.accrual_sources.map { |s| "#{s.source_type}##{s.natural_ref}" }.join(';')
                          else
                            ''
                          end
            yield row_for(je, accrual, line, source_refs)
          end
        end
    end

    def row_for(je, accrual, line, source_refs)
      [
        je.id,
        je.entry_type,
        je.entry_date.to_s,
        line.gl_account.account_code,
        line.gl_account.name,
        format('%.2f', line.debit_amount_usd),
        format('%.2f', line.credit_amount_usd),
        line.memo,
        @close_run.id,
        accrual&.id,
        accrual&.handler_name,
        source_refs
      ]
    end
  end
end
