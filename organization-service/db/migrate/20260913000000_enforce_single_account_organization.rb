# Preserve duplicate projection evidence before enforcing the ownership invariant.
class EnforceSingleAccountOrganization < ActiveRecord::Migration[8.0]
  def up
    ambiguous = select_value(<<~SQL)
      SELECT COUNT(*) FROM (
        SELECT account_id FROM organization_accounts
        GROUP BY account_id HAVING COUNT(DISTINCT organization_id) > 1
      ) ambiguous
    SQL
    raise "Ambiguous account ownership: reconcile explicitly before migration" if ambiguous.to_i.positive?

    create_table :organization_account_projection_archives, id: :uuid do |t|
      t.jsonb :original_row, null: false
      t.string :reason, null: false
    end
    execute <<~SQL
      WITH ranked AS (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY created_at, id) AS position
        FROM organization_accounts
      ), archived AS (
        INSERT INTO organization_account_projection_archives (id, original_row, reason)
        SELECT oa.id, to_jsonb(oa), 'duplicate account membership projection'
        FROM organization_accounts oa JOIN ranked ON ranked.id = oa.id
        WHERE ranked.position > 1
        RETURNING id
      )
      DELETE FROM organization_accounts WHERE id IN (SELECT id FROM archived)
    SQL
    remove_index :organization_accounts, :account_id
    add_index :organization_accounts, :account_id, unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Ownership repair retains original rows in organization_account_projection_archives"
  end
end
