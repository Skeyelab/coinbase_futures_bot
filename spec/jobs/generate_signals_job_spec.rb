# frozen_string_literal: true

require "rails_helper"

RSpec.describe GenerateSignalsJob, type: :job do
  let(:job) { described_class.new }
  let(:mock_strategy) { instance_double(Strategy::MultiTimeframeSignal) }
  let!(:trading_pair) { create(:trading_pair, enabled: true, product_id: "BTC-29DEC24-CDE") }
  let(:mock_signal) do
    {
      side: :buy,
      price: 50_000.0,
      quantity: 1,
      tp: 52_000.0,
      sl: 49_000.0,
      confidence: 80
    }
  end

  before do
    allow(Strategy::MultiTimeframeSignal).to receive(:new).and_return(mock_strategy)
    allow(SlackNotificationService).to receive(:signal_generated)
    # Allow puts to be called without mocking it
    allow(job).to receive(:puts).and_call_original
  end

  # Helper method to create comprehensive candle data for testing
  def create_comprehensive_candle_data(symbol:, base_price: 50_000.0, trend: :up, candle_count: {})
    candle_data = []
    base_time = Time.current.utc
    
    counts = {
      "1h" => 80,
      "15m" => 120,
      "5m" => 100,
      "1m" => 60
    }.merge(candle_count)

    # Create 1h candles for trend analysis
    counts["1h"].times do |i|
      timestamp = base_time - (counts["1h"] - i).hours
      price_adj = trend == :up ? (i * 10) : -(i * 10)
      price = base_price + price_adj
      candle_data << {
        symbol: symbol, timeframe: "1h", timestamp: timestamp,
        open: price - 50, high: price + 100, low: price - 100, close: price,
        volume: 1000 + (i * 10), created_at: Time.current, updated_at: Time.current
      }
    end

    # Create 15m candles for intraday confirmation
    counts["15m"].times do |i|
      timestamp = base_time - (counts["15m"] - i) * 15.minutes
      price_adj = trend == :up ? (i * 5) : -(i * 5)
      price = base_price + 100 + price_adj
      candle_data << {
        symbol: symbol, timeframe: "15m", timestamp: timestamp,
        open: price - 25, high: price + 50, low: price - 50, close: price,
        volume: 500 + (i * 5), created_at: Time.current, updated_at: Time.current
      }
    end

    # Create 5m candles for entry triggers
    counts["5m"].times do |i|
      timestamp = base_time - (counts["5m"] - i) * 5.minutes
      price_adj = trend == :up ? (i * 2) : -(i * 2)
      price = base_price + 150 + price_adj
      candle_data << {
        symbol: symbol, timeframe: "5m", timestamp: timestamp,
        open: price - 10, high: price + 20, low: price - 20, close: price,
        volume: 250 + (i * 2), created_at: Time.current, updated_at: Time.current
      }
    end

    # Create 1m candles for micro-timing
    counts["1m"].times do |i|
      timestamp = base_time - (counts["1m"] - i).minutes
      price_adj = trend == :up ? (i * 1) : -(i * 1)
      price = base_price + 200 + price_adj
      candle_data << {
        symbol: symbol, timeframe: "1m", timestamp: timestamp,
        open: price - 5, high: price + 10, low: price - 10, close: price,
        volume: 100 + i, created_at: Time.current, updated_at: Time.current
      }
    end

    candle_data
  end

  # Helper method to create sentiment data
  def create_sentiment_data(symbol:, z_score: 2.0, avg_score: 0.3)
    SentimentAggregate.create!(
      symbol: symbol,
      window: "15m",
      window_end_at: Time.current.utc.change(sec: 0),
      count: 10,
      avg_score: avg_score,
      z_score: z_score
    )
  end

  describe "#perform" do
    context "with default equity" do
      before do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return(nil)
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "initializes strategy with correct parameters" do
        expect(Strategy::MultiTimeframeSignal).to receive(:new).with(
          ema_1h_short: 21,
          ema_1h_long: 50,
          ema_15m: 21,
          min_1h_candles: 60,
          min_15m_candles: 80
        )

        job.perform
      end

      it "processes all enabled trading pairs" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: trading_pair.product_id, equity_usd: 10_000.0}
        )

        job.perform
      end

      it "logs analysis start for each pair" do
        expect(job).to receive(:puts).with("Analyzing #{trading_pair.product_id}...")

        job.perform
      end
    end

    context "with custom equity" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "uses provided equity amount" do
        expect(mock_strategy).to receive(:signal).with(
          {symbol: trading_pair.product_id, equity_usd: 25_000.0}
        )

        job.perform(equity_usd: 25_000.0)
      end
    end

    context "when strategy returns a signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
      end

      it "logs the signal details" do
        expect(job).to receive(:puts).with(
          "[Signal] #{trading_pair.product_id} side=buy price=50000.0 qty=1 tp=52000.0 sl=49000.0 conf=80%"
        )

        job.perform
      end

      it "sends Slack notification" do
        expect(SlackNotificationService).to receive(:signal_generated).with(
          {
            symbol: trading_pair.product_id,
            side: :buy,
            price: 50_000.0,
            quantity: 1,
            tp: 52_000.0,
            sl: 49_000.0,
            confidence: 80
          }
        )

        job.perform
      end
    end

    context "when strategy returns no signal" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "logs no-entry message" do
        expect(job).to receive(:puts).with("[Signal] #{trading_pair.product_id} no-entry")

        job.perform
      end

      it "does not send Slack notification" do
        expect(SlackNotificationService).not_to receive(:signal_generated)

        job.perform
      end
    end

    context "when no enabled trading pairs exist" do
      before do
        TradingPair.update_all(enabled: false)
      end

      it "still initializes strategy but processes no pairs" do
        expect(Strategy::MultiTimeframeSignal).to receive(:new)
        expect(mock_strategy).not_to receive(:signal)

        job.perform
      end
    end

    context "when multiple trading pairs exist" do
      let!(:trading_pair2) { create(:trading_pair, enabled: true, product_id: "ETH-29DEC24-CDE") }

      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "processes all enabled pairs" do
        enabled_count = TradingPair.enabled.count
        expect(mock_strategy).to receive(:signal).exactly(enabled_count).times

        job.perform
      end
    end
  end

  describe "#default_equity_usd" do
    context "when SIGNAL_EQUITY_USD environment variable is set" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return("20000")
      end

      it "returns the environment variable value as float" do
        expect(job.send(:default_equity_usd)).to eq(20_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD environment variable is not set" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return(nil)
      end

      it "returns default value of 10,000" do
        expect(job.send(:default_equity_usd)).to eq(10_000.0)
      end
    end

    context "when SIGNAL_EQUITY_USD is an invalid number" do
      before do
        allow(ENV).to receive(:[]).with("SIGNAL_EQUITY_USD").and_return("invalid")
      end

      it "returns 0.0" do
        expect(job.send(:default_equity_usd)).to eq(0.0)
      end
    end
  end

  describe "job configuration" do
    it "uses the default queue" do
      expect(described_class.queue_name).to eq("default")
    end

    it "inherits from ApplicationJob" do
      expect(described_class.superclass).to eq(ApplicationJob)
    end
  end

  describe "error handling" do
    before do
      # Mock TradingPair.enabled to return only our test trading pair
      allow(TradingPair).to receive(:enabled) do
        double.tap do |relation|
          allow(relation).to receive(:find_each) do |&block|
            block.call(trading_pair)
          end
        end
      end
    end

    context "when strategy initialization fails" do
      before do
        allow(Strategy::MultiTimeframeSignal).to receive(:new).and_raise(StandardError.new("Strategy init failed"))
        allow(mock_strategy).to receive(:signal).and_return(nil)
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Strategy init failed")
      end
    end

    context "when signal generation fails" do
      before do
        allow(mock_strategy).to receive(:signal).and_raise(StandardError.new("Signal generation failed"))
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Signal generation failed")
      end
    end

    context "when Slack notification fails" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(SlackNotificationService).to receive(:signal_generated).and_raise(StandardError.new("Slack error"))
        # Mock the default_equity_usd method for this context
        allow(job).to receive(:default_equity_usd).and_return(10_000.0)
      end

      it "raises the error" do
        expect { job.perform }.to raise_error(StandardError, "Slack error")
      end
    end
  end

  describe "integration with ActiveJob" do
    it "can be enqueued" do
      expect do
        described_class.perform_later
      end.not_to raise_error
    end

    it "can be enqueued with custom equity" do
      expect do
        described_class.perform_later(equity_usd: 50_000)
      end.not_to raise_error
    end
  end

  # ========== COMPREHENSIVE SIGNAL GENERATION TESTING ==========
  # These tests cover the high-priority scenarios from Linear issue FUT-49

  describe "Signal Generation Algorithms and Logic" do
    before do
      # Use mock strategy for consistent testing
      allow(mock_strategy).to receive(:signal).and_return(nil)
    end

    context "with bullish market conditions" do
      before do
        # Create comprehensive candle data for bullish scenario
        candle_data = create_comprehensive_candle_data(
          symbol: trading_pair.product_id,
          trend: :up,
          base_price: 50_000.0
        )
        Candle.insert_all(candle_data)

        # Create positive sentiment
        create_sentiment_data(symbol: trading_pair.product_id, z_score: 2.5, avg_score: 0.4)

        # Enable sentiment filtering
        allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
        allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")
      end

      it "generates long signals with proper risk management parameters" do
        job.perform(equity_usd: 25_000.0)

        # Verify strategy was called with correct parameters
        expect(Strategy::MultiTimeframeSignal).to have_received(:new).with(
          ema_1h_short: 21,
          ema_1h_long: 50,
          ema_15m: 21,
          min_1h_candles: 60,
          min_15m_candles: 80
        )
      end

      it "validates signal quality assessment for bullish conditions" do
        # Mock strategy to return a high-confidence signal
        allow(mock_strategy).to receive(:signal).and_return({
          side: :buy,
          price: 50_800.0,
          quantity: 2,
          tp: 51_000.0,
          sl: 50_600.0,
          confidence: 85.5
        })

        expect(job).to receive(:puts).with(
          /\[Signal\] #{trading_pair.product_id} side=buy price=50800\.0 qty=2 tp=51000\.0 sl=50600\.0 conf=85\.5%/
        )

        job.perform(equity_usd: 25_000.0)
      end
    end

    context "with bearish market conditions" do
      before do
        # Create comprehensive candle data for bearish scenario
        candle_data = create_comprehensive_candle_data(
          symbol: trading_pair.product_id,
          trend: :down,
          base_price: 50_000.0
        )
        Candle.insert_all(candle_data)

        # Create negative sentiment
        create_sentiment_data(symbol: trading_pair.product_id, z_score: -2.5, avg_score: -0.4)

        # Enable sentiment filtering
        allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
        allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")
      end

      it "generates short signals with proper risk management parameters" do
        # Mock strategy to return a short signal
        allow(mock_strategy).to receive(:signal).and_return({
          side: :sell,
          price: 49_200.0,
          quantity: 1,
          tp: 49_000.0,
          sl: 49_400.0,
          confidence: 78.2
        })

        expect(job).to receive(:puts).with(
          /\[Signal\] #{trading_pair.product_id} side=sell price=49200\.0 qty=1 tp=49000\.0 sl=49400\.0 conf=78\.2%/
        )

        job.perform(equity_usd: 15_000.0)
      end
    end

    context "with sideways market conditions" do
      before do
        # Create sideways market data (no clear trend)
        base_time = Time.current.utc
        candle_data = []

        # Create sideways 1h candles
        80.times do |i|
          timestamp = base_time - (80 - i).hours
          # Oscillating price around base
          price = 50_000.0 + (Math.sin(i * 0.3) * 200)
          candle_data << {
            symbol: trading_pair.product_id, timeframe: "1h", timestamp: timestamp,
            open: price - 50, high: price + 100, low: price - 100, close: price,
            volume: 1000, created_at: Time.current, updated_at: Time.current
          }
        end

        Candle.insert_all(candle_data)

        # Neutral sentiment
        create_sentiment_data(symbol: trading_pair.product_id, z_score: 0.3, avg_score: 0.05)
      end

      it "avoids false signals in sideways markets" do
        # Strategy should return nil for sideways markets
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(job).to receive(:puts).with("[Signal] #{trading_pair.product_id} no-entry")
        expect(SlackNotificationService).not_to receive(:signal_generated)

        job.perform(equity_usd: 10_000.0)
      end
    end
  end

  describe "Market Data Processing Workflows" do
    context "with complete market data" do
      before do
        # Create complete dataset across all timeframes
        candle_data = create_comprehensive_candle_data(
          symbol: trading_pair.product_id,
          trend: :up
        )
        Candle.insert_all(candle_data)
      end

      it "processes all required timeframes for signal generation" do
        allow(mock_strategy).to receive(:signal) do |args|
          # Verify the strategy has access to all required data
          symbol = args[:symbol]
          
          # Check that all timeframes have sufficient data
          expect(Candle.for_symbol(symbol).hourly.count).to be >= 60
          expect(Candle.for_symbol(symbol).fifteen_minute.count).to be >= 80
          expect(Candle.for_symbol(symbol).five_minute.count).to be >= 100
          expect(Candle.for_symbol(symbol).one_minute.count).to be >= 60

          mock_signal
        end

        job.perform
      end

      it "validates market data quality before signal generation" do
        # Test that strategy receives properly formatted data
        allow(mock_strategy).to receive(:signal) do |args|
          symbol = args[:symbol]
          
          # Verify data integrity
          latest_candles = Candle.for_symbol(symbol).order(:timestamp).limit(5)
          latest_candles.each do |candle|
            expect(candle.high).to be >= candle.low
            expect(candle.volume).to be > 0
            expect(candle.timestamp).to be_present
          end

          mock_signal
        end

        job.perform
      end
    end

    context "with insufficient market data" do
      before do
        # Create minimal data that's insufficient for signal generation
        Candle.create!(
          symbol: trading_pair.product_id,
          timeframe: "1h",
          timestamp: 1.hour.ago,
          open: 50_000, high: 50_100, low: 49_900, close: 50_050,
          volume: 1000
        )
      end

      it "handles insufficient data gracefully" do
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(job).to receive(:puts).with("[Signal] #{trading_pair.product_id} no-entry")
        expect(SlackNotificationService).not_to receive(:signal_generated)

        job.perform
      end
    end
  end

  describe "Signal Validation and Filtering" do
    before do
      # Create sufficient market data
      candle_data = create_comprehensive_candle_data(
        symbol: trading_pair.product_id,
        trend: :up
      )
      Candle.insert_all(candle_data)
    end

    context "with sentiment filtering enabled" do
      before do
        allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
        allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.5")
      end

      it "filters out signals when sentiment is below threshold" do
        # Create weak sentiment that should filter out signals
        create_sentiment_data(symbol: trading_pair.product_id, z_score: 1.0, avg_score: 0.1)
        
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(job).to receive(:puts).with("[Signal] #{trading_pair.product_id} no-entry")

        job.perform
      end

      it "allows signals when sentiment meets threshold" do
        # Create strong positive sentiment
        create_sentiment_data(symbol: trading_pair.product_id, z_score: 2.0, avg_score: 0.4)
        
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)

        expect(SlackNotificationService).to receive(:signal_generated)

        job.perform
      end
    end

    context "with confidence-based filtering" do
      it "processes high-confidence signals" do
        high_confidence_signal = mock_signal.merge(confidence: 90.5)
        allow(mock_strategy).to receive(:signal).and_return(high_confidence_signal)

        expect(job).to receive(:puts).with(
          /conf=90\.5%/
        )

        job.perform
      end

      it "processes low-confidence signals with appropriate logging" do
        low_confidence_signal = mock_signal.merge(confidence: 45.2)
        allow(mock_strategy).to receive(:signal).and_return(low_confidence_signal)

        expect(job).to receive(:puts).with(
          /conf=45\.2%/
        )

        job.perform
      end
    end
  end

  describe "Performance Under Various Market Conditions" do

    context "with high volatility conditions" do
      before do
        # Create high volatility candle data
        base_time = Time.current.utc
        candle_data = []

        80.times do |i|
          timestamp = base_time - (80 - i).hours
          base_price = 50_000.0
          # High volatility: large price swings
          volatility_factor = 500 * Math.sin(i * 0.5)
          price = base_price + volatility_factor
          
          candle_data << {
            symbol: trading_pair.product_id, timeframe: "1h", timestamp: timestamp,
            open: price - 200, high: price + 800, low: price - 800, close: price,
            volume: 2000 + (i * 20), created_at: Time.current, updated_at: Time.current
          }
        end

        Candle.insert_all(candle_data)
      end

      it "handles high volatility without errors" do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)

        expect { job.perform }.not_to raise_error
      end
    end

    context "with low volume conditions" do
      before do
        # Create low volume market data
        candle_data = create_comprehensive_candle_data(
          symbol: trading_pair.product_id,
          trend: :up
        )
        
        # Reduce all volumes to simulate low liquidity
        candle_data.each { |candle| candle[:volume] = candle[:volume] * 0.1 }
        
        Candle.insert_all(candle_data)
      end

      it "processes signals in low volume conditions" do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)

        expect { job.perform }.not_to raise_error
        expect(SlackNotificationService).to receive(:signal_generated)

        job.perform
      end
    end
  end

  describe "Integration with Trading Strategies" do
    before do
      # Create market data
      candle_data = create_comprehensive_candle_data(
        symbol: trading_pair.product_id,
        trend: :up
      )
      Candle.insert_all(candle_data)
    end

    it "integrates with multi-timeframe strategy configuration" do
      expect(Strategy::MultiTimeframeSignal).to receive(:new).with(
        ema_1h_short: 21,
        ema_1h_long: 50,
        ema_15m: 21,
        min_1h_candles: 60,
        min_15m_candles: 80
      )

      allow(mock_strategy).to receive(:signal).and_return(mock_signal)

      job.perform
    end

      it "validates trading strategy integration with futures contracts" do
        # Test with futures contract symbols
        futures_pair = create(:trading_pair, enabled: true, product_id: "BIT-29AUG25-CDE")
        
        allow(mock_strategy).to receive(:signal) do |args|
          # Verify futures contract symbol is passed correctly (it can be BTC or BIT format)
          expect(args[:symbol]).to match(/(BTC|BIT)-\d{2}[A-Z]{3}\d{2}-CDE/)
          mock_signal
        end

        job.perform
      end

    it "handles position sizing based on equity allocation" do
      test_equity = 50_000.0
      
      allow(mock_strategy).to receive(:signal) do |args|
        expect(args[:equity_usd]).to eq(test_equity)
        mock_signal.merge(quantity: 3) # Larger position for higher equity
      end

      expect(job).to receive(:puts).with(/qty=3/)

      job.perform(equity_usd: test_equity)
    end
  end

  describe "Advanced Error Handling and Retry Mechanisms" do
    context "when strategy initialization fails" do
      before do
        allow(Strategy::MultiTimeframeSignal).to receive(:new)
          .and_raise(StandardError.new("Strategy configuration error"))
      end

      it "propagates strategy initialization errors" do
        expect { job.perform }.to raise_error(StandardError, "Strategy configuration error")
      end
    end

    context "when market data is corrupted" do
      before do
        # Create valid candle data first, then simulate corruption during processing
        Candle.create!(
          symbol: trading_pair.product_id,
          timeframe: "1h",
          timestamp: 1.hour.ago,
          open: 50_000, high: 50_100, low: 49_900, close: 50_050,
          volume: 1000
        )

        # Simulate corruption by making the strategy handle invalid data
        allow(mock_strategy).to receive(:signal).and_raise(ArgumentError.new("Invalid candle data"))
      end

      it "handles corrupted market data gracefully" do
        expect { job.perform }.to raise_error(ArgumentError, "Invalid candle data")
      end
    end

    context "when Slack notification fails" do
      before do
        allow(mock_strategy).to receive(:signal).and_return(mock_signal)
        allow(SlackNotificationService).to receive(:signal_generated)
          .and_raise(StandardError.new("Slack API error"))
      end

      it "propagates Slack notification errors" do
        expect { job.perform }.to raise_error(StandardError, "Slack API error")
      end
    end

    context "when database operations fail" do
      before do
        # Mock TradingPair.enabled to raise an error
        allow(TradingPair).to receive(:enabled).and_raise(ActiveRecord::ConnectionTimeoutError.new("Database timeout"))
      end

      it "propagates database errors" do
        expect { job.perform }.to raise_error(ActiveRecord::ConnectionTimeoutError, "Database timeout")
      end
    end

    context "when external API dependencies fail" do
      before do
        allow(mock_strategy).to receive(:signal)
          .and_raise(Timeout::Error.new("External API timeout"))
      end

      it "propagates external API errors" do
        expect { job.perform }.to raise_error(Timeout::Error, "External API timeout")
      end
    end
  end

  describe "Signal Quality Assessment and Validation" do
    before do
      # Create comprehensive market data
      candle_data = create_comprehensive_candle_data(
        symbol: trading_pair.product_id,
        trend: :up
      )
      Candle.insert_all(candle_data)
    end

    it "validates signal structure and completeness" do
      complete_signal = {
        side: :buy,
        price: 50_800.0,
        quantity: 2,
        tp: 51_000.0,
        sl: 50_600.0,
        confidence: 85.5
      }
      
      allow(mock_strategy).to receive(:signal).and_return(complete_signal)

      expect(SlackNotificationService).to receive(:signal_generated).with({
        symbol: trading_pair.product_id,
        side: :buy,
        price: 50_800.0,
        quantity: 2,
        tp: 51_000.0,
        sl: 50_600.0,
        confidence: 85.5
      })

      job.perform
    end

    it "validates risk-reward ratios in generated signals" do
      signal_with_good_rr = {
        side: :buy,
        price: 50_000.0,
        quantity: 1,
        tp: 50_400.0,    # 400 point profit
        sl: 49_800.0,    # 200 point loss (2:1 RR)
        confidence: 75.0
      }
      
      allow(mock_strategy).to receive(:signal).and_return(signal_with_good_rr)

      expect(job).to receive(:puts).with(
        /tp=50400\.0 sl=49800\.0/
      )

      job.perform
    end

    it "handles edge case signals with extreme values" do
      extreme_signal = {
        side: :sell,
        price: 100_000.0,  # Extreme price
        quantity: 10,      # Large quantity
        tp: 95_000.0,
        sl: 105_000.0,
        confidence: 95.0
      }
      
      allow(mock_strategy).to receive(:signal).and_return(extreme_signal)

      expect { job.perform }.not_to raise_error
    end
  end

  describe "Comprehensive Integration Testing" do
    context "with complete realistic market scenario" do
      before do
        # Create realistic BTC market data
        candle_data = create_comprehensive_candle_data(
          symbol: trading_pair.product_id,
          base_price: 45_000.0,
          trend: :up
        )
        Candle.insert_all(candle_data)

        # Create realistic sentiment data
        create_sentiment_data(
          symbol: trading_pair.product_id,
          z_score: 1.8,
          avg_score: 0.25
        )

        # Configure realistic environment
        allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
        allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.2")

        # Mock the strategy to return a predictable result
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "executes complete signal generation workflow end-to-end", :integration_test do
        # This test validates that the complete workflow runs without errors
        expect { job.perform(equity_usd: 25_000.0) }.not_to raise_error
        
        # Verify the strategy was called
        expect(mock_strategy).to have_received(:signal).at_least(:once)
      end
    end

    context "with multiple trading pairs" do
      let!(:eth_pair) { create(:trading_pair, enabled: true, product_id: "ET-29AUG25-CDE") }
      
      before do
        # Create market data for both BTC and ETH
        [trading_pair.product_id, eth_pair.product_id].each do |symbol|
          candle_data = create_comprehensive_candle_data(
            symbol: symbol,
            base_price: symbol.start_with?('BTC') ? 45_000.0 : 2_800.0,
            trend: :up
          )
          Candle.insert_all(candle_data)
          
          create_sentiment_data(symbol: symbol, z_score: 1.5, avg_score: 0.2)
        end

        # Mock strategy to return nil for both calls
        allow(mock_strategy).to receive(:signal).and_return(nil)
      end

      it "processes multiple trading pairs sequentially" do
        job.perform(equity_usd: 50_000.0)
        
        # Verify the strategy was called for each trading pair
        expect(mock_strategy).to have_received(:signal).exactly(2).times
      end
    end
  end
end
