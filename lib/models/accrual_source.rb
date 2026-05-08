class AccrualSource < Sequel::Model
  many_to_one :accrual

  # Manual polymorphic association — `source_type` is a model class name.
  def source
    return nil unless source_type && source_id
    Object.const_get(source_type).where(id: source_id).first
  end
end
