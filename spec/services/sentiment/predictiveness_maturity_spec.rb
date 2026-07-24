# frozen_string_literal: true

require "rails_helper"

RSpec.describe Sentiment::PredictivenessMaturity do
  describe ".label" do
    it "is low when there are few samples" do
      expect(described_class.label(n: 8, signal_count: 2)).to eq("low")
    end

    it "is moderate once there are enough total samples" do
      expect(described_class.label(n: 50, signal_count: 25)).to eq("moderate")
    end

    it "is high only with many samples AND enough signal-strength observations" do
      expect(described_class.label(n: 150, signal_count: 30)).to eq("high")
    end

    it "stays moderate when total samples are high but signal observations are too few" do
      # hit_rate needs enough |z|>=threshold cases to be trustworthy.
      expect(described_class.label(n: 150, signal_count: 5)).to eq("moderate")
    end
  end
end
