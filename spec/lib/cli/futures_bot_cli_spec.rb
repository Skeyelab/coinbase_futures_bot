# frozen_string_literal: true

require "rails_helper"
require "thor"
require "climate_control"
require "tui"
require_relative "../../../lib/cli/futures_bot_cli"

RSpec.describe FuturesBotCli, type: :model do
  let(:cli) { described_class.new }

  # ── helpers ──────────────────────────────────────────────────────────────────

  def run_cli(*args)
    described_class.start(args)
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  describe "#mcp" do
    it "runs the MCP stdio server" do
      server = instance_double(Mcp::Server)
      allow(Mcp::Server).to receive(:new).and_return(server)
      expect(server).to receive(:run)

      run_cli("mcp")
    end
  end

  describe "--json output" do
    it "status --json emits valid JSON with as_of and no ANSI codes" do
      out = capture_stdout { run_cli("status", "--json") }

      parsed = JSON.parse(out)
      expect(parsed).to include("as_of", "halt", "positions", "dry_run")
      expect(out).not_to match(/\e\[/)
    end

    it "positions --json emits a positions array" do
      create(:position, product_id: "NOL-19JUN26-CDE")
      out = capture_stdout { run_cli("positions", "--json") }

      expect(JSON.parse(out)["positions"].first).to include("product_id" => "NOL-19JUN26-CDE")
    end

    it "signals --json emits a signals array" do
      create(:signal_alert, symbol: "OIL-USD")
      out = capture_stdout { run_cli("signals", "--json") }

      expect(JSON.parse(out)["signals"].first).to include("symbol" => "OIL-USD")
    end

    it "sentiment --json emits a sentiment document with recent events" do
      create(:contract, enabled: true, product_id: "NOL-19AUG26-CDE", base_currency: "OIL")
      SentimentEvent.create!(source: "oilprice_rss", symbol: "OIL-USD", published_at: Time.current,
        raw_text_hash: "cli-oil-news", title: "Oil up 4%", score: 1.0)
      out = capture_stdout { run_cli("sentiment", "--json") }

      parsed = JSON.parse(out)
      expect(parsed).to include("symbols", "recent_events", "sources")
      expect(parsed["recent_events"].first).to include("title" => "Oil up 4%")
    end

    it "halt_status --json emits the halt state" do
      out = capture_stdout { run_cli("halt_status", "--json") }

      expect(JSON.parse(out)).to include("active" => true, "halted" => false)
    end

    it "halt --json --reason echoes the resulting halt status" do
      out = capture_stdout { run_cli("halt", "--json", "--reason", "CPI print") }

      parsed = JSON.parse(out)
      expect(parsed).to include("halted" => true, "reason" => "CPI print")
      expect(DryRun.active?).to be false # unrelated state untouched
    end

    it "honors FUTURESBOT_JSON=1 without the flag" do
      out = ClimateControl.modify(FUTURESBOT_JSON: "1") { capture_stdout { run_cli("status") } }

      expect { JSON.parse(out) }.not_to raise_error
    end
  end

  # ── dashboard ────────────────────────────────────────────────────────────────

  describe "#dashboard" do
    context "with startup position sync" do
      let(:startup_sync) { instance_double(StartupPositionSync) }
      let(:sync_result) do
        StartupPositionSync::Result.new(
          status: :ok,
          message: "Positions synced from Coinbase (0 new, 1 updated, 1 on exchange)"
        )
      end

      before do
        allow(StartupPositionSync).to receive(:new).and_return(startup_sync)
        allow(startup_sync).to receive(:call).and_return(sync_result)
      end

      it "runs Tui::App via Bubbletea" do
        expect(Bubbletea).to receive(:run).with(instance_of(Tui::App), alt_screen: true)
        run_cli("dashboard")
      end

      it "syncs positions from Coinbase before starting the dashboard" do
        allow(Bubbletea).to receive(:run)
        expect(startup_sync).to receive(:call).ordered
        expect(Bubbletea).to receive(:run).ordered
        run_cli("dashboard")
      end
    end

    context "when FUTURESBOT_SKIP_POSITION_SYNC is set" do
      it "still delegates sync skipping to StartupPositionSync" do
        allow(Bubbletea).to receive(:run)
        startup_sync = instance_double(StartupPositionSync)
        allow(StartupPositionSync).to receive(:new).and_return(startup_sync)
        allow(startup_sync).to receive(:call).and_return(StartupPositionSync::Result.new(status: :skipped))

        ClimateControl.modify(FUTURESBOT_SKIP_POSITION_SYNC: "1") do
          expect(startup_sync).to receive(:call)
          run_cli("dashboard")
        end
      end
    end
  end

  # ── start ─────────────────────────────────────────────────────────────────────

  describe "#start" do
    let(:startup_sync) { instance_double(StartupPositionSync) }
    let(:mock_launcher) { instance_double(FuturesBotLauncher) }

    before do
      allow(StartupPositionSync).to receive(:new).and_return(startup_sync)
      allow(startup_sync).to receive(:call).and_return(StartupPositionSync::Result.new(status: :skipped))
      allow(FuturesBotLauncher).to receive(:new).and_return(mock_launcher)
      allow(mock_launcher).to receive(:start)
    end

    it "creates a FuturesBotLauncher and calls start" do
      expect(FuturesBotLauncher).to receive(:new).with(hash_including(tui_refresh: 5)).and_return(mock_launcher)
      expect(mock_launcher).to receive(:start)
      run_cli("start")
    end

    it "syncs positions before launching" do
      expect(startup_sync).to receive(:call).ordered
      expect(mock_launcher).to receive(:start).ordered
      run_cli("start")
    end

    it "passes a custom --refresh interval through" do
      expect(FuturesBotLauncher).to receive(:new).with(hash_including(tui_refresh: 10)).and_return(mock_launcher)
      run_cli("start", "--refresh", "10")
    end
  end

  # ── status ───────────────────────────────────────────────────────────────────

  describe "#status" do
    before do
      create_list(:position, 2)
      create_list(:position, 1, :swing_trading)
      create_list(:signal_alert, 3)
      allow(RecentMarketPrice).to receive(:for_product).and_return(nil)
    end

    it "prints a status summary without raising" do
      expect { run_cli("status") }.to output(/FuturesBot Status/).to_stdout
    end

    it "shows open position count with the Open positions label" do
      expect { run_cli("status") }.to output(/Open positions/).to_stdout
    end

    it "shows active signal count" do
      expect { run_cli("status") }.to output(/Active signals/).to_stdout
    end

    it "shows the realtime loop liveness" do
      expect { run_cli("status") }.to output(/Realtime loop/).to_stdout
    end

    it "shows the market-data feed liveness" do
      expect { run_cli("status") }.to output(/Market data/).to_stdout
    end

    it "flags the loop as stale when it has not been beating" do
      expect { run_cli("status") }.to output(/STALE/).to_stdout
    end

    it "shows operational status" do
      expect { run_cli("status") }.to output(/operational/).to_stdout
    end

    it "shows per-position rows with ID, side, entry, and held time" do
      pos = create(:position, product_id: "BIT-27JUN25-CDE", side: "LONG",
        entry_price: 107_240.0, size: 1, day_trading: true)
      allow(RecentMarketPrice).to receive(:for_product).with("BIT-27JUN25-CDE").and_return(nil)

      expect { run_cli("status") }.to output(/#{pos.id}/).to_stdout
      expect { run_cli("status") }.to output(/BIT-27JUN25-CDE/).to_stdout
      expect { run_cli("status") }.to output(/LONG/).to_stdout
    end

    it "shows aggregate unrealized PnL when market prices are available" do
      create(:position, product_id: "BIT-27JUN25-CDE", side: "LONG",
        entry_price: 100_000.0, size: 1, day_trading: true)
      allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(1)
      allow(RecentMarketPrice).to receive(:for_product).with("BIT-27JUN25-CDE").and_return(100_200.0)

      expect { run_cli("status") }.to output(/unrealized/).to_stdout
    end

    it "marks paper positions with the 🧪 emoji" do
      create(:position, product_id: "ET-27JUN25-CDE", paper: true)
      allow(RecentMarketPrice).to receive(:for_product).with("ET-27JUN25-CDE").and_return(nil)

      expect { run_cli("status") }.to output(/🧪/).to_stdout
    end

    it "shows a truncation hint when more than STATUS_POSITION_CAP positions are open" do
      cap = OperatorSnapshot::STATUS_POSITION_CAP
      create_list(:position, cap + 1, day_trading: true)
      allow(RecentMarketPrice).to receive(:for_product).and_return(nil)

      expect { run_cli("status") }.to output(/and \d+ more — run/).to_stdout
    end

    context "dry-run mode" do
      it "shows a DRY-RUN indicator when dry-run is active" do
        DryRun.enable!
        expect { run_cli("status") }.to output(/DRY-RUN/).to_stdout
      end

      it "does not show DRY-RUN when running live" do
        expect { run_cli("status") }.not_to output(/DRY-RUN/).to_stdout
      end

      it "shows a paper account section with equity when dry-run is active" do
        DryRun.enable!
        expect { run_cli("status") }.to output(/Paper account.*Equity/m).to_stdout
      end

      it "reflects realized paper PnL in equity" do
        create(:position, paper: true, status: "CLOSED", pnl: 100.0, close_time: Time.current)
        DryRun.enable!
        expect { run_cli("status") }.to output(/10100/).to_stdout
      end

      it "omits the paper section when live and no paper positions exist" do
        expect { run_cli("status") }.not_to output(/Paper account/).to_stdout
      end
    end
  end

  describe "dry-run toggle commands" do
    it "enables dry-run with dry_run_on" do
      expect { run_cli("dry_run_on") }.to output(/DRY-RUN/).to_stdout
      expect(DryRun.active?).to be true
    end

    it "disables dry-run with dry_run_off" do
      DryRun.enable!
      expect { run_cli("dry_run_off") }.to output(/LIVE/).to_stdout
      expect(DryRun.active?).to be false
    end

    it "reports state with dry_run_status" do
      DryRun.enable!
      expect { run_cli("dry_run_status") }.to output(/DRY-RUN is ACTIVE/).to_stdout
    end

    context "sentiment section" do
      it "includes a sentiment section" do
        expect { run_cli("status") }.to output(/Sentiment/).to_stdout
      end

      it "shows the z-score for an enabled contract's symbol when data exists" do
        create(:contract, enabled: true, product_id: "NOL-19JUN26-CDE", base_currency: "OIL")
        SentimentAggregate.create!(symbol: "OIL-USD", window: "15m", window_end_at: Time.current - 5.minutes,
          count: 3, avg_score: -0.2, z_score: -0.4)
        SentimentEvent.create!(source: "coindesk", symbol: "OIL-USD", published_at: Time.current - 2.minutes,
          raw_text_hash: "cli-oil-1", title: "crude selloff")

        expect { run_cli("status") }.to output(/OIL-USD.*z=.*-0\.4.*3\/15m/m).to_stdout
      end

      it "shows a missing/stale state when there is no sentiment data" do
        expect { run_cli("status") }.to output(/no sentiment data|stale/i).to_stdout
      end
    end
  end

  # ── positions ────────────────────────────────────────────────────────────────

  describe "#positions" do
    context "with open positions" do
      before { create_list(:position, 3) }

      it "prints position table without raising" do
        expect { run_cli("positions") }.to output(/Open Positions/).to_stdout
      end

      it "shows the position header row" do
        expect { run_cli("positions") }.to output(/Product/).to_stdout
      end

      it "respects --limit option" do
        create_list(:position, 10)
        expect { run_cli("positions", "--limit", "2") }.not_to raise_error
      end
    end

    # The header read `%w[ID Product Side Entry Price Type]` — six labels — while
    # the row supplied id, product, side, entry_price, SIZE, type. So the column
    # labelled "Price" showed the contract count: a 1-contract position rendered
    # "Price 1.0", which reads as a catastrophic quote on an $80 instrument.
    # "Entry Price" was almost certainly one label that %w split in two.
    context "column labelling" do
      before do
        Position.delete_all
        create(:position, product_id: "NOL-19AUG26-CDE", side: "SHORT",
          entry_price: 80.82, size: 1)
        allow(RecentMarketPrice).to receive(:for_product).and_return(81.59)
        allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(10)
      end

      it "does not label the size column as a price" do
        out = capture_stdout { run_cli("positions") }
        header = out.lines.find { |l| l.include?("Product") }

        expect(header).to include("Size")
        expect(header).not_to match(/\bPrice\b/)
      end

      # An operator looking at a money surface needs to see they are losing.
      # SHORT from 80.82 with the mark at 81.59 on contract_size 10 is ~-$7.70,
      # and the table showed no PnL at all.
      it "shows unrealized PnL" do
        out = capture_stdout { run_cli("positions") }

        expect(out).to match(/PnL/)
        expect(out).to match(/-7\.7/)
      end
    end

    context "with no open positions" do
      before { Position.delete_all }

      it "shows 'No open positions found'" do
        expect { run_cli("positions") }.to output(/No open positions found/).to_stdout
      end
    end

    context "with a paper (dry-run) position" do
      before { create(:position, paper: true, product_id: "NOL-19JUN26-CDE") }

      it "marks paper rows with an indicator" do
        expect { run_cli("positions") }.to output(/🧪/).to_stdout
      end
    end

    context "with --type day filter" do
      before do
        create(:position)             # day_trading: true (default)
        create(:position, :swing_trading)
      end

      it "filters to day-trading positions" do
        expect { run_cli("positions", "--type", "day") }.not_to raise_error
      end
    end

    context "with --type swing filter" do
      before { create(:position, :swing_trading) }

      it "filters to swing positions" do
        expect { run_cli("positions", "--type", "swing") }.not_to raise_error
      end
    end
  end

  # ── signals ──────────────────────────────────────────────────────────────────

  describe "#signals" do
    context "with active signals" do
      before { create_list(:signal_alert, 4) }

      it "prints signal table without raising" do
        expect { run_cli("signals") }.to output(/Active Signals/).to_stdout
      end

      it "shows signal header row" do
        expect { run_cli("signals") }.to output(/Symbol/).to_stdout
      end
    end

    context "with no active signals" do
      before { SignalAlert.delete_all }

      it "shows 'No active signals found'" do
        expect { run_cli("signals") }.to output(/No active signals found/).to_stdout
      end
    end

    context "with --min_confidence filter" do
      before do
        create(:signal_alert, confidence: 90)
        create(:signal_alert, confidence: 40)
      end

      it "respects minimum confidence threshold" do
        expect { run_cli("signals", "--min_confidence", "80") }.not_to raise_error
      end
    end
  end

  # ── version ──────────────────────────────────────────────────────────────────

  describe "#version" do
    it "outputs FuturesBot version info" do
      expect { run_cli("version") }.to output(/FuturesBot/).to_stdout
    end

    it "includes Rails version" do
      expect { run_cli("version") }.to output(/Rails/).to_stdout
    end
  end

  # ── close ────────────────────────────────────────────────────────────────────
  #
  # The operator CLI is the surface reached for during an incident, and it was
  # the only one with no way to close a position. Every close here routes through
  # Trading::PositionLifecycle — never Trading::CoinbasePositions directly —
  # because the lifecycle is the sole writer of the cooldown, the stoploss guard,
  # and the daily loss caps (ADR 0003, ADR 0005).
  describe "#close" do
    let(:position) { create(:position, product_id: "NOL-19AUG26-CDE", size: 1) }
    let(:lifecycle) { instance_double(Trading::PositionLifecycle) }
    let(:ok) { Trading::PositionLifecycle::Result.new(success: true, close_price: 81.5, reason: "cli_operator_close", fallback: false) }

    before { allow(Trading::PositionLifecycle).to receive(:new).and_return(lifecycle) }

    it "routes a confirmed close through PositionLifecycle" do
      expect(lifecycle).to receive(:close).with(position, hash_including(reason: "cli_operator_close")).and_return(ok)

      capture_stdout { run_cli("close", position.id.to_s, "--yes") }
    end

    it "refuses to close when the interactive prompt is not answered 'yes'" do
      allow($stdin).to receive(:gets).and_return("n\n")
      expect(lifecycle).not_to receive(:close)

      out = capture_stdout { run_cli("close", position.id.to_s) }

      expect(out).to match(/aborted/i)
      expect(position.reload.status).to eq("OPEN")
    end

    # An operator mistypes an id during an incident. That must read as a clear
    # "no such open position", not a NoMethodError on nil.
    it "reports an unknown position id cleanly" do
      expect(lifecycle).not_to receive(:close)

      out = capture_stdout { run_cli("close", "99999999", "--yes") }

      expect(out).to match(/No OPEN position with id 99999999/)
    end

    it "refuses a position that is already CLOSED" do
      closed = create(:position, status: "CLOSED", close_time: Time.current)
      expect(lifecycle).not_to receive(:close)

      out = capture_stdout { run_cli("close", closed.id.to_s, "--yes") }

      expect(out).to match(/No OPEN position/)
    end

    describe "--json" do
      # A machine caller cannot answer a prompt. Reading stdin here would hang
      # the /futuresbot skill mid-incident, so JSON without --yes refuses.
      it "refuses without --yes and never reads stdin" do
        expect($stdin).not_to receive(:gets)
        expect(lifecycle).not_to receive(:close)

        out = capture_stdout { run_cli("close", position.id.to_s, "--json") }

        expect(JSON.parse(out)).to include("closed" => false, "error" => "confirmation_required")
        expect(out).not_to match(/\e\[/)
      end

      it "emits a machine-readable document on a confirmed close" do
        allow(lifecycle).to receive(:close).and_return(ok)

        out = capture_stdout { run_cli("close", position.id.to_s, "--json", "--yes") }

        expect(JSON.parse(out)).to include(
          "closed" => true, "position_id" => position.id,
          "product_id" => "NOL-19AUG26-CDE", "close_price" => 81.5
        )
        expect(out).not_to match(/\e\[/)
      end
    end

    # The reason `close` must not call Trading::CoinbasePositions directly:
    # PositionLifecycle is the sole writer of the cooldown, the stoploss guard,
    # and Trading::LossLimits. A hand-closed loser that skipped it never counted
    # against the daily caps that exist to stop the next one.
    context "protections layer" do
      before do
        allow(Trading::PositionLifecycle).to receive(:new).and_call_original
        allow(Trading::CoinbasePositions).to receive(:new)
          .and_return(instance_double(Trading::CoinbasePositions, close_position: {"success" => true}))
        allow(RecentMarketPrice).to receive(:for_product).and_return(81.5)
      end

      it "starts a cooldown and evaluates the daily loss caps on a confirmed close" do
        expect(Trading::Protections::CooldownPeriod)
          .to receive(:record_exit).with(symbol: "NOL-19AUG26-CDE")
        expect(Trading::LossLimits).to receive(:evaluate!)

        capture_stdout { run_cli("close", position.id.to_s, "--yes") }

        expect(position.reload.status).to eq("CLOSED")
      end
    end

    # PositionLifecycle deliberately leaves the DB row OPEN when the exchange
    # close fails, so the bot never believes it is flat while real exposure
    # remains ("phantom-flat"). The CLI must report that failure, not success.
    context "when the exchange close fails" do
      let(:positions_service) { instance_double(Trading::CoinbasePositions) }

      before do
        allow(Trading::PositionLifecycle).to receive(:new).and_call_original
        allow(Trading::CoinbasePositions).to receive(:new).and_return(positions_service)
        allow(positions_service).to receive(:close_position).and_return({"success" => false})
        allow(RecentMarketPrice).to receive(:for_product).and_return(81.5)
      end

      it "leaves the position OPEN and says so" do
        out = capture_stdout { run_cli("close", position.id.to_s, "--yes") }

        expect(position.reload.status).to eq("OPEN")
        expect(out).to match(/still OPEN/)
      end

      it "reports closed=false in JSON" do
        out = capture_stdout { run_cli("close", position.id.to_s, "--yes", "--json") }

        expect(JSON.parse(out)).to include("closed" => false, "error" => "close_failed")
        expect(position.reload.status).to eq("OPEN")
      end
    end
  end

  describe "#backtests" do
    def run!(**overrides)
      BacktestRun.create!({
        symbol: "BIP-20DEC30-CDE", kind: "walk_forward", step: "5m",
        from_time: 30.days.ago, to_time: Time.current, status: "succeeded",
        fee_rate: 0.0003,
        metrics: {"expectancy" => 23.57, "cost_gate_passed" => true,
                  "win_rate" => 0.46, "trade_count" => 153}
      }.merge(overrides))
    end

    before { BacktestRun.delete_all }

    it "prints a PASS verdict and the headline metrics" do
      run!
      out = capture_stdout { described_class.new.invoke(:backtests, [], {}) }

      expect(out).to include("PASS", "BIP-20DEC30-CDE", "153", "23.57")
    end

    it "prints FAIL when the cost gate failed" do
      run!(metrics: {"cost_gate_passed" => false, "expectancy" => -5.0, "trade_count" => 2})
      out = capture_stdout { described_class.new.invoke(:backtests, [], {}) }

      expect(out).to include("FAIL")
    end

    # nil is "no verdict yet" and must not read as a failure.
    it "shows no verdict for a run still in flight" do
      run!(status: "running", metrics: nil)
      out = capture_stdout { described_class.new.invoke(:backtests, [], {}) }

      expect(out).not_to include("FAIL")
      expect(out).not_to include("PASS")
    end

    it "emits JSON on demand" do
      run!
      out = capture_stdout { described_class.new.invoke(:backtests, [], {json: true}) }
      parsed = JSON.parse(out)

      expect(parsed["runs"].first).to include("symbol" => "BIP-20DEC30-CDE", "cost_gate_passed" => true)
    end

    it "filters by symbol" do
      run!(symbol: "NOL-19AUG26-CDE")
      run!(symbol: "BIP-20DEC30-CDE")
      out = capture_stdout { described_class.new.invoke(:backtests, [], {json: true, symbol: "NOL-19AUG26-CDE"}) }

      expect(JSON.parse(out)["runs"].map { |r| r["symbol"] }).to eq(["NOL-19AUG26-CDE"])
    end

    it "says so plainly when nothing has run" do
      out = capture_stdout { described_class.new.invoke(:backtests, [], {}) }

      expect(out).to match(/none recorded/i)
    end
  end
end
