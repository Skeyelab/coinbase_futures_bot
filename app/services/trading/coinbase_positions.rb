# frozen_string_literal: true

require "faraday"
require "json"
require "openssl"
require "base64"
require "jwt"
require "securerandom"

module Trading
  class CoinbasePositions
    include SentryServiceTracking

    DEFAULT_BASE = "https://api.coinbase.com"

    # Raised when a mutation would have to GUESS which tracked row it applies to.
    # On the live order path a guess is a real-money error, so we refuse and
    # leave state alone rather than mutate whichever row sorted last.
    class AmbiguousPositionError < StandardError; end

    # How entries should be placed (issue #374/#377). Defaults to :market so
    # nothing changes until deliberately switched — the maker fill rate has never
    # been observed (zero perp fills), and #486 exists to measure it.
    #
    # Degrades to :market on any venue without a maker discount: only perps are
    # 0% maker. On a dated contract both sides are ~9 bps, so a maker entry buys
    # nothing and adds the risk of not filling at all.
    def self.entry_order_type(symbol: nil)
      preferred = ENV.fetch("ENTRY_ORDER_TYPE", "market").to_s.downcase.to_sym
      return :market unless preferred == :maker
      return :maker if symbol.nil?

      fees = CostModel.fee_for(symbol)
      (fees[:maker_rate].to_f < fees[:taker_rate].to_f) ? :maker : :market
    end

    # How long a resting maker entry may live before the EXCHANGE expires it.
    # Deliberately exchange-side (good-till-date) rather than a local timer: a
    # post-only GTC order would otherwise sit on the book indefinitely if the
    # process died between placing and cancelling it.
    # A maker entry must REST on the book, so it is posted passively — below the
    # market to buy, above it to sell. Posting at the signal price would mostly
    # be rejected for crossing, since a momentum entry fires precisely when price
    # is moving toward it. The offset is the price improvement bought in
    # exchange for accepting that the order may never fill.
    def self.maker_price(reference_price, side)
      offset = ENV.fetch("MAKER_PRICE_OFFSET_BPS", "5").to_f / 10_000.0
      buying = %w[buy long].include?(SideNormalizer.order(side).to_s.downcase) ||
        %i[buy long].include?(side.to_s.downcase.to_sym)
      buying ? reference_price.to_f * (1 - offset) : reference_price.to_f * (1 + offset)
    end

    def self.maker_ttl_seconds
      value = ENV.fetch("MAKER_ORDER_TTL_SECONDS", "60").to_i
      value.positive? ? value : 60
    end

    def initialize(base_url: ENV.fetch("COINBASE_AT_REST_URL", DEFAULT_BASE), logger: Rails.logger)
      @logger = logger
      @conn = Faraday.new(base_url) do |f|
        f.request :url_encoded
        f.response :raise_error
        f.adapter Faraday.default_adapter
      end

      # Try to load credentials from cdp_api_key.json file (same as AdvancedTradeClient)
      credentials = load_credentials_from_file

      if credentials
        @api_key = credentials[:api_key]
        @api_secret = credentials[:private_key]
        @authenticated = true
        @logger.info("CoinbasePositions service initialized with credentials from cdp_api_key.json")
      else
        @authenticated = false
        @logger.warn("CoinbasePositions service credentials not found in cdp_api_key.json")
      end

      # Initialize contract manager for current month contract resolution
      @contract_manager = MarketData::FuturesContractManager.new(logger: logger)
    end

    def authenticated?
      @authenticated
    end

    # Test method to validate auth with simpler endpoint first
    def test_auth_with_accounts
      raise "Authentication required" unless @authenticated

      path = "/api/v3/brokerage/accounts"
      begin
        resp = authenticated_get(path, {})
        data = JSON.parse(resp.body)
        {ok: true, count: data.is_a?(Array) ? data.size : 1, data: data}
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        {ok: false, error: e.class.to_s, message: e.message, body: body}
      end
    end

    # List open positions. Optionally filter by product_id (e.g., "BTC-USD").
    # Returns array of positions.
    def list_open_positions(product_id: nil)
      raise "Authentication required" unless @authenticated

      # Use the correct futures positions endpoint
      # Note: Coinbase API doesn't support filtering by product_id, so we fetch all and filter in Ruby
      path = "/api/v3/brokerage/cfm/positions"
      params = {} # Don't pass product_id to API

      begin
        resp = authenticated_get(path, params)
        data = JSON.parse(resp.body)
      rescue Faraday::ClientError => e
        body = (e.response && e.response[:body]).to_s
        message = begin
          parsed = JSON.parse(body)
          parsed["message"] || parsed["error"] || body
        rescue
          body.presence || e.message
        end
        raise Faraday::ClientError.new("#{e.message}#{": #{message}" if message}", response: e.response)
      end

      positions = if data.is_a?(Hash) && data["positions"]
        data["positions"]
      else
        data
      end

      positions = [positions] unless positions.is_a?(Array)

      # Filter by product_id in Ruby if specified
      positions = positions.select { |p| p["product_id"] == product_id } if product_id

      positions
    end

    # Real executed fills with true commissions (issue #391 fee truth). Read-only.
    # Coinbase returns the most-recent fills; `commission` is the actual fee paid
    # and `liquidity_indicator` is MAKER/TAKER. Returns the raw fills array.
    def list_fills(limit: 100, product_id: nil)
      raise "Authentication required" unless @authenticated

      params = {limit: limit}
      params[:product_id] = product_id if product_id
      resp = authenticated_get("/api/v3/brokerage/orders/historical/fills", params)
      data = JSON.parse(resp.body)
      fills = data.is_a?(Hash) ? (data["fills"] || []) : Array(data)
      fills.is_a?(Array) ? fills : [fills]
    end

    # Open a position by placing an order. By default uses market order.
    # side: :buy or :sell
    # size: String or Numeric quantity in base units
    # price: required for limit orders
    # type: :market or :limit
    # Returns order result hash
    def open_position(product_id:, side:, size:, type: :market, price: nil, day_trading: nil, take_profit: nil,
      stop_loss: nil)
      TradingHalt.assert_active!(context: "CoinbasePositions#open_position")
      # Use configuration default if not specified
      day_trading = Trading::HoldHorizon.day_trading?(product_id) if day_trading.nil?
      raise "Authentication required" unless @authenticated || DryRun.active?

      order_body = build_order_body(product_id: product_id, side: side, size: size, type: type, price: price)
      result = submit_order(order_body, product_id: product_id, side: side, size: size, price: price)

      # If order was successful, create local Position record
      if result["success"] || result["order_id"]
        position = create_local_position_record(
          product_id: product_id,
          side: side,
          size: size,
          entry_price: price || get_current_market_price(product_id),
          day_trading: day_trading,
          take_profit: take_profit,
          stop_loss: stop_loss,
          order_result: result,
          paper: DryRun.active?
        )
        # Surfaced so callers can link the order to what it created (issue #480
        # lineage). Merged rather than returned separately so every existing
        # caller keeps reading the same result hash.
        result = result.merge("position_id" => position.id) if result.is_a?(Hash) && position.is_a?(Position)
      end

      result
    end

    # Close a position by submitting an opposite-side market order for the specified size.
    # If size is nil, attempts to infer the open size from list_open_positions for the product.
    #
    # `size` smaller than the tracked position is a PARTIAL reduce, not a close.
    #
    # `position:` is the local row the caller already resolved. Passing it does
    # two things, and both matter on the live order path:
    #
    #   1. It stops us re-finding the row by product. Re-finding meant
    #      `Position.open.by_product(...).order(:entry_time).last`, which can
    #      pick a DIFFERENT row than the one the caller decided to close when
    #      several are open on the same product.
    #   2. It transfers ownership of realizing P&L to the caller. Whoever
    #      resolved the position closes it, and there is exactly one writer per
    #      close. Trading::PositionLifecycle passes it because it knows the exit
    #      reason and must run the protections layer on the realized row; we then
    #      only record the order and the fee. Callers that pass nothing (rollover,
    #      the legacy current-month helpers, operator paths with no tracked row)
    #      keep today's behavior: we find the row and realize it here.
    #
    # Returns order result hash
    # NOT gated on TradingHalt. Stopping new risk and preventing risk REDUCTION
    # are different actions, and only the first belongs to a kill switch.
    #
    # This used to call `TradingHalt.assert_active!`, so a halt did not stop the
    # bot holding risk — it removed the ability to shed it, pinning every open
    # position through its own stop-loss. Observed 2026-07-28: during a 14-minute
    # RISK halt, position 14's take-profit fired twice and all four close
    # attempts (2 + 2 retries) raised; the position was still open afterwards
    # with its TP unfilled (issue #537).
    #
    # Three things made that worse than a missed exit: a RISK halt needs a
    # console to clear (#481), RISK halts can be raised spuriously (#535 — a
    # calibration measuring DRY-RUN fills raised two), and ADR 0006 suspension
    # already documents the correct semantics for its sibling mechanism — new
    # entries only, "open positions still exit normally".
    #
    # Exits are safe to allow unconditionally here because this method is
    # reduce-only by construction: the size is capped at the open contracts
    # below, so it can never flip or grow a position. `open_position` and
    # `increase_position` keep their assertions — those are what a halt is for.
    def close_position(product_id:, size: nil, position: nil)
      raise "Authentication required" unless @authenticated || DryRun.active?

      # If explicit size provided, infer the actual open size + side from the
      # exchange. The Advanced Trade API has no reduce_only flag, so we enforce it
      # app-side: cap the close at the open contracts so an oversized/mismatched
      # request can never flip or grow the position instead of reducing it. If the
      # open size can't be determined (e.g., in tests), fall back to the request.
      if size
        actual_size, pos_side = begin
          infer_position(product_id: product_id, explicit_size: nil)
        rescue => e
          @logger.debug("close_position: could not infer open position: #{e.class}: #{e.message}")
          [nil, :buy]
        end

        pos_size = if actual_size && actual_size.to_f > 0 && size.to_f > actual_size.to_f
          @logger.warn("close_position: requested #{size} exceeds open #{actual_size} for #{product_id}; capping to open size (no reduce_only on Advanced Trade API)")
          actual_size.to_s
        else
          size.to_s
        end
      else
        pos_size, pos_side = infer_position(product_id: product_id, explicit_size: size)
        return {"success" => true, "message" => "No open position to close"} if pos_size.to_f <= 0.0
      end

      close_side = case pos_side
      when :long then :sell
      when :short then :buy
      when :buy then :sell
      when :sell then :buy
      else :sell
      end

      @logger.info("Closing position: product_id=#{product_id}, size=#{pos_size}, position_side=#{pos_side}, order_side=#{close_side}")

      order_body = build_order_body(product_id: product_id, side: close_side, size: pos_size, type: :market)

      @logger.info("Order body: #{order_body.inspect}")

      result = submit_order(order_body, product_id: product_id, side: close_side, size: pos_size)

      # If order was successful, update local Position record
      if result["success"] || result["order_id"]
        update_local_position_record(
          product_id: product_id,
          size: pos_size,
          close_price: get_current_market_price(product_id),
          order_result: result,
          position: position
        )
      end

      result
    end

    # Increase an existing position by adding more contracts in the same direction.
    #
    # `position:` is the local row the caller already resolved — the row this
    # increase lands on. It mirrors #close_position's `position:` for the same
    # reason: without it the size and averaged entry price were written to
    # `Position.open.by_product(...).order(:entry_time).last`, which is a
    # DIFFERENT row than the caller meant whenever several are open on one
    # product. On the close path Trading::PositionLifecycle sits in front and
    # would notice; nothing sits in front of an increase, so a misrouted fill
    # just silently skews some other position's average entry.
    #
    # Returns order result hash
    def increase_position(product_id:, size:, position: nil)
      TradingHalt.assert_active!(context: "CoinbasePositions#increase_position")
      raise "Authentication required" unless @authenticated || DryRun.active?

      # Resolve the target row BEFORE anything is sent. Refusing after the fill
      # would leave contracts at the venue that no local row accounts for, so
      # the ambiguity has to be settled while there is still nothing to undo.
      position ||= sole_open_position(product_id)

      # Get the current position to determine the side
      positions = list_open_positions(product_id: product_id)
      return {"success" => false, "message" => "No open position found to increase"} if positions.empty?

      venue_position = positions.find { |p| p["product_id"] == product_id } || positions.first
      current_side = venue_position["side"] || venue_position["position_side"] || venue_position.dig("position", "side")

      @logger.info("Increasing position debug: product_id=#{product_id}, current_side=#{current_side.inspect}, position=#{venue_position.inspect}")

      # Convert position side to order side for increase:
      # LONG position: BUY more contracts to increase
      # SHORT position: SELL more contracts to increase
      increase_side = case current_side.to_s.upcase
      when "LONG" then :buy
      when "SHORT" then :sell
      when "BUY" then :buy
      when "SELL" then :sell
      else
        @logger.error("Cannot determine position side for increase: #{current_side.inspect}")
        raise "Cannot determine position side for increase: #{current_side.inspect}"
      end

      @logger.info("Increasing position: product_id=#{product_id}, size=#{size}, original_side=#{current_side}, order_side=#{increase_side}")

      order_body = build_order_body(product_id: product_id, side: increase_side, size: size, type: :market)

      @logger.info("Order body: #{order_body.inspect}")

      result = submit_order(order_body, product_id: product_id, side: increase_side, size: size)

      # If order was successful, update local Position record
      if result["success"] || result["order_id"]
        increase_local_position_record(
          product_id: product_id,
          additional_size: size,
          additional_price: get_current_market_price(product_id) || venue_position["avg_entry_price"]&.to_f,
          order_result: result,
          position: position
        )
      end

      result
    end

    # Single order-placement chokepoint. In dry-run mode the order is routed to
    # the paper simulator and NEVER reaches Coinbase; otherwise it hits the live
    # brokerage endpoint. Every order-placing method (open/close/increase) goes
    # through here so the dry-run guarantee holds at one boundary.
    def submit_order(order_body, product_id:, side:, size:, price: nil)
      Trading::ExecutionSafety.enforce_paper_default!(logger: @logger)
      return simulate_order(product_id: product_id, side: side, size: size, price: price) if DryRun.active?

      resp = authenticated_post("/api/v3/brokerage/orders", order_body)
      JSON.parse(resp.body)
    end

    # Routes an order through PaperTrading::ExchangeSimulator using the real
    # market price instead of Coinbase. Full simulated fill/equity accounting is
    # a follow-up (#300 PR2); for now this guarantees no order reaches the
    # exchange and returns a dry-run result so the caller persists a
    # paper-labeled Position.
    def simulate_order(product_id:, side:, size:, price: nil)
      fill_price = price || get_current_market_price(product_id)
      # Simulated taker fee with the flat per-contract floor (issue #372) so
      # paper Positions carry realistic per-fill costs for reconciliation.
      #
      # Priced PER VENUE via CostModel.fee_for (issue #458, ADR 0004). This used
      # to inline CostModel.taker_fee_rate and .min_fee_per_contract — the PERP
      # schedule — for every product, so a dated NOL fill recorded 3 bps/$0.15
      # instead of 9 bps/$0.85 and understated the cost of the only instrument
      # this bot has actually traded. fee_for also prefers a real measured
      # commission over the seeded constant where one exists.
      #
      # The proportional leg is charged on NOTIONAL, not on the quote price.
      # `fill_price * size` drops contract_size — the #234 bug — and on BIP
      # (0.01 BTC/contract) that priced a 1-contract fill as if it were a whole
      # bitcoin: $19.12 instead of $0.19, 100x. The #486 calibration rehearsal
      # surfaced it as a "measured" 300 bps taker rate against a modeled 3 bps,
      # which would have read as ADR 0002's venue thesis being falsified when in
      # fact the simulator was overcharging. Trading::NotionalCap.notional_for is
      # the contract_size-aware helper every other notional site now uses.
      fees = CostModel.fee_for(product_id)
      notional = Trading::NotionalCap.notional_for(product_id, size, fill_price)
      fee = [notional * fees[:taker_rate].to_f,
        size.to_f * fees[:per_contract_fee].to_f].max.round(6)
      order_id = PaperTrading::ExchangeSimulator.new.place_limit(
        symbol: product_id,
        side: simulator_side(side),
        price: fill_price,
        quantity: size.to_f
      )
      @logger.warn("[DryRun] Simulated order #{order_id}: #{side} #{size} #{product_id} @ #{fill_price} (no Coinbase order placed)")
      {"success" => true, "order_id" => "DRY-RUN-#{order_id}", "dry_run" => true, "price" => fill_price, "fee" => fee}
    end

    def simulator_side(side)
      normalized = side.to_s.downcase
      return :sell if %w[sell short].include?(normalized)

      :buy
    end

    # Get current market price for a product
    def get_current_market_price(product_id)
      RecentMarketPrice.for_product(product_id).tap do |price|
        @logger.warn("No recent price data for #{product_id}") unless price
      end
    end

    # Update position method for tests
    def update_current_month_position(product_id, new_size, new_price)
      # Find the most recent open position for this product
      position = Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      # Update the position
      position.update!(
        size: new_size,
        entry_price: new_price
      )

      @logger.info("Updated local position record #{position.id}: size=#{new_size}, price=#{new_price}")
    rescue => e
      @logger.error("Failed to update local position record: #{e.message}")
      # Don't fail the main operation if local record update fails
    end

    # Open position on current month contract for an asset (legacy method, kept for compatibility)
    def open_current_month_position(asset_or_product_id, side = nil, size = nil, price = nil, day_trading: true,
      take_profit: nil, stop_loss: nil)
      # Handle both old and new calling signatures
      if side.nil? && size.nil? # New signature with hash
        product_id = asset_or_product_id
        params = side || {}
        side = params[:side]
        size = params[:size]
        price = params[:price]
        day_trading = params.fetch(:day_trading, true)
        take_profit = params[:take_profit]
        stop_loss = params[:stop_loss]
      else # Old signature with positional params
        asset = asset_or_product_id
        current_month_contract = @contract_manager.current_month_contract(asset)
        raise "No current month contract found for #{asset}" unless current_month_contract

        product_id = current_month_contract
      end

      @logger.info("Opening #{side} position of #{size} contracts on current month contract: #{product_id}")
      open_position(
        product_id: product_id,
        side: side,
        size: size,
        type: :market,
        price: price,
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss
      )
    end

    # Close position on current month contract for an asset (legacy method, kept for compatibility)
    def close_current_month_position(asset_or_product_id, size = nil)
      # Handle both asset lookup and direct product_id usage
      if asset_or_product_id.include?("-") # Looks like a product_id
        product_id = asset_or_product_id
      else # Looks like an asset (BTC, ETH)
        current_month_contract = @contract_manager.current_month_contract(asset_or_product_id)
        raise "No current month contract found for #{asset_or_product_id}" unless current_month_contract

        product_id = current_month_contract
      end

      @logger.info("Closing position on contract: #{product_id}")
      close_position(product_id: product_id, size: size)
    end

    # Open position on best available contract for an asset (current month preferred, upcoming as fallback)
    def open_best_available_position(asset:, side:, size:, type: :market, price: nil, day_trading: true,
      take_profit: nil, stop_loss: nil)
      best_contract = @contract_manager.best_available_contract(asset)
      raise "No suitable contract found for #{asset}" unless best_contract

      # Check if it's current or upcoming month for logging
      contract = Contract.find_by(product_id: best_contract)
      contract_type = if contract&.current_month?
        "current month"
      elsif contract&.upcoming_month?
        "upcoming month"
      else
        "available"
      end

      @logger.info("Opening #{side} position of #{size} contracts on #{contract_type} #{asset} contract: #{best_contract}")
      open_position(
        product_id: best_contract,
        side: side,
        size: size,
        type: type,
        price: price,
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss
      )
    end

    # Close position on best available contract for an asset
    def close_best_available_position(asset:, size: nil)
      best_contract = @contract_manager.best_available_contract(asset)
      raise "No suitable contract found for #{asset}" unless best_contract

      @logger.info("Closing position on #{asset} contract: #{best_contract}")
      close_position(product_id: best_contract, size: size)
    end

    private

    def build_order_body(product_id:, side:, size:, type:, price: nil)
      # For futures orders, use LONG/SHORT instead of buy/sell
      side_str = SideNormalizer.order(side)
      raise ArgumentError, "side must be :long, :short, :buy, or :sell, got: #{side}" unless side_str

      order_config = case type.to_sym
      when :market
        {
          "market_market_ioc" => {
            "base_size" => size.to_s
          }
        }
      when :limit
        raise ArgumentError, "price is required for limit orders" unless price

        {
          "limit_limit_gtc" => {
            "base_size" => size.to_s,
            "limit_price" => price.to_s,
            "post_only" => false
          }
        }
      when :maker
        raise ArgumentError, "price is required for limit orders" unless price

        # post_only is what makes this a maker order at all: the exchange
        # REJECTS it rather than crossing the spread, so it can never silently
        # pay taker. Paired with an end_time so an unfilled order cannot rest
        # forever — the two belong together.
        {
          "limit_limit_gtd" => {
            "base_size" => size.to_s,
            "limit_price" => price.to_s,
            "post_only" => true,
            "end_time" => self.class.maker_ttl_seconds.seconds.from_now.utc.iso8601
          }
        }
      else
        raise ArgumentError, "unsupported order type: #{type}"
      end

      {
        "client_order_id" => "cli-#{SecureRandom.uuid}",
        "product_id" => product_id,
        "side" => side_str,
        "order_configuration" => order_config
      }
    end

    def infer_position(product_id:, explicit_size: nil)
      positions = list_open_positions(product_id: product_id)
      return ["0", :buy] if positions.empty?

      pos = positions.find { |p| p["product_id"] == product_id } || positions.first

      # For futures positions, use number_of_contracts as the primary size field
      size = explicit_size || pos["number_of_contracts"] || pos["size"] || pos["base_size"] || pos["quantity"] || pos.dig(
        "position", "size"
      ) || "0"
      side = pos["side"] || pos["position_side"] || pos.dig("position", "side")

      [size.to_s, SideNormalizer.order_symbol(side) || :long]
    end

    # --- Local Position Record Management ---

    def create_local_position_record(product_id:, side:, size:, entry_price:, day_trading:, take_profit:, stop_loss:,
      order_result:, paper: false)
      position_side = SideNormalizer.position(side) || "LONG"

      # Calculate take profit and stop loss if not provided
      if take_profit.nil? && day_trading
        # Use 40 bps take profit for day trading (from strategy)
        take_profit = if position_side == "LONG"
          entry_price * (1 + 0.004)
        else
          entry_price * (1 - 0.004)
        end
      end

      if stop_loss.nil? && day_trading
        # Use 30 bps stop loss for day trading (from strategy)
        stop_loss = if position_side == "LONG"
          entry_price * (1 - 0.003)
        else
          entry_price * (1 + 0.003)
        end
      end

      position = Position.create!(
        product_id: product_id,
        side: position_side,
        size: size,
        entry_price: entry_price,
        entry_time: Time.current,
        status: "OPEN",
        day_trading: day_trading,
        take_profit: take_profit,
        stop_loss: stop_loss,
        paper: paper,
        entry_fee: order_result.is_a?(Hash) ? order_result["fee"] : nil,
        trailing_stop_enabled: ActiveModel::Type::Boolean.new.cast(ENV.fetch("TRAILING_STOP_ENABLED", "false")),
        trailing_stop_state: {}
      )

      persist_order(
        position: position,
        contract_id: product_id,
        side: SideNormalizer.order(side) || "buy",
        order_type: "market",
        quantity: size,
        target_price: entry_price,
        fill_price: entry_price,
        status: "filled",
        placed_at: Time.current,
        filled_at: Time.current,
        coinbase_order_id: extract_order_id(order_result)
      )

      @logger.info("Created local position record for #{product_id}: #{position_side} #{size} at #{entry_price}")
    rescue => e
      @logger.error("Failed to create local position record: #{e.message}")
    end

    def update_local_position_record(product_id:, size:, close_price:, order_result:, position: nil)
      # A caller that handed us the row owns realizing it (see #close_position).
      # We record the order and the fee; we do NOT touch status or size, because
      # two writers of realized P&L is how a reduce ends up counted twice.
      caller_realizes = !position.nil?
      # Otherwise: find the most recent open position for this product.
      position ||= Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      close_price ||= position.entry_price
      partial = partial_close?(position, size)

      persist_order(
        position: position,
        contract_id: product_id,
        side: position.long? ? "sell" : "buy",
        order_type: "market",
        quantity: size || position.size,
        target_price: close_price,
        fill_price: close_price,
        status: "filled",
        placed_at: Time.current,
        filled_at: Time.current,
        coinbase_order_id: extract_order_id(order_result)
      )

      fee = (order_result["fee"] if order_result.is_a?(Hash))

      if caller_realizes
        # On a partial the fee belongs to the split row, and only the caller's
        # close_partial! can put it there; writing it on the parent would bill
        # the contracts that are still open for an exit they have not taken.
        position.update!(exit_fee: fee) if fee && !partial
        return position
      end

      # A reduce is NOT a close. Asking to close 2 of 5 contracts used to run
      # close_position! anyway, flattening the whole row and leaving the caller
      # nothing left to realize. Route it to Position#close_partial! — the single
      # implementation of the split (#509, #517) — so the closed contracts become
      # their own CLOSED row and this one stays OPEN with the remainder.
      if partial
        portion = position.close_partial!(size, close_price, "API partial close", exit_fee: fee)
        if portion.nil?
          @logger.error("Failed to realize partial close of #{size} on position #{position.id}")
          return nil
        end
        @logger.info("Reduced local position record #{position.id} by #{size}; " \
                     "realized #{portion.id} with PnL: #{portion.pnl}; remaining #{position.size}")
        return portion
      end

      position.update!(exit_fee: fee) if fee

      # Close the position
      position.close_position!(close_price)
      @logger.info("Updated local position record #{position.id} as closed with PnL: #{position.pnl}")
      position
    rescue => e
      @logger.error("Failed to update local position record: #{e.message}")
      nil
    end

    # The one open row for this product, or nil when none is tracked (an
    # operator acting on an untracked venue position — allowed, it just has no
    # local record to update).
    #
    # Several open rows is NOT a nil case: it is a refusal. The caller asked us
    # to mutate "the" position for a product that has more than one, and the old
    # answer — `order(:entry_time).last` — was a guess dressed up as a lookup.
    # PositionsController#tracked_open_position takes the same care on close.
    def sole_open_position(product_id)
      scope = Position.open.by_product(product_id)
      count = scope.count
      return scope.first if count <= 1

      raise AmbiguousPositionError,
        "#{count} open positions tracked for #{product_id}; refusing to guess which one to increase. " \
        "Resolve the row and pass it as `position:`."
    end

    # A close request is a partial only when it is smaller than what we track.
    # nil, blank, or >= the tracked size all mean "close the whole thing", which
    # is the untouched full-close path.
    def partial_close?(position, size)
      return false if size.nil? || size.to_s.strip.empty?

      BigDecimal(size.to_s) < BigDecimal(position.size.to_s)
    rescue ArgumentError
      false
    end

    def increase_local_position_record(product_id:, additional_size:, additional_price:, order_result:, position: nil)
      # The caller's resolved row wins. Only fall back to finding one ourselves
      # when nobody told us which row this fill belongs to.
      position ||= Position.open.by_product(product_id).order(:entry_time).last
      return unless position

      # Calculate new average entry price
      total_size = position.size + additional_size.to_f
      new_entry_price = ((position.size * position.entry_price) + (additional_size.to_f * additional_price)) / total_size

      persist_order(
        position: position,
        contract_id: product_id,
        side: position.long? ? "buy" : "sell",
        order_type: "market",
        quantity: additional_size,
        target_price: additional_price,
        fill_price: additional_price,
        status: "filled",
        placed_at: Time.current,
        filled_at: Time.current,
        coinbase_order_id: extract_order_id(order_result)
      )

      # Update the position
      position.update!(
        size: total_size,
        entry_price: new_entry_price
      )

      @logger.info("Updated local position record #{position.id}: size increased to #{total_size}, new avg entry: #{new_entry_price}")
    rescue => e
      @logger.error("Failed to update local position record for increase: #{e.message}")
    end

    def extract_order_id(order_result)
      order_result&.dig("order_id") || order_result&.dig("success_response", "order_id")
    end

    def persist_order(position:, contract_id:, side:, order_type:, quantity:, status:,
      target_price: nil, fill_price: nil, placed_at: nil, filled_at: nil, coinbase_order_id: nil)
      Order.create!(
        position: position,
        contract_id: contract_id,
        side: side.to_s.downcase,
        order_type: order_type,
        quantity: quantity,
        target_price: target_price,
        fill_price: fill_price,
        status: status,
        placed_at: placed_at,
        filled_at: filled_at,
        coinbase_order_id: coinbase_order_id
      )
    rescue => e
      @logger.error("Failed to persist Order record: #{e.message}")
    end

    # --- Auth helpers (Advanced Trade style signing) ---

    def authenticated_get(path, params = {})
      @conn.headers["Accept"] = "application/json"
      jwt = build_jwt_token("GET", path, params: params)
      @conn.headers["Authorization"] = "Bearer #{jwt}"

      @logger.debug("GET #{path} with JWT payload: #{jwt[0..100]}...")
      @logger.debug("Headers: #{@conn.headers.slice("Accept", "Authorization").inspect}")

      begin
        @conn.get(path, params)
      rescue Faraday::ClientError => e
        log_faraday_error(e)
        raise
      end
    end

    def authenticated_post(path, body_hash = {})
      body_json = JSON.dump(body_hash)
      @conn.headers["Content-Type"] = "application/json"
      @conn.headers["Accept"] = "application/json"
      @conn.headers["Authorization"] = "Bearer #{build_jwt_token("POST", path, body: body_json)}"

      @logger.debug("POST #{path} with body: #{body_json}")
      @logger.debug("Headers: #{@conn.headers.slice("Content-Type", "Accept", "Authorization").inspect}")

      begin
        @conn.post(path, body_json)
      rescue Faraday::ClientError => e
        log_faraday_error(e)
        body = (e.response && e.response[:body]).to_s
        message = begin
          parsed = JSON.parse(body)
          parsed["message"] || parsed["error"] || body
        rescue
          body.presence || e.message
        end
        raise Faraday::ClientError.new("#{e.message}#{": #{message}" if message}", response: e.response)
      end
    end

    def log_faraday_error(e)
      @logger.error("Request failed: #{e.class} - #{e.message}")
      return unless e.response

      @logger.error("Response status: #{e.response[:status]}")
      @logger.error("Response headers: #{e.response[:headers]}")
      @logger.error("Response body: #{e.response[:body]}")
    end

    # Build ES256 JWT per Coinbase App API requirements (Authorization: Bearer <JWT>)
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def build_jwt_token(http_method, request_path, params: nil, body: nil)
      now = Time.now.to_i
      exp = now + 120 # expires in 2 minutes
      uri = format_jwt_uri(http_method, request_path, params, body)

      payload = {
        sub: @api_key,
        iss: "cdp",
        nbf: now,
        exp: exp,
        uri: uri
      }

      private_key = begin
        # Ruby/OpenSSL can read both PKCS#1/8 via OpenSSL::PKey.read
        OpenSSL::PKey.read(@api_secret)
      rescue OpenSSL::PKey::PKeyError
        OpenSSL::PKey::EC.new(@api_secret)
      end

      # Include kid header for clarity; some infrastructures rely on it
      # Use the full API key path like the Python implementation
      jwt = JWT.encode(payload, private_key, "ES256", {kid: @api_key})
      @logger.debug("Generated JWT for #{http_method} #{request_path}: #{jwt[0..50]}...")
      jwt
    end

    # Match Coinbase Python SDK jwt_generator.format_jwt_uri() behavior
    # See: https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication
    def format_jwt_uri(http_method, request_path, params, body)
      # Coinbase expects: "METHOD api.coinbase.com/path" format for the uri claim
      # Query params must NOT be included in the uri claim
      method = http_method.to_s.upcase
      host = "api.coinbase.com"

      "#{method} #{host}#{request_path}"
    end

    def load_credentials_from_file
      file_path = Rails.root.join("cdp_api_key.json")

      if File.exist?(file_path)
        begin
          data = JSON.parse(File.read(file_path))

          # Use the full organization path as the API key
          # This is what Coinbase expects for JWT authentication
          api_key = data["name"]
          private_key = data["privateKey"]

          @logger.info("Using API key: #{api_key}")
          @logger.info("Private key length: #{private_key.length}")

          {
            api_key: api_key,
            private_key: private_key
          }
        rescue JSON::ParserError => e
          @logger.error("Failed to parse cdp_api_key.json: #{e.message}")
          nil
        rescue => e
          @logger.error("Failed to load credentials from cdp_api_key.json: #{e.message}")
          nil
        end
      else
        @logger.warn("cdp_api_key.json file not found at #{file_path}")
        nil
      end
    end

    def normalize_pem_secret(secret)
      pem = secret.to_s
      # Support .env with escaped newlines
      pem = pem.gsub('\\n', "\n")
      pem.strip
    end

    # --- Current Month Contract Helpers ---

    # Get positions for current month contracts of a specific asset (BTC, ETH)
    def list_current_month_positions(asset:)
      current_month_contract = @contract_manager.current_month_contract(asset)
      return [] unless current_month_contract

      list_open_positions(product_id: current_month_contract)
    end

    # Get positions for upcoming month contracts of a specific asset (BTC, ETH)
    def list_upcoming_month_positions(asset:)
      upcoming_month_contract = @contract_manager.upcoming_month_contract(asset)
      return [] unless upcoming_month_contract

      list_open_positions(product_id: upcoming_month_contract)
    end

    # Get positions for the best available contract for an asset
    def list_best_available_positions(asset:)
      best_contract = @contract_manager.best_available_contract(asset)
      return [] unless best_contract

      list_open_positions(product_id: best_contract)
    end

    # Get all positions grouped by underlying asset
    def positions_by_asset
      all_positions = list_open_positions
      positions_by_asset = {}

      all_positions.each do |position|
        product_id = position["product_id"]
        asset = extract_asset_from_product_id(product_id)
        next unless asset

        positions_by_asset[asset] ||= []
        positions_by_asset[asset] << position
      end

      positions_by_asset
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

    # Check if any positions need to be rolled over to current month contracts
    def positions_need_rollover?
      expiring_contracts = @contract_manager.expiring_contracts(days_ahead: 3)
      all_positions = list_open_positions

      # Check if we have positions in any expiring contracts
      expiring_product_ids = expiring_contracts.map(&:product_id)
      all_positions.any? { |pos| expiring_product_ids.include?(pos["product_id"]) }
    end

    # Rollover positions from expiring contracts to current month contracts
    def rollover_positions
      return unless positions_need_rollover?

      @logger.info("Starting position rollover process")
      positions_by_asset.each do |asset, positions|
        rollover_asset_positions(asset, positions)
      end
    end

    private

    def rollover_asset_positions(asset, positions)
      current_month_contract = @contract_manager.current_month_contract(asset)
      return unless current_month_contract

      expiring_positions = positions.select do |pos|
        contract = Contract.find_by(product_id: pos["product_id"])
        contract&.expiration_date && contract.expiration_date <= Date.current + 3.days
      end

      return if expiring_positions.empty?

      @logger.info("Rolling over #{expiring_positions.size} #{asset} positions to #{current_month_contract}")

      expiring_positions.each do |position|
        rollover_single_position(position, current_month_contract, asset)
      end
    end

    def rollover_single_position(position, target_contract, asset)
      product_id = position["product_id"]
      size = position["number_of_contracts"] || position["size"]
      side = position["side"]

      @logger.info("Rolling over #{asset} position: #{size} contracts from #{product_id} to #{target_contract}")

      begin
        # Close the old position
        close_position(product_id: product_id, size: size)

        # Open new position in current month contract
        new_side = SideNormalizer.order_symbol(side) || :long

        open_position(
          product_id: target_contract,
          side: new_side,
          size: size,
          type: :market
        )

        @logger.info("Successfully rolled over #{asset} position to #{target_contract}")
      rescue => e
        @logger.error("Failed to rollover #{asset} position: #{e.message}")
        raise
      end
    end
  end
end
