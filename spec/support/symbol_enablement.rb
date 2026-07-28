# frozen_string_literal: true

# ADR 0006 decision 4 inverted the default: a symbol with no recorded
# enablement is now SUSPENDED, where before it was tradeable. That default is
# correct in production and wrong for the ~200 existing examples that assert
# things about strategy configuration, confidence thresholds and contract
# resolution and merely happen to run a symbol through the entry path.
#
# Rather than sprinkle an enablement call through every one of them — which
# would say "this test is about the universe gate" when it is not — the gate is
# opened by default in specs and closed for examples tagged `universe_scope`.
# The gate's real behaviour is covered by spec/services/trading/
# symbol_enablement_spec.rb and by the tagged examples elsewhere, so a
# regression back to fail-open still fails the suite.
#
# Explicit suspensions are untouched: only the "never enabled" arm is stubbed,
# so every existing suspend!/resume! assertion keeps its original meaning.
RSpec.configure do |config|
  config.before(:each) do |example|
    next if example.metadata[:universe_scope]

    allow(Trading::SymbolSuspension).to receive(:explicitly_enabled?).and_return(true)
  end
end
