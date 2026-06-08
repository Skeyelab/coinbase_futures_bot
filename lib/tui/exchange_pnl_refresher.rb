# frozen_string_literal: true

module Tui
  class ExchangePnlRefresher
    def self.refresh!(positions_service: Trading::CoinbasePositions.new, positions: Position.open)
      positions_service.list_open_positions.each do |exchange_position|
        sync_unrealized_pnl!(exchange_position, positions: positions)
      end
    rescue => e
      Rails.logger.warn("[TUI] Exchange PnL refresh failed: #{e.message}")
    end

    def self.sync_unrealized_pnl!(exchange_position, positions:)
      product_id = exchange_position["product_id"]
      side = SideNormalizer.position(exchange_position["side"]&.upcase)
      unrealized_pnl = Trading::FuturesUnrealizedPnl.from_exchange_position(exchange_position)
      return unless product_id && side && unrealized_pnl

      local_position = positions
        .where(product_id: product_id, side: side)
        .order(:entry_time)
        .last
      return unless local_position

      local_position.update!(pnl: unrealized_pnl)
    end
    private_class_method :sync_unrealized_pnl!
  end
end
