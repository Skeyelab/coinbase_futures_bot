# frozen_string_literal: true

namespace :chat_bot do
  desc "Start interactive trading bot chat"
  task start: :environment do
    puts "\n🤖 FuturesBot Chat Interface"
    puts "============================="
    puts "Type 'help' for available commands or 'quit' to exit.\n\n"

    session_id = SecureRandom.uuid
    bot = ChatBotService.new(session_id)
    command_history = []

    # Handle Ctrl+C gracefully
    Signal.trap("INT") do
      puts "\n\n👋 Goodbye! Chat session ended."
      exit(0)
    end

    loop do
      print "FuturesBot> "

      begin
        input = $stdin.gets
        break unless input # Handle EOF (Ctrl+D)

        input = input.chomp.strip
        next if input.empty?

        # Exit commands
        if %w[quit exit bye].include?(input.downcase)
          puts "\n👋 Goodbye! Chat session ended."
          break
        end

        # Store command in history
        command_history << input unless command_history.last == input
        command_history = command_history.last(50) # Keep last 50 commands

        # Process command with loading indicator
        print "Processing... "
        response = bot.process(input)
        print "\r" + " " * 14 + "\r" # Clear loading indicator

        puts response
        puts # Add blank line for readability
      rescue Interrupt
        puts "\n\n👋 Goodbye! Chat session ended."
        break
      rescue => e
        puts "\n❌ Error: #{e.message}"
        puts "Please try again or type 'quit' to exit.\n"
      end
    end

    # Show session summary on exit
    summary = bot.session_summary
    if summary && summary[:total_interactions] > 0
      puts "\n📊 Session Summary:"
      puts "   Commands processed: #{summary[:total_interactions]}"
      puts "   Session ID: #{session_id[0..7]}..."
    end
  end
end
