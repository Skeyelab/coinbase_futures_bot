# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseSpotSubscriber
    include SentryServiceTracking

    def initialize(product_ids:, logger: Rails.logger, on_ticker: nil, enable_candle_aggregation: true,
      url: ENV.fetch("COINBASE_WS_URL", "wss://advanced-trade-ws.coinbase.com"),
      stale_after: ENV.fetch("MARKET_DATA_WS_STALE_SECONDS", "60").to_f,
      connect: WebsocketSupervisor::DEFAULT_CONNECT, sleeper: WebsocketSupervisor::DEFAULT_SLEEPER)
      @product_ids = Array(product_ids)
      @logger = logger
      @on_ticker = on_ticker
      @candle_aggregator = enable_candle_aggregation ? RealTimeCandleAggregator.new(logger: logger) : nil
      @url = url
      @stale_after = stale_after
      @connect = connect
      @sleeper = sleeper
    end

    # Connection lifecycle (reconnect + silence detection) is owned by
    # WebsocketSupervisor; this subscriber supplies the subscribe message and
    # tick parsing only.
    def start
      @logger.info("[MD-Spot] Connecting to #{@url}...")

      subscriber = self
      log = @logger
      @supervisor = WebsocketSupervisor.new(
        url: @url,
        on_open: lambda { |socket|
          log.info("[MD-Spot] WebSocket connected successfully")
          subscriber.__send__(:subscribe, socket)
        },
        on_message: ->(msg) { subscriber.__send__(:handle_message, msg) },
        on_error: ->(e) { log.error("[MD-Spot] WebSocket error: #{e}") },
        stale_after: @stale_after,
        logger: @logger,
        connect: @connect,
        sleeper: @sleeper
      )
      @supervisor.run
    end

    def stop
      @supervisor&.stop
    end

    private

    def subscribe(socket)
      msg = {
        type: "subscribe",
        channel: "ticker",
        product_ids: @product_ids
      }
      socket.send(msg.to_json)
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
            tick_time = t["time"] || t["ts"] || t["timestamp"] || data["timestamp"] || Time.now.utc.iso8601
            normalized = {
              "product_id" => t["product_id"],
              "price" => t["price"],
              "time" => tick_time
            }
            @logger.debug("[MD-Spot] ticker: #{normalized.slice("product_id", "price", "time")}")

            # Update real-time candles
            @candle_aggregator&.process_tick(normalized)

            @on_ticker&.call(normalized)
          end
        end
        return
      end

      # Legacy schema (flat type)
      return unless data["type"] == "ticker"

      normalized = {
        "product_id" => data["product_id"],
        "price" => data["price"],
        "time" => data["time"] || data["ts"] || data["timestamp"] || Time.now.utc.iso8601
      }
      @logger.debug("[MD-Spot] ticker: #{normalized.slice("product_id", "price", "time")}")

      # Update real-time candles
      @candle_aggregator&.process_tick(normalized)

      @on_ticker&.call(normalized)
    end
  end
end
