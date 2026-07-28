# frozen_string_literal: true

require "rails_helper"

# Issue #550. Only a raised exception counted as failure, so a source returning
# zero events was recorded in successful_sources. cryptopanic sat there on every
# run it ever made while producing nothing, the completion log read "9/9
# sources", and Sentry was never notified.
RSpec.describe Sentiment::MultiSourceAggregator, "empty sources are not successes (#550)" do
  def client(name, events:, raises: false)
    double(name, source_name: name, enabled?: true).tap do |c|
      if raises
        allow(c).to receive(:fetch_recent).and_raise(StandardError, "upstream down")
      else
        allow(c).to receive(:fetch_recent).and_return(events)
      end
    end
  end

  def aggregator_with(*clients)
    described_class.new(clients: clients)
  end

  let(:event) { {source: "x", title: "t", url: "u"} }

  before { allow(SentryHelper).to receive(:add_breadcrumb) }

  it "does not count a zero-event source as delivering" do
    agg = aggregator_with(client("live", events: [event]), client("silent", events: []))

    agg.fetch_all_sources

    expect(SentryHelper).to have_received(:add_breadcrumb) do |args|
      expect(args[:data][:successful_sources]).to eq(["live"])
      expect(args[:data][:empty_sources]).to eq(["silent"])
    end
  end

  it "reports a success rate that reflects what actually delivered" do
    agg = aggregator_with(client("live", events: [event]), client("silent", events: []))

    agg.fetch_all_sources

    expect(SentryHelper).to have_received(:add_breadcrumb) do |args|
      expect(args[:data][:success_rate]).to eq(0.5)
    end
  end

  it "still separates a raising source from a merely empty one" do
    agg = aggregator_with(client("live", events: [event]),
      client("silent", events: []),
      client("broken", events: nil, raises: true))
    allow(Sentry).to receive(:with_scope)

    agg.fetch_all_sources

    expect(SentryHelper).to have_received(:add_breadcrumb) do |args|
      expect(args[:data][:successful_sources]).to eq(["live"])
      expect(args[:data][:empty_sources]).to eq(["silent"])
      expect(args[:data][:failed_sources]).to eq(["broken"])
    end
  end

  it "warns by name so an empty source is greppable in the log" do
    allow(Rails.logger).to receive(:warn)
    aggregator_with(client("silent", events: [])).fetch_all_sources

    expect(Rails.logger).to have_received(:warn).with(/silent: returned 0 events/)
  end

  it "still returns the events it did collect" do
    agg = aggregator_with(client("live", events: [event]), client("silent", events: []))

    expect(agg.fetch_all_sources).to eq([event])
  end

  it "names the empty sources in the completion log" do
    allow(Rails.logger).to receive(:info).and_call_original
    aggregator_with(client("live", events: [event]), client("silent", events: [])).fetch_all_sources

    expect(Rails.logger).to have_received(:info)
      .with(/1\/2 delivering, 1 empty \(silent\), 0 failed/)
  end

  it "keeps the completion log clean when nothing is empty" do
    allow(Rails.logger).to receive(:info).and_call_original
    aggregator_with(client("live", events: [event])).fetch_all_sources

    expect(Rails.logger).to have_received(:info)
      .with(/1\/1 delivering, 0 empty, 0 failed/)
  end

  describe "the source registry" do
    it "no longer wires the dead cryptopanic client" do
      names = described_class.new.source_status.map { |s| s[:name] }

      expect(names).not_to include("cryptopanic")
    end

    it "still wires the sources that work" do
      names = described_class.new.source_status.map { |s| s[:name] }

      expect(names).to include(
        "coindesk_rss", "cointelegraph_rss",
        "blockworks_rss", "decrypt_rss", "cryptobriefing_rss"
      )
    end
  end
end
