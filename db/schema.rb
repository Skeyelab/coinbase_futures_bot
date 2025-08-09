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

ActiveRecord::Schema[7.2].define(version: 2025_08_09_042439) do
  create_schema "auth"
  create_schema "extensions"
  create_schema "graphql"
  create_schema "graphql_public"
  create_schema "net"
  create_schema "pgbouncer"
  create_schema "pgsodium"
  create_schema "pgsodium_masks"
  create_schema "realtime"
  create_schema "storage"
  create_schema "supabase_functions"
  create_schema "undefined"
  create_schema "unstract"
  create_schema "vault"

  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_graphql"
  enable_extension "pg_net"
  enable_extension "pg_stat_statements"
  enable_extension "pgcrypto"
  enable_extension "pgjwt"
  enable_extension "pgsodium"
  enable_extension "plpgsql"
  enable_extension "supabase_vault"
  enable_extension "uuid-ossp"
  enable_extension "vector"

  create_table "additional_data", id: :bigint, default: nil, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "manufacturer"
    t.text "model"
    t.text "product type"
    t.text "product url"
    t.text "additional_details"
    t.text "UPC"
    t.datetime "updated_at", precision: nil, default: -> { "now()" }
    t.string "gtin"
    t.string "EAN/UCC-13"
    t.string "Catalog Number"
    t.string "Brand/Label"
    t.string "invoice"
    t.string "Catalog Description"
    t.string "Class Code"
    t.string "Sub Class Code"
    t.boolean "upc_verified"
    t.integer "inventory_id", null: false
    t.text "title"
    t.text "brand"
    t.boolean "upc_db_searched", default: false
    t.text "image_url"
    t.boolean "image_searched", default: false
    t.text "Gross Weight (Imperial)"
    t.text "Gross Weight UOM (Imperial)"
    t.text "Height (Imperial)"
    t.text "Height UOM (Imperial)"
    t.text "Width Imperial"
    t.text "Width UOM Imperial"
    t.text "Length Imperial"
    t.text "Length UOM Imperial"
    t.text "Gross Weight (Metric)"
    t.text "Gross Weight UOM (Metric)"
    t.text "Height (Metric)"
    t.text "Height UOM (Metric)"
    t.text "Width Metric"
    t.text "Width UOM Metric"
    t.text "Length Metric"
    t.text "Length UOM Metric"
    t.text "Safety Data Sheet Flag"
    t.text "SDS URL"
    t.text "Image URL"
    t.text "Specification URL"
    t.text "Technical Drawing URL"
    t.text "Spec 1"
    t.text "Spec 2"
    t.text "Spec 3"
    t.text "Spec 4"
    t.text "Spec 5"
    t.text "Spec 6"
    t.text "Order Minimum A"
    t.text "Order Minimum B"
    t.text "Order Minimum C"
    t.text "Order Multiple (Imperial)"
    t.text "Order UOM (Imperial)"
    t.text "EU RoHS Indicator"
    t.text "Material Decomposition Declaration URL"
    t.boolean "image_found"
    t.index ["inventory_id"], name: "inv_uniq", unique: true
  end

  create_table "additional_data2", id: :bigint, default: nil, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "manufacturer"
    t.text "model"
    t.text "product type"
    t.text "product url"
    t.text "additional_details"
    t.text "UPC"
    t.datetime "updated_at", precision: nil, default: -> { "now()" }
    t.string "gtin"
    t.string "EAN/UCC-13"
    t.string "Catalog Number"
    t.string "Brand/Label"
    t.string "invoice"
    t.string "Catalog Description"
    t.string "Class Code"
    t.string "Sub Class Code"
    t.boolean "upc_verified"
    t.integer "inventory_id", null: false
    t.text "title"
    t.text "brand"
    t.boolean "upc_db_searched", default: false
    t.text "image_url"
    t.boolean "image_searched", default: false
    t.text "Gross Weight (Imperial)"
    t.text "Gross Weight UOM (Imperial)"
    t.text "Height (Imperial)"
    t.text "Height UOM (Imperial)"
    t.text "Width Imperial"
    t.text "Width UOM Imperial"
    t.text "Length Imperial"
    t.text "Length UOM Imperial"
    t.text "Gross Weight (Metric)"
    t.text "Gross Weight UOM (Metric)"
    t.text "Height (Metric)"
    t.text "Height UOM (Metric)"
    t.text "Width Metric"
    t.text "Width UOM Metric"
    t.text "Length Metric"
    t.text "Length UOM Metric"
    t.text "Safety Data Sheet Flag"
    t.text "SDS URL"
    t.text "Image URL"
    t.text "Specification URL"
    t.text "Technical Drawing URL"
    t.text "Spec 1"
    t.text "Spec 2"
    t.text "Spec 3"
    t.text "Spec 4"
    t.text "Spec 5"
    t.text "Spec 6"
    t.text "Order Minimum A"
    t.text "Order Minimum B"
    t.text "Order Minimum C"
    t.text "Order Multiple (Imperial)"
    t.text "Order UOM (Imperial)"
    t.text "EU RoHS Indicator"
    t.text "Material Decomposition Declaration URL"
    t.boolean "image_found"
    t.text "product_num"
    t.index ["inventory_id"], name: "inventory_id_uniq", unique: true
  end

  create_table "additional_data_copy", id: false, force: :cascade do |t|
    t.bigint "id", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "manufacturer"
    t.text "model"
    t.text "product type"
    t.text "product url"
    t.text "additional_details"
    t.text "UPC"
    t.datetime "updated_at", precision: nil, default: -> { "now()" }
    t.string "gtin"
    t.string "EAN/UCC-13"
    t.string "Catalog Number"
    t.string "Brand/Label"
    t.string "invoice"
    t.string "Catalog Description"
    t.string "Class Code"
    t.string "Sub Class Code"
    t.boolean "upc_verified"
    t.integer "inventory_id"
    t.text "title"
    t.text "brand"
    t.boolean "upc_db_searched", default: false
    t.text "image_url"
    t.boolean "image_searched", default: false
    t.text "Gross Weight (Imperial)"
    t.text "Gross Weight UOM (Imperial)"
    t.text "Height (Imperial)"
    t.text "Height UOM (Imperial)"
    t.text "Width Imperial"
    t.text "Width UOM Imperial"
    t.text "Length Imperial"
    t.text "Length UOM Imperial"
    t.text "Gross Weight (Metric)"
    t.text "Gross Weight UOM (Metric)"
    t.text "Height (Metric)"
    t.text "Height UOM (Metric)"
    t.text "Width Metric"
    t.text "Width UOM Metric"
    t.text "Length Metric"
    t.text "Length UOM Metric"
    t.boolean "Safety Data Sheet Flag"
    t.text "SDS URL"
    t.text "Image URL"
    t.text "Specification URL"
    t.text "Technical Drawing URL"
    t.text "Spec 1"
    t.text "Spec 2"
    t.text "Spec 3"
    t.text "Spec 4"
    t.text "Spec 5"
    t.text "Spec 6"
    t.text "Order Minimum A"
    t.text "Order Minimum B"
    t.text "Order Minimum C"
    t.text "Order Multiple (Imperial)"
    t.text "Order UOM (Imperial)"
    t.boolean "EU RoHS Indicator"
    t.text "Material Decomposition Declaration URL"
    t.text "new"
  end

  create_table "auto_tweets", id: :bigint, default: nil, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "tweet"
    t.string "account"
    t.jsonb "inspiration"
    t.jsonb "previous_data"
    t.string "style", limit: 500
  end

