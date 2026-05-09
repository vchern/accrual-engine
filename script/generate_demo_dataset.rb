#!/usr/bin/env ruby
# Generates Helix_Demo_Expanded.xlsx — a richer Helix Compute dataset for
# the live walkthrough. Same company as the canonical anchor; expanded to
# 5 customers, 5 SKUs, 2 POs, multi-currency (USD/EUR/JPY/GBP), and two
# seeded anomalies instead of one.
#
# Run: bundle exec ruby script/generate_demo_dataset.rb
#
# Targets for period_end = 2026-03-31:
#   AR  $1,042.50  (5 customers, 13 unbilled-window events, 2 flagged)
#   AP  $150,000.00  (PO-2026-0188 \$100K + PO-2026-0190 \$50K, both GR-not-invoiced)
#   Total  $151,042.50

require 'caxlsx'

OUT = File.expand_path('../Helix_Demo_Expanded.xlsx', __dir__)

CUSTOMERS = [
  ['CUS-1001', 'Acme Robotics Inc.',     'USD', 'US', 'active',  '2024-11-03'],
  ['CUS-1002', 'Berlin Labs GmbH',       'EUR', 'DE', 'active',  '2025-01-12'],
  ['CUS-1003', 'Cobra Systems LLC',      'USD', 'US', 'churned', '2025-06-08'],
  ['CUS-1004', 'Tokyo AI Research',      'JPY', 'JP', 'active',  '2025-09-01'],
  ['CUS-1005', 'London Quant Capital',   'GBP', 'GB', 'active',  '2025-04-15']
].freeze

SKUS = [
  ['GPU-H100-HR',         'hour',      4.5,  'Compute'],
  ['STORAGE-TB-DAY',      'TB-day',    0.1,  'Storage'],
  ['INFERENCE-1K-TOKENS', '1k-tokens', 0.02, 'Inference'],
  ['GPU-A100-HR',         'hour',      3.0,  'Compute'],
  ['BANDWIDTH-TB',        'TB',        0.10, 'Network']
].freeze

VENDORS = [
  ['VEN-DELL-01', 'DataMetric Hardware Co.', 'hardware', 'USD', 1480, 'GPU Cloud Infra']
].freeze

GL_ACCOUNTS = [
  [1480, 'Computer Equipment — GPU Servers', 'Asset'],
  [2150, 'Accrued Expenses — AP',            'Liability'],
  [1310, 'Accrued Revenue',                  'Asset'],
  [4010, 'Compute Services Revenue',         'Revenue']
].freeze

