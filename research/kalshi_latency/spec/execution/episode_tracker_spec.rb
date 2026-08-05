require_relative "../../lib/execution/episode_tracker"

RSpec.describe Execution::EpisodeTracker do
  it "measures how long a ticker has been sighted continuously" do
    tracker = described_class.new

    expect(tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1000)).to eq(0)
    expect(tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1060)).to eq(60)
    expect(tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1120)).to eq(120)
  end

  it "starts a fresh episode after a gap, same rule as the analyzer" do
    tracker = described_class.new(gap: 300)

    tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1000)
    # 301s of silence: the earlier episode ended; this sighting is a new one.
    expect(tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1301)).to eq(0)
  end

  it "keeps the episode alive at exactly the gap" do
    tracker = described_class.new(gap: 300)

    tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1000)
    # 300s of silence is the boundary: still the same episode. Only MORE than
    # the gap separates episodes -- same as the analyzer's arithmetic.
    expect(tracker.observe("KXHIGHNY-26AUG04-B83.5", at: 1300)).to eq(300)
  end

  it "measures dwell from the episode's start, not the previous sighting" do
    tracker = described_class.new(gap: 300)

    # Steady 60s cadence, total dwell 360s -- longer than the gap. Each hop is
    # small so the episode never breaks, and the dwell must keep growing.
    [1000, 1060, 1120, 1180, 1240, 1300].each { |t| tracker.observe("A", at: t) }
    expect(tracker.observe("A", at: 1360)).to eq(360)
  end

  it "tracks tickers independently" do
    tracker = described_class.new

    tracker.observe("A", at: 1000)
    expect(tracker.observe("B", at: 1060)).to eq(0)
    expect(tracker.observe("A", at: 1060)).to eq(60)
  end
end
