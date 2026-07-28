# frozen_string_literal: true

require "rails_helper"
require "thor"
require "climate_control"
require "tui"
require_relative "../../../lib/cli/futures_bot_cli"

# The operator surface for issue #486. Follows the confirmation contract the
# `close` and `resume` verbs landed under (ADR 0005): money-touching actions
# require explicit confirmation, and `--json` callers who cannot answer a prompt
# are refused rather than blocked on one.
RSpec.describe FuturesBotCli, "#calibrate", type: :model do
  def run_cli(*args) = described_class.start(args)

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  let(:report) do
    Trading::ExecutionCalibration::Report.new(
      status: :completed, mode: :dry_run, product_id: "BIP-20DEC30-CDE",
      tape: Trading::ExecutionCalibration::Tape.new(product_id: "BIP-20DEC30-CDE"),
      refusals: [], reconciliation: nil
    )
  end

  before { allow_any_instance_of(Trading::ExecutionCalibration::Runner).to receive(:call).and_return(report) }

  it "runs in dry-run without asking for anything" do
    expect($stdin).not_to receive(:gets)

    output = capture_stdout { run_cli("calibrate") }

    expect(output).to include("BIP EXECUTION CALIBRATION")
  end

  it "passes dry-run through to the runner with live off" do
    expect(Trading::ExecutionCalibration::Runner).to receive(:new)
      .with(hash_including(live: false, confirmation: nil)).and_call_original

    capture_stdout { run_cli("calibrate") }
  end

  it "emits machine-readable JSON with --json" do
    output = capture_stdout { run_cli("calibrate", "--json") }

    expect(JSON.parse(output)).to include("status" => "completed", "product_id" => "BIP-20DEC30-CDE")
  end

  describe "going live" do
    it "prompts for the exact phrase and forwards what was typed" do
      allow($stdin).to receive(:gets).and_return("#{Trading::ExecutionCalibration::Runner::CONFIRMATION_PHRASE}\n")

      expect(Trading::ExecutionCalibration::Runner).to receive(:new)
        .with(hash_including(live: true, confirmation: Trading::ExecutionCalibration::Runner::CONFIRMATION_PHRASE))
        .and_call_original

      capture_stdout { run_cli("calibrate", "--live") }
    end

    it "forwards a wrong phrase verbatim so the runner is the one that refuses" do
      allow($stdin).to receive(:gets).and_return("yes\n")

      expect(Trading::ExecutionCalibration::Runner).to receive(:new)
        .with(hash_including(live: true, confirmation: "yes")).and_call_original

      capture_stdout { run_cli("calibrate", "--live") }
    end

    it "accepts the phrase non-interactively via --confirm" do
      expect($stdin).not_to receive(:gets)
      expect(Trading::ExecutionCalibration::Runner).to receive(:new)
        .with(hash_including(confirmation: Trading::ExecutionCalibration::Runner::CONFIRMATION_PHRASE))
        .and_call_original

      capture_stdout do
        run_cli("calibrate", "--live", "--confirm", Trading::ExecutionCalibration::Runner::CONFIRMATION_PHRASE)
      end
    end

    # A --json caller cannot answer a prompt, so it must supply --confirm or be
    # refused — never silently promoted to live, never hung on stdin.
    it "refuses a live --json run that supplied no phrase, without prompting" do
      expect($stdin).not_to receive(:gets)

      output = capture_stdout { run_cli("calibrate", "--live", "--json") }

      expect(JSON.parse(output)["status"]).to eq("refused")
      expect(JSON.parse(output)["refusals"].join).to include("--confirm")
    end
  end

  it "forwards the run shape the operator asked for" do
    expect(Trading::ExecutionCalibration::Runner).to receive(:new)
      .with(hash_including(round_trips: 6, hold_seconds: 45, resume: true)).and_call_original

    capture_stdout { run_cli("calibrate", "--round-trips", "6", "--hold-seconds", "45", "--resume") }
  end
end
