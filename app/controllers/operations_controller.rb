# frozen_string_literal: true

class OperationsController < ActionController::Base
  layout "application"
  protect_from_forgery with: :exception

  before_action :require_operations_basic_auth

  def index
    @profiles = TradingProfile.order(:name)
    @active_profile = TradingConfiguration.current_profile
    @trading_active = trading_active?
    @emergency_stop = Rails.cache.read("emergency_stop") || false
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
    result = Rails.cache.read("trading_active")
    result.nil? ? true : result
  end

  def require_operations_basic_auth
    username = ENV["OPERATIONS_UI_USERNAME"].to_s
    password = ENV["OPERATIONS_UI_PASSWORD"].to_s

    unless username.present? && password.present?
      render plain: "Operations UI credentials not configured. Set OPERATIONS_UI_USERNAME and OPERATIONS_UI_PASSWORD.",
        status: :forbidden and return
    end

    authenticate_or_request_with_http_basic("Operations UI") do |u, p|
      ActiveSupport::SecurityUtils.secure_compare(u.to_s, username) &&
        ActiveSupport::SecurityUtils.secure_compare(p.to_s, password)
    end
  end
end
