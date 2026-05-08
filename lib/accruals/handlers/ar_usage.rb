require 'bigdecimal'

module Accruals
  module Handlers
    # AR usage-based accrual: for each customer with usage events in the
    # unbilled window (period after the last Chargebee invoice through
    # period_end), book a single accrual = Σ quantity × SKU list_unit_price_usd.
    #
    # Multi-currency: the price book is USD-only, so amount_usd is the
    # canonical figure. For non-USD-billed customers, amount_billing_ccy
    # is derived via the FX-rate snap at period_end (display only — the
    # GL entry is USD).
    #
    # Anomaly flagging: per (customer, SKU), compare each window-day's
    # quantity against the customer's median+MAD over prior history. Any
    # flagged event → the whole customer accrual is marked `flagged`
    # (status), with the offending date(s) in `flagged_reason`. Amount
    # remains the actual computed value — nothing is smoothed or dropped.
    class ArUsage < Accruals::Handler
      DR_ACCOUNT_CODE = '1310'  # Accrued Revenue
      CR_ACCOUNT_CODE = '4010'  # Compute Services Revenue

      def self.handler_name
        'ar_usage'
      end

      def call
        window     = @close_run.unbilled_window
        period_end = @close_run.period_end

        events = UsageEvent.where(occurred_on: window).all
        events.group_by(&:customer_id).map do |customer_id, customer_events|
          build_draft(Customer[customer_id], customer_events, period_end)
        end.compact
      end

      private

      def build_draft(customer, events, period_end)
        return nil if events.empty?

        amount_usd = events.reduce(BigDecimal('0')) do |sum, e|
          sum + (e.quantity * Sku[e.sku_id].list_unit_price_usd)
        end

        fx_rate = FxRate.lookup!(from_ccy: customer.currency, to_ccy: 'USD', as_of: period_end)
        amount_billing_ccy = customer.currency == 'USD' ? amount_usd : (amount_usd / fx_rate).round(4)

        flag_reason = anomaly_reason(customer.id, events)

        Accruals::DraftAccrual.new(
          idempotency_key:      "ar_usage|#{period_end}|#{customer.customer_id}",
          handler_name:         self.class.handler_name,
          entity_kind:          'ar',
          status:               flag_reason ? 'flagged' : 'posted',
          memo:                 build_memo(customer, events),
          amount_usd:           amount_usd,
          amount_billing_ccy:   amount_billing_ccy,
          billing_currency:     customer.currency,
          fx_rate:              fx_rate,
          fx_rate_date:         period_end,
          gl_debit_account_id:  GlAccount.by_code(DR_ACCOUNT_CODE).id,
          gl_credit_account_id: GlAccount.by_code(CR_ACCOUNT_CODE).id,
          flagged_reason:       flag_reason,
          sources:              events.map { |e| { source_type: 'UsageEvent', source_id: e.id } }
        )
      end

      def anomaly_reason(customer_id, events)
        flagged = []

        events.group_by(&:sku_id).each do |sku_id, sku_events|
          baseline = baseline_quantities(customer_id, sku_id)
          detector = Accruals::AnomalyDetector.new(baseline: baseline)
          sku_events.each do |e|
            z = detector.z_score(e.quantity)
            next unless z && z > Accruals::AnomalyDetector::DEFAULT_Z_THRESHOLD
            flagged << {
              date:   e.occurred_on,
              sku:    Sku[sku_id].sku,
              qty:    e.quantity,
              median: detector.median.round(2),
              z:      z.round(1)
            }
          end
        end

        return nil if flagged.empty?
        flagged
          .map { |f| "#{f[:date]} #{f[:sku]} qty=#{f[:qty].to_s('F')} (median #{f[:median]}, z=#{f[:z]})" }
          .join('; ')
      end

      def baseline_quantities(customer_id, sku_id)
        UsageEvent
          .where(customer_id: customer_id, sku_id: sku_id)
          .where(Sequel.lit('occurred_on < ?', @close_run.unbilled_window.first))
          .map { |e| e.quantity }
      end

      def build_memo(customer, events)
        days = events.map(&:occurred_on).sort.uniq
        date_range = days.size == 1 ? days.first.to_s : "#{days.first}..#{days.last}"
        n = events.size
        "AR usage accrual for #{customer.customer_id} (#{customer.name}) — " \
          "#{n} event#{n == 1 ? '' : 's'} over #{date_range}"
      end
    end
  end
end
