# frozen_string_literal: true

module Trading
  # Per-asset position sizing (issue #340), data-driven from
  # config/asset_sizing.yml so adding a tradable asset is a config edit rather
  # than a new `case` branch. Previously RapidSignalEvaluationJob hardcoded
  # BTC/ETH and every other asset (OIL, metals, expansion pairs) silently fell
  # to crypto-shaped `else` defaults and was mis-sized. Unknown assets now hit
  # the deliberately conservative `default` block instead.
  class AssetSizing
    DEFAULT_PATH = Rails.root.join("config", "asset_sizing.yml")

    Params = Struct.new(:contract_size_usd, :max_contracts, :max_concurrent)

    def self.default
      @default ||= new(YAML.safe_load_file(DEFAULT_PATH))
    end

    def self.for(asset)
      default.for(asset)
    end

    def self.for_product(product_id)
      default.for_product(product_id)
    end

    def initialize(data)
      @data = data || {}
    end

    def for(asset)
      build(layers_for_asset(asset))
    end

    # Sizing for a specific CONTRACT, not just its underlying (issue #486
    # precondition 4).
    #
    # Base currency is the wrong grain for a venue with two shapes of the same
    # asset. Contract::PREFIX_TO_BASE_CURRENCY maps both "BIT" (dated nano,
    # ~$100/contract) and "BIP" (perp, ~$659/contract) to "BTC", so the perp
    # inherited the nano's 5-contract / 2-concurrent caps — 6.6x the intended
    # notional per contract and 13x per asset. A $150-budget calibration run
    # could have opened $6.6k of exposure under caps that looked satisfied.
    #
    # Resolution is layered, most specific last: default -> asset -> contract
    # prefix. A contract entry may therefore override one knob and leave the
    # others alone, and every existing base-currency entry keeps working
    # untouched for products with no contract entry.
    def for_product(product_id)
      prefix = prefix_for(product_id)
      asset = Contract::PREFIX_TO_BASE_CURRENCY.fetch(prefix, prefix)
      build(layers_for_asset(asset) << contracts.fetch(prefix, {}))
    end

    private

    def build(layers)
      merged = layers.compact.reduce({}) { |acc, layer| acc.merge(layer.compact) }
      Params.new(
        contract_size_usd: merged["contract_size_usd"].to_f,
        max_contracts: merged["max_contracts"].to_i,
        max_concurrent: merged["max_concurrent"].to_i
      )
    end

    def layers_for_asset(asset)
      fallback = @data.fetch("default", {})
      [fallback, (@data["assets"] || {}).fetch(asset.to_s, {})]
    end

    def contracts = @data["contracts"] || {}

    # "BIP-20DEC30-CDE" -> "BIP". Anything unparseable resolves to "" so it
    # matches no entry and lands on `default`.
    def prefix_for(product_id)
      product_id.to_s.split("-").first.to_s
    end
  end
end
