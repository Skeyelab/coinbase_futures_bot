require "openssl"
require "base64"

# Signs Kalshi REST requests.
#
# Kalshi uses RSA-PSS over "<timestamp_ms><METHOD><path>" -- a different scheme
# from Coinbase's EC/ES256 JWT, so none of the existing credential code applies.
#
# The path is signed WITHOUT its query string. Signing the query too produces a
# signature the venue cannot reproduce, and the failure is a flat 401 with no
# hint about which half was wrong.
class KalshiSigner
  def initialize(key_id:, private_key_pem:)
    @key_id = key_id.to_s.strip
    # Env vars frequently carry the PEM with escaped newlines; a real one always
    # has actual newlines, so only unescape when there are none.
    pem = private_key_pem.to_s
    pem = pem.gsub('\n', "\n") unless pem.include?("\n")
    @key = OpenSSL::PKey::RSA.new(pem)
  end

  def headers_for(method:, path:, timestamp_ms: nil)
    ts = (timestamp_ms || (Time.now.to_f * 1000).round).to_s
    message = ts + method.to_s.upcase + path.to_s.split("?").first.to_s

    {
      "KALSHI-ACCESS-KEY" => @key_id,
      "KALSHI-ACCESS-TIMESTAMP" => ts,
      "KALSHI-ACCESS-SIGNATURE" => sign(message),
      "Content-Type" => "application/json"
    }
  end

  private

  def sign(message)
    Base64.strict_encode64(
      @key.sign_pss("SHA256", message, salt_length: :digest, mgf1_hash: "SHA256")
    )
  end
end
