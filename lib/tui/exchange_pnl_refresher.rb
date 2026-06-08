# frozen_string_literal: true

module Tui
  class ExchangePnlRefresher
    def self.refresh!(positions_service: Trading::CoinbasePositions.new, positions: Position.open)
      local_by_key = index_open_positions(positions)

      positions_service.list_open_positions.each do |exchange_position|
        apply_exchange_pnl!(exchange_position, local_by_key: local_by_key)
      end
      true
    rescue => e
      Rails.logger.warn("[TUI] Exchange PnL refresh failed: #{e.message}")
      false
    end

    def self.index_open_positions(positions)
      positions.to_a.each_with_object({}) do |position, memo|
        key = [position.product_id, position.side]
        memo[key] = position if memo[key].nil? || position.entry_time >= memo[key].entry_time
      end
    end
    private_class_method :index_open_positions

    def self.apply_exchange_pnl!(exchange_position, local_by_key:)
      product_id = exchange_position["product_id"]
      side = SideNormalizer.position(exchange_position["side"]&.upcase)
      unrealized_pnl = Trading::FuturesUnrealizedPnl.from_exchange_position(exchange_position)
      return unless product_id && side && unrealized_pnl

      local_position = local_by_key[[product_id, side]]
      return unless local_position

      local_position.update!(pnl: unrealized_pnl)
    end
    private_class_method :apply_exchange_pnl!
  end
end
