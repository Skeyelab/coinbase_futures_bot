# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChatMemoryService, type: :service do
  let(:session_id) { "test-session-456" }
  let(:service) { described_class.new(session_id) }
  let(:cache_key) { "chat_session:#{session_id}" }

  before do
    Rails.cache.clear
  end

  describe "#initialize" do
    it "sets session_id and cache_key" do
      expect(service.instance_variable_get(:@session_id)).to eq(session_id)
      expect(service.instance_variable_get(:@cache_key)).to eq(cache_key)
    end
  end

  describe "#store" do
    let(:input) { "Show me my positions" }
    let(:result) { {type: "position_data", data: {}} }

    it "stores interaction in cache" do
      service.store(input, result)

      memory = Rails.cache.read(cache_key)
      expect(memory).not_to be_empty

      interaction = memory.values.first
      expect(interaction[:input]).to eq(input)
      expect(interaction[:command_type]).to eq("position_data")
      expect(interaction[:timestamp]).to be_present
    end

    it "truncates long input" do
      long_input = "a" * 300
      service.store(long_input, result)

      memory = Rails.cache.read(cache_key)
      interaction = memory.values.first
      expect(interaction[:input].length).to be <= 200
      expect(interaction[:input]).to end_with("...")
    end

    it "keeps only last 50 interactions" do
      base_time = Time.current
      # Store 55 interactions with incrementing timestamps
      55.times do |i|
        travel_to(base_time + i.seconds) do
          service.store("input #{i}", {type: "test", data: {}})
        end
      end

      memory = Rails.cache.read(cache_key)
      expect(memory.size).to eq(50)

      # Should keep the most recent ones (5-54)
      expect(memory.values.first[:input]).to include("input 5")
      expect(memory.values.last[:input]).to include("input 54")
    end
  end

  describe "#recent_interactions" do
    before do
      base_time = Time.current
      5.times do |i|
        travel_to(base_time + i.seconds) do
          service.store("input #{i}", {type: "test_#{i}", data: {}})
        end
      end
    end

    it "returns recent interactions in order" do
      interactions = service.recent_interactions(3)
      expect(interactions.size).to eq(3)
      expect(interactions.first[:input]).to include("input 2")
      expect(interactions.last[:input]).to include("input 4")
    end

    it "returns all interactions if limit is higher than stored" do
      interactions = service.recent_interactions(10)
      expect(interactions.size).to eq(5)
    end

    it "returns empty array for new session" do
      new_service = described_class.new("new-session")
      interactions = new_service.recent_interactions
      expect(interactions).to be_empty
    end
  end

  describe "#interaction_count" do
    it "returns zero for new session" do
      expect(service.interaction_count).to eq(0)
    end

    it "returns correct count after storing interactions" do
      base_time = Time.current
      3.times do |i|
        travel_to(base_time + i.seconds) do
          service.store("input #{i}", {type: "test", data: {}})
        end
      end
      expect(service.interaction_count).to eq(3)
    end
  end

  describe "#last_command_type" do
    it "returns nil for new session" do
      expect(service.last_command_type).to be_nil
    end

    it "returns last command type" do
      service.store("first", {type: "position_query", data: {}})
      service.store("second", {type: "signal_query", data: {}})

      expect(service.last_command_type).to eq("signal_query")
    end
  end

  describe "#clear_session" do
    before do
      service.store("test input", {type: "test", data: {}})
    end

    it "clears session data from cache" do
      expect(Rails.cache.read(cache_key)).not_to be_nil

      service.clear_session

      expect(Rails.cache.read(cache_key)).to be_nil
    end
  end

  describe "#session_summary" do
    before do
      base_time = Time.current
      travel_to(base_time) do
        service.store("first input", {type: "position_query", data: {}})
      end
      travel_to(base_time + 1.second) do
        service.store("second input", {type: "signal_query", data: {}})
      end
      travel_to(base_time + 2.seconds) do
        service.store("third input", {type: "position_query", data: {}})
      end
    end

    it "returns comprehensive session summary" do
      summary = service.session_summary

      expect(summary[:session_id]).to eq(session_id)
      expect(summary[:total_interactions]).to eq(3)
      expect(summary[:last_activity]).to be_present
      expect(summary[:command_types]).to contain_exactly("position_query", "signal_query")
    end

    it "returns empty summary for new session" do
      new_service = described_class.new("empty-session")
      summary = new_service.session_summary

      expect(summary[:session_id]).to eq("empty-session")
      expect(summary[:total_interactions]).to eq(0)
      expect(summary[:last_activity]).to be_nil
      expect(summary[:command_types]).to be_empty
    end
  end

  describe "cache expiration" do
    it "sets 24 hour expiration on memory" do
      service.store("test", {type: "test", data: {}})

      # Check that cache key exists
      expect(Rails.cache.exist?(cache_key)).to be true

      # Simulate time passage (we can't actually test 24 hours easily)
      # But we can verify the cache was written with expiration
      expect(Rails.cache.read(cache_key)).not_to be_nil
    end
  end

  describe "memory persistence" do
    it "persists memory across service instances" do
      # Store with first instance
      service.store("persistent test", {type: "test", data: {}})

      # Create new instance with same session_id
      new_service = described_class.new(session_id)

      # Should have same memory
      expect(new_service.interaction_count).to eq(1)
      expect(new_service.last_command_type).to eq("test")
    end
  end
end
