# frozen_string_literal: true

require "websocket-client-simple"

module MarketData
  class CoinbaseDerivativesSubscriber
    def initialize(product_ids: nil, channel: ENV.fetch("FUTURES_CHANNEL", "ticker"), logger: Rails.logger, auto_discover: true)
      @original_product_ids = Array(product_ids) if product_ids
      @channel = channel
      @logger = logger
      @ws = nil
      @auto_discover = auto_discover
      @contract_manager = FuturesContractManager.new(logger: logger)

      # Set up product IDs based on initialization
      @product_ids = determine_product_ids
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

    # Determine which product IDs to subscribe to
    def determine_product_ids
      if @original_product_ids && !@original_product_ids.empty?
        # Use explicitly provided product IDs
        @original_product_ids
      elsif @auto_discover
        # Auto-discover current month contracts
        discover_current_month_contracts
      else
        # Default to empty if no products specified and auto-discover disabled
        []
      end
    end

    # Discover current month futures contracts for BTC and ETH
    def discover_current_month_contracts
      contracts = []

      # Update contracts first to ensure we have the latest
      @contract_manager.update_current_month_contracts

      # Get current month contracts for BTC and ETH
      %w[BTC ETH].each do |asset|
        contract_id = @contract_manager.current_month_contract(asset)
        if contract_id
          contracts << contract_id
          @logger.info("[FUT] Found current month contract for #{asset}: #{contract_id}")
        else
          @logger.warn("[FUT] No current month contract found for #{asset}")
        end
      end

      contracts
    end

    # Update product IDs (useful for contract rollover)
    def update_product_ids
      new_product_ids = determine_product_ids
      if new_product_ids != @product_ids
        @logger.info("[FUT] Updating subscribed contracts from #{@product_ids} to #{new_product_ids}")
        @product_ids = new_product_ids

        # Resubscribe if websocket is active
        if @ws
          subscribe
        end
      end
    end
  end
end
