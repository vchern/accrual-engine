Sequel.migration do
  change do
    create_table(:close_runs) do
      primary_key :id
      Date :period_start, null: false
      Date :period_end, null: false
      String :status, null: false, default: 'pending'
      DateTime :started_at
      DateTime :completed_at
      String :notes, text: true
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :period_end
    end

    create_table(:accruals) do
      primary_key :id
      foreign_key :close_run_id, :close_runs, null: false
      String :handler_name, null: false
      String :idempotency_key, null: false
      String :entity_kind, null: false
      String :status, null: false
      String :memo
      BigDecimal :amount_usd, size: [15, 4], null: false
      BigDecimal :amount_billing_ccy, size: [15, 4], null: false
      String :billing_currency, null: false
      BigDecimal :fx_rate, size: [20, 8], null: false
      Date :fx_rate_date, null: false
      foreign_key :gl_debit_account_id, :gl_accounts, null: false
      foreign_key :gl_credit_account_id, :gl_accounts, null: false
      String :flagged_reason
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index :idempotency_key, unique: true
      index %i[close_run_id status]
    end

    create_table(:accrual_sources) do
      primary_key :id
      foreign_key :accrual_id, :accruals, null: false
      String :source_type, null: false
      Integer :source_id, null: false
      index :accrual_id
      index %i[source_type source_id]
    end

    create_table(:journal_entries) do
      primary_key :id
      foreign_key :close_run_id, :close_runs, null: false
      foreign_key :accrual_id, :accruals, null: false
      String :entry_type, null: false
      Date :entry_date, null: false
      DateTime :posted_at
      foreign_key :reverses_id, :journal_entries
      DateTime :created_at, null: false
      DateTime :updated_at, null: false
      index %i[close_run_id entry_date]
    end

    create_table(:journal_lines) do
      primary_key :id
      foreign_key :journal_entry_id, :journal_entries, null: false
      foreign_key :gl_account_id, :gl_accounts, null: false
      BigDecimal :debit_amount_usd, size: [15, 4], default: 0, null: false
      BigDecimal :credit_amount_usd, size: [15, 4], default: 0, null: false
      String :memo
      index :journal_entry_id
    end

    create_table(:audit_events) do
      primary_key :id
      foreign_key :close_run_id, :close_runs
      foreign_key :accrual_id, :accruals
      String :action, null: false
      String :payload, text: true
      String :actor, default: 'engine'
      DateTime :created_at, null: false
      index %i[close_run_id created_at]
    end
  end
end
