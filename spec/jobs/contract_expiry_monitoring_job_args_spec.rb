# frozen_string_literal: true

require "rails_helper"

# Argument plumbing for the emergency expiry cron (#417).
#
# The `emergency_expiry_check` cron raised ArgumentError on every fire from
# 09:00 UTC on 2026-07-22. The job declared keywords only, but GoodJob splats
# cron args and ActiveJob round-trips them through JSON, so the call arrived as
# a positional argument. `Array({emergency_check: true})` produces
# `[[:emergency_check, true]]` — an array of pairs, not a Hash.
#
# It went unnoticed for ten hours because the broken retry backoff (#416) masked
# the real exception behind "Couldn't determine a delay", at ~25 failures/sec.
RSpec.describe ContractExpiryMonitoringJob, type: :job do
  let(:workflow) { instance_double(Trading::PositionManagement::ContractExpiryMonitoringWorkflow) }
  let(:result) { double(summary: "ok") }

  before do
    allow(Trading::PositionManagement::ContractExpiryMonitoringWorkflow)
      .to receive(:new).and_return(workflow)
    allow(workflow).to receive(:call).and_return(result)
  end

  describe "argument shapes it must tolerate" do
    it "accepts keywords" do
      described_class.new.perform(emergency_check: true)

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: true)
    end

    it "accepts a positional Hash (post-JSON-round-trip shape)" do
      described_class.new.perform({"emergency_check" => true})

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: true)
    end

    it "accepts the array-of-pairs shape that Array(hash) produces" do
      # This is the EXACT payload that was failing in production, recovered from
      # good_jobs.serialized_params.
      described_class.new.perform([[:emergency_check, true]])

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: true)
    end

    it "defaults to a non-emergency run when called with nothing" do
      described_class.new.perform

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: false)
    end

    it "still carries buffer_days through" do
      described_class.new.perform(buffer_days: 5)

      expect(workflow).to have_received(:call).with(buffer_days: 5, emergency_check: false)
    end

    it "falls back to defaults rather than raising on an unusable payload" do
      # A critical safety job must degrade to a normal run rather than die --
      # dying is what produced the ten-hour outage.
      expect { described_class.new.perform("nonsense") }.not_to raise_error

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: false)
    end
  end

  describe "the cron configuration itself" do
    it "wraps emergency args in an Array so GoodJob passes one Hash" do
      cron = Rails.application.config.good_job.cron[:emergency_expiry_check]

      expect(cron[:args]).to eq([{emergency_check: true}])
      # A bare Hash is the bug: Array() would turn it into pairs.
      expect(cron[:args]).to be_an(Array)
    end

    it "produces a payload the job actually accepts" do
      # Ties the config to the job. If either drifts, this fails rather than
      # waiting for 09:00 on a weekday to find out.
      cron = Rails.application.config.good_job.cron[:emergency_expiry_check]

      described_class.new.perform(*Array(cron[:args]))

      expect(workflow).to have_received(:call).with(buffer_days: nil, emergency_check: true)
    end
  end
end
