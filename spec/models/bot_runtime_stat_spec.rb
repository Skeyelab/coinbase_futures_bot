# frozen_string_literal: true

require "rails_helper"

# Issue #546. Keyed singleton state (halt, dry-run, heartbeats, the drawdown
# peak) was written as find_or_initialize -> save! under a unique index on
# `key`. Two connections inserting the same key concurrently take conflicting
# index locks, and two of them in opposite order deadlock — the CI flake that
# turned a red X on a MaxDrawdown spec into an infrastructure investigation.
# upsert_value! is a single INSERT ... ON CONFLICT DO UPDATE: atomic, no
# read-modify-write window, nothing to retry.
RSpec.describe BotRuntimeStat do
  describe ".upsert_value!" do
    it "creates the row when the key is absent" do
      described_class.upsert_value!(key: "test:upsert", value: {"n" => 1})

      record = described_class.find_by(key: "test:upsert")
      expect(record.value).to eq({"n" => 1})
      expect(record.recorded_at).to be_within(5).of(Time.current)
    end

    it "overwrites value and recorded_at when the key exists" do
      described_class.create!(key: "test:upsert", value: {"n" => 1},
        recorded_at: 1.hour.ago)

      described_class.upsert_value!(key: "test:upsert", value: {"n" => 2})

      record = described_class.find_by(key: "test:upsert")
      expect(record.value).to eq({"n" => 2})
      expect(record.recorded_at).to be_within(5).of(Time.current)
      expect(described_class.where(key: "test:upsert").count).to eq(1)
    end

    it "is what the whole-value writers use — no insert race window" do
      # Heartbeat and the drawdown peak overwrite their entire value each
      # write; they must not go through find_or_initialize/save.
      expect(Heartbeat.instance_method(:beat!).source_location.first)
        .to end_with("app/services/heartbeat.rb")
      source = File.read(Rails.root.join("app/services/heartbeat.rb"))
      expect(source).to include("upsert_value!")
      expect(source).not_to include("find_or_initialize_by")

      monitor = File.read(Rails.root.join("app/services/trading/protections/max_drawdown_monitor.rb"))
      expect(monitor).to include("upsert_value!")
      expect(monitor).not_to include("find_or_initialize_by")
    end
  end
end
