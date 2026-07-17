# frozen_string_literal: true

module Trading
  class ContractSizeResolver
    CACHE_TTL = 1.hour
    DEFAULT_CONTRACT_SIZE = 1

    def self.for_product(product_id, client: nil)
      cached = Rails.cache.read(cache_key(product_id))
      return cached unless cached.nil?

      size = fetch_from_api(product_id, client: client)

      # Only cache a real API result. Caching the DEFAULT fallback would pin a
      # contract_size of 1 for CACHE_TTL whenever a lookup transiently fails,
      # understating dollar PnL and leverage ~contract_size× for futures like
      # NOL (contract_size 10). On failure, return the default but retry next
      # time. See #234.
      if size
        Rails.cache.write(cache_key(product_id), size, expires_in: CACHE_TTL)
        size
      else
        DEFAULT_CONTRACT_SIZE
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
