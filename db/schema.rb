# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_21_151801) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "bot_runtime_stats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "recorded_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_bot_runtime_stats_on_key", unique: true
  end

  create_table "candles", force: :cascade do |t|
    t.decimal "close", precision: 20, scale: 10, null: false
    t.datetime "created_at", null: false
    t.decimal "high", precision: 20, scale: 10, null: false
    t.decimal "low", precision: 20, scale: 10, null: false
    t.decimal "open", precision: 20, scale: 10, null: false
    t.string "symbol", null: false
    t.string "timeframe", default: "1h", null: false
    t.datetime "timestamp", null: false
    t.datetime "updated_at", null: false
    t.decimal "volume", precision: 30, scale: 10, default: "0.0", null: false
    t.index ["symbol", "timeframe", "timestamp"], name: "index_candles_on_symbol_and_timeframe_and_timestamp", unique: true
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "message_type", null: false
    t.json "metadata", default: {}
    t.string "profit_impact", default: "unknown", null: false
    t.decimal "relevance_score", precision: 5, scale: 3, default: "1.0"
    t.datetime "timestamp", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_session_id", "timestamp"], name: "index_chat_messages_on_chat_session_id_and_timestamp"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["message_type"], name: "index_chat_messages_on_message_type"
    t.index ["profit_impact"], name: "index_chat_messages_on_profit_impact"
    t.index ["relevance_score"], name: "index_chat_messages_on_relevance_score"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.json "metadata", default: {}
    t.string "name"
    t.string "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_chat_sessions_on_active"
    t.index ["session_id"], name: "index_chat_sessions_on_session_id", unique: true
    t.index ["updated_at"], name: "index_chat_sessions_on_updated_at"
  end

  create_table "contracts", force: :cascade do |t|
    t.string "base_currency"
    t.string "contract_type"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.date "expiration_date"
    t.decimal "min_size", precision: 20, scale: 10
    t.decimal "price_increment", precision: 20, scale: 10
    t.string "product_id", null: false
    t.string "quote_currency"
    t.decimal "size_increment", precision: 20, scale: 10
    t.string "status"
    t.bigint "underlying_id"
    t.datetime "updated_at", null: false
    t.index ["expiration_date"], name: "index_contracts_on_expiration_date"
    t.index ["product_id"], name: "index_contracts_on_product_id", unique: true
    t.index ["underlying_id"], name: "index_contracts_on_underlying_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at", where: "((retried_good_job_id IS NULL) AND (finished_at IS NOT NULL))"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "orders", force: :cascade do |t|
    t.string "coinbase_order_id"
    t.string "contract_id", null: false
    t.datetime "created_at", null: false
    t.decimal "fill_price", precision: 20, scale: 8
    t.datetime "filled_at"
    t.string "order_type", default: "market", null: false
    t.datetime "placed_at"
    t.bigint "position_id"
    t.decimal "quantity", precision: 20, scale: 8, null: false
    t.string "side", null: false
    t.string "status", default: "pending", null: false
    t.decimal "target_price", precision: 20, scale: 8
    t.datetime "updated_at", null: false
    t.index ["coinbase_order_id"], name: "index_orders_on_coinbase_order_id", unique: true, where: "(coinbase_order_id IS NOT NULL)"
    t.index ["contract_id"], name: "index_orders_on_contract_id"
    t.index ["position_id"], name: "index_orders_on_position_id"
    t.index ["status"], name: "index_orders_on_status"
  end

  create_table "positions", force: :cascade do |t|
    t.datetime "close_time"
    t.datetime "created_at", null: false
    t.boolean "day_trading"
    t.decimal "entry_price"
    t.datetime "entry_time"
    t.decimal "max_adverse_excursion"
    t.boolean "paper", default: false, null: false
    t.decimal "pnl"
    t.string "product_id"
    t.string "side"
    t.decimal "size"
    t.string "status"
    t.decimal "stop_loss"
    t.decimal "take_profit"
    t.boolean "trailing_stop_enabled", default: false, null: false
    t.jsonb "trailing_stop_state", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["status", "trailing_stop_enabled"], name: "index_positions_on_status_and_trailing_stop_enabled"
  end

  create_table "sentiment_aggregates", force: :cascade do |t|
    t.decimal "avg_score", precision: 8, scale: 4, default: "0.0", null: false
    t.integer "count", default: 0, null: false
    t.datetime "created_at", null: false
    t.jsonb "meta", default: {}, null: false
    t.string "symbol", null: false
    t.datetime "updated_at", null: false
    t.decimal "weighted_score", precision: 8, scale: 4, default: "0.0", null: false
    t.string "window", null: false
    t.datetime "window_end_at", null: false
    t.decimal "z_score", precision: 8, scale: 4, default: "0.0", null: false
    t.index ["symbol", "window", "window_end_at"], name: "index_sentiment_aggregates_on_sym_win_end", unique: true
    t.index ["symbol"], name: "index_sentiment_aggregates_on_symbol"
    t.index ["window_end_at"], name: "index_sentiment_aggregates_on_window_end_at"
  end

  create_table "sentiment_events", force: :cascade do |t|
    t.decimal "confidence", precision: 6, scale: 3
    t.datetime "created_at", null: false
    t.jsonb "meta", default: {}, null: false
    t.datetime "published_at", null: false
    t.string "raw_text_hash", null: false
    t.decimal "score", precision: 6, scale: 3
    t.string "source", null: false
    t.string "symbol"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["published_at"], name: "index_sentiment_events_on_published_at"
    t.index ["source", "raw_text_hash"], name: "index_sentiment_events_on_source_and_raw_text_hash", unique: true
    t.index ["symbol"], name: "index_sentiment_events_on_symbol"
    t.index ["url"], name: "index_sentiment_events_on_url"
  end

  create_table "signal_alerts", force: :cascade do |t|
    t.string "alert_status"
    t.datetime "alert_timestamp"
    t.decimal "confidence"
    t.datetime "created_at", null: false
    t.decimal "entry_price"
    t.datetime "expires_at"
    t.jsonb "metadata"
    t.integer "quantity"
    t.string "side"
    t.string "signal_type"
    t.decimal "stop_loss"
    t.jsonb "strategy_data"
    t.string "strategy_name"
    t.string "symbol"
    t.decimal "take_profit"
    t.string "timeframe"
    t.datetime "triggered_at"
    t.datetime "updated_at", null: false
  end

  create_table "ticks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "observed_at", null: false
    t.decimal "price", precision: 15, scale: 5, null: false
    t.string "product_id", null: false
    t.datetime "updated_at", null: false
    t.index ["product_id", "observed_at"], name: "index_ticks_on_product_id_and_observed_at"
  end

  create_table "trading_pairs", force: :cascade do |t|
    t.string "base_currency"
    t.string "contract_type"
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.date "expiration_date"
    t.decimal "min_size", precision: 20, scale: 10
    t.decimal "price_increment", precision: 20, scale: 10
    t.string "product_id", null: false
    t.string "quote_currency"
    t.decimal "size_increment", precision: 20, scale: 10
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["expiration_date"], name: "index_trading_pairs_on_expiration_date"
    t.index ["product_id"], name: "index_trading_pairs_on_product_id", unique: true
  end

  create_table "trading_profiles", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "deduplication_window", default: 300, null: false
    t.text "description"
    t.integer "max_position_size", default: 15, null: false
    t.integer "max_signals_per_hour", default: 10, null: false
    t.decimal "min_confidence_threshold", precision: 6, scale: 2, default: "60.0", null: false
    t.integer "min_position_size", default: 5, null: false
    t.string "name", null: false
    t.decimal "risk_fraction", precision: 10, scale: 6, default: "0.02", null: false
    t.decimal "sl_target", precision: 10, scale: 6, default: "0.004", null: false
    t.decimal "tp_target", precision: 10, scale: 6, default: "0.006", null: false
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "index_trading_profiles_on_lower_name", unique: true
    t.index ["active"], name: "index_trading_profiles_one_active", unique: true, where: "(active IS TRUE)"
  end

  create_table "underlyings", force: :cascade do |t|
    t.string "asset_class"
    t.datetime "created_at", null: false
    t.string "name"
    t.string "symbol"
    t.datetime "updated_at", null: false
    t.index ["symbol"], name: "index_underlyings_on_symbol", unique: true
  end

  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "contracts", "underlyings"
  add_foreign_key "orders", "positions"
end
