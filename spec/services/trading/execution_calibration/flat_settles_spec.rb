# frozen_string_literal: true

require "rails_helper"

# Issue #579. The first live #486 run to get past the venue's order enum placed a
# real round trip on BIP and then aborted at leg 1 of 20:
#
#   BIP-20DEC30-CDE is NOT flat after closing leg 1 — refusing to open another
#   position on top of exposure this run cannot account for
#
# It WAS flat. Checked seconds later: the venue reported zero positions, the
# local Position was CLOSED, nothing was stranded. Coinbase's /cfm/positions is
# eventually consistent, and #flat? read it microseconds after the close filled.
#
# Fail-closed is right here. The defect is treating a TRANSIENT disagreement as a
# permanent one — "not flat yet" is not "not flat, period".
RSpec.describe Trading::ExecutionCalibration::Runner, "the flat check settles (issue #579)" do
  let(:product_id) { "BIP-20DEC30-CDE" }
  let(:positions_service) { instance_double(Trading::CoinbasePositions, authenticated?: true) }
  let(:lifecycle) { instance_double(Trading::PositionLifecycle) }
  let(:logger) { instance_spy(Logger) }

  # Live, because #flat? short-circuits to true in dry-run — the venue read this
  # issue is about only happens on the path that spends money.
  def live_runner(**overrides)
    described_class.new(product_id: product_id,
      round_trips: 2,
      hold_seconds: 5,
      live: true,
      confirmation: described_class::CONFIRMATION_PHRASE,
      positions_service: positions_service,
      lifecycle: lifecycle,
      observer: always_fills,
      logger: logger,
      sleeper: ->(_seconds) {}, **overrides)
  end

  let(:always_fills) do
    Class.new do
      def observe(phase:, side:, intended_price:, order_result:, deadline:, poll_seconds: nil)
        Trading::ExecutionCalibration::Fill.new(
          phase: phase, side: side, order_id: order_result["order_id"], liquidity: "TAKER",
          intended_price: intended_price, fill_price: intended_price, commission: 0.198,
          contracts: 1.0, contract_multiplier: 0.01
        )
      end
    end.new
  end

  def order_ok(price: 64_370.0, fee: 0.65496)
    position = Position.create!(
      product_id: product_id, side: "LONG", size: 1, entry_price: price,
      entry_time: Time.current, status: "OPEN", paper: false, entry_fee: fee, day_trading: true
    )
    {"success" => true, "order_id" => SecureRandom.uuid, "price" => price, "fee" => fee,
     "position_id" => position.id}
  end

  # The venue's view of an open BIP position, in the shape /cfm/positions returns.
  def venue_position
    {"product_id" => product_id, "number_of_contracts" => "1", "side" => "LONG"}
  end

  around do |example|
    original = ENV["LIVE_TRADING_CONFIRMED"]
    ENV["LIVE_TRADING_CONFIRMED"] = "1"
    example.run
    ENV["LIVE_TRADING_CONFIRMED"] = original
  end

  before do
    BotRuntimeStat.delete_all
    Position.destroy_all
    Order.delete_all
    Contract.where(product_id: product_id).delete_all
    create(:contract, product_id: product_id, base_currency: "BTC")
    allow(Trading::EquityAssertion).to receive(:verify!).and_return({sizing: 373.0, actual: 373.0})
    allow(RecentMarketPrice).to receive(:for_product).and_return(64_370.0)
    allow(Trading::ContractSizeResolver).to receive(:for_product).and_return(0.01)
    allow(FeeMeasurementSnapshotJob).to receive(:perform_now)
    allow(positions_service).to receive(:open_position) { order_ok }
    allow(lifecycle).to receive(:close) do |position, **|
      position.update!(exit_fee: 0.65484)
      position.force_close!(64_355.0, "calibration", Time.current, pnl: -0.15)
      Trading::PositionLifecycle::Result.new(success: true, close_price: 64_355.0,
        reason: "calibration", fallback: false)
    end
  end

  # The tracer: exactly what happened live. The venue is stale for one read and
  # correct on the next.
  it "keeps going when the venue is momentarily stale after a close" do
    reads = 0
    allow(positions_service).to receive(:list_open_positions) do
      reads += 1
      (reads == 1) ? [venue_position] : []
    end

    report = live_runner.call

    expect(report.status).to eq(:completed)
    expect(report.tape.legs.count { |l| l.error }).to eq(0)
    expect(TradingHalt.risk_halted?).to be(false)
  end

  # The protection this issue is NOT about. Exposure that is really there must
  # still stop the run — a settle window that never gives up would be worse than
  # the bug it fixes.
  it "still aborts and halts when the venue is not flat for the whole window" do
    allow(positions_service).to receive(:list_open_positions).and_return([venue_position])

    report = live_runner.call

    expect(report.status).to eq(:aborted)
    expect(report.breach.reason).to include("NOT flat after closing leg 1")
    expect(TradingHalt.risk_halted?).to be(true)
  end

  # The abort reason names the instrument and nothing else, so it cannot tell a
  # stale local row from a stale venue response. That distinction is the whole
  # diagnosis, and on the live run it had to be reconstructed by hand afterwards.
  describe "it says which view disagreed" do
    it "names the venue when the venue is the one still reporting a position" do
      allow(positions_service).to receive(:list_open_positions).and_return([venue_position])

      live_runner.call

      expect(logger).to have_received(:info).with(/not flat on #{product_id}: the venue still reports 1 position/).at_least(:once)
    end

    it "names the local Position when the close has not landed locally" do
      allow(positions_service).to receive(:list_open_positions).and_return([])
      allow(lifecycle).to receive(:close) do |_position, **|
        Trading::PositionLifecycle::Result.new(success: true, close_price: 64_355.0,
          reason: "calibration", fallback: false)
      end

      live_runner.call

      expect(logger).to have_received(:info).with(/not flat on #{product_id}: a local Position is still OPEN/).at_least(:once)
    end
  end

  # A window that never closes is its own outage. The literal 5 is deliberate:
  # asserting against SETTLE_ATTEMPTS would move with the constant and pin
  # nothing, so widening the window has to be a deliberate edit here too.
  it "gives up after a bounded number of samples rather than polling forever" do
    reads = 0
    allow(positions_service).to receive(:list_open_positions) do
      reads += 1
      [venue_position]
    end

    live_runner.call

    expect(reads).to eq(5)
  end

  # Settling must stay cheap relative to the thing it protects. The whole window
  # has to fit inside one hold interval, or a run that settles on every leg
  # stretches its own measurement.
  it "settles well inside a single hold interval" do
    window = described_class::SETTLE_ATTEMPTS * described_class::SETTLE_POLL_SECONDS

    expect(window).to be <= described_class::DEFAULT_HOLD_SECONDS / 4
  end
end
