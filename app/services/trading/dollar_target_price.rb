# frozen_string_literal: true

module Trading
  class DollarTargetPrice
    DOLLAR_INPUT_PATTERN = /\A\$\s*(\d+(?:\.\d+)?)\s*\z/

    def self.parse_input(raw)
      text = raw.to_s.strip
      return nil if text.empty?

      if (match = text.match(DOLLAR_INPUT_PATTERN))
        {dollar_amount: match[1].to_f}
      else
        {price: text.to_f}
      end
    end

    def self.resolve(position:, field:, raw_input:, contract_size_resolver: ContractSizeResolver)
      parsed = parse_input(raw_input)
      return [nil, "Target value required"] unless parsed

      if parsed[:price]
        [parsed[:price], nil]
      else
        price = price_for(
          position: position,
          field: field,
          dollar_amount: parsed[:dollar_amount],
          contract_size_resolver: contract_size_resolver
        )
        [price, nil]
      end
    rescue ArgumentError => e
      [nil, e.message]
    end

    def self.price_for(position:, field:, dollar_amount:, contract_size_resolver: ContractSizeResolver)
      amount = dollar_amount.to_f
      raise ArgumentError, "Dollar amount must be positive" unless amount.positive?

      contract_size = contract_size_resolver.for_product(position.product_id) || 1
      denominator = position.size.to_f * contract_size
      raise ArgumentError, "Cannot calculate price target with zero position size" unless denominator.positive?

      price_move = amount / denominator
      entry = position.entry_price.to_f

      if position.side == "LONG"
        (field == :take_profit) ? entry + price_move : entry - price_move
      else
        (field == :take_profit) ? entry - price_move : entry + price_move
      end
    end
  end
end
