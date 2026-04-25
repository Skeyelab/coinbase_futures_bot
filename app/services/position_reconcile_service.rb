# frozen_string_literal: true

# Marks local OPEN positions CLOSED when they no longer appear on Coinbase
# futures positions (manual close on exchange, drift, etc.). Does not place orders.
class PositionReconcileService
  def initialize(coinbase_client: nil, logger: Rails.logger)
    @client = coinbase_client || Coinbase::Client.new(logger: logger)
    @logger = logger
  end

  # @return [Hash] { closed_count: Integer, closed_ids: Array<Integer>, errors: Array<String> }
  def reconcile!
    auth = @client.test_auth
    unless auth[:advanced_trade][:ok]
      raise "Coinbase authentication failed: #{auth[:advanced_trade][:message]}"
    end

    rows = @client.futures_positions
    open_keys = exchange_open_keys(rows)

    closed_ids = []
    errors = []

    Position.open.find_each do |position|
      key = [position.product_id, position.side]
      next if open_keys.key?(key)

      close_price = position.get_current_market_price || position.entry_price
      position.force_close!(close_price, "Reconcile: absent from exchange")
      closed_ids << position.id
    rescue => e
      msg = "Position #{position.id}: #{e.message}"
      @logger.error("[PRS] #{msg}")
      errors << msg
    end

    @logger.info("[PRS] Reconciled #{closed_ids.size} local row(s) absent from exchange")

    {closed_count: closed_ids.size, closed_ids: closed_ids, errors: errors}
  end

  private

  def exchange_open_keys(rows)
    keys = {}
    Array(rows).each do |cb|
      product_id = cb["product_id"]
      size = cb["number_of_contracts"].to_f
      next if size.zero? || product_id.blank?

      side = cb["side"]&.upcase
      position_side = normalized_side(side)
      next unless position_side

      keys[[product_id, position_side]] = true
    end
    keys
  end

  def normalized_side(side)
    return nil unless side

    case side.downcase
    when "long", "buy" then "LONG"
    when "short", "sell" then "SHORT"
    end
  end
end
