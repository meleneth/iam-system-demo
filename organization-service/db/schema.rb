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

ActiveRecord::Schema[8.0].define(version: 2026_06_30_050100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "msp_managed_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "msp_account_id", null: false
    t.uuid "managed_account_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["managed_account_id"], name: "index_msp_managed_accounts_on_managed_account_id"
    t.index ["msp_account_id", "managed_account_id"], name: "idx_msp_managed_accounts_unique_pair", unique: true
    t.index ["msp_account_id"], name: "index_msp_managed_accounts_on_msp_account_id"
  end

  create_table "msp_managed_organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "msp_organization_id", null: false
    t.uuid "msp_account_id", null: false
    t.uuid "client_organization_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_organization_id"], name: "idx_msp_managed_orgs_unique_client", unique: true
    t.index ["msp_account_id"], name: "index_msp_managed_organizations_on_msp_account_id"
    t.index ["msp_organization_id", "msp_account_id"], name: "idx_msp_managed_orgs_on_msp_org_account"
    t.index ["msp_organization_id"], name: "index_msp_managed_organizations_on_msp_organization_id"
  end

  create_table "organization_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "organization_id"
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_organization_accounts_on_account_id"
    t.index ["organization_id"], name: "index_organization_accounts_on_organization_id"
  end

  create_table "organizations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_organizations_on_account_id"
  end
end
