# frozen_string_literal: true

# OperatorSnapshot is the single canonical, machine-readable view of live bot
# state for out-of-process consumers (the `--json` CLI in #290 and the MCP
# server in #291). Stable snake_case keys, ISO-8601 UTC timestamps, no ANSI —
# so Claude (or any MCP client) consumes structured data instead of scraping
# the human-formatted tables.
class OperatorSnapshot
  def initialize(now: Time.current)
    @now = now
  end

  def status
    {
      as_of: iso(@now),
      halt: TradingHalt.status.slice(:active, :halted, :reason),
      dry_run: {active: DryRun.active?},
      positions: {
        day: Position.open.day_trading.count,
        swing: Position.open.swing_trading.count,
        open_total: Position.open.count
      },
      signals: {active: SignalAlert.active.count},
      eval: eval_info,
      paper: paper_info
    }
  end

  def positions
    {
      as_of: iso(@now),
      positions: Position.open.order(entry_time: :desc).map { |p| position_row(p) }
    }
  end

  def signals
    {
      as_of: iso(@now),
      signals: SignalAlert.active.recent.order(alert_timestamp: :desc).limit(25).map { |s| signal_row(s) }
    }
  end

  def halt_status
    {as_of: iso(@now)}.merge(TradingHalt.status.slice(:active, :halted, :reason))
  end

  private

  def position_row(position)
    price = RecentMarketPrice.for_product(position.product_id)
    {
      id: position.id,
      product_id: position.product_id,
      side: position.side,
      entry_price: position.entry_price&.to_f,
      size: position.size&.to_f,
      take_profit: position.take_profit&.to_f,
      stop_loss: position.stop_loss&.to_f,
      unrealized_pnl: price ? position.unrealized_pnl_at(price) : nil,
      day_trading: position.day_trading,
      paper: position.paper
    }
  end

  def signal_row(signal)
    {
      id: signal.id,
      symbol: signal.symbol,
      side: signal.side,
      signal_type: signal.signal_type,
      confidence: signal.confidence&.to_i,
      strategy: signal.strategy_name,
      timestamp: iso(signal.alert_timestamp)
    }
  end

  def eval_info
    last_eval_at = EvalTimestampStore.read
    {
      last_eval_at: iso(last_eval_at),
      age_seconds: last_eval_at ? (@now - last_eval_at).to_i : nil
    }
  end

  def paper_info
    account = PaperAccount.new
    return {active: false} unless DryRun.active? || account.any?

    {
      active: true,
      equity: account.equity.round(2),
      realized_pnl: account.realized_pnl.round(2),
      unrealized_pnl: account.unrealized_pnl.round(2),
      open_positions: account.open_positions.count
    }
  end

  def iso(time)
    time&.utc&.iso8601
  end
end
