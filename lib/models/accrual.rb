class Accrual < Sequel::Model
  many_to_one :close_run
  many_to_one :gl_debit_account, class: :GlAccount, key: :gl_debit_account_id
  many_to_one :gl_credit_account, class: :GlAccount, key: :gl_credit_account_id
  one_to_many :accrual_sources
  one_to_many :journal_entries

  STATUSES = %w[posted flagged blocked].freeze
  ENTITY_KINDS = %w[ar ap].freeze

  def flagged?
    status == 'flagged'
  end

  def sources
    accrual_sources.map(&:source).compact
  end
end
