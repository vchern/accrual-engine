Sequel.migration do
  change do
    create_table(:usage_events) do
      primary_key :id
      String :event_id, null: false, unique: true
      foreign_key :customer_id, :customers, null: false
      foreign_key :sku_id, :skus, null: false
      BigDecimal :quantity, size: [20, 6], null: false
      Date :occurred_on, null: false
      index %i[customer_id occurred_on]
      index :occurred_on
    end

    create_table(:chargebee_invoices) do
      primary_key :id
      String :invoice_id, null: false, unique: true
      foreign_key :customer_id, :customers, null: false
      Date :period_start, null: false
      Date :period_end, null: false
      DateTime :issued_at, null: false
      BigDecimal :subtotal_usd, size: [15, 4], null: false
      String :currency, null: false
      BigDecimal :fx_to_usd, size: [20, 8], null: false
    end

    create_table(:purchase_orders) do
      primary_key :id
      String :po_number, null: false, unique: true
      foreign_key :vendor_id, :vendors, null: false
      String :po_type, null: false
      String :department
      String :gl_account_code, null: false
      String :currency, null: false
      BigDecimal :po_total_usd, size: [15, 4], null: false
      String :po_status, null: false
    end

    create_table(:po_lines) do
      primary_key :id
      foreign_key :purchase_order_id, :purchase_orders, null: false
      String :po_line_ref, null: false
      String :description
      BigDecimal :qty, size: [20, 6], null: false
      String :uom
      BigDecimal :unit_price_usd, size: [15, 4], null: false
      BigDecimal :line_total_usd, size: [15, 4], null: false
      index %i[purchase_order_id po_line_ref], unique: true
    end

    create_table(:goods_receipts) do
      primary_key :id
      String :receipt_id, null: false, unique: true
      foreign_key :po_line_id, :po_lines, null: false
      BigDecimal :received_qty, size: [20, 6], null: false
      Date :received_on, null: false
      BigDecimal :value_usd, size: [15, 4], null: false
      String :notes
      index :received_on
    end

    create_table(:vendor_invoices) do
      primary_key :id
      String :invoice_number, null: false, unique: true
      foreign_key :vendor_id, :vendors, null: false
      foreign_key :purchase_order_id, :purchase_orders
      Date :invoice_date, null: false
      BigDecimal :subtotal_usd, size: [15, 4], null: false
      String :status, null: false
    end
  end
end
