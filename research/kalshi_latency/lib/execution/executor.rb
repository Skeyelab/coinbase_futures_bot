require_relative "../credibility"

# Sits between the scanner and the order client. The scanner produces raw
# candidates; only episodes Credibility cannot fault become orders.
module Execution
  class Executor
    def initialize(client:, log:, halt: nil)
      @client = client
      @log = log
      # The kill switch (#625). nil means no halt file is even checkable --
      # only the tests do that; the pipeline always wires one.
      @halt = halt
      # Seeded from the order log (issue #626): the scanner revisits a
      # persisting episode every cycle and must not re-order it -- and a
      # restart mid-episode must not re-order a position the venue already
      # holds. Tickers are date-stamped, so old entries never collide with a
      # new day's markets.
      @placed = log.placed_tickers.to_h { |t| [t, true] }
      # Last logged doubt set per ticker. A doubtful episode persists across
      # hundreds of scan cycles; one line per *change* keeps the log readable.
      @last_doubts = {}
    end

    # Returns the placed intent, or nil when the episode is not credible.
    # Refusals are logged too: gate #3 needs to show what was NOT traded and
    # why, or a clean fill record proves nothing.
    def consider(opportunity, episode:)
      return nil if halted?(opportunity[:ticker])
      return nil if @placed[opportunity[:ticker]]

      ticker = opportunity[:ticker]
      doubts = Credibility.doubts(episode)
      unless doubts.empty?
        # Compare doubt KINDS, digits stripped: "persisted 460s" and
        # "persisted 520s" are the same doubt aging, not news.
        kinds = doubts.map { |d| d.gsub(/\d+/, "") }
        if @last_doubts[ticker] != kinds
          @log.record(mode: "refused", ticker: ticker, doubts: doubts)
          @last_doubts[ticker] = kinds
        end
        return nil
      end

      intent = @client.place(opportunity)
      @placed[opportunity[:ticker]] = true
      @log.record(intent)
      intent
    end

    private

    # Checked before everything else: a halted executor places nothing and
    # explains itself once per ticker, not once per scan cycle.
    def halted?(ticker)
      return false unless @halt&.active?

      unless @halt_logged&.include?(ticker)
        @log.record(mode: "halted", ticker: ticker, reason: @halt.reason)
        (@halt_logged ||= {})[ticker] = true
      end
      true
    end
  end
end
