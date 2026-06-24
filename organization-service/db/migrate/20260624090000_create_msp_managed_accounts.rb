class CreateMspManagedAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :msp_managed_accounts, id: :uuid do |t|
      t.uuid :msp_account_id, null: false
      t.uuid :managed_account_id, null: false

      t.timestamps
    end

    add_index :msp_managed_accounts, [:msp_account_id, :managed_account_id], unique: true, name: "idx_msp_managed_accounts_unique_pair"
    add_index :msp_managed_accounts, :msp_account_id
    add_index :msp_managed_accounts, :managed_account_id
  end
end
