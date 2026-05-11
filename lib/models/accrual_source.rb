class AccrualSource < Sequel::Model
  many_to_one :accrual

  # Manual polymorphic association — `source_type` is a model class name.
  def source
    return nil unless source_type && source_id
    Object.const_get(source_type).where(id: source_id).first
  end

  # Human-meaningful identifier of the underlying source row, for trace
  # output that a NetSuite auditor can match against the original XLSX
  # (e.g. "evt_u0001", "GR-2026-0042", "PO-2026-0188/L1"). Falls back to
  # the internal PK if the source row was deleted.
  def natural_ref
    s = source
    return source_id.to_s unless s

    case source_type
    when 'UsageEvent'       then s.event_id
    when 'GoodsReceipt'     then s.receipt_id
    when 'PoLine'           then "#{s.purchase_order&.po_number}/#{s.po_line_ref}"
    when 'ChargebeeInvoice' then s.invoice_id
    when 'VendorInvoice'    then s.invoice_number
    when 'Customer'         then s.customer_id
    when 'Vendor'           then s.vendor_id
    when 'PurchaseOrder'    then s.po_number
    else                         s.id.to_s
    end
  end
end
