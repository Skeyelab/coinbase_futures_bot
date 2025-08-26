# frozen_string_literal: true

class TestNameFormatter
  RSpec::Core::Formatters.register self, :example_started, :example_finished

  def initialize(output)
    @output = output
  end

  def example_started(notification)
    @output.puts "\n🧪 STARTING: #{notification.example.full_description}"
    @output.puts "   📁 #{notification.example.file_path}:#{notification.example.line_number}"
    @output.flush
  end

  def example_finished(notification)
    status = case notification.example.execution_result.status
             when :passed then "✅ PASSED"
             when :failed then "❌ FAILED"
             when :pending then "⏸️  PENDING"
             else "❓ UNKNOWN"
             end
    
    @output.puts "   #{status}: #{notification.example.full_description}"
    @output.flush
  end
end
