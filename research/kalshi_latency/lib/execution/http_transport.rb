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
    BASE = "https://api.elections.kalshi.com/trade-api/v2".freeze

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

      # The venue's reply can echo request material, and exception text ends up
      # in logs. The status is the whole diagnosis a caller needs.
      raise RequestFailed, "#{method} #{path} -> HTTP #{response.code}" unless response.code.start_with?("2")

      JSON.parse(response.body)
    end

    private

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
