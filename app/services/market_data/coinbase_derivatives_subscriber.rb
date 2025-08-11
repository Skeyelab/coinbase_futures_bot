# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseDerivativesSubscriber
    def initialize(product_ids:, channel: ENV.fetch("FUTURES_CHANNEL", "ticker"), logger: Rails.logger)
      @product_ids = Array(product_ids)
      @channel = channel
      @logger = logger
      @ws = nil
    end

    def start
      url = ENV["COINBASE_FUTURES_WS_URL"]
      raise ArgumentError, "COINBASE_FUTURES_WS_URL is not set" if url.to_s.strip.empty?

      socket = WebSocket::Client::Simple.connect(url)
      @ws = socket

      subscriber = self
      log = @logger

      socket.on(:open) { subscriber.__send__(:subscribe) }
      socket.on(:message) { |msg| subscriber.__send__(:handle_message, msg) }
      socket.on(:error) { |e| log.error("[FUT] error: #{e}") }
      socket.on(:close) do
        log.info("[FUT] closed")
        subscriber.__send__(:mark_ws_as_closed)
      end

      sleep 0.1 while @ws
    end

    private

    def mark_ws_as_closed
      @ws = nil
    end

    def subscribe
      msg = {
        type: "subscribe",
        channel: @channel,
        product_ids: @product_ids
      }
      @ws.send(msg.to_json)
      @logger.info("[FUT] subscribed: #{msg}")
    end

    def handle_message(message)
      data = begin
        JSON.parse(message.data)
      rescue JSON::ParserError
        nil
      end
      return unless data

      # Try Advanced Trade-like schema first
      if data["channel"] == @channel && data["events"].is_a?(Array)
        data["events"].each do |event|
          Array(event["tickers"]).each do |t|
            @logger.debug("[FUT] ticker: #{t.slice("product_id", "price", "time")}")
          end
        end
        return
      end

      # Fallback: log compact payload for inspection
      @logger.debug("[FUT] msg: #{data.slice("channel", "type", "product_id", "price", "time")}")
    end
  end
end
