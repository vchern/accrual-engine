class UsageEvent < Sequel::Model
  many_to_one :customer
  many_to_one :sku

  dataset_module do
    def in_window(start_date, end_date)
      where(occurred_on: start_date..end_date)
    end
  end
end
