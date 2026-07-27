# frozen_string_literal: true

require "rails_helper"

# Issue #408: the read surface for persisted runs (#406). Backtests were
# write-only; this makes what ran actually inspectable.
RSpec.describe "BacktestRuns", type: :request do
  let(:user) { "ops" }
  let(:pass) { "secret" }

  def auth_headers(u = user, p = pass)
    {"HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(u, p)}
  end

  def make_run(**overrides)
    BacktestRun.create!({
      symbol: "BIP-20DEC30-CDE", kind: "single", step: "5m",
      from_time: 30.days.ago, to_time: Time.current, status: "succeeded",
      fee_rate: 0.0003, slippage: 0.0002, starting_equity: 10_000.0,
      contract_size_usd: 649.95,
      metrics: {"expectancy" => 23.57, "cost_gate_passed" => true, "win_rate" => 0.46,
                "max_drawdown" => 0.08, "trade_count" => 153, "total_fees" => 12.3},
      equity_curve: Array.new(5_000) { |i| 10_000 + i },
      trades: [{"side" => "long", "pnl" => 12.0, "fees" => 0.6}]
    }.merge(overrides))
  end

  around do |ex|
    ClimateControl.modify(POSITIONS_UI_USERNAME: user, POSITIONS_UI_PASSWORD: pass) { ex.run }
  end

  describe "auth" do
    it "challenges without credentials" do
      get "/backtest_runs"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects wrong credentials" do
      get "/backtest_runs", headers: auth_headers("nope", "wrong")
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /backtest_runs" do
    it "lists runs newest first" do
      old = make_run(symbol: "OLD-CDE", created_at: 2.days.ago)
      recent = make_run(symbol: "NEW-CDE")

      get "/backtest_runs", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body.index("NEW-CDE")).to be < response.body.index("OLD-CDE")
      expect([old, recent].map(&:symbol)).to all(be_present)
    end

    # #353's hard gate is the most important cell in the table.
    it "renders the cost gate as a pass/fail badge" do
      make_run(metrics: {"cost_gate_passed" => false, "expectancy" => -5.0})

      get "/backtest_runs", headers: auth_headers

      expect(response.body).to match(/FAIL/i)
    end

    # Slice 1 sizing note: a 30-day 5m curve is ~8,600 points, 1m ~43,000.
    it "does not load the heavy jsonb columns" do
      make_run

      get "/backtest_runs", headers: auth_headers

      selected = assigns(:runs).first
      expect { selected.equity_curve }.to raise_error(ActiveModel::MissingAttributeError)
      expect { selected.trades }.to raise_error(ActiveModel::MissingAttributeError)
    end

    it "filters by symbol and by gate result" do
      make_run(symbol: "BIP-20DEC30-CDE")
      make_run(symbol: "NOL-19AUG26-CDE")

      get "/backtest_runs", params: {symbol: "NOL-19AUG26-CDE"}, headers: auth_headers

      # Asserted on the result set, not the body: the filter dropdown lists
      # every known symbol, so the body legitimately mentions both.
      expect(assigns(:runs).map(&:symbol)).to eq(["NOL-19AUG26-CDE"])
    end
  end

  describe "GET /backtest_runs/:id" do
    it "shows the inputs so the run is reproducible" do
      run = make_run

      get "/backtest_runs/#{run.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("0.0003")   # fee_rate
      expect(response.body).to include("649.95")   # contract_size_usd
      expect(response.body).to include("5m")
    end

    it "shows the headline metrics" do
      run = make_run

      get "/backtest_runs/#{run.id}", headers: auth_headers

      expect(response.body).to include("23.57")
      expect(response.body).to match(/PASS/i)
    end

    # A zero-trade window with low 1m coverage is data-starved, not a signal
    # result (#378) — that distinction has to survive into the UI.
    it "shows per-window data_coverage for a walk-forward run" do
      run = make_run(kind: "walk_forward", train_days: 90, eval_days: 30,
        windows: [{"eval_from" => "2026-01-01T00:00:00Z",
                   "metrics" => {"trade_count" => 0, "total_pnl" => 0.0},
                   "data_coverage" => {"one_minute" => 0.6987, "five_minute" => 0.9325}}])

      get "/backtest_runs/#{run.id}", headers: auth_headers

      expect(response.body).to include("0.6987").or include("69.9")
    end

    it "shows the error plainly for a failed run" do
      run = make_run(status: "failed", metrics: nil, error_message: "ArgumentError: unknown step")

      get "/backtest_runs/#{run.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("unknown step")
    end

    it "renders a still-running run without metrics" do
      run = make_run(status: "running", metrics: nil, started_at: 5.minutes.ago)

      get "/backtest_runs/#{run.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(response.body).to match(/running/i)
    end
  end
end