# Could not dump table "babsco_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


  create_table "bs_bitcoin_sentiment", id: :bigint, default: -> { "nextval('bs_bitcoin_sentiment_sampleid_seq'::regclass)" }, force: :cascade do |t|
    t.text "bs_id", null: false
    t.text "content", null: false
    t.text "sentiment"
    t.datetime "post_date", precision: nil
    t.text "type"
    t.index ["bs_id"], name: "bs_id", unique: true
  end

# Could not dump table "ericdahl_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


# Could not dump table "george_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
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

  create_table "inventory", id: :serial, force: :cascade do |t|
    t.text "item_number", null: false
    t.text "item_description"
    t.text "stock_unit"
    t.text "site"
    t.text "available_quantity"
    t.text "on_hand_quantity"
    t.text "committed_quantity"
    t.text "backorder_quantity"
    t.text "last_sale_date"
    t.text "last_quote_date"
    t.text "last_receipt_date"
    t.text "upc"
    t.text "on_order_quantity"
    t.boolean "scanned", default: false
    t.text "item_number_bak"
    t.index ["item_number"], name: "uniq_item_num", unique: true
  end

# Could not dump table "klein_docs" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


  create_table "manufacturers", id: :bigint, default: nil, force: :cascade do |t|
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.text "name"
    t.text "other_names", array: true

    t.unique_constraint ["name"], name: "manufacturers_name_key"
  end

  create_table "memory", id: :bigint, default: -> { "nextval('memory_sampleid_seq'::regclass)" }, force: :cascade do |t|
    t.text "Memory", null: false
    t.integer "user", null: false
    t.datetime "created_at", precision: nil, null: false
  end

  create_table "n8n_chat_histories", id: :serial, force: :cascade do |t|
    t.string "session_id", limit: 255, null: false
    t.jsonb "message", null: false
  end

# Could not dump table "nd_football_docs" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


# Could not dump table "ndlib_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


# Could not dump table "okhh_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


# Could not dump table "southbend_tech_docs" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


  create_table "squid_servers", primary_key: ["id", "droplet_id"], force: :cascade do |t|
    t.bigint "id", null: false
    t.timestamptz "created_at", default: -> { "now()" }, null: false
    t.integer "droplet_id", null: false
    t.text "ip"
    t.integer "wait_until"
    t.boolean "used_up", default: false

    t.unique_constraint ["droplet_id"], name: "squid_servers_droplet_id_key"
  end

  create_table "top_trends", id: :serial, force: :cascade do |t|
    t.boolean "isposted", default: false
    t.datetime "createdat", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "updatedat", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "deletedat", precision: nil
    t.text "prompt", null: false
    t.text "thumbnail_url"
    t.text "code"
    t.text "tag"
  end

  create_table "topics", id: :integer, default: nil, force: :cascade do |t|
    t.text "topic"
    t.integer "count", limit: 2, default: 0
    t.boolean "active", default: true
  end

# Could not dump table "tyco_documents" because of following StandardError
#   Unknown type 'vector' for column 'embedding'


  create_table "upsertion_records", primary_key: "uuid", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "key", null: false
    t.text "namespace", null: false
    t.float "updated_at", null: false
    t.text "group_id"
    t.index ["group_id"], name: "group_id_index"
    t.index ["key"], name: "key_index"
    t.index ["namespace"], name: "namespace_index"
    t.index ["updated_at"], name: "updated_at_index"
    t.unique_constraint ["key", "namespace"], name: "upsertion_records_key_namespace_key"
  end

  add_foreign_key "additional_data", "inventory", name: "fk_inventory_id", on_delete: :cascade
  add_foreign_key "additional_data2", "inventory", name: "fk_inventory_id", on_delete: :cascade
  add_foreign_key "additional_data_copy", "inventory", name: "fk_inventory_id", on_delete: :cascade
end
