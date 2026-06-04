# frozen_string_literal: true

module Execution
  class FuturesExecutor
    include SentryServiceTracking

    def initialize(basis_threshold_bps: ENV.fetch("BASIS_THRESHOLD_BPS", 50).to_i, logger: Rails.logger)
      @basis_threshold_bps = basis_threshold_bps
      @logger = logger
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
      @trade_client = Coinbase::AdvancedTradeClient.new(logger: logger)
    end

    # spot_price: Float
    # futures_product_id: String
    # at: ISO8601 String
    def consider_entry(spot_price:, futures_product_id:, at: Time.now.utc.iso8601)
      TradingHalt.assert_active!(context: "FuturesExecutor#consider_entry")

      # Check if rollover is needed before considering entry
      check_and_perform_rollover

      # Resolve to current month contract if needed
      trading_contract = resolve_trading_contract(futures_product_id)
      return unless trading_contract

      # Fetch live futures mark price (mid of best bid/ask) via REST
      futures_mark = fetch_futures_mark_price(trading_contract, fallback: spot_price)
      basis_bps = ((futures_mark - spot_price) / spot_price.to_f) * 10_000

      if basis_bps.abs > @basis_threshold_bps
        @logger.info("[EXEC] skip: basis #{basis_bps.round(2)}bps > #{@basis_threshold_bps}bps")
        return
      end

      @logger.info("[EXEC] would place order on #{trading_contract} at spot=#{spot_price} futures_mark=#{futures_mark.round(2)} (basis=#{basis_bps.round(2)}bps) @ #{at}")
    end

    # Check if any contracts are expiring soon and handle rollover
    def check_and_perform_rollover
      return unless @contract_manager.rollover_needed?(days_before_expiry: 3)

      @logger.info("[EXEC] Contract rollover needed")
      perform_rollover
    end

    # Perform contract rollover - close positions in expiring contracts and move to current month
    def perform_rollover
      expiring_contracts = @contract_manager.expiring_contracts(days_ahead: 3)

      expiring_contracts.each do |contract|
        @logger.info("[EXEC] Processing rollover for expiring contract: #{contract.product_id}")

        asset = contract.underlying_asset
        next unless asset

        target_contract = @contract_manager.best_available_contract(asset)
        next unless target_contract

        next if contract.product_id == target_contract

        rollover_contract(
          from_contract: contract.product_id,
          to_contract: target_contract,
          asset: asset
        )
      end
    end

    # Rollover from one contract to another:
    #   1. Find open local positions in from_contract
    #   2. Close each via CoinbasePositions (market order on exchange + local record update)
    #   3. Re-open equivalent size on to_contract preserving side, day_trading flag, risk levels
    def rollover_contract(from_contract:, to_contract:, asset:)
      return if from_contract == to_contract

      @logger.info("[EXEC] Rolling over #{asset} from #{from_contract} to #{to_contract}")

      positions = Position.open.where(product_id: from_contract).to_a

      if positions.empty?
        @logger.info("[EXEC] No open positions found for #{from_contract}, skipping rollover")
        return
      end

      positions_service = Trading::CoinbasePositions.new(logger: @logger)

      positions.each do |pos|
        size = pos.size.to_f
        next if size <= 0

        side = pos.long? ? :buy : :sell
        @logger.info("[EXEC] Closing #{pos.side} #{size} #{from_contract} for rollover")

        begin
          positions_service.close_position(product_id: from_contract, size: size)
        rescue => e
          @logger.error("[EXEC] Failed to close #{from_contract} position #{pos.id}: #{e.class}: #{e.message}")
          next
        end

        @logger.info("[EXEC] Re-opening #{pos.side} #{size} #{to_contract}")
        begin
          positions_service.open_position(
            product_id: to_contract,
            side: side,
            size: size,
            day_trading: pos.day_trading,
            take_profit: pos.take_profit,
            stop_loss: pos.stop_loss
          )
        rescue => e
          @logger.error("[EXEC] Failed to open #{to_contract} position after rollover: #{e.class}: #{e.message}")
        end
      end

      @logger.info("[EXEC] Rollover completed: #{from_contract} -> #{to_contract}")
    end

    # Resolve a product ID to the appropriate trading contract
    def resolve_trading_contract(product_id)
      return nil unless product_id&.present?

      if product_id.match?(/\d{2}[A-Z]{3}\d{2}/)
        contract = Contract.find_by(product_id: product_id)
        return product_id if contract && !contract.expired?

        @logger.warn("[EXEC] Contract #{product_id} is expired or not found")
        return nil
      end

      asset = extract_asset_from_product_id(product_id)
      if asset
        best_contract = @contract_manager.best_available_contract(asset)
        if best_contract
          contract = Contract.find_by(product_id: best_contract)
          if contract&.current_month?
            @logger.info("[EXEC] Resolved #{product_id} to current month contract: #{best_contract}")
          elsif contract&.upcoming_month?
            @logger.info("[EXEC] Resolved #{product_id} to upcoming month contract: #{best_contract} (current month not suitable)")
          else
            @logger.info("[EXEC] Resolved #{product_id} to contract: #{best_contract}")
          end
          return best_contract
        else
          @logger.warn("[EXEC] No suitable contract found for asset #{asset}")
          return nil
        end
      end

      product_id
    end

    # Extract asset from product ID
    def extract_asset_from_product_id(product_id)
      case product_id
      when /^(BTC|ETH)(-USD)?$/
        ::Regexp.last_match(1)
      when /^(BIT|ET)-\d{2}[A-Z]{3}\d{2}-[A-Z]+$/
        product_id.start_with?("BIT") ? "BTC" : "ETH"
      end
    end

    private

    # Fetch the mid-market (mark) price for a futures contract via the Advanced Trade API.
    # Falls back to the provided +fallback+ price when the API call fails or credentials
    # are unavailable, so the basis gate degrades gracefully rather than blocking all entries.
    def fetch_futures_mark_price(product_id, fallback:)
      ticker = @trade_client.get_product_ticker(product_id)
      best_bid = ticker.dig("best_bid")&.to_f
      best_ask = ticker.dig("best_ask")&.to_f

      if best_bid && best_ask && best_bid > 0 && best_ask > 0
        (best_bid + best_ask) / 2.0
      elsif (price = ticker.dig("price")&.to_f) && price > 0
        price
      else
        @logger.warn("[EXEC] Could not parse mark price from ticker for #{product_id}, using spot as fallback")
        fallback
      end
    rescue => e
      @logger.warn("[EXEC] fetch_futures_mark_price failed for #{product_id}: #{e.class}: #{e.message}; using spot as fallback")
      fallback
    end
  end
end
