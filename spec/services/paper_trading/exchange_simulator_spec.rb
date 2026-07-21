# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaperTrading::ExchangeSimulator, type: :service do
  # slippage: 0 keeps the fee-mechanics assertions exact; slippage behavior
  # has its own describe block below.
  let(:simulator) { described_class.new(starting_equity_usd: 10_000.0, slippage: 0.0) }
  let(:candle) { double("Candle", close: 50_000.0, high: 51_000.0, low: 49_000.0) }

  describe "fee_rate" do
    it "accepts fee_rate as the canonical fee kwarg (taker pricing)" do
      sim = described_class.new(starting_equity_usd: 1_000.0, fee_rate: 0.002, slippage: 0.0)
      sim.place_limit(symbol: "TEST", side: :buy, price: 100.0, quantity: 1.0)
      sim.on_candle(double("Candle", close: 100.0, high: 100.0, low: 100.0))

      expect(sim.equity_usd).to eq(1_000.0 - 100.0 * 1.0 * 0.002)
    end

    it "still honors the legacy maker_fee kwarg" do
      sim = described_class.new(starting_equity_usd: 1_000.0, maker_fee: 0.001, slippage: 0.0)
      sim.place_limit(symbol: "TEST", side: :buy, price: 100.0, quantity: 1.0)
      sim.on_candle(double("Candle", close: 100.0, high: 100.0, low: 100.0))

      expect(sim.equity_usd).to eq(1_000.0 - 100.0 * 1.0 * 0.001)
    end
  end

  describe "slippage" do
    let(:sim) { described_class.new(starting_equity_usd: 10_000.0, fee_rate: 0.0, slippage: 0.001) }

    it "fills buy entries at an adversely slipped price" do
      sim.place_limit(symbol: "TEST", side: :buy, price: 100.0, quantity: 1.0)
      sim.on_candle(double("Candle", close: 100.0, high: 101.0, low: 99.0))

      expect(sim.fills.last[:price]).to be_within(1e-9).of(100.0 * 1.001)
    end

    it "fills sell entries at an adversely slipped price" do
      sim.place_limit(symbol: "TEST", side: :sell, price: 100.0, quantity: 1.0)
      sim.on_candle(double("Candle", close: 100.0, high: 101.0, low: 99.0))

      expect(sim.fills.last[:price]).to be_within(1e-9).of(100.0 * 0.999)
    end

    it "realizes long PnL from the slipped entry and slipped exit prices" do
      sim.place_limit(symbol: "TEST", side: :buy, price: 100.0, quantity: 1.0, tp: 110.0)
      sim.on_candle(double("Candle", close: 100.0, high: 101.0, low: 99.0))
      sim.on_candle(double("Candle", close: 111.0, high: 112.0, low: 109.0))

      entry = 100.0 * 1.001
      exit_price = 110.0 * 0.999
      expect(sim.equity_usd).to be_within(1e-9).of(10_000.0 + (exit_price - entry) * 1.0)
    end
  end

  describe "#initialize" do
    it "sets initial equity" do
      expect(simulator.equity_usd).to eq(10_000.0)
    end

    it "initializes empty orders and fills" do
      expect(simulator.orders).to be_empty
      expect(simulator.fills).to be_empty
    end
  end

  describe "#place_limit" do
    it "creates a buy limit order" do
      order_id = simulator.place_limit(symbol: "BTC-USD", side: :buy, price: 45_000.0, quantity: 0.1)

      expect(order_id).to be_a(Integer)
      expect(simulator.orders[order_id]).to be_present
      order = simulator.orders[order_id]
      expect(order.symbol).to eq("BTC-USD")
      expect(order.side).to eq(:buy)
      expect(order.price).to eq(45_000.0)
      expect(order.quantity).to eq(0.1)
      expect(order.status).to eq(:open)
    end

    it "creates a sell limit order with TP/SL" do
      order_id = simulator.place_limit(
        symbol: "BTC-USD",
        side: :sell,
        price: 55_000.0,
        quantity: 0.05,
        tp: 60_000.0,
        sl: 50_000.0
      )

      order = simulator.orders[order_id]
      expect(order.side).to eq(:sell)
      expect(order.tp).to eq(60_000.0)
      expect(order.sl).to eq(50_000.0)
    end
  end

  describe "#cancel" do
    it "cancels an open order" do
      order_id = simulator.place_limit(symbol: "BTC-USD", side: :buy, price: 45_000.0, quantity: 0.1)
      simulator.cancel(order_id)

      expect(simulator.orders[order_id].status).to eq(:canceled)
    end

    it "does not cancel a non-existent order" do
      expect { simulator.cancel(999) }.not_to raise_error
    end
  end

  describe "#on_candle" do
    context "with buy orders" do
      it "fills buy order when candle low touches order price" do
        order_id = simulator.place_limit(symbol: "BTC-USD", side: :buy, price: 49_500.0, quantity: 0.1)

        # Create candle where low is below order price
        low_candle = double("Candle", close: 49_000.0, high: 50_000.0, low: 49_000.0)
        simulator.on_candle(low_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:filled)
        expect(simulator.fills.size).to eq(1)
        expect(simulator.equity_usd).to be < 10_000.0 # Fee deducted
      end

      it "does not fill buy order when candle low is above order price" do
        order_id = simulator.place_limit(symbol: "BTC-USD", side: :buy, price: 48_000.0, quantity: 0.1)

        # Create candle where low is above order price
        high_candle = double("Candle", close: 50_000.0, high: 51_000.0, low: 49_000.0)
        simulator.on_candle(high_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:open)
        expect(simulator.fills).to be_empty
      end
    end

    context "with sell orders" do
      it "fills sell order when candle high touches order price" do
        order_id = simulator.place_limit(symbol: "BTC-USD", side: :sell, price: 50_500.0, quantity: 0.1)

        # Create candle where high is above order price
        high_candle = double("Candle", close: 51_000.0, high: 52_000.0, low: 50_000.0)
        simulator.on_candle(high_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:filled)
        expect(simulator.fills.size).to eq(1)
      end
    end

    context "with TP/SL orders" do
      it "closes long position on take profit with correct P&L" do
        simulator.equity_usd
        order_id = simulator.place_limit(
          symbol: "BTC-USD",
          side: :buy,
          price: 49_000.0,
          quantity: 0.1,
          tp: 51_000.0
        )

        # Fill the order first (entry fee deducted)
        fill_candle = double("Candle", close: 49_000.0, high: 49_500.0, low: 48_500.0)
        simulator.on_candle(fill_candle)
        equity_after_fill = simulator.equity_usd

        # Then trigger TP
        tp_candle = double("Candle", close: 51_000.0, high: 52_000.0, low: 50_500.0)
        simulator.on_candle(tp_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:closed)

        # Calculate expected P&L: (51_000 - 49_000) * 0.1 - exit_fee = 200 - 2.55 = 197.45
        expected_pnl = (51_000.0 - 49_000.0) * 0.1 - (51_000.0 * 0.1 * 0.0005)
        expect(simulator.equity_usd).to eq(equity_after_fill + expected_pnl)
      end

      it "closes long position on stop loss with correct P&L" do
        simulator.equity_usd
        order_id = simulator.place_limit(
          symbol: "BTC-USD",
          side: :buy,
          price: 50_000.0,
          quantity: 0.1,
          sl: 48_000.0
        )

        # Fill the order first
        fill_candle = double("Candle", close: 50_000.0, high: 50_500.0, low: 49_500.0)
        simulator.on_candle(fill_candle)
        equity_after_fill = simulator.equity_usd

        # Then trigger SL
        sl_candle = double("Candle", close: 48_000.0, high: 49_000.0, low: 47_500.0)
        simulator.on_candle(sl_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:closed)

        # Calculate expected P&L: (48_000 - 50_000) * 0.1 - exit_fee = -200 - 2.4 = -202.4
        expected_pnl = (48_000.0 - 50_000.0) * 0.1 - (48_000.0 * 0.1 * 0.0005)
        expect(simulator.equity_usd).to eq(equity_after_fill + expected_pnl)
      end

      it "closes short position on take profit with correct P&L" do
        simulator.equity_usd
        order_id = simulator.place_limit(
          symbol: "BTC-USD",
          side: :sell,
          price: 51_000.0,
          quantity: 0.1,
          tp: 49_000.0
        )

        # Fill the order first (entry fee deducted)
        fill_candle = double("Candle", close: 51_000.0, high: 51_500.0, low: 50_500.0)
        simulator.on_candle(fill_candle)
        equity_after_fill = simulator.equity_usd

        # Then trigger TP
        tp_candle = double("Candle", close: 49_000.0, high: 49_500.0, low: 48_500.0)
        simulator.on_candle(tp_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:closed)

        # Calculate expected P&L: (51_000 - 49_000) * 0.1 - exit_fee = 200 - 2.45 = 197.55
        expected_pnl = (51_000.0 - 49_000.0) * 0.1 - (49_000.0 * 0.1 * 0.0005)
        expect(simulator.equity_usd).to eq(equity_after_fill + expected_pnl)
      end

      it "closes short position on stop loss with correct P&L" do
        simulator.equity_usd
        order_id = simulator.place_limit(
          symbol: "BTC-USD",
          side: :sell,
          price: 50_000.0,
          quantity: 0.1,
          sl: 52_000.0
        )

        # Fill the order first
        fill_candle = double("Candle", close: 50_000.0, high: 50_500.0, low: 49_500.0)
        simulator.on_candle(fill_candle)
        equity_after_fill = simulator.equity_usd

        # Then trigger SL
        sl_candle = double("Candle", close: 52_000.0, high: 52_500.0, low: 51_500.0)
        simulator.on_candle(sl_candle)

        order = simulator.orders[order_id]
        expect(order.status).to eq(:closed)

        # Calculate expected P&L: (50_000 - 52_000) * 0.1 - exit_fee = -200 - 2.6 = -202.6
        expected_pnl = (50_000.0 - 52_000.0) * 0.1 - (52_000.0 * 0.1 * 0.0005)
        expect(simulator.equity_usd).to eq(equity_after_fill + expected_pnl)
      end
    end
  end
end
