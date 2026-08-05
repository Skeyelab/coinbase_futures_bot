require "json"
require "fileutils"

# Append-only record of every order intent, dry-run or live. Gate item #3 is
# scored off this file, so it must exist before the first order does.
module Execution
  class OrderLog
    def initialize(path:, clock: -> { Time.now.utc })
      @path = path
      @clock = clock
    end

    # Tickers whose intents were actually PLACED (dry-run or live). This is
    # the executor's memory across restarts (issue #626): the in-memory hash
    # forgets, the venue's position does not, so the log arbitrates. Refusal
    # and halt lines are not placements and do not count.
    def placed_tickers
      return [] unless File.exist?(@path)

      File.readlines(@path).filter_map { |line|
        record = JSON.parse(line)
        record["ticker"] if %w[dry_run live].include?(record["mode"])
      }
    end

    def record(intent)
      # The order is already at the venue by the time we get here. A missing
      # directory must not be what loses the only record of it.
      FileUtils.mkdir_p(File.dirname(@path))
      line = JSON.generate(intent.merge(ts: @clock.call.strftime("%Y-%m-%dT%H:%M:%SZ")))
      File.open(@path, "a") { |f| f.puts(line) }
    end
  end
end
