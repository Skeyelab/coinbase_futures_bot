# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseSpotSubscriber
    def initialize(product_ids:, logger: Rails.logger, on_ticker: nil)
      @product_ids = Array(product_ids)
      @logger = logger
      @on_ticker = on_ticker
      @ws = nil
    end

    def start
      url = ENV.fetch("COINBASE_WS_URL", "wss://advanced-trade-ws.coinbase.com")
      @logger.info("[MD-Spot] Connecting to #{url}...")

      begin
        socket = WebSocket::Client::Simple.connect(url)
        @ws = socket

        # Preserve self inside event handlers
        subscriber = self
        log = @logger

        socket.on(:open) do
          log.info("[MD-Spot] WebSocket connected successfully")
          subscriber.__send__(:subscribe)
        end

        socket.on(:message) { |msg| subscriber.__send__(:handle_message, msg) }

        socket.on(:error) do |e|
          log.error("[MD-Spot] WebSocket error: #{e}")
          subscriber.__send__(:mark_ws_as_closed)
        end

        socket.on(:close) do
          log.info("[MD-Spot] WebSocket closed")
          subscriber.__send__(:mark_ws_as_closed)
        end

        # Wait for connection with timeout
        timeout = 10 # 10 seconds timeout
        start_time = Time.current

        while @ws && (Time.current - start_time) < timeout
          sleep 0.1
        end

        if @ws && (Time.current - start_time) >= timeout
          @logger.error("[MD-Spot] Connection timeout after #{timeout} seconds")
          @ws.close if @ws.respond_to?(:close) && @ws.open?
          @ws = nil
        end
      rescue => e
        @logger.error("[MD-Spot] Failed to establish WebSocket connection: #{e.message}")
        @ws = nil
      end
    end

    private

    def mark_ws_as_closed
      @ws&.close if @ws&.open?
      @ws = nil
    end

    def ws_connected?
      @ws && @ws.ready_state == WebSocket::Client::Simple::STATE_OPEN
    end

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
            tick_time = t["time"] || t["ts"] || t["timestamp"]
            normalized = {
              "product_id" => t["product_id"],
              "price" => t["price"],
              "time" => tick_time
            }
            @logger.debug("[MD-Spot] ticker: #{normalized.slice("product_id", "price", "time")}")
            @on_ticker&.call(normalized)
          end
        end
        return
      end

      # Legacy schema (flat type)
      if data["type"] == "ticker"
        normalized = {
          "product_id" => data["product_id"],
          "price" => data["price"],
          "time" => data["time"] || data["ts"] || data["timestamp"]
        }
        @logger.debug("[MD-Spot] ticker: #{normalized.slice("product_id", "price", "time")}")
        @on_ticker&.call(normalized)
      end
    end
  end
end
