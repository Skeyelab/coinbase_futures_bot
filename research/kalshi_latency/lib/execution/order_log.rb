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

    def record(intent)
      # The order is already at the venue by the time we get here. A missing
      # directory must not be what loses the only record of it.
      FileUtils.mkdir_p(File.dirname(@path))
      line = JSON.generate(intent.merge(ts: @clock.call.strftime("%Y-%m-%dT%H:%M:%SZ")))
      File.open(@path, "a") { |f| f.puts(line) }
    end
  end
end
