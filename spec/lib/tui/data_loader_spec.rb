# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::DataLoader do
  describe ".load" do
    it "includes last_eval_at from EvalTimestampStore" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new

      freeze_time do
        EvalTimestampStore.write(Time.current.utc)

        expect(described_class.load[:last_eval_at]).to eq(Time.current.utc)
      end
    ensure
      Rails.cache = original_cache
    end

    it "includes a sentiment snapshot" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      allow(Tui::ExchangePnlRefresher).to receive(:refresh!).and_return(false)

      expect(described_class.load[:sentiment]).to be_a(Sentiment::Snapshot::Result)
    ensure
      Rails.cache = original_cache
    end

    it "includes the enabled contract count" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      allow(Tui::ExchangePnlRefresher).to receive(:refresh!).and_return(false)
      create(:contract, enabled: true, product_id: "NOL-19JUN26-CDE", base_currency: "OIL")
      create(:contract, enabled: false, product_id: "BIT-29AUG25-CDE")

      expect(described_class.load[:enabled_contract_count]).to eq(1)
    ensure
      Rails.cache = original_cache
    end

    it "includes the realtime loop heartbeat so a dead loop is visible in the TUI" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      allow(Tui::ExchangePnlRefresher).to receive(:refresh!).and_return(false)
      Heartbeat.beat!("realtime_signal")

      loop_hb = described_class.load[:loop_heartbeat]

      expect(loop_hb).to include(name: "realtime_signal", stale: false)
    ensure
      Rails.cache = original_cache
    end

    it "includes the market-data WS feed heartbeat" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      allow(Tui::ExchangePnlRefresher).to receive(:refresh!).and_return(false)
      Heartbeat.beat!("market_data")

      md = described_class.load[:market_data_heartbeat]

      expect(md).to include(name: "market_data", stale: false)
    ensure
      Rails.cache = original_cache
    end

    it "includes the dry-run flag" do
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::NullStore.new
      allow(Tui::ExchangePnlRefresher).to receive(:refresh!).and_return(false)
      DryRun.enable!

      expect(described_class.load[:dry_run]).to be true
    ensure
      Rails.cache = original_cache
    end
  end
end
