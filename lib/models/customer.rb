class Customer < Sequel::Model
  one_to_many :usage_events
  one_to_many :chargebee_invoices

  def churned?
    status == 'churned'
  end

  # Returns true if the customer was active at any point on the given date.
  def active_on?(date)
    return true unless churned?
    return true if churned_at.nil?
    churned_at.to_date >= date
  end
end
