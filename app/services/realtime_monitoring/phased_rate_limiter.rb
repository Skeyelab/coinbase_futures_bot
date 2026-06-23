# frozen_string_literal: true

require "zlib"

module RealtimeMonitoring
  # Spreads RTM side effects evenly across a fixed interval using modular
  # arithmetic (Euclidean division remainder) for per-key phase offsets.
  class PhasedRateLimiter
    def initialize(cache: Rails.cache, clock: -> { Time.current })
      @cache = cache
      @clock = clock
    end

    def due?(key:, interval_seconds:, cache_prefix:)
      interval = interval_seconds.to_i
      return true if interval <= 0

      phase = phase_for(key, interval)
      bucket = current_bucket(phase, interval)
      cache_key = "#{cache_prefix}:#{key}"
      last_bucket = read_last_bucket(cache_key, phase, interval)

      return false if last_bucket == bucket

      write_bucket(cache_key, bucket, interval)
      true
    end

    def phase_for(key, interval_seconds)
      euclidean_phase(key, interval_seconds)
    end

    def self.gcd_interval(*intervals)
      intervals.map(&:to_i).reduce { |memo, value| gcd(memo, value) }
    end

    def self.gcd(a, b)
      a, b = b, a % b while b.nonzero?
      a
    end

    private

    def euclidean_phase(key, interval)
      Zlib.crc32(key.to_s) % interval
    end

    def current_bucket(phase, interval)
      timestamp = @clock.call.to_i
      (timestamp - phase) / interval
    end

    def read_last_bucket(cache_key, phase, interval)
      state = @cache.read(cache_key)
      return nil if state.nil?
      return state[:bucket] if state.is_a?(Hash) && state.key?(:bucket)
      return current_bucket(phase, interval) if state.is_a?(Time)

      nil
    end

    def write_bucket(cache_key, bucket, interval)
      @cache.write(
        cache_key,
        {bucket: bucket},
        expires_in: interval * 2
      )
    end
  end
end
