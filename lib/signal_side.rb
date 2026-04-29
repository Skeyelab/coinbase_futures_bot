# frozen_string_literal: true

# Maps canonical futures direction (:long / :short) to execution-layer primitives.
module SignalSide
  module_function

  # Paper simulator and similar use :buy / :sell for fill direction.
  def simulator_fill_side(side)
    sym = side.respond_to?(:to_sym) ? side.to_sym : side.to_s.downcase.to_sym
    case sym
    when :long, :buy then :buy
    when :short, :sell then :sell
    else sym
    end
  end

  # Position model stores "LONG" / "SHORT".
  def position_model_side(side)
    sym = side.respond_to?(:to_sym) ? side.to_sym : side.to_s.downcase.to_sym
    case sym
    when :long, :buy then "LONG"
    when :short, :sell then "SHORT"
    else side.to_s.upcase
    end
  end
end
