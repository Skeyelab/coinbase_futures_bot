require "json"

# Append-only record of every order intent, dry-run or live. Gate item #3 is
# scored off this file, so it must exist before the first order does.
module Execution
  class OrderLog
    def initialize(path:, clock: -> { Time.now.utc })
      @path = path
      @clock = clock
    end

    def record(intent)
      line = JSON.generate(intent.merge(ts: @clock.call.strftime("%Y-%m-%dT%H:%M:%SZ")))
      File.open(@path, "a") { |f| f.puts(line) }
    end
  end
end
