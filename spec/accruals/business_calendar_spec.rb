require 'spec_helper'

RSpec.describe Accruals::BusinessCalendar do
  describe '.next_business_day' do
    it 'Tue Mar 31 2026 → Wed Apr 1 2026 (the close-reversal case)' do
      expect(described_class.next_business_day(Date.new(2026, 3, 31)))
        .to eq(Date.new(2026, 4, 1))
    end

    it 'Fri → Mon (skips weekend)' do
      expect(described_class.next_business_day(Date.new(2026, 3, 27)))
        .to eq(Date.new(2026, 3, 30))
    end

    it 'Fri May 22 2026 → Tue May 26 (skips weekend AND Memorial Day Mon May 25)' do
      expect(described_class.next_business_day(Date.new(2026, 5, 22)))
        .to eq(Date.new(2026, 5, 26))
    end
  end

  describe '.business_day?' do
    it 'Tue is a business day' do
      expect(described_class.business_day?(Date.new(2026, 3, 31))).to be true
    end

    it 'Saturday is not' do
      expect(described_class.business_day?(Date.new(2026, 4, 4))).to be false
    end

    it "New Year's Day is not" do
      expect(described_class.business_day?(Date.new(2026, 1, 1))).to be false
    end
  end
end
