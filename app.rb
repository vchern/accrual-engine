require 'sinatra/base'
require 'sinatra/contrib'
require 'bigdecimal'
require 'date'
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
          when 'completed', 'posted'    then 'bg-emerald-50 text-emerald-700 ring-emerald-200'
          when 'flagged', 'running'     then 'bg-amber-50 text-amber-700 ring-amber-200'
          when 'failed', 'blocked'      then 'bg-red-50 text-red-700 ring-red-200'
          when 'pending'                then 'bg-slate-100 text-slate-700 ring-slate-200'
          else                                'bg-slate-100 text-slate-700 ring-slate-200'
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
      @ar_count      = @accruals.count { |a| a.entity_kind == 'ar' }
      @ap_count      = @accruals.count { |a| a.entity_kind == 'ap' }
      @flagged_count = @accruals.count { |a| a.status == 'flagged' }
      @total_usd     = @accruals.map(&:amount_usd).reduce(BigDecimal('0'), :+)

      @journal_entries = JournalEntry.where(close_run_id: @close_run.id).order(:entry_date, :id).all
      @audit_events    = AuditEvent.where(close_run_id: @close_run.id).order(Sequel.desc(:created_at), Sequel.desc(:id)).all

      erb :'closes/show'
    end

    get '/closes/:id/accruals/:aid' do
      @close_run = CloseRun[params[:id].to_i] or halt(404, 'Close run not found')
      @accrual   = Accrual[params[:aid].to_i] or halt(404, 'Accrual not found')
      halt(404, 'Accrual does not belong to this close') unless @accrual.close_run_id == @close_run.id

      @sources = @accrual.accrual_sources.map { |s| [s, s.source] }
      @journal_entries = JournalEntry.where(accrual_id: @accrual.id).order(:entry_date, :id).all

      erb :'accruals/show'
    end

    get '/closes/:id/journal_entries.csv' do
      close_run = CloseRun[params[:id].to_i] or halt(404)
      content_type 'text/csv'
      attachment "journal_entries_#{close_run.period_end}.csv"
      Accruals::JournalCsvExporter.call(close_run)
    end
  end
end
