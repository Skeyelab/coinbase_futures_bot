# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::App do
  subject(:app) { described_class.new }

  describe "#init" do
    it "returns [model, command]" do
      model, cmd = app.init
      expect(model).to be_a(Tui::App)
      expect(cmd).to be_a(Bubbletea::Command).or(be_nil)
    end

    it "schedules a tick command on init" do
      _, cmd = app.init
      expect(cmd).to be_a(Bubbletea::TickCommand)
    end
  end

  describe "#view" do
    it "includes FuturesBot header" do
      expect(app.view).to include("FuturesBot")
    end

    it "includes tab bar labels" do
      expect(app.view).to include("Overview").and include("Health")
    end
  end

  describe "#update with quit key" do
    it "returns quit command on q" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "q".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::QuitCommand)
    end

    it "returns quit command on ctrl+c" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_CTRL_C)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::QuitCommand)
    end

    it "returns quit on esc" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_ESC)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::QuitCommand)
    end
  end

  describe "#update with unknown message" do
    it "returns self and nil" do
      model, cmd = app.update(Bubbletea::Message.new)
      expect(model).to be(app)
      expect(cmd).to be_nil
    end
  end
end
