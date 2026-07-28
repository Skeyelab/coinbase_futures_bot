# frozen_string_literal: true

require "rails_helper"

# A grep for the bug that will not die.
#
# Futures notional is `contract_size * price * quantity`. Writing `size * price`
# silently drops contract_size and is wrong by exactly that factor — 10x too
# small on NOL (contract_size 10), 100x too large on BIP (contract_size 0.01).
#
# Issue #234 fixed it for Position P&L. It then came back FOUR more times, each
# in a different file, each surviving human review, each doing real damage:
#
#   * PR #507 — nine sites in HealthCheckJob and the positions API: every
#     exposure, margin and leverage figure on the dashboard read 10x small.
#   * PR #531 — PaperTrading::ExchangeSimulator charged the proportional fee on
#     the quote price. The #486 calibration rehearsal, whose entire purpose was
#     to MEASURE the real taker rate, reported a fake 300 bps and aborted
#     claiming ADR 0002 was falsified. A measurement harness's first run was
#     consumed by our own bug.
#   * This PR — the overnight margin gate, realized return %, and portfolio
#     exposure in three more places.
#
# Four rounds of human review did not catch it, so this spec does. It is crude
# on purpose: a regex over app/ and lib/ is the only mechanism with a chance of
# catching the sixth instance, because the fifth will be written by someone who
# has never read any of the above.
module ContractSizeNotionalScan
  module_function

  # A receiver chain: `position.`, `p.`, `@`, or a bare local.
  RECEIVER = /(?:@{1,2}|(?:[A-Za-z_]\w*\.)+)?/

  # Quantity-shaped names. `contract_size` deliberately does NOT match: the `_`
  # before `size` is a word character, so `\bsize\b` cannot start there. That is
  # what lets `contract_size * price * quantity` read as correct.
  QUANTITY = /#{RECEIVER}(?:number_of_contracts|contracts|quantity|qty|size)\b(?:\.(?:to_f|to_d|to_i|abs|round|floor|ceil))*/

  # Price-shaped names: price, entry_price, fill_price, avg_entry_price, ...
  PRICE = /#{RECEIVER}[a-z_]*price\b(?:\.(?:to_f|to_d|abs|round))*/

  # Either order, tolerating an opening paren after the `*` so that
  # `size * (current_price || entry_price)` is not a blind spot.
  BLIND_NOTIONAL = /
    (?<![\w.])
    (?: #{QUANTITY}\s*\*\s*\(?\s*#{PRICE}
      | #{PRICE}\s*\*\s*\(?\s*#{QUANTITY} )
  /x

  # A statement that already carries a contract-size factor is correct by
  # construction, whichever order it multiplies in.
  CONTRACT_SIZE_FACTOR = /contract_size|contract_multiplier|ContractSizeResolver|NotionalCap|FuturesUnrealizedPnl|\bmultiplier\b/

  # Every entry needs a reason. "It looked fine" is not a reason.
  ALLOWED = {
    # The canonical helper. It is the thing everything else is supposed to call.
    "app/services/trading/notional_cap.rb" =>
      "Trading::NotionalCap.notional_for IS the contract_size-aware definition.",

    # Both callers (SymbolCircuitBreakerJob#estimated_round_trip_cost and
    # Trading::PaperPnlSummary#round_trip_cost_for) multiply entry_price by
    # contract_size BEFORE calling, so the kwarg is already a notional price.
    "app/services/cost_model.rb" =>
      "entry_price:/exit_price: arrive pre-multiplied by contract_size; both callers bake it in.",

    # A weighted average of PRICE, not a notional: contract_size appears in
    # every term of the numerator and in the denominator, so it cancels.
    "app/services/trading/coinbase_positions.rb" =>
      "Weighted-average entry PRICE — contract_size cancels between numerator and denominator."
  }.freeze

  SCAN_GLOB = "{app,lib}/**/*.{rb,rake}"

  # Physical lines are joined into logical ones when a line ends mid-expression,
  # so a `* ContractSizeResolver.for_product(...)` continuation is seen as part
  # of the same statement rather than read as a separate blind line.
  def logical_lines(path)
    out = []
    pending = nil
    pending_line = nil

    File.readlines(path).each_with_index do |raw, idx|
      code = raw.sub(%r{(?<!["'])#\s.*$}, "").rstrip

      if pending
        pending += " " + code.strip
      else
        pending = code
        pending_line = idx + 1
      end

      next if /[*+\-\/(,\\]\z/.match?(pending)

      out << [pending_line, pending]
      pending = nil
    end
    out << [pending_line, pending] if pending
    out
  end

  def offenders(root = Rails.root)
    Dir.glob(root.join(SCAN_GLOB)).sort.flat_map { |path|
      rel = Pathname.new(path).relative_path_from(root).to_s
      next [] if ALLOWED.key?(rel)

      logical_lines(path).filter_map do |lineno, code|
        next if CONTRACT_SIZE_FACTOR.match?(code)

        match = code.match(BLIND_NOTIONAL)
        "#{rel}:#{lineno}  #{match[0].strip}" if match
      end
    }
  end
end

RSpec.describe "contract_size-blind notional arithmetic", type: :lint do
  # If this spec fails on a line you wrote, read the failure message. If your
  # line is genuinely correct, add it to ContractSizeNotionalScan::ALLOWED with
  # a one-line reason — but read the message first, because four people were
  # sure their line was fine too.
  it "finds no `size * price` outside the canonical helpers" do
    found = ContractSizeNotionalScan.offenders

    expect(found).to be_empty, <<~MSG
      #{found.size} site(s) compute futures notional WITHOUT contract_size:

      #{found.join("\n      ")}

      WHAT IS WRONG
        Futures notional is `contract_size * price * quantity`. A `size` on a
        futures Position is a CONTRACT COUNT, not a coin amount, so multiplying
        it by the quote price is off by exactly contract_size — 10x too small on
        NOL-19AUG26-CDE (contract_size 10), 100x too large on BIP-20DEC30-CDE
        (contract_size 0.01). It is silent: the number looks plausible, and on a
        contract_size 1 product it is even correct, which is how the same defect
        has now shipped five times.

      WHAT TO USE INSTEAD
        dollar notional   -> Trading::NotionalCap.notional_for(product_id, quantity, price)
        dollar unrealized -> Trading::FuturesUnrealizedPnl.calculate(side:, entry_price:,
                               current_price:, contracts:, contract_size:)
        the multiplier    -> Trading::ContractSizeResolver.for_product(product_id)

      IF YOUR LINE IS ACTUALLY FINE
        Add the file to ContractSizeNotionalScan::ALLOWED in
        spec/lint/contract_size_notional_guard_spec.rb with a one-line reason.
        Three entries are there now; read them first — the bar is "contract_size
        provably cancels or is applied elsewhere", not "this looked right to me".

      AND TEST IT ON A REAL CONTRACT
        A spec written against a contract_size 1 product proves nothing. That is
        precisely how every one of the previous instances passed review. Use
        NOL-19AUG26-CDE (contract_size 10) or BIP-20DEC30-CDE (0.01).
    MSG
  end

  # The guard is worthless if the regex silently stops matching, so it is
  # exercised against the actual shape of each historical regression.
  describe "the pattern itself" do
    {
      "position.size * position.entry_price" => "margin_window_monitoring_job (this PR)",
      "(pnl / (entry_price * size)) * 100" => "Position#pnl_percentage (this PR)",
      "positions.sum { |p| (p.size * p.entry_price).abs }" => "market_analysis_service (this PR)",
      "summary[:total_exposure] += position.size * (current_price || position.entry_price)" => "swing_position_manager (this PR)",
      "total_notional = positions.sum { |pos| pos.size * pos.entry_price }" => "positions_monitoring.rake (this PR)",
      "fee = fill_price.to_f * size.to_f * fees[:taker_rate].to_f" => "exchange_simulator (PR #531)",
      "exposure = position.size.to_f * position.entry_price.to_f" => "health_check_job (PR #507)",
      "value = quantity * price" => "bare local variables"
    }.each do |snippet, origin|
      it "catches #{origin}" do
        expect(snippet).to match(ContractSizeNotionalScan::BLIND_NOTIONAL)
      end
    end

    [
      "ContractSizeResolver.for_product(product_id).to_f * price.to_f * quantity.to_f",
      "fill_price.to_f * contracts.to_f * contract_multiplier.to_f",
      "Trading::NotionalCap.notional_for(product_id, size, entry_price)",
      "delta * contracts * contract_size"
    ].each do |snippet|
      it "does not fire on #{snippet[0, 40]}..." do
        blind = ContractSizeNotionalScan::BLIND_NOTIONAL.match?(snippet)
        excused = ContractSizeNotionalScan::CONTRACT_SIZE_FACTOR.match?(snippet)

        expect(excused || !blind).to be(true)
      end
    end
  end
end
