# frozen_string_literal: true

module Coinbase
  # Where Coinbase CDP credentials come from (issue #591).
  #
  # Three clients each carried a verbatim copy of the same
  # `load_credentials_from_file` — CoinbasePositions, ExchangeClient and
  # AdvancedTradeClient. Three copies is three places for the next fix to land
  # in one or two of them, which is how the LONG/SHORT enum bug (#577) survived
  # in a spec that asserted it.
  #
  # ENV first, file fallback. The environment is what `doppler run --` provides;
  # the file stays so nothing breaks before the systemd units switch over.
  #
  # The venue wants two things: a key NAME (`organizations/.../apiKeys/...`) used
  # as the JWT `kid`, and an EC private key PEM used to sign ES256. Doppler
  # stores the PEM with real newlines, so it needs no unescaping — deliberately
  # not adding a transformation for a case that does not exist.
  class CredentialResolver
    ENV_KEY = "COINBASE_API_KEY"
    ENV_SECRET = "COINBASE_API_SECRET"
    FILENAME = "cdp_api_key.json"
    # A half-set environment. Distinct from nil so `call` cannot mistake a
    # deliberate refusal for "nothing here, try the file".
    REFUSED = :refused

    class << self
      # Returns {api_key:, private_key:} or nil. Nil means "no credentials",
      # never "empty credentials" — MarketData::CoinbaseRest guards with a bare
      # `if ENV[...] && ENV[...]`, and because empty strings are truthy in Ruby
      # it currently believes it is authenticated while holding "". A resolver
      # that returned blanks would spread that bug rather than end it.
      def call(logger: Rails.logger)
        env = from_env(logger)
        # REFUSED is not "absent". Written as `from_env || from_file` this fell
        # through to the file on a half-set environment — the precise behaviour
        # the refusal exists to prevent. A nil-means-two-things return is how
        # that mistake gets made, so the states are distinct values.
        return nil if env == REFUSED
        return env if env

        from_file(logger)
      end

      # Which source won, for the same reason CostModel.fee_source exists
      # (#585): a box running on the wrong source looks identical to one running
      # on the right source unless the code says so.
      def source
        @source || :none
      end

      private

      def from_env(logger)
        name = ENV[ENV_KEY].to_s
        secret = ENV[ENV_SECRET].to_s
        # Blank-test on a stripped copy, but hand back the value VERBATIM. A PEM
        # ends with a newline and .strip removed it, which also re-encoded the
        # string — mutating a secret in transit is how a working key starts
        # failing for reasons nobody can see.
        name_blank = name.strip.empty?
        secret_blank = secret.strip.empty?

        # Blank is ABSENT, not present. .env carries empty COINBASE_API_KEY= /
        # COINBASE_API_SECRET= entries, and letting those shadow a real file
        # would fail authentication in a way that reads like a bad key.
        return nil if name_blank && secret_blank

        # Half-set means someone's config is broken. Falling through to the file
        # would hide that, and could authenticate as a DIFFERENT identity than
        # the operator believes they configured.
        if name_blank || secret_blank
          @source = :none
          logger&.error("[CredentialResolver] only one of #{ENV_KEY}/#{ENV_SECRET} is set — " \
                        "refusing to fall back to #{FILENAME}, because that would authenticate " \
                        "as an identity nobody chose. Set both or neither.")
          return REFUSED
        end

        @source = :env
        logger&.info("[CredentialResolver] credentials from the environment (#{redact(name)})")
        {api_key: name.strip, private_key: secret}
      end

      def from_file(logger)
        path = Rails.root.join(FILENAME)
        unless File.exist?(path)
          @source = :none
          logger&.warn("[CredentialResolver] no credentials: #{ENV_KEY}/#{ENV_SECRET} unset and " \
                       "#{FILENAME} not found at #{path}")
          return nil
        end

        data = JSON.parse(File.read(path))
        name = data["name"].to_s
        secret = data["privateKey"].to_s
        if name.strip.empty? || secret.strip.empty?
          @source = :none
          logger&.error("[CredentialResolver] #{FILENAME} is missing name or privateKey")
          return nil
        end

        @source = :file
        logger&.info("[CredentialResolver] credentials from #{FILENAME} (#{redact(name)})")
        # Verbatim, same as the env path — the PEM's trailing newline is part of
        # the value, not whitespace to tidy up.
        {api_key: name.strip, private_key: secret}
      rescue JSON::ParserError => e
        @source = :none
        logger&.error("[CredentialResolver] failed to parse #{FILENAME}: #{e.message}")
        nil
      rescue => e
        @source = :none
        logger&.error("[CredentialResolver] failed to load #{FILENAME}: #{e.class}: #{e.message}")
        nil
      end

      # The key NAME is an identifier rather than a secret, but the loaders this
      # replaces logged it in full on every construction. The trailing key id is
      # enough to tell two keys apart during a rotation, which is the only
      # question anyone asks of it.
      def redact(name)
        id = name.to_s.split("/").last.to_s
        "key #{id[0, 8]}…"
      end
    end
  end
end
