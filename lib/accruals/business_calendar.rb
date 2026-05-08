require 'date'
require 'set'

module Accruals
  # Federal Reserve banking calendar — the right reference for an accrual
  # engine, since "next business day" for journal-entry purposes means
  # "next day banks/FX/payment systems are open," not "next day federal
  # employees are at work."
  #
  # Why hardcoded instead of a gem (e.g., `holidays`):
  # the public Ruby gems for US holidays apply OPM-style shift rules
  # ("Saturday holiday → observed Friday"), inconsistently and
  # incompletely. Federal Reserve banking observance is different:
  # Saturday holidays do NOT shift to Friday (banks stay open Friday);
  # Sunday holidays DO shift to Monday (banks closed Monday). Encoding
  # the curated list directly is correct, transparent, and auditable —
  # the very properties an accounting engine wants.
  #
  # Source: https://www.federalreserve.gov/aboutthefed/k8.htm
  # Update annually as the Federal Reserve publishes the next year's
  # schedule.
  module BusinessCalendar
    US_FED_HOLIDAYS = %w[
      2026-01-01  2026-01-19  2026-02-16  2026-05-25  2026-06-19
      2026-07-03  2026-09-07  2026-10-12  2026-11-11  2026-11-26  2026-12-25
      2027-01-01  2027-01-18  2027-02-15  2027-05-31  2027-06-19
      2027-07-05  2027-09-06  2027-10-11  2027-11-11  2027-11-25  2027-12-24
    ].map { |s| Date.parse(s) }.to_set.freeze

    module_function

    def business_day?(date)
      !date.saturday? && !date.sunday? && !US_FED_HOLIDAYS.include?(date)
    end

    def next_business_day(date)
      d = date + 1
      d += 1 until business_day?(d)
      d
    end
  end
end
