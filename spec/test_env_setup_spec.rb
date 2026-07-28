# frozen_string_literal: true

require "rails_helper"

# Regression guard for the ENV-vanishes-after-example-1 bug.
#
# dotenv-rails autorestore snapshots ENV in a `before(:suite)` hook registered
# during Rails initialization, then does `ENV.replace(snapshot)` after every
# example. Anything spec/support/test_env_setup.rb assigned AFTER that snapshot
# was therefore present for the first example of a run and gone for every one
# after it. Since auth fails closed (ADR 0005), a vanished credential denies
# rather than grants, so this produced order-dependent CI failures.
#
# Three examples: with the bug, exactly one of them (whichever RSpec ran first)
# would pass and the other two would fail, on any seed.
RSpec.describe "test_env_setup credentials" do
  %w[first second third].each do |position|
    it "are still present for the #{position} example of the run" do
      aggregate_failures do
        expect(ENV["POSITIONS_UI_USERNAME"]).to be_present
        expect(ENV["POSITIONS_UI_PASSWORD"]).to be_present
        expect(ENV["COINBASE_API_KEY"]).to be_present
        expect(ENV["COINBASE_API_SECRET"]).to be_present
        expect(ENV["SLACK_VERIFICATION_TOKEN"]).to be_present
        expect(ENV["OPENROUTER_API_KEY"]).to be_present
      end
    end
  end

  it "survives an example that mutates ENV" do
    ENV["POSITIONS_UI_USERNAME"] = "clobbered-by-this-example"
    expect(ENV["POSITIONS_UI_USERNAME"]).to eq("clobbered-by-this-example")
  end

  it "is restored after an example that mutated ENV" do
    expect(ENV["POSITIONS_UI_USERNAME"]).to be_present
    expect(ENV["POSITIONS_UI_USERNAME"]).not_to eq("clobbered-by-this-example")
  end
end
