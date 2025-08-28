# frozen_string_literal: true

module MarketData
  class FuturesContractManager
    ASSET_MAPPING = {
      "BTC" => "BIT",
      "ETH" => "ET"
    }.freeze

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Update current month contracts for BTC and ETH
    def update_current_month_contracts
      current_date = Date.current

      %w[BTC ETH].each do |asset|
        update_contracts_for_asset(asset, current_date)
      end
    end

    # Update upcoming month contracts for BTC and ETH
    def update_upcoming_month_contracts
      %w[BTC ETH].each do |asset|
        upcoming_contract_id = generate_upcoming_month_contract_id(asset)
        next unless upcoming_contract_id

        discover_upcoming_month_contract(asset)
      end
    end

    # Update both current and upcoming month contracts
    def update_all_contracts
      update_current_month_contracts
      update_upcoming_month_contracts
    end

    # Get current month contract product ID for an asset
    def current_month_contract(asset)
      contract = TradingPair.current_month_for_asset(asset).first
      return contract&.product_id if contract

      # If no current month contract found, try to discover it
      discover_current_month_contract(asset)
    end

    # Get upcoming month contract product ID for an asset
    def upcoming_month_contract(asset)
      contract = TradingPair.upcoming_month_for_asset(asset).first
      return contract&.product_id if contract

      # If no upcoming month contract found, try to discover it
      discover_upcoming_month_contract(asset)
    end

    # Get the best available contract for trading (current month preferred, upcoming as fallback)
    def best_available_contract(asset)
      contract = TradingPair.best_available_for_asset(asset)
      return contract&.product_id if contract

      # If no contracts found, try to discover current month first
      current = discover_current_month_contract(asset)
      return current if current

      # Fall back to upcoming month
      discover_upcoming_month_contract(asset)
    end

    # Discover and create current month contract for an asset
    def discover_current_month_contract(asset)
      contract_id = generate_current_month_contract_id(asset)
      return nil unless contract_id

      # Parse contract info
      contract_info = TradingPair.parse_contract_info(contract_id)
      return nil unless contract_info

      # Create or update the trading pair
      trading_pair = TradingPair.find_or_initialize_by(product_id: contract_id)
      trading_pair.assign_attributes(
        base_currency: contract_info[:base_currency],
        quote_currency: contract_info[:quote_currency],
        expiration_date: contract_info[:expiration_date],
        contract_type: contract_info[:contract_type],
        enabled: true,
        status: "online"
      )

      if trading_pair.save
        @logger.info("Created current month contract: #{contract_id}")
        contract_id
      else
        @logger.error("Failed to create contract #{contract_id}: #{trading_pair.errors.full_messages}")
        nil
      end
    end

    # Discover and create upcoming month contract for an asset
    def discover_upcoming_month_contract(asset)
      contract_id = generate_upcoming_month_contract_id(asset)
      return nil unless contract_id

      # Parse contract info
      contract_info = TradingPair.parse_contract_info(contract_id)
      return nil unless contract_info

      # Create or update the trading pair
      trading_pair = TradingPair.find_or_initialize_by(product_id: contract_id)
      trading_pair.assign_attributes(
        base_currency: contract_info[:base_currency],
        quote_currency: contract_info[:quote_currency],
        expiration_date: contract_info[:expiration_date],
        contract_type: contract_info[:contract_type],
        enabled: true,
        status: "online"
      )

      if trading_pair.save
        @logger.info("Created upcoming month contract: #{contract_id}")
        contract_id
      else
        @logger.error("Failed to create upcoming month contract #{contract_id}: #{trading_pair.errors.full_messages}")
        nil
      end
    end

    # Generate current month contract ID for an asset
    # This assumes the pattern: PREFIX-DDMMMYY-CDE
    def generate_current_month_contract_id(asset)
      generate_contract_id_for_month(asset, Date.current)
    end

    # Generate upcoming month contract ID for an asset
    def generate_upcoming_month_contract_id(asset)
      generate_contract_id_for_month(asset, Date.current.next_month)
    end

    # Generate contract ID for a specific month
    def generate_contract_id_for_month(asset, month_date)
      prefix = ASSET_MAPPING[asset.upcase]
      return nil unless prefix

      # Find the last Friday of the specified month (typical futures expiration)
      last_day = month_date.end_of_month

      # Find the last Friday of the month
      expiration_date = last_day
      until expiration_date.friday?
        expiration_date -= 1.day
        # Safety check - don't go before the start of the month
        break if expiration_date < month_date.beginning_of_month
      end

      # Format as DDMMMYY (e.g., 29AUG25)
      date_str = expiration_date.strftime("%d%b%y").upcase

      "#{prefix}-#{date_str}-CDE"
    end

    # Get all active futures contracts
    def active_futures_contracts
      TradingPair.active
    end

    # Get contracts that are expiring soon (within next 7 days)
    def expiring_contracts(days_ahead: 7)
      cutoff_date = Date.current + days_ahead.days
      TradingPair.enabled
        .where("expiration_date <= ? AND expiration_date > ?", cutoff_date, Date.current)
    end

    # Check if we need to rollover to next month contracts
    def rollover_needed?(days_before_expiry: 3)
      expiring_contracts(days_ahead: days_before_expiry).any?
    end

    private

    def update_contracts_for_asset(asset, current_date)
      @logger.info("Updating current month contracts for #{asset}")

      # Try to discover and create current month contract
      contract_id = discover_current_month_contract(asset)

      if contract_id
        @logger.info("Current month contract for #{asset}: #{contract_id}")
      else
        @logger.warn("Could not discover current month contract for #{asset}")
      end

      # Disable expired contracts
      expired_contracts = TradingPair.enabled
        .where(base_currency: asset)
        .where("expiration_date < ?", current_date)

      expired_contracts.update_all(enabled: false)

      return unless expired_contracts.any?

      @logger.info("Disabled #{expired_contracts.count} expired #{asset} contracts")
    end
  end
end
