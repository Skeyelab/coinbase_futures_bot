# frozen_string_literal: true

require "rails_helper"

RSpec.describe Heartbeat do
  let(:now) { Time.utc(2026, 7, 20, 12, 0, 0) }

  describe ".beat! + .status" do
    it "records a beat and reports it as fresh" do
      described_class.beat!("realtime_signal", now: now)

      status = described_class.status("realtime_signal", now: now + 5)

      expect(status[:last_beat_at]).to eq("2026-07-20T12:00:00Z")
      expect(status[:age_seconds]).to eq(5)
      expect(status[:stale]).to be(false)
    end

    it "reports stale once the beat is older than the staleness window" do
      described_class.beat!("realtime_signal", now: now)

      status = described_class.status("realtime_signal", stale_after: 90, now: now + 120)

      expect(status[:age_seconds]).to eq(120)
      expect(status[:stale]).to be(true)
    end

    it "overwrites the previous beat rather than duplicating rows" do
      described_class.beat!("realtime_signal", now: now)
      described_class.beat!("realtime_signal", now: now + 30)

      expect(BotRuntimeStat.where(key: "heartbeat:realtime_signal").count).to eq(1)
      expect(described_class.status("realtime_signal", now: now + 30)[:last_beat_at])
        .to eq("2026-07-20T12:00:30Z")
    end

    it "reports stale with no last_beat_at when the loop has never beaten" do
      status = described_class.status("never_started", now: now)

      expect(status[:last_beat_at]).to be_nil
      expect(status[:age_seconds]).to be_nil
      expect(status[:stale]).to be(true)
    end

    it "isolates heartbeats by name" do
      described_class.beat!("signal_loop", now: now)

      expect(described_class.status("sentiment_loop", now: now)[:stale]).to be(true)
      expect(described_class.status("signal_loop", now: now)[:stale]).to be(false)
    end
  end
end
