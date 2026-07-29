# frozen_string_literal: true

require "rails_helper"

# Issues #596 and #597, found together while migrating credentials to Doppler.
#
# #596 — the 2026-07-29 leak did not come from a config file, a log line, or a
# commit. It came from `inspect`. A diagnostic called a method on
# Trading::CoinbasePositions, the call raised, and the error message embedded
# the receiver's default inspect, which prints every instance variable:
#
#   @api_secret="-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEILYqmV6...
#
# Moving secrets to Doppler does not fix this. The value is in process memory
# either way; inspect is what publishes it.
#
# #597 — MarketData::CoinbaseRest guards with a bare `if ENV[...] && ENV[...]`,
# and empty strings are truthy in Ruby, so with .env's blank entries it reports
# authenticated while holding "".
RSpec.describe "credentials are not exposed", type: :service do
  let(:pem) { OpenSSL::PKey::EC.generate("prime256v1").to_pem }
  let(:key_name) { "organizations/#{SecureRandom.uuid}/apiKeys/#{SecureRandom.uuid}" }

  around do |example|
    originals = ENV.values_at("COINBASE_API_KEY", "COINBASE_API_SECRET")
    example.run
    %w[COINBASE_API_KEY COINBASE_API_SECRET].zip(originals) { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before do
    allow(Coinbase::CredentialResolver).to receive(:call)
      .and_return({api_key: key_name, private_key: pem})
  end

  # Every client that holds a credential in an ivar. None defined inspect, so
  # all four used Ruby's default.
  clients = {
    "Trading::CoinbasePositions" => -> { Trading::CoinbasePositions.new(base_url: "https://example.com") },
    "Coinbase::ExchangeClient" => -> { Coinbase::ExchangeClient.new },
    "Coinbase::AdvancedTradeClient" => -> { Coinbase::AdvancedTradeClient.new }
  }

  clients.each do |name, build|
    describe name do
      subject(:client) { build.call }

      it "does not put the private key in inspect" do
        expect(client.inspect).not_to include("BEGIN EC PRIVATE KEY")
        expect(client.inspect).not_to include(pem)
      end

      it "does not put the private key in to_s" do
        expect(client.to_s).not_to include(pem)
      end

      # The real failure path: interpolation into an exception message. This is
      # exactly how the key reached the transcript.
      it "does not leak the private key through an interpolated exception" do
        message = begin
          raise "boom on #{client}"
        rescue => e
          e.message
        end

        expect(message).not_to include(pem)
        expect(message).not_to include("BEGIN EC PRIVATE KEY")
      end

      # Redact, don't omit. A debugger asking "is the credential loaded?" should
      # still get an answer; that is usually the actual question.
      it "still shows that a credential is present" do
        expect(client.inspect).to match(/REDACTED/)
      end
    end
  end

  # Issue #597. The one client that reads ENV directly.
  describe MarketData::CoinbaseRest do
    it "does not treat empty strings as credentials" do
      ENV["COINBASE_API_KEY"] = ""
      ENV["COINBASE_API_SECRET"] = ""

      expect(described_class.new).not_to be_authenticated
    end

    it "warns when credentials are blank, as it was always meant to" do
      ENV["COINBASE_API_KEY"] = ""
      ENV["COINBASE_API_SECRET"] = ""
      allow(Rails.logger).to receive(:warn)

      described_class.new

      expect(Rails.logger).to have_received(:warn).with(/not fully configured/i)
    end

    # Half-set is its own case: a key with no secret cannot sign anything, and
    # reporting authenticated would push the failure to a confusing place.
    it "does not authenticate on a half-set pair" do
      ENV["COINBASE_API_KEY"] = key_name
      ENV["COINBASE_API_SECRET"] = ""

      expect(described_class.new).not_to be_authenticated
    end

    it "still authenticates when both are genuinely set" do
      ENV["COINBASE_API_KEY"] = key_name
      ENV["COINBASE_API_SECRET"] = pem

      expect(described_class.new).to be_authenticated
    end

    it "does not put its secret in inspect either" do
      ENV["COINBASE_API_KEY"] = key_name
      ENV["COINBASE_API_SECRET"] = pem

      expect(described_class.new.inspect).not_to include(pem)
    end
  end
end
