# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketData::WebsocketSupervisor do
  # A fake socket the test drives synchronously: it records the event handlers
  # the supervisor wires, and lets the test fire those events (:open/:message/
  # :close) to simulate the real WebSocket without any threads or real time.
  # Anonymous fake-socket class (no leaked constant): records the handlers the
  # supervisor wires so the test can fire :open/:message/:close, and counts
  # close calls.
  def fake_socket_class
    @fake_socket_class ||= Class.new do
      attr_reader :close_calls

      def initialize
        @handlers = {}
        @close_calls = 0
      end

      def on(event, &blk)
        @handlers[event] = blk
      end

      def fire(event, *args)
        @handlers[event]&.call(*args)
      end

      def close
        @close_calls += 1
      end
    end
  end

  # Records every socket handed out so tests can assert reconnections happened.
  def connector
    opened = []
    factory = ->(_url) { fake_socket_class.new.tap { |s| opened << s } }
    [factory, opened]
  end

  it "reconnects after the connection closes" do
    factory, opened = connector
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      connect: factory, clock: -> { 0.0 }, sleeper: nil, poll_interval: 0)

    # Drive deterministically through the sleeper (the loop's only blocking
    # point): close the first connection, then stop once the second is up.
    calls = 0
    supervisor.sleeper = lambda do |_dt|
      calls += 1
      opened.last.fire(:close) if calls == 1  # first connection drops
      supervisor.stop if calls == 3           # second connection established -> stop
    end

    supervisor.run

    expect(opened.size).to eq(2) # reconnected exactly once
  end

  it "force-reconnects when no message arrives within the stale window" do
    factory, opened = connector
    now = 0.0
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      connect: factory, clock: -> { now }, sleeper: nil, poll_interval: 0, stale_after: 60.0)

    # No :close ever fires (the half-open case). Silence past the stale window
    # must be detected on its own.
    calls = 0
    supervisor.sleeper = lambda do |_dt|
      calls += 1
      now += 61 if calls == 1  # first connection goes silent past 60s
      supervisor.stop if calls == 3
    end

    supervisor.run

    expect(opened.size).to eq(2) # detected the silent socket and reconnected
    expect(opened.first.close_calls).to eq(1) # and closed the dead one
  end

  it "backs off exponentially between reconnect attempts, capped" do
    factory, opened = connector
    durations = []
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      connect: factory, clock: -> { 0.0 }, sleeper: nil, poll_interval: 0,
      backoff_base: 1.0, backoff_cap: 30.0)

    # Every connection drops on its first poll -> a run of reconnect attempts.
    polls = 0
    supervisor.sleeper = lambda do |dt|
      durations << dt
      if dt.zero? # a supervise poll
        polls += 1
        opened.last.fire(:close)
        supervisor.stop if polls == 8
      end
    end

    supervisor.run

    backoffs = durations.reject(&:zero?)
    expect(backoffs).to eq([1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0])
  end

  it "resets the backoff after a connection that received data" do
    factory, opened = connector
    backoffs = []
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      connect: factory, clock: -> { 0.0 }, sleeper: nil, poll_interval: 0,
      backoff_base: 1.0, backoff_cap: 30.0)

    polls = 0
    supervisor.sleeper = lambda do |dt|
      if dt.zero? # a supervise poll
        polls += 1
        case polls
        when 1, 2 then opened.last.fire(:close)                       # two clean failures
        when 3 # healthy, then drop
          opened.last.fire(:message, "tick")
          opened.last.fire(:close)
        when 4 then opened.last.fire(:close)                          # fail again
        when 5 then supervisor.stop
        end
      else
        backoffs << dt
      end
    end

    supervisor.run

    # 1, 2 for the first two failures; the healthy 3rd connection resets, so the
    # 4th failure backs off from 1 again — not 8.
    expect(backoffs).to eq([1.0, 2.0, 1.0])
  end

  it "invokes on_open with the socket for every connection (so it resubscribes)" do
    factory, opened = connector
    resubscribed = []
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      on_open: ->(socket) { resubscribed << socket }, connect: factory,
      clock: -> { 0.0 }, sleeper: nil, poll_interval: 0)

    polls = 0
    supervisor.sleeper = lambda do |dt|
      next unless dt.zero?

      polls += 1
      opened.last.fire(:open)   # exchange accepts the connection...
      opened.last.fire(:close)  # ...then it drops
      supervisor.stop if polls == 3
    end

    supervisor.run

    # on_open fired once per connection, each with that connection's socket, so a
    # reconnect always re-sends the subscribe.
    expect(resubscribed).to eq(opened)
    expect(resubscribed.size).to eq(3)
  end

  it "retries with backoff when connecting raises, instead of crashing" do
    good = fake_socket_class.new
    attempts = 0
    factory = lambda do |_url|
      attempts += 1
      raise Errno::ECONNREFUSED, "refused" if attempts == 1 # first connect fails outright

      good
    end
    errors = []
    supervisor = described_class.new(url: "wss://x", on_message: ->(_m) {},
      on_error: ->(e) { errors << e }, connect: factory, clock: -> { 0.0 },
      sleeper: nil, poll_interval: 0, backoff_base: 1.0)

    calls = 0
    supervisor.sleeper = lambda do |_dt|
      calls += 1
      supervisor.stop if calls >= 2
    end

    expect { supervisor.run }.not_to raise_error
    expect(attempts).to be >= 2               # it recovered and connected on retry
    expect(errors.first).to be_a(Errno::ECONNREFUSED) # and reported the failure
  end
end
