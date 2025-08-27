# frozen_string_literal: true

namespace :good_job do
  desc "Delete all GoodJob jobs"
  task delete_all: :environment do
    count = GoodJob::Job.count
    GoodJob::Job.delete_all
    puts "✓ Deleted #{count} GoodJob jobs"
  end

  desc "Cancel all pending GoodJob jobs (mark as finished)"
  task cancel_all: :environment do
    pending_count = GoodJob::Job.where(finished_at: nil).count
    GoodJob::Job.where(finished_at: nil).update_all(finished_at: Time.current)
    puts "✓ Cancelled #{pending_count} pending GoodJob jobs"
  end

  desc "Show GoodJob statistics"
  task stats: :environment do
    total = GoodJob::Job.count
    pending = GoodJob::Job.where(finished_at: nil).count
    finished = GoodJob::Job.where.not(finished_at: nil).count
    errored = GoodJob::Job.where.not(error: nil).count

    puts "GoodJob Statistics:"
    puts "  Total jobs: #{total}"
    puts "  Pending jobs: #{pending}"
    puts "  Finished jobs: #{finished}"
    puts "  Errored jobs: #{errored}"
  end

  desc "Clean up old finished jobs (older than 7 days)"
  task cleanup: :environment do
    cutoff_date = 7.days.ago
    old_jobs = GoodJob::Job.where("finished_at < ?", cutoff_date).count
    GoodJob::Job.where("finished_at < ?", cutoff_date).delete_all
    puts "✓ Cleaned up #{old_jobs} old finished jobs (older than #{cutoff_date})"
  end
end
