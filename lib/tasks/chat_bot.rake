# frozen_string_literal: true

namespace :chat_bot do
  desc "Start interactive trading bot chat"
  task start: :environment do
    options = parse_cli_options(ARGV)

    puts "\n🤖 FuturesBot Chat Interface"
    puts "============================="

    # Handle session resumption
    session_id = if options[:resume]
      resume_last_session
    elsif options[:session_id]
      options[:session_id]
    else
      SecureRandom.uuid
    end

    bot = ChatBotService.new(session_id)

    # Show session info
    summary = bot.session_summary
    if summary[:total_interactions] > 0
      puts "Resuming session #{session_id[0..7]} (#{summary[:total_interactions]} messages, #{summary[:profitable_messages]} profitable)"
    else
      puts "Starting new session #{session_id[0..7]}"
    end

    puts "Type 'help' for available commands or 'quit' to exit.\n\n"

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

        # Built-in CLI commands (processed locally without AI)
        case input.downcase
        when /^history\s*(\d+)?$/
          limit = $1&.to_i || 10
          show_local_history(bot, limit)
          next
        when /^search\s+(.+)$/
          query = $1.strip
          show_search_results(bot, query)
          next
        when /^sessions$/
          show_sessions_list(bot)
          next
        when /^context[-_]?status$/
          show_context_status(bot)
          next
        when /^new[-_]?session(?:\s+(.+))?$/
          name = $1&.strip
          session_id = start_new_session(name)
          bot = ChatBotService.new(session_id)
          puts "Started new session: #{session_id[0..7]} - #{name || "Unnamed"}"
          next
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
      puts "   Profitable messages: #{summary[:profitable_messages]}"
      puts "   Session ID: #{session_id[0..7]}..."
    end
  end

  def self.parse_cli_options(args)
    options = {}

    args.each_with_index do |arg, i|
      case arg
      when "--resume"
        options[:resume] = true
      when "--session"
        options[:session_id] = args[i + 1] if args[i + 1]
      end
    end

    options
  end

  def self.resume_last_session
    last_session = ChatSession.active.recent.first
    if last_session
      last_session.session_id
    else
      puts "No active sessions found. Starting new session."
      SecureRandom.uuid
    end
  end

  def self.start_new_session(name = nil)
    session_id = SecureRandom.uuid
    ChatSession.create!(
      session_id: session_id,
      name: name,
      active: true
    )
    session_id
  end

  def self.show_local_history(bot, limit)
    bot.session_summary
    memory_service = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
    history = memory_service.recent_interactions(limit)

    puts "📜 Recent History (#{limit} messages):"
    if history.any?
      history.each_with_index do |interaction, i|
        timestamp = Time.parse(interaction[:timestamp]).strftime("%H:%M")
        puts "#{i + 1}. [#{timestamp}] #{interaction[:input].truncate(80)}"
      end
    else
      puts "No history found."
    end
    puts
  end

  def self.show_search_results(bot, query)
    memory_service = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
    results = memory_service.search_history(query)

    puts "🔍 Search Results for '#{query}':"
    if results.any?
      results.each_with_index do |result, i|
        timestamp = result[1].strftime("%m/%d %H:%M")
        impact = result[2].upcase
        puts "#{i + 1}. [#{timestamp}] [#{impact}] #{result[0].truncate(100)}"
      end
    else
      puts "No results found."
    end
    puts
  end

  def self.show_sessions_list(bot)
    sessions = ChatSession.active.recent.limit(10)
    current_id = bot.instance_variable_get(:@session_id)

    puts "💬 Active Chat Sessions:"
    if sessions.any?
      sessions.each_with_index do |session, i|
        marker = (session.session_id == current_id) ? "→" : " "
        puts "#{marker} #{i + 1}. #{session.session_id[0..7]} - #{session.name || "Unnamed"}"
        puts "    Messages: #{session.message_count} (#{session.profitable_messages.count} profitable)"
        puts "    Last: #{session.last_activity&.strftime("%m/%d %H:%M") || "N/A"}"
      end
    else
      puts "No active sessions found."
    end
    puts
  end

  def self.show_context_status(bot)
    summary = bot.session_summary
    memory_service = ChatMemoryService.new(bot.instance_variable_get(:@session_id))
    context_length = memory_service.context_for_ai(4000).length

    puts "🧠 Context Status:"
    puts "Session: #{summary[:session_id][0..7]}"
    puts "Messages: #{summary[:total_interactions]} (#{summary[:profitable_messages]} profitable)"
    puts "Context Length: #{context_length} chars (~#{(context_length / 4).to_i} tokens)"
    puts "Last Activity: #{summary[:last_activity] || "N/A"}"
    puts
  end
end
