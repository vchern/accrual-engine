require 'net/http'
require 'uri'
require 'json'
require 'bigdecimal'

module Accruals
  # Calls Gemini to write a 3-5 sentence Controller-grade summary of a
  # whole close run. Different granularity from ReviewNarrator (which is
  # per-flagged-accrual): this one paraphrases the close as a whole —
  # totals, status breakdown, flagged items, reversal date.
  #
  # Grounded by design: the prompt forbids inventing or recomputing
  # amounts. Every number in the output is one the engine already
  # produced and we hand to the LLM.
  class CloseSummarizer
    DEFAULT_MODEL    = 'gemini-2.5-flash-lite'.freeze
    ENDPOINT         = 'https://generativelanguage.googleapis.com/v1beta/models'.freeze
    GENERATION_CONFIG = {
      'temperature'     => 0.2,
      'maxOutputTokens' => 600,
      'thinkingConfig'  => { 'thinkingBudget' => 0 }
    }.freeze

    Result = Struct.new(:text, :model, :error, keyword_init: true)

    def self.summarize(close_run)
      new.summarize(close_run)
    end

    def initialize(api_key: ENV['GEMINI_API_KEY'], model: DEFAULT_MODEL, transport: nil)
      @api_key   = api_key
      @model     = model
      @transport = transport || HttpTransport.new(api_key: @api_key, model: @model)
    end

    def summarize(close_run)
      return nil if @api_key.nil? || @api_key.to_s.strip.empty?

      text = @transport.call(prompt_for(close_run))
      Result.new(text: text, model: @model)
    rescue StandardError => e
      Result.new(error: e.message, model: @model)
    end

    private

    def prompt_for(close_run)
      accruals = Accrual.where(close_run_id: close_run.id).order(:idempotency_key).all
      ar       = accruals.select { |a| a.entity_kind == 'ar' }
      ap       = accruals.select { |a| a.entity_kind == 'ap' }
      flagged  = accruals.select(&:flagged?)
      approved = accruals.select(&:approved?)
      rejected = accruals.select(&:rejected?)
      in_je    = accruals.select(&:in_journal_entry?)

      total_in_je = in_je.map(&:amount_usd).reduce(BigDecimal('0'), :+)
      total_all   = accruals.map(&:amount_usd).reduce(BigDecimal('0'), :+)
      reversal_date = BusinessCalendar.next_business_day(close_run.period_end)

      flagged_lines = if flagged.any?
        "Flagged items awaiting Controller review:\n" +
          flagged.map { |a| "  - #{a.idempotency_key}: $#{format('%.2f', a.amount_usd)} — #{a.flagged_reason}" }.join("\n")
      else
        'No flagged items.'
      end

      <<~PROMPT
        You are an internal-controls reviewer at Helix Compute Inc., a GPU cloud company.
        Write a 3-5 sentence Controller-grade summary of this close run. Lead with the
        close period and currently-posted total; mention pending review and the reversal
        date.

        Close period_end: #{close_run.period_end}
        Close status: #{close_run.status}
        Reversal entries dated: #{reversal_date}

        Accrual breakdown:
          Total accruals produced: #{accruals.size}
          AR accruals: #{ar.size}
          AP accruals: #{ap.size}

        Review state:
          Posted to consolidated JE: #{in_je.size}
          Awaiting review (flagged): #{flagged.size}
          Approved after review: #{approved.size}
          Rejected after review: #{rejected.size}

        Totals (USD):
          Currently posted to JE: $#{format('%.2f', total_in_je)}
          Including pending review: $#{format('%.2f', total_all)}

        #{flagged_lines}

        Constraints:
        - Use ONLY the figures supplied. Do NOT compute or invent amounts.
        - 3-5 sentences. Plain prose, no bullets, no greeting, no signature.
        - If there are flagged items, name them; if there are none, say so plainly.
      PROMPT
    end

    class HttpTransport
      def initialize(api_key:, model:)
        @api_key = api_key
        @model   = model
      end

      def call(prompt_text)
        uri = URI("#{ENDPOINT}/#{@model}:generateContent?key=#{@api_key}")
        body = {
          'contents' => [{ 'parts' => [{ 'text' => prompt_text }] }],
          'generationConfig' => GENERATION_CONFIG
        }
        request = Net::HTTP::Post.new(uri)
        request['Content-Type'] = 'application/json'
        request.body = JSON.dump(body)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |conn| conn.request(request) }
        raise "Gemini #{response.code}: #{response.body[0, 200]}" unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body)
        text = data.dig('candidates', 0, 'content', 'parts', 0, 'text').to_s.strip
        raise 'Gemini returned empty text' if text.empty?

        text
      end
    end
  end
end
