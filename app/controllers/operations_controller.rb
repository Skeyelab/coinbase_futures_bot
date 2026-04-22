# frozen_string_literal: true

class OperationsController < ActionController::Base
  layout "application"
  protect_from_forgery with: :exception

  def index
    @profiles = TradingProfile.order(:name)
    @active_profile = TradingConfiguration.current_profile
    @trading_active = trading_active?
    @emergency_stop = Rails.cache.fetch("emergency_stop", expires_in: 1.hour) { false }
  end

  def activate_profile
    profile = TradingProfile.find(params[:id])
    profile.activate!
    redirect_to operations_path, notice: "Activated profile: #{profile.name}"
  rescue ActiveRecord::RecordNotFound
    redirect_to operations_path, alert: "Profile not found"
  end

  def set_trading_state
    desired_state = params[:state] == "start"
    Rails.cache.write("trading_active", desired_state)
    Rails.cache.write("emergency_stop", false) if desired_state

    message = desired_state ? "Trading marked active" : "Trading marked paused"
    redirect_to operations_path, notice: message
  end

  def emergency_stop
    Rails.cache.write("trading_active", false)
    Rails.cache.write("emergency_stop", true)
    redirect_to operations_path, alert: "Emergency stop enabled"
  end

  private

  def trading_active?
    Rails.cache.fetch("trading_active", expires_in: 1.hour) { true }
  end
end
