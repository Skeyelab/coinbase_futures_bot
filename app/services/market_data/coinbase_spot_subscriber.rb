# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseSpotSubscriber
    def initialize(product_ids:, logger: Rails.logger)
      @product_ids = Array(product_ids)
      @logger = logger
      @ws = nil
    end

    def start
      url = ENV.fetch("COINBASE_WS_URL", "wss://advanced-trade-ws.coinbase.com")
      @ws = WebSocket::Client::Simple.connect(url)

      @ws.on(:open) { subscribe }
      @ws.on(:message) { |msg| handle_message(msg) }
      @ws.on(:error) { |e| @logger.error("[MD-Spot] error: #{e}") }
      @ws.on(:close) { @logger.info("[MD-Spot] closed"); @ws = nil }

      sleep 0.1 while @ws
    end

    private

    def subscribe
      msg = {
        type: "subscribe",
        channel: "ticker",
        product_ids: @product_ids
      }
      @ws.send(msg.to_json)
      @logger.info("[MD-Spot] subscribed: #{msg}")
    end

    def handle_message(message)
      data = JSON.parse(message.data) rescue nil
      return unless data && data["type"] == "ticker"

      @logger.debug("[MD-Spot] ticker: #{data.slice("product_id", "price", "time")}")
      # TODO: enqueue for 1h candle aggregation service
    end
  end
end