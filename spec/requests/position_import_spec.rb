# frozen_string_literal: true

require "rails_helper"

# ADR 0005: position import rewrites the `positions` table that the whole risk
# stack counts from — `#replace` clears it and re-imports. Authorization must
# fail closed on every environment, so a missing credential denies rather than
# grants, and `Rails.env.development?` is not a bypass.
RSpec.describe "Position import", type: :request do
  let(:username) { "importer" }
  let(:password) { "s3cret" }

  before do
    @orig_user = ENV["POSITIONS_AUTH_USER"]
    @orig_pass = ENV["POSITIONS_AUTH_PASS"]
  end

  after do
    ENV["POSITIONS_AUTH_USER"] = @orig_user
    ENV["POSITIONS_AUTH_PASS"] = @orig_pass
  end

  def basic_auth(user, pass)
    {"HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass)}
  end

  context "when credentials are not configured" do
    before do
      ENV.delete("POSITIONS_AUTH_USER")
      ENV.delete("POSITIONS_AUTH_PASS")
    end

    it "refuses the table-rewriting replace action" do
      post "/position_import/replace"

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses in development, where auth used to be skipped entirely" do
      allow(Rails.env).to receive(:development?).and_return(true)

      post "/position_import/replace"

      expect(response).to have_http_status(:forbidden)
    end

    it "refuses even when a caller supplies credentials" do
      post "/position_import/replace", headers: basic_auth(username, password)

      expect(response).to have_http_status(:forbidden)
    end
  end

  context "when credentials are configured" do
    before do
      ENV["POSITIONS_AUTH_USER"] = username
      ENV["POSITIONS_AUTH_PASS"] = password
    end

    it "challenges an unauthenticated request" do
      get "/position_import/index"

      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects wrong credentials" do
      get "/position_import/index", headers: basic_auth(username, "wrong")

      expect(response).to have_http_status(:unauthorized)
    end

    it "admits correct credentials" do
      allow_any_instance_of(PositionImportService).to receive(:import_and_replace)
        .and_return({cleared: 0, imported: 0})

      post "/position_import/replace", headers: basic_auth(username, password)

      expect(response).to have_http_status(:redirect)
    end
  end
end
