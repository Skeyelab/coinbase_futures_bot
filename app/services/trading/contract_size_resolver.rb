# frozen_string_literal: true

module Trading
  class ContractSizeResolver
    CACHE_TTL = 1.hour
    DEFAULT_CONTRACT_SIZE = 1

    def self.for_product(product_id, client: nil)
      Rails.cache.fetch(cache_key(product_id), expires_in: CACHE_TTL, race_condition_ttl: 10.seconds) do
        fetch_from_api(product_id, client: client) || DEFAULT_CONTRACT_SIZE
      end
    end

    def self.fetch_from_api(product_id, client: nil)
      client ||= Coinbase::AdvancedTradeClient.new
      product = client.get_product(product_id)
      product.dig("future_product_details", "contract_size")&.to_f
    rescue => e
      Rails.logger.debug("[ContractSizeResolver] #{product_id}: #{e.message}")
      nil
    end

    def self.cache_key(product_id)
      "contract_size:#{product_id}"
    end
    private_class_method :cache_key
  end
end
