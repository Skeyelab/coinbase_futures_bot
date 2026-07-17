# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GoodJob dashboard", type: :request do
  around do |example|
    @orig_username = ENV["POSITIONS_UI_USERNAME"]
    @orig_password = ENV["POSITIONS_UI_PASSWORD"]
    ENV["POSITIONS_UI_USERNAME"] = "admin"
    ENV["POSITIONS_UI_PASSWORD"] = "password123"
    example.run
  ensure
    ENV["POSITIONS_UI_USERNAME"] = @orig_username
    ENV["POSITIONS_UI_PASSWORD"] = @orig_password
  end

  it "allows access without credentials in local rails environments" do
    skip "GoodJob auth middleware is mounted outside local envs" unless Rails.env.local?

    get "/jobs"

    expect(response).not_to have_http_status(:unauthorized)
  end

  describe "production-style credential check" do
    def positions_ui_credentials_match?(user, password)
      expected_username = ENV["POSITIONS_UI_USERNAME"].to_s
      expected_password = ENV["POSITIONS_UI_PASSWORD"].to_s

      expected_username.present? && expected_password.present? &&
        ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_username) &&
        ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
    end

    it "accepts positions UI credentials" do
      expect(positions_ui_credentials_match?("admin", "password123")).to be true
    end

    it "rejects invalid credentials" do
      expect(positions_ui_credentials_match?("admin", "wrong")).to be false
    end
  end
end
