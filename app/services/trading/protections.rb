# frozen_string_literal: true

module Trading
  # Trading protections (issue #397, ADR 0003). Evaluates the active
  # ProtectionLocks against a candidate (symbol, side) entry and answers whether
  # the entry is currently blocked. This is the single seam consulted by the
  # realtime evaluator and the backtest before an entry is accepted.
  #
  # Individual protections (CooldownPeriod, StoplossGuard, MaxDrawdown, ...) are
  # small objects that WRITE locks via Trading::ProtectionLock; this module is
  # the READ side that composes them. New protections drop in behind here without
  # touching the evaluator.
  #
  # Lock matching:
  #   scope "global"  -> matches every symbol
  #   scope "symbol"  -> matches only its own symbol
  #   side  "both"    -> matches either candidate side
  #   side  "long"/"short" -> matches only that candidate direction
  #
  # Callers pass the side in whatever vocabulary their layer speaks — "LONG"
  # from Position#side, "BUY" from an order, :long from a strategy signal — and
  # all of them are normalized here. A side that names no direction matches no
  # direction-scoped lock (it is still caught by side "both" halts); deciding
  # whether such a side may be traded at all belongs to the entry gate, not to
  # this read.
  module Protections
    module_function

    def blocked?(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      matching_lock(symbol: symbol, side: side, now: now, store: store).present?
    end

    # Human-readable reason for the blocking lock, or nil if not blocked.
    def block_reason(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      lock = matching_lock(symbol: symbol, side: side, now: now, store: store)
      return nil unless lock

      base = lock["source"].to_s
      reason = lock["reason"].to_s
      reason.present? ? "#{base}: #{reason}" : base
    end

    def matching_lock(symbol:, side:, now: Time.current, store: Trading::ProtectionLock.default_store)
      Trading::ProtectionLock.active(now: now, store: store)
        .find { |lock| matches?(lock, symbol: symbol, side: side) }
    end

    def matches?(lock, symbol:, side:)
      scope_matches?(lock, symbol) && side_matches?(lock, side)
    end

    # Raw compare, deliberately, unlike side_matches? below. A side has five
    # spellings in this codebase (SideNormalizer carries a table per layer:
    # position, signal, order, order-symbol, simulator), which is how the two
    # ends of the side compare drifted apart. A product id has exactly one: it
    # is an opaque identifier issued by the exchange, stored on contracts, and
    # every lock symbol and every candidate symbol is that same column —
    # Position#product_id is a foreign key into it (`belongs_to :contract,
    # primary_key: :product_id`), the backtest carries the id it was handed, and
    # Contract.parse_contract_info only recognises the uppercase form. Nothing
    # on either the write or the read path case-transforms it. There is no
    # second vocabulary here to normalize toward, so normalizing would be
    # inventing a canonical form for values that already have one.
    def scope_matches?(lock, symbol)
      return true if lock["scope"] == "global"

      lock["symbol"].to_s == symbol.to_s
    end

    # Both sides of this comparison go through SideNormalizer, because the two
    # sides of it came from different vocabularies. Locks are written downcased
    # ("long"/"short") — StoplossGuard writes the side it counted, and it counts
    # PositionLifecycle's downcased exits. The candidate side is whatever the
    # caller has in hand, and the thing a caller naturally has is Position#side,
    # which the model constrains to %w[LONG SHORT]. "long" != "LONG" under a raw
    # compare, so the lock did not apply and the guard permitted exactly the
    # entry it was written to block: a halt that was written, stored, and not
    # enforced. Callers papered over it individually (see the pre-normalization
    # in RapidSignalEvaluationJob); the compare itself is the right home.
    #
    # Asked as two positive questions rather than `long?(a) == long?(b)` on
    # purpose. SideNormalizer.long?/.short? are deliberately not complements —
    # an unparseable side is neither — and that property only survives if an
    # unparseable value fails BOTH arms. Comparing normalized values directly
    # would instead match nil to nil, so two sides nobody can parse would read
    # as the same side and block. Unknown is not a match.
    def side_matches?(lock, side)
      lock_side = lock["side"].to_s
      return true if lock_side == "both"

      (SideNormalizer.long?(lock_side) && SideNormalizer.long?(side)) ||
        (SideNormalizer.short?(lock_side) && SideNormalizer.short?(side))
    end
  end
end
