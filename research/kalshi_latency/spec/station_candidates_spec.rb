require_relative "../lib/station_candidates"
require_relative "../lib/cities"

RSpec.describe StationCandidates do
  # The lows live in their own constant. Walking only Cities::ALL silently
  # skipped nine of the twenty-one series, and mutation testing is the only
  # reason that was caught: dropping a LOW series entirely left this green.
  def unverified
    (Cities::ALL + Cities::LOWS).reject { |c| c[:verified] }
  end

  def unverified_series
    unverified.map { |c| c[:series] }
  end

  # Adding a city to cities.rb without a candidate list would silently give it
  # no route to promotion -- exactly the state all twelve were already in.
  it "covers every unverified series" do
    missing = unverified_series - described_class::BY_SERIES.keys

    expect(missing).to be_empty
  end

  # Settlement can only ever confirm a station that was in the running. Leaving
  # the incumbent out means the evidence can disprove it but never promote it.
  it "includes each series' own incumbent station among its candidates" do
    wrong = unverified.reject { |c|
      described_class::BY_SERIES.fetch(c[:series], []).include?(c[:station])
    }.map { |c| [c[:series], c[:station]] }

    expect(wrong).to be_empty
  end

  # One candidate can never disagree with itself, so it can never produce a
  # discriminating day. A list of one is a list that proves nothing, forever.
  it "gives every series at least two candidates" do
    thin = described_class::BY_SERIES.select { |_s, ids| ids.size < 2 }

    expect(thin).to be_empty
  end

  it "uses well-formed four-letter METAR ids" do
    bad = described_class::BY_SERIES.values.flatten.uniq.reject { |id| id.match?(/\AK[A-Z]{3}\z/) }

    expect(bad).to be_empty
  end
end
