# frozen_string_literal: true

class BotRuntimeStat < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :recorded_at, presence: true
end
