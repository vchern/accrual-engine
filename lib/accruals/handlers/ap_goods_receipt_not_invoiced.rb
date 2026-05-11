require 'bigdecimal'

module Accruals
  module Handlers
    # AP Goods-Receipt-Not-Invoiced accrual: for each goods receipt posted
    # on or before period_end, accrue the portion not yet covered by a
    # vendor invoice against the same PO.
    #
    # DR side: PO line's GL account (e.g. 1480 Computer Equipment for the
    # Dell servers PO). CR side: 2150 Accrued Expenses – AP (the GR/IR
    # clearing account).
    #
    # Currency: PO/receipt currencies are read from the PO row. Anchor's
    # only PO is USD, so amount_usd == receipt.value_usd. For non-USD
    # POs, FX conversion would happen here — left as a follow-up since
    # it's not exercised by anchor data.
    class ApGoodsReceiptNotInvoiced < Accruals::Handler
      CR_ACCOUNT_CODE = '2150'

      def self.handler_name
        'ap_gr_not_invoiced'
      end

      def call
        period_end = @close_run.period_end
        receipts = GoodsReceipt.where(Sequel.lit('received_on <= ?', period_end)).all
        receipts.map { |r| build_draft(r, period_end) }.compact
      end

      private

      def build_draft(receipt, period_end)
        po_line = receipt.po_line
        po      = po_line.purchase_order

        invoiced  = invoiced_amount_for(po)
        uninvoiced = receipt.value_usd - invoiced
        return nil if uninvoiced <= BigDecimal('0')

        debit_account  = GlAccount.by_code(po.gl_account_code)
        credit_account = GlAccount.by_code(CR_ACCOUNT_CODE)

        # A single PO with an unrecognized GL code shouldn't crash the
        # whole month-end close. Surface the bad row to the controller as
        # `blocked` (off the JE; reason in `flagged_reason`); the rest of
        # the close completes; re-running after a data fix picks it up.
        block_reason = if debit_account.nil?
                         "PO #{po.po_number} references unknown GL account #{po.gl_account_code}"
                       elsif credit_account.nil?
                         "Missing GL config for accrued AP credit account #{CR_ACCOUNT_CODE}"
                       end

        Accruals::DraftAccrual.new(
          idempotency_key:      "ap_gr_not_invoiced|#{period_end}|#{receipt.receipt_id}",
          handler_name:         self.class.handler_name,
          entity_kind:          'ap',
          status:               block_reason ? 'blocked' : 'posted',
          memo:                 build_memo(receipt, po, po_line),
          amount_usd:           uninvoiced,
          amount_billing_ccy:   uninvoiced,
          billing_currency:     po.currency,
          fx_rate:              BigDecimal('1'),
          fx_rate_date:         period_end,
          gl_debit_account_id:  debit_account&.id,
          gl_credit_account_id: credit_account&.id,
          flagged_reason:       block_reason,
          sources: [
            { source_type: 'GoodsReceipt', source_id: receipt.id },
            { source_type: 'PoLine',       source_id: po_line.id }
          ]
        )
      end

      def invoiced_amount_for(po)
        VendorInvoice
          .where(purchase_order_id: po.id)
          .map(&:subtotal_usd)
          .reduce(BigDecimal('0'), :+)
      end

      def build_memo(receipt, po, po_line)
        "AP accrual for #{receipt.receipt_id} (#{po.po_number} #{po_line.po_line_ref}, " \
          "qty=#{receipt.received_qty.to_s('F')})"
      end
    end
  end
end
