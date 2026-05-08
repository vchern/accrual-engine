class GlAccount < Sequel::Model
  def self.by_code(code)
    where(account_code: code.to_s).first
  end
end
