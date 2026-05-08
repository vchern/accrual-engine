class VendorInvoice < Sequel::Model
  many_to_one :vendor
  many_to_one :purchase_order
end