# usage_events sheet — covers Mar 28-31, 2026.
# Mar 28 sits in the prior invoice (Mar 22-28); Mar 29-31 is the unbilled window.
USAGE_EVENTS = [
  # CUS-1001 GPU: steady 10h/day, anomaly Mar 30 = 25h.
  ['evt_h0001', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-28'],
  ['evt_u0001', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-29'],
  ['evt_u0002', 'CUS-1001', 'GPU-H100-HR',         25,   '2026-03-30'],
  ['evt_u0003', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-31'],
  # CUS-1002 storage: steady 200 TB-day.
  ['evt_h0002', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-28'],
  ['evt_u0004', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-29'],
  ['evt_u0005', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-30'],
  ['evt_u0006', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-31'],
  # CUS-1003 inference: churned EOD Mar 29, only one unbilled event.
  ['evt_h0003', 'CUS-1003', 'INFERENCE-1K-TOKENS', 5000, '2026-03-28'],
  ['evt_u0007', 'CUS-1003', 'INFERENCE-1K-TOKENS', 5000, '2026-03-29'],
  # CUS-1004 GPU-A100: steady 50h/day; bandwidth: 100 TB/day with Mar 30 anomaly = 300 TB.
  ['evt_h0004', 'CUS-1004', 'GPU-A100-HR',         50,   '2026-03-28'],
  ['evt_u0008', 'CUS-1004', 'GPU-A100-HR',         50,   '2026-03-29'],
  ['evt_u0009', 'CUS-1004', 'GPU-A100-HR',         50,   '2026-03-30'],
  ['evt_u0010', 'CUS-1004', 'GPU-A100-HR',         50,   '2026-03-31'],
  ['evt_h0005', 'CUS-1004', 'BANDWIDTH-TB',        100,  '2026-03-28'],
  ['evt_u0011', 'CUS-1004', 'BANDWIDTH-TB',        100,  '2026-03-29'],
  ['evt_u0012', 'CUS-1004', 'BANDWIDTH-TB',        300,  '2026-03-30'],
  ['evt_u0013', 'CUS-1004', 'BANDWIDTH-TB',        100,  '2026-03-31'],
  # CUS-1005 inference + storage: steady.
  ['evt_h0006', 'CUS-1005', 'INFERENCE-1K-TOKENS', 2500, '2026-03-28'],
  ['evt_u0014', 'CUS-1005', 'INFERENCE-1K-TOKENS', 2500, '2026-03-29'],
  ['evt_u0015', 'CUS-1005', 'INFERENCE-1K-TOKENS', 2500, '2026-03-30'],
  ['evt_u0016', 'CUS-1005', 'INFERENCE-1K-TOKENS', 2500, '2026-03-31'],
  ['evt_h0007', 'CUS-1005', 'STORAGE-TB-DAY',      100,  '2026-03-28'],
  ['evt_u0017', 'CUS-1005', 'STORAGE-TB-DAY',      100,  '2026-03-29'],
  ['evt_u0018', 'CUS-1005', 'STORAGE-TB-DAY',      100,  '2026-03-30'],
  ['evt_u0019', 'CUS-1005', 'STORAGE-TB-DAY',      100,  '2026-03-31']
].freeze

CHARGEBEE_INVOICES = [
  ['INV-2026-0291', 'CUS-1001', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z',  315.00, 'USD', 1.0],
  ['INV-2026-0292', 'CUS-1002', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z',  140.00, 'EUR', 1.08],
  ['INV-2026-0293', 'CUS-1003', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z',  700.00, 'USD', 1.0],
  ['INV-2026-0294', 'CUS-1004', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z', 1120.00, 'JPY', 0.0067],
  ['INV-2026-0295', 'CUS-1005', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z',  420.00, 'GBP', 1.27]
].freeze

PURCHASE_ORDERS = [
  ['PO-2026-0188', 'VEN-DELL-01', 'Goods', 'GPU Cloud Infra', 1480, 'USD', 250000.00, 'Open'],
  ['PO-2026-0190', 'VEN-DELL-01', 'Goods', 'GPU Cloud Infra', 1480, 'USD', 100000.00, 'Open']
].freeze

PO_LINES = [
  ['PO-2026-0188', 'L1', 'GPU Server Rack — 8x H100 SXM5',  5, 'each', 50000.00, 250000.00],
  ['PO-2026-0190', 'L1', 'GPU Server Rack — 8x A100 SXM4',  2, 'each', 50000.00, 100000.00]
].freeze

GOODS_RECEIPTS = [
  ['GR-2026-0042', 'PO-2026-0188', 'L1', 2, '2026-03-25', 100000.00, 'Partial receipt — 2 of 5 racks delivered'],
  ['GR-2026-0043', 'PO-2026-0190', 'L1', 1, '2026-03-27', 50000.00,  'Partial receipt — 1 of 2 racks delivered']
].freeze

# vendor_invoices sheet stays empty — same as the anchor (GR-not-invoiced case).
VENDOR_INVOICES = [].freeze

Axlsx::Package.new do |p|
  p.workbook do |wb|
    wb.add_worksheet(name: 'README') do |s|
      s.add_row ['Helix Compute Inc. — Expanded Demo Dataset']
      s.add_row []
      s.add_row ['Same company as the canonical anchor, expanded for richer demos.']
      s.add_row ['5 customers (USD/EUR/USD/JPY/GBP), 5 SKUs, 1 vendor, 2 POs.']
      s.add_row ['Two seeded anomalies: CUS-1001 Mar 30 GPU spike, CUS-1004 Mar 30 bandwidth spike.']
      s.add_row []
      s.add_row ['Targets for period_end=2026-03-31:']
      s.add_row ['  AR    $1,042.50  (5 customers, 2 flagged)']
      s.add_row ['  AP    $150,000.00 (2 GR-not-invoiced)']
      s.add_row ['  Total $151,042.50']
    end

    wb.add_worksheet(name: 'customers') do |s|
      s.add_row %w[customer_id name currency country status billing_anchor]
      CUSTOMERS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'sku_price_book') do |s|
      s.add_row %w[sku unit list_unit_price_usd category]
      SKUS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'usage_events') do |s|
      s.add_row %w[event_id customer_id sku quantity occurred_on]
      USAGE_EVENTS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'chargebee_invoices') do |s|
      s.add_row %w[invoice_id customer_id period_start period_end issued_at subtotal_usd currency fx_to_usd]
      CHARGEBEE_INVOICES.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'vendors') do |s|
      s.add_row %w[vendor_id name category currency default_gl_account default_department]
      VENDORS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'gl_accounts') do |s|
      s.add_row %w[account_code name type]
      GL_ACCOUNTS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'purchase_orders') do |s|
      s.add_row %w[po_number vendor_id po_type department gl_account currency po_total_usd po_status]
      PURCHASE_ORDERS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'po_lines') do |s|
      s.add_row %w[po_number po_line_ref description qty uom unit_price_usd line_total_usd]
      PO_LINES.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'goods_receipts') do |s|
      s.add_row %w[receipt_id po_number po_line_ref received_qty received_on value_usd notes]
      GOODS_RECEIPTS.each { |row| s.add_row row }
    end

    wb.add_worksheet(name: 'vendor_invoices') do |s|
      s.add_row %w[invoice_number vendor_id po_number invoice_date subtotal_usd status]
      VENDOR_INVOICES.each { |row| s.add_row row }
    end
  end

  p.serialize(OUT)
end

puts "Wrote #{OUT}"
