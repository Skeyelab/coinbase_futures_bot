# frozen_string_literal: true

class AddPgNotifyTriggersForTui < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION tui_notify_positions()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_notify('tui_positions', TG_OP);
        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS tui_positions_notify ON positions;
      CREATE TRIGGER tui_positions_notify
        AFTER INSERT OR UPDATE OR DELETE ON positions
        FOR EACH STATEMENT EXECUTE FUNCTION tui_notify_positions();

      CREATE OR REPLACE FUNCTION tui_notify_signals()
      RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        PERFORM pg_notify('tui_signals', TG_OP);
        RETURN NEW;
      END;
      $$;

      DROP TRIGGER IF EXISTS tui_signals_notify ON signal_alerts;
      CREATE TRIGGER tui_signals_notify
        AFTER INSERT OR UPDATE OR DELETE ON signal_alerts
        FOR EACH STATEMENT EXECUTE FUNCTION tui_notify_signals();
    SQL
  end

  def down
    execute <<~SQL
      DROP TRIGGER IF EXISTS tui_positions_notify ON positions;
      DROP FUNCTION IF EXISTS tui_notify_positions();
      DROP TRIGGER IF EXISTS tui_signals_notify ON signal_alerts;
      DROP FUNCTION IF EXISTS tui_notify_signals();
    SQL
  end
end
