# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealtimeMonitoring::Session do
  subject(:session) { described_class.new(logger: logger) }

  let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil) }
  let(:futures_subscriber) { instance_double(MarketData::CoinbaseFuturesSubscriber, start: nil, stop: nil) }

  before do
    described_class.reset_current!
    allow(MarketData::RealtimeSubscriptionCatalog).to receive(:futures_product_ids).and_return(["NOL-19JUN26-CDE"])
    allow(MarketData::RealtimeSubscriptionCatalog).to receive(:spot_product_ids).and_return([])
    allow(MarketData::CoinbaseFuturesSubscriber).to receive(:new).and_return(futures_subscriber)
    allow(MarketData::CoinbaseSpotSubscriber).to receive(:new)
    allow(Thread).to receive(:new).and_wrap_original do |original, &block|
      thread = original.call(&block)
      allow(thread).to receive(:alive?).and_return(true)
      thread
    end
  end

  after do
    described_class.reset_current!
  end

  describe "#start!" do
    it "starts futures monitoring for enabled products" do
      result = session.start!

      expect(result[:success]).to be(true)
      expect(session.active?).to be(true)
      expect(session.status[:futures_product_ids]).to eq(["NOL-19JUN26-CDE"])
    end

    it "returns an error when already running" do
      session.start!

      result = session.start!

      expect(result[:success]).to be(false)
      expect(result[:error]).to match(/already running/i)
    end
  end

  describe "#stop!" do
    it "stops an active session" do
      session.start!
      thread = session.instance_variable_get(:@threads).first
      allow(thread).to receive(:alive?).and_return(true, false)

      result = session.stop!

      expect(result[:success]).to be(true)
      expect(futures_subscriber).to have_received(:stop)
    end
  end

  describe "#toggle!" do
    it "starts when off and stops when on" do
      expect(session.toggle![:success]).to be(true)
      allow(session.instance_variable_get(:@threads).first).to receive(:alive?).and_return(false)

      expect(session.toggle![:success]).to be(true)
    end
  end
end
