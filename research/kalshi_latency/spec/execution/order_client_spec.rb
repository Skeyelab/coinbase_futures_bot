require_relative "../../lib/execution/order_client"
require "json"
require "openssl"

RSpec.describe Execution::OrderClient do
  require "base64"

  # Generated once for the whole file. Per-example generation cost 12 seconds
  # of suite time; the signature only has to verify against its own key.
  TEST_RSA = OpenSSL::PKey::RSA.generate(2048)

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

    it "POSTs a signed order through the transport" do
      seen = nil
      transport = ->(method:, path:, headers:, body: nil) {
        seen = {method: method, path: path, headers: headers, body: body}
        {"order" => {"order_id" => "abc-123", "status" => "resting"}}
      }
      client = described_class.new(transport: transport, live: true,
        env: {"KALSHI_LIVE" => "1"}, signer: test_signer)

      intent = client.place(opportunity)

      expect(seen[:path]).to eq("/portfolio/orders")
      expect(seen[:headers]).to include("KALSHI-ACCESS-KEY" => "test-key")
      order = JSON.parse(seen[:body])
      expect(order).to include(
        "ticker" => "KXHIGHNY-26AUG04-B83.5",
        "action" => "sell", "side" => "yes", "yes_price" => 12,
        "count" => 25, "type" => "limit"
      )
      expect(intent[:mode]).to eq("live")
      expect(intent[:order_id]).to eq("abc-123")
    end

    it "tags every order with a fresh client_order_id so a retry cannot double-fill" do
      bodies = []
      transport = ->(method:, path:, headers:, body: nil) {
        bodies << JSON.parse(body)
        {"order" => {"order_id" => "x"}}
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

  describe "the NO side" do
    # Closing a NO position means selling NO, and Kalshi prices that leg in
    # no_price. Sending yes_price with side "no" prices the wrong leg: 3c
    # becomes 97c and the close crosses the whole book.
    it "prices a NO order in no_price, not yes_price" do
      client = described_class.new(transport: ->(*) { raise "dry run must not reach transport" })

      intent = client.place(opportunity.merge(outcome_side: :no, price_cents: 3))

      expect(intent[:side]).to eq("no")
      expect(intent[:no_price]).to eq(3)
      expect(intent).not_to have_key(:yes_price)
    end

    it "still quotes in YES terms when no side is named" do
      client = described_class.new(transport: ->(*) { raise "dry run must not reach transport" })

      intent = client.place(opportunity)

      expect(intent[:side]).to eq("yes")
      expect(intent[:yes_price]).to eq(12)
      expect(intent).not_to have_key(:no_price)
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
      expect(seen[:path]).to eq("/portfolio/orders/abc-123")
      expect(seen[:body]).to be_nil
      expect(signs?(seen[:headers], "DELETE", "/trade-api/v2/portfolio/orders/abc-123")).to be(true)
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

    # There is no order to read in dry-run. Returning an empty state would let
    # a caller conclude "remaining 0, therefore filled" about an order that was
    # never placed.
    it "refuses in dry-run rather than inventing a state" do
      client = described_class.new(transport: ->(*) { raise "dry run must not reach transport" })

      expect { client.order("abc-123") }.to raise_error(Execution::OrderClient::NotLive)
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

    it "caps order size so one bad episode cannot empty the account" do
      capped = described_class.new(transport: ->(*) {}, max_contracts: 10)

      expect { capped.place(opportunity.merge(contracts: 11)) }
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
      expect(intent[:action]).to eq("sell")
      expect(intent[:side]).to eq("yes")
      expect(intent[:yes_price]).to eq(12)
      expect(intent[:count]).to eq(25)
    end
  end
end
