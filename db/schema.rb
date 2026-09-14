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

ActiveRecord::Schema[8.1].define(version: 2026_09_14_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "loadouts", force: :cascade do |t|
    t.string "chassis", null: false
    t.datetime "created_at", null: false
    t.string "match_id", null: false
    t.string "operation_id", null: false
    t.jsonb "parts", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["match_id", "operation_id"], name: "index_loadouts_on_match_id_and_operation_id", unique: true
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
