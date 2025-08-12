#!/usr/bin/env ruby

require 'json'
require 'openssl'
require 'jwt'

# Usage:
#   ruby scripts/generate_jwt_and_curl.rb GET /api/v3/brokerage/accounts
#   ruby scripts/generate_jwt_and_curl.rb GET /api/v3/brokerage/cfm/balance_summary
#   ruby scripts/generate_jwt_and_curl.rb GET /api/v3/brokerage/cfm/positions

method = (ARGV[0] || 'GET').to_s.upcase
path   = (ARGV[1] || '/api/v3/brokerage/accounts').to_s

root = File.expand_path('..', __dir__)
key_file = File.join(root, 'cdp_api_key.json')

abort("cdp_api_key.json not found at #{key_file}") unless File.exist?(key_file)

data = JSON.parse(File.read(key_file))
api_key = data.fetch('name')
api_secret = data.fetch('privateKey')

now = Time.now.to_i
nbf = now - 30
exp = now + 120

jwt_uri = "#{method} #{path}"

payload = {
  iss: api_key,
  nbf: nbf,
  exp: exp,
  sub: api_key,
  aud: 'retail_rest_api',
  uri: jwt_uri
}

private_key = OpenSSL::PKey.read(api_secret)
jwt_token = JWT.encode(payload, private_key, 'ES256')

puts "# JWT generated for: #{jwt_uri}"
puts "export JWT='#{jwt_token}'"
puts
puts "# curl command:"
puts "curl -s -D - \\\n+  -H 'Authorization: Bearer $JWT' \\\n+  -H 'Accept: application/json' \\\n+  'https://api.coinbase.com#{path}' | cat"
