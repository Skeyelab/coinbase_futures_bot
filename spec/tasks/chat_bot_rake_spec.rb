# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "chat_bot:start rake task", type: :task do
  let(:session_id) { "test-session-123" }
  let(:chat_bot_service) { instance_double(ChatBotService) }

  before do
    # Load tasks if not already loaded
    Rails.application.load_tasks unless Rake::Task.task_defined?("chat_bot:start")

    # Re-enable task before each test
    Rake::Task["chat_bot:start"].reenable if Rake::Task.task_defined?("chat_bot:start")

    allow(SecureRandom).to receive(:uuid).and_return(session_id)
    allow(ChatBotService).to receive(:new).with(session_id).and_return(chat_bot_service)
    allow(chat_bot_service).to receive(:process).and_return("Test response")
    allow(chat_bot_service).to receive(:session_summary).and_return({
      total_interactions: 2,
      session_id: session_id
    })
  end

  it "loads the rake task successfully" do
    expect { Rake::Task["chat_bot:start"] }.not_to raise_error
    expect(Rake::Task["chat_bot:start"]).to be_present
  end

  it "depends on environment task" do
    task = Rake::Task["chat_bot:start"]
    expect(task.prerequisites).to include("environment")
  end

  describe "task execution components" do
    # Test the individual components without running the infinite loop

    it "creates ChatBotService with session ID" do
      expect(SecureRandom).to receive(:uuid).and_return(session_id)
      expect(ChatBotService).to receive(:new).with(session_id).and_return(chat_bot_service)

      # Mock stdin to immediately quit to avoid infinite loop
      allow($stdin).to receive(:gets).and_return("quit\n")
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      Rake::Task["chat_bot:start"].execute
    end

    it "sets up signal handler for graceful exit" do
      expect(Signal).to receive(:trap).with("INT")

      # Mock stdin to immediately quit
      allow($stdin).to receive(:gets).and_return("quit\n")
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)

      Rake::Task["chat_bot:start"].execute
    end

    it "displays welcome message" do
      # Allow any puts calls but specifically check for the welcome message
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)
      allow($stdin).to receive(:gets).and_return("quit\n")

      expect($stdout).to receive(:puts).with("\n🤖 FuturesBot Chat Interface").ordered
      expect($stdout).to receive(:puts).with("=============================").ordered
      expect($stdout).to receive(:puts).with("Type 'help' for available commands or 'quit' to exit.\n\n").ordered

      Rake::Task["chat_bot:start"].execute
    end
  end

  describe "CLI interaction simulation" do
    before do
      allow($stdout).to receive(:puts)
      allow($stdout).to receive(:print)
    end

    it "processes quit command and exits gracefully" do
      allow($stdin).to receive(:gets).and_return("quit\n")
      expect($stdout).to receive(:puts).with("\n👋 Goodbye! Chat session ended.")

      Rake::Task["chat_bot:start"].execute
    end

    it "processes exit command and exits gracefully" do
      allow($stdin).to receive(:gets).and_return("exit\n")
      expect($stdout).to receive(:puts).with("\n👋 Goodbye! Chat session ended.")

      Rake::Task["chat_bot:start"].execute
    end

    it "processes bye command and exits gracefully" do
      allow($stdin).to receive(:gets).and_return("bye\n")
      expect($stdout).to receive(:puts).with("\n👋 Goodbye! Chat session ended.")

      Rake::Task["chat_bot:start"].execute
    end

    it "handles EOF gracefully" do
      allow($stdin).to receive(:gets).and_return(nil)

      expect { Rake::Task["chat_bot:start"].execute }.not_to raise_error
    end

    it "processes user commands through ChatBotService" do
      allow($stdin).to receive(:gets).and_return("show status\n", "quit\n")
      expect(chat_bot_service).to receive(:process).with("show status").and_return("Status: Active")

      Rake::Task["chat_bot:start"].execute
    end

    it "handles empty input gracefully" do
      allow($stdin).to receive(:gets).and_return("\n", "  \n", "quit\n")
      expect(chat_bot_service).not_to receive(:process)

      Rake::Task["chat_bot:start"].execute
    end

    it "handles processing errors gracefully" do
      allow($stdin).to receive(:gets).and_return("error command\n", "quit\n")
      allow(chat_bot_service).to receive(:process).and_raise(StandardError, "Test error")

      expect($stdout).to receive(:puts).with("\n❌ Error: Test error")
      expect($stdout).to receive(:puts).with("Please try again or type 'quit' to exit.\n")

      Rake::Task["chat_bot:start"].execute
    end

    it "displays session summary on exit" do
      allow($stdin).to receive(:gets).and_return("test command\n", "quit\n")

      expect($stdout).to receive(:puts).with("\n📊 Session Summary:")
      expect($stdout).to receive(:puts).with("   Commands processed: 2")
      expect($stdout).to receive(:puts).with("   Session ID: #{session_id[0..7]}...")

      Rake::Task["chat_bot:start"].execute
    end

    it "processes commands with visual feedback" do
      allow($stdin).to receive(:gets).and_return("slow command\n", "quit\n")
      allow($stdout).to receive(:print)

      # Just verify the task executes without error when processing commands
      expect { Rake::Task["chat_bot:start"].execute }.not_to raise_error
    end
  end
end
