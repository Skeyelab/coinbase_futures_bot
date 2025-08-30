class PositionsController < ActionController::Base
  layout "application"

  # In API-only apps, CSRF/session may not be configured; skip for this simple UI
  skip_forgery_protection

  before_action :require_positions_basic_auth

  def index
    @notice_message = params[:notice]
    @positions = [] # Initialize to empty array

    begin
      @positions = positions_service.list_open_positions

      # Track successful position retrieval
      SentryHelper.add_breadcrumb(
        message: "Positions retrieved successfully",
        category: "trading",
        level: "info",
        data: {
          controller: "positions",
          action: "index",
          position_count: @positions.size
        }
      )
    rescue Faraday::ClientError => e
      @error_message = e.message

      # Track API errors specifically
      Sentry.with_scope do |scope|
        scope.set_tag("controller", "positions")
        scope.set_tag("error_type", "api_error")
        scope.set_context("positions_request", {operation: "list_open_positions"})

        Sentry.capture_exception(e)
      end
    rescue => e
      @error_message = e.message
      # @positions is already set to [] above
    end
  end

  def new
    @position = {"product_id" => params[:product_id]}
  end

  def create
    product_id = params[:product_id]
    side = params[:side]
    size = params[:size]
    order_type = params[:order_type] || "market"
    price = params[:price]

    begin
      result = positions_service.open_position(
        product_id: product_id,
        side: side,
        size: size,
        type: order_type,
        price: price
      )
      redirect_to positions_path(notice: "Position opened: #{result["order_id"] || result["message"] || result["success"]}")
    rescue => e
      redirect_to new_position_path(product_id, notice: "Error: #{e.message}")
    end
  end

  def edit
    product_id = params[:product_id]

    begin
      positions = positions_service.list_open_positions(product_id: product_id)
      @position = positions.find { |p| p["product_id"] == product_id } || positions.first
      @position ||= {"product_id" => product_id}
    rescue Faraday::ClientError => e
      @error_message = e.message
      @position = {"product_id" => product_id}
    rescue => e
      @error_message = e.message
      @position = {"product_id" => product_id}
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

    Rails.logger.info("CLOSE ACTION CALLED: product_id=#{product_id}, size=#{size_to_close}")

    begin
      result = positions_service.close_position(product_id: product_id, size: size_to_close)
      redirect_to positions_path(notice: "Close order submitted: #{result["order_id"] || result["message"] || result["success"]}")
    rescue => e
      redirect_to edit_position_path(product_id, notice: "Error: #{e.message}")
    end
  end

  def increase
    product_id = params[:product_id]
    size_to_increase = params[:size].presence

    Rails.logger.info("INCREASE ACTION CALLED: product_id=#{product_id}, size=#{size_to_increase}")

    begin
      result = positions_service.increase_position(product_id: product_id, size: size_to_increase)
      redirect_to positions_path(notice: "Position increased: #{result["order_id"] || result["message"] || result["success"]}")
    rescue => e
      redirect_to edit_position_path(product_id, notice: "Error: #{e.message}")
    end
  end

  private

  def require_positions_basic_auth
    username = ENV["POSITIONS_UI_USERNAME"].to_s
    password = ENV["POSITIONS_UI_PASSWORD"].to_s

    unless username.present? && password.present?
      render plain: "Positions UI credentials not configured. Set POSITIONS_UI_USERNAME and POSITIONS_UI_PASSWORD.",
        status: :forbidden and return
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
