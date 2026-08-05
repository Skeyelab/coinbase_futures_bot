require "net/http"
require "json"
require "uri"

# The only place the write path touches the network.
#
# Kept separate from KalshiClient's private fetch on purpose: that one is
# GET-only by construction, and the read client's guarantee -- it cannot place
# a trade -- survives only while nothing here leaks back into it.
module Execution
  class HttpTransport
    # The write path lives on external-api. api.elections.kalshi.com still
    # answers GETs, which is why the retired order endpoint went unnoticed.
    BASE = "https://external-api.kalshi.com/trade-api/v2".freeze

    class RequestFailed < StandardError; end

    VERBS = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "DELETE" => Net::HTTP::Delete
    }.freeze

    def initialize(base: BASE, connect: nil)
      @base = base
      @connect = connect || method(:open_https)
    end

    def call(method:, path:, headers:, body: nil)
      uri = URI("#{@base}#{path}")
      request = build(method, uri, headers, body)
      response = @connect.call(uri).request(request)

      raise RequestFailed, "#{method} #{path} -> HTTP #{response.code}#{venue_code(response)}" unless response.code.start_with?("2")

      JSON.parse(response.body)
    end

    private

    # The venue's `code` is a fixed enum -- deprecated_v1_order_endpoint,
    # missing_parameters -- so it names the fault without echoing anything we
    # sent. `message` and `details` quote request material back, and exception
    # text ends up in logs, so they stay out.
    def venue_code(response)
      code = JSON.parse(response.body.to_s).dig("error", "code")
      code ? " (#{code})" : ""
    rescue JSON::ParserError
      ""
    end

    def build(method, uri, headers, body)
      klass = VERBS.fetch(method) { raise RequestFailed, "unsupported verb #{method}" }
      request = klass.new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body if body
      request
    end

    def open_https(uri)
      http = Net::HTTP.new(uri.host, 443)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 15
      http
    end
  end
end
