# frozen_string_literal: true

module Tui
  class OperationsCatalog
    Entry = Data.define(:key, :label, :description, :tabs)

    ENTRIES = [
      Entry.new(key: "r", label: "Refresh", description: "Reload dashboard data", tabs: :all),
      Entry.new(key: "i", label: "Import", description: "Sync positions from Coinbase", tabs: :all),
      Entry.new(key: "t", label: "Take-profit", description: "Set take-profit on an open position", tabs: :all),
      Entry.new(key: "s", label: "Stop-loss", description: "Set stop-loss on an open position", tabs: :all),
      Entry.new(key: "c", label: "Close", description: "Close an open position on Coinbase", tabs: :all),
      Entry.new(key: "o", label: "Reconcile", description: "Reconcile local positions vs exchange", tabs: :all),
      Entry.new(key: "h", label: "Halt", description: "Halt or resume automated trading", tabs: :all),
      Entry.new(key: "m", label: "Real-time", description: "Toggle futures TP/SL websocket monitoring", tabs: [:health]),
      Entry.new(key: "?", label: "Menu", description: "Choose an operation from a list", tabs: :all)
    ].freeze

    def self.entries
      ENTRIES
    end

    def self.for_tab(tab)
      entries.select { |entry| entry.tabs == :all || Array(entry.tabs).include?(tab) }
    end

    def self.find(key)
      entries.find { |entry| entry.key == key.to_s }
    end
  end
end
