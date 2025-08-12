class PositionsController < ActionController::Base
  layout "application"

  # In API-only apps, CSRF/session may not be configured; skip for this simple UI
  skip_forgery_protection

  before_action :require_positions_basic_auth

  def index
    @notice_message = params[:notice]

    begin
      @positions = positions_service.list_open_positions
    rescue Faraday::ClientError => e
      @error_message = e.message
    rescue => e
      @error_message = e.message
      @positions = []
    end
  end

  def edit
    product_id = params[:product_id]

    begin
      positions = positions_service.list_open_positions(product_id: product_id)
      @position = positions.find { |p| p["product_id"] == product_id } || positions.first
      @position ||= { "product_id" => product_id }
    rescue Faraday::ClientError => e
      @error_message = e.message
      @position = { "product_id" => product_id }
    rescue => e
      @error_message = e.message
      @position = { "product_id" => product_id }
    end
  end

  def update
    product_id = params[:product_id]
    size_to_close = params[:size].presence

    begin
      result = positions_service.close_position(product_id: product_id, size: size_to_close)
      redirect_to positions_path(notice: "Close order submitted: #{result["order_id"] || result["message"] || result["success"]}")
    rescue => e
      redirect_to edit_position_path(product_id, notice: "Error: #{e.message}")
    end
  end

  def close
    product_id = params[:product_id]
    size_to_close = params[:size].presence

    begin
      result = positions_service.close_position(product_id: product_id, size: size_to_close)
      redirect_to positions_path(notice: "Close order submitted: #{result["order_id"] || result["message"] || result["success"]}")
    rescue => e
      redirect_to edit_position_path(product_id, notice: "Error: #{e.message}")
    end
  end

  private

  def require_positions_basic_auth
    username = ENV["POSITIONS_UI_USERNAME"].to_s
    password = ENV["POSITIONS_UI_PASSWORD"].to_s

    unless username.present? && password.present?
      render plain: "Positions UI credentials not configured. Set POSITIONS_UI_USERNAME and POSITIONS_UI_PASSWORD.", status: :forbidden and return
    end

    authenticate_or_request_with_http_basic("Positions UI") do |u, p|
      ActiveSupport::SecurityUtils.secure_compare(u.to_s, username) &&
        ActiveSupport::SecurityUtils.secure_compare(p.to_s, password)
    end
  end

  def positions_service
    @positions_service ||= Trading::CoinbasePositions.new
  end
end
