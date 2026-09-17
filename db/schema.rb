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

ActiveRecord::Schema[8.1].define(version: 2026_09_16_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "achievement_attempts", force: :cascade do |t|
    t.string "achievement_id", null: false
    t.datetime "created_at", null: false
    t.boolean "disqualified", default: false, null: false
    t.bigint "opened_at_tick", null: false
    t.string "owner_id", null: false
    t.string "run_id", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id", "run_id", "achievement_id"], name: "idx_on_owner_id_run_id_achievement_id_6a52275d8e", unique: true
  end

  create_table "awards", force: :cascade do |t|
    t.string "achievement_id", null: false
    t.datetime "created_at", null: false
    t.string "owner_id", null: false
    t.string "run_id"
    t.bigint "tick"
    t.datetime "updated_at", null: false
    t.index ["owner_id", "achievement_id"], name: "index_awards_on_owner_id_and_achievement_id", unique: true
  end

  create_table "incidents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "detail", default: {}, null: false
    t.string "mode"
    t.string "node"
    t.string "operation_id", null: false
    t.string "run_id", null: false
    t.integer "seq", null: false
    t.string "severity", null: false
    t.bigint "tick", null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "id"], name: "index_incidents_on_run_id_and_id"
    t.index ["run_id", "operation_id", "tick", "seq"], name: "index_incidents_on_run_id_and_operation_id_and_tick_and_seq", unique: true
  end

  create_table "loadouts", force: :cascade do |t|
    t.string "chassis", null: false
    t.datetime "created_at", null: false
    t.string "match_id", null: false
    t.string "operation_id", null: false
    t.jsonb "parts", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["match_id", "operation_id"], name: "index_loadouts_on_match_id_and_operation_id", unique: true
  end

  create_table "match_runs", force: :cascade do |t|
    t.string "chassis"
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.jsonb "loadout", default: {}, null: false
    t.string "match_id", null: false
    t.string "run_id", null: false
    t.bigint "seed"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.index ["match_id", "created_at"], name: "index_match_runs_on_match_id_and_created_at"
    t.index ["run_id"], name: "index_match_runs_on_run_id", unique: true
  end

  create_table "minion_conditions", force: :cascade do |t|
    t.string "cause"
    t.datetime "created_at", null: false
    t.integer "matches_remaining", default: 0, null: false
    t.string "minion_id", null: false
    t.string "owner_id", null: false
    t.string "run_id"
    t.datetime "updated_at", null: false
    t.index ["owner_id", "minion_id"], name: "index_minion_conditions_on_owner_id_and_minion_id", unique: true
  end

  create_table "progresses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "metric", null: false
    t.string "owner_id", null: false
    t.string "run_id"
    t.datetime "updated_at", null: false
    t.float "value", default: 0.0, null: false
    t.index ["owner_id", "run_id", "metric"], name: "index_progresses_on_owner_id_and_run_id_and_metric", unique: true, nulls_not_distinct: true
  end

  create_table "rosters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "crew", default: {}, null: false
    t.string "match_id", null: false
    t.string "operation_id", null: false
    t.datetime "updated_at", null: false
    t.index ["match_id", "operation_id"], name: "index_rosters_on_match_id_and_operation_id", unique: true
  end

  create_table "unlocks", force: :cascade do |t|
    t.string "blueprint_id", null: false
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.string "owner_id", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id", "kind", "blueprint_id"], name: "index_unlocks_on_owner_id_and_kind_and_blueprint_id", unique: true
  end
end
