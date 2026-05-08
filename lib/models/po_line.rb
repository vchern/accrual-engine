class PoLine < Sequel::Model
  many_to_one :purchase_order
  one_to_many :goods_receipts

  def vendor
    purchase_order&.vendor
  end
end
