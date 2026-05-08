class Vendor < Sequel::Model
  one_to_many :purchase_orders
  one_to_many :vendor_invoices
end
