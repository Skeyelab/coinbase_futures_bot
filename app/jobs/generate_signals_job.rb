# frozen_string_literal: true

class GenerateSignalsJob < ApplicationJob
  queue_as :default

  def perform(equity_usd: default_equity_usd)
    # Same profile-aware build as the realtime evaluator, so Slack signal
    # notifications advertise the tp/sl actually traded (drift audit: this
    # job hardcoded EMAs and leaked class-DEFAULT tp/sl to Slack).
    strat = Trading::StrategyFactory.multi_timeframe

    Contract.enabled.find_each do |pair|
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

        execute_order(pair.product_id, order[:price]) unless paper_trading?
      else
        puts "[Signal] #{pair.product_id} no-entry"
      end
    end
  end

  private

  def default_equity_usd
    value = Trading::SignalEquity.usd
    Float(value)
  rescue ArgumentError, TypeError
    0.0
  end

  def paper_trading?
    ENV["PAPER_TRADING_MODE"] == "true"
  end

  def execute_order(product_id, price)
    Execution::FuturesExecutor.new.consider_entry(
      spot_price: price,
      futures_product_id: product_id
    )
  end
end
