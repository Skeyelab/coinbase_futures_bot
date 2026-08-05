require "fileutils"

# The kill switch (issue #625). Kalshi is a separate app from the Rails bot
# and cannot borrow trading_halt.rb, so this is its own: a HALT file in the
# data directory. The execution path checks it before every order; the
# operator sets it from any shell with no deploy:
#
#   ruby bin/halt "why"      # or: touch ~/kalshi-data/HALT
#   ruby bin/halt --resume   # or: rm ~/kalshi-data/HALT
#
# A file rather than memory or an API: it survives restarts, works when the
# process is wedged, and its absence is the only state that permits an order.
module Execution
  class Halt
    FILENAME = "HALT".freeze

    def initialize(data_dir:)
      @path = File.join(data_dir, FILENAME)
    end

    def active?
      File.exist?(@path)
    end

    def reason
      return nil unless active?

      File.read(@path).strip
    end

    def engage!(reason = "")
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, reason.to_s)
    end

    def resume!
      FileUtils.rm_f(@path)
    end
  end
end
