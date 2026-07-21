# frozen_string_literal: true

require "rails_helper"

# One builder for the LIVE-configured MultiTimeframeSignal so the evaluator,
# calibration, backtest engine, and signal jobs all describe the same
# strategy. (Drift audit: calibration was tuning a DEFAULTS-configured twin
# with a different trend filter than live.)
RSpec.describe Trading::StrategyFactory, type: :service do
  let(:live_config) { Rails.application.config.real_time_signals[:strategies]["MultiTimeframeSignal"] }

  it "builds from the live initializer config, not class DEFAULTS" do
    strategy = described_class.multi_timeframe
    config = strategy.instance_variable_get(:@config)

    expect(config[:ema_1h_short]).to eq(live_config[:ema_1h_short])
    expect(config[:ema_1h_long]).to eq(live_config[:ema_1h_long])
    expect(config[:min_1h_candles]).to eq(live_config[:min_1h_candles])
  end

  it "takes tp/sl/risk/position sizes from the given profile" do
    profile = create(:trading_profile, tp_target: 0.009, sl_target: 0.005,
      risk_fraction: 0.03, max_position_size: 20, min_position_size: 2)

    config = described_class.multi_timeframe(profile: profile).instance_variable_get(:@config)

    expect(config[:tp_target]).to eq(0.009)
    expect(config[:sl_target]).to eq(0.005)
    expect(config[:risk_fraction]).to eq(0.03)
    expect(config[:max_position_size]).to eq(20)
  end

  it "defaults to the effective profile" do
    create(:trading_profile, :active, tp_target: 0.011)
    config = described_class.multi_timeframe.instance_variable_get(:@config)
    expect(config[:tp_target]).to eq(0.011)
  end

  it "lets explicit overrides win (calibration candidates, backtest mode)" do
    config = described_class.multi_timeframe(tp_target: 0.02, resolve_symbols: false)
      .instance_variable_get(:@config)

    expect(config[:tp_target]).to eq(0.02)
    expect(config[:resolve_symbols]).to be(false)
    expect(config[:ema_1h_short]).to eq(live_config[:ema_1h_short])
  end
end
