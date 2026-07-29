# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Trainer do
  describe ".time_split" do
    let(:from) { Time.utc(2026, 1, 1) }
    let(:to) { from + 10.hours }
    let(:timestamps) { (0..20).map { |k| from + k * 30.minutes } }

    it "splits on time only: first 70% of the span trains, the rest evaluates" do
      split = described_class.time_split(timestamps, from: from, to: to,
        train_fraction: 0.7, embargo_seconds: 3600)

      cutoff = from + 7.hours
      expect(split[:cutoff]).to eq(cutoff)
      # Train labels must RESOLVE before the cutoff: ts + embargo <= cutoff.
      expect(split[:train]).to eq(timestamps.each_index.select { |i| timestamps[i] + 3600 <= cutoff })
      expect(split[:eval]).to eq(timestamps.each_index.select { |i| timestamps[i] > cutoff })
      # The overlap zone is embargoed, not smuggled into either side.
      expect(split[:embargoed]).to eq(timestamps.each_index.select { |i|
        timestamps[i] + 3600 > cutoff && timestamps[i] <= cutoff
      })
    end

    it "keeps every train bar's entire label window before every eval bar (no overlap leakage)" do
      split = described_class.time_split(timestamps, from: from, to: to,
        train_fraction: 0.7, embargo_seconds: 3600)

      last_train_resolution = timestamps[split[:train].max] + 3600
      first_eval = timestamps[split[:eval].min]
      expect(last_train_resolution).to be <= first_eval
    end

    it "partitions: every index lands in exactly one bucket" do
      split = described_class.time_split(timestamps, from: from, to: to,
        train_fraction: 0.7, embargo_seconds: 3600)

      all = split[:train] + split[:embargoed] + split[:eval]
      expect(all.sort).to eq((0..20).to_a)
    end
  end

  describe "#run" do
    let(:t0) { Time.utc(2026, 1, 1) }
    let(:from) { t0 + 5.hours }
    let(:to) { t0 + 15.hours }
    let(:symbol_a) { "AAA-20DEC30-CDE" }
    let(:symbol_b) { "BBB-20DEC30-CDE" }
    let(:shape) { {tp_frac: 0.02, sl_frac: 0.012, horizon: 12} }

    def seed_labels(symbol)
      rows = (0..119).map do |k|
        ts = from + k * 300
        label = if k % 3 == 0
          "win"
        else
          ((k % 3 == 1) ? "loss" : "unresolved")
        end
        {symbol: symbol, timeframe: "5m", bar_timestamp: ts, direction: "long",
         label: label, tp_frac: 0.02, sl_frac: 0.012, horizon: 12,
         created_at: Time.current, updated_at: Time.current}
      end
      PathDependentLabel.insert_all(rows)
    end

    before do
      seed_series(symbol_a, start_at: t0, hours: 16)
      seed_series(symbol_b, start_at: t0, hours: 16, base: 250.0)
      seed_labels(symbol_a)
      seed_labels(symbol_b)
    end

    def run_trainer(version: "test-fit-v1")
      described_class.new(symbols: [symbol_a, symbol_b], direction: "long",
        from: from, to: to, timeframe: "5m", train_fraction: 0.7,
        extractor_config: tiny_extractor_config, version: version, **shape).run
    end

    it "persists a FROZEN artifact with coefficients for every feature plus symbol dummies" do
      result = run_trainer

      artifact = result[:artifact].reload
      expect(artifact.frozen_artifact?).to be(true)
      expect(artifact.version).to eq("test-fit-v1")
      expect(artifact.direction).to eq("long")
      expect(artifact.tp_frac.to_f).to eq(0.02)

      weights = artifact.coefficients.fetch("weights")
      expect(weights.keys).to match_array(Ml::FeatureExtractor::FEATURE_NAMES + ["symbol=#{symbol_b}"])
      expect(artifact.coefficients.fetch("intercept")).to be_a(Float)
    end

    it "stores the feature spec needed to reproduce inputs: names, symbols, baseline, train-only standardization" do
      artifact = run_trainer[:artifact]

      spec = artifact.feature_spec
      expect(spec.fetch("feature_names")).to eq(Ml::FeatureExtractor::FEATURE_NAMES)
      expect(spec.fetch("symbols")).to eq([symbol_a, symbol_b])
      expect(spec.fetch("baseline_symbol")).to eq(symbol_a)

      stds = spec.dig("standardization", "stds")
      means = spec.dig("standardization", "means")
      expect(means.keys).to match_array(Ml::FeatureExtractor::FEATURE_NAMES)
      expect(stds.values).to all(be > 0)
    end

    it "reports the time split, dataset sizes, and the out-of-sample calibration deciles" do
      report = run_trainer[:report]

      dataset = report[:dataset]
      expect(dataset[:cutoff_at]).to eq(from + 7.hours)
      expect(dataset[:rows_total]).to eq(dataset[:train_rows] + dataset[:embargoed_rows] + dataset[:eval_rows])
      expect(dataset[:train_rows]).to be > 0
      expect(dataset[:eval_rows]).to be > 0
      expect(dataset[:symbols]).to eq([symbol_a, symbol_b])

      deciles = report[:evaluation][:deciles]
      expect(deciles.size).to eq(10)
      expect(deciles.sum { |d| d[:n] }).to eq(dataset[:eval_rows])

      cutoffs = report[:evaluation][:cutoffs]
      expect(cutoffs).to all(include(:cutoff, :n, :realized_rate, :per_year))
    end

    it "is deterministic: refitting the same data yields identical coefficients" do
      first = run_trainer[:artifact]
      second = run_trainer(version: "test-fit-v2")[:artifact]

      expect(second.coefficients).to eq(first.coefficients)
      expect(second.feature_spec["standardization"]).to eq(first.feature_spec["standardization"])
    end

    it "produces an artifact the scorer can load and score deterministically" do
      artifact = run_trainer[:artifact]
      scorer = Ml::ArtifactScorer.new(ScorerArtifact.find(artifact.id))

      features = Ml::FeatureExtractor::FEATURE_NAMES.index_with { 0.001 }
      p = scorer.score(symbol: symbol_b, features: features)

      expect(p).to be_between(0.0, 1.0).exclusive
      expect(scorer.score(symbol: symbol_b, features: features)).to eq(p)
    end

    it "refuses to run when a split side would be empty" do
      expect {
        described_class.new(symbols: [symbol_a], direction: "long",
          from: from, to: from + 1.hour, timeframe: "5m", train_fraction: 0.7,
          extractor_config: tiny_extractor_config, version: "test-empty", **shape).run
      }.to raise_error(ArgumentError, /side is empty/)
    end
  end
end

# Appended regression (2026-07-29): the first pooled 4-symbol fit on the box
# died with SystemStackError because row selection splatted ~300k indices as
# VM stack arguments (rows.values_at(*indices)). Specs never hit it — their
# datasets are tiny. This pins selection at real pooled scale.
RSpec.describe Ml::Trainer, ".select_rows at pooled scale" do
  it "selects 300k indices without exhausting the VM stack" do
    rows = Array.new(300_000) { |i| {i: i} }
    indices = (0...300_000).to_a

    selected = described_class.select_rows(rows, indices)

    expect(selected.size).to eq(300_000)
    expect(selected.first).to eq({i: 0})
    expect(selected.last).to eq({i: 299_999})
  end
end
