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
  end
end
