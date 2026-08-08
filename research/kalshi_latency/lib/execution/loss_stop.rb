require "json"
require "fileutils"
require_relative "halt"

# Daily loss stop: once the account has dropped more than the day's budget,
# engage the HALT file and the trading day is over. Operator-set at $10.
#
# Measured against the ACCOUNT BALANCE, not a reconstruction from fills.
# Settlements, fees, partial fills and manual trades all land in the balance;
# any tally we rebuild ourselves can be wrong about exactly the cases that
# matter. The opening balance is persisted, so a restart cannot silently
# re-baseline to a lower number and hand the day a fresh budget.
module Execution
  class LossStop
    STATE_FILE = "loss-stop.json".freeze
    DEFAULT_BUDGET_CENTS = 1000

    # data_dir is REQUIRED: an in-memory baseline resets on every restart, and
    # a loss stop that forgets is a loss stop that never fires.
    def initialize(client:, halt:, data_dir:, budget_cents: DEFAULT_BUDGET_CENTS,
      clock: -> { Time.now.utc })
      @client = client
      @halt = halt
      @budget_cents = budget_cents
      @clock = clock
      @path = File.join(data_dir, STATE_FILE)
    end

    # Records today's starting balance once. Called at collector boot; a second
    # call on the same UTC day is ignored so a restart keeps the real baseline.
    def mark_open(balance_cents)
      return read_state["open_cents"] if same_day?(read_state)

      write_state("day" => today, "open_cents" => balance_cents)
      balance_cents
    end

    # true when the stop engaged (or was already engaged) on today's drop.
    #
    # Rolls its own baseline. Observed live 2026-08-08: the collector had run
    # since the previous day, so the recorded day was stale and this returned
    # false on every cycle -- the $10 stop was INERT for a whole live trading
    # day. A stop that only baselines at process start protects nothing on a
    # process that does not restart, and failing quiet is still failing.
    def check(balance_cents: nil)
      current = balance_cents || fetch_balance_cents
      return false if current.nil?

      state = read_state
      unless same_day?(state)
        mark_open(current)
        return false
      end

      open_cents = state["open_cents"]
      return false if open_cents.nil?

      drop = open_cents - current
      return false if drop <= @budget_cents

      @halt.engage!(format("daily loss stop: down $%.2f from $%.2f open (budget $%.2f)",
        drop / 100.0, open_cents / 100.0, @budget_cents / 100.0))
      true
    end

    private

    def fetch_balance_cents
      @client.portfolio("/portfolio/balance")["balance"]
    rescue
      # A balance we cannot read is not permission to keep trading blind, but
      # neither is it a loss. The caller's next cycle tries again; the halt
      # file remains the operator's own switch.
      nil
    end

    def today
      @clock.call.strftime("%Y-%m-%d")
    end

    def same_day?(state)
      state["day"] == today
    end

    def read_state
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path))
    rescue
      {}
    end

    def write_state(state)
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.generate(state))
      state
    end
  end
end
