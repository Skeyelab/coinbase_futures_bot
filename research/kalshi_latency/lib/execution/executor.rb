require_relative "../credibility"

# Sits between the scanner and the order client. The scanner produces raw
# candidates; only episodes Credibility cannot fault become orders.
module Execution
  class Executor
    def initialize(client:, log:)
      @client = client
      @log = log
      # In-memory: the scanner revisits a persisting episode every cycle and
      # must not re-order it. A restart forgets -- acceptable while dry-run,
      # revisit before live.
      @placed = {}
      # Last logged doubt set per ticker. A doubtful episode persists across
      # hundreds of scan cycles; one line per *change* keeps the log readable.
      @last_doubts = {}
    end

    # Returns the placed intent, or nil when the episode is not credible.
    # Refusals are logged too: gate #3 needs to show what was NOT traded and
    # why, or a clean fill record proves nothing.
    def consider(opportunity, episode:)
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
  end
end
