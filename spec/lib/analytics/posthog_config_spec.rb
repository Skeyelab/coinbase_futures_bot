# frozen_string_literal: true

require "rails_helper"

# The PostHog initializer previously (a) raised when POSTHOG_PROJECT_TOKEN was
# blank in dev/test — which kills boot, and would fail every CI run since CI has
# no token — and (b) enabled capture in the test env whenever a token happened to
# be present, sending spec traffic to the production PostHog project.
#
# This config object is the decision seam: it never raises, and capture is always
# off under test.
RSpec.describe Analytics::PosthogConfig, type: :service do
  def env(name) = ActiveSupport::StringInquirer.new(name)

  describe ".capture_enabled?" do
    it "is disabled under test even when a token is present" do
      expect(described_class.capture_enabled?(rails_env: env("test"), token: "phc_real")).to be false
    end

    it "is disabled under test with no token" do
      expect(described_class.capture_enabled?(rails_env: env("test"), token: nil)).to be false
    end

    it "is enabled in development when a token is present" do
      expect(described_class.capture_enabled?(rails_env: env("development"), token: "phc_real")).to be true
    end

    it "is enabled in production when a token is present" do
      expect(described_class.capture_enabled?(rails_env: env("production"), token: "phc_real")).to be true
    end

    it "is disabled when the token is blank" do
      expect(described_class.capture_enabled?(rails_env: env("development"), token: "")).to be false
      expect(described_class.capture_enabled?(rails_env: env("production"), token: nil)).to be false
    end
  end

  describe ".missing_token_warning" do
    it "warns when a real env has no token" do
      expect(described_class.missing_token_warning(rails_env: env("development"), token: nil))
        .to include("POSTHOG_PROJECT_TOKEN")
    end

    it "does not warn under test (token is not expected there)" do
      expect(described_class.missing_token_warning(rails_env: env("test"), token: nil)).to be_nil
    end

    it "does not warn when a token is present" do
      expect(described_class.missing_token_warning(rails_env: env("production"), token: "phc_real")).to be_nil
    end
  end

  it "never raises for any env/token combination" do
    %w[test development production].each do |name|
      [nil, "", "phc_real"].each do |tok|
        expect { described_class.capture_enabled?(rails_env: env(name), token: tok) }.not_to raise_error
        expect { described_class.missing_token_warning(rails_env: env(name), token: tok) }.not_to raise_error
      end
    end
  end
end
