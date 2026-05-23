require 'sinatra/base'
require 'sinatra/contrib'
require 'bigdecimal'
require 'date'
require 'fileutils'
require 'tmpdir'
require_relative 'lib/models'
require_relative 'lib/accruals'
require_relative 'lib/seeder'

module Lambda
  class App < Sinatra::Base
    set :root, ROOT
    set :views, File.join(ROOT, 'views')
    set :public_folder, File.join(ROOT, 'public')
    set :default_encoding, 'utf-8'

    configure :development do
      register Sinatra::Reloader
      also_reload File.join(ROOT, 'lib', '**', '*.rb')
    end

    helpers do
      def usd(amount)
        return '&mdash;' if amount.nil?
        big = amount.is_a?(BigDecimal) ? amount : BigDecimal(amount.to_s)
        sign = big.negative? ? '-' : ''
        whole, frac = format('%.2f', big.abs).split('.')
        commas = whole.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
        "#{sign}$#{commas}.#{frac}"
      end

      def num(value, dp: 2)
        return '&mdash;' if value.nil?
        big = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        format("%.#{dp}f", big)
      end

      def status_pill(status)
        classes =
          case status
          when 'completed', 'posted'         then 'bg-emerald-50 text-emerald-700 ring-emerald-200'
          when 'approved'                    then 'bg-blue-50 text-blue-700 ring-blue-200'
          when 'flagged', 'running'          then 'bg-amber-50 text-amber-700 ring-amber-200'
          when 'failed', 'blocked', 'rejected' then 'bg-red-50 text-red-700 ring-red-200'
          when 'pending'                     then 'bg-slate-100 text-slate-700 ring-slate-200'
          else                                     'bg-slate-100 text-slate-700 ring-slate-200'
          end
        %(<span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset #{classes}">#{status}</span>)
      end

      def entity_pill(kind)
        label = kind.to_s.upcase
        cls = kind == 'ar' ? 'bg-blue-50 text-blue-700 ring-blue-200' : 'bg-purple-50 text-purple-700 ring-purple-200'
        %(<span class="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ring-1 ring-inset #{cls}">#{label}</span>)
      end

      def datetime(t)
        return '&mdash;' if t.nil?
        Time.parse(t.to_s).strftime('%Y-%m-%d %H:%M:%S UTC')
      end

      def date_str(d)
        return '&mdash;' if d.nil?
        Date.parse(d.to_s).strftime('%Y-%m-%d')
      end

      def tab_link(close_run, label, tab, count: nil, current:)
        active = current == tab
        cls = active ? 'border-slate-900 text-slate-900' : 'border-transparent text-slate-500 hover:text-slate-700 hover:border-slate-300'
        count_html = count ? %( <span class="ml-1 text-xs text-slate-400">#{count}</span>) : ''
        %(<a href="/closes/#{close_run.id}?tab=#{tab}" class="border-b-2 px-1 pb-3 text-sm font-medium #{cls}">#{label}#{count_html}</a>)
      end

      def filter_chip(close_run, label, value, count, current:)
        active = current == value
        cls = active ? 'bg-slate-900 text-white' : 'bg-white text-slate-700 ring-1 ring-inset ring-slate-200 hover:bg-slate-50'
        %(<a href="/closes/#{close_run.id}?tab=accruals&filter=#{value}" class="inline-flex items-center rounded-full px-3 py-1 text-xs font-medium #{cls}">#{label} <span class="ml-1.5 opacity-60">#{count}</span></a>)
      end


      def accrual_label(accrual)
        case accrual.handler_name
        when 'ar_usage'
          src = accrual.accrual_sources.first
          if src
            ev = UsageEvent[src.source_id]
            cust = Customer[ev.customer_id]
            "#{cust.customer_id} #{cust.name}"
          else
            accrual.idempotency_key
          end
        when 'ap_gr_not_invoiced'
          gr_src = accrual.accrual_sources.find { |s| s.source_type == 'GoodsReceipt' }
          if gr_src
            gr = GoodsReceipt[gr_src.source_id]
            "#{gr.receipt_id} (#{gr.purchase_order.po_number})"
          else
            accrual.idempotency_key
          end
        else
          accrual.idempotency_key
        end
      end
    end

    # Routes ------------------------------------------------------------------

    get '/' do
      redirect '/closes'
    end

    get '/health' do
      content_type :json
      { status: 'ok', env: APP_ENV }.to_json
    end

    get '/closes' do
      redirect '/import' unless reference_loaded?
      @closes = CloseRun.order(Sequel.desc(:created_at)).all
      @totals_by_close = @closes.each_with_object({}) do |c, h|
        accruals = Accrual.where(close_run_id: c.id).all
        h[c.id] = {
          accruals: accruals.size,
          flagged:  accruals.count { |a| a.status == 'flagged' },
          total:    accruals.map(&:amount_usd).reduce(BigDecimal('0'), :+)
        }
      end
      erb :'closes/index'
    end

    # All tables in dependency-safe order for full wipe.
    ALL_TABLES = %i[
      journal_lines journal_entries accrual_sources audit_events accruals close_runs
      vendor_invoices goods_receipts po_lines purchase_orders
      chargebee_invoices usage_events
      fx_rates gl_accounts vendors skus customers
    ].freeze

    UPLOAD_PATH        = File.join(Dir.tmpdir, 'lambda_uploaded_anchor.xlsx').freeze
    SAMPLE_ANCHOR_PATH = File.join(ROOT, 'Helix_Anchor_Canonical.xlsx').freeze
    SAMPLE_DEMO_PATH   = File.join(ROOT, 'Helix_Demo_Expanded.xlsx').freeze

    helpers do
      def reference_loaded?
        Customer.count.positive? && Sku.count.positive?
      end

      def sample_anchor_available?
        File.exist?(SAMPLE_ANCHOR_PATH)
      end

      def sample_demo_available?
        File.exist?(SAMPLE_DEMO_PATH)
      end

      def write_accrual_audit(close_run, accrual, action, prev_state)
        ev = AuditEvent.new(
          close_run_id: close_run.id,
          accrual_id:   accrual.id,
          action:       action.to_s,
          actor:        'controller',
          created_at:   Time.now.utc
        )
        ev.payload_data = { previous_status: prev_state, current_status: accrual.status }
        ev.save
      end

      def import_counts
        {
          customers:        Customer.count,
          skus:             Sku.count,
          gl_accounts:      GlAccount.count,
          vendors:          Vendor.count,
          usage_events:     UsageEvent.count,
          purchase_orders:  PurchaseOrder.count,
          goods_receipts:   GoodsReceipt.count
        }
      end

      # Returns { state: :added | :failed | :skipped | :generating, message:, model: }
      # describing whether a close has an LLM-generated executive summary.
      # `:generating` means engine.run! has completed but the background LLM
      # thread either hasn't finished writing yet or crashed silently — in
      # both cases the user can refresh in a few seconds to recheck.
      def summary_status(close_run)
        if close_run.summary && !close_run.summary.to_s.empty?
          return { state: :added, message: close_run.summary, model: close_run.summary_model }
        end

        failed = AuditEvent.where(close_run_id: close_run.id, action: 'close_summary_failed')
                            .order(Sequel.desc(:created_at)).first
        return { state: :failed, message: failed.payload_data['error'].to_s } if failed

        skipped = AuditEvent.where(close_run_id: close_run.id, action: 'close_summary_skipped')
                            .order(Sequel.desc(:created_at)).first
        return { state: :skipped, message: skipped.payload_data['reason'].to_s } if skipped

        { state: :generating }
      end

      # Returns { state: :added | :failed | :skipped | :generating, message:, model: }
      # describing why a flagged accrual does or doesn't have an LLM narration.
      # Reads the audit log written by Engine#narrate_flagged_accruals.
      def narration_status(accrual)
        if accrual.review_narration && !accrual.review_narration.to_s.empty?
          return { state: :added,
                   message: accrual.review_narration,
                   model:   accrual.review_narration_model }
        end

        failed = AuditEvent.where(accrual_id: accrual.id, action: 'review_narration_failed')
                            .order(Sequel.desc(:created_at)).first
        return { state: :failed, message: failed.payload_data['error'].to_s } if failed

        skipped = AuditEvent.where(close_run_id: accrual.close_run_id, action: 'review_narration_skipped')
                            .order(Sequel.desc(:created_at)).first
        return { state: :skipped, message: skipped.payload_data['reason'].to_s } if skipped

        { state: :generating, message: nil }
      end
    end

    get '/import' do
      @counts = import_counts
      erb :'import/show'
    end

    DATA_TABS = [
      ['customers',          'Customers'],
      ['vendors',            'Vendors'],
      ['skus',               'SKUs'],
      ['gl_accounts',        'GL Accounts'],
      ['fx_rates',           'FX Rates'],
      ['usage_events',       'Usage Events'],
      ['chargebee_invoices', 'Chargebee Invoices'],
      ['purchase_orders',    'Purchase Orders'],
      ['po_lines',           'PO Lines'],
      ['goods_receipts',     'Goods Receipts'],
      ['vendor_invoices',    'Vendor Invoices']
    ].freeze

    DATA_TAB_QUERIES = {
      'customers'          => -> { { rows: Customer.order(:customer_id), total: Customer.count } },
      'vendors'            => -> { { rows: Vendor.order(:vendor_id), total: Vendor.count } },
      'skus'               => -> { { rows: Sku.order(:sku), total: Sku.count } },
      'gl_accounts'        => -> { { rows: GlAccount.order(:account_code), total: GlAccount.count } },
      'fx_rates'           => -> { { rows: FxRate.order(:from_ccy, :effective_date), total: FxRate.count } },
      'usage_events'       => -> { { rows: UsageEvent.order(Sequel.desc(:occurred_on), :event_id), total: UsageEvent.count } },
      'chargebee_invoices' => -> { { rows: ChargebeeInvoice.order(Sequel.desc(:issued_at)), total: ChargebeeInvoice.count } },
      'purchase_orders'    => -> { { rows: PurchaseOrder.order(:po_number), total: PurchaseOrder.count } },
      'po_lines'           => -> { { rows: PoLine.order(:purchase_order_id, :po_line_ref), total: PoLine.count } },
      'goods_receipts'     => -> { { rows: GoodsReceipt.order(Sequel.desc(:received_on), :receipt_id), total: GoodsReceipt.count } },
      'vendor_invoices'    => -> { { rows: VendorInvoice.order(Sequel.desc(:invoice_date), :invoice_number), total: VendorInvoice.count } }
    }.freeze

    get '/audit' do
      @row_cap     = 500
      @total_count = AuditEvent.count
      @events      = AuditEvent.order(Sequel.desc(:created_at), Sequel.desc(:id)).limit(@row_cap).all
      @close_runs  = CloseRun.all.each_with_object({}) { |c, h| h[c.id] = c }
      erb :'audit/show'
    end

    get '/data' do
      @row_cap = 200
      requested = params[:tab].to_s
      valid_tabs = DATA_TABS.map(&:first)
      @tab = valid_tabs.include?(requested) ? requested : 'customers'

      @tab_counts = valid_tabs.each_with_object({}) do |t, h|
        h[t] = DATA_TAB_QUERIES[t].call[:total]
      end

      active = DATA_TAB_QUERIES[@tab].call
      @active_rows = active[:rows].limit(@row_cap).all
      @active_total = active[:total]
      @all_empty = @tab_counts.values.all?(&:zero?)

      erb :'data/show'
    end

    post '/import' do
      file = params[:anchor_file]
      halt 400, 'anchor_file is required (multipart upload).' unless file && file[:tempfile]

      original = file[:filename].to_s
      halt 400, 'must be a .xlsx file' unless original.downcase.end_with?('.xlsx')

      mode = params[:mode] == 'append' ? :append : :replace

      FileUtils.cp(file[:tempfile].path, UPLOAD_PATH)

      # Validate BEFORE wiping any data — a malformed file leaves the existing
      # state intact and the user gets a clear list of what needs fixing.
      begin
        Seeder.validate!(path: UPLOAD_PATH)
      rescue Seeder::SchemaError => e
        @counts = import_counts
        @schema_errors = e.errors
        status 422
        return erb :'import/show'
      end

      # Single transaction wrapping wipe + seed — if seed fails, the wipe
      # rolls back too, so we never end up with a half-empty DB.
      DB.transaction do
        ALL_TABLES.each { |t| DB[t].delete } if mode == :replace
        Seeder.run!(path: UPLOAD_PATH, log: ->(_) {}, mode: mode)
      end

      redirect '/closes'
    end

    post '/import/sample' do
      halt 404, 'No bundled sample available' unless sample_anchor_available?

      DB.transaction do
        ALL_TABLES.each { |t| DB[t].delete }
        Seeder.run!(path: SAMPLE_ANCHOR_PATH, log: ->(_) {})
      end

      redirect '/closes'
    end

    post '/import/demo' do
      halt 404, 'No bundled demo dataset available' unless sample_demo_available?

      DB.transaction do
        ALL_TABLES.each { |t| DB[t].delete }
        Seeder.run!(path: SAMPLE_DEMO_PATH, log: ->(_) {})
      end

      redirect '/closes'
    end

    post '/closes/reset' do
      DB.transaction { ALL_TABLES.each { |t| DB[t].delete } }
      redirect '/closes'
    end

    post '/closes/:id/delete' do
      close_run = CloseRun[params[:id].to_i] or halt(404, 'Close run not found')

      DB.transaction do
        accrual_ids   = Accrual.where(close_run_id: close_run.id).select_map(:id)
        je_ids        = JournalEntry.where(close_run_id: close_run.id).select_map(:id)
        accrual_count = accrual_ids.size
        flagged_count = Accrual.where(close_run_id: close_run.id, status: 'flagged').count
        total_amount  = Accrual.where(close_run_id: close_run.id).sum(:amount_usd) || BigDecimal('0')

        # Write the deletion audit BEFORE the cascade and with a nil
        # close_run_id so the audit row survives its own subject's
        # deletion. Payload snapshots the relevant facts so a reviewer
        # can still see what was deleted on /audit.
        deletion = AuditEvent.new(
          close_run_id: nil,
          action:       'close_deleted',
          actor:        'controller',
          created_at:   Time.now.utc
        )
        deletion.payload_data = {
          deleted_close_run_id:    close_run.id,
          period_end:              close_run.period_end.to_s,
          status:                  close_run.status,
          accrual_count:           accrual_count,
          flagged_count:           flagged_count,
          journal_entry_count:     je_ids.size,
          total_amount_usd:        total_amount.to_s
        }
        deletion.save

        # Order matters: delete the FK referrers (journal lines/entries,
        # accrual sources, audit events) before the referents (accruals,
        # close run). Audit events FK to accrual_id, so they go first.
        JournalLine.where(journal_entry_id: je_ids).delete unless je_ids.empty?
        JournalEntry.where(id: je_ids).delete unless je_ids.empty?
        AccrualSource.where(accrual_id: accrual_ids).delete unless accrual_ids.empty?
        AuditEvent.where(close_run_id: close_run.id).delete
        Accrual.where(id: accrual_ids).delete unless accrual_ids.empty?
        close_run.delete
      end

      redirect '/closes'
    end

    post '/closes' do
      period_end_str = params[:period_end].to_s.strip
      halt 400, 'period_end is required' if period_end_str.empty?

      period_end = Date.parse(period_end_str)
      close_run = CloseRun.where(period_end: period_end).first || CloseRun.create(
        period_start: period_end - 30,
        period_end:   period_end,
        status:       'pending'
      )

      begin
        Accruals::Engine.new(close_run).run!
      rescue StandardError
        # Engine already audited and marked the run failed; redirect anyway.
      end

      redirect "/closes/#{close_run.id}"
    end

    get '/closes/:id' do
      @close_run = CloseRun[params[:id].to_i] or halt(404, 'Close run not found')
      @tab    = params[:tab]    || 'overview'
      @filter = params[:filter] || 'all'

      @accruals = Accrual.where(close_run_id: @close_run.id).order(:entity_kind, :idempotency_key).all
      @ar_count       = @accruals.count { |a| a.entity_kind == 'ar' }
      @ap_count       = @accruals.count { |a| a.entity_kind == 'ap' }
      @flagged_count  = @accruals.count { |a| a.status == 'flagged' }
      @approved_count = @accruals.count { |a| a.status == 'approved' }
      @rejected_count = @accruals.count { |a| a.status == 'rejected' }
      @blocked_count  = @accruals.count { |a| a.status == 'blocked' }
      @total_usd      = @accruals.map(&:amount_usd).reduce(BigDecimal('0'), :+)

      @journal_entries = JournalEntry.where(close_run_id: @close_run.id).order(:entry_date, :id).all
      @audit_events    = AuditEvent.where(close_run_id: @close_run.id).order(Sequel.desc(:created_at), Sequel.desc(:id)).all

      erb :'closes/show'
    end

    get '/closes/:id/accruals/:aid' do
      @close_run = CloseRun[params[:id].to_i] or halt(404, 'Close run not found')
      @accrual   = Accrual[params[:aid].to_i] or halt(404, 'Accrual not found')
      halt(404, 'Accrual does not belong to this close') unless @accrual.close_run_id == @close_run.id

      @sources = @accrual.accrual_sources.map { |s| [s, s.source] }

      # Lines this accrual contributed to the close's consolidated JEs,
      # grouped by their parent JE for display.
      lines = JournalLine.where(accrual_id: @accrual.id).order(:journal_entry_id, :id).all
      @lines_by_je = lines.group_by(&:journal_entry_id)
      @journal_entries = lines.map(&:journal_entry).uniq.sort_by(&:entry_date)

      erb :'accruals/show'
    end

    # Controller review action: approve / reject / reset a flagged accrual.
    # Updates the accrual status, regenerates the close's consolidated JEs
    # (so an approval lands on the JE immediately; a reject drops it),
    # and audits the transition with prev->current status.
    post '/closes/:id/accruals/:aid/review' do
      close_run = CloseRun[params[:id].to_i] or halt(404, 'Close run not found')
      accrual   = Accrual[params[:aid].to_i] or halt(404, 'Accrual not found')
      halt(404, 'Accrual does not belong to this close') unless accrual.close_run_id == close_run.id

      decision   = params[:decision].to_s
      prev_state = accrual.status

      case decision
      when 'approved', 'rejected'
        halt(422, 'must be flagged to approve or reject') unless accrual.status == 'flagged'
        accrual.update(status: decision)
        write_accrual_audit(close_run, accrual, "accrual_#{decision}", prev_state)
      when 'reset'
        halt(422, 'only reviewed accruals can be reset') unless %w[approved rejected].include?(accrual.status)
        accrual.update(status: 'flagged')
        write_accrual_audit(close_run, accrual, 'accrual_reflagged', prev_state)
      else
        halt 400, "unknown decision '#{decision}'"
      end

      Accruals::Engine.new(close_run).regenerate_journal_entries

      redirect(params[:return].to_s.empty? ? "/closes/#{close_run.id}/accruals/#{accrual.id}" : params[:return])
    end

    get '/closes/:id/journal_entries.csv' do
      close_run = CloseRun[params[:id].to_i] or halt(404)
      content_type 'text/csv'
      attachment "journal_entries_#{close_run.period_end}.csv"
      Accruals::JournalCsvExporter.call(close_run)
    end
  end
end
