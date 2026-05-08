Sequel.migration do
  change do
    create_table(:customers) do
      primary_key :id
      String :customer_id, null: false, unique: true
      String :name, null: false
      String :currency, null: false
      String :country, size: 2
      String :status, null: false
      Date :billing_anchor
      DateTime :churned_at
      DateTime :created_at
      DateTime :updated_at
    end

    create_table(:skus) do
      primary_key :id
      String :sku, null: false, unique: true
      String :unit, null: false
      BigDecimal :list_unit_price_usd, size: [15, 4], null: false
      String :category
    end

    create_table(:vendors) do
      primary_key :id
      String :vendor_id, null: false, unique: true
      String :name, null: false
      String :category
      String :currency, null: false
      String :default_gl_account
      String :default_department
    end

    create_table(:gl_accounts) do
      primary_key :id
      String :account_code, null: false, unique: true
      String :name, null: false
      String :account_type, null: false
    end

    create_table(:fx_rates) do
      primary_key :id
      String :from_ccy, null: false
      String :to_ccy, null: false
      BigDecimal :rate, size: [20, 8], null: false
      Date :effective_date, null: false
      index %i[from_ccy to_ccy effective_date], unique: true
    end
  end
end
