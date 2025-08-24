require "rails_helper"

RSpec.describe Strategy::MultiTimeframeSignal, type: :service do
  before do
    allow(ENV).to receive(:fetch).and_call_original
  end

  it "respects sentiment gate when enabled and z below threshold (no entry)" do
    # Seed minimum candles using bulk insert for speed
    candle_data = []

    # Pre-calculate all timestamps to ensure proper chronological order
    # Use reverse order so oldest timestamps come first
    timestamps_1h = (0...120).map { |i| (120 - i).hours.ago }
    timestamps_15m = (0...120).map { |i| ((120 - i) * 15).minutes.ago }
    timestamps_5m = (0...100).map { |i| ((100 - i) * 5).minutes.ago }
    timestamps_1m = (0...60).map { |i| (60 - i).minutes.ago }

    # 1h candles
    (0...120).each do |i|
      candle_data << {
        symbol: "BTC-USD-PERP", timeframe: "1h", timestamp: timestamps_1h[i],
        open: 100, high: 100, low: 100, close: 100, volume: 1,
        created_at: Time.current, updated_at: Time.current
      }
    end

    # 15m candles
    (0...120).each do |i|
      candle_data << {
        symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
        open: 100, high: 100, low: 100, close: 100, volume: 1,
        created_at: Time.current, updated_at: Time.current
      }
    end

    # 5m candles
    (0...100).each do |i|
      candle_data << {
        symbol: "BTC-USD-PERP", timeframe: "5m", timestamp: timestamps_5m[i],
        open: 100, high: 100, low: 100, close: 100, volume: 1,
        created_at: Time.current, updated_at: Time.current
      }
    end

    # 1m candles
    (0...60).each do |i|
      candle_data << {
        symbol: "BTC-USD-PERP", timeframe: "1m", timestamp: timestamps_1m[i],
        open: 100, high: 100, low: 100, close: 100, volume: 1,
        created_at: Time.current, updated_at: Time.current
      }
    end

    # Bulk insert all candles at once, ensuring proper order
    Candle.insert_all!(candle_data)

    # Verify we have the right number of candles
    expect(Candle.count).to eq(400) # 120 + 120 + 100 + 60

    # Put price slightly above EMA to trigger a hypothetical long setup
    Candle.last.update!(close: 101)

    # Seed sentiment aggregate with z below threshold
    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: Time.now.utc.change(sec: 0), avg_score: 0.1, z_score: 0.5)

    allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
    allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")

    strat = described_class.new(ema_1h_short: 1, ema_1h_long: 1, ema_15m: 1, ema_5m: 1, ema_1m: 1, min_1h_candles: 80, min_15m_candles: 120, min_5m_candles: 100, min_1m_candles: 60)
    expect(strat.signal(symbol: "BTC-USD-PERP")).to be_nil
  end

  it "allows entry when z above threshold and sign matches side" do
    # Create candles using bulk insert for much better performance
    candle_data = []
    base_price = 100.0

    # Pre-calculate all timestamps to ensure proper chronological order
    # Use reverse order so oldest timestamps come first
    timestamps_1h = (0...80).map { |i| (80 - i).hours.ago }
    timestamps_15m = (0...120).map { |i| ((120 - i) * 15).minutes.ago }
    timestamps_5m = (0...100).map { |i| ((100 - i) * 5).minutes.ago }
    timestamps_1m = (0...60).map { |i| (60 - i).minutes.ago }

    # Create 1h candles with a clear uptrend (EMA short > EMA long)
    (0...80).each do |i|
      price = base_price + (i * 0.5) # 0.5% increase per hour
      candle_data << {
        symbol: "BTC-USD-PERP", timeframe: "1h", timestamp: timestamps_1h[i],
        open: price, high: price + 1, low: price - 1, close: price, volume: 1,
        created_at: Time.current, updated_at: Time.current
      }
    end

    # Create 15m candles with pullback and reclaim pattern
    (0...120).each do |i|
      if i < 100
        # Most candles above EMA (uptrend)
        price = base_price + 2.0 + (i * 0.1)
        candle_data << {
          symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
          open: price, high: price + 0.5, low: price - 0.5, close: price, volume: 1,
          created_at: Time.current, updated_at: Time.current
        }
      else
        # Last few candles show pullback to EMA then reclaim above
        case i
        when 100
          # Pullback candle - touches EMA
          price = base_price + 2.0 + (i * 0.1)
          candle_data << {
            symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
            open: price + 0.5, high: price + 0.5, low: price - 0.1, close: price - 0.2, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        when 101
          # Reclaim candle - closes above EMA
          price = base_price + 2.0 + (i * 0.1)
          candle_data << {
            symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
            open: price - 0.2, high: price + 0.3, low: price - 0.2, close: price + 0.1, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        when 102
          # Final candle - well above EMA
          price = base_price + 2.0 + (i * 0.1)
          candle_data << {
            symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
            open: price, high: price + 0.3, low: price - 0.2, close: price + 0.2, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        when 115
          # This candle should touch the EMA
          candle_data << {
            symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
            open: 113.5, high: 113.8, low: 113.0, close: 113.2, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        else
          # Other recent candles above EMA
          price = base_price + 2.0 + (i * 0.1)
          candle_data << {
            symbol: "BTC-USD-PERP", timeframe: "15m", timestamp: timestamps_15m[i],
            open: price, high: price + 0.3, low: price - 0.2, close: price + 0.2, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
    end

    # Create 5m candles with similar pattern
    (0...100).each do |i|
      price = base_price + 2.0 + (i * 0.05)
      candle_data << if i < 80
        # Most candles above EMA (uptrend)
        {
          symbol: "BTC-USD-PERP", timeframe: "5m", timestamp: timestamps_5m[i],
          open: price, high: price + 0.3, low: price - 0.3, close: price, volume: 1,
          created_at: Time.current, updated_at: Time.current
        }
      else
        # Last few candles show pullback to EMA then reclaim above
        case i
        when 80
          # Pullback candle - touches EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "5m", timestamp: timestamps_5m[i],
            open: price + 0.3, high: price + 0.3, low: price - 0.1, close: price - 0.1, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        when 81
          # Reclaim candle - closes above EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "5m", timestamp: timestamps_5m[i],
            open: price - 0.1, high: price + 0.2, low: price - 0.1, close: price + 0.1, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        else
          # Final candles - well above EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "5m", timestamp: timestamps_5m[i],
            open: price, high: price + 0.2, low: price - 0.1, close: price + 0.1, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
    end

    # Create 1m candles with similar pattern
    (0...60).each do |i|
      price = base_price + 2.0 + (i * 0.01)
      candle_data << if i < 50
        # Most candles above EMA (uptrend)
        {
          symbol: "BTC-USD-PERP", timeframe: "1m", timestamp: timestamps_1m[i],
          open: price, high: price + 0.1, low: price - 0.1, close: price, volume: 1,
          created_at: Time.current, updated_at: Time.current
        }
      else
        # Last few candles show pullback to EMA then reclaim above
        case i
        when 50
          # Pullback candle - touches EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "1m", timestamp: timestamps_1m[i],
            open: price + 0.1, high: price + 0.1, low: price - 0.05, close: price - 0.05, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        when 51
          # Reclaim candle - closes above EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "1m", timestamp: timestamps_1m[i],
            open: price - 0.05, high: price + 0.1, low: price - 0.05, close: price + 0.05, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        else
          # Final candles - well above EMA
          {
            symbol: "BTC-USD-PERP", timeframe: "1m", timestamp: timestamps_1m[i],
            open: price, high: price + 0.1, low: price - 0.05, close: price + 0.05, volume: 1,
            created_at: Time.current, updated_at: Time.current
          }
        end
      end
    end

    # Bulk insert all candles at once - MUCH faster than individual creates
    Candle.insert_all!(candle_data)

    # Verify we have the right number of candles
    expect(Candle.count).to eq(360) # 80 + 120 + 100 + 60

    SentimentAggregate.create!(symbol: "BTC-USD-PERP", window: "15m", window_end_at: Time.now.utc.change(sec: 0), avg_score: 0.2, z_score: 2.0)

    allow(ENV).to receive(:fetch).with("SENTIMENT_ENABLE", anything).and_return("true")
    allow(ENV).to receive(:fetch).with("SENTIMENT_Z_THRESHOLD", anything).and_return("1.0")

    strat = described_class.new(ema_1h_short: 12, ema_1h_long: 26, ema_15m: 21, ema_5m: 13, ema_1m: 8, min_1h_candles: 80, min_15m_candles: 120, min_5m_candles: 100, min_1m_candles: 60)

    order = strat.signal(symbol: "BTC-USD-PERP")

    # Debug: Check what candles we actually have
    puts "\n🔍 Debug: Candle counts by timeframe:"
    puts "  1h: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "1h").count}"
    puts "  15m: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "15m").count}"
    puts "  5m: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "5m").count}"
    puts "  1m: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "1m").count}"

    puts "\n🔍 Debug: Latest candle timestamps:"
    puts "  1h latest: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "1h").order(:timestamp).last&.timestamp}"
    puts "  15m latest: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "15m").order(:timestamp).last&.timestamp}"
    puts "  5m latest: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "5m").order(:timestamp).last&.timestamp}"
    puts "  1m latest: #{Candle.where(symbol: "BTC-USD-PERP", timeframe: "1m").order(:timestamp).last&.timestamp}"

    expect(order).to be_present
    expect(order[:side]).to eq(:buy)
  end

  describe "upcoming month contract functionality" do
    let(:current_date) { Date.new(2025, 8, 15) } # Mid-August 2025

    before do
      # Mock Date.current to return a fixed date for testing
      allow(Date).to receive(:current).and_return(current_date)
    end

    let!(:btc_current_month) do
      TradingPair.create!(
        product_id: "BIT-29AUG25-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2025, 8, 29),
        contract_type: "CDE",
        enabled: true
      )
    end

    let!(:btc_upcoming_month) do
      TradingPair.create!(
        product_id: "BIT-26SEP25-CDE",
        base_currency: "BTC",
        quote_currency: "USD",
        expiration_date: Date.new(2025, 9, 26),
        contract_type: "CDE",
        enabled: true
      )
    end

    describe "#resolve_trading_symbol" do
      let(:strategy) { described_class.new }

      context "when current month contract is available and tradeable" do
        it "resolves BTC to current month contract" do
          result = strategy.send(:resolve_trading_symbol, "BTC")
          expect(result).to eq("BIT-29AUG25-CDE")
        end

        it "resolves BTC-USD to current month contract" do
          result = strategy.send(:resolve_trading_symbol, "BTC-USD")
          expect(result).to eq("BIT-29AUG25-CDE")
        end

        it "logs current month contract usage" do
          expect(Rails.logger).to receive(:info).with(/Using current month contract BIT-29AUG25-CDE for asset BTC/)
          strategy.send(:resolve_trading_symbol, "BTC")
        end
      end

      context "when current month contract is not tradeable" do
        before do
          # Mock Date.current to make current month contracts expire tomorrow
          allow(Date).to receive(:current).and_return(Date.new(2025, 8, 28))
        end

        it "falls back to upcoming month contract for BTC" do
          result = strategy.send(:resolve_trading_symbol, "BTC")
          expect(result).to eq("BIT-26SEP25-CDE")
        end

        it "logs upcoming month contract usage" do
          expect(Rails.logger).to receive(:info).with(/Using upcoming month contract BIT-26SEP25-CDE for asset BTC/)
          strategy.send(:resolve_trading_symbol, "BTC")
        end
      end

      context "when no contracts are available" do
        it "returns nil for supported assets with no contracts" do
          # Mock the contract manager to return nil
          mock_contract_manager = instance_double(MarketData::FuturesContractManager)
          allow(MarketData::FuturesContractManager).to receive(:new).and_return(mock_contract_manager)
          allow(mock_contract_manager).to receive(:best_available_contract).with("BTC").and_return(nil)

          expect(Rails.logger).to receive(:warn).with(/No suitable contract found for asset BTC/)
          result = strategy.send(:resolve_trading_symbol, "BTC")
          expect(result).to be_nil
        end
      end

      context "when given specific contract symbols" do
        it "returns the contract symbol as-is for current month contracts" do
          result = strategy.send(:resolve_trading_symbol, "BIT-29AUG25-CDE")
          expect(result).to eq("BIT-29AUG25-CDE")
        end

        it "returns the contract symbol as-is for upcoming month contracts" do
          result = strategy.send(:resolve_trading_symbol, "BIT-26SEP25-CDE")
          expect(result).to eq("BIT-26SEP25-CDE")
        end
      end

      context "when given unsupported symbols" do
        it "returns the symbol as-is for non-futures assets" do
          result = strategy.send(:resolve_trading_symbol, "DOGE-USD")
          expect(result).to eq("DOGE-USD")
        end
      end
    end

    describe "#extract_asset_from_symbol" do
      let(:strategy) { described_class.new }

      it "extracts BTC from BTC-USD" do
        result = strategy.send(:extract_asset_from_symbol, "BTC-USD")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from ETH-USD" do
        result = strategy.send(:extract_asset_from_symbol, "ETH-USD")
        expect(result).to eq("ETH")
      end

      it "extracts BTC from BTC" do
        result = strategy.send(:extract_asset_from_symbol, "BTC")
        expect(result).to eq("BTC")
      end

      it "extracts BTC from current month BTC contract" do
        result = strategy.send(:extract_asset_from_symbol, "BIT-29AUG25-CDE")
        expect(result).to eq("BTC")
      end

      it "extracts ETH from current month ETH contract" do
        result = strategy.send(:extract_asset_from_symbol, "ET-29AUG25-CDE")
        expect(result).to eq("ETH")
      end

      it "returns nil for unsupported symbols" do
        result = strategy.send(:extract_asset_from_symbol, "DOGE-USD")
        expect(result).to be_nil
      end
    end

    describe "contract rollover scenarios" do
      let(:strategy) { described_class.new }

      context "when contracts expire tomorrow (not tradeable)" do
        before do
          # Set date to make current month contracts expire tomorrow (not tradeable)
          allow(Date).to receive(:current).and_return(Date.new(2025, 8, 28))
        end

        it "prioritizes upcoming month contracts for new signals" do
          # Current month expires tomorrow so not tradeable, use upcoming month
          result = strategy.send(:resolve_trading_symbol, "BTC")
          expect(result).to eq("BIT-26SEP25-CDE")
        end
      end

      context "when contracts expire today" do
        before do
          # Set date to expiration day
          allow(Date).to receive(:current).and_return(Date.new(2025, 8, 29))
        end

        it "uses upcoming month contracts only" do
          result = strategy.send(:resolve_trading_symbol, "BTC")
          expect(result).to eq("BIT-26SEP25-CDE")
        end
      end
    end

    describe "error handling in contract resolution" do
      let(:strategy) { described_class.new }

      context "when contract manager fails" do
        before do
          allow_any_instance_of(MarketData::FuturesContractManager).to receive(:best_available_contract).and_raise(StandardError, "Contract manager error")
        end

        it "raises the error (no error handling implemented)" do
          expect {
            strategy.send(:resolve_trading_symbol, "BTC")
          }.to raise_error(StandardError, "Contract manager error")
        end
      end
    end
  end
end
