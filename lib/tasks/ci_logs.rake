# frozen_string_literal: true

require "json"
require "fileutils"
require "faraday"

namespace :ci do
  # Usage examples:
  #   bundle exec rake ci:fetch_logs
  #   bundle exec rake ci:fetch_logs[ci.yml]
  #   RUN_ID=123 bundle exec rake ci:fetch_logs
  #   GITHUB_REPO=Skeyelab/coinbase_futures_bot bundle exec rake ci:fetch_logs
  #
  # Env vars / args (args override env):
  #   GITHUB_TOKEN: Personal access token with Actions: Read
  #   GITHUB_REPO:  "owner/repo" (auto-detected from git remote if omitted)
  #   CI_WORKFLOW:  Workflow file name or ID (default: "ci.yml")
  #   RUN_ID:       Specific run ID to download (default: detect by HEAD SHA)
  desc "Download GitHub Actions logs for the latest run of the CI workflow into log/ci/"
  task :fetch_logs, %i[workflow run_id repo] => :environment do |_t, args|
    token = ENV["GITHUB_TOKEN"] || ENV["GH_TOKEN"] || ENV["GH_PAT"]
    abort "GITHUB_TOKEN (or GH_TOKEN) is required" unless token && !token.strip.empty?

    workflow = (args[:workflow] || ENV["CI_WORKFLOW"] || "ci.yml").to_s
    repo = (args[:repo] || ENV["GITHUB_REPO"] || autodetect_repo).to_s
    abort "GITHUB_REPO could not be determined" if repo.to_s.strip.empty?

    head_sha = (ENV["GIT_SHA"] || current_head_sha).to_s

    connection = Faraday.new(
      url: "https://api.github.com",
      headers: {
        "Authorization" => "Bearer #{token}",
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28"
      }
    )

    run_id = (args[:run_id] || ENV["RUN_ID"]).to_s

    wait_for_run = truthy_env?(ENV["WAIT"]) || truthy_env?(ENV["WAIT_FOR_RUN"]) || false
    wait_for_completion = truthy_env?(ENV["WAIT_FOR_COMPLETION"]) || false
    wait_timeout = (ENV["WAIT_TIMEOUT"] || 300).to_i
    wait_interval = (ENV["WAIT_INTERVAL"] || 5).to_i

    if run_id.empty?
      run = nil
      deadline = Time.now + wait_timeout
      loop do
        run = locate_workflow_run(connection, repo, workflow, head_sha)
        break if run || !wait_for_run
        break if Time.now >= deadline

        sleep wait_interval
      end
      abort "No workflow runs found for #{workflow} in #{repo}" unless run
      run_id = run.fetch("id").to_s
      run_number = run.fetch("run_number")
      run_status = run.fetch("status")
      run_conclusion = run["conclusion"]
      run_created_at = run.fetch("created_at")
      puts "Found run ##{run_number} (id #{run_id}) status=#{run_status} conclusion=#{run_conclusion} created_at=#{run_created_at}"
    else
      puts "Using provided RUN_ID=#{run_id}"
    end

    dest_dir = File.join("log", "ci", "#{run_id}-#{head_sha[0, 7]}")
    FileUtils.mkdir_p(dest_dir)

    # Download combined run logs (zip)
    run_zip_path = File.join(dest_dir, "run_#{run_id}.zip")
    download_with_redirects(connection, "/repos/#{repo}/actions/runs/#{run_id}/logs", run_zip_path)
    puts "Saved run logs ZIP => #{run_zip_path}"

    # Optionally wait for completion
    if wait_for_completion
      puts "Waiting for run #{run_id} to complete..."
      deadline = Time.now + wait_timeout
      loop do
        run_meta = fetch_json(connection, "/repos/#{repo}/actions/runs/#{run_id}")
        status = run_meta["status"]
        conclusion = run_meta["conclusion"]
        if status == "completed"
          puts "Run completed with conclusion=#{conclusion}"
          break
        end
        break if Time.now >= deadline

        sleep wait_interval
      end
    end

    # Save run metadata for convenience (final snapshot)
    run_meta = fetch_json(connection, "/repos/#{repo}/actions/runs/#{run_id}")
    File.write(File.join(dest_dir, "run_#{run_id}_metadata.json"), JSON.pretty_generate(run_meta))

    # Download each job's plaintext logs
    jobs = fetch_json(connection, "/repos/#{repo}/actions/runs/#{run_id}/jobs").fetch("jobs", [])
    jobs.each do |job|
      job_id = job.fetch("id")
      job_name = job.fetch("name")
      safe_name = job_name.gsub(/[^a-zA-Z0-9_.-]+/, "_")
      job_log_path = File.join(dest_dir, "job_#{job_id}_#{safe_name}.log")
      download_with_redirects(connection, "/repos/#{repo}/actions/jobs/#{job_id}/logs", job_log_path)
      puts "Saved job log => #{job_log_path}"
    end

    puts "All logs saved under #{dest_dir}"
  end

  # Convenience: push current branch (or specified) then wait for CI and fetch logs
  # Usage:
  #   bundle exec rake ci:after_push                  # push current branch to origin, wait, fetch
  #   bundle exec rake ci:after_push[upstream,feat/x] # push feat/x to upstream, wait, fetch
  # Env vars honored:
  #   SKIP_PUSH=1                 # do not push, only wait+fetch
  #   CI_WORKFLOW / GITHUB_REPO   # passed to ci:fetch_logs
  #   WAIT_TIMEOUT / WAIT_INTERVAL
  desc "Push branch then wait for CI run and fetch logs (into log/ci/)"
  task :after_push, %i[remote branch] => :environment do |_t, args|
    remote = (args[:remote] || ENV["GIT_REMOTE"] || "origin").to_s
    branch = (args[:branch] || ENV["GIT_BRANCH"] || current_branch).to_s
    abort "Unable to determine git branch" if branch.to_s.strip.empty?

    if truthy_env?(ENV["SKIP_PUSH"])
      puts "SKIP_PUSH=1 set; skipping git push"
    else
      puts "Pushing #{branch} to #{remote}..."
      success = system("git", "push", remote, branch)
      abort "git push failed for #{remote} #{branch}" unless success
    end

    # Ensure we wait for the run to appear and complete
    ENV["WAIT"] = "1"
    ENV["WAIT_FOR_RUN"] = "1"
    ENV["WAIT_FOR_COMPLETION"] = "1"

    # Re-enable in case it was invoked before
    Rake::Task["ci:fetch_logs"].reenable
    Rake::Task["ci:fetch_logs"].invoke
  end

  def truthy_env?(value)
    return false if value.nil?

    %w[1 true yes on y].include?(value.to_s.strip.downcase)
  end

  def autodetect_repo
    origin = `git remote get-url origin 2>/dev/null`.strip
    return ENV["GITHUB_REPO"] if origin.empty?

    # Handle SSH (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git)
    if origin =~ %r{github.com[/:]([^/]+)/([^/.]+)(?:\.git)?$}
      "#{Regexp.last_match(1)}/#{Regexp.last_match(2)}"
    else
      ""
    end
  end

  def current_head_sha
    `git rev-parse HEAD 2>/dev/null`.strip
  end

  def current_branch
    `git rev-parse --abbrev-ref HEAD 2>/dev/null`.strip
  end

  def fetch_json(connection, path)
    res = connection.get(path)
    JSON.parse(res.body)
  end

  def locate_workflow_run(connection, repo, workflow, head_sha)
    # List workflow runs for the given workflow file
    res = connection.get("/repos/#{repo}/actions/workflows/#{workflow}/runs", {per_page: 50})
    runs = JSON.parse(res.body).fetch("workflow_runs", [])
    runs.find { |r| r["head_sha"] == head_sha } || runs.first
  end

  def download_with_redirects(connection, path, dest_path)
    res = connection.get(path)
    if res.status.to_i.between?(300, 399) && (location = res.headers["location"]) && !location.to_s.empty?
      # Follow redirect without auth (signed URL)
      body = Faraday.get(location).body
      File.binwrite(dest_path, body)
    else
      File.binwrite(dest_path, res.body)
    end
  end
end
