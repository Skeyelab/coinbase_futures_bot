require "json"
require "net/http"
require "uri"
require "fileutils"

# Season named-storm counts per basin, from the National Hurricane Center's
# public CurrentStorms feed -- the NWS source Kalshi's KXNAMEDSTORM rules name.
#
# The ratchet here is subtler than weather's. NHC publishes only ACTIVE storms,
# so the feed itself is not monotone: a storm leaves the list when it
# dissipates. The season COUNT is monotone, which means the ratchet exists only
# if we remember. Names seen are therefore persisted; forgetting one would let
# a confirmed contract silently un-confirm, the exact failure the whole
# settled-fact thesis cannot survive.
#
# Built before the snow markets list and while KXNAMEDSTORM is already open.
class StormCountSource
  NHC_CURRENT = "https://www.nhc.noaa.gov/CurrentStorms.json".freeze

  # NHC bin numbers carry the basin prefix: AL (Atlantic), EP (East Pacific),
  # CP (Central Pacific). Kalshi names basins ATL / EPAC / CPAC.
  BASINS = {"AL" => "ATL", "EP" => "EPAC", "CP" => "CPAC"}.freeze

  # A named storm is at least a tropical storm. Depressions carry numbers, not
  # names, and do not count toward a named-storm total.
  NAMED_CLASSIFICATIONS = %w[TS HU TY ST SS MH].freeze

  def initialize(fetch: nil, state_path: nil)
    @fetch = fetch || method(:http_fetch)
    @state_path = state_path
    @seen = load_state
  end

  # Poll NHC and fold anything new into the running per-basin sets.
  def observe!
    payload = @fetch.call
    Array(payload && payload["activeStorms"]).each do |storm|
      next unless named?(storm)

      basin = BASINS[storm["binNumber"].to_s[0, 2]]
      next unless basin

      (@seen[basin] ||= []) << identity(storm)
      @seen[basin].uniq!
    end
    save_state
    @seen
  rescue
    # A failed poll must never shrink the count. Silence is not dissipation.
    @seen
  end

  def count(basin)
    Array(@seen[basin]).size
  end

  # Not private: the constructor takes method(:http_fetch) as the default, and
  # a private method is unreachable there.
  def http_fetch
    response = Net::HTTP.get_response(URI(NHC_CURRENT))
    return nil unless response.code == "200"

    JSON.parse(response.body)
  rescue
    nil
  end

  private

  def named?(storm)
    NAMED_CLASSIFICATIONS.include?(storm["classification"].to_s.upcase) &&
      !storm["name"].to_s.strip.empty?
  end

  # Name plus basin, not the NHC id: ids are per-storm advisories and can
  # change form, while a season's name is used once.
  def identity(storm)
    storm["name"].to_s.strip.downcase
  end

  def load_state
    return {} unless @state_path && File.exist?(@state_path)

    JSON.parse(File.read(@state_path))
  rescue
    {}
  end

  def save_state
    return unless @state_path

    FileUtils.mkdir_p(File.dirname(@state_path))
    File.write(@state_path, JSON.generate(@seen))
  end
end
