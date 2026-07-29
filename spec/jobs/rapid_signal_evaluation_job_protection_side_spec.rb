# frozen_string_literal: true

require "rails_helper"

# The entry gate's side handling. This job is the only path that reaches
# open_position, so whatever it decides about a side is what actually trades.
#
# Two separate questions get asked about one value here, and they have
# different right answers:
#
#   1. "Does an active protection lock cover this side?" — answered by
#      Trading::Protections, which now normalizes both sides of the compare.
#      An unparseable side names no direction, so it matches no
#      direction-scoped lock (it is still bound by side "both" halts).
#   2. "Should we trade a side we cannot parse at all?" — answered here, and
#      the answer is no. Question 1 must not be made to answer it: whether a
#      long-scoped StoplossGuard lock happens to exist right now has nothing
#      to do with whether an unnameable direction is safe to send to the
#      exchange. Leaning on it would mean the refusal fires or does not fire
#      depending on unrelated market history.
RSpec.describe RapidSignalEvaluationJob, "protection gate side handling", type: :job do
  subject(:job) { described_class.new }

  before do
    job.instance_variable_set(:@logger, Rails.logger)
    job.instance_variable_set(:@asset, "BTC")
    job.instance_variable_set(:@current_price, 100.0)
    job.instance_variable_set(:@target_contract, "BIP-20DEC30-CDE")
    pass_cost_gate!("BIP-20DEC30-CDE")
    allow(described_class).to receive(:max_live_instruments).and_return(10)
    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
  end

  after { Trading::ProtectionLock.clear! }

  def gate(side) = job.send(:should_execute_signal?,
    {side: side, quantity: 1, confidence: 90, price: 100.0, tp: 101.0, sl: 99.0})

  describe "a side the gate can name" do
    it "permits an entry when nothing is locked" do
      expect(gate("BUY")).to be true
    end

    # The vocabularies that reach this gate: a strategy emits :long, an order
    # side is "BUY", Position#side is "LONG". A StoplossGuard lock is written
    # downcased. All four name one direction and all four must hit the lock.
    it "is stopped by a side-scoped lock whichever vocabulary names the side" do
      Trading::ProtectionLock.add(scope: "symbol", symbol: "BIP-20DEC30-CDE",
        side: "long", source: "StoplossGuard", expires_at: 10.minutes.from_now)

      ["BUY", "buy", "LONG", :long].each do |side|
        expect(gate(side)).to be(false), "expected #{side.inspect} to be blocked by a long lock"
      end
      expect(gate("SELL")).to be true
    end
  end

  describe "a side the gate cannot name" do
    # Fail closed. A side that normalizes to nothing is not a direction, and
    # the next thing this method does on a `true` is size and send an order.
    # There is no reading of "sideways" that makes placing a trade the correct
    # response, and permitting it is the same fail-open shape as the lock
    # mismatch this spec file exists because of.
    it "refuses the entry outright rather than trading an unnameable direction" do
      [nil, "", "sideways", "LNOG"].each do |side|
        expect(gate(side)).to be(false), "expected unparseable side #{side.inspect} to be refused"
      end
    end

    it "records the refusal in the decision ledger as its own reason" do
      decisions = instance_double(Trading::DecisionRecorder, rejected: nil)
      job.instance_variable_set(:@decisions, decisions)

      expect(decisions).to receive(:rejected).with(:unparseable_side, hash_including(:signal))
      gate("sideways")
    end

    # The refusal must not depend on which locks happen to exist.
    it "refuses whether or not a protection lock is active" do
      expect(gate("sideways")).to be false

      Trading::ProtectionLock.add(scope: "symbol", symbol: "BIP-20DEC30-CDE",
        side: "long", source: "StoplossGuard", expires_at: 10.minutes.from_now)

      expect(gate("sideways")).to be false
    end
  end
end
