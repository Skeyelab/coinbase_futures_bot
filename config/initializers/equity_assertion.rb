# frozen_string_literal: true

# Refuse to boot a LIVE-trading process whose sizing equity disagrees with the
# account (issue #482).
#
# Gated on LIVE_TRADING_CONFIRMED so paper, development, test and CI pay nothing
# — no API call, no boot-time failure mode — while a live process cannot start
# mis-sized. That is the only configuration where being wrong costs money.
Rails.application.config.after_initialize do
  next unless ENV["LIVE_TRADING_CONFIRMED"] == "1"
  next if Rails.env.test?

  begin
    result = Trading::EquityAssertion.verify!
    Rails.logger.info("[EquityAssertion] sizing $#{result[:sizing]} vs account $#{result[:actual]}") unless result[:skipped]
  rescue Trading::EquityAssertion::Divergence => e
    Rails.logger.fatal("[EquityAssertion] #{e.message}")
    raise
  end
end
