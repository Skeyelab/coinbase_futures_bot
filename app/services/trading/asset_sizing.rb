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

    def initialize(data)
      @data = data || {}
    end

    def for(asset)
      fallback = @data.fetch("default", {})
      cfg = (@data["assets"] || {}).fetch(asset.to_s, fallback)
      Params.new(
        contract_size_usd: pick(cfg, fallback, "contract_size_usd").to_f,
        max_contracts: pick(cfg, fallback, "max_contracts").to_i,
        max_concurrent: pick(cfg, fallback, "max_concurrent").to_i
      )
    end

    private

    def pick(cfg, fallback, key)
      cfg.fetch(key) { fallback[key] }
    end
  end
end
