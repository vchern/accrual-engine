Sequel.migration do
  change do
    # Move from one-JE-per-accrual to one-JE-per-close-per-direction.
    # `journal_entries.accrual_id` is no longer the per-accrual link;
    # `journal_lines.accrual_id` carries the line-level source trace.
    alter_table(:journal_entries) do
      set_column_allow_null :accrual_id, true
    end

    alter_table(:journal_lines) do
      add_foreign_key :accrual_id, :accruals
      add_index :accrual_id
    end
  end
end
