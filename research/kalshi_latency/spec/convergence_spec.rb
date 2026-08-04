require_relative "../lib/convergence"

RSpec.describe Convergence do
  # mids: [seconds_since_publication, mid_price_cents]
  def series(pairs, published_at: 1000.0)
    pairs.map { |offset, mid| {at: published_at + offset, mid: mid.to_f} }
  end

  describe ".measure" do
    # The number lands at t=0. The book sits at 40c for three seconds, then
    # walks to 90c over the next four, and settles. The tradeable window is the
    # gap between publication and the market being mostly done moving.
    it "measures how long the market took to absorb the release" do
      mids = series([[-2, 40], [-1, 40], [0, 40], [1, 40], [2, 40], [3, 55],
        [4, 70], [5, 85], [6, 90], [7, 90], [8, 90]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:pre_mid]).to eq(40.0)
      expect(result[:settled_mid]).to eq(90.0)
      expect(result[:move_cents]).to eq(50.0)
      expect(result[:seconds_to_first_move]).to eq(3.0)
      expect(result[:seconds_to_half]).to eq(4.0)
      expect(result[:seconds_to_ninety]).to eq(5.0)
    end

    # THE KILL CASE. If the book jumps in the first sample after publication,
    # there was never a window -- the measurement must say 1 second, not
    # flatter it by reporting the settle time of a move that already happened.
    it "reports no window when the book gaps instantly" do
      mids = series([[-2, 40], [-1, 40], [1, 90], [2, 90], [3, 90]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:seconds_to_first_move]).to eq(1.0)
      expect(result[:seconds_to_ninety]).to eq(1.0)
    end

    it "measures a move downward the same as a move up" do
      mids = series([[-1, 90], [0, 90], [2, 70], [4, 41], [5, 40], [6, 40]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:move_cents]).to eq(50.0)
      expect(result[:seconds_to_first_move]).to eq(2.0)
    end

    # A market the release did not touch has no reaction to time. Reporting a
    # window here would manufacture an edge out of noise.
    it "times nothing when the market barely moved" do
      mids = series([[-1, 50], [0, 50], [1, 51], [2, 50], [3, 51]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:move_cents]).to be < 3.0
      expect(result[:seconds_to_first_move]).to be_nil
      expect(result[:seconds_to_ninety]).to be_nil
    end

    # A dislocation that reverts is not absorption. Timing the spike would
    # report a window on a market that ended up exactly where it started.
    it "reports no window when a spike reverts to the starting price" do
      mids = series([[-2, 50], [-1, 50], [1, 62], [2, 55], [3, 50], [4, 50], [5, 50]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:move_cents]).to be < 3.0
      expect(result[:seconds_to_first_move]).to be_nil
    end

    # If the book already moved BEFORE the figure was public, that is leakage,
    # not reaction. Counting those samples would report a window measured from
    # a move that had already happened -- the most flattering possible error.
    it "never credits a pre-publication move as a reaction" do
      # The book was at 90 well before the release, settled to 40 just before
      # it, then genuinely repriced to 90 afterwards. Scanning pre-publication
      # samples would match that early 90 and report a NEGATIVE window.
      mids = series([[-6, 90], [-5, 90], [-4, 90], [-3, 40], [-2, 40], [-1, 40],
        [1, 40], [2, 65], [3, 90], [4, 90], [5, 90]])

      result = described_class.measure(mids, published_at: 1000.0, move_threshold: 3.0)

      expect(result[:pre_mid]).to eq(40.0)
      expect(result[:move_cents]).to eq(50.0)
      expect(result[:seconds_to_first_move]).to eq(2.0)
      expect(result[:seconds_to_first_move]).to be > 0
    end

    it "has nothing to say without samples on both sides of publication" do
      only_after = series([[1, 50], [2, 60]])

      expect(described_class.measure(only_after, published_at: 1000.0)[:move_cents]).to be_nil
      expect(described_class.measure([], published_at: 1000.0)[:samples_after]).to eq(0)
    end

    # A single spiky tick before publication must not define the baseline, or
    # every window is measured from a price that never really existed.
    it "takes the baseline from a median, not the last tick" do
      mids = series([[-3, 40], [-2, 40], [-1, 70], [1, 40], [2, 40], [3, 40]])

      expect(described_class.measure(mids, published_at: 1000.0)[:pre_mid]).to eq(40.0)
    end
  end
end
