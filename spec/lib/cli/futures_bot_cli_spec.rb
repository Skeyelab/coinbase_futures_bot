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
    end

    it "prints a status summary without raising" do
      expect { run_cli("status") }.to output(/FuturesBot Status/).to_stdout
    end

    it "shows day-trading and swing position counts" do
      expect { run_cli("status") }.to output(/Day-trading positions/).to_stdout
      expect { run_cli("status") }.to output(/Swing positions/).to_stdout
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

  # ── chat command (unit-level helpers) ────────────────────────────────────────

  describe "private chat helpers" do
    let(:session_id) { "aaaa-bbbb-cccc-1234" }
    let(:bot) { instance_double(ChatBotService) }

    before do
      allow(ChatBotService).to receive(:new).and_return(bot)
      allow(bot).to receive(:session_summary).and_return(
        total_interactions: 0,
        profitable_messages: 0,
        session_id: session_id,
        last_activity: nil
      )
    end

    describe "#quit_command?" do
      it "returns true for 'quit'" do
        allow($stdout).to receive(:puts)
        expect(cli.send(:quit_command?, "quit")).to be true
      end

      it "returns true for 'exit'" do
        allow($stdout).to receive(:puts)
        expect(cli.send(:quit_command?, "exit")).to be true
      end

      it "returns true for 'bye'" do
        allow($stdout).to receive(:puts)
        expect(cli.send(:quit_command?, "bye")).to be true
      end

      it "returns false for regular commands" do
        expect(cli.send(:quit_command?, "show status")).to be false
      end
    end

    describe "#resolve_session_id" do
      it "returns a new UUID when neither resume nor session_id are set" do
        allow(SecureRandom).to receive(:uuid).and_return("new-uuid-123")
        result = cli.send(:resolve_session_id, {resume: false, session_id: nil})
        expect(result).to eq("new-uuid-123")
      end

      it "returns the provided session_id when given" do
        result = cli.send(:resolve_session_id, {resume: false, session_id: "custom-id"})
        expect(result).to eq("custom-id")
      end
    end

    describe "#handle_local_command" do
      let(:memory) { instance_double(ChatMemoryService) }

      before do
        allow(ChatMemoryService).to receive(:new).and_return(memory)
        allow(memory).to receive(:recent_interactions).and_return([])
        allow(memory).to receive(:search_history).and_return([])
        allow(memory).to receive(:context_for_ai).and_return("")
        allow(bot).to receive(:instance_variable_get).with(:@session_id).and_return(session_id)
        allow($stdout).to receive(:puts)
      end

      it "handles 'history' command and returns true" do
        expect(cli.send(:handle_local_command, "history", bot, session_id)).to be true
      end

      it "handles 'history N' command" do
        expect(cli.send(:handle_local_command, "history 5", bot, session_id)).to be true
      end

      it "handles 'search query' command and returns true" do
        expect(cli.send(:handle_local_command, "search BTC", bot, session_id)).to be true
      end

      it "handles 'sessions' command and returns true" do
        create(:chat_session, session_id: session_id)
        expect(cli.send(:handle_local_command, "sessions", bot, session_id)).to be true
      end

      it "handles 'context-status' command and returns true" do
        expect(cli.send(:handle_local_command, "context-status", bot, session_id)).to be true
      end

      it "returns false for unrecognised commands" do
        expect(cli.send(:handle_local_command, "show positions", bot, session_id)).to be false
      end
    end
  end

  # ── chat integration (stdin simulation) ──────────────────────────────────────

  describe "#chat" do
    let(:session_id) { "test-session-abc" }
    let(:bot) { instance_double(ChatBotService) }
    let(:startup_sync) { instance_double(StartupPositionSync) }
    let(:sync_result) { StartupPositionSync::Result.new(status: :ok, message: "Positions synced from Coinbase (0 new, 0 updated, 0 on exchange)") }

    before do
      allow(StartupPositionSync).to receive(:new).and_return(startup_sync)
      allow(startup_sync).to receive(:call).and_return(sync_result)
      allow(SecureRandom).to receive(:uuid).and_return(session_id)
      allow(ChatBotService).to receive(:new).with(session_id).and_return(bot)
      allow(bot).to receive(:process).and_return("✅ Command processed")
      allow(bot).to receive(:session_summary).and_return(
        total_interactions: 1,
        profitable_messages: 0,
        session_id: session_id,
        last_activity: nil
      )
      allow(Signal).to receive(:trap)
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)
    end

    it "syncs positions from Coinbase after the banner" do
      allow($stdin).to receive(:gets).and_return("quit\n")
      expect(startup_sync).to receive(:call)
      run_cli("chat")
    end

    it "exits cleanly on 'quit'" do
      allow($stdin).to receive(:gets).and_return("quit\n")
      expect { run_cli("chat") }.not_to raise_error
    end

    it "exits cleanly on 'exit'" do
      allow($stdin).to receive(:gets).and_return("exit\n")
      expect { run_cli("chat") }.not_to raise_error
    end

    it "exits cleanly on EOF" do
      allow($stdin).to receive(:gets).and_return(nil)
      expect { run_cli("chat") }.not_to raise_error
    end

    it "skips empty input" do
      allow($stdin).to receive(:gets).and_return("\n", "  \n", "quit\n")
      expect(bot).not_to receive(:process)
      run_cli("chat")
    end

    it "passes non-empty commands to ChatBotService#process" do
      allow($stdin).to receive(:gets).and_return("show status\n", "quit\n")
      expect(bot).to receive(:process).with("show status").and_return("OK")
      run_cli("chat")
    end

    it "handles processing errors gracefully" do
      allow($stdin).to receive(:gets).and_return("bad command\n", "quit\n")
      allow(bot).to receive(:process).and_raise(StandardError, "explosion")
      expect($stdout).to receive(:puts).with(/Error: explosion/)
      run_cli("chat")
    end
  end
end
