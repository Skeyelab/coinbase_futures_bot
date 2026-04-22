# frozen_string_literal: true

class GenerateSignalsJob < ApplicationJob
  queue_as :default

  def perform(equity_usd: default_equity_usd)
    strat = Strategy::MultiTimeframeSignal.new(
      ema_1h_short: 21, ema_1h_long: 50, ema_15m: 21, min_1h_candles: 60, min_15m_candles: 80
    )

    TradingPair.enabled.find_each do |pair|
      puts "Analyzing #{pair.product_id}..."
      order = strat.signal(symbol: pair.product_id, equity_usd: equity_usd)
      if order
        puts "[Signal] #{pair.product_id} side=#{order[:side]} price=#{order[:price].round(2)} qty=#{order[:quantity]} tp=#{order[:tp].round(2)} sl=#{order[:sl].round(2)} conf=#{order[:confidence]}%"

        # Send Slack notification for the signal
        SlackNotificationService.signal_generated({
          symbol: pair.product_id,
          side: order[:side],
          price: order[:price],
          quantity: order[:quantity],
          tp: order[:tp],
          sl: order[:sl],
          confidence: order[:confidence]
        })

        # TODO: hand off to a real executor once implemented for futures
      else
        puts "[Signal] #{pair.product_id} no-entry"
      end
    end
  end

  private

  def default_equity_usd
    TradingConfiguration.signal_equity_usd
  end
end
