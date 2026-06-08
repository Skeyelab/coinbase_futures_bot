# frozen_string_literal: true

module Trading
  class FuturesUnrealizedPnl
    def self.calculate(side:, entry_price:, current_price:, contracts:, contract_size: 1)
      return nil unless entry_price && current_price && contracts

      normalized_side = SideNormalizer.position(side) || side.to_s.upcase
      delta = if normalized_side == "LONG"
        current_price - entry_price
      else
        entry_price - current_price
      end

      (delta * contracts * contract_size).round(2)
    end

    def self.from_exchange_position(exchange_position, contract_size_resolver: ContractSizeResolver)
      product_id = exchange_position["product_id"]
      return nil unless product_id

      calculate(
        side: exchange_position["side"],
        entry_price: exchange_position["avg_entry_price"]&.to_f,
        current_price: exchange_position["current_price"]&.to_f,
        contracts: exchange_position["number_of_contracts"]&.to_f,
        contract_size: contract_size_resolver.for_product(product_id)
      )
    end
  end
end
