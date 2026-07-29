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

  # Declarative strategy selection (issue #303): for_symbol is THE resolution
  # site. The realtime evaluator, RapidSignalEvaluationJob and
  # GenerateSignalsJob all resolve through it — per-job divergence is the
  # #479/#504 bug class.
  describe ".for_symbol" do
    def stub_selection(data)
      allow(Trading::StrategySelection).to receive(:default)
        .and_return(Trading::StrategySelection.new(data))
    end

    let(:funding_skew_data) do
      {"symbols" => {"BIP-FACT-CDE" => {
        "strategy" => "FundingSkewContrarian",
        "params" => {"entry_z" => 2.0, "exit_z" => 0.5, "window" => 168,
                     "stop" => 0.01, "spot_symbol" => "BTC-USD"}
      }}}
    end

    it "builds the same live MultiTimeframeSignal as .multi_timeframe for an unconfigured symbol" do
      strategy = described_class.for_symbol("ETH-UNCONF-CDE")

      expect(strategy).to be_a(Strategy::MultiTimeframeSignal)
      expect(strategy.instance_variable_get(:@config))
        .to eq(described_class.multi_timeframe.instance_variable_get(:@config))
    end

    it "passes overrides through to the default strategy (rapid-path knobs)" do
      config = described_class.for_symbol("ETH-UNCONF-CDE", min_5m_candles: 60, min_1m_candles: 30)
        .instance_variable_get(:@config)

      expect(config[:min_5m_candles]).to eq(60)
      expect(config[:min_1m_candles]).to eq(30)
    end

    it "uses the symbol's effective (calibrated) profile when none is given" do
      create(:trading_profile, :active, symbol: "ETH-UNCONF-CDE", name: "cal-eth", tp_target: 0.013)

      config = described_class.for_symbol("ETH-UNCONF-CDE").instance_variable_get(:@config)

      expect(config[:tp_target]).to eq(0.013)
    end

    it "builds the configured FundingSkewContrarian with the selection's frozen params" do
      stub_selection(funding_skew_data)

      strategy = described_class.for_symbol("BIP-FACT-CDE")

      expect(strategy).to be_a(Strategy::FundingSkewContrarian)
      config = strategy.instance_variable_get(:@config)
      expect(config[:entry_z]).to eq(2.0)
      expect(config[:exit_z]).to eq(0.5)
      expect(config[:window]).to eq(168)
      expect(config[:stop]).to eq(0.01)
      expect(config[:spot_symbol]).to eq("BTC-USD")
    end

    it "merges caller overrides over the selection params (real contract notional)" do
      stub_selection(funding_skew_data)

      config = described_class.for_symbol("BIP-FACT-CDE", contract_size_usd: 659.0)
        .instance_variable_get(:@config)

      expect(config[:contract_size_usd]).to eq(659.0)
    end

    it "raises loudly on a strategy name the registry does not know" do
      stub_selection({"symbols" => {"X-CDE" => {"strategy" => "TypoStrategy"}}})

      expect { described_class.for_symbol("X-CDE") }
        .to raise_error(Trading::StrategyFactory::UnknownStrategyError, /TypoStrategy/)
    end
  end

  describe ".registry" do
    it "lists the available strategies by name" do
      expect(described_class.registry.keys)
        .to include("MultiTimeframeSignal", "FundingSkewContrarian")
    end
  end

  # Freeze discipline (#483/#376): a strategy-selection config change while a
  # calibration freeze is active invalidates the gate-2a sample. It must be
  # LOUD — critical Slack alert + error log — not silent.
  describe "selection drift alarm under freeze" do
    before do
      BotRuntimeStat.where(key: Trading::CalibrationFreeze::STORE_KEY).delete_all
      described_class.instance_variable_set(:@selection_drift_alerted, nil)
      allow(SlackNotificationService).to receive(:alert)
    end

    def drift_the_config!
      allow(Trading::StrategySelection).to receive(:fingerprint).and_return("drifted-fingerprint")
    end

    it "fires a critical Slack alert and error log when the selection changes after freeze!" do
      Trading::CalibrationFreeze.freeze!(reason: "gate-2a sample", logger: Logger.new(IO::NULL))
      drift_the_config!
      allow(Rails.logger).to receive(:error).and_call_original

      described_class.for_symbol("ETH-UNCONF-CDE")

      expect(SlackNotificationService).to have_received(:alert)
        .with("critical", /[Ss]trategy selection/, hash_including(:frozen_fingerprint, :current_fingerprint))
      expect(Rails.logger).to have_received(:error).with(/strategy selection/i)
    end

    it "alerts once per drift, not once per resolution" do
      Trading::CalibrationFreeze.freeze!(reason: "gate-2a sample", logger: Logger.new(IO::NULL))
      drift_the_config!

      3.times { described_class.for_symbol("ETH-UNCONF-CDE") }

      expect(SlackNotificationService).to have_received(:alert).once
    end

    it "stays quiet when not frozen" do
      drift_the_config!

      described_class.for_symbol("ETH-UNCONF-CDE")

      expect(SlackNotificationService).not_to have_received(:alert)
    end

    it "stays quiet while the frozen fingerprint still matches" do
      Trading::CalibrationFreeze.freeze!(reason: "gate-2a sample", logger: Logger.new(IO::NULL))

      described_class.for_symbol("ETH-UNCONF-CDE")

      expect(SlackNotificationService).not_to have_received(:alert)
    end
  end
end
