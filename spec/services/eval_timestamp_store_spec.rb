# frozen_string_literal: true

require "rails_helper"

RSpec.describe EvalTimestampStore do
  describe ".write and .read" do
    it "round-trips through the database when cache is NullStore" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new

      freeze_time do
        described_class.write(Time.current.utc)

        expect(described_class.read).to eq(Time.current.utc)
      end
    ensure
      Rails.cache = original_cache
    end

    it "prefers cache when present" do
      cached_at = 5.seconds.ago.utc.change(usec: 0)
      db_at = 60.seconds.ago.utc.change(usec: 0)

      described_class.write(db_at)
      Rails.cache.write(described_class::CACHE_KEY, cached_at, expires_in: 10.minutes)

      expect(described_class.read).to eq(cached_at)
    end

    it "falls back to latest signal alert when no durable row exists" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      alert_time = 2.minutes.ago.utc.change(usec: 0)
      create(:signal_alert, alert_timestamp: alert_time)

      expect(described_class.read).to eq(alert_time)
    ensure
      Rails.cache = original_cache
    end
  end
end
