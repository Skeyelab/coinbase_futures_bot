# frozen_string_literal: true

require "rails_helper"
require "tui"

RSpec.describe Tui::App do
  subject(:app) { described_class.new }

  describe "#update with TickMessage" do
    it "reschedules tick" do
      allow(Tui::DataLoader).to receive(:load).and_return({})
      _, cmd = app.update(Tui::TickMessage.new)
      expect(cmd).to be_a(Bubbletea::TickCommand)
    end

    it "calls DataLoader.load" do
      expect(Tui::DataLoader).to receive(:load).and_return({})
      app.update(Tui::TickMessage.new)
    end
  end

  describe "#update with WindowSizeMessage" do
    it "stores width" do
      msg = Bubbletea::WindowSizeMessage.new(width: 160, height: 40)
      app.update(msg)
      expect(app.instance_variable_get(:@width)).to eq(160)
    end
  end

  describe "#update with r key" do
    it "triggers data refresh" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "r".codepoints)
      expect(Tui::DataLoader).to receive(:load).and_return({})
      app.update(msg)
    end
  end

  describe "#update with p key" do
    it "toggles positions visibility" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "p".codepoints)
      expect { app.update(msg) }.to change { app.instance_variable_get(:@show_positions) }.from(true).to(false)
    end
  end

  describe "#update with s key" do
    it "toggles signals visibility" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "s".codepoints)
      expect { app.update(msg) }.to change { app.instance_variable_get(:@show_signals) }.from(true).to(false)
    end
  end

  describe "#update with c key" do
    it "returns an ExecCommand for close form" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "c".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end

  describe "#update with o key" do
    it "returns an ExecCommand for reconcile form" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "o".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end

  describe "#update with h key" do
    it "returns an ExecCommand for halt form" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "h".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end
end
