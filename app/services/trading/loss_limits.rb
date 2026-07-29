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
  #
  # The CAP VALUES are scoped the same way. They were shared, and a live cap
  # sized for real capital is the wrong number for paper: on 2026-07-28 one
  # ordinary NOL-19AUG26-CDE stop-out realized -$12.60 against the $10 daily
  # cap — 94% of the day's budget in a single trade — and the resulting halt,
  # which never auto-expires, needed a manual clear before paper could trade
  # again. A live cap protects capital; a paper cap protects nothing and costs
  # the >=100-trades-per-symbol sample that #376 gate 2 requires.
  class LossLimits
    Breach = Struct.new(:window, :realized, :cap) do
      def reason
        "#{window} realized loss #{format("$%.2f", realized.abs)} breached cap #{format("$%.2f", cap)}"
      end
    end

    Caps = Struct.new(:daily, :weekly, :cumulative)

    # ---- LIVE caps: #392 condition 3, governing real money. Do not renumber.
    def self.live_daily_cap = ENV.fetch("LOSS_CAP_DAILY_USD", "10").to_f

    def self.live_weekly_cap = ENV.fetch("LOSS_CAP_WEEKLY_USD", "30").to_f

    # The tuition cap: total realized loss across the whole program.
    def self.live_cumulative_cap = ENV.fetch("LOSS_CAP_CUMULATIVE_USD", "100").to_f

    # ---- PAPER caps: no capital to protect, so they exist to catch a broken
    # strategy or a runaway loop, not to preserve a balance. Defaults are a
    # fraction of PAPER_EQUITY_USD so they scale when the operator raises paper
    # equity, and they keep #392's 1:3:10 daily:weekly:cumulative shape. The
    # fraction is 10x live's (10%/30%/100% against live's 1%/3%/10% of the
    # $1,000 account #392 sized itself against) because a live cap has to sit
    # below one ordinary stop-out and a paper cap has to sit above it: at $10 a
    # single -$12.60 stop-out ended the day. Cumulative at 100% is the only
    # terminal condition paper actually has — the paper account is gone.
    PAPER_DAILY_EQUITY_FRACTION = 0.10
    PAPER_WEEKLY_EQUITY_FRACTION = 0.30
    PAPER_CUMULATIVE_EQUITY_FRACTION = 1.00

    def self.paper_daily_cap
      ENV.fetch("PAPER_LOSS_CAP_DAILY_USD") { paper_equity * PAPER_DAILY_EQUITY_FRACTION }.to_f
    end

    def self.paper_weekly_cap
      ENV.fetch("PAPER_LOSS_CAP_WEEKLY_USD") { paper_equity * PAPER_WEEKLY_EQUITY_FRACTION }.to_f
    end

    def self.paper_cumulative_cap
      ENV.fetch("PAPER_LOSS_CAP_CUMULATIVE_USD") { paper_equity * PAPER_CUMULATIVE_EQUITY_FRACTION }.to_f
    end

    def self.paper_equity = PaperAccount.starting_equity

    # The ONE place a mode chooses a cap set. Callers pass the same `paper` flag
    # they scope rows with, so the cap and the sample cannot disagree.
    def self.caps_for(paper:)
      if paper
        Caps.new(daily: paper_daily_cap, weekly: paper_weekly_cap, cumulative: paper_cumulative_cap)
      else
        Caps.new(daily: live_daily_cap, weekly: live_weekly_cap, cumulative: live_cumulative_cap)
      end
    end

    def self.evaluate!(now: Time.current, logger: Rails.logger)
      new(now: now, logger: logger).evaluate!
    end

    def self.status(now: Time.current)
      new(now: now).status
    end

    # DryRun is a DB-backed toggle that another process can flip between two
    # calls. Read it ONCE and derive both the cap set and the row scope from
    # that single answer: a cap reading live values against paper rows (or the
    # reverse) is worse than the shared cap this replaced.
    def initialize(now: Time.current, logger: Rails.logger)
      @now = now
      @logger = logger
      @paper = DryRun.active?
      @caps = self.class.caps_for(paper: @paper)
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
        mode: @paper ? "paper" : "live",
        cumulative: {realized: realized_since(nil), cap: @caps.cumulative},
        weekly: {realized: realized_since(@now - 7.days), cap: @caps.weekly},
        daily: {realized: realized_since(@now.beginning_of_day), cap: @caps.daily},
        breached: breaches.map(&:window)
      }
    end

    private

    def breaches
      [
        Breach.new(window: "cumulative", realized: realized_since(nil), cap: @caps.cumulative),
        Breach.new(window: "weekly", realized: realized_since(@now - 7.days), cap: @caps.weekly),
        Breach.new(window: "daily", realized: realized_since(@now.beginning_of_day), cap: @caps.daily)
      ].select { |b| b.cap.positive? && b.realized.negative? && b.realized.abs >= b.cap }
    end

    def realized_since(from)
      scope = Position.where(status: "CLOSED", paper: @paper)
      scope = scope.where(close_time: from..@now) if from
      scope.sum(:pnl).to_f
    end
  end
end
