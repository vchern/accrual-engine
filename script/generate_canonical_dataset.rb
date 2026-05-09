#!/usr/bin/env ruby
# Generates Helix_Anchor_Canonical.xlsx — a synthetic regeneration of the
# brief's canonical anchor. Same data values, written from scratch, with
# a new README that doesn't carry the brief's proprietary instructions.
#
# Run: bundle exec ruby script/generate_canonical_dataset.rb
#
# When the engine runs against this file for period_end=2026-03-31 it
# produces the brief's target totals exactly:
#   AR     $362.50    (3 customers · 7 events · Mar 29-31)
#   AP $100,000.00    (GR-2026-0042 partial receipt, no vendor invoice)
#   Total $100,362.50

require 'caxlsx'

OUT = File.expand_path('../Helix_Anchor_Canonical.xlsx', __dir__)

CUSTOMERS = [
  ['CUS-1001', 'Acme Robotics Inc.', 'USD', 'US', 'active',  '2024-11-03'],
  ['CUS-1002', 'Berlin Labs GmbH',   'EUR', 'DE', 'active',  '2025-01-12'],
  ['CUS-1003', 'Cobra Systems LLC',  'USD', 'US', 'churned', '2025-06-08']
].freeze

SKUS = [
  ['GPU-H100-HR',         'hour',      4.5,  'Compute'],
  ['STORAGE-TB-DAY',      'TB-day',    0.1,  'Storage'],
  ['INFERENCE-1K-TOKENS', '1k-tokens', 0.02, 'Inference']
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

USAGE_EVENTS = [
  # Mar 28 — already invoiced (prior period).
  ['evt_h0001', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-28'],
  ['evt_h0002', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-28'],
  ['evt_h0003', 'CUS-1003', 'INFERENCE-1K-TOKENS', 5000, '2026-03-28'],
  # Mar 29-31 — unbilled window. CUS-1001 Mar 30 is the seeded anomaly.
  ['evt_u0001', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-29'],
  ['evt_u0002', 'CUS-1001', 'GPU-H100-HR',         25,   '2026-03-30'],
  ['evt_u0003', 'CUS-1001', 'GPU-H100-HR',         10,   '2026-03-31'],
  ['evt_u0004', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-29'],
  ['evt_u0005', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-30'],
  ['evt_u0006', 'CUS-1002', 'STORAGE-TB-DAY',      200,  '2026-03-31'],
  # CUS-1003 churned EOD Mar 29 — single unbilled event.
  ['evt_u0007', 'CUS-1003', 'INFERENCE-1K-TOKENS', 5000, '2026-03-29']
].freeze

CHARGEBEE_INVOICES = [
  ['INV-2026-0291', 'CUS-1001', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z', 315.00, 'USD', 1.0],
  ['INV-2026-0292', 'CUS-1002', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z', 140.00, 'EUR', 1.08],
  ['INV-2026-0293', 'CUS-1003', '2026-03-22', '2026-03-28', '2026-03-29T00:00:00Z', 700.00, 'USD', 1.0]
].freeze

PURCHASE_ORDERS = [
  ['PO-2026-0188', 'VEN-DELL-01', 'Goods', 'GPU Cloud Infra', 1480, 'USD', 250000.00, 'Open']
].freeze

PO_LINES = [
  ['PO-2026-0188', 'L1', 'GPU Server Rack — 8x H100 SXM5', 5, 'each', 50000.00, 250000.00]
].freeze

GOODS_RECEIPTS = [
  ['GR-2026-0042', 'PO-2026-0188', 'L1', 2, '2026-03-25', 100000.00, 'Partial receipt — 2 of 5 racks delivered']
].freeze

VENDOR_INVOICES = [].freeze   # GR-not-invoiced case is the whole point.

Axlsx::Package.new do |p|
  p.workbook do |wb|
    wb.add_worksheet(name: 'README') do |s|
      s.add_row ['Helix Compute Inc. — Canonical Anchor (synthetic regeneration)']
      s.add_row []
      s.add_row ['Same data values as the brief\'s anchor, written from scratch and']
      s.add_row ['shipped in the public repo as a one-click demo sample.']
      s.add_row []
      s.add_row ['When the engine runs against this file for period_end=2026-03-31:']
      s.add_row ['  AR     $362.50    (3 customers, 7 events, Mar 29-31)']
      s.add_row ['  AP $100,000.00    (GR-2026-0042 partial receipt, no vendor invoice)']
      s.add_row ['  Total $100,362.50']
      s.add_row []
      s.add_row ['Edge cases:']
      s.add_row ['  CUS-1001 Mar 30 lands flagged (25h vs ~10h median, z ≈ 6.1).']
      s.add_row ['  CUS-1002 (EUR) books in USD via FX 1.08 (price book is USD).']
      s.add_row ['  CUS-1003 churned EOD Mar 29 → 1-day accrual.']
      s.add_row ['  PO-2026-0188 partial receipt (2 of 5 racks); no vendor invoice yet.']
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
