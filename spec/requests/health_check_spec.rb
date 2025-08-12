# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HealthCheck", type: :request do
  it "returns success for /up" do
    get "/up"
    expect(response).to have_http_status(:success)
  end
end
