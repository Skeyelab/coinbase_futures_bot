# Rival stations for the series whose rules text does NOT name one.
#
# The twelve inferred highs and nine inferred lows say only "at Atlanta", "at
# Phoenix". The station in cities.rb is the obvious primary climate site, which
# is very likely right and is NOT evidence -- Chicago settling on Midway rather
# than O'Hare is exactly this class of error, and it was only caught because
# that market's rules happen to name the station.
#
# These lists exist to be WRONG on purpose. StationEvidence only learns from
# days where candidates disagree, so a rival that never differs from the
# incumbent teaches nothing; the useful rivals are the ones far enough away, or
# different enough in siting, to straddle a bucket boundary now and then.
#
# Every id below was checked against api.weather.gov on 2026-08-05 and returned
# a live temperature. Observed spreads at that moment, which is what makes them
# worth carrying: OKC 84.2/87.8/83.7, DC 80.6/78.8/77.0, Denver 55.0/57.2/53.6.
#
# The incumbent is listed FIRST in each list, and is always present -- evidence
# that cannot promote the sitting station can only ever disprove it.
module StationCandidates
  BY_SERIES = {
    # --- inferred daily highs ------------------------------------------------
    "KXHIGHTATL" => %w[KATL KFTY KPDK],     # Hartsfield, Fulton County, DeKalb-Peachtree
    "KXHIGHTBOS" => %w[KBOS KOWD KBED],     # Logan, Norwood, Hanscom
    "KXHIGHTDC" => %w[KDCA KIAD KBWI],      # Reagan National, Dulles, BWI
    "KXHIGHTDAL" => %w[KDFW KDAL KADS],     # DFW, Love Field, Addison
    "KXHIGHTMIN" => %w[KMSP KSTP KFCM],     # MSP, St Paul Downtown, Flying Cloud
    "KXHIGHTNOLA" => %w[KMSY KNEW KHUM],    # Armstrong, Lakefront, Houma
    "KXHIGHTOKC" => %w[KOKC KPWA KTIK],     # Will Rogers, Wiley Post, Tinker AFB
    "KXHIGHTSATX" => %w[KSAT KSSF KRND],    # SA International, Stinson, Randolph AFB
    "KXHIGHTPHX" => %w[KPHX KDVT KSDL],     # Sky Harbor, Deer Valley, Scottsdale
    "KXHIGHTLV" => %w[KLAS KVGT KHND],      # Harry Reid, North Las Vegas, Henderson
    "KXHIGHTSEA" => %w[KSEA KBFI KPAE],     # SeaTac, Boeing Field, Paine
    "KXHIGHTSFO" => %w[KSFO KOAK KHWD],     # SFO, Oakland, Hayward

    # --- inferred daily lows -------------------------------------------------
    # A low is the more discriminating direction: overnight minima diverge more
    # across a metro than afternoon maxima do, because cold air pools where the
    # siting differs. These are the same rivals, carried for the LOW series.
    "KXLOWTDEN" => %w[KDEN KAPA KBJC],      # Denver Intl, Centennial, Rocky Mtn Metro
    "KXLOWTATL" => %w[KATL KFTY KPDK],
    "KXLOWTCHI" => %w[KMDW KORD KPWK],      # Midway, O'Hare, Chicago Executive
    "KXLOWTMIN" => %w[KMSP KSTP KFCM],
    "KXLOWTOKC" => %w[KOKC KPWA KTIK],
    "KXLOWTSATX" => %w[KSAT KSSF KRND],
    "KXLOWTSFO" => %w[KSFO KOAK KHWD],
    "KXLOWTLV" => %w[KLAS KVGT KHND],
    "KXLOWTPHIL" => %w[KPHL KPNE KILG]      # Philadelphia Intl, Northeast Phl, Wilmington
  }.freeze

  module_function

  # The rivals for a series, or an empty list when its station is already named
  # in the rules text and there is nothing to establish.
  def for_series(series)
    BY_SERIES.fetch(series, [])
  end
end
