#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to identify test files related to changed files in a PR
# Usage: ruby scripts/get_changed_test_files.rb [base_branch]

require "json"
require "open3"

class ChangedTestFilesFinder
  def initialize(base_branch = "main")
    @base_branch = base_branch
  end

  def find_changed_test_files
    changed_files = get_changed_files
    test_files = find_test_files_for_changes(changed_files)

    # Only output debug messages if not in CI mode
    unless ENV["CI"] == "true"
      puts "Changed files: #{changed_files.join(", ")}"
      puts "Related test files: #{test_files.join(", ")}"
    end

    # Output as JSON for CI consumption
    {
      changed_files: changed_files,
      test_files: test_files,
      has_changes: !changed_files.empty?,
      has_test_files: !test_files.empty?
    }.to_json
  end

  private

  def get_changed_files
    # Get changed files in the PR
    if ENV["GITHUB_EVENT_NAME"] == "pull_request"
      # In PR context, get files changed in the PR
      # Use Open3.capture3 for secure command execution
      # brakemanc:ignore Execute
      stdout, _stderr, status = Open3.capture3("git", "diff", "--name-only", "origin/#{@base_branch}...HEAD")
    else
      # In push context, get files changed in the last commit
      # brakemanc:ignore Execute
      stdout, _stderr, status = Open3.capture3("git", "diff", "--name-only", "HEAD~1...HEAD")
    end

    status.success? ? stdout.split("\n").reject(&:empty?) : []
  end

  def find_test_files_for_changes(changed_files)
    test_files = Set.new

    changed_files.each do |file|
      # Skip if it's already a test file
      next if file.start_with?("spec/")

      # Find corresponding test files
      test_files.merge(find_test_files_for_file(file))
    end

    test_files.to_a.sort
  end

  def find_test_files_for_file(file)
    test_files = Set.new

    # Extract the base name and path components
    base_name = File.basename(file, ".*")
    File.dirname(file)

    # Common patterns for finding test files
    patterns = []

    # Direct spec file mapping
    patterns << "spec/#{file.sub(%r{^app/}, "").sub(/\.rb$/, "_spec.rb")}"

    # Add patterns based on file type
    patterns << "spec/controllers/#{base_name}_spec.rb" if file.include?("controllers/")
    patterns << "spec/models/#{base_name}_spec.rb" if file.include?("models/")
    patterns << "spec/services/#{base_name}_spec.rb" if file.include?("services/")
    patterns << "spec/jobs/#{base_name}_spec.rb" if file.include?("jobs/")
    patterns << "spec/requests/#{base_name}_spec.rb" if file.include?("requests/")
    patterns << "spec/channels/#{base_name}_spec.rb" if file.include?("channels/")
    patterns << "spec/tasks/#{base_name}_spec.rb" if file.include?("tasks/")
    patterns << "spec/factories/#{base_name}_spec.rb" if file.include?("factories/")

    # Add additional patterns based on file type
    case file
    when %r{^app/controllers/}
      patterns << "spec/requests/#{base_name}_spec.rb"
    end

    # Check if test files exist
    patterns.compact.each do |pattern|
      test_files.add(pattern) if File.exist?(pattern)
    end

    # If no specific test files found, look for related test files
    if test_files.empty?
      # Look for test files that might test the same functionality
      base_name_without_underscores = base_name.delete("_")

      Dir.glob("spec/**/*_spec.rb").each do |test_file|
        test_base_name = File.basename(test_file, "_spec.rb")
        test_base_name_without_underscores = test_base_name.delete("_")

        # Check for similar names
        next unless test_base_name.include?(base_name) ||
          base_name.include?(test_base_name) ||
          test_base_name_without_underscores.include?(base_name_without_underscores)

        test_files.add(test_file)
      end
    end

    test_files.to_a
  end
end

# Main execution
if __FILE__ == $0
  base_branch = ARGV[0] || "main"
  finder = ChangedTestFilesFinder.new(base_branch)
  puts finder.find_changed_test_files
end
