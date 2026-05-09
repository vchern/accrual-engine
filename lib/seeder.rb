require 'roo'
require 'bigdecimal'
require 'date'
require 'time'

# Loads the Helix anchor XLSX into the database, then augments with ~30 days
# of synthetic prior-period usage events so the anomaly detector has a
# baseline. The synthetic events are deterministic (seeded RNG) and clearly
# tagged with `evt_synth_` prefixed event_ids — disclosed in README.
class Seeder
  ANCHOR_PATH             = File.join(ROOT, 'Helix_Anchor_Dataset_CANDIDATE.xlsx').freeze
  SYNTHETIC_RNG_SEED      = 42
  SYNTHETIC_WINDOW_START  = Date.new(2026, 2, 26)
  SYNTHETIC_WINDOW_END    = Date.new(2026, 3, 27)
  CUS_1003_CHURN_AT       = Time.utc(2026, 3, 29, 23, 59, 59)

  # Synthetic-history baselines per (customer, SKU) pair. Multiple SKUs per
  # customer are supported so the anomaly detector has enough baseline for
  # each independently — e.g. CUS-1004 has both GPU and BANDWIDTH series,
  # and a spike in either should flag without contaminating the other.
  CUSTOMER_BASELINES = {
    'CUS-1001' => [{ sku: 'GPU-H100-HR',         mean: 10,   sigma: 2,   round: 1 }],
    'CUS-1002' => [{ sku: 'STORAGE-TB-DAY',      mean: 200,  sigma: 20,  round: 0 }],
    'CUS-1003' => [{ sku: 'INFERENCE-1K-TOKENS', mean: 5000, sigma: 500, round: 0 }],
    # Demo-dataset customers — only seeded if these customer rows exist.
    'CUS-1004' => [
      { sku: 'GPU-A100-HR',  mean: 50,  sigma: 5,  round: 1 },
      { sku: 'BANDWIDTH-TB', mean: 100, sigma: 10, round: 0 }
    ],
    'CUS-1005' => [
      { sku: 'INFERENCE-1K-TOKENS', mean: 2500, sigma: 250, round: 0 },
      { sku: 'STORAGE-TB-DAY',      mean: 100,  sigma: 10,  round: 0 }
    ]
  }.freeze

  # FX rates seeded daily for each non-USD currency that appears in the
  # customer set. Anchor README pegs EUR @ 1.08; JPY/GBP figures are
  # plausible 2026 placeholders.
  FX_RATES = {
    'EUR' => '1.08',
    'JPY' => '0.0067',
    'GBP' => '1.27',
    'SGD' => '0.74'
  }.freeze

  # Expected sheet names + column order. Any divergence in an uploaded XLSX
  # raises SchemaError before we touch the database — protects against the
  # silent-shift bug where columns swapped in the spreadsheet would land
  # in the wrong DB fields.
  SHEET_SCHEMA = {
    'customers'          => %w[customer_id name currency country status billing_anchor],
    'sku_price_book'     => %w[sku unit list_unit_price_usd category],
    'vendors'            => %w[vendor_id name category currency default_gl_account default_department],
    'gl_accounts'        => %w[account_code name type],
    'usage_events'       => %w[event_id customer_id sku quantity occurred_on],
    'chargebee_invoices' => %w[invoice_id customer_id period_start period_end issued_at subtotal_usd currency fx_to_usd],
    'purchase_orders'    => %w[po_number vendor_id po_type department gl_account currency po_total_usd po_status],
    'po_lines'           => %w[po_number po_line_ref description qty uom unit_price_usd line_total_usd],
    'goods_receipts'     => %w[receipt_id po_number po_line_ref received_qty received_on value_usd notes],
    'vendor_invoices'    => %w[invoice_number vendor_id po_number invoice_date subtotal_usd status]
  }.freeze

  class SchemaError < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = Array(errors)
      super(@errors.join("\n"))
    end
  end

  MODES = %i[replace append].freeze

  def self.run!(path: ANCHOR_PATH, log: ->(m) { puts m }, mode: :replace)
    new(path: path, log: log, mode: mode).call
  end

  def self.validate!(path:)
    new(path: path, log: ->(_) {}).validate!
  end

  def initialize(path:, log:, mode: :replace)
    @path = path
    @log  = log
    @mode = MODES.include?(mode) ? mode : :replace
  end

  def validate!
    raise SchemaError, ["File not found: #{@path}"] unless File.exist?(@path)
    @xlsx ||= Roo::Excelx.new(@path)

    errors = []
    SHEET_SCHEMA.each do |sheet_name, expected_cols|
      sheet = sheet_or_nil(sheet_name)
      if sheet.nil?
        errors << "Missing sheet: '#{sheet_name}'"
        next
      end
      actual = Array(sheet.row(1)).map { |c| c.to_s.strip }
      expected_cols.each_with_index do |col, i|
        got = actual[i]
        next if got == col
        display = got.nil? || got.empty? ? '(empty)' : got
        errors << "Sheet '#{sheet_name}', column #{i + 1}: expected '#{col}', got '#{display}'"
      end
    end
    raise SchemaError, errors unless errors.empty?
    true
  end

  def call
    validate!

    DB.transaction do
      seed_customers
      seed_skus
      seed_vendors
      seed_gl_accounts
      seed_fx_rates
      seed_chargebee_invoices
      seed_purchase_orders
      seed_po_lines
      seed_goods_receipts
      seed_vendor_invoices
      seed_anchor_usage_events
      seed_synthetic_history
    end

    @log.call(summary)
  end

  private

  # In :append mode, returns true if a row matching `lookup` already exists
  # so the caller should skip the insert. Always false in :replace mode.
  def skip?(model_class, lookup)
    @mode == :append && model_class.where(lookup).any?
  end

  def seed_customers
    each_row('customers') do |row|
      customer_id, name, currency, country, status, billing_anchor = row
      next if skip?(Customer, customer_id: customer_id)
      Customer.create(
        customer_id:    customer_id,
        name:           name,
        currency:       currency,
        country:        country,
        status:         status,
        billing_anchor: to_date(billing_anchor),
        churned_at:     status == 'churned' ? CUS_1003_CHURN_AT : nil
      )
    end
  end

  def seed_skus
    each_row('sku_price_book') do |row|
      sku, unit, list_unit_price_usd, category = row
      next if skip?(Sku, sku: sku)
      Sku.create(
        sku:                 sku,
        unit:                unit,
        list_unit_price_usd: to_decimal(list_unit_price_usd),
        category:            category
      )
    end
  end

  def seed_vendors
    each_row('vendors') do |row|
      vendor_id, name, category, currency, default_gl_account, default_department = row
      next if skip?(Vendor, vendor_id: vendor_id)
      Vendor.create(
        vendor_id:          vendor_id,
        name:               name,
        category:           category,
        currency:           currency,
        default_gl_account: default_gl_account.to_s,
        default_department: default_department
      )
    end
  end

  def seed_gl_accounts
    each_row('gl_accounts') do |row|
      account_code, name, account_type = row
      next if skip?(GlAccount, account_code: account_code.to_s)
      GlAccount.create(
        account_code: account_code.to_s,
        name:         name,
        account_type: account_type
      )
    end
  end

  # Synthetic FX rates for any non-USD currency a customer might use.
  # Anchor README pegs EUR @ 1.08; JPY and GBP added for the expanded demo.
  # Daily rates so a lookup at any period_end finds a row.
  def seed_fx_rates
    (Date.new(2026, 3, 1)..Date.new(2026, 3, 31)).each do |d|
      FX_RATES.each do |from_ccy, rate|
        next if skip?(FxRate, from_ccy: from_ccy, to_ccy: 'USD', effective_date: d)
        FxRate.create(
          from_ccy:       from_ccy,
          to_ccy:         'USD',
          rate:           BigDecimal(rate),
          effective_date: d
        )
      end
    end
  end

  def seed_chargebee_invoices
    each_row('chargebee_invoices') do |row|
      invoice_id, customer_code, period_start, period_end, issued_at, subtotal_usd, currency, fx_to_usd = row
      next if skip?(ChargebeeInvoice, invoice_id: invoice_id)
      ChargebeeInvoice.create(
        invoice_id:   invoice_id,
        customer_id:  customer_pk(customer_code),
        period_start: to_date(period_start),
        period_end:   to_date(period_end),
        issued_at:    to_time(issued_at),
        subtotal_usd: to_decimal(subtotal_usd),
        currency:     currency,
        fx_to_usd:    to_decimal(fx_to_usd)
      )
    end
  end

  def seed_purchase_orders
    each_row('purchase_orders') do |row|
      po_number, vendor_code, po_type, department, gl_account, currency, po_total_usd, po_status = row
      next if skip?(PurchaseOrder, po_number: po_number)
      PurchaseOrder.create(
        po_number:       po_number,
        vendor_id:       Vendor.where(vendor_id: vendor_code).first.id,
        po_type:         po_type,
        department:      department,
        gl_account_code: gl_account.to_s,
        currency:        currency,
        po_total_usd:    to_decimal(po_total_usd),
        po_status:       po_status
      )
    end
  end

  def seed_po_lines
    each_row('po_lines') do |row|
      po_number, po_line_ref, description, qty, uom, unit_price_usd, line_total_usd = row
      po = PurchaseOrder.where(po_number: po_number).first
      next if po.nil?  # PO row may have been skipped in append mode
      next if skip?(PoLine, purchase_order_id: po.id, po_line_ref: po_line_ref)
      PoLine.create(
        purchase_order_id: po.id,
        po_line_ref:       po_line_ref,
        description:       description,
        qty:               to_decimal(qty),
        uom:               uom,
        unit_price_usd:    to_decimal(unit_price_usd),
        line_total_usd:    to_decimal(line_total_usd)
      )
    end
  end

  def seed_goods_receipts
    each_row('goods_receipts') do |row|
      receipt_id, po_number, po_line_ref, received_qty, received_on, value_usd, notes = row
      next if skip?(GoodsReceipt, receipt_id: receipt_id)
      po      = PurchaseOrder.where(po_number: po_number).first
      po_line = PoLine.where(purchase_order_id: po.id, po_line_ref: po_line_ref).first
      GoodsReceipt.create(
        receipt_id:   receipt_id,
        po_line_id:   po_line.id,
        received_qty: to_decimal(received_qty),
        received_on:  to_date(received_on),
        value_usd:    to_decimal(value_usd),
        notes:        notes
      )
    end
  end

  def seed_vendor_invoices
    each_row('vendor_invoices') do |row|
      invoice_number, vendor_code, po_number, invoice_date, subtotal_usd, status = row
      next if invoice_number.nil? || invoice_number.to_s.strip.empty?
      next if skip?(VendorInvoice, invoice_number: invoice_number)
      VendorInvoice.create(
        invoice_number:    invoice_number,
        vendor_id:         Vendor.where(vendor_id: vendor_code).first.id,
        purchase_order_id: po_number ? PurchaseOrder.where(po_number: po_number).first&.id : nil,
        invoice_date:      to_date(invoice_date),
        subtotal_usd:      to_decimal(subtotal_usd),
        status:            status
      )
    end
  end

  def seed_anchor_usage_events
    each_row('usage_events') do |row|
      event_id, customer_code, sku_code, quantity, occurred_on = row
      next if skip?(UsageEvent, event_id: event_id)
      UsageEvent.create(
        event_id:    event_id,
        customer_id: customer_pk(customer_code),
        sku_id:      Sku.where(sku: sku_code).first.id,
        quantity:    to_decimal(quantity),
        occurred_on: to_date(occurred_on)
      )
    end
  end

  def seed_synthetic_history
    rng = Random.new(SYNTHETIC_RNG_SEED)

    CUSTOMER_BASELINES.each do |customer_code, sku_specs|
      customer = Customer.where(customer_id: customer_code).first
      next unless customer

      sku_specs.each do |params|
        sku = Sku.where(sku: params[:sku]).first
        next unless sku

        # Per-(customer, SKU) skip: if this pair already has synthetic
        # history, leave it alone. Lets a second dataset add NEW pairs in
        # append mode without duplicating IDs for previously-seeded ones.
        next if UsageEvent.where(customer_id: customer.id, sku_id: sku.id)
                          .where(Sequel.like(:event_id, 'evt_synth_%')).any?

        (SYNTHETIC_WINDOW_START..SYNTHETIC_WINDOW_END).each do |date|
          next if customer.churned? && customer.churned_at && date > customer.churned_at.to_date

          # Box-Muller for Gaussian noise
          u1 = rng.rand
          u2 = rng.rand
          z  = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
          raw = params[:mean] + (z * params[:sigma])
          quantity = [0.0, raw].max

          rounded = if params[:round].zero?
                      quantity.round
                    else
                      factor = 10**params[:round]
                      (quantity * factor).round / factor.to_f
                    end

          UsageEvent.create(
            event_id:    "evt_synth_#{customer_code}_#{date.strftime('%Y%m%d')}_#{params[:sku]}",
            customer_id: customer.id,
            sku_id:      sku.id,
            quantity:    BigDecimal(rounded.to_s),
            occurred_on: date
          )
        end
      end
    end
  end

  def each_row(sheet_name)
    sheet = @xlsx.sheet(sheet_name)
    sheet.each_with_index do |row, idx|
      next if idx.zero?
      next if row.all? { |c| c.nil? || c.to_s.strip.empty? }
      yield row
    end
  end

  def sheet_or_nil(name)
    @xlsx.sheet(name)
  rescue StandardError
    nil
  end

  def customer_pk(code)
    Customer.where(customer_id: code).first.id
  end

  def to_date(value)
    case value
    when Date    then value
    when DateTime then value.to_date
    when Time    then value.to_date
    when String  then Date.parse(value)
    when nil     then nil
    else raise "Unexpected date value: #{value.inspect}"
    end
  end

  def to_time(value)
    case value
    when Time     then value
    when DateTime then value.to_time
    when Date     then value.to_time
    when String   then Time.parse(value)
    when nil      then nil
    else raise "Unexpected time value: #{value.inspect}"
    end
  end

  def to_decimal(value)
    return nil if value.nil? || value.to_s.strip.empty?
    BigDecimal(value.to_s)
  end

  def summary
    [
      'Seed complete:',
      "  customers:           #{Customer.count}",
      "  skus:                #{Sku.count}",
      "  vendors:             #{Vendor.count}",
      "  gl_accounts:         #{GlAccount.count}",
      "  fx_rates:            #{FxRate.count}",
      "  chargebee_invoices:  #{ChargebeeInvoice.count}",
      "  purchase_orders:     #{PurchaseOrder.count}",
      "  po_lines:            #{PoLine.count}",
      "  goods_receipts:      #{GoodsReceipt.count}",
      "  vendor_invoices:     #{VendorInvoice.count}",
      "  usage_events:        #{UsageEvent.count} " \
      "(#{UsageEvent.where(Sequel.like(:event_id, 'evt_synth_%')).count} synthetic)"
    ].join("\n")
  end
end
