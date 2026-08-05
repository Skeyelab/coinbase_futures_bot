require_relative "../lib/candidate_evaluation"

# Stands in for a ratchet model. status_given is the whole interface the
# evaluation needs: what would this contract be, given that extreme?
class FakeMarket
  def initialize(ticker, by_extreme, settles_open_as: :refuted)
    @ticker = ticker
    @by_extreme = by_extreme
    @settles_open_as = settles_open_as
  end

  attr_reader :settles_open_as

  attr_reader :ticker

  def status_given(extreme)
    @by_extreme.fetch(extreme)
  end
end

RSpec.describe CandidateEvaluation do
  it "asks every candidate what it would have called, per settled market" do
    market = FakeMarket.new("KXHIGHTOKC-26AUG05-B83.5", {84.2 => :refuted, 87.8 => :confirmed})

    records = described_class.day_records(
      date: "2026-08-05",
      markets: [market],
      extremes: {"KOKC" => 84.2, "KPWA" => 87.8},
      settlements: {"KXHIGHTOKC-26AUG05-B83.5" => "yes"}
    )

    expect(records).to eq([{
      date: "2026-08-05",
      ticker: "KXHIGHTOKC-26AUG05-B83.5",
      settled: "yes",
      calls: [{station: "KOKC", says: "refuted"}, {station: "KPWA", says: "confirmed"}]
    }])
  end

  # A station whose reading leaves the contract still open has made no claim.
  # Recording that as a call would let settlement score it wrong and fault a
  # station for declining to guess -- and worse, an [open, refuted] pair looks
  # like disagreement, so it would manufacture evidence out of silence.
  it "drops candidates that had not yet called the market either way" do
    market = FakeMarket.new("KXHIGHTOKC-26AUG05-B83.5", {84.2 => :open, 87.8 => :confirmed})

    records = described_class.day_records(
      date: "2026-08-05", markets: [market],
      extremes: {"KOKC" => 84.2, "KPWA" => 87.8},
      settlements: {"KXHIGHTOKC-26AUG05-B83.5" => "yes"}
    )

    expect(records.first[:calls]).to eq([{station: "KPWA", says: "confirmed"}])
  end

  # status_given is a MID-DAY check: for a daily high, a reading below the
  # bucket is :open because the high can still climb. On a finished day it
  # cannot -- a high that never reached the bucket settled NO. Treating those
  # as "no claim" is what made 126 settled markets yield zero disagreement:
  # every cooler station said :open, got dropped, and left one lonely call.
  # A "83 or below" contract that stayed below all day settles YES. Mapping
  # every open call to refuted scored exactly that case backwards -- and it is
  # half the board, which is why 378 candidate calls yielded only 3 confirms.
  it "asks the market what open settles as, rather than assuming refuted" do
    market = FakeMarket.new("KXHIGHTSEA-26AUG04-T84", {80.6 => :open, 88.0 => :refuted},
      settles_open_as: :confirmed)

    records = described_class.day_records(
      date: "2026-08-04", markets: [market],
      extremes: {"KSEA" => 80.6, "KOTHER" => 88.0},
      settlements: {"KXHIGHTSEA-26AUG04-T84" => "yes"}, final: true
    )

    expect(records.first[:calls]).to eq([
      {station: "KSEA", says: "confirmed"}, {station: "KOTHER", says: "refuted"}
    ])
  end

  it "reads open as refuted once the day is over" do
    market = FakeMarket.new("KXHIGHTSEA-26AUG04-B79.5", {80.6 => :refuted, 73.4 => :open})

    records = described_class.day_records(
      date: "2026-08-04", markets: [market],
      extremes: {"KSEA" => 80.6, "KPAE" => 73.4},
      settlements: {"KXHIGHTSEA-26AUG04-B79.5" => "no"}, final: true
    )

    expect(records.first[:calls]).to eq([
      {station: "KSEA", says: "refuted"}, {station: "KPAE", says: "refuted"}
    ])
  end

  it "skips a market that has not settled yet" do
    market = FakeMarket.new("KXHIGHTOKC-26AUG05-B83.5", {84.2 => :refuted})

    records = described_class.day_records(
      date: "2026-08-05", markets: [market],
      extremes: {"KOKC" => 84.2}, settlements: {}
    )

    expect(records).to be_empty
  end
end
