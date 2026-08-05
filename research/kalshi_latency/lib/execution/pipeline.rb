require_relative "order_client"
require_relative "order_log"
require_relative "executor"
require_relative "episode_tracker"
require_relative "halt"
require_relative "repricing_exit"

# The one entry point the collector calls: a sighting goes in, a dry-run
# intent (or a logged refusal) comes out. Wires the tracker's dwell clock into
# the credibility check so persistence blocks an order instead of explaining a
# bad one later.
module Execution
  class Pipeline
    def self.build(data_dir:, client: nil, reader: nil)
      order_client = client || OrderClient.new(transport: nil_transport)
      log = OrderLog.new(path: File.join(data_dir, "orders.jsonl"))
      new(
        executor: Executor.new(
          client: order_client,
          log: log,
          # The kill switch lives in the data dir so `ruby bin/halt "why"` (or
          # a bare `touch HALT` over ssh) stops orders without a deploy.
          halt: Halt.new(data_dir: data_dir)
        ),
        tracker: EpisodeTracker.new,
        # Exit-on-repricing needs a market reader; without one (pure dry-run
        # test pipelines) exits are simply never checked.
        repricing_exit: reader && RepricingExit.new(client: order_client, log: log, reader: reader)
      )
    end

    # Dry-run must never need a network; a transport that refuses loudly beats
    # one that quietly succeeds.
    def self.nil_transport
      ->(*) { raise "dry-run pipeline has no transport" }
    end

    def initialize(executor:, tracker:, repricing_exit: nil)
      @executor = executor
      @tracker = tracker
      @repricing_exit = repricing_exit
    end

    # Settled facts are exited on the market's agreement, not held to
    # settlement: capital recycles same-day and METAR-vs-CLI basis risk never
    # gets a chance to bite. Called once per collector cycle.
    def check_exits
      @repricing_exit ? @repricing_exit.check : []
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
