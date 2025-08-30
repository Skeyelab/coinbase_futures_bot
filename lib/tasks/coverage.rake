# frozen_string_literal: true

namespace :coverage do
  desc "Run tests with coverage and open report"
  task run: :environment do
    puts "Running tests with SimpleCov coverage..."

    # Set coverage environment variable
    ENV["COVERAGE"] = "true"

    # Run RSpec
    system("bundle exec rspec --format progress")

    if $?.success?
      puts "\n✅ Tests completed successfully!"
      puts "📊 Coverage report generated in coverage/index.html"

      # Check if we can open the browser
      if RUBY_PLATFORM.include?("darwin")
        system("open coverage/index.html")
      elsif RUBY_PLATFORM.include?("linux")
        system("xdg-open coverage/index.html 2>/dev/null || echo 'Please open coverage/index.html manually'")
      else
        puts "Please open coverage/index.html in your browser to view the report"
      end
    else
      puts "\n❌ Tests failed. Please fix the issues before checking coverage."
      exit 1
    end
  end

  desc "Check coverage thresholds"
  task check: :environment do
    puts "Checking coverage thresholds..."

    unless File.exist?("coverage/.resultset.json")
      puts "❌ Coverage file not found. Run 'rake coverage:run' first."
      exit 1
    end

    require "json"

    data = JSON.parse(File.read("coverage/.resultset.json"))

    if data["RSpec"]
      # Line coverage
      line_coverage = data["RSpec"]["coverage"].values.map { |v| v["lines"] }.flatten.compact
      covered_lines = line_coverage.count { |v| v && v > 0 }
      total_lines = line_coverage.count { |v| v }
      line_percentage = (total_lines > 0) ? (covered_lines.to_f / total_lines * 100).round(2) : 0

      # Branch coverage
      branch_coverage = data["RSpec"]["coverage"].values.map { |v| v["branches"] }.flatten.compact
      covered_branches = branch_coverage.count { |v| v && v > 0 }
      total_branches = branch_coverage.count { |v| v }
      branch_percentage = (total_branches > 0) ? (covered_branches.to_f / total_branches * 100).round(2) : 0

      puts "📊 Coverage Report:"
      puts "Line Coverage: #{covered_lines}/#{total_lines} (#{line_percentage}%)"
      puts "Branch Coverage: #{covered_branches}/#{total_branches} (#{branch_percentage}%)"

      # Check thresholds
      line_threshold = (ENV["CI"] == "true") ? 85.0 : 90.0
      branch_threshold = (ENV["CI"] == "true") ? 75.0 : 80.0

      puts "\n🎯 Thresholds:"
      puts "Line Coverage: #{(line_percentage >= line_threshold) ? "✅" : "❌"} #{line_percentage}% (>= #{line_threshold}%)"
      puts "Branch Coverage: #{(branch_percentage >= branch_threshold) ? "✅" : "❌"} #{branch_percentage}% (>= #{branch_threshold}%)"

      # Exit with error if thresholds not met
      if line_percentage < line_threshold || branch_percentage < branch_threshold
        puts "\n❌ Coverage thresholds not met!"
        exit 1
      else
        puts "\n🎉 All coverage thresholds met!"
      end
    else
      puts "❌ No coverage data found"
      exit 1
    end
  end

  desc "Clean coverage files"
  task clean: :environment do
    puts "Cleaning coverage files..."

    if Dir.exist?("coverage")
      FileUtils.rm_rf("coverage")
      puts "✅ Coverage directory removed"
    else
      puts "ℹ️  Coverage directory not found"
    end
  end

  desc "Show coverage summary"
  task summary: :environment do
    puts "Coverage Summary:"
    puts "================="

    unless File.exist?("coverage/.resultset.json")
      puts "❌ Coverage file not found. Run 'rake coverage:run' first."
      exit 1
    end

    require "json"

    data = JSON.parse(File.read("coverage/.resultset.json"))

    if data["RSpec"]
      coverage = data["RSpec"]["coverage"]

      puts "Files covered: #{coverage.keys.length}"

      # Group by directory
      groups = coverage.keys.group_by { |file| File.dirname(file) }

      groups.each do |dir, files|
        puts "\n#{dir}:"
        files.each do |file|
          file_data = coverage[file]
          line_coverage = file_data["lines"]
          file_data["branches"]

          next unless line_coverage

          covered_lines = line_coverage.values.count { |v| v && v > 0 }
          total_lines = line_coverage.values.count { |v| v }
          line_percentage = (total_lines > 0) ? (covered_lines.to_f / total_lines * 100).round(1) : 0

          puts "  #{File.basename(file)}: #{line_percentage}% (#{covered_lines}/#{total_lines})"
        end
      end
    else
      puts "❌ No coverage data found"
      exit 1
    end
  end
end

# Default coverage task
task coverage: "coverage:run"
