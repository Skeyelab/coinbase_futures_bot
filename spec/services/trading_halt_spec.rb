# frozen_string_literal: true

require "rails_helper"

RSpec.describe TradingHalt do
  let(:logger) { instance_double(Logger, warn: true, info: true) }
  let(:halt) { described_class.new(logger: logger) }

  # The store is DB-backed (bot_runtime_stats). Clear the cache in each example
  # to prove the cache is NOT the source of truth for halt state.
  before { Rails.cache.clear }

  describe "#active?" do
    it "returns true when no record exists (default-on)" do
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

  describe "cross-process durability (the #289 fix)" do
    it "a halt from one instance is visible to a separately constructed instance" do
      described_class.new(logger: logger).halt!(reason: "cpi print")

      fresh = described_class.new(logger: logger)
      expect(fresh.halted?).to be true
      expect(fresh.status[:reason]).to eq("cpi print")
    end

    it "remains halted after the cache is cleared (state is not cache-backed)" do
      halt.halt!(reason: "durability")
      Rails.cache.clear

      expect(described_class.new(logger: logger).halted?).to be true
    end

    it "persists the halt in bot_runtime_stats so it survives a process restart" do
      halt.halt!(reason: "restart-proof")
      # Simulate a fresh boot: nothing in memory/cache, only the DB row remains.
      Rails.cache.clear
      expect(BotRuntimeStat.find_by(key: described_class::STORE_KEY)).to be_present
      expect(described_class.active?).to be false
    end
  end

  describe "TTL auto-expiry" do
    it "auto-resumes once the halt is older than the TTL" do
      halt.halt!(reason: "stale")
      BotRuntimeStat.find_by(key: described_class::STORE_KEY)
        .update!(recorded_at: (described_class::DEFAULT_TTL_HOURS + 1).hours.ago)

      expect(halt.active?).to be true
    end

    it "stays halted while within the TTL window" do
      halt.halt!(reason: "fresh")
      BotRuntimeStat.find_by(key: described_class::STORE_KEY)
        .update!(recorded_at: 1.hour.ago)

      expect(halt.active?).to be false
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
      expect { described_class.assert_active! }.not_to raise_error
    end

    it "raises HaltedError when trading is halted" do
      described_class.halt!
      expect { described_class.assert_active! }.to raise_error(described_class::HaltedError, /Trading is halted/)
    end

    it "includes the reason in the error message" do
      described_class.halt!(reason: "margin call")
      expect { described_class.assert_active! }.to raise_error(described_class::HaltedError, /margin call/)
    end

    it "includes the context in the error message" do
      described_class.halt!
      expect { described_class.assert_active!(context: "MyService#place_order") }
        .to raise_error(described_class::HaltedError, /MyService#place_order/)
    end
  end

  describe "class-level helpers" do
    it ".active? delegates to instance" do
      expect(described_class.active?).to be true
      described_class.halt!
      expect(described_class.active?).to be false
    end

    it ".halted? is the inverse of .active?" do
      expect(described_class.halted?).to eq(!described_class.active?)
    end

    it ".status returns a hash" do
      expect(described_class.status).to be_a(Hash)
    end
  end
end
