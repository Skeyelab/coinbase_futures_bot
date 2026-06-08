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
    it "stores width on layout" do
      msg = Bubbletea::WindowSizeMessage.new(width: 160, height: 40)
      app.update(msg)
      expect(app.instance_variable_get(:@layout).width).to eq(160)
    end
  end

  describe "#update with r key" do
    it "triggers data refresh" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "r".codepoints)
      expect(Tui::DataLoader).to receive(:load).and_return({})
      app.update(msg)
    end
  end

  describe "#update with 2 key" do
    it "switches to positions tab" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "2".codepoints)
      app.update(msg)
      expect(app.instance_variable_get(:@layout).active_tab).to eq(:positions)
    end
  end

  describe "#update with s key" do
    it "returns an ExecCommand for stop-loss edit" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "s".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end

  describe "#update with t key" do
    it "returns an ExecCommand for take-profit edit" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "t".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end

  describe "#update with tab number keys" do
    it "switches to market tab on 4" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "4".codepoints)
      app.update(msg)
      expect(app.instance_variable_get(:@layout).active_tab).to eq(:market)
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

  describe "#update with ? key" do
    it "returns an ExecCommand for the operation menu" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "?".codepoints)
      _, cmd = app.update(msg)
      expect(cmd).to be_a(Bubbletea::ExecCommand)
    end
  end

  describe "#update with m key on health tab" do
    let(:session) { instance_double(RealtimeMonitoring::Session, toggle!: {success: true, message: "Real-time monitoring started"}) }

    before do
      layout = app.instance_variable_get(:@layout).switch_to_tab(:health)
      app.instance_variable_set(:@layout, layout)
      allow(RealtimeMonitoring::Session).to receive(:current).and_return(session)
    end

    it "toggles realtime monitoring" do
      msg = Bubbletea::KeyMessage.new(key_type: Bubbletea::KeyMessage::KEY_RUNES, runes: "m".codepoints)
      app.update(msg)
      sleep 0.05
      expect(session).to have_received(:toggle!)
    end
  end
end
