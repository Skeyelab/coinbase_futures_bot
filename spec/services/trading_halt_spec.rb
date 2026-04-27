# frozen_string_literal: true

require "rails_helper"

RSpec.describe TradingHalt do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:logger) { instance_double(Logger, warn: true, info: true) }
  let(:halt) { described_class.new(logger: logger, cache: cache) }

  before { cache.clear }

  describe "#active?" do
    it "returns true when no cache entry exists (default-on)" do
      expect(halt.active?).to be true
    end

    it "returns false after halt!" do
      halt.halt!
      expect(halt.active?).to be false
    end

    it "returns true after resume!" do
      halt.halt!
      halt.resume!
      expect(halt.active?).to be true
    end
  end

  describe "#halted?" do
    it "is the inverse of active?" do
      expect(halt.halted?).to be false
      halt.halt!
      expect(halt.halted?).to be true
    end
  end

  describe "#halt!" do
    it "persists the reason" do
      halt.halt!(reason: "margin call")
      expect(halt.status[:reason]).to eq("margin call")
    end

    it "logs a warning" do
      halt.halt!(reason: "test")
      expect(logger).to have_received(:warn).with("[TradingHalt] Trading HALTED: test")
    end

    it "returns a status hash" do
      result = halt.halt!
      expect(result).to include(active: false, halted: true)
    end
  end

  describe "#resume!" do
    it "clears the reason" do
      halt.halt!(reason: "margin call")
      halt.resume!
      expect(halt.status[:reason]).to be_nil
    end

    it "logs an info message" do
      halt.resume!
      expect(logger).to have_received(:info).with("[TradingHalt] Trading RESUMED")
    end

    it "returns a status hash" do
      result = halt.resume!
      expect(result).to include(active: true, halted: false)
    end
  end

  describe "#status" do
    it "includes active, halted, reason, and as_of" do
      status = halt.status
      expect(status.keys).to include(:active, :halted, :reason, :as_of)
    end
  end

  describe ".assert_active!" do
    it "does nothing when trading is active" do
      allow(described_class).to receive(:active?).and_return(true)
      expect { described_class.assert_active! }.not_to raise_error
    end

    it "raises HaltedError when trading is halted" do
      allow(described_class).to receive(:active?).and_return(false)
      allow(Rails.cache).to receive(:read).with(described_class::CACHE_KEY_REASON).and_return(nil)
      expect { described_class.assert_active! }.to raise_error(described_class::HaltedError, /Trading is halted/)
    end

    it "includes the reason in the error message" do
      allow(described_class).to receive(:active?).and_return(false)
      allow(Rails.cache).to receive(:read).with(described_class::CACHE_KEY_REASON).and_return("margin call")
      expect { described_class.assert_active! }.to raise_error(described_class::HaltedError, /margin call/)
    end

    it "includes the context in the error message" do
      allow(described_class).to receive(:active?).and_return(false)
      allow(Rails.cache).to receive(:read).with(described_class::CACHE_KEY_REASON).and_return(nil)
      expect { described_class.assert_active!(context: "MyService#place_order") }
        .to raise_error(described_class::HaltedError, /MyService#place_order/)
    end
  end

  describe "class-level helpers" do
    before do
      allow(Rails.cache).to receive(:read).and_call_original
      allow(Rails.cache).to receive(:write).and_call_original
      allow(Rails.cache).to receive(:delete).and_call_original
    end

    it ".active? delegates to instance" do
      expect(described_class.active?).to be(true).or be(false)
    end

    it ".halted? is the inverse of .active?" do
      expect(described_class.halted?).to eq(!described_class.active?)
    end

    it ".status returns a hash" do
      expect(described_class.status).to be_a(Hash)
    end
  end
end
