# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalController, type: :request do
  describe "GET /signals/health" do
    it "returns healthy status" do
      get "/signals/health"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/json")
    end
  end
end
