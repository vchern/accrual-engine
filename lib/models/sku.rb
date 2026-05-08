class Sku < Sequel::Model
  one_to_many :usage_events
end
