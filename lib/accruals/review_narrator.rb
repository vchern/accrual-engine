require 'net/http'
require 'uri'
require 'json'

module Accruals
  # Calls Google Gemini to turn a flagged accrual's structured anomaly
  # signal into a 2-3 sentence note for the Controller's review queue.
  #
  # Grounded by design: the prompt forbids inventing amounts and only
  # supplies fields the engine already computed. The LLM's job is plain-
  # English paraphrasing, not arithmetic. If GEMINI_API_KEY is unset, the
  # call returns nil silently and the UI hides the section.
  class ReviewNarrator
    DEFAULT_MODEL    = 'gemini-2.5-flash-lite'.freeze
    ENDPOINT         = 'https://generativelanguage.googleapis.com/v1beta/models'.freeze
    # Gemini 2.5 routes a chunk of `maxOutputTokens` to internal "thinking"
    # tokens by default — we don't need that for 2-3 sentence paraphrasing,
    # so disable it and keep the visible-output budget tight.
    GENERATION_CONFIG = {
      'temperature'     => 0.2,
      'maxOutputTokens' => 400,
      'thinkingConfig'  => { 'thinkingBudget' => 0 }
    }.freeze

    Result = Struct.new(:text, :model, :error, keyword_init: true)

    def self.narrate(accrual)
      new.narrate(accrual)
    end

    def initialize(api_key: ENV['GEMINI_API_KEY'], model: DEFAULT_MODEL, transport: nil)
      @api_key   = api_key
      @model     = model
      @transport = transport || HttpTransport.new(api_key: @api_key, model: @model)
    end

    def narrate(accrual)
      return nil if @api_key.nil? || @api_key.to_s.strip.empty?
      return nil unless accrual.flagged?

      text = @transport.call(prompt_for(accrual))
      Result.new(text: text, model: @model)
    rescue StandardError => e
      Result.new(error: e.message, model: @model)
    end

    private

    def prompt_for(accrual)
      <<~PROMPT
        You are an internal-controls reviewer at Helix Compute Inc., a GPU cloud company.
        An automated anomaly detector flagged the following accrual line for human review.

        Subject: #{accrual_label(accrual)}
        Period close: #{accrual.close_run.period_end}
        Handler: #{accrual.handler_name}
        Accrual amount (USD): #{format('%.2f', accrual.amount_usd)}
        Detector signal: #{accrual.flagged_reason}

        Write a 2-3 sentence note for the Controller's review queue. State factually:
        (1) which day(s) deviated and by how much, (2) that this could still be valid
        usage and is not necessarily an error, (3) what the Controller should verify
        before approving.

        Constraints:
        - Use ONLY the figures supplied. Do NOT compute or invent amounts.
        - No greeting, no signature. Plain prose, no bullets.
      PROMPT
    end

    def accrual_label(accrual)
      first = accrual.accrual_sources.first
      return accrual.idempotency_key unless first

      case first.source_type
      when 'UsageEvent'
        ev = UsageEvent[first.source_id]
        cust = ev && Customer[ev.customer_id]
        cust ? "#{cust.customer_id} (#{cust.name})" : accrual.idempotency_key
      when 'GoodsReceipt'
        gr = GoodsReceipt[first.source_id]
        gr ? gr.receipt_id : accrual.idempotency_key
      else
        accrual.idempotency_key
      end
    end

    # Default transport: real HTTPS POST to Gemini. Tests inject a callable
    # that takes a prompt String and returns a narration String.
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
