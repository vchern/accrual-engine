Sequel.migration do
  change do
    # Blocked accruals can't have GL coding by definition — that's often
    # *why* they're blocked (e.g., PO references an unknown GL account).
    # Allow nil so engine.rb can persist a `blocked` DraftAccrual instead
    # of raising and crashing the whole close on one bad row.
    alter_table(:accruals) do
      set_column_allow_null :gl_debit_account_id,  true
      set_column_allow_null :gl_credit_account_id, true
    end
  end
end
