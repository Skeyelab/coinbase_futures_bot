require_relative "../lib/t_cdf"

RSpec.describe TCdf do
  # Golden values from scipy.stats.t.cdf, generated 2026-08-05 alongside the
  # grid itself. 0.335 sits BETWEEN grid points, so it exercises the
  # interpolation, not just the table lookup.
  it "matches scipy across the board for df=8" do
    expect(described_class.cdf(-2.0, df: 8)).to be_within(1e-4).of(0.04025812)
    expect(described_class.cdf(0.0, df: 8)).to be_within(1e-6).of(0.5)
    expect(described_class.cdf(0.335, df: 8)).to be_within(1e-4).of(0.62688003)
    expect(described_class.cdf(2.5, df: 8)).to be_within(1e-4).of(0.98152898)
  end

  it "matches scipy for df=5" do
    expect(described_class.cdf(-0.5, df: 5)).to be_within(1e-4).of(0.31914944)
    expect(described_class.cdf(1.0, df: 5)).to be_within(1e-4).of(0.81839127)
  end

  it "clamps beyond the grid instead of extrapolating nonsense" do
    expect(described_class.cdf(-50.0, df: 8)).to be_within(1e-6).of(0.0)
    expect(described_class.cdf(50.0, df: 8)).to be_within(1e-6).of(1.0)
  end

  it "refuses a df the grid does not carry" do
    expect { described_class.cdf(0.0, df: 3) }.to raise_error(TCdf::UnknownDf)
  end
end
