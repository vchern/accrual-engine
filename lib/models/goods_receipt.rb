class GoodsReceipt < Sequel::Model
  many_to_one :po_line

  dataset_module do
    def received_by(date)
      where(Sequel[:received_on] <= date)
    end
  end

  def purchase_order
    po_line&.purchase_order
  end

  def vendor
    purchase_order&.vendor
  end

  def fully_invoiced?
    return false unless purchase_order
    invoiced_total = VendorInvoice.where(purchase_order_id: purchase_order.id).sum(:subtotal_usd) || BigDecimal('0')
    invoiced_total >= value_usd
  end
end
