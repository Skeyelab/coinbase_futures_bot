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
  end
end
