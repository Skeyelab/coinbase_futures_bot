require "openssl"
require "base64"
require_relative "../lib/kalshi_signer"

RSpec.describe KalshiSigner do
  # Generated once per run: the signature only has to verify against its own
  # key, and a checked-in private key would be a liability even for a test.
  let(:rsa) { OpenSSL::PKey::RSA.generate(2048) }
  let(:signer) { described_class.new(key_id: "abc-123", private_key_pem: rsa.to_pem) }

  def verify(headers, expected_message)
    rsa.verify_pss("SHA256", Base64.strict_decode64(headers["KALSHI-ACCESS-SIGNATURE"]),
      expected_message, salt_length: :auto, mgf1_hash: "SHA256")
  end

  describe "#headers_for" do
    it "signs timestamp, method and path so the venue can verify it" do
      headers = signer.headers_for(method: "GET", path: "/trade-api/v2/portfolio/balance",
        timestamp_ms: 1_785_869_198_000)

      expect(headers["KALSHI-ACCESS-KEY"]).to eq("abc-123")
      expect(headers["KALSHI-ACCESS-TIMESTAMP"]).to eq("1785869198000")
      expect(verify(headers, "1785869198000GET/trade-api/v2/portfolio/balance")).to be(true)
    end

    # The venue signs the path only. Including the query produces a signature it
    # cannot reproduce, and the failure is a bare 401 that says nothing about
    # which half was wrong -- so it is worth pinning rather than discovering.
    it "signs the path without its query string" do
      headers = signer.headers_for(method: "GET",
        path: "/trade-api/v2/markets/KXHIGHNY-26AUG05-B80.5/orderbook?depth=10",
        timestamp_ms: 1_000)

      expect(verify(headers, "1000GET/trade-api/v2/markets/KXHIGHNY-26AUG05-B80.5/orderbook")).to be(true)
    end

    it "upcases the method so a lowercase verb still verifies" do
      headers = signer.headers_for(method: "get", path: "/x", timestamp_ms: 1_000)

      expect(verify(headers, "1000GET/x")).to be(true)
    end

    it "stamps its own timestamp when none is given" do
      before = (Time.now.to_f * 1000).round
      headers = signer.headers_for(method: "GET", path: "/x")

      expect(headers["KALSHI-ACCESS-TIMESTAMP"].to_i).to be >= before
    end

    # Doppler and .env both hand back PEMs with escaped newlines.
    it "accepts a key whose newlines arrived escaped" do
      escaped = described_class.new(key_id: "k", private_key_pem: rsa.to_pem.gsub("\n", '\n'))

      expect { escaped.headers_for(method: "GET", path: "/x", timestamp_ms: 1) }.not_to raise_error
    end

    it "produces a different signature for a different path" do
      a = signer.headers_for(method: "GET", path: "/a", timestamp_ms: 1)
      b = signer.headers_for(method: "GET", path: "/b", timestamp_ms: 1)

      expect(a["KALSHI-ACCESS-SIGNATURE"]).not_to eq(b["KALSHI-ACCESS-SIGNATURE"])
    end
  end
end
