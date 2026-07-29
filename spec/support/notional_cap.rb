# frozen_string_literal: true

# Issue #530 moved NotionalCap enforcement to the submit_order chokepoint, so
# EVERY spec that opens or increases a position now passes through the cap.
# That is correct in production and wrong for the existing examples that
# assert things about order persistence, dry-run routing and fee recording
# while opening positions whose test-fixture notional (1 BTC @ $50k against
# $10k paper equity) was never meant to be realistic.
#
# Rather than resize every fixture — which would say "this test is about the
# cap" when it is not — the cap admits everything by default in specs and
# enforces for examples tagged `notional_cap`. The cap's real behaviour is
# covered by spec/services/trading/notional_cap_spec.rb and
# spec/services/trading/notional_cap_executor_gate_spec.rb (tagged), so a
# regression back to uncapped entries still fails the suite.
RSpec.configure do |config|
  config.before(:each) do |example|
    next if example.metadata[:notional_cap]

    allow(Trading::NotionalCap).to receive(:allows?).and_return(true)
  end
end
