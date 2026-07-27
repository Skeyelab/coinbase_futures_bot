# frozen_string_literal: true

module Trading
  # Daily / weekly / cumulative realized-loss caps that trip a non-expiring risk
  # halt (issue #482, #392 condition 3).
  #
  # Before this, grepping app/ and config/ for tuition|daily_loss|weekly_loss|
  # cumulative_loss returned nothing: every implemented control governed WHETHER
  # trading was allowed (halt asserted at each order, LIVE_TRADING_CONFIRMED,
  # dry-run), and not one governed HOW MUCH could be lost. That asymmetry is why
  # the $1k live test was a no-go.
  #
  # Measured on NET realized PnL, not gross losses: a $20 loss followed by a $15
  # win has cost $5, and treating it as a $20 breach would halt a system that is
  # working. Capital at risk is the honest quantity.
  #
  # Scoped to the mode currently in force — paper rows in dry-run, live rows
  # otherwise — so the caps can be drilled in paper and still mean real dollars
  # live.
  class LossLimits
    Breach = Struct.new(:window, :realized, :cap) do
      def reason
        "#{window} realized loss #{format("$%.2f", realized.abs)} breached cap #{format("$%.2f", cap)}"
      end
    end

    def self.daily_cap = ENV.fetch("LOSS_CAP_DAILY_USD", "10").to_f

    def self.weekly_cap = ENV.fetch("LOSS_CAP_WEEKLY_USD", "30").to_f

    # The tuition cap: total realized loss across the whole program.
    def self.cumulative_cap = ENV.fetch("LOSS_CAP_CUMULATIVE_USD", "100").to_f

    def self.evaluate!(now: Time.current, logger: Rails.logger)
      new(now: now, logger: logger).evaluate!
    end

    def self.status(now: Time.current)
      new(now: now).status
    end

    def initialize(now: Time.current, logger: Rails.logger)
      @now = now
      @logger = logger
    end

    # Halts on the FIRST breach found, widest window first: a cumulative breach
    # is the more serious statement about the program, and naming it as the
    # reason is more useful to an operator than "today was bad".
    def evaluate!
      breach = breaches.first
      return nil unless breach

      # Already stopped — do not rewrite the halt and lose the original reason.
      return breach if TradingHalt.risk_halted?

      @logger.error("[LossLimits] #{breach.reason} — halting")
      TradingHalt.halt_for_risk!(reason: breach.reason)
      breach
    end

    def status
      {
        cumulative: {realized: realized_since(nil), cap: self.class.cumulative_cap},
        weekly: {realized: realized_since(@now - 7.days), cap: self.class.weekly_cap},
        daily: {realized: realized_since(@now.beginning_of_day), cap: self.class.daily_cap},
        breached: breaches.map(&:window)
      }
    end

    private

    def breaches
      [
        Breach.new(window: "cumulative", realized: realized_since(nil), cap: self.class.cumulative_cap),
        Breach.new(window: "weekly", realized: realized_since(@now - 7.days), cap: self.class.weekly_cap),
        Breach.new(window: "daily", realized: realized_since(@now.beginning_of_day), cap: self.class.daily_cap)
      ].select { |b| b.cap.positive? && b.realized.negative? && b.realized.abs >= b.cap }
    end

    def realized_since(from)
      scope = Position.where(status: "CLOSED", paper: DryRun.active?)
      scope = scope.where(close_time: from..@now) if from
      scope.sum(:pnl).to_f
    end
  end
end
