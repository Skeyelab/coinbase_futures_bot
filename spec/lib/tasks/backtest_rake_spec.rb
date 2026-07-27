# frozen_string_literal: true

require "rails_helper"
require "rake"

# Issue #406: the CLI is the existing interface and must keep behaving exactly
# as it did — JSON on stdout — while also landing the run in history. Asserting
# that by actually invoking the tasks, not by grepping the rake file.
RSpec.describe "backtest rake tasks" do
  before(:all) do
    Rake::Task.clear
    Rails.application.load_tasks
  end

  before { Rake::Task.tasks.each(&:reenable) }

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  # A window with no stored candles: the engine has nothing to replay, which is
  # all this needs — the recording path is under test, not the replay.
  let(:from) { "2026-06-01" }
  let(:to) { "2026-06-08" }

  describe "backtest:run" do
    it "persists the run and still prints the JSON metrics" do
      output = capture_stdout do
        expect {
          Rake::Task["backtest:run"].invoke("BTC-USD", from, to, "5m")
        }.to change(BacktestRun, :count).by(1)
      end

      expect { JSON.parse(output) }.not_to raise_error
      expect(JSON.parse(output)).to include("expectancy", "cost_gate_passed")

      run = BacktestRun.recent.first
      expect(run.kind).to eq("single")
      expect(run.symbol).to eq("BTC-USD")
      expect(run.step).to eq("5m")
      expect(run.status).to eq("succeeded")
      # The resolved rate, not the nil the task passed (ADR 0002 comparability).
      expect(run.fee_rate).to be_present
      expect(run.finished_at).to be_present
    end
  end

  describe "backtest:walk_forward" do
    it "persists the run and still prints the JSON report" do
      output = capture_stdout do
        expect {
          Rake::Task["backtest:walk_forward"].invoke("BTC-USD", from, to, "3", "2", "5m")
        }.to change(BacktestRun, :count).by(1)
      end

      expect(JSON.parse(output)).to include("windows", "aggregate")

      run = BacktestRun.recent.first
      expect(run.kind).to eq("walk_forward")
      expect(run.train_days).to eq(3)
      expect(run.eval_days).to eq(2)
      expect(run.windows).to be_present
    end
  end
end
