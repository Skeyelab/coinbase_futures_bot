# frozen_string_literal: true

require "rails_helper"
require "thor"
require "climate_control"
require "tui"
require_relative "../../../lib/cli/futures_bot_cli"

# ADR 0006 decision 5. Suspension had exactly one writer an operator could
# reach — a Rails console — and after decision 4 made the gate fail closed, that
# would have been the only way to dig a stopped bot out. A control reachable
# only from a console is not a control.
#
# `universe_scope` so these examples see the real fail-closed default: the
# whole point is that `resume` is what flips a symbol from blocked to live.
RSpec.describe FuturesBotCli, "universe verbs", type: :model, universe_scope: true do
  def run_cli(*args) = described_class.start(args)

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  # `suspend` is the brake. It takes no confirmation for the same reason `halt`
  # takes none: friction on the safe direction is friction during an incident.
  describe "#suspend" do
    it "blocks a symbol from new entries and records the reason" do
      Trading::SymbolSuspension.enable!("NOL-30SEP26-CDE", reason: "seed")
      expect($stdin).not_to receive(:gets)

      capture_stdout { run_cli("suspend", "NOL-30SEP26-CDE", "--reason", "roll risk") }

      expect(Trading::SymbolSuspension.suspended?("NOL-30SEP26-CDE")).to be true
      expect(Trading::SymbolSuspension.all["NOL-30SEP26-CDE"]["reason"]).to eq("roll risk")
    end

    it "emits machine-readable JSON" do
      Trading::SymbolSuspension.enable!("NOL-30SEP26-CDE", reason: "seed")

      out = capture_stdout { run_cli("suspend", "NOL-30SEP26-CDE", "--json", "--reason", "roll risk") }

      expect(JSON.parse(out)).to include("suspended" => true, "symbol" => "NOL-30SEP26-CDE", "reason" => "roll risk")
      expect(out).not_to match(/\e\[/)
    end
  end

  # `resume SYMBOL` is the permissive direction: it is what puts an instrument
  # back on the order path, so ADR 0005's confirmation rule applies to it and
  # not to the brake.
  describe "#resume SYMBOL" do
    it "records the explicit enablement the fail-closed gate requires" do
      expect(Trading::SymbolSuspension.suspended?("BIP-20DEC30-CDE")).to be true

      capture_stdout { run_cli("resume", "BIP-20DEC30-CDE", "--yes") }

      expect(Trading::SymbolSuspension.suspended?("BIP-20DEC30-CDE")).to be false
    end

    it "lifts an explicit suspension" do
      Trading::SymbolSuspension.suspend!("NOL-30SEP26-CDE", reason: "cost bleed")

      capture_stdout { run_cli("resume", "NOL-30SEP26-CDE", "--yes") }

      expect(Trading::SymbolSuspension.suspended?("NOL-30SEP26-CDE")).to be false
    end

    it "refuses without confirmation and leaves the symbol blocked" do
      allow($stdin).to receive(:gets).and_return("no\n")

      out = capture_stdout { run_cli("resume", "BIP-20DEC30-CDE") }

      expect(Trading::SymbolSuspension.suspended?("BIP-20DEC30-CDE")).to be true
      expect(out).to match(/Not confirmed/)
    end

    it "refuses --json without --yes and never reads stdin" do
      expect($stdin).not_to receive(:gets)

      out = capture_stdout { run_cli("resume", "BIP-20DEC30-CDE", "--json") }

      expect(JSON.parse(out)).to include("resumed" => false, "error" => "confirmation_required")
      expect(Trading::SymbolSuspension.suspended?("BIP-20DEC30-CDE")).to be true
    end

    it "emits machine-readable JSON listing the resulting live universe" do
      out = capture_stdout { run_cli("resume", "BIP-20DEC30-CDE", "--json", "--yes", "--reason", "walk-forward") }

      doc = JSON.parse(out)
      expect(doc).to include("resumed" => true, "symbol" => "BIP-20DEC30-CDE")
      expect(doc["live_symbols"]).to include("BIP-20DEC30-CDE")
    end

    # `resume` with no argument has meant "lift the global trading halt" since
    # the kill switch shipped. ADR 0006 adds a symbol argument; it must not
    # silently repurpose the verb operators already have in their runbooks.
    it "still resumes global trading when given no symbol" do
      TradingHalt.halt!(reason: "test")

      capture_stdout { run_cli("resume") }

      expect(TradingHalt.status[:active]).to be true
    end
  end

  describe "#universe" do
    it "shows which symbols may trade and why the others may not" do
      Trading::SymbolSuspension.enable!("BIP-20DEC30-CDE", reason: "walk-forward")
      Trading::SymbolSuspension.suspend!("NOL-30SEP26-CDE", reason: "cost bleed")

      out = capture_stdout { run_cli("universe", "--json") }

      doc = JSON.parse(out)
      expect(doc["live_symbols"]).to eq(["BIP-20DEC30-CDE"])
      expect(doc["max_live_instruments"]).to eq(1)
      expect(doc["suspended"]["NOL-30SEP26-CDE"]["reason"]).to eq("cost bleed")
    end
  end
end
