# frozen_string_literal: true

module Trading
  # Declarative per-symbol strategy selection (issue #303), data-driven from
  # config/strategy_selection.yml — the same pattern as AssetSizing. A symbol
  # with an ENABLED entry runs the named strategy with the entry's frozen
  # params; every other symbol resolves to the default MultiTimeframeSignal,
  # so the file is zero behavior change until an operator flips an entry on.
  #
  # A YAML file rather than a TradingProfile column, deliberately: profiles
  # are mutated nightly by CalibrationJob — the exact motion #483 exists to
  # freeze — while this file only changes by reviewed deploy, and its
  # fingerprint is captured by CalibrationFreeze so a mid-sample edit is loud.
  class StrategySelection
    DEFAULT_PATH = Rails.root.join("config", "strategy_selection.yml")
    DEFAULT_STRATEGY = "MultiTimeframeSignal"

    Selection = Data.define(:symbol, :strategy_name, :params, :min_confidence, :configured) do
      def configured? = !!configured
    end

    class << self
      def default
        @default ||= new(load_data)
      end

      # Test hook / config reload.
      def reset!
        @default = nil
      end

      def for_symbol(symbol) = default.for_symbol(symbol)

      def entries(include_disabled: false)
        default.entries(include_disabled: include_disabled)
      end

      def fingerprint = default.fingerprint

      private

      def load_data
        return {} unless File.exist?(DEFAULT_PATH)

        YAML.safe_load_file(DEFAULT_PATH) || {}
      end
    end

    def initialize(data)
      @data = data || {}
    end

    def for_symbol(symbol)
      entry = symbols_config[symbol.to_s]
      return default_selection(symbol) unless entry && enabled?(entry)

      build_selection(symbol.to_s, entry)
    end

    # Every enabled non-default selection. include_disabled: true also lists
    # entries whose switch is off — the proxy-fidelity cron validates a
    # pairing BEFORE the operator flips it.
    def entries(include_disabled: false)
      symbols_config.filter_map do |symbol, entry|
        next if !include_disabled && !enabled?(entry)

        build_selection(symbol, entry)
      end
    end

    # Digest of the whole selection config. Captured by CalibrationFreeze at
    # freeze! time so a mid-sample config change is detectable (#483/#376).
    def fingerprint
      Digest::SHA256.hexdigest(JSON.generate(@data))
    end

    private

    def symbols_config = @data["symbols"] || {}

    def enabled?(entry)
      entry.key?("enabled") ? !!entry["enabled"] : true
    end

    def build_selection(symbol, entry)
      Selection.new(
        symbol: symbol,
        strategy_name: entry.fetch("strategy"),
        params: (entry["params"] || {}).symbolize_keys,
        min_confidence: entry["min_confidence"]&.to_f,
        configured: true
      )
    end

    def default_selection(symbol)
      Selection.new(
        symbol: symbol.to_s,
        strategy_name: @data.dig("default", "strategy") || DEFAULT_STRATEGY,
        params: {},
        min_confidence: nil,
        configured: false
      )
    end
  end
end
