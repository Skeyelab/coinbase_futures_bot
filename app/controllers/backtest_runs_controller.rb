# frozen_string_literal: true

# Read surface for persisted backtest runs (issue #408, PRD #405).
#
# Backtesting was write-only: the rake task printed JSON and forgot it. #406
# made runs durable; this makes them inspectable without SQL.
class BacktestRunsController < ActionController::Base
  layout "application"

  skip_forgery_protection
  before_action :require_positions_basic_auth

  PER_PAGE = 50

  def index
    # Deliberately excludes trades/equity_curve/windows: a 30-day 5m curve is
    # ~8,600 points and 1m is ~43,000, none of which a table needs.
    scope = BacktestRun.without_payloads.recent
    scope = scope.for_symbol(params[:symbol]) if params[:symbol].present?
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = filter_by_gate(scope, params[:cost_gate])

    @symbols = BacktestRun.distinct.order(:symbol).pluck(:symbol)
    @page = [params[:page].to_i, 1].max
    @runs = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
    # except(:select): without_payloads narrows the SELECT list, and COUNT over
    # an explicit column list is not valid SQL.
    @total = scope.except(:select).count
  end

  def show
    @run = BacktestRun.find(params[:id])
    @trades = Array(@run.trades)
    @trade_page = [params[:trade_page].to_i, 1].max
    @trades_page = @trades[((@trade_page - 1) * PER_PAGE), PER_PAGE] || []
    # Thousands of points do not need to reach the browser to show a shape.
    @curve = downsample(Array(@run.equity_curve), 300)
  end

  private

  # cost_gate_passed lives in the metrics jsonb, so filtering is a containment
  # query rather than a column comparison.
  def filter_by_gate(scope, value)
    return scope if value.blank?

    scope.where("metrics @> ?", {cost_gate_passed: value == "pass"}.to_json)
  end

  def downsample(points, limit)
    return points if points.size <= limit

    step = (points.size.to_f / limit).ceil
    points.each_slice(step).map(&:first)
  end

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
end
