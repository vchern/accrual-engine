require 'spec_helper'

RSpec.describe Accruals::AnomalyDetector do
  describe '#anomaly?' do
    it 'flags a clear outlier (CUS-1001 25h vs 10h baseline)' do
      # Deterministic baseline with non-zero MAD (see seeder.rb's synthetic
      # generation for the realistic shape).
      baseline = [9, 10, 11, 10, 9, 11, 10, 12, 9, 10, 11, 10, 9, 10, 11, 10, 12, 9, 10, 11]
      detector = described_class.new(baseline: baseline)
      expect(detector.anomaly?(25)).to be true
    end

    it 'does not flag a value within the noise band' do
      baseline = Array.new(15) { |i| 10 + (i % 3 - 1) }
      detector = described_class.new(baseline: baseline)
      expect(detector.anomaly?(11)).to be false
    end

    it 'returns nil z_score when the baseline is too small' do
      detector = described_class.new(baseline: [10, 11, 12])
      expect(detector.z_score(20)).to be_nil
      expect(detector.anomaly?(20)).to be false
    end

    it 'returns nil z_score when MAD is zero (constant baseline)' do
      detector = described_class.new(baseline: Array.new(20) { 10 })
      expect(detector.z_score(50)).to be_nil
      expect(detector.anomaly?(50)).to be false
    end
  end

  describe '#median and #mad' do
    it 'computes median for an even-length sample' do
      detector = described_class.new(baseline: [1, 2, 3, 4])
      expect(detector.median).to eq(2.5)
    end

    it 'computes MAD as the median of absolute deviations from the median' do
      detector = described_class.new(baseline: [1, 1, 2, 2, 4, 6, 9])
      # median = 2; deviations = [1,1,0,0,2,4,7]; MAD = median of those = 1
      expect(detector.mad).to eq(1)
    end
  end
end
