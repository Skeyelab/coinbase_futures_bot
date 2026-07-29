# frozen_string_literal: true

require "rails_helper"

# Issue #586, the static half. Preloaded#recent now REFUSES a missing cutoff,
# which turns a silent lookahead into a loud failure — but only on a code path
# a test actually exercises. This catches the same mistake at author time.
#
# freqtrade's documented lookahead failure modes, translated to a codebase that
# works in Ruby arrays rather than pandas dataframes:
#
#   "aggregation functions like .mean(), .min() and .max(), without a rolling
#    window, will calculate the value over the whole dataframe, so the signal
#    candle will 'see' a value including future candles"
#
# Our equivalent of a rolling window is `series.last(n)`. Our equivalent of the
# whole dataframe is the series the candle source hands back — which, absent a
# cutoff, runs to the end of the backtest.
# Helpers live in a module so the constants are not defined inside an RSpec
# block, and so `def` bodies can actually see them.
module LookaheadLint
  module_function

  STRATEGY_GLOBS = [
    Rails.root.join("app/services/strategy/*.rb"),
    Rails.root.join("app/services/signals/*.rb")
  ].freeze

  def sources
    STRATEGY_GLOBS.flat_map { |g| Dir[g] }
      .reject { |f| f.end_with?("candle_source.rb") } # the guard itself lives here
      .map { |f| [Pathname.new(f).relative_path_from(Rails.root).to_s, File.read(f)] }
  end

  # A series is BOUNDED if it came from something that took only a window of
  # candles — a limited candle read, or an explicit trailing slice. Aggregating
  # over one of those is an indicator, not lookahead.
  BOUNDED_SOURCE = /\.last\(|\.first\(|recent_candles\(|limit:|each_cons\(/

  # Walk back from a flagged line to the assignment that produced the receiver,
  # stopping at the enclosing `def`. Without this the rule cannot tell
  # `volumes.sum / volumes.size` over the last 10 candles — an average — from
  # the same expression over the whole run, which is the future.
  #
  # Boundedness is TRANSITIVE, which is how the real code reads:
  #
  #   candles = recent_candles(:five_minute, 10)   # bounded
  #   volumes = candles.map { |c| c.volume.to_f }  # bounded, via candles
  #   avg     = volumes.sum / volumes.size         # an average, not the future
  #
  # so an assignment that does not itself name a window is followed through the
  # locals it reads. `seen` stops a self-referential assignment from looping.
  def bounded_before?(lines, index, receiver, seen = Set.new)
    return false unless seen.add?(receiver)

    assignment = /^\s*#{Regexp.escape(receiver)}\s*=[^=]/

    index.downto(0) do |i|
      line = lines[i]
      break if i < index && line.match?(/^\s*def\s/)
      next unless line.match?(assignment)
      return true if line.match?(BOUNDED_SOURCE)

      rhs = line.split("=", 2).last.to_s
      return rhs.scan(/\b[a-z_][a-z0-9_]*\b/).any? { |name| bounded_before?(lines, i, name, seen) }
    end
    false
  end
end

RSpec.describe "indicator and strategy code cannot read the future", :lint do
  include LookaheadLint

  # Every candle read in a strategy has to carry the cutoff through. A call site
  # that omits it now raises at runtime, but only if something runs it; a
  # backtest that never hits that branch would ship the bias.
  it "threads as_of through every candle_source.recent call" do
    offenders = sources.flat_map do |path, body|
      body.each_line.each_with_index.filter_map do |line, i|
        next unless line.include?("candle_source.recent(") || line.include?(".recent(symbol:")
        # The call may wrap; look at the statement, not the line.
        statement = body.each_line.to_a[i, 3].join
        next if statement.include?("as_of")

        "#{path}:#{i + 1}"
      end
    end

    expect(offenders).to be_empty,
      "candle read without an as_of cutoff — in a backtest this reads past the current bar " \
      "(issue #586):\n  #{offenders.join("\n  ")}"
  end

  # A strategy that accepts as_of and then ignores it is the same bug wearing a
  # correct-looking signature.
  it "does not accept an as_of it never uses" do
    offenders = sources.filter_map do |path, body|
      next unless body.match?(/def signal\(.*as_of:/m)
      # One mention is the parameter itself; it has to appear again in the body.
      next if body.scan("as_of").size > 1

      path
    end

    expect(offenders).to be_empty,
      "accepts an as_of cutoff and never passes it on (issue #586):\n  #{offenders.join("\n  ")}"
  end

  # The freqtrade pattern, direct: an aggregation over a whole price series with
  # no trailing window. `closes.max` is the future high; `closes.last(20).max`
  # is an indicator.
  it "does not aggregate over an unbounded price series" do
    unbounded = /\b(closes|highs|lows|volumes|prices|series|candles)\.(max|min|sum|mean|average)\b/

    offenders = sources.flat_map do |path, body|
      lines = body.each_line.to_a
      lines.each_with_index.filter_map do |line, i|
        match = line.match(unbounded)
        next unless match
        next if line.include?(".last(") || line.include?(".first(") || line.include?("each_cons")
        next if line.strip.start_with?("#")
        next if bounded_before?(lines, i, match[1])

        "#{path}:#{i + 1}  #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "aggregation over a whole series rather than a trailing window — the current bar sees " \
      "values that include later candles (issue #586):\n  #{offenders.join("\n  ")}"
  end

  # The provenance rule is the part most likely to rot into a rubber stamp, so
  # it gets its own test rather than only ever being exercised by clean code.
  describe "the bounded-source rule" do
    let(:lines) { source.each_line.to_a }

    context "with a windowed series" do
      let(:source) do
        <<~RUBY
          def volume_confidence_score
            candles = recent_candles(:five_minute, 10)
            volumes = candles.map { |c| c.volume.to_f }
            avg = volumes.sum / volumes.size
          end
        RUBY
      end

      it "accepts an aggregation over it" do
        expect(bounded_before?(lines, 3, "volumes")).to be(true)
      end
    end

    context "with a series read whole" do
      let(:source) do
        <<~RUBY
          def volume_confidence_score
            volumes = every_candle_in_the_run.map { |c| c.volume.to_f }
            avg = volumes.sum / volumes.size
          end
        RUBY
      end

      it "rejects an aggregation over it" do
        expect(bounded_before?(lines, 2, "volumes")).to be(false)
      end
    end

    context "when the assignment is in a different method" do
      let(:source) do
        <<~RUBY
          def elsewhere
            volumes = candles.last(10)
          end

          def here
            avg = volumes.sum / volumes.size
          end
        RUBY
      end

      it "does not borrow boundedness across the def boundary" do
        expect(bounded_before?(lines, 5, "volumes")).to be(false)
      end
    end
  end

  # shift(-n) is freqtrade's canonical example. In Ruby it looks like reaching
  # forward off the end of the current position, or indexing from the tail when
  # the tail is the future.
  it "does not reach forward in a series" do
    offenders = sources.flat_map do |path, body|
      body.each_line.each_with_index.filter_map do |line, i|
        next unless line.match?(/\.shift\(-|\.drop\(-|\bfetch\(\s*\w+\s*\+\s*1\s*\)/)
        next if line.strip.start_with?("#")

        "#{path}:#{i + 1}  #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "reads forward of the current bar (issue #586):\n  #{offenders.join("\n  ")}"
  end
end
