require 'json'

class AuditEvent < Sequel::Model
  many_to_one :close_run
  many_to_one :accrual

  unrestrict_primary_key

  def payload_data
    return {} if payload.nil? || payload.empty?
    JSON.parse(payload)
  end

  def payload_data=(hash)
    self.payload = JSON.dump(hash)
  end
end
