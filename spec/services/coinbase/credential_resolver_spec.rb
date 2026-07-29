# frozen_string_literal: true

require "rails_helper"

# Issue #591. Doppler holds every secret this app reads, on both machines, in
# both configs — and the code cannot see any of them, because three clients each
# read cdp_api_key.json directly and nothing reads ENV.
#
# The loader was copy-pasted verbatim into three files:
#
#   app/services/trading/coinbase_positions.rb:1017
#   app/services/coinbase/exchange_client.rb:123
#   app/services/coinbase/advanced_trade_client.rb:271
#
# One resolver, ENV first, file fallback. The fallback stays so nothing breaks
# before the systemd units switch to `doppler run --`.
RSpec.describe Coinbase::CredentialResolver do
  # A real EC key, generated for this spec. The venue signs with ES256 over
  # prime256v1, and the resolver must hand back something OpenSSL can read.
  let(:pem) { OpenSSL::PKey::EC.generate("prime256v1").to_pem }
  let(:key_name) { "organizations/#{SecureRandom.uuid}/apiKeys/#{SecureRandom.uuid}" }
  let(:logger) { instance_spy(Logger) }

  around do |example|
    originals = ENV.values_at("COINBASE_API_KEY", "COINBASE_API_SECRET")
    example.run
    %w[COINBASE_API_KEY COINBASE_API_SECRET].zip(originals) { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  before do
    ENV.delete("COINBASE_API_KEY")
    ENV.delete("COINBASE_API_SECRET")
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(Rails.root.join("cdp_api_key.json")).and_return(false)
  end

  def env!(name: key_name, secret: pem)
    ENV["COINBASE_API_KEY"] = name
    ENV["COINBASE_API_SECRET"] = secret
  end

  def file!(name: key_name, secret: pem)
    allow(File).to receive(:exist?).with(Rails.root.join("cdp_api_key.json")).and_return(true)
    allow(File).to receive(:read).with(Rails.root.join("cdp_api_key.json"))
      .and_return({"name" => name, "privateKey" => secret}.to_json)
  end

  # The tracer: credentials from the environment, no file on disk. This is the
  # whole point — it is what `doppler run --` provides.
  it "resolves credentials from the environment with no file present" do
    env!

    creds = described_class.call(logger: logger)

    expect(creds[:api_key]).to eq(key_name)
    expect(creds[:private_key]).to eq(pem)
  end

  # And what it returns has to be usable, not merely present. A PEM that
  # OpenSSL rejects would authenticate nothing.
  it "returns a private key OpenSSL can read" do
    env!

    expect { OpenSSL::PKey.read(described_class.call(logger: logger)[:private_key]) }.not_to raise_error
  end

  it "falls back to the file when the environment is unset" do
    file!

    creds = described_class.call(logger: logger)

    expect(creds[:api_key]).to eq(key_name)
  end

  it "prefers the environment when both are available" do
    file!(name: "organizations/from-file/apiKeys/from-file")
    env!(name: key_name)

    expect(described_class.call(logger: logger)[:api_key]).to eq(key_name)
  end

  # .env on exo-mini carries blank COINBASE_API_KEY= / COINBASE_API_SECRET=
  # entries. Empty is NOT present — dotenv's blanks must not shadow a real file,
  # or authentication fails in a way that looks like a bad key.
  it "treats blank environment variables as absent" do
    file!
    ENV["COINBASE_API_KEY"] = ""
    ENV["COINBASE_API_SECRET"] = ""

    expect(described_class.call(logger: logger)[:api_key]).to eq(key_name)
  end

  # A half-set pair is the dangerous case: it means someone's config is broken.
  # Silently using the file would hide that, and could authenticate as a
  # DIFFERENT identity than the operator intended.
  it "refuses a half-set environment rather than quietly using the file" do
    file!
    ENV["COINBASE_API_KEY"] = key_name

    expect(described_class.call(logger: logger)).to be_nil
    expect(logger).to have_received(:error).with(/only one of/i)
  end

  it "returns nil when neither source has credentials" do
    expect(described_class.call(logger: logger)).to be_nil
  end

  it "returns nil rather than raising on unparseable file contents" do
    allow(File).to receive(:exist?).with(Rails.root.join("cdp_api_key.json")).and_return(true)
    allow(File).to receive(:read).with(Rails.root.join("cdp_api_key.json")).and_return("{not json")

    expect(described_class.call(logger: logger)).to be_nil
  end

  # #585 set the precedent with CostModel.fee_source: when a value can come from
  # two places, the code says which one it used. Otherwise a box running on the
  # wrong source looks identical to one running on the right source.
  describe "it names its source" do
    it "reports the environment" do
      env!

      described_class.call(logger: logger)

      expect(described_class.source).to eq(:env)
      expect(logger).to have_received(:info).with(/from the environment/i)
    end

    it "reports the file" do
      file!

      described_class.call(logger: logger)

      expect(described_class.source).to eq(:file)
    end

    it "reports none when nothing resolved" do
      described_class.call(logger: logger)

      expect(described_class.source).to eq(:none)
    end
  end

  # The secret must never reach the logs. The 2026-07-29 exposure came from a
  # value being printed, and the loaders this replaces logged the key id on
  # every construction.
  it "never writes the private key to the log" do
    env!

    described_class.call(logger: logger)

    expect(logger).not_to have_received(:info).with(a_string_including(pem))
    expect(logger).not_to have_received(:debug).with(a_string_including(pem))
  end
end
