class Accrual < Sequel::Model
  many_to_one :close_run
  many_to_one :gl_debit_account, class: :GlAccount, key: :gl_debit_account_id
  many_to_one :gl_credit_account, class: :GlAccount, key: :gl_credit_account_id
  one_to_many :accrual_sources
  one_to_many :journal_entries

  STATUSES = %w[posted flagged approved rejected blocked].freeze
  ENTITY_KINDS = %w[ar ap].freeze

  def flagged?
    status == 'flagged'
  end

  def approved?
    status == 'approved'
  end

  def rejected?
    status == 'rejected'
  end

  # Whether this accrual contributes lines to the consolidated journal entry.
  # Flagged (awaiting review), rejected (controller declined), and blocked
  # accruals are excluded.
  def in_journal_entry?
    %w[posted approved].include?(status)
  end

  def sources
    accrual_sources.map(&:source).compact
  end
end
