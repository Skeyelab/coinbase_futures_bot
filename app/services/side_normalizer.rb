# frozen_string_literal: true

class SideNormalizer
  POSITION_SIDES = {
    "long" => "LONG",
    "buy" => "LONG",
    "short" => "SHORT",
    "sell" => "SHORT"
  }.freeze

  SIGNAL_SIDES = {
    "long" => "long",
    "buy" => "long",
    "short" => "short",
    "sell" => "short"
  }.freeze

  ORDER_SIDES = {
    "long" => "LONG",
    "short" => "SHORT",
    "buy" => "BUY",
    "sell" => "SELL"
  }.freeze

  ORDER_SIDE_SYMBOLS = {
    "LONG" => :long,
    "SHORT" => :short,
    "BUY" => :buy,
    "SELL" => :sell
  }.freeze

  SIMULATOR_SIDES = {
    "long" => :buy,
    "buy" => :buy,
    "short" => :sell,
    "sell" => :sell
  }.freeze

  def self.position(value)
    POSITION_SIDES[value.to_s.downcase]
  end

  def self.signal(value)
    SIGNAL_SIDES[value.to_s.downcase]
  end

  def self.order(value)
    ORDER_SIDES[value.to_s.downcase]
  end

  def self.order_symbol(value)
    ORDER_SIDE_SYMBOLS[value.to_s.upcase]
  end

  def self.simulator_fill_side(value)
    SIMULATOR_SIDES[value.to_s.downcase] || value.to_s.downcase.to_sym
  end
end
