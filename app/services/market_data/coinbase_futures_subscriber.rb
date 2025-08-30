# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseFuturesSubscriber
    include SentryServiceTracking

    def initialize(product_ids:, logger: Rails.logger, on_ticker: nil, enable_candle_aggregation: true)
      @product_ids = Array(product_ids)
      @logger = logger
      @on_ticker = on_ticker
      @ws = nil
      @candle_aggregator = enable_candle_aggregation ? RealTimeCandleAggregator.new(logger: logger) : nil
    end

    def start
      url = ENV.fetch("COINBASE_WS_URL", "wss://advanced-trade-ws.coinbase.com")

      SentryHelper.add_breadcrumb(
        message: "Starting Coinbase futures WebSocket connection",
        category: "websocket",
        level: "info",
        data: {
          service: "coinbase_futures_subscriber",
          url: url,
          product_ids: @product_ids
        }
      )

      begin
        socket = WebSocket::Client::Simple.connect(url)
        @ws = socket

        # Capture external references because the event_emitter uses instance_exec
        # which changes self inside the blocks to the socket instance.
        subscriber = self
        log = @logger

        socket.on(:open) { subscriber.__send__(:subscribe) }
        socket.on(:message) { |msg| subscriber.__send__(:handle_message, msg) }
        socket.on(:error) { |e| subscriber.__send__(:handle_error, e) }
        socket.on(:close) do
          log.info("[MD] closed")
          subscriber.__send__(:mark_ws_as_closed)
        end

        # Keep the job alive until the websocket closes
        sleep 0.1 while @ws
      rescue => e
        Sentry.with_scope do |scope|
          scope.set_tag("service", "coinbase_futures_subscriber")
          scope.set_tag("operation", "websocket_connection")
          scope.set_tag("error_type", "connection_error")

          scope.set_context("websocket", {
            url: url,
            product_ids: @product_ids,
            enable_candle_aggregation: @candle_aggregator.present?
          })

          Sentry.capture_exception(e)
        end

        raise
      end
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
          connection_active: @ws.present?,
          error_message: error.to_s
        })

        Sentry.capture_message("WebSocket connection error", level: "error")
      end
    end
  end
end
