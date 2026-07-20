# frozen_string_literal: true

require "rails_helper"

RSpec.describe RealtimeSignalRunner do
  let(:job_class) { class_double(RealTimeSignalJob) }
  let(:logger) { instance_double(Logger, info: true) }
  let(:runner) { described_class.new(job_class: job_class, logger: logger, interval_seconds: 30) }

  describe "#start!" do
    it "logs and runs the first evaluation immediately" do
      expect(logger).to receive(:info).with("[RTS] Starting real-time signal evaluation (interval=30s)...")
      expect(job_class).to receive(:perform_now)

      runner.start!
    end
  end

  describe "liveness heartbeat" do
    it "records a fresh heartbeat when it runs an evaluation, so a dead loop is detectable" do
      allow(job_class).to receive(:perform_now)

      expect(Heartbeat.status("realtime_signal")[:stale]).to be(true)

      runner.start!

      expect(Heartbeat.status("realtime_signal")[:stale]).to be(false)
    end
  end

  describe "#tick" do
    it "does nothing before the interval elapses" do
      travel_to(Time.current) do
        allow(job_class).to receive(:perform_now)
        runner.start!

        expect(job_class).not_to receive(:perform_now)
        runner.tick(now: 29.seconds.from_now)
      end
    end

    it "runs again once the interval elapses" do
      travel_to(Time.current) do
        allow(job_class).to receive(:perform_now)
        runner.start!

        expect(job_class).to receive(:perform_now)
        runner.tick(now: 30.seconds.from_now)
      end
    end
  end
end
