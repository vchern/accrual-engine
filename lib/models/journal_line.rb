class JournalLine < Sequel::Model
  many_to_one :journal_entry
  many_to_one :gl_account
end
