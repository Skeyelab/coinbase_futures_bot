# frozen_string_literal: true

module MarketData
  class FuturesContractManager
    # Assets whose DATED monthly product id we synthesize when the row is
    # missing. Narrower than "every dated prefix" on purpose: synthesis assumes
    # a last-Friday expiry, which BIT and ET follow and NOL does not, so
    # deriving oil into this map would fabricate "NOL-31JUL26-CDE" — an id for
    # a contract that does not exist on the venue.
    SYNTHESIZED_DATED_ASSETS = %w[BTC ETH].freeze

    # asset => dated prefix. This is NOT "which contract does BTC trade" — that
    # question is answered by #best_available_contract, and since ADR 0002 the
    # answer for BTC is the BIP perp. This map only names the dated family whose
    # monthly ids we can construct.
    #
    # Derived from Contract::PRODUCT_PREFIXES rather than restated, because the
    # restatement is what went wrong: this map said BTC => BIT while the prefix
    # map said BIP => BTC, and the two contradicted each other about the same
    # pair for five days after ADR 0002 (issue #390).
    ASSET_MAPPING = Contract::DATED_PREFIX_BY_ASSET.slice(*SYNTHESIZED_DATED_ASSETS).freeze

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
      contract = Contract.current_month_for_asset(asset).first
      return contract&.product_id if contract

      # If no current month contract found, try to discover it
      discover_current_month_contract(asset)
    end

    # Get upcoming month contract product ID for an asset
    def upcoming_month_contract(asset)
      contract = Contract.upcoming_month_for_asset(asset).first
      return contract&.product_id if contract

      # If no upcoming month contract found, try to discover it
      discover_upcoming_month_contract(asset)
    end

    # THE trading resolver: which contract does this asset trade right now?
    #
    # Venue-aware since issue #390 — the perp where one exists (ADR 0002/0004),
    # the dated current month otherwise, upcoming month as the dated fallback.
    # Every order-path caller goes through here so the sites cannot disagree.
    def best_available_contract(asset)
      contract = Contract.best_available_for_asset(asset, logger: @logger)
      return contract&.product_id if contract

      # Discovery synthesizes a DATED monthly product id, so it must not run for
      # an asset whose venue is a perp: that is how a missing BIP row would turn
      # into a freshly-created BIT contract and an order on it.
      return nil if Contract.perp_prefix_for_asset(asset)

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
      contract_info = Contract.parse_contract_info(contract_id)
      return nil unless contract_info

      # Create or update the trading pair. `enabled` is written on CREATE only:
      # discovery may bring a new month into the data pipeline, but it must not
      # overturn a decision already recorded on an existing row. It used to
      # assign it unconditionally, and because the lookup that calls discovery
      # is scoped to Contract.enabled, disabling a contract made the lookup miss
      # and discovery re-enabled the row the operator had just turned off.
      contract = Contract.find_or_initialize_by(product_id: contract_id)
      contract.assign_attributes(
        base_currency: contract_info[:base_currency],
        quote_currency: contract_info[:quote_currency],
        expiration_date: contract_info[:expiration_date],
        contract_type: contract_info[:contract_type],
        status: "online"
      )
      contract.enabled = true if contract.new_record?

      if contract.save
        @logger.info("Created current month contract: #{contract_id}")
        contract_id
      else
        @logger.error("Failed to create contract #{contract_id}: #{contract.errors.full_messages}")
        nil
      end
    end

    # Discover and create upcoming month contract for an asset
    def discover_upcoming_month_contract(asset)
      contract_id = generate_upcoming_month_contract_id(asset)
      return nil unless contract_id

      # Parse contract info
      contract_info = Contract.parse_contract_info(contract_id)
      return nil unless contract_info

      # Create or update the trading pair. `enabled` is written on CREATE only:
      # discovery may bring a new month into the data pipeline, but it must not
      # overturn a decision already recorded on an existing row. It used to
      # assign it unconditionally, and because the lookup that calls discovery
      # is scoped to Contract.enabled, disabling a contract made the lookup miss
      # and discovery re-enabled the row the operator had just turned off.
      contract = Contract.find_or_initialize_by(product_id: contract_id)
      contract.assign_attributes(
        base_currency: contract_info[:base_currency],
        quote_currency: contract_info[:quote_currency],
        expiration_date: contract_info[:expiration_date],
        contract_type: contract_info[:contract_type],
        status: "online"
      )
      contract.enabled = true if contract.new_record?

      if contract.save
        @logger.info("Created upcoming month contract: #{contract_id}")
        contract_id
      else
        @logger.error("Failed to create upcoming month contract #{contract_id}: #{contract.errors.full_messages}")
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
      return nil unless asset

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
      Contract.active
    end

    # Get contracts that are expiring soon (within next 7 days)
    def expiring_contracts(days_ahead: 7)
      cutoff_date = Date.current + days_ahead.days
      Contract.enabled
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
      expired_contracts = Contract.enabled
        .where(base_currency: asset)
        .where("expiration_date < ?", current_date)

      expired_contracts.update_all(enabled: false)

      return unless expired_contracts.any?

      @logger.info("Disabled #{expired_contracts.count} expired #{asset} contracts")
    end
  end
end
