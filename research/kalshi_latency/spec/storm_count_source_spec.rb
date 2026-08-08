require_relative "../lib/storm_count_source"

RSpec.describe StormCountSource do
  # NHC publishes active storms as JSON. A season's NAMED-storm count is
  # monotone: a storm that was named cannot be un-named, so the count only
  # rises. Kalshi's KXNAMEDSTORM markets are `greater` strikes on that count
  # per basin ("more than 26 named storms in the Eastern Pacific").
  def payload(*storms)
    {"activeStorms" => storms}
  end

  def storm(name:, basin:, id: nil, classification: "TS")
    {"name" => name, "binNumber" => basin, "id" => id || "#{basin}#{name}",
     "classification" => classification}
  end

  it "counts distinct named storms seen in a basin" do
    source = described_class.new(fetch: -> { payload(storm(name: "Alex", basin: "EP1"), storm(name: "Blas", basin: "EP2")) })

    source.observe!
    expect(source.count("EPAC")).to eq(2)
  end

  it "does not double-count a storm seen on successive polls" do
    seen = payload(storm(name: "Alex", basin: "EP1"))
    source = described_class.new(fetch: -> { seen })

    3.times { source.observe! }

    expect(source.count("EPAC")).to eq(1)
  end

  it "keeps a storm counted after it dissipates off the active list" do
    # THE RATCHET. A named storm leaves activeStorms when it dies; the season
    # count must not fall with it, or contracts the season has confirmed would
    # silently un-confirm.
    first = payload(storm(name: "Alex", basin: "EP1"))
    second = payload
    responses = [first, second]
    source = described_class.new(fetch: -> { responses.shift || second })

    source.observe!
    source.observe!

    expect(source.count("EPAC")).to eq(1)
  end

  it "separates basins" do
    source = described_class.new(fetch: -> {
      payload(storm(name: "Alex", basin: "EP1"), storm(name: "Bonnie", basin: "AL1"))
    })

    source.observe!
    expect(source.count("EPAC")).to eq(1)
    expect(source.count("ATL")).to eq(1)
  end

  it "ignores an unnamed depression, which is not a named storm" do
    source = described_class.new(fetch: -> {
      payload(storm(name: "Seven", basin: "EP7", classification: "TD"))
    })

    source.observe!
    expect(source.count("EPAC")).to eq(0)
  end

  it "survives a failed fetch without losing the running count" do
    good = payload(storm(name: "Alex", basin: "EP1"))
    calls = 0
    source = described_class.new(fetch: -> {
      calls += 1
      (calls == 1) ? good : raise("network")
    })

    source.observe!
    source.observe!

    expect(source.count("EPAC")).to eq(1)
  end

  # The specs always injected a fetcher, so the DEFAULT path -- the one
  # production uses -- was never constructed. It raised NameError on
  # method(:http_fetch) because the method was private. A source that cannot be
  # built without a test double is not a source.
  it "constructs with its real HTTP fetcher" do
    expect { described_class.new }.not_to raise_error
  end
end
