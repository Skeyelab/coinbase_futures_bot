# frozen_string_literal: true

# Load Coinbase API credentials from cdp_api_key.json if present.
# This ensures the private key has real newlines (dotenv drops \n escapes).
cdp_key_path = Rails.root.join("cdp_api_key.json")
secret = ENV["COINBASE_API_SECRET"].to_s

if secret.count("\n").zero? && cdp_key_path.exist?
  data = JSON.parse(cdp_key_path.read)
  # Only load from JSON if .env key matches the JSON key name (avoid mismatches)
  if ENV["COINBASE_API_KEY"].blank? || ENV["COINBASE_API_KEY"] == data["name"]
    ENV["COINBASE_API_KEY"] = data["name"]
    ENV["COINBASE_API_SECRET"] = data["privateKey"]
  else
    # .env has a different key — fix its newlines by gsub
    ENV["COINBASE_API_SECRET"] = secret.gsub('\n', "\n")
  end
end
