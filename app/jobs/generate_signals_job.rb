# frozen_string_literal: true

class GenerateSignalsJob < ApplicationJob
  queue_as :default

  def perform(equity_usd: default_equity_usd)
    strat = Strategy::MultiTimeframeSignal.new

    TradingPair.enabled.find_each do |pair|
      order = strat.signal(symbol: pair.product_id, equity_usd: equity_usd)
      if order
        Rails.logger.info("[Signal] #{pair.product_id} side=#{order[:side]} price=#{order[:price].round(2)} qty=#{order[:quantity]} tp=#{order[:tp].round(2)} sl=#{order[:sl].round(2)} conf=#{order[:confidence]}%")
        # TODO: hand off to a real executor once implemented for PERP
      else
        Rails.logger.debug("[Signal] #{pair.product_id} no-entry")
      end
    end
  end

  private

  def default_equity_usd
    (ENV["SIGNAL_EQUITY_USD"] || 10_000).to_f
  end
end


