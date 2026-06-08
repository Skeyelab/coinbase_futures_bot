# frozen_string_literal: true

# Marks local OPEN positions CLOSED when they no longer appear on Coinbase
# futures positions (manual close on exchange, drift, etc.). Does not place orders.
class PositionReconcileService
  REASON = "Reconcile: closed on exchange"

  def initialize(coinbase_client: nil, logger: Rails.logger)
    @client = coinbase_client || Coinbase::Client.new(logger: logger)
    @logger = logger
  end

  # @param exchange_rows [Array<Hash>, nil] optional Coinbase futures snapshot (avoids refetch)
  # @return [Hash] { closed_count: Integer, closed_ids: Array<Integer>, errors: Array<String> }
  def reconcile!(exchange_rows: nil)
    rows = exchange_rows || fetch_exchange_rows
    open_keys = self.class.exchange_open_keys(rows)

    closed_ids = []
    errors = []

    Position.open.find_each do |position|
      key = [position.product_id, position.side]
      next if open_keys.key?(key)

      close_price, market_price_used = resolve_close_price(position)
      pnl = resolve_close_pnl(position, close_price, market_price_used: market_price_used)
      position.force_close!(close_price, REASON, pnl: pnl)
      closed_ids << position.id
    rescue => e
      msg = "Position #{position.id}: #{e.message}"
      @logger.error("[PRS] #{msg}")
      errors << msg
    end

    @logger.info("[PRS] Reconciled #{closed_ids.size} local row(s) absent from exchange")

    {closed_count: closed_ids.size, closed_ids: closed_ids, errors: errors}
  end

  def self.exchange_open_keys(rows)
    keys = {}
    Array(rows).each do |cb|
      product_id = cb["product_id"]
      size = cb["number_of_contracts"].to_f
      next if size.zero? || product_id.blank?

      position_side = SideNormalizer.position(cb["side"]&.upcase)
      next unless position_side

      keys[[product_id, position_side]] = true
    end
    keys
  end

  private

  def fetch_exchange_rows
    auth = @client.test_auth
    unless auth[:advanced_trade][:ok]
      raise "Coinbase authentication failed: #{auth[:advanced_trade][:message]}"
    end

    @client.futures_positions
  end

  def resolve_close_price(position)
    market_price = position.get_current_market_price
    return [market_price, true] if market_price

    [position.entry_price, false]
  end

  def resolve_close_pnl(position, close_price, market_price_used:)
    if market_price_used
      pnl = position.unrealized_pnl_at(close_price)
      return pnl if pnl
    end

    return position.pnl.round(2) if position.pnl.present?

    position.calculate_pnl(close_price) || 0
  end
end
