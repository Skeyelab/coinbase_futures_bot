# frozen_string_literal: true

begin
  require "climate_control"
rescue LoadError
  # climate_control is optional; specs that rely on it should guard accordingly
end
