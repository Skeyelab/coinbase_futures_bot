# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseFuturesSubscriber
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

    # Delegates the connection lifecycle to WebsocketSupervisor, which reconnects
    # on drop and on silence (a dead socket the :close event never reported —
    # the failure that silently froze the market-data feed). This subscriber
    # only supplies the subscribe message and tick parsing.
    def start
      SentryHelper.add_breadcrumb(
        message: "Starting Coinbase futures WebSocket connection",
        category: "websocket",
        level: "info",
        data: {service: "coinbase_futures_subscriber", url: @url, product_ids: @product_ids}
      )

      subscriber = self
      @supervisor = WebsocketSupervisor.new(
        url: @url,
        on_open: ->(socket) { subscriber.__send__(:subscribe, socket) },
        on_message: ->(msg) { subscriber.__send__(:handle_message, msg) },
        on_error: ->(e) { subscriber.__send__(:handle_error, e) },
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
      @logger.info("[MD] subscribed: #{msg}")
    end

    def handle_message(message)
      data = begin
        JSON.parse(message.data)
      rescue JSON::ParserError => e
        # Track JSON parsing errors
        Sentry.with_scope do |scope|
          scope.set_tag("service", "coinbase_futures_subscriber")
          scope.set_tag("operation", "parse_message")
          scope.set_tag("error_type", "json_parse_error")

          scope.set_context("websocket_message", {
            raw_message: message.data.to_s[0..500], # Truncate for safety
            message_size: message.data.to_s.bytesize
          })

          Sentry.capture_exception(e)
        end

        @logger.error("[MD] JSON parse error: #{e.message}")
        return
      end
      return unless data

      begin
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
              @logger.debug("[MD] ticker: #{normalized.slice("product_id", "price", "time")}")

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
          "time" => data["time"] || data["ts"] || data["timestamp"]
        }
        @logger.debug("[MD] ticker: #{normalized.slice("product_id", "price", "time")}")

        # Update real-time candles
        @candle_aggregator&.process_tick(normalized)

        @on_ticker&.call(normalized)
      rescue => e
        # Track message processing errors
        Sentry.with_scope do |scope|
          scope.set_tag("service", "coinbase_futures_subscriber")
          scope.set_tag("operation", "process_message")
          scope.set_tag("error_type", "message_processing_error")

          scope.set_context("websocket_message", {
            message_type: data["type"] || data["channel"],
            product_ids: @product_ids,
            data_keys: data.keys.join(",")
          })

          Sentry.capture_exception(e)
        end

        @logger.error("[MD] Message processing error: #{e.message}")
      end
    end

    def handle_error(error)
      @logger.error("[MD] WebSocket error: #{error}")

      # Track WebSocket errors in Sentry
      Sentry.with_scope do |scope|
        scope.set_tag("service", "coinbase_futures_subscriber")
        scope.set_tag("operation", "websocket_error")
        scope.set_tag("error_type", "websocket_error")

        scope.set_context("websocket", {
          product_ids: @product_ids,
          error_message: error.to_s
        })

        Sentry.capture_message("WebSocket connection error", level: "error")
      end
    end
  end
end
