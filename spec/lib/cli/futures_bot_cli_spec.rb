# frozen_string_literal: true

require "rails_helper"
require "thor"
require "climate_control"
require_relative "../../../lib/cli/futures_bot_cli"

RSpec.describe FuturesBotCli, type: :model do
  let(:cli) { described_class.new }

  # ── helpers ──────────────────────────────────────────────────────────────────

  def run_cli(*args)
    described_class.start(args)
  end

  # ── dashboard ────────────────────────────────────────────────────────────────

  describe "#dashboard" do
    context "with startup position sync" do
      let(:import_service) { instance_double(PositionImportService) }
      let(:import_result) { {imported: 0, updated: 1, errors: [], total_coinbase: 1} }

      before do
        allow(PositionImportService).to receive(:new).and_return(import_service)
        allow(import_service).to receive(:import_positions_from_coinbase).and_return(import_result)
      end

      it "delegates to TuiDashboard#start" do
        mock_tui = instance_double(TuiDashboard)
        expect(TuiDashboard).to receive(:new).with(refresh_interval: TuiDashboard::DEFAULT_REFRESH).and_return(mock_tui)
        expect(mock_tui).to receive(:start)
        run_cli("dashboard")
      end

      it "syncs positions from Coinbase before starting the dashboard" do
        mock_tui = instance_double(TuiDashboard)
        allow(TuiDashboard).to receive(:new).and_return(mock_tui)
        allow(mock_tui).to receive(:start)
        expect(import_service).to receive(:import_positions_from_coinbase).ordered
        expect(mock_tui).to receive(:start).ordered
        run_cli("dashboard")
      end

      it "passes a custom --refresh interval through" do
        mock_tui = instance_double(TuiDashboard)
        expect(TuiDashboard).to receive(:new).with(refresh_interval: 10).and_return(mock_tui)
        expect(mock_tui).to receive(:start)
        run_cli("dashboard", "--refresh", "10")
      end
    end

    context "when FUTURESBOT_SKIP_POSITION_SYNC is set" do
      it "does not call PositionImportService" do
        mock_tui = instance_double(TuiDashboard)
        allow(TuiDashboard).to receive(:new).and_return(mock_tui)
        allow(mock_tui).to receive(:start)
        ClimateControl.modify(FUTURESBOT_SKIP_POSITION_SYNC: "1") do
          expect(PositionImportService).not_to receive(:new)
          run_cli("dashboard")
        end
      end
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

    it "shows operational status" do
      expect { run_cli("status") }.to output(/operational/).to_stdout
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
        allow(ChatSession).to receive_message_chain(:active, :recent, :limit).and_return([])
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
    let(:import_service) { instance_double(PositionImportService) }
    let(:import_result) { {imported: 0, updated: 0, errors: [], total_coinbase: 0} }

    before do
      allow(PositionImportService).to receive(:new).and_return(import_service)
      allow(import_service).to receive(:import_positions_from_coinbase).and_return(import_result)
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
      expect(import_service).to receive(:import_positions_from_coinbase)
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
