# frozen_string_literal: true

require "rails_helper"

# The signal that a bug was happening was itself invisible.
#
# On 2026-07-28 three positions were created with no Order row, and the operator
# found nothing in `journalctl --user -u cfb-realtime`. Two reasons, both real:
#
#   1. The message they grepped for never existed on that path — #persist_order
#      swallowed the failure under its own wording. Fixed in CoinbasePositions.
#   2. NO Rails.logger line of any level was in that journal, at any point in
#      seven days. The units run `bundle exec rails ...` with no RAILS_ENV, so
#      the loop boots in DEVELOPMENT, where Rails logs to log/development.log.
#      journald only ever received the rake task's `puts` and crash backtraces.
#      Verified on the live box: 0 logger lines in the journal, and the swallowed
#      "Failed to persist Order record: Validation failed: Side is not included
#      in the list" sitting in log/development.log where nobody was looking.
#
# Flipping the live loop to RAILS_ENV=production is a much bigger change than a
# logging fix (database, eager loading, credentials), so instead the long-running
# units opt in to the Rails-conventional RAILS_LOG_TO_STDOUT and development
# honours it. A background service whose logs go to a file inside the working
# directory is a service nobody is watching.
RSpec.describe "operator-visible logging", type: :lint do
  root = Rails.root

  # cfb-web is excluded on purpose: `rails server` already broadcasts to stdout,
  # so opting in there would double every line.
  background_units = %w[cfb-realtime cfb-signals cfb-worker]

  background_units.each do |unit|
    it "#{unit} sends its Rails log to stdout so journald can capture it" do
      contents = File.read(root.join("deploy/systemd/#{unit}.service"))

      expect(contents).to match(/RAILS_LOG_TO_STDOUT=1/)
    end
  end

  it "development honours RAILS_LOG_TO_STDOUT, so the opt-in actually does something" do
    contents = File.read(root.join("config/environments/development.rb"))

    expect(contents).to match(/RAILS_LOG_TO_STDOUT/)
  end
end
