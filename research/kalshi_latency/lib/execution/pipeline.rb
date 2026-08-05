require_relative "order_client"
require_relative "order_log"
require_relative "executor"
require_relative "episode_tracker"

# The one entry point the collector calls: a sighting goes in, a dry-run
# intent (or a logged refusal) comes out. Wires the tracker's dwell clock into
# the credibility check so persistence blocks an order instead of explaining a
# bad one later.
module Execution
  class Pipeline
    def self.build(data_dir:, client: nil)
      new(
        executor: Executor.new(
          client: client || OrderClient.new(transport: nil_transport),
          log: OrderLog.new(path: File.join(data_dir, "orders.jsonl"))
        ),
        tracker: EpisodeTracker.new
      )
    end

    # Dry-run must never need a network; a transport that refuses loudly beats
    # one that quietly succeeds.
    def self.nil_transport
      ->(*) { raise "dry-run pipeline has no transport" }
    end

    def initialize(executor:, tracker:)
      @executor = executor
      @tracker = tracker
    end

    def sight(opportunity, at:)
      @executor.consider(opportunity, episode: {
        verified: opportunity[:verified],
        market_pct: opportunity[:market_pct],
        support: opportunity[:peak_support],
        seconds: @tracker.observe(opportunity[:ticker], at: at)
      })
    end
  end
end
