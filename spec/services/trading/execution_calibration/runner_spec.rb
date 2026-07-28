# frozen_string_literal: true

require "rails_helper"

# The #486 harness: 20 forced round trips on BIP, 1 contract, half taker-entry
# and half maker-entry, to MEASURE execution cost. Not signal-driven and not a
# strategy test.
RSpec.describe Trading::ExecutionCalibration::Runner do
  let(:product_id) { "BIP-20DEC30-CDE" }
  let(:positions_service) { instance_double(Trading::CoinbasePositions, authenticated?: true) }
  let(:lifecycle) { instance_double(Trading::PositionLifecycle) }
  let(:logger) { instance_spy(Logger) }

  def runner(**overrides)
    described_class.new(product_id: product_id,
      round_trips: 4,
      hold_seconds: 5,
      positions_service: positions_service,
      lifecycle: lifecycle,
      logger: logger,
      sleeper: ->(_seconds) {}, **overrides)
  end

  # Mirrors what Trading::CoinbasePositions#open_position actually does: places
  # the order, persists the Position, and merges its id into the result.
  def order_ok(price: 65_900.0, fee: 0.198)
    position = Position.create!(
      product_id: product_id, side: "LONG", size: 1, entry_price: price,
      entry_time: Time.current, status: "OPEN", paper: true, entry_fee: fee, day_trading: true
    )
    {"success" => true, "order_id" => SecureRandom.uuid, "price" => price, "fee" => fee,
     "position_id" => position.id, "dry_run" => true}
  end

  # Mirrors Trading::PositionLifecycle#close: the position really does end up
  # CLOSED, which is what lets the runner assert it is flat before the next leg.
  def close_ok(price: 65_900.0, exit_fee: 0.198, pnl: -0.396)
    lambda do |position, **|
      position.update!(exit_fee: exit_fee)
      position.force_close!(price, "calibration", Time.current, pnl: pnl)
      Trading::PositionLifecycle::Result.new(success: true, close_price: price, reason: "calibration", fallback: false)
    end
  end

  def stub_happy_path!(fee: 0.198)
    allow(positions_service).to receive(:open_position) { order_ok(fee: fee) }
    allow(lifecycle).to receive(:close) { |position, **kw| close_ok.call(position, **kw) }
  end

  before do
    BotRuntimeStat.delete_all
    Position.destroy_all
    Order.delete_all
    Contract.where(product_id: product_id).delete_all
    create(:contract, product_id: product_id, base_currency: "BTC")
    allow(Trading::EquityAssertion).to receive(:verify!).and_return({sizing: 1000.0, actual: 1000.0})
    allow(RecentMarketPrice).to receive(:for_product).and_return(65_900.0)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    allow(FeeMeasurementSnapshotJob).to receive(:perform_now)
    DryRun.enable!
  end

  # ── Safety: dry-run by default ──────────────────────────────────────────────

  describe "dry-run by default" do
    it "runs simulated when nothing asked for live, and never turns dry-run off" do
      stub_happy_path!

      report = runner.call

      expect(report.mode).to eq(:dry_run)
      expect(DryRun.active?).to be(true)
    end

    it "forces dry-run ON even if it was off, before placing anything" do
      DryRun.disable!
      allow(lifecycle).to receive(:close) { |position, **kw| close_ok.call(position, **kw) }
      allow(positions_service).to receive(:open_position) do
        expect(DryRun.active?).to be(true)
        order_ok
      end

      runner.call
    end
  end

  describe "the three independent gates on going live" do
    around do |example|
      original = ENV["LIVE_TRADING_CONFIRMED"]
      example.run
      ENV["LIVE_TRADING_CONFIRMED"] = original
    end

    it "refuses live without LIVE_TRADING_CONFIRMED even with the flag and the phrase" do
      ENV.delete("LIVE_TRADING_CONFIRMED")

      report = runner(live: true, confirmation: described_class::CONFIRMATION_PHRASE).call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("LIVE_TRADING_CONFIRMED")
      expect(positions_service).not_to have_received(:open_position) if positions_service.respond_to?(:open_position)
    end

    it "refuses live without the typed confirmation phrase" do
      ENV["LIVE_TRADING_CONFIRMED"] = "1"

      report = runner(live: true, confirmation: "yes").call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include(described_class::CONFIRMATION_PHRASE)
    end

    it "places no order at all when a live gate is missing" do
      ENV["LIVE_TRADING_CONFIRMED"] = "1"
      expect(positions_service).not_to receive(:open_position)

      runner(live: true, confirmation: nil).call
    end
  end

  # ── Safety: preconditions ───────────────────────────────────────────────────

  describe "preconditions" do
    it "refuses to place any order when a precondition is unmet, naming it" do
      allow(Trading::LossLimits).to receive(:cumulative_cap).and_return(500.0)
      expect(positions_service).not_to receive(:open_position)

      report = runner.call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("cumulative loss cap")
    end

    it "refuses any instrument that is not BIP" do
      report = runner(product_id: "BIT-31JUL26-CDE").call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("BIP")
    end

    it "refuses, saying so plainly, when no BIP contract is ingested at all" do
      Contract.where("product_id LIKE ?", "BIP-%").delete_all

      report = described_class.new(round_trips: 4, positions_service: positions_service,
        lifecycle: lifecycle, logger: logger, sleeper: ->(_) {}).call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("no BIP contract is ingested")
    end

    it "refuses an odd number of round trips, which cannot split evenly into taker and maker arms" do
      report = runner(round_trips: 5).call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("even")
    end
  end

  # The observation #486 exists to buy. The paper simulator always fills, so
  # this path only ever runs live — which is exactly why it needs a spec.
  describe "a maker entry that never fills" do
    let(:never_fills_maker) do
      Class.new do
        def observe(phase:, side:, intended_price:, order_result:, deadline:, poll_seconds: nil)
          return nil if phase == :entry && order_result["maker"]

          Trading::ExecutionCalibration::Fill.new(
            phase: phase, side: side, order_id: order_result["order_id"], liquidity: "TAKER",
            intended_price: intended_price, fill_price: intended_price, commission: 0.198,
            contracts: 1.0, contract_multiplier: 0.01
          )
        end
      end.new
    end

    before do
      allow(positions_service).to receive(:open_position) do |args|
        order_ok.merge("maker" => args[:type] == :maker)
      end
      allow(lifecycle).to receive(:close) { |position, **kw| close_ok.call(position, **kw) }
    end

    it "records it as an unfilled attempt rather than an error, and keeps going" do
      report = runner(round_trips: 4, observer: never_fills_maker).call

      expect(report.status).to eq(:completed)
      expect(report.tape.maker_attempts.size).to eq(2)
      expect(report.tape.maker_fills).to be_empty
      expect(report.tape.legs.count { |l| l.error }).to eq(0)
    end

    # The exchange expires a post-only GTD order itself, but open_position has
    # already written a local Position for the ACCEPTANCE. Left OPEN it is a
    # phantom, and the next leg's flat check would refuse to continue.
    it "voids the phantom position the acceptance created" do
      runner(round_trips: 4, observer: never_fills_maker).call

      expect(Position.open.by_product(product_id)).to be_empty
      voided = Position.where(product_id: product_id, status: "CLOSED").where(pnl: 0.0)
      expect(voided.count).to eq(2)
    end

    it "reports the zero maker fill rate as the finding that kills the +22 bps case" do
      report = runner(round_trips: 4, observer: never_fills_maker).call

      expect(report.tape.maker_fill_rate).to eq(0.0)
      expect(report.maker_warning).to include("KILLS")
      expect(TradingHalt.risk_halted?).to be(false)
    end
  end

  # ── The run itself ──────────────────────────────────────────────────────────

  describe "the forced round trips" do
    before { allow(lifecycle).to receive(:close) { |position, **kw| close_ok.call(position, **kw) } }

    it "runs exactly one contract on every entry" do
      allow(positions_service).to receive(:open_position) { order_ok }

      runner(round_trips: 4).call

      expect(positions_service).to have_received(:open_position)
        .with(hash_including(product_id: product_id, size: 1)).exactly(4).times
    end

    it "splits the run half taker-entry and half maker-entry" do
      types = []
      allow(positions_service).to receive(:open_position) do |args|
        types << args[:type]
        order_ok
      end

      runner(round_trips: 4).call

      expect(types.count(:market)).to eq(2)
      expect(types.count(:maker)).to eq(2)
    end

    it "posts the maker entry passively, away from the reference price" do
      prices = {}
      allow(positions_service).to receive(:open_position) do |args|
        prices[args[:type]] = args[:price]
        order_ok
      end

      runner(round_trips: 2).call

      expect(prices[:maker]).to be < 65_900.0
    end

    it "closes every entry through PositionLifecycle, not a second order path" do
      allow(positions_service).to receive(:open_position) { order_ok }
      expect(positions_service).not_to receive(:close_position)

      runner(round_trips: 4).call

      expect(lifecycle).to have_received(:close).exactly(4).times
    end

    it "reports a completed run" do
      allow(positions_service).to receive(:open_position) { order_ok }

      report = runner(round_trips: 4).call

      expect(report.status).to eq(:completed)
      expect(report.tape.legs.size).to eq(4)
    end
  end

  # ── Safety: aborts stop the run ─────────────────────────────────────────────

  describe "aborting" do
    it "stops placing orders the moment an abort condition trips" do
      calls = 0
      allow(positions_service).to receive(:open_position) do
        calls += 1
        # A ~60 bps commission on the first fill falsifies ADR 0002.
        order_ok(fee: 4.0)
      end
      allow(lifecycle).to receive(:close) { |position, **kw| close_ok(exit_fee: 4.0).call(position, **kw) }

      report = runner(round_trips: 20).call

      expect(report.status).to eq(:aborted)
      expect(report.breach.condition).to eq(:taker_rate)
      expect(calls).to eq(1)
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "halts rather than leaving an untracked open position when the close fails" do
      allow(positions_service).to receive(:open_position) { order_ok }
      allow(lifecycle).to receive(:close).and_return(
        Trading::PositionLifecycle::Result.new(success: false, close_price: nil, reason: "c", fallback: false)
      )

      report = runner(round_trips: 4).call

      expect(report.status).to eq(:aborted)
      expect(report.breach.condition).to eq(:order_integrity)
      expect(TradingHalt.risk_halted?).to be(true)
    end

    it "halts when the entry order is rejected" do
      allow(positions_service).to receive(:open_position)
        .and_return({"success" => false, "error" => "INSUFFICIENT_FUND"})
      allow(lifecycle).to receive(:close)

      report = runner(round_trips: 4).call

      expect(report.status).to eq(:aborted)
      expect(report.breach.reason).to include("INSUFFICIENT_FUND")
      expect(TradingHalt.risk_halted?).to be(true)
    end
  end

  # ── Resumability ────────────────────────────────────────────────────────────

  describe "resumability" do
    before { stub_happy_path! }

    it "records progress after each leg so a crash does not lose the run" do
      runner(round_trips: 4).call

      journal = Trading::ExecutionCalibration::Journal.load
      expect(journal.completed_legs).to eq(4)
      expect(journal.status).to eq("completed")
    end

    it "refuses to start a fresh run over an unfinished one unless resuming" do
      Trading::ExecutionCalibration::Journal.start!(product_id: product_id, round_trips: 20)

      report = runner(round_trips: 4).call

      expect(report.status).to eq(:refused)
      expect(report.refusals.join).to include("--resume")
    end

    it "picks up where an interrupted run stopped instead of re-running its legs" do
      journal = Trading::ExecutionCalibration::Journal.start!(product_id: product_id, round_trips: 4)
      journal.record_leg!(Trading::ExecutionCalibration::Leg.new(number: 1, intent: :taker,
        intended_hold_seconds: 5, held_seconds: 5, realized_pnl: -0.4))
      journal.record_leg!(Trading::ExecutionCalibration::Leg.new(number: 2, intent: :taker,
        intended_hold_seconds: 5, held_seconds: 5, realized_pnl: -0.4))

      runner(round_trips: 4, resume: true).call

      expect(positions_service).to have_received(:open_position).twice
    end
  end

  # ── The deliverable ─────────────────────────────────────────────────────────

  describe "the written summary" do
    before { stub_happy_path! }

    it "states measured vs modeled taker rate, maker fill rate, slippage, funding and the ADR 0002 verdict" do
      summary = runner(round_trips: 4).call.summary

      expect(summary).to include("measured taker rate")
      expect(summary).to include("modeled")
      expect(summary).to include("maker fill rate")
      expect(summary).to include("slippage")
      expect(summary).to include("funding")
      expect(summary).to include("ADR 0002")
    end

    it "writes the measured rates to ProductFee through the existing measured-fee path" do
      runner(round_trips: 4).call

      expect(FeeMeasurementSnapshotJob).to have_received(:perform_now)
    end

    it "reconciles measured cost against CostModel and reports whether it is within 10%" do
      report = runner(round_trips: 4).call

      expect(report.reconciliation).to include(:within_tolerance, :measured_rate, :modeled_rate)
    end
  end
end
