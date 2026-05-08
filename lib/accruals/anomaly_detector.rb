module Accruals
  # Median + MAD-based outlier detector. Robust to outliers in the baseline
  # itself (which mean+stddev wouldn't be). 1.4826 is the MAD-to-σ scaling
  # constant for a normal distribution.
  #
  # Returns nil from `#z_score` when the baseline is too small or has zero
  # MAD (a constant series — no signal to judge against). Callers should
  # treat nil as "no opinion" rather than "not anomalous."
  class AnomalyDetector
    DEFAULT_Z_THRESHOLD = 3.0
    MIN_BASELINE_SIZE   = 7
    MAD_TO_SIGMA        = 1.4826

    def initialize(baseline:, z_threshold: DEFAULT_Z_THRESHOLD)
      @baseline = baseline.map(&:to_f)
      @z_threshold = z_threshold
    end

    def z_score(value)
      return nil if @baseline.size < MIN_BASELINE_SIZE
      sigma = mad * MAD_TO_SIGMA
      return nil if sigma.zero?
      (value.to_f - median).abs / sigma
    end

    def anomaly?(value)
      z = z_score(value)
      !z.nil? && z > @z_threshold
    end

    def median
      @median ||= compute_median(@baseline)
    end

    def mad
      @mad ||= begin
        m = median
        compute_median(@baseline.map { |v| (v - m).abs })
      end
    end

    private

    def compute_median(arr)
      sorted = arr.sort
      n = sorted.size
      n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    end
  end
end
