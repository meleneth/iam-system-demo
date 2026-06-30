class CreateMspManagedOrganizations < ActiveRecord::Migration[8.0]
  def change
    create_table :msp_managed_organizations, id: :uuid do |t|
      t.uuid :msp_organization_id, null: false
      t.uuid :msp_account_id, null: false
      t.uuid :client_organization_id, null: false

      t.timestamps
    end

    add_index :msp_managed_organizations, :client_organization_id, unique: true, name: "idx_msp_managed_orgs_unique_client"
    add_index :msp_managed_organizations, :msp_organization_id
    add_index :msp_managed_organizations, :msp_account_id
    add_index :msp_managed_organizations, [:msp_organization_id, :msp_account_id], name: "idx_msp_managed_orgs_on_msp_org_account"
  end
end
