# frozen_string_literal: true

module Tui
  class Layout
    TABS = %i[overview positions signals market health].freeze

    attr_reader :active_tab, :width

    def initialize(active_tab: :overview, width: 120)
      @active_tab = TABS.include?(active_tab) ? active_tab : :overview
      @width = width
    end

    def tab_number
      TABS.index(active_tab) + 1
    end

    def switch_to(number)
      index = number.to_i - 1
      return self unless TABS[index]

      self.class.new(active_tab: TABS[index], width: width)
    end

    def switch_to_tab(tab)
      return self unless TABS.include?(tab)

      self.class.new(active_tab: tab, width: width)
    end

    def with_width(new_width)
      self.class.new(active_tab: active_tab, width: new_width)
    end
  end
end
