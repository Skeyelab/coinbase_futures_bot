require "json"
require_relative "../../lib/execution/http_transport"

RSpec.describe Execution::HttpTransport do
  # Stands in for Net::HTTP. Captures the request object the transport built so
  # the test can assert on the verb, URI and headers that would go out.
  class FakeHttp
    attr_reader :sent

    def initialize(code: "200", body: '{"order":{"order_id":"abc-123"}}')
      @code = code
      @body = body
    end

    def request(req)
      @sent = req
      Struct.new(:code, :body).new(@code, @body)
    end
  end

  it "sends the verb, the signed headers and the body, and parses the reply" do
    http = FakeHttp.new
    transport = described_class.new(connect: ->(_uri) { http })

    reply = transport.call(method: "POST", path: "/portfolio/orders",
      headers: {"KALSHI-ACCESS-KEY" => "k"}, body: '{"count":5}')

    expect(http.sent.method).to eq("POST")
    expect(http.sent.uri.to_s).to eq("https://api.elections.kalshi.com/trade-api/v2/portfolio/orders")
    expect(http.sent["KALSHI-ACCESS-KEY"]).to eq("k")
    expect(http.sent.body).to eq('{"count":5}')
    expect(reply.dig("order", "order_id")).to eq("abc-123")
  end

  it "builds a DELETE with no body" do
    http = FakeHttp.new(body: '{"order":{"status":"canceled"}}')
    transport = described_class.new(connect: ->(_uri) { http })

    transport.call(method: "DELETE", path: "/portfolio/orders/abc-123", headers: {})

    expect(http.sent.method).to eq("DELETE")
    expect(http.sent.body).to be_nil
  end

  # A failed write must never look like a successful one. Reporting the status
  # alone keeps the venue's reply -- which can echo request material -- out of
  # the log, per the exo-mini rule about exception text.
  it "raises on a non-2xx instead of returning a parsed error" do
    transport = described_class.new(connect: ->(_uri) { FakeHttp.new(code: "401", body: "nope") })

    expect {
      transport.call(method: "POST", path: "/portfolio/orders", headers: {}, body: "{}")
    }.to raise_error(Execution::HttpTransport::RequestFailed, /401/)
  end
end
