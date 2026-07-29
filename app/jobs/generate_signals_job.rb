# frozen_string_literal: true

class GenerateSignalsJob < ApplicationJob
  queue_as :default

  # A halt is a STATE, not a transient fault. GoodJob retries unhandled errors
  # immediately and forever (retry_on_unhandled_error), so a HaltedError
  # escaping this job turned one cron tick into ~3 attempts/second — each
  # re-posting the signal to Slack before crashing. Observed live 2026-07-28:
  # 900+ identical "New Trading Signal" messages while the daily loss cap halt
  # was active. Retrying into a non-expiring halt can never succeed.
  discard_on TradingHalt::HaltedError

  # Suppress repeat Slack posts for the same symbol+side while the signal
  # persists. The job runs every 15 minutes; an unactioned signal that is
  # still valid does not need re-announcing four times an hour.
  NOTIFY_THROTTLE = 1.hour

  def perform(equity_usd: default_equity_usd)
    Contract.enabled.find_each do |pair|
      # Suspension must gate THIS job too (issue #411). RealTimeSignalEvaluator
      # and RapidSignalEvaluationJob already check it; this one did not, so a
      # suspended symbol still reached execute_order below whenever the bot was
      # out of paper mode. That breaks ADR 0002's no-evidence-inheritance rule,
      # which depends on a symbol collecting candles while barred from trading —
      # exactly the state BIP/XPP are being added in.
      if Trading::SymbolSuspension.suspended?(pair.product_id)
        puts "[Signal] #{pair.product_id} blocked — #{Trading::SymbolSuspension.block_reason(pair.product_id)}"
        next
      end

      puts "Analyzing #{pair.product_id}..."
      # Per-pair, profile-aware build through the shared resolution site
      # (issue #303) so Slack notifications advertise the strategy and tp/sl
      # actually traded (drift audit: this job hardcoded EMAs and leaked
      # class-DEFAULT tp/sl to Slack; later it built one global strategy that
      # could not follow a per-symbol selection).
      strat = Trading::StrategyFactory.for_symbol(pair.product_id)
      order = strat.signal(symbol: pair.product_id, equity_usd: equity_usd)
      if order
        puts "[Signal] #{pair.product_id} side=#{order[:side]} price=#{order[:price].round(2)} qty=#{order[:quantity]} tp=#{order[:tp].round(2)} sl=#{order[:sl].round(2)} conf=#{order[:confidence]}%"

        # Send Slack notification for the signal (throttled per symbol+side)
        notify_signal(pair.product_id, order)

        # PostHog: Track signal generation
        PostHog.capture(
          distinct_id: "system",
          event: "signal_generated",
          properties: {
            symbol: pair.product_id,
            side: order[:side],
            price: order[:price].round(2),
            quantity: order[:quantity],
            tp: order[:tp].round(2),
            sl: order[:sl].round(2),
            confidence: order[:confidence],
            paper_trading: paper_trading?
          }
        )

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

  # The durable dry-run state (BotRuntimeStat, toggled via `bin/futuresbot
  # dry_run_on`) must gate execution here too. This job only consulted the
  # PAPER_TRADING_MODE env var, so a box in dry-run with the var unset still
  # walked the live execution path — which is how a halted bot ended up
  # raising HaltedError out of a signal-generation cron (2026-07-28 storm).
  def paper_trading?
    ENV["PAPER_TRADING_MODE"] == "true" || DryRun.active?
  end

  def notify_signal(product_id, order)
    throttle_key = "signal_notification:#{product_id}:#{order[:side]}"
    return unless Rails.cache.write(throttle_key, Time.current.utc.iso8601,
      unless_exist: true, expires_in: NOTIFY_THROTTLE)

    SlackNotificationService.signal_generated({
      symbol: product_id,
      side: order[:side],
      price: order[:price],
      quantity: order[:quantity],
      tp: order[:tp],
      sl: order[:sl],
      confidence: order[:confidence]
    })
  end

  def execute_order(product_id, price)
    Execution::FuturesExecutor.new.consider_entry(
      spot_price: price,
      futures_product_id: product_id
    )
  rescue TradingHalt::HaltedError => e
    # Skip, don't crash: the halt transition already alerted, the signal above
    # is still worth announcing, and the remaining symbols still deserve their
    # analysis pass. discard_on remains as the backstop for any other path.
    puts "[Signal] #{product_id} not executed — #{e.message}"
  end
end
