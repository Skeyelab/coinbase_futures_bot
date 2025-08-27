# frozen_string_literal: true

class FuturesBasisMonitoringJob < ApplicationJob
  queue_as :default

  def perform(spot_product_id:, futures_product_id:, spot_price:)
    @spot_product_id = spot_product_id
    @futures_product_id = futures_product_id
    @spot_price = spot_price.to_f
    @logger = Rails.logger

    # Get current futures price from recent ticks or market data
    futures_price = get_futures_price(@futures_product_id)
    return unless futures_price

    # Calculate basis (futures - spot)
    basis = futures_price - @spot_price
    basis_bps = (basis / @spot_price * 10000).round(2) # basis points

    @logger.debug("[FBM] #{@futures_product_id} basis: #{basis_bps} bps (F: $#{futures_price}, S: $#{@spot_price})")

    # Store basis data for analysis
    store_basis_data(basis, basis_bps)

    # Check for arbitrage opportunities
    check_arbitrage_opportunities(basis_bps)

    # Monitor for extreme basis situations
    monitor_basis_extremes(basis_bps)
  end

  private

  def get_futures_price(futures_product_id)
    # Try to get recent tick data first
    recent_tick = Tick.where(symbol: futures_product_id)
      .where("timestamp > ?", 5.minutes.ago)
      .order(timestamp: :desc)
      .first

    if recent_tick
      recent_tick.price.to_f
    else
      # Fallback to market data API if no recent ticks
      fetch_current_market_price(futures_product_id)
    end
  end

  def fetch_current_market_price(product_id)
    # This would make an API call to get current market price
    # For now, return nil to avoid making API calls during high-frequency monitoring
    nil
  end

  def store_basis_data(basis, basis_bps)
    # Store basis data for historical analysis
    # This could be stored in a dedicated BasisData model
    Rails.cache.write(
      "basis_#{@futures_product_id}_latest",
      {
        spot_price: @spot_price,
        futures_price: @spot_price + basis,
        basis: basis,
        basis_bps: basis_bps,
        timestamp: Time.current
      },
      expires_in: 1.hour
    )
  end

  def check_arbitrage_opportunities(basis_bps)
    # Define arbitrage thresholds
    arbitrage_threshold = ENV.fetch("BASIS_ARBITRAGE_THRESHOLD_BPS", "50").to_f

    if basis_bps.abs > arbitrage_threshold
      direction = (basis_bps > 0) ? "POSITIVE" : "NEGATIVE"
      @logger.info("[FBM] Arbitrage opportunity detected: #{direction} basis #{basis_bps} bps on #{@futures_product_id}")

      # In production, this could trigger arbitrage strategy
      ArbitrageOpportunityJob.perform_later(
        spot_product_id: @spot_product_id,
        futures_product_id: @futures_product_id,
        basis_bps: basis_bps,
        direction: direction
      )
    end
  end

  def monitor_basis_extremes(basis_bps)
    # Monitor for extremely wide basis that might indicate market stress
    extreme_threshold = ENV.fetch("BASIS_EXTREME_THRESHOLD_BPS", "200").to_f

    if basis_bps.abs > extreme_threshold
      @logger.warn("[FBM] EXTREME BASIS DETECTED: #{basis_bps} bps on #{@futures_product_id}")

      # This could trigger risk management actions
      send_extreme_basis_alert(basis_bps)
    end
  end

  def send_extreme_basis_alert(basis_bps)
    @logger.warn("[ALERT] EXTREME BASIS: #{@futures_product_id} at #{basis_bps} bps - potential market stress")

    # In production, this could trigger:
    # - Position size reductions
    # - Stop loss tightening
    # - Trading halt for the affected contract
  end
end
