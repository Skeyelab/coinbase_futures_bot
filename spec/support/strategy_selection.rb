# frozen_string_literal: true

# The 2026-07-29 flip enabled FundingSkewContrarian on BIP in the shipped
# config/strategy_selection.yml, so EVERY spec that evaluates BIP through the
# factory now resolves a different strategy than the MultiTimeframeSignal its
# stubs assume (the #575 cost-gate specs were the first casualties). That is
# correct in production and wrong for specs that are about cost gates,
# suspensions and signal plumbing, not about selection.
#
# Same pattern as spec/support/symbol_enablement.rb and notional_cap.rb:
# selection resolves to UNCONFIGURED (default MultiTimeframeSignal) in specs
# by default, and examples tagged `strategy_selection` get the real shipped
# config. The selection/factory/wiring specs carry the tag, so a regression
# in the real config still fails the suite.
RSpec.configure do |config|
  config.before(:each) do |example|
    next if example.metadata[:strategy_selection]

    allow(Trading::StrategySelection).to receive(:for_symbol) do |symbol|
      Trading::StrategySelection.new(nil).for_symbol(symbol)
    end
  end
end
