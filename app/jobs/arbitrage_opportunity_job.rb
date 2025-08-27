# frozen_string_literal: true

class ArbitrageOpportunityJob < ApplicationJob
  queue_as :default

  def perform(spot_product_id:, futures_product_id:, basis_bps:, direction:)
    @spot_product_id = spot_product_id
    @futures_product_id = futures_product_id
    @basis_bps = basis_bps.to_f
    @direction = direction
    @logger = Rails.logger

    @logger.info("[ARB] Evaluating arbitrage: #{@direction} #{@basis_bps} bps between #{@spot_product_id} and #{@futures_product_id}")

    # Check if arbitrage is still valid (basis might have moved)
    return unless arbitrage_still_valid?

    # Check risk limits for arbitrage trading
    return unless within_arbitrage_risk_limits?

    # Log the opportunity for analysis
    log_arbitrage_opportunity

    # In a full implementation, this would execute the arbitrage strategy
    # For now, we just log and monitor
    @logger.info("[ARB] Arbitrage opportunity logged for analysis")
  end

  private

  def arbitrage_still_valid?
    # Re-check basis to ensure opportunity is still valid
    current_basis = calculate_current_basis
    return false unless current_basis

    # Opportunity is valid if basis is still above threshold and in same direction
    threshold = ENV.fetch("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").to_f
    current_direction = (current_basis > 0) ? "POSITIVE" : "NEGATIVE"

    current_basis.abs > threshold && current_direction == @direction
  end

  def within_arbitrage_risk_limits?
    # Check if we're within risk limits for arbitrage positions
    max_arbitrage_positions = ENV.fetch("MAX_ARBITRAGE_POSITIONS", "2").to_i
    current_arbitrage_positions = count_active_arbitrage_positions

    if current_arbitrage_positions >= max_arbitrage_positions
      @logger.info("[ARB] Skipping arbitrage - at max positions (#{current_arbitrage_positions}/#{max_arbitrage_positions})")
      return false
    end

    true
  end

  def calculate_current_basis
    # Get current prices for both spot and futures
    spot_data = Rails.cache.read("last_price_#{@spot_product_id}")
    futures_data = Rails.cache.read("basis_#{@futures_product_id}_latest")

    return nil unless spot_data && futures_data

    futures_price = futures_data[:futures_price]
    basis = futures_price - spot_data
    (basis / spot_data * 10000).round(2) # basis points
  end

  def count_active_arbitrage_positions
    # Count positions that are part of arbitrage strategies
    # This would be tracked in position metadata or a separate arbitrage tracking system
    Position.open.where("product_id LIKE ?", "%-ARB").count
  end

  def log_arbitrage_opportunity
    # Log the opportunity for historical analysis and backtesting
    opportunity_data = {
      timestamp: Time.current,
      spot_product_id: @spot_product_id,
      futures_product_id: @futures_product_id,
      basis_bps: @basis_bps,
      direction: @direction,
      opportunity_score: calculate_opportunity_score
    }

    Rails.cache.write(
      "arbitrage_opportunity_#{Time.current.to_i}",
      opportunity_data,
      expires_in: 1.day
    )

    @logger.info("[ARB] Opportunity logged: #{opportunity_data}")
  end

  def calculate_opportunity_score
    # Calculate a score based on basis magnitude and market conditions
    base_score = [@basis_bps.abs / 10, 10].min # 0-10 based on basis

    # Adjust for market volatility and liquidity
    volatility_adjustment = calculate_volatility_adjustment
    liquidity_adjustment = calculate_liquidity_adjustment

    (base_score * volatility_adjustment * liquidity_adjustment).round(2)
  end

  def calculate_volatility_adjustment
    # Lower scores during high volatility (riskier arbitrage)
    # This would use recent price volatility data
    1.0 # Placeholder - would be 0.5-1.5 based on volatility
  end

  def calculate_liquidity_adjustment
    # Lower scores during low liquidity periods
    # This would use order book depth or volume data
    1.0 # Placeholder - would be 0.7-1.3 based on liquidity
  end
end
