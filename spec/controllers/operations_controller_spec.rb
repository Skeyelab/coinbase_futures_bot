# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationsController, type: :controller do
  let!(:profile) do
    TradingProfile.create!(
      name: "Conservative",
      slug: "conservative",
      signal_equity_usd: 1000,
      min_confidence: 70,
      max_signals_per_hour: 5,
      evaluation_interval_seconds: 60,
      strategy_risk_fraction: 0.01,
      strategy_tp_target: 0.004,
      strategy_sl_target: 0.003,
      active: true
    )
  end

  describe "GET #index" do
    it "renders successfully" do
      get :index
      expect(response).to have_http_status(:success)
      expect(response).to render_template(:index)
    end
  end

  describe "POST #activate_profile" do
    let!(:other) do
      TradingProfile.create!(
        name: "Aggressive",
        slug: "aggressive",
        signal_equity_usd: 5000,
        min_confidence: 65,
        max_signals_per_hour: 8,
        evaluation_interval_seconds: 45,
        strategy_risk_fraction: 0.02,
        strategy_tp_target: 0.006,
        strategy_sl_target: 0.004,
        active: false
      )
    end

    it "activates the selected profile" do
      post :activate_profile, params: {id: other.id}
      expect(response).to redirect_to(operations_path)
      expect(other.reload).to be_active
      expect(profile.reload).not_to be_active
    end
  end

  describe "POST #set_trading_state" do
    it "writes active state to cache" do
      post :set_trading_state, params: {state: "start"}
      expect(Rails.cache.read("trading_active")).to be true
    end
  end

  describe "POST #emergency_stop" do
    it "sets emergency stop and pauses trading" do
      post :emergency_stop
      expect(Rails.cache.read("trading_active")).to be false
      expect(Rails.cache.read("emergency_stop")).to be true
    end
  end
end
