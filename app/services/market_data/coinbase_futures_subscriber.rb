# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseFuturesSubscriber
    def initialize(product_ids:, logger: Rails.logger, on_ticker: nil)
      @product_ids = Array(product_ids)
      @logger = logger
      @on_ticker = on_ticker
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

      # Advanced Trade schema (channel/events)
      if data["channel"] == "ticker" && data["events"].is_a?(Array)
        data["events"].each do |event|
          Array(event["tickers"]).each do |t|
            @logger.debug("[MD] ticker: #{t.slice("product_id", "price", "time")}")
            @on_ticker&.call({
              "product_id" => t["product_id"],
              "price" => t["price"],
              "time" => t["time"]
            })
          end
        end
        return
      end

      # Legacy schema (flat type)
      if data["type"] == "ticker"
        @logger.debug("[MD] ticker: #{data.slice("product_id", "price", "time")}")
        @on_ticker&.call({
          "product_id" => data["product_id"],
          "price" => data["price"],
          "time" => data["time"]
        })
      end
    end
  end
end
