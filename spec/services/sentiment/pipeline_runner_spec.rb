# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::PipelineRunner do
  let(:calls) { [] }
  let(:fetch_job) { class_double(FetchNewsJob).tap { |d| allow(d).to receive(:perform_now) { calls << :fetch } } }
  let(:score_job) { class_double(ScoreSentimentJob).tap { |d| allow(d).to receive(:perform_now) { calls << :score } } }
  let(:aggregate_job) { class_double(AggregateSentimentJob).tap { |d| allow(d).to receive(:perform_now) { calls << :aggregate } } }

  def build(interval_seconds: 120)
    described_class.new(
      fetch_jobs: [fetch_job],
      score_job: score_job,
      aggregate_job: aggregate_job,
      interval_seconds: interval_seconds,
      logger: Logger.new(File::NULL)
    )
  end

  it "runs fetch, then score, then aggregate on start!" do
    build.start!

    expect(calls).to eq([:fetch, :score, :aggregate])
  end

  it "runs on the first tick, then skips until the interval elapses" do
    t0 = Time.utc(2026, 7, 17, 12, 0, 0)
    runner = build(interval_seconds: 120)

    runner.tick(now: t0)              # never run before -> runs
    runner.tick(now: t0 + 60)         # within interval -> skip
    runner.tick(now: t0 + 120)        # interval elapsed -> runs

    expect(calls.count(:fetch)).to eq(2)
    expect(calls.count(:aggregate)).to eq(2)
  end

  it "keeps running later ticks even if one job raises" do
    allow(fetch_job).to receive(:perform_now).and_raise(StandardError, "boom")
    t0 = Time.utc(2026, 7, 17, 12, 0, 0)
    runner = build(interval_seconds: 120)

    expect { runner.tick(now: t0) }.not_to raise_error
    expect { runner.tick(now: t0 + 120) }.not_to raise_error
    expect(fetch_job).to have_received(:perform_now).twice
  end
end
