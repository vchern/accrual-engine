class JournalEntry < Sequel::Model
  many_to_one :close_run
  many_to_one :accrual
  many_to_one :reverses, class: self, key: :reverses_id
  one_to_many :reversed_by, class: self, key: :reverses_id
  one_to_many :journal_lines

  ENTRY_TYPES = %w[accrual reversal].freeze

  def reversal?
    entry_type == 'reversal'
  end
end
