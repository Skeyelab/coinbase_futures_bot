# frozen_string_literal: true

# Frozen fitted-scorer artifacts (issue #302 steps 3-4). One row = one fitted
# model: coefficients + the exact feature spec needed to reproduce its inputs
# (names, symbol dummies, standardization constants) + training metadata
# (ranges, row counts, out-of-sample calibration report). Once frozen_at is
# set the row refuses updates — #483 discipline: a config under evaluation
# must have stopped moving.
class CreateScorerArtifacts < ActiveRecord::Migration[8.1]
  def change
    create_table :scorer_artifacts do |t|
      t.string :version, null: false, index: {unique: true}
      t.string :kind, null: false, default: "logistic_v1"
      t.string :direction, null: false
      t.string :timeframe, null: false, default: "5m"
      t.decimal :tp_frac, precision: 10, scale: 6, null: false
      t.decimal :sl_frac, precision: 10, scale: 6, null: false
      t.integer :horizon, null: false
      t.jsonb :feature_spec, null: false, default: {}
      t.jsonb :coefficients, null: false, default: {}
      t.jsonb :training_metadata, null: false, default: {}
      t.datetime :frozen_at
      t.timestamps
    end
  end
end
