# frozen_string_literal: true

module Strategy
  class SpotDrivenStrategy
    def initialize(logger: Rails.logger)
      @logger = logger
    end

    # Returns signal per product_id: { product_id => :long|:short|:flat }
    def generate_signals(product_ids: ["BTC-USD-PERP", "ETH-USD-PERP"], as_of: Time.now.utc)
      signals = {}
      product_ids.each do |pid|
        z = latest_sentiment_z(pid, window: "15m")
        base_signal = base_strategy_signal(pid)
        signals[pid] = apply_sentiment_gate(base_signal, z)
      end
      signals
    end

    private

    def base_strategy_signal(product_id)
      :flat
    end

    def latest_sentiment_z(product_id, window: "15m")
      rec = SentimentAggregate.where(symbol: product_id, window: window).order(window_end_at: :desc).first
      rec&.z_score&.to_f || 0.0
    end

    def apply_sentiment_gate(base_signal, z)
      threshold = ENV.fetch("SENTIMENT_Z_THRESHOLD", "1.2").to_f
      if z.abs < threshold
        :flat
      else
        base_signal
      end
    end
  end
end
