# frozen_string_literal: true

require "rails_helper"
require "stringio"
require_relative "../../../lib/cli/tui_dashboard"

RSpec.describe TuiDashboard do
  let(:output) { StringIO.new }
  let(:dashboard) { described_class.new(refresh_interval: 5, output: output) }

  # ── Initial state ─────────────────────────────────────────────────────────────

  describe "initial state" do
    it "starts with running = true" do
      expect(dashboard.running).to be true
    end

    it "starts with positions and signals visible" do
      expect(dashboard.show_positions).to be true
      expect(dashboard.show_signals).to be true
    end

    it "respects the provided refresh interval" do
      expect(dashboard.refresh_interval).to eq(5)
    end
  end

  # ── handle_keypress ───────────────────────────────────────────────────────────

  describe "#handle_keypress" do
    it "sets running=false on 'q'" do
      dashboard.handle_keypress("q")
      expect(dashboard.running).to be false
    end

    it "sets running=false on 'Q'" do
      dashboard.handle_keypress("Q")
      expect(dashboard.running).to be false
    end

    it "sets running=false on Escape" do
      dashboard.handle_keypress("\e")
      expect(dashboard.running).to be false
    end

    it "sets running=false on Ctrl+C" do
      dashboard.handle_keypress("\x03")
      expect(dashboard.running).to be false
    end

    it "forces a refresh on 'r'" do
      dashboard.handle_keypress("r")
      # last_refresh should be in the past so next loop iteration triggers a refresh
      expect(dashboard.instance_variable_get(:@last_refresh)).to be <= Time.now - dashboard.refresh_interval
    end

    it "forces a refresh on 'R'" do
      dashboard.handle_keypress("R")
      expect(dashboard.instance_variable_get(:@last_refresh)).to be <= Time.now - dashboard.refresh_interval
    end

    it "toggles positions section on 'p'" do
      expect { dashboard.handle_keypress("p") }.to change(dashboard, :show_positions).from(true).to(false)
    end

    it "toggles positions section back on second 'p'" do
      dashboard.handle_keypress("p")
      expect { dashboard.handle_keypress("p") }.to change(dashboard, :show_positions).from(false).to(true)
    end

    it "toggles signals section on 's'" do
      expect { dashboard.handle_keypress("s") }.to change(dashboard, :show_signals).from(true).to(false)
    end

    it "refreshes slower (increases interval value) on '-'" do
      expect { dashboard.handle_keypress("-") }.to change(dashboard, :refresh_interval).from(5).to(6)
    end

    it "refreshes faster (decreases interval value) on '+'" do
      expect { dashboard.handle_keypress("+") }.to change(dashboard, :refresh_interval).from(5).to(4)
    end

    it "does not decrease interval below 1 second" do
      9.times { dashboard.handle_keypress("+") }
      expect(dashboard.refresh_interval).to eq(1)
    end

    it "ignores unknown keys" do
      expect { dashboard.handle_keypress("x") }.not_to change(dashboard, :running)
    end
  end

  # ── refresh_data ──────────────────────────────────────────────────────────────

  describe "#refresh_data" do
    context "with database records" do
      before do
        create(:position)
        create(:position, :swing_trading)
        create(:signal_alert)
      end

      it "populates day position count" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:day_pos_count]).to eq(1)
      end

      it "populates swing position count" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:swing_pos_count]).to eq(1)
      end

      it "populates signal count" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:signal_count]).to be >= 1
      end

      it "populates positions array" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:positions]).not_to be_empty
      end

      it "populates signals array" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:signals]).not_to be_empty
      end

      it "populates live prices from recent ticks" do
        create(:tick, product_id: "NOL-18MAY26-CDE", price: 93.62, observed_at: 5.seconds.ago)
        dashboard.refresh_data
        live_prices = dashboard.instance_variable_get(:@data)[:live_prices]
        expect(live_prices.map(&:product_id)).to include("NOL-18MAY26-CDE")
      end

      it "splits live prices into futures and spot buckets" do
        create(:tick, product_id: "NOL-18MAY26-CDE", price: 93.62, observed_at: 5.seconds.ago)
        create(:tick, product_id: "BTC-USD", price: 68_000, observed_at: 4.seconds.ago)
        dashboard.refresh_data
        data = dashboard.instance_variable_get(:@data)
        expect(data[:futures_live_prices].map(&:product_id)).to include("NOL-18MAY26-CDE")
        expect(data[:spot_live_prices].map(&:product_id)).to include("BTC-USD")
      end

      it "sets refreshed_at timestamp" do
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:refreshed_at]).to be_within(2.seconds).of(Time.now)
      end

      it "captures latest tick timestamp for connectivity display" do
        tick = create(:tick, observed_at: 1.second.ago)
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@data)[:latest_tick_at]).to eq(tick.observed_at)
      end

      it "clears any previous error" do
        dashboard.instance_variable_set(:@error, "old error")
        dashboard.refresh_data
        expect(dashboard.instance_variable_get(:@error)).to be_nil
      end
    end

    context "when the database raises" do
      it "captures the error message instead of raising" do
        allow(Position).to receive(:open).and_raise(StandardError, "DB offline")
        expect { dashboard.refresh_data }.not_to raise_error
        expect(dashboard.instance_variable_get(:@error)).to eq("DB offline")
      end
    end
  end

  # ── render ────────────────────────────────────────────────────────────────────

  describe "#render" do
    before do
      allow(dashboard).to receive(:terminal_cols).and_return(100)
      dashboard.refresh_data
    end

    it "outputs the FuturesBot header" do
      dashboard.render
      expect(output.string).to include("FuturesBot")
    end

    it "outputs the key-bindings hint" do
      dashboard.render
      expect(output.string).to include("[q]uit")
      expect(output.string).to include("[r]efresh")
    end

    it "outputs the Status row" do
      dashboard.render
      expect(output.string).to include("Status")
    end

    it "outputs Coinbase connectivity status" do
      dashboard.render
      expect(output.string).to include("Coinbase:")
    end

    it "outputs the Open Positions section when show_positions=true" do
      dashboard.render
      expect(output.string).to include("Open Positions")
    end

    it "outputs unrealized PnL column when positions exist" do
      create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG")
      create(:tick, product_id: "BIT-29AUG25-CDE", price: 51000, observed_at: 2.seconds.ago)
      dashboard.refresh_data
      dashboard.render
      expect(output.string).to include("U.PnL")
    end

    it "omits the Open Positions section when show_positions=false" do
      dashboard.handle_keypress("p")
      dashboard.render
      expect(output.string).not_to include("Open Positions")
    end

    it "outputs the Active Signals section when show_signals=true" do
      dashboard.render
      expect(output.string).to include("Active Signals")
    end

    it "outputs separate futures and spot price sections" do
      dashboard.render
      expect(output.string).to include("Futures Live Prices")
      expect(output.string).to include("Spot Prices")
    end

    it "omits the Active Signals section when show_signals=false" do
      dashboard.handle_keypress("s")
      dashboard.render
      expect(output.string).not_to include("Active Signals")
    end

    it "outputs the footer with interval information" do
      dashboard.render
      expect(output.string).to include("Interval:")
    end

    context "when there is a stored error" do
      before { dashboard.instance_variable_set(:@error, "connection refused") }

      it "renders the error in the output" do
        dashboard.render
        expect(output.string).to include("Error:")
        expect(output.string).to include("connection refused")
      end
    end

    context "with position and signal records" do
      before do
        create(:position, product_id: "BIT-29AUG25-CDE", side: "LONG")
        create(:signal_alert, symbol: "BTC-USD", confidence: 90)
        create(:tick, product_id: "BIT-29AUG25-CDE", price: 51000, observed_at: 2.seconds.ago)
        create(:tick, product_id: "NOL-18MAY26-CDE", price: 93.62, observed_at: 3.seconds.ago)
        dashboard.refresh_data
        dashboard.render
      end

      it "renders position product IDs" do
        expect(output.string).to include("BIT-29AUG25-CDE")
      end

      it "renders signal symbols" do
        expect(output.string).to include("BTC-USD")
      end

      it "renders live price product IDs" do
        expect(output.string).to include("NOL-18MAY26-CDE")
      end

      it "renders spot prices in the spot section" do
        create(:tick, product_id: "BTC-USD", price: 68_000, observed_at: 2.seconds.ago)
        dashboard.refresh_data
        dashboard.render
        expect(output.string).to include("BTC-USD")
      end

      it "renders unrealized PnL values when price data exists" do
        expect(output.string).to match(/[+-]\d+\.\d{1,2}/)
      end
    end
  end

  # ── start (non-TTY / one-shot) ────────────────────────────────────────────────

  describe "#start (non-TTY output)" do
    it "renders once and returns without entering the interactive loop" do
      allow(output).to receive(:tty?).and_return(false)
      allow(dashboard).to receive(:terminal_cols).and_return(80)
      expect { dashboard.start }.not_to raise_error
      expect(output.string).to include("FuturesBot")
    end
  end

  describe "terminal buffer behavior" do
    it "enters alternate screen mode during setup" do
      allow(output).to receive(:print)
      allow(Signal).to receive(:trap)

      dashboard.send(:setup_terminal)

      expect(output).to have_received(:print).with(include("\e[?1049h"))
    end

    it "exits alternate screen mode during restore" do
      allow(output).to receive(:print)

      dashboard.send(:restore_terminal)

      expect(output).to have_received(:print).with(include("\e[?1049l"))
    end

    it "uses CRLF line endings in interactive tty renders" do
      allow(output).to receive(:tty?).and_return(true)
      allow(dashboard).to receive(:terminal_cols).and_return(80)

      dashboard.refresh_data
      dashboard.render

      expect(output.string).to include("\r\n")
    end
  end

  describe "coinbase status helper" do
    it "returns no data when no ticks are available" do
      status = dashboard.send(:coinbase_connection_status, nil)
      expect(status).to include("NO DATA")
    end

    it "returns live for fresh tick data" do
      status = dashboard.send(:coinbase_connection_status, 3.seconds.ago)
      expect(status).to include("LIVE")
    end

    it "returns stale for old tick data" do
      status = dashboard.send(:coinbase_connection_status, 2.minutes.ago)
      expect(status).to include("STALE")
    end
  end
end
