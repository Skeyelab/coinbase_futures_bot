# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Sentiment
  # Ingests EIA weekly crude oil inventory as a sentiment signal. Unlike the
  # headline feeds, this is a numeric fundamental: a week-over-week stock draw is
  # bullish for crude, a build is bearish. We phrase the event title as
  # "inventory draw"/"inventory build" so the existing oil lexicon scores it with
  # no special-casing.
  #
  # Series WCESTUS1 = weekly ending stocks of crude oil (thousand barrels).
  class EiaInventoryClient < BaseNewsClient
    API_URL = "https://api.eia.gov/v2/petroleum/stoc/wstk/data/"
    SERIES = "WCESTUS1"

    def initialize(api_key: ENV["EIA_API_KEY"], logger: Rails.logger)
      super(logger: logger)
      @api_key = api_key
    end

    def enabled?
      @api_key.to_s.strip != ""
    end

    def source_name
      "eia_inventory"
    end

    def fetch_recent(max_pages: 1)
      return [] unless enabled?

      normalize(fetch_rows)
    rescue => e
      @logger.error("EIA inventory fetch failed: #{e.class} #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      []
    end

    private

    def fetch_rows
      params = {
        :api_key => @api_key,
        :frequency => "weekly",
        "data[0]" => "value",
        "facets[series][]" => SERIES,
        "sort[0][column]" => "period",
        "sort[0][direction]" => "desc",
        :length => 2
      }
      uri = URI(API_URL)
      uri.query = URI.encode_www_form(params)

      response = Net::HTTP.get_response(uri)
      return [] unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body).dig("response", "data") || []
    end

    # rows: EIA data array (newest first), each {"period"=>, "value"=>}.
    def normalize(rows)
      return [] if rows.size < 2

      latest, previous = rows[0], rows[1]
      delta = latest["value"].to_f - previous["value"].to_f
      return [] if delta.zero?

      direction = (delta < 0) ? "draw" : "build"
      million_bbl = (delta.abs / 1_000.0).round(1)
      period = latest["period"].to_s

      title = "EIA weekly crude oil inventory #{direction} of #{million_bbl} million barrels (week of #{period})"

      [{
        source: source_name,
        symbol: "OIL-USD",
        url: nil,
        title: title,
        published_at: parse_timestamp(period),
        raw_text_hash: generate_content_hash(source_name, period, "OIL-USD"),
        meta: {
          series: SERIES,
          period: period,
          value_kbbl: latest["value"],
          delta_kbbl: delta.round(1)
        }
      }]
    end
  end
end
