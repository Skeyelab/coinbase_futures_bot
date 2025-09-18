# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaperTradingJob, type: :job do
  let(:btc_pair) do
    TradingPair.find_or_create_by(product_id: "BTC-USD") do |tp|
      tp.base_currency = "BTC"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = true
    end
  end

  let(:eth_pair) do
    TradingPair.find_or_create_by(product_id: "ETH-USD") do |tp|
      tp.base_currency = "ETH"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = true
    end
  end

  let(:disabled_pair) do
    TradingPair.find_or_create_by(product_id: "DISABLED-USD") do |tp|
      tp.base_currency = "DISABLED"
      tp.quote_currency = "USD"
      tp.status = "online"
      tp.enabled = false
    end
  end

  let(:mock_rest) { instance_double("MarketData::CoinbaseRest") }
  let(:mock_simulator) { instance_double("PaperTrading::ExchangeSimulator") }
  let(:mock_strategy) { instance_double("Strategy::Pullback1h") }

  # Create sample candles for testing
  let(:sample_candles) do
    base_time = 1.day.ago
    (0...250).map do |i|
      Candle.new(
        symbol: "BTC-USD",
        timeframe: "1h",
        timestamp: base_time + i.hours,
        open: 50_000 + i * 10,
        high: 50_100 + i * 10,
        low: 49_900 + i * 10,
        close: 50_050 + i * 10,
        volume: 1000
      )
    end
  end

  let(:insufficient_candles) do
    base_time = 1.day.ago
    (0...150).map do |i|  # Less than 200 required
      Candle.new(
        symbol: "BTC-USD",
        timeframe: "1h",
        timestamp: base_time + i.hours,
        open: 50_000,
        high: 50_100,
        low: 49_900,
        close: 50_050,
        volume: 1000
      )
    end
  end

  before do
    # Mock external dependencies
    allow(MarketData::CoinbaseRest).to receive(:new).and_return(mock_rest)
    allow(mock_rest).to receive(:upsert_products)

    # Mock Rails logger to avoid nil logger issues
    allow(Rails.logger).to receive(:info)

    # Ensure test pairs exist
    btc_pair
    eth_pair
    disabled_pair
  end

  describe "#perform" do
    context "with successful execution" do
      it "processes all enabled trading pairs" do
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)

        # Mock simulator methods
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        # Mock strategy signal
        signal = {
          side: :buy,
          price: 50_000.0,
          quantity: 0.1,
          tp: 51_000.0,
          sl: 49_000.0
        }
        allow(mock_strategy).to receive(:signal).and_return(signal)

        expect { described_class.perform_now }.not_to raise_error

        expect(mock_rest).to have_received(:upsert_products).once
        expect(PaperTrading::ExchangeSimulator).to have_received(:new).at_least(2).times
        expect(Strategy::Pullback1h).to have_received(:new).at_least(2).times
      end

      it "logs paper trading results for each pair" do
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)

        allow(mock_simulator).to receive(:equity_usd).and_return(10_500.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({1 => double("order")})
        allow(mock_simulator).to receive(:fills).and_return([{order_id: 1, price: 50_000}])
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect(Rails.logger).to receive(:info).with(/\[Paper\] BTC-USD equity_usd=10500\.0 orders=1 fills=1/)
        expect(Rails.logger).to receive(:info).with(/\[Paper\] ETH-USD equity_usd=10500\.0 orders=1 fills=1/)

        described_class.perform_now
      end

      it "only processes enabled trading pairs" do
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)

        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])
        allow(mock_strategy).to receive(:signal).and_return(nil)

        described_class.perform_now

        # Should only process enabled pairs (BTC-USD and ETH-USD), not DISABLED-USD
        expect(Rails.logger).to have_received(:info).with(/\[Paper\] BTC-USD/).once
        expect(Rails.logger).to have_received(:info).with(/\[Paper\] ETH-USD/).once
        expect(Rails.logger).not_to have_received(:info).with(/\[Paper\] DISABLED-USD/)
      end
    end

    context "with no trading pairs" do
      it "handles missing trading pairs gracefully" do
        # Remove all trading pairs
        TradingPair.destroy_all

        expect { described_class.perform_now }.not_to raise_error
        expect(mock_rest).to have_received(:upsert_products).once
      end
    end
  end

  describe "#run_for_pair" do
    let(:job) { described_class.new }

    context "with sufficient candle data" do
      it "creates simulator with correct starting equity" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(mock_strategy).to receive(:signal).and_return(nil)
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(PaperTrading::ExchangeSimulator).to have_received(:new).with(starting_equity_usd: 10_000.0)
      end

      it "uses custom starting equity from environment" do
        allow(ENV).to receive(:[]).with("PAPER_EQUITY_USD").and_return("25000")
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(mock_strategy).to receive(:signal).and_return(nil)
        allow(mock_simulator).to receive(:equity_usd).and_return(25_000.0)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(PaperTrading::ExchangeSimulator).to have_received(:new).with(starting_equity_usd: 25_000.0)
      end

      it "generates signal and places order when signal is valid" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)

        signal = {
          side: :buy,
          price: 50_000.0,
          quantity: 0.1,
          tp: 51_000.0,
          sl: 49_000.0
        }
        allow(mock_strategy).to receive(:signal).and_return(signal)
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(mock_strategy).to have_received(:signal).with(
          candles: sample_candles,
          symbol: "BTC-USD",
          equity_usd: 10_000.0
        )
        expect(mock_simulator).to have_received(:place_limit).with(
          symbol: "BTC-USD",
          side: :buy,
          price: 50_000.0,
          quantity: 0.1,
          tp: 51_000.0,
          sl: 49_000.0
        )
      end

      it "does not place order when signal is nil" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(mock_strategy).to receive(:signal).and_return(nil)
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(mock_simulator).not_to have_received(:place_limit)
      end

      it "does not place order when quantity is zero or negative" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)

        signal = {
          side: :buy,
          price: 50_000.0,
          quantity: 0.0,  # Zero quantity
          tp: 51_000.0,
          sl: 49_000.0
        }
        allow(mock_strategy).to receive(:signal).and_return(signal)
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:place_limit)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(mock_simulator).not_to have_received(:place_limit)
      end

      it "processes next candle for simulation" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(mock_strategy).to receive(:signal).and_return(nil)
        allow(mock_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(mock_simulator).to receive(:on_candle)
        allow(mock_simulator).to receive(:orders).and_return({})
        allow(mock_simulator).to receive(:fills).and_return([])

        job.send(:run_for_pair, btc_pair)

        expect(mock_simulator).to have_received(:on_candle) do |candle|
          expect(candle.symbol).to eq(sample_candles.last.symbol)
          expect(candle.timeframe).to eq(sample_candles.last.timeframe)
          expect(candle.timestamp).to eq(sample_candles.last.timestamp + 1.hour)
          expect(candle.open).to eq(sample_candles.last.close)
        end
      end
    end

    context "with insufficient candle data" do
      it "returns early when less than 200 candles available" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(insufficient_candles)
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)

        # The job creates simulator and strategy but returns early, so no signal call
        expect(mock_strategy).not_to receive(:signal)
        expect(mock_simulator).not_to receive(:place_limit)
        expect(mock_simulator).not_to receive(:on_candle)
        expect(Rails.logger).not_to receive(:info).with(/\[Paper\] BTC-USD/)

        job.send(:run_for_pair, btc_pair)
      end

      it "returns early when no candles available" do
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return([])
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(mock_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)

        # The job creates simulator and strategy but returns early, so no signal call
        expect(mock_strategy).not_to receive(:signal)
        expect(mock_simulator).not_to receive(:place_limit)
        expect(mock_simulator).not_to receive(:on_candle)
        expect(Rails.logger).not_to receive(:info).with(/\[Paper\] BTC-USD/)

        job.send(:run_for_pair, btc_pair)
      end
    end
  end

  describe "#starting_equity_usd" do
    let(:job) { described_class.new }

    it "returns default value when environment variable not set" do
      allow(ENV).to receive(:[]).with("PAPER_EQUITY_USD").and_return(nil)

      expect(job.send(:starting_equity_usd)).to eq(10_000.0)
    end

    it "returns environment variable value when set" do
      allow(ENV).to receive(:[]).with("PAPER_EQUITY_USD").and_return("50000")

      expect(job.send(:starting_equity_usd)).to eq(50_000.0)
    end

    it "handles string values correctly" do
      allow(ENV).to receive(:[]).with("PAPER_EQUITY_USD").and_return("25000.50")

      expect(job.send(:starting_equity_usd)).to eq(25_000.50)
    end

    it "handles invalid values gracefully" do
      allow(ENV).to receive(:[]).with("PAPER_EQUITY_USD").and_return("invalid")

      expect(job.send(:starting_equity_usd)).to eq(0.0)
    end
  end

  describe "#next_hour_candle_stub" do
    let(:job) { described_class.new }
    let(:last_candle) do
      Candle.new(
        symbol: "BTC-USD",
        timeframe: "1h",
        timestamp: Time.parse("2025-01-15 10:00:00 UTC"),
        open: 50_000.0,
        high: 50_200.0,
        low: 49_800.0,
        close: 50_100.0,
        volume: 1500.0
      )
    end

    it "creates next hour candle with correct timestamp" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      expect(next_candle.timestamp).to eq(Time.parse("2025-01-15 11:00:00 UTC"))
    end

    it "preserves symbol and timeframe" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      expect(next_candle.symbol).to eq("BTC-USD")
      expect(next_candle.timeframe).to eq("1h")
    end

    it "sets open price to last candle's close price" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      expect(next_candle.open).to eq(50_100.0)
    end

    it "calculates realistic price movements" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      # High should be close * 1.002
      expect(next_candle.high).to be_within(0.01).of(50_100.0 * 1.002)
      # Low should be close * 0.998
      expect(next_candle.low).to be_within(0.01).of(50_100.0 * 0.998)
      # Close should be close * 1.001
      expect(next_candle.close).to be_within(0.01).of(50_100.0 * 1.001)
    end

    it "preserves volume from last candle" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      expect(next_candle.volume).to eq(1500.0)
    end

    it "maintains OHLC relationships" do
      next_candle = job.send(:next_hour_candle_stub, last_candle)

      # High should be >= open, close, low
      expect(next_candle.high).to be >= next_candle.open
      expect(next_candle.high).to be >= next_candle.close
      expect(next_candle.high).to be >= next_candle.low

      # Low should be <= open, close, high
      expect(next_candle.low).to be <= next_candle.open
      expect(next_candle.low).to be <= next_candle.close
      expect(next_candle.low).to be <= next_candle.high
    end
  end

  describe "integration scenarios" do
    context "with realistic trading simulation" do
      it "executes complete paper trading workflow" do
        # Setup realistic candles
        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)

        # Use real simulator and strategy instances for integration test
        real_simulator = PaperTrading::ExchangeSimulator.new(starting_equity_usd: 10_000.0)
        real_strategy = Strategy::Pullback1h.new

        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(real_simulator)
        allow(Strategy::Pullback1h).to receive(:new).and_return(real_strategy)

        # Execute the job
        expect { described_class.perform_now }.not_to raise_error

        # Verify simulator state changes
        expect(real_simulator.equity_usd).to be_a(Float)
        expect(real_simulator.orders).to be_a(Hash)
        expect(real_simulator.fills).to be_a(Array)
      end

      it "handles multiple trading pairs with different signals" do
        btc_candles = sample_candles.map { |c| c.dup.tap { |candle| candle.symbol = "BTC-USD" } }
        eth_candles = sample_candles.map { |c| c.dup.tap { |candle| candle.symbol = "ETH-USD" } }

        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last) do |symbol|
          case symbol
          when "BTC-USD"
            btc_candles
          when "ETH-USD"
            eth_candles
          else
            []
          end
        end

        # Use real instances for integration testing
        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_call_original
        allow(Strategy::Pullback1h).to receive(:new).and_call_original

        expect { described_class.perform_now }.not_to raise_error
      end
    end

    context "with risk management scenarios" do
      it "handles high volatility scenarios" do
        # Create high volatility candles
        volatile_candles = (0...250).map do |i|
          base_price = 50_000
          volatility = 0.05  # 5% volatility

          Candle.new(
            symbol: "BTC-USD",
            timeframe: "1h",
            timestamp: 1.day.ago + i.hours,
            open: base_price * (1 + rand(-volatility..volatility)),
            high: base_price * (1 + rand(0..volatility * 2)),
            low: base_price * (1 + rand(-volatility * 2..0)),
            close: base_price * (1 + rand(-volatility..volatility)),
            volume: 1000
          )
        end

        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(volatile_candles)

        expect { described_class.perform_now }.not_to raise_error
      end

      it "handles low liquidity scenarios" do
        # Create low volume candles
        low_volume_candles = sample_candles.map do |candle|
          candle.dup.tap { |c| c.volume = 10 }  # Very low volume
        end

        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(low_volume_candles)

        expect { described_class.perform_now }.not_to raise_error
      end
    end

    context "with performance scenarios" do
      it "handles large datasets efficiently" do
        # Create large dataset
        large_candle_set = (0...1000).map do |i|
          Candle.new(
            symbol: "BTC-USD",
            timeframe: "1h",
            timestamp: 42.days.ago + i.hours,
            open: 50_000 + i,
            high: 50_100 + i,
            low: 49_900 + i,
            close: 50_050 + i,
            volume: 1000
          )
        end

        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(large_candle_set)

        start_time = Time.current
        expect { described_class.perform_now }.not_to raise_error
        execution_time = Time.current - start_time

        # Should complete within reasonable time (adjust threshold as needed)
        expect(execution_time).to be < 30.seconds
      end

      it "handles memory efficiently with large order books" do
        # Mock simulator with many orders
        large_simulator = instance_double("PaperTrading::ExchangeSimulator")
        large_orders = (1..1000).to_h { |i| [i, double("order_#{i}")] }
        large_fills = (1..500).map { |i| {order_id: i, price: 50_000} }

        allow(PaperTrading::ExchangeSimulator).to receive(:new).and_return(large_simulator)
        allow(large_simulator).to receive(:equity_usd).and_return(10_000.0)
        allow(large_simulator).to receive(:place_limit)
        allow(large_simulator).to receive(:on_candle)
        allow(large_simulator).to receive(:orders).and_return(large_orders)
        allow(large_simulator).to receive(:fills).and_return(large_fills)

        allow(Candle).to receive_message_chain(:for_symbol, :hourly, :order, :last).and_return(sample_candles)
        allow(Strategy::Pullback1h).to receive(:new).and_return(mock_strategy)
        allow(mock_strategy).to receive(:signal).and_return(nil)

        expect { described_class.perform_now }.not_to raise_error
      end
    end
  end
end
