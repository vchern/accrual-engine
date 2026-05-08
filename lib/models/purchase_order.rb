class PurchaseOrder < Sequel::Model
  many_to_one :vendor
  one_to_many :po_lines
  one_to_many :vendor_invoices
end
