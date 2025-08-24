# frozen_string_literal: true

module Execution
  class FuturesExecutor
    def initialize(basis_threshold_bps: ENV.fetch("BASIS_THRESHOLD_BPS", 50).to_i, logger: Rails.logger)
      @basis_threshold_bps = basis_threshold_bps
      @logger = logger
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
    end

    # spot_price: Float
    # futures_product_id: String
    # at: ISO8601 String
    def consider_entry(spot_price:, futures_product_id:, at: Time.now.utc.iso8601)
      # Check if rollover is needed before considering entry
      check_and_perform_rollover
      
      # Resolve to current month contract if needed
      trading_contract = resolve_trading_contract(futures_product_id)
      return unless trading_contract

      # TODO: Query futures best bid/ask or mark via REST to compute basis
      # For now, just log the intent and apply a placeholder basis check
      futures_mark = spot_price # placeholder assumption until wired
      basis_bps = ((futures_mark - spot_price) / spot_price.to_f) * 10_000

      if basis_bps.abs > @basis_threshold_bps
        @logger.info("[EXEC] skip: basis #{basis_bps.round(2)}bps > #{@basis_threshold_bps}bps")
        return
      end

      @logger.info("[EXEC] would place order on #{trading_contract} at spot=#{spot_price} (basis=#{basis_bps.round(2)}bps) @ #{at}")
    end

    # Check if any contracts are expiring soon and handle rollover
    def check_and_perform_rollover
      if @contract_manager.rollover_needed?(days_before_expiry: 3)
        @logger.info("[EXEC] Contract rollover needed")
        perform_rollover
      end
    end

    # Perform contract rollover - close positions in expiring contracts and move to current month
    def perform_rollover
      expiring_contracts = @contract_manager.expiring_contracts(days_ahead: 3)
      
      expiring_contracts.each do |contract|
        @logger.info("[EXEC] Processing rollover for expiring contract: #{contract.product_id}")
        
        # Get asset for this contract
        asset = contract.underlying_asset
        next unless asset

        # Find current month contract for this asset
        current_month_contract = @contract_manager.current_month_contract(asset)
        next unless current_month_contract

        # Perform the rollover
        rollover_contract(
          from_contract: contract.product_id,
          to_contract: current_month_contract,
          asset: asset
        )
      end
    end

    # Rollover from one contract to another
    def rollover_contract(from_contract:, to_contract:, asset:)
      return if from_contract == to_contract

      @logger.info("[EXEC] Rolling over #{asset} from #{from_contract} to #{to_contract}")
      
      # TODO: Implement actual position rollover logic
      # This would involve:
      # 1. Getting current position in from_contract
      # 2. Closing position in from_contract
      # 3. Opening equivalent position in to_contract
      # 4. Handling any basis differences and slippage
      
      @logger.info("[EXEC] Rollover completed: #{from_contract} -> #{to_contract}")
    end

    # Resolve a product ID to the appropriate trading contract
    # If it's an asset (BTC, ETH), return current month contract
    # If it's already a specific contract, validate it's still active
    def resolve_trading_contract(product_id)
      return nil unless product_id

      # If it's already a specific current month contract, check if it's still valid
      if product_id.match?(/\d{2}[A-Z]{3}\d{2}/)
        contract = TradingPair.find_by(product_id: product_id)
        if contract && !contract.expired?
          return product_id
        else
          @logger.warn("[EXEC] Contract #{product_id} is expired or not found")
          return nil
        end
      end

      # If it's a perpetual, use it directly
      if product_id.end_with?('-PERP')
        return product_id
      end

      # If it's an asset symbol, find current month contract
      asset = extract_asset_from_product_id(product_id)
      if asset
        current_contract = @contract_manager.current_month_contract(asset)
        if current_contract
          @logger.info("[EXEC] Resolved #{product_id} to current month contract: #{current_contract}")
          return current_contract
        else
          @logger.warn("[EXEC] No current month contract found for asset #{asset}")
          return nil
        end
      end

      # Default: return as-is
      product_id
    end

    # Extract asset from product ID
    def extract_asset_from_product_id(product_id)
      case product_id
      when /^(BTC|ETH)(-USD)?(-PERP)?$/
        $1
      when /^(BIT|ET)-\d{2}[A-Z]{3}\d{2}-[A-Z]+$/
        product_id.start_with?('BIT') ? 'BTC' : 'ETH'
      else
        nil
      end
    end
  end
end
