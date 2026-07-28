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

  # "Is this side long?" was the question four callers actually had, and each
  # answered it by re-typing a slice of POSITION_SIDES as its own inclusion
  # list: %i[long buy] (CostModel, Strategy::MultiTimeframeSignal),
  # %w[BUY LONG] (ExecutionCalibration::Tape), %w[long buy] (SignalAlert).
  # Four copies of one table is four places for an alias to go missing.
  #
  # Deliberately NOT complements: an unrecognised side is neither long nor
  # short, so garbage cannot silently read as "short" the way `!long?` would
  # make it.
  def self.long?(value)
    position(value) == "LONG"
  end

  def self.short?(value)
    position(value) == "SHORT"
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
