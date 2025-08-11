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
      socket = WebSocket::Client::Simple.connect(url)
      @ws = socket

      # Capture external references because the event_emitter uses instance_exec
      # which changes self inside the blocks to the socket instance.
      subscriber = self
      log = @logger

      socket.on(:open) { subscriber.__send__(:subscribe) }
      socket.on(:message) { |msg| subscriber.__send__(:handle_message, msg) }
      socket.on(:error) { |e| log.error("[MD] error: #{e}") }
      socket.on(:close) do
        log.info("[MD] closed")
        subscriber.__send__(:mark_ws_as_closed)
      end

      # Keep the job alive until the websocket closes
      sleep 0.1 while @ws
    end

    private

    def mark_ws_as_closed
      @ws = nil
    end

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
      data = begin
        JSON.parse(message.data)
      rescue JSON::ParserError
        nil
      end
      return unless data
      return unless data["type"] == "ticker"

      # TODO: normalize and enqueue for strategy engine
      @logger.debug("[MD] ticker: #{data.slice("product_id", "price", "time")}")
    end
  end
end
