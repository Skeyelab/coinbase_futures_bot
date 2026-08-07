require_relative "../../lib/execution/order_client"
require "json"
require "openssl"

# Generated once for the whole file. Per-example generation cost 12 seconds
# of suite time; the signature only has to verify against its own key.
TEST_RSA = OpenSSL::PKey::RSA.generate(2048)

RSpec.describe Execution::OrderClient do
  require "base64"

  let(:rsa) { TEST_RSA }

  def test_signer
    KalshiSigner.new(key_id: "test-key", private_key_pem: rsa.to_pem)
  end

  # The venue is the only other party that checks this. Asserting a key header
  # exists proves nothing -- a signature over the wrong verb carries the same
  # header and fails live as a bare 401 that names neither half.
  def signs?(headers, verb, path)
    message = headers["KALSHI-ACCESS-TIMESTAMP"] + verb + path
    rsa.verify_pss("SHA256", Base64.strict_decode64(headers["KALSHI-ACCESS-SIGNATURE"]),
      message, salt_length: :auto, mgf1_hash: "SHA256")
  end

  def opportunity
    {
      ticker: "KXHIGHNY-26AUG04-B83.5",
      side: :sell,
      price_cents: 12,
      contracts: 25,
      edge_cents: 12,
      gross_cents: 300,
      fee_cents: 19,
      net_cents: 281
    }
  end

  describe "live mode" do
    it "cannot be constructed without the environment agreeing" do
      # Two independent switches must both be thrown: live: true in code AND
      # KALSHI_LIVE=1 in the environment. Either alone refuses. This is what
      # makes "accidentally live" require two separate mistakes.
      expect {
        described_class.new(transport: ->(*) {}, live: true, env: {})
      }.to raise_error(Execution::OrderClient::LiveRefused)
    end

    it "is not live just because the environment says so" do
      client = described_class.new(transport: ->(*) { raise "no network" }, env: {"KALSHI_LIVE" => "1"})

      expect(client.place(opportunity)[:mode]).to eq("dry_run")
    end

    # The v2 event-order shape. The old body -- action + yes/no side + integer
    # cent prices -- now returns HTTP 410 deprecated_v1_order_endpoint, and no
    # dry-run test could ever have caught that.
    it "POSTs a v2 event order: bid/ask side, string count, dollar price" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {path: path, body: body}
        {"order_id" => "abc-123"}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      client.place(opportunity)

      expect(seen[:path]).to eq("/portfolio/events/orders")
      order = JSON.parse(seen[:body])
      expect(order).to include(
        "ticker" => "KXHIGHNY-26AUG04-B83.5",
        "side" => "ask",              # selling YES
        "count" => "25.00",
        "price" => "0.1200",          # 12c in fixed-point dollars
        "time_in_force" => "good_till_canceled",
        # Required. Omitting it is a 400 missing_parameters, which no fake
        # could have told us: the venue is the only source for this list.
        "self_trade_prevention_type" => "taker_at_cross"
      )
      expect(order).not_to have_key("action")
      expect(order).not_to have_key("yes_price")
    end

    it "quotes a buy as a bid" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = JSON.parse(body)
        {"order_id" => "x"}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      client.place(opportunity.merge(side: :buy))

      expect(seen["side"]).to eq("bid")
    end

    it "POSTs a signed order through the transport" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {method: method, path: path, headers: headers, body: body}
        # v2 create returns a FLAT 201 body -- no "order" wrapper. Digging for
        # one yields nil, and a nil order_id means nothing can be watched or
        # cancelled afterwards.
        {"order_id" => "abc-123", "client_order_id" => "x", "remaining_count" => "1.00"}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      intent = client.place(opportunity)

      expect(seen[:path]).to eq("/portfolio/events/orders")
      expect(seen[:headers]).to include("KALSHI-ACCESS-KEY" => "test-key")
      expect(signs?(seen[:headers], "POST", "/trade-api/v2/portfolio/events/orders")).to be(true)
      expect(intent[:mode]).to eq("live")
      expect(intent[:order_id]).to eq("abc-123")
    end

    it "tags every order with a fresh client_order_id so a retry cannot double-fill" do
      bodies = []
      transport = ->(method:, path:, headers:, body: nil) {
        bodies << JSON.parse(body)
        {"order_id" => "x"}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      first = client.place(opportunity)
      second = client.place(opportunity)

      expect(bodies[0]["client_order_id"]).to eq(first[:client_order_id])
      expect(bodies[1]["client_order_id"]).to eq(second[:client_order_id])
      expect(first[:client_order_id]).not_to eq(second[:client_order_id])
      expect(first[:client_order_id]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end
  end

  describe "cancel" do
    it "reports what it would cancel without touching the network in dry-run" do
      client = described_class.new(transport: ->(*) { raise "dry run must not reach transport" })

      intent = client.cancel("abc-123")

      expect(intent).to include(action: "cancel", order_id: "abc-123", mode: "dry_run")
    end

    it "DELETEs the order and signs the bare path" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {method: method, path: path, headers: headers, body: body}
        {"order" => {"order_id" => "abc-123", "status" => "canceled"}}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      intent = client.cancel("abc-123")

      expect(seen[:method]).to eq("DELETE")
      expect(seen[:path]).to eq("/portfolio/events/orders/abc-123")
      expect(seen[:body]).to be_nil
      expect(signs?(seen[:headers], "DELETE", "/trade-api/v2/portfolio/events/orders/abc-123")).to be(true)
      expect(intent[:mode]).to eq("live")
    end
  end

  describe "reading one order back" do
    it "GETs the order and hands back the venue's own view of it" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {method: method, path: path, headers: headers}
        {"order" => {"order_id" => "abc-123", "status" => "resting", "remaining_count_fp" => "5.00"}}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      state = client.order("abc-123")

      expect(seen[:method]).to eq("GET")
      expect(seen[:path]).to eq("/portfolio/orders/abc-123")
      expect(signs?(seen[:headers], "GET", "/trade-api/v2/portfolio/orders/abc-123")).to be(true)
      expect(state).to include("status" => "resting", "remaining_count_fp" => "5.00")
    end

    # A freshly created order 404s for a moment before the venue will serve it
    # back. That is not "no such order", it is "not yet" -- and treating it as
    # an error aborts the watch on an order that is already live at the venue.
    it "returns nil while the venue cannot see the order yet" do
      transport = ->(method:, path:, headers:, body: nil) {
        raise Execution::HttpTransport::RequestFailed, "GET x -> HTTP 404 (not_found)"
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      expect(client.order("abc-123")).to be_nil
    end

    # A 401 or a 500 is not "not yet" and must not be swallowed into a nil
    # that reads as a resting order.
    it "still raises on any other failure" do
      transport = ->(method:, path:, headers:, body: nil) {
        raise Execution::HttpTransport::RequestFailed, "GET x -> HTTP 401"
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      expect { client.order("abc-123") }.to raise_error(Execution::HttpTransport::RequestFailed)
    end

    # There is no order to read in dry-run. Returning an empty state would let
    # a caller conclude "remaining 0, therefore filled" about an order that was
    # never placed.
    it "refuses in dry-run rather than inventing a state" do
      client = described_class.new(transport: ->(*) { raise "dry run must not reach transport" })

      expect { client.order("abc-123") }.to raise_error(Execution::OrderClient::NotLive)
    end
  end

  describe "reading an order's fills" do
    # Gate #3 hinges on is_taker (issue #631): a taker fill at the quoted
    # price is trivially "at or better" and proves nothing about whether a
    # resting quote gets hit. The fills endpoint is where is_taker lives.
    it "GETs the fills with the order_id in the QUERY but not in the signature" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {method: method, path: path, headers: headers}
        {"fills" => [{"is_taker" => true, "count_fp" => "1.00"}]}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      fills = client.fills("ord-9")

      expect(seen[:method]).to eq("GET")
      expect(seen[:path]).to eq("/portfolio/fills?order_id=ord-9")
      # Kalshi signs <ts><verb><path> with NO query string. Signing the query
      # is a bare 401 that names neither half.
      expect(signs?(seen[:headers], "GET", "/trade-api/v2/portfolio/fills")).to be(true)
      expect(fills.first["is_taker"]).to be(true)
    end

    it "has no fills to read in dry-run" do
      client = described_class.new(transport: ->(*) { raise "no network" })

      expect { client.fills("ord-9") }.to raise_error(Execution::OrderClient::NotLive)
    end
  end

  describe "validation" do
    def client
      described_class.new(transport: ->(*) { raise "must not reach transport" })
    end

    it "refuses a price off the 1-99 board" do
      expect { client.place(opportunity.merge(price_cents: 0)) }
        .to raise_error(Execution::OrderClient::BadOrder, /price/)
      expect { client.place(opportunity.merge(price_cents: 100)) }
        .to raise_error(Execution::OrderClient::BadOrder, /price/)
    end

    it "refuses zero or negative size" do
      expect { client.place(opportunity.merge(contracts: 0)) }
        .to raise_error(Execution::OrderClient::BadOrder, /count/)
    end

    # 2026-08-07: with MAX_CONTRACTS=1 live, every approved candidate died here.
    # The scanner sizes from resting depth (25 contracts on LAX) and raising
    # turned a legitimate depth reading into a swallowed cycle error, so the
    # bot found trades all afternoon and placed none. max_contracts is a RISK
    # BUDGET, not a claim that the order is malformed: clamp to it, the same
    # thing Backtest::Engine#capped_contracts does live.
    it "clamps an oversized order down to the cap instead of refusing it" do
      capped = described_class.new(transport: ->(*) { raise "dry-run" }, max_contracts: 10)

      intent = capped.place(opportunity.merge(contracts: 25))

      expect(intent[:count]).to eq("10.00")
      expect(intent[:mode]).to eq("dry_run")
    end

    it "leaves an order inside the cap alone" do
      capped = described_class.new(transport: ->(*) { raise "dry-run" }, max_contracts: 10)

      expect(capped.place(opportunity.merge(contracts: 4))[:count]).to eq("4.00")
    end

    it "still refuses a non-positive count -- that is malformed, not oversized" do
      client = described_class.new(transport: ->(*) { raise "dry-run" }, max_contracts: 10)

      expect { client.place(opportunity.merge(contracts: 0)) }
        .to raise_error(Execution::OrderClient::BadOrder, /count/)
    end

    it "refuses a side that is not buy or sell" do
      expect { client.place(opportunity.merge(side: :hold)) }
        .to raise_error(Execution::OrderClient::BadOrder, /side/)
    end
  end

  describe "dry-run mode (the default)" do
    it "returns the order it would have placed without touching the network" do
      transport = ->(*) { raise "dry run must never reach the transport" }
      client = described_class.new(transport: transport)

      intent = client.place(opportunity)

      expect(intent[:mode]).to eq("dry_run")
      expect(intent[:ticker]).to eq("KXHIGHNY-26AUG04-B83.5")
      expect(intent[:side]).to eq("ask")
      expect(intent[:price]).to eq("0.1200")
      expect(intent[:count]).to eq("25.00")
    end
  end
end
