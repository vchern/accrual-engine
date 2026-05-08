class FxRate < Sequel::Model
  # Look up the rate from `from_ccy` to `to_ccy` on or before `as_of`.
  # Returns BigDecimal rate; raises if no rate is on file.
  def self.lookup!(from_ccy:, to_ccy:, as_of:)
    return BigDecimal('1') if from_ccy == to_ccy

    record = where(from_ccy: from_ccy, to_ccy: to_ccy)
             .where(Sequel[:effective_date] <= as_of)
             .reverse(:effective_date)
             .first

    raise "No FX rate for #{from_ccy}->#{to_ccy} on or before #{as_of}" unless record

    record.rate
  end
end
