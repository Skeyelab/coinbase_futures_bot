# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseFuturesSubscriber
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
      @ws.on(:error) { |e| @logger.error("[MD] error: #{e}") }
      @ws.on(:close) { @logger.info("[MD] closed") }

      sleep 0.1 while @ws&.open?
    end

    private

    def subscribe
      msg = {
        type: "subscribe",
        channel: "ticker",
        product_ids: @product_ids
      }
      @ws.send(msg.to_json)
      @logger.info("[MD] subscribed: #{msg}")
    end

    def handle_message(message)
      data = JSON.parse(message.data) rescue nil
      return unless data
      return unless data["type"] == "ticker"

      # TODO: normalize and enqueue for strategy engine
      @logger.debug("[MD] ticker: #{data.slice("product_id", "price", "time")}")
    end
  end
end
