require "json"

# Student-t CDF by linear interpolation over a precomputed scipy grid
# (lib/data/tcdf_grid.json, z in [-8, 8] step 0.01, one column per df).
#
# A grid instead of an incomplete-beta implementation on purpose: zero
# numerics risk, and a mutation to the lookup is caught by golden values
# where a subtle continued-fraction bug would not be.
module TCdf
  class UnknownDf < StandardError; end

  GRID_PATH = File.expand_path("data/tcdf_grid.json", __dir__)

  def self.grid
    @grid ||= JSON.parse(File.read(GRID_PATH))
  end

  def self.cdf(z, df:)
    column = grid["cdf"][df.to_s]
    raise UnknownDf, "no CDF column for df=#{df}" unless column

    z_min = grid["z_min"]
    step = grid["z_step"]
    position = (z - z_min) / step

    return 0.0 if position <= 0
    return 1.0 if position >= column.size - 1

    lower = position.floor
    fraction = position - lower
    column[lower] * (1 - fraction) + column[lower + 1] * fraction
  end
end
