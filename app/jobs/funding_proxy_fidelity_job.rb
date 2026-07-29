# frozen_string_literal: true

# Daily proxy-fidelity cross-validation (#568 caveat 1 / #572).
#
# FundingSkewContrarian trades the #569 basis PROXY (perp-vs-spot premium),
# not real funding — validated at r = 0.58-0.77 against the 143h of real
# funding snapshots that existed at gate time. Backtest-vs-live parity
# therefore depends on the proxy staying faithful as the #391 snapshot
# pipeline accrues data. This job re-runs the correlation daily for every
# funding-skew pairing declared in config/strategy_selection.yml — including
# not-yet-enabled entries, so the pairing is validated BEFORE the operator
# flips it — and warns loudly (log + Slack) when fidelity degrades.
class FundingProxyFidelityJob < ApplicationJob
  queue_as :low

  # #569 validated r ~ 0.77; #568 shipped on 0.58-0.77. Below 0.5 the proxy
  # explains under a quarter of the variance — no longer a usable stand-in
  # for the signal driver, and the paper sample stops testing the strategy
  # that passed the gates.
  MIN_R = 0.5

  # Two days of hourly funding snapshots. Below this the correlation is too
  # noisy to call either way — say so rather than false-alarm on r.
  MIN_OVERLAP_HOURS = 48

  LOOKBACK = 30.days

  def perform
    pairings = Trading::StrategySelection.entries(include_disabled: true)
      .select { |s| s.strategy_name == "FundingSkewContrarian" }
    return if pairings.empty?

    pairings.each { |selection| check(selection) }
  end

  private

  def check(selection)
    params = selection.params
    to = Time.current.utc
    result = Signals::FundingProxy.new(
      perp_symbol: selection.symbol,
      spot_symbol: params.fetch(:spot_symbol, "BTC-USD"),
      window: params.fetch(:window, 168)
    ).correlation_with_funding(from: to - LOOKBACK, to: to)

    n = result[:n].to_i
    r = result[:r]

    if n < MIN_OVERLAP_HOURS
      thin_overlap(selection, n)
    elsif r.nil? || r < MIN_R
      degraded(selection, n, r)
    else
      Rails.logger.info(
        "[FundingProxyFidelity] #{selection.symbol} r=#{r.round(3)} n=#{n} — proxy healthy"
      )
    end
  end

  def thin_overlap(selection, n)
    Rails.logger.warn(
      "[FundingProxyFidelity] #{selection.symbol}: only #{n} overlapping funding hours " \
      "in the last #{LOOKBACK.inspect} (need #{MIN_OVERLAP_HOURS}) — fidelity unjudgeable. " \
      "Is FundingRateSnapshotJob running?"
    )
    SlackNotificationService.alert("warning", "Funding proxy fidelity: overlap too thin",
      {symbol: selection.symbol, n: n, required: MIN_OVERLAP_HOURS,
       lookback_days: LOOKBACK.in_days.round})
  end

  def degraded(selection, n, r)
    Rails.logger.error(
      "[FundingProxyFidelity] #{selection.symbol}: proxy-vs-funding r=#{r.inspect} over " \
      "#{n} hours is below #{MIN_R} — the basis proxy no longer tracks real funding. " \
      "The funding-skew paper sample is not testing the gated strategy; consider suspending."
    )
    SlackNotificationService.alert("error", "Funding proxy fidelity degraded",
      {symbol: selection.symbol, r: r, n: n, floor: MIN_R,
       action: "proxy no longer tracks funding — review before trusting the paper sample"})
  end
end
