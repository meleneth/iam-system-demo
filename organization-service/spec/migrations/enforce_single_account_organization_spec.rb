require "rails_helper"
require Rails.root.join("db/migrate/20260913000000_enforce_single_account_organization")

RSpec.describe EnforceSingleAccountOrganization do
  around do |example|
    connection = ActiveRecord::Base.connection
    original = connection.select_value("SHOW search_path")
    schema = connection.quote_table_name("ownership_repair_#{SecureRandom.hex(6)}")
    connection.execute("CREATE SCHEMA #{schema}")
    connection.execute("SET LOCAL search_path TO #{schema}")
    connection.create_table(:organization_accounts, id: :uuid) do |table|
      table.uuid :account_id
      table.uuid :organization_id
      table.timestamps
    end
    connection.add_index(:organization_accounts, :account_id)
    example.run
  ensure
    connection.execute("SET LOCAL search_path TO #{original}")
    connection.schema_cache.clear!
  end

  def insert_membership(account, organization)
    id = SecureRandom.uuid
    ActiveRecord::Base.connection.execute(<<~SQL)
      INSERT INTO organization_accounts (id, account_id, organization_id, created_at, updated_at)
      VALUES ('#{id}', '#{account}', '#{organization}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
    id
  end

  it "archives exact existing duplicate rows and enforces one organization per account" do
    connection = ActiveRecord::Base.connection
    account, organization = Array.new(2) { SecureRandom.uuid }
    ids = Array.new(2) { insert_membership(account, organization) }
    original_rows = connection.select_values("SELECT to_jsonb(oa)::text FROM organization_accounts oa").map { |row| JSON.parse(row) }
    described_class.new.migrate(:up)
    retained = connection.select_all("SELECT * FROM organization_accounts").to_a
    archived = connection.select_all("SELECT original_row FROM organization_account_projection_archives").to_a
    repaired_and_archived = connection.select_values("SELECT to_jsonb(oa)::text FROM organization_accounts oa UNION ALL SELECT original_row::text FROM organization_account_projection_archives").map { |row| JSON.parse(row) }
    expect(repaired_and_archived).to match_array(original_rows)
    expect(retained.map { |row| row.fetch("id") }).to eq([ids.min])
    expect(JSON.parse(archived.fetch(0).fetch("original_row")).fetch("id")).to eq(ids.max)
    expect(retained.first.fetch("organization_id")).to eq(organization)
    expect(connection.indexes(:organization_accounts).find { |index| index.columns == ["account_id"] }.unique).to eq(true)
  end

  it "refuses to guess the owner when existing rows assign an account to different organizations" do
    account = SecureRandom.uuid
    ids = Array.new(2) { insert_membership(account, SecureRandom.uuid) }
    expect { described_class.new.migrate(:up) }.to raise_error(RuntimeError, /Ambiguous account ownership/)
    expect(ActiveRecord::Base.connection.select_values("SELECT id FROM organization_accounts")).to match_array(ids)
  end
end
